extends SceneTree

## Finds ground a city can stand on: flat enough, above the tide, far from the towns
## already there, and with the sun high over it.
##
##     & $godot --headless --path . --script dev/_city_site.gd
##     & $godot --headless --path . --script dev/_city_site.gd -- --core=700 --sun=45
##
## Restored because the first city's site was found this way and then the script was
## thrown away, which left [constant CityLayout.CENTRE] as a magic vector nobody could
## re-derive or argue with. Siting a city by eye off a screenshot of the planet is
## how you get a pad with a 60 m cut across one side of it and a beach buried under
## the other.
##
## Measures against the [b]natural[/b] terrain — it clears [member PlanetShape.cities]
## first — so a candidate is judged on the ground that is there, not on a pad some
## other town already flattened.
##
## What it is looking for, in order of how much it matters:
##
## [codeblock]
## dry     no part of the footprint or its rim under water, since a pad that
##         crosses the waterline either dams the sea or cliffs into it
## flat    little cut and fill, because a one-level city has no grade to
##         spread the difference along
## lit     the sun well up at noon, which is what "the well lit part of the
##         map" means and is a fixed direction on this planet
## apart   clear of every existing town's reach, twice over
## [/codeblock]
##
## Flags:
##
## [codeblock]
## --core=M    half the footprint to test, in metres; 700 by default
## --rim=M     blend band outside it, also tested for water; 240
## --sun=DEG   least sun elevation at noon; 45
## --apart=DEG least angular distance from an existing town; 25
## --coarse=N  directions in the first sweep; 24000
## --keep=N    candidates to report; 6
## --skip=NAME a settlement to ignore when keeping clear of the others, which is
##             what you want when re-siting a town that is already in the list
## [/codeblock]

## Where the sun stands overhead, which is -sun_direction and has to be kept in step
## with the Sun node in `game/world.tscn`.
const NOON := Vector3(-0.3501, 0.3201, 0.8803)

## Samples across the footprint, per axis. 13 is 169 height field evaluations per
## candidate, which is affordable for a few thousand survivors and fine enough to
## catch a gully the pad would have to bridge.
const GRID := 13
## Extra ring of samples out on the rim, per side, purely to check for water.
const RIM_RING := 24

## Height that counts as dry land, in metres above sea level. The sand band starts
## at half a metre, so anything under this is beach at best.
const DRY := 3.0

## How far the refining pass looks around a coarse winner, in degrees, and how many
## steps it takes across that.
const REFINE_ARC := 1.6
const REFINE_STEPS := 9


func _initialize() -> void:
	var args := _flags()
	var core := float(args.get("core", 700.0))
	var rim := float(args.get("rim", 240.0))
	var min_sun := float(args.get("sun", 45.0))
	var apart := float(args.get("apart", 25.0))
	var coarse := int(args.get("coarse", 24000.0))
	var keep := int(args.get("keep", 6.0))
	var skip := StringName(String(args.get("skip", "")))

	var shape := PlanetShape.new()
	# The natural planet. Without this the probe would be measuring the flatness of
	# whatever pads are already baked in, and would happily recommend building on top of
	# Vacationer's Landing.
	shape.settled = false
	shape.prepare()

	var taken: Array[Vector3] = []
	for town: CityPlan in Settlements.plans():
		if town.site == skip:
			continue
		taken.append(town.centre.normalized())
	print("Siting a %.0f m city: sun at least %.0f deg up, at least %.0f deg from %d town(s)"
		% [core * 2.0, min_sun, apart, taken.size()])

	var picked: Array[Dictionary] = []
	for index in coarse:
		var direction := _spiral(index, coarse)
		if not _allowed(shape, direction, taken, min_sun, apart):
			continue
		var scored := _score(shape, direction, core, rim)
		if not bool(scored["dry"]):
			continue
		picked.append(scored)
	print("  %d of %d directions are dry, lit and clear" % [picked.size(), coarse])
	if picked.is_empty():
		printerr("FAIL: nowhere on the planet meets those limits")
		quit(1)
		return

	picked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["fill"]) < float(b["fill"]))
	var shortlist := picked.slice(0, mini(keep, picked.size()))

	print("\nRefined, best first:")
	var best: Array[Dictionary] = []
	for candidate: Dictionary in shortlist:
		best.append(_refine(shape, candidate, taken, core, rim, min_sun, apart))
	best.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["fill"]) < float(b["fill"]))
	for candidate: Dictionary in best:
		_say(candidate, taken)
	quit()


## Whether a direction is worth measuring at all: lit enough, out of the arctic, and
## not on top of a town that is already there.
##
## The frost test is not fussiness. The polar cap lifts everything under the waterline
## to exactly [constant PlanetShape.ICE_TOP], so the ice sheet is the flattest ground
## on the planet by a wide margin and scores perfectly on every other measure here —
## the first run of this probe recommended six sites on it, all reading zero cut and
## zero fill, all of them a city built on frozen sea. Flat is not the same as solid.
##
## The separation is doubled because two footprints must not touch: each town's own
## reach subtends its own angle, so "far enough" is the sum of the two radii, and
## asking for twice the larger is the same thing with slack in it.
func _allowed(shape: PlanetShape, direction: Vector3, taken: Array[Vector3],
		min_sun: float, apart: float) -> bool:
	if _sun_elevation(direction) < min_sun:
		return false
	if shape.frost(direction) > 0.0:
		return false
	for other: Vector3 in taken:
		if rad_to_deg(direction.angle_to(other)) < apart:
			return false
	return true


