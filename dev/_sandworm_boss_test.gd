extends Node

## One focused launch covering the generated asset, deterministic desert site,
## encounter state machine, bite hit, multi-boss HUD selection, and late-join
## snapshot routing.
##
##     godot --headless --path . dev/_sandworm_boss_test.tscn

const WORLD_SCENE := preload("res://game/world.tscn")
const SANDWORM_SCENE := preload(
	"res://game/enemies/sandworm/sandworm.tscn")
const SANDWORM_SCRIPT := preload(
	"res://game/enemies/sandworm/sandworm.gd")
const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")
const BOSS_DEFINITION_REGRESSION := preload(
	"res://dev/_boss_definition_regression.gd")

const SITE_DIRECTION := Vector3(0.939715624, -0.159266293, 0.302603334)
const MAX_HEALTH := 8500.0
const ARENA_RADIUS := 1600.0
const EMERGE_DURATION := 0.72
const LEAP_DURATION := 1.05
const DIVE_DURATION := 0.52
const BITE_PATH_AT := 0.52

var _failures := 0
var _world: GameWorld
var _planet: Planet
var _boss: CharacterBody3D
var _player: TestPlayer
var _other_boss: TestBoss


class TestPlayer extends CharacterBody3D:
	var peer_id := 1
	var hits := 0
	var damage := 0.0
	var reaction := DamageHit.Reaction.NONE
	var last_hit: DamageHit

	func combat_peer_id() -> int:
		return peer_id

	func combat_position() -> Vector3:
		return global_position + global_basis.y.normalized()

	func combat_radius() -> float:
		return 0.55

	func is_dead() -> bool:
		return false

	func apply_damage(hit: DamageHit) -> float:
		hits += 1
		damage += hit.amount
		reaction = hit.reaction
		last_hit = hit
		return hit.amount


class TestBoss extends Node3D:
	var boss_health := 100.0
	var engaged_state := false
	var distance := 500.0
	var boundary_visible := false
	var snapshots_applied := 0

	func _ready() -> void:
		add_to_group(BossAdapter.GROUP)

	func boss_id() -> String:
		return "test_boss"

	func combat_display_name() -> String:
		return "Distant Boss"

	func health() -> float:
		return boss_health

	func maximum_health() -> float:
		return 100.0

	func engaged() -> bool:
		return engaged_state

	func battle_radius() -> float:
		return 100.0

	func arena_distance_to(_body: Node3D) -> float:
		return distance

	func set_arena_boundary_visible(shown: bool) -> void:
		boundary_visible = shown

	func boss_snapshot() -> Dictionary:
		return {
			"boss_id": boss_id(),
			"health": boss_health,
			"maximum_health": 100.0,
			"engaged": engaged_state,
		}

	func apply_boss_snapshot(wire: Dictionary) -> void:
		if String(wire.get("boss_id", "")) != boss_id():
			return
		boss_health = float(wire.get("health", boss_health))
		snapshots_applied += 1


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var shape := _check_authored_world()
	if shape == null:
		_finish()
		return
	await _build_test_world(shape)
	_check_asset_and_shell()
	_check_world_space_infrastructure()
	await _check_burrow_leap_bite()
	_check_damage_and_reset()
	await _check_multi_boss_hud_and_snapshots()
	_cleanup()
	_finish()


