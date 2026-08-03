extends Node

## Screenshots the home screen without a human clicking through it. The menu is a
## camera over the live world now, so this loads the world the same way the game
## does and drives its HomeScreen from the outside.
##
##     godot --path . dev/_menu_shot.tscn
##
## Saves one capture per view to dev/captures/ and quits. Pass `-- --freeze` to
## stop the pencil surfaces redrawing, so two runs are comparable, and
## `-- --handover` to also shoot the sweep from the home pose into third person,
## which is the one thing here that cannot be checked from a single frame.

const WORLD: PackedScene = preload("res://game/world.tscn")
const CAPTURE_DIR := "res://dev/captures"
## Long enough for the planet to get past its coarsest chunks, so the shots are of
## the thing the player sees rather than of a cube.
const SETTLE_FRAMES := 90
## Settings goes last because _run_settings_tabs picks up where the loop leaves
## off, and its card has to still be on screen.
const VIEWS := [
	{"name": "home", "view": HomeScreen.View.HOME},
	{"name": "online", "view": HomeScreen.View.ONLINE},
	{"name": "character", "view": HomeScreen.View.CHARACTER},
	{"name": "settings", "view": HomeScreen.View.SETTINGS},
]

var _world: GameWorld
var _home: HomeScreen


func _ready() -> void:
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _settle(SETTLE_FRAMES)
	_home = _world.get_node_or_null("HomeScreen") as HomeScreen
	if _home == null:
		push_error("_menu_shot: the world came up with no home screen")
		get_tree().quit(1)
		return

	for entry: Dictionary in VIEWS:
		_home.show_view(entry["view"])
		await _wait(HomeScreen.MOVE_TIME + 0.4)
		await _capture("menu_%s" % entry["name"])
		if entry["view"] == HomeScreen.View.HOME:
			_report_preview()
		if entry["view"] == HomeScreen.View.CHARACTER:
			await _run_character_bodies()

	await _run_settings_tabs()

	# The pause card used to be shot here. Escape now opens GameMenu instead, which
	# needs a spawned player to build its pages against, so it has a harness of its
	# own: dev/_menu_test.tscn.
	if "--handover" in OS.get_cmdline_user_args():
		await _run_handover()
	get_tree().quit()


## The figure on the home screen is meant to be hovering, and a body in its rest
## pose and a body in a hover look near enough alike at 1024 px to have gone
## unnoticed once already. So the clip is named rather than looked at, with the
## hip height beside it: the float lifts them, the rest pose does not.
func _report_preview() -> void:
	var preview := _home.get_node_or_null("PreviewCharacter") as Node3D
	if preview == null:
		push_error("_menu_shot: no preview character on the home screen")
		return
	var animator := preview.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skeleton := preview.find_child("Skeleton3D", true, false) as Skeleton3D
	var hips := skeleton.find_bone("Hips")
	print("_menu_shot: preview playing '%s' at %.2fs, hips %.3f (rest %.3f)" % [
		"NOTHING" if animator == null else animator.current_animation,
		0.0 if animator == null else animator.current_animation_position,
		skeleton.get_bone_global_pose(hips).origin.y,
		skeleton.get_bone_global_rest(hips).origin.y])


## New Game should never cut: the camera leaves the home pose and arrives behind
## the body, and the body is the one that was standing there. Three frames along
## the sweep is enough to see whether it moved or jumped.
func _run_handover() -> void:
	# Seconds rather than frames, all the way through: the tweens and the sweep run
	# on a clock and the harness runs unlocked, so counting frames here started the
	# sweep from whichever pose the camera happened to still be travelling through.
	_home.show_view(HomeScreen.View.HOME)
	await _wait(HomeScreen.MOVE_TIME + 0.4)
	_home.start_new_game()
	for step in 3:
		await _wait(HomeScreen.HANDOVER_TIME / 4.0)
		await _capture("menu_handover_%d" % step)
	await _wait(HomeScreen.HANDOVER_TIME)
	await _capture("menu_handover_done")
	var player := _world.local_player()
	print("_menu_shot: local player %s, camera %s, controls %s, home screen %s" % [
		"spawned" if player != null else "MISSING",
		"handed over" if player != null and player.camera.current else "NOT HANDED OVER",
		"on" if player != null and player.controls_enabled else "OFF",
		"gone" if not is_instance_valid(_home) else "STILL UP",
	])
	# The body the editor chose has to be the body that spawns, garments and all.
	# It is the one thing about the handover that no frame of the sweep shows,
	# since the preview and the player are meant to look identical by then.
	if player != null:
		var wanted := CharacterDB.load_look()
		print("_menu_shot: body wanted=%s got=%s, worn wanted=%s got=%s" % [
			wanted["body"], player.body_id(),
			CharacterDB.worn_items(wanted), player.worn_items(),
		])


