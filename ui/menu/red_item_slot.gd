class_name RedItemSlot
extends Control

## A sharp inventory tile for [GameMenu].
##
## The old [ItemSlot] remains the right tile for the home editor and HUD. This
## one belongs to the red menu: black glass, square red glow, green icon, and a
## compact key badge. It keeps the same container contract and quick-move signal
## so moving an item is still an [ItemContainer] operation rather than UI state.

signal picked(slot: RedItemSlot)
signal quick_move_requested(slot: RedItemSlot)
signal hover_started(slot: RedItemSlot)
signal hover_ended(slot: RedItemSlot)

const EDGE := 70.0
const RED := Color("ef151f")
const GREEN := Color("45df68")
const YELLOW := Color("ffd84a")
const BLACK := Color(0.0, 0.0, 0.0, 0.76)

var container: ItemContainer
var index := 0
var interactive := true
var draggable := true
var selected := false
var equipped := false:
	set(value):
		equipped = value
		queue_redraw()
var placeholder := "X"
var badge := ""

var _hovered := false
var _drop_target := false
var _fallback_glyph: RedMenuGlyph


func _init() -> void:
	custom_minimum_size = Vector2.ONE * EDGE
	size = custom_minimum_size
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# Mesh icons take at least one rendered frame. Keep a readable vector icon in
	# the tile until that texture arrives instead of showing a dark tint block
	# (which made Settler Hair look empty on its first appearance).
	_fallback_glyph = RedMenuGlyph.new()
	_fallback_glyph.name = "ItemFallbackGlyph"
	_fallback_glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fallback_glyph.offset_left = 13.0
	_fallback_glyph.offset_top = 13.0
	_fallback_glyph.offset_right = -13.0
	_fallback_glyph.offset_bottom = -13.0
	_fallback_glyph.visible = false
	add_child(_fallback_glyph)


func set_edge(edge: float) -> void:
	custom_minimum_size = Vector2.ONE * edge
	size = custom_minimum_size
	queue_redraw()


func bind(to_container: ItemContainer, at_index: int) -> void:
	container = to_container
	index = at_index
	queue_redraw()


func item_id() -> String:
	return container.get_item(index) if container != null else ""


func _notification(what: int) -> void:
	match what:
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
		NOTIFICATION_RESIZED:
			queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not interactive:
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed \
			or button.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if button.shift_pressed and not item_id().is_empty():
		quick_move_requested.emit(self)
		return
	picked.emit(self)


func _get_drag_data(_at: Vector2) -> Variant:
	if not interactive or not draggable or item_id().is_empty():
		return null
	set_drag_preview(_drag_preview())
	return {"red_item_slot": self}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	var from := _source_slot(data)
	if from == null or container == null:
		return false
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


func _source_slot(data: Variant) -> RedItemSlot:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var from := (data as Dictionary).get("red_item_slot") as RedItemSlot
	return from if from != null and from != self and from.container != null else null


func _drag_preview() -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var preview := TextureRect.new()
	preview.texture = ItemIcons.cached(item_id())
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.position = -size * 0.42
	preview.size = size * 0.84
	preview.modulate = Color(GREEN, 0.86)
	holder.add_child(preview)
	return holder


func _draw() -> void:
	var outer := Rect2(Vector2.ZERO, size).grow(-3.0)
	# A few translucent strokes read as bloom without a rounded shader or a
	# texture atlas, and retain perfectly sharp corners at every resolution.
	draw_rect(outer.grow(3.0), Color(RED, 0.12), false, 6.0)
	draw_rect(outer.grow(1.5), Color(RED, 0.28), false, 3.0)
	var fill := BLACK
	if equipped:
		fill = Color(0.16, 0.12, 0.01, 0.92)
	if selected and not equipped:
		fill = Color(0.02, 0.17, 0.06, 0.9)
	draw_rect(outer, fill)
	var rim := (
		GREEN if _drop_target
		else YELLOW if equipped
		else GREEN if selected
		else RED
	)
	draw_rect(outer, Color(rim, 0.98), false,
		3.0 if (_hovered or _drop_target or selected or equipped) else 2.0)

	var id := item_id()
	if id.is_empty():
		_sync_fallback("", false)
		_draw_placeholder()
	else:
		var icon := ItemIcons.cached(id)
		var inner := outer.grow(-7.0)
		var has_icon := icon != null and icon.get_width() > 1
		_sync_fallback(id, not has_icon)
		if has_icon:
			draw_texture_rect(icon, inner, false, YELLOW if equipped else GREEN)
		else:
			draw_rect(inner.grow(-4.0), Color(ItemDB.tint(id), 0.22))
	_draw_badge()


func _sync_fallback(id: String, show: bool) -> void:
	if _fallback_glyph == null:
		return
	_fallback_glyph.visible = show
	if not show:
		return
	var glyph := _fallback_for(id)
	if _fallback_glyph.glyph != glyph:
		_fallback_glyph.glyph = glyph
	var ink := YELLOW if equipped else GREEN
	if _fallback_glyph.green_color != ink:
		_fallback_glyph.green_color = ink


func _fallback_for(id: String) -> RedMenuGlyph.Glyph:
	if ItemDB.is_weapon(id):
		return RedMenuGlyph.Glyph.WEAPONS
	if ItemDB.is_item(id):
		return RedMenuGlyph.Glyph.ITEMS
	if ItemDB.is_ability(id):
		return RedMenuGlyph.Glyph.ABILITIES
	match ItemDB.slot_of(id):
		"hat":
			return RedMenuGlyph.Glyph.HAT
		"goggles":
			return RedMenuGlyph.Glyph.GOGGLES
		"long_sleeve":
			return RedMenuGlyph.Glyph.BODY_TUNIC
		"pants":
			return RedMenuGlyph.Glyph.PANTS
		"shoes":
			return RedMenuGlyph.Glyph.BOOTS
	return RedMenuGlyph.Glyph.ITEMS


func _draw_placeholder() -> void:
	if placeholder.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := clampi(roundi(size.y * 0.34), 14, 28)
	var baseline := (size.y + font_size) * 0.5 - 2.0
	draw_string(font, Vector2(0.0, baseline), placeholder,
		HORIZONTAL_ALIGNMENT_CENTER, size.x, font_size, GREEN)


func _draw_badge() -> void:
	if badge.is_empty():
		return
	var font := get_theme_default_font()
	if font == null:
		return
	draw_string(font, Vector2(7.0, 16.0), badge,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, YELLOW if equipped else RED)
