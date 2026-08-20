class_name SpecialtyShop
extends Control

## Player-local catalogue opened only by a completed specialty structure.

signal closed
signal hat_purchase_requested(item_id: String)
signal ability_action_requested(ability_id: String, action: int)
signal ability_stat_upgrade_requested(ability_id: String, stat_id: String)

## Append-only: these values are used by OnlinePlayer's interaction routing.
enum Mode { HATS, ABILITIES }

const PLATE_SIZE := Vector2(760.0, 700.0)
const BACKDROP := Color(0.02, 0.0, 0.03, 0.52)

var _player: OnlinePlayer
var _mode: int = Mode.HATS
var _stats_unlocked := false
var _gold: Label
var _list: VBoxContainer
var _stat_list: VBoxContainer
var _tabs: TabContainer
var _refresh_queued := false
var _hat_buttons: Dictionary = {}
var _ability_buttons: Dictionary = {}
var _stat_buttons: Dictionary = {}


func _init() -> void:
	name = "SpecialtyShop"
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP


func configure(player: OnlinePlayer, mode: int,
		stats_unlocked := false) -> void:
	_player = player
	_mode = clampi(mode, 0, Mode.size() - 1)
	_stats_unlocked = stats_unlocked and _mode == Mode.ABILITIES


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	if _player != null:
		_player.progression_changed.connect(_queue_refresh)
		_player.equipment.changed.connect(_queue_refresh)
		_player.abilities.changed.connect(_queue_refresh)
		_player.backpack.changed.connect(_queue_refresh)
	_refresh()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") or event.is_action_pressed(&"inventory"):
		get_viewport().set_input_as_handled()
		close()


func hat_button(item_id: String) -> Button:
	return _hat_buttons.get(item_id) as Button


func ability_button(ability_id: String, action: int) -> Button:
	return _ability_buttons.get("%s:%d" % [ability_id, action]) as Button


func ability_stat_button(ability_id: String, stat_id: String) -> Button:
	return _stat_buttons.get("%s:%s" % [ability_id, stat_id]) as Button


func tab_container() -> TabContainer:
	return _tabs


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
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
	plate.border_color = Color(RedHudTheme.RED_BRIGHT, 0.98)
	plate.border_width = 2.0
	plate.glow_intensity = 1.5
	plate.glow_spread = 13.0
	plate.glow_layers = 5
	plate.mouse_behavior = RedGlowPanel.MouseBehavior.STOP
	centre.add_child(plate)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: StringName in [&"margin_left", &"margin_right"]:
		pad.add_theme_constant_override(side, 26)
	for side: StringName in [&"margin_top", &"margin_bottom"]:
		pad.add_theme_constant_override(side, 20)
	plate.add_child(pad)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override(&"separation", 10)
	pad.add_child(outer)

	var title := Label.new()
	title.name = "Title"
	title.text = "HAT HOUSE" if _mode == Mode.HATS else "ABILITIES HOUSE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 26)
	title.add_theme_color_override(&"font_color", RedHudTheme.RED_BRIGHT)
	title.add_theme_color_override(
		&"font_outline_color", Color(0.04, 0.0, 0.0, 0.98))
	title.add_theme_constant_override(&"outline_size", 4)
	outer.add_child(title)

	_gold = Label.new()
	_gold.name = "Gold"
	_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold.add_theme_font_size_override(&"font_size", 17)
	_gold.add_theme_color_override(&"font_color", RedHudTheme.GREEN)
	outer.add_child(_gold)
	outer.add_child(_rule())

	if _mode == Mode.ABILITIES:
		_tabs = TabContainer.new()
		_tabs.name = "AbilityTabs"
		_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
		outer.add_child(_tabs)
		var catalogue := _stock_scroll("StockScroll", "Stock")
		_tabs.add_child(catalogue["root"])
		_list = catalogue["list"]
		_tabs.set_tab_title(0, "CATALOGUE")
		var training := _stock_scroll("StatScroll", "StatStock")
		_tabs.add_child(training["root"])
		_stat_list = training["list"]
		_tabs.set_tab_title(1, "STATS")
		_tabs.set_tab_hidden(1, not _stats_unlocked)
	else:
		var stock := _stock_scroll("StockScroll", "Stock")
		outer.add_child(stock["root"])
		_list = stock["list"]

	outer.add_child(_rule())
	var close_lane := CenterContainer.new()
	outer.add_child(close_lane)
	var close_button := _button("CLOSE", 150.0)
	close_button.name = "CloseButton"
	close_button.pressed.connect(close)
	close_lane.add_child(close_button)


