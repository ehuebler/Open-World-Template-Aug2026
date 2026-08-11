extends Node

## Central session coordinator. Add this script as the "NetworkManager" autoload.
## The host owns the roster and world spawning; player movement is validated and
## relayed by the host in player.gd.

signal status_changed(message: String)
signal lobby_list_changed(lobbies: Array)
signal player_registered(peer_id: int, metadata: Dictionary)
signal player_left(peer_id: int)
signal session_started
signal session_ended

enum SessionState {
	IDLE,
	STARTING,
	CONNECTING,
	IN_GAME,
	ERROR,
}

const WORLD_SCENE := "res://game/world.tscn"
const LanDiscoveryScript := preload("res://core/lan_discovery.gd")
const TextModerationScript := preload("res://core/text_moderation.gd")
const DEFAULT_PORT := 7777
const DEFAULT_MAX_PLAYERS := 8
const GAME_MODES: Array[String] = ["story", "crawler", "duels", "sandbox"]
const DUELS_MODES: Array[String] = ["battle", "race"]

var state: SessionState = SessionState.IDLE
var is_single_player := false
var is_host := false
var session_options: Dictionary = {}
var players: Dictionary = {}
var local_player_name := "Player"
## Leaving a game reloads the world with no session in it, which is the home
## screen: there is no separate menu scene to go back to.
var menu_scene_path := WORLD_SCENE
## The world in the tree, which registers itself. Asking it directly rather than
## reading `current_scene` also answers for a harness, which loads the world as a
## child of its own root.
var active_world: Node
var last_status := "Ready"
var _join_code := ""
var _rejection_pending := false

var _enet_peer: ENetMultiplayerPeer
var _local_lan_discovery: Node


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_lan_discovery().lobby_list_changed.connect(_on_lobby_list_changed)
	_set_status(SessionState.IDLE, "Ready")
	if "--server" in OS.get_cmdline_user_args():
		call_deferred("_start_from_command_line")


func start_single_player(game_mode := "story", duels_mode := "") -> void:
	_reset_session(false)
	is_single_player = true
	is_host = true
	local_player_name = saved_player_name()
	var selected_mode := sanitize_game_mode(game_mode)
	session_options = {
		"name": "Single Player",
		"max_players": 1,
		"port": 0,
		"mode": selected_mode,
		"duels_mode": (
			sanitize_duels_mode(duels_mode) if selected_mode == "duels" else ""),
	}
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players[1] = _sanitize_player_metadata(_local_look_metadata(1))
	_set_status(SessionState.STARTING, "Starting single-player game...")
	_open_world()


func host_game(options: Dictionary) -> void:
	_reset_session(false)
	_rejection_pending = false
	var port := clampi(int(options.get("port", DEFAULT_PORT)), 1, 65535)
	var max_players := clampi(int(options.get("max_players", DEFAULT_MAX_PLAYERS)), 2, 32)
	local_player_name = _clean_name(str(options.get("player_name", "Host")))
	session_options = options.duplicate(true)
	session_options["port"] = port
	session_options["max_players"] = max_players
	session_options["name"] = _clean_lobby_name(str(options.get("name", "%s's game" % local_player_name)))
	session_options["visibility"] = str(options.get("visibility", "public"))
	session_options["code"] = str(options.get("code", "")).strip_edges()
	session_options["mode"] = sanitize_game_mode(str(options.get("mode", "story")))
	session_options["duels_mode"] = (
		sanitize_duels_mode(str(options.get("duels_mode", "battle")))
		if session_options["mode"] == "duels" else "")
	if not TextModerationScript.is_allowed(local_player_name) or not TextModerationScript.is_allowed(session_options["name"]):
		_fail("Player and lobby names must use appropriate language.")
		return
	if session_options["visibility"] == "private" and session_options["code"].length() < 4:
		_fail("Private lobbies require a code.")
		return

	_enet_peer = ENetMultiplayerPeer.new()
	var error := _enet_peer.create_server(port, max_players)
	if error != OK:
		_enet_peer = null
		_fail("Could not create the lobby (%s)." % error_string(error))
		return

	is_host = true
	multiplayer.multiplayer_peer = _enet_peer
	players[1] = _sanitize_player_metadata(_local_look_metadata(1))
	_lan_discovery().begin_host_advertising(_lobby_metadata())
	_set_status(SessionState.STARTING, "Starting lobby...")
	_open_world()


