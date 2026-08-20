class_name MeepCityPlan
extends RefCounted

## A city's complete physical growth recipe.
##
## The expensive decisions are made once, after the founding grid is baked: which
## direction each district grows, which ground remains park, where every class of
## building may stand, and where the district streets run. Runtime town planning
## consumes these packed records instead of repeatedly scanning the whole claim.

enum Style {
	GRID_BOROUGHS,
	RING_AND_SPOKE,
	ORGANIC_BRANCHES,
	PARK_COURTYARDS,
	TERRACES,
}

enum Shape {
	CORE,
	RECTANGLE,
	ELLIPSE,
	BRANCH,
	COURTYARD,
	TERRACE,
}

enum RoadProjectState {
	NONE,
	READY,
	WAITING_FOR_CLAIM,
	WAITING_FOR_SURFACE,
	COMPLETE,
}

const VERSION := 2
const MIN_PACKED_VERSION := 1
const CIVIC_LOT := -1
const LOT_FREE := 0
const LOT_BUILT := 1
const LOT_OWED := 2
const LOT_BLOCKED := 3
## Temporarily outside a regional ownership/setback clip. Replans may revive it.
const LOT_REGION_BLOCKED := 4

## centre x/y, half x/y, tier, shape, parent, orientation, required reach dm.
const DISTRICT_STRIDE := 9
const DISTRICT_X := 0
const DISTRICT_Y := 1
const DISTRICT_HALF_X := 2
const DISTRICT_HALF_Y := 3
const DISTRICT_TIER := 4
const DISTRICT_SHAPE := 5
const DISTRICT_PARENT := 6
const DISTRICT_ORIENTATION := 7
const DISTRICT_REACH_DM := 8

## kind/zone, centre x/y, district, maximum span, stable build order.
const LOT_STRIDE := 6
const LOT_KIND := 0
const LOT_X := 1
const LOT_Y := 2
const LOT_DISTRICT := 3
const LOT_MAX_SPAN := 4
const LOT_ORDER := 5

const ROAD_SUBJECT_BASE := -200000
const OUTER_TIERS := [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4]
const OUTER_RADII := [104.0, 108.0, 112.0, 116.0, 120.0, 124.0,
	128.0, 132.0, 136.0, 138.0, 142.0, 146.0, 150.0, 154.0]
const RESIDENTIAL_LOTS_PER_DISTRICT := {
	1: 7,
	2: 5,
	3: 3,
	4: 2,
}
const CORE_HUT_LOTS := 52
## Current 9x9 civic projects must remain reachable even when outer terrain is
## isolated; larger future pads still seed through distinct ordinary districts.
const CORE_CIVIC_LOTS := 4
const CIVIC_PAD_SPANS := [9, 12, 15]
const CORRIDOR_HALF_WIDTH := 2

var style := Style.GRID_BOROUGHS
var active_districts := 1
var requested_district := -1
var districts := PackedInt32Array()
var lots := PackedInt32Array()
var lot_states := PackedByteArray()

var _grid: MeepGrid
var _claim: MeepClaim
var _seed := 0
var _max_radius := 185.0
var _generated := false
var _layout_revision := 0
var _permit_revision := 0
var _mask_revision := 0
var _permit_mask := PackedByteArray()
var _park_mask := PackedByteArray()
var _lot_mask := PackedByteArray()
var _all_park_mask := PackedByteArray()
var _legacy_mask := PackedByteArray()
var _road_projects: Array[Dictionary] = []
var _candidate_cache: Dictionary = {}
var _restored: Dictionary = {}


func apply_snapshot(state: Dictionary) -> void:
	_restored = state.duplicate(true)
	if state.is_empty():
		return
	var packed_version := int(_restored.get("version", 0))
	if packed_version >= MIN_PACKED_VERSION \
			and packed_version < VERSION \
			and _packed_layout_valid(_restored):
		# Version 1 already uses the current packed strides. Preserve its authored
		# districts and occupied lots instead of silently regenerating a lived-in city.
		_restored["version"] = VERSION
	style = clampi(int(state.get("style", style)), 0, Style.size() - 1)
	active_districts = maxi(int(state.get("active_districts", 1)), 1)
	requested_district = int(state.get("requested_district", -1))


func snapshot() -> Dictionary:
	if not _generated and not _restored.is_empty():
		return _restored.duplicate(true)
	return {
		"version": VERSION,
		"style": style,
		"active_districts": active_districts,
		"requested_district": requested_district,
		"districts": districts.duplicate(),
		"lots": lots.duplicate(),
		"lot_states": lot_states.duplicate(),
	}


static func _packed_layout_valid(state: Dictionary) -> bool:
	var version := int(state.get("version", 0))
	if version < MIN_PACKED_VERSION or version > VERSION:
		return false
	var district_value: Variant = state.get("districts", null)
	var lot_value: Variant = state.get("lots", null)
	return district_value is PackedInt32Array \
		and lot_value is PackedInt32Array \
		and (district_value as PackedInt32Array).size() >= DISTRICT_STRIDE \
		and (district_value as PackedInt32Array).size() % DISTRICT_STRIDE == 0 \
		and (lot_value as PackedInt32Array).size() >= LOT_STRIDE \
		and (lot_value as PackedInt32Array).size() % LOT_STRIDE == 0


func configure(for_grid: MeepGrid, for_claim: MeepClaim, city_seed: int,
		structures: MeepStructures = null, roads: MeepRoads = null,
		max_radius := 185.0) -> void:
	var previous_seed := _seed
	_grid = for_grid
	_claim = for_claim
	_seed = city_seed
	_max_radius = maxf(max_radius, MeepClaim.DEFAULT_RADIUS)
	if _grid == null or not _grid.built:
		return
	var restored_districts: PackedInt32Array = _restored.get(
		"districts", PackedInt32Array())
	var restored_lots: PackedInt32Array = _restored.get(
		"lots", PackedInt32Array())
	if _packed_layout_valid(_restored):
		districts = restored_districts.duplicate()
		lots = restored_lots.duplicate()
		lot_states = (_restored.get("lot_states", PackedByteArray())
			as PackedByteArray).duplicate()
	elif _restored.is_empty() and _generated and previous_seed == city_seed \
			and districts.size() >= DISTRICT_STRIDE \
			and lots.size() >= LOT_STRIDE:
		# A terrain or constructed-surface rebake replaces the grid and claim, not
		# the founding decision. Rebind the same compact plan so districts already
		# opened and lots already consumed cannot disappear after a crater or bridge.
		pass
	else:
		style = posmod(city_seed, Style.size())
		active_districts = 1
		requested_district = -1
		_build_layout()
	while lot_states.size() < lot_count():
		lot_states.push_back(LOT_FREE)
	active_districts = clampi(active_districts, 1, district_count())
	if requested_district >= district_count():
		requested_district = -1
	_mark_existing(structures, roads)
	_extend_all_district_reaches_from_lots()
	_build_derived()
	_generated = true
	_restored.clear()


func generated() -> bool:
	return _generated


## Re-applies dormant plan work after the registry publishes a new regional clip.
## Built and owed lots are immutable anchors; only uncommitted lots move.
func reflow_region_clip() -> void:
	if not _generated or _grid == null:
		return
	var total := _grid.cells * _grid.cells
	var occupied := PackedByteArray()
	occupied.resize(total)
	for cell_index in total:
		if (int(_grid.flags[cell_index]) & (MeepGrid.FLAG_BUILDING \
				| MeepGrid.FLAG_ROAD | MeepGrid.FLAG_RESERVED \
				| MeepGrid.FLAG_SHIP)) != 0:
			occupied[cell_index] = 1
	var movable := PackedInt32Array()
	for lot in _ordered_lot_indices():
		var state := lot_states[lot]
		if state == LOT_FREE or state == LOT_REGION_BLOCKED:
			movable.push_back(lot)
			continue
		_mark_lot_occupied(lot, occupied)
	var changed := false
	for lot in movable:
		var original_district := _lot(lot, LOT_DISTRICT)
		var centre := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y))
		if _region_lot_valid(lot, centre, occupied):
			if lot_states[lot] == LOT_REGION_BLOCKED:
				lot_states[lot] = LOT_FREE
				changed = true
			_mark_lot_occupied(lot, occupied)
			continue
		var placed := false
		var districts_to_try := PackedInt32Array([original_district])
		for district in district_count():
			if district != original_district:
				districts_to_try.push_back(district)
		for district in districts_to_try:
			for candidate in _cached_district_candidates(district, 3):
				if not _region_lot_valid(lot, candidate, occupied):
					continue
				lots[lot * LOT_STRIDE + LOT_X] = candidate.x
				lots[lot * LOT_STRIDE + LOT_Y] = candidate.y
				lots[lot * LOT_STRIDE + LOT_DISTRICT] = district
				lot_states[lot] = LOT_FREE
				_extend_district_reach_for_lot(lot)
				_mark_lot_occupied(lot, occupied)
				placed = true
				changed = true
				break
			if placed:
				break
		if not placed:
			if lot_states[lot] != LOT_REGION_BLOCKED:
				changed = true
			lot_states[lot] = LOT_REGION_BLOCKED
	if changed:
		_layout_revision += 1
	_build_derived()


