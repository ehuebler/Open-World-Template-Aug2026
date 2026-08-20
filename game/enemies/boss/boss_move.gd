class_name BossMove
extends RefCounted

## Data-driven move lifecycle. Implementations should call the base lifecycle
## methods so elapsed time, cooldowns, targeting, and snapshots stay consistent.

var _move_owner: Node
var _move_data: Dictionary = {}
var _move_parameters: Dictionary = {}
var _move_active := false
var _move_elapsed := 0.0
var _move_cooldown_left := 0.0
var _move_target_peer := 0


func configure(owner: Node, move: Dictionary) -> BossMove:
	_move_owner = owner
	_move_data = move.duplicate(true)
	var raw_parameters: Variant = _move_data.get("parameters", {})
	_move_parameters = (raw_parameters as Dictionary).duplicate(true) \
		if raw_parameters is Dictionary else {}
	return self


func advance(delta: float) -> void:
	if _move_active or not is_finite(delta) or delta <= 0.0:
		return
	_move_cooldown_left = maxf(_move_cooldown_left - delta, 0.0)


func can_start(_target: Node3D, _context: Dictionary = {}) -> bool:
	return _move_owner != null and is_instance_valid(_move_owner) \
		and owner_is_host() and not _move_active \
		and _move_cooldown_left <= 0.0


func start(target: Node3D, _context: Dictionary = {}) -> void:
	_move_active = true
	_move_elapsed = 0.0
	_move_target_peer = target_peer_id(target)


## Returns true when the controller should call [method finish].
func tick_host(
		delta: float,
		_target: Node3D,
		_context: Dictionary = {}) -> bool:
	if is_finite(delta) and delta > 0.0:
		_move_elapsed += delta
	return false


func finish(_interrupted := false) -> void:
	_move_active = false
	_move_cooldown_left = maxf(
		_move_cooldown_left, parameter_float(&"cooldown", 0.0))


func move_id() -> StringName:
	return StringName(String(_move_data.get("id", "")))


func behavior_id() -> StringName:
	return StringName(String(_move_data.get("behavior", "")))


func active() -> bool:
	return _move_active


func elapsed() -> float:
	return _move_elapsed


func cooldown_left() -> float:
	return _move_cooldown_left


func animation(stage: StringName) -> StringName:
	var mappings: Variant = _move_data.get("animations", {})
	if not mappings is Dictionary:
		return &""
	var clip: Variant = (mappings as Dictionary).get(String(stage), "")
	return StringName(String(clip)) \
		if clip is String or clip is StringName else &""


func parameters() -> Dictionary:
	return _move_parameters.duplicate(true)


func parameter(key: StringName, fallback: Variant = null) -> Variant:
	return _move_parameters.get(String(key), fallback)


func parameter_float(key: StringName, fallback: float) -> float:
	var value: Variant = parameter(key, fallback)
	if value is int or value is float:
		var number := float(value)
		if is_finite(number):
			return number
	return fallback


func parameter_int(key: StringName, fallback: int) -> int:
	var value: Variant = parameter(key, fallback)
	return int(value) if value is int or value is float else fallback


func parameter_bool(key: StringName, fallback: bool) -> bool:
	var value: Variant = parameter(key, fallback)
	return bool(value) if value is bool else fallback


func parameter_string(key: StringName, fallback := "") -> String:
	var value: Variant = parameter(key, fallback)
	return String(value) if value is String or value is StringName else fallback


func parameter_vector(
		key: StringName, fallback := Vector3.ZERO) -> Vector3:
	var value: Variant = parameter(key, fallback)
	if value is Vector3 and (value as Vector3).is_finite():
		return value as Vector3
	if value is Array and (value as Array).size() == 3:
		var row := value as Array
		if (row[0] is int or row[0] is float) \
				and (row[1] is int or row[1] is float) \
				and (row[2] is int or row[2] is float):
			var result := Vector3(
				float(row[0]), float(row[1]), float(row[2]))
			if result.is_finite():
				return result
	return fallback


