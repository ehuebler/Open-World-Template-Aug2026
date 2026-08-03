class_name InventoryPage
extends Control

## Who you are and what you are carrying: your name, a live model you can spin,
## what you are wearing, your stats, your weapon bar, your pockets, and a strip
## along the bottom for recolouring any of it.
##
## This is the Inventory tab of [GameMenu] **and** the home screen's character
## editor, and that is deliberate rather than convenient. Dressing a character is
## dressing a character; a second screen for doing it before the game starts would
## be a second place for the tiles, the preview, the filters and the quick-move
## rules to drift out of step. [method configure] takes an `editing` flag, and what
## it changes is small: the name becomes typeable, the pockets become the rail of
## garments that fit this body, and there is no weapon bar to show because nothing
## has been picked up yet.
##
## The page holds no item state. Every tile points at a slot of an [ItemContainer],
## and moving an item is a change to a container, which reports back and has the
## tiles and the model redrawn. Equipping is not special-cased: dropping a hat in
## the head slot is an ordinary move, and the player is the one listening to its
## equipment container.

## A garment or the skin was recoloured. Raised rather than acted on: in game the
## player owns the body being painted, and on the home screen the look being saved.
signal tint_picked(target: String, colour: Color)
## The name field was committed to. Same reasoning — the name belongs to whoever
## opened the page.
signal name_entered(value: String)

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const GAP := 6
## Columns of the pockets grid — wide and shallow rather than square, and this is
## the value the whole page is sized around. The card has width going spare and none
## of its height, because the figure, the equipment column and the colour strip
## between them spend all of it, so every row saved here is what keeps the strip
## above the fold. Times its rows this has to come to the backpack's size, or the
## last row comes out ragged.
const COLUMNS := 18
## Columns of the garment rail the character editor shows instead of pockets.
const RAIL_COLUMNS := 8
## Height is the axis that runs out on this page: the figure, the pockets and the
## colour strip all want it and the card has to fit inside the window. Every value
## here that looks mean is paying for the strip staying above the fold.
const PREVIEW_SIZE := Vector2(176.0, 236.0)
## The preview is rendered several times larger than it is shown and scaled back
## down. The outline pass measures its strokes in pixels, so drawing straight into
## a panel this size would ring the model in strokes as thick as its limbs.
const PREVIEW_SUPERSAMPLE := 3
const SPIN_PER_PIXEL := 0.01
const TOOLTIP_OFFSET := Vector2(18.0, 12.0)
const TOOLTIP_WIDTH := 330.0
## The tint key for the body rather than for a garment, as [CharacterDB], the
## player and the spawn metadata all spell it. Its button says "Skin", because
## "Body" is already the equipment column's label for the torso.
const TINT_BODY := "body"
## Size of a colour chip. Chips are spaced wider than they are big: a drawn surface
## reaches [constant PencilSurface.BLEED] past the control it backs, which on
## something this small is most of the gap.
const CHIP := 26.0
const CHIP_GAP := 14
## What a tint can be set to. Skin tones first, then dyes.
const SWATCHES := [
	Color(0.94, 0.90, 0.84), Color(0.85, 0.70, 0.55), Color(0.62, 0.44, 0.32),
	Color(0.34, 0.24, 0.19), Color(0.86, 0.24, 0.20), Color(0.94, 0.68, 0.22),
	Color(0.32, 0.62, 0.38), Color(0.24, 0.46, 0.74), Color(0.52, 0.34, 0.66),
	Color(0.16, 0.16, 0.19),
]

var _equipment: ItemContainer
var _weapons: ItemContainer
var _pockets: ItemContainer
var _stats: PlayerStats
var _body_id := CharacterDB.DEFAULT_BODY
var _player_name := "Player"
var _editing := false

var _slots: Array[ItemSlot] = []
var _icons: ItemIcons
var _tooltip: PanelContainer
var _tooltip_title: Label
var _tooltip_body: Label
var _hovered: ItemSlot

var _preview_character: Node3D
var _preview_holder: TextureRect
var _preview_viewport: SubViewport
var _preview_camera: Camera3D
var _preview_pivot: Node3D
var _spin := 0.0
var _dragging := false
## Body slot to item id, so the model is only rebuilt where it changed.
var _preview_worn: Dictionary = {}

