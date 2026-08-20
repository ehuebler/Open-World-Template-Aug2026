class_name CalderaTrialHud
extends Control

## Local-only countdown shown while a grounded player is awakening the caldera.

var _timer: Label


func _init() -> void:
	name = "CalderaTrialHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false


func _ready() -> void:
	_build()


func set_trial(shown: bool, remaining: float, _moving: bool) -> void:
	visible = shown
	if not shown:
		return
	if _timer == null:
		_build()
	_timer.text = "%04.1f" % maxf(remaining, 0.0)


func countdown_text() -> String:
	return _timer.text if _timer != null else ""


func instruction_text() -> String:
	return ""


func _build() -> void:
	if _timer != null:
		return
	_timer = Label.new()
	_timer.name = "Countdown"
	_timer.text = "24.0"
	_timer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timer.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timer.position = Vector2(-50.0, 72.0)
	_timer.size = Vector2(100.0, 42.0)
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_timer.add_theme_font_size_override(&"font_size", 28)
	_timer.add_theme_color_override(&"font_color", Color(1.0, 0.92, 0.72))
	_timer.add_theme_color_override(
		&"font_shadow_color", Color(0.08, 0.005, 0.0, 0.95))
	_timer.add_theme_constant_override(&"shadow_offset_x", 2)
	_timer.add_theme_constant_override(&"shadow_offset_y", 2)
	add_child(_timer)
