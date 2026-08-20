extends Node

## One focused launch covering the generated dragon asset, grounded caldera
## ritual, hazards, aerial attacks, fauna contact, named boss HUD, and world
## snapshot contract.
##
##     godot --headless --path . dev/_volcanoronomous_boss_test.tscn

const WORLD_SCENE := preload("res://game/world.tscn")
const BOSS_SCENE := preload(
	"res://game/enemies/volcanoronomous/volcanoronomous.tscn")
const BOSS_SCRIPT := preload(
	"res://game/enemies/volcanoronomous/volcanoronomous.gd")
const TEST_CYCLE := preload("res://dev/_multiplayer_test_cycle.gd")
const BOSS_DEFINITION_REGRESSION := preload(
	"res://dev/_boss_definition_regression.gd")

const SITE_DIRECTION := Vector3.DOWN
const MAX_HEALTH := 50_000.0
const ARENA_RADIUS := 900.0
const TRIAL_DURATION := 24.0

var _failures := 0
var _world: GameWorld
var _planet: Planet
var _boss: CharacterBody3D
var _player: TestPlayer


class TestPlayer extends CharacterBody3D:
	var peer_id := 1
	var stance_state := 0
	var dead := false
	var hits := 0
	var damage := 0.0
	var last_hit: DamageHit
	var shakes := 0

	func combat_peer_id() -> int:
		return peer_id

	func combat_position() -> Vector3:
		return global_position + global_basis.y.normalized()

	func combat_radius() -> float:
		return 0.55

	func stance() -> int:
		return stance_state

	func is_dead() -> bool:
		return dead

	func apply_damage(hit: DamageHit) -> float:
		hits += 1
		damage += hit.amount
		last_hit = hit
		return hit.amount

	func camera_shake(_strength: float, _duration: float) -> void:
		shakes += 1

	func clear_hits() -> void:
		hits = 0
		damage = 0.0
		last_hit = null


class TestFauna extends Node3D:
	var destroyed := false

	func _ready() -> void:
		add_to_group(&"fauna_mobs")

	func combat_position() -> Vector3:
		return global_position

	func combat_radius() -> float:
		return 0.7

	func destroy_by_boss(_source: Node) -> bool:
		destroyed = true
		return true


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var shape := _check_authored_world()
	if shape == null:
		_finish()
		return
	await _build_test_world(shape)
	_check_asset_and_shell()
	_check_grounded_trial_and_hazards()
	_check_summon_and_attacks()
	await _check_hud_and_snapshots()
	_cleanup()
	_finish()


func _check_authored_world() -> PlanetShape:
	var authored := WORLD_SCENE.instantiate()
	var planet := authored.get_node_or_null("Planet") as Planet
	var site := authored.get_node_or_null(
		"Planet/VolcanoronomousCaldera") as Landmark
	var boss := authored.get_node_or_null(
		"Planet/VolcanoronomousCaldera/Volcanoronomous")
	_expect(planet != null and planet.shape != null,
		"authored world supplies the live volcanic PlanetShape")
	_expect(site != null and site.waypoint and site.title == "Volcanoronomous" \
			and site.direction.normalized().angle_to(SITE_DIRECTION) < 0.000001,
		"the south caldera exposes a planet-wide Volcanoronomous waypoint")
	_expect(boss != null and boss.get_script() == BOSS_SCRIPT,
		"Volcanoronomous is instanced beneath the exact caldera landmark")
	var director_failures := \
		BOSS_DEFINITION_REGRESSION.validate_authored_director(authored)
	var director_message := \
		"detached authored BossDirector preserves all three bosses"
	if not director_failures.is_empty():
		director_message += ": " + "; ".join(director_failures)
	_expect(director_failures.is_empty(), director_message)
	if site != null and site.has_method(&"survey_metrics"):
		var metrics := site.call(&"survey_metrics") as Dictionary
		_expect(is_equal_approx(
			float(metrics.get("caldera_radius", 0.0)), 190.0) \
			and is_equal_approx(
				float(metrics.get("arena_radius", 0.0)), ARENA_RADIUS),
			"site metadata matches the analytical caldera and huge arena")
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

	var site := SurfaceAnchor.new()
	site.name = "VolcanoronomousCaldera"
	site.direction = SITE_DIRECTION
	_planet.add_child(site)
	_boss = BOSS_SCENE.instantiate() as CharacterBody3D
	site.add_child(_boss)

	_world.set_physics_process(false)
	add_child(_world)
	await get_tree().process_frame
	await get_tree().process_frame
	_boss.set_physics_process(false)

	_player = TestPlayer.new()
	_player.name = "1"
	_world.add_child(_player, true)
	var at := _offset_direction(SITE_DIRECTION, 650.0, 0.35)
	_player.global_position = _planet.to_global(
		shape.surface_point(at, _planet.finest_spacing())) \
		+ _surface_up(at) * 0.15
	_player.global_basis = _upright_basis(
		_boss.global_position - _player.global_position, _surface_up(at))
	_player.velocity = _player.global_basis.x * 8.0
	_world._spawned_players[1] = _player


