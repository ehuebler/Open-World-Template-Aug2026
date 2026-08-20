class_name MeepCityProjection
extends RefCounted

## Economy-free, deterministic physical projection of a Meep city.
##
## This is deliberately not a compact-city simulation. A ledger can estimate how
## quickly work finishes, but it cannot decide where roads and buildings stand.
## Projection instead drives the production MeepCityPlan, MeepStructures and
## MeepRoads planners directly until they can house the requested population.

const VERSION := 2
const MAX_PLANNING_STEPS := 768
const MAX_ROAD_PASSES := 256


## Terrain sampling is the expensive portion and is independent of population.
## A local blueprint registry caches this immutable payload and can cheaply
## re-project the same site whenever its dummy population changes.
static func bake_ground(site: MeepSite, shape: PlanetShape,
		spacing := 0.0) -> Dictionary:
	if site == null or shape == null:
		return {}
	var grid := MeepGrid.new(site)
	grid.build(shape, spacing)
	return ground_snapshot(grid)


static func ground_snapshot(grid: MeepGrid) -> Dictionary:
	if grid == null or not grid.built:
		return {}
	return {
		"version": VERSION,
		"cells": grid.cells,
		"cell_size": grid.cell_size,
		"terrain": grid.terrain.duplicate(),
		"heights": grid.heights.duplicate(),
		"surface_heights": grid.surface_heights.duplicate(),
	}


static func grid_from_ground(site: MeepSite, state: Dictionary) -> MeepGrid:
	if site == null or state.is_empty():
		return null
	var cells := maxi(int(state.get("cells", MeepGrid.CELLS)), 8)
	var cell_size := maxf(float(state.get("cell_size", MeepGrid.CELL)), 0.25)
	var grid := MeepGrid.new(site, cells, cell_size)
	var total := cells * cells
	var terrain: PackedByteArray = state.get(
		"terrain", PackedByteArray())
	var heights: PackedFloat32Array = state.get(
		"heights", PackedFloat32Array())
	if terrain.size() != total or heights.size() != total:
		return null
	grid.terrain = terrain.duplicate()
	grid.heights = heights.duplicate()
	var surfaces: PackedFloat32Array = state.get(
		"surface_heights", PackedFloat32Array())
	if surfaces.size() == total:
		grid.surface_heights = surfaces.duplicate()
	else:
		grid.surface_heights.resize(total)
		grid.surface_heights.fill(NAN)
	grid.flags.resize(total)
	grid.flags.fill(0)
	grid.hazard.resize(total)
	grid.hazard.fill(0)
	grid.built = true
	grid.revision = 1
	return grid


