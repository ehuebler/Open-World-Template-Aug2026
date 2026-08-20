extends Node

## Regression for the two periodic hitches captured on 2026-08-18.
##
## Continuous growth used to flood all 36,864 claim cells and issue one rendering
## server call per wall segment. The real captures measured 141–270 ms every five
## seconds. This fixture keeps the same production grid size and a typical 100 m
## boundary while removing terrain generation from the measurement.

const SPIKE_BUDGET_MS := 40.0
const REGION_WORKER_BUDGET_MS := 500.0
const REGION_APPLY_BUDGET_MS := 75.0

var _failures := 0


func _ready() -> void:
	var site := MeepSite.new(Vector3.UP, 8000.0, 0.0, 200.0)
	var grid := MeepGrid.new(site)
	grid.terrain.fill(MeepGrid.Terrain.PASSABLE)
	grid.flags.fill(MeepGrid.FLAG_NONE)
	grid.heights.fill(2.0)
	grid.surface_heights.fill(NAN)
	grid.built = true
	grid.revision += 1

	var claim := MeepClaim.new()
	claim.build(grid, Vector2.ZERO, 100.0)
	var wall := MeepBoundaryWall.new()
	add_child(wall)
	var shape := PlanetShape.new()
	wall.raise(site, claim, shape)

	var began := Time.get_ticks_usec()
	claim.expand(grid, Vector2.ZERO, 104.0)
	var expanded := Time.get_ticks_usec()
	claim.border_edges()
	var traced := Time.get_ticks_usec()
	wall.raise(site, claim, shape)
	var raised := Time.get_ticks_usec()
	var elapsed_ms := float(raised - began) / 1000.0

	var reference := MeepClaim.new()
	reference.build(grid, Vector2.ZERO, 104.0, false,
		PackedVector3Array(), PackedByteArray(), false)
	_expect(claim._claimed == reference._claimed,
		"incremental growth matches a complete claim flood")
	_expect(wall.segment_count() == claim.border_edges().size() / 2,
		"the packed wall buffer contains every boundary segment")
	_expect(elapsed_ms < SPIKE_BUDGET_MS,
		"one claim band and wall upload costs %.2f ms, below %.0f ms"
		% [elapsed_ms, SPIKE_BUDGET_MS])
	var region_size := Vector2i(192, 96)
	var terrain := PackedByteArray()
	terrain.resize(region_size.x * region_size.y)
	terrain.fill(1)
	var region := MeepRegionPlan.new()
	var worker_began := Time.get_ticks_usec()
	var solved := region.solve(Vector2(-192.0, -96.0), region_size,
		terrain, [{
			"site": "west",
			"local_centre": Vector2(-80.0, 0.0),
			"forecast_rate": 1.0,
			"seed": 1,
			"protected_local": PackedVector2Array([Vector2(-80.0, 0.0)]),
		}, {
			"site": "east",
			"local_centre": Vector2(80.0, 0.0),
			"forecast_rate": 1.4,
			"seed": 2,
			"protected_local": PackedVector2Array([Vector2(80.0, 0.0)]),
		}])
	var owner := PackedByteArray()
	var setback := PackedByteArray()
	owner.resize(grid.cells * grid.cells)
	setback.resize(owner.size())
	var owner_map := region.owner_map()
	var regional_setback := region.setback_mask(&"west")
	var west := region.site_index(&"west")
	var region_origin := region.origin()
	var region_dimensions := region.dimensions()
	for cell_index in owner.size():
		var cell := Vector2i(
			cell_index % grid.cells, cell_index / grid.cells)
		var local := grid.centre_of(cell)
		var source_cell := Vector2i(
			floori((local.x - region_origin.x)
				/ MeepRegionPlan.CELL_SIZE),
			floori((local.y - region_origin.y)
				/ MeepRegionPlan.CELL_SIZE))
		var source := source_cell.y * region_dimensions.x + source_cell.x \
			if source_cell.x >= 0 and source_cell.y >= 0 \
				and source_cell.x < region_dimensions.x \
				and source_cell.y < region_dimensions.y else -1
		if source < 0 or source >= owner_map.size():
			continue
		owner[cell_index] = 1 if owner_map[source] == west else 0
		setback[cell_index] = regional_setback[source] \
			if source < regional_setback.size() else 0
	var worker_ms := float(
		Time.get_ticks_usec() - worker_began) / 1000.0
	var apply_began := Time.get_ticks_usec()
	grid.bind_region_masks(owner, setback, region.revision())
	var bound := Time.get_ticks_usec()
	var clipped := MeepClaim.new()
	clipped.build(grid, Vector2(-80.0, 0.0), 104.0)
	var apply_ms := float(
		Time.get_ticks_usec() - apply_began) / 1000.0
	var bind_ms := float(bound - apply_began) / 1000.0
	var claim_apply_ms := float(
		Time.get_ticks_usec() - bound) / 1000.0
	_expect(solved and worker_ms < REGION_WORKER_BUDGET_MS,
		"the regional worker solve costs %.2f ms, below %.0f ms"
			% [worker_ms, REGION_WORKER_BUDGET_MS])
	_expect(not clipped.claimed_cells().is_empty()
		and apply_ms < REGION_APPLY_BUDGET_MS,
		"atomic owner-mask projection and claim apply costs %.2f ms, below %.0f ms"
			% [apply_ms, REGION_APPLY_BUDGET_MS])
	print(("claim_spike_test: incremental band + wall %.2f ms "
		+ "(expand %.2f, trace %.2f, upload %.2f)") % [
			elapsed_ms,
			float(expanded - began) / 1000.0,
			float(traced - expanded) / 1000.0,
			float(raised - traced) / 1000.0,
		])
	print("claim_spike_test: regional apply %.2f ms (bind %.2f, claim %.2f)"
		% [apply_ms, bind_ms, claim_apply_ms])
	print("claim_spike_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(passed: bool, message: String) -> void:
	if passed:
		print("claim_spike_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("claim_spike_test: FAIL  %s" % message)
