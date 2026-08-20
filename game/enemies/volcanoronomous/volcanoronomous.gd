class_name VolcanoronomousBoss
extends BossController

## Host-authoritative caldera encounter.
##
## Before the dragon exists, a grounded player must keep moving on the volcano
## while deterministic fire spouts and falling lava warn, then strike. Flying,
## floating, swimming, grappling, or leaving the mountain clears the trial
## immediately. Once awakened, Volcanoronomous rises from the crater
## lake and owns aerial movement, target choice, attacks, fauna contact, health,
## and reset on the host. Clients interpolate compact snapshots and replay the
## same authored clips and reliable hazard events.

signal health_changed(current: float, maximum: float)
signal engaged_changed(engaged: bool)
signal damaged_flash(strength: float)
signal arena_reset
signal ritual_changed(active: bool, remaining: float)

enum Stage {
	DORMANT,
	TRIAL,
	SUMMONING,
	ORBIT,
	SWOOP,
	LASER,
	CLAW,
	DODGE,
	DEFEATED,
}

const BOSS_SPEC := preload(
	"res://game/enemies/boss/generated/volcanoronomous_spec.gd")
const GROUP := &"bosses"
const LEGACY_GROUP := &"volcanoronomous_boss"
const DISPLAY_NAME := BOSS_SPEC.DISPLAY_NAME
const BOSS_ID := BOSS_SPEC.BOSS_ID

const ARENA_BOUNDARY := preload(
	"res://game/enemies/bigfoot/bigfoot_arena_boundary.gd")
const HAZARD := preload(
	"res://game/enemies/volcanoronomous/volcanic_hazard.gd")
const LASER_BEAMS := preload("res://game/abilities/laser_beams.gd")
const TRIAL_HUD := preload("res://ui/combat/caldera_trial_hud.gd")
const RIM_SURFACE := preload(
	"res://game/enemies/volcanoronomous/volcanoronomous_surface.tres")

const MAX_HEALTH := BOSS_SPEC.MAX_HEALTH
const ARENA_RADIUS := BOSS_SPEC.ARENA_RADIUS
const ARENA_RESET_DELAY := BOSS_SPEC.RESET_DELAY
const ARENA_INSET := 40.0
const SYNC_INTERVAL := 1.0 / 20.0

const TRIAL_DURATION := 24.0
const TRIAL_VOLCANO_RADIUS := BOSS_SPEC.DETECT_RADIUS
const TRIAL_HEIGHT_BELOW := 3.5
const TRIAL_JUMP_HEIGHT := 8.5
const TRIAL_MOVE_SPEED := 1.25
const SPOUT_INTERVAL := 1.05
const BALL_INTERVAL := 1.42
const SPOUT_LEAD_MIN := 10.0
const SPOUT_LEAD_MAX := 170.0
const BALL_LEAD_MIN := 28.0
const BALL_LEAD_MAX := 500.0
const SPOUT_WEAVE_OFFSET := 2.8
const BALL_WEAVE_OFFSET := 4.8
const BALL_LAUNCH_AHEAD := 70.0
const SPOUT_RADIUS := 4.8
const SPOUT_DAMAGE := 22.0
const BALL_RADIUS := 6.4
const BALL_DAMAGE := 32.0

const SUMMON_DURATION := 2.45
const SUMMON_DEPTH := 24.0
const SUMMON_ALTITUDE := 64.0
const BODY_CENTRE_HEIGHT := 5.6
const BODY_RADIUS := 5.8

const ORBIT_RADIUS := 118.0
const ORBIT_ALTITUDE := 92.0
const ORBIT_SPEED := 62.0
const ORBIT_ACCEL := 78.0
const ATTACK_WAIT_MIN := 2.4
const ATTACK_WAIT_MAX := 4.1
const SLOW_TARGET_SPEED := 14.0
const CLAW_START_RANGE := 230.0

const SWOOP_DURATION := 2.05
const SWOOP_HIT_AT := 0.56
const SWOOP_OVERSHOOT := 135.0
const SWOOP_EXIT_ALTITUDE := 74.0
const SWOOP_RADIUS := 6.8
const SWOOP_DAMAGE := 54.0
const SWOOP_KNOCKBACK := 33.0
const SWOOP_LIFT := 17.0

const LASER_TELEGRAPH := 0.78
const LASER_END := 2.12
const LASER_DURATION := 2.52
const LASER_TICK := 0.16
const LASER_DAMAGE := 8.0
const LASER_RADIUS := 1.55
const LASER_EXTENSION := 22.0
const LASER_COLOR := Color(1.0, 0.10, 0.015)

const CLAW_DURATION := 1.02
const CLAW_HIT_START := 0.42
const CLAW_HIT_END := 0.78
const CLAW_RADIUS := 7.2
const CLAW_DAMAGE := 38.0
const CLAW_KNOCKBACK := 22.0
const CLAW_REFLECT := 115.0

const DODGE_DURATION := 0.82
const DODGE_SPEED := 126.0
const DODGE_ACCEL := 290.0
const DODGE_DISTANCE := 102.0
const DODGE_COOLDOWN := 1.25
const FAUNA_SCAN_INTERVAL := 0.085
const FAUNA_CONTACT_RADIUS := 7.0
const CLIP_BLEND := 0.10

const CLIP_IDLE := BOSS_SPEC.ANIMATIONS["rest"]
const CLIP_FLY := BOSS_SPEC.ANIMATIONS["fly"]
const CLIP_SWOOP := BOSS_SPEC.ANIMATIONS["swoop"]
const CLIP_LASER := BOSS_SPEC.ANIMATIONS["laser"]
const CLIP_CLAW := BOSS_SPEC.ANIMATIONS["claw"]
const CLIP_DODGE := BOSS_SPEC.ANIMATIONS["dodge"]
const CLIP_EMERGE := BOSS_SPEC.ANIMATIONS["emerge"]
const CLIP_HIT_REACT := BOSS_SPEC.ANIMATIONS["hit_react"]
const CLIP_DEFEAT := BOSS_SPEC.ANIMATIONS["defeat"]

# Blender (x, y, z) becomes Godot (x, z, -y) under glTF's Y-up conversion.
const LEFT_EYE_MODEL := Vector3(-0.52, 8.34, -4.34)
const RIGHT_EYE_MODEL := Vector3(0.52, 8.34, -4.34)

var _health := MAX_HEALTH
var _engaged := false
var _defeated := false
var _stage := Stage.DORMANT
var _stage_time := 0.0
var _arena_empty_time := 0.0
var _target_peer := 0
var _attack_sequence := 0
var _attack_wait := 0.0

var _site_direction := Vector3.DOWN
var _caldera_point := Vector3.ZERO
var _spawn_transform := Transform3D.IDENTITY
var _trial_remaining := TRIAL_DURATION
var _trial_moving := false
var _spout_left := 0.0
var _ball_left := 0.0
var _hazard_sequence := 0
var _trial_players: Array[Node] = []

