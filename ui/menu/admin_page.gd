class_name AdminPage
extends VBoxContainer

## The Admin tab: conjure any item into the backpack, and set any stat.
##
## A cheat panel, and it is worth saying why one is in the game rather than in a
## harness. Every other way to get an item involves walking to the thing that has
## it, and every way to test a stat involves whatever changes it — so the moment
## there is a second garment or a third stat, checking that it works costs a trip.
## This is the shortcut, and because it is built off [constant ItemDB.ITEMS] and
## [constant PlayerStats.STATS] rather than a list of its own, anything added to
## either table appears here with no edit.
##
## It writes through the same containers and the same stats object the game uses.
## There is no admin-only path into the player: an item added here arrives in the
## backpack exactly as one taken off a shelf would, which is the point — a bug that
## only shows up for conjured items would be a bug in this file.

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const ROWS_HEIGHT := 190.0

var _backpack: ItemContainer
var _stats: PlayerStats
var _body_id := CharacterDB.DEFAULT_BODY

var _item_list: VBoxContainer
var _stat_list: VBoxContainer
var _notice: Label
var _item_search := ""
var _item_slot := "All"


## Called before the page enters the tree. Handed the container and the stats
## rather than the player, so a harness can drive it without one.
func configure(backpack: ItemContainer, stats: PlayerStats,
		body_id := CharacterDB.DEFAULT_BODY) -> void:
	_backpack = backpack
	_stats = stats
	_body_id = CharacterDB.sanitize_body(body_id)


func _ready() -> void:
	add_theme_constant_override(&"separation", 14)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build()


func _build() -> void:
	_build_items()
	_build_stats()
	_notice = Label.new()
	_notice.add_theme_font_size_override(&"font_size", 16)
	_notice.add_theme_color_override(&"font_color", PALETTE.accent)
	add_child(_notice)


# --- Items ------------------------------------------------------------------

func _build_items() -> void:
	var box := _well("ITEMS")
	var filters := HBoxContainer.new()
	filters.add_theme_constant_override(&"separation", 10)
	box.add_child(filters)

	# Slots as the filter, which is the one axis every item has: five body slots
	# and weapons, straight off the tables rather than typed here.
	var slots := PackedStringArray(["All"])
	slots.append_array(ItemDB.SLOT_ORDER)
	slots.append(ItemDB.WEAPON)
	var picker := OptionButton.new()
	for slot in slots:
		picker.add_item(String(ItemDB.SLOT_LABELS.get(slot, slot)).capitalize() \
			if slot != "All" else "All slots")
	picker.custom_minimum_size.x = 150
	PencilSurface.add_to(picker, PencilSurface.Style.BUTTON)
	picker.item_selected.connect(func(index: int) -> void:
		_item_slot = slots[index] if index < slots.size() else "All"
		_fill_items()
	)
	filters.add_child(picker)

	var search := LineEdit.new()
	search.placeholder_text = "Search items"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PencilSurface.add_to(search, PencilSurface.Style.INPUT)
	search.text_changed.connect(func(text: String) -> void:
		_item_search = text.strip_edges().to_lower()
		_fill_items()
	)
	filters.add_child(search)

	_item_list = _scrolled(box)
	_fill_items()


func _fill_items() -> void:
	for child in _item_list.get_children():
		child.queue_free()
	var shown := 0
	for id: String in ItemDB.ITEMS:
		var slot := ItemDB.slot_of(id)
		if _item_slot != "All" and slot != _item_slot:
			continue
		if not _item_search.is_empty() \
				and not ItemDB.title(id).to_lower().contains(_item_search):
			continue
		shown += 1
		_item_list.add_child(_item_row(id, slot))
	if shown == 0:
		_item_list.add_child(MenuWidgets.caption("No item matches that."))


