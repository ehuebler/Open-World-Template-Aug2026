extends Node

## Opens the in-game menu the way a player would and photographs every tab.
##
##     & $godot --path . dev/_menu_test.tscn
##
## What it is actually checking is the handful of things a screenshot cannot tell
## you: that Tab opens on the inventory and Escape on the settings, that either key
## shuts it, that the world stops in single player while it is up and starts again
## after, that dressing through the tiles reaches the body, and that the admin tab's
## ADD really lands in the backpack. Shots go to dev/captures/.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

var _world: GameWorld
var _player: OnlinePlayer


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# The world opens the home screen and spawns nobody while the session reads as
	# idle, so the state has to say "in game" before it comes up.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(10)
	_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
	if _player == null:
		push_error("menu_test: no player spawned")
		get_tree().quit(1)
		return
	await _run()
	get_tree().quit()


func _run() -> void:
	await _tab_key()
	await _dress()
	await _tint()
	await _filter()
	await _walk_tabs()
	await _admin()
	await _close_with_tab()
	await _escape_key()


## Tab opens on the inventory, and the world stops while it is up.
func _tab_key() -> void:
	await _tap("inventory")
	await _wait(30)
	var menu := _menu()
	_report("tab", "menu=%s tab=%s paused=%s controls=%s mouse=%s" % [
		menu != null,
		menu.current_tab() if menu != null else -1,
		get_tree().paused,
		_player.controls_enabled,
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE])
	await _shot("menu_inventory")


## Through the tiles rather than through the containers, so the path being measured
## is the one a shift-click takes.
##
## The garments are put in the backpack first, because nothing hands them out any
## more: the wardrobe is gone, so in game an item arrives either in the look saved
## on the home screen or through the admin tab.
func _dress() -> void:
	var page := _page()
	if page == null:
		_report("dress", "no inventory page")
		return
	_player.equipment.clear()
	for id in CharacterDB.apparel_ids(_player.body_id()):
		var free := _player.backpack.first_accepting(id)
		if free >= 0:
			_player.backpack.set_item(free, id)
	await _wait(10)
	for id in CharacterDB.apparel_ids(_player.body_id()):
		var index := page.spare_slots().find(id)
		if index < 0:
			continue
		var slot := _slot_for(page, page.spare_slots(), index)
		if slot != null:
			slot.quick_move_requested.emit(slot)
			await _wait(8)
	await _wait(20)
	_report("dress", "worn=%s" % [_player.worn_items()])
	await _shot("menu_dressed")


## The colour strip along the bottom. Only offers targets for what is actually worn,
## so this runs after dressing.
func _tint() -> void:
	var page := _page(InventoryPage.Section.HERO)
	if page == null:
		return
	await _wait(16)
	page.tint_picked.emit(InventoryPage.TINT_BODY, Color(0.85, 0.70, 0.55))
	await _wait(16)
	_report("tint", "tints=%s" % [_player.tints()])
	await _shot("menu_tinted")


## Whether the pockets filter narrows anything, which is the one thing about it a
## screenshot cannot say: a row of buttons that does nothing photographs exactly
## like a row that works. Pressed through the button, so what is measured is the
## wiring and not the predicate.
##
## Filled with one garment and one weapon, because a filter is only proved by the
## thing it leaves out.
func _filter() -> void:
	var page := _page()
	if page == null:
		return
	_player.backpack.clear()
	_player.backpack.set_item(0, "c3_hair")
	_player.backpack.set_item(1, "sword")
	await _wait(12)
	var counts: Array[String] = []
	for label: String in ["", "Clothing", "Weapons", "Items"]:
		if not label.is_empty():
			_press(page, label)
			await _wait(10)
		counts.append("%s=%d" % [label if not label.is_empty() else "all",
			_showing(page)])
	# Back to everything, or the tabs are photographed mid-search below.
	_press(page, "Items")
	await _wait(10)
	_report("pockets filter", ", ".join(counts))


