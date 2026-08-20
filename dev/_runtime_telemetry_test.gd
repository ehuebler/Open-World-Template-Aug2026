extends Node

## Deterministic checks for the thirty-second performance flight recorder.
##
##     godot --headless --path . dev/_runtime_telemetry_test.tscn
##
## Synthetic timestamps avoid making this a thirty-second test. The same ring,
## summary and export paths are used; only the source of the frame interval differs.

var _failures := 0


func _ready() -> void:
	RuntimeTelemetry.set_process(false)
	RuntimeTelemetry.clear_history()
	RuntimeTelemetry.set_deep_enabled(true)
	_check_frame_ring()
	_check_subsystem_rollup()
	_check_export()
	await _finish()


func _check_frame_ring() -> void:
	var finish := Time.get_ticks_usec()
	var begin := finish - 30000000
	for index in 61:
		var frame_ms := 80.0 if index == 20 else 1000.0 / 60.0
		# Two thirds scripted process, one sixth scripted physics: the remainder
		# has to land in the engine column for the three to sum to the frame, and
		# is declared here to be a quarter each of the deferred queue, the delete
		# queue, the draw, and the wait.
		# Half of each scripted step is declared to belong to a named whole
		# callback, so the two unexplained remainders have a value to check.
		# The long frame runs several catch-up physics steps, as the engine does
		# after an overrun, so the column that divides the physics cost is exercised.
		RuntimeTelemetry._store_frame(begin + index * 500000, frame_ms,
			roundi(frame_ms * 666.0), roundi(frame_ms * 167.0), [
				roundi(frame_ms * 41.0),
				roundi(frame_ms * 42.0),
				roundi(frame_ms * 42.0),
				roundi(frame_ms * 42.0),
			], roundi(frame_ms * 333.0), roundi(frame_ms * 83.0),
			5 if index == 20 else 1)
	var latest := RuntimeTelemetry.latest_frame()
	_expect(absf(
		float(latest.get("script_process_ms", 0.0))
		+ float(latest.get("script_physics_ms", 0.0))
		+ float(latest.get("engine_ms", 0.0))
		- float(latest.get("frame_ms", 0.0))) < 0.01,
		"scripted process, scripted physics and engine time sum to the frame")
	_expect(absf(
		float(latest.get("deferred_ms", 0.0))
		+ float(latest.get("scene_flush_ms", 0.0))
		+ float(latest.get("render_draw_ms", 0.0))
		+ float(latest.get("engine_gap_ms", 0.0))
		- float(latest.get("engine_ms", 0.0))) < 0.02
		and float(latest.get("deferred_ms", 0.0)) > 0.0
		and float(latest.get("scene_flush_ms", 0.0)) > 0.0
		and float(latest.get("render_draw_ms", 0.0)) > 0.0
		and float(latest.get("engine_gap_ms", 0.0)) > 0.0,
		"the engine column splits into deferred calls, frees, drawing and waiting")
	_expect(float(latest.get("process_untraced_ms", 0.0)) > 0.0
		and float(latest.get("process_untraced_ms", 0.0))
			< float(latest.get("script_process_ms", 0.0))
		and float(latest.get("physics_untraced_ms", 0.0)) > 0.0
		and float(latest.get("physics_untraced_ms", 0.0))
			< float(latest.get("script_physics_ms", 0.0)),
		"each scripted step reports the part of it no named callback claimed")
	_expect(int(latest.get("physics_steps", 0)) == 1,
		"a frame counts the physics steps whose cost its physics column holds")
	var summary := RuntimeTelemetry.summary()
	var series := RuntimeTelemetry.fps_series()
	_expect(series.size() == 61
		and is_equal_approx(series[0].x, 0.0)
		and absf(series[-1].x - 30.0) < 0.001,
		"the graph returns the complete ordered thirty-second window")
	_expect(int(summary.get("samples", 0)) == 61
		and absf(float(summary.get("current_fps", 0.0)) - 60.0) < 0.1
		and absf(float(summary.get("worst_ms", 0.0)) - 80.0) < 0.01
		and int(summary.get("spike_frames", 0)) == 1,
		"the summary preserves current, worst, and spike frames")