func _region_lot_valid(lot: int, centre: Vector2i,
		occupied: PackedByteArray) -> bool:
	var kind := _lot(lot, LOT_KIND)
	var actual_kind := _civic_pad_kind(_lot(lot, LOT_MAX_SPAN)) \
		if kind == CIVIC_LOT else kind
	var plan := MeepStructures.plan_of(actual_kind)
	var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
		_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT else plan.span
	var corner := centre - Vector2i(span.x / 2, span.y / 2)
	for y in span.y:
		for x in span.x:
			var cell := corner + Vector2i(x, y)
			if not _grid.inside(cell) or not _grid.region_buildable(cell):
				return false
	return _footprint_valid(plan, corner, span, occupied)


func _mark_lot_occupied(lot: int, occupied: PackedByteArray) -> void:
	var kind := _lot(lot, LOT_KIND)
	var actual_kind := _civic_pad_kind(_lot(lot, LOT_MAX_SPAN)) \
		if kind == CIVIC_LOT else kind
	var plan := MeepStructures.plan_of(actual_kind)
	var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
		_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT else plan.span
	var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
		- Vector2i(span.x / 2, span.y / 2)
	var margin := maxi(2, ceili(plan.spacing / (_grid.cell_size * 2.0)))
	for y in range(corner.y - margin, corner.y + span.y + margin):
		for x in range(corner.x - margin, corner.x + span.x + margin):
			var cell := Vector2i(x, y)
			if _grid.inside(cell):
				occupied[_grid.index(cell)] = 1


func style_name() -> String:
	match style:
		Style.RING_AND_SPOKE:
			return "Ring and Spoke"
		Style.ORGANIC_BRANCHES:
			return "Organic Branches"
		Style.PARK_COURTYARDS:
			return "Park Courtyards"
		Style.TERRACES:
			return "Terraces"
		_:
			return "Grid Boroughs"


func district_count() -> int:
	return districts.size() / DISTRICT_STRIDE


func lot_count() -> int:
	return lots.size() / LOT_STRIDE


func road_project_count() -> int:
	return _road_projects.size()


func lot_summary() -> Dictionary:
	var by_kind := PackedInt32Array()
	by_kind.resize(MeepStructures.Kind.size())
	var furthest := PackedFloat32Array()
	furthest.resize(MeepStructures.Kind.size())
	var free := 0
	var owed := 0
	var blocked := 0
	var civic_by_span := {
		9: 0,
		12: 0,
		15: 0,
	}
	for index in lot_count():
		var kind := _lot(index, LOT_KIND)
		if kind == CIVIC_LOT:
			var civic_span := _lot(index, LOT_MAX_SPAN)
			civic_by_span[civic_span] = int(civic_by_span.get(
				civic_span, 0)) + 1
		if kind >= 0 and kind < by_kind.size():
			by_kind[kind] += 1
			if _grid != null:
				furthest[kind] = maxf(furthest[kind], _grid.centre_of(
					Vector2i(_lot(index, LOT_X), _lot(index, LOT_Y))).length())
		if lot_states[index] == LOT_FREE:
			free += 1
		elif lot_states[index] == LOT_OWED:
			owed += 1
		elif lot_states[index] == LOT_BLOCKED \
				or lot_states[index] == LOT_REGION_BLOCKED:
			blocked += 1
	return {
		"total": lot_count(),
		"free": free,
		"owed": owed,
		"blocked": blocked,
		"by_kind": by_kind,
		"furthest_by_kind": furthest,
		"civic_by_span": civic_by_span,
	}


func availability_summary(kind: int) -> Dictionary:
	var free_active := 0
	var available := 0
	var dormant := 0
	for index in _ordered_lot_indices():
		if lot_states[index] != LOT_FREE:
			continue
		if not _lot_accepts_kind(index, kind):
			continue
		if _lot(index, LOT_DISTRICT) >= active_districts:
			dormant += 1
			continue
		free_active += 1
		if _lot_available_now(index, kind, _lot_corner(index, kind)):
			available += 1
	return {
		"free_active": free_active,
		"available": available,
		"dormant": dormant,
	}


func permit_mask() -> PackedByteArray:
	return _permit_mask


func permit_revision() -> int:
	return _permit_revision


## Runtime-only revision for all three derived masks. Unlike permit_revision this
## also advances when consuming a lot changes only the planned-lot overlay.
func mask_revision() -> int:
	return _mask_revision


func park_mask() -> PackedByteArray:
	return _park_mask


func planned_lot_mask() -> PackedByteArray:
	return _lot_mask


func lot_cell_indices(lot: int) -> PackedInt32Array:
	var cells := PackedInt32Array()
	if _grid == null or lot < 0 or lot >= lot_count():
		return cells
	var kind := _lot(lot, LOT_KIND)
	var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
		_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
		else MeepStructures.plan_of(kind).span
	var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
		- Vector2i(span.x / 2, span.y / 2)
	for y in span.y:
		for x in span.x:
			var cell := corner + Vector2i(x, y)
			if _grid.inside(cell):
				cells.push_back(_grid.index(cell))
	return cells


func target_radius() -> float:
	if requested_district < 0 or requested_district >= district_count():
		return 0.0
	var target := 0.0
	for district in mini(active_districts, district_count()):
		target = maxf(target,
			float(_district(district, DISTRICT_REACH_DM)) * 0.1)
	return target


func has_pending_expansion(current_radius: float) -> bool:
	return requested_district >= 0 \
		and current_radius + 0.001 < target_radius()


func finish_expansion(current_radius: float) -> void:
	if requested_district >= 0 and current_radius + 0.001 >= target_radius():
		requested_district = -1


## Returns a real prepared lot. A dormant match activates all districts leading to
## it and returns empty until the border reaches that lot.
func prepared_lot(kind: int, completed_owed := false) -> Dictionary:
	if not _generated:
		return {}
	var fallback := -1
	var active_waiting := -1
	var states := [LOT_OWED, LOT_FREE] if completed_owed else [LOT_FREE]
	for wanted_state in states:
		for exact in [true, false]:
			for index in _ordered_lot_indices():
				if lot_states[index] != wanted_state:
					continue
				var lot_kind := _lot(index, LOT_KIND)
				if exact and lot_kind != kind:
					continue
				if not exact and not _lot_accepts_kind(index, kind):
					continue
				var district := _lot(index, LOT_DISTRICT)
				if district >= active_districts:
					if fallback < 0:
						fallback = index
					continue
				var corner := _lot_corner(index, kind)
				if _lot_available_now(index, kind, corner):
					return _lot_dictionary(index, kind, corner)
				if active_waiting < 0:
					active_waiting = index
	if fallback >= 0:
		request_district(_lot(fallback, LOT_DISTRICT))
	elif active_waiting >= 0 and _claim != null:
		var district := _lot(active_waiting, LOT_DISTRICT)
		var reach := float(_district(district, DISTRICT_REACH_DM)) * 0.1
		if _claim.radius + 0.001 < reach:
			request_district(district)
	return {}


## Economy-free projection may advance directly to a later authored lot when the
## live planner would wait for a work crew, a route cache, or an intermediate
## construction pass. The location and order are still the production blueprint;
## only the time-dependent availability gate is omitted.
func projection_lot(kind: int) -> Dictionary:
	if not _generated:
		return {}
	for exact in [true, false]:
		for index in _ordered_lot_indices():
			if lot_states[index] != LOT_FREE:
				continue
			var lot_kind := _lot(index, LOT_KIND)
			if exact and lot_kind != kind:
				continue
			if not exact and not _lot_accepts_kind(index, kind):
				continue
			var district := _lot(index, LOT_DISTRICT)
			request_district(district)
			return _lot_dictionary(index, kind, _lot_corner(index, kind))
	return {}


func commit_lot(index: int) -> void:
	if index < 0 or index >= lot_states.size():
		return
	lot_states[index] = LOT_BUILT
	_layout_revision += 1
	_refresh_lot_mask(index)


func release_lot(index: int) -> void:
	if index >= 0 and index < lot_states.size() \
			and lot_states[index] == LOT_BUILT:
		lot_states[index] = LOT_FREE
		_layout_revision += 1
		_refresh_lot_mask(index)


func block_lot(index: int) -> void:
	if index < 0 or index >= lot_states.size():
		return
	lot_states[index] = LOT_BLOCKED
	_layout_revision += 1
	_refresh_lot_mask(index)


func request_kind(kind: int) -> bool:
	for exact in [true, false]:
		for index in _ordered_lot_indices():
			if lot_states[index] != LOT_FREE:
				continue
			var lot_kind := _lot(index, LOT_KIND)
			if exact and lot_kind != kind:
				continue
			if not exact and not _lot_accepts_kind(index, kind):
				continue
			request_district(_lot(index, LOT_DISTRICT))
			return true
	return false


func request_district(district: int) -> void:
	if district < 0 or district >= district_count():
		return
	var old_active := active_districts
	active_districts = maxi(active_districts, district + 1)
	requested_district = maxi(requested_district, district)
	if active_districts != old_active:
		_build_active_masks()


