class_name BossMoveMelee
extends BossMove

var _struck := false


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	var distance := combat_distance_to(target)
	var reach := maxf(parameter_float(&"range", 4.0), 0.0)
	var minimum := maxf(parameter_float(&"min_range", 0.0), 0.0)
	return distance >= minimum and distance <= reach + target_radius(target)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	_struck = false
	if animation(&"windup").is_empty():
		play_animation(&"attack", &"attack")
	else:
		play_animation(&"windup", &"attack")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	if not target_is_available(target):
		return true
	face_target(
		target, delta, maxf(parameter_float(&"turn_rate", 10.0), 0.0))
	var strike_at := maxf(parameter_float(&"windup", 0.35), 0.0)
	if not _struck and elapsed() >= strike_at:
		_struck = true
		if not animation(&"strike").is_empty():
			play_animation(&"strike", &"attack")
		_apply_strike(target)
	var recovery := maxf(parameter_float(&"recovery", 0.45), 0.0)
	return elapsed() >= strike_at + recovery


func snapshot_extras() -> Dictionary:
	return {"struck": _struck}


func apply_snapshot_extras(wire: Dictionary) -> void:
	_struck = bool(wire.get("struck", _struck))


func _apply_strike(target: Node3D) -> void:
	var reach := maxf(parameter_float(&"range", 4.0), 0.01)
	if combat_distance_to(target) > reach + target_radius(target):
		return
	var damage := maxf(parameter_float(&"damage", 20.0), 0.0)
	if damage <= 0.0:
		return
	var hit := DamageHit.impact(
		target_position(target),
		maxf(parameter_float(&"radius", 1.25), 0.01),
		damage)
	configure_hit(hit, target)
	apply_target_hit(target, hit)
