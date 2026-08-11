extends Node

## Real ENet verification that two peers end up with the same battered ground.
##
##     godot --headless --path . dev/_ability_net_test.tscn
##
## Host, client and late joiner run as separate MultiplayerAPI branches in one
## process, the same arrangement [code]_multiplayer_pickup_test.gd[/code] uses.
## Everything below crosses a socket: nothing calls the receiving side directly,
## because the claim being made is about the wire and about who is allowed to
## change the world, and a direct call proves neither.
##
## The flora here is a stub rather than a biome. What a real [GroundCover] does
## with a hit is already settled in [code]_flora_damage_test.gd[/code]; what is
## unsettled is whether the volume and the confirmed break keys survive the trip,
## and a field with nothing growing in it answers that without standing three
## planets' worth of vegetation up in one process.

const PLAYER: PackedScene = preload("res://game/player/player.tscn")
const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")
const CONNECT_FRAMES := 360
const RPC_FRAMES := 240

## Somewhere on the sphere to cut, and something to cut with. Nothing depends on
## the numbers beyond their being distinctive enough to recognise on the far end.
const SCAR_RADIUS := 5.0
const SCAR_DEPTH := 2.25

## Plants the host decides are gone. Any three numbers: a break key is opaque to
## everything between the field that made it and the field that receives it.
static var BREAK_KEYS := PackedInt32Array([17, 41, 99])

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
var _owner_player: OnlinePlayer
var _owner_id := 0
## The volume the client sent, as the far end should find it.
var _expected_hit: DamageHit

var _saved_players: Dictionary
var _saved_state: int
var _saved_single_player := false
var _saved_host := false


## A damageable field with nothing growing in it: a ledger of what it was asked
## to absorb, and of what it has been told is gone.
class TestCover extends Node3D:
	var absorbed: Array[DamageHit] = []
	var broken := PackedInt32Array()
	var _fresh := PackedInt32Array()

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		add_to_group(DamageHit.FIELD_GROUP)

	func apply_damage(hit: DamageHit) -> float:
		absorbed.append(hit)
		return 0.0

	## Stands in for a plant that the damage finished off on this peer only.
	func break_here(keys: PackedInt32Array) -> void:
		for key in keys:
			if broken.find(key) < 0:
				broken.append(key)
			_fresh.append(key)

	func broken_keys() -> PackedInt32Array:
		return broken

	func drain_new_breaks() -> PackedInt32Array:
		var keys := _fresh
		_fresh = PackedInt32Array()
		return keys

	func apply_broken_keys(keys: PackedInt32Array) -> void:
		for key in keys:
			if broken.find(key) < 0:
				broken.append(key)

	## Whether a volume with these numbers was offered here.
	func saw(hit: DamageHit) -> bool:
		for seen in absorbed:
			if is_equal_approx(seen.amount, hit.amount) \
					and seen.origin.is_equal_approx(hit.origin) \
					and seen.toward.is_equal_approx(hit.toward) \
					and is_equal_approx(seen.radius, hit.radius) \
					and seen.kind == hit.kind \
					and is_equal_approx(seen.falloff, hit.falloff) \
					and seen.source_peer == hit.source_peer \
					and seen.ability_id == hit.ability_id:
				return true
		return false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
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

	if not await _start_peers():
		await _finish()
		return
	await _build_worlds()
	if _owner_player == null:
		_expect(false, "the client has a player of its own")
		await _finish()
		return

	await _check_scars()
	await _check_damage_volume()
	await _check_break_confirmation()
	await _check_late_join()
	await _finish()