## Reserves one actual lot for a building completed by a compact ledger.
func reserve_owed_lot(kind: int, current_radius: float) -> bool:
	for exact in [true, false]:
		for index in _ordered_lot_indices():
			if lot_states[index] != LOT_FREE:
				continue
			var lot_kind := _lot(index, LOT_KIND)
			if exact and lot_kind != kind:
				continue
			if not exact and (lot_kind != CIVIC_LOT \
					or not _lot_accepts_kind(index, kind)):
				continue
			var district := _lot(index, LOT_DISTRICT)
			if district >= active_districts:
				request_district(district)
				return false
			var reach := float(_district(district, DISTRICT_REACH_DM)) * 0.1
			if current_radius + 0.001 < reach:
				requested_district = maxi(requested_district, district)
				return false
			lot_states[index] = LOT_OWED
			return true
	return false


func free_lot_count(kind: int, include_dormant := true) -> int:
	var found := 0
	for index in lot_count():
		if lot_states[index] != LOT_FREE:
			continue
		if not include_dormant and _lot(index, LOT_DISTRICT) >= active_districts:
			continue
		if _lot_accepts_kind(index, kind):
			found += 1
	return found


## Compact cities use the exact same packed lot queue without constructing a grid.
## [param pending] skips lots promised to in-flight projects; [param reserve] turns
## the selected free lot into an owed physical placement once its work completes.
static func ledger_prepare_lot(state: Dictionary, kind: int,
		current_radius: float, pending := 0, reserve := false) -> Dictionary:
	var district_state: PackedInt32Array = state.get(
		"districts", PackedInt32Array())
	var lot_state: PackedInt32Array = state.get("lots", PackedInt32Array())
	var packed_version := int(state.get("version", 0))
	if packed_version < MIN_PACKED_VERSION or packed_version > VERSION \
			or district_state.size() < DISTRICT_STRIDE \
			or lot_state.size() < LOT_STRIDE:
		return {"managed": false, "ready": true, "state": state}
	state["version"] = VERSION
	var used: PackedByteArray = (state.get(
		"lot_states", PackedByteArray()) as PackedByteArray).duplicate()
	var count := lot_state.size() / LOT_STRIDE
	while used.size() < count:
		used.push_back(LOT_FREE)
	var matches := PackedInt32Array()
	for exact in [true, false]:
		for index in _ordered_snapshot_lot_indices(lot_state):
			if used[index] != LOT_FREE:
				continue
			var lot_kind := lot_state[index * LOT_STRIDE + LOT_KIND]
			if exact and lot_kind != kind:
				continue
			if not exact and (lot_kind != CIVIC_LOT \
					or not _snapshot_lot_accepts_kind(
						lot_state, index, kind)):
				continue
			matches.push_back(index)
	if pending < 0 or pending >= matches.size():
		state["lot_states"] = used
		return {
			"managed": true,
			"ready": false,
			"exhausted": true,
			"state": state,
		}
	var selected := matches[pending]
	var district := lot_state[selected * LOT_STRIDE + LOT_DISTRICT]
	var active := clampi(int(state.get("active_districts", 1)), 1,
		district_state.size() / DISTRICT_STRIDE)
	if district >= active:
		active = district + 1
		state["active_districts"] = active
		state["requested_district"] = district
	var reach := float(district_state[
		district * DISTRICT_STRIDE + DISTRICT_REACH_DM]) * 0.1
	if current_radius + 0.001 < reach:
		state["requested_district"] = maxi(
			int(state.get("requested_district", -1)), district)
		state["lot_states"] = used
		return {
			"managed": true,
			"ready": false,
			"exhausted": false,
			"target_radius": ledger_target_radius(state),
			"state": state,
		}
	if reserve:
		used[selected] = LOT_OWED
	state["lot_states"] = used
	return {
		"managed": true,
		"ready": true,
		"lot": selected,
		"state": state,
	}


static func _snapshot_lot_accepts_kind(
		lot_state: PackedInt32Array, index: int, kind: int) -> bool:
	if index < 0 or (index + 1) * LOT_STRIDE > lot_state.size() \
			or kind < 0 or kind >= MeepStructures.Kind.size():
		return false
	var lot_kind := lot_state[index * LOT_STRIDE + LOT_KIND]
	if lot_kind == kind:
		return true
	if lot_kind == MeepStructures.Kind.SUPER_SKYSCRAPER \
			and kind == MeepStructures.Kind.ARCLOGY:
		var replacement_span := MeepStructures.plan_of(kind).span
		var reserved_span := lot_state[
			index * LOT_STRIDE + LOT_MAX_SPAN]
		return replacement_span.x <= reserved_span \
			and replacement_span.y <= reserved_span
	if lot_kind != CIVIC_LOT or MeepStructures.is_residential_kind(kind):
		return false
	var span := MeepStructures.plan_of(kind).span
	var maximum := lot_state[index * LOT_STRIDE + LOT_MAX_SPAN]
	return span.x <= maximum and span.y <= maximum


static func _ordered_snapshot_lot_indices(
		lot_state: PackedInt32Array) -> PackedInt32Array:
	var count := lot_state.size() / LOT_STRIDE
	var ranked := PackedInt64Array()
	for index in count:
		var order := maxi(
			lot_state[index * LOT_STRIDE + LOT_ORDER], 0)
		ranked.push_back(int(order) * maxi(count, 1) + index)
	ranked.sort()
	var ordered := PackedInt32Array()
	for encoded in ranked:
		ordered.push_back(int(encoded % maxi(count, 1)))
	return ordered


static func ledger_target_radius(state: Dictionary) -> float:
	var district_state: PackedInt32Array = state.get(
		"districts", PackedInt32Array())
	var requested := int(state.get("requested_district", -1))
	if requested < 0 or (requested + 1) * DISTRICT_STRIDE \
			> district_state.size():
		return 0.0
	var count := district_state.size() / DISTRICT_STRIDE
	var active := clampi(int(state.get("active_districts", requested + 1)),
		1, count)
	var target := 0.0
	for district in active:
		target = maxf(target, float(district_state[
			district * DISTRICT_STRIDE + DISTRICT_REACH_DM]) * 0.1)
	return target


static func ledger_finish_expansion(state: Dictionary,
		current_radius: float) -> Dictionary:
	var target := ledger_target_radius(state)
	if target > 0.0 and current_radius + 0.001 >= target:
		state["requested_district"] = -1
	return state


## A district road is a planned piece of city structure, not a fresh path search.
## Projects remain dormant until every cell has entered the active claim.
func road_project_status(roads: MeepRoads, claim: MeepClaim,
		grid: MeepGrid) -> Dictionary:
	if roads == null or claim == null or grid == null:
		return {"state": RoadProjectState.NONE}
	var had_active := false
	for project in _road_projects:
		var district := int(project.get("district", 0))
		var subject := int(project.get("subject", 0))
		if district >= active_districts:
			continue
		had_active = true
		if roads.has_subject(subject):
			continue
		var planned: PackedInt32Array = project.get(
			"cells", PackedInt32Array())
		var missing := PackedInt32Array()
		for cell_index in planned:
			var cell := Vector2i(cell_index % grid.cells,
				cell_index / grid.cells)
			if not claim.contains_cell(cell):
				return {
					"state": RoadProjectState.WAITING_FOR_CLAIM,
					"district": district,
					"subject": subject,
				}
			if not grid.passable(cell) \
					or grid.has_flag(cell, MeepGrid.FLAG_BUILDING) \
					or (grid.has_flag(cell, MeepGrid.FLAG_RESERVED)
						and not roads.has_cell(cell_index)):
				return {
					"state": RoadProjectState.WAITING_FOR_SURFACE,
					"district": district,
					"subject": subject,
				}
			if not roads.has_cell(cell_index):
				missing.push_back(cell_index)
		return {
			"state": RoadProjectState.READY,
			"district": district,
			"subject": subject,
			"width_class": int(project.get("width_class", 0)),
			"cells": missing,
		}
	return {"state": RoadProjectState.COMPLETE
		if had_active else RoadProjectState.NONE}


func next_road_project(roads: MeepRoads, claim: MeepClaim,
		grid: MeepGrid) -> Dictionary:
	var status := road_project_status(roads, claim, grid)
	return status if int(status.get("state", RoadProjectState.NONE)) \
		== RoadProjectState.READY else {}


func _build_layout() -> void:
	districts.clear()
	lots.clear()
	lot_states.clear()
	var centre := _grid.cell_of(Vector2.ZERO)
	_add_district(centre, Vector2i(50, 50), 0, Shape.CORE, -1, 0,
		MeepClaim.DEFAULT_RADIUS)
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed ^ 0x43A91
	var base_angle := rng.randf() * TAU
	var previous_angle := base_angle
	for outer_index in OUTER_TIERS.size():
		var tier: int = OUTER_TIERS[outer_index]
		var angle := _district_angle(
			outer_index, base_angle, previous_angle, rng)
		previous_angle = angle
		var radius: float = OUTER_RADII[outer_index]
		var wanted_local := Vector2(cos(angle), sin(angle)) * radius
		var wanted := _grid.cell_of(wanted_local)
		var district_centre := _nearest_plan_cell(wanted, 18, tier)
		var half := _district_half_size(tier, outer_index)
		var orientation := posmod(
			roundi(angle / (PI * 0.5)), 4)
		var district_shape := _shape_for_style()
		var parent := _district_parent(district_centre)
		var reach := _district_required_reach(
			district_centre, half, orientation)
		_add_district(district_centre, half, tier, district_shape,
			parent, orientation, reach)
	# Roads and parks constrain lot generation, but no runtime mask is published
	# until the completed lot queue has been marked against existing construction.
	_build_derived(false)
	_generate_lots()


