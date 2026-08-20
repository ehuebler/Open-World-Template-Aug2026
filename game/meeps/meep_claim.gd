class_name MeepClaim
extends RefCounted

## The town boundary: which cells of a [MeepGrid] belong to the colony.
##
## Derived, not authored. A flood fill leaves the ship, spreads over claimable
## ground (plus coast-unlocked shallows), and stops where unsupported ground does
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
const CARDINAL_STEPS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

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
## Claimed cell indices in fill order. Boundary work walks these rather than all
## 36,864 cells in the navigation square.
var _cells := PackedInt32Array()
var _edges := PackedVector2Array()
var _edge_heights := PackedFloat32Array()
var _edges_built := false
var _surface_frontier := PackedInt32Array()
## Claimable cells reached by the fill but still beyond the current radius. A
## continuous border step starts here instead of flooding the entire town again.
var _growth_frontier := PackedInt32Array()
var _growth_frontier_mask := PackedByteArray()
## Claimed cells that can contribute a wall edge or constructed-surface frontier.
## Filled on the ground worker, then patched only around newly claimed cells.
var _boundary_cells: Dictionary = {}
var _centre := Vector2.ZERO
var _coasts := false
## Founding-blueprint cells currently approved for development. Empty means the
## legacy radial fill. The radial cap remains an outer safety/reach budget; this
## mask is what lets demand add one connected district lobe instead of another ring.
var _permit := PackedByteArray()
var _permit_revision := 0
var _applied_permit_revision := -1
## Cells newly admitted by an additive district activation. Keeping this delta lets
## expansion seed the new lobe from the old boundary instead of re-flooding 36k cells.
var _permit_added := PackedInt32Array()
var _permit_requires_rebuild := false
## Why the last [method expand] had to re-flood the whole square instead of adding
## a band, or empty if it did not. A full fill is two orders of magnitude dearer, so
## when one turns up in a frame the recorder needs to say what invalidated the claim
## rather than leave it looking like growth is simply expensive.
var last_rebuild_reason := &""


func bind_permit_mask(mask: PackedByteArray, mask_revision: int) -> void:
	if mask_revision == _permit_revision and mask.size() == _permit.size():
		return
	_permit_added.clear()
	_permit_requires_rebuild = false
	if _permit.size() == mask.size() and not _permit.is_empty():
		for index in mask.size():
			var was_permitted := _permit[index] != 0
			var now_permitted := mask[index] != 0
			if was_permitted and not now_permitted:
				_permit_requires_rebuild = true
				_permit_added.clear()
				break
			if now_permitted and not was_permitted:
				_permit_added.push_back(index)
	elif not _claimed.is_empty():
		# Founding first floods the initial radius on the ground worker, then binds
		# the blueprint on the main thread. Its core mask normally contains every
		# cell that fill reached, so restricting only still-unclaimed outer ground
		# does not justify repeating the flood.
		_permit_requires_rebuild = _permit.size() != 0 \
			or mask.size() != _claimed.size()
		if not _permit_requires_rebuild:
			for index in _claimed.size():
				if _claimed[index] != 0 and mask[index] == 0:
					_permit_requires_rebuild = true
					break
	_permit = mask.duplicate()
	_permit_revision = mask_revision


func claimed_cells() -> PackedInt32Array:
	return _cells.duplicate()


