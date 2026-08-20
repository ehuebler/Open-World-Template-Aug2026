class_name ResidentListOverlay
extends Control

## Compact player-local roster for residences too dense for a look prompt.

signal closed

const PLATE_SIZE := Vector2(480.0, 430.0)

var _report: Callable
var _title: Label
var _summary: Label
var _residents: Label
var _former: Label
var _refresh_left := 0.0


func configure(report: Callable) -> void:
	_report = report


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.0, 0.03, 0.46)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)
	var plate := RedGlowPanel.new()
	plate.custom_minimum_size = PLATE_SIZE
	plate.fill_color = Color(0.0, 0.0, 0.0, 0.88)
	plate.border_color = RedHudTheme.RED_BRIGHT
	plate.mouse_behavior = RedGlowPanel.MouseBehavior.STOP
	centre.add_child(plate)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: StringName in [&"margin_left", &"margin_right",
			&"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 22)
	plate.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 12)
	margin.add_child(column)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override(&"font_size", 22)
	_title.add_theme_color_override(&"font_color", RedHudTheme.RED_BRIGHT)
	column.add_child(_title)
	_summary = Label.new()
	_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary.add_theme_color_override(&"font_color", RedHudTheme.GREEN)
	column.add_child(_summary)
	_residents = _roster_label()
	_residents.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_residents)
	_former = _roster_label()
	_former.add_theme_color_override(&"font_color", Color(0.72, 0.58, 0.62))
	column.add_child(_former)
	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size.y = 38.0
	RedHudTheme.button(close, 14, 7.0)
	close.pressed.connect(close_overlay)
	column.add_child(close)
	_refresh()


func _roster_label() -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_color_override(&"font_color", Color(1.0, 0.74, 0.76))
	return label


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = 0.5
		_refresh()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"inventory"):
		get_viewport().set_input_as_handled()
		close_overlay()


func _refresh() -> void:
	var report: Dictionary = _report.call() if _report.is_valid() else {}
	var residents: Array = report.get("residents", [])
	var former: Array = report.get("former_owners", [])
	_title.text = String(report.get("title", "Residence")).to_upper()
	_summary.text = "%d FLOORS  •  %d/%d RESIDENTS" % [
		int(report.get("floors", 1)), residents.size(),
		int(report.get("capacity", 0))]
	_residents.text = "CURRENT\n%s" % (
		"\n".join(residents) if not residents.is_empty() else "Vacant")
	_former.visible = not former.is_empty()
	_former.text = "DEPARTED FORMER OWNERS\n%s" % "\n".join(former)


func close_overlay() -> void:
	closed.emit()
	queue_free()
