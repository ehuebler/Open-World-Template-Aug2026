@tool
class_name RoadMesh
extends RefCounted

## Triangles and colliders for a resolved [RoadNetwork], laid on a [CityPlan]'s
## ground.
##
## Knows nothing about which city it is building. Everything it needs arrives as
## the network's lines, [RoadProfile]'s cross-sections, and the plan's answers to
## "how high is the ground here" and "which way is up here" — so the same sweep
## builds a graded seaside town with viaducts over it and a flat inland grid, and
## neither one is a special case in here.
##
## A road is laid as several ribbons rather than one, because [RoadNetwork] has
## already taken a bite out of every centreline where it crosses another, and the
## crossing is then paved from the exact rings the ribbons stopped on. Sweeping
## straight through instead is simpler and wrong: it lays each road's raised
## footway across the mouth of every side street, leaves the four corners of a
## crossroads unpaved, and puts a second surface at exactly carriageway height for
## the depth buffer to argue with.

## Extra columns swept round the head of a cul-de-sac, between the two sides of the
## one road that reaches it.
const HEAD_ARC := 5
## Columns spent rounding one corner of a junction. Three is the difference between
## a kerb that turns and a kerb that has a corner cut off it; more buys very
## little, and there are four of these on every crossroads.
const CORNER_ARC := 3
## How far a corner's mitre may run from the two rim points it joins, as a multiple
## of the distance between them, before it is treated as a runaway and the corner
## is cut straight across instead.
const CORNER_REACH := 3.0
## Two road edges within this much of parallel have no usable meeting point. About
## eight degrees.
const CORNER_PARALLEL := 0.15

## Metres between piers, and how wide one is at the deck and at the ground. A
## viaduct closer to the ground than [constant PIER_MIN_HEIGHT] is riding on fill,
## not on legs.
const PIER_SPACING := 42.0
const PIER_TOP := 2.2
const PIER_FOOT := 3.2
const PIER_MIN_HEIGHT := 2.5

## Metres of collision per body. A whole city in one concave shape would have an
## axis-aligned box two kilometres across and never be culled by the broad phase,
## so it is cut into tiles that can be.
const TILE := 300.0

## Cell size of the map of what is on the ground, in metres. Only the piers ask it
## anything, and they ask about eighty times a build, so this is sized to keep a
## bucket short rather than to keep the table small.
const BELOW_CELL := 64.0

## Triangles waiting to be turned into bodies, keyed by tile. Read by [method
## bodies] and emptied as it goes.
var tiles: Dictionary = {}

## Where the viaducts' legs came down, on the map, in the order they were laid.
## Kept for the harness, which is the only thing that can tell whether they stayed
## off the streets and whether avoiding them stretched a span.
var piers: PackedVector2Array = PackedVector2Array()

var _plan: CityPlan
var _network: RoadNetwork
var _origin := Vector3.ZERO
var _radius := 0.0
## Rim columns each road left where it stopped at a junction, by junction id.
var _stubs: Dictionary = {}
## Which tile the geometry being emitted right now belongs to. Set from the map
## coordinate the work is happening at, because the node's own axes are the
## planet's and one of them points more or less straight up out of the ground —
## hashing a vertex by those would drop the whole city into one row of tiles.
var _tile := Vector2i.ZERO
## Every ground road's footprint, bucketed by map cell, so a pier can find out what
## is under it without walking the whole city.
var _below: Dictionary = {}


func _init(plan: CityPlan, network: RoadNetwork, origin: Vector3,
		planet_radius: float) -> void:
	_plan = plan
	_network = network
	_origin = origin
	_radius = planet_radius


## Sweeps every run, paves every junction, and hands back the one mesh all of it
## went into. Fills [member tiles] on the way, so call this before [method bodies].
func build() -> ArrayMesh:
	_below = _ground_map()
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	for run: Dictionary in _network.runs:
		_lay(mesh, run)
	_pave_junctions(mesh)
	mesh.generate_normals()
	return mesh.commit()


