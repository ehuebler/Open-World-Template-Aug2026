class_name BossMoveFly
extends BossMove


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	return combat_distance_to(target) \
		> maxf(parameter_float(&"stop_distance", 8.0), 0.0)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	play_animation(&"move", &"fly")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	if not target_is_available(target):
		return true
	var stop_distance := maxf(
		parameter_float(&"stop_distance", 8.0), 0.0)
	if combat_distance_to(target) <= stop_distance:
		return true
	var goal := target_position(target) + owner_up() \
		* parameter_float(&"target_height", 0.0)
	move_owner_toward(
		goal,
		maxf(parameter_float(&"speed", 18.0), 0.0),
		maxf(parameter_float(&"acceleration", 40.0), 0.0),
		delta,
		true)
	var duration := parameter_float(&"duration", 0.8)
	return duration > 0.0 and elapsed() >= duration
