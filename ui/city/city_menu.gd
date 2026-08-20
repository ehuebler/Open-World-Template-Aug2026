class_name CityMenu
extends Control

## The colony's control panel, opened by pressing E at the Colony Ship.
##
## An overlay on the player's own HUD rather than a page in [GameMenu], because
## it is reached by standing somewhere rather than by pressing Tab: a tab would
## put the city's controls in front of someone on the far side of the planet, and
## the ship is the thing that makes them make sense. [DeathScreen] is the same
## shape for the same reason and this follows it.
##
## It knows nothing about how a colony works. Everything on it arrives through
## one [Callable] that answers with a report, polled while the panel is open, and
## everything it does leaves as a signal. That is what lets the simulation grow
## rows here — resources, then buildings, then whatever the cloner needs — without
## the panel learning the shape of any of it.

## Emitted once, when the panel should be taken down and the mouse handed back.
signal closed
## The button was pressed. The world decides whether it is allowed.
signal release_settlers_requested
## Amount the player wants moved from their carried bank into this city.
signal deposit_biomass_requested(amount: float)
## Fixed city-side grant. It does not read or debit the player's carried biomass.
signal add_100_biomass_requested
## Exact append-only purchase ID. The host resolves its price and prerequisites.
signal city_purchase_requested(purchase_id: int)
signal settlement_rename_requested(wanted: String)

const TITLE := "COLONY // CITY CONTROL"
const PLATE_SIZE := Vector2(620.0, 680.0)
const BACKDROP := Color(0.02, 0.0, 0.03, 0.46)
## What the single resource is called. One line to change, and the row it labels
## reads whatever the colony's bank reports without caring.
const RESOURCE_LABEL := "BIOMASS"
## Report reads per second. The host keeps simulating while this is open in
## company, so the figures have to move; four times a second is faster than
## anyone can read and far cheaper than every frame.
const REFRESH_INTERVAL := 0.25
## A button can cross the network before its authoritative result reaches this peer.
## Poll briefly at UI cadence after every action so the resulting bank, offer, or
## city name appears as soon as the host's answer lands.
const ACTION_REFRESH_INTERVAL := 1.0 / 30.0
const ACTION_REFRESH_SECONDS := 1.0
## Shown before a colony exists, so the rows are never blank.
const EMPTY_REPORT := {
	"founded": false,
	"tier": 0,
	"tier_full": false,
	"settlers": 0,
	"resources": 0.0,
	"carried_biomass": 0.0,
	"committed": 0.0,
	"structures": 0,
	"raising": 0,
	"road_cells": 0,
	"paving": 0,
	"timber": 0,
	"claim_radius": 0.0,
	"max_claim_radius": MeepColony.MAX_CLAIM_RADIUS,
	"expansion_rate": MeepColony.EXPANSION_BASE_RATE,
	"city_style": "Planning",
	"districts_active": 0,
	"districts_total": 0,
	"border_expanding": false,
	"doing": "",
	"meeps": [],
	"purchase_offers": {},
}

var _report: Callable
var _rows: Dictionary = {}
var _release: Button
var _deposit: Button
var _deposit_100: Button
var _purchase_buttons: Dictionary = {}
var _purchase_values: Dictionary = {}
var _status: Label
var _rename_lane: HBoxContainer
var _rename_field: LineEdit
var _rename_button: Button
var _tabs: TabContainer
var _alive_toggle: Button
var _dead_toggle: Button
var _roster_grid: MeepRosterGrid
var _alive_roster: Array[Dictionary] = []
var _dead_roster: Array[Dictionary] = []
var _meep_row_texts: Dictionary = {}
var _show_dead := false
var _meep_roster_revision := -1
var _refresh_left := 0.0
var _action_refresh_left := 0.0
var _asked := false
var _carried_biomass := 0.0


func _init() -> void:
	name = "CityMenu"
	# The tree is paused underneath in single player, exactly as it is behind the
	# Tab menu, so nothing here may be pausable or the panel would freeze with it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP


## The one wire in. [param report] is expected to answer with a dictionary in the
## shape of [constant EMPTY_REPORT]; a null or failing callable simply leaves the
## rows at their empty values rather than being an error, because a panel that
## cannot describe the colony is still a panel that has to close.
func configure(report: Callable) -> void:
	_report = report
	if is_inside_tree():
		_refresh()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh()