## Everything laid out, as against the tooltip and the icon driver, which are also
## children of the page but are not part of its layout.
var _column: VBoxContainer
var _stat_rows: VBoxContainer
var _tint_target := TINT_BODY
var _tints: Dictionary = {}
var _tint_targets: HBoxContainer
var _tint_caption: Label


## Called before the page enters the tree: it is built against these. `stats` may
## be null, which is what the character editor passes — there is nobody to have
## stats yet. `editing` makes the name typeable and turns the pockets into the rail
## of garments that fit this body.
func configure(equipment: ItemContainer, weapons: ItemContainer, pockets: ItemContainer,
		stats: PlayerStats = null, body_id := CharacterDB.DEFAULT_BODY,
		editing := false) -> void:
	_equipment = equipment
	_weapons = weapons
	_pockets = pockets
	_stats = stats
	_body_id = CharacterDB.sanitize_body(body_id)
	_editing = editing


func set_player_name(value: String) -> void:
	_player_name = value


## Slot name (or [constant TINT_BODY]) to HTML colour, as [CharacterDB] stores them.
func set_tints(tints: Dictionary) -> void:
	_tints = tints.duplicate(true)
	_paint_model()
	_update_tint_caption()


## Swaps the model for another body. The caller has already decided what happens to
## the garments that were on the old one.
func set_body(body_id: String) -> void:
	body_id = CharacterDB.sanitize_body(body_id)
	if body_id == _body_id:
		return
	_body_id = body_id
	if is_instance_valid(_preview_character):
		_preview_character.queue_free()
	_preview_worn.clear()
	_preview_character = _new_model()
	_preview_pivot.add_child(_preview_character)
	_frame_model()
	refresh()
	_paint_model()


## The containers the page was configured against, so a harness can move an item
## without a mouse.
func worn_slots() -> ItemContainer:
	return _equipment


func spare_slots() -> ItemContainer:
	return _pockets


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build()
	# Late, because a ViewportTexture can only resolve the path to its viewport
	# once both ends are in the tree.
	_preview_holder.texture = _preview_viewport.get_texture()
	refresh()
	_paint_model()


func _process(_delta: float) -> void:
	if _tooltip.visible:
		_place_tooltip()


## A plain [Control] does not take a size from its children, and this one is put
## inside a card that has to fit it — the character editor's card is sized by its
## contents. So the page reports the layout column's own minimum and leaves the
## tooltip out of it, which is right for a second reason: the tooltip is positioned
## against the mouse and would otherwise widen the card by its own width.
func _get_minimum_size() -> Vector2:
	return _column.get_combined_minimum_size() if _column != null else Vector2.ZERO


# --- Construction -----------------------------------------------------------

## The shape of the page, top to bottom: a name and a wide reserve above; the
## figure, what it is wearing, the stats and the weapon bar in the middle, with a
## tall reserve down the right; the pockets and the colour strip below.
##
## The two reserves are empty on purpose and captioned as such. They are the room
## the layout was designed with, and leaving them visible is what stops the next
## panel that wants a home from being wedged into the space between two others.
func _build() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override(&"separation", 10)
	add_child(column)
	_column = column

	var top := HBoxContainer.new()
	top.add_theme_constant_override(&"separation", 12)
	top.add_child(_name_plate())
	top.add_child(_reserve("", 0.0, 38.0))
	column.add_child(top)

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override(&"separation", 12)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(middle)

	var left := VBoxContainer.new()
	left.add_theme_constant_override(&"separation", 10)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(left)
	left.add_child(_figure_row())
	left.add_child(_pockets_block())
	left.add_child(_tint_strip())

	middle.add_child(_reserve("Reserved", 168.0, 0.0))

	_build_tooltip()

	_icons = ItemIcons.new()
	add_child(_icons)
	_icons.icon_ready.connect(_on_icon_ready)
	_icons.request(ItemDB.ITEMS.keys())

	for container in [_equipment, _weapons, _pockets]:
		if container != null:
			(container as ItemContainer).changed.connect(refresh)
	if _stats != null:
		_stats.changed.connect(func(_id: StringName, _value: float) -> void: _fill_stats())
	update_minimum_size()


