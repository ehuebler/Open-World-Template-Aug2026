class_name RedHeroPage
extends VBoxContainer

## Read-only in-game character overview for the red menu.
##
## Call [method configure] before adding the page to the tree. Apparel is the one
## deliberate exception to the read-only presentation: shift-clicking a worn tile
## uses [method ItemContainer.quick_move] to stow it in the backpack.

const RED := Color("ef151f")
const RED_BRIGHT := Color("ff3445")
const RED_TEXT := Color("ff9ca4")
const RED_MUTED := Color("b94a53")
const GREEN := Color("45df68")
const YELLOW := Color("ffd84a")
const BLACK_42 := Color(0.0, 0.0, 0.0, 0.42)
const BLACK_68 := Color(0.0, 0.0, 0.0, 0.68)
const BLACK_86 := Color(0.0, 0.0, 0.0, 0.86)

const NARROW_WIDTH := 900.0
const WIDE_APPAREL_EDGE := 72.0
const NARROW_APPAREL_EDGE := 54.0
const WIDE_HOTBAR_EDGE := 72.0
const NARROW_HOTBAR_EDGE := 54.0

const HOTBAR_BADGES := ["LMB", "RMB", "1", "2", "3"]
const APPAREL_GLYPHS := [
	RedMenuGlyph.Glyph.HAT,
	RedMenuGlyph.Glyph.GOGGLES,
	RedMenuGlyph.Glyph.BODY_TUNIC,
	RedMenuGlyph.Glyph.PANTS,
	RedMenuGlyph.Glyph.BOOTS,
]

var _player: OnlinePlayer
var _equipment: ItemContainer
var _weapons: ItemContainer
var _abilities: ItemContainer
var _backpack: ItemContainer
var _stats: PlayerStats

var _built := false
var _sources_connected := false
var _narrow := false
var _responsive_initialized := false
var _selected_apparel := -1
var _stats_open := false

var _main_grid: GridContainer
var _stats_frame: PanelContainer
var _stats_rows: VBoxContainer
var _character_block: VBoxContainer
var _loadout_column: VBoxContainer
var _hero_name: Label
var _preview: RedCharacterPreview
var _stats_toggle: Button
var _apparel_frame: PanelContainer
var _apparel_grid: GridContainer
var _apparel_hint: Label
var _hotbar_frame: PanelContainer
var _hotbar_row: HBoxContainer
var _icons: ItemIcons

var _apparel_slots: Array[RedItemSlot] = []
var _apparel_glyphs: Array[RedMenuGlyph] = []
var _hotbar_slots: Array[RedItemSlot] = []


## Supplies the player whose live loadout this page presents. Configure the page
## before it enters the tree so the 3D preview can build the correct body once.
func configure(player: OnlinePlayer) -> void:
	_disconnect_sources()
	_player = player
	_capture_sources()
	if is_inside_tree():
		_connect_sources()
	if not _built:
		return
	_bind_slots()
	if _preview != null and _player != null:
		_preview.configure(
			_equipment,
			_player.body_id(),
			_player.skin_id(),
			_player.tints()
		)
	refresh()


## Re-reads the name, stats and all ten visible item slots. Menu code and visual
## harnesses may call this after changing player state directly.
func refresh() -> void:
	if not _built:
		return

	var player_name := "PLAYER"
	if _player != null:
		player_name = _player.display_name.strip_edges()
		if player_name.is_empty():
			player_name = "PLAYER"
	_hero_name.text = player_name.to_upper()

	_fill_stats()
	_refresh_apparel()
	_refresh_hotbar()
	if _preview != null:
		if _player != null:
			_preview.set_tints(_player.tints())
		_preview.refresh()
	_request_icons()


func _init() -> void:
	name = "RedHeroPage"
	process_mode = Node.PROCESS_MODE_ALWAYS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(320.0, 360.0)


## The wide three-column contents must not become the page's own minimum width:
## doing so would prevent a parent container from ever shrinking it far enough
## to trigger the one-column layout. The scroll region owns overflow instead.
func _get_minimum_size() -> Vector2:
	return custom_minimum_size


func _enter_tree() -> void:
	_connect_sources()


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	_build()
	_built = true
	refresh()
	resized.connect(_update_responsive_layout)
	_update_responsive_layout()
	call_deferred(&"_update_responsive_layout")


func _exit_tree() -> void:
	_disconnect_sources()


func _capture_sources() -> void:
	if _player == null:
		_equipment = null
		_weapons = null
		_abilities = null
		_backpack = null
		_stats = null
		return
	_equipment = _player.equipment
	_weapons = _player.weapons
	# Dynamic access keeps this page parseable across the two-slot backend landing.
	_abilities = _player.get("abilities") as ItemContainer
	_backpack = _player.backpack
	_stats = _player.stats