func _process(delta: float) -> void:
	_action_refresh_left = maxf(_action_refresh_left - delta, 0.0)
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = ACTION_REFRESH_INTERVAL \
		if _action_refresh_left > 0.0 else REFRESH_INTERVAL
	_refresh()


## Escape and Tab both close it, which is the same contract [GameMenu] has: the
## keys that open a menu are the keys that get you out of one, and the panel has
## to swallow them or the player's own handler would open the Tab menu on top.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"inventory"):
		get_viewport().set_input_as_handled()
		close()


func release_button() -> Button:
	return _release


func deposit_button() -> Button:
	return _deposit


func deposit_100_button() -> Button:
	return _deposit_100


func purchase_button(key: String) -> Button:
	return _purchase_buttons.get(key) as Button


func settlement_name_field() -> LineEdit:
	return _rename_field


func settlement_rename_button() -> Button:
	return _rename_button


func tab_container() -> TabContainer:
	return _tabs


func meep_row_text(index: int) -> String:
	return String(_meep_row_texts.get(index, ""))


## What a readout row currently says. Keys are the ones passed to [method _add_row]:
## `settlers`, `resources`, `structures` and `timber`.
func row_text(key: String) -> String:
	var value := _rows.get(key) as Label
	return value.text if value != null else ""


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = BACKDROP
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var centre := CenterContainer.new()
	centre.name = "Centre"
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	var plate := RedGlowPanel.new()
	plate.name = "Plate"
	plate.custom_minimum_size = PLATE_SIZE
	plate.fill_color = Color(0.0, 0.0, 0.0, 0.84)
	plate.border_color = Color(RedHudTheme.RED_BRIGHT, 0.98)
	plate.border_width = 2.0
	plate.glow_intensity = 1.5
	plate.glow_spread = 13.0
	plate.glow_layers = 5
	plate.mouse_behavior = RedGlowPanel.MouseBehavior.STOP
	centre.add_child(plate)

	var pad := MarginContainer.new()
	pad.name = "Padding"
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: StringName in [&"margin_left", &"margin_right"]:
		pad.add_theme_constant_override(side, 26)
	for side: StringName in [&"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 20)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(pad)

	# The title and close action stay put. Everything that can grow with later city
	# tiers lives in one vertical scroll, so new controls never push CLOSE off-screen.
	var outer := VBoxContainer.new()
	outer.name = "Outer"
	outer.add_theme_constant_override(&"separation", 10)
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(outer)

	var title := Label.new()
	title.name = "Title"
	title.text = TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 24)
	title.add_theme_color_override(&"font_color", RedHudTheme.RED_BRIGHT)
	title.add_theme_color_override(
		&"font_outline_color", Color(0.04, 0.0, 0.0, 0.98))
	title.add_theme_constant_override(&"outline_size", 4)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(title)

	outer.add_child(_rule())

	_tabs = TabContainer.new()
	_tabs.name = "CityTabs"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.name = "CityControlsScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_child(scroll)
	_tabs.set_tab_title(0, "CONTROL")

	var inset := MarginContainer.new()
	inset.name = "ScrollInset"
	inset.add_theme_constant_override(&"margin_right", 14)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inset)

	# A column of report rows and actions rather than a fixed layout. Later phases
	# can add project detail without changing the panel's outer geometry.
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override(&"separation", 12)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.add_child(column)

	_add_row(column, "display_name", "CITY")
	_add_row(column, "parent_name", "PARENT")
	_add_row(column, "children", "CHILDREN")
	_add_row(column, "tier", "CITY TIER")
	_add_row(column, "settlers", "SETTLERS")
	_add_row(column, "carried_biomass", "YOUR BIOMASS")
	_add_row(column, "resources", "CITY %s" % RESOURCE_LABEL)
	_add_row(column, "city_style", "CITY PLAN")
	_add_row(column, "claim_radius", "BORDER REACH")
	_add_row(column, "structures", "STRUCTURES")
	_add_row(column, "roads", "ROAD LAID")
	_add_row(column, "timber", "TIMBER STANDING")
	_rename_lane = HBoxContainer.new()
	_rename_lane.name = "SettlementRenameLane"
	_rename_lane.add_theme_constant_override(&"separation", 8)
	column.add_child(_rename_lane)
	_rename_field = LineEdit.new()
	_rename_field.name = "SettlementNameField"
	_rename_field.placeholder_text = "Settlement name"
	_rename_field.max_length = 24
	_rename_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename_lane.add_child(_rename_field)
	_rename_button = Button.new()
	_rename_button.name = "RenameSettlementButton"
	_rename_button.text = "RENAME"
	RedHudTheme.button(_rename_button, 13, 7.0)
	_rename_button.pressed.connect(_on_rename_pressed)
	_rename_lane.add_child(_rename_button)
	column.add_child(_rule())

	_status = Label.new()
	_status.name = "Status"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override(&"font_size", 14)
	_status.add_theme_color_override(&"font_color", Color(1.0, 0.63, 0.66))
	_status.add_theme_color_override(
		&"font_outline_color", Color(0.04, 0.0, 0.0, 0.98))
	_status.add_theme_constant_override(&"outline_size", 3)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_status)

	var deposit_lane := HBoxContainer.new()
	deposit_lane.name = "DepositLane"
	deposit_lane.alignment = BoxContainer.ALIGNMENT_CENTER
	deposit_lane.add_theme_constant_override(&"separation", 10)
	deposit_lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(deposit_lane)

	_deposit_100 = Button.new()
	_deposit_100.name = "Deposit100BiomassButton"
	_deposit_100.text = "ADD 100"
	_deposit_100.custom_minimum_size = Vector2(210.0, 44.0)
	_deposit_100.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(_deposit_100, 15, 8.0)
	_deposit_100.pressed.connect(_on_deposit_100_pressed)
	deposit_lane.add_child(_deposit_100)

	_deposit = Button.new()
	_deposit.name = "DepositBiomassButton"
	_deposit.text = "ADD ALL"
	_deposit.custom_minimum_size = Vector2(210.0, 44.0)
	_deposit.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(_deposit, 15, 8.0)
	_deposit.pressed.connect(_on_deposit_pressed)
	deposit_lane.add_child(_deposit)

	var lane := CenterContainer.new()
	lane.name = "ButtonLane"
	lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(lane)

	_release = Button.new()
	_release.name = "ReleaseSettlersButton"
	_release.text = "RELEASE SETTLERS"
	_release.custom_minimum_size = Vector2(280.0, 46.0)
	_release.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(_release, 16, 8.0)
	_release.pressed.connect(_on_release_pressed)
	lane.add_child(_release)

	column.add_child(_rule())
	var upgrades := Label.new()
	upgrades.name = "CityUpgrades"
	upgrades.text = "CITY UPGRADES"
	upgrades.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	upgrades.add_theme_font_size_override(&"font_size", 18)
	upgrades.add_theme_color_override(&"font_color", RedHudTheme.RED_BRIGHT)
	upgrades.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(upgrades)

	_add_purchase_control(column, "build_speed", "BUILD SPEED")
	_add_purchase_control(column, "move_speed", "MEEP MOVE SPEED")
	_add_purchase_control(column, "bridges", "BRIDGES")
	_add_purchase_control(column, "coasts", "COASTS")
	_add_purchase_control(column, "second_cloner", "SECOND MEEP CLONER")
	_add_purchase_control(column, "third_cloner", "THIRD MEEP CLONER")
	_add_purchase_control(column, "fourth_cloner", "FOURTH MEEP CLONER")
	_add_purchase_control(column, "hat_house", "HAT HOUSE")
	_add_purchase_control(column, "abilities_house", "ABILITIES HOUSE")
	_add_purchase_control(column, "abilities_house_tower",
		"UPGRADE ABILITIES HOUSE")
	_add_purchase_control(column, "biomass_harvester", "BIOMASS HARVESTER")
	_add_purchase_control(column, "send_settlement", "SEND NEW SETTLEMENT")

	_build_meeps_tab()

	outer.add_child(_rule())
	var close_lane := CenterContainer.new()
	close_lane.name = "CloseLane"
	close_lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(close_lane)

	var close_button := Button.new()
	close_button.name = "CloseButton"
	close_button.text = "CLOSE"
	close_button.custom_minimum_size = Vector2(150.0, 34.0)
	close_button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(close_button, 13, 6.0)
	close_button.pressed.connect(close)
	close_lane.add_child(close_button)