## One static body per tile of city, each holding its own triangles relative to its
## own centre. Parent them to the node the mesh went under.
func bodies() -> Array[StaticBody3D]:
	var made: Array[StaticBody3D] = []
	for tile: Vector2i in tiles:
		var faces: PackedVector3Array = tiles[tile]
		if faces.is_empty():
			continue
		var middle := Vector3((float(tile.x) + 0.5) * TILE, 0.0,
			(float(tile.y) + 0.5) * TILE)
		var moved := PackedVector3Array()
		moved.resize(faces.size())
		for index in faces.size():
			moved[index] = faces[index] - middle
		var collider := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(moved)
		collider.shape = shape
		var body := StaticBody3D.new()
		body.name = "Tile%d_%d" % [tile.x, tile.y]
		body.position = middle
		body.add_child(collider)
		made.append(body)
	tiles.clear()
	return made


# --- Ribbons ----------------------------------------------------------------

## One run of centreline into a ribbon of triangles. Viaducts are swept closed and
## get their legs; everything else records where it stopped, so the junction can be
## paved from the ribbon's own last ring.
func _lay(mesh: SurfaceTool, run: Dictionary) -> void:
	var kind: Dictionary = run["kind"]
	var path: PackedVector3Array = run["path"]
	if path.size() < 2:
		return
	if bool(kind["deck"]):
		_sweep(mesh, path, kind, RoadProfile.deck(kind), true)
		_raise_piers(mesh, path, kind)
		return
	var rings := _sweep(mesh, path, kind, RoadProfile.ground(kind), false)
	if rings.is_empty():
		return
	_stub(String(run["from"]), rings[0], path, 0, kind)
	_stub(String(run["to"]), rings[rings.size() - 1], path, path.size() - 1, kind)


## Extrudes a profile along a centreline and hands back the rings it built, so a
## caller that cut the line short can pave the junction from its exact ends.
func _sweep(mesh: SurfaceTool, path: PackedVector3Array, kind: Dictionary,
		profile: Dictionary, closed: bool) -> Array[PackedVector3Array]:
	var rings: Array[PackedVector3Array] = []
	if path.size() < 2:
		return rings
	var points: PackedVector2Array = profile["points"]
	var tones: PackedColorArray = profile["tones"]
	for index in path.size():
		rings.append(_ring(path, index, points, kind))
	for index in path.size() - 1:
		_tile = _tile_of(Vector2(path[index].x, path[index].y))
		_stitch(mesh, rings[index], rings[index + 1], tones, closed)
	if closed:
		var last := rings.size() - 1
		_tile = _tile_of(Vector2(path[0].x, path[0].y))
		_cap(mesh, rings[0], rings[0][0] - rings[1][0])
		_tile = _tile_of(Vector2(path[last].x, path[last].y))
		_cap(mesh, rings[last], rings[last][0] - rings[last - 1][0])
	return rings


## One cross-section, in planet-local metres relative to the city's origin.
##
## [param points] is the shape being extruded, as offsets across the road and
## heights above its surface. The frame is rebuilt per station from the map
## tangent, so a road keeps its width through a curve.
func _ring(path: PackedVector3Array, index: int, points: PackedVector2Array,
		kind: Dictionary) -> PackedVector3Array:
	var here := path[index]
	var local := Vector2(here.x, here.y)
	var ahead := path[mini(index + 1, path.size() - 1)]
	var behind := path[maxi(index - 1, 0)]
	var along := (Vector2(ahead.x, ahead.y) - Vector2(behind.x, behind.y))
	if along.length_squared() < 1e-9:
		along = Vector2.UP
	var across := along.normalized().orthogonal()
	var base := _plan.pad_height(local) + float(kind["lift"]) + here.z

	var ring := PackedVector3Array()
	for point: Vector2 in points:
		var at := local + across * point.x
		# Height is measured off the ground under the road's centre rather than off
		# the ground under each edge, so a wide road stays flat across itself
		# instead of tilting with the city's grade.
		ring.append(_place(at, base + point.y))
	return ring