func _connect_sources() -> void:
	if _sources_connected:
		return
	for source: ItemContainer in [_equipment, _weapons, _abilities, _backpack]:
		if source != null and not source.changed.is_connected(refresh):
			source.changed.connect(refresh)
	if _stats != null and not _stats.changed.is_connected(_on_stats_changed):
		_stats.changed.connect(_on_stats_changed)
	_sources_connected = true


func _disconnect_sources() -> void:
	for source: ItemContainer in [_equipment, _weapons, _abilities, _backpack]:
		if source != null and source.changed.is_connected(refresh):
			source.changed.disconnect(refresh)
	if _stats != null and _stats.changed.is_connected(_on_stats_changed):
		_stats.changed.disconnect(_on_stats_changed)
	_sources_connected = false


func _on_stats_changed(_id: StringName, _value: float) -> void:
	refresh()


func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "HeroScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_main_grid = GridContainer.new()
	_main_grid.name = "HeroComposition"
	_main_grid.columns = 2
	_main_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_grid.add_theme_constant_override(&"h_separation", 14)
	_main_grid.add_theme_constant_override(&"v_separation", 12)
	scroll.add_child(_main_grid)

	_character_block = _build_character_block()
	_main_grid.add_child(_character_block)

	_loadout_column = VBoxContainer.new()
	_loadout_column.name = "HeroLoadoutRows"
	_loadout_column.custom_minimum_size.x = 480.0
	_loadout_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loadout_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_loadout_column.size_flags_stretch_ratio = 1.12
	_loadout_column.add_theme_constant_override(&"separation", 12)
	_main_grid.add_child(_loadout_column)

	_apparel_frame = _build_apparel_frame()
	_loadout_column.add_child(_apparel_frame)
	_loadout_column.add_child(_build_hotbar_block())

	_icons = ItemIcons.new()
	_icons.name = "ItemIcons"
	add_child(_icons)
	_icons.icon_ready.connect(_on_icon_ready)


func _build_stats_frame() -> PanelContainer:
	var column := VBoxContainer.new()
	column.name = "StatsContent"
	column.add_theme_constant_override(&"separation", 8)
	column.add_child(_section_heading("PLAYER STATS  //  LIVE READOUT"))
	column.add_child(_rule())

	_stats_rows = VBoxContainer.new()
	_stats_rows.name = "StatRows"
	_stats_rows.add_theme_constant_override(&"separation", 7)
	_stats_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_stats_rows)

	var frame := _glow_frame(column, "StatsFrame", 13.0)
	frame.visible = false
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	return frame


func _build_character_block() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.name = "HeroModel"
	column.custom_minimum_size.x = 430.0
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.size_flags_stretch_ratio = 1.0
	column.add_theme_constant_override(&"separation", 6)

	_hero_name = _label("PLAYER", 27, RED_BRIGHT)
	_hero_name.name = "HeroName"
	_hero_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_hero_name)
	column.add_child(_rule())

	var stage := Control.new()
	stage.name = "CharacterStage"
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var preview_center := CenterContainer.new()
	preview_center.name = "CharacterPreviewCenter"
	preview_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stage.add_child(preview_center)

	_preview = RedCharacterPreview.new()
	_preview.name = "CharacterPreview"
	if _player != null:
		_preview.configure(
			_equipment,
			_player.body_id(),
			_player.skin_id(),
			_player.tints()
		)
	else:
		_preview.configure(null, CharacterDB.DEFAULT_BODY, "", {})
	preview_center.add_child(_preview)

	_stats_frame = _build_stats_frame()
	_stats_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stats_frame.offset_left = 10.0
	_stats_frame.offset_top = 10.0
	_stats_frame.offset_right = -10.0
	_stats_frame.offset_bottom = -10.0
	stage.add_child(_stats_frame)

	_stats_toggle = _build_stats_toggle()
	stage.add_child(_stats_toggle)

	var preview_frame := _glow_frame(stage, "CharacterFrame", 3.0)
	preview_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(preview_frame)

	var hint := _label("DRAG MODEL TO ROTATE  //  FLOAT POSE", 10, RED_MUTED)
	hint.name = "CharacterHint"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	return column


