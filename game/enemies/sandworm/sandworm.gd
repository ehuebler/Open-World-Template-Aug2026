class_name SandwormBoss
extends BossController

## Host-authoritative desert boss. It travels below the collision surface,
## erupts beside a player, crosses their position in a high bite arc, and dives
## back into the sand. Clients only interpolate snapshots and present the same
## authored clips/VFX; health, target choice, hits, and encounter reset live on
## the host.

signal health_changed(current: float, maximum: float)
signal engaged_changed(engaged: bool)
signal damaged_flash(strength: float)
signal arena_reset

enum State {
	BURIED,
	EMERGE,
	LEAP,
	DIVE,
	DEFEATED,
}

const BOSS_SPEC := preload(
	"res://game/enemies/boss/generated/sandworm_spec.gd")
const GROUP := &"bosses"
const LEGACY_GROUP := &"sandworm_boss"
const DISPLAY_NAME := BOSS_SPEC.DISPLAY_NAME
const BOSS_ID := BOSS_SPEC.BOSS_ID

const ARENA_BOUNDARY := preload(
	"res://game/enemies/bigfoot/bigfoot_arena_boundary.gd")
const ARC_MODIFIER := preload(
	"res://game/enemies/sandworm/sandworm_arc_modifier.gd")
const ATTACK_ARC := preload(
	"res://game/enemies/sandworm/sandworm_attack_arc.gd")
const RIM_SURFACE := preload(
	"res://game/enemies/sandworm/sandworm_surface.tres")

const MAX_HEALTH := BOSS_SPEC.MAX_HEALTH
## Wide enough that a boosted flight spends long enough inside the territory for
## the invisible intercept and eruption to complete, even on a grazing pass.
const ARENA_RADIUS := BOSS_SPEC.ARENA_RADIUS
const DETECT_RADIUS := BOSS_SPEC.DETECT_RADIUS
const RESET_DEBOUNCE := BOSS_SPEC.RESET_DELAY
const SYNC_INTERVAL := 1.0 / 20.0

## The source coil is 120 m across; every runtime clip extends it to 369 m.
const BURROW_DEPTH := 90.0
const PATROL_SPEED := 72.0
## Never directly below the target. Every launch is an unseen angled intercept.
const AMBUSH_MIN := 55.0
const AMBUSH_MAX := 145.0
const AMBUSH_REACHED := 5.0
const EMERGE_DURATION := 0.72
const EMERGE_BURST_SHARE := 0.58
const LEAP_DURATION := 1.05
const DIVE_DURATION := 0.52
const BITE_CLIP_AT := 0.08
const BITE_WINDOW_START := 0.10
const BITE_WINDOW_END := 0.88
const BITE_PATH_AT := 0.52
const BODY_CENTRE_HEIGHT := 42.0
const BITE_MOUTH_HEIGHT := 67.0
const COMBAT_RADIUS := 58.0
const BITE_RADIUS := 52.0
const BITE_DAMAGE := 58.0
const BITE_KNOCKBACK := 34.0
const BITE_LIFT := 21.0
const BITE_REFLECT := 90.0
## Preview/emerge plus the travel to BITE_PATH_AT is about 1.27 seconds.
const TARGET_LEAD := 1.25
const MAX_FLYING_BITE_ALTITUDE := 2200.0
const LEAP_OVERSHOOT := 180.0
const ATTACK_WAIT_MIN := 0.55
const ATTACK_WAIT_MAX := 0.95
const VULNERABLE_DEPTH := -36.0
const MOUTH_BONE_OFFSET := 6.55
const CLIP_BLEND := 0.10
const ARC_SAMPLES := 64

const CLIP_IDLE := BOSS_SPEC.ANIMATIONS["rest"]
const CLIP_BURROW := BOSS_SPEC.ANIMATIONS["burrow"]
const CLIP_EMERGE := BOSS_SPEC.ANIMATIONS["emerge"]
const CLIP_LEAP := BOSS_SPEC.ANIMATIONS["leap"]
const CLIP_BITE := BOSS_SPEC.ANIMATIONS["bite"]
const CLIP_DIVE := BOSS_SPEC.ANIMATIONS["dive"]
const CLIP_HIT_REACT := BOSS_SPEC.ANIMATIONS["hit_react"]
const CLIP_DEFEAT := BOSS_SPEC.ANIMATIONS["defeat"]

@export var mouth_marker := NodePath("Mouth")

