class_name MeepBorderWalls
extends Node3D

## Registry-level state and presentation for infrastructure shared by two cities.
##
## Region planning owns seam geometry and deterministic gate placement. This class
## owns only the resulting build contract: one canonical record, one reservation,
## one payer, one active builder, and one globally visible completion. Simulation
## methods do not need a planet, terrain, scene tree, or either resident colony.
##
## Gate gaps are normalized [from, to] fractions along the endpoint order supplied
## to [method define_segment]. Endpoints and city names are canonicalized before the
## record is keyed, so either city and either endpoint order address the same wall.

signal segment_reserved(segment_id: String, reserved_by: StringName,
	builder: StringName, reservation_id: int, charge_amount: float)
signal segment_progressed(segment_id: String, reservation_id: int,
	progress: float, work_required: float)
signal segment_completed(segment_id: String, completed_by: StringName,
	reservation_id: int)
signal segment_cancelled(segment_id: String, cancelled_by: StringName,
	reservation_id: int, refund_amount: float)

enum SegmentState {
	OPEN,
	RESERVED,
	COMPLETE,
}

const VERSION := 1
const RECORD_VERSION := 1
## A centimetre absorbs harmless transform noise while keeping neighbouring 2 m
## regional-grid vertices distinct.
const ENDPOINT_QUANTUM := 0.01
const DEFAULT_COST := 40.0
const DEFAULT_WORK := 24.0
const WALL_HEIGHT := 2.4
const WALL_THICKNESS := 0.55
const EPSILON := 0.000001

@export var presentation_enabled := true
@export var collision_enabled := true
@export var collision_layer := 1
@export var collision_mask := 1
@export var wall_height := WALL_HEIGHT
@export var wall_thickness := WALL_THICKNESS
@export var wall_color := Color(0.32, 0.16, 0.47)

var _segments: Dictionary = {}
var _revision := 0
var _next_reservation_id := 1

var _instances: MultiMeshInstance3D
var _body: StaticBody3D
var _mesh: BoxMesh
var _material: StandardMaterial3D


func _init() -> void:
	name = "MeepBorderWalls"
	_ensure_presentation_nodes()


## Creates or refreshes one region-authored seam span.
##
## Existing construction state is retained. A completed span is immutable, while a
## reserved span refuses contract changes so its payer cannot be charged under one
## price and complete another shape. Open spans accept a newer regional revision.
func define_segment(city_a: StringName, city_b: StringName,
		endpoint_a: Vector3, endpoint_b: Vector3,
		gate_gaps: PackedVector2Array = PackedVector2Array(),
		cost := DEFAULT_COST, work_required := DEFAULT_WORK,
		region_revision := 0, up_hint := Vector3.UP,
		region_id: StringName = &"") -> Dictionary:
	var validation := _validated_definition(
		city_a, city_b, endpoint_a, endpoint_b, gate_gaps,
		cost, work_required, region_revision, up_hint, region_id)
	if not bool(validation.get("ok", false)):
		return validation
	var segment_id := String(validation["segment_id"])
	var existing := _record(segment_id)
	if not existing.is_empty():
		var saved_plan_revision := int(existing.get("plan_revision", 0))
		if region_revision < saved_plan_revision:
			return _result(false, &"stale_plan", segment_id, existing)
		var changed := not _definition_matches(existing, validation)
		if int(existing.get("state", SegmentState.OPEN)) == SegmentState.COMPLETE:
			return _result(not changed, &"already_defined" if not changed
				else &"immutable_complete", segment_id, existing)
		if int(existing.get("state", SegmentState.OPEN)) == SegmentState.RESERVED \
				and changed:
			return _result(false, &"reserved_contract", segment_id, existing)
		if changed or region_revision != saved_plan_revision:
			existing["gates"] = (
				validation["gates"] as PackedVector2Array).duplicate()
			existing["cost"] = float(validation["cost"])
			existing["work_required"] = float(validation["work_required"])
			existing["up"] = validation["up"]
			existing["region_id"] = String(validation["region_id"])
			existing["plan_revision"] = region_revision
			_touch(existing)
			_rebuild_presentation()
			return _result(true, &"updated", segment_id, existing)
		return _result(true, &"already_defined", segment_id, existing)

	var record := {
		"version": RECORD_VERSION,
		"id": segment_id,
		"cities": (validation["cities"] as PackedStringArray).duplicate(),
		"from_q": validation["from_q"],
		"to_q": validation["to_q"],
		"anchor_from_q": validation["from_q"],
		"anchor_to_q": validation["to_q"],
		"up": validation["up"],
		"gates": (validation["gates"] as PackedVector2Array).duplicate(),
		"cost": float(validation["cost"]),
		"work_required": float(validation["work_required"]),
		"progress": 0.0,
		"state": SegmentState.OPEN,
		"reached": PackedByteArray([0, 0]),
		"reserved_by": "",
		"active_builder": "",
		"reservation_id": 0,
		"paid_by": "",
		"paid_cost": 0.0,
		"last_cancelled_reservation": 0,
		"completed_reservation": 0,
		"completed_by": "",
		"completed_builder": "",
		"region_id": String(validation["region_id"]),
		"plan_revision": region_revision,
		"revision": 1,
	}
	_segments[segment_id] = record
	_revision += 1
	return _result(true, &"created", segment_id, record)