## Floods out from [param from], which is a point on the site map rather than a
## cell, so callers can hand over a ship's position without converting.
##
## Rival centres turn the radius cap into a spherical Voronoi territory. A cell
## can only belong to the nearest founded city. One cell-diagonal of neutral seam
## accounts for two independently oriented grids snapping the same world point to
## different centres, so their actual buildable footprints cannot overlap.
##
## Cheap enough for a worker thread and side-effect free apart from the grid's
## [constant MeepGrid.FLAG_CLAIMED] bits, which it writes in one pass at the end.
func build(for_grid: MeepGrid, from: Vector2, cap := DEFAULT_RADIUS,
		coasts := false,
		rival_centres := PackedVector3Array(),
		rival_wins_ties := PackedByteArray(),
		bump_grid_revision := true) -> void:
	grid = for_grid
	_centre = from
	_coasts = coasts
	radius = maxf(cap, 0.0)
	count = 0
	_cells.clear()
	_edges.clear()
	_edge_heights.clear()
	_edges_built = false
	_surface_frontier.clear()
	_growth_frontier.clear()
	_boundary_cells.clear()
	if grid == null:
		_growth_frontier_mask.clear()
		_applied_permit_revision = _permit_revision
		_permit_added.clear()
		_permit_requires_rebuild = false
		return
	var total := grid.cells * grid.cells
	_claimed.resize(total)
	# A resize keeps whatever was already there, and half of a previous claim is
	# worse than none of it.
	_claimed.fill(0)
	_growth_frontier_mask.resize(total)
	_growth_frontier_mask.fill(0)
	# The origin itself remains walkable even though coast claims may later include
	# shallow cells that cannot be stood on until a dock completes.
	origin = grid.nearest_passable(grid.cell_of(from))
	if not grid.inside(origin) or not grid.passable(origin):
		_applied_permit_revision = _permit_revision
		_permit_added.clear()
		_permit_requires_rebuild = false
		_publish(bump_grid_revision)
		return
	var queue := PackedInt32Array()
	queue.push_back(grid.index(origin))
	_claimed[grid.index(origin)] = 1
	count = 1
	# Measured from where the colony says it is, not from the cell the fill happened
	# to start in, so the radius means what it says.
	var reach_squared := radius * radius
	var side := grid.cells
	var cell_size := grid.cell_size
	var half_span := grid.half_span()
	var terrain := grid.terrain
	var flags := grid.flags
	var region_owner := grid.region_owner
	var has_region_owner := region_owner.size() == total
	var has_permit := _permit.size() == total
	var has_rivals := not rival_centres.is_empty()
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		var cell_x := at % side
		var cell_y := at / side
		for step: Vector2i in CARDINAL_STEPS:
			var next_x := cell_x + step.x
			var next_y := cell_y + step.y
			if next_x < 0 or next_y < 0 \
					or next_x >= side or next_y >= side:
				continue
			var next := next_y * side + next_x
			if _claimed[next] != 0 \
					or (has_region_owner and region_owner[next] == 0) \
					or (has_permit and _permit[next] == 0):
				continue
			var bits := int(flags[next])
			if (bits & MeepGrid.FLAG_SURFACE) == 0 \
					and terrain[next] != MeepGrid.Terrain.PASSABLE \
					and (not coasts
						or terrain[next] != MeepGrid.Terrain.SHALLOW):
				continue
			if has_rivals and not _owns_cell(
					Vector2i(next_x, next_y),
					rival_centres, rival_wins_ties):
				continue
			var local_x := (float(next_x) + 0.5) * cell_size - half_span
			var local_y := (float(next_y) + 0.5) * cell_size - half_span
			var delta_x := local_x - from.x
			var delta_y := local_y - from.y
			if delta_x * delta_x + delta_y * delta_y > reach_squared:
				_defer_growth(next)
				continue
			_claimed[next] = 1
			count += 1
			queue.push_back(next)
	_cells = queue
	_rebuild_boundary_cells()
	revision = grid.revision
	_applied_permit_revision = _permit_revision
	_permit_added.clear()
	_permit_requires_rebuild = false
	_publish(bump_grid_revision)


