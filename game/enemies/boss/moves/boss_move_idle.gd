class_name BossMoveIdle
extends BossMove


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	play_animation(&"idle", &"rest")
	var owner := owner_node()
	if owner != null and owner.has_method(&"framework_stop_movement"):
		owner.call(&"framework_stop_movement")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	return elapsed() >= maxf(parameter_float(&"duration", 0.75), 0.05)
