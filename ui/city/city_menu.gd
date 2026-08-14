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

const TITLE := "COLONY // CITY CONTROL"
const PLATE_SIZE := Vector2(540.0, 348.0)
const BACKDROP := Color(0.02, 0.0, 0.03, 0.46)
## What the single resource is called. One line to change, and the row it labels
## reads whatever the colony's bank reports without caring.
const RESOURCE_LABEL := "BIOMASS"
## Report reads per second. The host keeps simulating while this is open in
## company, so the figures have to move; four times a second is faster than
## anyone can read and far cheaper than every frame.
const REFRESH_INTERVAL := 0.25
## Shown before a colony exists, so the rows are never blank.
const EMPTY_REPORT := {
	"founded": false,
	"settlers": 0,
	"resources": 0.0,
	"committed": 0.0,
	"structures": 0,
	"raising": 0,
	"timber": 0,
	"doing": "",
}

var _report: Callable
var _rows: Dictionary = {}
var _release: Button
var _status: Label
var _refresh_left := 0.0
var _asked := false


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
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_INTERVAL
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

	# A column of rows rather than a fixed layout: the cloner, construction and
	# any second resource are all another _add_row call from here.
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override(&"separation", 12)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(column)

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
	column.add_child(title)

	column.add_child(_rule())
	_add_row(column, "settlers", "SETTLERS")
	_add_row(column, "resources", RESOURCE_LABEL)
	_add_row(column, "structures", "STRUCTURES")
	_add_row(column, "timber", "TIMBER STANDING")
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

	var close_lane := CenterContainer.new()
	close_lane.name = "CloseLane"
	close_lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(close_lane)

	var close_button := Button.new()
	close_button.name = "CloseButton"
	close_button.text = "CLOSE"
	close_button.custom_minimum_size = Vector2(150.0, 34.0)
	close_button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(close_button, 13, 6.0)
	close_button.pressed.connect(close)
	close_lane.add_child(close_button)


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
	if _rows.has("settlers"):
		(_rows["settlers"] as Label).text = str(settlers)
	if _rows.has("resources"):
		# What is spare and what is promised, because a bank showing only its total
		# looks stuck when every unit in it is already spoken for by a building.
		var bank := roundi(float(report.get("resources", 0.0)))
		var held := roundi(float(report.get("committed", 0.0)))
		(_rows["resources"] as Label).text = "%d" % bank if held <= 0 \
			else "%d  (%d held)" % [bank, held]
	if _rows.has("structures"):
		var raised := int(report.get("structures", 0))
		var raising := int(report.get("raising", 0))
		(_rows["structures"] as Label).text = str(raised) if raising <= 0 \
			else "%d  (+%d rising)" % [raised, raising]
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


func _on_release_pressed() -> void:
	if _asked:
		return
	# One press. The host answers over the network, so the button stops asking
	# rather than waiting to be told that it worked.
	_asked = true
	if _release != null:
		_release.disabled = true
	release_settlers_requested.emit()


## Takes the panel down. Whoever opened it is responsible for the mouse, which is
## what [signal closed] is for.
func close() -> void:
	closed.emit()
	queue_free()
