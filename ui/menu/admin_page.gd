class_name AdminPage
extends VBoxContainer

## Admin performance flight recorder.
##
## RuntimeTelemetry records whether this page exists or not. Opening a
## single-player menu pauses both the world and the recorder, so the curve freezes
## on the thirty seconds that led to opening it instead of replacing the evidence
## with thirty seconds of looking at a menu. Multiplayer cannot pause the world and
## remains live.
##
## EXPORT writes one self-describing JSON file containing every frame, quarter-
## second subsystem snapshots, attack/activity rollups, spike markers, graphics
## settings and machine details. That file is the thing to attach to a lag report.

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const REFRESH_MSEC := 200
const GOOD := Color("45df68")
const WARN := Color("ffc247")
const BAD := Color("ff3445")

var _player: OnlinePlayer
var _graph: PerformanceGraph
var _summary_labels: Dictionary = {}
var _details: RichTextLabel
var _events: RichTextLabel
var _trace: Button
var _notice: Label
var _refresh_at := 0


func configure(player: OnlinePlayer) -> void:
	_player = player


func _init() -> void:
	name = "AdminPerformance"
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_theme_constant_override(&"separation", 8)
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	_build()
	_refresh()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now < _refresh_at:
		return
	_refresh_at = now + REFRESH_MSEC
	_refresh()


func graph() -> PerformanceGraph:
	return _graph


func export_button() -> Button:
	return find_child("ExportPerformanceLog", true, false) as Button


func notice_text() -> String:
	return _notice.text if _notice != null else ""


func _build() -> void:
	var header := HBoxContainer.new()
	header.name = "PerformanceHeader"
	header.add_theme_constant_override(&"separation", 8)
	add_child(header)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override(&"separation", 0)
	header.add_child(title_box)
	var title := MenuWidgets.heading("PERFORMANCE FLIGHT RECORDER", 19)
	title_box.add_child(title)
	var caption := MenuWidgets.caption(
		"Every frame and every major subsystem — rolling 30 seconds")
	caption.add_theme_font_size_override(&"font_size", 11)
	title_box.add_child(caption)

	_trace = MenuWidgets.button("")
	_trace.name = "DetailedTraceToggle"
	_trace.toggle_mode = true
	_trace.button_pressed = RuntimeTelemetry.deep_enabled()
	_trace.tooltip_text = (
		"Adds timed Meep stages, attacks, flora damage, and terrain mutations. "
		+ "The FPS curve and engine counters are always recorded.")
	_trace.toggled.connect(_on_trace_toggled)
	header.add_child(_trace)
	_refresh_trace_button()

	var clear := MenuWidgets.button("CLEAR")
	clear.name = "ClearPerformanceHistory"
	clear.tooltip_text = "Clear only the diagnostic history; no game state changes"
	clear.pressed.connect(_on_clear)
	header.add_child(clear)

	var folder := MenuWidgets.button("FOLDER")
	folder.name = "OpenPerformanceFolder"
	folder.tooltip_text = "Open the folder containing exported performance logs"
	folder.pressed.connect(_on_open_folder)
	header.add_child(folder)

	var export := MenuWidgets.button("EXPORT 30s")
	export.name = "ExportPerformanceLog"
	export.tooltip_text = "Save one JSON file to attach to a lag report"
	export.pressed.connect(_on_export)
	header.add_child(export)

	var graph_panel := PanelContainer.new()
	graph_panel.name = "PerformanceGraphPanel"
	graph_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	AuroraSurface.add_to(graph_panel, AuroraSurface.Style.ROW)
	add_child(graph_panel)
	_graph = PerformanceGraph.new()
	graph_panel.add_child(_graph)

	var summary := GridContainer.new()
	summary.name = "PerformanceSummary"
	summary.columns = 5
	summary.add_theme_constant_override(&"h_separation", 8)
	add_child(summary)
	_add_summary(summary, &"current", "CURRENT")
	_add_summary(summary, &"average", "30s AVERAGE")
	_add_summary(summary, &"low", "1% LOW")
	_add_summary(summary, &"worst", "WORST FRAME")
	_add_summary(summary, &"spikes", "SPIKE FRAMES")

	var lower := HBoxContainer.new()
	lower.name = "PerformanceDetails"
	lower.custom_minimum_size.y = 105.0
	lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lower.add_theme_constant_override(&"separation", 8)
	add_child(lower)

	var details_panel := _well(lower, "SUBSYSTEMS", 0.68)
	_details = _report_label("SubsystemReport")
	details_panel.add_child(_details)

	var event_panel := _well(lower, "RECENT SPIKES / HOTSPOTS", 0.32)
	_events = _report_label("PerformanceEvents")
	event_panel.add_child(_events)

	_notice = Label.new()
	_notice.name = "PerformanceNotice"
	_notice.add_theme_font_size_override(&"font_size", 11)
	_notice.add_theme_color_override(&"font_color", PALETTE.accent)
	_notice.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_notice)


