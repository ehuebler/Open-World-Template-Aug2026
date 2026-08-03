class_name ItemSlot
extends Control

## One tile of an inventory grid: a drawn square holding whatever item sits at
## `index` of `container`.
##
## The tile owns its own rules rather than reporting clicks upwards. Dragging asks
## both containers whether the swap is legal, dropping performs it, and the
## containers then tell the screen to redraw. Shift-clicking is the exception,
## because where an item should jump to depends on which grids are on screen, so
## that is passed out as a signal.

signal quick_move_requested(slot: ItemSlot)
signal hover_started(slot: ItemSlot)
signal hover_ended(slot: ItemSlot)

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

const SIZE := 52.0
## Segments per edge of the drawn border, and how far each joint wanders.
const EDGE_SEGMENTS := 5
const EDGE_WANDER := 1.1
const ICON_INSET := 4.0

var container: ItemContainer
var index := 0
## HUD tiles are drawn but take no input: the weapon bar reports what is in hand
## rather than being rummaged in.
var interactive := true
## Shown when the slot is empty, naming the body part an equipment slot covers.
var placeholder := ""
## Drawn small in the top corner: the key that reaches this slot.
var badge := ""
## Marks the weapon bar's current slot, which is drawn heavier and in accent ink.
var selected := false

var _hovered := false
var _drop_target := false
var _outlines: Array[PackedVector2Array] = []


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = custom_minimum_size


func bind(to_container: ItemContainer, at_index: int) -> void:
	container = to_container
	index = at_index
	queue_redraw()


func item_id() -> String:
	if container == null:
		return ""
	return container.get_item(index)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_outlines.clear()
			queue_redraw()
		NOTIFICATION_MOUSE_ENTER:
			_hovered = true
			hover_started.emit(self)
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			_hovered = false
			_drop_target = false
			hover_ended.emit(self)
			queue_redraw()
		NOTIFICATION_DRAG_END:
			_drop_target = false
			queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if button.shift_pressed and not item_id().is_empty():
		accept_event()
		quick_move_requested.emit(self)


func _get_drag_data(_at: Vector2) -> Variant:
	if not interactive or item_id().is_empty():
		return null
	set_drag_preview(_drag_preview())
	return {"slot": self}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	var from := _source_slot(data)
	if from == null or container == null:
		return false
	# A drop swaps, so the item coming back has to be legal where it lands too.
	var legal := container.accepts(index, from.item_id()) \
		and from.container.accepts(from.index, item_id())
	if legal != _drop_target:
		_drop_target = legal
		queue_redraw()
	return legal


func _drop_data(_at: Vector2, data: Variant) -> void:
	var from := _source_slot(data)
	if from == null:
		return
	_drop_target = false
	ItemContainer.transfer(from.container, from.index, container, index)


func _source_slot(data: Variant) -> ItemSlot:
	if not interactive or typeof(data) != TYPE_DICTIONARY:
		return null
	var from := (data as Dictionary).get("slot") as ItemSlot
	if from == null or from == self or from.container == null:
		return null
	return from


func _drag_preview() -> Control:
	# Wrapped in a spacer, because a preview is pinned by its top-left corner and
	# should hang off the cursor's middle.
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = ItemIcons.cached(item_id())
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size = size
	icon.position = -size * 0.5
	icon.modulate = Color(1.0, 1.0, 1.0, 0.85)
	if icon.texture == null:
		icon.modulate = ItemDB.tint(item_id())
	holder.add_child(icon)
	return holder


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, _fill_color())
	if _outlines.is_empty():
		_build_outlines()
	# Outlined in a light pencil, not the dark one: a tile is a well cut into the
	# card, so its edge has to read against violet rather than against paper.
	var ink: Color = PALETTE.accent if (_drop_target or selected) else PALETTE.text_muted
	var weight := 2.4 if (_drop_target or _hovered or selected) else 1.6
	for outline in _outlines:
		draw_polyline(outline, Color(ink, 0.9), weight, true)
	_draw_badge()

	var id := item_id()
	if id.is_empty():
		_draw_placeholder()
		return
	var icon := ItemIcons.cached(id)
	var inner := rect.grow(-ICON_INSET)
	if icon != null:
		draw_texture_rect(icon, inner, false)
	else:
		# Until the icon has been rendered, the item still reads as something
		# rather than as an empty slot.
		draw_rect(inner.grow(-4.0), ItemDB.tint(id))


func _fill_color() -> Color:
	if not interactive:
		# These sit over the world rather than over a card, so they keep enough
		# of the plate to be read against grass, sky or a lit prop. Any thinner
		# and the slot numbers dissolve into whatever is behind them, which is
		# the same reason the HUD's text plates are opaque.
		return Color(PALETTE.paper_card, 0.94) if selected else Color(PALETTE.paper, 0.86)
	# A tile lightens as it is reached for, the opposite way round from the light
	# scheme this replaced but the same signal: the one under the cursor is the
	# one furthest from the card behind it.
	if _drop_target or _hovered:
		return PALETTE.paper_card
	return PALETTE.paper_shade


## Sits over the tile's own corner rather than beside it, so a row of tiles keeps
## its spacing whether the numbers are there or not.
func _draw_badge() -> void:
	if badge.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	# Full-strength rather than muted: the number is the one thing on a HUD tile
	# that has to be read at a glance, and it is the smallest type in the game.
	var color: Color = PALETTE.accent if selected else PALETTE.text_primary
	draw_string(font, Vector2(5.0, 17.0), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)


func _draw_placeholder() -> void:
	if placeholder.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 15
	var baseline := (size.y + float(font_size)) * 0.5 - 1.0
	draw_string(font, Vector2(0.0, baseline), placeholder, HORIZONTAL_ALIGNMENT_CENTER,
		size.x, font_size, Color(PALETTE.text_muted, 0.85))


## Two passes of a wandering rectangle, so a grid of tiles looks pencilled rather
## than printed. Held rather than rebuilt per frame: the wander is meant to sit
## still, not to boil.
func _build_outlines() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(int(size.x), int(size.y), get_instance_id() % 4096))
	var corners := [
		Vector2(1.0, 1.0),
		Vector2(size.x - 1.0, 1.0),
		Vector2(size.x - 1.0, size.y - 1.0),
		Vector2(1.0, size.y - 1.0),
	]
	for pass_index in 2:
		var path := PackedVector2Array()
		for corner_index in corners.size():
			var from: Vector2 = corners[corner_index]
			var to: Vector2 = corners[(corner_index + 1) % corners.size()]
			for step in EDGE_SEGMENTS:
				var point := from.lerp(to, float(step) / float(EDGE_SEGMENTS))
				if step > 0:
					point += Vector2(
						rng.randf_range(-EDGE_WANDER, EDGE_WANDER),
						rng.randf_range(-EDGE_WANDER, EDGE_WANDER))
				path.append(point)
		path.append(path[0])
		_outlines.append(path)