## Shuts the end of a box girder, so a viaduct is a solid and not a pipe.
##
## Worth the three quads: a tube open at both ends is a tube something can be
## inside, and a body inside a concave shell is a body that cannot be pushed out of
## one. The ends that are not buried in an embankment are at ramp feet and at the
## joints between a skyway and its ramps, which is exactly where anybody driving or
## flying along the deck arrives.
##
## [param onward] points out of the end being closed. Which way round the three
## quads have to be wound depends on which end this is, so rather than write two
## versions the first triangle's normal is measured and the lot is flipped if it
## came out facing back into the box.
func _cap(mesh: SurfaceTool, ring: PackedVector3Array, onward: Vector3) -> void:
	if ring.size() != 8:
		return
	# The cross-section is not convex — the carriageway is a channel between the two
	# parapets — so it is cut into the three blocks it obviously is: a parapet, the
	# girder under the road, and the other parapet.
	var blocks := [[0, 1, 2, 3], [0, 3, 4, 7], [4, 5, 6, 7]]
	var first: Array = blocks[0]
	var facing := (ring[first[2]] - ring[first[0]]).cross(
		ring[first[1]] - ring[first[0]])
	var flip := facing.dot(onward) < 0.0
	var tone := RoadProfile.PIER
	for block: Array in blocks:
		if flip:
			_quad(mesh, ring[block[3]], ring[block[2]], ring[block[1]],
				ring[block[0]], tone, tone)
		else:
			_quad(mesh, ring[block[0]], ring[block[1]], ring[block[2]],
				ring[block[3]], tone, tone)


## Two rings into a strip of quads, with the profile's own tones carried onto the
## vertices. Decks close back on themselves; ground roads do not.
func _stitch(mesh: SurfaceTool, from: PackedVector3Array, to: PackedVector3Array,
		tones: PackedColorArray, closed: bool) -> void:
	var count := tones.size()
	for edge in count - (0 if closed else 1):
		var next := (edge + 1) % count
		_quad(mesh, from[edge], from[next], to[next], to[edge],
			tones[edge], tones[next])


# --- Junctions --------------------------------------------------------------

## Records one road's arrival at a junction: the two rim columns it stopped on,
## where they sit on the map, and which way the road leaves.
##
## The columns are the ribbon's own vertices, not a fresh cross-section at the same
## place. That is the whole reason the junction has no seam to find — the two
## surfaces are not merely flush, they share their corners.
func _stub(id: String, ring: PackedVector3Array, path: PackedVector3Array,
		index: int, kind: Dictionary) -> void:
	if id.is_empty() or not _network.junctions.has(id):
		return
	var here := path[index]
	var forward := index == 0
	var other := path[1] if forward else path[path.size() - 2]
	var away := Vector2(other.x, other.y) - Vector2(here.x, here.y)
	if away.length_squared() < 1e-9:
		return
	away = away.normalized()

	# _ring names its sides off the direction of travel, which at the far end of a
	# run is the direction back into the junction.
	var sides := _columns(ring)
	var rim := RoadProfile.rim(kind)
	var offsets: PackedFloat32Array = rim["offsets"]
	var at := Vector2(here.x, here.y)
	var right_map := PackedVector2Array()
	var left_map := PackedVector2Array()
	for slot in 4:
		right_map.append(at + away.orthogonal() * offsets[slot])
		left_map.append(at - away.orthogonal() * offsets[slot])

	if not _stubs.has(id):
		_stubs[id] = [] as Array[Dictionary]
	(_stubs[id] as Array[Dictionary]).append({
		"dir": away, "at": at,
		"base": _plan.pad_height(at) + float(kind["lift"]) + here.z,
		"left": sides[0] if forward else sides[1],
		"right": sides[1] if forward else sides[0],
		"left_map": left_map, "right_map": right_map,
		"heights": rim["heights"], "tones": RoadProfile.rim_tones(kind)})


## A cross-section ring split into its left and right rim columns, outermost point
## first. A profile with no footway repeats its edge into the two slots a kerb
## would have used.
func _columns(ring: PackedVector3Array) -> Array[PackedVector3Array]:
	if ring.size() == 4:
		return [
			PackedVector3Array([ring[0], ring[1], ring[1], ring[1]]),
			PackedVector3Array([ring[3], ring[2], ring[2], ring[2]])]
	return [
		PackedVector3Array([ring[0], ring[1], ring[2], ring[3]]),
		PackedVector3Array([ring[7], ring[6], ring[5], ring[4]])]


