class_name SteamLobbyService
extends Node

## Thin owner of Steamworks lobby state.
##
## Steam supplies discovery, friend invites, NAT traversal, and encrypted relay
## transport. NetworkManager still owns Godot's MultiplayerAPI and the game
## roster; keeping those jobs apart lets headless gameplay tests keep using their
## local ENet transport without pretending an IP address is part of the player UI.

signal availability_changed(available: bool, message: String)
signal lobby_created(lobby_id: int)
signal lobby_joined(lobby_id: int, owner_steam_id: int)
signal lobby_left
signal lobby_list_changed(lobbies: Array)
signal lobby_members_changed(members: Array)
signal lobby_data_changed(data: Dictionary)
signal invite_received(lobby_id: int, data: Dictionary, inviter_name: String)
signal operation_failed(message: String)

const PLAYTEST_APP_ID := 5098060
const FULL_GAME_APP_ID := 5098010
const LOBBY_SCHEMA := "1"
const MAX_RESULTS := 50

var available := false
var lobby_id := 0
var local_steam_id := 0
var local_persona_name := ""
var last_error := "Steam is not initialized."

var _pending_host_options: Dictionary = {}
var _pending_invite_id := 0
var _pending_inviter_name := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not Engine.has_singleton("Steam"):
		_set_unavailable("Steam support is not installed in this build.")
		return

	_connect_callbacks()
	# Auto-initialization runs before the renderer so Steam's overlay can hook the
	# exported Vulkan window. The fallback keeps this script usable if that
	# project setting is deliberately switched off in a stripped test project.
	var result: Dictionary = Steam.get_steam_init_result()
	if result.is_empty():
		result = Steam.steamInitEx(_configured_app_id(), true)
	if int(result.get("status", -1)) != 0:
		_set_unavailable(str(result.get(
			"verbal", "Steam could not initialize. Make sure Steam is running.")))
		return

	available = true
	last_error = ""
	local_steam_id = int(Steam.getSteamID())
	local_persona_name = str(Steam.getPersonaName())
	availability_changed.emit(true, "Connected to Steam as %s" % local_persona_name)
	call_deferred("_read_command_line_invite")


func _process(_delta: float) -> void:
	# GodotSteam 4.21 cannot combine pre-render auto-initialization (needed by
	# the Vulkan overlay) with embedded callbacks. Pumping here is the supported
	# combination and keeps lobby lists and friend invites responsive.
	if available:
		Steam.run_callbacks()


## GodotSteam's App Type enum is App, Demo, Playtest, Tool. Both supplied IDs
## live in Project Settings; changing App Type from 2 to 0 is the release switch.
func _configured_app_id() -> int:
	var app_type := int(ProjectSettings.get_setting(
		"steam/initialization/app_data/app_type", 2))
	return FULL_GAME_APP_ID if app_type == 0 else PLAYTEST_APP_ID


func create_lobby(options: Dictionary) -> void:
	if not _require_steam():
		return
	if lobby_id != 0:
		operation_failed.emit("Leave the current Steam lobby before creating another.")
		return
	_pending_host_options = options.duplicate(true)
	var visibility := str(options.get("visibility", "public"))
	var lobby_type := Steam.LOBBY_TYPE_FRIENDS_ONLY \
		if visibility == "friends" else Steam.LOBBY_TYPE_PUBLIC
	Steam.createLobby(
		lobby_type,
		clampi(int(options.get("max_players", 8)), 2, 32)
	)


func join_lobby(next_lobby_id: int) -> void:
	if not _require_steam():
		return
	if next_lobby_id <= 0:
		operation_failed.emit("That Steam lobby is no longer available.")
		return
	if lobby_id != 0 and lobby_id != next_lobby_id:
		leave_lobby()
	Steam.joinLobby(next_lobby_id)


## Prevents a hosted lobby from being inherited as an apparently live room while
## the host transport is shutting down. Steam destroys the room once every
## disconnected member has left; until then these flags keep it closed and out of
## discovery.
func close_hosted_lobby() -> void:
	if lobby_id == 0 or not available:
		return
	Steam.setLobbyJoinable(lobby_id, false)
	Steam.setLobbyData(lobby_id, "started", "1")


func leave_lobby(clear_pending_invite := false) -> void:
	if available:
		if lobby_id != 0:
			Steam.leaveLobby(lobby_id)
		Steam.clearRichPresence()
	lobby_id = 0
	_pending_host_options.clear()
	if clear_pending_invite:
		_pending_invite_id = 0
		_pending_inviter_name = ""
	lobby_members_changed.emit([])
	lobby_left.emit()


