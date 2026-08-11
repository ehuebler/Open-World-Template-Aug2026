@tool
class_name HoldActionButton
extends Control

## A sharp-edged action button that completes after a continuous hold.
##
## Mouse, touch, keyboard and controller input are supported. Moving a pointer
## outside the Control or releasing before [member hold_duration] cancels the
## gesture. A completed gesture is latched until its input is released, which
## guarantees one [signal completed] emission per physical press.
##
## Set [member hold_duration] to zero for ordinary release-to-activate behavior.
## Positive durations draw progress clockwise around the glyph.

signal hold_started
signal hold_cancelled
signal progress_changed(value: float)
signal completed

enum HoldSource {
	NONE,
	MOUSE,
	TOUCH,
	ACTION,
}

const GlyphControl := preload("res://ui/menu/red_menu_glyph.gd")

@export_group("Content")
@export var label_text := "HOLD":
	set(value):
		label_text = value
		_layout_icon()
		queue_redraw()
@export var glyph: GlyphControl.Glyph = GlyphControl.Glyph.EMPTY_X:
	set(value):
		glyph = value
		_sync_icon()
@export var show_icon := true:
	set(value):
		show_icon = value
		_layout_icon()
		queue_redraw()
@export var icon_red_accent := false:
	set(value):
		icon_red_accent = value
		_sync_icon()

@export_group("Hold")
@export_range(0.0, 10.0, 0.05, "or_greater") var hold_duration := 0.9:
	set(value):
		hold_duration = maxf(value, 0.0)
		_refresh_progress_for_duration()

@export_group("State")
## Brighter red rim for a primary or currently available action.
@export var active := false:
	set(value):
		active = value
		queue_redraw()
## Adds a green inner keyline without changing the action's input behavior.
@export var selected := false:
	set(value):
		selected = value
		queue_redraw()
@export var disabled := false:
	set(value):
		disabled = value
		if disabled:
			_cancel_hold()
		focus_mode = Control.FOCUS_NONE if disabled else Control.FOCUS_ALL
		_sync_icon()
		queue_redraw()
## Draws the action as a round icon key. Intended for compact shell actions with
## an empty label; ordinary catalogue actions remain sharp rectangles.
@export var circular := false:
	set(value):
		circular = value
		queue_redraw()

@export_group("Colors")
@export var fill_color := Color(0.0, 0.0, 0.0, 0.58):
	set(value):
		fill_color = value
		queue_redraw()
@export var green_color := Color(0.36, 1.0, 0.43, 1.0):
	set(value):
		green_color = value
		_sync_icon()
		queue_redraw()
@export var black_color := Color(0.005, 0.008, 0.006, 0.98):
	set(value):
		black_color = value
		_sync_icon()
		queue_redraw()
@export var red_color := Color(1.0, 0.055, 0.11, 1.0):
	set(value):
		red_color = value
		_sync_icon()
		queue_redraw()

@export_group("Layout")
@export_range(8, 48, 1) var label_font_size := 17:
	set(value):
		label_font_size = clampi(value, 8, 48)
		queue_redraw()
@export_range(2.0, 32.0, 1.0) var content_padding := 10.0:
	set(value):
		content_padding = maxf(value, 2.0)
		_layout_icon()
		queue_redraw()
@export_range(1.0, 10.0, 0.25) var progress_width := 3.0:
	set(value):
		progress_width = clampf(value, 1.0, 10.0)
		_layout_icon()
		queue_redraw()

var _icon: GlyphControl
var _source := HoldSource.NONE
var _touch_index := -1
var _holding := false
var _latched_until_release := false
var _elapsed := 0.0
var _progress := 0.0
var _hovered := false