func _check_authored_world() -> PlanetShape:
	var authored := WORLD_SCENE.instantiate()
	var planet := authored.get_node_or_null("Planet") as Planet
	var site := authored.get_node_or_null(
		"Planet/SandwormTerritory") as Landmark
	var boss := authored.get_node_or_null(
		"Planet/SandwormTerritory/Sandworm")
	_expect(planet != null and planet.shape != null,
		"authored world supplies the live PlanetShape")
	_expect(site != null and site.waypoint and site.title == "Sandworm",
		"one desert exposes an enabled Sandworm waypoint")
	_expect(site != null and site.direction.normalized().angle_to(
			SITE_DIRECTION) < 0.000001,
		"waypoint uses the deterministic surveyed desert direction")
	_expect(boss != null and boss.get_script() == SANDWORM_SCRIPT,
		"Sandworm boss is instanced beneath its desert territory")
	var director_failures := \
		BOSS_DEFINITION_REGRESSION.validate_authored_director(authored)
	var director_message := \
		"detached authored BossDirector preserves all three bosses"
	if not director_failures.is_empty():
		director_message += ": " + "; ".join(director_failures)
	_expect(director_failures.is_empty(), director_message)
	if site != null and site.has_method(&"survey_metrics"):
		var metrics := site.call(&"survey_metrics") as Dictionary
		_expect(float(metrics.get("arid_share", 0.0)) >= 0.999 \
			and float(metrics.get("dry_share", 0.0)) >= 0.999 \
			and float(metrics.get("max_slope_degrees", 90.0)) < 1.0 \
			and is_equal_approx(
				float(metrics.get("arena_radius", 0.0)), ARENA_RADIUS),
			"the surveyed desert core anchors a 1.6 km hunting territory")
	var result: PlanetShape = planet.shape if planet != null else null
	authored.free()
	return result


func _build_test_world(shape: PlanetShape) -> void:
	_world = GameWorld.new()
	_world.name = "World"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var marker := Marker3D.new()
	marker.name = "Spawn1"
	spawn_points.add_child(marker)
	_world.add_child(spawn_points)
	var cycle := TEST_CYCLE.new() as CelestialCycle
	cycle.name = "CelestialCycle"
	_world.add_child(cycle)

	_planet = Planet.new()
	_planet.name = "Planet"
	_planet.shape = shape
	_planet.max_depth = 0
	_planet.collision_range = 0.0
	_planet.has_water = false
	_planet.has_clouds = false
	_world.add_child(_planet)

	var territory := SurfaceAnchor.new()
	territory.name = "SandwormTerritory"
	territory.direction = SITE_DIRECTION
	_planet.add_child(territory)
	_boss = SANDWORM_SCENE.instantiate() as CharacterBody3D
	_boss.name = "Sandworm"
	territory.add_child(_boss)

	_world.set_physics_process(false)
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame
	_boss.set_physics_process(false)

	_player = TestPlayer.new()
	_player.name = "1"
	_world.add_child(_player, true)
	var at := _offset_direction(SITE_DIRECTION, 18.0, 0.4)
	_player.global_position = _planet.to_global(
		shape.surface_point(at, 1.5))
	_player.global_basis = _upright_basis(
		_boss.global_position - _player.global_position, at)
	_world._spawned_players[1] = _player