## The name, top left. Typeable in the editor, where naming yourself is part of
## making a character; a plate in game, where it is who you already are.
func _name_plate() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(260.0, 0.0)
	PencilSurface.add_to(panel, PencilSurface.Style.INPUT if _editing \
		else PencilSurface.Style.ROW)
	var padding := _padded(10)
	panel.add_child(padding)
	if not _editing:
		var label := Label.new()
		label.text = _player_name
		label.add_theme_font_size_override(&"font_size", 24)
		label.add_theme_color_override(&"font_color", PALETTE.text_primary)
		padding.add_child(label)
		return panel

	var field := LineEdit.new()
	field.text = _player_name
	field.placeholder_text = "Your name"
	field.max_length = 24
	field.add_theme_font_size_override(&"font_size", 24)
	field.text_submitted.connect(func(value: String) -> void: name_entered.emit(value))
	field.focus_exited.connect(func() -> void: name_entered.emit(field.text))
	padding.add_child(field)
	return panel


## Figure, what it is wearing, a narrow reserve, then the stats with the weapon bar
## under them.
func _figure_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	row.add_child(_preview())
	row.add_child(_worn_column())
	row.add_child(_reserve("", 42.0, 0.0))

	var right := VBoxContainer.new()
	right.add_theme_constant_override(&"separation", 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(right)
	# Nothing has stats or weapons before the world starts, so the editor gets the
	# room as room rather than as two wells explaining what they would hold.
	if _editing:
		right.add_child(_reserve("Reserved", 0.0, 0.0))
		return row
	right.add_child(_stats_block())
	right.add_child(_weapon_block())
	return row


func _worn_column() -> Control:
	var worn := VBoxContainer.new()
	worn.add_theme_constant_override(&"separation", GAP)
	for index in _equipment.size():
		var slot := _new_slot(_equipment, index)
		slot.placeholder = String(ItemDB.SLOT_LABELS.get(_equipment.filter_of(index), ""))
		worn.add_child(slot)
	return worn


## The weapon slots, in the same order and with the same numbers as the bar on the
## HUD, because they are the same container.
func _weapon_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override(&"separation", GAP)
	var slots := HBoxContainer.new()
	slots.add_theme_constant_override(&"separation", GAP)
	for index in _weapons.size():
		var slot := _new_slot(_weapons, index)
		slot.badge = str(index + 1)
		slots.add_child(slot)
	block.add_child(slots)
	block.add_child(_hint("1 - 5 or the mouse wheel to draw"))
	return block


func _pockets_block() -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override(&"separation", GAP)
	block.add_child(_caption("Apparel" if _editing else "Inventory"))
	var grid := GridContainer.new()
	grid.columns = RAIL_COLUMNS if _editing else COLUMNS
	grid.add_theme_constant_override(&"h_separation", GAP)
	grid.add_theme_constant_override(&"v_separation", GAP)
	for index in _pockets.size():
		grid.add_child(_new_slot(_pockets, index))
	block.add_child(grid)
	return block


# --- Stats ------------------------------------------------------------------

func _stats_block() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	PencilSurface.add_to(panel, PencilSurface.Style.ROW)
	var padding := _padded(16)
	panel.add_child(padding)
	_stat_rows = VBoxContainer.new()
	_stat_rows.add_theme_constant_override(&"separation", 8)
	padding.add_child(_stat_rows)
	_fill_stats()
	return panel


## One row per entry in [constant PlayerStats.STATS], so a stat added to that table
## shows up here with no edit. The editor has no stats to show and says so rather
## than drawing an empty well.
func _fill_stats() -> void:
	for child in _stat_rows.get_children():
		child.queue_free()
	_stat_rows.add_child(_caption("Stats"))
	if _stats == null:
		_stat_rows.add_child(_hint("Stats begin once you are in the world."))
		return
	for id in PlayerStats.ids():
		_stat_rows.add_child(_stat_row(_stats.row(StringName(id))))


func _stat_row(row: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)

	var line := HBoxContainer.new()
	var title := Label.new()
	title.text = String(row["title"])
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override(&"font_size", 17)
	title.add_theme_color_override(&"font_color", PALETTE.text_secondary)
	line.add_child(title)

	var value := Label.new()
	value.text = String(row["text"])
	value.add_theme_font_size_override(&"font_size", 17)
	value.add_theme_color_override(&"font_color", PALETTE.text_primary)
	line.add_child(value)
	box.add_child(line)
	box.add_child(_bar(float(row["share"])))
	return box


## A filled share of a track, drawn rather than themed: a ProgressBar would need a
## pair of styleboxes, and `main_theme.tres` leaves styleboxes empty on purpose so
## that the pencil shader reaches a control's edge.
func _bar(share: float) -> Control:
	var track := Control.new()
	track.custom_minimum_size = Vector2(0.0, 7.0)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var filled := clampf(share, 0.0, 1.0)
	track.draw.connect(func() -> void:
		track.draw_rect(Rect2(Vector2.ZERO, track.size), PALETTE.paper_shade)
		track.draw_rect(Rect2(Vector2.ZERO,
			Vector2(track.size.x * filled, track.size.y)), PALETTE.secondary)
	)
	return track


# --- The colour strip -------------------------------------------------------

## Along the bottom, where a Drop button would otherwise be. What it recolours is
## whatever is worn: the skin, plus one target per garment actually on the body, so
## there is never a button for tinting a hat you are not wearing.
func _tint_strip() -> Control:
	var panel := PanelContainer.new()
	PencilSurface.add_to(panel, PencilSurface.Style.ROW)
	var padding := _padded(14)
	panel.add_child(padding)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 14)
	padding.add_child(row)

	var heading := VBoxContainer.new()
	heading.add_theme_constant_override(&"separation", 2)
	heading.add_child(_caption("Colour"))
	_tint_caption = _hint("")
	heading.add_child(_tint_caption)
	row.add_child(heading)

	_tint_targets = HBoxContainer.new()
	_tint_targets.add_theme_constant_override(&"separation", GAP)
	_tint_targets.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_tint_targets)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var chips := HBoxContainer.new()
	chips.add_theme_constant_override(&"separation", CHIP_GAP)
	chips.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for swatch: Color in SWATCHES:
		chips.add_child(_chip(swatch))
	row.add_child(chips)
	_fill_tint_targets()
	return panel


