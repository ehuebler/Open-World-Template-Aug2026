extends Node

## Regression for the crash in the 2026-08-19 22:44 session log:
##
##     Out of bounds get index '4' (on base: 'PackedVector3Array')
##     at: GroundCover._place_glow_lights
##
## A tile's four glow arrays are written by [method GroundCover._sow] on a worker
## thread, one array at a time, while the main thread reads them to choose which
## patches get one of the pooled lights. A tile re-sown at a finer detail therefore
## offers the previous pass's anchors right up to the moment it offers fewer of them.
##
## Neither half of that is reproducible on a clock, so this fixture asserts the two
## rules that make the read safe whatever the worker is doing: a tile the pool owns is
## not read at all, and a tile that is read is walked to the shortest of its four
## arrays rather than to whichever one was asked for its length first.
##
## The field is deliberately planted on nothing, so the two "has no planet" warnings
## on start-up are the fixture working as intended: the anchors are handed in rather
## than grown, and no terrain is needed to read them back.

var _failures := 0


func _ready() -> void:
	var field := GroundCover.new()
	add_child(field)
	var plant := PlantSpecies.new()
	plant.glowing_patches = 1.0
	plant.glow_patch_size = 6.0
	field.species = [plant]

	var settled := _tile_with_anchors(Vector3i(1, 0, 0), 3)
	var torn := _tile_with_anchors(Vector3i(2, 0, 0), 3)
	# Mid-swap: the levels of the finished pass, the anchors of a shorter new one.
	torn.glow_points.resize(1)
	var owned := _tile_with_anchors(Vector3i(3, 0, 0), 3)
	owned.queued = true
	for tile in [settled, torn, owned]:
		field._tiles[tile.cell] = tile
	field._tile_list_stale = true

	var anchors := field._glow_anchors()
	var points := anchors["points"] as PackedVector3Array
	var levels := anchors["levels"] as PackedFloat32Array
	var kinds := anchors["species"] as PackedInt32Array
	_expect(points.size() == levels.size() and points.size() == kinds.size(),
		"the three anchor lists are returned the same length")
	_expect(points.size() == 4,
		"a torn tile gives its shortest count and an owned tile gives nothing (%d)"
			% points.size())
	var from_owned := 0
	for point in points:
		if is_equal_approx(point.x, float(owned.cell.x)):
			from_owned += 1
	_expect(from_owned == 0,
		"no anchor comes from the tile the worker pool is sowing")

	# The same read once the pool has handed the tile back, which is the pass that
	# is supposed to pick it up.
	owned.queued = false
	var adopted := (field._glow_anchors()["points"] as PackedVector3Array).size()
	_expect(adopted == 7,
		"an adopted tile's anchors are offered on the next pass (%d)" % adopted)

	print("flora_glow_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	field.queue_free()
	get_tree().quit(1 if _failures > 0 else 0)


## A grown tile holding [param count] anchors, each one identifiable by the cell it
## belongs to.
func _tile_with_anchors(cell: Vector3i, count: int) -> GroundCover.Tile:
	var tile := GroundCover.Tile.new()
	tile.cell = cell
	tile.grown = true
	tile.away = 1.0
	for index in count:
		tile.glow_points.append(Vector3(float(cell.x), 0.0, float(index)))
		tile.glow_levels.append(1.0)
		tile.glow_species.append(0)
		tile.glow_instances.append(index)
	return tile


func _expect(passed: bool, message: String) -> void:
	if passed:
		print("flora_glow_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("flora_glow_test: FAIL  %s" % message)