## Reprojects a planned seam after a terrain bake without reopening its one
## payment/progress contract. This is also how unfinished spans follow a bounded
## regional replan while completed infrastructure simply settles onto new ground.
func resettle_segment(segment_id: String, endpoint_a: Vector3,
		endpoint_b: Vector3, gate_gaps: PackedVector2Array,
		region_revision: int, up_hint := Vector3.UP) -> Dictionary:
	var record := _record(segment_id)
	if record.is_empty():
		return _result(false, &"missing", segment_id)
	var cities: PackedStringArray = record.get(
		"cities", PackedStringArray())
	if cities.size() < 2:
		return _result(false, &"invalid_record", segment_id, record)
	var validation := _validated_definition(
		StringName(cities[0]), StringName(cities[1]),
		endpoint_a, endpoint_b, gate_gaps,
		float(record.get("cost", DEFAULT_COST)),
		float(record.get("work_required", DEFAULT_WORK)),
		region_revision, up_hint,
		StringName(record.get("region_id", "")))
	if not bool(validation.get("ok", false)):
		return validation
	if validation.get("cities", PackedStringArray()) != cities:
		return _result(false, &"city_mismatch", segment_id, record)
	record["from_q"] = validation["from_q"]
	record["to_q"] = validation["to_q"]
	record["up"] = validation["up"]
	record["gates"] = (
		validation["gates"] as PackedVector2Array).duplicate()
	record["plan_revision"] = region_revision
	_touch(record)
	_rebuild_presentation()
	return _result(true, &"resettled", segment_id, record)


## Marks whether one city's physical claim has reached this planned seam.
## Eligibility is shared: once either byte is set, either member city may reserve.
func set_city_reached(segment_id: String, city: StringName,
		reached := true) -> Dictionary:
	var record := _record(segment_id)
	if record.is_empty():
		return _result(false, &"missing", segment_id)
	var city_index := _city_index(record, city)
	if city_index < 0:
		return _result(false, &"not_member", segment_id, record)
	var reached_state: PackedByteArray = record.get(
		"reached", PackedByteArray([0, 0]))
	while reached_state.size() < 2:
		reached_state.push_back(0)
	var wanted := 1 if reached else 0
	if reached_state[city_index] == wanted:
		var unchanged := _result(true, &"unchanged", segment_id, record)
		unchanged["eligible"] = _eligible_record(record)
		return unchanged
	reached_state[city_index] = wanted
	record["reached"] = reached_state
	_touch(record)
	var result := _result(true, &"reached" if reached else &"unreached",
		segment_id, record)
	result["eligible"] = _eligible_record(record)
	return result


func is_eligible(segment_id: String) -> bool:
	var record := _record(segment_id)
	return not record.is_empty() and _eligible_record(record)


## Atomically checks eligibility/member/funds and claims the single open contract.
##
## The manager does not own city banks. The first successful result exposes the
## exact debit as `charge_city`, `charge_amount`, and `payment_contract`; all retries
## return zero. Passing the caller's available bank makes insufficient-funds refusal
## part of the same check-and-set operation.
func reserve_segment(segment_id: String, city: StringName,
		builder: StringName, available_funds := INF) -> Dictionary:
	var record := _record(segment_id)
	if record.is_empty():
		return _reserve_result(false, &"missing", segment_id)
	if _city_index(record, city) < 0:
		return _reserve_result(false, &"not_member", segment_id, record)
	var city_text := String(city)
	var builder_text := String(builder)
	if builder_text.is_empty():
		return _reserve_result(false, &"missing_builder", segment_id, record)
	var state := int(record.get("state", SegmentState.OPEN))
	if state == SegmentState.COMPLETE:
		return _reserve_result(false, &"complete", segment_id, record)
	if state == SegmentState.RESERVED:
		var same_contract := String(record.get("reserved_by", "")) == city_text \
			and String(record.get("active_builder", "")) == builder_text
		return _reserve_result(same_contract,
			&"already_reserved" if same_contract else &"reserved",
			segment_id, record)
	if not _eligible_record(record):
		return _reserve_result(false, &"not_eligible", segment_id, record)
	var price := float(record.get("cost", 0.0))
	if is_nan(available_funds) or available_funds < price:
		var insufficient := _reserve_result(
			false, &"insufficient_funds", segment_id, record)
		insufficient["required_cost"] = price
		return insufficient

	var reservation_id := _next_reservation_id
	_next_reservation_id += 1
	record["state"] = SegmentState.RESERVED
	record["reserved_by"] = city_text
	record["active_builder"] = builder_text
	record["reservation_id"] = reservation_id
	record["paid_by"] = city_text
	record["paid_cost"] = price
	record["progress"] = 0.0
	_touch(record)
	var result := _reserve_result(true, &"reserved", segment_id, record)
	result["charge_city"] = city_text
	result["charge_amount"] = price
	result["first_builder_pays"] = true
	result["payment_contract"] = {
		"kind": &"debit",
		"city": city_text,
		"amount": price,
		"segment_id": segment_id,
		"reservation_id": reservation_id,
	}
	segment_reserved.emit(
		segment_id, StringName(city_text), StringName(builder_text),
		reservation_id, price)
	return result