## Adds only the newly reached radial band to an otherwise unchanged claim.
##
## Continuous expansion advances by one two-metre cell every few seconds. Re-running
## [method build] for that used to flood and republish the whole 192x192 navigation
## square on the physics thread, producing a 140–270 ms hitch at each boundary step.
## The full fill records the first radius-limited cells it met; each expansion resumes
## from that frontier and touches only the new band. Terrain, constructed surfaces, or
## rival ownership changes still use [method build] so contraction remains exact.
func expand(for_grid: MeepGrid, from: Vector2, cap: float,
		coasts := false,
		rival_centres := PackedVector3Array(),
		rival_wins_ties := PackedByteArray()) -> bool:
	var wanted_radius := maxf(cap, 0.0)
	var additive_permit := _applied_permit_revision != _permit_revision \
		and not _permit_requires_rebuild
	last_rebuild_reason = &""
	if grid == null or grid != for_grid:
		last_rebuild_reason = &"regrid"
	elif _claimed.is_empty():
		last_rebuild_reason = &"unfilled"
	elif wanted_radius < radius:
		last_rebuild_reason = &"shrank"
	elif not from.is_equal_approx(_centre):
		last_rebuild_reason = &"recentred"
	elif coasts != _coasts:
		last_rebuild_reason = &"coasts"
	elif _applied_permit_revision != _permit_revision \
			and _permit_requires_rebuild:
		last_rebuild_reason = &"district"
	if not last_rebuild_reason.is_empty():
		var old_count := count
		var old_radius := radius
		build(for_grid, from, wanted_radius, coasts,
			rival_centres, rival_wins_ties, false)
		return count != old_count or not is_equal_approx(radius, old_radius)
	if wanted_radius <= radius and not additive_permit:
		return false

	var old_count := count
	radius = wanted_radius
	_edges.clear()
	_edge_heights.clear()
	_edges_built = false
	_surface_frontier.clear()
	var waiting := _growth_frontier
	_growth_frontier = PackedInt32Array()
	_growth_frontier_mask.fill(0)
	var queue := PackedInt32Array()
	var reach_squared := radius * radius
	for next in waiting:
		if next < 0 or next >= _claimed.size() or _claimed[next] != 0:
			continue
		var cell := Vector2i(next % grid.cells, next / grid.cells)
		if not grid.raw_claimable(cell, coasts) \
				or not _permitted(next) \
				or not _owns_cell(cell, rival_centres, rival_wins_ties):
			continue
		if grid.centre_of(cell).distance_squared_to(from) > reach_squared:
			_defer_growth(next)
			continue
		_claimed[next] = 1
		grid.flags[next] = grid.flags[next] | MeepGrid.FLAG_CLAIMED
		_cells.push_back(next)
		count += 1
		queue.push_back(next)

	if additive_permit:
		_seed_permit_additions(queue, coasts, rival_centres, rival_wins_ties)
		_applied_permit_revision = _permit_revision
		_permit_added.clear()
		_permit_requires_rebuild = false
	var band := queue
	for cell_index in _flood(queue, coasts, rival_centres, rival_wins_ties):
		band.push_back(cell_index)
	_refresh_boundary_around(band)
	revision = grid.revision
	return count != old_count