func _build_meeps_tab() -> void:
	var column := VBoxContainer.new()
	column.name = "MeepRoster"
	column.add_theme_constant_override(&"separation", 9)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tabs.add_child(column)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, "MEEPS")

	var note := Label.new()
	note.text = "Living residents and this city's permanent memorial."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override(&"font_size", 13)
	note.add_theme_color_override(&"font_color", Color(0.78, 0.6, 0.64))
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(note)

	var segments := HBoxContainer.new()
	segments.name = "MeepRosterSegments"
	segments.add_theme_constant_override(&"separation", 8)
	segments.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	segments.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(segments)

	var segment_group := ButtonGroup.new()
	_alive_toggle = _roster_segment("AliveMeepsToggle", "ALIVE  0", segment_group)
	_alive_toggle.set_pressed_no_signal(true)
	_alive_toggle.pressed.connect(_on_roster_segment_pressed.bind(false))
	segments.add_child(_alive_toggle)
	_dead_toggle = _roster_segment("DeadMeepsToggle", "DEAD  0", segment_group)
	_dead_toggle.pressed.connect(_on_roster_segment_pressed.bind(true))
	segments.add_child(_dead_toggle)

	var scroll := ScrollContainer.new()
	scroll.name = "MeepRosterScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)

	var inset := MarginContainer.new()
	inset.name = "MeepRosterInset"
	inset.add_theme_constant_override(&"margin_left", 2)
	inset.add_theme_constant_override(&"margin_right", 10)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inset)

	_roster_grid = MeepRosterGrid.new()
	inset.add_child(_roster_grid)
	_roster_grid.bind_scroll_container(scroll)


