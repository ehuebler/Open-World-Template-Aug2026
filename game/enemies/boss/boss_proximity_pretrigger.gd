class_name BossProximityPretrigger
extends BossPretrigger

var _proximity_mode := &"arena"


func configure_proximity(
		owner: Node,
		id: StringName,
		mode: StringName) -> BossProximityPretrigger:
	super.configure(owner, id, false)
	_proximity_mode = mode
	return self


func tick_host(_delta: float, players: Array) -> bool:
	if externally_owned() or triggered():
		return triggered()
	var owner := owner_node()
	if owner == null:
		return false
	var radius := _detection_radius(owner)
	for candidate: Variant in players:
		var player := candidate as Node3D
		if player == null or not is_instance_valid(player):
			continue
		var distance := _distance_to(owner, player)
		if distance <= radius:
			_pretrigger_triggered = true
			return true
	return false


func _detection_radius(owner: Node) -> float:
	if owner.has_method(&"definition"):
		var resource: Variant = owner.call(&"definition")
		if resource is BossDefinition:
			return maxf((resource as BossDefinition).detection_radius, 0.0)
	if owner.has_method(&"battle_radius"):
		return maxf(float(owner.call(&"battle_radius")), 0.0)
	return 0.0


func _distance_to(owner: Node, player: Node3D) -> float:
	if _proximity_mode == &"arena" \
			and owner.has_method(&"arena_distance_to"):
		var value: Variant = owner.call(&"arena_distance_to", player)
		if value is int or value is float:
			var distance := float(value)
			if is_finite(distance):
				return maxf(distance, 0.0)
	var from := (owner as Node3D).global_position \
		if owner is Node3D else Vector3.ZERO
	if owner.has_method(&"combat_position"):
		var owner_point: Variant = owner.call(&"combat_position")
		if owner_point is Vector3 and (owner_point as Vector3).is_finite():
			from = owner_point
	var to := player.global_position
	if player.has_method(&"combat_position"):
		var player_point: Variant = player.call(&"combat_position")
		if player_point is Vector3 and (player_point as Vector3).is_finite():
			to = player_point
	return from.distance_to(to) \
		if from.is_finite() and to.is_finite() else INF