func _item_row(id: String, slot: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)

	var title := Label.new()
	title.text = ItemDB.title(id)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override(&"font_size", 17)
	row.add_child(title)

	var where := Label.new()
	where.text = String(ItemDB.SLOT_LABELS.get(slot, slot))
	where.custom_minimum_size.x = 80
	where.add_theme_font_size_override(&"font_size", 15)
	where.add_theme_color_override(&"font_color", PALETTE.text_muted)
	row.add_child(where)

	var fits := CharacterDB.apparel_fits(_body_id, id) or ItemDB.is_weapon(id)
	if not fits:
		# Offered anyway rather than hidden: it is a real item and this is the
		# admin tab. Marked, because a garment cut for the other body will attach
		# to this skeleton looking wrong rather than failing.
		where.text = "other body"
		where.add_theme_color_override(&"font_color", PALETTE.danger)

	var add := MenuWidgets.button("ADD")
	add.custom_minimum_size.x = 90
	add.add_theme_font_size_override(&"font_size", 15)
	add.pressed.connect(func() -> void: _give(id))
	row.add_child(add)
	return row


## Into the backpack, through the container's own filters, so an item that would
## not be accepted is refused here too.
func _give(id: String) -> void:
	if _backpack == null:
		return
	var index := _backpack.first_accepting(id)
	if index < 0:
		_say("No room in the backpack for %s." % ItemDB.title(id))
		return
	_backpack.set_item(index, id)
	_say("%s added to the backpack." % ItemDB.title(id))


# --- Stats ------------------------------------------------------------------

func _build_stats() -> void:
	var box := _well("STATS")
	_stat_list = _scrolled(box)
	_fill_stats()


func _fill_stats() -> void:
	for child in _stat_list.get_children():
		child.queue_free()
	if _stats == null:
		_stat_list.add_child(MenuWidgets.caption("No stats to edit here."))
		return
	for id in PlayerStats.ids():
		_stat_list.add_child(_stat_row(StringName(id)))


## One stat, its current base, a box to type a new one into, and APPLY. A box
## rather than a slider because the point of this tab is to set an exact number and
## see what it does, which a slider is bad at.
func _stat_row(id: StringName) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 10)

	var title := Label.new()
	title.text = PlayerStats.title_of(id)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override(&"font_size", 17)
	row.add_child(title)

	var now := Label.new()
	now.text = PlayerStats.format(id, _stats.base_of(id))
	now.custom_minimum_size.x = 90
	now.add_theme_font_size_override(&"font_size", 15)
	now.add_theme_color_override(&"font_color", PALETTE.text_muted)
	row.add_child(now)

	var field := SpinBox.new()
	field.min_value = PlayerStats.minimum_of(id)
	field.max_value = PlayerStats.maximum_of(id)
	field.step = 0.1
	field.value = _stats.base_of(id)
	field.custom_minimum_size.x = 120
	PencilSurface.add_to(field, PencilSurface.Style.INPUT)
	row.add_child(field)

	var apply := MenuWidgets.button("APPLY")
	apply.custom_minimum_size.x = 90
	apply.add_theme_font_size_override(&"font_size", 15)
	apply.pressed.connect(func() -> void:
		_stats.set_base(id, field.value)
		now.text = PlayerStats.format(id, _stats.base_of(id))
		field.value = _stats.base_of(id)
		_say("%s set to %s." % [PlayerStats.title_of(id), now.text])
	)
	row.add_child(apply)
	return row


# --- Shared -----------------------------------------------------------------

## A captioned well added straight to the page, returning the box to fill. Both
## builders above want the same four nodes and neither wants the panel itself, so
## it is added here rather than handed back.
func _well(title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(panel)
	PencilSurface.add_to(panel, PencilSurface.Style.ROW)
	var padding := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		padding.add_theme_constant_override(side, 18)
	panel.add_child(padding)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	padding.add_child(box)
	box.add_child(MenuWidgets.heading(title, 24))
	return box


func _scrolled(box: VBoxContainer) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, ROWS_HEIGHT)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override(&"separation", 8)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The scrollbar draws over the content, so the rows are inset clear of it.
	var inset := MarginContainer.new()
	inset.add_theme_constant_override(&"margin_right", 20)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(inner)
	scroll.add_child(inset)
	return inner


func _say(text: String) -> void:
	if _notice != null:
		_notice.text = text