func _build_stats_toggle() -> Button:
	var button := Button.new()
	button.name = "StatsToggle"
	button.tooltip_text = "Show player stats"
	button.custom_minimum_size = Vector2(48.0, 48.0)
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -58.0
	button.offset_top = -58.0
	button.offset_right = -10.0
	button.offset_bottom = -10.0
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_toggle_stats)
	_style_stats_toggle(button)

	var glyph := RedMenuGlyph.new()
	glyph.name = "StatsGlyph"
	glyph.glyph = RedMenuGlyph.Glyph.STATS
	glyph.green_color = Color(0.02, 0.03, 0.02, 1.0)
	glyph.black_color = Color(0.02, 0.03, 0.02, 1.0)
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.offset_left = 9.0
	glyph.offset_top = 9.0
	glyph.offset_right = -9.0
	glyph.offset_bottom = -9.0
	button.add_child(glyph)
	return button


func _toggle_stats() -> void:
	_stats_open = not _stats_open
	_stats_frame.visible = _stats_open
	_stats_toggle.tooltip_text = (
		"Hide player stats" if _stats_open else "Show player stats"
	)
	_style_stats_toggle(_stats_toggle)


func _style_stats_toggle(button: Button) -> void:
	var fill := RED_BRIGHT if _stats_open else GREEN
	var border := YELLOW if _stats_open else Color(GREEN, 0.95)
	button.add_theme_stylebox_override(
		&"normal", _round_style(fill, border, 2, 4.0, Color(RED, 0.20), 5)
	)
	button.add_theme_stylebox_override(
		&"hover", _round_style(GREEN, YELLOW, 2, 4.0, Color(RED, 0.24), 5)
	)
	button.add_theme_stylebox_override(
		&"pressed", _round_style(GREEN.lightened(0.12), YELLOW, 2, 4.0)
	)
	button.add_theme_stylebox_override(
		&"focus", _round_style(Color.TRANSPARENT, YELLOW, 2, 4.0)
	)


func _build_apparel_frame() -> PanelContainer:
	var column := VBoxContainer.new()
	column.name = "ApparelContent"
	column.add_theme_constant_override(&"separation", 8)
	column.add_child(_section_heading("EQUIPPED APPAREL"))
	column.add_child(_rule())

	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(centre)

	_apparel_grid = GridContainer.new()
	_apparel_grid.name = "ApparelSlots"
	_apparel_grid.columns = 5
	_apparel_grid.add_theme_constant_override(&"h_separation", 7)
	_apparel_grid.add_theme_constant_override(&"v_separation", 7)
	centre.add_child(_apparel_grid)

	for index in ItemDB.SLOT_ORDER.size():
		var body_slot: String = ItemDB.SLOT_ORDER[index]
		var slot := RedItemSlot.new()
		slot.name = "ApparelSlot_%02d" % index
		slot.set_meta(&"body_slot", body_slot)
		slot.set_edge(WIDE_APPAREL_EDGE)
		slot.placeholder = ""
		slot.badge = String(ItemDB.SLOT_LABELS.get(body_slot, body_slot)).to_upper()
		slot.draggable = false
		slot.bind(_equipment, index)
		slot.picked.connect(_on_apparel_picked)
		slot.quick_move_requested.connect(_on_apparel_quick_move)
		_apparel_grid.add_child(slot)
		_apparel_slots.append(slot)

		var glyph := RedMenuGlyph.new()
		glyph.name = "EmptyGlyph_%02d" % index
		glyph.glyph = APPAREL_GLYPHS[index]
		glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		glyph.offset_left = 11.0
		glyph.offset_top = 11.0
		glyph.offset_right = -11.0
		glyph.offset_bottom = -11.0
		slot.add_child(glyph)
		_apparel_glyphs.append(glyph)

	_apparel_hint = _label(
		"CLICK TO IDENTIFY  //  SHIFT+CLICK TO STOW",
		10,
		RED_MUTED,
		true
	)
	_apparel_hint.name = "ApparelHint"
	_apparel_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_apparel_hint)

	var frame := _glow_frame(column, "ApparelFrame", 12.0)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.size_flags_stretch_ratio = 1.0
	return frame