var _health := MAX_HEALTH
var _engaged := false
var _defeated := false
var _state := State.BURIED
var _state_time := 0.0
var _arena_empty_time := 0.0
var _target_peer := 0
var _attack_sequence := 0
var _attack_wait := 0.0
var _model_depth := -BURROW_DEPTH
var _spawn_transform := Transform3D.IDENTITY
var _site_direction := Vector3.UP
var _burrow_goal := Vector3.INF
var _patrol_step := 0
var _emerge_burst_done := false

var _leap_start := Vector3.ZERO
var _leap_control := Vector3.ZERO
var _leap_end := Vector3.ZERO
var _leap_planned := false
var _attack_curve := PackedVector3Array()
var _bite_from := Vector3.ZERO
var _bite_hit_peers: Dictionary = {}

var _clip := CLIP_BURROW
var _clip_speed := 1.0
var _clip_playing := ""
var _clip_seek := -1.0
var _animator: AnimationPlayer
var _skeleton: Skeleton3D
var _head_bone := -1
var _model: Node3D
var _mouth: Marker3D
var _collision: CollisionShape3D
var _arena_boundary: Node3D
var _arc_modifier: Node
var _attack_arc: MeshInstance3D
var _sand_particles: GPUParticles3D
var _sand_ripple: MeshInstance3D

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
	var site := get_parent()
	if site != null and site.get(&"direction") is Vector3:
		_site_direction = (site.get(&"direction") as Vector3).normalized()
	call_deferred(&"_capture_spawn")
	if _is_host():
		_publish_sync(true)
	else:
		_target_transform = global_transform
		_has_target_transform = true


func _capture_spawn() -> void:
	if not is_inside_tree():
		return
	_level_to_surface()
	_snap_to_surface()
	_spawn_transform = global_transform
	var planet := _planet()
	if is_instance_valid(_arena_boundary) and planet != null \
			and planet.shape != null:
		var local := planet.to_local(_spawn_transform.origin)
		if local.length_squared() > 0.5:
			_arena_boundary.call(
				&"configure", planet, local.normalized(), ARENA_RADIUS)
	_choose_patrol_goal()
	_apply_model_depth()


func _physics_process(delta: float) -> void:
	if not RuntimeTelemetry.deep_enabled():
		_tick(delta)
		return
	var began := Time.get_ticks_usec()
	_tick(delta)
	RuntimeTelemetry.record_physics_step(
		&"bosses", &"sandworm_tick", Time.get_ticks_usec() - began)


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
	if _defeated:
		velocity = Vector3.ZERO
		return
	_update_arena_presence(delta)
	var target := _target_player()
	# Once an eruption starts, keep the selected fly-by target through the bite.
	# Dropping it the instant its surface projection crossed the arena edge made
	# the worm visibly rise and then cancel against the fastest players.
	if _engaged and _state == State.BURIED and (target == null \
			or arena_distance_to(target as Node3D) > ARENA_RADIUS):
		_pick_target()
		target = _target_player()

	match _state:
		State.BURIED:
			_tick_buried(delta, target)
		State.EMERGE:
			_tick_emerge(delta, target)
		State.LEAP:
			_tick_leap(delta)
		State.DIVE:
			_tick_dive(delta, target)
		State.DEFEATED:
			pass


func _client_tick(delta: float) -> void:
	if not _has_target_transform:
		return
	var step := clampf(delta * 14.0, 0.0, 1.0)
	global_transform = global_transform.interpolate_with(_target_transform, step)
	velocity = _target_velocity


func _update_arena_presence(delta: float) -> void:
	var any_inside := false
	var any_detected := false
	for player: Node in _living_players_in_world():
		var distance := arena_distance_to(player as Node3D)
		any_inside = any_inside or distance <= ARENA_RADIUS
		any_detected = any_detected or distance <= DETECT_RADIUS
	if not _engaged:
		_arena_empty_time = 0.0
		if any_detected:
			_begin_aggro()
		return
	if any_inside:
		_arena_empty_time = 0.0
		return
	_arena_empty_time += delta
	if _arena_empty_time >= RESET_DEBOUNCE:
		_reset_arena()


func _begin_aggro() -> void:
	_engaged = true
	_arena_empty_time = 0.0
	_attack_wait = 0.0
	_pick_target()
	var target := _target_player()
	if target != null:
		_choose_ambush(target)
		_warp_to_burrow_goal(target)
		if _plan_leap(target):
			_begin_emerge()
	engaged_changed.emit(true)
	_publish_sync(true)