## Transfers the active task inside the paying city without creating a second job.
func set_active_builder(segment_id: String, city: StringName,
		reservation_id: int, builder: StringName) -> Dictionary:
	var checked := _reserved_contract(
		segment_id, city, reservation_id, &"", false)
	if not bool(checked.get("ok", false)):
		return checked
	var record := _record(segment_id)
	var builder_text := String(builder)
	if builder_text.is_empty():
		return _result(false, &"missing_builder", segment_id, record)
	if String(record.get("active_builder", "")) == builder_text:
		return _result(true, &"unchanged", segment_id, record)
	record["active_builder"] = builder_text
	_touch(record)
	return _result(true, &"builder_changed", segment_id, record)


## Sets absolute completed work for this reservation.
##
## Absolute, monotonic reporting makes reliable-RPC retries idempotent: submitting
## the same total twice applies zero work the second time. Completion is explicit so
## the caller can synchronize its final task transition with [method complete_segment].
func report_progress(segment_id: String, city: StringName,
		reservation_id: int, builder: StringName,
		total_work: float) -> Dictionary:
	var terminal := _terminal_retry(segment_id, city, reservation_id)
	if not terminal.is_empty():
		return terminal
	var checked := _reserved_contract(
		segment_id, city, reservation_id, builder, true)
	if not bool(checked.get("ok", false)):
		return checked
	var record := _record(segment_id)
	if not is_finite(total_work) or total_work < 0.0:
		return _result(false, &"invalid_progress", segment_id, record)
	var required := float(record.get("work_required", DEFAULT_WORK))
	var previous := float(record.get("progress", 0.0))
	var current := clampf(maxf(previous, total_work), 0.0, required)
	if current > previous + EPSILON:
		record["progress"] = current
		_touch(record)
		segment_progressed.emit(
			segment_id, reservation_id, current, required)
	var result := _result(true,
		&"progressed" if current > previous + EPSILON else &"unchanged",
		segment_id, record)
	result["applied_work"] = current - previous
	result["progress"] = current
	result["work_required"] = required
	result["ready_to_complete"] = current + EPSILON >= required
	return result


## Publishes completion once. Repeating the same terminal request is successful but
## reports `newly_completed == false` and emits no second signal.
func complete_segment(segment_id: String, city: StringName,
		reservation_id: int, builder: StringName) -> Dictionary:
	var terminal := _terminal_retry(segment_id, city, reservation_id)
	if not terminal.is_empty():
		if StringName(terminal.get("status", &"")) == &"already_complete":
			terminal["newly_completed"] = false
		return terminal
	var checked := _reserved_contract(
		segment_id, city, reservation_id, builder, true)
	if not bool(checked.get("ok", false)):
		return checked
	var record := _record(segment_id)
	var required := float(record.get("work_required", DEFAULT_WORK))
	if float(record.get("progress", 0.0)) + EPSILON < required:
		var waiting := _result(false, &"work_remaining", segment_id, record)
		waiting["work_remaining"] = required \
			- float(record.get("progress", 0.0))
		return waiting
	var city_text := String(city)
	var builder_text := String(builder)
	record["state"] = SegmentState.COMPLETE
	record["progress"] = required
	record["completed_reservation"] = reservation_id
	record["completed_by"] = city_text
	record["completed_builder"] = builder_text
	record["reserved_by"] = ""
	record["active_builder"] = ""
	_touch(record)
	_rebuild_presentation()
	var result := _result(true, &"completed", segment_id, record)
	result["newly_completed"] = true
	result["visible_to"] = (
		record.get("cities", PackedStringArray()) as PackedStringArray).duplicate()
	segment_completed.emit(segment_id, city, reservation_id)
	return result


## Reopens a reservation and exposes its one refund. A stale cancellation cannot
## cancel a later retry because every reservation receives a new monotonic token.
func cancel_segment(segment_id: String, city: StringName,
		reservation_id: int, builder: StringName) -> Dictionary:
	var terminal := _terminal_retry(segment_id, city, reservation_id)
	if not terminal.is_empty():
		if StringName(terminal.get("status", &"")) == &"already_cancelled":
			terminal["refund_city"] = ""
			terminal["refund_amount"] = 0.0
		return terminal
	var checked := _reserved_contract(
		segment_id, city, reservation_id, builder, true)
	if not bool(checked.get("ok", false)):
		return checked
	var record := _record(segment_id)
	var refund_city := String(record.get("paid_by", ""))
	var refund_amount := float(record.get("paid_cost", 0.0))
	record["state"] = SegmentState.OPEN
	record["progress"] = 0.0
	record["reserved_by"] = ""
	record["active_builder"] = ""
	record["paid_by"] = ""
	record["paid_cost"] = 0.0
	record["last_cancelled_reservation"] = reservation_id
	_touch(record)
	var result := _result(true, &"cancelled", segment_id, record)
	result["refund_city"] = refund_city
	result["refund_amount"] = refund_amount
	result["refund_contract"] = {
		"kind": &"credit",
		"city": refund_city,
		"amount": refund_amount,
		"segment_id": segment_id,
		"reservation_id": reservation_id,
	}
	segment_cancelled.emit(
		segment_id, city, reservation_id, refund_amount)
	return result