func _build_hotbar_block() -> PanelContainer:
	var column := VBoxContainer.new()
	column.name = "HotbarContent"
	column.add_theme_constant_override(&"separation", 6)

	var heading := _section_heading("ACTIVE HOTBAR  //  LMB  RMB  1  2  3", 13)
	column.add_child(heading)
	column.add_child(_rule())

	_hotbar_row = HBoxContainer.new()
	_hotbar_row.name = "HotbarSlots"
	_hotbar_row.add_theme_constant_override(&"separation", 7)
	_hotbar_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_hotbar_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hotbar_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_hotbar_row)

	for logical_index in HOTBAR_BADGES.size():
		var slot := RedItemSlot.new()
		var badge: String = HOTBAR_BADGES[logical_index]
		slot.name = "HotbarSlot_%s" % badge
		slot.set_meta(&"logical_input", badge)
		slot.set_edge(WIDE_HOTBAR_EDGE)
		slot.badge = badge
		slot.placeholder = "X"
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slot.interactive = false
		slot.draggable = false
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hotbar_row.add_child(slot)
		_hotbar_slots.append(slot)

	_hotbar_frame = _glow_frame(column, "HotbarFrame", 10.0)
	_hotbar_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hotbar_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hotbar_frame.size_flags_stretch_ratio = 1.0
	_bind_hotbar_slots()
	return _hotbar_frame


func _bind_slots() -> void:
	for index in _apparel_slots.size():
		_apparel_slots[index].bind(_equipment, index)
	_bind_hotbar_slots()


func _bind_hotbar_slots() -> void:
	if _hotbar_slots.size() != HOTBAR_BADGES.size():
		return
	for logical_index in _hotbar_slots.size():
		if logical_index < 2:
			_hotbar_slots[logical_index].bind(_abilities, logical_index)
		else:
			_hotbar_slots[logical_index].bind(_weapons, logical_index - 2)


func _fill_stats() -> void:
	if _stats_rows == null:
		return
	_clear_children(_stats_rows)
	if _stats == null:
		_stats_rows.add_child(_label("NO STAT DATA", 12, RED_MUTED))
		return

	for id_text: String in PlayerStats.ids():
		var id := StringName(id_text)
		var data: Dictionary = _stats.row(id)
		var row_panel := PanelContainer.new()
		row_panel.name = "Stat_%s" % id_text
		row_panel.tooltip_text = PlayerStats.description_of(id)
		row_panel.add_theme_stylebox_override(
			&"panel",
			_style(BLACK_42, Color(RED, 0.42), 1, 7.0)
		)
		_stats_rows.add_child(row_panel)

		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 12)
		row_panel.add_child(row)

		var title := _label(PlayerStats.title_of(id), 12, RED_TEXT)
		title.name = "Stat_%s_Name" % id_text
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(title)

		var value := _label(
			_format_stat_number(id, float(data.get("value", 0.0))),
			18,
			GREEN
		)
		value.name = "Stat_%s_Value" % id_text
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(value)


func _format_stat_number(id: StringName, value: float) -> String:
	var precision := 0
	var definition: Variant = PlayerStats.STATS.get(String(id), {})
	if definition is Dictionary:
		precision = maxi(int((definition as Dictionary).get("precision", 0)), 0)
	return "%.*f" % [precision, value]


func _refresh_apparel() -> void:
	if _selected_apparel >= 0 and (
			_equipment == null
			or _equipment.get_item(_selected_apparel).is_empty()
	):
		_selected_apparel = -1

	for index in _apparel_slots.size():
		var slot := _apparel_slots[index]
		var id := slot.item_id()
		slot.selected = index == _selected_apparel
		slot.equipped = not id.is_empty()
		slot.tooltip_text = (
			"%s\nSHIFT+CLICK TO MOVE TO BACKPACK" % ItemDB.title(id)
			if not id.is_empty()
			else "%s // EMPTY" % _apparel_slot_label(index)
		)
		slot.queue_redraw()
		_apparel_glyphs[index].visible = id.is_empty()


func _refresh_hotbar() -> void:
	for index in _hotbar_slots.size():
		var slot := _hotbar_slots[index]
		var id := slot.item_id()
		slot.equipped = not id.is_empty()
		slot.tooltip_text = (
			"%s // %s" % [HOTBAR_BADGES[index], ItemDB.title(id)]
			if not id.is_empty()
			else "%s // EMPTY" % HOTBAR_BADGES[index]
		)
		slot.queue_redraw()


func _request_icons() -> void:
	if _icons == null:
		return
	var ids: Array = []
	for source: ItemContainer in [_equipment, _weapons, _abilities, _backpack]:
		if source == null:
			continue
		for id: String in source.items():
			if not id.is_empty() and not ids.has(id):
				ids.append(id)
	_icons.request(ids)


func _on_icon_ready(_id: String, _texture: Texture2D) -> void:
	for slot: RedItemSlot in _apparel_slots:
		slot.queue_redraw()
	for slot: RedItemSlot in _hotbar_slots:
		slot.queue_redraw()


