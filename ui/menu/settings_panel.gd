class_name SettingsPanel
extends VBoxContainer

## The settings screen, in one place for both the ways it is reached: the home
## screen puts it up over the starfield, and the Settings tab of [GameMenu] puts
## the same thing over a paused world.
##
## One panel rather than two because a setting is a setting — a second in-game copy
## would be a second place for the rows, the write-through and the rebind capture
## to drift, and the pair would disagree about defaults the first time one of them
## gained a row. What differs between the two is only the frame around it, which is
## [method configure]: on the home screen the panel draws its own card and a
## heading and offers BACK; in game the tab it sits in is already the card, so it
## draws neither and offers LEAVE GAME instead.
##
## Sections are four buttons over one content area rather than a [TabContainer].
## A tab container brings its own tab strip, and inside [GameMenu] that would be a
## second row of tabs under the first, in a style nothing else here uses.
##
## The controls list is generated from [InputMap], so a new action is rebindable
## with no edit in this file.

signal closed
## In-game only: the player asked to leave the session. Raised rather than acted
## on, because what leaving means — drop the peer, reload the world, go back to the
## home screen — belongs to whoever opened this.
signal leave_requested

const SettingsManagerScript := preload("res://core/settings_manager.gd")
const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

## Section name and the builder for it. Walked to make both the buttons and the
## pages, so the two cannot fall out of order.
const SECTIONS: Array[String] = ["Display", "Audio", "Gameplay", "Controls / Info"]

var _settings: GameSettingsManager
## While a rebind row is armed, the next key or button press belongs to it rather
## than to the menu, which is why this is read in _input and not _unhandled_input.
var _rebind_action: StringName
var _rebind_button: Button
var _in_game := false
var _section := 0
var _section_row: HBoxContainer
var _content: MarginContainer


## Called before the panel enters the tree. In game it drops its own card and
## heading — the tab is the card — and swaps BACK for LEAVE GAME.
func configure(in_game: bool) -> void:
	_in_game = in_game


func _ready() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_settings = get_node_or_null("/root/SettingsManager") as GameSettingsManager
	if _settings == null:
		_settings = SettingsManagerScript.new()
		_settings.name = "LocalSettingsManager"
		add_child(_settings)
	_build()


func _input(event: InputEvent) -> void:
	if _rebind_button == null:
		return
	if event is InputEventKey and not event.pressed:
		return
	if event is InputEventMouseButton and not event.pressed:
		return
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton:
		_settings.rebind_action(_rebind_action, event)
		_rebind_button.text = event.as_text()
		_rebind_button = null
		_rebind_action = &""
		get_viewport().set_input_as_handled()


## Rebuilt wholesale after a reset to defaults, so every control re-reads the
## value it is showing instead of being walked back one at a time.
func _build() -> void:
	for child: Node in get_children():
		if child != _settings:
			child.queue_free()

	var box := self as Control
	if not _in_game:
		var card := MenuWidgets.card(self, 24, true)
		card.custom_minimum_size = Vector2(MenuWidgets.panel_width(self, 0.84, 1240.0), 0)
		card.add_child(MenuWidgets.heading("SETTINGS", 44))
		card.add_child(MenuWidgets.caption("Changes are saved as you make them."))
		card.add_child(PencilSurface.rule())
		box = card

	_section_row = HBoxContainer.new()
	_section_row.add_theme_constant_override("separation", 12)
	box.add_child(_section_row)

	_content = MarginContainer.new()
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.custom_minimum_size = Vector2(0, 190)
	box.add_child(_content)

	box.add_child(_footer())
	show_section(_section)


## The section buttons, redrawn on every switch so the chosen one carries the gold
## fill. Colour is the only thing that marks it: the rule everywhere in this UI is
## that state is shading and meaning is hue, and "which section am I in" is meaning.
func _fill_section_row() -> void:
	for child in _section_row.get_children():
		child.queue_free()
	for index in SECTIONS.size():
		var button := MenuWidgets.button(SECTIONS[index],
			PencilSurface.Style.PRIMARY if index == _section else PencilSurface.Style.BUTTON)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 18)
		var chosen := index
		button.pressed.connect(func() -> void: show_section(chosen))
		_section_row.add_child(button)


## Switches section. Public because a harness photographs each one, and because the
## in-game tab may one day want to open straight on the controls list.
func show_section(index: int) -> void:
	_section = clampi(index, 0, SECTIONS.size() - 1)
	_fill_section_row()
	for child in _content.get_children():
		child.queue_free()
	var page: VBoxContainer
	match _section:
		0: page = _display_section()
		1: page = _audio_section()
		2: page = _gameplay_section()
		_: page = _controls_section()
	_content.add_child(_scrolled(page))


func _footer() -> Control:
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 14)
	var reset := MenuWidgets.button("RESET DEFAULTS")
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset.pressed.connect(func() -> void:
		_settings.reset_to_defaults()
		_build()
	)
	actions.add_child(reset)

	if _in_game:
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(spacer)
		var leave := MenuWidgets.button("LEAVE GAME", PencilSurface.Style.DANGER)
		leave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		leave.pressed.connect(func() -> void:
			_settings.save_settings()
			leave_requested.emit()
		)
		actions.add_child(leave)
		return actions

	var back := MenuWidgets.button("BACK", PencilSurface.Style.PRIMARY)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.pressed.connect(func() -> void:
		_settings.save_settings()
		closed.emit()
	)
	actions.add_child(back)
	return actions


func _section_box() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	return box


## Every section scrolls. The card has to fit between the title and the foot of
## the screen, and the rebind list alone is longer than that at any size the type
## is actually readable at.
func _scrolled(box: VBoxContainer) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The scrollbar is drawn over the content, not beside it, so without this it
	# sits on the right-hand end of every slider and on the value above it.
	var inset := MarginContainer.new()
	inset.add_theme_constant_override(&"margin_right", 20)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(box)
	scroll.add_child(inset)
	return scroll