func _build_derived(build_masks := true) -> void:
	_build_all_parks()
	_build_roads()
	for project in _road_projects:
		for cell_index in project.get("cells", PackedInt32Array()):
			if cell_index >= 0 and cell_index < _all_park_mask.size():
				_all_park_mask[cell_index] = 0
	for lot in lot_count():
		var kind := _lot(lot, LOT_KIND)
		var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
			_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
			else MeepStructures.plan_of(kind).span
		var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
			- Vector2i(span.x / 2, span.y / 2)
		for y in span.y:
			for x in span.x:
				var cell := corner + Vector2i(x, y)
				if _grid.inside(cell):
					_all_park_mask[_grid.index(cell)] = 0
	if build_masks:
		_build_active_masks()


func _generate_lots() -> void:
	lots.clear()
	lot_states.clear()
	_candidate_cache.clear()
	var occupied := PackedByteArray()
	occupied.resize(_grid.cells * _grid.cells)
	for cell_index in occupied.size():
		if (int(_grid.flags[cell_index]) & (MeepGrid.FLAG_BUILDING \
				| MeepGrid.FLAG_ROAD | MeepGrid.FLAG_RESERVED \
				| MeepGrid.FLAG_SHIP)) != 0:
			occupied[cell_index] = 1
	for project in _road_projects:
		for cell_index in project.get("cells", PackedInt32Array()):
			if cell_index >= 0 and cell_index < occupied.size():
				occupied[cell_index] = 1
	var order := 0
	# Future-sized civic pads are seeded through ordinary neighbourhoods before
	# houses consume the blocks. Their span cycle is seed-rotated but every city
	# attempts all three sizes; there is deliberately no upgrade-only district.
	var civic_targets := {
		# Hat, Abilities, Harvester, and three additional Cloners all need a
		# current small civic contract before future upgrade kinds are counted.
		9: 4,
		12: 1,
		15: 1,
	}
	var civic_counts := {
		9: 0,
		12: 0,
		15: 0,
	}
	var civic_districts: Dictionary = {}
	for district in district_count():
		var wanted := CORE_CIVIC_LOTS if district == 0 else 1
		var span_slot := posmod(district + _seed, CIVIC_PAD_SPANS.size())
		var maximum: int = 9 if district == 0 \
			else CIVIC_PAD_SPANS[span_slot]
		wanted = mini(wanted, int(civic_targets.get(maximum, 0))
			- int(civic_counts.get(maximum, 0)))
		if wanted <= 0:
			continue
		for candidate in _cached_district_candidates(
				district, maxi(7, maximum / 2 + 3)):
			if wanted <= 0:
				break
			if _try_add_lot(CIVIC_LOT, candidate, district, maximum,
					order, occupied):
				order += 1
				wanted -= 1
				civic_counts[maximum] = int(civic_counts.get(
					maximum, 0)) + 1
				civic_districts[district] = true
	# A rough founding site may reject a span in its seed-selected district.
	# Deterministically search the other ordinary districts once so every city
	# still carries the complete current and future civic contract.
	for maximum in CIVIC_PAD_SPANS:
		var missing := int(civic_targets.get(maximum, 0)) \
			- int(civic_counts.get(maximum, 0))
		if missing <= 0:
			continue
		for prefer_unused_district in [true, false]:
			if missing <= 0:
				break
			for offset in district_count():
				if missing <= 0:
					break
				var district := posmod(
					offset + _seed + maximum, district_count())
				if prefer_unused_district and civic_districts.has(district):
					continue
				for candidate in _cached_district_candidates(
						district, maxi(5, maximum / 2 + 2)):
					if not _try_add_lot(CIVIC_LOT, candidate, district,
							maximum, order, occupied, true):
						continue
					order += 1
					missing -= 1
					civic_counts[maximum] = int(civic_counts.get(
						maximum, 0)) + 1
					civic_districts[district] = true
					break
	# The first standalone cloner and the complete Tier-0 settlement plan.
	for candidate in _cached_district_candidates(0, 5):
		if _try_add_lot(MeepStructures.Kind.CLONER, candidate, 0, 3,
				order, occupied):
			order += 1
			break
	var huts := 0
	var core_candidates := _cached_district_candidates(0, 6)
	# The first families settle beside the plaza; the next block establishes a
	# real outer street, after which the remaining prepared blocks fill in.
	for candidate in core_candidates:
		if huts >= 3:
			break
		if _try_add_lot(MeepStructures.Kind.HUT, candidate, 0, 3,
				order, occupied):
			order += 1
			huts += 1
	for reverse_index in range(core_candidates.size() - 1, -1, -1):
		var candidate := core_candidates[reverse_index]
		var candidate_radius := _grid.centre_of(candidate).length()
		if candidate_radius < 78.0 \
				or candidate_radius > MeepClaim.DEFAULT_RADIUS - 5.0:
			continue
		if _try_add_lot(MeepStructures.Kind.HUT, candidate, 0, 3,
				order, occupied):
			order += 1
			huts += 1
			break
	# Successive districts contain only the architecture intended for their stage.
	var tier_ordinals: Dictionary = {}
	for district in range(1, district_count()):
		var tier := _district(district, DISTRICT_TIER)
		var tier_ordinal := int(tier_ordinals.get(tier, 0))
		tier_ordinals[tier] = tier_ordinal + 1
		var count := int(RESIDENTIAL_LOTS_PER_DISTRICT.get(tier, 1))
		for slot in count:
			var kind := MeepStructures.residential_kind_for_tier(tier)
			if tier >= 4 and (tier_ordinal + slot) % 3 == 0:
				kind = MeepStructures.Kind.ARCLOGY
			elif tier >= 4:
				kind = MeepStructures.Kind.MEGA_SKYSCRAPER
			var placed := false
			var form_span := MeepStructures.plan_of(kind).span
			var step := 3 if maxi(form_span.x, form_span.y) < 9 else 4
			for candidate in _cached_district_candidates(district, step):
				if _try_add_lot(kind, candidate, district,
						maxi(MeepStructures.plan_of(kind).span.x,
							MeepStructures.plan_of(kind).span.y),
						order, occupied):
					order += 1
					placed = true
					break
			if not placed:
				break
	for requirement in [
			Vector2i(MeepStructures.Kind.TOWNHOUSE, 14),
			Vector2i(MeepStructures.Kind.MID_RISE, 10),
			Vector2i(MeepStructures.Kind.SKYSCRAPER, 8),
			Vector2i(MeepStructures.Kind.ARCLOGY, 3),
			Vector2i(MeepStructures.Kind.MEGA_SKYSCRAPER, 5),
		]:
		while _planned_kind_count(requirement.x) < requirement.y:
			var added := false
			var required_tier := MeepStructures.plan_of(requirement.x).tier
			for district in range(1, district_count()):
				if _district(district, DISTRICT_TIER) != required_tier:
					continue
				for candidate in _cached_district_candidates(district,
						3 if requirement.x < MeepStructures.Kind.SKYSCRAPER
							else 4):
					var span := MeepStructures.plan_of(requirement.x).span
					if _try_add_lot(requirement.x, candidate, district,
							maxi(span.x, span.y), order, occupied):
						order += 1
						added = true
						break
				if added:
					break
			if not added:
				var candidate := _global_lot_candidate(
					requirement.x, occupied)
				if candidate.x >= 0:
					var span := MeepStructures.plan_of(requirement.x).span
					var tier := MeepStructures.plan_of(requirement.x).tier
					var half := Vector2i(maxi(span.x + 5, 12),
						maxi(span.y + 5, 12))
					var parent := _district_parent(candidate)
					var district := district_count()
					_add_district(candidate, half, tier, _shape_for_style(),
						parent, posmod(district + _seed, 4),
						_district_required_reach(candidate, half, 0))
					added = _try_add_lot(requirement.x, candidate, district,
						maxi(span.x, span.y), order, occupied, true)
					if added:
						order += 1
			if not added:
				break
	# Fill the remaining Tier-0 blocks after every later tier has secured its
	# minimum housing campuses. Dense forms cannot otherwise recover when dozens
	# of surplus hut reservations consume the last broad, level sites.
	for candidate in core_candidates:
		if huts >= CORE_HUT_LOTS:
			break
		if _try_add_lot(MeepStructures.Kind.HUT, candidate, 0, 3,
				order, occupied):
			order += 1
			huts += 1
	lot_states.resize(lot_count())
	lot_states.fill(LOT_FREE)
	# Candidate rankings are founding scratch, not part of the resident city.
	_candidate_cache.clear()


func _planned_kind_count(kind: int) -> int:
	var found := 0
	for index in lots.size() / LOT_STRIDE:
		if _lot(index, LOT_KIND) == kind:
			found += 1
	return found


