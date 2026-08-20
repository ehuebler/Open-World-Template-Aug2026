class_name BossMoveCharge
extends BossMove

var _charge_goal := Vector3.ZERO
var _hit_target := false
var _charging_started := false


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	var distance := combat_distance_to(target)
	return distance >= maxf(parameter_float(&"min_range", 6.0), 0.0) \
		and distance <= maxf(parameter_float(&"max_range", 40.0), 0.0)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	_charge_goal = target_position(target)
	_hit_target = false
	_charging_started = false
	if animation(&"windup").is_empty():
		play_animation(&"charge", &"run")
	else:
		play_animation(&"windup", &"attack")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	var windup := maxf(parameter_float(&"windup", 0.35), 0.0)
	var travel_time := maxf(parameter_float(&"duration", 0.9), 0.05)
	if elapsed() < windup:
		if target_is_available(target):
			face_target(
				target, delta,
				maxf(parameter_float(&"turn_rate", 8.0), 0.0))
		return false
	if elapsed() <= windup + travel_time:
		if not _charging_started:
			_charging_started = true
			if not animation(&"charge").is_empty():
				play_animation(&"charge", &"run")
		if parameter_bool(&"track_target", false) \
				and target_is_available(target):
			_charge_goal = target_position(target)
		var previous := owner_combat_position()
		move_owner_toward(
			_charge_goal,
			maxf(parameter_float(&"speed", 24.0), 0.0),
			maxf(parameter_float(&"acceleration", 80.0), 0.0),
			delta)
		_try_hit_target(previous, owner_combat_position(), target)
		return false
	var owner := owner_node()
	if owner != null and owner.has_method(&"framework_stop_movement"):
		owner.call(&"framework_stop_movement")
	return elapsed() >= windup + travel_time \
		+ maxf(parameter_float(&"recovery", 0.45), 0.0)


func snapshot_extras() -> Dictionary:
	return {
		"goal": _charge_goal,
		"hit_target": _hit_target,
		"charging_started": _charging_started,
	}


func apply_snapshot_extras(wire: Dictionary) -> void:
	var goal: Variant = wire.get("goal", _charge_goal)
	if goal is Vector3 and (goal as Vector3).is_finite():
		_charge_goal = goal
	_hit_target = bool(wire.get("hit_target", _hit_target))
	_charging_started = bool(
		wire.get("charging_started", _charging_started))


func _try_hit_target(from: Vector3, to: Vector3, target: Node3D) -> void:
	if _hit_target or not target_is_available(target):
		return
	var radius := maxf(parameter_float(&"radius", 2.0), 0.01)
	var damage := maxf(parameter_float(&"damage", 28.0), 0.0)
	var sweep := DamageHit.beam(from, to, radius, damage)
	if not sweep.reaches(target_position(target), target_radius(target)):
		return
	_hit_target = true
	configure_hit(sweep, target)
	apply_target_hit(target, sweep)