## The paving where roads meet: one carriageway across the middle, and the footways
## carried round every corner, so a kerb turns the corner instead of running out
## across the road it crosses.
func _pave_junctions(mesh: SurfaceTool) -> void:
	for id: String in _stubs:
		var stubs: Array[Dictionary] = _stubs[id]
		if stubs.is_empty():
			continue
		_tile = _tile_of((_network.junctions[id] as Dictionary)["at"] as Vector2)
		# Anticlockwise seen from above, which is the order the rim is walked in and
		# the order the winding in _quad and _triangle expects.
		stubs.sort_custom(func(one: Dictionary, two: Dictionary) -> bool:
			var a: Vector2 = one["dir"]
			var b: Vector2 = two["dir"]
			return atan2(a.y, a.x) < atan2(b.y, b.x))

		var rim: Array[PackedVector3Array] = []
		var tones: Array[PackedColorArray] = []
		# Whether the span from this column to the next is the open mouth of a road
		# rather than paving. Only the carriageway crosses a mouth.
		var mouth: Array[bool] = []
		for index in stubs.size():
			var stub: Dictionary = stubs[index]
			rim.append(stub["right"])
			tones.append(stub["tones"])
			mouth.append(true)
			rim.append(stub["left"])
			tones.append(stub["tones"])
			mouth.append(false)
			for column: Dictionary in _corner(stub,
					stubs[(index + 1) % stubs.size()], stubs.size()):
				rim.append(column["points"])
				tones.append(column["tones"])
				mouth.append(false)

		_fill(mesh, rim)
		for index in rim.size():
			if mouth[index]:
				continue
			var next := (index + 1) % rim.size()
			for slot in 3:
				# Inward to outward paired with anticlockwise, which is the same
				# handedness as across-then-along on a ribbon.
				_quad(mesh, rim[index][slot + 1], rim[index][slot],
					rim[next][slot], rim[next][slot + 1],
					tones[index][slot + 1], tones[index][slot])


## The carriageway inside a rim: a fan from the middle out to every column's
## innermost point, which spans the mouths of the roads as well as the corners
## between them.
func _fill(mesh: SurfaceTool, rim: Array[PackedVector3Array]) -> void:
	var middle := Vector3.ZERO
	for column: PackedVector3Array in rim:
		middle += column[3]
	middle /= float(rim.size())
	var asphalt := RoadProfile.ASPHALT
	for index in rim.size():
		_triangle(mesh, middle, rim[(index + 1) % rim.size()][3],
			rim[index][3], asphalt, asphalt, asphalt)


## The columns between one road leaving a junction and the next one round.
##
## Rounded, as a kerb is. The point where the two roads' edges would have met is
## the corner's apex, and it used to be the corner: one column there, and the
## footway ran into it and out again as a spike. Every crossing therefore had four
## barbs on it, which is what a junction looks like when it is mitred like a
## picture frame instead of built like a road.
##
## So the apex is demoted to the control point of a quadratic through it, from the
## edge of one road to the edge of the next. That curve leaves each road exactly
## along its own kerb line and arrives along the other's, which is the definition
## of a fillet, and its radius comes out of the setback the junction was already cut
## back by — a few metres on a lane, a dozen on a boulevard, which is about what a
## real corner is. Where [method _meet] gives up and returns the midpoint the curve
## flattens to a straight chamfer, which is the right answer for two roads meeting
## nearly head on.
##
## A junction with one road is a cul-de-sac, and its "corner" is the whole head.
func _corner(one: Dictionary, two: Dictionary, arms: int) -> Array[Dictionary]:
	if arms < 2:
		return _head(one)
	var da: Vector2 = one["dir"]
	var db: Vector2 = two["dir"]
	var left: PackedVector2Array = one["left_map"]
	var right: PackedVector2Array = two["right_map"]
	var base_one := float(one["base"])
	var base_two := float(two["base"])
	var lift_one: PackedFloat32Array = one["heights"]
	var lift_two: PackedFloat32Array = two["heights"]
	var tone_one: PackedColorArray = one["tones"]
	var tone_two: PackedColorArray = two["tones"]

	var apex := PackedVector2Array()
	for slot in 4:
		apex.append(_meet(left[slot], da, right[slot], db))

	var columns: Array[Dictionary] = []
	for step in CORNER_ARC:
		var t := float(step + 1) / float(CORNER_ARC + 1)
		var points := PackedVector3Array()
		var tones := PackedColorArray()
		for slot in 4:
			var at := left[slot].lerp(apex[slot], t).lerp(
				apex[slot].lerp(right[slot], t), t)
			points.append(_place(at, lerpf(base_one, base_two, t)
				+ lerpf(lift_one[slot], lift_two[slot], t)))
			tones.append(tone_one[slot].lerp(tone_two[slot], t))
		columns.append({"points": points, "tones": tones})
	return columns