func _on_apparel_picked(slot: RedItemSlot) -> void:
	if slot.container != _equipment:
		return
	_selected_apparel = slot.index
	var id := slot.item_id()
	_apparel_hint.text = (
		"%s  //  SHIFT+CLICK TO STOW" % ItemDB.title(id).to_upper()
		if not id.is_empty()
		else "%s  //  EMPTY" % _apparel_slot_label(slot.index)
	)
	_refresh_apparel()


func _on_apparel_quick_move(slot: RedItemSlot) -> void:
	if slot.container != _equipment or _backpack == null:
		return
	var id := slot.item_id()
	if id.is_empty():
		return
	var title := ItemDB.title(id).to_upper()
	var moved := ItemContainer.quick_move(_equipment, slot.index, _backpack)
	if moved:
		_selected_apparel = -1
		_apparel_hint.text = "%s  //  MOVED TO BACKPACK" % title
	else:
		_apparel_hint.text = "BACKPACK FULL  //  %s REMAINS WORN" % title
	refresh()


func _apparel_slot_label(index: int) -> String:
	var body_slot := (
		_equipment.filter_of(index)
		if _equipment != null
		else ""
	)
	if body_slot.is_empty() and index >= 0 and index < ItemDB.SLOT_ORDER.size():
		body_slot = ItemDB.SLOT_ORDER[index]
	return String(ItemDB.SLOT_LABELS.get(body_slot, body_slot)).to_upper()


func _update_responsive_layout() -> void:
	if not _built:
		return
	var available_width := size.x
	if available_width <= 0.0:
		available_width = get_viewport_rect().size.x
	var narrow := available_width < NARROW_WIDTH
	if _responsive_initialized and narrow == _narrow:
		return
	_responsive_initialized = true
	_narrow = narrow

	_main_grid.columns = 1 if narrow else 2
	_character_block.custom_minimum_size.x = 0.0 if narrow else 430.0
	_loadout_column.custom_minimum_size.x = 0.0 if narrow else 480.0
	_preview.custom_minimum_size = (
		Vector2(260.0, 300.0)
		if narrow
		else Vector2(410.0, 350.0)
	)

	_apparel_grid.columns = 5
	for slot: RedItemSlot in _apparel_slots:
		slot.set_edge(
			NARROW_APPAREL_EDGE if narrow else WIDE_APPAREL_EDGE
		)
	for slot: RedItemSlot in _hotbar_slots:
		slot.set_edge(NARROW_HOTBAR_EDGE if narrow else WIDE_HOTBAR_EDGE)


func _section_heading(text: String, font_size := 16) -> Label:
	var heading := _label(text, font_size, RED_BRIGHT)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return heading


func _label(
	text: String,
	font_size: int,
	color: Color,
	wrap: bool = false
) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(
		&"font_outline_color",
		Color(0.10, 0.0, 0.0, 0.94)
	)
	label.add_theme_constant_override(&"outline_size", 2)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _rule() -> PanelContainer:
	var rule := PanelContainer.new()
	rule.custom_minimum_size.y = 2.0
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.add_theme_stylebox_override(
		&"panel",
		_style(Color(RED, 0.48), RED_BRIGHT, 1, 0.0)
	)
	return rule


func _glow_frame(
	content: Control,
	node_name: String,
	padding: float
) -> PanelContainer:
	var frame := PanelContainer.new()
	frame.name = node_name
	frame.add_theme_stylebox_override(
		&"panel",
		_style(
			BLACK_68,
			Color(RED_BRIGHT, 0.92),
			1,
			padding,
			Color(RED, 0.18),
			6
		)
	)
	var glow := RedGlowPanel.add_to(frame)
	glow.fill_color = BLACK_42
	glow.border_color = Color(RED, 0.9)
	glow.border_width = 1.5
	glow.glow_intensity = 1.15
	glow.glow_spread = 8.0
	glow.glow_layers = 4
	frame.add_child(content)
	return frame


func _round_style(
	fill: Color,
	border: Color,
	border_width: int,
	padding: float,
	shadow: Color = Color.TRANSPARENT,
	shadow_size: int = 0
) -> StyleBoxFlat:
	var box := _style(fill, border, border_width, padding, shadow, shadow_size)
	box.set_corner_radius_all(28)
	return box


func _style(
	fill: Color,
	border: Color,
	border_width: int,
	padding: float,
	shadow: Color = Color.TRANSPARENT,
	shadow_size: int = 0
) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(0)
	box.content_margin_left = padding
	box.content_margin_top = padding
	box.content_margin_right = padding
	box.content_margin_bottom = padding
	box.shadow_color = shadow
	box.shadow_size = shadow_size
	box.shadow_offset = Vector2.ZERO
	return box


func _clear_children(parent: Node) -> void:
	for child: Node in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
