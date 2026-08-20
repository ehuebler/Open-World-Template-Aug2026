class_name BossMoveArea
extends BossMove

var _fired := false


func can_start(target: Node3D, context: Dictionary = {}) -> bool:
	if not super.can_start(target, context) or not target_is_available(target):
		return false
	var distance := combat_distance_to(target)
	return distance >= maxf(parameter_float(&"min_range", 0.0), 0.0) \
		and distance <= maxf(parameter_float(&"max_range", 12.0), 0.0)


func start(target: Node3D, context: Dictionary = {}) -> void:
	super.start(target, context)
	_fired = false
	play_animation(&"attack", &"attack")


func tick_host(
		delta: float,
		target: Node3D,
		context: Dictionary = {}) -> bool:
	super.tick_host(delta, target, context)
	if target_is_available(target):
		face_target(
			target, delta, maxf(parameter_float(&"turn_rate", 6.0), 0.0))
	var fire_at := maxf(parameter_float(&"windup", 0.6), 0.0)
	if not _fired and elapsed() >= fire_at:
		_fired = true
		if not animation(&"active").is_empty():
			play_animation(&"active", &"attack")
		_apply_area(target)
	var recovery := maxf(parameter_float(&"recovery", 0.6), 0.0)
	return elapsed() >= fire_at + recovery


func snapshot_extras() -> Dictionary:
	return {"fired": _fired}


func apply_snapshot_extras(wire: Dictionary) -> void:
	_fired = bool(wire.get("fired", _fired))


func _apply_area(target: Node3D) -> void:
	var damage := maxf(parameter_float(&"damage", 16.0), 0.0)
	if damage <= 0.0:
		return
	var centre := owner_combat_position()
	if parameter_string(&"center", "owner") == "target" \
			and target_is_available(target):
		centre = target_position(target)
	var hit := DamageHit.area(
		centre,
		maxf(parameter_float(&"radius", 6.0), 0.01),
		damage,
		clampf(parameter_float(&"falloff", 1.0), 0.0, 1.0))
	configure_hit(hit)
	hit.radial_impulse = maxf(
		parameter_float(&"radial_impulse", 0.0), 0.0)
	hit.radial_lift = maxf(parameter_float(&"radial_lift", 0.0), 0.0)
	if DamageHit.game_world_of(owner_node()) != null:
		apply_world_hit(hit)
	elif target_is_available(target):
		hit.target_peer = target_peer_id(target)
		apply_target_hit(target, hit)
