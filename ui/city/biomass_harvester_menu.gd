class_name BiomassHarvesterMenu
extends Control

## Player-local controls for one completed Biomass Harvester.

signal closed
signal upgrade_requested(purchase_id: int)

const PLATE_SIZE := Vector2(620.0, 500.0)
const BACKDROP := Color(0.02, 0.0, 0.03, 0.52)
const REFRESH_INTERVAL := 0.25

var _report: Callable
var _rows: Dictionary = {}
var _upgrade: Button
var _refresh_left := 0.0


func _init() -> void:
	name = "BiomassHarvesterMenu"
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
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = REFRESH_INTERVAL
		_refresh()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"inventory"):
		get_viewport().set_input_as_handled()
		close()


func upgrade_button() -> Button:
	return _upgrade


func row_text(key: String) -> String:
	var value := _rows.get(key) as Label
	return value.text if value != null else ""


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
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
	plate.fill_color = Color(0.0, 0.0, 0.0, 0.88)
	plate.border_color = Color(0.96, 0.24, 0.62, 0.98)
	plate.border_width = 2.0
	plate.glow_intensity = 1.5
	plate.glow_spread = 13.0
	plate.glow_layers = 5
	plate.mouse_behavior = RedGlowPanel.MouseBehavior.STOP
	centre.add_child(plate)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: StringName in [&"margin_left", &"margin_right"]:
		pad.add_theme_constant_override(side, 32)
	for side: StringName in [&"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 24)
	plate.add_child(pad)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 15)
	pad.add_child(column)

	var title := Label.new()
	title.text = "BIOMASS HARVESTER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 26)
	title.add_theme_color_override(&"font_color", Color(1.0, 0.42, 0.70))
	column.add_child(title)
	column.add_child(_rule())

	_add_row(column, "bank", "CITY BANK")
	_add_row(column, "rate", "CURRENT RATE")
	_add_row(column, "lifetime", "LIFETIME OUTPUT")
	_add_row(column, "level", "RATE LEVEL")
	_add_row(column, "next", "NEXT UPGRADE")
	column.add_child(_rule())

	var upgrade_lane := CenterContainer.new()
	column.add_child(upgrade_lane)
	_upgrade = _button("LOCKED", 330.0)
	_upgrade.name = "UpgradeButton"
	_upgrade.pressed.connect(_on_upgrade_pressed)
	upgrade_lane.add_child(_upgrade)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	column.add_child(_rule())

	var close_lane := CenterContainer.new()
	column.add_child(close_lane)
	var close_button := _button("CLOSE", 150.0)
	close_button.name = "CloseButton"
	close_button.pressed.connect(close)
	close_lane.add_child(close_button)


func _add_row(column: VBoxContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	column.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override(&"font_size", 16)
	label.add_theme_color_override(&"font_color", Color(1.0, 0.58, 0.72))
	row.add_child(label)
	var value := Label.new()
	value.text = "0"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.add_theme_font_size_override(&"font_size", 18)
	value.add_theme_color_override(&"font_color", RedHudTheme.GREEN)
	row.add_child(value)
	_rows[key] = value


func _refresh() -> void:
	if _upgrade == null:
		return
	var report: Dictionary = {}
	if _report.is_valid():
		var answer: Variant = _report.call()
		if answer is Dictionary:
			report = answer as Dictionary
	(_rows["bank"] as Label).text = "%d BIOMASS" % roundi(
		float(report.get("resources", 0.0)))
	(_rows["rate"] as Label).text = "%.1f BIOMASS / SEC" % float(
		report.get("harvester_rate", 0.0))
	(_rows["lifetime"] as Label).text = "%.1f BIOMASS" % float(
		report.get("harvester_lifetime", 0.0))
	var level := int(report.get("harvester_rate_level", 0))
	(_rows["level"] as Label).text = "%d / %d" % [
		level, MeepColony.MAX_HARVEST_RATE_LEVEL]
	var offer_variant: Variant = report.get("harvester_upgrade", {})
	var offer := offer_variant as Dictionary \
		if offer_variant is Dictionary else {}
	var status := String(offer.get("status", "locked"))
	var purchase_id := int(offer.get("purchase_id", -1))
	var cost := roundi(float(offer.get("cost", 0.0)))
	var shortfall := ceili(maxf(float(offer.get("shortfall", 0.0)), 0.0))
	_upgrade.set_meta(&"purchase_id", purchase_id)
	_upgrade.disabled = not bool(offer.get("enabled", false))
	if status == "maxed":
		(_rows["next"] as Label).text = "MAXIMUM"
		_upgrade.text = "MAXIMUM RATE"
	elif status == "available":
		(_rows["next"] as Label).text = "+0.5 / SEC  //  %d BIOMASS" % cost
		_upgrade.text = "UPGRADE — %d BIOMASS" % cost
		if shortfall > 0:
			_upgrade.text = "NEED %d MORE BIOMASS" % shortfall
	else:
		(_rows["next"] as Label).text = "UNAVAILABLE"
		_upgrade.text = "LOCKED"


func _button(caption: String, width: float) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(width, 40.0)
	button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(button, 14, 7.0)
	return button


func _rule() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(0.96, 0.24, 0.62, 0.42)
	line.custom_minimum_size.y = 1.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _on_upgrade_pressed() -> void:
	if _upgrade == null or _upgrade.disabled:
		return
	var purchase_id := int(_upgrade.get_meta(&"purchase_id", -1))
	if MeepColony.is_harvester_rate_purchase(purchase_id):
		upgrade_requested.emit(purchase_id)


func close() -> void:
	closed.emit()
	queue_free()