func _add_summary(parent: GridContainer, id: StringName, heading: String) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	AuroraSurface.add_to(panel, AuroraSurface.Style.ROW)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override(&"separation", 0)
	panel.add_child(box)
	var title := Label.new()
	title.text = heading
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 10)
	title.add_theme_color_override(&"font_color", PALETTE.text_muted)
	box.add_child(title)
	var value := Label.new()
	value.name = "Summary_%s" % id
	value.text = "—"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override(&"font_size", 16)
	box.add_child(value)
	_summary_labels[id] = value


## Returns the VBox inside a captioned panel. Horizontal stretch ratios make the
## subsystem report wider than the event tail without hard-coding pixels.
func _well(parent: HBoxContainer, heading: String,
		ratio: float) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = ratio
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	AuroraSurface.add_to(panel, AuroraSurface.Style.ROW)
	parent.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override(&"margin_left", 10)
	margin.add_theme_constant_override(&"margin_right", 10)
	margin.add_theme_constant_override(&"margin_top", 6)
	margin.add_theme_constant_override(&"margin_bottom", 6)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	margin.add_child(box)
	var title := MenuWidgets.caption(heading)
	title.add_theme_font_size_override(&"font_size", 10)
	box.add_child(title)
	return box


func _report_label(node_name: String) -> RichTextLabel:
	var report := RichTextLabel.new()
	report.name = node_name
	report.bbcode_enabled = true
	report.fit_content = false
	report.scroll_active = true
	report.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	report.size_flags_vertical = Control.SIZE_EXPAND_FILL
	report.add_theme_font_size_override(&"normal_font_size", 10)
	report.add_theme_color_override(&"default_color", PALETTE.text_muted)
	return report


func _refresh() -> void:
	if _graph == null:
		return
	var summary := RuntimeTelemetry.summary()
	_graph.set_series(
		RuntimeTelemetry.fps_series(),
		float(summary.get("spike_threshold_ms", 40.0)))
	_set_summary(
		&"current", "%.1f FPS" % float(summary.get("current_fps", 0.0)),
		_rate_colour(float(summary.get("current_fps", 0.0))))
	_set_summary(
		&"average", "%.1f FPS" % float(summary.get("mean_fps", 0.0)),
		_rate_colour(float(summary.get("mean_fps", 0.0))))
	_set_summary(
		&"low", "%.1f FPS" % float(summary.get("one_percent_low_fps", 0.0)),
		_rate_colour(float(summary.get("one_percent_low_fps", 0.0))))
	var worst := float(summary.get("worst_ms", 0.0))
	_set_summary(
		&"worst", "%.1f ms" % worst,
		BAD if worst >= 40.0 else (WARN if worst >= 20.0 else GOOD))
	var spikes := int(summary.get("spike_frames", 0))
	_set_summary(
		&"spikes", "%d" % spikes,
		BAD if spikes > 0 else GOOD)
	_details.text = _subsystem_report(RuntimeTelemetry.latest_snapshot())
	_events.text = _event_report(RuntimeTelemetry.recent_events())
	_trace.button_pressed = RuntimeTelemetry.deep_enabled()
	_refresh_trace_button()


func _set_summary(id: StringName, text: String, colour: Color) -> void:
	var label := _summary_labels.get(id) as Label
	if label == null:
		return
	label.text = text
	label.add_theme_color_override(&"font_color", colour)