func _stock_scroll(scroll_name: String, list_name: String) -> Dictionary:
	var scroll := ScrollContainer.new()
	scroll.name = scroll_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var inset := MarginContainer.new()
	inset.add_theme_constant_override(&"margin_right", 14)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inset)
	var list := VBoxContainer.new()
	list.name = list_name
	list.add_theme_constant_override(&"separation", 14)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(list)
	return {
		"root": scroll,
		"list": list,
	}


func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	call_deferred("_refresh")


func _refresh() -> void:
	_refresh_queued = false
	if _list == null:
		return
	_gold.text = "YOUR GOLD  //  %d" % roundi(
		_player.gold() if _player != null else 0.0)
	for child: Node in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	if _stat_list != null:
		for child: Node in _stat_list.get_children():
			_stat_list.remove_child(child)
			child.queue_free()
	_hat_buttons.clear()
	_ability_buttons.clear()
	_stat_buttons.clear()
	if _mode == Mode.HATS:
		_build_hats()
	else:
		_build_abilities()
		if _stats_unlocked:
			_build_ability_stats()


func _build_hats() -> void:
	for item_id: String in ItemDB.hat_shop_ids():
		var row := _entry(ItemDB.title(item_id), ItemDB.description(item_id))
		var owned := _player != null and _player.owns_hat(item_id)
		var carried := _player != null and _player.owns_physical_item(item_id)
		var equipped := _player != null and _player.equipment.find(item_id) >= 0
		var action := _button(
			"UNEQUIP" if equipped else (
				"EQUIP" if carried else (
					"OWNED — NOT CARRIED" if owned else "GET — FREE")),
			190.0)
		action.disabled = owned and not carried
		action.name = "%sAction" % item_id.to_pascal_case()
		action.pressed.connect(_on_hat_pressed.bind(item_id))
		(row["actions"] as HBoxContainer).add_child(action)
		_hat_buttons[item_id] = action
		_list.add_child(row["root"])
		_list.add_child(_rule())


func _build_abilities() -> void:
	for ability_id: String in ItemDB.reusable_ability_ids():
		var level := _player.ability_level(ability_id) if _player != null else 0
		var detail := "LOCKED" if level <= 0 else "LEVEL %d / %d" % [
			level, ItemDB.MAX_ABILITY_LEVEL]
		var stats := ItemDB.stat_lines(ability_id, maxi(level, 1),
			_player.ability_stat_levels(ability_id) if _player != null else {})
		var summary := PackedStringArray()
		for line: String in stats:
			var key := line.get_slice("\t", 0)
			if key in ["Damage", "Impact", "Duration", "Range", "Radius", "Cooldown"]:
				summary.append(line.replace("\t", " "))
		if not summary.is_empty():
			detail += "\n" + "  •  ".join(summary)
		var row := _entry(
			"%s  //  %s" % [ItemDB.title(ability_id), detail],
			ItemDB.description(ability_id))
		var actions := row["actions"] as HBoxContainer
		if level <= 0:
			_add_ability_action(actions, ability_id,
				OnlinePlayer.AbilityProgressAction.UNLOCK, "UNLOCK — FREE")
		else:
			var upgrade := _add_ability_action(actions, ability_id,
				OnlinePlayer.AbilityProgressAction.UPGRADE,
				"MAX LEVEL" if level >= ItemDB.MAX_ABILITY_LEVEL \
					else "UPGRADE — FREE")
			upgrade.disabled = level >= ItemDB.MAX_ABILITY_LEVEL
			var left := _add_ability_action(actions, ability_id,
				OnlinePlayer.AbilityProgressAction.EQUIP_PRIMARY,
				"LMB EQUIPPED" if _player.abilities.get_item(0) == ability_id \
					else "EQUIP LMB")
			left.disabled = _player.abilities.get_item(0) == ability_id
			var right := _add_ability_action(actions, ability_id,
				OnlinePlayer.AbilityProgressAction.EQUIP_SECONDARY,
				"RMB EQUIPPED" if _player.abilities.get_item(1) == ability_id \
					else "EQUIP RMB")
			right.disabled = _player.abilities.get_item(1) == ability_id
		_list.add_child(row["root"])
		_list.add_child(_rule())