func _reset_arena() -> void:
	set_arena_boundary_visible(false)
	_health = MAX_HEALTH
	_engaged = false
	_defeated = false
	_state = State.BURIED
	_state_time = 0.0
	_arena_empty_time = 0.0
	_target_peer = 0
	_attack_wait = 0.0
	_model_depth = -BURROW_DEPTH
	_burrow_goal = Vector3.INF
	_leap_planned = false
	_attack_curve = PackedVector3Array()
	_bite_hit_peers.clear()
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_play_clip(CLIP_BURROW)
	_set_collision_enabled(false)
	_choose_patrol_goal()
	_apply_model_depth()
	health_changed.emit(_health, MAX_HEALTH)
	engaged_changed.emit(false)
	arena_reset.emit()
	_publish_event({"kind": "reset"})
	_publish_sync(true)


func _tick_buried(delta: float, target: Node) -> void:
	_state_time += delta
	_attack_wait = maxf(_attack_wait - delta, 0.0)
	_model_depth = -BURROW_DEPTH
	_set_collision_enabled(false)
	if not _engaged or target == null:
		if not _burrow_goal.is_finite() \
				or global_position.distance_to(_burrow_goal) < AMBUSH_REACHED:
			_choose_patrol_goal()
		_move_over_surface(_burrow_goal, PATROL_SPEED, delta)
		return
	if _attack_wait > 0.0:
		return
	# There is deliberately no travelling wake. Re-solve from the target's
	# newest velocity, relocate below the opaque terrain, and erupt immediately.
	_choose_ambush(target)
	_warp_to_burrow_goal(target)
	if _plan_leap(target):
		_begin_emerge()


func _begin_emerge() -> void:
	_state = State.EMERGE
	_state_time = 0.0
	_model_depth = -BURROW_DEPTH
	velocity = Vector3.ZERO
	_bite_hit_peers.clear()
	_emerge_burst_done = false
	_play_clip(CLIP_EMERGE)
	_publish_sync(true)


func _tick_emerge(delta: float, target: Node) -> void:
	_state_time += delta
	var share := clampf(_state_time / EMERGE_DURATION, 0.0, 1.0)
	share = _ease(share)
	_model_depth = lerpf(-BURROW_DEPTH, 0.0, share)
	_set_collision_enabled(_model_depth >= VULNERABLE_DEPTH)
	_face_target(target, delta, 5.0)
	if not _emerge_burst_done and share >= EMERGE_BURST_SHARE:
		_emerge_burst_done = true
		_burst_sand()
		_publish_event({"kind": "burst"})
	if share >= 1.0:
		_begin_leap(target)


func _plan_leap(target: Node) -> bool:
	_leap_planned = false
	_attack_curve = PackedVector3Array()
	var planet := _planet()
	if target == null or planet == null or planet.shape == null:
		return false
	_leap_start = global_position
	var target_point := _combat_position(target)
	if target is CharacterBody3D:
		target_point += (target as CharacterBody3D).velocity * TARGET_LEAD
	var target_local := planet.to_local(target_point)
	if target_local.length_squared() < 1.0:
		return false
	var target_direction := target_local.normalized()
	var target_ground := _surface_point(target_direction)
	var target_up := _surface_up(target_direction)
	var altitude := clampf(
		(target_point - target_ground).dot(target_up),
		1.2, MAX_FLYING_BITE_ALTITUDE)
	var desired_bite := target_ground + target_up * altitude
	var desired_root := desired_bite - target_up * BITE_MOUTH_HEIGHT

	var start_direction := planet.to_local(_leap_start).normalized()
	var axis := start_direction.cross(target_direction)
	if axis.length_squared() < 0.000001:
		axis = target_direction.cross(_tangent_east(target_direction))
	var end_direction := (
		Basis(axis.normalized(), LEAP_OVERSHOOT / planet.shape.radius)
		* target_direction
	).normalized()
	_leap_end = _clamp_to_arena(_surface_point(end_direction))
	var one_minus := 1.0 - BITE_PATH_AT
	var denominator := 2.0 * one_minus * BITE_PATH_AT
	_leap_control = (
		desired_root
		- _leap_start * (one_minus * one_minus)
		- _leap_end * (BITE_PATH_AT * BITE_PATH_AT)
	) / denominator
	_leap_planned = true
	_refresh_attack_curve()
	return true


func _begin_leap(target: Node) -> void:
	if not _leap_planned and not _plan_leap(target):
		_begin_dive()
		return
	_state = State.LEAP
	_state_time = 0.0
	_model_depth = 0.0
	_set_collision_enabled(true)
	_bite_hit_peers.clear()
	_attack_sequence += 1
	_bite_from = _bite_position()
	_play_clip(CLIP_LEAP)
	_publish_sync(true)