func _init() -> void:
	name = "HoldActionButton"
	custom_minimum_size = Vector2(176.0, 56.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	# Menus can pause the game tree. Input and elapsed hold time must continue.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_ensure_icon()
	_sync_icon()
	_layout_icon()


func _exit_tree() -> void:
	_reset_hold(false)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_layout_icon()
			queue_redraw()
		NOTIFICATION_MOUSE_ENTER:
			_hovered = true
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			_hovered = false
			if _holding and _source == HoldSource.MOUSE:
				_cancel_hold()
			queue_redraw()
		NOTIFICATION_FOCUS_ENTER:
			queue_redraw()
		NOTIFICATION_FOCUS_EXIT:
			if _holding and _source == HoldSource.ACTION:
				_cancel_hold()
			queue_redraw()
		NOTIFICATION_VISIBILITY_CHANGED:
			if not visible:
				_cancel_hold()


func _process(delta: float) -> void:
	if not _holding or hold_duration <= 0.0:
		return
	if disabled:
		_cancel_hold()
		return

	# Covers controls moved out from under a held cursor as well as pointer motion
	# that did not produce a GUI event for this Control.
	if _source == HoldSource.MOUSE \
			and not get_global_rect().has_point(get_viewport().get_mouse_position()):
		_cancel_hold()
		return

	_elapsed += delta
	_set_progress(_elapsed / hold_duration)
	if _elapsed >= hold_duration:
		_complete_hold()


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return

	var mouse_button := event as InputEventMouseButton
	if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_LEFT:
		if mouse_button.pressed:
			grab_focus()
			_begin_hold(HoldSource.MOUSE)
		else:
			_release_source(HoldSource.MOUSE,
				get_global_rect().has_point(mouse_button.global_position))
		accept_event()
		return

	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			grab_focus()
			_touch_index = touch.index
			_begin_hold(HoldSource.TOUCH)
		elif touch.index == _touch_index:
			_release_source(HoldSource.TOUCH,
				get_global_rect().has_point(touch.position))
		accept_event()
		return

	if not has_focus():
		return
	if event is InputEventKey and (event as InputEventKey).echo:
		return
	if event.is_action_pressed(&"ui_accept"):
		_begin_hold(HoldSource.ACTION)
		accept_event()
	elif event.is_action_released(&"ui_accept"):
		_release_source(HoldSource.ACTION, true)
		accept_event()


## Release and pointer-drag events can leave this Control's GUI region. Reading
## only `_gui_input` would strand the hold until a later click, so an active
## gesture follows its matching release globally.
func _input(event: InputEvent) -> void:
	if _source == HoldSource.NONE:
		return

	match _source:
		HoldSource.MOUSE:
			var mouse_motion := event as InputEventMouseMotion
			if mouse_motion != null and _holding \
					and not get_global_rect().has_point(mouse_motion.global_position):
				_cancel_hold()
				return
			var mouse_button := event as InputEventMouseButton
			if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_LEFT \
					and not mouse_button.pressed:
				_release_source(HoldSource.MOUSE,
					get_global_rect().has_point(mouse_button.global_position))
		HoldSource.TOUCH:
			var drag := event as InputEventScreenDrag
			if drag != null and drag.index == _touch_index and _holding \
					and not get_global_rect().has_point(drag.position):
				_cancel_hold()
				return
			var touch := event as InputEventScreenTouch
			if touch != null and touch.index == _touch_index and not touch.pressed:
				_release_source(HoldSource.TOUCH,
					get_global_rect().has_point(touch.position))
		HoldSource.ACTION:
			if event.is_action_released(&"ui_accept"):
				_release_source(HoldSource.ACTION, true)


func _draw() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	_draw_surface()
	_draw_progress()
	_draw_label()


func _draw_surface() -> void:
	var border_rect := Rect2(Vector2.ZERO, size).grow(-1.0)
	var intensity := 0.48
	if active:
		intensity += 0.38
	if selected:
		intensity += 0.32
	if _hovered or has_focus():
		intensity += 0.24
	if _holding:
		intensity += 0.62
	if disabled:
		intensity = 0.10

	if circular:
		_draw_circular_surface(intensity)
		return

	for layer in range(4, 0, -1):
		var fraction := float(layer) / 4.0
		var width := 2.0 + 14.0 * fraction
		var alpha := red_color.a * intensity * 0.10 * (1.0 - fraction * 0.65)
		draw_rect(border_rect, _with_alpha(red_color, alpha), false, width, true)

	var fill := fill_color
	if selected:
		fill = fill.lerp(_with_alpha(green_color, fill_color.a), 0.09)
	elif active:
		fill = fill.lerp(_with_alpha(red_color, fill_color.a), 0.06)
	if disabled:
		fill = _with_alpha(fill, fill.a * 0.72)
	draw_rect(border_rect, fill, true)

	var core_alpha := red_color.a * clampf(0.38 + intensity * 0.48, 0.0, 1.0)
	draw_rect(border_rect, _with_alpha(red_color, core_alpha), false, 2.0, true)

	if selected:
		draw_rect(border_rect.grow(-4.0),
			_with_alpha(green_color, 0.88 if not disabled else 0.22),
			false, 1.75, true)
	elif has_focus() and not disabled:
		draw_rect(border_rect.grow(-4.0), _with_alpha(green_color, 0.58),
			false, 1.25, true)


func _draw_circular_surface(intensity: float) -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 2.0
	for layer in range(4, 0, -1):
		var fraction := float(layer) / 4.0
		var width := 2.0 + 12.0 * fraction
		var alpha := red_color.a * intensity * 0.10 * (1.0 - fraction * 0.65)
		draw_arc(center, radius, 0.0, TAU, 48,
			_with_alpha(red_color, alpha), width, true)

	var fill := fill_color
	if selected:
		fill = fill.lerp(_with_alpha(green_color, fill_color.a), 0.09)
	elif active:
		fill = fill.lerp(_with_alpha(red_color, fill_color.a), 0.06)
	if disabled:
		fill = _with_alpha(fill, fill.a * 0.72)
	draw_circle(center, radius, fill)

	var core_alpha := red_color.a * clampf(0.38 + intensity * 0.48, 0.0, 1.0)
	draw_arc(center, radius, 0.0, TAU, 48,
		_with_alpha(red_color, core_alpha), 2.0, true)
	if selected:
		draw_arc(center, radius - 4.0, 0.0, TAU, 48,
			_with_alpha(green_color, 0.88 if not disabled else 0.22),
			1.75, true)
	elif has_focus() and not disabled:
		draw_arc(center, radius - 4.0, 0.0, TAU, 48,
			_with_alpha(green_color, 0.58), 1.25, true)


func _draw_progress() -> void:
	if _icon == null or not show_icon or hold_duration <= 0.0:
		return
	var center := _icon.position + _icon.size * 0.5
	var radius := minf(_icon.size.x, _icon.size.y) * 0.5 + progress_width + 2.0
	var points := maxi(24, ceili(radius * 1.5))
	var dim := 0.16 if disabled else 0.34

	draw_arc(center, radius, -PI * 0.5, TAU - PI * 0.5, points,
		_with_alpha(black_color, 0.9), progress_width + 2.0, true)
	draw_arc(center, radius, -PI * 0.5, TAU - PI * 0.5, points,
		_with_alpha(red_color, dim), progress_width, true)
	if _progress <= 0.0:
		return
	draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * _progress, points,
		_with_alpha(black_color, 0.95), progress_width + 2.0, true)
	draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * _progress, points,
		_with_alpha(green_color, 0.32 if disabled else 1.0),
		progress_width, true)