var _orbit_phase := 0.0
var _swoop_start := Vector3.ZERO
var _swoop_control := Vector3.ZERO
var _swoop_end := Vector3.ZERO
var _swoop_hit_peers: Dictionary = {}
var _claw_start := Vector3.ZERO
var _claw_end := Vector3.ZERO
var _claw_hit_peers: Dictionary = {}
var _laser_aim := Vector3.ZERO
var _laser_tick_left := 0.0
var _dodge_goal := Vector3.ZERO
var _dodge_cooldown_left := 0.0
var _dodge_sign := 1.0
var _fauna_scan_left := 0.0
var _fauna_sweep_from := Vector3.ZERO
var _defeat_start := Vector3.ZERO

var _clip := CLIP_IDLE
var _clip_speed := 1.0
var _clip_playing := ""
var _clip_seek := -1.0
var _animator: AnimationPlayer
var _skeleton: Skeleton3D
var _head_bone := -1
var _left_eye_in_head := Vector3.ZERO
var _right_eye_in_head := Vector3.ZERO
var _eyes_bound := false
var _model: Node3D
var _collision: CollisionShape3D
var _arena_boundary: Node3D
var _laser_beams: Node3D
var _summon_particles: GPUParticles3D
var _trial_hud: Control
var _trial_rumble_left := 0.0

var _cached_planet: Planet
var _players_buffer: Array = []
var _sync_left := 0.0
var _sync_sequence := 0
var _last_sync_sequence := 0
var _event_sequence := 0
var _last_event_sequence := 0
var _target_transform := Transform3D.IDENTITY
var _target_velocity := Vector3.ZERO
var _has_target_transform := false


func _ready() -> void:
	super._ready()
	add_to_group(GROUP)
	add_to_group(LEGACY_GROUP)
	add_to_group(DamageHit.COMBATANT_GROUP)
	_bind_visuals()
	_build_trial_hud()
	call_deferred(&"_capture_site")
	if _is_host():
		_publish_sync(true)
	else:
		_target_transform = global_transform
		_has_target_transform = true


func _capture_site() -> void:
	if not is_inside_tree():
		return
	var planet := _planet()
	if planet == null or planet.shape == null:
		return
	var site := get_parent()
	if site != null and site.get(&"direction") is Vector3:
		var authored := site.get(&"direction") as Vector3
		if authored.length_squared() > 0.5:
			_site_direction = authored.normalized()
	else:
		_site_direction = planet.shape.volcano_axis().normalized()
	var surface := _surface_point(_site_direction)
	var up := _surface_up(_site_direction)
	var local_elevation := planet.shape.elevation(
		_site_direction, planet.finest_spacing())
	var lava_lift := maxf(
		planet.shape.volcano_crater_lava_height - local_elevation, 0.0)
	_caldera_point = surface + up * (lava_lift + 0.32)
	var forward := _tangent_east(_site_direction)
	_spawn_transform = Transform3D(
		_upright_basis(forward, up), _caldera_point - up * SUMMON_DEPTH)
	top_level = true
	global_transform = _spawn_transform
	_target_transform = global_transform
	_has_target_transform = true
	_fauna_sweep_from = combat_position()
	if is_instance_valid(_arena_boundary):
		_arena_boundary.call(
			&"configure", planet, _site_direction, ARENA_RADIUS)
	_set_collision_enabled(false)
	_update_presentation(0.0)


func _physics_process(delta: float) -> void:
	if not RuntimeTelemetry.deep_enabled():
		_tick(delta)
		return
	var began := Time.get_ticks_usec()
	_tick(delta)
	RuntimeTelemetry.record_physics_step(
		&"bosses", &"volcanoronomous_tick", Time.get_ticks_usec() - began)


func _tick(delta: float) -> void:
	if _is_host():
		_host_tick(delta)
		_sync_left -= delta
		if _sync_left <= 0.0:
			_sync_left = SYNC_INTERVAL
			_publish_sync(false)
	else:
		_client_tick(delta)
	_update_presentation(delta)


func _host_tick(delta: float) -> void:
	_dodge_cooldown_left = maxf(_dodge_cooldown_left - delta, 0.0)
	_fauna_scan_left = maxf(_fauna_scan_left - delta, 0.0)
	if _stage == Stage.DORMANT or _stage == Stage.TRIAL:
		_tick_trial(delta)
		return
	if _stage == Stage.DEFEATED:
		_tick_defeated(delta)
		return

	if _stage >= Stage.SUMMONING:
		_update_arena_presence(delta)
		if _stage == Stage.DORMANT:
			return
		if _target_player() == null:
			_pick_target()

	match _stage:
		Stage.SUMMONING:
			_tick_summoning(delta)
		Stage.ORBIT:
			_tick_orbit(delta)
		Stage.SWOOP:
			_tick_swoop(delta)
		Stage.LASER:
			_tick_laser(delta)
		Stage.CLAW:
			_tick_claw(delta)
		Stage.DODGE:
			_tick_dodge(delta)


func _client_tick(delta: float) -> void:
	if _has_target_transform:
		var step := clampf(delta * 12.0, 0.0, 1.0)
		global_transform = global_transform.interpolate_with(
			_target_transform, step)
		velocity = _target_velocity
	_stage_time += delta


# --- Caldera trial ----------------------------------------------------------

func _tick_trial(delta: float) -> void:
	_trial_players.clear()
	for player: Node in _living_players_in_world():
		if _player_grounded_on_volcano(player):
			_trial_players.append(player)
	if _trial_players.is_empty():
		if _stage == Stage.TRIAL:
			_clear_trial()
		return

	if _stage == Stage.DORMANT:
		_begin_trial()
	_trial_moving = false
	for player: Node in _trial_players:
		_trial_moving = _trial_moving \
			or _player_moving_for_trial(player)
	if _trial_moving:
		_trial_remaining = maxf(_trial_remaining - delta, 0.0)
	_stage_time += delta
	_spout_left -= delta
	_ball_left -= delta
	if _spout_left <= 0.0:
		_spout_left = SPOUT_INTERVAL
		_launch_trial_hazard(VolcanicHazard.Kind.FIRE_SPOUT)
	if _ball_left <= 0.0:
		_ball_left = BALL_INTERVAL
		_launch_trial_hazard(VolcanicHazard.Kind.LAVA_BALL)
	if _trial_remaining <= 0.0:
		_begin_summoning()


func _begin_trial() -> void:
	_stage = Stage.TRIAL
	_stage_time = 0.0
	_trial_remaining = TRIAL_DURATION
	_trial_moving = false
	_spout_left = 0.35
	_ball_left = 0.78
	ritual_changed.emit(true, _trial_remaining)
	_publish_event({"kind": "trial_started"})
	_publish_sync(true)


func _clear_trial() -> void:
	_stage = Stage.DORMANT
	_stage_time = 0.0
	_trial_remaining = TRIAL_DURATION
	_trial_moving = false
	_spout_left = 0.0
	_ball_left = 0.0
	_clear_hazards()
	ritual_changed.emit(false, _trial_remaining)
	_publish_event({"kind": "trial_cleared"})
	_publish_sync(true)