func _refresh_attack_curve() -> void:
	_attack_curve = PackedVector3Array()
	if not _leap_planned:
		return
	for index in range(ARC_SAMPLES + 1):
		var share := float(index) / float(ARC_SAMPLES)
		var root := _leap_root_at(share)
		_attack_curve.append(
			root + _planet_up_at(root) * BITE_MOUTH_HEIGHT)


func _leap_root_at(share: float) -> Vector3:
	var amount := clampf(share, 0.0, 1.0)
	var one_minus := 1.0 - amount
	return _leap_start * (one_minus * one_minus) \
		+ _leap_control * (2.0 * one_minus * amount) \
		+ _leap_end * (amount * amount)


func _tick_leap(delta: float) -> void:
	var previous := _bite_position()
	var previous_origin := global_position
	_state_time += delta
	var share := clampf(_state_time / LEAP_DURATION, 0.0, 1.0)
	var one_minus := 1.0 - share
	var point := _leap_root_at(share)
	var derivative := (_leap_control - _leap_start) * (2.0 * one_minus) \
		+ (_leap_end - _leap_control) * (2.0 * share)
	global_position = point
	var up := _planet_up_at(point)
	global_basis = _upright_basis(derivative, up)
	velocity = (global_position - previous_origin) / maxf(delta, 0.001)
	_update_mouth_marker()

	if share >= BITE_CLIP_AT and _clip != CLIP_BITE:
		_play_clip(CLIP_BITE)
	if share >= BITE_WINDOW_START and share <= BITE_WINDOW_END:
		var current := _bite_position()
		_sweep_bite(previous, current)
		_bite_from = current
	if share >= 1.0:
		global_position = _leap_end
		_snap_to_surface()
		_begin_dive()


func _sweep_bite(from: Vector3, to: Vector3) -> void:
	var volume := DamageHit.beam(from, to, BITE_RADIUS, BITE_DAMAGE)
	for player: Node in _living_players_in_world():
		var peer := _peer_id(player)
		if _bite_hit_peers.has(peer) \
				or not volume.reaches(_combat_position(player), _combat_radius(player)):
			continue
		_bite_hit_peers[peer] = true
		var along := to - from
		if along.length_squared() < 0.01:
			along = _flat_on_surface(_combat_position(player) - from)
		along = along.normalized() if along.length_squared() > 0.001 \
			else -global_basis.z
		var hit := DamageHit.impact(
			_combat_position(player), BITE_RADIUS, BITE_DAMAGE)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = peer
		hit.reaction = DamageHit.Reaction.RAGDOLL
		hit.world_impulse = along * BITE_KNOCKBACK + _up() * BITE_LIFT
		hit.parryable = true
		hit.reflection = BITE_REFLECT
		hit.ability_id = "sandworm_bite"
		hit.set_source(self)
		if player.has_method(&"apply_damage"):
			player.call(&"apply_damage", hit)


func _begin_dive() -> void:
	_state = State.DIVE
	_state_time = 0.0
	_model_depth = 0.0
	velocity = Vector3.ZERO
	_play_clip(CLIP_DIVE)
	_burst_sand()
	_publish_event({"kind": "burst"})
	_publish_sync(true)


func _tick_dive(delta: float, target: Node) -> void:
	_state_time += delta
	var share := _ease(clampf(_state_time / DIVE_DURATION, 0.0, 1.0))
	_model_depth = lerpf(0.0, -BURROW_DEPTH, share)
	_set_collision_enabled(_model_depth >= VULNERABLE_DEPTH)
	if share < 1.0:
		return
	_state = State.BURIED
	_state_time = 0.0
	_model_depth = -BURROW_DEPTH
	_set_collision_enabled(false)
	_attack_wait = _next_attack_wait()
	_leap_planned = false
	_attack_curve = PackedVector3Array()
	_play_clip(CLIP_BURROW)
	_burrow_goal = Vector3.INF
	if target == null:
		_choose_patrol_goal()
	_publish_sync(true)


func _choose_ambush(target: Node) -> void:
	var planet := _planet()
	if planet == null or planet.shape == null or target == null:
		_burrow_goal = _spawn_transform.origin
		return
	var predicted := _combat_position(target)
	if target is CharacterBody3D:
		predicted += (target as CharacterBody3D).velocity * TARGET_LEAD
	var local := planet.to_local(predicted)
	if local.length_squared() < 1.0:
		_burrow_goal = _spawn_transform.origin
		return
	_attack_sequence += 1
	var centre := local.normalized()
	var east := _tangent_east(centre)
	var north := centre.cross(east).normalized()
	var seed := posmod(_attack_sequence * 197 + 53, 997)
	var angle := TAU * float(seed) / 997.0
	var radial := east * cos(angle) + north * sin(angle)
	var distance := lerpf(
		AMBUSH_MIN, AMBUSH_MAX,
		float(posmod(_attack_sequence * 73, 101)) / 100.0)
	var direction := (
		centre * cos(distance / planet.shape.radius)
		+ radial * sin(distance / planet.shape.radius)
	).normalized()
	_burrow_goal = _clamp_to_arena(_surface_point(direction))


