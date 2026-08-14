class_name MeepGrid
extends RefCounted

## What a colony knows about the ground it stands on: one byte of terrain and one
## of intent per two metres, over a square of map centred on the settlement.
##
## This exists because the planet's collider does not. Chunks are only given a
## [ConcavePolygonShape3D] within a couple of hundred metres of a viewer, so a
## Meep working on the far side of its town — never mind a town nobody is at — has
## no geometry under it to cast a ray against. The height field always answers,
## costs half a microsecond, and is const, so it can be asked sixteen thousand
## times on a worker thread while the game runs.
##
## Asked once, that is. The point of baking it is that a crevasse edge is
## expensive to discover and cheap to remember: the flood fill that draws the
## boundary, the cost field that routes every walk, and every step a Meep takes
## all read these bytes instead of the field.
##
## Sampled at the spacing the terrain is actually drawn at rather than the finest
## it can be. A coarse chunk draws a lid across a gorge, and a grid built from the
## finest field would mark the floor of that gorge walkable while the ground the
## player can see is thirty metres above it.

## Terrain as a Meep sees it. Only [constant Terrain.PASSABLE] can be stood on;
## the rest differ so that the reason a town stopped growing somewhere can be
## reported rather than guessed at.
enum Terrain {
	## Walkable ground.
	PASSABLE,
	## Too steep to climb, which on this planet is mostly canyon wall and mesa
	## riser.
	STEEP,
	## At or under the waterline. Includes the shoreline margin, because a town
	## that builds to the exact water's edge looks like a mistake.
	WATER,
	## A cliff edge, a pit, or the floor of either: somewhere with a fall next to
	## it. See [constant FALL_LIMIT].
	VOID,
	## Held by something the colony put there, or by terrain that was recut after
	## the bake.
	BLOCKED,
}

## Metres per cell. Two is a Meep's own stride and about the narrowest road worth
## laying, which keeps the grid honest as both a navigation mesh and a plan.
const CELL := 2.0
## Cells across. 128 at two metres is a 256 m square, which holds a 100 m claim
## with room for it to grow before any of this has to be rebuilt bigger.
const CELLS := 128

## Nothing here yet.
const FLAG_NONE := 0
## Inside the town boundary. Written by [MeepClaim].
const FLAG_CLAIMED := 1 << 0
## Reserved for the roads pass: a laid road, which is cheaper to walk than raw
## ground.
const FLAG_ROAD := 1 << 1
## Reserved for the buildings pass: standing structure, which is not.
const FLAG_BUILDING := 1 << 2
## Promised to a job that has not finished, so two crews cannot plan the same
## square.
const FLAG_RESERVED := 1 << 3

## Steepest ground a Meep will walk, in degrees. Generous enough for dunes and
## hillside, mean enough to refuse the canyon walls at Vacationer's Landing.
const MAX_SLOPE_DEGREES := 38.0
## Metres of drop to an adjacent cell that makes this one a ledge. Roughly twice a
## Meep's height: survivable to walk beside, not to walk off, and small enough
## that the rim of the chasm by the colony ship is caught by the first cell that
## can see down it.
const FALL_LIMIT := 3.5
## Metres above sea level a cell has to be to count as dry land. The shoreline
## itself is left to the sea so that a boundary drawn against it sits above the
## tide rather than in it.
const SHORE_MARGIN := 0.6

## Cost units for one orthogonal step of open ground. Ten rather than one so that
## a road can be cheaper than dirt later without any of this becoming fractional.
const STEP_COST := 10
## sqrt(2), in the same units.
const DIAGONAL_COST := 14
## Added for every point of hazard on a cell. Reserved for the mobs pass: a Meep
## will detour a long way around somewhere its colony has learned to fear, but
## will still cross it rather than refuse to move.
const HAZARD_COST := 6

var site: MeepSite
var cells := CELLS
var cell_size := CELL
## Terrain class per cell. See [enum Terrain].
var terrain := PackedByteArray()
## What the colony has decided about each cell. A mask of the FLAG_ constants.
var flags := PackedByteArray()
## How dangerous each cell is, 0-255. Nothing writes this yet; the cost field
## already reads it, so the mobs pass is a writer and not a redesign.
var hazard := PackedByteArray()
## Ground height above sea level per cell, in metres.
var heights := PackedFloat32Array()
## Bumped whenever anything above changes, so cost fields built against an older
## version of the ground know to throw themselves away.
var revision := 0
var built := false

## Half the map's width in metres, cached because every coordinate conversion
## needs it.
var _half := 0.0


func _init(for_site: MeepSite, across := CELLS, metres := CELL) -> void:
	site = for_site
	cells = maxi(across, 8)
	cell_size = maxf(metres, 0.25)
	_half = cells * cell_size * 0.5
	var total := cells * cells
	terrain.resize(total)
	flags.resize(total)
	hazard.resize(total)
	heights.resize(total)


## Metres from the colony centre to the edge of the map.
func half_span() -> float:
	return _half


# --- Coordinates -------------------------------------------------------------

func index(cell: Vector2i) -> int:
	return cell.y * cells + cell.x


func inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < cells and cell.y < cells


## The cell containing a point on the site map. Not clamped: a caller outside the
## grid has to know that, because the honest answer to "what is the ground like
## out there" is that this colony has not looked.
func cell_of(local: Vector2) -> Vector2i:
	return Vector2i(
		floori((local.x + _half) / cell_size),
		floori((local.y + _half) / cell_size))


