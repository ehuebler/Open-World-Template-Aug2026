class_name WeaponBar
extends Control

## The row of weapon slots along the bottom of the HUD, and the cell readout for
## whatever is in hand.
##
## The bar shows the same container the wardrobe's weapon rack fills in, so a
## weapon put on the rack is on the bar without anything being copied between the
## two. Tiles are the ordinary inventory tile with its input turned off: they are a
## readout here, not somewhere to rummage.

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

const GAP := 4
## Height of the strip the bar is centred in, above the bottom edge.
const STRIP := 82.0
const BOTTOM_MARGIN := 16.0

var _container: ItemContainer
var _slots: Array[ItemSlot] = []
var _icons: ItemIcons
var _cell_plate: PanelContainer
var _cell_label: Label
var _selected := 0


func _ready() -> void:
	# Across the bottom of the screen, and transparent to the mouse: a left click
	# over the bar is a swing, not a click on a tile.
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_top = -(STRIP + BOTTOM_MARGIN)
	offset_bottom = -BOTTOM_MARGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


## Points the bar at the container it reports, and redraws whenever it changes.
func bind(container: ItemContainer) -> void:
	_container = container
	for index in _slots.size():
		_slots[index].bind(container, index)
	if not container.changed.is_connected(refresh):
		container.changed.connect(refresh)
	refresh()


func select(index: int) -> void:
	_selected = index
	for slot_index in _slots.size():
		_slots[slot_index].selected = slot_index == index
		_slots[slot_index].queue_redraw()


## Shows a line under the bar, or hides the plate when passed nothing: an empty
## plate would read as a blank sticker over the world.
func show_cell(text: String) -> void:
	_cell_label.text = text
	_cell_plate.visible = not text.is_empty()


func refresh() -> void:
	for slot in _slots:
		slot.queue_redraw()


func _build() -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(column)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", GAP)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)
	for index in OnlinePlayer.WEAPON_SLOTS:
		var slot := ItemSlot.new()
		slot.interactive = false
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.badge = str(index + 1)
		row.add_child(slot)
		_slots.append(slot)

	_cell_plate = PanelContainer.new()
	_cell_plate.visible = false
	_cell_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cell_plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_cell_plate)
	PencilSurface.add_to(_cell_plate, PencilSurface.Style.HUD)

	var padding := MarginContainer.new()
	for side in [&"margin_left", &"margin_right"]:
		padding.add_theme_constant_override(side, 8)
	padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cell_plate.add_child(padding)

	_cell_label = Label.new()
	_cell_label.add_theme_font_size_override(&"font_size", 16)
	_cell_label.add_theme_color_override(&"font_color", PALETTE.text_secondary)
	_cell_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	padding.add_child(_cell_label)

	_icons = ItemIcons.new()
	add_child(_icons)
	_icons.icon_ready.connect(_on_icon_ready)
	_icons.request(ItemDB.items_for_slot(ItemDB.WEAPON))
	select(_selected)


func _on_icon_ready(_id: String, _texture: Texture2D) -> void:
	refresh()