## Required config:
##   site: MeepSite
##   shape: PlanetShape
##   population: int
##   seed: int
## Either `ground` or a shape from which ground can be baked must be supplied.
##
## Optional regional inputs are owner_mask, setback_mask, region_revision,
## rival_centres and rival_wins_ties. The returned snapshots use the exact wire
## shapes consumed by resident/distant city presentation.
static func project(config: Dictionary) -> Dictionary:
	var site := config.get("site") as MeepSite
	var shape := config.get("shape") as PlanetShape
	if site == null or shape == null:
		return {}
	var ground_value: Variant = config.get("ground", {})
	var ground: Dictionary = (ground_value as Dictionary).duplicate(true) \
		if ground_value is Dictionary else {}
	if ground.is_empty():
		ground = bake_ground(site, shape,
			float(config.get("spacing", 0.0)))
	var grid := grid_from_ground(site, ground)
	if grid == null:
		return {}
	var owner: PackedByteArray = config.get(
		"owner_mask", PackedByteArray())
	var setback: PackedByteArray = config.get(
		"setback_mask", PackedByteArray())
	grid.bind_region_masks(owner, setback,
		int(config.get("region_revision", -1)))

	var rival_centres: PackedVector3Array = config.get(
		"rival_centres", PackedVector3Array())
	var rival_ties: PackedByteArray = config.get(
		"rival_wins_ties", PackedByteArray())
	var maximum_radius := clampf(float(config.get(
		"maximum_radius", MeepColony.MAX_CLAIM_RADIUS)),
		MeepClaim.DEFAULT_RADIUS, MeepColony.MAX_CLAIM_RADIUS)
	var claim := MeepClaim.new()
	claim.build(grid, Vector2.ZERO, minf(
		MeepClaim.DEFAULT_RADIUS, maximum_radius), false,
		rival_centres, rival_ties)

	var roads := MeepRoads.new()
	roads.configure(site, grid, claim, shape, null,
		int(config.get("seed", 0)), false, false, false)
	roads.set_centre_exclusion_radius(MeepColony.SHIP_NAVIGATION_RADIUS)
	var structures := MeepStructures.new()
	structures.configure(site, grid, claim, shape, null, null,
		roads, false, false)
	var city_plan := MeepCityPlan.new()
	city_plan.configure(grid, claim, int(config.get("seed", 0)),
		structures, roads, maximum_radius)
	_apply_plan_masks(city_plan, grid, claim)
	_rebuild_claim(claim, grid, claim.radius, city_plan,
		rival_centres, rival_ties)

	var target := clampi(int(config.get(
		"population", MeepColony.STARTER_POPULATION)),
		MeepColony.FIRST_WAVE,
		MeepColony.MAX_CITY_POPULATION)
	var population := MeepColony.FIRST_WAVE
	var tier := 0
	var vertical_huts := 0
	var stalled := false
	for _step in MAX_PLANNING_STEPS:
		var housing := maxi(MeepColony.FIRST_WAVE,
			structures.residential_capacity(true))
		population = mini(target, maxi(population, mini(target, housing)))
		if housing >= MeepColony.TIER_POPULATION_CEILINGS[tier] \
				and tier < MeepColony.MAX_CITY_TIER:
			tier += 1
			continue
		if population >= target:
			break
		if tier > 0 and population >= housing \
				and housing < MeepColony.TIER_POPULATION_CEILINGS[tier] \
				and vertical_huts < MeepColony.MAX_VERTICAL_HUT_UPGRADES:
			if _complete_one_vertical_hut(structures):
				vertical_huts += 1
				continue
		var tier_zero_target := clampi(
			floori(claim.area() / MeepColony.TIER_ZERO_LOT_AREA),
			MeepColony.STARTER_STRUCTURES,
			MeepColony.TIER_ZERO_MAX_STRUCTURES)
		var kind := MeepColony.projected_growth_kind(
			tier, population, housing,
			structures.count_of(MeepStructures.Kind.CLONER, true),
			structures.count_of(MeepStructures.Kind.HUT, true),
			tier_zero_target)
		if kind < 0:
			# Vacant completed homes fill before another lot is authored.
			if population < mini(target, housing):
				population = mini(target, housing)
				continue
			stalled = true
			break
		var placed := _place_next(kind, tier, city_plan, structures,
			roads, grid, claim, maximum_radius, rival_centres, rival_ties)
		if not placed:
			stalled = true
			break
		if kind == MeepStructures.Kind.CLONER:
			_complete_ship_ring(roads, grid, claim)
		_complete_ready_roads(city_plan, roads, grid, claim,
			maximum_radius, rival_centres, rival_ties)
		_connect_unserved_structures(structures, roads, grid, claim)

	# A population exactly on a tier ceiling has completed that architectural
	# stage even though no structure from the next stage is needed yet.
	while tier < MeepColony.MAX_CITY_TIER \
			and structures.residential_capacity(true) \
				>= MeepColony.TIER_POPULATION_CEILINGS[tier]:
		tier += 1
	_complete_ready_roads(city_plan, roads, grid, claim,
		maximum_radius, rival_centres, rival_ties)
	_connect_unserved_structures(structures, roads, grid, claim)

	var raised := PackedFloat32Array()
	raised.resize(structures.count())
	raised.fill(1.0)
	var result := {
		"version": VERSION,
		"population": target,
		"projected_population": population,
		"housing_capacity": maxi(MeepColony.FIRST_WAVE,
			structures.residential_capacity(true)),
		"tier": tier,
		"stalled": stalled or population < target,
		"claim_radius": claim.radius,
		"ground": ground,
		"owner_mask": owner.duplicate(),
		"setback_mask": setback.duplicate(),
		"city_plan": city_plan.snapshot(),
		"structures": structures.snapshot(),
		"raised": raised,
		"structure_forms": structures.form_snapshot(),
		"structure_upgrades": structures.upgrade_progress_snapshot(),
		"roads": roads.snapshot(),
		"road_widths": roads.width_snapshot(),
		"road_surfaces": roads.surface_snapshot(),
	}
	result["protected_directions"] = protected_directions(result, site)
	structures.free()
	roads.free()
	return result


static func protected_directions(result: Dictionary,
		site: MeepSite) -> PackedVector3Array:
	var out := PackedVector3Array()
	if site == null:
		return out
	out.push_back(site.centre)
	var structures: PackedInt32Array = result.get(
		"structures", PackedInt32Array())
	for offset in range(0, structures.size(), 3):
		if offset + 2 >= structures.size():
			break
		var kind := structures[offset]
		if kind < 0 or kind >= MeepStructures.Kind.size():
			continue
		var corner := Vector2i(structures[offset + 1], structures[offset + 2])
		var span := MeepStructures.plan_of(kind).span
		out.push_back(site.direction_at(_grid_centre(corner,
			MeepGrid.CELLS, MeepGrid.CELL)
			+ Vector2(span - Vector2i.ONE) * MeepGrid.CELL * 0.5))
	var road_cells: PackedInt32Array = result.get(
		"roads", PackedInt32Array())
	for cell_index in road_cells:
		var cell := Vector2i(
			cell_index % MeepGrid.CELLS, cell_index / MeepGrid.CELLS)
		out.push_back(site.direction_at(_grid_centre(
			cell, MeepGrid.CELLS, MeepGrid.CELL)))
	return out