func _roster_segment(
		wanted_name: String,
		text: String,
		group: ButtonGroup
	) -> Button:
	var button := Button.new()
	button.name = wanted_name
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size.y = 36.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(button, 13, 7.0)
	return button


## One label/value pair, kept in [member _rows] so the refresh can write the
## value without walking the tree for it.
func _add_row(column: VBoxContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.name = "%sRow" % caption.capitalize()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override(&"font_size", 16)
	label.add_theme_color_override(&"font_color", Color(1.0, 0.55, 0.6))
	label.add_theme_color_override(
		&"font_outline_color", Color(0.04, 0.0, 0.0, 0.98))
	label.add_theme_constant_override(&"outline_size", 3)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)

	var value := Label.new()
	value.name = "Value"
	value.text = "0"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override(&"font_size", 18)
	value.add_theme_color_override(&"font_color", RedHudTheme.GREEN)
	value.add_theme_color_override(
		&"font_outline_color", Color(0.0, 0.04, 0.01, 0.98))
	value.add_theme_constant_override(&"outline_size", 3)
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value)

	_rows[key] = value


func _add_purchase_control(column: VBoxContainer, key: String,
		caption: String) -> void:
	var box := VBoxContainer.new()
	box.name = "%sControl" % key.to_pascal_case()
	box.add_theme_constant_override(&"separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(box)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)

	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_color_override(&"font_color", Color(1.0, 0.55, 0.6))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)

	var value := Label.new()
	value.text = "LOCKED"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override(&"font_size", 14)
	value.add_theme_color_override(&"font_color", RedHudTheme.GREEN)
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value)
	_purchase_values[key] = value

	var lane := CenterContainer.new()
	lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(lane)

	var button := Button.new()
	button.name = "%sButton" % key.to_pascal_case()
	button.text = "LOCKED"
	button.custom_minimum_size = Vector2(320.0, 38.0)
	button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(button, 14, 7.0)
	button.pressed.connect(_on_purchase_pressed.bind(key))
	lane.add_child(button)
	_purchase_buttons[key] = button

	column.add_child(_rule())


