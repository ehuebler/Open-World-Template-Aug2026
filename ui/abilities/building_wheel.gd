class_name BuildingWheel
extends Control

## Mouse-directed utility wheel opened by [BuildingAbility]. The root ignores
## mouse buttons so the held ability receives its release edge; the launcher
## picker switches to ordinary buttons after that release has already happened.

signal launcher_chosen(parent_site: StringName)
signal picker_cancelled

enum Option {
	CITY,
	SETTLEMENT,
	BLUEPRINT,
}

const CITY_ICON := preload(
	"res://assets/runtime/abilities/icons/build_city.svg")
const SETTLEMENT_ICON := preload(
	"res://assets/runtime/abilities/icons/settlement_launcher.svg")
const BLUEPRINT_ICON := preload(
	"res://assets/runtime/abilities/icons/build_blueprint.svg")

const INNER_RADIUS := 58.0
const OUTER_RADIUS := 168.0
const DEAD_ZONE := 46.0
const CARD_SIZE := Vector2(142.0, 92.0)
const OPTION_ANGLES := [
	-PI * 0.5,
	PI / 6.0,
	PI * 5.0 / 6.0,
]
const OPTION_LABELS := [
	"NEAREST CITY",
	"SETTLEMENT",
	"BLUEPRINTS",
]

var _city_available := false
var _launchers: Array[Dictionary] = []
var _selected := -1
var _picker_open := false
var _option_cards: Array[Control] = []
var _status: Label
var _picker: PanelContainer
var _launcher_labels := PackedStringArray()


func _init() -> void:
	name = "BuildingWheel"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 120


func configure(city_available: bool,
		launchers: Array[Dictionary]) -> void:
	_city_available = city_available
	_launchers.clear()
	for launcher: Dictionary in launchers:
		_launchers.append(launcher.duplicate(true))


func _ready() -> void:
	_build_option_cards()
	_status = Label.new()
	_status.name = "BuildingWheelStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.add_theme_color_override(&"font_color", Color("f8e8c5"))
	_status.add_theme_font_size_override(&"font_size", 15)
	add_child(_status)
	_layout()
	_refresh_selection()
	call_deferred(&"_centre_pointer")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_layout()
		queue_redraw()


func _process(_delta: float) -> void:
	if _picker_open or not is_inside_tree():
		return
	update_selection_from_point(get_viewport().get_mouse_position())


func selected_option() -> int:
	return _selected


func option_enabled(option: int) -> bool:
	match option:
		Option.CITY:
			return _city_available
		Option.SETTLEMENT:
			return not _launchers.is_empty()
		Option.BLUEPRINT:
			return true
	return false


func launcher_count() -> int:
	return _launchers.size()


func picker_open() -> bool:
	return _picker_open


func picker_count() -> int:
	return _launcher_labels.size()


func picker_labels() -> PackedStringArray:
	return _launcher_labels.duplicate()


## Public so deterministic UI harnesses can exercise the same directional
## selection law without relying on an operating-system cursor.
func update_selection_from_point(point: Vector2) -> void:
	var away := point - size * 0.5
	var next := -1
	if away.length() >= DEAD_ZONE:
		var direction := away.normalized()
		var best_dot := -2.0
		for option in Option.size():
			var angle: float = OPTION_ANGLES[option]
			var option_direction := Vector2(cos(angle), sin(angle))
			var alignment := direction.dot(option_direction)
			if alignment > best_dot:
				best_dot = alignment
				next = option
	if next == _selected:
		return
	_selected = next
	_refresh_selection()


func clear_selection() -> void:
	if _selected == -1:
		return
	_selected = -1
	_refresh_selection()


func point_for_option(option: int) -> Vector2:
	if option < 0 or option >= Option.size():
		return size * 0.5
	var angle: float = OPTION_ANGLES[option]
	return size * 0.5 + Vector2(cos(angle), sin(angle)) \
		* ((INNER_RADIUS + OUTER_RADIUS) * 0.5)