func _check_asset_and_shell() -> void:
	var contract_failures := BOSS_DEFINITION_REGRESSION.validate(
		"volcanoronomous", _boss, {
			"node_name": "Volcanoronomous",
			"display_name": "Volcanoronomous",
			"max_health": MAX_HEALTH,
			"arena_radius": ARENA_RADIUS,
			"detection_radius": 1040.0,
			"reset_delay": 7.0,
			"arena_distance_mode": &"surface_arc",
			"location": {
				"mode": &"planet_surface",
				"direction": SITE_DIRECTION,
				"facing": 0.0,
				"clearance": 18.0,
			},
		})
	var contract_message := \
		"shared catalog/runtime contract matches Volcanoronomous"
	if not contract_failures.is_empty():
		contract_message += ": " + "; ".join(contract_failures)
	_expect(contract_failures.is_empty(), contract_message)

	var animator := _boss.get("_animator") as AnimationPlayer
	var skeleton := _boss.get("_skeleton") as Skeleton3D
	var definition := (_boss as BossController).definition()
	var expected_clips := definition.all_animation_clips() \
		if definition != null else PackedStringArray()
	var clips_ok := animator != null and definition != null \
		and expected_clips.size() == 9
	if animator != null:
		for clip: String in expected_clips:
			clips_ok = clips_ok and animator.has_animation(clip)
	var expected_bones := [
		"Root", "Hips", "Spine", "Chest", "Neck", "Head", "LowerJaw",
		"Tail01", "Tail02", "Tail03", "Tail04",
		"LeftWingBase", "LeftWingMid", "LeftWingTip",
		"RightWingBase", "RightWingMid", "RightWingTip",
		"LeftFrontUpperArm", "LeftFrontLowerArm", "LeftFrontClaw",
		"RightFrontUpperArm", "RightFrontLowerArm", "RightFrontClaw",
		"LeftHindUpperLeg", "LeftHindLowerLeg", "LeftHindClaw",
		"RightHindUpperLeg", "RightHindLowerLeg", "RightHindClaw",
	]
	var bones_ok := skeleton != null and skeleton.get_bone_count() == 29
	if skeleton != null:
		for bone: String in expected_bones:
			bones_ok = bones_ok and skeleton.find_bone(bone) >= 0
	_expect(clips_ok, "runtime GLB imports all nine authored encounter clips")
	_expect(bones_ok,
		"runtime GLB imports the 29-bone body, wings, limbs, tail, and jaw")
	_expect(_boss.get("_summon_particles") is GPUParticles3D \
			and _boss.get("_laser_beams") is Node3D,
		"the boss owns eruption and paired eye-beam presentation")
	var boundary := _boss.get("_arena_boundary") as Node
	_expect(boundary != null and is_equal_approx(
			float(boundary.call(&"arena_radius")), ARENA_RADIUS),
		"the dragon owns a terrain-following 900 m arena boundary")
	_expect(int(_boss.get("_stage")) == 0 \
			and not bool((_boss.get("_model") as Node3D).visible),
		"the encounter begins dormant beneath the caldera")
	var trial_hud := _boss.get("_trial_hud") as Control
	trial_hud.call(&"set_trial", true, 12.3, true)
	var timer := trial_hud.get("_timer") as Label
	_expect(String(trial_hud.call(&"countdown_text")) == "12.3" \
			and String(trial_hud.call(&"instruction_text")).is_empty() \
			and trial_hud.get_node_or_null(^"TrialPanel") == null \
			and timer != null and timer.size.x <= 100.0,
		"the ritual HUD is only a compact countdown with no context popup")