func _warp_to_burrow_goal(target: Node) -> void:
	if not _burrow_goal.is_finite():
		return
	global_position = _burrow_goal
	var up := _planet_up_at(global_position)
	var forward := _combat_position(target) - global_position \
		if target != null else -global_basis.z
	forward -= up * forward.dot(up)
	global_basis = _upright_basis(forward, up)
	velocity = Vector3.ZERO


func _choose_patrol_goal() -> void:
	var planet := _planet()
	if planet == null or planet.shape == null:
		_burrow_goal = _spawn_transform.origin
		return
	_patrol_step += 1
	var centre_local := planet.to_local(_spawn_transform.origin)
	if centre_local.length_squared() < 1.0:
		_burrow_goal = _spawn_transform.origin
		return
	var centre := centre_local.normalized()
	var east := _tangent_east(centre)
	var north := centre.cross(east).normalized()
	var angle := wrapf(float(_patrol_step) * 2.399963, 0.0, TAU)
	var distance := 32.0 + float(posmod(_patrol_step * 31, 46))
	var radial := east * cos(angle) + north * sin(angle)
	var direction := (
		centre * cos(distance / planet.shape.radius)
		+ radial * sin(distance / planet.shape.radius)
	).normalized()
	_burrow_goal = _surface_point(direction)


func _move_over_surface(goal: Vector3, speed: float, delta: float) -> void:
	if not goal.is_finite():
		return
	var planet := _planet()
	if planet == null or planet.shape == null:
		var along := goal - global_position
		var step := minf(along.length(), speed * delta)
		if along.length_squared() > 0.001:
			global_position += along.normalized() * step
		return
	var from_local := planet.to_local(global_position)
	var goal_local := planet.to_local(goal)
	if from_local.length_squared() < 1.0 or goal_local.length_squared() < 1.0:
		return
	var from_direction := from_local.normalized()
	var goal_direction := goal_local.normalized()
	var angle := from_direction.angle_to(goal_direction)
	if angle < 0.000001:
		global_position = _surface_point(goal_direction)
		velocity = Vector3.ZERO
		return
	var axis := from_direction.cross(goal_direction)
	if axis.length_squared() < 0.000001:
		axis = from_direction.cross(_tangent_east(from_direction))
	var turn := minf(angle, speed * delta / planet.shape.radius)
	var next_direction := (
		Basis(axis.normalized(), turn) * from_direction
	).normalized()
	var previous := global_position
	global_position = _surface_point(next_direction)
	var forward := _flat_on_surface(goal - global_position)
	global_basis = _upright_basis(forward, _surface_up(next_direction))
	velocity = (global_position - previous) / maxf(delta, 0.001)


func _clamp_to_arena(point: Vector3) -> Vector3:
	var planet := _planet()
	if planet == null or planet.shape == null:
		var flat := _flat_on_surface(point - _spawn_transform.origin)
		if flat.length() <= ARENA_RADIUS:
			return point
		return _spawn_transform.origin + flat.normalized() * ARENA_RADIUS
	var centre_local := planet.to_local(_spawn_transform.origin)
	var point_local := planet.to_local(point)
	if centre_local.length_squared() < 1.0 or point_local.length_squared() < 1.0:
		return point
	var centre := centre_local.normalized()
	var direction := point_local.normalized()
	var angle := centre.angle_to(direction)
	var limit := (ARENA_RADIUS - 5.0) / planet.shape.radius
	if angle <= limit:
		return point
	var axis := centre.cross(direction)
	if axis.length_squared() < 0.000001:
		axis = centre.cross(_tangent_east(centre))
	var clamped := (Basis(axis.normalized(), limit) * centre).normalized()
	return _surface_point(clamped)


# --- Public boss/combat API -------------------------------------------------

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
	return global_position + _up() * maxf(
		BODY_CENTRE_HEIGHT + _model_depth, 0.2)


func combat_radius() -> float:
	return COMBAT_RADIUS