func show_launcher_picker() -> void:
	if _picker_open or _launchers.size() < 2:
		return
	_picker_open = true
	_selected = -1
	_refresh_selection()
	_launcher_labels.clear()

	_picker = PanelContainer.new()
	_picker.name = "SettlementLauncherPicker"
	_picker.mouse_filter = Control.MOUSE_FILTER_STOP
	_picker.anchor_left = 0.5
	_picker.anchor_top = 0.5
	_picker.anchor_right = 0.5
	_picker.anchor_bottom = 0.5
	var height := minf(174.0 + float(_launchers.size()) * 48.0, 382.0)
	_picker.offset_left = -210.0
	_picker.offset_top = -height * 0.5
	_picker.offset_right = 210.0
	_picker.offset_bottom = height * 0.5
	_picker.add_theme_stylebox_override(&"panel", _panel_style())
	add_child(_picker)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 8)
	_picker.add_child(column)

	var title := Label.new()
	title.text = "SETTLEMENT LAUNCHER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override(&"font_color", Color("f0b85a"))
	title.add_theme_font_size_override(&"font_size", 18)
	column.add_child(title)

	var prompt := Label.new()
	prompt.text = "Choose the parent city"
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_color_override(&"font_color", Color("b8c8d8"))
	prompt.add_theme_font_size_override(&"font_size", 12)
	column.add_child(prompt)

	var scroll := ScrollContainer.new()
	scroll.name = "SettlementLauncherScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	var list := VBoxContainer.new()
	list.name = "SettlementLauncherList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override(&"separation", 5)
	scroll.add_child(list)
	for launcher: Dictionary in _launchers:
		var parent := StringName(String(launcher.get("parent_site", "")))
		var parent_city := String(
			launcher.get("parent_city", parent)).strip_edges()
		var unique_title := String(launcher.get("title", "")).strip_edges()
		var label := parent_city
		if not unique_title.is_empty() \
				and unique_title.casecmp_to(parent_city) != 0:
			label += "  //  %s" % unique_title
		_launcher_labels.push_back(label)
		var button := Button.new()
		button.text = label
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 42.0
		button.add_theme_color_override(&"font_color", Color("eaf7f2"))
		button.add_theme_color_override(&"font_hover_color", Color("f5c96e"))
		button.pressed.connect(_choose_launcher.bind(parent))
		list.add_child(button)

	var cancel := Button.new()
	cancel.name = "SettlementLauncherCancel"
	cancel.text = "CANCEL"
	cancel.custom_minimum_size.y = 34.0
	cancel.pressed.connect(func() -> void:
		picker_cancelled.emit())
	column.add_child(cancel)
	queue_redraw()


func _build_option_cards() -> void:
	var icons: Array[Texture2D] = [
		CITY_ICON,
		SETTLEMENT_ICON,
		BLUEPRINT_ICON,
	]
	for option in Option.size():
		var card := VBoxContainer.new()
		card.name = "BuildingOption_%s" % OPTION_LABELS[option]
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.size = CARD_SIZE
		card.add_theme_constant_override(&"separation", 3)
		add_child(card)

		var icon_centre := CenterContainer.new()
		icon_centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_centre.custom_minimum_size = Vector2(CARD_SIZE.x, 58.0)
		card.add_child(icon_centre)
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.custom_minimum_size = Vector2(54.0, 54.0)
		icon.texture = icons[option]
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon_centre.add_child(icon)

		var label := Label.new()
		label.name = "Label"
		label.text = OPTION_LABELS[option]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override(&"font_size", 12)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(label)
		_option_cards.append(card)


func _choose_launcher(parent: StringName) -> void:
	launcher_chosen.emit(parent)