func snapshot() -> Dictionary:
	var wire := {
		"id": String(move_id()),
		"active": _move_active,
		"elapsed": _move_elapsed,
		"cooldown": _move_cooldown_left,
		"target_peer": _move_target_peer,
	}
	var extras := snapshot_extras()
	for key: Variant in extras:
		wire[key] = extras[key]
	return wire


func apply_snapshot(wire: Dictionary) -> void:
	if wire.has("id") and String(wire.get("id", "")) != String(move_id()):
		return
	_move_active = bool(wire.get("active", _move_active))
	var next_elapsed := float(wire.get("elapsed", _move_elapsed))
	if is_finite(next_elapsed):
		_move_elapsed = maxf(next_elapsed, 0.0)
	var next_cooldown := float(wire.get("cooldown", _move_cooldown_left))
	if is_finite(next_cooldown):
		_move_cooldown_left = maxf(next_cooldown, 0.0)
	_move_target_peer = maxi(
		int(wire.get("target_peer", _move_target_peer)), 0)
	apply_snapshot_extras(wire)


func snapshot_extras() -> Dictionary:
	return {}


func apply_snapshot_extras(_wire: Dictionary) -> void:
	pass


func owner_node() -> Node:
	return _move_owner if is_instance_valid(_move_owner) else null


func owner_is_host() -> bool:
	if _move_owner == null or not is_instance_valid(_move_owner):
		return false
	if _move_owner.has_method(&"framework_is_host"):
		return bool(_move_owner.call(&"framework_is_host"))
	return not _move_owner.multiplayer.has_multiplayer_peer() \
		or _move_owner.multiplayer.is_server()


func owner_combat_position() -> Vector3:
	if _move_owner == null or not is_instance_valid(_move_owner):
		return Vector3.ZERO
	if _move_owner.has_method(&"combat_position"):
		var value: Variant = _move_owner.call(&"combat_position")
		if value is Vector3 and (value as Vector3).is_finite():
			return value
	if _move_owner is Node3D:
		return (_move_owner as Node3D).global_position
	return Vector3.ZERO


func owner_up() -> Vector3:
	if _move_owner is Node3D:
		var up := (_move_owner as Node3D).global_basis.y
		if up.is_finite() and up.length_squared() > 0.000001:
			return up.normalized()
	return Vector3.UP


func target_position(target: Node) -> Vector3:
	if target == null or not is_instance_valid(target):
		return Vector3(INF, INF, INF)
	if target.has_method(&"combat_position"):
		var value: Variant = target.call(&"combat_position")
		if value is Vector3 and (value as Vector3).is_finite():
			return value
	if target is Node3D:
		return (target as Node3D).global_position
	return Vector3(INF, INF, INF)


func target_radius(target: Node) -> float:
	if target != null and is_instance_valid(target) \
			and target.has_method(&"combat_radius"):
		var value := float(target.call(&"combat_radius"))
		return maxf(value, 0.0) if is_finite(value) else 0.0
	return 0.5


func target_peer_id(target: Node) -> int:
	if target != null and is_instance_valid(target) \
			and target.has_method(&"combat_peer_id"):
		return maxi(int(target.call(&"combat_peer_id")), 0)
	if target != null and is_instance_valid(target):
		var value: Variant = target.get(&"peer_id")
		if value is int or value is float:
			return maxi(int(value), 0)
	return 0


func target_is_available(target: Node) -> bool:
	if target == null or not is_instance_valid(target) \
			or not target is Node3D:
		return false
	if target.has_method(&"is_dead") and bool(target.call(&"is_dead")):
		return false
	return target_position(target).is_finite()


func combat_distance_to(target: Node) -> float:
	var from := owner_combat_position()
	var to := target_position(target)
	return from.distance_to(to) \
		if from.is_finite() and to.is_finite() else INF


