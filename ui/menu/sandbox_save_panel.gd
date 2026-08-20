class_name SandboxSavePanel
extends VBoxContainer

## Named sandbox-save browser shared by the in-game Save and Load actions.

signal save_requested(save_id: String, display_name: String)
signal load_requested(save_id: String)

enum Action { SAVE, LOAD }

const RED := Color("ef151f")
const RED_BRIGHT := Color("ff3445")
const RED_TEXT := Color("ff9ca4")
const RED_MUTED := Color("b94a53")
const GREEN := Color("45df68")
const GREEN_TEXT := Color("8ff3a5")

var _action: Action = Action.SAVE
var _active_save_id := ""
var _built := false
var _name_input: LineEdit
var _list: VBoxContainer
var _status: Label


func configure(action: Action, active_save_id := "") -> void:
	_action = action
	_active_save_id = active_save_id
	if _built:
		_rebuild()


func _init() -> void:
	name = "SandboxSavePanel"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	_built = true
	_rebuild()


func show_result(result: Dictionary) -> void:
	var success := bool(result.get("ok", false))
	_status.text = (
		"SAVED  //  %s" % String(result.get("name", "SANDBOX")).to_upper()
		if success else String(result.get("message", "SAVE OPERATION FAILED")))
	_status.add_theme_color_override(
		&"font_color", GREEN_TEXT if success else RED_BRIGHT)
	if success:
		_active_save_id = String(result.get("id", _active_save_id))
		if _name_input != null:
			_name_input.clear()
		_rebuild_rows()


func _rebuild() -> void:
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()

	var heading := Label.new()
	heading.text = (
		"SAVE SANDBOX  //  CREATE OR OVERWRITE"
		if _action == Action.SAVE
		else "LOAD SANDBOX  //  SELECT A SAVE")
	_style_label(heading, GREEN_TEXT, 22)
	add_child(heading)
	add_child(_rule())

	var description := Label.new()
	description.text = (
		"Create a named snapshot, or overwrite an existing one."
		if _action == Action.SAVE
		else "Loading rebuilds the world from the selected snapshot.")
	_style_label(description, RED_MUTED, 12)
	add_child(description)

	if _action == Action.SAVE:
		_build_create_row()

	var scroll := ScrollContainer.new()
	scroll.name = "SandboxSaveScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_list = VBoxContainer.new()
	_list.name = "SandboxSaveRows"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override(&"separation", 7)
	scroll.add_child(_list)
	_rebuild_rows()

	_status = Label.new()
	_status.name = "SandboxSaveStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_label(_status, GREEN_TEXT, 12)
	add_child(_status)


func _build_create_row() -> void:
	var row := HBoxContainer.new()
	row.name = "CreateSandboxSaveRow"
	row.add_theme_constant_override(&"separation", 8)

	_name_input = LineEdit.new()
	_name_input.name = "SandboxSaveName"
	_name_input.placeholder_text = "SAVE NAME"
	_name_input.max_length = SaveManager.MAX_DISPLAY_NAME_LENGTH
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_input.custom_minimum_size.y = 38.0
	_name_input.add_theme_font_size_override(&"font_size", 13)
	_name_input.add_theme_color_override(&"font_color", GREEN_TEXT)
	_name_input.add_theme_color_override(&"caret_color", GREEN)
	_name_input.add_theme_stylebox_override(
		&"normal", _style(Color(0.0, 0.0, 0.0, 0.72), RED, 1, 2.0))
	_name_input.add_theme_stylebox_override(
		&"focus", _style(Color(0.0, 0.08, 0.02, 0.86), GREEN, 2, 2.0))
	_name_input.text_submitted.connect(func(_value: String) -> void:
		_create_pressed()
	)
	row.add_child(_name_input)

	var create := _button("CREATE SAVE")
	create.name = "CreateSandboxSave"
	create.custom_minimum_size.x = 180.0
	create.pressed.connect(_create_pressed)
	row.add_child(create)
	add_child(row)