## The editor dresses the figure and recolours it, and neither shows in a single
## frame of whichever look happened to be saved. So the body is dressed in its own
## apparel for a shot, which is also the check that a garment cut for the other
## skeleton is never offered on this one.
##
## There is one playable body now, so this no longer walks them. Turning the
## astronaut back on means putting the loop back — the containers already handle a
## body change; see `_on_tint_picked` in `home_screen.gd`.
func _run_character_bodies() -> void:
	var pages := _world.find_children("*", "InventoryPage", true, false)
	if pages.is_empty():
		push_error("_menu_shot: the character view came up with no editor")
		return
	var page := pages[0] as InventoryPage
	# The editor writes every pick straight to settings.cfg, which is the point of
	# it — but a screenshot run is not a choice, so the look is put back after.
	var saved := CharacterDB.load_look()
	var body_id := CharacterDB.sanitize_body(saved["body"])
	var spare := page.spare_slots()
	for item_id in CharacterDB.apparel_ids(body_id):
		ItemContainer.quick_move(spare, spare.find(item_id), page.worn_slots())
	await _wait(0.35)
	await _capture("menu_character_%s" % body_id)
	print("_menu_shot: %s wearing %s" % [body_id, page.worn_slots().items()])
	# Twice over on one target, because a tint multiplies what it lands on and the
	# failure is not a wrong colour but a colour that keeps getting darker.
	for colour: Color in [Color(0.86, 0.24, 0.20), Color(0.24, 0.46, 0.74)]:
		page.tint_picked.emit(InventoryPage.TINT_BODY, colour)
		await _wait(0.2)
	page.tint_picked.emit("long_sleeve", Color(0.94, 0.68, 0.22))
	await _wait(0.35)
	await _capture("menu_character_tinted")
	CharacterDB.save_look(saved)


## The settings shot above only ever catches the first section. The others are
## worth their own frames: audio is the widest row and controls carries the rebind
## list, which is the longest thing in any menu and the first to overrun its card
## when the type is resized.
func _run_settings_tabs() -> void:
	var panels := _world.find_children("*", "SettingsPanel", true, false)
	if panels.is_empty():
		push_error("_menu_shot: the settings card came up with no panel")
		return
	var panel := panels[0] as SettingsPanel
	for index in range(1, SettingsPanel.SECTIONS.size()):
		panel.show_section(index)
		await _wait(0.25)
		await _capture("menu_settings_%d" % index)
	panel.show_section(0)
	await _wait(0.25)
	await _scrolled_shot(panel, "menu_settings_0_foot")


## Every section is taller than the card it sits in, so a shot of one is a shot of
## its first three rows. Display is the section where that hides the most — the
## render scale, the quality and the render distance are all under the fold, and
## none of them had ever been photographed. Run to the bottom and take the rest.
func _scrolled_shot(panel: SettingsPanel, shot_name: String) -> void:
	var scrolls := panel.find_children("*", "ScrollContainer", true, false)
	if scrolls.is_empty():
		push_error("_menu_shot: the settings section has no scroll to run down")
		return
	var scroll := scrolls[0] as ScrollContainer
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	await _wait(0.25)
	await _capture(shot_name)


## Frames, for waiting on work that is measured in them: the planet applies a
## fixed number of built chunks per frame.
func _settle(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame
	await _still()


## Seconds, for waiting on anything driven by a tween or by delta.
func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await _still()


func _still() -> void:
	if "--freeze" in OS.get_cmdline_user_args():
		_freeze()
		await get_tree().process_frame


func _freeze() -> void:
	for control: Node in _surfaces(self):
		var material := (control as CanvasItem).material as ShaderMaterial
		if material != null:
			material.set_shader_parameter(&"redraw_fps", 0.0)


func _surfaces(node: Node) -> Array[Node]:
	var found: Array[Node] = []
	if node is CanvasItem and (node as CanvasItem).material is ShaderMaterial:
		found.append(node)
	for child: Node in node.get_children():
		found.append_array(_surfaces(child))
	return found


func _capture(capture_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [CAPTURE_DIR, capture_name])
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if image.save_png(path) == OK:
		print("_menu_shot: saved %s" % path)
	else:
		push_error("_menu_shot: could not save %s" % path)