func _display_section() -> VBoxContainer:
	var tab := _section_box()
	tab.add_child(MenuWidgets.option_row(
		"Window mode",
		["Windowed", "Borderless fullscreen", "Exclusive fullscreen"],
		int(_settings.get_setting(&"graphics", &"window_mode", 0)),
		func(value: int) -> void: _write(&"graphics", &"window_mode", value)
	))
	var resolutions := ["1280x720", "1600x900", "1920x1080", "2560x1440"]
	var saved_resolution := String(_settings.get_setting(&"graphics", &"resolution", "1280x720"))
	tab.add_child(MenuWidgets.option_row(
		"Resolution",
		resolutions,
		maxi(resolutions.find(saved_resolution), 0),
		func(value: int) -> void: _write(&"graphics", &"resolution", resolutions[value])
	))
	tab.add_child(MenuWidgets.toggle_row(
		"Vertical sync",
		bool(_settings.get_setting(&"graphics", &"vsync", true)),
		func(value: bool) -> void: _write(&"graphics", &"vsync", value)
	))
	tab.add_child(MenuWidgets.slider_row(
		"Frame rate limit", 30.0, 240.0, 10.0,
		float(_settings.get_setting(&"graphics", &"max_fps", 120)),
		func(value: float) -> void: _write(&"graphics", &"max_fps", int(value)),
		" FPS"
	))
	tab.add_child(MenuWidgets.slider_row(
		"Render scale", 0.5, 2.0, 0.05,
		float(_settings.get_setting(&"graphics", &"render_scale", 1.0)),
		func(value: float) -> void: _write(&"graphics", &"render_scale", value),
		"x"
	))
	tab.add_child(MenuWidgets.option_row(
		"Graphics quality",
		["Low", "Medium", "High"],
		int(_settings.get_setting(&"graphics", &"quality", 1)),
		func(value: int) -> void: _write(&"graphics", &"quality", value)
	))
	# Labelled by the planet, so the row cannot come to offer a level the terrain
	# does not have.
	var distances: Array[String] = []
	for level: Dictionary in Planet.DETAIL_LEVELS:
		distances.append(String(level["label"]))
	tab.add_child(MenuWidgets.option_row(
		"Render distance",
		distances,
		int(_settings.get_setting(&"graphics", &"render_distance", 1)),
		func(value: int) -> void: _write(&"graphics", &"render_distance", value)
	))
	return tab


func _audio_section() -> VBoxContainer:
	var tab := _section_box()
	for setting: Dictionary in [
		{"label": "Master volume", "key": &"master_volume"},
		{"label": "Music volume", "key": &"music_volume"},
		{"label": "Sound effects", "key": &"sfx_volume"},
		{"label": "Voice chat", "key": &"voice_volume"},
	]:
		var key: StringName = setting.key
		tab.add_child(MenuWidgets.slider_row(
			setting.label, 0.0, 1.0, 0.01,
			float(_settings.get_setting(&"audio", key, 0.8)),
			func(value: float) -> void: _write(&"audio", key, value),
			"%"
		))
	return tab


func _gameplay_section() -> VBoxContainer:
	var tab := _section_box()
	tab.add_child(MenuWidgets.slider_row(
		"Mouse sensitivity", 0.05, 1.0, 0.05,
		float(_settings.get_setting(&"gameplay", &"mouse_sensitivity", 0.35)),
		func(value: float) -> void: _write(&"gameplay", &"mouse_sensitivity", value)
	))
	tab.add_child(MenuWidgets.toggle_row(
		"Invert vertical look",
		bool(_settings.get_setting(&"gameplay", &"invert_y", false)),
		func(value: bool) -> void: _write(&"gameplay", &"invert_y", value)
	))
	tab.add_child(MenuWidgets.slider_row(
		"Field of view", 60.0, 110.0, 1.0,
		float(_settings.get_setting(&"gameplay", &"fov", 75.0)),
		func(value: float) -> void: _write(&"gameplay", &"fov", value),
		"deg"
	))
	return tab


## The rebind list, and the handful of facts worth being able to read back without
## leaving the game.
func _controls_section() -> VBoxContainer:
	var tab := _section_box()
	var found_actions := false
	for action: StringName in InputMap.get_actions():
		if String(action).begins_with("ui_"):
			continue
		found_actions = true
		tab.add_child(_rebind_row(action))
	if not found_actions:
		tab.add_child(MenuWidgets.caption(
			"Input actions appear here after they are added to the Input Map."))

	tab.add_child(PencilSurface.rule())
	var about := Label.new()
	about.text = "Godot %s    %s" % [
		Engine.get_version_info().get("string", "?"),
		"multiplayer" if NetworkManager != null and NetworkManager.in_multiplayer_session() \
			else "single player",
	]
	about.add_theme_font_size_override("font_size", 16)
	about.add_theme_color_override("font_color", PALETTE.text_muted)
	tab.add_child(about)
	return tab


func _rebind_row(action: StringName) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = String(action).replace("_", " ").capitalize()
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var control := MenuWidgets.button(MenuWidgets.binding_text(action))
	control.custom_minimum_size.x = 180
	control.pressed.connect(func() -> void:
		if _rebind_button != null:
			_rebind_button.text = MenuWidgets.binding_text(_rebind_action)
		_rebind_action = action
		_rebind_button = control
		control.text = "PRESS A KEY..."
	)
	row.add_child(control)
	return row


func _write(section: StringName, key: StringName, value: Variant) -> void:
	_settings.set_setting(section, key, value)
	_settings.save_settings()
