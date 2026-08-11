extends SceneTree

## Searches the coast at Vacationer's Landing for somewhere to stand the colony
## ship, and prints the direction to paste into `game/world.tscn`.
##
##     godot --headless --path . --script dev/_lander_site.gd
##
## The town's pads are switched off, so the ground there is the raw height field
## again — an amphitheatre of bluffs opening south to the sea, per [CityLayout].
## A lander wants the opposite of what a city wanted: not the flattest shelf, but
## the flattest patch that is still within sight of the water, because "it came
## down by the sea" is the whole of what the placement has to say.
##
## Distance to water is measured over a grid rather than by rays, because a
## coastline is not convex: a ray cast south from a headland crosses open sea in
## a hundred metres while the beach the ship should be on is round the other
## side. Flooding outward from every wet cell answers for the shape the coast
## actually has, at a cost this only pays once.

## Half-width of the surveyed square, in metres, and the grid step across it.
## The waterline runs about a kilometre north of the town centre, so the survey
## has to reach past it for the flood below to have anything to flood from. 10 m
## is a third of the ship's own footprint; finer than that only resolves detail
## the flatness test would reject anyway.
const REACH := 1700.0
const STEP := 10.0
## How far from the town centre the ship may stand. It is meant to read as the
## thing Vacationer's Landing was named for, so it has to be at the Landing —
## which on this coast means the search cannot simply walk to the sea.
const SITE_REACH := 1400.0
## Mesh spacing at full detail. Everything here is judged on the ground that gets
## built rather than on a smoother field than the player walks over.
const SPACING := 1.5
## Radius of the ship's own footprint, which is how far out the ground has to
## stay level for it to stand on its four legs rather than on two of them.
const FOOTPRINT := 12.0
const FOOTPRINT_SAMPLES := 12
## The band of dry ground worth landing on, in metres above sea level. The floor
## is well clear of the tide line — a lander parked at 2 m reads as beached — and
## the ceiling keeps it off the bluffs.
const MIN_HEIGHT := 6.0
const MAX_HEIGHT := 34.0
## How near the water the ship should be, in metres. Near enough that the sea is
## the thing behind it in a photograph, far enough that there is dry ground to
## walk round it on.
const NEAR_WATER := 35.0
const FAR_WATER := 130.0
## Worst height difference across the footprint that still counts as level.
const LEVEL := 2.5