## Adds only the ground that a just-restored physical overlay made walkable.
##
## Bridge decks, ramps, and docks are the one thing that turns water and cliff
## cells into ground a Meep can stand on, and they are restored on the main thread
## after the ground bake's flood has already finished on its worker. Noticing them
## used to mean repeating that whole flood — 290 ms with the physics step held
## open, every time a town with a bridge rebaked. Overlays only ever add
## passability, so the claim can only grow, and everything it can gain is reachable
## from the cells that changed.
##
## [param restored] is the overlay cells; ownership and radius still decide, so a
## deck laid outside the boundary is refused exactly as the full fill would refuse
## it. Returns whether the claim actually grew.
func repair(restored: PackedInt32Array, coasts := false,
		rival_centres := PackedVector3Array(),
		rival_wins_ties := PackedByteArray()) -> bool:
	if grid == null or restored.is_empty() \
			or _claimed.size() != grid.cells * grid.cells:
		return false
	var queue := PackedInt32Array()
	var seeded := PackedByteArray()
	seeded.resize(_claimed.size())
	for cell_index in restored:
		if cell_index < 0 or cell_index >= _claimed.size() \
				or _claimed[cell_index] != 0:
			continue
		var cell := Vector2i(
			cell_index % grid.cells, cell_index / grid.cells)
		for step in CARDINAL_STEPS:
			var neighbour := cell + step
			if not grid.inside(neighbour):
				continue
			var neighbour_index := grid.index(neighbour)
			# Seeded from the claimed bank rather than from the deck itself, so a
			# run of new cells is reached in any order and one that no Meep can
			# walk to is still refused.
			if _claimed[neighbour_index] == 0 \
					or seeded[neighbour_index] != 0:
				continue
			seeded[neighbour_index] = 1
			queue.push_back(neighbour_index)
	if queue.is_empty():
		return false
	var gained := _flood(queue, coasts, rival_centres, rival_wins_ties)
	if gained.is_empty():
		return false
	_edges.clear()
	_edge_heights.clear()
	_edges_built = false
	_surface_frontier.clear()
	# The seeds go in as well: a bank cell that was a boundary because the water
	# beside it was impassable stops being one once the deck is walkable.
	for cell_index in queue:
		gained.push_back(cell_index)
	_refresh_boundary_around(gained)
	revision = grid.revision
	return true


## Seeds a newly activated district from cells already inside the town. District
## permits only grow during normal play, so this preserves the exact connected-fill
## result while touching the new lobe instead of every cell in the navigation square.
func _seed_permit_additions(queue: PackedInt32Array, coasts: bool,
		rival_centres: PackedVector3Array,
		rival_wins_ties: PackedByteArray) -> void:
	var reach_squared := radius * radius
	for next in _permit_added:
		if next < 0 or next >= _claimed.size() or _claimed[next] != 0 \
				or not _permitted(next):
			continue
		var cell := Vector2i(next % grid.cells, next / grid.cells)
		if not grid.raw_claimable(cell, coasts) \
				or not _owns_cell(cell, rival_centres, rival_wins_ties):
			continue
		var touches_claim := false
		for step in CARDINAL_STEPS:
			var neighbour := cell + step
			if grid.inside(neighbour) \
					and _claimed[grid.index(neighbour)] != 0:
				touches_claim = true
				break
		if not touches_claim:
			continue
		if grid.centre_of(cell).distance_squared_to(_centre) > reach_squared:
			_defer_growth(next)
			continue
		_claimed[next] = 1
		grid.flags[next] = grid.flags[next] | MeepGrid.FLAG_CLAIMED
		_cells.push_back(next)
		count += 1
		queue.push_back(next)


## The breadth-first step shared by growth and repair: claims everything reachable
## from [param queue] that is claimable, owned, and inside the radius, and defers
## the rest to the growth frontier. Cells already in [param queue] are assumed
## claimed; the returned array is what this pass added.
func _flood(queue: PackedInt32Array, coasts: bool,
		rival_centres: PackedVector3Array,
		rival_wins_ties: PackedByteArray) -> PackedInt32Array:
	var gained := PackedInt32Array()
	var reach_squared := radius * radius
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		var cell := Vector2i(at % grid.cells, at / grid.cells)
		for step: Vector2i in CARDINAL_STEPS:
			var neighbour := cell + step
			if not grid.inside(neighbour):
				continue
			var next := grid.index(neighbour)
			if _claimed[next] != 0 \
					or not _permitted(next) \
					or not grid.raw_claimable(neighbour, coasts) \
					or not _owns_cell(
						neighbour, rival_centres, rival_wins_ties):
				continue
			if grid.centre_of(neighbour).distance_squared_to(_centre) \
					> reach_squared:
				_defer_growth(next)
				continue
			_claimed[next] = 1
			grid.flags[next] = grid.flags[next] | MeepGrid.FLAG_CLAIMED
			_cells.push_back(next)
			count += 1
			queue.push_back(next)
			gained.push_back(next)
	return gained