func _check_asset_and_shell() -> void:
	var contract_failures := BOSS_DEFINITION_REGRESSION.validate(
		"sandworm", _boss, {
			"node_name": "Sandworm",
			"display_name": "Sandworm",
			"max_health": MAX_HEALTH,
			"arena_radius": ARENA_RADIUS,
			"detection_radius": 1550.0,
			"reset_delay": 5.0,
			"arena_distance_mode": &"surface_arc",
			"location": {
				"mode": &"planet_surface",
				"direction": SITE_DIRECTION,
				"facing": 0.0,
				"clearance": 0.0,
			},
		})
	var contract_message := "shared catalog/runtime contract matches Sandworm"
	if not contract_failures.is_empty():
		contract_message += ": " + "; ".join(contract_failures)
	_expect(contract_failures.is_empty(), contract_message)

	var animator := _boss.get("_animator") as AnimationPlayer
	var skeleton := _boss.get("_skeleton") as Skeleton3D
	var definition := (_boss as BossController).definition()
	var expected_clips := definition.all_animation_clips() \
		if definition != null else PackedStringArray()
	var clips_ok := animator != null and definition != null \
		and expected_clips.size() == 8
	if animator != null:
		for clip: String in expected_clips:
			clips_ok = clips_ok and animator.has_animation(clip)
	var expected_bones := [
		"Root", "Tail", "Body01", "Body02", "Body03", "Body04",
		"Body05", "Body06", "Neck", "Head", "LowerJaw",
	]
	var bones_ok := skeleton != null and skeleton.get_bone_count() == 11
	if skeleton != null:
		for bone: String in expected_bones:
			bones_ok = bones_ok and skeleton.find_bone(bone) >= 0
	_expect(clips_ok, "runtime GLB imports all eight authored encounter clips")
	_expect(bones_ok, "runtime GLB imports the 11-bone body and jaw skeleton")
	var least_straightness := 1.0
	if animator != null and skeleton != null and clips_ok and bones_ok:
		var chain := [
			"Tail", "Body01", "Body02", "Body03", "Body04",
			"Body05", "Body06", "Neck", "Head",
		]
		for clip: String in expected_clips:
			animator.play(clip)
			animator.seek(
				animator.get_animation(clip).length * 0.5, true)
			var points: Array[Vector3] = []
			for bone: String in chain:
				points.append(skeleton.get_bone_global_pose(
					skeleton.find_bone(bone)).origin)
			var body_length := 0.0
			for index in range(1, points.size()):
				body_length += points[index - 1].distance_to(points[index])
			least_straightness = minf(
				least_straightness,
				points[0].distance_to(points[-1])
					/ maxf(body_length, 0.001))
		animator.play(&"Burrow")
		animator.seek(0.0, true)
	_expect(least_straightness >= 0.90,
		"every resting, attack, reaction, and defeat pose stays extended")
	var largest_span := 0.0
	var expanded_bounds := false
	var model := _boss.get_node_or_null(^"Model")
	if model != null:
		for node: Node in model.find_children(
				"*", "MeshInstance3D", true, false):
			var body := node as MeshInstance3D
			var size := body.get_aabb().size
			largest_span = maxf(
				largest_span, maxf(size.x, maxf(size.y, size.z)))
			expanded_bounds = expanded_bounds or body.custom_aabb.size.z >= 500.0
	_expect(largest_span >= 119.0,
		"runtime Sandworm is a skyscraper-scale 120 m creature")
	_expect(expanded_bounds,
		"the 369 m airborne body remains inside its animated culling bounds")
	_expect(_boss.get("_sand_particles") is GPUParticles3D \
			and _boss.get("_sand_ripple") is MeshInstance3D,
		"surface breakthroughs own giant eruption sand effects")
	var boundary := _boss.get("_arena_boundary") as Node
	_expect(boundary != null
		and is_equal_approx(float(boundary.call(&"arena_radius")), ARENA_RADIUS),
		"Sandworm owns a terrain-following 1.6 km arena boundary")
	_expect(int(_boss.get("_state")) == 0 \
			and float(_boss.get("_model_depth")) <= -90.0,
		"the entire giant body begins below the sand")
	_boss.call(&"_update_presentation", 0.0)
	var ripple := _boss.get("_sand_ripple") as MeshInstance3D
	var particles := _boss.get("_sand_particles") as GPUParticles3D
	_expect(ripple != null and not ripple.visible \
			and particles != null and not particles.emitting,
		"buried movement has no wake or launch-position indicator")


