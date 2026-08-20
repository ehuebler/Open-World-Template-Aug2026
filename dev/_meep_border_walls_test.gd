extends Node

## Focused, planet-free checks for the shared border-wall registry.
##
##     godot --headless --path . dev/_meep_border_walls_test.tscn

const BORDER_WALLS := preload("res://game/meeps/meep_border_walls.gd")

var _failures := 0
var _completion_events := 0
var _manager: Node3D
var _primary_id := ""
var _retry_id := ""


func _ready() -> void:
	_check_either_city_and_single_contract()
	_check_cancel_and_retry()
	_check_snapshot_round_trip()
	_check_gate_collision_spans()
	await get_tree().process_frame
	print("meep_border_walls_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_either_city_and_single_contract() -> void:
	_manager = BORDER_WALLS.new()
	add_child(_manager)
	var gates := PackedVector2Array([Vector2(0.4, 0.6)])
	var defined: Dictionary = _manager.define_segment(
		&"beta", &"alpha",
		Vector3(10.004, 0.0, 0.0), Vector3(0.003, 0.0, 0.0),
		gates, 50.0, 10.0, 4, Vector3.UP, &"cluster_one")
	_primary_id = String(defined.get("segment_id", ""))
	var stable_reverse: String = BORDER_WALLS.stable_segment_id(
		&"alpha", &"beta",
		Vector3(0.003, 0.0, 0.0), Vector3(10.004, 0.0, 0.0))
	_expect(bool(defined.get("ok", false))
		and not _primary_id.is_empty()
		and stable_reverse == _primary_id,
		"sorted city pairs and quantized endpoints produce one stable key")
	var defined_again: Dictionary = _manager.define_segment(
		&"alpha", &"beta",
		Vector3(0.003, 0.0, 0.0), Vector3(10.004, 0.0, 0.0),
		gates, 50.0, 10.0, 4, Vector3.UP, &"cluster_one")
	_expect(bool(defined_again.get("ok", false))
		and _manager.segment_count() == 1,
		"replaying an identical region definition does not duplicate a segment")

	var too_early: Dictionary = _manager.reserve_segment(
		_primary_id, &"beta", &"beta_builder_7", 100.0)
	_expect(not bool(too_early.get("ok", false))
		and StringName(too_early.get("status", &"")) == &"not_eligible",
		"a shared wall cannot reserve before either city reaches the seam")
	var reached: Dictionary = _manager.set_city_reached(
		_primary_id, &"alpha", true)
	_expect(bool(reached.get("eligible", false)),
		"one city's reached seam makes the shared segment eligible")

	var first: Dictionary = _manager.reserve_segment(
		_primary_id, &"beta", &"beta_builder_7", 100.0)
	var reservation := int(first.get("reservation_id", 0))
	_expect(bool(first.get("ok", false))
		and String(first.get("charge_city", "")) == "beta"
		and is_equal_approx(float(first.get("charge_amount", 0.0)), 50.0)
		and bool(first.get("first_builder_pays", false))
		and String(first.get("active_builder", "")) == "beta_builder_7",
		"the other city may reserve and receives the first-builder debit")

	var duplicate: Dictionary = _manager.reserve_segment(
		_primary_id, &"beta", &"beta_builder_7", 100.0)
	var rival: Dictionary = _manager.reserve_segment(
		_primary_id, &"alpha", &"alpha_builder_3", 100.0)
	_expect(bool(duplicate.get("ok", false))
		and StringName(duplicate.get("status", &"")) == &"already_reserved"
		and is_zero_approx(float(duplicate.get("charge_amount", -1.0)))
		and not bool(rival.get("ok", true))
		and is_zero_approx(float(rival.get("charge_amount", -1.0)))
		and _manager.state_of(_primary_id)
			== BORDER_WALLS.SegmentState.RESERVED,
		"retries and the rival city cannot double-reserve or double-charge")

	var progressed: Dictionary = _manager.report_progress(
		_primary_id, &"beta", reservation, &"beta_builder_7", 4.0)
	var replayed: Dictionary = _manager.report_progress(
		_primary_id, &"beta", reservation, &"beta_builder_7", 4.0)
	_expect(is_equal_approx(float(progressed.get("applied_work", 0.0)), 4.0)
		and is_zero_approx(float(replayed.get("applied_work", -1.0)))
		and is_equal_approx(float(
			_manager.segment_record(_primary_id).get("progress", 0.0)), 4.0),
		"absolute progress reports are monotonic and retry-idempotent")
	var premature: Dictionary = _manager.complete_segment(
		_primary_id, &"beta", reservation, &"beta_builder_7")
	_expect(not bool(premature.get("ok", false))
		and StringName(premature.get("status", &"")) == &"work_remaining",
		"completion refuses a reservation with unfinished work")

	_manager.segment_completed.connect(_on_segment_completed)
	_manager.report_progress(
		_primary_id, &"beta", reservation, &"beta_builder_7", 10.0)
	var completed: Dictionary = _manager.complete_segment(
		_primary_id, &"beta", reservation, &"beta_builder_7")
	var completed_again: Dictionary = _manager.complete_segment(
		_primary_id, &"beta", reservation, &"beta_builder_7")
	var alpha_view: Array = _manager.segments_for_city(&"alpha", true)
	var beta_view: Array = _manager.segments_for_city(&"beta", true)
	_expect(bool(completed.get("newly_completed", false))
		and not bool(completed_again.get("newly_completed", true))
		and _completion_events == 1
		and _manager.completed_segment_count() == 1
		and alpha_view.size() == 1 and beta_view.size() == 1
		and String((alpha_view[0] as Dictionary).get("id", ""))
			== String((beta_view[0] as Dictionary).get("id", "")),
		"completion publishes once and both cities see the same record")


func _check_cancel_and_retry() -> void:
	var defined: Dictionary = _manager.define_segment(
		&"gamma", &"delta", Vector3(0.0, 0.0, 5.0),
		Vector3(12.0, 0.0, 5.0), PackedVector2Array(),
		30.0, 12.0, 5, Vector3.UP, &"cluster_two")
	_retry_id = String(defined.get("segment_id", ""))
	_manager.set_city_reached(_retry_id, &"delta", true)
	var first: Dictionary = _manager.reserve_segment(
		_retry_id, &"gamma", &"gamma_builder", 30.0)
	var first_reservation := int(first.get("reservation_id", 0))
	_manager.report_progress(
		_retry_id, &"gamma", first_reservation, &"gamma_builder", 5.0)
	var cancelled: Dictionary = _manager.cancel_segment(
		_retry_id, &"gamma", first_reservation, &"gamma_builder")
	var cancelled_again: Dictionary = _manager.cancel_segment(
		_retry_id, &"gamma", first_reservation, &"gamma_builder")
	_expect(bool(cancelled.get("ok", false))
		and is_equal_approx(float(cancelled.get("refund_amount", 0.0)), 30.0)
		and bool(cancelled_again.get("ok", false))
		and is_zero_approx(float(cancelled_again.get("refund_amount", -1.0)))
		and _manager.state_of(_retry_id) == BORDER_WALLS.SegmentState.OPEN,
		"cancellation refunds once and its reliable retry is idempotent")

	var retry: Dictionary = _manager.reserve_segment(
		_retry_id, &"delta", &"delta_builder_1", 30.0)
	var retry_reservation := int(retry.get("reservation_id", 0))
	var stale_cancel: Dictionary = _manager.cancel_segment(
		_retry_id, &"gamma", first_reservation, &"gamma_builder")
	_expect(bool(retry.get("ok", false))
		and retry_reservation > first_reservation
		and not bool(stale_cancel.get("ok", true))
		and StringName(stale_cancel.get("status", &"")) == &"stale_reservation"
		and _manager.state_of(_retry_id)
			== BORDER_WALLS.SegmentState.RESERVED,
		"either city can retry and stale cancellation cannot erase the new job")

	var reassigned: Dictionary = _manager.set_active_builder(
		_retry_id, &"delta", retry_reservation, &"delta_builder_2")
	var old_builder: Dictionary = _manager.report_progress(
		_retry_id, &"delta", retry_reservation, &"delta_builder_1", 3.0)
	var active_builder: Dictionary = _manager.report_progress(
		_retry_id, &"delta", retry_reservation, &"delta_builder_2", 3.0)
	_expect(bool(reassigned.get("ok", false))
		and not bool(old_builder.get("ok", true))
		and StringName(old_builder.get("status", &"")) == &"not_active_builder"
		and bool(active_builder.get("ok", false)),
		"only the current active builder can advance global progress")


func _check_snapshot_round_trip() -> void:
	var saved: Dictionary = _manager.snapshot()
	var restored := BORDER_WALLS.new()
	add_child(restored)
	var applied: Dictionary = restored.apply_snapshot(saved)
	_expect(bool(applied.get("ok", false))
		and restored.snapshot() == saved
		and restored.state_of(_primary_id)
			== BORDER_WALLS.SegmentState.COMPLETE
		and restored.state_of(_retry_id)
			== BORDER_WALLS.SegmentState.RESERVED
		and String(restored.segment_record(
			_retry_id).get("active_builder", "")) == "delta_builder_2",
		"snapshot restore preserves completed, reserved, payer, and builder state")
	_expect(restored.presentation_span_count() == 2
		and restored.collision_shape_count() == 2,
		"restoring completed state rebuilds its shared presentation and collision")
	var before_invalid: Dictionary = restored.snapshot()
	var future := saved.duplicate(true)
	future["version"] = BORDER_WALLS.VERSION + 1
	var refused: Dictionary = restored.apply_snapshot(future)
	_expect(not bool(refused.get("ok", true))
		and restored.snapshot() == before_invalid,
		"an unsupported snapshot is refused atomically")
	restored.queue_free()


func _check_gate_collision_spans() -> void:
	var manager := BORDER_WALLS.new()
	add_child(manager)
	var gates := PackedVector2Array([
		Vector2(0.0, 0.2),
		Vector2(0.45, 0.55),
		Vector2(0.8, 1.0),
	])
	var defined: Dictionary = manager.define_segment(
		&"east", &"west", Vector3.ZERO, Vector3(20.0, 0.0, 0.0),
		gates, 20.0, 2.0, 1)
	var segment_id := String(defined.get("segment_id", ""))
	manager.set_city_reached(segment_id, &"east", true)
	var reserved: Dictionary = manager.reserve_segment(
		segment_id, &"west", &"west_builder", 20.0)
	var reservation := int(reserved.get("reservation_id", 0))
	manager.report_progress(
		segment_id, &"west", reservation, &"west_builder", 2.0)
	manager.complete_segment(
		segment_id, &"west", reservation, &"west_builder")
	var spans: PackedVector3Array = manager.collision_spans_for_segment(segment_id)
	var exact_spans := spans.size() == 4
	if exact_spans:
		exact_spans = spans[0].is_equal_approx(Vector3(4.0, 0.0, 0.0)) \
			and spans[1].is_equal_approx(Vector3(9.0, 0.0, 0.0)) \
			and spans[2].is_equal_approx(Vector3(11.0, 0.0, 0.0)) \
			and spans[3].is_equal_approx(Vector3(16.0, 0.0, 0.0))
	_expect(exact_spans
		and manager.collision_shape_count() == 2
		and manager.presentation_span_count() == 2,
		"collision and MultiMesh spans subtract every region-planned gate gap")
	manager.queue_free()


func _on_segment_completed(_segment_id: String, _completed_by: StringName,
		_reservation_id: int) -> void:
	_completion_events += 1


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("meep_border_walls_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("meep_border_walls_test: FAIL  %s" % message)