static func _grid_centre(cell: Vector2i, cells: int,
		cell_size: float) -> Vector2:
	var half := float(cells) * cell_size * 0.5
	return Vector2(
		(float(cell.x) + 0.5) * cell_size - half,
		(float(cell.y) + 0.5) * cell_size - half)


static func _apply_plan_masks(plan: MeepCityPlan, grid: MeepGrid,
		claim: MeepClaim) -> void:
	var parks := plan.park_mask()
	var lots := plan.planned_lot_mask()
	var changed := false
	for index in grid.cells * grid.cells:
		var was := int(grid.flags[index])
		var now := was & ~(
			MeepGrid.FLAG_PARK | MeepGrid.FLAG_PLANNED_LOT)
		if index < parks.size() and parks[index] != 0:
			now |= MeepGrid.FLAG_PARK
		if index < lots.size() and lots[index] != 0:
			now |= MeepGrid.FLAG_PLANNED_LOT
		if now != was:
			grid.flags[index] = now
			changed = true
	if changed:
		grid.revision += 1
	claim.bind_permit_mask(plan.permit_mask(), plan.permit_revision())


static func _rebuild_claim(claim: MeepClaim, grid: MeepGrid,
		radius: float, plan: MeepCityPlan,
		rival_centres: PackedVector3Array,
		rival_ties: PackedByteArray) -> void:
	claim.build(grid, Vector2.ZERO, radius, false,
		rival_centres, rival_ties)
	plan.finish_expansion(radius)


static func _place_next(kind: int, tier: int, city_plan: MeepCityPlan,
		structures: MeepStructures, roads: MeepRoads, grid: MeepGrid,
		claim: MeepClaim, maximum_radius: float,
		rival_centres: PackedVector3Array,
		rival_ties: PackedByteArray) -> bool:
	for _attempt in 128:
		var old_permit := city_plan.permit_revision()
		var lot := city_plan.prepared_lot(kind)
		if city_plan.permit_revision() != old_permit:
			_apply_plan_masks(city_plan, grid, claim)
			var wanted := clampf(maxf(
				claim.radius, city_plan.target_radius()),
				claim.radius, maximum_radius)
			_rebuild_claim(claim, grid, wanted, city_plan,
				rival_centres, rival_ties)
			_complete_ready_roads(city_plan, roads, grid, claim,
				maximum_radius, rival_centres, rival_ties)
			continue
		if lot.is_empty():
			var wanted := city_plan.target_radius()
			if wanted > claim.radius + 0.001:
				_rebuild_claim(claim, grid,
					minf(wanted, maximum_radius), city_plan,
					rival_centres, rival_ties)
				_complete_ready_roads(city_plan, roads, grid, claim,
					maximum_radius, rival_centres, rival_ties)
				continue
			lot = city_plan.projection_lot(kind)
			if lot.is_empty():
				return _place_fallback(
					kind, tier, structures)
			_apply_plan_masks(city_plan, grid, claim)
			wanted = minf(maxf(claim.radius,
				city_plan.target_radius()), maximum_radius)
			_rebuild_claim(claim, grid, wanted, city_plan,
				rival_centres, rival_ties)
			_complete_ready_roads(city_plan, roads, grid, claim,
				maximum_radius, rival_centres, rival_ties)
		var corner: Vector2i = lot.get("corner", Vector2i.ZERO)
		var index := structures.place_planned(kind, corner,
			int(lot.get("district_tier", tier)))
		if index == -1:
			_complete_ready_roads(city_plan, roads, grid, claim,
				maximum_radius, rival_centres, rival_ties)
			index = structures.place_planned(kind, corner,
				int(lot.get("district_tier", tier)))
		if index == -1:
			# The authored lot is terrain-valid; an absent live colony means there
			# is no cached home field, so retain the production location rather
			# than inventing a second placement order for previews.
			index = structures.place_at(kind, corner,
				int(lot.get("district_tier", tier)))
		if index == -2:
			city_plan.block_lot(int(lot.get("index", -1)))
			_apply_plan_masks(city_plan, grid, claim)
			continue
		if index < 0:
			return false
		city_plan.commit_lot(int(lot.get("index", -1)))
		structures.set_progress(index, 1.0)
		structures.block(index)
		_apply_plan_masks(city_plan, grid, claim)
		return true
	return _place_fallback(kind, tier, structures)


