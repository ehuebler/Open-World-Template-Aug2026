class_name BossMoveChase
extends BossMove


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	return combat_distance_to(target) \
		> maxf(parameter_float(&"stop_distance", 3.0), 0.0)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	play_animation(&"move", &"walk")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	if not target_is_available(target):
		return true
	var stop_distance := maxf(
		parameter_float(&"stop_distance", 3.0), 0.0)
	if combat_distance_to(target) <= stop_distance:
		return true
	move_owner_toward(
		target_position(target),
		maxf(parameter_float(&"speed", 8.0), 0.0),
		maxf(parameter_float(&"acceleration", 24.0), 0.0),
		delta)
	var duration := parameter_float(&"duration", 0.8)
	return duration > 0.0 and elapsed() >= duration