func _layout() -> void:
	var centre := size * 0.5
	var distance := (INNER_RADIUS + OUTER_RADIUS) * 0.5
	for option in mini(_option_cards.size(), Option.size()):
		var angle: float = OPTION_ANGLES[option]
		var at := centre + Vector2(cos(angle), sin(angle)) * distance
		_option_cards[option].position = at - CARD_SIZE * 0.5
		_option_cards[option].size = CARD_SIZE
	if _status != null:
		_status.position = centre - Vector2(118.0, 27.0)
		_status.size = Vector2(236.0, 54.0)


func _refresh_selection() -> void:
	for option in _option_cards.size():
		var enabled := option_enabled(option)
		var card := _option_cards[option]
		card.modulate = (
			Color.WHITE
			if enabled and option == _selected
			else Color(0.78, 0.82, 0.86, 0.84)
			if enabled
			else Color(0.38, 0.42, 0.47, 0.72)
		)
	if _status != null:
		if _picker_open:
			_status.text = ""
		elif _selected < 0:
			_status.text = "BUILD\nMOVE TO SELECT"
		elif option_enabled(_selected):
			_status.text = OPTION_LABELS[_selected]
			if _selected == Option.SETTLEMENT:
				_status.text += "\n%d AVAILABLE" % _launchers.size()
		else:
			_status.text = "%s\nUNAVAILABLE" % OPTION_LABELS[_selected]
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.025, 0.04, 0.58))
	var centre := size * 0.5
	var half_wedge := TAU / 6.0 - 0.035
	for option in Option.size():
		var enabled := option_enabled(option)
		var selected := option == _selected and not _picker_open
		var fill := Color(0.11, 0.18, 0.22, 0.94)
		var edge := Color(0.35, 0.48, 0.55, 0.9)
		if not enabled:
			fill = Color(0.08, 0.095, 0.115, 0.92)
			edge = Color(0.24, 0.27, 0.31, 0.78)
		elif selected:
			fill = Color(0.30, 0.20, 0.07, 0.98)
			edge = Color("f0b85a")
		draw_colored_polygon(_wedge(
			centre, OPTION_ANGLES[option] - half_wedge,
			OPTION_ANGLES[option] + half_wedge), fill)
		var angle: float = OPTION_ANGLES[option]
		var radial := Vector2(cos(angle), sin(angle))
		var tangent := Vector2(-radial.y, radial.x)
		var start := centre + radial * INNER_RADIUS
		var finish := centre + radial * OUTER_RADIUS
		draw_line(start - tangent * 2.0, finish - tangent * 2.0,
			Color(edge, 0.24), 2.0, true)
		draw_arc(centre, OUTER_RADIUS, angle - half_wedge,
			angle + half_wedge, 22, edge, 3.0 if selected else 1.5, true)
	draw_circle(centre, INNER_RADIUS - 3.0, Color(0.025, 0.04, 0.055, 0.98))
	draw_arc(centre, INNER_RADIUS - 3.0, 0.0, TAU, 48,
		Color("f0b85a") if _selected >= 0 else Color("667887"), 2.0, true)


func _wedge(centre: Vector2, from_angle: float,
		to_angle: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	const STEPS := 20
	for step in STEPS + 1:
		var angle := lerpf(from_angle, to_angle, float(step) / STEPS)
		points.push_back(
			centre + Vector2(cos(angle), sin(angle)) * OUTER_RADIUS)
	for step in STEPS + 1:
		var angle := lerpf(to_angle, from_angle, float(step) / STEPS)
		points.push_back(
			centre + Vector2(cos(angle), sin(angle)) * INNER_RADIUS)
	return points


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.045, 0.06, 0.98)
	style.border_color = Color("f0b85a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14.0
	style.content_margin_top = 12.0
	style.content_margin_right = 14.0
	style.content_margin_bottom = 12.0
	return style


func _centre_pointer() -> void:
	if is_inside_tree() and not _picker_open:
		Input.warp_mouse(size * 0.5)