func _check_world_space_infrastructure() -> void:
	var definition := BossDefinition.new()
	definition.boss_id = "synthetic_space_boss"
	definition.display_name = "Synthetic Space Boss"
	definition.arena_radius = 37.5
	definition.arena_distance_mode = &"euclidean"
	var origin := Vector3(12.0, -3.0, 7.0)
	var orientation := Vector3(15.0, -30.0, 5.0)
	definition.location = {
		"mode": "world_space",
		"parent": "Space",
		"origin": [origin.x, origin.y, origin.z],
		"orientation": [
			orientation.x, orientation.y, orientation.z],
	}
	definition.waypoint = {
		"enabled": false,
		"title": "Orbital Threat",
		"tint": "#6ac7ff",
		"show_beyond": 120.0,
		"aimed_beyond": 240.0,
		"hide_beyond": 480.0,
	}

	var parent := Node3D.new()
	parent.position = Vector3(100.0, 50.0, -25.0)
	parent.rotation_degrees = Vector3(0.0, 45.0, 0.0)
	var anchor := BossWorldAnchor.new()
	parent.add_child(anchor)
	var configured := anchor.configure(definition)
	var anchor_node: Node = anchor
	_expect(configured and not (anchor_node is SurfaceAnchor) \
			and anchor.definition_id == definition.boss_id \
			and anchor.position.is_equal_approx(origin) \
			and anchor.rotation_degrees.is_equal_approx(orientation) \
			and not anchor.waypoint and anchor.title == "Orbital Threat" \
			and anchor.tint.is_equal_approx(Color("#6ac7ff")) \
			and is_equal_approx(anchor.show_beyond, 120.0) \
			and is_equal_approx(anchor.aimed_beyond, 240.0) \
			and is_equal_approx(anchor.hide_beyond, 480.0),
		"BossWorldAnchor applies local world-space transform and waypoint data")

	var distance := BossArena.distance_for_definition(
		definition,
		Vector3(1.0, 2.0, 3.0),
		Vector3(4.0, 6.0, 15.0),
		anchor)
	_expect(is_equal_approx(distance, 13.0),
		"world-space BossArena distance is Euclidean")

	var boundary := BossSpaceArenaBoundary.new()
	add_child(boundary)
	boundary.configure(Vector3(9.0, 8.0, 7.0), definition.arena_radius)
	var boundary_mesh := boundary.mesh as ArrayMesh
	var expected_vertices := BossSpaceArenaBoundary.RING_COUNT \
		* BossSpaceArenaBoundary.SEGMENTS * 6
	var built := boundary_mesh != null \
		and boundary_mesh.get_surface_count() == 1 \
		and boundary_mesh.surface_get_array_len(0) == expected_vertices \
		and boundary.ring_count() == 3 \
		and is_equal_approx(
			boundary.arena_radius(), definition.arena_radius)
	boundary.set_active(true)
	var activated := boundary.visible
	boundary.set_active(false)
	_expect(built and activated and not boundary.visible,
		"BossSpaceArenaBoundary builds three exact-radius rings and toggles")
	boundary.free()
	parent.free()


