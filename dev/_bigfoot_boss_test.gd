extends Node

## Headless boss combat, arena reset, attack contracts, and snapshot checks.
##
##     godot --headless --path . dev/_bigfoot_boss_test.tscn

const BOSS_SCENE := preload("res://game/enemies/bigfoot/bigfoot.tscn")
const ROCK := preload("res://game/enemies/bigfoot/bigfoot_rock.gd")
const ROAR_WAVE := preload("res://game/enemies/bigfoot/bigfoot_roar_wave.gd")
const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")

const RESET_DEBOUNCE := BigfootBoss.RESET_DEBOUNCE
## Three seconds of patrol, watched on the physics clock.
const PATROL_FRAMES := 180
const ROAR_WAVE_START := BigfootBoss.ROAR_WAVE_START
const ROAR_WAVE_END := BigfootBoss.ROAR_WAVE_END
const PUNCH_DURATION := BigfootBoss.PUNCH_DURATION
const PUNCH_STRIKE := BigfootBoss.PUNCH_STRIKE
const PUNCH_WINDOW := BigfootBoss.PUNCH_WINDOW
const GRAB_DURATION := BigfootBoss.GRAB_DURATION
const GRAB_CONNECT := BigfootBoss.GRAB_CONNECT
const GRAB_WINDOW := BigfootBoss.GRAB_WINDOW
const THROW_DURATION := BigfootBoss.THROW_DURATION
const THROW_RELEASE := BigfootBoss.THROW_RELEASE
const MAX_HEALTH := BigfootBoss.MAX_HEALTH
const METEOR_CRATER_DEPTH := BigfootBoss.METEOR_CRATER_DEPTH

var _failures := 0
var _saved_players: Dictionary
var _saved_state: int
var _saved_single_player := false
var _saved_host := false


class TestPlayer extends CharacterBody3D:
	signal status_changed(id: StringName, remaining: float)

	var peer_id := 1
	var display_name := "Tester"
	var statuses := CombatStatuses.new()
	var stats := PlayerStats.new()
	var _dead := false
	var _grabbed := false
	var _grab_socket: Node3D
	var _grab_offset := Transform3D.IDENTITY
	var _stance := OnlinePlayer.Stance.STAND
	var _parry_window_left := 0.0
	var _parry_perfect_left := 0.0
	var _parry_cooldown_left := 0.0
	var _combat_state_sequence := 0
	var _last_combat_state_sequence := 0
	var _grab_sequence := 0
	var _last_grab_sequence := 0
	var _forced_ragdoll := false
	var damage_dealt_total := 0.0

	func _ready() -> void:
		add_to_group(DamageHit.COMBATANT_GROUP)
		stats.set_base(PlayerStats.HEALTH, 100.0)
		stats.set_health(100.0)

	func combat_faction() -> int:
		return DamageHit.Faction.PLAYER

	func combat_peer_id() -> int:
		return peer_id

	func combat_position() -> Vector3:
		return global_position + Vector3.UP * 0.9

	func combat_radius() -> float:
		return 0.4

	func health() -> float:
		return stats.health()

	func maximum_health() -> float:
		return stats.base_of(PlayerStats.HEALTH)

	func is_dead() -> bool:
		return _dead

	func stance() -> int:
		return _stance

	func has_status(id: StringName) -> bool:
		return statuses.has(id)

	func is_grabbed() -> bool:
		return _grabbed

	func combat_damage_dealt(_target: Node, amount: float,
			_hit: DamageHit) -> void:
		damage_dealt_total += amount

	func parry_active() -> bool:
		return _parry_window_left > 0.0

	func parry_perfect_active() -> bool:
		return _parry_perfect_left > 0.0 and _parry_window_left > 0.0

	func request_parry() -> bool:
		_parry_window_left = 0.32
		_parry_perfect_left = 0.10
		return true

	func _tick_combat(delta: float) -> void:
		_parry_window_left = maxf(_parry_window_left - delta, 0.0)
		_parry_perfect_left = minf(
			maxf(_parry_perfect_left - delta, 0.0), _parry_window_left)
		_parry_cooldown_left = maxf(_parry_cooldown_left - delta, 0.0)
		statuses.tick(delta)

	func apply_damage(hit: DamageHit) -> float:
		if hit == null or _dead:
			return 0.0
		if hit.faction != DamageHit.Faction.ENEMY:
			return 0.0
		if hit.parryable and parry_active():
			if parry_perfect_active():
				var source := hit.source_node(self)
				if source != null and source.has_method(&"receive_reflected_damage"):
					var reflected := hit.reflection if hit.reflection > 0.0 else hit.amount
					source.call(&"receive_reflected_damage", reflected, peer_id)
			return 0.0
		var before := stats.health()
		var actual := minf(maxf(hit.amount, 0.0), before)
		if actual > 0.0:
			stats.set_health(before - actual)
		if not hit.status.is_empty() and hit.status_duration > 0.0:
			statuses.apply_status(hit.status, hit.status_duration)
		if hit.reaction == DamageHit.Reaction.RAGDOLL:
			_forced_ragdoll = true
			velocity += hit.world_impulse
		elif hit.reaction == DamageHit.Reaction.KNOCKBACK:
			velocity += hit.world_impulse
		return actual

	func grab_at_socket(socket: Node3D, offset := Transform3D.IDENTITY) -> bool:
		if _dead or socket == null:
			return false
		_grabbed = true
		_grab_socket = socket
		_grab_offset = offset
		return true

	func release_grab(throw_velocity := Vector3.ZERO) -> bool:
		if not _grabbed:
			return false
		_grabbed = false
		_grab_socket = null
		velocity = throw_velocity
		if throw_velocity.length_squared() > 0.0001:
			_forced_ragdoll = true
		return true


class TestClientBoss extends BigfootBoss:
	func _is_host() -> bool:
		return false


## Stands in for a streamed flora field: records the volumes offered to it and
## the ground it is asked to regrow, without needing a planet's worth of plants.
class TestFlora extends Node3D:
	var hits: Array[DamageHit] = []
	var restored: Array = []

	func _ready() -> void:
		add_to_group(DamageHit.FIELD_GROUP)

	func apply_damage(hit: DamageHit) -> float:
		hits.append(hit)
		return 0.0

	func restore_within(centre: Vector3, radius: float) -> int:
		restored.append({"at": centre, "radius": radius})
		return 0

	func broken_keys() -> PackedInt32Array:
		return PackedInt32Array()

	func drain_new_breaks() -> PackedInt32Array:
		return PackedInt32Array()