func context_value(
		context: Dictionary, key: StringName, fallback: Variant = null) -> Variant:
	return context.get(String(key), fallback)


func play_animation(
		stage: StringName, fallback_role: StringName = &"") -> void:
	if _move_owner != null and is_instance_valid(_move_owner) \
			and _move_owner.has_method(&"framework_play_move_animation"):
		_move_owner.call(
			&"framework_play_move_animation", self, stage, fallback_role)


func face_target(target: Node3D, delta: float, turn_rate := 8.0) -> void:
	if _move_owner != null and is_instance_valid(_move_owner) \
			and _move_owner.has_method(&"framework_face_target"):
		_move_owner.call(
			&"framework_face_target", target, delta, turn_rate)


func move_owner_toward(
		goal: Vector3,
		speed: float,
		acceleration: float,
		delta: float,
		flying := false) -> void:
	if _move_owner != null and is_instance_valid(_move_owner) \
			and _move_owner.has_method(&"framework_move_toward"):
		_move_owner.call(
			&"framework_move_toward",
			goal,
			speed,
			acceleration,
			delta,
			flying)


func configure_hit(hit: DamageHit, target: Node = null) -> DamageHit:
	if hit == null:
		return null
	hit.faction = DamageHit.Faction.ENEMY
	hit.ability_id = parameter_string(
		&"ability_id",
		"%s_%s" % [_owner_boss_id(), String(move_id())])
	hit.parryable = parameter_bool(&"parryable", false)
	hit.reflection = maxf(parameter_float(&"reflection", 0.0), 0.0)
	hit.blocked_by_world = parameter_bool(&"blocked_by_world", false)
	hit.reaction = _reaction_from_parameter()
	hit.status = StringName(parameter_string(&"status", ""))
	hit.status_duration = maxf(
		parameter_float(&"status_duration", 0.0), 0.0)
	if target != null:
		hit.target_peer = target_peer_id(target)
	var impulse := parameter_vector(&"world_impulse", Vector3.ZERO)
	var knockback := maxf(parameter_float(&"knockback", 0.0), 0.0)
	var lift := parameter_float(&"lift", 0.0)
	if target != null and knockback > 0.0:
		var away := target_position(target) - owner_combat_position()
		if away.length_squared() > 0.000001:
			impulse += away.normalized() * knockback
	if lift != 0.0:
		impulse += owner_up() * lift
	hit.world_impulse = impulse
	hit.set_source(_move_owner)
	return hit


func apply_target_hit(target: Node, hit: DamageHit) -> float:
	if not owner_is_host() or hit == null or not target_is_available(target):
		return 0.0
	if DamageHit.game_world_of(_move_owner) != null:
		return DamageHit.apply_to_combatants(_move_owner, hit)
	if not hit.affects_combatant(target) or not target.has_method(&"apply_damage"):
		return 0.0
	var result: Variant = target.call(&"apply_damage", hit)
	return maxf(float(result), 0.0) \
		if result is int or result is float else 0.0


func apply_world_hit(hit: DamageHit) -> float:
	if not owner_is_host() or hit == null:
		return 0.0
	return DamageHit.apply_to_combatants(_move_owner, hit)


func _owner_boss_id() -> String:
	if _move_owner != null and is_instance_valid(_move_owner) \
			and _move_owner.has_method(&"boss_id"):
		return String(_move_owner.call(&"boss_id"))
	return "boss"


func _reaction_from_parameter() -> int:
	var value: Variant = parameter(&"reaction", "none")
	if value is int or value is float:
		return clampi(
			int(value), DamageHit.Reaction.NONE, DamageHit.Reaction.RAGDOLL)
	match String(value).to_lower():
		"stagger":
			return DamageHit.Reaction.STAGGER
		"knockback":
			return DamageHit.Reaction.KNOCKBACK
		"ragdoll":
			return DamageHit.Reaction.RAGDOLL
	return DamageHit.Reaction.NONE