func _sun_elevation(direction: Vector3) -> float:
	return 90.0 - rad_to_deg(acos(clampf(direction.dot(NOON), -1.0, 1.0)))


## How much earth a flat pad here would have to move, and whether it would get its
## feet wet.
##
## Cut and fill is measured against the mean rather than against the lowest point,
## because a level pad is free to sit anywhere in the range and the mean is where it
## costs least. [code]fill[/code] is the average distance the ground has to travel,
## which is the number that decides whether a one-level city looks built or looks
## dropped; [code]spread[/code] is the worst of it.
func _score(shape: PlanetShape, up: Vector3, core: float,
		rim: float) -> Dictionary:
	var frame := _frame(up)
	var heights := PackedFloat32Array()
	var lowest := 1e9
	var highest := -1e9
	var total := 0.0
	for row in GRID:
		for column in GRID:
			var local := Vector2(
				lerpf(-core, core, float(column) / float(GRID - 1)),
				lerpf(-core, core, float(row) / float(GRID - 1)))
			var height := shape.elevation(_direction_at(frame, up, local,
				shape.radius))
			heights.append(height)
			total += height
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	var level := total / float(heights.size())
	var fill := 0.0
	for height: float in heights:
		fill += absf(height - level)
	fill /= float(heights.size())

	# The rim has to be dry as well. A pad that is dry across its middle and wet at
	# one corner is a sea wall, which is the first city's problem and the whole
	# reason this one is being sited on a plain.
	var dry := lowest >= DRY
	if dry:
		for step in RIM_RING:
			var turn := TAU * float(step) / float(RIM_RING)
			var local := Vector2(cos(turn), sin(turn)) * (core + rim)
			if shape.elevation(_direction_at(frame, up, local, shape.radius)) < DRY:
				dry = false
				break
	return {"up": up, "level": level, "fill": fill,
		"spread": highest - lowest, "low": lowest, "high": highest, "dry": dry}


## A local hunt around a coarse winner. The coarse sweep is about 1.2 degrees between
## samples at 24000 directions, which is 170 m on this planet — enough to miss the
## flattest part of a flat place by most of a city.
func _refine(shape: PlanetShape, from: Dictionary, taken: Array[Vector3],
		core: float, rim: float, min_sun: float, apart: float) -> Dictionary:
	var up: Vector3 = from["up"]
	var frame := _frame(up)
	var best := from
	for row in REFINE_STEPS:
		for column in REFINE_STEPS:
			var offset := Vector2(
				lerpf(-REFINE_ARC, REFINE_ARC, float(column) / float(REFINE_STEPS - 1)),
				lerpf(-REFINE_ARC, REFINE_ARC, float(row) / float(REFINE_STEPS - 1)))
			var moved := (up + frame[0] * deg_to_rad(offset.x)
				+ frame[1] * deg_to_rad(offset.y)).normalized()
			if not _allowed(shape, moved, taken, min_sun, apart):
				continue
			var scored := _score(shape, moved, core, rim)
			if not bool(scored["dry"]):
				continue
			if float(scored["fill"]) < float(best["fill"]):
				best = scored
	return best


func _say(candidate: Dictionary, taken: Array[Vector3]) -> void:
	var up: Vector3 = candidate["up"]
	var nearest := 360.0
	for other: Vector3 in taken:
		nearest = minf(nearest, rad_to_deg(up.angle_to(other)))
	print(("  Vector3(%.7f, %.7f, %.7f)  level %.1f m, fill %.1f m, spread %.1f m,"
		+ " sun %.1f deg, %.1f deg from the nearest town") % [
		up.x, up.y, up.z, candidate["level"], candidate["fill"],
		candidate["spread"], _sun_elevation(up), nearest])


# --- Geometry ---------------------------------------------------------------

## An east and a north for a local up, built exactly the way [CityPlan] builds them
## at zero facing, so a site found here lands where the plan puts it.
func _frame(up: Vector3) -> Array[Vector3]:
	var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - up * hint.dot(up)).normalized()
	return [up.cross(forward), -forward]


## Azimuthal equidistant, as [method CityPlan.direction_at] does it.
func _direction_at(frame: Array[Vector3], up: Vector3, local: Vector2,
		radius: float) -> Vector3:
	var metres := local.length()
	if metres < 1e-6:
		return up
	var arc := metres / radius
	var tangent := (frame[0] * local.x + frame[1] * local.y) / metres
	return up * cos(arc) + tangent * sin(arc)


## Evenly spread directions over the sphere, by the golden angle. Cheap, and unlike a
## latitude-longitude sweep it does not spend most of its samples at the poles.
func _spiral(index: int, count: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(index) + 0.5) / float(count)
	var ring := sqrt(maxf(0.0, 1.0 - y * y))
	var turn := PI * (1.0 + sqrt(5.0)) * float(index)
	return Vector3(cos(turn) * ring, y, sin(turn) * ring)


## Numbers arrive as floats and anything else as a string, so a caller reading a flag
## has to know which it asked for. That is fine for six flags and would not be for
## sixty.
func _flags() -> Dictionary:
	var found := {}
	for argument: String in OS.get_cmdline_user_args():
		var pair := argument.trim_prefix("--").split("=")
		if pair.size() != 2:
			continue
		found[pair[0]] = pair[1].to_float() if pair[1].is_valid_float() else pair[1]
	return found