func _rule() -> Control:
	var line := ColorRect.new()
	line.color = Color(RedHudTheme.RED, 0.42)
	line.custom_minimum_size.y = 1.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _refresh() -> void:
	var report := EMPTY_REPORT
	if _report.is_valid():
		var answer: Variant = _report.call()
		if answer is Dictionary:
			report = answer as Dictionary
	var settlers := int(report.get("settlers", 0))
	var founded := bool(report.get("founded", false))
	if _rows.has("display_name"):
		(_rows["display_name"] as Label).text = String(
			report.get("display_name", "Colony"))
	if _rows.has("parent_name"):
		var parent_name := String(report.get("parent_name", ""))
		(_rows["parent_name"] as Label).text = parent_name \
			if not parent_name.is_empty() else "—"
	if _rows.has("children"):
		var child_names := PackedStringArray()
		var child_state: Variant = report.get("children", [])
		if child_state is Array:
			for child_variant: Variant in child_state:
				if child_variant is Dictionary:
					var child := child_variant as Dictionary
					child_names.push_back("%s T%d (%d)" % [
						String(child.get("name", "Settlement")),
						int(child.get("tier", 0)),
						int(child.get("settlers", 0))])
		(_rows["children"] as Label).text = ", ".join(child_names) \
			if not child_names.is_empty() else "—"
	if _rows.has("tier"):
		var tier := int(report.get("tier", 0))
		var filled := bool(report.get("tier_full", false))
		(_rows["tier"] as Label).text = "TIER %d" % tier if not filled \
			else "TIER %d — FILLED" % tier
	if _rows.has("settlers"):
		(_rows["settlers"] as Label).text = str(settlers)
	_carried_biomass = maxf(
		float(report.get("carried_biomass", 0.0)), 0.0)
	if _rows.has("carried_biomass"):
		(_rows["carried_biomass"] as Label).text = \
			str(roundi(_carried_biomass))
	if _rows.has("resources"):
		# What is spare and what is promised, because a bank showing only its total
		# looks stuck when every unit in it is already spoken for by a building.
		var bank := roundi(float(report.get("resources", 0.0)))
		var held := roundi(float(report.get("committed", 0.0)))
		(_rows["resources"] as Label).text = "%d" % bank if held <= 0 \
			else "%d  (%d held)" % [bank, held]
	if _rows.has("claim_radius"):
		var reach := float(report.get("claim_radius", 0.0))
		var maximum := float(report.get(
			"max_claim_radius", MeepColony.MAX_CLAIM_RADIUS))
		var rate := float(report.get(
			"expansion_rate", MeepColony.EXPANSION_BASE_RATE))
		(_rows["claim_radius"] as Label).text = (
			"%.1f / %.0f M  (+%.1f M/S)" % [reach, maximum, rate]
			if bool(report.get("border_expanding", false))
			else "%.1f / %.0f M  (ON DEMAND)" % [reach, maximum])
	if _rows.has("city_style"):
		(_rows["city_style"] as Label).text = "%s  •  %d/%d DISTRICTS" % [
			String(report.get("city_style", "Planning")).to_upper(),
			int(report.get("districts_active", 0)),
			int(report.get("districts_total", 0)),
		]
	if _rows.has("structures"):
		var raised := int(report.get("structures", 0))
		var raising := int(report.get("raising", 0))
		(_rows["structures"] as Label).text = str(raised) if raising <= 0 \
			else "%d  (+%d rising)" % [raised, raising]
	if _rows.has("roads"):
		var road_cells := int(report.get("road_cells", 0))
		var paving := int(report.get("paving", 0))
		var metres := roundi(road_cells * MeepGrid.CELL)
		(_rows["roads"] as Label).text = "%d m" % metres if paving <= 0 \
			else "%d m  (+%d paving)" % [metres, paving]
	if _rows.has("timber"):
		(_rows["timber"] as Label).text = str(int(report.get("timber", 0)))
	if _status != null:
		_status.text = "%d settlers. %s." % [settlers,
			String(report.get("doing", "At work"))] if founded \
			else "No settlers released yet."
	# The first wave is the whole of what this button does; population after it
	# comes from the cloner, so a founded colony leaves it as a statement of
	# fact rather than something to press again.
	if _release != null:
		_release.disabled = founded or _asked
		if founded:
			_release.text = "SETTLERS RELEASED"
	if _deposit != null:
		var carried := roundi(_carried_biomass)
		_deposit.disabled = not founded or carried <= 0
		_deposit.text = "ADD ALL (%d)" % carried \
			if carried > 0 else "ADD ALL"
	if _deposit_100 != null:
		_deposit_100.disabled = not founded
		_deposit_100.text = "ADD 100 BIOMASS"
	if _rename_lane != null:
		var can_rename := bool(report.get("can_rename", false))
		_rename_lane.visible = can_rename
		if can_rename and _rename_field != null \
				and not _rename_field.has_focus():
			_rename_field.placeholder_text = String(
				report.get("display_name", "Settlement"))
	var meeps_variant: Variant = report.get("meeps", [])
	var roster_revision := int(report.get(
		"meep_roster_revision", _meep_roster_revision + 1))
	if roster_revision != _meep_roster_revision:
		_meep_roster_revision = roster_revision
		_refresh_meeps(meeps_variant as Array if meeps_variant is Array else [])
	var offers_variant: Variant = report.get("purchase_offers", {})
	var offers := offers_variant as Dictionary \
		if offers_variant is Dictionary else {}
	for key_variant: Variant in _purchase_buttons:
		var key := String(key_variant)
		var offer_variant: Variant = offers.get(key, {})
		_refresh_purchase(key, offer_variant as Dictionary
			if offer_variant is Dictionary else {}, founded)