func _subsystem_report(snapshot: Dictionary) -> String:
	if snapshot.is_empty():
		return "Collecting subsystem state..."
	var terrain := snapshot.get("terrain", {}) as Dictionary
	var meeps := snapshot.get("meeps", {}) as Dictionary
	var flora := snapshot.get("flora", {}) as Dictionary
	var fauna := snapshot.get("fauna", {}) as Dictionary
	var aerial := snapshot.get("aerial", {}) as Dictionary
	var scene := snapshot.get("scene", {}) as Dictionary
	var network := snapshot.get("network", {}) as Dictionary
	var frame := RuntimeTelemetry.latest_frame()
	var frame_budget := snapshot.get("frame_budget", {}) as Dictionary
	var per_frame := frame_budget.get("per_frame_ms", {}) as Dictionary
	var lines := PackedStringArray()
	lines.append(
		"[color=#8ff3a5]FRAME[/color]  %.1f ms = script %.1f + physics %.1f + engine %.1f (deferred %.1f, free %.1f, draw %.1f, wait %.1f) — GPU %.2f ms, render CPU %.2f ms, %d draws / %.0f primitives"
		% [
			float(per_frame.get("wall", frame.get("frame_ms", 0.0))),
			float(per_frame.get("script_process", 0.0)),
			float(per_frame.get("script_physics", 0.0)),
			float(per_frame.get("engine", 0.0)),
			float(per_frame.get("deferred", 0.0)),
			float(per_frame.get("scene_flush", 0.0)),
			float(per_frame.get("render_draw", 0.0)),
			float(per_frame.get("engine_gap", 0.0)),
			float(frame.get("gpu_ms", 0.0)),
			float(frame.get("render_cpu_ms", 0.0)),
			int(frame.get("draw_calls", 0)),
			float(frame.get("primitives", 0.0)),
		])
	var untraced := float(per_frame.get("untraced_script", 0.0))
	var scripted := float(per_frame.get("script_process", 0.0)) \
		+ float(per_frame.get("script_physics", 0.0))
	lines.append(
		"[color=%s]SCRIPTS[/color]  %.1f ms traced, %.1f ms unnamed (%.1f process + %.1f physics, %d%% of scripted) — %d processing / %d physics nodes"
		% [
			"#ffc247" if untraced > scripted * 0.5 and scripted > 4.0 \
				else "#8ff3a5",
			float(per_frame.get("traced", 0.0)),
			untraced,
			float(per_frame.get("process_untraced", 0.0)),
			float(per_frame.get("physics_untraced", 0.0)),
			roundi(100.0 * untraced / maxf(scripted, 0.001)),
			int(scene.get("processing_nodes", 0)),
			int(scene.get("physics_processing_nodes", 0)),
		])
	var census := scene.get("processing_census", []) as Array
	if not census.is_empty():
		var busiest := PackedStringArray()
		for index in mini(census.size(), 5):
			var row := census[index] as Dictionary
			busiest.append("%s %dp/%df" % [
				String(row.get("script", "?")),
				int(row.get("process", 0)),
				int(row.get("physics", 0)),
			])
		lines.append("        %s" % ", ".join(busiest))
	lines.append(
		"[color=#8ff3a5]MEEPS[/color]  %d population — %d resident / %d ledger cities"
		% [
			int(meeps.get("population", 0)),
			int(meeps.get("resident_cities", 0)),
			int(meeps.get("ledger_cities", 0)),
		])
	lines.append(
		"        %d active rows, %d visible, %d structures, %d road cells, %d street lights"
		% [
			int(meeps.get("active_rows", 0)),
			int(meeps.get("visible_rows", 0)),
			int(meeps.get("structures", 0)),
			int(meeps.get("road_cells", 0)),
			int(meeps.get("street_lights", 0)),
		])
	var budget := flora.get("budget", {}) as Dictionary
	var flora_phases := flora.get("phase_ms", {}) as Dictionary
	lines.append(
		"[color=#8ff3a5]FLORA[/color]  %d fields, %d tiles, %d pending, %d surveys — apply %.1f ms, dress %.1f ms, prune %.1f ms / %d left — budget %.0f / %d µs"
		% [
			int(flora.get("fields", 0)),
			int(flora.get("tiles", 0)),
			int(flora.get("pending_tiles", 0)),
			int(flora.get("survey_tasks", 0)),
			float(flora_phases.get("apply", 0.0)),
			float(flora_phases.get("dress", 0.0)),
			float(flora_phases.get("prune", 0.0)),
			int(flora.get("prune_backlog", 0)),
			float(budget.get("estimated_total_usec", 0.0)),
			int(budget.get("budget_usec", 0)),
		])
	lines.append(
		"[color=#8ff3a5]TERRAIN[/color]  %d visible, %d pending + %d queued, depth %d, %d scars, %.2f ms frame"
		% [
			int(terrain.get("visible", 0)),
			int(terrain.get("pending", 0)),
			int(terrain.get("requests", 0)),
			int(terrain.get("depth", -1)),
			int(terrain.get("scars", 0)),
			float(terrain.get("frame_ms", 0.0)),
		])
	lines.append(
		"[color=#8ff3a5]FAUNA / BOSSES[/color]  %d mobs, %d streamed actors, %d bosses, %.2f ms survey — %d night insects / %d clusters"
		% [
			int(fauna.get("mobs_in_tree", 0)),
			int(fauna.get("actors", 0)),
			int(scene.get("bosses", 0)),
			float(fauna.get("last_survey_ms", 0.0)),
			int(aerial.get("visible_insects", 0)),
			int(aerial.get("clusters", 0)),
		])
	lines.append(
		"[color=#8ff3a5]RENDER[/color]  %d geometry, %d MultiMesh instances, %d/%d lights, %d/%d particles, %d ability walls"
		% [
			int(scene.get("visible_geometry", 0)),
			int(scene.get("multimesh_instances", 0)),
			int(scene.get("visible_lights", 0)),
			int(scene.get("lights", 0)),
			int(scene.get("emitting_particles", 0)),
			int(scene.get("particles", 0)),
			int(scene.get("ability_walls", 0)),
		])
	lines.append(
		"[color=#8ff3a5]NETWORK[/color]  %d player(s), %s, %s — %d voice packets%s"
		% [
			int(network.get("players", 0)),
			"host" if bool(network.get("host", false)) else "client",
			String(network.get("mode", "offline")),
			int(network.get("voice_packets_sent", 0)),
			" (transmitting)" if bool(
				network.get("voice_transmitting", false)) else "",
		])
	var activities := snapshot.get("activity", []) as Array
	if not activities.is_empty():
		var hot := PackedStringArray()
		for index in mini(activities.size(), 4):
			var row := activities[index] as Dictionary
			hot.append("%s/%s %.2f ms (%dx)" % [
				String(row.get("category", "")),
				String(row.get("label", "")),
				float(row.get("total_ms", 0.0)),
				int(row.get("calls", 0)),
			])
		lines.append("[color=#ffc247]HOT THIS SAMPLE[/color]  %s" % ", ".join(hot))
	lines.append(
		"[color=#666666]Recorder overhead %.3f ms/sample (%.3f ms/frame); detailed trace %s[/color]"
		% [
			float(snapshot.get("telemetry_ms", 0.0)),
			float(frame_budget.get("recorder_ms", 0.0))
				/ maxf(float(frame_budget.get("frames", 1)), 1.0),
			"ON" if RuntimeTelemetry.deep_enabled() else "OFF",
		])
	return "\n".join(lines)