## The centre of a cell, on the site map.
func centre_of(cell: Vector2i) -> Vector2:
	return Vector2(
		(cell.x + 0.5) * cell_size - _half,
		(cell.y + 0.5) * cell_size - _half)


# --- Reads -------------------------------------------------------------------

func terrain_at(cell: Vector2i) -> Terrain:
	if not inside(cell):
		return Terrain.BLOCKED
	return terrain[index(cell)] as Terrain


func height_at(cell: Vector2i) -> float:
	if not inside(cell):
		return 0.0
	return heights[index(cell)]


func flags_at(cell: Vector2i) -> int:
	if not inside(cell):
		return FLAG_NONE
	return flags[index(cell)]


func has_flag(cell: Vector2i, flag: int) -> bool:
	return (flags_at(cell) & flag) != 0


func set_flag(cell: Vector2i, flag: int, on := true) -> void:
	if not inside(cell):
		return
	var at := index(cell)
	var was := flags[at]
	flags[at] = (was | flag) if on else (was & ~flag)
	if flags[at] != was:
		revision += 1


## Whether a Meep can stand here. Blocked cells and everything outside the map are
## no; a claim is not required, because Meeps walk out of their town to work.
func passable(cell: Vector2i) -> bool:
	if not inside(cell):
		return false
	if terrain[index(cell)] != Terrain.PASSABLE:
		return false
	return (flags[index(cell)] & FLAG_BUILDING) == 0


## What crossing this cell costs, in the units of [constant STEP_COST]. Only
## called for cells that are already [method passable].
func cost_at(cell: Vector2i) -> int:
	var at := index(cell)
	var cost := STEP_COST
	# Roads are the whole reason cost is not a boolean. Nothing sets this flag in
	# this build; when the roads pass does, every Meep on the planet starts
	# preferring them without a line changing here or in the cost field.
	if (flags[at] & FLAG_ROAD) != 0:
		cost = STEP_COST / 2
	return cost + hazard[at] * HAZARD_COST


## The nearest cell that can be stood in, spiralling out from [param from] and
## giving up after [param rings].
##
## Somewhere has to be found rather than assumed. A lander is put down for its own
## reasons and its legs are the flattest thing about the site, so the cell directly
## under a colony's centre can easily be a slope nobody may walk on — and a colony
## that refused to start because its front door is on a gradient would be worse than
## one that starts a stride to the left of it.
func nearest_passable(from: Vector2i, rings := 6) -> Vector2i:
	if passable(from):
		return from
	for ring in range(1, rings + 1):
		for offset_x in range(-ring, ring + 1):
			for offset_y in range(-ring, ring + 1):
				# Only the ring itself; the inside of it was walked already.
				if absi(offset_x) != ring and absi(offset_y) != ring:
					continue
				var cell := from + Vector2i(offset_x, offset_y)
				if passable(cell):
					return cell
	return from


## Whether the ground is close enough to level here to put something on. Reads the
## cached heights rather than the field, so it is free.
func level_within(cell: Vector2i, metres: float) -> bool:
	if not passable(cell):
		return false
	var here := heights[index(cell)]
	for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0),
			Vector2i(0, 1), Vector2i(0, -1)]:
		var neighbour := cell + step
		if not inside(neighbour):
			continue
		if absf(heights[index(neighbour)] - here) > metres:
			return false
	return true


# --- The bake ----------------------------------------------------------------

## Reads the height field into [member heights] and classifies every cell.
##
## Safe on a [WorkerThreadPool] task, and meant for one: this is the only
## expensive thing a colony ever does, and it does it once. Nothing here touches
## the scene tree, and [method PlanetShape.elevation] is const — which is what the
## native field was written to make true, and what the terrain's own mesh threads
## already rely on.
##
## One field sample per cell, not five. The slope at a cell is measured against
## its neighbours' cached heights, so the sixteen thousand samples this costs are
## the whole bill rather than a fifth of it.
func build(shape: PlanetShape, spacing := 0.0) -> void:
	if site == null or shape == null:
		return
	for y in cells:
		var row := y * cells
		for x in cells:
			var local := centre_of(Vector2i(x, y))
			heights[row + x] = shape.elevation(
				site.direction_at(local), spacing)
	_classify()
	built = true
	revision += 1


func _classify() -> void:
	var slope_limit := tan(deg_to_rad(MAX_SLOPE_DEGREES))
	# Centre-to-centre across two cells, which is what the difference of the two
	# neighbours' heights is measured over.
	var run := cell_size * 2.0
	for y in cells:
		var row := y * cells
		for x in cells:
			var at := row + x
			var here := heights[at]
			if here < SHORE_MARGIN:
				terrain[at] = Terrain.WATER
				continue
			var west := heights[at - 1] if x > 0 else here
			var east := heights[at + 1] if x < cells - 1 else here
			var south := heights[at - cells] if y > 0 else here
			var north := heights[at + cells] if y < cells - 1 else here
			# A fall beside a cell matters more than the average slope across it.
			# A canyon rim is nearly level right up to the lip, so gradient alone
			# would march a Meep to the edge and then off it.
			var drop := maxf(
				maxf(here - west, here - east),
				maxf(here - south, here - north))
			var rise := maxf(
				maxf(west - here, east - here),
				maxf(south - here, north - here))
			if maxf(drop, rise) > FALL_LIMIT:
				terrain[at] = Terrain.VOID
				continue
			var gradient := Vector2(east - west, north - south) / run
			terrain[at] = Terrain.STEEP if gradient.length() > slope_limit \
				else Terrain.PASSABLE