func _player_grounded_on_volcano(player: Node) -> bool:
	if player == null or not player is Node3D or _player_dead(player):
		return false
	if player.has_method(&"stance"):
		var stance := int(player.call(&"stance"))
		# STAND, CROUCH, SLIDE, and HERO remain surface movement. FLY includes
		# its slow float pose; CRASH, SWIM, METEOR, and GRAPPLE do not qualify.
		if stance != 0 and stance != 1 and stance != 2 and stance != 6:
			return false
	var planet := _planet()
	if planet == null or planet.shape == null:
		return false
	var local := planet.to_local((player as Node3D).global_position)
	if local.length_squared() < 1.0:
		return false
	var direction := local.normalized()
	var radial := planet.shape.volcano_coordinates(direction).length()
	if radial > TRIAL_VOLCANO_RADIUS:
		return false
	var ground_radius := planet.shape.radius + planet.shape.elevation(
		direction, planet.finest_spacing())
	var altitude := local.length() - ground_radius
	return altitude >= -TRIAL_HEIGHT_BELOW and altitude <= TRIAL_JUMP_HEIGHT


func _player_moving_for_trial(player: Node) -> bool:
	if not player is CharacterBody3D:
		return true
	var up := _planet_up_at((player as Node3D).global_position)
	var carried := (player as CharacterBody3D).velocity
	var tangent := carried - up * carried.dot(up)
	# A jump is allowed even at the instant its tangent speed falls away.
	return tangent.length() >= TRIAL_MOVE_SPEED \
		or absf(carried.dot(up)) >= TRIAL_MOVE_SPEED * 0.65


func _launch_trial_hazard(hazard_kind: int) -> void:
	if _trial_players.is_empty():
		return
	_hazard_sequence += 1
	var pick := posmod(_hazard_sequence * 7 + hazard_kind * 3,
		_trial_players.size())
	var target := _trial_players[pick] as Node3D
	var plan := _hazard_plan(target, hazard_kind, _hazard_sequence)
	var at: Vector3 = plan.get("at", _caldera_point)
	var up: Vector3 = plan.get("up", _planet_up_at(at))
	var launch: Vector3 = plan.get("launch", Vector3.ZERO)
	_publish_event({
		"kind": "hazard",
		"hazard_kind": hazard_kind,
		"at": at,
		"up": up,
		"launch": launch,
		"seed": _hazard_sequence * 101 + hazard_kind * 17,
	})


func _hazard_plan(target: Node3D, hazard_kind: int,
		sequence: int) -> Dictionary:
	var planet := _planet()
	if planet == null or planet.shape == null or target == null:
		return {
			"at": _caldera_point,
			"up": _planet_up_at(_caldera_point),
			"launch": Vector3.ZERO,
		}
	var local := planet.to_local(target.global_position)
	if local.length_squared() < 1.0:
		return {
			"at": _caldera_point,
			"up": _planet_up_at(_caldera_point),
			"launch": Vector3.ZERO,
		}

	var player_up := _planet_up_at(target.global_position)
	var carried := (target as CharacterBody3D).velocity \
		if target is CharacterBody3D else Vector3.ZERO
	var forward := carried - player_up * carried.dot(player_up)
	var speed := forward.length()
	if speed < TRIAL_MOVE_SPEED:
		forward = -target.global_basis.z
		forward -= player_up * forward.dot(player_up)
	if forward.length_squared() < 0.01:
		forward = _tangent_east(player_up)
	forward = forward.normalized()

	var lava_ball := hazard_kind == VolcanicHazard.Kind.LAVA_BALL
	var reaction_time := VolcanicHazard.BALL_FALL \
		if lava_ball else VolcanicHazard.SPOUT_WARNING
	var lead := clampf(
		speed * reaction_time,
		BALL_LEAD_MIN if lava_ball else SPOUT_LEAD_MIN,
		BALL_LEAD_MAX if lava_ball else SPOUT_LEAD_MAX)
	var right := forward.cross(player_up).normalized()
	var lane := 1.0 if sequence % 2 == 0 else -1.0
	var weave := BALL_WEAVE_OFFSET if lava_ball else SPOUT_WEAVE_OFFSET
	var predicted := target.global_position \
		+ forward * lead + right * lane * weave
	var predicted_local := planet.to_local(predicted)
	var direction := predicted_local.normalized()
	var at := _surface_point(direction) + _surface_up(direction) * 0.18
	var impact_up := _planet_up_at(at)
	var impact_forward := forward - impact_up * forward.dot(impact_up)
	impact_forward = impact_forward.normalized() \
		if impact_forward.length_squared() > 0.01 \
		else _tangent_east(impact_up)
	var launch := at + impact_up * VolcanicHazard.BALL_HEIGHT \
		+ impact_forward * BALL_LAUNCH_AHEAD if lava_ball else Vector3.ZERO
	return {
		"at": at,
		"up": impact_up,
		"launch": launch,
		"forward": forward,
		"lead": lead,
		"lane": lane,
	}


func _spawn_hazard(hazard_kind: int, at: Vector3,
		up: Vector3, seed: int, launch := Vector3.ZERO) -> void:
	var hazard := HAZARD.new()
	add_child(hazard)
	hazard.configure(hazard_kind, at, up, seed, launch)
	hazard.resolved.connect(_on_hazard_resolved)


func _on_hazard_resolved(hazard_kind: int, at: Vector3) -> void:
	if not _is_host() or (_stage != Stage.TRIAL \
			and _stage != Stage.SUMMONING):
		return
	var radius := SPOUT_RADIUS \
		if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT else BALL_RADIUS
	var amount := SPOUT_DAMAGE \
		if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT else BALL_DAMAGE
	var up := _planet_up_at(at)
	for player: Node in _living_players_in_world():
		var point := _combat_position(player)
		if point.distance_to(at) > radius + _combat_radius(player):
			continue
		var away := point - at
		away -= up * away.dot(up)
		if away.length_squared() < 0.01:
			away = _tangent_east(up)
		var hit := DamageHit.impact(at, radius, amount)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = _peer_id(player)
		hit.reaction = DamageHit.Reaction.STAGGER \
			if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT \
			else DamageHit.Reaction.RAGDOLL
		hit.world_impulse = away.normalized() * (
			10.0 if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT else 19.0
		) + up * (
			7.0 if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT else 13.0)
		hit.ability_id = "volcanic_fire_spout" \
			if hazard_kind == VolcanicHazard.Kind.FIRE_SPOUT \
			else "volcanic_lava_ball"
		hit.set_source(self)
		if player.has_method(&"apply_damage"):
			player.call(&"apply_damage", hit)


func _clear_hazards() -> void:
	for child: Node in get_children():
		if child.get_script() == HAZARD:
			child.queue_free()


# --- Summon and aerial behaviour -------------------------------------------

func _begin_summoning() -> void:
	_stage = Stage.SUMMONING
	_stage_time = 0.0
	_engaged = true
	_trial_remaining = 0.0
	_trial_moving = false
	_target_peer = 0
	_pick_target()
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_play_clip(CLIP_EMERGE)
	_set_collision_enabled(false)
	engaged_changed.emit(true)
	ritual_changed.emit(false, 0.0)
	_publish_event({"kind": "summoned"})
	_publish_sync(true)


func _tick_summoning(delta: float) -> void:
	_stage_time += delta
	var share := _ease(_stage_time / SUMMON_DURATION)
	var up := _surface_up(_site_direction)
	var previous := global_position
	global_position = _caldera_point + up * lerpf(
		-SUMMON_DEPTH, SUMMON_ALTITUDE, share)
	var forward := _tangent_east(_site_direction)
	global_basis = _upright_basis(forward, up)
	velocity = (global_position - previous) / maxf(delta, 0.001)
	_set_collision_enabled(share >= 0.42)
	if share < 1.0:
		return
	_stage = Stage.ORBIT
	_stage_time = 0.0
	_attack_wait = 2.15
	_orbit_phase = 0.0
	_play_clip(CLIP_FLY)
	_fauna_sweep_from = combat_position()
	_publish_sync(true)


