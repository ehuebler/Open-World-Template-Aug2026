class_name GameMenu
extends Control

## The in-game menu: one card with a row of tabs across the top, holding the
## character screen in two halves, the quest log, the achievements, the settings
## and the admin tools.
##
## It replaced two screens that used to be separate — the wardrobe/inventory card
## and the pause overlay — and that is the point of it. Both were opened by a key,
## both took the mouse, both dimmed the world, and having two of them meant Escape
## and Tab led to different places with different rules about what closed them. One
## screen with tabs means the two keys are the same door held open at a different
## page:
##
## - **Tab** opens it on the inventory, and closes it.
## - **Escape** opens it on the settings, and closes it.
##
## Either key closes it from any tab, because a key that closes a menu everywhere
## else in software should not be the key that navigates inside this one.
##
## Pages are built the first time their tab is opened and then kept, because the
## inventory page carries a 3D viewport and rebuilding it on every visit would
## reload the body and lose the angle it was turned to.
##
## The menu does not decide what pausing means. It says it is open and [GameWorld]
## decides — single player really stops, a co-op session only stops taking this
## player's input — which is the rule the pause overlay already had and the one
## place it belongs.

signal closed
## The Settings tab's LEAVE GAME. Passed up rather than acted on for the same
## reason the pause overlay never acted on it: leaving is the session's business.
signal leave_requested

enum Tab { HERO, INVENTORY, QUESTS, ACHIEVEMENTS, SETTINGS, ADMIN }

const THEME: Theme = preload("res://ui/themes/main_theme.tres")
const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
## Tab order, and the labels on them.
const TABS: Array[String] = ["Hero Design", "Inventory", "Quests", "Achievements",
	"Settings", "Admin"]
## How much of the window's width the card takes, and the most it may grow to.
const WIDTH_SHARE := 0.92
const WIDTH_CAP := 1320.0
## Height left over the card for the tab row and a margin off the window's edges.
## The card is given the rest of the window rather than a share of it, and given the
## same height on every tab: a card that sized itself to each page would jump every
## time a tab was pressed, and the strip along the top would jump with it.
const TAB_ROW_ROOM := 96.0
const MIN_HEIGHT := 320.0

var _player: OnlinePlayer
var _tab := Tab.INVENTORY
var _tab_row: HBoxContainer
var _page_host: MarginContainer
var _pages: Dictionary = {}


## Called before the menu enters the tree. The player is what every page is built
## against: its containers, its stats, its journal and its body.
func configure(player: OnlinePlayer) -> void:
	_player = player


func _init() -> void:
	name = "GameMenu"
	# The world behind may be stopped dead in single player, and a menu that stops
	# with it would be a still picture of itself.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	theme = THEME
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Swallows clicks, so rummaging in a menu cannot also swing the camera.
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	show_tab(_tab)


## Handled here rather than in _unhandled_input: the inventory key is Tab, which
## the GUI would otherwise spend on moving focus between tiles before the menu ever
## saw it, and Escape would reach the world's own handler first.
##
## Except while a chat line is open, when Escape is the field's way of throwing the
## line away and is not this menu's to take. The panel handles it in `_input` too and
## this node is deeper in the tree, so without the guard abandoning a message would
## shut the menu out from under it.
func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and ChatHud != null and ChatHud.typing:
		return
	if event.is_action_pressed("inventory") or event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		close()


func close() -> void:
	closed.emit()
	queue_free()


func show_tab(tab: Tab) -> void:
	_tab = tab
	_fill_tab_row()
	for child in _page_host.get_children():
		child.visible = false
	var page := _page_for(tab)
	if page != null:
		page.visible = true


## Which tab is up. The harness reads this; nothing in the game needs to.
func current_tab() -> Tab:
	return _tab


# --- Construction -----------------------------------------------------------

func _build() -> void:
	var dimmer := ColorRect.new()
	# The same violet the card is cut from. The world behind is a lit planet, and
	# anything paler here would leave the card looking like a window onto a
	# different scene rather than a panel over this one.
	dimmer.color = Color(PALETTE.paper_shade, 0.62)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dimmer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dimmer)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	centre.add_child(column)

	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override(&"separation", 10)
	column.add_child(_tab_row)

	var window := get_viewport_rect().size
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(
		minf(window.x * WIDTH_SHARE, WIDTH_CAP),
		maxf(window.y - TAB_ROW_ROOM, MIN_HEIGHT))
	column.add_child(card)
	PencilSurface.add_to(card, PencilSurface.Style.CARD)

	var padding := MarginContainer.new()
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		padding.add_theme_constant_override(side, 20)
	card.add_child(padding)

	_page_host = MarginContainer.new()
	padding.add_child(_page_host)


## The strip lives in [MenuWidgets] because the home screen's character editor
## grew the same two tabs and a second copy is a second place for them to differ.
func _fill_tab_row() -> void:
	MenuWidgets.fill_tab_row(_tab_row, TABS, _tab,
		func(index: int) -> void: show_tab(index as Tab))


## Built once and kept. The inventory page owns a SubViewport with a body in it, so
## rebuilding it per visit would reload the model and throw away the angle it was
## turned to; the others are cheap but there is no reason for them to differ.
func _page_for(tab: Tab) -> Control:
	if _pages.has(tab):
		return _pages[tab]
	var page: Control = null
	match tab:
		Tab.HERO: page = _character_page(InventoryPage.Section.HERO)
		Tab.INVENTORY: page = _character_page(InventoryPage.Section.POCKETS)
		Tab.QUESTS: page = _journal_page(JournalDB.QUEST)
		Tab.ACHIEVEMENTS: page = _journal_page(JournalDB.ACHIEVEMENT)
		Tab.SETTINGS: page = _settings_page()
		Tab.ADMIN: page = _admin_page()
	if page == null:
		return null
	_pages[tab] = page
	_page_host.add_child(page)
	return page


## Both halves of the character screen come from here, against the same
## containers: Hero Design is the figure and its colours, Inventory is the
## pockets. Two instances rather than two classes, because an item moving in
## either one has to redraw the tiles in the other, and sharing the container is
## what already does that.
func _character_page(section: InventoryPage.Section) -> Control:
	var page := InventoryPage.new()
	page.section = section
	if _player == null:
		return page
	page.configure(_player.equipment, _player.weapons, _player.backpack,
		_player.stats, _player.body_id())
	page.set_player_name(NetworkManager.local_player_name)
	page.set_tints(_player.tints())
	page.tint_picked.connect(_player.set_tint)
	return page


func _journal_page(kind: StringName) -> Control:
	var page := JournalPage.new()
	page.configure(_player.journal if _player != null else null, kind)
	return page


func _settings_page() -> Control:
	var page := SettingsPanel.new()
	page.configure(true)
	page.leave_requested.connect(func() -> void: leave_requested.emit())
	return page


func _admin_page() -> Control:
	var page := AdminPage.new()
	if _player != null:
		page.configure(_player.backpack, _player.stats, _player.body_id())
	return page