func _global_lot_candidate(kind: int,
		occupied: PackedByteArray) -> Vector2i:
	var plan := MeepStructures.plan_of(kind)
	var desired_radius := 112.0 + float(plan.tier) * 12.0
	var phase := float(posmod(
		_seed ^ (kind * 7919) ^ (_planned_kind_count(kind) * 104729),
		65521)) / 65521.0
	# Most fallback campuses have open ground on their preferred ring. Probe that
	# ring first in a seed-rotated order; the old exhaustive square remains below
	# only for unusually fragmented terrain.
	for radial_step in 20:
		var signed_step := 0 if radial_step == 0 \
			else ceili(float(radial_step) * 0.5) \
				* (1 if radial_step % 2 == 1 else -1)
		var radius := clampf(desired_radius + float(signed_step) * 4.0,
			MeepClaim.DEFAULT_RADIUS, _max_radius - 4.0)
		for angle_step in 72:
			var angle := TAU * (phase + float(angle_step) / 72.0)
			var centre := _grid.cell_of(
				Vector2(cos(angle), sin(angle)) * radius)
			var corner := centre - Vector2i(
				plan.span.x / 2, plan.span.y / 2)
			if _footprint_valid(plan, corner, plan.span, occupied, true):
				return centre
	var best := Vector2i(-1, -1)
	var best_score := INF
	var grid_phase := posmod(_seed ^ (kind * 7919), 2)
	for y in range(grid_phase, _grid.cells, 2):
		for x in range(grid_phase, _grid.cells, 2):
			var centre := Vector2i(x, y)
			var local := _grid.centre_of(centre)
			if local.length() < MeepClaim.DEFAULT_RADIUS - 8.0 \
					or local.length() > _max_radius - 3.0:
				continue
			var corner := centre - Vector2i(
				plan.span.x / 2, plan.span.y / 2)
			if not _footprint_valid(
					plan, corner, plan.span, occupied, true):
				continue
			var score := absf(local.length() - (112.0
				+ float(plan.tier) * 12.0))
			score += float(posmod(_grid.index(centre) ^ _seed, 997)) * 0.0001
			if score < best_score:
				best_score = score
				best = centre
	return best


func _try_add_lot(kind: int, centre: Vector2i, district: int,
		max_span: int, order: int, occupied: PackedByteArray,
		clear_planned_park := false) -> bool:
	var actual_kind := _civic_pad_kind(max_span) \
		if kind == CIVIC_LOT else kind
	var plan := MeepStructures.plan_of(actual_kind)
	var span := Vector2i(max_span, max_span) \
		if kind == CIVIC_LOT else plan.span
	var corner := centre - Vector2i(span.x / 2, span.y / 2)
	if district == 0 and _claim != null:
		for y in span.y:
			for x in span.x:
				var cell := corner + Vector2i(x, y)
				if not _claim.contains_cell(cell) \
						or not _inside_district(0, cell):
					return false
	if not _footprint_valid(
			plan, corner, span, occupied, clear_planned_park):
		return false
	if clear_planned_park:
		for y in span.y:
			for x in span.x:
				_all_park_mask[_grid.index(
					corner + Vector2i(x, y))] = 0
	lots.append_array(PackedInt32Array([
		kind, centre.x, centre.y, district, max_span, order,
	]))
	_extend_district_reach_for_footprint(district, corner, span)
	var margin := maxi(2, ceili(plan.spacing / (_grid.cell_size * 2.0)))
	for y in range(corner.y - margin, corner.y + span.y + margin):
		for x in range(corner.x - margin, corner.x + span.x + margin):
			var cell := Vector2i(x, y)
			if _grid.inside(cell):
				occupied[_grid.index(cell)] = 1
	return true


## District reach is also a construction guarantee: when its border finishes
## growing, every cell of every authored lot must be physically claimable.
func _extend_district_reach_for_footprint(district: int,
		corner: Vector2i, span: Vector2i) -> void:
	if _grid == null or district < 0 or district >= district_count():
		return
	var required := 0.0
	for y in span.y:
		for x in span.x:
			var cell := corner + Vector2i(x, y)
			if _grid.inside(cell):
				required = maxf(required, _grid.centre_of(cell).length())
	var field := district * DISTRICT_STRIDE + DISTRICT_REACH_DM
	districts[field] = maxi(districts[field],
		ceili(minf(required, _max_radius) * 10.0))


func _extend_district_reach_for_lot(lot: int) -> void:
	if lot < 0 or lot >= lot_count():
		return
	var kind := _lot(lot, LOT_KIND)
	var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
		_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
		else MeepStructures.plan_of(kind).span
	var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
		- Vector2i(span.x / 2, span.y / 2)
	_extend_district_reach_for_footprint(
		_lot(lot, LOT_DISTRICT), corner, span)


func _extend_all_district_reaches_from_lots() -> void:
	for lot in lot_count():
		_extend_district_reach_for_lot(lot)


static func _civic_pad_kind(max_span: int) -> int:
	if max_span >= 15:
		return MeepStructures.Kind.SUPER_SKYSCRAPER
	if max_span >= 12:
		return MeepStructures.Kind.MEGA_SKYSCRAPER
	return MeepStructures.Kind.BIOMASS_HARVESTER


func _footprint_valid(plan: MeepStructures.Plan, corner: Vector2i,
		span: Vector2i, occupied: PackedByteArray,
		allow_planned_park := false) -> bool:
	var lowest := INF
	var highest := -INF
	for y in span.y:
		for x in span.x:
			var cell := corner + Vector2i(x, y)
			if not _grid.inside(cell):
				return false
			var index := _grid.index(cell)
			if (not allow_planned_park and _all_park_mask[index] != 0) \
					or occupied[index] != 0 \
					or _grid.terrain_at(cell) != MeepGrid.Terrain.PASSABLE:
				return false
			var local := _grid.centre_of(cell)
			if local.length() > _max_radius:
				return false
			var height := _grid.height_at(cell)
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > plan.level_tolerance:
		return false
	var middle := _grid.centre_of(corner) \
		+ Vector2(span - Vector2i.ONE) * _grid.cell_size * 0.5
	var half := Vector2(span) * _grid.cell_size * 0.5
	var nearest := Vector2(
		maxf(absf(middle.x) - half.x, 0.0),
		maxf(absf(middle.y) - half.y, 0.0))
	return nearest.length() >= MeepStructures.SHIP_CLEAR_RADIUS


func _district_candidates(district: int, step: int) -> Array[Vector2i]:
	var ranked := PackedInt64Array()
	var centre := _district_cell(district)
	var half := Vector2i(_district(district, DISTRICT_HALF_X),
		_district(district, DISTRICT_HALF_Y))
	var orientation := _district(district, DISTRICT_ORIENTATION)
	var start_x := -half.x + step / 2
	var start_y := -half.y + step / 2
	var total := _grid.cells * _grid.cells
	for local_y in range(start_y, half.y + 1, maxi(step, 1)):
		for local_x in range(start_x, half.x + 1, maxi(step, 1)):
			var offset := _orient(Vector2i(local_x, local_y), orientation)
			var cell := centre + offset
			if not _grid.inside(cell):
				continue
			if district == 0 and _grid.centre_of(cell).length() \
					> MeepClaim.DEFAULT_RADIUS - 4.0:
				continue
			var index := _grid.index(cell)
			if index >= _all_park_mask.size() \
					or not _inside_district(district, cell):
				continue
			var score := _candidate_score(district, cell, local_x, local_y)
			# Packed integer sorting stays in native code. Four decimal places retain
			# the seeded score's tie-break while the cell index makes every order total.
			ranked.push_back(
				int(round(score * 10000.0)) * total + _grid.index(cell))
	ranked.sort()
	var cells: Array[Vector2i] = []
	for encoded in ranked:
		var cell_index := int(encoded % total)
		cells.push_back(Vector2i(
			cell_index % _grid.cells, cell_index / _grid.cells))
	return cells


func _cached_district_candidates(district: int, step: int) -> Array[Vector2i]:
	var key := Vector2i(district, step)
	if not _candidate_cache.has(key):
		_candidate_cache[key] = _district_candidates(district, step)
	return _candidate_cache[key] as Array[Vector2i]


func _candidate_score(district: int, cell: Vector2i,
		local_x: int, local_y: int) -> float:
	var local := _grid.centre_of(cell)
	var score := local.length()
	match style:
		Style.RING_AND_SPOKE:
			score += absf(float(local_x * local_y)) * 0.03
		Style.ORGANIC_BRANCHES:
			score += absf(sin(float(local_x) * 0.31
				+ float(district))) * 8.0
		Style.PARK_COURTYARDS:
			score += float(absi(local_x) + absi(local_y)) * 0.12
		Style.TERRACES:
			score += absf(float(local_y)) * 0.35
		_:
			score += float(posmod(local_x + local_y + _seed, 3))
	return score + float(posmod(_grid.index(cell) ^ _seed, 97)) * 0.0001