func join_game(address: String, port: int, player_name: String, lobby_code := "") -> void:
	_reset_session(false)
	_rejection_pending = false
	var clean_address := address.strip_edges()
	if clean_address.is_empty():
		_fail("Enter a host address.")
		return
	if port < 1 or port > 65535:
		_fail("Port must be between 1 and 65535.")
		return

	local_player_name = _clean_name(player_name)
	_join_code = str(lobby_code).strip_edges()
	_enet_peer = ENetMultiplayerPeer.new()
	var error := _enet_peer.create_client(clean_address, port)
	if error != OK:
		_enet_peer = null
		_fail("Could not start connection (%s)." % error_string(error))
		return

	multiplayer.multiplayer_peer = _enet_peer
	_set_status(SessionState.CONNECTING, "Connecting...")


func refresh_lobbies() -> void:
	_set_status(state, "Searching for games...")
	_lan_discovery().refresh_lobbies()


func leave_game() -> void:
	_reset_session(true)
	_set_status(SessionState.IDLE, "Disconnected")
	session_ended.emit()


func _start_from_command_line() -> void:
	var options := {
		"player_name": "Server",
		"name": "Local Co-op Server",
		"port": DEFAULT_PORT,
		"max_players": DEFAULT_MAX_PLAYERS,
		"visibility": "public",
		"code": "",
		"mode": "story",
		"duels_mode": "",
	}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			options["port"] = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--max-players="):
			options["max_players"] = int(argument.trim_prefix("--max-players="))
		elif argument.begins_with("--lobby-name="):
			options["name"] = argument.trim_prefix("--lobby-name=")
		elif argument.begins_with("--player-name="):
			options["player_name"] = argument.trim_prefix("--player-name=")
		elif argument == "--private":
			options["visibility"] = "private"
		elif argument.begins_with("--lobby-code="):
			options["code"] = argument.trim_prefix("--lobby-code=")
		elif argument.begins_with("--game-mode="):
			options["mode"] = argument.trim_prefix("--game-mode=")
		elif argument.begins_with("--duels-mode="):
			options["duels_mode"] = argument.trim_prefix("--duels-mode=")
	host_game(options)


func get_local_peer_id() -> int:
	return multiplayer.get_unique_id()


## In a session with other people in it, which is what chat and voice wait for:
## a single-player game reaches IN_GAME too, and has nobody to talk to.
func in_multiplayer_session() -> bool:
	return state == SessionState.IN_GAME and not is_single_player


func get_player_metadata(peer_id: int) -> Dictionary:
	return players.get(peer_id, {}).duplicate(true)


func update_lobby_metadata(changes: Dictionary) -> void:
	if not is_host or is_single_player:
		return
	for key in changes:
		if key in ["name", "map", "mode", "duels_mode", "passworded"]:
			session_options[key] = changes[key]
	_lan_discovery().update_host_metadata(_lobby_metadata())


## The world is usually already loaded: the home screen lives inside it, so a
## session started from the menu only has to say so. Reloading the scene there
## would rebuild the planet's quadtree behind the menu and turn what should be a
## camera move into a cut. The scene change is left for the cases that really do
## arrive without a world, such as a dedicated server booting from the command
## line, or a client that has just been dropped back to a fresh menu.
func _open_world() -> void:
	if not is_instance_valid(active_world):
		var error := get_tree().change_scene_to_file(WORLD_SCENE)
		if error != OK:
			_fail("Could not load the game world (%s)." % error_string(error))
			return
	_set_status(SessionState.IN_GAME, "In game")
	session_started.emit()


func _on_connected_to_server() -> void:
	_set_status(SessionState.IN_GAME, "Connected")
	_open_world()
	# Deferring lets the new world enter the tree before the host broadcasts a spawn.
	call_deferred("_send_registration")


func _send_registration() -> void:
	var payload := _local_look_metadata(multiplayer.get_unique_id())
	payload["code"] = _join_code
	_register_player.rpc_id(1, payload)