func _chip(swatch: Color) -> Control:
	var chip := Button.new()
	chip.custom_minimum_size = Vector2(CHIP, CHIP)
	# The chip is a control filled with the colour it offers, so the paper is
	# repainted rather than the whole button modulated: modulate would take the
	# drawn strokes and the shading down with it, leaving ten pale rectangles that
	# all read as the same washed-out celadon.
	var surface := PencilSurface.add_to(chip, PencilSurface.Style.BUTTON)
	(surface.material as ShaderMaterial).set_shader_parameter(&"paper_color", swatch)
	var colour := swatch
	chip.pressed.connect(func() -> void: tint_picked.emit(_tint_target, colour))
	return chip


func _fill_tint_targets() -> void:
	for child in _tint_targets.get_children():
		child.queue_free()
	var targets: Array[String] = [TINT_BODY]
	for index in _equipment.size():
		if not _equipment.get_item(index).is_empty():
			targets.append(_equipment.filter_of(index))
	# A target that has just been taken off should not stay selected, or the chips
	# would silently paint a garment nobody can see.
	if not targets.has(_tint_target):
		_tint_target = TINT_BODY
	for target in targets:
		var button := MenuWidgets.button(
			"Skin" if target == TINT_BODY \
				else String(ItemDB.SLOT_LABELS.get(target, target)),
			PencilSurface.Style.PRIMARY if target == _tint_target \
				else PencilSurface.Style.BUTTON)
		button.add_theme_font_size_override(&"font_size", 15)
		var chosen := target
		button.pressed.connect(func() -> void:
			_tint_target = chosen
			_fill_tint_targets()
		)
		_tint_targets.add_child(button)
	_update_tint_caption()


func _update_tint_caption() -> void:
	if _tint_caption == null:
		return
	if _tint_target == TINT_BODY:
		_tint_caption.text = "the skin"
		return
	var worn := _equipped_in(_tint_target)
	_tint_caption.text = ItemDB.title(worn) if not worn.is_empty() else "nothing worn there"


## Read off the filters rather than by position, so this does not depend on the
## equipment container being in SLOT_ORDER.
func _equipped_in(slot: String) -> String:
	for index in _equipment.size():
		if _equipment.filter_of(index) == slot:
			return _equipment.get_item(index)
	return ""


# --- The figure -------------------------------------------------------------