func _event_report(events: Array) -> String:
	if events.is_empty():
		return "No frame over 40 ms or subsystem over 4 ms in this window."
	var lines := PackedStringArray()
	var start := maxi(events.size() - 8, 0)
	for index in range(events.size() - 1, start - 1, -1):
		var event := events[index] as Dictionary
		var details := event.get("details", {}) as Dictionary
		var suffix := ""
		if details.has("worst_ms"):
			suffix = " — %.1f ms %s" % [
				float(details["worst_ms"]), _spike_blame(details)]
		elif details.has("elapsed_ms"):
			suffix = " — %.2f ms" % float(details["elapsed_ms"])
		lines.append("[color=#ff8d98]-%4.1fs[/color] %s%s" % [
			float(event.get("seconds_ago", 0.0)),
			String(event.get("label", "event")),
			suffix,
		])
	return "\n".join(lines)


## Names where the spike's worst frame spent itself, and the heaviest single
## traced call inside it. A marker that only says "218 ms" starts an
## investigation; one that says the settlers were paving finishes it.
func _spike_blame(details: Dictionary) -> String:
	var script_ms := float(details.get("worst_script_process_ms", 0.0))
	var physics_ms := float(details.get("worst_script_physics_ms", 0.0))
	var columns := {
		"script": script_ms,
		"physics": physics_ms,
		"deferred calls": float(details.get("worst_deferred_ms", 0.0)),
		"freeing nodes": float(details.get("worst_scene_flush_ms", 0.0)),
		"draw": float(details.get("worst_render_draw_ms", 0.0)),
		"waiting": float(details.get("worst_engine_gap_ms", 0.0)),
	}
	var blamed := ""
	var most := 0.0
	for column: Variant in columns:
		if float(columns[column]) > most:
			most = float(columns[column])
			blamed = String(column)
	if blamed.is_empty():
		return ""
	# A physics column holding several catch-up steps is one frame paying off the
	# frame before it, not a subsystem that suddenly cost several times more.
	var steps := int(details.get("worst_physics_steps", 0))
	if blamed == "physics" and steps > 1:
		return "(%d physics steps catching up — %.0f ms each)" % [
			steps, physics_ms / float(steps)]
	# When most of the blamed step belongs to no named callback, the traced rows
	# below cannot be the answer and saying so is the useful reading.
	var unnamed := float(details.get("worst_process_untraced_ms", 0.0)) \
		if blamed == "script" \
		else float(details.get("worst_physics_untraced_ms", 0.0))
	if (blamed == "script" or blamed == "physics") and unnamed > most * 0.5:
		return "(%s — %.0f ms of it in code with no label)" % [blamed, unnamed]
	# Roll-up rows are skipped rather than ranked: a whole physics step always
	# contains, and so outranks, the one stage that actually burst inside it.
	var hottest := ""
	var worst_call := 0.0
	for row_value: Variant in details.get("traced", []) as Array:
		var row := row_value as Dictionary
		var label := String(row.get("label", ""))
		if label.ends_with("_total") \
				or float(row.get("max_ms", 0.0)) <= worst_call:
			continue
		worst_call = float(row.get("max_ms", 0.0))
		hottest = label
	if hottest.is_empty():
		return "(%s)" % blamed
	return "(%s — %s %.0f ms)" % [blamed, hottest, worst_call]