func _create_pressed() -> void:
	if _name_input == null:
		return
	var clean := SaveManager.clean_display_name(_name_input.text)
	if clean.is_empty():
		_status.text = "ENTER A SAVE NAME"
		_status.add_theme_color_override(&"font_color", RED_BRIGHT)
		return
	save_requested.emit("", clean)


func _rebuild_rows() -> void:
	if _list == null:
		return
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var saves := SaveManager.list_saves("sandbox")
	if saves.is_empty():
		var empty := Label.new()
		empty.name = "NoSandboxSaves"
		empty.text = "NO SANDBOX SAVES YET"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.custom_minimum_size.y = 74.0
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_style_label(empty, RED_MUTED, 14)
		_list.add_child(empty)
		return
	for metadata: Dictionary in saves:
		_list.add_child(_save_row(metadata))


func _save_row(metadata: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)
	var save_id := String(metadata.get("id", ""))
	var display_name := String(metadata.get("name", "Sandbox"))

	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_constant_override(&"separation", 2)
	var title := Label.new()
	title.text = display_name.to_upper() + (
		"  //  ACTIVE" if save_id == _active_save_id else "")
	_style_label(title, GREEN_TEXT if save_id == _active_save_id else RED_TEXT, 14)
	copy.add_child(title)
	var updated := int(metadata.get("updated_unix", 0))
	var detail := Label.new()
	detail.text = (
		Time.get_datetime_string_from_unix_time(updated, true)
		if updated > 0 else "UNKNOWN DATE")
	_style_label(detail, RED_MUTED, 11)
	copy.add_child(detail)
	row.add_child(copy)

	var action := _button(
		"OVERWRITE" if _action == Action.SAVE else "LOAD")
	action.name = (
		"OverwriteSave_%s" % save_id
		if _action == Action.SAVE else "LoadSave_%s" % save_id)
	action.custom_minimum_size = Vector2(154.0, 38.0)
	if _action == Action.SAVE:
		action.pressed.connect(func() -> void:
			save_requested.emit(save_id, display_name)
		)
	else:
		action.pressed.connect(func() -> void:
			load_requested.emit(save_id)
		)
	row.add_child(action)

	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 62.0
	panel.add_theme_stylebox_override(
		&"panel",
		_style(
			Color(0.0, 0.055, 0.015, 0.72),
			GREEN if save_id == _active_save_id else RED,
			2 if save_id == _active_save_id else 1,
			2.0,
			10.0))
	panel.add_child(row)
	return panel


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 36.0
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override(&"font_size", 12)
	button.add_theme_color_override(&"font_color", GREEN_TEXT)
	button.add_theme_stylebox_override(
		&"normal", _style(Color(0.0, 0.08, 0.02, 0.88), RED, 1, 2.0))
	button.add_theme_stylebox_override(
		&"hover", _style(Color(0.0, 0.18, 0.05, 0.94), GREEN, 2, 2.0))
	button.add_theme_stylebox_override(
		&"pressed", _style(Color(0.0, 0.28, 0.08, 0.98), GREEN_TEXT, 2, 2.0))
	button.add_theme_stylebox_override(
		&"focus", _style(Color.TRANSPARENT, GREEN, 2, 2.0))
	return button


func _rule() -> ColorRect:
	var rule := ColorRect.new()
	rule.color = Color(RED, 0.72)
	rule.custom_minimum_size.y = 1.0
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rule


static func _style_label(label: Label, colour: Color, size: int) -> void:
	label.add_theme_color_override(&"font_color", colour)
	label.add_theme_color_override(&"font_outline_color", Color(0.04, 0.0, 0.0, 1.0))
	label.add_theme_constant_override(&"outline_size", 2)
	label.add_theme_font_size_override(&"font_size", size)


static func _style(
		fill: Color,
		border: Color,
		width: int,
		radius: float,
		padding := 8.0
	) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(roundi(radius))
	style.content_margin_left = padding
	style.content_margin_top = padding
	style.content_margin_right = padding
	style.content_margin_bottom = padding
	return style
