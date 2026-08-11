extends Node

## Real ENet/SceneMultiplayer verification for finite drop and pickup RPCs.
##
##     godot --headless --path . dev/_multiplayer_pickup_test.tscn
##
## Server, remote owner, and late joiner run as separate MultiplayerAPI branches
## in one process. Calls below cross ENet; direct _server_drop/_server_pickup
## invocation is deliberately absent.

const PLAYER: PackedScene = preload("res://game/player/player.tscn")
const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")
const SETTINGS_PATH := "user://settings.cfg"
const CONNECT_FRAMES := 360
const RPC_FRAMES := 360

var _failures := 0
var _port := 0

var _server_branch: Node
var _owner_branch: Node
var _late_branch: Node
var _server_api: SceneMultiplayer
var _owner_api: SceneMultiplayer
var _late_api: SceneMultiplayer
var _server_peer: ENetMultiplayerPeer
var _owner_peer: ENetMultiplayerPeer
var _late_peer: ENetMultiplayerPeer

var _server_world: GameWorld
var _owner_world: GameWorld
var _late_world: GameWorld
var _server_owner: OnlinePlayer
var _owner_player: OnlinePlayer
var _host_player: OnlinePlayer
var _owner_id := 0
var _test_pickup_id := 0

var _settings_existed := false
var _settings_bytes := PackedByteArray()
var _saved_players: Dictionary
var _saved_state: int
var _saved_single_player := false
var _saved_host := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_snapshot_settings()
	_saved_players = NetworkManager.players.duplicate(true)
	_saved_state = int(NetworkManager.state)
	_saved_single_player = NetworkManager.is_single_player
	_saved_host = NetworkManager.is_host
	for item_id: String in ItemDB.ITEMS:
		ItemIcons._cache[item_id] = ImageTexture.new()
	NetworkManager.players.clear()
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.is_single_player = false
	NetworkManager.is_host = true

	if not await _start_initial_peers():
		await _finish()
		return
	await _build_initial_worlds()
	if _server_owner == null or _owner_player == null or _host_player == null:
		_expect(false, "server and owner player mirrors are available")
		await _finish()
		return

	await _check_remote_drop()
	await _finish()


func _start_initial_peers() -> bool:
	_server_branch = Node.new()
	_server_branch.name = "ServerBranch"
	add_child(_server_branch)
	_server_api = SceneMultiplayer.new()
	_server_peer = _listen()
	if _server_peer == null:
		_expect(false, "ENet server binds a local test port")
		return false
	_server_api.multiplayer_peer = _server_peer
	get_tree().set_multiplayer(_server_api, _server_branch.get_path())

	_owner_branch = Node.new()
	_owner_branch.name = "OwnerBranch"
	add_child(_owner_branch)
	_owner_api = SceneMultiplayer.new()
	_owner_peer = ENetMultiplayerPeer.new()
	var error := _owner_peer.create_client("127.0.0.1", _port)
	if not _expect(error == OK, "remote owner starts an ENet client"):
		return false
	_owner_api.multiplayer_peer = _owner_peer
	get_tree().set_multiplayer(_owner_api, _owner_branch.get_path())
	var connected := await _wait_until(
		Callable(self, "_owner_connected"), CONNECT_FRAMES)
	_expect(connected, "remote owner connects through ENet")
	if not connected:
		return false
	_owner_id = _owner_api.get_unique_id()
	return _expect(_owner_id > 1, "remote owner receives a non-authority peer id")


func _listen() -> ENetMultiplayerPeer:
	var first_port := 47000 + (OS.get_process_id() % 1000)
	for offset in 12:
		var peer := ENetMultiplayerPeer.new()
		var candidate_port := first_port + offset
		if peer.create_server(candidate_port, 4) == OK:
			_port = candidate_port
			return peer
	return null


