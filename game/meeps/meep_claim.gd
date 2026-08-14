class_name MeepClaim
extends RefCounted

## The town boundary: which cells of a [MeepGrid] belong to the colony.
##
## Derived, not authored. A flood fill leaves the ship, spreads over walkable
## ground, and stops where the ground does — so the shape of a town is an argument
## the terrain wins. At Vacationer's Landing that means the claim runs out to its
## full radius across the flats and stops dead at the lip of the chasm beside the
## lander, without anything here knowing that the chasm is there.
##
## That is also why the cap is a radius and the result is not a circle. The radius
## only says how far the colony is willing to walk to work; reachability says how
## much of that it actually got.
##
## The fill is connected on purpose. Ground on the far side of a canyon can be
## within the radius, level, and dry, and it is still not part of this town,
## because a Meep cannot get to it without leaving.

## Metres from the centre a first claim reaches for.
const DEFAULT_RADIUS := 100.0

var grid: MeepGrid
## Cell the fill started from, which is the cell the colony ship stands in.
var origin := Vector2i.ZERO
var radius := DEFAULT_RADIUS
## Cells claimed.
var count := 0
## The grid revision this was filled against, so a colony can tell that the ground
## has been recut underneath it.
var revision := -1

## One byte per cell: claimed or not. Kept beside the grid's own flags rather than
## only in them, because the fill needs a scratch mask it can write while it works
## and the grid's flags are read by everything.
var _claimed := PackedByteArray()
var _edges := PackedVector2Array()
var _edges_built := false


## Floods out from [param from], which is a point on the site map rather than a
## cell, so callers can hand over a ship's position without converting.
##
## Cheap enough for a worker thread and side-effect free apart from the grid's
## [constant MeepGrid.FLAG_CLAIMED] bits, which it writes in one pass at the end.
func build(for_grid: MeepGrid, from: Vector2, cap := DEFAULT_RADIUS) -> void:
	grid = for_grid
	radius = maxf(cap, 0.0)
	count = 0
	_edges.clear()
	_edges_built = false
	if grid == null:
		return
	var total := grid.cells * grid.cells
	_claimed.resize(total)
	# A resize keeps whatever was already there, and half of a previous claim is
	# worse than none of it.
	_claimed.fill(0)
	# Started from walkable ground near the centre rather than the centre itself, so
	# that every claimed cell can be stood in without exception — which is what lets
	# roads, buildings and routes all trust the mask instead of re-testing it.
	origin = grid.nearest_passable(grid.cell_of(from))
	if not grid.inside(origin) or not grid.passable(origin):
		_publish()
		return
	var queue := PackedInt32Array()
	queue.push_back(grid.index(origin))
	_claimed[grid.index(origin)] = 1
	count = 1
	# Measured from where the colony says it is, not from the cell the fill happened
	# to start in, so the radius means what it says.
	var reach_squared := radius * radius
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		var cell := Vector2i(at % grid.cells, at / grid.cells)
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
				Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbour := cell + step
			if not grid.inside(neighbour):
				continue
			var next := grid.index(neighbour)
			if _claimed[next] != 0 or not grid.passable(neighbour):
				continue
			if grid.centre_of(neighbour).distance_squared_to(from) > reach_squared:
				continue
			_claimed[next] = 1
			count += 1
			queue.push_back(next)
	revision = grid.revision
	_publish()


## Writes the fill into the grid in one pass. The grid's own setter bumps its
## revision per call, and eight thousand bumps would invalidate every cost field
## eight thousand times.
func _publish() -> void:
	for at in _claimed.size():
		if _claimed[at] != 0:
			grid.flags[at] = grid.flags[at] | MeepGrid.FLAG_CLAIMED
		else:
			grid.flags[at] = grid.flags[at] & ~MeepGrid.FLAG_CLAIMED
	grid.revision += 1
	revision = grid.revision


func contains_cell(cell: Vector2i) -> bool:
	if grid == null or not grid.inside(cell):
		return false
	return _claimed[grid.index(cell)] != 0


func contains(local: Vector2) -> bool:
	return contains_cell(grid.cell_of(local)) if grid != null else false