func _rate_colour(fps: float) -> Color:
	if fps < 30.0:
		return BAD
	if fps < 55.0:
		return WARN
	return GOOD


func _on_trace_toggled(enabled: bool) -> void:
	RuntimeTelemetry.set_deep_enabled(enabled)
	_refresh_trace_button()
	_say("Detailed subsystem tracing %s." % ("on" if enabled else "off"))


func _refresh_trace_button() -> void:
	if _trace != null:
		_trace.text = "TRACE %s" % (
			"ON" if RuntimeTelemetry.deep_enabled() else "OFF")


func _on_clear() -> void:
	RuntimeTelemetry.clear_history()
	_refresh()
	_say("Performance history cleared; recording continues.")


func _on_open_folder() -> void:
	var error := RuntimeTelemetry.open_export_folder()
	_say(
		"Opened the performance log folder."
		if error == OK else "Could not open the folder (error %d)." % error)


func _on_export() -> void:
	var result := RuntimeTelemetry.export_last_window()
	if not bool(result.get("ok", false)):
		_say(String(result.get("message", "Could not export the log.")))
		return
	var path := String(result.get("path", ""))
	if not path.is_empty() and DisplayServer.get_name() != "headless":
		DisplayServer.clipboard_set(path)
	_say("%s Path copied: %s" % [
		String(result.get("message", "Performance log saved.")), path])


func _say(text: String) -> void:
	if _notice != null:
		_notice.text = text
