class_name BossAdapter
extends RefCounted

## Small read-only adapter for any arena boss in group [code]bosses[/code].
##
## Multiple authored encounters live on the same planet. Discovery therefore
## selects the locally relevant boss rather than returning whichever group member
## happened to enter the scene tree first.

const GROUP := &"bosses"
const LEGACY_GROUP := &"bigfoot_boss"
const DEFAULT_RADIUS := 200.0
const FADE_MARGIN := 20.0


static func find_in_tree(from: Node) -> Node:
	if from == null or not from.is_inside_tree():
		return null
	var local_world := DamageHit.game_world_of(from)
	var body := from as Node3D
	var best: Node = null
	var best_score := INF
	var seen: Dictionary = {}
	var candidates := from.get_tree().get_nodes_in_group(GROUP)
	# Compatibility for stripped fixtures and saves authored before the generic
	# group existed. Live Bigfoot joins both and is de-duplicated below.
	candidates.append_array(
		from.get_tree().get_nodes_in_group(LEGACY_GROUP))
	for node: Node in candidates:
		if node == null or not is_instance_valid(node) \
				or seen.has(node.get_instance_id()) \
				or (local_world != null
					and not DamageHit.in_same_world(from, node)):
			continue
		seen[node.get_instance_id()] = true
		var distance := arena_distance_to(node, body) \
			if body != null else 0.0
		# An encounter already in progress keeps ownership of the bar through its
		# five-second exit warning. Otherwise the geographically nearest arena is
		# the one the player is approaching.
		var score := distance - (1000000.0 if is_engaged(node) else 0.0)
		if score < best_score:
			best_score = score
			best = node
	return best


static func is_boss(node: Node) -> bool:
	return node != null and (
		node.is_in_group(GROUP) or node.is_in_group(LEGACY_GROUP))


static func display_name(boss: Node) -> String:
	if boss == null:
		return "Boss"
	for method: StringName in [&"boss_display_name", &"combat_display_name"]:
		if boss.has_method(method):
			var value := String(boss.call(method)).strip_edges()
			if not value.is_empty():
				return value
	var fallback := String(boss.name).strip_edges()
	return fallback if not fallback.is_empty() else "Boss"


static func is_engaged(boss: Node) -> bool:
	if boss == null:
		return false
	if is_defeated(boss):
		return false
	if boss.has_method(&"is_engaged"):
		return bool(boss.call(&"is_engaged"))
	if boss.has_method(&"engaged"):
		return bool(boss.call(&"engaged"))
	return false


static func is_defeated(boss: Node) -> bool:
	if boss == null:
		return false
	if boss.has_method(&"is_defeated"):
		return bool(boss.call(&"is_defeated"))
	if boss.has_method(&"defeated"):
		return bool(boss.call(&"defeated"))
	return false


static func health(boss: Node) -> float:
	if boss == null:
		return 0.0
	if boss.has_method(&"health"):
		return maxf(float(boss.call(&"health")), 0.0)
	if boss.has_method(&"get_health"):
		return maxf(float(boss.call(&"get_health")), 0.0)
	return 0.0


static func maximum_health(boss: Node) -> float:
	if boss == null:
		return 1.0
	if boss.has_method(&"maximum_health"):
		return maxf(float(boss.call(&"maximum_health")), 0.001)
	if boss.has_method(&"max_health"):
		return maxf(float(boss.call(&"max_health")), 0.001)
	var current := health(boss)
	return maxf(current, 1.0)


static func battle_radius(boss: Node) -> float:
	if boss == null:
		return DEFAULT_RADIUS
	if boss.has_method(&"battle_radius"):
		return maxf(float(boss.call(&"battle_radius")), 1.0)
	if boss.has_method(&"arena_radius"):
		return maxf(float(boss.call(&"arena_radius")), 1.0)
	return DEFAULT_RADIUS


static func arena_distance_to(boss: Node, body: Node3D) -> float:
	if boss == null or body == null:
		return INF
	if boss.has_method(&"arena_distance_to"):
		var value: Variant = boss.call(&"arena_distance_to", body)
		if value is float or value is int:
			return maxf(float(value), 0.0)
	var boss_pos := _combat_position(boss)
	var body_pos := body.global_position
	if boss_pos.is_finite() and body_pos.is_finite():
		var planet := _planet_of(boss)
		if planet != null:
			var centre := planet.global_position
			var boss_dir := (boss_pos - centre).normalized()
			var body_dir := (body_pos - centre).normalized()
			return boss_dir.angle_to(body_dir) * _planet_radius(planet)
	return boss_pos.distance_to(body_pos)


static func arena_alpha(distance: float, radius: float) -> float:
	if distance > radius:
		return 0.0
	var fade_start := maxf(radius - FADE_MARGIN, radius * 0.5)
	if distance <= fade_start:
		return 1.0
	return clampf(inverse_lerp(radius, fade_start, distance), 0.0, 1.0)


static func model_root(boss: Node) -> Node3D:
	if boss == null:
		return null
	var model := boss.get_node_or_null("Model") as Node3D
	return model if model != null else boss as Node3D


static func _combat_position(node: Node) -> Vector3:
	if node.has_method(&"combat_position"):
		var value: Variant = node.call(&"combat_position")
		if value is Vector3 and (value as Vector3).is_finite():
			return value
	if node is Node3D:
		return (node as Node3D).global_position
	return Vector3.ZERO


static func _planet_of(node: Node) -> Planet:
	var walk := node
	while walk != null:
		if walk is Planet:
			return walk as Planet
		walk = walk.get_parent()
	return null


static func _planet_radius(planet: Planet) -> float:
	if planet != null and planet.shape != null:
		return planet.shape.radius
	return 8000.0