func refresh_lobbies() -> void:
	if not _require_steam():
		lobby_list_changed.emit([])
		return
	Steam.addRequestLobbyListDistanceFilter(
		Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	Steam.addRequestLobbyListFilterSlotsAvailable(1)
	Steam.addRequestLobbyListResultCountFilter(MAX_RESULTS)
	Steam.requestLobbyList()


func update_lobby_data(changes: Dictionary) -> void:
	if not available or lobby_id == 0:
		return
	for key: Variant in changes:
		if str(key) == "code":
			continue
		Steam.setLobbyData(lobby_id, str(key), _metadata_text(changes[key]))
	lobby_data_changed.emit(lobby_data(lobby_id))


func set_joinable(joinable: bool) -> void:
	if available and lobby_id != 0:
		Steam.setLobbyJoinable(lobby_id, joinable)
		Steam.setLobbyData(lobby_id, "started", "0" if joinable else "1")


func invite_friends() -> void:
	if not _require_steam() or lobby_id == 0:
		operation_failed.emit("Create or join a Steam lobby before inviting friends.")
		return
	Steam.activateGameOverlayInviteDialog(lobby_id)


func current_members() -> Array:
	return lobby_members(lobby_id)


func lobby_members(for_lobby_id: int) -> Array:
	var members: Array = []
	if not available or for_lobby_id <= 0:
		return members
	var owner := int(Steam.getLobbyOwner(for_lobby_id))
	var count := int(Steam.getNumLobbyMembers(for_lobby_id))
	for index in count:
		var member_id := int(Steam.getLobbyMemberByIndex(for_lobby_id, index))
		if member_id <= 0:
			continue
		members.append({
			"steam_id": member_id,
			"name": (
				local_persona_name if member_id == local_steam_id
				else str(Steam.getFriendPersonaName(member_id))
			),
			"is_host": member_id == owner,
		})
	return members


func lobby_data(for_lobby_id: int) -> Dictionary:
	if not available or for_lobby_id <= 0:
		return {}
	var mode := str(Steam.getLobbyData(for_lobby_id, "mode"))
	if mode.is_empty():
		mode = "story"
	var maximum := int(Steam.getLobbyData(for_lobby_id, "max_players"))
	if maximum <= 0:
		maximum = int(Steam.getLobbyMemberLimit(for_lobby_id))
	var owner := int(Steam.getLobbyOwner(for_lobby_id))
	var name := str(Steam.getLobbyData(for_lobby_id, "name"))
	if name.is_empty():
		name = "%s's Lobby" % str(Steam.getFriendPersonaName(owner))
	return {
		"lobby_id": for_lobby_id,
		"name": name,
		"lobby_name": name,
		"mode": mode,
		"duels_mode": str(Steam.getLobbyData(for_lobby_id, "duels_mode")),
		"map": str(Steam.getLobbyData(for_lobby_id, "map")),
		"visibility": str(Steam.getLobbyData(for_lobby_id, "visibility")),
		"passworded": Steam.getLobbyData(for_lobby_id, "passworded") == "1",
		"started": Steam.getLobbyData(for_lobby_id, "started") == "1",
		"players": int(Steam.getNumLobbyMembers(for_lobby_id)),
		"max_players": maximum,
		"owner_steam_id": owner,
		"owner_name": str(Steam.getFriendPersonaName(owner)),
		"schema": str(Steam.getLobbyData(for_lobby_id, "schema")),
	}


func _connect_callbacks() -> void:
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	Steam.lobby_data_update.connect(_on_lobby_data_update)
	Steam.join_requested.connect(_on_join_requested)


func _on_lobby_created(result: int, created_lobby_id: int) -> void:
	if result != Steam.RESULT_OK:
		_pending_host_options.clear()
		operation_failed.emit("Steam could not create the lobby (%d)." % result)
		return
	lobby_id = created_lobby_id
	var visibility := str(_pending_host_options.get("visibility", "public"))
	var metadata := {
		"name": str(_pending_host_options.get("name", "Steam Lobby")),
		"mode": str(_pending_host_options.get("mode", "story")),
		"duels_mode": str(_pending_host_options.get("duels_mode", "")),
		"map": str(_pending_host_options.get("map", "world")),
		"visibility": visibility,
		"passworded": visibility == "private",
		"max_players": int(_pending_host_options.get("max_players", 8)),
		"started": false,
		"schema": LOBBY_SCHEMA,
	}
	update_lobby_data(metadata)
	Steam.setLobbyJoinable(lobby_id, true)
	_set_member_identity()
	_set_join_presence()
	lobby_created.emit(lobby_id)


func _on_lobby_joined(
		joined_lobby_id: int,
		_permissions: int,
		_locked: bool,
		response: int
	) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		operation_failed.emit(_join_error(response))
		return
	lobby_id = joined_lobby_id
	_set_member_identity()
	_set_join_presence()
	lobby_joined.emit(lobby_id, int(Steam.getLobbyOwner(lobby_id)))
	lobby_members_changed.emit(current_members())
	lobby_data_changed.emit(lobby_data(lobby_id))


func _on_lobby_match_list(lobby_ids: Array) -> void:
	var lobbies: Array = []
	for id_variant: Variant in lobby_ids:
		var data := lobby_data(int(id_variant))
		if data.is_empty() or str(data.get("schema", "")) != LOBBY_SCHEMA:
			continue
		if bool(data.get("started", false)):
			continue
		lobbies.append(data)
	lobbies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")).naturalnocasecmp_to(
			str(b.get("name", ""))) < 0
	)
	lobby_list_changed.emit(lobbies)