func _draw_label() -> void:
	if label_text.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return

	var left := content_padding
	if _icon != null and show_icon:
		left = _icon.position.x + _icon.size.x + progress_width + content_padding
	var available_width := maxf(size.x - left - content_padding, 0.0)
	if available_width <= 1.0:
		return

	var baseline := (size.y - font.get_height(label_font_size)) * 0.5 \
		+ font.get_ascent(label_font_size)
	var position := Vector2(left, baseline)
	var text_color := green_color
	if selected:
		text_color = green_color.lightened(0.14)
	elif not active:
		text_color = _with_alpha(green_color, green_color.a * 0.82)
	if disabled:
		text_color = _with_alpha(text_color, text_color.a * 0.30)

	var outline_alpha := 0.55 if disabled else 0.96
	var outline_color := _with_alpha(black_color, outline_alpha)
	for offset in [
		Vector2(-1.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(0.0, -1.0),
		Vector2(0.0, 1.0),
	]:
		draw_string(font, position + offset, label_text,
			HORIZONTAL_ALIGNMENT_CENTER, available_width,
			label_font_size, outline_color)
	draw_string(font, position, label_text, HORIZONTAL_ALIGNMENT_CENTER,
		available_width, label_font_size, text_color)


func _ensure_icon() -> void:
	if _icon != null and is_instance_valid(_icon):
		return
	_icon = GlyphControl.new() as GlyphControl
	_icon.name = "Glyph"
	# This control owns the icon's exact fitted size. RedMenuGlyph's standalone
	# minimum would otherwise push compact hold-action icons off center.
	_icon.custom_minimum_size = Vector2.ZERO
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)


