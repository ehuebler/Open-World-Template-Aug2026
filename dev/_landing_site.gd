extends Node

## Throwaway: searches PlanetShape for the flattest dry ground on the planet and
## prints the Planet transform that would bring it to the north pole.
##
## The pole is the only place the world's -Y gravity already points at the planet's
## centre, so until the player derives up radially it is the one spot that can be
## stood on. Rotating the whole planet is how a chosen site gets there without
## touching the terrain.

## Wide enough to hold a station, the player and room to walk around both.
const SITE_RADIUS := 45.0
const RING_SAMPLES := 16
## Grass, clear of the sand band and well under the uplands.
const MIN_HEIGHT := 10.0
const MAX_HEIGHT := 70.0
## Mesh spacing at full detail, so flatness is judged on the ground that gets
## built rather than on a smoother field than the player walks over.
const SPACING := 1.5
## The direction the sun is overhead, which is -sun_direction and has to be kept
## in step with the Sun node in world.tscn.
const NOON := Vector3(-0.3501, 0.3201, 0.8803)
## How high the sun must stand at the site. The whole planet is lit by one
## directional light, so a site on the night side gets no direct sun at all and
## renders flat and shadowless off ambient alone. This also keeps the site on the
## hemisphere the spawn markers are looking at, so it is somewhere to aim for.
const MIN_SUN_ELEVATION := 40.0


func _ready() -> void:
	var shape := PlanetShape.new()
	shape.prepare()

	var best_direction := Vector3.UP
	var best_score := INF
	var considered := 0
	var candidates := 24000

	var min_noon := cos(deg_to_rad(90.0 - MIN_SUN_ELEVATION))
	for index in candidates:
		var direction := _fibonacci(index, candidates)
		if direction.dot(NOON) < min_noon:
			continue
		var here := shape.sample(direction)
		if here["river"] > 0.0 or here["lake"] > 0.0:
			continue
		var height := float(here["elevation"])
		if height < MIN_HEIGHT or height > MAX_HEIGHT:
			continue
		considered += 1
		var score := _roughness(shape, direction, height)
		if score < best_score:
			best_score = score
			best_direction = direction

	if best_score == INF:
		push_error("landing_site: nothing dry and flat inside the height band")
		get_tree().quit(1)
		return

	var final := shape.sample(best_direction)
	var normal := shape.normal_at(best_direction, SPACING)
	var slope := rad_to_deg(acos(clampf(normal.dot(best_direction), -1.0, 1.0)))
	print("dry flat candidates  %d of %d" % [considered, candidates])
	print("direction            %.6v" % best_direction)
	print("elevation            %.1f m" % final["elevation"])
	print("spread over %.0f m    %.2f m" % [SITE_RADIUS, best_score])
	print("slope                %.2f deg" % slope)
	print("roughness field      %.3f" % final["rough"])
	print("sun elevation        %.1f deg" % rad_to_deg(asin(clampf(best_direction.dot(NOON), -1.0, 1.0))))
	print("angle from spawn     %.1f deg" % rad_to_deg(best_direction.angle_to(Vector3.BACK)))

	# The rotation that carries the site onto +Y. Written as the Planet node's
	# basis, which is what world.tscn needs.
	var basis := Basis(Quaternion(best_direction, Vector3.UP))
	var moved := basis * best_direction
	print("checks out           site lands at %.4v" % moved)
	print("ground at pole       %.1f m" % shape.elevation(Vector3.UP))
	print("transform = Transform3D(%.8f, %.8f, %.8f, %.8f, %.8f, %.8f, %.8f, %.8f, %.8f, 0, 0, 0)" % [
		basis.x.x, basis.x.y, basis.x.z,
		basis.y.x, basis.y.y, basis.y.z,
		basis.z.x, basis.z.y, basis.z.z,
	])
	get_tree().quit()


## Worst height difference from the centre over two rings, which is what decides
## whether a building sits flush or on a slope.
func _roughness(shape: PlanetShape, direction: Vector3, height: float) -> float:
	var tangent := direction.cross(Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT).normalized()
	var bitangent := direction.cross(tangent)
	var worst := 0.0
	for ring in [SITE_RADIUS * 0.5, SITE_RADIUS]:
		var step: float = ring / shape.radius
		for index in RING_SAMPLES:
			var angle := TAU * float(index) / float(RING_SAMPLES)
			var offset := (tangent * cos(angle) + bitangent * sin(angle)) * step
			var probe := shape.sample((direction + offset).normalized())
			# Water anywhere in the site disqualifies it outright.
			if probe["river"] > 0.0 or probe["lake"] > 0.0 or float(probe["elevation"]) <= 0.0:
				return INF
			worst = maxf(worst, absf(float(probe["elevation"]) - height))
	return worst


## Evenly spread directions, so the search covers the sphere without clumping at
## the poles the way a latitude/longitude grid does.
func _fibonacci(index: int, count: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(index) + 0.5) / float(count)
	var radius := sqrt(maxf(0.0, 1.0 - y * y))
	var angle := PI * (1.0 + sqrt(5.0)) * float(index)
	return Vector3(cos(angle) * radius, y, sin(angle) * radius).normalized()
