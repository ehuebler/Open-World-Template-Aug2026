class_name PerformanceGraph
extends Control

## Thirty-second FPS curve used by the Admin performance recorder.
##
## The recorder owns samples and this control owns only their presentation. It
## draws directly rather than creating one Control per point: a normal sixty-FPS
## window is eighteen hundred samples, and turning those into UI nodes would make
## opening the profiler its own lag spike.

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const WINDOW_SECONDS := 30.0
const MARGIN_LEFT := 48.0
const MARGIN_RIGHT := 12.0
const MARGIN_TOP := 12.0
const MARGIN_BOTTOM := 24.0
const GRID := Color(1.0, 1.0, 1.0, 0.10)
const GRID_STRONG := Color(1.0, 1.0, 1.0, 0.22)
const GOOD := Color("45df68")
const WARN := Color("ffc247")
const BAD := Color("ff3445")

var _samples := PackedVector2Array()
var _spike_fps := 25.0


func _init() -> void:
	name = "PerformanceGraph"
	custom_minimum_size = Vector2(0.0, 210.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_series(samples: PackedVector2Array, spike_ms := 40.0) -> void:
	_samples = samples
	_spike_fps = 1000.0 / maxf(spike_ms, 0.001)
	queue_redraw()


func samples() -> PackedVector2Array:
	return _samples


func _draw() -> void:
	var plot := Rect2(
		Vector2(MARGIN_LEFT, MARGIN_TOP),
		Vector2(
			maxf(size.x - MARGIN_LEFT - MARGIN_RIGHT, 1.0),
			maxf(size.y - MARGIN_TOP - MARGIN_BOTTOM, 1.0)))
	draw_rect(plot, Color(0.0, 0.0, 0.0, 0.42), true)
	var ceiling := _ceiling()
	_draw_grid(plot, ceiling)
	if _samples.size() < 2:
		_draw_empty(plot)
		return
	var previous := _point_in_plot(_samples[0], plot, ceiling)
	for index in range(1, _samples.size()):
		var current_sample := _samples[index]
		var current := _point_in_plot(current_sample, plot, ceiling)
		var fps := minf(_samples[index - 1].y, current_sample.y)
		if fps <= _spike_fps:
			draw_line(
				Vector2(current.x, plot.position.y),
				Vector2(current.x, plot.end.y),
				Color(BAD, 0.12), 1.0)
		draw_line(previous, current, _line_colour(fps), 2.0, true)
		previous = current


func _draw_grid(plot: Rect2, ceiling: float) -> void:
	var font := get_theme_default_font()
	var font_size := 11
	for second in range(0, 31, 5):
		var x := plot.position.x + float(second) / WINDOW_SECONDS * plot.size.x
		draw_line(
			Vector2(x, plot.position.y), Vector2(x, plot.end.y),
			GRID_STRONG if second % 10 == 0 else GRID, 1.0)
		var label := "-%ds" % (30 - second) if second < 30 else "now"
		draw_string(
			font, Vector2(x - 11.0, plot.end.y + 17.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PALETTE.text_muted)
	var step := 30
	if ceiling > 120.0:
		step = 60
	for fps in range(0, int(ceiling) + 1, step):
		var y := plot.end.y - float(fps) / ceiling * plot.size.y
		var strong := fps == 30 or fps == 60
		draw_line(
			Vector2(plot.position.x, y), Vector2(plot.end.x, y),
			GRID_STRONG if strong else GRID, 1.0)
		draw_string(
			font, Vector2(5.0, y + 4.0), "%d" % fps,
			HORIZONTAL_ALIGNMENT_RIGHT, 35.0, font_size,
			WARN if fps == 30 else (
				GOOD if fps == 60 else PALETTE.text_muted))


func _draw_empty(plot: Rect2) -> void:
	var font := get_theme_default_font()
	draw_string(
		font,
		Vector2(plot.position.x + 16.0, plot.get_center().y),
		"Collecting frame history...",
		HORIZONTAL_ALIGNMENT_LEFT,
		plot.size.x - 32.0,
		13,
		PALETTE.text_muted)


func _ceiling() -> float:
	var highest := 60.0
	for sample in _samples:
		# One uncapped loading/menu frame should not flatten the useful range.
		highest = maxf(highest, minf(sample.y, 240.0))
	return clampf(ceilf(highest / 30.0) * 30.0, 60.0, 240.0)


func _point_in_plot(sample: Vector2, plot: Rect2, ceiling: float) -> Vector2:
	return Vector2(
		plot.position.x
			+ clampf(sample.x / WINDOW_SECONDS, 0.0, 1.0) * plot.size.x,
		plot.end.y
			- clampf(sample.y / ceiling, 0.0, 1.0) * plot.size.y)


func _line_colour(fps: float) -> Color:
	if fps < 30.0:
		return BAD
	if fps < 55.0:
		return WARN
	return GOOD