func _layout_icon() -> void:
	if _icon == null or not is_instance_valid(_icon):
		return
	_icon.visible = show_icon
	if not show_icon:
		return

	var ring_room := progress_width + 4.0
	var available_edge := size.y - (content_padding + ring_room) * 2.0
	var width_share := size.x * (0.55 if label_text.is_empty() else 0.32)
	var edge := maxf(minf(available_edge, width_share), 8.0)
	var x := content_padding + ring_room
	if label_text.is_empty():
		x = (size.x - edge) * 0.5
	_icon.position = Vector2(x, (size.y - edge) * 0.5)
	_icon.size = Vector2(edge, edge)


func _sync_icon() -> void:
	if _icon == null or not is_instance_valid(_icon):
		return
	_icon.glyph = glyph
	_icon.green_color = green_color
	_icon.black_color = black_color
	_icon.red_color = red_color
	_icon.red_accent = icon_red_accent
	_icon.modulate = Color(1.0, 1.0, 1.0, 0.28 if disabled else 1.0)
	_icon.queue_redraw()


func _begin_hold(source: HoldSource) -> void:
	if disabled or _holding or _latched_until_release:
		return
	_source = source
	_holding = true
	_elapsed = 0.0
	_set_progress(0.0)
	hold_started.emit()
	queue_redraw()


func _release_source(source: HoldSource, inside: bool) -> void:
	if source != _source:
		return
	if _latched_until_release:
		_reset_hold(false)
		return
	if not _holding:
		return
	if hold_duration <= 0.0 and inside:
		_complete_hold()
		_reset_hold(false)
	else:
		_cancel_hold()


func _complete_hold() -> void:
	if not _holding or _latched_until_release:
		return
	_holding = false
	_latched_until_release = true
	_set_progress(1.0)
	completed.emit()
	queue_redraw()


func _cancel_hold() -> void:
	_reset_hold(_holding)


func _reset_hold(emit_cancelled: bool) -> void:
	var should_emit := emit_cancelled and _holding and not _latched_until_release
	_holding = false
	_latched_until_release = false
	_source = HoldSource.NONE
	_touch_index = -1
	_elapsed = 0.0
	_set_progress(0.0)
	if should_emit:
		hold_cancelled.emit()
	queue_redraw()


func _set_progress(value: float) -> void:
	var next := clampf(value, 0.0, 1.0)
	if is_equal_approx(next, _progress):
		return
	_progress = next
	progress_changed.emit(_progress)
	queue_redraw()


func _refresh_progress_for_duration() -> void:
	if not _holding:
		return
	if hold_duration > 0.0:
		_set_progress(_elapsed / hold_duration)
		if _elapsed >= hold_duration:
			_complete_hold()
	else:
		_set_progress(0.0)


func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, clampf(alpha, 0.0, 1.0))


func is_holding() -> bool:
	return _holding


func hold_progress() -> float:
	return _progress


func cancel_hold() -> void:
	_cancel_hold()
