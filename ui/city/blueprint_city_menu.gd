class_name BlueprintCityMenu
extends Control

signal closed
signal population_changed(population: int)

const PLATE_SIZE := Vector2(480.0, 480.0)
const REFRESH_INTERVAL := 0.15

var _report: Callable
var _population: SpinBox
var _growth: Label
var _tier: Label
var _housing: Label
var _status: Label
var _refresh_left := 0.0
var _refreshing := false


func _init() -> void:
	name = "BlueprintCityMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP


func configure(report: Callable) -> void:
	_report = report
	if is_inside_tree():
		_refresh()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_refresh()


func _process(delta: float) -> void:
	_refresh_left -= maxf(delta, 0.0)
	if _refresh_left <= 0.0:
		_refresh_left = REFRESH_INTERVAL
		_refresh()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") \
			or event.is_action_pressed(&"inventory"):
		get_viewport().set_input_as_handled()
		close()


func population_control() -> SpinBox:
	return _population


func growth_text() -> String:
	return _growth.text if _growth != null else ""


func status_text() -> String:
	return _status.text if _status != null else ""


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.005, 0.025, 0.055, 0.52)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var plate := RedGlowPanel.new()
	plate.name = "Plate"
	plate.custom_minimum_size = PLATE_SIZE
	plate.fill_color = Color(0.005, 0.025, 0.045, 0.96)
	plate.border_color = Color(0.18, 0.72, 1.0, 0.98)
	plate.border_width = 2.0
	plate.glow_intensity = 1.35
	plate.glow_spread = 12.0
	plate.glow_layers = 5
	plate.mouse_behavior = RedGlowPanel.MouseBehavior.STOP
	centre.add_child(plate)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: StringName in [&"margin_left", &"margin_right"]:
		margin.add_theme_constant_override(side, 28)
	for side: StringName in [&"margin_top", &"margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	plate.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 14)
	margin.add_child(column)

	var title := Label.new()
	title.text = "BLUEPRINT // CITY PROJECTION"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 22)
	title.add_theme_color_override(
		&"font_color", Color(0.48, 0.86, 1.0))
	column.add_child(title)

	var help := Label.new()
	help.text = "Set a dummy population to rebuild the planned city."
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_color_override(&"font_color", Color(0.68, 0.78, 0.86))
	column.add_child(help)

	var population_row := HBoxContainer.new()
	population_row.name = "PopulationRow"
	population_row.add_theme_constant_override(&"separation", 12)
	column.add_child(population_row)
	var population_label := Label.new()
	population_label.text = "DUMMY POPULATION"
	population_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	population_label.add_theme_color_override(
		&"font_color", Color(0.72, 0.86, 0.94))
	population_row.add_child(population_label)
	_population = SpinBox.new()
	_population.name = "DummyPopulation"
	_population.min_value = MeepBlueprintPreviewRegistry.MIN_POPULATION
	_population.max_value = MeepBlueprintPreviewRegistry.MAX_POPULATION
	_population.step = 1.0
	_population.allow_greater = false
	_population.allow_lesser = false
	_population.custom_minimum_size = Vector2(140.0, 38.0)
	_population.value_changed.connect(_on_population_changed)
	population_row.add_child(_population)

	var presets := HBoxContainer.new()
	presets.name = "PopulationPresets"
	presets.add_theme_constant_override(&"separation", 8)
	column.add_child(presets)
	_preset_button(presets, "STARTER", MeepColony.STARTER_POPULATION)
	_preset_button(presets, "1,000", 1000)
	_preset_button(presets, "MAX 12,000",
		MeepBlueprintPreviewRegistry.MAX_POPULATION)

	_growth = _value_row(column, "PopulationGrowth", "POPULATION GROWTH")
	_tier = _value_row(column, "ProjectedTier", "PROJECTED TIER")
	_housing = _value_row(column, "ProjectedHousing", "HOUSING CAPACITY")

	_status = Label.new()
	_status.name = "ProjectionStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override(&"font_size", 13)
	_status.add_theme_color_override(
		&"font_color", Color(0.32, 0.82, 1.0))
	column.add_child(_status)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)

	var close_button := Button.new()
	close_button.name = "Close"
	close_button.text = "CLOSE"
	close_button.custom_minimum_size.y = 42.0
	close_button.pressed.connect(close)
	column.add_child(close_button)


func _value_row(column: VBoxContainer, node_name: String,
		caption: String) -> Label:
	var row := HBoxContainer.new()
	row.name = "%sRow" % node_name
	column.add_child(row)
	var key := Label.new()
	key.text = caption
	key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	key.add_theme_color_override(
		&"font_color", Color(0.64, 0.76, 0.84))
	row.add_child(key)
	var value := Label.new()
	value.name = node_name
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_color_override(
		&"font_color", Color(0.88, 0.96, 1.0))
	row.add_child(value)
	return value


func _preset_button(row: HBoxContainer, caption: String,
		value: int) -> void:
	var button := Button.new()
	button.name = "PopulationPreset%d" % value
	button.text = caption
	button.custom_minimum_size.y = 34.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func() -> void:
		if _population != null:
			_population.value = value)
	row.add_child(button)


func _refresh() -> void:
	var report_value: Variant = _report.call() \
		if _report.is_valid() else {}
	var report := report_value as Dictionary \
		if report_value is Dictionary else {}
	if report.is_empty() or _population == null:
		return
	_refreshing = true
	_population.value = int(report.get(
		"population", MeepBlueprintPreviewRegistry.DEFAULT_POPULATION))
	_refreshing = false
	_growth.text = "%.2f MEEPS / MIN" % float(
		report.get("growth_per_minute", 0.0))
	_tier.text = "%d" % int(report.get("tier", 0))
	_housing.text = "%d" % int(report.get(
		"housing_capacity", MeepColony.FIRST_WAVE))
	if bool(report.get("calculating", false)):
		_status.text = "RECALCULATING UNIFIED CITY GRID..."
	elif bool(report.get("stalled", false)):
		_status.text = "PROJECTION LIMITED BY TERRAIN OR BORDER"
	else:
		_status.text = "CITY PROJECTION READY"


func _on_population_changed(value: float) -> void:
	if not _refreshing:
		population_changed.emit(roundi(value))


func close() -> void:
	closed.emit()
	queue_free()