func _check_burrow_leap_bite() -> void:
	# A high, boosted player near the outer territory must aggro in the same tick.
	var flyby_direction := _offset_direction(SITE_DIRECTION, 1200.0, 0.4)
	var flyby_ground := _planet.shape.surface_point(flyby_direction, 1.5)
	_player.global_position = _planet.to_global(
		flyby_ground + flyby_direction * 900.0)
	var tangent := flyby_direction.cross(Vector3.UP)
	if tangent.length_squared() < 0.01:
		tangent = flyby_direction.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	_player.velocity = _planet.global_basis * tangent * 700.0
	_player.global_basis = _upright_basis(_player.velocity, flyby_direction)
	_boss.call(&"_update_arena_presence", 0.016)
	var launch_direction := _planet.to_local(
		_boss.global_position).normalized()
	var launch_offset := launch_direction.angle_to(flyby_direction) \
		* _planet.shape.radius
	_expect(bool(_boss.call(&"engaged")) and int(_boss.get("_state")) == 1 \
			and String(_boss.get("_clip")) == "Emerge",
		"a 700 m/s flyby 900 m above the desert triggers an immediate eruption")
	_expect(launch_offset >= 50.0,
		"the hidden launch originates from a varied angle, not directly below")
	_boss.call(&"_update_presentation", 0.0)
	var ripple := _boss.get("_sand_ripple") as MeshInstance3D
	var attack_arc := _boss.get("_attack_arc") as MeshInstance3D
	var arc_points := _boss.get("_attack_curve") as PackedVector3Array
	var arc_color := attack_arc.call(&"line_color") as Color \
		if attack_arc != null else Color.BLACK
	_expect(ripple != null and not ripple.visible,
		"the sand itself remains unmarked until the worm breaks the surface")
	_expect(attack_arc != null and attack_arc.visible \
			and int(attack_arc.call(&"point_count")) == 65 \
			and arc_color.b > arc_color.r and arc_color.r > arc_color.g,
		"a bright purple 64-segment attack arc previews the coming bite")

	var planned_bite := arc_points[
		roundi(BITE_PATH_AT * float(arc_points.size() - 1))]
	var planned_up := _planet.to_local(planned_bite).normalized()
	_player.global_basis = _upright_basis(tangent, planned_up)
	_player.global_position = planned_bite - _player.global_basis.y
	_player.velocity = Vector3.ZERO
	_boss.call(&"_tick_emerge", EMERGE_DURATION + 0.01, _player)
	_boss.call(&"_update_presentation", 0.0)
	var arc_modifier := _boss.get("_arc_modifier") as Node
	_expect(int(_boss.get("_state")) == 2
			and String(_boss.get("_clip")) == "Leap",
		"the fast emergence launches a bite at the high airborne player")
	_expect(not attack_arc.visible and arc_modifier != null \
			and bool(arc_modifier.get("active")),
		"the preview clears as its skeleton path solver takes over")
	var head_on_path := false
	var curved_chain := false
	for _step in 48:
		if int(_boss.get("_state")) != 2:
			break
		_boss.call(&"_tick_leap", LEAP_DURATION / 36.0)
		_boss.call(&"_update_presentation", 0.0)
		var progress := clampf(
			float(_boss.get("_state_time")) / LEAP_DURATION, 0.0, 1.0)
		if not curved_chain and progress >= 0.45 and progress <= 0.65:
			arc_modifier.call(&"_process_modification")
			var skeleton := _boss.get("_skeleton") as Skeleton3D
			var chain := [
				"Tail", "Body01", "Body02", "Body03", "Body04",
				"Body05", "Body06", "Neck", "Head",
			]
			var posed: Array[Vector3] = []
			for bone: String in chain:
				posed.append(skeleton.global_transform * skeleton \
					.get_bone_global_pose(skeleton.find_bone(bone)).origin)
			var expected_head := arc_points[
				roundi(progress * float(arc_points.size() - 1))]
			head_on_path = posed[-1].distance_to(expected_head) < 3.0
			var bend := 0.0
			for index in range(1, posed.size() - 1):
				bend = maxf(bend, _distance_to_segment(
					posed[index], posed[0], posed[-1]))
			curved_chain = bend >= 3.0
		await get_tree().process_frame
	_expect(head_on_path and curved_chain,
		"the extended skeleton bends along the exact runtime attack arc")
	_expect(_player.hits == 1 and absf(_player.damage - 58.0) < 0.01,
		"the moving bite volume hits a player exactly once")
	_expect(_player.reaction == DamageHit.Reaction.RAGDOLL \
			and _player.last_hit != null \
			and _player.last_hit.ability_id == "sandworm_bite",
		"the bite is attributed and ragdolls its target")
	_expect(int(_boss.get("_state")) == 3
			and String(_boss.get("_clip")) == "Dive",
		"the completed launch dives back into the sand")
	_boss.call(&"_tick_dive", DIVE_DURATION + 0.01, _player)
	_expect(int(_boss.get("_state")) == 0
			and String(_boss.get("_clip")) == "Burrow" \
			and float(_boss.get("_attack_wait")) < 1.0,
		"the fast dive re-arms another hidden bite in under one second")