## The rounded head of a cul-de-sac, swept from the road's left side round the back
## to its right. Centred on the ring the road stopped on, so the head reaches
## exactly as far as the junction the layout put there.
func _head(stub: Dictionary) -> Array[Dictionary]:
	var at: Vector2 = stub["at"]
	var dir: Vector2 = stub["dir"]
	var offsets := _rim_offsets(stub)
	var base: float = stub["base"]
	var heights: PackedFloat32Array = stub["heights"]
	var tones: PackedColorArray = stub["tones"]
	var columns: Array[Dictionary] = []
	for step in HEAD_ARC:
		# From the left edge round the far side of the junction to the right, which
		# is the half the road does not occupy.
		var turn := PI * 0.5 + PI * float(step + 1) / float(HEAD_ARC + 1)
		var out := dir.rotated(turn)
		var points := PackedVector3Array()
		for slot in 4:
			points.append(_place(at + out * offsets[slot], base + heights[slot]))
		columns.append({"points": points, "tones": tones})
	return columns


## A stub's offsets, recovered from the map positions it recorded rather than from
## its kind, which it did not keep.
func _rim_offsets(stub: Dictionary) -> PackedFloat32Array:
	var at: Vector2 = stub["at"]
	var right: PackedVector2Array = stub["right_map"]
	var offsets := PackedFloat32Array()
	for slot in 4:
		offsets.append(at.distance_to(right[slot]))
	return offsets


## Where two road edges would have met. Falls back to straight across when the two
## are near enough to parallel, or far enough apart, that the meeting point runs
## away — a bend with a road joining it, mostly, where straight across is what the
## corner looks like anyway.
func _meet(pa: Vector2, da: Vector2, pb: Vector2, db: Vector2) -> Vector2:
	var middle := (pa + pb) * 0.5
	var turn := da.cross(db)
	if absf(turn) < CORNER_PARALLEL:
		return middle
	var meet := pa + da * ((pb - pa).cross(db) / turn)
	if meet.distance_to(middle) > pa.distance_to(pb) * CORNER_REACH + 2.0:
		return middle
	return meet


# --- Piers ------------------------------------------------------------------

## Every ground road, as fattened segments in a grid, for the piers to avoid.
##
## Each segment is filed under every cell its own footprint plus a pier's can
## reach, so a query is one bucket and no neighbours. That costs a little
## duplication and buys an answer that cannot miss a road lying just over a cell
## boundary — which, at 42 m between legs and 64 m between cells, would otherwise be
## most of them.
func _ground_map() -> Dictionary:
	var cells := {}
	for trace: Dictionary in _network.traces:
		var kind: Dictionary = trace["kind"]
		if bool(kind["deck"]):
			continue
		# The carriageway and no more. Keeping legs off the footway as well reads as
		# the safer rule and is the wrong one: it suppressed half the Skyway's piers
		# and left it spanning a hundred metres between legs, which looks far worse
		# than the thing it was avoiding. A pier on the pavement is what a real
		# viaduct does, and this still keeps every one of them out of the traffic —
		# a leg is only 2.3 m from its own centre to its side, so standing this far
		# out it cannot reach the tarmac.
		var clear := RoadProfile.clearance(kind)
		var path: PackedVector3Array = trace["path"]
		for index in range(1, path.size()):
			var a := Vector2(path[index - 1].x, path[index - 1].y)
			var b := Vector2(path[index].x, path[index].y)
			var span := {"a": a, "b": b, "clear": clear}
			var pad := clear + PIER_FOOT
			for x in range(floori((minf(a.x, b.x) - pad) / BELOW_CELL),
					floori((maxf(a.x, b.x) + pad) / BELOW_CELL) + 1):
				for y in range(floori((minf(a.y, b.y) - pad) / BELOW_CELL),
						floori((maxf(a.y, b.y) + pad) / BELOW_CELL) + 1):
					var key := Vector2i(x, y)
					if not cells.has(key):
						cells[key] = [] as Array[Dictionary]
					(cells[key] as Array[Dictionary]).append(span)
	return cells