func _initialize() -> void:
	var shape := PlanetShape.new()
	# The pads are off in `game/world.tscn`, so a survey against a settled shape
	# would be measuring a graded terrace that is not there any more.
	shape.settled = false
	shape.prepare()

	var centre: Vector3 = CityLayout.CENTRE.normalized()
	var east := centre.cross(Vector3.UP).normalized()
	var north := centre.cross(east)
	var side := int(REACH * 2.0 / STEP) + 1

	# One elevation per cell, then how far each dry cell is from the nearest wet
	# one, flooded outward over the grid.
	var heights := PackedFloat32Array()
	heights.resize(side * side)
	var to_water := PackedFloat32Array()
	to_water.resize(side * side)
	var frontier: Array[int] = []
	for row in side:
		for col in side:
			var index := row * side + col
			var direction := _at(centre, east, north, shape.radius,
				(float(col) - float(side - 1) * 0.5) * STEP,
				(float(row) - float(side - 1) * 0.5) * STEP)
			var height := shape.elevation(direction, SPACING)
			heights[index] = height
			to_water[index] = INF
			if height <= 0.0:
				frontier.append(index)

	var wet := frontier.size()
	print("surveyed %d cells over %.0f m, %d of them under water" % [side * side, REACH * 2.0, wet])
	_profile(shape, centre, east, north, heights, side)
	# Only the open sea counts, and getting there takes two cuts. The river is
	# dropped first: it is under sea level along its whole length, it runs
	# inland for kilometres, and left in it reports a lander in a gorge as
	# "70 m from water". What is left is still ponds as well as ocean, so the
	# largest connected body of it is taken and the flood runs from that alone.
	var sea := _largest_body(shape, centre, east, north, heights, side)
	print("the sea is %d of those cells; the rest are ponds and river channel" % sea.size())
	if sea.size() < 64:
		push_error("lander_site: no sea inside the survey; the coast is not where it was")
		quit(1)
		return
	_flood(to_water, sea, side)
	for index: int in sea:
		to_water[index] = 0.0

	var best := -1
	var best_score := INF
	var considered := 0
	for index in side * side:
		var height := heights[index]
		if height < MIN_HEIGHT or height > MAX_HEIGHT:
			continue
		if to_water[index] < NEAR_WATER or to_water[index] > FAR_WATER:
			continue
		var offset := Vector2(
			(float(index % side) - float(side - 1) * 0.5) * STEP,
			(float(index / side) - float(side - 1) * 0.5) * STEP)
		if offset.length() > SITE_REACH:
			continue
		var direction := _at(centre, east, north, shape.radius, offset.x, offset.y)
		var here := shape.sample(direction)
		if here["river"] > 0.0 or here["lake"] > 0.0:
			continue
		var spread := _spread(shape, direction, height)
		if spread > LEVEL:
			continue
		considered += 1
		# Three wants, and the weights are what settles the argument between
		# them. Level is worth the most because it is the one a photograph
		# cannot forgive — a ship standing at an angle reads as a mistake. Then
		# near the town, then near the water: a hundred metres further along the
		# beach costs nothing, and a hundred metres further inland is a lander
		# that has nothing to do with the sea.
		var score := spread + offset.length() * 0.0015 + to_water[index] * 0.004
		if score < best_score:
			best_score = score
			best = index

	if best < 0:
		push_error("lander_site: nothing level, dry and near the water inside the band")
		quit(1)
		return

	var col := best % side
	var row := best / side
	var offset_east := (float(col) - float(side - 1) * 0.5) * STEP
	var offset_north := (float(row) - float(side - 1) * 0.5) * STEP
	var direction := _at(centre, east, north, shape.radius, offset_east, offset_north)
	var normal := shape.normal_at(direction, SPACING)
	print("candidates          %d" % considered)
	print("offset from centre  %.0f m east, %.0f m north" % [offset_east, offset_north])
	print("elevation           %.1f m" % heights[best])
	print("distance to water   %.0f m" % to_water[best])
	print("spread over %.0f m   %.2f m" % [FOOTPRINT, _spread(shape, direction, heights[best])])
	print("slope               %.2f deg" % rad_to_deg(
		acos(clampf(normal.dot(direction), -1.0, 1.0))))
	print("from the Landing    %.0f m" % (centre.angle_to(direction) * shape.radius))
	print("direction = Vector3(%.7f, %.7f, %.7f)" % [direction.x, direction.y, direction.z])

	# Which way the sea is from there, as a heading a SurfaceAnchor can take, so
	# the ship can be turned to face it rather than the bluffs.
	print("facing the water    %.1f deg" % _toward_water(
		shape, direction, to_water, side, centre, east, north,
		Vector2(offset_east, offset_north)))
	quit()


## A coarse picture of the ground surveyed, printed because the numbers below are
## only trustworthy if the coast is where the reading says it is.
func _profile(shape: PlanetShape, centre: Vector3, east: Vector3, north: Vector3,
		heights: PackedFloat32Array, side: int) -> void:
	var rows := 21
	print("  ground over the survey, north at the top; '~' is sea, '.' beach, '#' bluff")
	for row in range(rows - 1, -1, -1):
		var line := "   "
		for col in rows:
			var index := (row * (side - 1) / (rows - 1)) * side + col * (side - 1) / (rows - 1)
			var height := heights[index]
			if height <= 0.0:
				line += "~"
			elif height < 8.0:
				line += "."
			elif height < 40.0:
				line += "-"
			elif height < 90.0:
				line += "+"
			else:
				line += "#"
		print(line)
	var lowest := INF
	var highest := -INF
	for height in heights:
		lowest = minf(lowest, height)
		highest = maxf(highest, height)
	print("  elevation %.0f m to %.0f m; the Landing itself is at %.0f m" % [
		lowest, highest, shape.elevation(centre, SPACING)])
	# Which way the ground falls, which is the direction the open sea is in even
	# when the survey does not reach it.
	var step := 40.0 / shape.radius
	var down_east := shape.elevation((centre + east * step).normalized(), SPACING) \
		- shape.elevation((centre - east * step).normalized(), SPACING)
	var down_north := shape.elevation((centre + north * step).normalized(), SPACING) \
		- shape.elevation((centre - north * step).normalized(), SPACING)
	print("  downhill from the centre is %.0f m east, %.0f m north" % [
		-down_east, -down_north])