func _tick_orbit(delta: float) -> void:
	_stage_time += delta
	_attack_wait = maxf(_attack_wait - delta, 0.0)
	var target := _target_player()
	if target == null:
		_pick_target()
		target = _target_player()
	var goal := _orbit_goal(target, delta)
	_fly_toward(goal, ORBIT_SPEED, ORBIT_ACCEL, delta)
	_scan_fauna_contact()
	if target == null or _attack_wait > 0.0:
		return
	_choose_attack(target)


func _orbit_goal(target: Node, delta: float) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return _caldera_point + _surface_up(_site_direction) * ORBIT_ALTITUDE
	var centre_direction := _site_direction
	if target is Node3D:
		var local := planet.to_local((target as Node3D).global_position)
		if local.length_squared() > 1.0:
			centre_direction = local.normalized()
	_orbit_phase = wrapf(
		_orbit_phase + delta * (ORBIT_SPEED / ORBIT_RADIUS), 0.0, TAU)
	var east := _tangent_east(centre_direction)
	var north := centre_direction.cross(east).normalized()
	var radial := east * cos(_orbit_phase) + north * sin(_orbit_phase)
	var orbit_direction := (
		centre_direction * cos(ORBIT_RADIUS / planet.shape.radius)
		+ radial * sin(ORBIT_RADIUS / planet.shape.radius)
	).normalized()
	orbit_direction = _clamp_direction_to_arena(orbit_direction)
	var altitude := ORBIT_ALTITUDE + sin(_orbit_phase * 1.7) * 23.0
	return _surface_point(orbit_direction) \
		+ _surface_up(orbit_direction) * altitude


func _choose_attack(target: Node) -> void:
	_attack_sequence += 1
	var gap := combat_position().distance_to(_combat_position(target))
	var slow := _player_speed(target) <= SLOW_TARGET_SPEED
	if slow and gap <= CLAW_START_RANGE and _attack_sequence % 3 != 0:
		_begin_claw(target)
	elif _attack_sequence % 2 == 0:
		_begin_laser(target)
	else:
		_begin_swoop(target)


func _begin_swoop(target: Node) -> void:
	if target == null:
		return
	var planet := _planet()
	if planet == null or planet.shape == null:
		return
	_stage = Stage.SWOOP
	_stage_time = 0.0
	_swoop_hit_peers.clear()
	_swoop_start = global_position
	var target_point := _combat_position(target)
	if target is CharacterBody3D:
		target_point += (target as CharacterBody3D).velocity * 0.46
	var target_up := _planet_up_at(target_point)
	var hit_root := _root_for_combat_point(target_point, target_up)
	var travel := hit_root - _swoop_start
	travel -= target_up * travel.dot(target_up)
	if travel.length_squared() < 0.01:
		travel = -global_basis.z
	var overshot := hit_root + travel.normalized() * SWOOP_OVERSHOOT
	_swoop_end = _point_at_altitude(overshot, SWOOP_EXIT_ALTITUDE)
	var one_minus := 1.0 - SWOOP_HIT_AT
	var denominator := 2.0 * one_minus * SWOOP_HIT_AT
	_swoop_control = (
		hit_root
		- _swoop_start * (one_minus * one_minus)
		- _swoop_end * (SWOOP_HIT_AT * SWOOP_HIT_AT)
	) / denominator
	_play_clip(CLIP_SWOOP)
	_publish_sync(true)


func _tick_swoop(delta: float) -> void:
	var previous_position := global_position
	var previous_combat := combat_position()
	_stage_time += delta
	var share := clampf(_stage_time / SWOOP_DURATION, 0.0, 1.0)
	var one_minus := 1.0 - share
	global_position = _swoop_start * (one_minus * one_minus) \
		+ _swoop_control * (2.0 * one_minus * share) \
		+ _swoop_end * (share * share)
	global_position = _clamp_point_to_arena(global_position)
	var derivative := (_swoop_control - _swoop_start) * (2.0 * one_minus) \
		+ (_swoop_end - _swoop_control) * (2.0 * share)
	velocity = (global_position - previous_position) / maxf(delta, 0.001)
	_face_flight_vector(derivative, delta, 12.0)
	_sweep_swoop(previous_combat, combat_position())
	_scan_fauna_contact()
	if share >= 1.0:
		_finish_attack()


func _sweep_swoop(from: Vector3, to: Vector3) -> void:
	var volume := DamageHit.beam(from, to, SWOOP_RADIUS, SWOOP_DAMAGE)
	for player: Node in _living_players_in_world():
		var peer := _peer_id(player)
		if _swoop_hit_peers.has(peer) \
				or not volume.reaches(
					_combat_position(player), _combat_radius(player)):
			continue
		_swoop_hit_peers[peer] = true
		var along := to - from
		if along.length_squared() < 0.01:
			along = -global_basis.z
		var up := _planet_up_at(_combat_position(player))
		var hit := DamageHit.impact(
			_combat_position(player), SWOOP_RADIUS, SWOOP_DAMAGE)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = peer
		hit.reaction = DamageHit.Reaction.RAGDOLL
		hit.world_impulse = along.normalized() * SWOOP_KNOCKBACK \
			+ up * SWOOP_LIFT
		hit.ability_id = "volcanoronomous_swoop"
		hit.set_source(self)
		if player.has_method(&"apply_damage"):
			player.call(&"apply_damage", hit)


func _begin_laser(target: Node) -> void:
	_stage = Stage.LASER
	_stage_time = 0.0
	_laser_tick_left = LASER_TELEGRAPH
	_laser_aim = _combat_position(target)
	velocity *= 0.3
	_play_clip(CLIP_LASER)
	_publish_sync(true)


func _tick_laser(delta: float) -> void:
	_stage_time += delta
	var target := _target_player()
	if target != null:
		var wanted := _combat_position(target)
		if target is CharacterBody3D:
			wanted += (target as CharacterBody3D).velocity * 0.10
		var aim_step := clampf(delta * (
			3.0 if _stage_time < LASER_TELEGRAPH else 6.5), 0.0, 1.0)
		_laser_aim = _laser_aim.lerp(wanted, aim_step)
		_face_flight_vector(_laser_aim - combat_position(), delta, 5.5)
	velocity = velocity.move_toward(Vector3.ZERO, 48.0 * delta)
	global_position += velocity * delta
	if _stage_time >= LASER_TELEGRAPH and _stage_time <= LASER_END:
		_laser_tick_left -= delta
		if _laser_tick_left <= 0.0:
			_laser_tick_left += LASER_TICK
			_apply_laser_damage()
	if _stage_time >= LASER_DURATION:
		_finish_attack()