## Whether a leg [param need] metres across can stand at [param local] without
## putting a foot on a street or its footway. [param need] may not exceed
## [constant PIER_FOOT], which is what the buckets were padded by.
func clear_below(local: Vector2, need: float) -> bool:
	var key := Vector2i(floori(local.x / BELOW_CELL), floori(local.y / BELOW_CELL))
	if not _below.has(key):
		return true
	for span: Dictionary in _below[key] as Array[Dictionary]:
		var closest := Geometry2D.get_closest_point_to_segment(
			local, span["a"], span["b"])
		if closest.distance_to(local) < float(span["clear"]) + need:
			return false
	return true


## Legs under a viaduct, wherever it is far enough off the ground to need them.
##
## A leg that is due where a street runs underneath is not dropped on it and is not
## abandoned either: it stays due and takes the first station past the road, so the
## span either side stretches by a few metres and the carriageway below stays clear.
## Which is what a viaduct actually does — the whole reason to build one is not to
## put anything in the way of what it crosses.
func _raise_piers(mesh: SurfaceTool, path: PackedVector3Array,
		kind: Dictionary) -> void:
	var travelled := PIER_SPACING
	for index in range(1, path.size()):
		var here := path[index]
		travelled += Vector2(here.x, here.y).distance_to(
			Vector2(path[index - 1].x, path[index - 1].y))
		if travelled < PIER_SPACING:
			continue
		var local := Vector2(here.x, here.y)
		var ground := _plan.pad_height(local)
		var top := ground + float(kind["lift"]) + here.z - RoadProfile.GIRDER
		if top - ground < PIER_MIN_HEIGHT:
			# Riding on fill, not on legs. Reset, so the first leg past the
			# embankment stands a full span out and not at its toe.
			travelled = 0.0
			continue
		if not clear_below(local, PIER_FOOT):
			continue
		travelled = 0.0
		piers.append(local)
		_tile = _tile_of(local)
		for corner in 4:
			var one := TAU * (float(corner) + 0.5) / 4.0
			var two := TAU * (float(corner) + 1.5) / 4.0
			var a := Vector2(cos(one), sin(one))
			var b := Vector2(cos(two), sin(two))
			_quad(mesh,
				_place(local + a * PIER_FOOT, ground),
				_place(local + b * PIER_FOOT, ground),
				_place(local + b * PIER_TOP, top),
				_place(local + a * PIER_TOP, top),
				RoadProfile.PIER, RoadProfile.PIER)


# --- Geometry ---------------------------------------------------------------

## A point on the map at a height above sea level, in the city node's own space.
func _place(local: Vector2, height: float) -> Vector3:
	return _plan.direction_at(local) * (_radius + height) - _origin


func _tile_of(local: Vector2) -> Vector2i:
	return Vector2i(floori(local.x / TILE), floori(local.y / TILE))


## One quad, as two triangles. [param near] belongs to the two vertices on the
## profile edge the strip started from and [param far] to the two it ran to, so a
## kerb reads as a step rather than as a gradient.
##
## Wound backwards from the order the corners are given in. The map frame is
## right-handed with the up out of the planet, so walking a profile across a road
## and then along it traces a triangle anticlockwise seen from above — and Godot's
## front face is the clockwise one. Left as it comes, every road is culled and only
## the viaducts survive, because a closed box still shows its far wall.
func _quad(mesh: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		near: Color, far: Color) -> void:
	_triangle(mesh, a, c, b, near, far, far)
	_triangle(mesh, a, d, c, near, near, far)


## One triangle into the mesh and into whichever collision tile is current.
##
## Slivers are dropped. A junction rim carries a column for a kerb whether the road
## it came from has one or not, so a path meeting a lane emits several quads of no
## width, and a degenerate face is a normal nobody can compute and a triangle the
## collision BVH has to hold anyway.
func _triangle(mesh: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		first: Color, second: Color, third: Color) -> void:
	if (b - a).cross(c - a).length_squared() < 1e-8:
		return
	mesh.set_color(first)
	mesh.add_vertex(a)
	mesh.set_color(second)
	mesh.add_vertex(b)
	mesh.set_color(third)
	mesh.add_vertex(c)
	if not tiles.has(_tile):
		tiles[_tile] = PackedVector3Array()
	var faces: PackedVector3Array = tiles[_tile]
	faces.append(a)
	faces.append(b)
	faces.append(c)
	tiles[_tile] = faces
