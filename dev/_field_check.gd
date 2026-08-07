extends SceneTree

## Proves the native height field answers what the GDScript one did.
##
##     & $godot --headless --path . --script dev/_field_check.gd
##
## Reads `dev/captures/field_reference.json`, which `dev/_field_reference.gd`
## wrote from the GDScript field, and asks [PlanetField] the same questions. A
## port of a terrain generator is the kind of change where every intermediate
## result is a plausible-looking landscape, so nothing here is judged by eye:
## the noise fields are checked before the heights that are built from them, and
## `sea_bias` before either, because it is the one number a small error in moves
## every coastline in the world while leaving the planet looking fine.

## Frozen, committed, and never to be regenerated: it is what the terrain
## answered *before* the port, taken with the GDScript field that no longer
## exists. Refreshing it from the thing it is checking would turn the only proof
## the planet did not change into a tautology.
const REFERENCE := "res://dev/field_reference.json"

## Heights are metres and are compared in absolute terms; noise is unitless and
## in [-1, 1]. Both are tight enough that only float-versus-double rounding
## should fit under them — this is checking for *sameness*, not similarity.
const NOISE_TOLERANCE := 1e-5
const HEIGHT_TOLERANCE := 1e-3
const COLOUR_TOLERANCE := 1e-3


func _initialize() -> void:
	var file := FileAccess.open(REFERENCE, FileAccess.READ)
	if file == null:
		push_error("field_check: no reference at %s — run dev/_field_reference.gd first" % REFERENCE)
		quit(1)
		return
	var record: Dictionary = JSON.parse_string(file.get_as_text())
	file.close()

	var shape := PlanetShape.new()
	shape.prepare()
	var field := PlanetField.new()
	field.configure(PlanetShape.native_settings(shape))

	var failures := 0
	var count := int(record["directions"])
	var directions := PackedVector3Array()
	directions.resize(count)
	for index in count:
		directions[index] = PlanetShape.even_direction(index, count)

	# 1. The shoreline solve, first, because everything is measured from it.
	var solved: float = field.solve_sea_bias(4096, shape.sea_fraction)
	var bias_gap: float = absf(solved - float(record["sea_bias"]))
	failures += _report("sea_bias", bias_gap, NOISE_TOLERANCE, 1)
	print("field_check: sea_bias  gdscript %.9f  native %.9f" % [
		float(record["sea_bias"]), solved])

	# 2. Each noise field on its own. A mismatch here explains every later one,
	# and would otherwise show up as a confusing disagreement about mountains.
	var arid_gap: float = absf(float(field.get_arid_edge()) - float(record["arid_edge"]))
	failures += _report("arid_edge", arid_gap, NOISE_TOLERANCE, 1)

	var fields: Dictionary = record["fields"]
	for named: String in fields:
		var expected_noise: Array = fields[named]
		var worst_noise := 0.0
		var noise_over := 0
		for index in count:
			var got: float = field.noise_at(named, directions[index])
			var gap: float = absf(got - float(expected_noise[index]))
			worst_noise = maxf(worst_noise, gap)
			if gap > NOISE_TOLERANCE:
				noise_over += 1
		failures += _report("noise %-18s" % named, worst_noise, NOISE_TOLERANCE, noise_over)

	# 3. Elevation at every spacing a chunk is built at, plus 0 for point queries.
	var elevations: Dictionary = record["elevation"]
	for key: String in elevations:
		var spacing := float(key)
		var expected: Array = elevations[key]
		var worst := 0.0
		var worst_at := 0
		var over := 0
		for index in count:
			var got: float = shape.elevation(directions[index], spacing)
			var gap: float = absf(got - float(expected[index]))
			if gap > worst:
				worst = gap
				worst_at = index
			if gap > HEIGHT_TOLERANCE:
				over += 1
		failures += _report("elevation spacing %-6s" % key, worst, HEIGHT_TOLERANCE, over)
		if worst > HEIGHT_TOLERANCE:
			print("        worst at %d: gdscript %.6f, native %.6f" % [
				worst_at, float(expected[worst_at]),
				shape.elevation(directions[worst_at], spacing)])

	# 4. Colour, which shares `_arid_at` and the frost cap with the heights and
	# so is a second opinion on both.
	var colours: Array = record["colour"]
	var worst_colour := 0.0
	var worst_colour_at := 0
	var worst_tint := Color.BLACK
	var worst_height := 0.0
	var colour_over := 0
	for index in count:
		var height: float = shape.elevation(directions[index], 0.0)
		var tint: Color = shape.color_at(directions[index], height, directions[index])
		for channel in 3:
			var gap: float = absf(tint[channel] - float(colours[index * 3 + channel]))
			if gap > worst_colour:
				worst_colour = gap
				worst_colour_at = index
				worst_tint = tint
				worst_height = height
			if gap > COLOUR_TOLERANCE:
				colour_over += 1
	failures += _report("colour", worst_colour, COLOUR_TOLERANCE, colour_over)
	if worst_colour > COLOUR_TOLERANCE:
		print("        worst at %d: height %.6f frost %.6f" % [
			worst_colour_at, worst_height, shape.frost(directions[worst_colour_at])])
		print("        gdscript (%.5f %.5f %.5f)  native (%.5f %.5f %.5f)" % [
			float(colours[worst_colour_at * 3]),
			float(colours[worst_colour_at * 3 + 1]),
			float(colours[worst_colour_at * 3 + 2]),
			worst_tint.r, worst_tint.g, worst_tint.b])

	print("field_check: %s" % ("every check passed" if failures == 0
		else "%d CHECKS FAILED" % failures))
	quit(1 if failures > 0 else 0)


func _report(what: String, worst: float, tolerance: float, over: int) -> int:
	var passed := worst <= tolerance
	print("field_check: %-24s worst %.9f  %s%s" % [
		what, worst, "ok" if passed else "FAIL",
		"" if over == 0 or passed else " (%d samples over)" % over])
	return 0 if passed else 1