func has_segment(segment_id: String) -> bool:
	return _segments.has(segment_id)


func segment_count() -> int:
	return _segments.size()


func completed_segment_count() -> int:
	var count := 0
	for record_variant: Variant in _segments.values():
		var record := record_variant as Dictionary
		if int(record.get("state", SegmentState.OPEN)) == SegmentState.COMPLETE:
			count += 1
	return count


func state_of(segment_id: String) -> int:
	return int(_record(segment_id).get("state", -1))


func revision() -> int:
	return _revision


## A defensive copy suitable for UI, networking, and tests.
func segment_record(segment_id: String) -> Dictionary:
	var record := _record(segment_id)
	return record.duplicate(true) if not record.is_empty() else {}


func segments_for_city(city: StringName,
		only_completed := false) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for segment_id in _sorted_ids():
		var record := _record(segment_id)
		if _city_index(record, city) < 0:
			continue
		if only_completed and int(record.get(
				"state", SegmentState.OPEN)) != SegmentState.COMPLETE:
			continue
		found.push_back(record.duplicate(true))
	return found


## Drops superseded, unstarted future spans after an atomic regional replan.
## Paid or completed contracts remain stable until their owning registry resolves them.
func prune_open_except(valid_ids: PackedStringArray) -> void:
	var keep: Dictionary = {}
	for segment_id in valid_ids:
		keep[String(segment_id)] = true
	var removed := false
	for segment_id in _sorted_ids():
		var record := _record(segment_id)
		if keep.has(segment_id) or int(record.get(
				"state", SegmentState.OPEN)) != SegmentState.OPEN:
			continue
		_segments.erase(segment_id)
		removed = true
	if removed:
		_revision += 1
		_rebuild_presentation()


## Consecutive endpoint pairs for the completed, collidable parts of one record.
## Planned gate intervals are subtracted before anything reaches physics.
func collision_spans_for_segment(segment_id: String) -> PackedVector3Array:
	var record := _record(segment_id)
	if record.is_empty() or int(record.get(
			"state", SegmentState.OPEN)) != SegmentState.COMPLETE:
		return PackedVector3Array()
	return _solid_spans(record)


## Consecutive endpoint pairs for every completed record in stable key order.
func completed_collision_spans() -> PackedVector3Array:
	var spans := PackedVector3Array()
	for segment_id in _sorted_ids():
		var record := _record(segment_id)
		if int(record.get("state", SegmentState.OPEN)) != SegmentState.COMPLETE:
			continue
		spans.append_array(_solid_spans(record))
	return spans


func presentation_span_count() -> int:
	return _instances.multimesh.instance_count \
		if _instances != null and _instances.multimesh != null else 0


func collision_shape_count() -> int:
	return _body.get_child_count() if _body != null else 0


## Re-applies dimensions, material, collision masks, and completed state.
func refresh_presentation() -> void:
	_rebuild_presentation()


func clear() -> void:
	_segments.clear()
	_revision += 1
	_next_reservation_id = 1
	_rebuild_presentation()


## One registry snapshot; cities carry only their region link elsewhere.
func snapshot() -> Dictionary:
	var records: Array[Dictionary] = []
	for segment_id in _sorted_ids():
		records.push_back(_record(segment_id).duplicate(true))
	return {
		"version": VERSION,
		"quantization": ENDPOINT_QUANTUM,
		"revision": _revision,
		"next_reservation_id": _next_reservation_id,
		"segments": records,
	}


## Atomically restores a snapshot. Invalid or future schemas leave current state
## untouched rather than publishing a partially restored shared contract.
func apply_snapshot(state: Dictionary) -> Dictionary:
	if int(state.get("version", 0)) != VERSION:
		return {"ok": false, "status": &"unsupported_version"}
	if absf(float(state.get("quantization", ENDPOINT_QUANTUM))
			- ENDPOINT_QUANTUM) > EPSILON:
		return {"ok": false, "status": &"incompatible_quantization"}
	var records_variant: Variant = state.get("segments", [])
	if not records_variant is Array:
		return {"ok": false, "status": &"invalid_segments"}
	var restored: Dictionary = {}
	var highest_reservation := 0
	for value: Variant in records_variant:
		if not value is Dictionary:
			return {"ok": false, "status": &"invalid_record"}
		var parsed := _parse_snapshot_record(value as Dictionary)
		if not bool(parsed.get("ok", false)):
			return parsed
		var record: Dictionary = parsed["record"]
		var segment_id := String(record["id"])
		if restored.has(segment_id):
			return {
				"ok": false,
				"status": &"duplicate_record",
				"segment_id": segment_id,
			}
		restored[segment_id] = record
		highest_reservation = maxi(highest_reservation,
			int(record.get("reservation_id", 0)))
		highest_reservation = maxi(highest_reservation,
			int(record.get("last_cancelled_reservation", 0)))
		highest_reservation = maxi(highest_reservation,
			int(record.get("completed_reservation", 0)))
	var restored_next := maxi(maxi(
		int(state.get("next_reservation_id", 1)),
		highest_reservation + 1), 1)
	_segments = restored
	_revision = maxi(int(state.get("revision", 0)), 0)
	_next_reservation_id = restored_next
	_rebuild_presentation()
	return {
		"ok": true,
		"status": &"restored",
		"segments": _segments.size(),
		"completed": completed_segment_count(),
		"revision": _revision,
	}