## Tiles of the pockets grid the player can currently see.
func _showing(page: InventoryPage) -> int:
	var shown := 0
	for node in page.find_children("*", "ItemSlot", true, false):
		var slot := node as ItemSlot
		if slot.container == page.spare_slots() and slot.visible:
			shown += 1
	return shown


func _press(page: InventoryPage, label: String) -> void:
	for node in page.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == label:
			button.pressed.emit()
			return


func _walk_tabs() -> void:
	var menu := _menu()
	if menu == null:
		return
	var rows: Array[Array] = [
		[GameMenu.Tab.HERO, "menu_hero"],
		[GameMenu.Tab.INVENTORY, "menu_inventory"],
		[GameMenu.Tab.QUESTS, "menu_quests"],
		[GameMenu.Tab.ACHIEVEMENTS, "menu_achievements"],
		[GameMenu.Tab.SETTINGS, "menu_settings"],
		[GameMenu.Tab.ADMIN, "menu_admin"],
	]
	for row: Array in rows:
		menu.show_tab(row[0])
		await _wait(26)
		await _shot(row[1])
	_report("tabs", "photographed %d" % rows.size())


## The admin tab's ADD, found by walking for the button rather than by calling the
## page's own helper: what is being checked is that the button is wired.
func _admin() -> void:
	var menu := _menu()
	if menu == null:
		return
	menu.show_tab(GameMenu.Tab.ADMIN)
	await _wait(20)
	var before := _carried()
	for node in menu.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == "ADD":
			button.pressed.emit()
			break
	await _wait(16)
	_report("admin add", "carried %d -> %d" % [before, _carried()])


func _close_with_tab() -> void:
	await _tap("inventory")
	await _wait(24)
	_report("tab shuts", "menu=%s paused=%s controls=%s mouse=%s" % [
		_menu() != null, get_tree().paused, _player.controls_enabled,
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE])


## Escape opens the same menu on its settings tab, and shuts it again.
func _escape_key() -> void:
	await _tap("pause")
	await _wait(30)
	var menu := _menu()
	_report("escape", "menu=%s tab=%s paused=%s" % [
		menu != null, menu.current_tab() if menu != null else -1, get_tree().paused])
	await _shot("menu_escape")
	await _tap("pause")
	await _wait(24)
	_report("escape shuts", "menu=%s paused=%s controls=%s" % [
		_menu() != null, get_tree().paused, _player.controls_enabled])


# --- Helpers ----------------------------------------------------------------

func _menu() -> GameMenu:
	for child in _player.hud.get_children():
		if child is GameMenu:
			return child as GameMenu
	return null


## The character screen is two pages against one set of containers now, so which
## one is wanted has to be said: the pockets live on Inventory and the figure, the
## worn tiles and the colour strip live on Hero Design.
func _page(section := InventoryPage.Section.POCKETS) -> InventoryPage:
	var menu := _menu()
	if menu == null:
		return null
	menu.show_tab(GameMenu.Tab.INVENTORY if section == InventoryPage.Section.POCKETS \
		else GameMenu.Tab.HERO)
	for node in menu.find_children("*", "Control", true, false):
		var page := node as InventoryPage
		if page != null and page.section == section:
			return page
	return null


func _slot_for(root: Node, container: ItemContainer, index: int) -> ItemSlot:
	if index < 0:
		return null
	for node in root.find_children("*", "Control", true, false):
		var slot := node as ItemSlot
		if slot != null and slot.container == container and slot.index == index:
			return slot
	return null


func _carried() -> int:
	var count := 0
	for id in _player.backpack.items():
		if not String(id).is_empty():
			count += 1
	return count


## Dispatched as an event rather than with Input.action_press, which only moves the
## polled state and never reaches an _unhandled_input handler.
func _tap(action: String) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	await _wait(2)
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)
	await _wait(2)


func _wait(frames: int) -> void:
	for _index in frames:
		await get_tree().process_frame


func _report(step: String, detail: String) -> void:
	print("menu_test: %-14s %s" % [step, detail])


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		print("menu_test: shot %s failed: %s" % [shot_name, error_string(error)])
