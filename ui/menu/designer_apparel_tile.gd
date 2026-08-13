class_name DesignerApparelTile
extends RedItemSlot

## A red catalogue tile whose only action is a deliberate hold.
##
## The player designer uses a catalogue rather than storage, so dragging and
## quick-moving would be misleading. Holding the tile completes one equip or
## unequip request and paints progress around the tile's square rim.

signal hold_completed(tile: DesignerApparelTile)

enum HoldSource {
	NONE,
	MOUSE,
	TOUCH,
	ACTION,
}

@export_range(0.1, 3.0, 0.05) var hold_duration := 0.75

var _holding := false
var _latched := false
var _elapsed := 0.0
var _progress := 0.0
var _source := HoldSource.NONE
var _touch_index := -1


func _init() -> void:
	super._init()
	draggable = false
	focus_mode = Control.FOCUS_ALL
	process_mode = Node.PROCESS_MODE_ALWAYS


func _notification(what: int) -> void:
	super._notification(what)
	if what == NOTIFICATION_MOUSE_EXIT and _holding and _source == HoldSource.MOUSE:
		_cancel_hold()
	elif what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		_reset_hold()


func _process(delta: float) -> void:
	if not _holding:
		return
	if _source == HoldSource.MOUSE \
			and not get_global_rect().has_point(get_viewport().get_mouse_position()):
		_cancel_hold()
		return
	_elapsed += delta
	_progress = clampf(_elapsed / maxf(hold_duration, 0.01), 0.0, 1.0)
	queue_redraw()
	if _progress >= 1.0:
		_complete_hold()


func _gui_input(event: InputEvent) -> void:
	if not interactive or item_id().is_empty():
		return
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT:
		if mouse.pressed:
			grab_focus()
			_begin_hold(HoldSource.MOUSE)
		else:
			_release_hold(HoldSource.MOUSE)
		accept_event()
		return
	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			grab_focus()
			_touch_index = touch.index
			_begin_hold(HoldSource.TOUCH)
		elif touch.index == _touch_index:
			_release_hold(HoldSource.TOUCH)
		accept_event()
		return
	if has_focus() and event.is_action_pressed(&"ui_accept"):
		_begin_hold(HoldSource.ACTION)
		accept_event()
	elif has_focus() and event.is_action_released(&"ui_accept"):
		_release_hold(HoldSource.ACTION)
		accept_event()


func _input(event: InputEvent) -> void:
	if not _holding and not _latched:
		return
	var mouse := event as InputEventMouseButton
	if mouse != null and mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.pressed:
		_release_hold(HoldSource.MOUSE)
	var touch := event as InputEventScreenTouch
	if touch != null and touch.index == _touch_index and not touch.pressed:
		_release_hold(HoldSource.TOUCH)
	elif event.is_action_released(&"ui_accept"):
		_release_hold(HoldSource.ACTION)


func _draw() -> void:
	super._draw()
	if _progress <= 0.0:
		return
	var rim := Rect2(Vector2.ONE * 4.0, size - Vector2.ONE * 8.0)
	_draw_progress_path(rim, _progress, Color(0.27, 0.87, 0.41, 1.0), 4.0)


func _begin_hold(source: HoldSource) -> void:
	if _holding or _latched:
		return
	_source = source
	_holding = true
	_elapsed = 0.0
	_progress = 0.0
	queue_redraw()


func _release_hold(source: HoldSource) -> void:
	if source != _source:
		return
	if _latched:
		_reset_hold()
	elif _holding:
		_cancel_hold()


func _complete_hold() -> void:
	if not _holding or _latched:
		return
	_holding = false
	_latched = true
	_progress = 1.0
	hold_completed.emit(self)
	queue_redraw()


func _cancel_hold() -> void:
	_reset_hold()


func _reset_hold() -> void:
	_holding = false
	_latched = false
	_elapsed = 0.0
	_progress = 0.0
	_source = HoldSource.NONE
	_touch_index = -1
	queue_redraw()


func _draw_progress_path(
		rect: Rect2,
		share: float,
		colour: Color,
		width: float
	) -> void:
	var points := PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
		rect.position,
	])
	var perimeter := (rect.size.x + rect.size.y) * 2.0
	var remaining := perimeter * clampf(share, 0.0, 1.0)
	for index in points.size() - 1:
		if remaining <= 0.0:
			break
		var from := points[index]
		var to := points[index + 1]
		var length := from.distance_to(to)
		var drawn := minf(remaining, length)
		var end := from.lerp(to, drawn / maxf(length, 0.001))
		draw_line(from, end, Color(colour, 0.24), width + 5.0, true)
		draw_line(from, end, colour, width, true)
		remaining -= drawn


func hold_progress() -> float:
	return _progress