func restore_snapshot(state: Dictionary) -> Dictionary:
	return apply_snapshot(state)


## Pure stable-key helper for region planners and compact ledgers.
static func stable_segment_id(city_a: StringName, city_b: StringName,
		endpoint_a: Vector3, endpoint_b: Vector3) -> String:
	var cities := _sorted_cities(city_a, city_b)
	if cities.size() != 2:
		return ""
	var from_q := _quantize(endpoint_a)
	var to_q := _quantize(endpoint_b)
	if _point_less(to_q, from_q):
		var swap := from_q
		from_q = to_q
		to_q = swap
	return _id_from_canonical(cities, from_q, to_q)


static func quantized_endpoint(point: Vector3) -> Vector3i:
	return _quantize(point)


func _validated_definition(city_a: StringName, city_b: StringName,
		endpoint_a: Vector3, endpoint_b: Vector3,
		gate_gaps: PackedVector2Array, cost: float, work_required: float,
		region_revision: int, up_hint: Vector3,
		region_id: StringName) -> Dictionary:
	var cities := _sorted_cities(city_a, city_b)
	if cities.size() != 2:
		return {"ok": false, "status": &"invalid_cities"}
	if not endpoint_a.is_finite() or not endpoint_b.is_finite():
		return {"ok": false, "status": &"invalid_endpoints"}
	if not is_finite(cost) or cost < 0.0 \
			or not is_finite(work_required) or work_required <= 0.0:
		return {"ok": false, "status": &"invalid_contract"}
	if region_revision < 0:
		return {"ok": false, "status": &"invalid_revision"}
	var from_q := _quantize(endpoint_a)
	var to_q := _quantize(endpoint_b)
	if from_q == to_q:
		return {"ok": false, "status": &"zero_length"}
	var reversed := _point_less(to_q, from_q)
	if reversed:
		var swap := from_q
		from_q = to_q
		to_q = swap
	var up := up_hint
	if not up.is_finite() or up.length_squared() < EPSILON:
		up = Vector3.UP
	else:
		up = up.normalized()
	var segment_id := _id_from_canonical(cities, from_q, to_q)
	return {
		"ok": true,
		"status": &"valid",
		"segment_id": segment_id,
		"cities": cities,
		"from_q": from_q,
		"to_q": to_q,
		"up": up,
		"gates": _normalise_gates(gate_gaps, reversed),
		"cost": cost,
		"work_required": work_required,
		"plan_revision": region_revision,
		"region_id": String(region_id),
	}


func _definition_matches(record: Dictionary, definition: Dictionary) -> bool:
	return record.get("gates", PackedVector2Array()) == definition["gates"] \
		and is_equal_approx(float(record.get("cost", 0.0)),
			float(definition["cost"])) \
		and is_equal_approx(float(record.get("work_required", 0.0)),
			float(definition["work_required"])) \
		and (record.get("up", Vector3.UP) as Vector3).is_equal_approx(
			definition["up"] as Vector3) \
		and String(record.get("region_id", "")) \
			== String(definition["region_id"])


func _reserved_contract(segment_id: String, city: StringName,
		reservation_id: int, builder: StringName,
		require_builder: bool) -> Dictionary:
	var record := _record(segment_id)
	if record.is_empty():
		return _result(false, &"missing", segment_id)
	if int(record.get("state", SegmentState.OPEN)) != SegmentState.RESERVED:
		return _result(false, &"not_reserved", segment_id, record)
	if int(record.get("reservation_id", 0)) != reservation_id:
		return _result(false, &"stale_reservation", segment_id, record)
	if String(record.get("reserved_by", "")) != String(city):
		return _result(false, &"not_reserver", segment_id, record)
	if require_builder and String(record.get("active_builder", "")) \
			!= String(builder):
		return _result(false, &"not_active_builder", segment_id, record)
	return _result(true, &"reserved", segment_id, record)


func _terminal_retry(segment_id: String, city: StringName,
		reservation_id: int) -> Dictionary:
	var record := _record(segment_id)
	if record.is_empty():
		return _result(false, &"missing", segment_id)
	var state := int(record.get("state", SegmentState.OPEN))
	if state == SegmentState.COMPLETE \
			and int(record.get("completed_reservation", 0)) == reservation_id \
			and String(record.get("completed_by", "")) == String(city):
		return _result(true, &"already_complete", segment_id, record)
	if state == SegmentState.OPEN \
			and int(record.get("last_cancelled_reservation", 0)) == reservation_id:
		return _result(true, &"already_cancelled", segment_id, record)
	return {}