func _build_all_parks() -> void:
	var total := _grid.cells * _grid.cells
	_all_park_mask.resize(total)
	_all_park_mask.fill(0)
	for district in district_count():
		var centre := _district_cell(district)
		var tier := _district(district, DISTRICT_TIER)
		var half_size := 3 + mini(tier, 2)
		var offsets: Array[Vector2i] = []
		if district == 0:
			var phase := posmod(_seed, 4)
			for quadrant in 4:
				var angle := float(quadrant + phase) * PI * 0.5 + PI * 0.25
				offsets.push_back(Vector2i(
					roundi(cos(angle) * 24.0),
					roundi(sin(angle) * 24.0)))
		elif style == Style.PARK_COURTYARDS:
			offsets.push_back(Vector2i.ZERO)
			half_size += 2
		elif style == Style.RING_AND_SPOKE:
			offsets.push_back(Vector2i(0, -4))
		else:
			offsets.push_back(Vector2i(4, 4))
		for offset in offsets:
			var park_centre := centre + _orient(offset,
				_district(district, DISTRICT_ORIENTATION))
			for y in range(-half_size, half_size + 1):
				for x in range(-half_size, half_size + 1):
					var cell := park_centre + Vector2i(x, y)
					if not _grid.inside(cell) \
							or _grid.centre_of(cell).length() \
								< MeepStructures.SHIP_CLEAR_RADIUS + 4.0:
						continue
					var index := _grid.index(cell)
					if _grid.terrain_at(cell) == MeepGrid.Terrain.PASSABLE:
						_all_park_mask[index] = 1


func _build_roads() -> void:
	_road_projects.clear()
	var project_index := 0
	for district in range(1, district_count()):
		var centre := _district_cell(district)
		var parent := _district(district, DISTRICT_PARENT)
		var parent_centre := _district_cell(maxi(parent, 0))
		var tier := _district(district, DISTRICT_TIER)
		var width := MeepRoads.width_class_for_tier(tier)
		if district > OUTER_TIERS.size():
			# Emergency terrain campuses are centred on their one large lot. Give
			# them a planned edge approach instead of cutting a generic cross through it.
			var approach := _fallback_district_approach(
				district, parent_centre)
			_add_road_project(district, project_index,
				_line_cells(parent_centre, approach), width)
			project_index += 1
			continue
		_add_road_project(district, project_index,
			_line_cells(parent_centre, centre), width)
		project_index += 1
		var half_x := _district(district, DISTRICT_HALF_X)
		var half_y := _district(district, DISTRICT_HALF_Y)
		var orientation := _district(district, DISTRICT_ORIENTATION)
		match style:
			Style.RING_AND_SPOKE:
				for side in _rectangle_sides(centre,
						Vector2i(maxi(half_x - 4, 4),
							maxi(half_y - 4, 4)), orientation):
					_add_road_project(district, project_index, side, width)
					project_index += 1
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(-half_x, 0),
						Vector2i(half_x, 0), orientation), width)
				project_index += 1
			Style.ORGANIC_BRANCHES:
				_add_road_project(district, project_index,
					_bent_line(centre, half_x, half_y, orientation), width)
				project_index += 1
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(0, -half_y / 2),
						Vector2i(half_x / 2, half_y / 2), orientation),
					width)
				project_index += 1
			Style.PARK_COURTYARDS:
				for side in _rectangle_sides(centre,
						Vector2i(7 + tier, 7 + tier), orientation):
					_add_road_project(district, project_index, side, width)
					project_index += 1
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(-half_x, 0),
						Vector2i(-(7 + tier), 0), orientation), width)
				project_index += 1
			Style.TERRACES:
				for lane in [-half_y / 2, half_y / 2]:
					_add_road_project(district, project_index,
						_oriented_line(centre, Vector2i(-half_x, lane),
							Vector2i(half_x, lane), orientation), width)
					project_index += 1
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(0, -half_y / 2),
						Vector2i(0, half_y / 2), orientation), width)
				project_index += 1
			_:
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(-half_x, 0),
						Vector2i(half_x, 0), orientation), width)
				project_index += 1
				_add_road_project(district, project_index,
					_oriented_line(centre, Vector2i(0, -half_y),
						Vector2i(0, half_y), orientation), width)
				project_index += 1
		# Mature neighbourhoods get a genuinely separate second approach.
		if tier >= 2:
			var offset := _orient(Vector2i(0, 3 + tier), orientation)
			_add_road_project(district, project_index,
				_line_cells(parent_centre + offset, centre + offset), width)
			project_index += 1


func _fallback_district_approach(
		district: int, parent_centre: Vector2i) -> Vector2i:
	var centre := _district_cell(district)
	var maximum := 3
	for lot in lot_count():
		if _lot(lot, LOT_DISTRICT) == district:
			maximum = maxi(maximum, _lot(lot, LOT_MAX_SPAN))
	var toward := parent_centre - centre
	var clearance := maximum / 2 + 2
	if absi(toward.x) >= absi(toward.y):
		return centre + Vector2i(
			clearance if toward.x >= 0 else -clearance, 0)
	return centre + Vector2i(
		0, clearance if toward.y >= 0 else -clearance)


func _add_road_project(district: int, project_index: int,
		cells: PackedInt32Array, width: int) -> void:
	var unique := PackedInt32Array()
	var seen: Dictionary = {}
	for cell_index in cells:
		if cell_index < 0 or cell_index >= _grid.cells * _grid.cells \
				or seen.has(cell_index):
			continue
		if not _grid.region_buildable_index(cell_index):
			if not unique.is_empty():
				break
			continue
		seen[cell_index] = true
		unique.push_back(cell_index)
	if unique.size() < 2:
		return
	_road_projects.push_back({
		"district": district,
		"subject": ROAD_SUBJECT_BASE - project_index,
		"width_class": width,
		"cells": unique,
	})


## Lot consumption changes one small footprint, not the district, parks or permit.
## Updating it in place keeps ordinary construction from rescanning the 192² grid.
func _refresh_lot_mask(lot: int) -> void:
	if _grid == null:
		return
	var total := _grid.cells * _grid.cells
	if _lot_mask.size() != total or _permit_mask.size() != total:
		_build_active_masks(false)
		return
	var kind := _lot(lot, LOT_KIND)
	var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
		_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
		else MeepStructures.plan_of(kind).span
	var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
		- Vector2i(span.x / 2, span.y / 2)
	var wants_lot := (lot_states[lot] == LOT_FREE \
			or lot_states[lot] == LOT_OWED)
	for y in span.y:
		for x in span.x:
			var cell := corner + Vector2i(x, y)
			if not _grid.inside(cell):
				continue
			var cell_index := _grid.index(cell)
			var bits := int(_grid.flags[cell_index])
			_lot_mask[cell_index] = 1 if wants_lot \
				and _grid.region_buildable_index(cell_index) \
				and (bits & (MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_ROAD)) == 0 \
				else 0
	_mask_revision += 1


func _build_active_masks(bump_permit := true) -> void:
	if _grid == null:
		return
	var total := _grid.cells * _grid.cells
	_permit_mask.resize(total)
	_permit_mask.fill(0)
	_park_mask.resize(total)
	_park_mask.fill(0)
	_lot_mask.resize(total)
	_lot_mask.fill(0)
	_fill_district_mask(0, _permit_mask)
	for district in range(1, mini(active_districts, district_count())):
		_fill_district_mask(district, _permit_mask)
		var parent := maxi(_district(district, DISTRICT_PARENT), 0)
		_fill_corridor(_district_cell(parent), _district_cell(district),
			CORRIDOR_HALF_WIDTH + mini(_district(
				district, DISTRICT_TIER), 2), _permit_mask)
	# A lot centre is constrained to its district shape, but a large tower footprint
	# may intentionally straddle that shape's clipped edge. Give every active lot a
	# small construction apron so its authored cells and work perimeter are actually
	# claimable. Core footprints are generated wholly inside their authored shape;
	# outer local protrusions make the visible border follow building need instead of
	# smoothing district extents back into a radial ring.
	for lot in lot_count():
		if _lot(lot, LOT_DISTRICT) >= active_districts \
				or lot_states[lot] == LOT_BLOCKED \
				or lot_states[lot] == LOT_REGION_BLOCKED:
			continue
		var kind := _lot(lot, LOT_KIND)
		var district := _lot(lot, LOT_DISTRICT)
		if district == 0:
			continue
		var lot_centre := Vector2i(
			_lot(lot, LOT_X), _lot(lot, LOT_Y))
		_fill_corridor(_district_cell(district), lot_centre,
			1 + mini(_district(district, DISTRICT_TIER), 1), _permit_mask)
		var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
			_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
			else MeepStructures.plan_of(kind).span
		var corner := lot_centre \
			- Vector2i(span.x / 2, span.y / 2)
		for y in range(corner.y - 2, corner.y + span.y + 2):
			for x in range(corner.x - 2, corner.x + span.x + 2):
				var cell := Vector2i(x, y)
				if _grid.inside(cell) \
						and _grid.centre_of(cell).length() <= _max_radius:
					_permit_mask[_grid.index(cell)] = 1
	for index in mini(_legacy_mask.size(), total):
		if _legacy_mask[index] != 0:
			_permit_mask[index] = 1
	for index in total:
		if not _grid.regionally_owned_index(index) \
				and (index >= _legacy_mask.size() or _legacy_mask[index] == 0):
			_permit_mask[index] = 0
	for index in mini(_all_park_mask.size(), total):
		if _all_park_mask[index] == 0 or _permit_mask[index] == 0 \
				or not _grid.region_buildable_index(index):
			continue
		# Existing streets and buildings win migration conflicts.
		var bits := int(_grid.flags[index])
		if (bits & (MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_ROAD)) == 0:
			_park_mask[index] = 1
	for lot in lot_count():
		if lot_states[lot] != LOT_FREE and lot_states[lot] != LOT_OWED:
			continue
		var kind := _lot(lot, LOT_KIND)
		var span := Vector2i(_lot(lot, LOT_MAX_SPAN),
			_lot(lot, LOT_MAX_SPAN)) if kind == CIVIC_LOT \
			else MeepStructures.plan_of(kind).span
		var corner := Vector2i(_lot(lot, LOT_X), _lot(lot, LOT_Y)) \
			- Vector2i(span.x / 2, span.y / 2)
		for y in span.y:
			for x in span.x:
				var cell := corner + Vector2i(x, y)
				if not _grid.inside(cell):
					continue
				var cell_index := _grid.index(cell)
				if not _grid.region_buildable_index(cell_index):
					continue
				var bits := int(_grid.flags[cell_index])
				if (bits & (MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_ROAD)) == 0:
					_lot_mask[cell_index] = 1
	if bump_permit:
		_permit_revision += 1
	_mask_revision += 1


