extends SceneTree

## What one height-field sample costs, which is the number every arrival time on
## this planet is a multiple of.
##
##     & $godot --headless --path . --script dev/_sample_cost.gd
##
## A chunk is a few thousand of these, so a tenth of a microsecond here is a
## visible amount of ground. Sampled over a spread of directions rather than one
## point, because the field early-outs at sea and a benchmark that happens to
## stand in the ocean measures the cheapest branch it has.

const SAMPLES := 40000
const SPACING := 1.5


func _initialize() -> void:
	var shape := PlanetShape.new()
	shape.prepare()

	var directions := PackedVector3Array()
	directions.resize(SAMPLES)
	for index in SAMPLES:
		directions[index] = PlanetShape.even_direction(index, SAMPLES)

	var started := Time.get_ticks_usec()
	var total := 0.0
	for index in SAMPLES:
		total += shape.elevation(directions[index], SPACING)
	var elevation_cost := float(Time.get_ticks_usec() - started) / float(SAMPLES)

	started = Time.get_ticks_usec()
	for index in SAMPLES:
		shape.color_at(directions[index], 10.0, directions[index])
	var colour_cost := float(Time.get_ticks_usec() - started) / float(SAMPLES)

	# The floor this can ever reach: an empty call over the same binding, so the
	# difference between it and the two above is the arithmetic rather than the
	# crossing into native code.
	var field: PlanetField = shape.get("_field")
	started = Time.get_ticks_usec()
	for index in SAMPLES:
		field.get_arid_edge()
	var call_cost := float(Time.get_ticks_usec() - started) / float(SAMPLES)

	print("sample_cost: elevation %.3f us  color_at %.3f us  bare call %.3f us" % [
		elevation_cost, colour_cost, call_cost])
	print("sample_cost: mean height %.2f m over %d samples" % [
		total / float(SAMPLES), SAMPLES])
	quit()