func _parse_snapshot_record(saved: Dictionary) -> Dictionary:
	if int(saved.get("version", 0)) != RECORD_VERSION:
		return {"ok": false, "status": &"unsupported_record_version"}
	var cities := _snapshot_cities(saved.get("cities", PackedStringArray()))
	if cities.size() != 2:
		return {"ok": false, "status": &"invalid_record_cities"}
	var from_variant: Variant = saved.get("from_q")
	var to_variant: Variant = saved.get("to_q")
	if not from_variant is Vector3i or not to_variant is Vector3i:
		return {"ok": false, "status": &"invalid_record_endpoints"}
	var from_q: Vector3i = from_variant
	var to_q: Vector3i = to_variant
	if from_q == to_q or _point_less(to_q, from_q):
		return {"ok": false, "status": &"noncanonical_record"}
	var anchor_from_variant: Variant = saved.get("anchor_from_q", from_q)
	var anchor_to_variant: Variant = saved.get("anchor_to_q", to_q)
	if not anchor_from_variant is Vector3i \
			or not anchor_to_variant is Vector3i:
		return {"ok": false, "status": &"invalid_record_anchor"}
	var anchor_from_q: Vector3i = anchor_from_variant
	var anchor_to_q: Vector3i = anchor_to_variant
	if anchor_from_q == anchor_to_q \
			or _point_less(anchor_to_q, anchor_from_q):
		return {"ok": false, "status": &"noncanonical_anchor"}
	var segment_id := _id_from_canonical(
		cities, anchor_from_q, anchor_to_q)
	if String(saved.get("id", segment_id)) != segment_id:
		return {"ok": false, "status": &"id_mismatch"}
	var gates_variant: Variant = saved.get("gates", PackedVector2Array())
	if not gates_variant is PackedVector2Array:
		return {"ok": false, "status": &"invalid_record_gates"}
	var gates := _normalise_gates(gates_variant as PackedVector2Array, false)
	if gates != gates_variant:
		return {"ok": false, "status": &"noncanonical_gates"}
	var cost := float(saved.get("cost", -1.0))
	var work_required := float(saved.get("work_required", 0.0))
	var progress := float(saved.get("progress", 0.0))
	if not is_finite(cost) or cost < 0.0 \
			or not is_finite(work_required) or work_required <= 0.0 \
			or not is_finite(progress) or progress < 0.0:
		return {"ok": false, "status": &"invalid_record_contract"}
	var state := int(saved.get("state", -1))
	if state < SegmentState.OPEN or state > SegmentState.COMPLETE:
		return {"ok": false, "status": &"invalid_record_state"}
	var reached_variant: Variant = saved.get("reached", PackedByteArray())
	if not reached_variant is PackedByteArray:
		return {"ok": false, "status": &"invalid_record_reach"}
	var reached := (reached_variant as PackedByteArray).duplicate()
	if reached.size() != 2:
		return {"ok": false, "status": &"invalid_record_reach"}
	reached[0] = 1 if reached[0] != 0 else 0
	reached[1] = 1 if reached[1] != 0 else 0
	var reservation_id := maxi(int(saved.get("reservation_id", 0)), 0)
	var last_cancelled := maxi(
		int(saved.get("last_cancelled_reservation", 0)), 0)
	var completed_reservation := maxi(
		int(saved.get("completed_reservation", 0)), 0)
	var reserved_by := String(saved.get("reserved_by", ""))
	var active_builder := String(saved.get("active_builder", ""))
	var paid_by := String(saved.get("paid_by", ""))
	var paid_cost := maxf(float(saved.get("paid_cost", 0.0)), 0.0)
	var completed_by := String(saved.get("completed_by", ""))
	var completed_builder := String(saved.get("completed_builder", ""))
	if state == SegmentState.RESERVED:
		if reservation_id <= 0 or active_builder.is_empty() \
				or not _cities_contain(cities, reserved_by) \
				or paid_by != reserved_by:
			return {"ok": false, "status": &"invalid_reservation"}
		progress = minf(progress, work_required)
	elif state == SegmentState.COMPLETE:
		if completed_reservation <= 0 \
				or not _cities_contain(cities, completed_by) \
				or completed_builder.is_empty() \
				or not _cities_contain(cities, paid_by):
			return {"ok": false, "status": &"invalid_completion"}
		progress = work_required
		reserved_by = ""
		active_builder = ""
	else:
		progress = 0.0
		reserved_by = ""
		active_builder = ""
		paid_by = ""
		paid_cost = 0.0
	var up_variant: Variant = saved.get("up", Vector3.UP)
	var up := up_variant as Vector3 if up_variant is Vector3 else Vector3.UP
	if not up.is_finite() or up.length_squared() < EPSILON:
		up = Vector3.UP
	else:
		up = up.normalized()
	var record := {
		"version": RECORD_VERSION,
		"id": segment_id,
		"cities": cities,
		"from_q": from_q,
		"to_q": to_q,
		"anchor_from_q": anchor_from_q,
		"anchor_to_q": anchor_to_q,
		"up": up,
		"gates": gates,
		"cost": cost,
		"work_required": work_required,
		"progress": progress,
		"state": state,
		"reached": reached,
		"reserved_by": reserved_by,
		"active_builder": active_builder,
		"reservation_id": reservation_id,
		"paid_by": paid_by,
		"paid_cost": paid_cost,
		"last_cancelled_reservation": last_cancelled,
		"completed_reservation": completed_reservation,
		"completed_by": completed_by,
		"completed_builder": completed_builder,
		"region_id": String(saved.get("region_id", "")),
		"plan_revision": maxi(int(saved.get("plan_revision", 0)), 0),
		"revision": maxi(int(saved.get("revision", 1)), 1),
	}
	return {"ok": true, "status": &"valid", "record": record}