func _permitted(cell_index: int) -> bool:
	if grid != null and not grid.regionally_owned_index(cell_index):
		return false
	return _permit.size() != _claimed.size() \
		or cell_index < 0 or cell_index >= _permit.size() \
		or _permit[cell_index] != 0


func _defer_growth(cell_index: int) -> void:
	if cell_index < 0 or cell_index >= _growth_frontier_mask.size() \
			or _growth_frontier_mask[cell_index] != 0:
		return
	_growth_frontier_mask[cell_index] = 1
	_growth_frontier.push_back(cell_index)


func _rebuild_boundary_cells() -> void:
	_boundary_cells.clear()
	for cell_index in _cells:
		_refresh_boundary_cell(cell_index)


func _refresh_boundary_around(changed: PackedInt32Array) -> void:
	var touched := PackedInt32Array()
	var touched_mask := PackedByteArray()
	touched_mask.resize(_claimed.size())
	for cell_index in changed:
		if touched_mask[cell_index] == 0:
			touched_mask[cell_index] = 1
			touched.push_back(cell_index)
		var cell := Vector2i(cell_index % grid.cells, cell_index / grid.cells)
		for step in CARDINAL_STEPS:
			var neighbour := cell + step
			if grid.inside(neighbour):
				var neighbour_index := grid.index(neighbour)
				if touched_mask[neighbour_index] == 0:
					touched_mask[neighbour_index] = 1
					touched.push_back(neighbour_index)
	for cell_index in touched:
		_refresh_boundary_cell(cell_index)


func _refresh_boundary_cell(cell_index: int) -> void:
	if cell_index < 0 or cell_index >= _claimed.size() \
			or _claimed[cell_index] == 0:
		_boundary_cells.erase(cell_index)
		return
	var cell := Vector2i(
		cell_index % grid.cells, cell_index / grid.cells)
	var passable := grid.passable(cell)
	for step in CARDINAL_STEPS:
		var neighbour := cell + step
		if not contains_cell(neighbour) \
				or (passable and not grid.passable(neighbour)):
			_boundary_cells[cell_index] = true
			return
	_boundary_cells.erase(cell_index)


## Nearest-centre ownership is independent of either city's current radius. That
## makes every shared frontier stable: one city never has to retract old ground when
## its neighbour's slower border eventually arrives.
func _owns_cell(cell: Vector2i, rival_centres: PackedVector3Array,
		rival_wins_ties: PackedByteArray) -> bool:
	if rival_centres.is_empty() or grid == null or grid.site == null:
		return true
	var local := grid.centre_of(cell)
	var direction := grid.site.direction_at(local)
	# Each grid can snap a queried world point by half a cell diagonal. Reserving a
	# little more than both errors combined makes `contains` mutually exclusive even
	# though neighbouring cities use differently rotated local maps.
	var clearance := grid.cell_size * 1.5
	var rival_score_limit := cos(
		(local.length() + clearance) / grid.site.planet_radius)
	for rival_index in rival_centres.size():
		var rival_score := direction.dot(rival_centres[rival_index])
		if rival_score > rival_score_limit + 0.000000001:
			return false
		if absf(rival_score - rival_score_limit) <= 0.000000001 \
				and rival_index < rival_wins_ties.size() \
				and rival_wins_ties[rival_index] != 0:
			return false
	return true


## Writes the fill into the grid in one pass. The grid's own setter bumps its
## revision per call, and eight thousand bumps would invalidate every cost field
## eight thousand times.
func _publish(bump_grid_revision := true) -> void:
	for at in _claimed.size():
		if _claimed[at] != 0:
			grid.flags[at] = grid.flags[at] | MeepGrid.FLAG_CLAIMED
		else:
			grid.flags[at] = grid.flags[at] & ~MeepGrid.FLAG_CLAIMED
	if bump_grid_revision:
		grid.revision += 1
	revision = grid.revision