func _on_peer_connected(peer_id: int) -> void:
	if is_host:
		_set_status(state, "Player %d connected; waiting for profile..." % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return
	if players.erase(peer_id):
		player_left.emit(peer_id)
		_remove_player.rpc(peer_id)
		_lan_discovery().update_host_metadata(_lobby_metadata())
	_set_status(state, "Player disconnected")


func _on_connection_failed() -> void:
	_reset_session(false)
	_fail("Connection failed.")


func _on_server_disconnected() -> void:
	if _rejection_pending:
		_rejection_pending = false
		return
	_reset_session(true)
	_fail("The host disconnected.")
	session_ended.emit()


@rpc("any_peer", "reliable")
func _register_player(metadata: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		return
	if not TextModerationScript.is_allowed(str(metadata.get("name", ""))):
		_reject_peer(sender, "Please choose an appropriate player name.")
		return
	if str(session_options.get("visibility", "public")) == "private":
		var expected_code := str(session_options.get("code", ""))
		if expected_code.is_empty() or str(metadata.get("code", "")) != expected_code:
			_reject_peer(sender, "The private lobby code is incorrect.")
			return
	var clean := _sanitize_player_metadata(metadata)
	clean["peer_id"] = sender
	players[sender] = clean
	_set_player_metadata.rpc(sender, clean)
	_receive_roster.rpc_id(sender, players)
	_receive_session_options.rpc_id(sender, _shared_session_options())
	player_registered.emit(sender, clean)
	_lan_discovery().update_host_metadata(_lobby_metadata())
	_set_status(state, "%s joined" % clean["name"])


@rpc("authority", "call_local", "reliable")
func _set_player_metadata(peer_id: int, metadata: Dictionary) -> void:
	players[peer_id] = metadata.duplicate(true)


@rpc("authority", "reliable")
func _receive_roster(roster: Dictionary) -> void:
	players = roster.duplicate(true)


@rpc("authority", "reliable")
func _receive_session_options(options: Dictionary) -> void:
	session_options = options.duplicate(true)


@rpc("authority", "call_local", "reliable")
func _remove_player(peer_id: int) -> void:
	players.erase(peer_id)
	player_left.emit(peer_id)


@rpc("authority", "reliable")
func _reject_connection(message: String) -> void:
	_rejection_pending = true
	_reset_session(true)
	_fail(message)
	session_ended.emit()


func _reject_peer(peer_id: int, message: String) -> void:
	_reject_connection.rpc_id(peer_id, message)
	get_tree().create_timer(0.25).timeout.connect(func() -> void:
		if _enet_peer != null:
			_enet_peer.disconnect_peer(peer_id)
	)


func _reset_session(return_to_menu: bool) -> void:
	_lan_discovery().stop_host_advertising()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_enet_peer = null
	is_single_player = false
	is_host = false
	players.clear()
	session_options.clear()
	_join_code = ""
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if return_to_menu and not menu_scene_path.is_empty() and ResourceLoader.exists(menu_scene_path):
		get_tree().change_scene_to_file(menu_scene_path)


func _lobby_metadata() -> Dictionary:
	return {
		"name": session_options.get("name", "Co-op game"),
		"address": "",
		"port": int(session_options.get("port", DEFAULT_PORT)),
		"players": players.size(),
		"max_players": int(session_options.get("max_players", DEFAULT_MAX_PLAYERS)),
		"map": str(session_options.get("map", "world")),
		"mode": str(session_options.get("mode", "story")),
		"duels_mode": str(session_options.get("duels_mode", "")),
		"visibility": str(session_options.get("visibility", "public")),
		"passworded": str(session_options.get("visibility", "public")) == "private",
	}


## Session configuration safe to hand to clients. The private code is
## deliberately absent: clients prove they know it while registering and never
## receive the host's copy back.
func _shared_session_options() -> Dictionary:
	return {
		"name": str(session_options.get("name", "Game")),
		"map": str(session_options.get("map", "world")),
		"mode": str(session_options.get("mode", "story")),
		"duels_mode": str(session_options.get("duels_mode", "")),
		"max_players": int(session_options.get("max_players", DEFAULT_MAX_PLAYERS)),
		"visibility": str(session_options.get("visibility", "public")),
	}


func sanitize_game_mode(value: String) -> String:
	var clean := value.strip_edges().to_lower()
	return clean if clean in GAME_MODES else "story"


func sanitize_duels_mode(value: String) -> String:
	var clean := value.strip_edges().to_lower()
	return clean if clean in DUELS_MODES else "battle"


func _sanitize_player_metadata(metadata: Dictionary) -> Dictionary:
	var look := {
		"body": CharacterDB.sanitize_body(str(metadata.get("body", CharacterDB.DEFAULT_BODY))),
		"skin": "",
		"worn": {},
		"tints": {},
	}
	look["skin"] = CharacterDB.sanitize_skin(str(look["body"]), str(metadata.get("skin", "")))
	var worn_raw: Variant = metadata.get("worn", {})
	if worn_raw is Dictionary:
		for slot: Variant in worn_raw:
			var item_id := str(worn_raw[slot])
			if ItemDB.has_item(item_id) and CharacterDB.apparel_fits(str(look["body"]), item_id):
				look["worn"][str(slot)] = item_id
	var tint_raw: Variant = metadata.get("tints", {})
	if tint_raw is Dictionary:
		look["tints"] = (tint_raw as Dictionary).duplicate(true)
	return {
		"name": _clean_name(str(metadata.get("name", "Player"))),
		"peer_id": int(metadata.get("peer_id", 0)),
		"body": look["body"],
		"skin": look["skin"],
		"worn": look["worn"],
		"tints": look["tints"],
	}


func _local_look_metadata(peer_id: int) -> Dictionary:
	var look := CharacterDB.load_look()
	return {
		"name": local_player_name,
		"peer_id": peer_id,
		"body": look.get("body", CharacterDB.DEFAULT_BODY),
		"skin": look.get("skin", CharacterDB.default_skin(
			str(look.get("body", CharacterDB.DEFAULT_BODY)))),
		"worn": look.get("worn", {}),
		"tints": look.get("tints", {}),
	}


## The name typed under the figure on the home screen. It is kept in settings
## rather than only in [member local_player_name] because it outlasts a session:
## single player uses it as-is, the lobby's two fields start on it, and it is what
## the host stamps on this peer's chat lines.
func saved_player_name() -> String:
	if SettingsManager == null:
		return _clean_name("")
	return _clean_name(str(SettingsManager.get_setting(&"appearance", &"name", "Player")))


## Stores the name and returns whether it was allowed. Moderated here rather than
## at the field, so the one rule in [code]core/text_moderation.gd[/code] covers
## the home screen the same way it already covers a lobby and a chat line — a name
## refused at the door of a lobby should never have been saveable.
func save_player_name(value: String) -> bool:
	var clean := _clean_name(value)
	if not TextModerationScript.is_allowed(clean):
		return false
	local_player_name = clean
	if SettingsManager != null:
		SettingsManager.set_setting(&"appearance", &"name", clean, false)
		SettingsManager.save_settings()
	return true


func _clean_name(value: String) -> String:
	var clean := value.strip_edges().substr(0, 24)
	return clean if not clean.is_empty() else "Player"


func _clean_lobby_name(value: String) -> String:
	var clean := value.strip_edges().substr(0, 48)
	return clean if not clean.is_empty() else "Co-op game"


func _set_status(new_state: SessionState, message: String) -> void:
	state = new_state
	last_status = message
	status_changed.emit(message)


func _fail(message: String) -> void:
	_set_status(SessionState.ERROR, message)
	push_error(message)


func _on_lobby_list_changed(lobbies: Array) -> void:
	lobby_list_changed.emit(lobbies)
	if state == SessionState.IDLE:
		status_changed.emit("Found %d game(s)" % lobbies.size())


func _lan_discovery() -> Node:
	var autoload := get_node_or_null("/root/LanDiscovery")
	if autoload != null:
		return autoload
	if _local_lan_discovery == null:
		_local_lan_discovery = LanDiscoveryScript.new()
		_local_lan_discovery.name = "LanDiscovery"
		add_child(_local_lan_discovery)
	return _local_lan_discovery