func _refresh_meeps(roster: Array) -> void:
	if _roster_grid == null:
		return
	var seen: Dictionary = {}
	var next_texts: Dictionary = {}
	var next_alive: Array[Dictionary] = []
	var next_dead: Array[Dictionary] = []
	for row_variant: Variant in roster:
		if not row_variant is Dictionary:
			continue
		var row := row_variant as Dictionary
		var index := int(row.get("index", -1))
		if index < 0 or seen.has(index):
			continue
		seen[index] = true
		var snapshot: Dictionary = row.duplicate(true)
		var dead := String(snapshot.get("status", "alive")).to_lower() == "dead"
		next_texts[index] = _meep_text(snapshot, dead)
		if dead:
			next_dead.append(snapshot)
		else:
			next_alive.append(snapshot)
	_meep_row_texts = next_texts
	_alive_roster = next_alive
	_dead_roster = next_dead
	_alive_toggle.text = "ALIVE  %d" % _alive_roster.size()
	_dead_toggle.text = "DEAD  %d" % _dead_roster.size()
	_refresh_roster_segment()


func _on_roster_segment_pressed(show_dead: bool) -> void:
	_show_dead = show_dead
	_alive_toggle.set_pressed_no_signal(not _show_dead)
	_dead_toggle.set_pressed_no_signal(_show_dead)
	_refresh_roster_segment()


func _refresh_roster_segment() -> void:
	if _roster_grid == null:
		return
	if _show_dead:
		_roster_grid.set_rows(_dead_roster)
	else:
		_roster_grid.set_rows(_alive_roster)


func _meep_text(row: Dictionary, dead: bool) -> String:
	var meep_name := String(row.get("name", "Meep"))
	var meep_type := String(row.get(
		"type", row.get("meep_type", "Meep")
	)).strip_edges()
	if meep_type.is_empty():
		meep_type = "Meep"
	var age := _duration(float(row.get("age_seconds", 0.0)))
	var sibling := String(row.get("sibling", "None"))
	if dead:
		return (
			"%s  •  TYPE: %s  •  AGE %s\n"
			+ "DIED %s  •  %s\nHEALTH: %d/%d HP  •  SIBLING: %s"
		) % [
			meep_name, meep_type, age,
			_ago(float(row.get("death_seconds_ago", 0.0))),
			String(row.get("death_cause", "Killed in combat")),
			roundi(float(row.get("health", 0.0))),
			roundi(float(row.get("maximum_health", 0.0))), sibling]
	return (
		"%s  •  TYPE: %s  •  AGE %s\n"
		+ "%s  •  %d/%d HP\nHOME: %s  •  SIBLING: %s"
	) % [
		meep_name, meep_type, age, String(row.get("activity", "Idle")),
		roundi(float(row.get("health", 0.0))),
		roundi(float(row.get("maximum_health", 0.0))),
		String(row.get("home", "Unhoused")), sibling]


func _duration(seconds: float) -> String:
	var total := maxi(floori(maxf(seconds, 0.0)), 0)
	if total < 60:
		return "%ds" % total
	if total < 3600:
		return "%dm %ds" % [total / 60, total % 60]
	if total < 86400:
		return "%dh %dm" % [total / 3600, (total % 3600) / 60]
	return "%dd %dh" % [total / 86400, (total % 86400) / 3600]