func _fill_district_mask(district: int, mask: PackedByteArray) -> void:
	var centre := _district_cell(district)
	var half_x := _district(district, DISTRICT_HALF_X)
	var half_y := _district(district, DISTRICT_HALF_Y)
	var orientation := _district(district, DISTRICT_ORIENTATION)
	for local_y in range(-half_y, half_y + 1):
		for local_x in range(-half_x, half_x + 1):
			var cell := centre + _orient(
				Vector2i(local_x, local_y), orientation)
			if not _grid.inside(cell) or not _inside_shape(
					district, local_x, local_y):
				continue
			if _grid.centre_of(cell).length() <= _max_radius:
				mask[_grid.index(cell)] = 1


func _fill_corridor(from: Vector2i, to: Vector2i, half_width: int,
		mask: PackedByteArray) -> void:
	for cell_index in _line_cells(from, to):
		var centre := Vector2i(cell_index % _grid.cells,
			cell_index / _grid.cells)
		for y in range(-half_width, half_width + 1):
			for x in range(-half_width, half_width + 1):
				var cell := centre + Vector2i(x, y)
				if _grid.inside(cell) \
						and _grid.centre_of(cell).length() <= _max_radius:
					mask[_grid.index(cell)] = 1


func _inside_district(district: int, cell: Vector2i) -> bool:
	var centre := _district_cell(district)
	var offset := _unorient(cell - centre,
		_district(district, DISTRICT_ORIENTATION))
	return _inside_shape(district, offset.x, offset.y)


func _inside_shape(district: int, x: int, y: int) -> bool:
	var half_x := maxf(float(_district(district, DISTRICT_HALF_X)), 1.0)
	var half_y := maxf(float(_district(district, DISTRICT_HALF_Y)), 1.0)
	match _district(district, DISTRICT_SHAPE):
		Shape.CORE:
			var nx := absf(float(x)) / half_x
			var ny := absf(float(y)) / half_y
			var radial := sqrt(nx * nx + ny * ny)
			var phase := float(posmod(_seed, 6283)) * 0.001
			var angle := atan2(float(y), float(x)) + phase
			match style:
				Style.RING_AND_SPOKE:
					return radial <= 0.84 + cos(angle * 4.0) * 0.08 \
						+ cos(angle * 7.0) * 0.03
				Style.ORGANIC_BRANCHES:
					return radial <= 0.80 + sin(angle * 3.0) * 0.12 \
						+ sin(angle * 5.0 + 0.7) * 0.06
				Style.PARK_COURTYARDS:
					return nx <= 0.92 and ny <= 0.92 \
						and (minf(nx, ny) <= 0.62 or radial <= 0.78)
				Style.TERRACES:
					var terrace := floorf(nx * 4.0) * 0.045
					return nx <= 0.94 and ny <= 0.90 - terrace
				_:
					return nx <= 0.92 and ny <= 0.92 \
						and nx + ny <= 1.48
		Shape.ELLIPSE:
			return float(x * x) / (half_x * half_x) \
				+ float(y * y) / (half_y * half_y) <= 1.0
		Shape.BRANCH:
			var wave := sin((float(x) + float(district * 3)) * 0.24) \
				* half_y * 0.22
			return absf(float(y) - wave) <= half_y \
				* (0.72 + 0.28 * (1.0 - absf(float(x)) / half_x))
		Shape.COURTYARD:
			# Keep the central park inside the district while clipping the four
			# anonymous rectangular corners into a recognizable courtyard block.
			return absf(float(x)) <= half_x and absf(float(y)) <= half_y \
				and (absf(float(x)) <= half_x * 0.78 \
					or absf(float(y)) <= half_y * 0.78)
		Shape.TERRACE:
			return absf(float(x)) <= half_x \
				and absf(float(y)) <= half_y \
				and not (absf(float(x)) > half_x * 0.82
					and absf(float(y)) > half_y * 0.72)
		_:
			return absf(float(x)) <= half_x and absf(float(y)) <= half_y


func _mark_existing(structures: MeepStructures, roads: MeepRoads) -> void:
	var total := _grid.cells * _grid.cells
	_legacy_mask.resize(total)
	_legacy_mask.fill(0)
	if structures != null:
		for structure in structures.count():
			var entry := structures.at(structure)
			if entry == null:
				continue
			var plan := MeepStructures.plan_of(entry.kind)
			for y in range(-2, plan.span.y + 2):
				for x in range(-2, plan.span.x + 2):
					var cell := entry.corner + Vector2i(x, y)
					if _grid.inside(cell):
						_legacy_mask[_grid.index(cell)] = 1
			_fill_corridor(_grid.cell_of(Vector2.ZERO),
				_grid.cell_of(entry.local), 1, _legacy_mask)
			_mark_matching_lot(entry.kind, entry.local)
	if roads != null:
		for slot in roads.cell_count():
			var cell_index := roads.cell_index_at(slot)
			if cell_index >= 0 and cell_index < total:
				_legacy_mask[cell_index] = 1


func _mark_matching_lot(kind: int, local: Vector2) -> void:
	var best := -1
	var best_distance := INF
	for index in lot_count():
		if not _lot_accepts_kind(index, kind):
			continue
		var away := _grid.centre_of(Vector2i(
			_lot(index, LOT_X), _lot(index, LOT_Y))).distance_squared_to(local)
		if away < best_distance:
			best_distance = away
			best = index
	if best >= 0 and best_distance <= 24.0 * 24.0:
		if lot_states[best] == LOT_FREE:
			lot_states[best] = LOT_BUILT
		active_districts = maxi(active_districts,
			_lot(best, LOT_DISTRICT) + 1)


func _lot_available_now(index: int, kind: int, corner: Vector2i) -> bool:
	if _grid == null or _claim == null:
		return false
	var plan := MeepStructures.plan_of(kind)
	var span := plan.span
	var checked_corner := corner
	if _lot(index, LOT_KIND) == CIVIC_LOT:
		var maximum := _lot(index, LOT_MAX_SPAN)
		plan = MeepStructures.plan_of(_civic_pad_kind(maximum))
		span = Vector2i(maximum, maximum)
		checked_corner = Vector2i(_lot(index, LOT_X), _lot(index, LOT_Y)) \
			- Vector2i(maximum / 2, maximum / 2)
	var lowest := INF
	var highest := -INF
	for y in span.y:
		for x in span.x:
			var cell := checked_corner + Vector2i(x, y)
			if not _grid.inside(cell) or not _claim.contains_cell(cell) \
					or not _grid.passable(cell) \
					or not _grid.region_buildable(cell):
				return false
			var bits := _grid.flags_at(cell)
			if (bits & (MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_ROAD
					| MeepGrid.FLAG_RESERVED | MeepGrid.FLAG_PARK)) != 0:
				return false
			var height := _grid.height_at(cell)
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	return highest - lowest <= plan.level_tolerance


func _lot_accepts_kind(index: int, kind: int) -> bool:
	if index < 0 or index >= lot_count() \
			or kind < 0 or kind >= MeepStructures.Kind.size():
		return false
	var lot_kind := _lot(index, LOT_KIND)
	if lot_kind == kind:
		return true
	if lot_kind == MeepStructures.Kind.SUPER_SKYSCRAPER \
			and kind == MeepStructures.Kind.ARCLOGY:
		var replacement_span := MeepStructures.plan_of(kind).span
		var reserved_span := _lot(index, LOT_MAX_SPAN)
		return replacement_span.x <= reserved_span \
			and replacement_span.y <= reserved_span
	if lot_kind != CIVIC_LOT or MeepStructures.is_residential_kind(kind):
		return false
	var span := MeepStructures.plan_of(kind).span
	var maximum := _lot(index, LOT_MAX_SPAN)
	return span.x <= maximum and span.y <= maximum