## The unit direction a given number of metres east and north of the centre.
func _at(centre: Vector3, east: Vector3, north: Vector3, radius: float,
		metres_east: float, metres_north: float) -> Vector3:
	return (centre + east * (metres_east / radius) + north * (metres_north / radius)).normalized()


## The biggest connected body of standing water on the grid, as cell indices —
## the sea, against the ponds and the river channels that also read as water at
## this resolution.
func _largest_body(shape: PlanetShape, centre: Vector3, east: Vector3, north: Vector3,
		heights: PackedFloat32Array, side: int) -> Array[int]:
	var standing := PackedByteArray()
	standing.resize(side * side)
	for index in side * side:
		if heights[index] > 0.0:
			continue
		var direction := _at(centre, east, north, shape.radius,
			(float(index % side) - float(side - 1) * 0.5) * STEP,
			(float(index / side) - float(side - 1) * 0.5) * STEP)
		standing[index] = 0 if float(shape.sample(direction)["river"]) > 0.0 else 1

	var seen := PackedByteArray()
	seen.resize(side * side)
	var largest: Array[int] = []
	for start in side * side:
		if seen[start] == 1 or standing[start] == 0:
			continue
		var body: Array[int] = [start]
		seen[start] = 1
		var at := 0
		while at < body.size():
			var index: int = body[at]
			at += 1
			var col := index % side
			var row := index / side
			for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var to_col := col + step.x
				var to_row := row + step.y
				if to_col < 0 or to_row < 0 or to_col >= side or to_row >= side:
					continue
				var neighbour := to_row * side + to_col
				if seen[neighbour] == 1 or standing[neighbour] == 0:
					continue
				seen[neighbour] = 1
				body.append(neighbour)
		if body.size() > largest.size():
			largest = body
	return largest


## Chebyshev distance to the nearest wet cell, in metres, by breadth-first sweep
## out from the water. Good to about half a cell, which is finer than the bands
## above are chosen to.
func _flood(to_water: PackedFloat32Array, frontier: Array[int], side: int) -> void:
	var next: Array[int] = []
	var depth := 0.0
	while not frontier.is_empty():
		depth += STEP
		next.clear()
		for index: int in frontier:
			var col := index % side
			var row := index / side
			for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var to_col := col + step.x
				var to_row := row + step.y
				if to_col < 0 or to_row < 0 or to_col >= side or to_row >= side:
					continue
				var neighbour := to_row * side + to_col
				if to_water[neighbour] <= depth:
					continue
				to_water[neighbour] = depth
				next.append(neighbour)
		frontier = next.duplicate()


## Worst height difference around the ship's own footprint, which is what decides
## whether it stands on four legs or on two.
func _spread(shape: PlanetShape, direction: Vector3, height: float) -> float:
	var east := direction.cross(Vector3.UP).normalized()
	var north := direction.cross(east)
	var worst := 0.0
	for index in FOOTPRINT_SAMPLES:
		var angle := TAU * float(index) / float(FOOTPRINT_SAMPLES)
		var offset := (east * cos(angle) + north * sin(angle)) * (FOOTPRINT / shape.radius)
		var probe := shape.elevation((direction + offset).normalized(), SPACING)
		if probe <= 0.0:
			return INF
		worst = maxf(worst, absf(probe - height))
	return worst


## The heading, in [SurfaceAnchor]'s degrees, that turns a prop's -Z toward the
## nearest wet cell — the shore the ship is actually beside, rather than the sea
## in general, which on a bay is a different direction.
func _toward_water(shape: PlanetShape, direction: Vector3, to_water: PackedFloat32Array,
		side: int, centre: Vector3, east: Vector3, north: Vector3,
		here: Vector2) -> float:
	var nearest := here
	var nearest_at := INF
	for index in side * side:
		if to_water[index] > 0.0:
			continue
		var offset := Vector2(
			(float(index % side) - float(side - 1) * 0.5) * STEP,
			(float(index / side) - float(side - 1) * 0.5) * STEP)
		var away := here.distance_to(offset)
		if away < nearest_at:
			nearest_at = away
			nearest = offset
	if nearest == here:
		return 0.0
	var toward := nearest - here
	var world := (east * toward.x + north * toward.y).normalized()
	# The frame `SurfaceAnchor` measures a facing from: its `_upright` picks this
	# same arbitrary tangent for -Z, and `facing` is the angle round to it.
	var hint := Vector3.FORWARD if absf(direction.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - direction * hint.dot(direction)).normalized()
	return rad_to_deg((-forward).signed_angle_to(world, direction))