static func _place_fallback(kind: int, tier: int,
		structures: MeepStructures) -> bool:
	var bounded_tier := clampi(
		tier, 0, MeepColony.MAX_CITY_TIER)
	var index := structures.place_district(kind,
		MeepColony.CITY_TIER_DEVELOPMENT_INNER_RADII[bounded_tier],
		MeepColony.TIER_BLOCK_SIZES[bounded_tier], bounded_tier) \
		if bounded_tier > 0 \
			and MeepStructures.is_residential_kind(kind) \
		else structures.place(kind, true)
	if index < 0 and MeepStructures.is_residential_kind(kind):
		structures.clear_exhaustion()
		index = structures.place(kind, true)
	if index < 0:
		return false
	structures.set_progress(index, 1.0)
	structures.block(index)
	return true


static func _complete_ship_ring(roads: MeepRoads, grid: MeepGrid,
		claim: MeepClaim) -> void:
	if roads.has_subject(MeepColony.SHIP_RING_ROAD_SUBJECT):
		return
	var ring := PackedInt32Array()
	var seen: Dictionary = {}
	var samples := maxi(32, ceili(TAU * MeepColony.SHIP_ROAD_RADIUS
		/ (grid.cell_size * 0.5)))
	for sample in samples:
		var angle := TAU * float(sample) / float(samples)
		var cell := grid.cell_of(Vector2(cos(angle), sin(angle))
			* MeepColony.SHIP_ROAD_RADIUS)
		if not grid.passable(cell) or not claim.contains_cell(cell):
			continue
		var cell_index := grid.index(cell)
		if seen.has(cell_index):
			continue
		seen[cell_index] = true
		ring.push_back(cell_index)
	if ring.size() >= 16:
		roads.complete(roads.plan(
			MeepColony.SHIP_RING_ROAD_SUBJECT, ring))


static func _complete_ready_roads(city_plan: MeepCityPlan,
		roads: MeepRoads, grid: MeepGrid, claim: MeepClaim,
		maximum_radius: float, rival_centres: PackedVector3Array,
		rival_ties: PackedByteArray) -> void:
	for _pass in MAX_ROAD_PASSES:
		var prepared := city_plan.road_project_status(
			roads, claim, grid)
		var state := int(prepared.get(
			"state", MeepCityPlan.RoadProjectState.NONE))
		if state == MeepCityPlan.RoadProjectState.READY:
			roads.complete(roads.plan(
				int(prepared.get("subject", 0)),
				prepared.get("cells", PackedInt32Array()),
				int(prepared.get("width_class",
					MeepRoads.WidthClass.STREET))))
			continue
		if state == MeepCityPlan.RoadProjectState.WAITING_FOR_CLAIM:
			var wanted := city_plan.target_radius()
			if wanted > claim.radius + 0.001:
				_rebuild_claim(claim, grid,
					minf(wanted, maximum_radius), city_plan,
					rival_centres, rival_ties)
				continue
		break


static func _connect_unserved_structures(structures: MeepStructures,
		roads: MeepRoads, grid: MeepGrid, claim: MeepClaim) -> void:
	for structure in structures.count():
		var entry := structures.at(structure)
		if entry == null or not entry.built() or roads.has_subject(structure):
			continue
		var width_class := MeepRoads.width_class_for_tier(
			entry.district_tier)
		var access := structures.access_cells(structure)
		var touches := false
		for cell in access:
			if grid.has_flag(cell, MeepGrid.FLAG_ROAD):
				touches = true
				break
		if touches:
			roads.plan(structure, PackedInt32Array(), width_class)
			continue
		var field := MeepFlowField.new()
		field.build(grid, claim.origin)
		var candidates: Array[Vector2i] = []
		for cell in access:
			if grid.passable(cell) and field.reachable(cell):
				candidates.push_back(cell)
		candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var a_distance := field.distance_at(a)
			var b_distance := field.distance_at(b)
			return a_distance < b_distance \
				or (a_distance == b_distance
					and grid.index(a) < grid.index(b)))
		for candidate in candidates:
			var cells := roads.path_home_from(candidate, field)
			if cells.is_empty():
				continue
			roads.complete(roads.plan(
				structure, cells, width_class))
			break


static func _complete_one_vertical_hut(
		structures: MeepStructures) -> bool:
	for index in structures.count():
		var entry := structures.at(index)
		if entry == null or entry.kind != MeepStructures.Kind.HUT \
				or not structures.begin_vertical_upgrade(index):
			continue
		structures.advance_upgrade(index,
			structures.upgrade_work(index))
		return structures.complete_upgrade(index)
	return false