func _ordered_lot_indices() -> PackedInt32Array:
	var count := lot_count()
	var ranked := PackedInt64Array()
	for index in count:
		var order := maxi(_lot(index, LOT_ORDER), 0)
		ranked.push_back(int(order) * maxi(count, 1) + index)
	ranked.sort()
	var ordered := PackedInt32Array()
	for encoded in ranked:
		ordered.push_back(int(encoded % maxi(count, 1)))
	return ordered


func _lot_dictionary(index: int, kind: int, corner: Vector2i) -> Dictionary:
	return {
		"index": index,
		"kind": kind,
		"corner": corner,
		"district": _lot(index, LOT_DISTRICT),
		"district_tier": _district(
			_lot(index, LOT_DISTRICT), DISTRICT_TIER),
	}


func _lot_corner(index: int, kind: int) -> Vector2i:
	var centre := Vector2i(_lot(index, LOT_X), _lot(index, LOT_Y))
	var span := MeepStructures.plan_of(kind).span
	return centre - Vector2i(span.x / 2, span.y / 2)


func _add_district(centre: Vector2i, half: Vector2i, tier: int,
		shape: int, parent: int, orientation: int, reach: float) -> void:
	districts.append_array(PackedInt32Array([
		centre.x, centre.y, half.x, half.y, tier, shape, parent,
		orientation, roundi(clampf(reach, MeepClaim.DEFAULT_RADIUS,
			_max_radius) * 10.0),
	]))


func _district(index: int, field: int) -> int:
	return districts[index * DISTRICT_STRIDE + field]


func _district_cell(index: int) -> Vector2i:
	return Vector2i(_district(index, DISTRICT_X),
		_district(index, DISTRICT_Y))


func _lot(index: int, field: int) -> int:
	return lots[index * LOT_STRIDE + field]


func _district_angle(index: int, base: float, previous: float,
		rng: RandomNumberGenerator) -> float:
	match style:
		Style.GRID_BOROUGHS:
			return base + float(posmod(index * 3, 4)) * PI * 0.5
		Style.RING_AND_SPOKE:
			return base + float(index) * TAU / float(OUTER_TIERS.size())
		Style.ORGANIC_BRANCHES:
			return previous + rng.randf_range(-0.72, 0.72)
		Style.PARK_COURTYARDS:
			return base + float(posmod(index * 5, 8)) * PI * 0.25
		_:
			return base + (0.0 if (index & 1) == 0 else PI) \
				+ rng.randf_range(-0.24, 0.24)


func _shape_for_style() -> int:
	match style:
		Style.RING_AND_SPOKE:
			return Shape.ELLIPSE
		Style.ORGANIC_BRANCHES:
			return Shape.BRANCH
		Style.PARK_COURTYARDS:
			return Shape.COURTYARD
		Style.TERRACES:
			return Shape.TERRACE
		_:
			return Shape.RECTANGLE


func _district_half_size(tier: int, index: int) -> Vector2i:
	var longitudinal := 14 + tier * 2
	var lateral := 11 + tier * 2
	if style == Style.PARK_COURTYARDS:
		longitudinal += 2
		lateral += 2
	elif style == Style.TERRACES:
		longitudinal += 5
		lateral = maxi(lateral - 2, 8)
	elif style == Style.ORGANIC_BRANCHES:
		longitudinal += posmod(index, 3)
	return Vector2i(longitudinal, lateral)


func _district_required_reach(centre: Vector2i, half: Vector2i,
		orientation: int) -> float:
	var furthest := 0.0
	for corner in [
			Vector2i(-half.x, -half.y), Vector2i(half.x, -half.y),
			Vector2i(-half.x, half.y), Vector2i(half.x, half.y),
		]:
		furthest = maxf(furthest,
			_grid.centre_of(centre + _orient(corner, orientation)).length())
	return minf(furthest + _grid.cell_size * 2.0, _max_radius)


func _district_parent(cell: Vector2i) -> int:
	var best := 0
	var best_distance := INF
	for district in district_count():
		var away := _district_cell(district).distance_squared_to(cell)
		if away < best_distance:
			best_distance = away
			best = district
	return best


func _nearest_plan_cell(wanted: Vector2i, radius: int, tier := 0) -> Vector2i:
	var best := wanted
	var best_score := INF
	var district_kind := MeepStructures.residential_kind_for_tier(tier)
	var district_plan := MeepStructures.plan_of(district_kind)
	var sample_radius := clampi(ceili(float(maxi(
		district_plan.span.x, district_plan.span.y)) * 0.5), 2, 8)
	var sample_offsets := PackedInt32Array([-sample_radius, 0, sample_radius])
	var origin_height := _grid.heights[_grid.index(_grid.cell_of(Vector2.ZERO))]
	# A two-cell coarse pass finds the useful terrain patch over the complete
	# search radius; a tiny local pass restores single-cell precision without
	# surveying all 1,369 possible centres for every district.
	for y in range(-radius, radius + 1, 2):
		for x in range(-radius, radius + 1, 2):
			var cell := wanted + Vector2i(x, y)
			var score := _plan_cell_score(
				cell, wanted, district_plan, sample_offsets, origin_height)
			if score < best_score:
				best_score = score
				best = cell
	var coarse_best := best
	for y in range(-2, 3):
		for x in range(-2, 3):
			var cell := coarse_best + Vector2i(x, y)
			var score := _plan_cell_score(
				cell, wanted, district_plan, sample_offsets, origin_height)
			if score < best_score:
				best_score = score
				best = cell
	return best


func _plan_cell_score(cell: Vector2i, wanted: Vector2i,
		district_plan: MeepStructures.Plan, sample_offsets: PackedInt32Array,
		origin_height: float) -> float:
	if not _grid.inside(cell):
		return INF
	var cell_index := _grid.index(cell)
	if _grid.terrain[cell_index] != MeepGrid.Terrain.PASSABLE:
		return INF
	var local := _grid.centre_of(cell)
	if local.length_squared() > (_max_radius - 8.0) * (_max_radius - 8.0):
		return INF
	var delta := cell - wanted
	var score := float(delta.length_squared())
	score += absf(_grid.heights[cell_index] - origin_height) * 0.1
	var flat_samples := 0
	var centre_height := _grid.heights[cell_index]
	for sample_y in sample_offsets:
		for sample_x in sample_offsets:
			var sample := cell + Vector2i(sample_x, sample_y)
			if not _grid.inside(sample):
				continue
			var sample_index := _grid.index(sample)
			if _grid.terrain[sample_index] == MeepGrid.Terrain.PASSABLE \
					and absf(_grid.heights[sample_index] - centre_height) \
						<= district_plan.level_tolerance:
				flat_samples += 1
	return score - float(flat_samples) * 31.5


func _orient(value: Vector2i, quarter_turns: int) -> Vector2i:
	match posmod(quarter_turns, 4):
		1:
			return Vector2i(-value.y, value.x)
		2:
			return -value
		3:
			return Vector2i(value.y, -value.x)
		_:
			return value


func _unorient(value: Vector2i, quarter_turns: int) -> Vector2i:
	return _orient(value, 4 - posmod(quarter_turns, 4))


func _line_cells(from: Vector2i, to: Vector2i) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x0 := from.x
	var y0 := from.y
	var x1 := to.x
	var y1 := to.y
	var dx := absi(x1 - x0)
	var sx := 1 if x0 < x1 else -1
	var dy := -absi(y1 - y0)
	var sy := 1 if y0 < y1 else -1
	var error := dx + dy
	for _step in _grid.cells * 2:
		var cell := Vector2i(x0, y0)
		if _grid.inside(cell):
			out.push_back(_grid.index(cell))
		if x0 == x1 and y0 == y1:
			break
		var twice := error * 2
		if twice >= dy:
			error += dy
			x0 += sx
		if twice <= dx:
			error += dx
			y0 += sy
	return out


func _oriented_line(centre: Vector2i, from: Vector2i, to: Vector2i,
		orientation: int) -> PackedInt32Array:
	return _line_cells(centre + _orient(from, orientation),
		centre + _orient(to, orientation))


func _bent_line(centre: Vector2i, half_x: int, half_y: int,
		orientation: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var points := [
		Vector2i(-half_x, -half_y / 3),
		Vector2i(-half_x / 3, half_y / 4),
		Vector2i(half_x / 3, -half_y / 4),
		Vector2i(half_x, half_y / 3),
	]
	for index in points.size() - 1:
		var segment := _oriented_line(centre, points[index],
			points[index + 1], orientation)
		for slot in segment.size():
			if out.is_empty() or slot > 0:
				out.push_back(segment[slot])
	return out


func _rectangle_sides(centre: Vector2i, half: Vector2i,
		orientation: int) -> Array[PackedInt32Array]:
	var corners := [
		Vector2i(-half.x, -half.y), Vector2i(half.x, -half.y),
		Vector2i(half.x, half.y), Vector2i(-half.x, half.y),
	]
	var out: Array[PackedInt32Array] = []
	for index in 4:
		out.push_back(_oriented_line(centre, corners[index],
			corners[(index + 1) % 4], orientation))
	return out