func _bite_position() -> Vector3:
	# Collision and the procedural head use the same replicated interception
	# curve. Bone modifiers are evaluated after animation, so the marker is
	# intentionally presentation-only and never moves authoritative damage.
	return global_position + _up() * maxf(
		BITE_MOUTH_HEIGHT + _model_depth, 0.2)


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
	var centre := planet.to_local(_spawn_transform.origin)
	var point := planet.to_local(body.global_position)
	if centre.length_squared() < 1.0 or point.length_squared() < 1.0:
		return INF
	return centre.normalized().angle_to(point.normalized()) * planet.shape.radius


func apply_damage(hit: DamageHit) -> float:
	if hit == null or not _is_host() or _defeated or not _vulnerable():
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
	if not _engaged:
		_begin_aggro()
	if _health <= 0.0:
		_defeat()
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


func _vulnerable() -> bool:
	return _state == State.LEAP \
		or (_state == State.EMERGE and _model_depth >= VULNERABLE_DEPTH) \
		or (_state == State.DIVE and _model_depth >= VULNERABLE_DEPTH)


func _defeat() -> void:
	_defeated = true
	_state = State.DEFEATED
	_state_time = 0.0
	_model_depth = 0.0
	velocity = Vector3.ZERO
	_snap_to_surface()
	_set_collision_enabled(false)
	set_arena_boundary_visible(false)
	_play_clip(CLIP_DEFEAT)
	_burst_sand()
	_publish_event({"kind": "defeated"})
	_publish_sync(true)


func flash_damage(strength := 1.0) -> void:
	damaged_flash.emit(clampf(strength, 0.0, 1.0))


