class_name BossMoveProjectile
extends BossMove

var _launched := false


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	var distance := combat_distance_to(target)
	return distance >= maxf(parameter_float(&"min_range", 5.0), 0.0) \
		and distance <= maxf(parameter_float(&"max_range", 60.0), 0.0)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	_launched = false
	play_animation(&"attack", &"attack")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	if target_is_available(target):
		face_target(
			target, delta, maxf(parameter_float(&"turn_rate", 7.0), 0.0))
	var release_at := maxf(parameter_float(&"release", 0.4), 0.0)
	if not _launched and elapsed() >= release_at:
		_launched = true
		_launch(target)
	return elapsed() >= release_at \
		+ maxf(parameter_float(&"recovery", 0.4), 0.0)


func snapshot_extras() -> Dictionary:
	return {"launched": _launched}


func apply_snapshot_extras(wire: Dictionary) -> void:
	_launched = bool(wire.get("launched", _launched))


func _launch(target: Node3D) -> void:
	var owner := owner_node()
	if owner != null and owner.has_method(&"framework_launch_projectile"):
		owner.call(&"framework_launch_projectile", self, target)
		return
	push_warning(
		"Boss projectile move '%s' has no projectile launch hook" % move_id())