func _check_damage_and_reset() -> void:
	var shot := DamageHit.impact(
		_boss.call(&"combat_position"), 1.0, 100.0)
	shot.faction = DamageHit.Faction.PLAYER
	shot.set_source(_player, _player.peer_id)
	var hidden_damage := float(_boss.call(&"apply_damage", shot))
	_boss.set("_state", 2)
	_boss.set("_model_depth", 0.0)
	var exposed_damage := float(_boss.call(&"apply_damage", shot))
	_expect(is_zero_approx(hidden_damage) and is_equal_approx(
			exposed_damage, 100.0),
		"the buried body is protected while the launched body takes damage")
	var bite := DamageHit.new()
	bite.ability_id = "sandworm_bite"
	_expect(bite.ability_display_name() == "Burrowing Bite",
		"death notices can name the Sandworm's specific attack")

	_boss.set("_health", 500.0)
	_boss.set("_engaged", true)
	_world._spawned_players.clear()
	_boss.call(&"_update_arena_presence", 4.9)
	var warned := bool(_boss.call(&"engaged")) \
		and is_equal_approx(float(_boss.call(&"health")), 500.0)
	_boss.call(&"_update_arena_presence", 0.2)
	_expect(warned and not bool(_boss.call(&"engaged")) \
			and is_equal_approx(float(_boss.call(&"health")), MAX_HEALTH) \
			and int(_boss.get("_state")) == 0,
		"leaving warns for five seconds, then resets health and burrowing")
	_world._spawned_players[1] = _player
	var at := _offset_direction(SITE_DIRECTION, 18.0, 0.4)
	_player.global_position = _planet.to_global(
		_planet.shape.surface_point(at, 1.5))
	_player.global_basis = _upright_basis(
		_boss.global_position - _player.global_position, at)


func _check_multi_boss_hud_and_snapshots() -> void:
	_other_boss = TestBoss.new()
	_other_boss.name = "DistantBoss"
	_world.add_child(_other_boss)
	await get_tree().process_frame
	_boss.set("_engaged", false)
	_other_boss.engaged_state = false
	var nearest := BossAdapter.find_in_tree(_player)
	_expect(nearest == _boss,
		"multiple-boss discovery selects the geographically nearest arena")
	_other_boss.engaged_state = true
	var warning_owner := BossAdapter.find_in_tree(_player)
	_expect(warning_owner == _other_boss,
		"an engaged boss retains the bar during its arena-exit warning")
	_other_boss.engaged_state = false
	_boss.set("_engaged", true)

	var hud := CombatHud.new()
	add_child(hud)
	hud.configure(_player, null, null, null)
	await get_tree().process_frame
	hud.call(&"_poll_boss", 0.16)
	var bar := hud.boss_bar()
	_expect(bar.visible and bar.encounter_title() == "Sandworm" \
			and is_equal_approx(bar.offset_top, BossBar.TOP),
		"the top boss bar switches its title to Sandworm")
	var boundary := _boss.get("_arena_boundary") as Node
	_expect(boundary != null and bool(boundary.get("visible")),
		"showing Sandworm's health bar also shows its arena edge")

	var rows := _world.boss_snapshots()
	var ids: Array[String] = []
	for row_variant: Variant in rows:
		var row := row_variant as Dictionary
		ids.append(String(row.get("boss_id", "")))
	_world.apply_boss_snapshots(rows)
	_expect(ids.has("sandworm") and ids.has("test_boss") \
			and _other_boss.snapshots_applied == 1,
		"late-join snapshots route independently to both named bosses")
	hud.queue_free()
	await get_tree().process_frame


func _offset_direction(centre: Vector3, distance: float, angle: float) -> Vector3:
	var east := centre.cross(
		Vector3.UP if absf(centre.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := centre.cross(east).normalized()
	var radial := east * cos(angle) + north * sin(angle)
	var arc := distance / _planet.shape.radius
	return (centre * cos(arc) + radial * sin(arc)).normalized()


func _upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.001:
		forward = up.cross(Vector3.RIGHT).normalized()
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(right, up, right.cross(up).normalized()).orthonormalized()


func _distance_to_segment(point: Vector3, from: Vector3, to: Vector3) -> float:
	var along := to - from
	if along.length_squared() < 0.001:
		return point.distance_to(from)
	var share := clampf((point - from).dot(along) / along.length_squared(),
		0.0, 1.0)
	return point.distance_to(from + along * share)


func _cleanup() -> void:
	if is_instance_valid(_world):
		_world.queue_free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("sandworm_boss_test: PASS  " + message)
		return
	_failures += 1
	push_error("sandworm_boss_test: FAIL  " + message)


func _finish() -> void:
	print("sandworm_boss_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