func _solid_spans(record: Dictionary) -> PackedVector3Array:
	var spans := PackedVector3Array()
	var from := _dequantize(record.get("from_q", Vector3i.ZERO))
	var to := _dequantize(record.get("to_q", Vector3i.ZERO))
	var gates: PackedVector2Array = record.get(
		"gates", PackedVector2Array())
	var cursor := 0.0
	for gate in gates:
		if gate.x > cursor + EPSILON:
			spans.push_back(from.lerp(to, cursor))
			spans.push_back(from.lerp(to, gate.x))
		cursor = maxf(cursor, gate.y)
	if cursor < 1.0 - EPSILON:
		spans.push_back(from.lerp(to, cursor))
		spans.push_back(to)
	return spans


func _rebuild_presentation() -> void:
	_ensure_presentation_nodes()
	var spans := completed_collision_spans()
	var span_records: Array[Dictionary] = []
	for segment_id in _sorted_ids():
		var record := _record(segment_id)
		if int(record.get("state", SegmentState.OPEN)) != SegmentState.COMPLETE:
			continue
		var record_spans := _solid_spans(record)
		for index in record_spans.size() / 2:
			span_records.push_back({
				"from": record_spans[index * 2],
				"to": record_spans[index * 2 + 1],
				"up": record.get("up", Vector3.UP),
			})
	# The aggregate is also the collision API's source; retaining this assertion in
	# debug builds catches presentation accidentally reintroducing a gate span.
	assert(spans.size() / 2 == span_records.size())

	_ensure_mesh()
	var multimesh := _instances.multimesh
	multimesh.instance_count = span_records.size() if presentation_enabled else 0
	multimesh.visible_instance_count = multimesh.instance_count
	for index in multimesh.instance_count:
		var entry := span_records[index]
		multimesh.set_instance_transform(index, _visual_transform(
			entry["from"], entry["to"], entry["up"]))
	_instances.visible = presentation_enabled and multimesh.instance_count > 0

	for child in _body.get_children():
		_body.remove_child(child)
		child.free()
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	if not collision_enabled:
		return
	for index in span_records.size():
		var entry := span_records[index]
		var from: Vector3 = entry["from"]
		var to: Vector3 = entry["to"]
		var length := from.distance_to(to)
		if length <= EPSILON:
			continue
		var axes := _span_axes(from, to, entry["up"])
		var shape := BoxShape3D.new()
		shape.size = Vector3(length, maxf(wall_height, EPSILON),
			maxf(wall_thickness, EPSILON))
		var collision := CollisionShape3D.new()
		collision.name = "WallSpan_%d" % index
		collision.shape = shape
		collision.transform = Transform3D(axes,
			(from + to) * 0.5 + axes.y * wall_height * 0.5)
		_body.add_child(collision)


func _ensure_presentation_nodes() -> void:
	if _instances == null:
		_instances = MultiMeshInstance3D.new()
		_instances.name = "WallInstances"
		_instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_instances)
	if _instances.multimesh == null:
		_instances.multimesh = MultiMesh.new()
		_instances.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "WallCollision"
		add_child(_body)


func _ensure_mesh() -> void:
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = Vector3.ONE
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.roughness = 0.84
		_material.emission_enabled = true
		_material.emission_energy_multiplier = 0.18
	_material.albedo_color = wall_color
	_material.emission = wall_color
	_instances.material_override = _material
	_instances.multimesh.mesh = _mesh


func _visual_transform(from: Vector3, to: Vector3,
		up_hint: Vector3) -> Transform3D:
	var length := from.distance_to(to)
	var axes := _span_axes(from, to, up_hint)
	var scaled := Basis(
		axes.x * length,
		axes.y * maxf(wall_height, EPSILON),
		axes.z * maxf(wall_thickness, EPSILON))
	return Transform3D(scaled,
		(from + to) * 0.5 + axes.y * wall_height * 0.5)


func _span_axes(from: Vector3, to: Vector3, up_hint: Vector3) -> Basis:
	var along := (to - from).normalized()
	var up := up_hint.normalized() if up_hint.length_squared() > EPSILON \
		else Vector3.UP
	up = up - along * up.dot(along)
	if up.length_squared() <= EPSILON:
		up = Vector3.UP - along * Vector3.UP.dot(along)
	if up.length_squared() <= EPSILON:
		up = Vector3.RIGHT - along * Vector3.RIGHT.dot(along)
	up = up.normalized()
	var across := along.cross(up).normalized()
	return Basis(along, up, across)