func _ready() -> void:
	_saved_players = NetworkManager.players.duplicate(true)
	_saved_state = int(NetworkManager.state)
	_saved_single_player = NetworkManager.is_single_player
	_saved_host = NetworkManager.is_host
	NetworkManager.players.clear()
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var world := _make_world("World")
	var planet := Planet.new()
	planet.name = "Planet"
	var shape := PlanetShape.new()
	shape.prepare()
	planet.shape = shape
	world.add_child(planet)
	var boss: CharacterBody3D = BOSS_SCENE.instantiate()
	boss.name = "Bigfoot"
	planet.add_child(boss)
	add_child(world)
	await get_tree().process_frame
	boss.global_position = planet.global_transform.origin + Vector3.UP * (
		planet.shape.radius + 30.0)
	world._spawned_players = {}
	var player := TestPlayer.new()
	player.name = "1"
	world.add_child(player, true)
	world._spawned_players[1] = player
	player.global_transform = boss.global_transform
	await get_tree().process_frame
	boss.call(&"_capture_spawn")

	_check_combatant(boss, player)
	_check_camera_rim(boss)
	_check_arena_boundary(boss)
	_check_arena_containment(boss)
	_check_rate_limits(boss)
	_check_snapshot_stale(boss)
	_check_client_sync_path(boss, planet)
	_check_aggro_and_reset(boss, player, world)
	_check_attack_selection(boss, player)
	_check_pace(boss, player)
	await _check_patrol(boss, player)
	await _check_footing(boss, planet)
	await _check_tree_avoidance(boss, planet)
	_check_retreat(boss, player)
	_check_roar(boss, player)
	_check_punch(boss, player)
	_check_melee_closes(boss, player)
	_check_meteor_scar(boss, player, planet)
	_check_grab_throw(boss, player)
	_check_rock_throw(boss, player, planet)
	_check_survivable_blows(boss, player)
	_check_juke(boss, player)
	_check_trample(boss, world)
	_check_arena_regrow(boss, player, world)
	_check_defeat(boss, player, planet)
	_check_world_boss_scope(world, boss)
	world.queue_free()
	NetworkManager.players = _saved_players
	NetworkManager.state = _saved_state as NetworkManager.SessionState
	NetworkManager.is_single_player = _saved_single_player
	NetworkManager.is_host = _saved_host
	print("bigfoot_boss_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _make_world(world_name: String) -> GameWorld:
	var world := GameWorld.new()
	world.name = world_name
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var marker := Marker3D.new()
	marker.name = "Spawn1"
	spawn_points.add_child(marker)
	world.add_child(spawn_points)
	var cycle := TEST_CYCLE.new() as CelestialCycle
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	world.set_physics_process(false)
	return world


func _check_combatant(boss: CharacterBody3D, player: TestPlayer) -> void:
	_expect(boss.call(&"combat_faction") == DamageHit.Faction.ENEMY,
		"boss is ENEMY faction")
	_expect(is_equal_approx(float(boss.call(&"maximum_health")), 10000.0),
		"boss maximum health is 10000")
	var hit := DamageHit.impact(boss.call(&"combat_position"), 1.0, 120.0)
	hit.faction = DamageHit.Faction.PLAYER
	hit.set_source(player, player.peer_id)
	var lost := float(boss.call(&"apply_damage", hit))
	_expect(is_equal_approx(lost, 120.0)
		and is_equal_approx(float(boss.call(&"health")), MAX_HEALTH - 120.0),
		"apply_damage returns actual HP lost")
	boss.call(&"receive_reflected_damage", 15.0, player.peer_id)
	_expect(is_equal_approx(float(boss.call(&"health")), MAX_HEALTH - 135.0),
		"receive_reflected_damage reduces boss health")
	_expect(is_equal_approx(player.damage_dealt_total, 15.0),
		"perfect-parry reflection reports outgoing damage feedback")
	var flashes := [0.0]
	boss.connect(&"damaged_flash", func(strength: float) -> void: flashes[0] = strength)
	boss.call(&"flash_damage", 0.5)
	_expect(flashes[0] > 0.0, "flash_damage emits damaged_flash")


func _check_camera_rim(boss: CharacterBody3D) -> void:
	var model := boss.get_node_or_null(^"Model")
	var meshes: Array[Node] = []
	if model != null:
		meshes = model.find_children("*", "MeshInstance3D", true, false)
	var all_rimmed := not meshes.is_empty()
	for node in meshes:
		var material := (node as MeshInstance3D).material_override \
			as ShaderMaterial
		if material == null:
			all_rimmed = false
			break
		var colour: Variant = material.get_shader_parameter(&"camera_rim_color")
		if not (colour is Color
			and (colour as Color).is_equal_approx(
				SurfaceSkin.CAMERA_RIM_COLOR)
			and bool(material.get_shader_parameter(&"use_vertex_color"))
			and is_equal_approx(float(material.get_shader_parameter(
				&"camera_rim_energy")), SurfaceSkin.CAMERA_RIM_ENERGY)):
			all_rimmed = false
			break
	_expect(all_rimmed,
		"Bigfoot meshes use the same neon-green camera rim as Character 3")


func _check_arena_boundary(boss: CharacterBody3D) -> void:
	_expect(is_equal_approx(float(boss.call(&"battle_radius")), 200.0)
		and BigfootBoss.DETECT_RADIUS < BigfootBoss.ARENA_RADIUS,
		"Bigfoot owns the enlarged 400 m-wide combat arena")
	var boundary := boss.get_node_or_null(^"ArenaBoundary") as MeshInstance3D
	_expect(boundary != null and boundary.mesh != null
		and boundary.mesh.get_surface_count() == 1
		and is_equal_approx(
			float(boundary.call(&"arena_radius")), BigfootBoss.ARENA_RADIUS),
		"arena boundary is built on the same radius gameplay uses")
	if boundary == null:
		return
	boss.call(&"set_arena_boundary_visible", true)
	_expect(boundary.visible,
		"the local HUD can reveal the arena boundary during a fight")
	var material := boundary.material_override as ShaderMaterial
	var line_color: Variant = material.get_shader_parameter(&"line_color") \
		if material != null else null
	_expect(line_color is Color and (line_color as Color).r > 0.9
		and (line_color as Color).g < 0.1,
		"arena boundary uses the glowing red line material")
	boss.call(&"set_arena_boundary_visible", false)
	_expect(not boundary.visible,
		"arena boundary is hidden when the boss bar is hidden")


func _check_arena_containment(boss: CharacterBody3D) -> void:
	var spawn: Transform3D = boss.get("_spawn_transform")
	var outward := spawn.basis.x.normalized()
	boss.global_position = spawn.origin \
		+ outward * (BigfootBoss.ARENA_RUN_RADIUS + 30.0)
	boss.velocity = outward * BigfootBoss.SPRINT_SPEED
	var corrected := bool(boss.call(&"_contain_inside_arena"))
	var distance := float(boss.call(
		&"_arena_distance_from_home", boss.global_position))
	var edge_outward: Vector3 = boss.call(
		&"_flat_on_surface", boss.global_position - spawn.origin)
	edge_outward = edge_outward.normalized()
	_expect(corrected
		and distance <= BigfootBoss.ARENA_RUN_RADIUS + 0.05
		and boss.velocity.dot(edge_outward) <= 0.01,
		"the hard guard keeps every movement path and its velocity inside the line")

	var inward: Vector3 = boss.call(
		&"_flat_on_surface", spawn.origin - boss.global_position)
	inward = inward.normalized()
	var steered: Vector3 = boss.call(&"_steer_inside_arena", -inward)
	_expect(steered.normalized().dot(inward) > 0.99,
		"an outward sprint at the edge is turned back through the arena")
	boss.global_transform = spawn
	boss.velocity = Vector3.ZERO
	boss.set("_ground_speed", 0.0)
	boss.set("_trample_from", Vector3.INF)


func _check_rate_limits(boss: CharacterBody3D) -> void:
	var constants: Dictionary = boss.get_script().get_script_constant_map()
	var sync_interval := float(constants.get("SYNC_INTERVAL", 0.0))
	var sweep_interval := float(constants.get("METEOR_SWEEP_STEP", 0.0))
	_expect(sync_interval >= 0.05 and sweep_interval >= 0.05,
		"boss replication and meteor field scans remain capped at 20 Hz")


func _check_snapshot_stale(boss: CharacterBody3D) -> void:
	var snap: Dictionary = boss.call(&"boss_snapshot")
	snap["health"] = 777.0
	snap["sync_sequence"] = int(boss.get("_sync_sequence")) + 1
	boss.call(&"apply_boss_snapshot", snap)
	_expect(is_equal_approx(float(boss.call(&"health")), 777.0),
		"apply_boss_snapshot updates health")
	var stale := snap.duplicate(true)
	stale["sync_sequence"] = int(boss.get("_last_sync_sequence"))
	stale["health"] = 1.0
	boss.call(&"apply_boss_snapshot", stale)
	_expect(is_equal_approx(float(boss.call(&"health")), 777.0),
		"stale sync_sequence is ignored")


func _check_client_sync_path(boss: CharacterBody3D, planet: Planet) -> void:
	var client := TestClientBoss.new()
	client.name = "ClientBigfoot"
	planet.add_child(client)
	var snap: Dictionary = boss.call(&"boss_snapshot").duplicate(true)
	snap["health"] = 654.0
	snap["sync_sequence"] = 100
	snap["meteor_landed"] = true
	client.call(&"_apply_bigfoot_sync", 100, snap)
	_expect(is_equal_approx(client.health(), 654.0)
		and bool(client.get("_meteor_landed")),
		"client RPC path applies a fresh boss snapshot")
	var stale := snap.duplicate(true)
	stale["health"] = 1.0
	stale["sync_sequence"] = 99
	client.call(&"_apply_bigfoot_sync", 99, stale)
	_expect(is_equal_approx(client.health(), 654.0),
		"client RPC path rejects an older boss snapshot")
	client.free()


func _check_aggro_and_reset(boss: CharacterBody3D, player: TestPlayer,
		world: GameWorld) -> void:
	boss.call(&"_reset_arena")
	_expect(not bool(boss.call(&"engaged")), "reset clears engagement")
	player.global_position = boss.global_position + boss.global_basis.x * (
		BigfootBoss.DETECT_RADIUS + 3.0)
	boss.call(&"_update_arena_presence", 0.1)
	_expect(not bool(boss.call(&"engaged")),
		"arena edge alone does not count as boss detection")
	player.global_position = boss.global_position + boss.global_basis.x * (
		BigfootBoss.DETECT_RADIUS - 5.0)
	boss.call(&"_update_arena_presence", 0.1)
	_expect(bool(boss.call(&"engaged")),
		"player inside the detection radius engages the boss")
	boss.call(&"_reset_arena")
	var hit := DamageHit.impact(boss.call(&"combat_position"), 1.0, 1.0)
	hit.faction = DamageHit.Faction.PLAYER
	hit.set_source(player, player.peer_id)
	boss.call(&"apply_damage", hit)
	_expect(bool(boss.call(&"engaged")), "damage immediately engages the boss")
	boss.set("_health", 500.0)
	world._spawned_players.clear()
	boss.set("_arena_empty_left", 0.0)
	boss.call(&"_update_arena_presence", RESET_DEBOUNCE - 0.1)
	_expect(bool(boss.call(&"engaged"))
		and is_equal_approx(float(boss.call(&"health")), 500.0),
		"leaving the arena warns for five seconds instead of ending the fight")
	world._spawned_players[1] = player
	player.global_transform = boss.global_transform
	boss.call(&"_update_arena_presence", 0.1)
	_expect(bool(boss.call(&"engaged"))
		and is_zero_approx(float(boss.get("_arena_empty_left"))),
		"returning during the warning cancels the arena reset")
	world._spawned_players.clear()
	boss.call(&"_update_arena_presence", RESET_DEBOUNCE + 0.1)
	_expect(not bool(boss.call(&"engaged"))
		and is_equal_approx(float(boss.call(&"health")), MAX_HEALTH),
		"staying outside for the full five seconds resets health and aggro")
	boss.set("_engaged", true)
	boss.set("_defeated", true)
	boss.set("_health", 0.0)
	boss.set("_arena_empty_left", RESET_DEBOUNCE)
	boss.call(&"_host_tick", 0.1)
	_expect(bool(boss.call(&"defeated"))
		and is_zero_approx(float(boss.call(&"health"))),
		"a defeated boss and the damage around him persist after the arena empties")
	# Explicit harness cleanup; gameplay never invokes this after a win.
	boss.call(&"_reset_arena")
	world._spawned_players[1] = player
	player.global_transform = boss.global_transform


func _check_attack_selection(boss: CharacterBody3D,
		player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	boss.global_position = spawn.origin + side * 45.0
	player.global_position = spawn.origin + side * 47.0
	player.set("_stance", OnlinePlayer.Stance.STAND)
	boss.call(&"_chase_or_attack", player, 0.016)
	_expect(StringName(boss.get("_attack")) == &"punch",
		"melee selection uses distance from Bigfoot, not distance from arena spawn")
	boss.call(&"_reset_arena")
	boss.global_position = spawn.origin + side * 45.0
	player.global_position = spawn.origin + side * 47.0
	# The grab is an explicit follow-up, not an accident of cooldown ordering.
	# A trip around the old retreat point lasted longer than punch cooldown and
	# made punch win this branch forever in play.
	boss.set("_grab_pending", true)
	boss.call(&"_chase_or_attack", player, 0.016)
	_expect(StringName(boss.get("_attack")) == &"grab",
		"a landed punch guarantees a grab on the next close exchange")
	boss.call(&"_reset_arena")
	player.global_position = spawn.origin + side * 50.0
	player.set("_stance", OnlinePlayer.Stance.FLY)
	boss.call(&"_chase_or_attack", player, 0.016)
	_expect(StringName(boss.get("_attack")) == &"roar",
		"Bigfoot prioritizes Roar against a flying target")
	boss.call(&"_reset_arena")
	player.set("_stance", OnlinePlayer.Stance.STAND)
	player.global_position = spawn.origin + side * 50.0
	# Melee spent and nobody in the air: the roar must stay holstered rather
	# than firing at a party that is already on the ground.
	boss.set("_cooldowns", {&"punch": 3.0, &"grab": 6.0, &"meteor": 20.0,
		&"rock": 5.0})
	boss.call(&"_chase_or_attack", player, 0.016)
	_expect(String(boss.get("_attack")).is_empty(),
		"Roar is never spent on a party that is entirely on the ground")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform


func _check_pace(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	var far := float(boss.call(&"_closing_speed", 90.0))
	var near := float(boss.call(&"_closing_speed", 3.0))
	_expect(is_equal_approx(far, BigfootBoss.SPRINT_SPEED) and far >= 50.0,
		"a long run through the jungle opens up to 50 m/s")
	_expect(is_equal_approx(near, BigfootBoss.CHASE_SPEED)
		and near >= 18.0 and near < BigfootBoss.SPRINT_SPEED,
		"the last few metres stay fast without carrying sprint speed into a swing")
	var middle := float(boss.call(&"_closing_speed", 30.0))
	_expect(middle > 35.0,
		"a thirty-metre close is already a sprint (%.1f m/s)" % middle)
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	boss.global_position = spawn.origin
	player.global_position = spawn.origin + side * 80.0
	boss.set("_ground_speed", 0.0)
	boss.call(&"_travel", side, BigfootBoss.SPRINT_SPEED, 0.05, 6.0)
	var first := float(boss.get("_ground_speed"))
	_expect(first >= 3.5 and first < BigfootBoss.SPRINT_SPEED * 0.2,
		"top speed is reached on a short ramp rather than from a standing start")
	for _step in 60:
		boss.call(&"_travel", side, BigfootBoss.SPRINT_SPEED, 0.05, 6.0)
	_expect(is_equal_approx(float(boss.get("_ground_speed")),
			BigfootBoss.SPRINT_SPEED),
		"a sustained sprint does reach the authored top speed")
	boss.call(&"_reset_arena")
	_expect(is_equal_approx(float(boss.get("_ground_speed")), 0.0),
		"an arena reset puts him back at a standstill")
	player.global_transform = boss.global_transform


## Nobody arrives to find him standing on his own landmark: he has somewhere to
## be from the moment he loads, and somewhere else once he gets there.
func _check_patrol(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	var spawn: Transform3D = boss.get("_spawn_transform")
	boss.call(&"_capture_spawn")
	var first: Vector3 = boss.get("_wander_goal")
	_expect(first.distance_to(spawn.origin) >= BigfootBoss.PATROL_MIN,
		"he is given ground to cross the moment he loads in")
	var goals: Array[Vector3] = [first]
	var apart := 0.0
	for _step in 5:
		var next: Vector3 = boss.call(&"_pick_wander_goal")
		apart = maxf(apart, next.distance_to(goals[goals.size() - 1]))
		goals.append(next)
	_expect(apart > BigfootBoss.PATROL_MIN,
		"each patrol goal is somewhere he has not just been")
	for goal in goals:
		if goal.distance_to(spawn.origin) > BigfootBoss.ARENA_RADIUS:
			_expect(false, "patrol goals stay inside his arena")
			break
	# Left alone for a few seconds he should have covered real ground, at a jog
	# rather than at the old amble.
	# Left alone he should cover real ground, and over real physics frames rather
	# than by driving _wander in a loop: how far a body travels is decided by
	# move_and_slide against the engine's own physics delta, which means nothing
	# outside a physics step. It also puts his own tick in the path, which is the
	# one that has to work. Ground covered rather than distance from where he
	# started, because reaching a goal and setting off for the next one can point
	# him back the way he came.
	boss.global_transform = spawn
	boss.set("_engaged", false)
	# Taken out of the world for the window rather than merely moved away. His
	# arena is measured along the ground, so a player parked overhead — however
	# far overhead — is a player standing on him, and he would spend the patrol
	# staring up at one.
	var world := player.get_parent() as GameWorld
	var roster: Dictionary = world._spawned_players.duplicate()
	world._spawned_players.clear()
	var walked := 0.0
	var was := boss.global_position
	for _step in PATROL_FRAMES:
		await get_tree().physics_frame
		walked += was.distance_to(boss.global_position)
		was = boss.global_position
	world._spawned_players = roster
	# Three seconds of patrol at his jog covers about 24 m from a standing start.
	# Anything near half that means he is idling on the spot again.
	_expect(walked > 16.0,
		"an unengaged Bigfoot is running his territory, not waiting on it")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform


## The guard that keeps him on the surface, against ground that is not exactly
## where the height field says it is.
##
## It never is. A chunk is a triangulation of the field, and a flat chord across
## a curve stands proud of it — a quarter of a metre inside the bowl of one of
## his own craters, which is the sharpest thing dug at the spacing chunks are
## built at. Setting his height from the field alone therefore buried him that
## deep in the crater wall on every tick, and the solver spent each following
## frame pushing him back out along a normal that points up and inward, against
## the way out. He would climb to the rim of his own hole at a sprint and stay
## there until the fight ended.
##
## Stood on a plate rather than in a crater because the arena here has no
## collision mesh in it at all: what broke was the guard's willingness to put him
## under solid ground, and a plate above the field is that in one line. The
## crater itself is walked out of in the runtime suite.
func _check_footing(boss: CharacterBody3D, planet: Planet) -> void:
	boss.call(&"_reset_arena")
	var out := planet.to_local(boss.global_position).normalized()
	var ground := planet.shape.radius \
		+ planet.shape.elevation(out, planet.finest_spacing())
	var ledge := 0.4
	var plate := StaticBody3D.new()
	plate.name = "Chord"
	# Whatever he collides with, so this cannot drift from his own layers.
	plate.collision_layer = boss.collision_mask
	var slab := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 2.0, 40.0)
	slab.shape = box
	# Half a box below the top face, so the top face is the ledge.
	slab.position = Vector3.DOWN
	plate.add_child(slab)
	planet.add_child(plate)
	plate.global_transform = Transform3D(boss.global_basis,
		planet.to_global(out * (ground + ledge)))
	await get_tree().physics_frame

	boss.global_position = planet.to_global(out * (ground + ledge))
	boss.velocity = Vector3.ZERO
	boss.call(&"_snap_to_ground")
	var stayed := planet.to_local(boss.global_position).length() - ground
	_expect(stayed > ledge - 0.05,
		"he stands on the ground that is there, not the ground the field"
		+ " describes (%.2f m of a %.2f m ledge)" % [stayed, ledge])

	# And with nothing under him, the field is still what holds him up: this is
	# the same call that catches him where a chunk has no collider yet.
	plate.queue_free()
	await get_tree().physics_frame
	boss.global_position = planet.to_global(out * (ground - 5.0))
	boss.velocity = Vector3.ZERO
	boss.call(&"_snap_to_ground")
	var lifted := planet.to_local(boss.global_position).length() - ground
	_expect(absf(lifted) < 0.05,
		"and is lifted out of ground he has fallen through (%.2f m off)"
		% lifted)
	boss.call(&"_reset_arena")


## A canopy trunk is the obstacle he is not allowed to solve by destroying.
## This drives his real CharacterBody around a broad one over physics frames;
## merely checking that `_blocked` increments was the old test, and it happily
## passed while he ran into the same tree for the rest of the encounter.
func _check_tree_avoidance(boss: CharacterBody3D, planet: Planet) -> void:
	boss.call(&"_reset_arena")
	boss.set_physics_process(false)
	var start := boss.global_transform
	var forward := start.basis.x.normalized()
	var up := start.basis.y.normalized()
	var trunk := StaticBody3D.new()
	trunk.name = "CanopyTrunk"
	# Explicit rather than inherited defaults: this harness creates both bodies
	# from code, while the shipped boss and tree fields declare layer one.
	trunk.collision_layer = 1
	trunk.collision_mask = 1
	var saved_mask := boss.collision_mask
	boss.collision_mask = 1
	var shape := CollisionShape3D.new()
	# A broad square trunk isolates the behaviour under test — clearing a wide
	# near-vertical face — through the same known primitive path as the footing
	# plate above. Its rounded real-world counterpart only changes the normals.
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 10.0, 6.0)
	shape.shape = box
	shape.position = Vector3.UP * 5.0
	trunk.add_child(shape)
	planet.add_child(trunk)
	trunk.global_transform = Transform3D(start.basis,
		start.origin + forward * 7.0)
	await get_tree().physics_frame

	var goal := start.origin + forward * 24.0
	var furthest := 0.0
	var widest := 0.0
	for _step in 240:
		await get_tree().physics_frame
		boss.call(&"_travel",
			boss.call(&"_flat_on_surface", goal - boss.global_position),
			BigfootBoss.SPRINT_SPEED, 1.0 / 60.0, 8.0)
		boss.call(&"_snap_to_ground")
		var moved := boss.global_position - start.origin
		furthest = maxf(furthest, moved.dot(forward))
		widest = maxf(widest, absf(moved.dot(up.cross(forward).normalized())))
		if furthest > 16.0:
			break
	_expect(furthest > 16.0 and widest > box.size.z * 0.45,
		"he steers his whole body around a canopy trunk (%.1f m on, %.1f m across)"
		% [furthest, widest])
	trunk.queue_free()
	await get_tree().physics_frame
	boss.global_transform = start
	boss.velocity = Vector3.ZERO
	boss.collision_mask = saved_mask
	boss.set_physics_process(true)
	boss.call(&"_reset_arena")


func _check_retreat(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	var up := spawn.basis.y.normalized()
	boss.global_position = spawn.origin
	player.global_position = spawn.origin + side * 2.0
	boss.set("_target_peer", player.peer_id)
	boss.set("_attack", &"punch")
	boss.call(&"_finish_attack")
	var retreat_left := float(boss.get("_retreat_left"))
	_expect(retreat_left >= BigfootBoss.RETREAT_MIN,
		"a landed punch is followed by a cooldown run")
	boss.set("_ground_speed", BigfootBoss.SPRINT_SPEED)
	boss.call(&"_run_cooldown_orbit", player,
		boss.global_position.distance_to(player.global_position), 0.01)
	var away := (boss.global_position - player.global_position).normalized()
	var heading := boss.velocity.normalized()
	_expect(absf(heading.dot(away)) < 0.8
		and absf(heading.dot(up.cross(away).normalized())) > 0.5,
		"the cooldown run crosses around the player instead of reversing away")
	# He waits in the trees while the meteor charges, then comes back out.
	boss.set("_cooldowns", {&"meteor": 5.0, &"punch": 3.0, &"grab": 6.0,
		&"rock": 5.0})
	player.global_position = spawn.origin + side * 40.0
	boss.call(&"_chase_or_attack", player, 0.05)
	_expect(String(boss.get("_attack")).is_empty()
		and float(boss.get("_retreat_left")) < retreat_left,
		"a charging meteor is waited out rather than traded through")
	# With a stone to hand the same wait is not spent jogging in silence: he
	# stops in the trees, throws, and the retreat clock keeps running.
	boss.set("_cooldowns", {&"meteor": 5.0, &"punch": 3.0, &"grab": 6.0})
	boss.call(&"_chase_or_attack", player, 0.05)
	_expect(StringName(boss.get("_attack")) == &"rock"
		and float(boss.get("_retreat_left")) > 0.0,
		"a retreat through the bushes is interrupted to throw, not abandoned")
	boss.set("_attack", &"")
	boss.set("_cooldowns", {})
	boss.call(&"_chase_or_attack", player, 0.05)
	_expect(StringName(boss.get("_attack")) == &"meteor",
		"a charged meteor breaks the retreat off immediately")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform


func _check_roar(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	player.global_transform = boss.global_transform
	player.statuses.clear()
	player.set("_forced_ragdoll", false)
	player.set("_stance", OnlinePlayer.Stance.STAND)
	boss.call(&"_update_bone_markers")
	boss.call(&"_start_attack", &"roar")
	for _step in 40:
		boss.call(&"_update_bone_markers")
		boss.call(&"_tick_roar", 0.05)
	_expect(player.has_status(CombatStatuses.FLIGHTLESS),
		"roar applies Flightless to a grounded player")
	_expect(not player.get("_forced_ragdoll"),
		"roar does not ragdoll a grounded player")
	_expect(ROAR_WAVE.DRAW_LIMIT >= BigfootBoss.ROAR_WAVE_RADIUS,
		"the visible roar shell lasts for the whole authoritative wave")

	# A distant player is untouched while the shell is still in front of them,
	# then hit on the tick its visible radius crosses their body. This guards
	# against turning the ring back into an unrelated warning animation.
	player.statuses.clear()
	boss.set("_roar_wave_peers", {})
	player.global_position = boss.global_position + boss.global_basis.x * 60.0
	boss.call(&"_update_bone_markers")
	boss.set("_roar_elapsed", ROAR_WAVE_START)
	boss.set("_roar_radius", 0.0)
	var mouth := boss.get_node(^"Mouth") as Marker3D
	var front_gap := player.combat_position().distance_to(mouth.global_position) \
		- player.combat_radius()
	var before_crossing := maxf(
		(front_gap - 1.0) / BigfootBoss.ROAR_WAVE_SPEED, 0.0)
	boss.call(&"_tick_roar", before_crossing)
	_expect(not player.has_status(CombatStatuses.FLIGHTLESS),
		"a distant player can still move before the roar front arrives")
	boss.call(&"_tick_roar", 2.0 / BigfootBoss.ROAR_WAVE_SPEED)
	_expect(player.has_status(CombatStatuses.FLIGHTLESS),
		"the roar lands when its expanding shell reaches the player")

	player.global_transform = boss.global_transform
	player.statuses.clear()
	boss.set("_roar_wave_peers", {})
	boss.set("_roar_elapsed", ROAR_WAVE_START)
	boss.set("_roar_radius", 0.0)
	player.request_parry()
	boss.call(&"_update_bone_markers")
	boss.call(&"_tick_roar", 0.05)
	_expect(not player.has_status(CombatStatuses.FLIGHTLESS),
		"active parry blocks roar status")
	player.set("_parry_window_left", 0.0)
	player.set("_parry_perfect_left", 0.0)
	player.statuses.clear()
	player.set("_forced_ragdoll", false)
	player.set("_stance", OnlinePlayer.Stance.FLY)
	player.global_position = boss.global_position + boss.global_basis.y * 150.0
	boss.set("_roar_wave_peers", {})
	boss.set("_roar_elapsed", ROAR_WAVE_START)
	boss.set("_roar_radius", 0.0)
	for _step in 24:
		boss.call(&"_tick_roar", (ROAR_WAVE_END - ROAR_WAVE_START) / 24.0)
	_expect(player.has_status(CombatStatuses.FLIGHTLESS)
		and bool(player.get("_forced_ragdoll")),
		"true spherical roar front reaches and ragdolls a high flying player")
	player.set("_stance", OnlinePlayer.Stance.STAND)
	player.global_transform = boss.global_transform


func _check_punch(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	player.global_transform = boss.global_transform
	player.set("_parry_window_left", 0.0)
	player.set("_parry_perfect_left", 0.0)
	var before := player.health()
	boss.set("_target_peer", player.peer_id)
	player.global_position = boss.global_position + boss.global_basis.x * 10.0
	boss.call(&"_update_bone_markers")
	boss.call(&"_start_attack", &"punch")
	boss.set("_attack_left", PUNCH_DURATION - PUNCH_STRIKE)
	boss.call(&"_tick_punch", 0.0, player)
	_expect(is_equal_approx(player.health(), before),
		"run punch misses a player outside the animated fist volume")

	# The range he actually fights at, rather than standing inside the target.
	player.global_position = boss.global_position \
		+ boss.global_basis.x * 2.4
	player.velocity = Vector3.ZERO
	player.set("_forced_ragdoll", false)
	boss.call(&"_update_bone_markers")
	boss.call(&"_start_attack", &"punch")
	boss.set("_attack_left", PUNCH_DURATION - PUNCH_STRIKE)
	boss.call(&"_tick_punch", 0.0, player)
	_expect(player.health() < before, "run punch reaches a player at arm's length")
	_expect(player.velocity.length() > 5.0
		and player.velocity.length() < OnlinePlayer.CRASH_SPEED
		and not bool(player.get("_forced_ragdoll")),
		"the punch knocks the player back without putting them down")

	# A swing that opens on somebody who then steps out of it stays live for its
	# window and no longer, and does not count as a hit worth retreating from.
	player.global_transform = boss.global_transform
	player.stats.set_health(player.maximum_health())
	before = player.health()
	boss.call(&"_start_attack", &"punch")
	boss.set("_attack_left", PUNCH_DURATION - PUNCH_STRIKE - PUNCH_WINDOW - 0.02)
	player.global_position = boss.global_position + boss.global_basis.x * 12.0
	boss.call(&"_tick_punch", 0.0, player)
	_expect(is_equal_approx(player.health(), before)
		and bool(boss.get("_melee_whiffed")),
		"a swing that connects with nothing closes without landing late")
	player.global_transform = boss.global_transform


## The whole approach rather than the single frame the blow lands on. He opens
## each attack at the range he really starts it from and has to cover the gap
## himself, which is the path that was missing in play while the staged checks
## above went on passing.
func _check_melee_closes(boss: CharacterBody3D, player: TestPlayer) -> void:
	for attack: StringName in [&"punch", &"grab"]:
		boss.call(&"_reset_arena")
		boss.call(&"_begin_aggro")
		player.global_transform = boss.global_transform
		player.stats.set_health(player.maximum_health())
		player.velocity = Vector3.ZERO
		player.set("_forced_ragdoll", false)
		player.set("_parry_window_left", 0.0)
		player.set("_parry_perfect_left", 0.0)
		var start := BigfootBoss.PUNCH_START_RANGE if attack == &"punch" \
			else BigfootBoss.GRAB_START_RANGE
		player.global_position = boss.global_position \
			+ boss.global_basis.x * start
		var before := player.health()
		boss.set("_target_peer", player.peer_id)
		boss.call(&"_start_attack", attack)
		var landed := false
		for _step in 90:
			var delta := 1.0 / 60.0
			boss.call(&"_update_bone_markers")
			if attack == &"punch":
				boss.call(&"_tick_punch", delta, player)
			else:
				boss.call(&"_tick_grab_throw", delta, player)
			boss.set("_attack_left", float(boss.get("_attack_left")) - delta)
			if player.health() < before:
				landed = true
				break
		_expect(landed,
			"a %s opened at its own start range closes the gap and lands"
				% attack)
		if attack == &"grab":
			_expect(player.is_grabbed(),
				"closing on somebody with a grab actually takes hold of them")
		if player.is_grabbed():
			player.release_grab()
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform
	player.stats.set_health(player.maximum_health())


func _check_meteor_scar(boss: CharacterBody3D, player: TestPlayer,
		planet: Planet) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	var flora := TestFlora.new()
	flora.name = "CraterFlora"
	boss.get_parent().add_child(flora)
	var before := planet.shape.scars.count()
	var constants: Dictionary = boss.get_script().get_script_constant_map()
	_expect(float(constants.get("METEOR_FLY_MAX", 99.0)) < 0.5,
		"meteor charge commits within its authored 50 m reach")
	boss.set("_target_peer", player.peer_id)
	boss.set("_meteor_along", -boss.global_basis.z)
	boss.set("_meteor_landed", false)
	boss.call(&"_update_bone_markers")
	var fist: Marker3D = boss.get_node(^"RightFist")
	# An odd final flora sample used to be discarded when the fist landed,
	# leaving the tail of the corridor untouched.
	boss.set("_meteor_flora_from",
		fist.global_position + boss.global_basis.z * 7.0)
	boss.call(&"_land_meteor", player)
	_expect(planet.shape.scars.count() == before + 1,
		"meteor landing requests a terrain scar")
	var corridor := false
	for offered: DamageHit in flora.hits:
		if offered.kind == DamageHit.Kind.BEAM \
				and offered.amount >= BigfootBoss.METEOR_FLATTEN_DAMAGE:
			corridor = not offered.plant_break_effects
			break
	_expect(corridor,
		"the final meteor-trench segment uproots its flora without per-blade bursts")
	var direction := planet.to_local(fist.global_position).normalized()
	var depth := planet.shape.scars.depth_at(direction, 1.0)
	_expect(depth >= METEOR_CRATER_DEPTH * 0.5,
		"meteor scar depth is written into the height field")
	_check_crater_cleared(flora, fist.global_position)
	flora.queue_free()


## Whatever was growing on the ground he just dug away has to leave with it.
## Anything that survives the landing keeps the origin it was sown at and ends up
## standing on nothing, several metres above the floor of a fresh crater — the one
## thing in this fight that cannot be explained away as a rough edge.
func _check_crater_cleared(flora: TestFlora, at: Vector3) -> void:
	if flora.hits.is_empty():
		_expect(false, "the landing offers the ground it broke to the flora")
		return
	var blast: DamageHit = flora.hits.back()
	_expect(blast.origin.distance_to(at) < 0.01
		and blast.radius >= BigfootBoss.METEOR_CRATER_RADIUS,
		"the blast reaches at least as far as the hole it digs (%.1f m of %.1f m)"
		% [blast.radius, BigfootBoss.METEOR_CRATER_RADIUS])
	_expect(is_zero_approx(blast.falloff),
		"and does not taper away, which would ring the crater with survivors")
	# Measured against the toughest thing that could plausibly be rooted in the
	# few metres he took out, rather than against the grass that made this
	# visible: cover is either uprooted here or it floats.
	var stubborn := PlantSpecies.new()
	stubborn.toughness = PlantSpecies.Toughness.STONE
	var needed := stubborn.health_for(4.0) / stubborn.damage_taken(1.0)
	_expect(blast.amount >= needed,
		"and uproots what it reaches rather than scorching it (%.0f of %.0f)"
		% [blast.amount, needed])
	_expect(blast.amount > BigfootBoss.METEOR_IMPACT_DAMAGE,
		"what a landing does to the jungle is not what it does to a player")


func _check_grab_throw(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	# Standing off at the distance a grab is really thrown from. The old check
	# put the player inside the boss, where a one-frame sphere around the fist
	# could not miss, which is exactly why the miss went unnoticed.
	player.global_transform = boss.global_transform
	player.global_position = boss.global_position + boss.global_basis.x * 2.2
	player.stats.set_health(player.maximum_health())
	player.velocity = Vector3.ZERO
	player.set("_parry_window_left", 0.0)
	player.set("_parry_perfect_left", 0.0)
	boss.set("_target_peer", player.peer_id)
	boss.call(&"_update_bone_markers")
	boss.call(&"_start_attack", &"grab")
	boss.set("_attack_left", GRAB_DURATION + THROW_DURATION - GRAB_CONNECT)
	boss.call(&"_tick_grab_throw", 0.0, player)
	_expect(player.is_grabbed(), "grab attack attaches to the grab socket")
	if player.is_grabbed():
		var socket: Node3D = boss.get_node(^"GrabSocket")
		player.global_transform = socket.global_transform \
			* (player.get("_grab_offset") as Transform3D)
		_expect(player.combat_position().distance_to(socket.global_position) < 0.05,
			"and visibly holds the player's torso in the animated hand")
	boss.set("_attack_left", THROW_DURATION - THROW_RELEASE)
	boss.call(&"_tick_grab_throw", 0.0, player)
	_expect(not player.is_grabbed(), "throw releases the grabbed player")
	_expect(player.velocity.length() > 20.0 and player.velocity.length() < 30.0,
		"throw applies its authored impulse exactly once")

	# Grabbing at somebody who has already gone: he breaks off rather than
	# playing out two seconds of carrying and throwing thin air, and pays a
	# shorter price for it than a grab that landed.
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	boss.set("_target_peer", player.peer_id)
	player.global_transform = boss.global_transform
	player.stats.set_health(player.maximum_health())
	player.velocity = Vector3.ZERO
	boss.call(&"_update_bone_markers")
	boss.call(&"_start_attack", &"grab")
	boss.set("_attack_left",
		GRAB_DURATION + THROW_DURATION - GRAB_CONNECT - GRAB_WINDOW - 0.02)
	player.global_position = boss.global_position + boss.global_basis.x * 14.0
	boss.call(&"_tick_grab_throw", 0.0, player)
	_expect(not player.is_grabbed()
		and is_equal_approx(float(boss.get("_attack_left")), 0.0),
		"a grab that closes on nobody ends there instead of miming a throw")
	boss.call(&"_finish_attack")
	_expect(is_equal_approx(float(boss.get("_cooldowns").get(&"grab", 0.0)),
			BigfootBoss.GRAB_WHIFF_COOLDOWN)
		and is_zero_approx(float(boss.get("_retreat_left"))),
		"a missed grab costs a moment, not the full cycle and a retreat")
	player.global_transform = boss.global_transform


## The stone he throws at range: that he reaches for one at all, that it is
## thrown where the target is rather than where he happens to be facing, and
## that being hit by it puts you on the ground.
func _check_rock_throw(boss: CharacterBody3D, player: TestPlayer,
		planet: Planet) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	boss.global_position = spawn.origin
	player.global_transform = boss.global_transform
	player.global_position = spawn.origin + side * 40.0
	player.velocity = Vector3.ZERO
	player.stats.set_health(player.maximum_health())
	player.set("_forced_ragdoll", false)
	player.set("_parry_window_left", 0.0)
	player.set("_parry_perfect_left", 0.0)
	boss.set("_target_peer", player.peer_id)
	boss.set("_cooldowns", {&"meteor": 12.0})
	boss.call(&"_chase_or_attack", player, 0.05)
	_expect(StringName(boss.get("_attack")) == &"rock",
		"a target too far to hit and too near to charge is thrown at")
	_expect(not bool(boss.call(&"_rock_ready", 5.0, player)),
		"he does not throw rocks at somebody standing in front of him")

	var before_rocks := _rocks_under(planet).size()
	for _step in 40:
		boss.call(&"_update_bone_markers")
		boss.call(&"_tick_rock", 1.0 / 60.0, player)
		boss.set("_attack_left", float(boss.get("_attack_left")) - 1.0 / 60.0)
		if _rocks_under(planet).size() > before_rocks:
			break
	var rocks := _rocks_under(planet)
	_expect(rocks.size() == before_rocks + 1,
		"the throw puts exactly one rock in the air")
	if rocks.is_empty():
		return
	var rock := rocks[rocks.size() - 1] as Node3D
	var launch: Vector3 = rock.get("_velocity")
	var closest := _closest_pass(rock.global_position, launch,
		planet.up_at(rock.global_position), player.combat_position())
	_expect(closest <= ROCK.HIT_RADIUS,
		"the thrown arc is lofted onto the target rather than fired flat")
	var flying := player.combat_position() + planet.up_at(
		player.global_position) * 40.0
	boss.set("_cooldowns", {})
	_expect(bool(boss.call(&"_rock_ready",
			boss.global_position.distance_to(flying), player)),
		"the same throw is offered against a player up in the air")

	var health_before := player.health()
	rock.global_position = player.combat_position()
	rock.call(&"_strike", player)
	_expect(is_equal_approx(health_before - player.health(),
			BigfootBoss.ROCK_DAMAGE),
		"a rock that lands on a player deals its authored damage")
	_expect(bool(player.get("_forced_ragdoll"))
		and player.velocity.length() > 10.0,
		"a rock that lands on a player puts them down")

	boss.set("_attack", &"rock")
	boss.call(&"_finish_attack")
	_expect(is_equal_approx(float(boss.get("_cooldowns").get(&"rock", 0.0)),
			BigfootBoss.ROCK_COOLDOWN),
		"the throw goes on its own cooldown")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform
	player.stats.set_health(player.maximum_health())
	player.velocity = Vector3.ZERO
	player.set("_forced_ragdoll", false)


## Running at somebody who is shooting back. A straight line is what a held beam
## wants; he should stop giving them one, and only while he is being hit.
## What each attack costs a player who is standing in the worst place for it,
## measured by running the attack rather than by reading its constant. Nothing
## he has may empty a full bar on its own, and the meteor has to be worth more
## than the things he does while waiting for it — a shove that kills as fast as
## the wind-up he commits to makes the wind-up pointless.
func _check_survivable_blows(boss: CharacterBody3D, player: TestPlayer) -> void:
	var full := player.maximum_health()
	var punched := _blow_cost(boss, player, func() -> void:
		player.global_position = boss.global_position \
			+ boss.global_basis.x * 2.4
		boss.call(&"_update_bone_markers")
		boss.call(&"_start_attack", &"punch")
		boss.set("_attack_left", PUNCH_DURATION - PUNCH_STRIKE)
		boss.call(&"_tick_punch", 0.0, player))

	# Grab and throw are one attack from the receiving end: he does not take
	# hold of somebody and put them down again.
	var thrown := _blow_cost(boss, player, func() -> void:
		player.global_position = boss.global_position \
			+ boss.global_basis.x * 2.2
		boss.call(&"_update_bone_markers")
		boss.call(&"_start_attack", &"grab")
		boss.set("_attack_left", GRAB_DURATION + THROW_DURATION - GRAB_CONNECT)
		boss.call(&"_tick_grab_throw", 0.0, player)
		boss.set("_attack_left", THROW_DURATION - THROW_RELEASE)
		boss.call(&"_tick_grab_throw", 0.0, player))
	if player.is_grabbed():
		player.release_grab()

	# Swept up by the charge and then stood on by the landing, which is the
	# whole meteor and the most one attack of his can take.
	var struck := _blow_cost(boss, player, func() -> void:
		boss.set("_meteor_along", boss.global_basis.x)
		boss.set("_meteor_landed", false)
		boss.call(&"_update_bone_markers")
		var fist: Marker3D = boss.get_node(^"RightFist")
		player.global_position = fist.global_position
		boss.set("_meteor_fist",
			fist.global_position - boss.global_basis.x * 4.0)
		boss.call(&"_sweep_meteor_fist")
		boss.call(&"_land_meteor", player))

	_expect(struck > 0.0 and struck < full,
		"his meteor takes most of a full bar (%.0f of %.0f) and not all of it"
			% [struck, full])
	_expect(punched > 0.0 and punched < struck,
		"a punch costs less than the meteor (%.0f against %.0f)"
			% [punched, struck])
	_expect(thrown > 0.0 and thrown < struck,
		"and so does being grabbed and thrown (%.0f against %.0f)"
			% [thrown, struck])
	_expect(BigfootBoss.ROCK_DAMAGE < BigfootBoss.METEOR_IMPACT_DAMAGE,
		"a thrown stone is worth less than the fist he throws himself with")
	# Two of anything still kills, which is what keeps the fight a fight.
	_expect(struck * 2.0 > full, "two meteors are still fatal")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform
	player.stats.set_health(full)


## Runs one attack against a player restored to full health and reports what it
## took off them.
func _blow_cost(boss: CharacterBody3D, player: TestPlayer,
		attack: Callable) -> float:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	boss.set("_target_peer", player.peer_id)
	player.global_transform = boss.global_transform
	player.stats.set_health(player.maximum_health())
	player.velocity = Vector3.ZERO
	player.set("_forced_ragdoll", false)
	player.set("_parry_window_left", 0.0)
	player.set("_parry_perfect_left", 0.0)
	attack.call()
	return player.maximum_health() - player.health()


func _check_juke(boss: CharacterBody3D, player: TestPlayer) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	boss.global_position = spawn.origin
	player.global_position = spawn.origin + side * 40.0
	boss.set("_target_peer", player.peer_id)
	var straight: Vector3 = boss.call(&"_chase_heading", player, 40.0,
		1.0 / 60.0)
	_expect(straight.normalized().dot(side) > 0.99,
		"an unopposed charge is run straight at the target")
	var arc: Vector3 = boss.call(&"_chase_heading", player, 25.0,
		1.0 / 60.0)
	_expect(rad_to_deg(arc.normalized().angle_to(side)) > 20.0
		and arc.normalized().dot(side) > 0.7,
		"the middle of an approach strafes across the target while still closing")

	var beam := DamageHit.beam(player.combat_position(),
		boss.call(&"combat_position"), 0.4, 30.0)
	beam.faction = DamageHit.Faction.PLAYER
	beam.set_source(player, player.peer_id)
	boss.call(&"apply_damage", beam)
	_expect(float(boss.get("_under_fire")) >= BigfootBoss.UNDER_FIRE_BEAM,
		"a beam held on him keeps him aware he is being shot")
	var first: Vector3 = boss.call(&"_chase_heading", player, 40.0, 1.0 / 60.0)
	_expect(rad_to_deg(first.normalized().angle_to(side)) > 30.0,
		"a charge under fire is cut off the straight line")
	_expect(first.normalized().dot(side) > 0.3,
		"cutting across is still closing rather than orbiting")
	var flipped := false
	for _step in 60:
		var heading: Vector3 = boss.call(&"_chase_heading", player, 40.0,
			1.0 / 60.0)
		if heading.normalized().cross(side).dot(
				first.normalized().cross(side)) < 0.0:
			flipped = true
			break
	_expect(flipped, "the weave changes sides rather than curving away")
	var contact: Vector3 = boss.call(&"_chase_heading", player,
		BigfootBoss.CONTACT_AT - 1.0, 1.0 / 60.0)
	_expect(contact.normalized().dot(side) > 0.99,
		"the last few metres are closed straight so the swing can land")
	boss.set("_under_fire", 0.0)
	var calmed: Vector3 = boss.call(&"_chase_heading", player, 40.0, 1.0 / 60.0)
	_expect(calmed.normalized().dot(side) > 0.99,
		"he stops weaving once nothing is hitting him")
	boss.call(&"_reset_arena")
	player.global_transform = boss.global_transform


## What he does to the undergrowth simply by being in it, and what he leaves
## standing while he does.
func _check_trample(boss: CharacterBody3D, world: GameWorld) -> void:
	var flora := TestFlora.new()
	flora.name = "TrampleFlora"
	world.add_child(flora)
	boss.call(&"_reset_arena")
	var spawn: Transform3D = boss.get("_spawn_transform")
	var side := spawn.basis.x.normalized()
	boss.global_position = spawn.origin
	boss.set("_trample_from", Vector3.INF)
	boss.set("_trample_left", 0.0)
	boss.call(&"_trample", 1.0)
	_expect(flora.hits.is_empty(),
		"the first mark is only a mark; standing still cuts nothing")
	boss.global_position = spawn.origin + side * (BigfootBoss.TRAMPLE_STRIDE
		+ 1.0)
	boss.call(&"_trample", 1.0)
	_expect(flora.hits.size() == 1,
		"crossing ground offers that stretch of it to the flora fields")
	if flora.hits.is_empty():
		flora.free()
		return
	var cut: DamageHit = flora.hits[0]
	_expect(is_equal_approx(cut.max_plant_height, BigfootBoss.TRAMPLE_TALLEST)
		and cut.max_plant_height > 2.0 and cut.max_plant_height < 6.0,
		"he flattens undergrowth and leaves the canopy he lives under")
	_expect(cut.min_plant_height > 0.0
		and cut.min_plant_height < cut.max_plant_height,
		"and walks over the grass rather than through every blade of it")
	_expect(cut.origin.distance_to(cut.toward) > BigfootBoss.TRAMPLE_STRIDE
		and is_equal_approx(cut.radius, BigfootBoss.TRAMPLE_RADIUS),
		"the cut follows the whole stretch he covered, at his own width")
	_expect(cut.amount >= 900.0,
		"anything short enough goes down in one pass rather than charring")
	flora.hits.clear()
	boss.global_position += side * 0.1
	boss.call(&"_trample", 1.0)
	_expect(flora.hits.is_empty(),
		"shuffling on the spot does not re-cut ground already cut")
	boss.global_position += side * (BigfootBoss.TRAMPLE_MAX_SPAN + 5.0)
	boss.call(&"_trample", 1.0)
	_expect(flora.hits.is_empty(),
		"and a meteor flight is not a corridor he walked")
	boss.global_position += side * (BigfootBoss.TRAMPLE_STRIDE + 0.5)
	boss.call(&"_trample", 1.0)
	_expect(flora.hits.size() == 1, "though the next stride after one is")

	# Meeting something he will not break has to turn into going around it.
	boss.set("_ground_speed", 20.0)
	boss.set("_blocked", 0.0)
	var standing := boss.global_position
	for _step in 20:
		boss.call(&"_note_progress", standing, 1.0 / 60.0)
	_expect(float(boss.get("_blocked")) >= BigfootBoss.BLOCKED_AFTER,
		"grinding against a trunk is noticed rather than pushed through")
	boss.call(&"_note_progress", standing - side * 1.0, 1.0 / 60.0)
	_expect(float(boss.get("_blocked")) < BigfootBoss.BLOCKED_AFTER * 2.0,
		"and forgotten again as soon as he is travelling")
	boss.set("_blocked", 0.0)
	boss.set("_ground_speed", 0.0)
	flora.free()


## Leaving or dying winds the arena back, including the ground it was fought
## over. Killing him does not: the wreckage is the point.
func _check_arena_regrow(boss: CharacterBody3D, player: TestPlayer,
		world: GameWorld) -> void:
	var flora := TestFlora.new()
	flora.name = "RegrowFlora"
	world.add_child(flora)
	boss.call(&"_reset_arena")
	_expect(flora.restored.size() == 1,
		"an arena reset regrows the jungle it was fought in")
	if not flora.restored.is_empty():
		var asked: Dictionary = flora.restored[0]
		var spawn: Transform3D = boss.get("_spawn_transform")
		_expect((asked["at"] as Vector3).distance_to(spawn.origin) < 0.01
			and is_equal_approx(float(asked["radius"]),
				BigfootBoss.ARENA_RADIUS),
			"and regrows his arena rather than the whole planet")
	flora.restored.clear()
	boss.call(&"_begin_aggro")
	var kill := DamageHit.impact(boss.call(&"combat_position"), 2.0, MAX_HEALTH)
	kill.faction = DamageHit.Faction.PLAYER
	kill.set_source(player, player.peer_id)
	boss.call(&"apply_damage", kill)
	_expect(bool(boss.call(&"defeated")) and flora.restored.is_empty(),
		"killing him leaves the ground as the fight left it")
	var roster := world._spawned_players.duplicate()
	world._spawned_players.clear()
	boss.set("_arena_empty_left", RESET_DEBOUNCE)
	boss.call(&"_host_tick", RESET_DEBOUNCE + 0.1)
	_expect(bool(boss.call(&"defeated")) and flora.restored.is_empty(),
		"leaving after the kill does not regrow a won encounter")
	world._spawned_players = roster
	boss.call(&"_reset_arena")
	flora.free()
	player.global_transform = boss.global_transform


func _rocks_under(planet: Planet) -> Array:
	var found: Array = []
	for child in planet.get_children():
		if child.get_script() == ROCK:
			found.append(child)
	return found


## Nearest the thrown arc comes to a point, walked in small steps. The launch
## solution is only worth anything if the stone actually arrives.
func _closest_pass(from: Vector3, launch: Vector3, up: Vector3,
		at: Vector3) -> float:
	var gravity := float(ProjectSettings.get_setting(
		"physics/3d/default_gravity", 24.0))
	var step := 1.0 / 60.0
	var point := from
	var moving := launch
	var closest := INF
	for _tick in 240:
		moving -= up * gravity * step
		point += moving * step
		closest = minf(closest, point.distance_to(at))
	return closest


func _check_defeat(boss: CharacterBody3D, player: TestPlayer,
		planet: Planet) -> void:
	boss.call(&"_reset_arena")
	boss.call(&"_begin_aggro")
	var kill := DamageHit.impact(boss.call(&"combat_position"), 2.0, MAX_HEALTH)
	kill.faction = DamageHit.Faction.PLAYER
	kill.set_source(player, player.peer_id)
	boss.call(&"apply_damage", kill)
	_expect(bool(boss.call(&"defeated"))
		and String(boss.get("_clip")) == "Defeat",
		"the killing blow starts the collapse")
	var up := planet.up_at(boss.global_position)
	boss.call(&"_settle_defeat", 0.05)
	_expect(boss.global_basis.y.normalized().dot(up) > 0.9,
		"the collapse clip plays out before the body goes over")
	for _step in 60:
		boss.call(&"_settle_defeat", 0.05)
	_expect(absf(boss.global_basis.y.normalized().dot(up)) < 0.2,
		"the carcass ends up lying on the ground, not stuck upright")
	var settled: Vector3 = boss.global_position
	for _step in 20:
		boss.call(&"_settle_defeat", 0.05)
	_expect(settled.distance_to(boss.global_position) < 0.01,
		"a fallen Bigfoot comes to rest instead of drifting")
	boss.call(&"_reset_arena")
	var spawn: Transform3D = boss.get("_spawn_transform")
	_expect(not bool(boss.call(&"defeated"))
		and boss.global_basis.y.normalized().dot(
			spawn.basis.y.normalized()) > 0.999,
		"an arena reset stands him back up")
	player.global_transform = boss.global_transform


func _check_world_boss_scope(world: GameWorld, boss: CharacterBody3D) -> void:
	var other_world := _make_world("OtherWorld")
	var other_planet := Planet.new()
	other_planet.name = "Planet"
	var other_shape := PlanetShape.new()
	other_shape.prepare()
	other_planet.shape = other_shape
	other_world.add_child(other_planet)
	var other_boss: CharacterBody3D = BOSS_SCENE.instantiate()
	other_boss.name = "Bigfoot"
	other_planet.add_child(other_boss)
	add_child(other_world)
	other_boss.set("_health", 321.0)
	boss.set("_health", 876.0)
	var own_snapshot := world.bigfoot_snapshot()
	var other_snapshot := other_world.bigfoot_snapshot()
	_expect(is_equal_approx(float(own_snapshot.get("health", 0.0)), 876.0)
		and is_equal_approx(float(other_snapshot.get("health", 0.0)), 321.0),
		"world snapshots select their own Bigfoot in multi-world network trees")
	other_world.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("bigfoot_boss_test: PASS  %s" % message)
		return
	_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	push_error("bigfoot_boss_test: FAIL  %s" % message)