## A live model wearing whatever the equipment container holds, on a pivot so it
## can be turned by dragging it. The pivot rather than the model itself, because
## the model is replaced whenever the body changes and the spin should survive that.
func _preview() -> Control:
	var holder := TextureRect.new()
	holder.custom_minimum_size = PREVIEW_SIZE
	# Otherwise the panel would grow to the full size of the supersampled render.
	holder.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	holder.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	holder.mouse_filter = Control.MOUSE_FILTER_STOP
	holder.gui_input.connect(_on_preview_input)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(PREVIEW_SIZE * PREVIEW_SUPERSAMPLE)
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	holder.add_child(viewport)

	# No environment of its own: the transparent target already clears to nothing,
	# and the pencil material ignores ambient light, so the only thing an
	# Environment here could do is escape into the world's own lighting. That same
	# blindness to ambient is why the model needs a lamp to hatch against.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-34.0, 152.0, 0.0)
	key.light_energy = 1.1
	viewport.add_child(key)

	_preview_pivot = Node3D.new()
	viewport.add_child(_preview_pivot)
	_preview_character = _new_model()
	_preview_pivot.add_child(_preview_character)

	_preview_camera = Camera3D.new()
	_preview_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	viewport.add_child(_preview_camera)
	_preview_holder = holder
	_preview_viewport = viewport
	_frame_model()
	return holder


func _on_preview_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_spin -= event.relative.x * SPIN_PER_PIXEL
		if is_instance_valid(_preview_pivot):
			_preview_pivot.basis = Basis(Vector3.UP, _spin)


func _new_model() -> Node3D:
	var packed := CharacterDB.scene(_body_id)
	var model: Node3D = packed.instantiate() if packed != null else Node3D.new()
	SurfaceSkin.apply(model)
	_play_idle(model)
	return model


## Framed on the body's authored height with headroom for a hat, from slightly
## off-centre so the pose reads as three-dimensional. Re-measured whenever the body
## changes, since two bodies are not the same height.
func _frame_model() -> void:
	var height := CharacterDB.height(_body_id)
	_preview_camera.size = height * 1.28
	var eye := Vector3(-0.55, height * 0.54, -1.9)
	var target := Vector3(0.0, height * 0.5, 0.0)
	_preview_camera.transform = Transform3D(Basis.looking_at(target - eye, Vector3.UP), eye)


func _play_idle(character: Node) -> void:
	var animator: AnimationPlayer = null
	for node in character.find_children("*", "AnimationPlayer", true, false):
		animator = node as AnimationPlayer
		break
	if animator == null or not animator.has_animation("Idle"):
		return
	animator.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
	animator.play("Idle")


# --- Small parts ------------------------------------------------------------

func _new_slot(container: ItemContainer, index: int) -> ItemSlot:
	var slot := ItemSlot.new()
	slot.bind(container, index)
	slot.quick_move_requested.connect(_on_quick_move)
	slot.hover_started.connect(_on_hover_started)
	slot.hover_ended.connect(_on_hover_ended)
	_slots.append(slot)
	return slot


## Room the layout was designed with and nothing has claimed yet. Drawn as a
## recessed well so it reads as reserved rather than as a gap something failed to
## fill; give it a caption and it names itself.
func _reserve(text: String, width: float, height: float) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, height)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if width <= 0.0:
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if height <= 0.0:
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	PencilSurface.add_to(panel, PencilSurface.Style.ROW)
	if not text.is_empty():
		var padding := _padded(10)
		panel.add_child(padding)
		var label := _hint(text)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		padding.add_child(label)
	return panel


## Margins are theme constants rather than properties, so they cannot be set
## through the inspector-style names.
func _padded(inset: int) -> MarginContainer:
	var margin := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, inset)
	return margin


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", 17)
	label.add_theme_color_override(&"font_color", PALETTE.text_secondary)
	return label


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", 14)
	label.add_theme_color_override(&"font_color", PALETTE.text_muted)
	return label


func _build_tooltip() -> void:
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.custom_minimum_size = Vector2(TOOLTIP_WIDTH, 0.0)
	add_child(_tooltip)
	PencilSurface.add_to(_tooltip, PencilSurface.Style.ROW)

	var padding := _padded(10)
	_tooltip.add_child(padding)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 2)
	padding.add_child(column)

	_tooltip_title = Label.new()
	_tooltip_title.add_theme_font_size_override(&"font_size", 21)
	_tooltip_title.add_theme_color_override(&"font_color", PALETTE.text_primary)
	column.add_child(_tooltip_title)

	_tooltip_body = Label.new()
	_tooltip_body.add_theme_font_size_override(&"font_size", 17)
	_tooltip_body.add_theme_color_override(&"font_color", PALETTE.text_secondary)
	_tooltip_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tooltip_body.custom_minimum_size = Vector2(TOOLTIP_WIDTH - 20.0, 0.0)
	column.add_child(_tooltip_body)