func contains_cell(cell: Vector2i) -> bool:
	if grid == null or not grid.inside(cell):
		return false
	return _claimed[grid.index(cell)] != 0


## One byte per cell, non-zero inside the boundary, indexed the way the grid is.
##
## For the scans that ask about thousands of cells in one pass, where a
## bounds-checked call per cell is the whole cost. Read only: the fill writes this
## while it works, so a caller that changed it would be changing the boundary.
func claimed_mask() -> PackedByteArray:
	return _claimed


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


## Ground height on the claimed side of each pair returned by [method border_edges].
##
## The navigation grid already sampled this terrain at two-metre spacing on its
## worker. Reusing it keeps a visual boundary refresh from making hundreds of
## synchronous procedural height queries on the physics frame.
func border_heights() -> PackedFloat32Array:
	if not _edges_built:
		_trace()
	return _edge_heights


## Claimed walkable cells beside unsupported or not-yet-walkable claimed ground.
## Bridge and coast planners start only here; caching this with the already-cached
## wall trace avoids rescanning the complete navigation grid for every crossing.
func surface_frontier_cells() -> PackedInt32Array:
	if not _edges_built:
		_trace()
	return _surface_frontier


## Walks the boundary cells once, producing the wall's segments and the frontier the
## bridge and dock planners start from.
##
## Grid membership, passability and height are read out of their arrays here rather
## than through their accessors. A grown town has thousands of boundary cells and each
## one asks about its four neighbours, so this was tens of thousands of script calls
## and thirteen milliseconds of a rebaked town's physics step.
func _trace() -> void:
	_edges.clear()
	_edge_heights.clear()
	_surface_frontier.clear()
	_edges_built = true
	if grid == null:
		return
	var across := grid.cells
	var metres := grid.cell_size
	var half := metres * 0.5
	var offset := half - across * half
	var terrain := grid.terrain
	var flags := grid.flags
	var heights := grid.heights
	var surface_heights := grid.surface_heights
	var blocked := MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_SHIP
	var walkable := MeepGrid.Terrain.PASSABLE
	for at_variant: Variant in _boundary_cells:
		var at := int(at_variant)
		var x := at % across
		var y := at / across
		var middle := Vector2(x * metres + offset, y * metres + offset)
		var west := x > 0
		var east := x < across - 1
		var south := y > 0
		var north := y < across - 1
		if (terrain[at] == walkable
				or (flags[at] & MeepGrid.FLAG_SURFACE) != 0) \
				and (flags[at] & blocked) == 0:
			for neighbour in [
				at + 1 if east else -1,
				at - 1 if west else -1,
				at + across if north else -1,
				at - across if south else -1,
			]:
				if neighbour < 0 or _claimed[neighbour] == 0 \
						or (terrain[neighbour] != walkable
							and (flags[neighbour] & MeepGrid.FLAG_SURFACE) == 0) \
						or (flags[neighbour] & blocked) != 0:
					_surface_frontier.push_back(at)
					break
		# Wound so that the town is always on the same side of a segment,
		# which is what lets the wall face its posts outward.
		var height := surface_heights[at] \
			if is_finite(surface_heights[at]) else heights[at]
		if not east or _claimed[at + 1] == 0:
			_add_edge(middle + Vector2(half, -half),
				middle + Vector2(half, half), height)
		if not west or _claimed[at - 1] == 0:
			_add_edge(middle + Vector2(-half, half),
				middle + Vector2(-half, -half), height)
		if not north or _claimed[at + across] == 0:
			_add_edge(middle + Vector2(half, half),
				middle + Vector2(-half, half), height)
		if not south or _claimed[at - across] == 0:
			_add_edge(middle + Vector2(-half, -half),
				middle + Vector2(half, -half), height)


func _add_edge(from: Vector2, to: Vector2, height: float) -> void:
	_edges.push_back(from)
	_edges.push_back(to)
	_edge_heights.push_back(height)


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
