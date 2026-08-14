class_name WeaponBar
extends Control

## The five logical action slots along the bottom of the HUD, in input order:
## LMB, RMB, 1, 2, 3. The first two bind the private ability container and the
## numbered three bind the hotbar.
##
## Tiles are ordinary inventory tiles with input turned off: they are a readout
## here, not somewhere to rummage.

const GAP := 4
## Height of the strip the bar is centred in, above the bottom edge.
const STRIP := 118.0
const BOTTOM_MARGIN := 16.0

var _abilities: ItemContainer
var _hotbar: ItemContainer
var _slots: Array[ItemSlot] = []
var _ability_slots: Array[ItemSlot] = []
var _hotbar_slots: Array[ItemSlot] = []
var _ability_controller: AbilityController
var _icons: ItemIcons
var _column: VBoxContainer
var _cell_plate: PanelContainer
var _cell_label: Label
var _selected := 0
var _holstered := true


func _init() -> void:
	name = "WeaponBar"


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
	set_process(_ability_controller != null)


## Compatibility binding for callers that only know about the old weapon
## container. New code should bind both halves with [method bind_loadout].
func bind(container: ItemContainer) -> void:
	bind_loadout(null, container)


func bind_loadout(ability_container: ItemContainer, hotbar_container: ItemContainer) -> void:
	for old_container: ItemContainer in [_abilities, _hotbar]:
		if old_container != null and old_container.changed.is_connected(refresh):
			old_container.changed.disconnect(refresh)
	_abilities = ability_container
	_hotbar = hotbar_container
	_bind_slots()
	for container: ItemContainer in [_abilities, _hotbar]:
		if container != null and not container.changed.is_connected(refresh):
			container.changed.connect(refresh)
	refresh()


## Supplies the live runtime instances behind the two ability tiles. Containers
## know which icon belongs in a slot; the controller knows how far that ability
## is through its current cooldown.
func bind_ability_controller(controller: AbilityController) -> void:
	_ability_controller = controller
	set_process(_ability_controller != null)
	_update_cooldowns()


## Compatibility: index is a numbered slot, not an index into the five drawn
## tiles. Selecting a numbered slot takes the HUD out of ability mode.
func select(index: int) -> void:
	_selected = index
	_holstered = false
	_update_selection()


## Empty hands make both mouse ability slots active. There is nothing in them yet,
## but showing the mode prevents F from looking like it selected an invisible slot.
func holster() -> void:
	_holstered = true
	_update_selection()


## Shows a line under the bar, or hides the plate when passed nothing: an empty
## plate would read as a blank sticker over the world.
func show_cell(text: String) -> void:
	_cell_label.text = text
	_cell_plate.visible = not text.is_empty()


## CombatHud adds the shield and health pair here so both bars stay exactly
## centred beneath the five inventory boxes at every resolution.
func add_vitals(control: Control) -> void:
	if _column == null:
		call_deferred(&"add_vitals", control)
		return
	if control.get_parent() != null:
		control.reparent(_column)
	else:
		_column.add_child(control)


func refresh() -> void:
	for slot in _slots:
		slot.queue_redraw()
	_update_cooldowns()


func _process(_delta: float) -> void:
	_update_cooldowns()


func _update_cooldowns() -> void:
	for index in _ability_slots.size():
		var fill := 1.0
		var active := false
		var ability := _ability_controller.ability_in(index) \
			if _ability_controller != null else null
		if ability != null:
			var duration := maxf(ability.cooldown(), 0.0)
			var left := maxf(ability.cooldown_left(), 0.0)
			active = duration > 0.0 and left > 0.0
			if active:
				fill = 1.0 - clampf(left / duration, 0.0, 1.0)
		_ability_slots[index].set_cooldown(fill, active)


func _build() -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	_column = VBoxContainer.new()
	_column.name = "HotbarStack"
	_column.add_theme_constant_override(&"separation", 5)
	_column.alignment = BoxContainer.ALIGNMENT_CENTER
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(_column)

	_cell_plate = PanelContainer.new()
	_cell_plate.visible = false
	_cell_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cell_plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_column.add_child(_cell_plate)
	RedHudTheme.panel(_cell_plate, 0.0)

	var padding := MarginContainer.new()
	for side in [&"margin_left", &"margin_right"]:
		padding.add_theme_constant_override(side, 7)
	padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cell_plate.add_child(padding)

	_cell_label = Label.new()
	RedHudTheme.label(_cell_label, 9)
	_cell_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	padding.add_child(_cell_label)

	var row := HBoxContainer.new()
	row.name = "HotbarSlots"
	row.add_theme_constant_override(&"separation", GAP)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(row)
	for index in OnlinePlayer.ABILITY_SLOTS:
		var slot := ItemSlot.new()
		slot.interactive = false
		slot.hud_style = true
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.badge = "LMB" if index == 0 else "RMB"
		row.add_child(slot)
		_slots.append(slot)
		_ability_slots.append(slot)
	for index in OnlinePlayer.HOTBAR_SLOTS:
		var slot := ItemSlot.new()
		slot.interactive = false
		slot.hud_style = true
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.badge = str(index + 1)
		row.add_child(slot)
		_slots.append(slot)
		_hotbar_slots.append(slot)

	_icons = ItemIcons.new()
	add_child(_icons)
	_icons.icon_ready.connect(_on_icon_ready)
	var icon_ids: Array = []
	for item_id: String in ItemDB.hotbar_ids():
		icon_ids.append(item_id)
	for ability_id: String in ItemDB.ability_ids():
		icon_ids.append(ability_id)
	_icons.request(icon_ids)
	_bind_slots()
	_update_selection()


func _bind_slots() -> void:
	for index in _ability_slots.size():
		_ability_slots[index].bind(_abilities, index)
	for index in _hotbar_slots.size():
		_hotbar_slots[index].bind(_hotbar, index)


func _update_selection() -> void:
	for slot in _ability_slots:
		slot.selected = _holstered
		slot.queue_redraw()
	for index in _hotbar_slots.size():
		_hotbar_slots[index].selected = not _holstered and index == _selected
		_hotbar_slots[index].queue_redraw()


func _on_icon_ready(_id: String, _texture: Texture2D) -> void:
	refresh()