func _check_grounded_trial_and_hazards() -> void:
	_boss.call(&"_tick_trial", 0.1)
	_expect(int(_boss.get("_stage")) == 1 \
			and is_equal_approx(
				float(_boss.get("_trial_remaining")), TRIAL_DURATION - 0.1),
		"a grounded moving player on the volcano mountainside advances the timer")

	_player.velocity = Vector3.ZERO
	_boss.set("_spout_left", 999.0)
	_boss.set("_ball_left", 999.0)
	var held := float(_boss.get("_trial_remaining"))
	_boss.call(&"_tick_trial", 1.0)
	_expect(is_equal_approx(
			float(_boss.get("_trial_remaining")), held),
		"standing still holds the ritual instead of completing it")

	_player.stance_state = 3
	_boss.call(&"_tick_trial", 0.1)
	_expect(int(_boss.get("_stage")) == 0 \
			and is_equal_approx(
				float(_boss.get("_trial_remaining")), TRIAL_DURATION),
		"flying or floating immediately clears the rumble and timer")

	_player.stance_state = 0
	_player.velocity = _player.global_basis.x * 8.0
	_boss.call(&"_tick_trial", 0.1)
	_boss.set("_spout_left", 999.0)
	_boss.set("_ball_left", 999.0)

	_player.velocity = _player.global_basis.x * 180.0
	var run := _player.velocity.normalized()
	var player_up := _surface_up(
		_planet.to_local(_player.global_position).normalized())
	var side := run.cross(player_up).normalized()
	var first_plan := _boss.call(
		&"_hazard_plan", _player, VolcanicHazard.Kind.LAVA_BALL, 10
	) as Dictionary
	var second_plan := _boss.call(
		&"_hazard_plan", _player, VolcanicHazard.Kind.LAVA_BALL, 11
	) as Dictionary
	var first_at: Vector3 = first_plan["at"]
	var second_at: Vector3 = second_plan["at"]
	var first_delta := first_at - _player.global_position
	var second_delta := second_at - _player.global_position
	_expect(first_delta.dot(run) > 350.0 and second_delta.dot(run) > 350.0 \
			and first_delta.dot(side) * second_delta.dot(side) < 0.0,
		"fast runners receive alternating lava-ball lanes far ahead of them")
	var launch: Vector3 = first_plan["launch"]
	var impact_up: Vector3 = first_plan["up"]
	_expect((launch - first_at).dot(impact_up) >= 95.0 \
			and (launch - first_at).dot(run) >= 60.0,
		"the visible fireball approaches from high in the runner's forward view")
	var visual := VolcanicHazard.new()
	add_child(visual)
	visual.configure(
		VolcanicHazard.Kind.LAVA_BALL,
		first_at, impact_up, 1010, launch)
	var ball := visual.get("_ball") as MeshInstance3D
	_expect(VolcanicHazard.BALL_FALL >= 2.0 \
			and ball != null and ball.get_aabb().size.x >= 5.0 \
			and ball.get_node_or_null(^"FireHalo") != null \
			and ball.global_position.distance_to(launch) < 0.1,
		"large haloed fireballs remain readable for over two seconds")
	visual.queue_free()

	_player.velocity = _player.global_basis.x * 8.0
	_player.clear_hits()
	_boss.call(&"_on_hazard_resolved", 0, _player.global_position)
	_expect(_player.hits == 1 and is_equal_approx(_player.damage, 22.0) \
			and _player.last_hit.ability_id == "volcanic_fire_spout",
		"warned fire spouts damage and name their grounded target")
	_player.clear_hits()
	_boss.call(&"_on_hazard_resolved", 1, _player.global_position)
	_expect(_player.hits == 1 and is_equal_approx(_player.damage, 32.0) \
			and _player.last_hit.reaction == DamageHit.Reaction.RAGDOLL \
			and _player.last_hit.ability_id == "volcanic_lava_ball",
		"falling lava lands as an attributed ragdoll blast")

	_boss.set("_trial_remaining", 0.05)
	_boss.call(&"_tick_trial", 0.1)
	_expect(int(_boss.get("_stage")) == 2 \
			and bool(_boss.call(&"engaged")) \
			and String(_boss.get("_clip")) == "Emerge",
		"finishing the moving trial summons and engages the boss")