# --- Reacting ---------------------------------------------------------------

## Everything that depends on a container, in one call. Public because the owner
## changes containers behind the page's back — the admin tab fills the backpack,
## and the home screen restocks the rail when the body changes.
func refresh() -> void:
	for slot in _slots:
		slot.queue_redraw()
	if _hovered != null:
		_show_tooltip(_hovered)
	_refresh_preview()
	if _tint_targets != null:
		_fill_tint_targets()
	if _stat_rows != null:
		_fill_stats()


## Puts the model in step with the equipment container, garment by garment, so an
## unchanged shirt is not reloaded because a hat came off.
func _refresh_preview() -> void:
	if not is_instance_valid(_preview_character):
		return
	var dressing_changed := false
	for index in _equipment.size():
		var body_slot := _equipment.filter_of(index)
		var id := _equipment.get_item(index)
		if _preview_worn.get(body_slot, "") == id:
			continue
		_preview_worn[body_slot] = id
		dressing_changed = true
		if id.is_empty():
			Wardrobe.unequip(_preview_character, body_slot)
			continue
		var garment := Wardrobe.equip(_preview_character, body_slot, ItemDB.scene_path(id))
		if garment != null:
			SurfaceSkin.paint(garment)
	if dressing_changed and not _tints.is_empty():
		_paint_model()


## A tint multiplies the albedo it finds, so picking three colours in a row would
## otherwise leave the garment the product of all three. Every tint is laid over a
## freshly painted model instead of over the last one.
##
## Materials are derived per target rather than across the whole model, which does
## two things: a material the body and a garment happened to share cannot carry
## one's tint onto the other, and each material is tinted exactly once however many
## meshes are wearing it.
func _paint_model() -> void:
	if not is_instance_valid(_preview_character):
		return
	var groups: Dictionary = {}
	for node in _preview_character.find_children("*", "MeshInstance3D", true, false):
		var worn_as := String(node.name)
		var target := worn_as.trim_prefix(Wardrobe.NODE_PREFIX) \
			if worn_as.begins_with(Wardrobe.NODE_PREFIX) else TINT_BODY
		groups.get_or_add(target, []).append(node)
	for target: String in groups:
		var derived: Dictionary = {}
		for mesh_instance: MeshInstance3D in groups[target]:
			SurfaceSkin.paint(mesh_instance, derived)
		if not _tints.has(target):
			continue
		var colour := Color.html(str(_tints[target]))
		for material: Variant in derived.values():
			SurfaceSkin.tint_material(material as ShaderMaterial, colour)


## Shift-clicking sends an item where it most obviously wants to go: onto the body
## or the rack if it can be equipped, and off either into your pockets.
func _on_quick_move(slot: ItemSlot) -> void:
	var id := slot.item_id()
	if id.is_empty():
		return
	var from := slot.container
	var equipped: Array[ItemContainer] = [_equipment, _weapons]
	if equipped.has(from):
		ItemContainer.quick_move(from, slot.index, _pockets)
		return
	for to in equipped:
		if to.first_accepting(id) >= 0:
			ItemContainer.quick_move(from, slot.index, to)
			return


func _on_hover_started(slot: ItemSlot) -> void:
	_hovered = slot
	_show_tooltip(slot)


func _on_hover_ended(slot: ItemSlot) -> void:
	if _hovered != slot:
		return
	_hovered = null
	_tooltip.visible = false


func _show_tooltip(slot: ItemSlot) -> void:
	var id := slot.item_id()
	if id.is_empty():
		_tooltip.visible = false
		return
	_tooltip_title.text = ItemDB.title(id)
	_tooltip_body.text = ItemDB.description(id)
	_tooltip.visible = true
	_tooltip.reset_size()
	_place_tooltip()


func _place_tooltip() -> void:
	var wanted := get_global_mouse_position() + TOOLTIP_OFFSET
	var limit := size - _tooltip.size - Vector2(8.0, 8.0)
	_tooltip.global_position = Vector2(minf(wanted.x, limit.x), minf(wanted.y, limit.y)).maxf(8.0)


func _on_icon_ready(_id: String, _texture: Texture2D) -> void:
	for slot in _slots:
		slot.queue_redraw()