## A crater asked for by a client is the host's to grant, and once granted it is
## in the same place on both peers' ground.
func _check_scars() -> void:
	var here := Vector3(0.3, 0.9, 0.2).normalized()
	_owner_world.request_scar(_scar(here))
	_expect(_scars(_owner_world).count() == 0,
		"a client does not cut its own ground while it waits")
	var granted := await _wait_until(_client_has_one_scar, RPC_FRAMES)
	_expect(granted, "the host grants a client's crater and it comes back")
	if not granted:
		return
	_expect(_scars(_server_world).count() == 1,
		"and the host cut the same one into its own ground")
	_expect(is_equal_approx(_scars(_server_world).depth_at(here),
			_scars(_owner_world).depth_at(here))
		and _scars(_owner_world).depth_at(here) > SCAR_DEPTH * 0.5,
		"both peers' ground has dropped by the same amount")

	# The other direction, which is the one the host itself punches through.
	var there := Vector3(-0.4, 0.8, 0.45).normalized()
	_server_world.request_scar(_scar(there))
	var shared := await _wait_until(_client_has_two_scars, RPC_FRAMES)
	_expect(shared, "a crater the host makes reaches the client too")


## The damage itself replicates as the volume rather than as its consequences,
## so what has to survive the trip is every number that decides who is inside it.
func _check_damage_volume() -> void:
	var hit := DamageHit.beam(
		Vector3(4.0, 1.5, 0.0), Vector3(9.0, 1.5, 2.0), 0.35, 18.0)
	hit.ability_id = "laser_eyes"
	_expected_hit = DamageHit.from_wire(hit.to_wire())
	_expected_hit.source_peer = _owner_id
	_owner_player.deal_damage(hit)
	var arrived := await _wait_until(_host_saw_the_volume, RPC_FRAMES)
	_expect(arrived, "a client's damage volume reaches the host unchanged")
	_expect(_cover(_owner_world).saw(_expected_hit),
		"and the client applied the same volume to its own flora")


## What actually broke is a correction, sent by the host a few times a second.
## Driven by hand here: every world in this process shares one scene tree and so
## one damage-field group, and a client left to its own timer would drain the
## host's pending breaks before the host had said them out loud.
func _check_break_confirmation() -> void:
	_cover(_server_world).break_here(BREAK_KEYS)
	_expect(_cover(_owner_world).broken_keys().is_empty(),
		"a break on the host has not reached the client by itself")
	_server_world.confirm_flora_breaks()
	var told := await _wait_until(_client_told_of_breaks, RPC_FRAMES)
	_expect(told, "the host's confirmed breaks reach the client")
	if not told:
		return
	_expect(_same_keys(_cover(_owner_world).broken_keys(), BREAK_KEYS),
		"and they are the same plants")
	_server_world.confirm_flora_breaks()
	await _network_frames(4)
	_expect(_cover(_owner_world).broken_keys().size() == BREAK_KEYS.size(),
		"a second pass confirms nothing twice")


## Somebody arriving after the fight gets the ground as it was left.
func _check_late_join() -> void:
	if not await _start_late_joiner():
		return
	_late_world._request_world_state.rpc_id(1)
	var caught_up := await _wait_until(_late_joiner_caught_up, RPC_FRAMES)
	_expect(caught_up, "a late joiner is told about the craters and the losses")
	if not caught_up:
		return
	_expect(_same_keys(_cover(_late_world).broken_keys(), BREAK_KEYS),
		"and about exactly the plants that are gone")


func _client_has_one_scar() -> bool:
	return _scars(_owner_world).count() == 1


func _client_has_two_scars() -> bool:
	return _scars(_owner_world).count() == 2


func _host_saw_the_volume() -> bool:
	return _cover(_server_world).saw(_expected_hit)


func _owner_connected() -> bool:
	return _owner_peer != null and _owner_peer.get_connection_status() \
		== MultiplayerPeer.CONNECTION_CONNECTED


func _late_connected() -> bool:
	return _late_peer != null and _late_peer.get_connection_status() \
		== MultiplayerPeer.CONNECTION_CONNECTED


func _client_told_of_breaks() -> bool:
	return _cover(_owner_world).broken_keys().size() == BREAK_KEYS.size()


func _late_joiner_caught_up() -> bool:
	return _scars(_late_world).count() == 2 \
		and _cover(_late_world).broken_keys().size() == BREAK_KEYS.size()