func _build_initial_worlds() -> void:
	_server_world = _new_world()
	_server_branch.add_child(_server_world)
	_owner_world = _new_world()
	_owner_branch.add_child(_owner_world)
	await _network_frames(4)

	# Identical relative node paths are required for player snapshot RPCs.
	_server_owner = _add_player(_server_world, _owner_id)
	_host_player = _add_player(_server_world, 1)
	_owner_player = _add_player(_owner_world, _owner_id)
	_server_world._spawned_players[_owner_id] = _server_owner
	_server_world._spawned_players[1] = _host_player
	_owner_world._spawned_players[_owner_id] = _owner_player
	await _network_frames(4)

	_clear_player(_server_owner)
	_clear_player(_host_player)
	_clear_player(_owner_player)
	_owner_player.backpack.set_item(0, "sword")
	_owner_player.sync_loadout_to_server()
	var mirrored := await _wait_until(
		Callable(self, "_owner_mirrored"), RPC_FRAMES)
	_expect(mirrored,
		"owner loadout snapshot reaches the authoritative server mirror")


func _new_world() -> GameWorld:
	var world := GameWorld.new()
	world.name = "World"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var marker := Marker3D.new()
	marker.name = "Spawn1"
	spawn_points.add_child(marker)
	world.add_child(spawn_points)
	var cycle := TEST_CYCLE.new() as CelestialCycle
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	return world


func _add_player(world: GameWorld, peer_id: int) -> OnlinePlayer:
	var player := PLAYER.instantiate() as OnlinePlayer
	player.name = str(peer_id)
	player.peer_id = peer_id
	player.defer_camera = true
	world.add_child(player, true)
	player.set_process(false)
	player.set_physics_process(false)
	player.global_transform = Transform3D.IDENTITY
	player.reset_network_state(player.global_transform)
	return player


func _clear_player(player: OnlinePlayer) -> void:
	player.holster()
	player.equipment.clear()
	player.hotbar.clear()
	player.abilities.clear()
	player.backpack.clear()


func _check_remote_drop() -> void:
	if not _server_owner.authoritative_inventory_ready():
		return

	# Public peer-id spoofing dies on the owner before a packet is sent.
	_owner_world.request_drop(1, "backpack", 0, "sword")
	await _network_frames(3)
	_expect(_owner_player.backpack.get_item(0) == "sword"
		and _server_world.pickup_snapshots().is_empty(),
		"client cannot name another peer in a drop request")

	# This is a real client RPC with an invalid generation. The server derives the
	# sender from ENet and rejects it without changing canonical state.
	_owner_world._request_drop_from_client.rpc_id(
		1, "backpack", 0, "sword",
		_owner_player.inventory_generation() + 7)
	await _network_frames(4)
	_expect(_server_owner.backpack.get_item(0) == "sword"
		and _server_world.pickup_snapshots().is_empty(),
		"server rejects a remote stale-generation drop")

	_owner_world.request_drop(_owner_id, "backpack", 0, "sword")
	_expect(_owner_player.backpack.get_item(0) == "sword",
		"remote source waits for authoritative drop confirmation")
	var dropped := await _wait_until(
		Callable(self, "_drop_replicated"), RPC_FRAMES)
	_expect(dropped, "remote drop confirms and replicates its spawn")
	if not dropped:
		return
	var snapshot: Dictionary = _server_world.pickup_snapshots()[0]
	var pickup_id := int(snapshot.get("pickup_id", 0))
	_test_pickup_id = pickup_id
	_expect(_owner_player._confirmed_drop_ids.has(pickup_id)
		and _server_owner.backpack.get_item(0).is_empty(),
		"owner applies one authoritative removal confirmation")
	_expect(_server_world.pickup_node(pickup_id) != null
		and _owner_world.pickup_node(pickup_id) != null,
		"server and remote owner both hold the replicated pickup")

	if not await _start_late_joiner():
		return
	var joined := await _wait_until(
		Callable(self, "_late_snapshot_received"), RPC_FRAMES)
	_expect(joined, "late join snapshot contains the live pickup")

	# The remote owner claims first through ENet. A host claim for the same id
	# follows and must lose; a second owner packet must not grant twice either.
	_owner_world.request_pickup(pickup_id, _owner_id)
	var claimed := await _wait_until(
		Callable(self, "_claim_replicated"), RPC_FRAMES)
	_expect(claimed, "winning remote claim grants once and despawns on all peers")
	var owner_count := _count_item(_owner_player, "sword")
	_server_world.request_pickup(pickup_id, 1)
	_owner_world.request_pickup(pickup_id, _owner_id)
	await _network_frames(6)
	_expect(owner_count == 1
		and _count_item(_owner_player, "sword") == 1
		and _count_item(_host_player, "sword") == 0,
		"one pickup claim wins and duplicate claims grant nothing")
	_expect(_owner_player._received_pickup_ids.has(pickup_id)
		and _owner_player._received_pickup_ids.size() == 1,
		"remote owner records exactly one authoritative grant")