func boss_snapshot() -> Dictionary:
	return {
		"boss_id": BOSS_ID,
		"health": _health,
		"maximum_health": MAX_HEALTH,
		"engaged": _engaged,
		"defeated": _defeated,
		"state": _state,
		"state_time": _state_time,
		"target_peer": _target_peer,
		"transform": global_transform,
		"velocity": velocity,
		"model_depth": _model_depth,
		"clip": _clip,
		"clip_speed": _clip_speed,
		"clip_position": _animation_position(),
		"leap_start": _leap_start,
		"leap_control": _leap_control,
		"leap_end": _leap_end,
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
	_engaged = bool(wire.get("engaged", _engaged))
	_defeated = bool(wire.get("defeated", _defeated))
	_state = clampi(int(wire.get("state", _state)), 0, State.DEFEATED)
	_state_time = maxf(float(wire.get("state_time", _state_time)), 0.0)
	_target_peer = int(wire.get("target_peer", _target_peer))
	_model_depth = clampf(
		float(wire.get("model_depth", _model_depth)), -BURROW_DEPTH, 0.0)
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
	var previous_clip := _clip
	_clip = String(wire.get("clip", _clip))
	_clip_speed = clampf(float(wire.get("clip_speed", 1.0)), 0.1, 3.0)
	if _clip != previous_clip or _clip_playing != _clip:
		_clip_seek = maxf(float(wire.get("clip_position", 0.0)), 0.0)
	for key: String in ["leap_start", "leap_control", "leap_end"]:
		var value: Variant = wire.get(key)
		if value is Vector3 and (value as Vector3).is_finite():
			set("_" + key, value)
	_leap_planned = _state == State.EMERGE \
		or _state == State.LEAP or _state == State.DIVE
	if _leap_planned:
		_refresh_attack_curve()
	else:
		_attack_curve = PackedVector3Array()
	if was_engaged != _engaged:
		engaged_changed.emit(_engaged)


# --- Networking -------------------------------------------------------------

func _publish_sync(reliable: bool) -> void:
	if not _has_listeners():
		return
	_sync_sequence += 1
	var wire := boss_snapshot()
	wire["sync_sequence"] = _sync_sequence
	if reliable:
		_apply_sandworm_sync_reliable.rpc(_sync_sequence, wire)
	else:
		_apply_sandworm_sync.rpc(_sync_sequence, wire)


func _publish_event(event: Dictionary) -> void:
	_event_sequence += 1
	event["sequence"] = _event_sequence
	if not _has_listeners():
		_apply_sandworm_event(_event_sequence, event)
	else:
		_apply_sandworm_event.rpc(_event_sequence, event)


@rpc("authority", "call_local", "unreliable_ordered")
func _apply_sandworm_sync(sequence: int, wire: Dictionary) -> void:
	if _is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_local", "reliable")
func _apply_sandworm_sync_reliable(sequence: int, wire: Dictionary) -> void:
	if _is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_local", "reliable")
func _apply_sandworm_event(sequence: int, event: Dictionary) -> void:
	if sequence <= _last_event_sequence:
		return
	_last_event_sequence = sequence
	match String(event.get("kind", "")):
		"damaged":
			var amount := float(event.get("amount", 0.0))
			flash_damage(clampf(amount / 100.0, 0.2, 1.0))
		"burst", "defeated":
			_burst_sand()
		"reset":
			arena_reset.emit()


func _has_listeners() -> bool:
	return multiplayer.has_multiplayer_peer() \
		and not multiplayer.get_peers().is_empty()


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


# --- Presentation -----------------------------------------------------------

func _bind_visuals() -> void:
	_model = get_node_or_null(^"Model") as Node3D
	if _model != null:
		_animator = _model.find_child(
			"AnimationPlayer", true, false) as AnimationPlayer
		_skeleton = _model.find_child("Skeleton3D", true, false) as Skeleton3D
		if _skeleton != null:
			_arc_modifier = ARC_MODIFIER.new()
			_arc_modifier.name = "AttackArcModifier"
			_skeleton.add_child(
				_arc_modifier, false, Node.INTERNAL_MODE_BACK)
		for node: Node in _model.find_children(
				"*", "MeshInstance3D", true, false):
			var body := node as MeshInstance3D
			body.material_override = RIM_SURFACE
			# Every clip extends the 120 m source coil to roughly 369 m. Keep the
			# skinned tail from being culled by the smaller bind-pose bounds.
			body.custom_aabb = AABB(
				Vector3(-90.0, -90.0, -90.0),
				Vector3(180.0, 260.0, 540.0))
	_mouth = get_node_or_null(mouth_marker) as Marker3D
	_collision = get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	if _animator != null:
		for clip_name: String in [CLIP_IDLE, CLIP_BURROW]:
			if _animator.has_animation(clip_name):
				_animator.get_animation(clip_name).loop_mode \
					= Animation.LOOP_LINEAR
	_arena_boundary = ARENA_BOUNDARY.new()
	_arena_boundary.name = "ArenaBoundary"
	add_child(_arena_boundary, false, Node.INTERNAL_MODE_BACK)
	_attack_arc = ATTACK_ARC.new()
	add_child(_attack_arc, false, Node.INTERNAL_MODE_BACK)
	_build_sand_fx()
	_set_collision_enabled(false)


func _build_sand_fx() -> void:
	_sand_ripple = MeshInstance3D.new()
	_sand_ripple.name = "EruptionRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 22.0
	torus.outer_radius = 39.0
	torus.rings = 12
	torus.ring_segments = 64
	_sand_ripple.mesh = torus
	_sand_ripple.position.y = 0.35
	_sand_ripple.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wake_material := StandardMaterial3D.new()
	wake_material.albedo_color = Color(0.72, 0.43, 0.18, 0.72)
	wake_material.roughness = 1.0
	wake_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wake_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sand_ripple.material_override = wake_material
	add_child(_sand_ripple, false, Node.INTERNAL_MODE_BACK)

	_sand_particles = GPUParticles3D.new()
	_sand_particles.name = "SandSpray"
	_sand_particles.amount = 180
	_sand_particles.lifetime = 1.15
	_sand_particles.randomness = 0.55
	_sand_particles.local_coords = true
	_sand_particles.visibility_aabb = AABB(
		Vector3(-65.0, -8.0, -65.0), Vector3(130.0, 105.0, 130.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 24.0
	process.direction = Vector3.UP
	process.spread = 68.0
	process.initial_velocity_min = 14.0
	process.initial_velocity_max = 40.0
	process.gravity = Vector3(0.0, -18.0, 0.0)
	process.scale_min = 1.8
	process.scale_max = 6.8
	process.color = Color(0.76, 0.46, 0.21, 0.82)
	_sand_particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(1.35, 1.35)
	var dust_material := StandardMaterial3D.new()
	dust_material.albedo_color = Color(0.82, 0.52, 0.27, 0.76)
	dust_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dust_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dust_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = dust_material
	_sand_particles.draw_pass_1 = quad
	add_child(_sand_particles, false, Node.INTERNAL_MODE_BACK)


func _update_presentation(_delta: float) -> void:
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
	_apply_model_depth()
	_update_attack_path_presentation()
	_update_mouth_marker()
	if _model != null:
		# Once the whole 84.7 m body is below a 90 m offset, drawing its 32k
		# triangles only asks the terrain depth buffer to reject them.
		_model.visible = _state != State.BURIED or _defeated
	# No travelling wake and no warning ring. Sand appears only once the body is
	# already breaking the surface, then again while it dives.
	var erupting := _state == State.EMERGE \
		and _model_depth >= -BURROW_DEPTH * (1.0 - EMERGE_BURST_SHARE)
	var sanding := erupting or _state == State.DIVE
	if _sand_ripple != null:
		_sand_ripple.visible = sanding and not _defeated
		var pulse := 1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.008)
		_sand_ripple.scale = Vector3(pulse, 1.0, pulse)
	if _sand_particles != null:
		_sand_particles.emitting = sanding and not _defeated
		_sand_particles.amount_ratio = 0.82 if erupting else 0.68


func _update_attack_path_presentation() -> void:
	if _leap_planned and _attack_curve.size() < 2:
		_refresh_attack_curve()
	var planet := _planet()
	var planet_center := planet.global_position \
		if planet != null else Vector3.ZERO
	var previewing := _state == State.EMERGE \
		and _leap_planned and not _defeated
	if _attack_arc != null:
		if previewing:
			_attack_arc.call(
				&"set_attack_curve", _attack_curve, planet_center)
		elif _attack_arc.visible:
			_attack_arc.call(&"clear_attack_curve")
	if _arc_modifier == null:
		return
	if _state == State.LEAP and _leap_planned:
		var progress := clampf(_state_time / LEAP_DURATION, 0.0, 1.0)
		_arc_modifier.call(
			&"set_attack_curve", _attack_curve, progress, planet_center)
	else:
		_arc_modifier.call(&"clear_attack_curve")


func _apply_model_depth() -> void:
	if _model != null:
		var at := _model.position
		at.y = _model_depth
		_model.position = at


func _update_mouth_marker() -> void:
	if _skeleton == null or _mouth == null:
		return
	if _head_bone < 0:
		_head_bone = _skeleton.find_bone("Head")
	if _head_bone < 0:
		return
	_mouth.global_transform = _skeleton.global_transform \
		* _skeleton.get_bone_global_pose(_head_bone) \
		* Transform3D(
			Basis.IDENTITY, Vector3(0.0, MOUTH_BONE_OFFSET, 0.0))


func _burst_sand() -> void:
	if _sand_particles != null:
		_sand_particles.amount_ratio = 1.0
		_sand_particles.restart()


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
	var should_be_disabled := not enabled
	if _collision.disabled != should_be_disabled:
		_collision.set_deferred(&"disabled", should_be_disabled)


# --- Planet/player helpers --------------------------------------------------

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
		return _up()
	var local := planet.to_local(point)
	return _surface_up(local.normalized()) \
		if local.length_squared() > 0.001 else _up()


func _snap_to_surface() -> void:
	var planet := _planet()
	if planet == null or planet.shape == null:
		return
	var local := planet.to_local(global_position)
	if local.length_squared() < 1.0:
		return
	global_position = _surface_point(local.normalized())
	var forward := _flat_on_surface(-global_basis.z)
	global_basis = _upright_basis(forward, _surface_up(local.normalized()))


func _level_to_surface() -> void:
	var planet := _planet()
	if planet == null:
		return
	var up := planet.up_at(global_position)
	if not up.is_finite() or up.length_squared() < 0.5:
		return
	global_basis = _upright_basis(-global_basis.z, up)


func _up() -> Vector3:
	return global_basis.y.normalized()


func _flat_on_surface(vector: Vector3) -> Vector3:
	var up := _up()
	return vector - up * vector.dot(up)


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


func _face_target(target: Node, delta: float, rate: float) -> void:
	if target == null:
		return
	var along := _flat_on_surface(_combat_position(target) - global_position)
	if along.length_squared() < 0.001:
		return
	var wanted := _upright_basis(along, _up())
	global_basis = global_basis.slerp(
		wanted, clampf(delta * rate, 0.0, 1.0)).orthonormalized()


func _next_attack_wait() -> float:
	var share := float(posmod(_attack_sequence * 47 + 11, 101)) / 100.0
	return lerpf(ATTACK_WAIT_MIN, ATTACK_WAIT_MAX, share)


func _ease(value: float) -> float:
	value = clampf(value, 0.0, 1.0)
	return value * value * (3.0 - 2.0 * value)


func _living_players_in_world() -> Array:
	_players_buffer.clear()
	var world := _world()
	if world == null:
		return _players_buffer
	for peer_id: Variant in world._spawned_players:
		var player := world._spawned_players[peer_id] as Node
		if player == null or not is_instance_valid(player):
			continue
		if player.has_method(&"is_dead") and bool(player.call(&"is_dead")):
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


func _peer_id(player: Node) -> int:
	if player == null:
		return 0
	if player.has_method(&"combat_peer_id"):
		return int(player.call(&"combat_peer_id"))
	var value: Variant = player.get("peer_id")
	return int(value) if value != null else 0


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
