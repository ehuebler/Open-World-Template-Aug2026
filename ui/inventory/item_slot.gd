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

## A plain left click. What that means is the screen's business, not the tile's:
## the character pages use it to choose what the colour chips paint.
signal picked(slot: ItemSlot)
signal quick_move_requested(slot: ItemSlot)
signal hover_started(slot: ItemSlot)
signal hover_ended(slot: ItemSlot)

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

const SIZE := 52.0
## Corner of the drawn tile, and the segments each one is drawn with.
const CORNER := 7.0
const CORNER_STEPS := 4
const ICON_INSET := 4.0
## How far inside the rim the second ring of a selected tile sits. It is what
## makes "worn" read as a box around the item rather than as a slightly brighter
## edge, which at 1.6 px against a dark tile is not a difference anyone sees.
const RING_INSET := 3.5

var container: ItemContainer
var index := 0
## HUD tiles are drawn but take no input: the weapon bar reports what is in hand
## rather than being rummaged in.
var interactive := true
## Off for a tile that is a **view** of an item rather than a place one is kept —
## the character editor's catalogue is the case. Dragging one of those would swap
## containers and put a worn garment into a list that is meant to hold every
## garment; clicking and hovering still work, which is all a catalogue needs.
var draggable := true
## Shown when the slot is empty, naming the body part an equipment slot covers.
var placeholder := ""
## Drawn small in the top corner: the key that reaches this slot.
var badge := ""
## Marks the weapon bar's current slot, which is drawn heavier and in accent ink.
var selected := false

var _hovered := false
var _drop_target := false
## The rounded outline, rebuilt only when the tile is resized.
var _outline := PackedVector2Array()


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = custom_minimum_size


## A tile off the standard [constant SIZE], which the character editor's
## catalogue is. Everything drawn here is measured off `size`, so the icon, the
## border's wander and the badge all follow.
func set_edge(edge: float) -> void:
	custom_minimum_size = Vector2(edge, edge)
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
			_outline.clear()
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
		return
	# Not accepted, because a press is also where a drag begins and swallowing it
	# would leave the tiles unable to be moved. Selecting the tile a drag starts
	# from is harmless: it is the one the player is pointing at either way.
	picked.emit(self)


func _get_drag_data(_at: Vector2) -> Variant:
	if not interactive or not draggable or item_id().is_empty():
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
	if not interactive or not draggable or typeof(data) != TYPE_DICTIONARY:
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
	if _outline.is_empty():
		_outline = _rounded(rect.grow(-1.0), CORNER)
	draw_colored_polygon(_outline, _fill_color())
	# A tile is a well cut into the pane, so its rim has to read against the pane
	# rather than against the tile.
	var ink: Color = PALETTE.accent if (_drop_target or selected) else PALETTE.text_muted
	var weight := 2.4 if (_drop_target or _hovered or selected) else 1.4
	draw_polyline(_outline, Color(ink, 0.9), weight, true)
	if selected or _drop_target:
		# The box that says this item is on the body. Two rings rather than one
		# heavier ring: a grid of tiles is read at a glance and a doubled edge is
		# the only weight difference that survives being 44 px across.
		draw_polyline(_rounded(rect.grow(-RING_INSET), CORNER - 2.0),
			Color(PALETTE.accent, 0.55), 1.6, true)
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
	draw_string(font, Vector2(5.0, 15.0), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)


func _draw_placeholder() -> void:
	if placeholder.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 12
	var baseline := (size.y + float(font_size)) * 0.5 - 1.0
	draw_string(font, Vector2(0.0, baseline), placeholder, HORIZONTAL_ALIGNMENT_CENTER,
		size.x, font_size, Color(PALETTE.text_muted, 0.85))


## A closed rounded rectangle, corners first. Returned as a path rather than
## drawn, because the fill and the rim are the same shape and a tile whose fill
## and outline disagree about its corners shows a bright pip at each one.
func _rounded(rect: Rect2, radius: float) -> PackedVector2Array:
	var limit := clampf(radius, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
	var centres := [
		rect.position + Vector2(limit, limit),
		rect.position + Vector2(rect.size.x - limit, limit),
		rect.end - Vector2(limit, limit),
		rect.position + Vector2(limit, rect.size.y - limit),
	]
	var path := PackedVector2Array()
	for corner in 4:
		# Anticlockwise from the top-left corner's own quarter turn.
		var from := PI + float(corner) * TAU * 0.25
		for step in CORNER_STEPS + 1:
			var angle := from + TAU * 0.25 * float(step) / float(CORNER_STEPS)
			path.append(centres[corner] + Vector2(cos(angle), sin(angle)) * limit)
	path.append(path[0])
	return path