func _start_late_joiner() -> bool:
	_late_branch = Node.new()
	_late_branch.name = "LateBranch"
	add_child(_late_branch)
	_late_api = SceneMultiplayer.new()
	_late_peer = ENetMultiplayerPeer.new()
	var error := _late_peer.create_client("127.0.0.1", _port)
	if not _expect(error == OK, "late joiner starts an ENet client"):
		return false
	_late_api.multiplayer_peer = _late_peer
	get_tree().set_multiplayer(_late_api, _late_branch.get_path())
	var connected := await _wait_until(
		Callable(self, "_late_connected"), CONNECT_FRAMES)
	if not _expect(connected, "late joiner connects after the drop"):
		return false
	_late_world = _new_world()
	_late_branch.add_child(_late_world)
	await _network_frames(3)
	return true


func _owner_connected() -> bool:
	return _owner_peer != null and _owner_peer.get_connection_status() \
		== MultiplayerPeer.CONNECTION_CONNECTED


func _late_connected() -> bool:
	return _late_peer != null and _late_peer.get_connection_status() \
		== MultiplayerPeer.CONNECTION_CONNECTED


func _owner_mirrored() -> bool:
	return _server_owner != null \
		and _server_owner.authoritative_inventory_ready() \
		and _server_owner.backpack.get_item(0) == "sword"


func _drop_replicated() -> bool:
	return _server_world.pickup_snapshots().size() == 1 \
		and _owner_player.backpack.get_item(0).is_empty() \
		and _owner_world.pickup_snapshots().size() == 1


func _late_snapshot_received() -> bool:
	return _late_world != null \
		and _late_world.pickup_node(_test_pickup_id) != null


func _claim_replicated() -> bool:
	return _owner_player.backpack.find("sword") >= 0 \
		and _server_world.pickup_node(_test_pickup_id) == null \
		and _owner_world.pickup_node(_test_pickup_id) == null \
		and _late_world.pickup_node(_test_pickup_id) == null


func _count_item(player: OnlinePlayer, item_id: String) -> int:
	var count := 0
	for container: ItemContainer in [
		player.equipment,
		player.hotbar,
		player.backpack,
	]:
		for held: String in container.items():
			if held == item_id:
				count += 1
	return count


func _wait_until(test: Callable, frames: int) -> bool:
	for _frame in frames:
		_poll_network()
		if bool(test.call()):
			return true
		await get_tree().process_frame
	return bool(test.call())


func _network_frames(frames: int) -> void:
	for _frame in frames:
		_poll_network()
		await get_tree().process_frame


func _poll_network() -> void:
	for api: SceneMultiplayer in [_server_api, _owner_api, _late_api]:
		if api != null and api.has_multiplayer_peer():
			api.poll()


func _expect(condition: bool, message: String) -> bool:
	if condition:
		print("multiplayer_pickup_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("multiplayer_pickup_test: FAIL  %s" % message)
	return false


func _snapshot_settings() -> void:
	var path := ProjectSettings.globalize_path(SETTINGS_PATH)
	_settings_existed = FileAccess.file_exists(path)
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes(path)


func _restore_settings() -> void:
	var path := ProjectSettings.globalize_path(SETTINGS_PATH)
	if not _settings_existed:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("multiplayer_pickup_test: could not restore %s" % path)
		return
	file.store_buffer(_settings_bytes)
	file.close()


func _finish() -> void:
	get_tree().paused = false
	for peer: ENetMultiplayerPeer in [_late_peer, _owner_peer, _server_peer]:
		if peer != null:
			peer.close()
	for branch: Node in [_late_branch, _owner_branch, _server_branch]:
		if is_instance_valid(branch):
			branch.queue_free()
	for _frame in 3:
		await get_tree().process_frame
	NetworkManager.players.clear()
	NetworkManager.players.merge(_saved_players, true)
	NetworkManager.state = _saved_state as NetworkManager.SessionState
	NetworkManager.is_single_player = _saved_single_player
	NetworkManager.is_host = _saved_host
	_restore_settings()
	print("multiplayer_pickup_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