func _scar(direction: Vector3) -> TerrainScars.Scar:
	var scar := TerrainScars.Scar.new()
	scar.direction = direction
	scar.radius = SCAR_RADIUS
	scar.depth = SCAR_DEPTH
	scar.profile = TerrainScars.Profile.BOWL
	scar.char = 0.4
	return scar


func _scars(world: GameWorld) -> TerrainScars:
	return world.planet().shape.scars


func _cover(world: GameWorld) -> TestCover:
	return world.get_node("Planet/TestCover") as TestCover


func _same_keys(got: PackedInt32Array, want: PackedInt32Array) -> bool:
	for key in want:
		if got.find(key) < 0:
			return false
	return got.size() == want.size()


func _start_peers() -> bool:
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
	if not _expect(_owner_peer.create_client("127.0.0.1", _port) == OK,
			"the client starts an ENet client"):
		return false
	_owner_api.multiplayer_peer = _owner_peer
	get_tree().set_multiplayer(_owner_api, _owner_branch.get_path())
	var connected := await _wait_until(_owner_connected, CONNECT_FRAMES)
	if not _expect(connected, "the client connects through ENet"):
		return false
	_owner_id = _owner_api.get_unique_id()
	return _expect(_owner_id > 1, "and is given a non-authority peer id")


func _start_late_joiner() -> bool:
	_late_branch = Node.new()
	_late_branch.name = "LateBranch"
	add_child(_late_branch)
	_late_api = SceneMultiplayer.new()
	_late_peer = ENetMultiplayerPeer.new()
	if not _expect(_late_peer.create_client("127.0.0.1", _port) == OK,
			"the late joiner starts an ENet client"):
		return false
	_late_api.multiplayer_peer = _late_peer
	get_tree().set_multiplayer(_late_api, _late_branch.get_path())
	var connected := await _wait_until(_late_connected, CONNECT_FRAMES)
	if not _expect(connected, "the late joiner connects after the fight"):
		return false
	_late_world = _new_world()
	_late_branch.add_child(_late_world)
	await _network_frames(4)
	return true


func _listen() -> ENetMultiplayerPeer:
	var first_port := 47100 + (OS.get_process_id() % 800)
	for offset in 12:
		var peer := ENetMultiplayerPeer.new()
		if peer.create_server(first_port + offset, 4) == OK:
			_port = first_port + offset
			return peer
	return null


func _build_worlds() -> void:
	_server_world = _new_world()
	_server_branch.add_child(_server_world)
	_owner_world = _new_world()
	_owner_branch.add_child(_owner_world)
	await _network_frames(6)

	# Identical relative node paths on every peer: the player RPCs and the flora
	# confirmations are both addressed by path.
	_add_player(_server_world, _owner_id)
	_owner_player = _add_player(_owner_world, _owner_id)
	await _network_frames(4)


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
	var planet := Planet.new()
	planet.name = "Planet"
	# Nothing is looked at here. A scar has to land in the height field and be
	# told to the other peer, and none of that wants a quadtree.
	planet.max_depth = 0
	planet.collision_range = 0.0
	planet.has_water = false
	planet.has_clouds = false
	world.add_child(planet)
	var cover := TestCover.new()
	cover.name = "TestCover"
	planet.add_child(cover)
	# Three worlds share one scene tree, and the reconciliation pass walks the
	# tree's damage-field group rather than its own children. Left running, each
	# world would drain the others' pending breaks. It is driven by hand instead.
	world.set_physics_process(false)
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
	# Undressed. Nothing here looks at the body, and the default outfit's skins
	# are the only thing in this harness that needs a full skeleton.
	player.holster()
	player.equipment.clear()
	player.hotbar.clear()
	player.abilities.clear()
	player.backpack.clear()
	world._spawned_players[peer_id] = player
	return player


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
		print("ability_net_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("ability_net_test: FAIL  %s" % message)
	return false


func _finish() -> void:
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
	print("ability_net_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