func _build_ability_stats() -> void:
	if _stat_list == null:
		return
	var shown := 0
	for ability_id: String in ItemDB.reusable_ability_ids():
		var ability_level := _player.ability_level(ability_id) \
			if _player != null else 0
		if ability_level <= 0:
			continue
		shown += 1
		var row := _entry(
			"%s  //  LEVEL %d" % [
				ItemDB.title(ability_id), ability_level],
			"Train each stat independently. Every track has five permanent levels.")
		var root := row["root"] as VBoxContainer
		(row["actions"] as HBoxContainer).hide()
		for stat_id: String in ItemDB.ability_stat_ids(ability_id):
			var level := _player.ability_stat_level(ability_id, stat_id)
			var lane := HBoxContainer.new()
			lane.add_theme_constant_override(&"separation", 10)
			var detail := Label.new()
			detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			detail.add_theme_font_size_override(&"font_size", 14)
			detail.add_theme_color_override(
				&"font_color", Color(0.88, 0.78, 0.82))
			detail.text = "%s  //  %d/%d\n%s" % [
				ItemDB.ability_stat_label(stat_id), level,
				ItemDB.MAX_ABILITY_STAT_LEVEL,
				ItemDB.ability_stat_preview(
					ability_id, ability_level,
					_player.ability_stat_levels(ability_id), stat_id),
			]
			lane.add_child(detail)
			var action := _button(
				"MAX" if level >= ItemDB.MAX_ABILITY_STAT_LEVEL \
					else "UPGRADE — FREE", 142.0)
			action.name = "%s%sStat" % [
				ability_id.to_pascal_case(), stat_id.to_pascal_case()]
			action.disabled = level >= ItemDB.MAX_ABILITY_STAT_LEVEL
			action.pressed.connect(
				_on_ability_stat_pressed.bind(ability_id, stat_id))
			lane.add_child(action)
			root.add_child(lane)
			_stat_buttons["%s:%s" % [ability_id, stat_id]] = action
		_stat_list.add_child(root)
		_stat_list.add_child(_rule())
	if shown <= 0:
		var empty := Label.new()
		empty.text = "UNLOCK AN ABILITY IN THE CATALOGUE TO TRAIN IT."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override(&"font_color", Color(0.84, 0.76, 0.78))
		_stat_list.add_child(empty)


func _entry(title_text: String, description_text: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.add_theme_constant_override(&"separation", 5)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override(&"font_size", 18)
	title.add_theme_color_override(&"font_color", Color(1.0, 0.58, 0.62))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(title)
	var description := Label.new()
	description.text = description_text
	description.add_theme_font_size_override(&"font_size", 14)
	description.add_theme_color_override(&"font_color", Color(0.84, 0.76, 0.78))
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(description)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override(&"separation", 8)
	actions.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(actions)
	return {
		"root": root,
		"actions": actions,
	}


func _add_ability_action(actions: HBoxContainer, ability_id: String,
		action_id: int, caption: String) -> Button:
	var button := _button(caption, 132.0)
	button.pressed.connect(
		_on_ability_pressed.bind(ability_id, action_id))
	actions.add_child(button)
	_ability_buttons["%s:%d" % [ability_id, action_id]] = button
	return button


func _button(caption: String, width: float) -> Button:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(width, 38.0)
	button.focus_mode = Control.FOCUS_ALL
	RedHudTheme.button(button, 13, 7.0)
	return button


func _rule() -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(RedHudTheme.RED, 0.42)
	line.custom_minimum_size.y = 1.0
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _on_hat_pressed(item_id: String) -> void:
	if _player == null:
		return
	hat_purchase_requested.emit(item_id)


func _on_ability_pressed(ability_id: String, action: int) -> void:
	ability_action_requested.emit(ability_id, action)


func _on_ability_stat_pressed(ability_id: String, stat_id: String) -> void:
	ability_stat_upgrade_requested.emit(ability_id, stat_id)


func close() -> void:
	closed.emit()
	queue_free()
