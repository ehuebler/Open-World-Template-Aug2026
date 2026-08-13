extends Node

## Focused online-sandbox formation checks without loading the rendered planet.
##
##     godot --headless --path . dev/_sandbox_spawn_test.tscn

const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")
const PEERS: Array[int] = [1, 7, 13, 19, 25, 31, 37, 43]

var _failures := 0
var _saved_players: Dictionary
var _saved_options: Dictionary
var _saved_state: int
var _saved_single_player := false
var _saved_host := false


func _ready() -> void:
	_saved_players = NetworkManager.players.duplicate(true)
	_saved_options = NetworkManager.session_options.duplicate(true)
	_saved_state = int(NetworkManager.state)
	_saved_single_player = NetworkManager.is_single_player
	_saved_host = NetworkManager.is_host

	NetworkManager.players.clear()
	NetworkManager.session_options = {"mode": "sandbox", "max_players": 8}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.is_single_player = false
	NetworkManager.is_host = true
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

	var world := _make_world()
	add_child(world)
	await get_tree().process_frame
	_check_formation(world)

	world.queue_free()
	await get_tree().process_frame
	NetworkManager.players.clear()
	NetworkManager.players.merge(_saved_players, true)
	NetworkManager.session_options = _saved_options
	NetworkManager.state = _saved_state as NetworkManager.SessionState
	NetworkManager.is_single_player = _saved_single_player
	NetworkManager.is_host = _saved_host
	print("sandbox_spawn_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _make_world() -> GameWorld:
	var world := GameWorld.new()
	world.name = "World"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var first := Marker3D.new()
	first.name = "Spawn1"
	first.position = Vector3(0.0, 3.0, 17000.0)
	spawn_points.add_child(first)
	# Every chosen peer id maps to Spawn1 under the old peer-id modulo rule.
	var second := Marker3D.new()
	second.name = "Spawn2"
	second.position = Vector3(50.0, 3.0, 17000.0)
	spawn_points.add_child(second)
	world.add_child(spawn_points)
	var cycle := TEST_CYCLE.new() as CelestialCycle
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	var centre := Node3D.new()
	centre.name = "Planet"
	world.add_child(centre)
	world.set_physics_process(false)
	return world


func _check_formation(world: GameWorld) -> void:
	var frames: Array[Transform3D] = []
	for peer_id in PEERS:
		frames.append(world._spawn_transform(peer_id))
	_expect(frames.size() == PEERS.size(),
		"all eight online sandbox players receive a spawn transform")

	var closest := INF
	var facing := 1.0
	for index in frames.size():
		var frame := frames[index]
		var toward_planet := -frame.origin.normalized()
		facing = minf(facing, (-frame.basis.z).normalized().dot(toward_planet))
		for other in range(index + 1, frames.size()):
			closest = minf(
				closest, frame.origin.distance_to(frames[other].origin))
	_expect(closest >= GameWorld.ONLINE_SANDBOX_SPAWN_SPACING - 0.001,
		"no two players share a spawn capsule (closest %.2f m)" % closest)
	_expect(facing > 0.999999,
		"every player faces the planet centre (worst dot %.7f)" % facing)

	var across := frames[0].basis.x.normalized()
	var lanes := PackedFloat32Array()
	for frame in frames:
		lanes.append((frame.origin - frames[0].origin).dot(across))
	lanes.sort()
	var widest_gap := 0.0
	for index in range(1, lanes.size()):
		widest_gap = maxf(widest_gap, lanes[index] - lanes[index - 1])
	_expect(widest_gap <= GameWorld.ONLINE_SANDBOX_SPAWN_SPACING + 0.001,
		"formation slots remain directly beside one another")

	var repeated := world._spawn_transform(PEERS[3])
	_expect(repeated.is_equal_approx(frames[3]),
		"a peer keeps the same formation slot across repeated lookups")
	world._despawn_player(PEERS[1])
	var replacement := world._spawn_transform(99)
	_expect(replacement.is_equal_approx(frames[1]),
		"a vacated formation slot is safely reused by the next player")

	NetworkManager.is_single_player = true
	var authored := world._spawn_transform(13)
	var marker := world.get_node("SpawnPoints/Spawn1") as Marker3D
	_expect(authored.is_equal_approx(marker.global_transform),
		"single-player Sandbox retains its authored spawn behavior")
	NetworkManager.is_single_player = false


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("sandbox_spawn_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("sandbox_spawn_test: FAIL  %s" % message)