## Ground metres inside the boundary.
func area() -> float:
	return count * grid.cell_size * grid.cell_size if grid != null else 0.0


## How far the claim got along a bearing, in metres, and what stopped it there.
##
## The boundary is derived, so the only way to know whether a town ran out of
## radius or ran out of ground is to ask. Returns the reach and the [enum
## MeepGrid.Terrain] of the first cell outside it.
func reach_along(heading: Vector2) -> Array:
	if grid == null or heading == Vector2.ZERO:
		return [0.0, MeepGrid.Terrain.BLOCKED]
	var step := heading.normalized()
	var away := grid.cell_size
	var reach := 0.0
	while away <= radius + grid.cell_size:
		var cell := grid.cell_of(step * away)
		if not contains_cell(cell):
			return [reach, grid.terrain_at(cell)]
		reach = away
		away += grid.cell_size
	return [reach, MeepGrid.Terrain.BLOCKED]


# --- Boundary ----------------------------------------------------------------

## Every cell edge with the town on one side and the world on the other, as
## consecutive point pairs on the site map.
##
## Pairs rather than an ordered ring because that is what the wall wants — one
## MultiMesh instance per segment, in any order — and because the boundary of a
## town split around a rock is legitimately several rings.
func border_edges() -> PackedVector2Array:
	if not _edges_built:
		_trace()
	return _edges


func _trace() -> void:
	_edges.clear()
	_edges_built = true
	if grid == null:
		return
	var half := grid.cell_size * 0.5
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			if not contains_cell(cell):
				continue
			var middle := grid.centre_of(cell)
			# Wound so that the town is always on the same side of a segment,
			# which is what lets the wall face its posts outward.
			if not contains_cell(cell + Vector2i(1, 0)):
				_edges.push_back(middle + Vector2(half, -half))
				_edges.push_back(middle + Vector2(half, half))
			if not contains_cell(cell + Vector2i(-1, 0)):
				_edges.push_back(middle + Vector2(-half, half))
				_edges.push_back(middle + Vector2(-half, -half))
			if not contains_cell(cell + Vector2i(0, 1)):
				_edges.push_back(middle + Vector2(half, half))
				_edges.push_back(middle + Vector2(-half, half))
			if not contains_cell(cell + Vector2i(0, -1)):
				_edges.push_back(middle + Vector2(-half, -half))
				_edges.push_back(middle + Vector2(half, -half))


## The same boundary stitched into ordered rings.
##
## The wall does not need this; roads will. A ring is what you can walk along, set
## a gate into, or lay a ring road inside of, and none of those can be done with a
## bag of segments.
func border_loops() -> Array[PackedVector2Array]:
	var loops: Array[PackedVector2Array] = []
	var edges := border_edges()
	if edges.is_empty():
		return loops
	# Cell corners land on an exact lattice, so quantising by the cell size is a
	# rename rather than a rounding, and two segments that share a corner get the
	# same key for it.
	var scale := 1.0 / grid.cell_size
	var starts := {}
	for edge in edges.size() / 2:
		var key := _key(edges[edge * 2], scale)
		var here: PackedInt32Array = starts.get(key, PackedInt32Array())
		here.push_back(edge)
		starts[key] = here
	var walked := PackedByteArray()
	walked.resize(edges.size() / 2)
	for edge in walked.size():
		if walked[edge] != 0:
			continue
		var loop := PackedVector2Array()
		var current := edge
		while true:
			walked[current] = 1
			loop.push_back(edges[current * 2])
			var tail := edges[current * 2 + 1]
			var candidates: PackedInt32Array = starts.get(
				_key(tail, scale), PackedInt32Array())
			var next := -1
			for candidate in candidates:
				if walked[candidate] == 0:
					next = candidate
					break
			if next < 0:
				# Closed on itself, or ran into a corner already spent by another
				# ring. Either way this ring is finished.
				break
			current = next
		if loop.size() > 2:
			loops.push_back(loop)
	return loops


func _key(point: Vector2, scale: float) -> Vector2i:
	return Vector2i(roundi(point.x * scale), roundi(point.y * scale))