func _ago(seconds: float) -> String:
	return "just now" if seconds < 1.0 else "%s ago" % _duration(seconds)


func _refresh_purchase(key: String, offer: Dictionary, founded: bool) -> void:
	var button := _purchase_buttons.get(key) as Button
	var value := _purchase_values.get(key) as Label
	if button == null or value == null:
		return
	var status := String(offer.get("status", "locked"))
	var shown := String(offer.get("value", status.to_upper()))
	var shortfall := maxf(float(offer.get("shortfall", 0.0)), 0.0)
	if status == "available" and shortfall > 0.0001:
		var need := ceili(shortfall)
		shown = "%s  •  NEED %d" % [shown, need] \
			if shown != "AVAILABLE" else "NEED %d BIOMASS" % need
	elif status == "requested":
		shown = "COMMISSIONED — PENDING WORK" \
			if shown == "REQUESTED" else shown
	elif status == "built":
		shown = "PURCHASED" if shown == "BUILT" else shown
	elif status == "maxed":
		shown = "MAXIMUM LEVEL"
	elif status == "token_ready":
		shown = "ONE LAUNCH READY"
	elif status == "ability_ready":
		shown = "%s  •  ONE USE" % shown
	elif status == "locked":
		shown = "LOCKED"
	value.text = shown

	var purchase_id := int(offer.get("purchase_id", -1))
	button.set_meta(&"purchase_id", purchase_id)
	button.disabled = not founded or purchase_id < 0 \
		or not bool(offer.get("enabled", false))
	var cost := roundi(float(offer.get("cost", 0.0)))
	match status:
		"available":
			var verb := "PURCHASE"
			if key == "build_speed" or key == "move_speed":
				verb = "UPGRADE"
			elif key == "bridges" or key == "coasts":
				verb = "UNLOCK"
			elif key == "second_cloner" or key == "third_cloner" \
					or key == "fourth_cloner" or key == "hat_house" \
					or key == "abilities_house" \
					or key == "biomass_harvester":
				verb = "COMMISSION"
			elif key == "abilities_house_tower":
				verb = "UPGRADE"
			elif key == "send_settlement":
				verb = "BUY ONE-TIME"
			button.text = "%s — %d BIOMASS" % [verb, cost]
		"requested":
			button.text = "PURCHASED — PENDING WORK"
		"built":
			button.text = "PURCHASED"
		"maxed":
			button.text = "MAXIMUM"
		"token_ready":
			button.text = "LAUNCH TOKEN READY"
		"ability_ready":
			button.text = "OWNED — ASSIGN IN ABILITIES TAB"
		_:
			button.text = "LOCKED"


func _refresh_after_action() -> void:
	# Local/host actions mutate the report synchronously, so this first read is
	# immediate. Client actions keep the short refresh burst alive for the reply.
	_refresh()
	_action_refresh_left = ACTION_REFRESH_SECONDS
	_refresh_left = 0.0


func _on_release_pressed() -> void:
	if _asked:
		return
	# One press. The host answers over the network, so the button stops asking
	# rather than waiting to be told that it worked.
	_asked = true
	if _release != null:
		_release.disabled = true
	release_settlers_requested.emit()
	_refresh_after_action()


func _on_deposit_pressed() -> void:
	if _deposit == null or _deposit.disabled or _carried_biomass <= 0.0:
		return
	deposit_biomass_requested.emit(_carried_biomass)
	_refresh_after_action()


func _on_deposit_100_pressed() -> void:
	if _deposit_100 == null or _deposit_100.disabled:
		return
	add_100_biomass_requested.emit()
	_refresh_after_action()


func _on_rename_pressed() -> void:
	if _rename_field == null or _rename_field.text.strip_edges().is_empty():
		return
	settlement_rename_requested.emit(_rename_field.text)
	_rename_field.clear()
	_refresh_after_action()


func _on_purchase_pressed(key: String) -> void:
	var button := _purchase_buttons.get(key) as Button
	if button == null or button.disabled:
		return
	var purchase_id := int(button.get_meta(&"purchase_id", -1))
	if purchase_id >= 0:
		city_purchase_requested.emit(purchase_id)
		_refresh_after_action()


## Takes the panel down. Whoever opened it is responsible for the mouse, which is
## what [signal closed] is for.
func close() -> void:
	closed.emit()
	queue_free()