func _on_lobby_chat_update(
		changed_lobby_id: int,
		_user_changed_id: int,
		_making_change_id: int,
		_chat_state: int
	) -> void:
	if changed_lobby_id == lobby_id:
		lobby_members_changed.emit(current_members())


func _on_lobby_data_update(
		success: bool,
		changed_lobby_id: int,
		member_id: int
	) -> void:
	if _pending_invite_id == changed_lobby_id and member_id == changed_lobby_id:
		var invite_id := _pending_invite_id
		var inviter := _pending_inviter_name
		_pending_invite_id = 0
		_pending_inviter_name = ""
		invite_received.emit(
			invite_id,
			lobby_data(invite_id) if success else {},
			inviter
		)
	if changed_lobby_id == lobby_id:
		lobby_data_changed.emit(lobby_data(lobby_id))
		lobby_members_changed.emit(current_members())


func _on_join_requested(requested_lobby_id: int, friend_id: int) -> void:
	var inviter := str(Steam.getFriendPersonaName(friend_id))
	_queue_invite(requested_lobby_id, inviter)


func _read_command_line_invite() -> void:
	var arguments := OS.get_cmdline_args()
	for index in arguments.size():
		var argument := str(arguments[index])
		if argument == "+connect_lobby" and index + 1 < arguments.size():
			_queue_invite(int(arguments[index + 1]), "")
			return
		if argument.begins_with("+connect_lobby="):
			_queue_invite(int(argument.get_slice("=", 1)), "")
			return


func _queue_invite(requested_lobby_id: int, inviter_name: String) -> void:
	if requested_lobby_id <= 0:
		return
	_pending_invite_id = requested_lobby_id
	_pending_inviter_name = inviter_name
	if not Steam.requestLobbyData(requested_lobby_id):
		_pending_invite_id = 0
		_pending_inviter_name = ""
		invite_received.emit(
			requested_lobby_id, lobby_data(requested_lobby_id), inviter_name)


func _set_member_identity() -> void:
	if lobby_id == 0:
		return
	Steam.setLobbyMemberData(lobby_id, "steam_name", local_persona_name)


## This is what makes "Join Game" appear on a friend's Steam profile. Steam
## starts a closed game with the same +connect_lobby argument handled above.
func _set_join_presence() -> void:
	Steam.setRichPresence("connect", "+connect_lobby %d" % lobby_id)
	Steam.setRichPresence("status", "Waiting in a lobby")


func _metadata_text(value: Variant) -> String:
	if value is bool:
		return "1" if value else "0"
	return str(value)


func _require_steam() -> bool:
	if available:
		return true
	operation_failed.emit(last_error)
	return false


func _set_unavailable(message: String) -> void:
	available = false
	last_error = message if not message.is_empty() else \
		"Steam could not initialize. Make sure Steam is running."
	availability_changed.emit(false, last_error)


func _join_error(response: int) -> String:
	match response:
		Steam.CHAT_ROOM_ENTER_RESPONSE_DOESNT_EXIST:
			return "That Steam lobby no longer exists."
		Steam.CHAT_ROOM_ENTER_RESPONSE_NOT_ALLOWED:
			return "Steam did not allow this account into the lobby."
		Steam.CHAT_ROOM_ENTER_RESPONSE_FULL:
			return "That Steam lobby is full."
		Steam.CHAT_ROOM_ENTER_RESPONSE_BANNED:
			return "This Steam account is banned from that lobby."
		Steam.CHAT_ROOM_ENTER_RESPONSE_RATE_LIMIT_EXCEEDED:
			return "Steam is receiving join requests too quickly. Try again shortly."
		_:
			return "Steam could not join the lobby (%d)." % response