func _apply_laser_damage() -> void:
	var eyes := _eye_positions()
	var from := (eyes[0] + eyes[1]) * 0.5
	var endpoint := _laser_endpoint(from)
	var volume := DamageHit.beam(from, endpoint, LASER_RADIUS, LASER_DAMAGE)
	for player: Node in _living_players_in_world():
		if not volume.reaches(
				_combat_position(player), _combat_radius(player)):
			continue
		var hit := DamageHit.beam(from, endpoint, LASER_RADIUS, LASER_DAMAGE)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = _peer_id(player)
		hit.reaction = DamageHit.Reaction.STAGGER
		hit.world_impulse = Vector3.ZERO
		hit.ability_id = "volcanoronomous_eye_beam"
		hit.set_source(self)
		if player.has_method(&"apply_damage"):
			player.call(&"apply_damage", hit)


func _begin_claw(target: Node) -> void:
	if target == null:
		return
	_stage = Stage.CLAW
	_stage_time = 0.0
	_claw_hit_peers.clear()
	_claw_start = global_position
	var point := _combat_position(target)
	if target is CharacterBody3D:
		point += (target as CharacterBody3D).velocity * 0.22
	_claw_end = _root_for_combat_point(point, _planet_up_at(point))
	_play_clip(CLIP_CLAW)
	_publish_sync(true)


func _tick_claw(delta: float) -> void:
	var previous_position := global_position
	var previous_combat := combat_position()
	_stage_time += delta
	var share := clampf(_stage_time / CLAW_DURATION, 0.0, 1.0)
	var eased := _ease(share)
	var up := _planet_up_at(_claw_start.lerp(_claw_end, eased))
	global_position = _claw_start.lerp(_claw_end, eased) \
		+ up * sin(share * PI) * 11.0
	global_position = _clamp_point_to_arena(global_position)
	velocity = (global_position - previous_position) / maxf(delta, 0.001)
	_face_flight_vector(_claw_end - global_position, delta, 14.0)
	if share >= CLAW_HIT_START and share <= CLAW_HIT_END:
		_sweep_claw(previous_combat, combat_position())
	_scan_fauna_contact()
	if share >= 1.0:
		_finish_attack()


func _sweep_claw(from: Vector3, to: Vector3) -> void:
	var volume := DamageHit.beam(from, to, CLAW_RADIUS, CLAW_DAMAGE)
	for player: Node in _living_players_in_world():
		var peer := _peer_id(player)
		if _claw_hit_peers.has(peer) \
				or not volume.reaches(
					_combat_position(player), _combat_radius(player)):
			continue
		_claw_hit_peers[peer] = true
		var away := _combat_position(player) - combat_position()
		if away.length_squared() < 0.01:
			away = -global_basis.z
		var up := _planet_up_at(_combat_position(player))
		var hit := DamageHit.impact(
			_combat_position(player), CLAW_RADIUS, CLAW_DAMAGE)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = peer
		hit.reaction = DamageHit.Reaction.KNOCKBACK
		hit.world_impulse = away.normalized() * CLAW_KNOCKBACK + up * 7.0
		hit.parryable = true
		hit.reflection = CLAW_REFLECT
		hit.ability_id = "volcanoronomous_claw"
		hit.set_source(self)
		if player.has_method(&"apply_damage"):
			player.call(&"apply_damage", hit)


func _begin_dodge() -> void:
	if _stage != Stage.ORBIT and _stage != Stage.LASER:
		return
	_stage = Stage.DODGE
	_stage_time = 0.0
	_dodge_cooldown_left = DODGE_COOLDOWN
	_dodge_sign *= -1.0
	var up := _planet_up_at(global_position)
	var forward := velocity
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.01:
		forward = -global_basis.z
	var side := up.cross(forward).normalized() * _dodge_sign
	_dodge_goal = _point_at_altitude(
		global_position + side * DODGE_DISTANCE + up * 24.0,
		ORBIT_ALTITUDE + 16.0)
	_play_clip(CLIP_DODGE)
	_publish_sync(true)


func _tick_dodge(delta: float) -> void:
	_stage_time += delta
	_fly_toward(_dodge_goal, DODGE_SPEED, DODGE_ACCEL, delta)
	_scan_fauna_contact()
	if _stage_time >= DODGE_DURATION \
			or global_position.distance_to(_dodge_goal) <= 8.0:
		_finish_attack(1.2)


func _finish_attack(wait := -1.0) -> void:
	_stage = Stage.ORBIT
	_stage_time = 0.0
	_attack_wait = _next_attack_wait() if wait < 0.0 else wait
	_swoop_hit_peers.clear()
	_claw_hit_peers.clear()
	_play_clip(CLIP_FLY)
	_publish_sync(true)


func _fly_toward(goal: Vector3, speed: float, acceleration: float,
		delta: float) -> void:
	goal = _clamp_point_to_arena(goal)
	var along := goal - global_position
	var desired := along.normalized() * speed \
		if along.length_squared() > 0.01 else Vector3.ZERO
	velocity = velocity.move_toward(desired, acceleration * delta)
	var previous := global_position
	global_position += velocity * delta
	global_position = _clamp_point_to_arena(global_position)
	velocity = (global_position - previous) / maxf(delta, 0.001)
	_face_flight_vector(velocity, delta, 5.5)


func _face_flight_vector(along: Vector3, delta: float, rate: float) -> void:
	if along.length_squared() < 0.01:
		return
	var up := _planet_up_at(global_position)
	var wanted := _upright_basis(along, up)
	global_basis = global_basis.slerp(
		wanted, clampf(delta * rate, 0.0, 1.0)).orthonormalized()


func _scan_fauna_contact() -> void:
	var current := combat_position()
	if _fauna_scan_left > 0.0:
		return
	_fauna_scan_left = FAUNA_SCAN_INTERVAL
	var volume := DamageHit.beam(
		_fauna_sweep_from, current, FAUNA_CONTACT_RADIUS, MAX_HEALTH)
	for fauna_variant: Variant in get_tree().get_nodes_in_group(&"fauna_mobs"):
		var fauna := fauna_variant as Node
		if fauna == null or not is_instance_valid(fauna) \
				or not DamageHit.in_same_world(self, fauna):
			continue
		if not volume.reaches(
			_combat_position(fauna), _combat_radius(fauna)):
			continue
		if fauna.has_method(&"destroy_by_boss"):
			fauna.call(&"destroy_by_boss", self)
	_fauna_sweep_from = current


# --- Arena, health, and combat contract ------------------------------------

func _update_arena_presence(delta: float) -> void:
	var any_inside := false
	for player: Node in _living_players_in_world():
		if arena_distance_to(player as Node3D) <= ARENA_RADIUS:
			any_inside = true
			break
	if any_inside:
		_arena_empty_time = 0.0
		return
	_arena_empty_time += delta
	if _arena_empty_time >= ARENA_RESET_DELAY:
		_reset_arena()


func _reset_arena() -> void:
	set_arena_boundary_visible(false)
	_health = MAX_HEALTH
	_engaged = false
	_defeated = false
	_stage = Stage.DORMANT
	_stage_time = 0.0
	_arena_empty_time = 0.0
	_target_peer = 0
	_attack_wait = 0.0
	_trial_remaining = TRIAL_DURATION
	_trial_moving = false
	_spout_left = 0.0
	_ball_left = 0.0
	_swoop_hit_peers.clear()
	_claw_hit_peers.clear()
	_clear_hazards()
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_play_clip(CLIP_IDLE)
	_set_collision_enabled(false)
	health_changed.emit(_health, MAX_HEALTH)
	engaged_changed.emit(false)
	ritual_changed.emit(false, _trial_remaining)
	arena_reset.emit()
	_publish_event({"kind": "reset"})
	_publish_sync(true)