func _check_subsystem_rollup() -> void:
	RuntimeTelemetry.record_activity(
		&"combat", &"test_attack", 2500, 42.0, 3)
	RuntimeTelemetry.mark_event(
		&"test", "Synthetic encounter", {"kind": "boss"})
	RuntimeTelemetry._collect_coarse(Time.get_ticks_usec())
	var snapshot := RuntimeTelemetry.latest_snapshot()
	var activity := snapshot.get("activity", []) as Array
	var found := false
	for value: Variant in activity:
		var row := value as Dictionary
		if String(row.get("category", "")) == "combat" \
				and String(row.get("label", "")) == "test_attack":
			found = int(row.get("calls", 0)) == 3 \
				and absf(float(row.get("total_ms", 0.0)) - 2.5) < 0.001 \
				and absf(float(row.get("amount", 0.0)) - 42.0) < 0.001
	_expect(found,
		"quarter-second subsystem rows retain calls, time, and affected amount")
	var events := RuntimeTelemetry.recent_events()
	var named := false
	for value: Variant in events:
		if String((value as Dictionary).get("label", "")) \
				== "Synthetic encounter":
			named = true
	_expect(named, "named encounter events stay aligned with the frame window")
	var budget := snapshot.get("frame_budget", {}) as Dictionary
	# 61 frames were stored above, one of them the 80 ms spike, and only 2.5 ms of
	# subsystem work was traced. Half of each scripted step was declared to belong
	# to a named callback, so the unexplained half is what the recorder exposes.
	_expect(int(budget.get("frames", 0)) == 61
		and float(budget.get("script_process_ms", 0.0)) > 0.0
		and absf(float(budget.get("traced_ms", 0.0)) - 2.5) < 0.001
		and float(budget.get("untraced_script_ms", 0.0))
			> float(budget.get("traced_ms", 0.0))
		and float(budget.get("untraced_script_ms", 0.0))
			< float(budget.get("script_process_ms", 0.0))
				+ float(budget.get("script_physics_ms", 0.0)),
		"the frame budget separates traced subsystem time from the rest")
	_expect(absf(float(budget.get("deferred_ms", 0.0))
			+ float(budget.get("scene_flush_ms", 0.0))
			+ float(budget.get("render_draw_ms", 0.0))
			+ float(budget.get("engine_gap_ms", 0.0))
			- float(budget.get("engine_ms", 0.0))) < 1.0
		and float(budget.get("render_draw_ms", 0.0)) > 0.0
		and float(budget.get("deferred_ms", 0.0)) > 0.0,
		"the budget carries every share of the engine column")


func _check_export() -> void:
	var result := RuntimeTelemetry.export_last_window()
	var path := String(result.get("path", ""))
	_expect(bool(result.get("ok", false))
		and not path.is_empty() and FileAccess.file_exists(path),
		"export writes one attachable JSON file")
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var payload := parsed as Dictionary
	var frames := payload.get("frames", []) as Array
	var snapshots := payload.get("snapshots", []) as Array
	var environment := payload.get("environment", {}) as Dictionary
	_expect(String(payload.get("schema", "")).ends_with("-v5")
		and frames.size() == 61 and not snapshots.is_empty()
		and environment.has("engine") and environment.has("graphics"),
		"the JSON contains frames, subsystem snapshots, settings, and machine details")
	var first := snapshots[0] as Dictionary
	var exported_frame := frames[0] as Dictionary
	_expect(first.has("frame_budget") and first.has("telemetry_phase_ms")
		and exported_frame.has("script_process_ms")
		and exported_frame.has("engine_ms")
		and exported_frame.has("render_draw_ms")
		and exported_frame.has("physics_untraced_ms")
		and exported_frame.has("physics_steps")
		and (payload.get("frame_fields", []) as Array).size()
			== RuntimeTelemetry.FRAME_STRIDE,
		"the export carries the frame split, the budget, and its own cost")
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("runtime_telemetry_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("runtime_telemetry_test: FAIL  %s" % message)


func _finish() -> void:
	RuntimeTelemetry.clear_history()
	RuntimeTelemetry.set_process(true)
	await get_tree().process_frame
	print("runtime_telemetry_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