func _check_summon_and_attacks() -> void:
	_boss.call(&"_tick_summoning", 2.5)
	# Runtime calls presentation immediately after the host tick; this harness
	# invokes the state method directly with physics disabled, so mirror that.
	_boss.call(&"_update_presentation", 0.0)
	_expect(int(_boss.get("_stage")) == 3 \
			and String(_boss.get("_clip")) == "Fly" \
			and bool((_boss.get("_model") as Node3D).visible),
		"the eruption ends in a vulnerable aerial orbit")

	_player.clear_hits()
	var target := _player.combat_position()
	_boss.call(&"_sweep_swoop",
		target - _player.global_basis.x * 3.0,
		target + _player.global_basis.x * 3.0)
	_boss.call(&"_sweep_swoop",
		target - _player.global_basis.x * 3.0,
		target + _player.global_basis.x * 3.0)
	_expect(_player.hits == 1 and is_equal_approx(_player.damage, 54.0) \
			and _player.last_hit.reaction == DamageHit.Reaction.RAGDOLL \
			and _player.last_hit.ability_id == "volcanoronomous_swoop",
		"a swoop sweep hits each player once and throws them")

	_player.clear_hits()
	_boss.set("_laser_aim", target)
	_boss.call(&"_apply_laser_damage")
	_expect(_player.hits == 1 and is_equal_approx(_player.damage, 8.0) \
			and _player.last_hit.ability_id == "volcanoronomous_eye_beam",
		"the paired eye beam applies its named damage tick")

	_player.clear_hits()
	_boss.set("_claw_hit_peers", {})
	_boss.call(&"_sweep_claw",
		target - _player.global_basis.x * 3.0,
		target + _player.global_basis.x * 3.0)
	_expect(_player.hits == 1 and is_equal_approx(_player.damage, 38.0) \
			and _player.last_hit.parryable \
			and _player.last_hit.ability_id == "volcanoronomous_claw",
		"the slow-target claw is quick, named, and parryable")

	var fauna := TestFauna.new()
	_world.add_child(fauna)
	fauna.global_position = _boss.call(&"combat_position")
	_boss.set("_fauna_sweep_from", fauna.global_position)
	_boss.set("_fauna_scan_left", 0.0)
	_boss.call(&"_scan_fauna_contact")
	_expect(fauna.destroyed,
		"the flying body categorically destroys fauna it crosses")

	_boss.set("_stage", 3)
	_boss.set("_dodge_cooldown_left", 0.0)
	var shot := DamageHit.impact(
		_boss.call(&"combat_position"), 1.0, 250.0)
	shot.faction = DamageHit.Faction.PLAYER
	shot.set_source(_player, _player.peer_id)
	var dealt := float(_boss.call(&"apply_damage", shot))
	_expect(is_equal_approx(dealt, 250.0) \
			and is_equal_approx(
				float(_boss.call(&"health")), MAX_HEALTH - 250.0) \
			and int(_boss.get("_stage")) == 7 \
			and String(_boss.get("_clip")) == "Dodge",
		"massive health absorbs attacks and incoming fire triggers a fast dodge")

	for ability: String in [
			"volcanoronomous_swoop",
			"volcanoronomous_eye_beam",
			"volcanoronomous_claw",
			"volcanic_lava_ball",
		]:
		var named := DamageHit.new()
		named.ability_id = ability
		_expect(named.ability_display_name() != ability,
			"death notices translate " + ability)


func _check_hud_and_snapshots() -> void:
	_boss.set("_stage", 3)
	_boss.set("_engaged", true)
	_boss.set("_defeated", false)
	var hud := CombatHud.new()
	add_child(hud)
	hud.configure(_player, null, null, null)
	await get_tree().process_frame
	hud.call(&"_poll_boss", 0.16)
	var bar := hud.boss_bar()
	_expect(bar.visible and bar.encounter_title() == "Volcanoronomous",
		"the shared top boss bar names the summoned dragon")
	var boundary := _boss.get("_arena_boundary") as Node
	_expect(boundary != null and bool(boundary.get("visible")),
		"showing the health bar also reveals the huge arena edge")

	var rows := _world.boss_snapshots()
	var found := false
	for row_variant: Variant in rows:
		var row := row_variant as Dictionary
		found = found or String(row.get("boss_id", "")) == "volcanoronomous"
	_world.apply_boss_snapshots(rows)
	_expect(found,
		"late-join world state includes the ritual and flying boss snapshot")

	_world._spawned_players.clear()
	_boss.call(&"_update_arena_presence", 6.9)
	var warned := bool(_boss.call(&"engaged"))
	_boss.call(&"_update_arena_presence", 0.2)
	_expect(warned and not bool(_boss.call(&"engaged")) \
			and is_equal_approx(float(_boss.call(&"health")), MAX_HEALTH) \
			and int(_boss.get("_stage")) == 0,
		"leaving preserves a seven-second warning, then resets the ritual")
	_world._spawned_players[1] = _player
	hud.queue_free()
	await get_tree().process_frame


func _offset_direction(centre: Vector3, distance: float, angle: float) -> Vector3:
	var east := centre.cross(
		Vector3.UP if absf(centre.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := centre.cross(east).normalized()
	var radial := east * cos(angle) + north * sin(angle)
	var arc := distance / _planet.shape.radius
	return (centre * cos(arc) + radial * sin(arc)).normalized()


func _surface_up(direction: Vector3) -> Vector3:
	var inner := _planet.to_global(direction)
	var outer := _planet.to_global(direction * 2.0)
	return (outer - inner).normalized()


func _upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.001:
		forward = up.cross(Vector3.RIGHT).normalized()
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(right, up, right.cross(up).normalized()).orthonormalized()


func _cleanup() -> void:
	if is_instance_valid(_world):
		_world.queue_free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("volcanoronomous_boss_test: PASS  " + message)
		return
	_failures += 1
	push_error("volcanoronomous_boss_test: FAIL  " + message)


func _finish() -> void:
	print("volcanoronomous_boss_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