func boss_id() -> String:
	return BOSS_ID


func maximum_health() -> float:
	return MAX_HEALTH


func health() -> float:
	return _health


func engaged() -> bool:
	return _engaged


func defeated() -> bool:
	return _defeated


func battle_radius() -> float:
	return ARENA_RADIUS


func combat_faction() -> int:
	return DamageHit.Faction.ENEMY


func combat_peer_id() -> int:
	return 0


func combat_display_name() -> String:
	return DISPLAY_NAME


func combat_position() -> Vector3:
	return global_position + _planet_up_at(global_position) * BODY_CENTRE_HEIGHT


func combat_radius() -> float:
	return BODY_RADIUS


func can_be_grappled() -> bool:
	return false


func can_be_lassoed() -> bool:
	return false


func set_arena_boundary_visible(shown: bool) -> void:
	if is_instance_valid(_arena_boundary) \
			and _arena_boundary.has_method(&"set_active"):
		_arena_boundary.call(&"set_active", shown and not _defeated)


func arena_distance_to(body: Node3D) -> float:
	var planet := _planet()
	if planet == null or planet.shape == null or body == null:
		return INF
	var point := planet.to_local(body.global_position)
	if point.length_squared() < 1.0:
		return INF
	return _site_direction.angle_to(point.normalized()) * planet.shape.radius


func apply_damage(hit: DamageHit) -> float:
	if hit == null or not _is_host() or _defeated \
			or _stage < Stage.SUMMONING:
		return 0.0
	if _stage == Stage.SUMMONING and _stage_time < SUMMON_DURATION * 0.38:
		return 0.0
	if hit.faction != DamageHit.Faction.PLAYER:
		return 0.0
	var amount := clampf(
		hit.amount if is_finite(hit.amount) else 0.0, 0.0, _health)
	if amount <= 0.0:
		return 0.0
	_health -= amount
	health_changed.emit(_health, MAX_HEALTH)
	_publish_event({
		"kind": "damaged",
		"amount": amount,
		"at": hit.centre(),
	})
	if _health <= 0.0:
		_defeat()
	elif _dodge_cooldown_left <= 0.0 \
			and (_stage == Stage.ORBIT or _stage == Stage.LASER):
		_begin_dodge()
	return amount


func receive_reflected_damage(amount: float, source_peer: int) -> void:
	if not _is_host() or amount <= 0.0:
		return
	var hit := DamageHit.impact(combat_position(), combat_radius(), amount)
	hit.faction = DamageHit.Faction.PLAYER
	hit.source_peer = source_peer
	hit.ability_id = "parry_reflect"
	var source := _player_by_peer(source_peer)
	if source != null:
		hit.set_source(source, source_peer)
	var dealt := apply_damage(hit)
	if dealt > 0.0 and source != null \
			and source.has_method(&"combat_damage_dealt"):
		source.call(&"combat_damage_dealt", self, dealt, hit)


func _defeat() -> void:
	_defeated = true
	_engaged = false
	_stage = Stage.DEFEATED
	_stage_time = 0.0
	_defeat_start = global_position
	velocity = Vector3.ZERO
	_set_collision_enabled(false)
	set_arena_boundary_visible(false)
	_play_clip(CLIP_DEFEAT)
	engaged_changed.emit(false)
	_publish_event({"kind": "defeated"})
	_publish_sync(true)


func _tick_defeated(delta: float) -> void:
	_stage_time += delta
	var share := _ease(clampf(_stage_time / 3.2, 0.0, 1.0))
	var up := _surface_up(_site_direction)
	global_position = _defeat_start.lerp(_caldera_point + up * 3.0, share)
	velocity = Vector3.ZERO


func flash_damage(strength := 1.0) -> void:
	damaged_flash.emit(clampf(strength, 0.0, 1.0))


# --- Boss snapshots and encounter events ----------------------------------

func boss_snapshot() -> Dictionary:
	return {
		"boss_id": BOSS_ID,
		"health": _health,
		"maximum_health": MAX_HEALTH,
		"engaged": _engaged,
		"defeated": _defeated,
		"stage": _stage,
		"stage_time": _stage_time,
		"trial_remaining": _trial_remaining,
		"trial_moving": _trial_moving,
		"target_peer": _target_peer,
		"transform": global_transform,
		"velocity": velocity,
		"clip": _clip,
		"clip_speed": _clip_speed,
		"clip_position": _animation_position(),
		"laser_aim": _laser_aim,
		"sync_sequence": _sync_sequence,
	}


func apply_boss_snapshot(wire: Dictionary) -> void:
	if wire.is_empty() or String(wire.get("boss_id", BOSS_ID)) != BOSS_ID:
		return
	var sequence := int(wire.get("sync_sequence", 0))
	if sequence > 0:
		if sequence <= _last_sync_sequence:
			return
		_last_sync_sequence = sequence
	var previous_health := _health
	var next_health := float(wire.get("health", _health))
	if is_finite(next_health):
		_health = clampf(next_health, 0.0, MAX_HEALTH)
	if not is_equal_approx(previous_health, _health):
		health_changed.emit(_health, MAX_HEALTH)
	var was_engaged := _engaged
	var previous_stage := _stage
	_engaged = bool(wire.get("engaged", _engaged))
	_defeated = bool(wire.get("defeated", _defeated))
	_stage = clampi(int(wire.get("stage", _stage)), Stage.DORMANT, Stage.DEFEATED)
	_stage_time = maxf(float(wire.get("stage_time", _stage_time)), 0.0)
	_trial_remaining = clampf(
		float(wire.get("trial_remaining", _trial_remaining)),
		0.0, TRIAL_DURATION)
	_trial_moving = bool(wire.get("trial_moving", _trial_moving))
	_target_peer = int(wire.get("target_peer", _target_peer))
	var transform_variant: Variant = wire.get("transform", global_transform)
	if transform_variant is Transform3D:
		var first_transform := not _has_target_transform
		_target_transform = transform_variant
		if first_transform:
			global_transform = transform_variant
		_has_target_transform = true
	var velocity_variant: Variant = wire.get("velocity", velocity)
	if velocity_variant is Vector3 and (velocity_variant as Vector3).is_finite():
		_target_velocity = velocity_variant
		velocity = _target_velocity
	var aim_variant: Variant = wire.get("laser_aim", _laser_aim)
	if aim_variant is Vector3 and (aim_variant as Vector3).is_finite():
		_laser_aim = aim_variant
	var previous_clip := _clip
	_clip = String(wire.get("clip", _clip))
	_clip_speed = clampf(float(wire.get("clip_speed", 1.0)), 0.1, 3.0)
	if _clip != previous_clip or _clip_playing != _clip:
		_clip_seek = maxf(float(wire.get("clip_position", 0.0)), 0.0)
	if was_engaged != _engaged:
		engaged_changed.emit(_engaged)
	if previous_stage != _stage:
		ritual_changed.emit(
			_stage == Stage.TRIAL, _trial_remaining)


