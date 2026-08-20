class_name BossArena
extends RefCounted

## Location-aware arena math shared by generic and custom boss controllers.
## Rendering deliberately lives elsewhere.


static func planet_of(from: Node) -> Planet:
	var current := from
	while current != null:
		if current is Planet:
			return current as Planet
		current = current.get_parent()
	return null


static func planet_center(planet: Planet) -> Vector3:
	return planet.global_position if planet != null else Vector3.ZERO


static func planet_radius(planet: Planet) -> float:
	if planet != null and planet.shape != null:
		return maxf(float(planet.shape.radius), 0.001)
	return 0.0


## Unit direction in planet-local space.
static func surface_direction(planet: Planet, point: Vector3) -> Vector3:
	if planet == null or not point.is_finite():
		return Vector3.ZERO
	var local := planet.to_local(point)
	if not local.is_finite() or local.length_squared() < 0.000001:
		return Vector3.ZERO
	return local.normalized()


## Unit radial direction in world space.
static func surface_up(planet: Planet, point: Vector3) -> Vector3:
	var direction := surface_direction(planet, point)
	if direction == Vector3.ZERO:
		return Vector3.UP
	var inner := planet.to_global(direction)
	var outer := planet.to_global(direction * 2.0)
	var up := outer - inner
	return up.normalized() if up.length_squared() > 0.000001 \
		else Vector3.UP


static func surface_arc_distance(
		planet: Planet, from: Vector3, to: Vector3) -> float:
	if planet == null or not from.is_finite() or not to.is_finite():
		return INF
	var from_direction := surface_direction(planet, from)
	var to_direction := surface_direction(planet, to)
	var radius := planet_radius(planet)
	if from_direction == Vector3.ZERO or to_direction == Vector3.ZERO \
			or radius <= 0.0:
		return INF
	return from_direction.angle_to(to_direction) * radius


static func euclidean_distance(from: Vector3, to: Vector3) -> float:
	if not from.is_finite() or not to.is_finite():
		return INF
	return from.distance_to(to)


static func distance(
		mode: StringName,
		arena_origin: Vector3,
		point: Vector3,
		context: Node) -> float:
	if mode == &"surface_arc":
		var arc := surface_arc_distance(
			planet_of(context), arena_origin, point)
		if is_finite(arc):
			return arc
	return euclidean_distance(arena_origin, point)


static func distance_for_definition(
		definition: BossDefinition,
		arena_origin: Vector3,
		point: Vector3,
		context: Node) -> float:
	var mode := definition.arena_distance_mode \
		if definition != null else &"euclidean"
	return distance(mode, arena_origin, point, context)


static func clamp_euclidean(
		point: Vector3, arena_origin: Vector3, radius: float) -> Vector3:
	if not point.is_finite() or not arena_origin.is_finite() or radius <= 0.0:
		return point
	var offset := point - arena_origin
	if offset.length_squared() <= radius * radius:
		return point
	return arena_origin + offset.normalized() * radius


static func clamp_surface_arc(
		planet: Planet,
		point: Vector3,
		arena_origin: Vector3,
		radius: float) -> Vector3:
	if planet == null or radius <= 0.0 or not point.is_finite() \
			or not arena_origin.is_finite():
		return point
	var planet_size := planet_radius(planet)
	var centre := surface_direction(planet, arena_origin)
	var direction := surface_direction(planet, point)
	if planet_size <= 0.0 or centre == Vector3.ZERO \
			or direction == Vector3.ZERO:
		return point
	var limit := radius / planet_size
	var angle := centre.angle_to(direction)
	if angle <= limit:
		return point
	var axis := centre.cross(direction)
	if axis.length_squared() < 0.000001:
		var hint := Vector3.UP if absf(centre.y) < 0.9 else Vector3.RIGHT
		axis = centre.cross(hint)
	if axis.length_squared() < 0.000001:
		return point
	var local_point := planet.to_local(point)
	var radial_distance := local_point.length()
	var clamped_direction := (
		Basis(axis.normalized(), limit) * centre
	).normalized()
	return planet.to_global(clamped_direction * radial_distance)


static func clamp_point(
		mode: StringName,
		point: Vector3,
		arena_origin: Vector3,
		radius: float,
		context: Node) -> Vector3:
	if mode == &"surface_arc":
		var planet := planet_of(context)
		if planet != null:
			return clamp_surface_arc(
				planet, point, arena_origin, radius)
	return clamp_euclidean(point, arena_origin, radius)


static func clamp_for_definition(
		definition: BossDefinition,
		point: Vector3,
		arena_origin: Vector3,
		context: Node,
		inset := 0.0) -> Vector3:
	if definition == null:
		return point
	var radius := maxf(definition.arena_radius - maxf(inset, 0.0), 0.0)
	return clamp_point(
		definition.arena_distance_mode,
		point,
		arena_origin,
		radius,
		context)
