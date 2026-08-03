class_name GameWorld
extends Node3D

## The world is also the home screen. It is loaded once, empty, and the menu is a
## camera and an overlay put over it (see ui/menu/home_screen.gd); players are
## spawned only once a session exists. Nothing between the title and playing is a
## scene change, which is what keeps the planet's quadtree built across it.

const PLAYER_SCENE := preload("res://game/player/player.tscn")

@onready var spawn_points: Node3D = $SpawnPoints

var _spawned_players: Dictionary = {}
var _locally_paused := false
var _home_screen: HomeScreen
## Set once a session has been opened here, so a second `session_started` — the
## one a client gets on connecting, after the host's — cannot spawn twice.
var _session_open := false
var _spawn_override := Transform3D.IDENTITY
var _has_spawn_override := false
## Look the home screen was showing when New Game was pressed. Wins over the
## roster metadata for the local peer so the body that starts is the one that
## was on screen, not a stale settings read.
var _look_override: Dictionary = {}
var _has_look_override := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	NetworkManager.active_world = self
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_left.connect(_despawn_player)
	NetworkManager.session_started.connect(_begin_session)

	if NetworkManager.state == NetworkManager.SessionState.IDLE:
		_open_home_screen()
	else:
		_begin_session()


func _exit_tree() -> void:
	if NetworkManager.active_world == self:
		NetworkManager.active_world = null
	if NetworkManager.player_registered.is_connected(_on_player_registered):
		NetworkManager.player_registered.disconnect(_on_player_registered)
	if NetworkManager.player_left.is_connected(_despawn_player):
		NetworkManager.player_left.disconnect(_despawn_player)
	if NetworkManager.session_started.is_connected(_begin_session):
		NetworkManager.session_started.disconnect(_begin_session)


func local_player() -> OnlinePlayer:
	return _spawned_players.get(multiplayer.get_unique_id()) as OnlinePlayer


## Where the local player will be put when a session opens, overriding the spawn
## markers. The home screen uses it to start the player exactly where the
## character it has been showing was standing.
func override_local_spawn(at_transform: Transform3D) -> void:
	_spawn_override = at_transform
	_has_spawn_override = true


func override_local_look(look: Dictionary) -> void:
	_look_override = look.duplicate(true)
	_has_look_override = true


func _open_home_screen() -> void:
	_home_screen = HomeScreen.new()
	_home_screen.name = "HomeScreen"
	_home_screen.frame = _spawn_transform(1)
	add_child(_home_screen)


func _begin_session() -> void:
	if _session_open:
		return
	_session_open = true
	if multiplayer.is_server():
		for peer_id in NetworkManager.players:
			_spawn_player(int(peer_id), NetworkManager.get_player_metadata(int(peer_id)), _spawn_transform(int(peer_id)), true)
	else:
		_request_world_state.rpc_id(1)


## What being in a menu costs. Escape used to raise a pause card of the world's
## own; now [GameMenu] is that card and calls this instead, but the policy stays
## here because it is about the session and not about the menu:
##
## - **Single player** really stops. There is nobody else in the world to keep it
##   turning for, and stopping means you can read a settings page without falling
##   out of the sky while you do.
## - **In company** nothing stops. The other players are still playing, so all this
##   can honestly do is take the mouse and stop taking this player's input — which
##   [method OnlinePlayer.open_menu] has already done by the time this is called.
func set_local_pause(paused: bool) -> void:
	_locally_paused = paused
	get_tree().paused = paused and NetworkManager.is_single_player


## Whether a menu is holding this player out of the world. Not the same question as
## `get_tree().paused`, which is only true in single player, and the reason this is
## worth asking separately: in company the world keeps turning and this is still the
## honest answer to "am I in a menu".
func locally_paused() -> bool:
	return _locally_paused


## Drop the session and go back to the home screen. Reached from the Settings tab's
## LEAVE GAME; the menu raises it rather than doing it, because what a world is is
## this node's business.
func leave_session() -> void:
	get_tree().paused = false
	NetworkManager.leave_game()
	if NetworkManager.menu_scene_path.is_empty():
		queue_free()