func _publish_sync(reliable: bool) -> void:
	if not _has_listeners():
		return
	_sync_sequence += 1
	var wire := boss_snapshot()
	wire["sync_sequence"] = _sync_sequence
	if reliable:
		_apply_volcanoronomous_sync_reliable.rpc(_sync_sequence, wire)
	else:
		_apply_volcanoronomous_sync.rpc(_sync_sequence, wire)


func _publish_event(event: Dictionary) -> void:
	_event_sequence += 1
	event["sequence"] = _event_sequence
	if not _has_listeners():
		_apply_volcanoronomous_event(_event_sequence, event)
	else:
		_apply_volcanoronomous_event.rpc(_event_sequence, event)


@rpc("authority", "call_local", "unreliable_ordered")
func _apply_volcanoronomous_sync(sequence: int, wire: Dictionary) -> void:
	if _is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_local", "reliable")
func _apply_volcanoronomous_sync_reliable(
		sequence: int, wire: Dictionary) -> void:
	if _is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_local", "reliable")
func _apply_volcanoronomous_event(
		sequence: int, event: Dictionary) -> void:
	if sequence <= _last_event_sequence:
		return
	_last_event_sequence = sequence
	match String(event.get("kind", "")):
		"hazard":
			var at: Variant = event.get("at", Vector3.ZERO)
			var up: Variant = event.get("up", Vector3.UP)
			var launch: Variant = event.get("launch", Vector3.ZERO)
			if at is Vector3 and up is Vector3 and launch is Vector3:
				_spawn_hazard(
					int(event.get("hazard_kind", 0)),
					at, up, int(event.get("seed", sequence)), launch)
		"trial_cleared", "reset":
			_clear_hazards()
			if String(event.get("kind", "")) == "reset":
				arena_reset.emit()
		"summoned", "defeated":
			_burst_summon()
		"damaged":
			var amount := float(event.get("amount", 0.0))
			flash_damage(clampf(amount / 180.0, 0.18, 1.0))


func _has_listeners() -> bool:
	return multiplayer.has_multiplayer_peer() \
		and not multiplayer.get_peers().is_empty()


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


# --- Presentation -----------------------------------------------------------

func _bind_visuals() -> void:
	_model = get_node_or_null(^"Model") as Node3D
	if _model != null:
		# Capture is deferred until the Planet has finished preparing its shape.
		# Hide now so the submerged rest pose cannot flash for that one frame.
		_model.visible = false
		_animator = _model.find_child(
			"AnimationPlayer", true, false) as AnimationPlayer
		_skeleton = _model.find_child(
			"Skeleton3D", true, false) as Skeleton3D
		for node: Node in _model.find_children(
				"*", "MeshInstance3D", true, false):
			(node as MeshInstance3D).material_override = RIM_SURFACE
	_collision = get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if _animator != null:
		for clip_name: String in [CLIP_IDLE, CLIP_FLY]:
			if _animator.has_animation(clip_name):
				_animator.get_animation(clip_name).loop_mode \
					= Animation.LOOP_LINEAR
	_bind_eye_rest()
	_laser_beams = LASER_BEAMS.new()
	_laser_beams.name = "EyeBeam"
	add_child(_laser_beams, false, Node.INTERNAL_MODE_BACK)
	_arena_boundary = ARENA_BOUNDARY.new()
	_arena_boundary.name = "ArenaBoundary"
	add_child(_arena_boundary, false, Node.INTERNAL_MODE_BACK)
	_build_summon_particles()
	_set_collision_enabled(false)


func _bind_eye_rest() -> void:
	if _skeleton == null or _model == null:
		return
	_head_bone = _skeleton.find_bone("Head")
	if _head_bone < 0:
		return
	var rest := _skeleton.get_bone_global_rest(_head_bone)
	var left_in_skeleton := _skeleton.to_local(
		_model.to_global(LEFT_EYE_MODEL))
	var right_in_skeleton := _skeleton.to_local(
		_model.to_global(RIGHT_EYE_MODEL))
	_left_eye_in_head = rest.affine_inverse() * left_in_skeleton
	_right_eye_in_head = rest.affine_inverse() * right_in_skeleton
	_eyes_bound = true


func _eye_positions() -> Array[Vector3]:
	if _eyes_bound and _skeleton != null and _head_bone >= 0:
		var head := _skeleton.global_transform \
			* _skeleton.get_bone_global_pose(_head_bone)
		return [
			head * _left_eye_in_head,
			head * _right_eye_in_head,
		]
	if _model != null:
		return [
			_model.to_global(LEFT_EYE_MODEL),
			_model.to_global(RIGHT_EYE_MODEL),
		]
	return [
		combat_position() - global_basis.x * 0.5,
		combat_position() + global_basis.x * 0.5,
	]


func _build_summon_particles() -> void:
	_summon_particles = GPUParticles3D.new()
	_summon_particles.name = "CalderaEruption"
	_summon_particles.top_level = true
	_summon_particles.amount = 190
	_summon_particles.lifetime = 1.75
	_summon_particles.one_shot = true
	_summon_particles.explosiveness = 0.86
	_summon_particles.randomness = 0.58
	_summon_particles.local_coords = true
	_summon_particles.emitting = false
	_summon_particles.visibility_aabb = AABB(
		Vector3(-45.0, -8.0, -45.0), Vector3(90.0, 110.0, 90.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 15.0
	process.direction = Vector3.UP
	process.spread = 48.0
	process.initial_velocity_min = 18.0
	process.initial_velocity_max = 54.0
	process.gravity = Vector3(0.0, -19.0, 0.0)
	process.scale_min = 0.8
	process.scale_max = 3.8
	process.color = Color(1.0, 0.16, 0.02, 0.92)
	_summon_particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.8)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(1.0, 0.19, 0.02, 0.86)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.08, 0.01)
	material.emission_energy_multiplier = 4.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = material
	_summon_particles.draw_pass_1 = quad
	add_child(_summon_particles, false, Node.INTERNAL_MODE_BACK)


func _burst_summon() -> void:
	if _summon_particles == null:
		return
	var up := _surface_up(_site_direction)
	_summon_particles.global_transform = Transform3D(
		_upright_basis(_tangent_east(_site_direction), up),
		_caldera_point)
	_summon_particles.restart()


func _build_trial_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "CalderaTrialLayer"
	layer.layer = 76
	add_child(layer, false, Node.INTERNAL_MODE_BACK)
	_trial_hud = TRIAL_HUD.new()
	layer.add_child(_trial_hud)


func _update_presentation(delta: float) -> void:
	if _animator != null and _animator.has_animation(_clip):
		var looping := _animator.get_animation(_clip).loop_mode \
			!= Animation.LOOP_NONE
		var restart := _clip_playing != _clip \
			or (looping and _animator.current_animation.is_empty())
		if restart:
			_clip_playing = _clip
			_animator.play(_clip, CLIP_BLEND)
		if _clip_seek >= 0.0:
			if restart:
				var length := _animator.get_animation(_clip).length
				_animator.seek(clampf(_clip_seek, 0.0, length), true)
			_clip_seek = -1.0
		_animator.speed_scale = _clip_speed
	if _model != null:
		_model.visible = _stage >= Stage.SUMMONING
	if _laser_beams != null:
		if _stage == Stage.LASER and _stage_time >= LASER_TELEGRAPH \
				and _stage_time <= LASER_END:
			var eyes := _eye_positions()
			_laser_beams.call(
				&"aim", eyes[0], eyes[1],
				_laser_endpoint((eyes[0] + eyes[1]) * 0.5), LASER_COLOR)
		else:
			_laser_beams.call(&"stop")
	_update_trial_presentation(delta)