func _record(segment_id: String) -> Dictionary:
	var value: Variant = _segments.get(segment_id, {})
	return value as Dictionary if value is Dictionary else {}


func _touch(record: Dictionary) -> void:
	record["revision"] = int(record.get("revision", 0)) + 1
	_revision += 1


func _result(ok: bool, status: StringName, segment_id: String,
		record: Dictionary = {}) -> Dictionary:
	var result := {
		"ok": ok,
		"status": status,
		"segment_id": segment_id,
		"manager_revision": _revision,
	}
	if not record.is_empty():
		result["state"] = int(record.get("state", SegmentState.OPEN))
		result["record_revision"] = int(record.get("revision", 0))
		result["reservation_id"] = int(record.get("reservation_id", 0))
		result["reserved_by"] = String(record.get("reserved_by", ""))
		result["active_builder"] = String(record.get("active_builder", ""))
		result["progress"] = float(record.get("progress", 0.0))
		result["work_required"] = float(record.get("work_required", 0.0))
	return result


func _reserve_result(ok: bool, status: StringName, segment_id: String,
		record: Dictionary = {}) -> Dictionary:
	var result := _result(ok, status, segment_id, record)
	result["charge_city"] = ""
	result["charge_amount"] = 0.0
	result["first_builder_pays"] = false
	result["payment_contract"] = {}
	return result


func _eligible_record(record: Dictionary) -> bool:
	var reached: PackedByteArray = record.get(
		"reached", PackedByteArray())
	return reached.size() >= 2 and (reached[0] != 0 or reached[1] != 0)


func _city_index(record: Dictionary, city: StringName) -> int:
	var cities: PackedStringArray = record.get(
		"cities", PackedStringArray())
	var wanted := String(city)
	for index in mini(cities.size(), 2):
		if cities[index] == wanted:
			return index
	return -1


func _sorted_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for key: Variant in _segments:
		ids.push_back(String(key))
	ids.sort()
	return ids


static func _sorted_cities(city_a: StringName,
		city_b: StringName) -> PackedStringArray:
	var first := String(city_a)
	var second := String(city_b)
	if first.is_empty() or second.is_empty() or first == second:
		return PackedStringArray()
	var cities := PackedStringArray([first, second])
	cities.sort()
	return cities


static func _snapshot_cities(value: Variant) -> PackedStringArray:
	var cities := PackedStringArray()
	if value is PackedStringArray:
		cities = (value as PackedStringArray).duplicate()
	elif value is Array:
		for city: Variant in value:
			cities.push_back(String(city))
	if cities.size() != 2 or cities[0].is_empty() or cities[1].is_empty() \
			or cities[0] == cities[1]:
		return PackedStringArray()
	var sorted := cities.duplicate()
	sorted.sort()
	return cities if cities == sorted else PackedStringArray()


static func _cities_contain(cities: PackedStringArray, city: String) -> bool:
	return cities.size() == 2 and (cities[0] == city or cities[1] == city)


static func _quantize(point: Vector3) -> Vector3i:
	return Vector3i(
		roundi(point.x / ENDPOINT_QUANTUM),
		roundi(point.y / ENDPOINT_QUANTUM),
		roundi(point.z / ENDPOINT_QUANTUM))


static func _dequantize(point: Vector3i) -> Vector3:
	return Vector3(point) * ENDPOINT_QUANTUM


static func _point_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


static func _id_from_canonical(cities: PackedStringArray,
		from_q: Vector3i, to_q: Vector3i) -> String:
	# Length prefixes make site names containing punctuation unambiguous.
	return "%d:%s|%d:%s|%d,%d,%d>%d,%d,%d" % [
		cities[0].length(), cities[0],
		cities[1].length(), cities[1],
		from_q.x, from_q.y, from_q.z,
		to_q.x, to_q.y, to_q.z,
	]


static func _normalise_gates(gates: PackedVector2Array,
		reverse: bool) -> PackedVector2Array:
	var ordered: Array[Vector2] = []
	for gate in gates:
		if not gate.is_finite():
			continue
		var start := clampf(minf(gate.x, gate.y), 0.0, 1.0)
		var finish := clampf(maxf(gate.x, gate.y), 0.0, 1.0)
		if finish - start <= EPSILON:
			continue
		if reverse:
			var reversed_start := 1.0 - finish
			finish = 1.0 - start
			start = reversed_start
		ordered.push_back(Vector2(start, finish))
	ordered.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x or (is_equal_approx(a.x, b.x) and a.y < b.y))
	var merged: Array[Vector2] = []
	for gate in ordered:
		if merged.is_empty() \
				or gate.x > merged[-1].y + EPSILON:
			merged.push_back(gate)
		else:
			var previous := merged[-1]
			previous.y = maxf(previous.y, gate.y)
			merged[-1] = previous
	var packed := PackedVector2Array()
	for gate in merged:
		packed.push_back(gate)
	return packed
