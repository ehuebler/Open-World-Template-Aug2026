extends Node

## Focused deterministic checks for the pure regional ownership solver.
##
##     godot --headless --path . dev/_meep_region_plan_test.tscn

const RegionPlan = preload("res://game/meeps/meep_region_plan.gd")

var _failures := 0


func _ready() -> void:
	_check_two_cities_and_public_api()
	_check_three_and_four_cities()
	_check_determinism_and_round_trip()
	_check_weighted_seam_shift()
	_check_blueprint_population_repartition()
	_check_immutable_anchors()
	_check_setback_gap()
	_check_rle()
	print("meep_region_plan_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_two_cities_and_public_api() -> void:
	var size := Vector2i(40, 20)
	var cities := [
		_city("zeta", size, Vector2i(34, 10), 1.0, 92),
		_city("alpha", size, Vector2i(5, 10), 1.0, 17),
	]
	var plan := RegionPlan.new()
	_expect(plan.solve(Vector2.ZERO, size, _flat_terrain(size), cities,
		8.0, 6.0, 12), "two-city regional solve succeeds")
	_expect(plan.site_ids() == PackedStringArray(["alpha", "zeta"])
		and plan.cluster_members() == plan.site_ids()
		and plan.same_cluster(&"alpha", &"zeta")
		and plan.region_revision() == 1
		and plan.terrain_revision() == 12,
		"site IDs and cluster membership are stable and sorted")
	_expect(plan.owner_of_cell(Vector2i(5, 10)) == &"alpha"
		and plan.owner_of_cell(Vector2i(34, 10)) == &"zeta",
		"city centres retain their site owners")
	var tally := _owner_tally(plan)
	_expect(int(tally.get(0, 0)) > 0 and int(tally.get(1, 0)) > 0
		and int(tally.get(RegionPlan.OWNER_NEUTRAL, 0)) > 0,
		"both owners and a neutral shared seam are represented")
	var key := RegionPlan.pair_key(&"zeta", &"alpha")
	var spans := plan.seam_spans_for_pair(key)
	var gates := plan.gate_gaps_for_pair("alpha", "zeta")
	_expect(plan.seam_pair_keys() == PackedStringArray([key])
		and spans.size() >= RegionPlan.SPAN_STRIDE
		and spans.size() % RegionPlan.SPAN_STRIDE == 0
		and gates.size() >= RegionPlan.SPAN_STRIDE
		and gates.size() % RegionPlan.SPAN_STRIDE == 0
		and not plan.seam_records().is_empty(),
		"pair-keyed seam spans expose deterministic gate gaps")
	var inputs := plan.forecast_inputs()
	_expect(inputs.size() == 2
		and String(inputs[0].get("site", "")) == "alpha"
		and absf(float(inputs[0].get("forecast_rate", 0.0)) - 1.0) < 0.001,
		"sorted forecast inputs remain available to replan policy")
	_assert_no_overlap(plan, "two-city owner masks never overlap")


func _check_three_and_four_cities() -> void:
	var three_size := Vector2i(42, 30)
	var three := RegionPlan.new()
	_expect(three.solve(Vector2.ZERO, three_size, _flat_terrain(three_size), [
		_city("south", three_size, Vector2i(21, 25), 1.0, 3),
		_city("east", three_size, Vector2i(36, 5), 1.0, 2),
		_city("west", three_size, Vector2i(5, 5), 1.0, 1),
	]), "three-city regional solve succeeds")
	var three_tally := _owner_tally(three)
	_expect(three.site_ids().size() == 3
		and int(three_tally.get(0, 0)) > 0
		and int(three_tally.get(1, 0)) > 0
		and int(three_tally.get(2, 0)) > 0
		and three.seam_pair_keys().size() >= 2,
		"three cities receive territory and shared pair seams")
	_assert_no_overlap(three, "three-city owner masks never overlap")

	var four_size := Vector2i(40, 40)
	var four := RegionPlan.new()
	_expect(four.solve(Vector2.ZERO, four_size, _flat_terrain(four_size), [
		_city("delta", four_size, Vector2i(33, 33), 1.0, 44),
		_city("bravo", four_size, Vector2i(33, 6), 1.0, 22),
		_city("charlie", four_size, Vector2i(6, 33), 1.0, 33),
		_city("alpha", four_size, Vector2i(6, 6), 1.0, 11),
	]), "four-city regional solve succeeds")
	var four_tally := _owner_tally(four)
	var every_city_owns := four.site_ids().size() == 4
	for owner in 4:
		every_city_owns = every_city_owns \
			and int(four_tally.get(owner, 0)) > 0
	_expect(every_city_owns and four.seam_pair_keys().size() >= 4,
		"four-city partition keeps every cluster member represented")
	_assert_no_overlap(four, "four-city owner masks never overlap")


func _check_determinism_and_round_trip() -> void:
	var size := Vector2i(48, 22)
	var cities := [
		_city("beta", size, Vector2i(41, 11), 1.2, 907),
		_city("alpha", size, Vector2i(6, 11), 1.2, 401),
	]
	var first := RegionPlan.new()
	var second := RegionPlan.new()
	_expect(first.solve(Vector2(-10.0, -4.0), size,
		_flat_terrain(size), cities, 8.0, 8.0, 6),
		"first deterministic fixture solves")
	cities.reverse()
	_expect(second.solve(Vector2(-10.0, -4.0), size,
		_flat_terrain(size), cities, 8.0, 8.0, 6),
		"reordered deterministic fixture solves")
	var first_state := first.snapshot()
	var second_state := second.snapshot()
	_expect(first.owner_map() == second.owner_map()
		and first_state.get("owner_rle") == second_state.get("owner_rle")
		and first.seam_spans() == second.seam_spans()
		and first.gate_gaps() == second.gate_gaps(),
		"input order cannot change owners, seams, or gates")
	var restored := RegionPlan.new()
	_expect(restored.apply_snapshot(first_state)
		and restored.snapshot() == first_state
		and restored.owner_map() == first.owner_map()
		and restored.region_revision() == first.region_revision(),
		"versioned snapshot restores a byte-exact regional plan")
	var before_bad := restored.snapshot()
	var bad := first_state.duplicate(true)
	bad["version"] = RegionPlan.VERSION + 1
	_expect(not restored.apply_snapshot(bad)
		and restored.snapshot() == before_bad
		and not restored.last_error().is_empty(),
		"invalid snapshots fail atomically without replacing live state")


func _check_weighted_seam_shift() -> void:
	var size := Vector2i(64, 18)
	var balanced := RegionPlan.new()
	var weighted := RegionPlan.new()
	var balanced_cities := [
		_city("fast", size, Vector2i(6, 9), 1.0, 100),
		_city("slow", size, Vector2i(57, 9), 1.0, 200),
	]
	_expect(balanced.solve(Vector2.ZERO, size,
		_flat_terrain(size), balanced_cities),
		"balanced forecast fixture solves")
	var weighted_cities := balanced_cities.duplicate(true)
	(weighted_cities[0] as Dictionary)["forecast_rate"] = 2.5
	_expect(weighted.solve(Vector2.ZERO, size,
		_flat_terrain(size), weighted_cities),
		"weighted forecast fixture solves")
	var fast_index := weighted.site_index("fast")
	var slow_index := weighted.site_index("slow")
	var balanced_fast := _owner_count(balanced, balanced.site_index("fast"))
	var weighted_fast := _owner_count(weighted, fast_index)
	var weighted_slow := _owner_count(weighted, slow_index)
	var key := RegionPlan.pair_key("fast", "slow")
	var balanced_fixed := _longest_vertical_fixed(
		balanced.seam_spans_for_pair(key))
	var weighted_fixed := _longest_vertical_fixed(
		weighted.seam_spans_for_pair(key))
	_expect(weighted_fast > balanced_fast and weighted_fast > weighted_slow
		and weighted_fixed > balanced_fixed,
		"a faster forecast claims more unbuilt cells and shifts the seam")


func _check_blueprint_population_repartition() -> void:
	var size := Vector2i(78, 26)
	var real := _city("real", size, Vector2i(8, 13), 1.0, 10,
		PackedInt32Array([_index(Vector2i(12, 13), size)]))
	var facts := [
		real,
		_city("blueprint_a", size, Vector2i(38, 7), 1.0, 20),
		_city("blueprint_b", size, Vector2i(68, 19), 1.0, 30),
	]
	var production_fact := real.duplicate(true)
	var before := RegionPlan.new()
	var after := RegionPlan.new()
	_expect(before.solve(Vector2.ZERO, size,
		_flat_terrain(size), facts),
		"real and local blueprint facts share one private regional solve")
	var changed := facts.duplicate(true)
	(changed[1] as Dictionary)["forecast_rate"] = 3.5
	_expect(after.solve(Vector2.ZERO, size,
		_flat_terrain(size), changed),
		"dummy population growth can trigger a private blueprint replan")
	var before_a := _owner_count(
		before, before.site_index("blueprint_a"))
	var after_a := _owner_count(
		after, after.site_index("blueprint_a"))
	var before_b := before.owner_mask("blueprint_b")
	var after_b := after.owner_mask("blueprint_b")
	_expect(after_a > before_a and before_b != after_b
		and real == production_fact
		and after.owner_of_cell(Vector2i(12, 13)) == &"real",
		"one blueprint's population shifts both previews without mutating real facts or anchors")
	_assert_no_overlap(after,
		"recalculated real-plus-blueprint owner masks remain disjoint")


func _check_immutable_anchors() -> void:
	var size := Vector2i(54, 18)
	var protected_at := _index(Vector2i(20, 9), size)
	var plan := RegionPlan.new()
	_expect(plan.solve(Vector2.ZERO, size, _flat_terrain(size), [
		_city("rapid", size, Vector2i(5, 9), 4.0, 71),
		_city("steady", size, Vector2i(48, 9), 1.0, 72,
			PackedInt32Array([protected_at])),
	]), "protected-anchor fixture solves")
	_expect(plan.owner_index_of_cell(Vector2i(20, 9))
		== plan.site_index("steady")
		and (plan.forecast_input("steady").get(
			"protected_cells", PackedInt32Array()) as PackedInt32Array) \
				== PackedInt32Array([protected_at]),
		"developed protected cells cannot be reassigned or neutralized")
	var revision_before := plan.region_revision()
	var conflicting := [
		_city("rapid", size, Vector2i(5, 9), 4.0, 71,
			PackedInt32Array([protected_at])),
		_city("steady", size, Vector2i(48, 9), 1.0, 72,
			PackedInt32Array([protected_at])),
	]
	_expect(not plan.solve(Vector2.ZERO, size, _flat_terrain(size), conflicting)
		and plan.region_revision() == revision_before
		and plan.owner_index_of_cell(Vector2i(20, 9))
			== plan.site_index("steady"),
		"conflicting immutable anchors reject the replan atomically")


func _check_setback_gap() -> void:
	var size := Vector2i(60, 20)
	var plan := RegionPlan.new()
	_expect(plan.solve(Vector2.ZERO, size, _flat_terrain(size), [
		_city("left", size, Vector2i(5, 10), 1.0, 31),
		_city("right", size, Vector2i(54, 10), 1.0, 32),
	], 8.0, 6.0), "setback fixture solves")
	var key := RegionPlan.pair_key("left", "right")
	var spans := plan.seam_spans_for_pair(key)
	var span_offset := _longest_vertical_offset(spans)
	var fixed := spans[span_offset + RegionPlan.SPAN_FIXED] \
		if span_offset >= 0 else -100
	var sample_y := (spans[span_offset + RegionPlan.SPAN_START]
		+ spans[span_offset + RegionPlan.SPAN_END]) / 2 \
		if span_offset >= 0 else 0
	var left_setback := plan.setback_mask("left")
	var right_setback := plan.setback_mask("right")
	var left_buildable := plan.buildable_mask("left")
	var right_buildable := plan.buildable_mask("right")
	var checked := 0
	for x in size.x:
		var owner := plan.owner_index_of_cell(Vector2i(x, sample_y))
		if owner < 0 or absf(float(x) + 0.5 - float(fixed)) >= 4.0:
			continue
		var at := _index(Vector2i(x, sample_y), size)
		if owner == plan.site_index("left"):
			checked += 1
			_expect(left_setback[at] == 1 and left_buildable[at] == 0,
				"left owner leaves the full wall setback")
		elif owner == plan.site_index("right"):
			checked += 1
			_expect(right_setback[at] == 1 and right_buildable[at] == 0,
				"right owner leaves the full wall setback")
	var projected := plan.local_masks(
		"left", Vector2.ZERO, size, Transform2D.IDENTITY)
	_expect(checked >= 4
		and projected.get("owner") == plan.owner_mask("left")
		and projected.get("setback") == left_setback
		and projected.get("buildable") == left_buildable,
		"two-metre local projection preserves owner and 8 m setback masks")
	var gates := plan.gate_gaps_for_pair(key)
	var deterministic_gap := gates.size() >= RegionPlan.SPAN_STRIDE
	for offset in range(0, gates.size(), RegionPlan.SPAN_STRIDE):
		deterministic_gap = deterministic_gap \
			and gates[offset + RegionPlan.SPAN_END] \
				> gates[offset + RegionPlan.SPAN_START]
	_expect(deterministic_gap,
		"shared wall seam contains stable non-empty gate gaps")


func _check_rle() -> void:
	var raw := PackedInt32Array([
		RegionPlan.OWNER_UNREACHABLE, RegionPlan.OWNER_UNREACHABLE,
		0, 0, 0, RegionPlan.OWNER_NEUTRAL, 1, 1, 1, 1,
	])
	var encoded := RegionPlan.encode_owner_rle(raw)
	_expect(encoded == PackedInt32Array([
		RegionPlan.OWNER_UNREACHABLE, 2, 0, 3,
		RegionPlan.OWNER_NEUTRAL, 1, 1, 4,
	]) and RegionPlan.decode_owner_rle(encoded, raw.size()) == raw,
		"owner-map RLE preserves signed owner and seam values")
	_expect(RegionPlan.decode_owner_rle(
		PackedInt32Array([0, 11]), raw.size()).is_empty()
		and RegionPlan.decode_owner_rle(
			PackedInt32Array([0, 2, 1]), raw.size()).is_empty(),
		"owner-map RLE rejects bad run totals and odd records")
	var size := Vector2i(50, 16)
	var plan := RegionPlan.new()
	plan.solve(Vector2.ZERO, size, _flat_terrain(size), [
		_city("a", size, Vector2i(4, 8), 1.0, 1),
		_city("b", size, Vector2i(45, 8), 1.0, 2),
	])
	var state := plan.snapshot()
	var rle := state.get("owner_rle", PackedInt32Array()) as PackedInt32Array
	_expect(not state.has("owner_map")
		and rle.size() < plan.owner_map().size()
		and RegionPlan.decode_owner_rle(
			rle, plan.cell_count()) == plan.owner_map(),
		"snapshots persist a compact RLE owner map instead of raw cells")


func _city(site: String, _size: Vector2i, cell: Vector2i,
		rate: float, seed: int,
		protected := PackedInt32Array()) -> Dictionary:
	return {
		"site": site,
		"local_centre": _cell_centre(cell),
		"forecast_rate": rate,
		"seed": seed,
		"protected_cells": protected,
	}


func _flat_terrain(size: Vector2i) -> PackedByteArray:
	var terrain := PackedByteArray()
	terrain.resize(size.x * size.y)
	terrain.fill(1)
	return terrain


func _cell_centre(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * RegionPlan.CELL_SIZE


func _index(cell: Vector2i, size: Vector2i) -> int:
	return cell.y * size.x + cell.x


func _owner_tally(plan: RegionPlan) -> Dictionary:
	var tally: Dictionary = {}
	for owner in plan.owner_map():
		tally[owner] = int(tally.get(owner, 0)) + 1
	return tally


func _owner_count(plan: RegionPlan, wanted: int) -> int:
	var found := 0
	for owner in plan.owner_map():
		if owner == wanted:
			found += 1
	return found


func _assert_no_overlap(plan: RegionPlan, message: String) -> void:
	var masks: Array[PackedByteArray] = []
	for site in plan.site_ids():
		masks.push_back(plan.owner_mask(site))
	var valid := true
	var owners := plan.owner_map()
	for at in owners.size():
		var memberships := 0
		for mask in masks:
			memberships += int(mask[at])
		if memberships > 1 or (owners[at] >= 0 and memberships != 1) \
				or (owners[at] < 0 and memberships != 0):
			valid = false
			break
	_expect(valid, message)


func _longest_vertical_fixed(spans: PackedInt32Array) -> int:
	var offset := _longest_vertical_offset(spans)
	return spans[offset + RegionPlan.SPAN_FIXED] if offset >= 0 else -1


func _longest_vertical_offset(spans: PackedInt32Array) -> int:
	var best := -1
	var best_length := -1
	for offset in range(0, spans.size(), RegionPlan.SPAN_STRIDE):
		if spans[offset + RegionPlan.SPAN_ORIENTATION] != RegionPlan.VERTICAL:
			continue
		var length := spans[offset + RegionPlan.SPAN_END] \
			- spans[offset + RegionPlan.SPAN_START]
		if length > best_length:
			best_length = length
			best = offset
	return best


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("meep_region_plan_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("meep_region_plan_test: FAIL  %s" % message)