func _update_trial_presentation(delta: float) -> void:
	if _trial_hud == null:
		return
	var local := _local_player()
	var shown := _stage == Stage.TRIAL \
		and local != null and _player_grounded_on_volcano(local)
	var moving := shown and _player_moving_for_trial(local)
	_trial_hud.call(
		&"set_trial", shown, _trial_remaining, moving)
	if not shown:
		_trial_rumble_left = 0.0
		return
	_trial_rumble_left -= delta
	if _trial_rumble_left <= 0.0:
		_trial_rumble_left = 0.24
		if local.has_method(&"camera_shake"):
			local.call(&"camera_shake", 0.17, 0.20)


func _laser_endpoint(from: Vector3) -> Vector3:
	var along := _laser_aim - from
	if along.length_squared() < 0.01:
		along = -global_basis.z
	return _laser_aim + along.normalized() * LASER_EXTENSION


func _play_clip(clip: String, speed := 1.0) -> void:
	_clip = clip
	_clip_speed = speed


func _animation_position() -> float:
	if _animator == null or _animator.current_animation.is_empty():
		return 0.0
	return _animator.current_animation_position


func _set_collision_enabled(enabled: bool) -> void:
	if _collision == null:
		return
	var disabled := not enabled
	if _collision.disabled != disabled:
		_collision.set_deferred(&"disabled", disabled)


# --- Planet, geometry, and player helpers ----------------------------------

func _planet() -> Planet:
	if is_instance_valid(_cached_planet):
		return _cached_planet
	var walk: Node = self
	while walk != null:
		if walk is Planet:
			_cached_planet = walk as Planet
			return _cached_planet
		walk = walk.get_parent()
	return null


func _world() -> GameWorld:
	return DamageHit.game_world_of(self)


func _surface_point(direction: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return global_position
	return planet.to_global(planet.shape.surface_point(
		direction.normalized(), planet.finest_spacing()))


func _surface_up(direction: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null:
		return Vector3.UP
	var inner := planet.to_global(direction.normalized())
	var outer := planet.to_global(direction.normalized() * 2.0)
	return (outer - inner).normalized()


func _planet_up_at(point: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null:
		return global_basis.y.normalized()
	var local := planet.to_local(point)
	return _surface_up(local.normalized()) \
		if local.length_squared() > 0.001 else global_basis.y.normalized()


func _point_at_altitude(point: Vector3, altitude: float) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return point
	var local := planet.to_local(point)
	if local.length_squared() < 1.0:
		return point
	var direction := _clamp_direction_to_arena(local.normalized())
	return _surface_point(direction) + _surface_up(direction) * altitude


func _root_for_combat_point(point: Vector3, up: Vector3) -> Vector3:
	var root := point - up.normalized() * BODY_CENTRE_HEIGHT
	var planet := _planet()
	if planet == null or planet.shape == null:
		return root
	var local := planet.to_local(root)
	if local.length_squared() < 1.0:
		return root
	var direction := _clamp_direction_to_arena(local.normalized())
	var surface := _surface_point(direction)
	var height := maxf((root - surface).dot(_surface_up(direction)), 1.2)
	return surface + _surface_up(direction) * height


func _clamp_point_to_arena(point: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return point
	var local := planet.to_local(point)
	if local.length_squared() < 1.0:
		return point
	var span := local.length()
	var original_direction := local.normalized()
	var direction := _clamp_direction_to_arena(original_direction)
	if direction.is_equal_approx(original_direction):
		return point
	return planet.to_global(direction * span)


func _clamp_direction_to_arena(direction: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return direction.normalized()
	direction = direction.normalized()
	var limit := (ARENA_RADIUS - ARENA_INSET) / planet.shape.radius
	var angle := _site_direction.angle_to(direction)
	if angle <= limit:
		return direction
	var axis := _site_direction.cross(direction)
	if axis.length_squared() < 0.000001:
		axis = _site_direction.cross(_tangent_east(_site_direction))
	return (Basis(axis.normalized(), limit) * _site_direction).normalized()


func _upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.001:
		var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
		forward = hint - up * hint.dot(up)
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(right, up, right.cross(up).normalized()).orthonormalized()


func _tangent_east(up: Vector3) -> Vector3:
	var hint := Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT
	return up.cross(hint).normalized()


func _ease(value: float) -> float:
	value = clampf(value, 0.0, 1.0)
	return value * value * (3.0 - 2.0 * value)


func _next_attack_wait() -> float:
	var share := float(posmod(_attack_sequence * 47 + 11, 101)) / 100.0
	return lerpf(ATTACK_WAIT_MIN, ATTACK_WAIT_MAX, share)


func _living_players_in_world() -> Array:
	_players_buffer.clear()
	var world := _world()
	if world == null:
		return _players_buffer
	for peer_id: Variant in world._spawned_players:
		var player := world._spawned_players[peer_id] as Node
		if player == null or not is_instance_valid(player) or _player_dead(player):
			continue
		_players_buffer.append(player)
	return _players_buffer


func _pick_target() -> void:
	var best: Node = null
	var best_distance := INF
	for player: Node in _living_players_in_world():
		if arena_distance_to(player as Node3D) > ARENA_RADIUS:
			continue
		var distance := combat_position().distance_to(_combat_position(player))
		if distance < best_distance:
			best_distance = distance
			best = player
	_target_peer = _peer_id(best)


func _target_player() -> Node:
	return _player_by_peer(_target_peer)


func _player_by_peer(peer_id: int) -> Node:
	if peer_id <= 0:
		return null
	var world := _world()
	return world._spawned_players.get(peer_id) as Node if world != null else null


func _local_player() -> Node:
	var peer := multiplayer.get_unique_id() \
		if multiplayer.has_multiplayer_peer() else 1
	var player := _player_by_peer(peer)
	if player != null:
		return player
	var players := _living_players_in_world()
	return players[0] as Node if players.size() == 1 else null


func _peer_id(player: Node) -> int:
	if player == null:
		return 0
	if player.has_method(&"combat_peer_id"):
		return int(player.call(&"combat_peer_id"))
	var value: Variant = player.get("peer_id")
	return int(value) if value != null else 0


func _player_dead(player: Node) -> bool:
	return player != null and player.has_method(&"is_dead") \
		and bool(player.call(&"is_dead"))


func _player_speed(player: Node) -> float:
	return (player as CharacterBody3D).velocity.length() \
		if player is CharacterBody3D else 0.0


func _combat_position(player: Node) -> Vector3:
	if player == null:
		return Vector3.ZERO
	if player.has_method(&"combat_position"):
		var value: Variant = player.call(&"combat_position")
		if value is Vector3:
			return value
	return (player as Node3D).global_position if player is Node3D \
		else Vector3.ZERO


func _combat_radius(player: Node) -> float:
	if player != null and player.has_method(&"combat_radius"):
		return maxf(float(player.call(&"combat_radius")), 0.0)
	return 0.5