func _on_player_registered(peer_id: int, metadata: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_spawn_player.rpc(peer_id, metadata, _spawn_transform(peer_id), true)


## [param in_flight] is for the spawn markers, which hang in orbit with nothing
## under them. A player rebuilt from a late joiner's snapshot is placed wherever
## they already were, and their real stance arrives on the next sync packet.
@rpc("authority", "call_local", "reliable")
func _spawn_player(peer_id: int, metadata: Dictionary, at_transform: Transform3D, in_flight: bool) -> void:
	if _spawned_players.has(peer_id):
		return
	var player := PLAYER_SCENE.instantiate() as OnlinePlayer
	player.name = str(peer_id)
	player.peer_id = peer_id
	player.display_name = str(metadata.get("name", "Player"))
	# The home screen still owns the viewport and the mouse; it hands both to the
	# body at the end of its sweep rather than losing them the moment it spawns.
	player.defer_camera = is_instance_valid(_home_screen) \
		and peer_id == multiplayer.get_unique_id()
	add_child(player, true)
	# Look arrives with the roster metadata so every peer builds the same body
	# before the first sync packet. The home screen can override the local peer
	# with the preview that was just on screen.
	var look := {
		"body": metadata.get("body", CharacterDB.DEFAULT_BODY),
		"worn": metadata.get("worn", {}),
		"tints": metadata.get("tints", {}),
	}
	if _has_look_override and peer_id == multiplayer.get_unique_id():
		look = _look_override.duplicate(true)
		_has_look_override = false
	player.apply_look(look)
	player.global_transform = at_transform
	player.reset_network_state(at_transform)
	if in_flight:
		player.start_flying()
	_spawned_players[peer_id] = player


@rpc("authority", "call_local", "reliable")
func _despawn_player(peer_id: int) -> void:
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	_spawned_players.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()


@rpc("any_peer", "reliable")
func _request_world_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var snapshots: Array = []
	for peer_id in NetworkManager.players:
		var id := int(peer_id)
		var player := _spawned_players.get(id) as OnlinePlayer
		var player_transform := player.global_transform if is_instance_valid(player) else _spawn_transform(id)
		var meta: Dictionary = NetworkManager.get_player_metadata(id)
		snapshots.append({
			"peer_id": id,
			"metadata": meta,
			"transform": player_transform,
			# Clothes and weapons are broadcast when they change, so a peer joining
			# later has to be told what everyone already has on and in hand.
			"worn": player.worn_items() if is_instance_valid(player) else PackedStringArray(),
			"held": player.held_item() if is_instance_valid(player) else "",
			"body": player.body_id() if is_instance_valid(player) else str(meta.get("body", CharacterDB.DEFAULT_BODY)),
		})
	_receive_world_state.rpc_id(sender, snapshots)


@rpc("authority", "reliable")
func _receive_world_state(snapshots: Array) -> void:
	for snapshot_variant in snapshots:
		if not snapshot_variant is Dictionary:
			continue
		var snapshot: Dictionary = snapshot_variant
		var peer_id := int(snapshot.get("peer_id", 0))
		var meta: Dictionary = snapshot.get("metadata", {})
		if snapshot.has("body"):
			meta = meta.duplicate(true)
			meta["body"] = snapshot.get("body")
		_spawn_player(
			peer_id,
			meta,
			snapshot.get("transform", Transform3D.IDENTITY),
			false
		)
		var player := _spawned_players.get(peer_id) as OnlinePlayer
		if is_instance_valid(player):
			player.apply_worn(snapshot.get("worn", PackedStringArray()))
			player.apply_held(String(snapshot.get("held", "")))


func _spawn_transform(peer_id: int) -> Transform3D:
	if _has_spawn_override and peer_id == multiplayer.get_unique_id():
		return _spawn_override
	var points := spawn_points.get_children()
	if points.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0))
	var index := posmod(peer_id - 1, points.size())
	return (points[index] as Node3D).global_transform
