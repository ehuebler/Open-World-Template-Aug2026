class_name HomeScreen
extends Node3D

## The home screen, which is the world itself seen from the spawn point rather
## than a scene in front of it. Nothing the player picks here changes scene: the
## planet, the sun and the starfield are already the ones they will be playing in,
## and the character on the left is standing where they will start.
##
## That is the whole reason this is a Node3D living under the world instead of a
## Control living on its own. Rebuilding the planet's quadtree behind a menu costs
## seconds, so any cut between "home screen" and "playing" would be a cut the
## player could see. Here, New Game is a camera move.
##
## Three views, each a camera pose over the same scene:
##   HOME      character to the left, planet to the right, menu under it
##   ONLINE    pitched down onto the planet, create and join side by side
##   SETTINGS  turned away from the planet into empty sky

signal handed_over

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")

enum View { HOME, ONLINE, SETTINGS, CHARACTER }

## Camera poses, in the spawn point's frame: metres from the spawn, then degrees
## of yaw and pitch (positive is up) off its facing, and the field of view. The
## rows are indexed by View for HOME/ONLINE/SETTINGS; CHARACTER reuses HOME.
##
## Three things about the HOME row are worked out rather than picked, because the
## spawn is nine kilometres above a planet eight across and that fixes most of it:
##
##   - The planet subtends 56 degrees from here. No amount of yaw turns something
##     that wide into the contained ball the mock-up draws, so the field of view
##     is opened to 90 rather than the planet being moved; at 90 it covers about
##     three fifths of the frame's height and reads as a globe.
##   - The character is metres away and the planet is kilometres away, so the only
##     thing that can separate them across the frame is parallax. Standing the
##     camera a metre and a half to the side throws the character 60 degrees off
##     the planet's bearing; the yaw then slides the pair over until the character
##     sits a quarter of the way in and the planet fills the right.
##   - Pitching down lifts the planet in the frame, which is what opens the dark
##     sky under it for the menu.
##   - The camera's height is the character's own centre and not the pitch's, and
##     those are two different jobs on this shot. Pitch decides where in the
##     frame things land; height decides what angle the near one is seen from,
##     because the planet is nine kilometres off and does not move for a camera
##     that rises a metre. Raised to 1.7 to sit level with the pitch, the camera
##     looked 25 degrees down onto a figure whose middle is at 0.9, and the home
##     screen showed the top of its head. Dropping to the figure's own height
##     rides it up the frame, which the shorter pitch then pays for.
##   - The HOME row was moved in until the figure fills three fifths of the frame
##     rather than two fifths, and the height went **up** to pay for it. Those are
##     the same two dials as above doing the same two jobs: coming in makes the
##     figure bigger about wherever it already was, and at this size that put the
##     hair through the top edge; rising drops the whole figure down the frame and
##     leaves the planet where it was, because nine kilometres does not care about
##     a foot of camera. Reaching for the pitch instead is the mistake — it would
##     have brought the planet down with it and closed the band the menu sits in.
##     The head now lands about a sixth of the way down and the feet three
##     quarters, which leaves the name plate and the menu row the bottom quarter.
const POSE_OFFSETS := [
	Vector3(1.50, 1.15, 0.77),
	Vector3(0.0, 2.2, -2.0),
	Vector3(-2.0, 1.2, 3.5),
]
const POSE_YAWS := [30.0, 0.0, 180.0]
const POSE_PITCHES := [-12.0, 30.0, 12.0]

## How far off dead-on the figure stands. Float draws one knee up and across the
## other, and that is the whole silhouette that says hovering rather than
## standing — but it is drawn up *forward*, so a camera square to the chest
## foreshortens it to nothing and the pose reads as a body at attention. A turn
## of this much still shows the face, which is what the low camera was for, and
## opens the knee. It also turns the figure into the frame rather than out of it.
const PREVIEW_TURN := -32.0
const POSE_FOVS := [90.0, 62.0, 58.0]

## Type over space is outlined in near-black rather than in the palette's violet:
## the planet's lit face passes under this text as the camera moves, and violet on
## a pale limb is not a strong enough edge to hold the letterforms apart.
const SKY_OUTLINE := Color(0.02, 0.01, 0.03, 0.92)
## Side of the pencil beside the name field, in pixels.
const PENCIL_SIZE := 58.0

## What New Game opens onto. They all start the same game for now; the list is
## here so a fourth is one string rather than another button and another lambda.
const MODES: Array[String] = ["Story Mode", "Crawler Mode"]

## The editor's tabs, in [enum InventoryPage.Section] order because the row is
## indexed by it. Named as the in-game menu names the same two.
const EDITOR_TABS: Array[String] = ["Hero Design", "Inventory"]
## Weapon slots the editor draws. The player's own bar is this long; see
## [method _character_editor] for why an empty copy of it is worth the room.
const EDITOR_WEAPON_SLOTS := 5

## Height of the band at the foot of the window the menu row runs along, and how
## far its baseline sits off the bottom edge.
const MENU_ROW_HEIGHT := 56.0
const MENU_ROW_INSET := 38.0
## Share of the window the character editor's card is allowed, measured from the
## right edge. The rest is the figure, which is the whole reason the editor has no
## preview of its own — see [method _character_editor].
const EDITOR_CARD_SHARE := 0.56
## Where a screen's card starts: under the title row for the full-width ones, and
## higher for the editor, which is off to the right of the title rather than under
## it. `dev/_menu_shot.tscn` prints what the card wants against what it is given.
const TITLE_BAND := 136.0
## Higher again since the editor grew a tab strip, which is 54 px the card has to
## find from somewhere. It only clears the title horizontally rather than
## vertically now, which is enough: the title ends around 400 px in and the card
## starts past the middle of the window.
const EDITOR_TOP := 52.0

const MOVE_TIME := 0.85
## The sweep from the home pose to behind the character. Long enough to read as a
## camera move, short enough not to be a cutscene.
const HANDOVER_TIME := 1.15
const FADE_IN_TIME := 0.9
const SPIN_PER_PIXEL := 0.008

## Set by the world before this enters the tree: the spawn the local player will
## use, and the frame every camera pose is measured in.
var frame := Transform3D.IDENTITY

var _camera: Camera3D
var _preview: Node3D
## The facing the preview was built with, kept apart from the drag so a spin is
## always measured from where the character was put rather than from itself.
var _preview_rest := Basis.IDENTITY
var _preview_spin := 0.0
var _dragging := false

var _view := View.HOME
var _layer: CanvasLayer
var _root: Control
var _title: Label
var _menu: HBoxContainer
## Which set of entries the menu row is showing. New Game does not start a game
## any more, it asks which one, and the answer replaces the row it was pressed on.
var _picking_mode := false
var _back: Button
var _screen_host: MarginContainer
var _screen: Control
var _notice: Label
var _fade: ColorRect
var _move: Tween

var _handover_from := Transform3D.IDENTITY
var _handover_fov := 0.0
var _handover_at := 0.0
var _handover_target: OnlinePlayer
var _body_from := Basis.IDENTITY
var _awaiting_player := false
var _edit_button: Button
var _name_row: HBoxContainer
var _name_field: LineEdit
var _look: Dictionary = {}
## The containers the character editor is built against, held here rather than in
## the screen so the look survives the editor being closed and opened again.
var _worn_slots: ItemContainer
var _apparel_rail: ItemContainer
## Five weapon slots nothing can be put in, and the stats a new character starts
## with. Held here for the same reason the containers are: the editor is thrown
## away and rebuilt every time it is opened.
var _editor_weapons: ItemContainer
var _editor_stats: PlayerStats
## The editor's pages by section, which are the card's content rather than the
## card itself, so they cannot be reached by casting `_screen`.
var _editor_pages: Dictionary = {}
var _editor_tabs: HBoxContainer
var _editor_host: MarginContainer
## Stocking a container fires its changed signal, which is the same signal the
## player dragging a garment fires; without this the editor would read its own
## restock back as a change and write it out again.
var _stocking := false


func _ready() -> void:
	_build_camera()
	_build_preview()
	_build_overlay()
	_apply_pose(_view, true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	NetworkManager.session_started.connect(_on_session_started)
	NetworkManager.status_changed.connect(_on_status_changed)


func _exit_tree() -> void:
	if NetworkManager.session_started.is_connected(_on_session_started):
		NetworkManager.session_started.disconnect(_on_session_started)
	if NetworkManager.status_changed.is_connected(_on_status_changed):
		NetworkManager.status_changed.disconnect(_on_status_changed)


func _process(delta: float) -> void:
	if _awaiting_player:
		# On a join the local body arrives with the host's spawn broadcast, which
		# is some frames after the session says it has started.
		var player := _world().local_player()
		if player != null:
			_awaiting_player = false
			_begin_handover(player)
	if _handover_target != null:
		_advance_handover(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and _handover_target == null:
		if _view != View.HOME:
			show_view(View.HOME)
			get_viewport().set_input_as_handled()
		return
	# Turnable while the editor is open as well as from the home view: with no
	# preview of its own, the figure standing in the world *is* the editor's
	# model, and being able to look at its back is most of what dressing one is.
	if (_view != View.HOME and _view != View.CHARACTER) or _handover_target != null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_preview_spin -= event.relative.x * SPIN_PER_PIXEL
		_apply_preview_basis()


# --- The scene ---------------------------------------------------------------


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "MenuCamera"
	# The planet is nine kilometres off and eight across, so the far plane is the
	# player camera's rather than the default fifty metres.
	_camera.near = 0.05
	_camera.far = 60000.0
	add_child(_camera)
	_camera.current = true


func _build_preview() -> void:
	_look = CharacterDB.load_look()
	_spawn_preview()


func _spawn_preview() -> void:
	var spin := _preview_spin
	var rest := _preview_rest
	if is_instance_valid(_preview):
		_preview.queue_free()
		_preview = null
	var packed := CharacterDB.scene(str(_look.get("body", CharacterDB.DEFAULT_BODY)))
	if packed == null:
		return
	_preview = packed.instantiate() as Node3D
	_preview.name = "PreviewCharacter"
	add_child(_preview)
	SurfaceSkin.apply(_preview)
	_dress_preview()
	_preview.global_position = frame.origin
	if rest != Basis.IDENTITY:
		_preview_rest = rest
		_preview_spin = spin
		_apply_preview_basis()
	else:
		_face_camera()
	# The spawn hangs in orbit with nothing under it, so the body that stands
	# there is floating, and so is the one the player takes over.
	var animator := _preview.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if animator != null and animator.has_animation("Float"):
		animator.get_animation("Float").loop_mode = Animation.LOOP_LINEAR
		animator.play("Float")


## Re-dresses the figure from scratch every time, garments and all. A tint
## multiplies the albedo it lands on, so laying a second one over the first would
## give the product of the two rather than the second; stripping back to the
## authored colours first is what makes picking a colour repeatable.
func _dress_preview() -> void:
	if not is_instance_valid(_preview):
		return
	var worn: Dictionary = _look.get("worn", {})
	for slot: String in ItemDB.SLOT_ORDER:
		Wardrobe.unequip(_preview, slot)
	SurfaceSkin.apply(_preview)
	for slot: String in worn:
		var item_id := str(worn[slot])
		if item_id.is_empty() or not ItemDB.has_item(item_id):
			continue
		var garment := Wardrobe.equip(_preview, str(slot), ItemDB.scene_path(item_id))
		if garment != null:
			SurfaceSkin.paint(garment)
	var tints: Dictionary = _look.get("tints", {})
	if tints.has("body"):
		var body_tint := Color.html(str(tints["body"]))
		for node in _preview.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := node as MeshInstance3D
			if String(mesh_instance.name).begins_with(Wardrobe.NODE_PREFIX):
				continue
			SurfaceSkin.tint(mesh_instance, body_tint)
	for slot: String in ItemDB.SLOT_ORDER:
		if not tints.has(slot):
			continue
		for node in _preview.find_children(Wardrobe.NODE_PREFIX + slot, "MeshInstance3D", true, false):
			SurfaceSkin.tint(node as MeshInstance3D, Color.html(str(tints[slot])))


## Turned to face the home camera and then PREVIEW_TURN off it, flattened against
## the spawn's up so the body stays upright however the pose is angled.
func _face_camera() -> void:
	var up := frame.basis.y
	var to_camera := _pose(View.HOME).origin - frame.origin
	to_camera -= up * to_camera.dot(up)
	if to_camera.length_squared() < 0.0001:
		return
	_preview.look_at(frame.origin + to_camera, up)
	_preview.global_basis = _preview.global_basis * Basis(Vector3.UP, deg_to_rad(PREVIEW_TURN))
	_preview_rest = _preview.global_basis
	_apply_preview_basis()


func _apply_preview_basis() -> void:
	if is_instance_valid(_preview):
		_preview.global_basis = _preview_rest * Basis(Vector3.UP, _preview_spin)


func _pose(view: int) -> Transform3D:
	var basis := frame.basis \
		* Basis(Vector3.UP, deg_to_rad(POSE_YAWS[view])) \
		* Basis(Vector3.RIGHT, deg_to_rad(POSE_PITCHES[view]))
	return Transform3D(basis, frame * POSE_OFFSETS[view])


func _apply_pose(view: int, immediate: bool) -> void:
	var target := _pose(view)
	if immediate:
		_camera.global_transform = target
		_camera.fov = POSE_FOVS[view]
		return
	if _move != null and _move.is_valid():
		_move.kill()
	_move = create_tween().set_parallel(true)
	_move.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_move.tween_property(_camera, "global_transform", target, MOVE_TIME)
	_move.tween_property(_camera, "fov", POSE_FOVS[view], MOVE_TIME)


# --- The overlay -------------------------------------------------------------


func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 10
	add_child(_layer)

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = preload("res://ui/themes/main_theme.tres")
	_layer.add_child(_root)

	_title = _sky_label(String(ProjectSettings.get_setting("game/title", "Astraphel")), 64)
	_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_title.position = Vector2(56, 40)
	_root.add_child(_title)

	# Beside the title rather than under it. The cards below are as tall as the
	# window allows, so a second line up here is a line taken off every screen,
	# and the one that gets clipped is whichever button the form ends with.
	_back = _sky_button("BACK", func() -> void: show_view(View.HOME))
	_back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_back.position = Vector2(56.0 + _title.get_minimum_size().x + 56.0, 54.0)
	_back.visible = false
	_root.add_child(_back)

	# One row along the foot of the window rather than a list down the right.
	# The list was there because the figure owned the left of the frame and the
	# planet the right, which left one column of dark sky to put it in — but the
	# figure has since been brought in close enough to want the middle as well,
	# and a row along the bottom is the one place that crosses neither. It also
	# stops being a column that grows downward off the screen as entries are
	# added to it.
	_menu = HBoxContainer.new()
	_menu.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_menu.offset_top = -(MENU_ROW_HEIGHT + MENU_ROW_INSET)
	_menu.offset_bottom = -MENU_ROW_INSET
	_menu.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu.add_theme_constant_override("separation", 54)
	_root.add_child(_menu)
	_fill_menu_row()

	_build_name_row()

	# A margin rather than a centring container: screens are told how tall they
	# may be and fill it, instead of growing to their contents and being centred
	# past both edges of the window when the contents are taller than it.
	_screen_host = MarginContainer.new()
	_screen_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Clear of the title row, which stays put behind every screen.
	_screen_host.offset_top = TITLE_BAND
	_screen_host.offset_bottom = -28.0
	_screen_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_screen_host)

	_notice = _sky_label("", 20)
	_notice.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_notice.offset_top = -38.0
	_notice.offset_bottom = -12.0
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.visible = false
	_root.add_child(_notice)

	# There is no boot sheet any more: the first thing the game shows is this
	# scene, and it fades up out of the dark the starfield is already made of.
	_fade = ColorRect.new()
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color(0.004, 0.006, 0.016)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fade)
	create_tween().tween_property(_fade, "modulate:a", 0.0, FADE_IN_TIME) \
		.set_trans(Tween.TRANS_SINE)


## The row's entries, which are one of two sets.
##
## New Game asks which mode rather than starting one, and the answer takes over
## the row it was pressed on instead of opening a screen of its own. Two buttons
## are not a form, and a card holding them would dim the figure that is about to
## become the player — which is the one thing on this screen a mode picker should
## leave alone, since the modes differ in what happens to that character.
func _fill_menu_row() -> void:
	for child in _menu.get_children():
		child.queue_free()
	if _picking_mode:
		# Both start the same game today. The seam for telling them apart is
		# `start_new_game`, which is already the one place the world is handed
		# the spawn and the look, and is where a mode would go beside them.
		for mode: String in MODES:
			_menu.add_child(_sky_button(mode, start_new_game))
		_menu.add_child(_sky_button("Back", func() -> void: _pick_mode(false)))
		return
	_menu.add_child(_sky_button("New Game", func() -> void: _pick_mode(true)))
	_menu.add_child(_sky_button("Online", func() -> void: show_view(View.ONLINE)))
	_menu.add_child(_sky_button("Settings", func() -> void: show_view(View.SETTINGS)))
	_menu.add_child(_sky_button("Quit", func() -> void: get_tree().quit()))


func _pick_mode(picking: bool) -> void:
	if _picking_mode == picking:
		return
	_picking_mode = picking
	_fill_menu_row()


## The name under the figure, and the pencil beside it.
##
## Under the character rather than in the menu on the right, because it is that
## figure's name and the list on the right is about game modes. The field is a drawn
## input and not outlined sky type like everything else up here: a name you can type
## into has to look like somewhere you can type, and a caret blinking in open space
## does not. The pencil opens the editor, which is the same name field again — being
## able to rename yourself without leaving the title screen is the point of having
## it here, and the editor is where you go when you want to change more than that.
func _build_name_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	# Between the figure's feet and the menu row along the bottom, which is the
	# band left over once the figure was brought in close. Anchored across rather
	# than placed in pixels from the left edge: the figure's own position in the
	# frame is a fraction of the width — it is parallax off a camera a metre and a
	# half to the side — so a pixel offset only holds at one window size.
	row.anchor_top = 0.75
	row.anchor_bottom = 0.75
	row.anchor_left = 0.17
	row.anchor_right = 0.17
	row.offset_left = 0.0
	row.offset_right = 345.0
	row.offset_top = -26.0
	row.offset_bottom = 26.0
	_root.add_child(row)

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.custom_minimum_size = Vector2(250.0, 0.0)
	row.add_child(panel)
	PencilSurface.add_to(panel, PencilSurface.Style.INPUT)
	var padding := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		padding.add_theme_constant_override(side, 12)
	panel.add_child(padding)

	_name_field = LineEdit.new()
	_name_field.text = NetworkManager.saved_player_name()
	_name_field.placeholder_text = "Your name"
	_name_field.max_length = 24
	_name_field.add_theme_font_size_override("font_size", 24)
	_name_field.text_submitted.connect(func(value: String) -> void: _rename(value))
	_name_field.focus_exited.connect(func() -> void: _rename(_name_field.text))
	padding.add_child(_name_field)

	_edit_button = _pencil_button()
	_edit_button.pressed.connect(func() -> void: show_view(View.CHARACTER))
	row.add_child(_edit_button)
	_name_row = row


## A pencil, drawn rather than set as text: the pixel face carries no glyph for one,
## and a missing glyph in this font comes out as a stray sliver rather than as a
## visible box. Two polygons over a dark rim, so it reads against the starfield the
## same way the outlined type beside it does.
func _pencil_button() -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = "Edit character"
	button.custom_minimum_size = Vector2(PENCIL_SIZE, PENCIL_SIZE)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.draw.connect(func() -> void:
		var lit := button.has_focus() or button.is_hovered() or button.button_pressed
		var ink := PALETTE.accent if lit else PALETTE.text_primary
		var s := minf(button.size.x, button.size.y)
		var along := Vector2(1.0, -1.0).normalized()
		var across := Vector2(1.0, 1.0).normalized() * (s * 0.15)
		var tip := Vector2(0.14, 0.86) * s
		var shoulder := tip + along * (s * 0.26)
		var back := Vector2(0.86, 0.14) * s
		var body := PackedVector2Array([
			shoulder + across, back + across, back - across, shoulder - across])
		var point := PackedVector2Array([tip, shoulder + across, shoulder - across])
		for shape: PackedVector2Array in [body, point]:
			button.draw_polyline(shape + PackedVector2Array([shape[0]]),
				SKY_OUTLINE, s * 0.14)
		for shape: PackedVector2Array in [body, point]:
			button.draw_colored_polygon(shape, ink)
		# The band where the paint stops and the wood begins, which is most of what
		# tells a pencil apart from a slash at this size.
		var band := shoulder + along * (s * 0.14)
		button.draw_line(band + across, band - across, SKY_OUTLINE, s * 0.07)
	)
	# The fill and the rim are both read off the button's state, so a redraw has to
	# be asked for whenever that changes; a flat Button repaints on neither.
	for signal_name: StringName in [&"mouse_entered", &"mouse_exited",
			&"focus_entered", &"focus_exited"]:
		button.connect(signal_name, button.queue_redraw)
	return button


## Saves the typed name, or puts the field back to the stored one if it was
## refused. Moderation lives in [NetworkManager] so that the one rule covers this
## field, the two in the lobby and every chat line; all this does is report it.
func _rename(value: String) -> void:
	if NetworkManager.save_player_name(value):
		_set_notice("", false)
	else:
		_set_notice("That name is not allowed.", true)
	var stored := NetworkManager.saved_player_name()
	if _name_field.text != stored:
		_name_field.text = stored
	for page: Variant in _editor_pages.values():
		if is_instance_valid(page):
			(page as InventoryPage).set_player_name(stored)


## Type over the starfield cannot sit on a drawn plate the way the in-game HUD
## does — the mock-up is bare text on space, and a sheet of paper in the middle of
## it would read as a menu bolted over the game rather than part of it. So the
## legibility comes from an ink outline instead, which holds up over both the
## black of space and the lit face of the planet.
func _sky_label(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", PALETTE.text_primary)
	label.add_theme_color_override("font_outline_color", SKY_OUTLINE)
	label.add_theme_constant_override("outline_size", 10)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## On a card the label stays violet and only the focus ring moves; over space
## violet is invisible, so here the text itself carries the state. The meaning is
## the one that holds everywhere else in the UI: custard at rest, and the screen's
## own gold for the one item the player is on.
func _sky_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", 34)
	button.add_theme_color_override("font_color", PALETTE.text_primary)
	button.add_theme_color_override("font_hover_color", PALETTE.accent)
	button.add_theme_color_override("font_focus_color", PALETTE.accent)
	button.add_theme_color_override("font_pressed_color", PALETTE.accent)
	button.add_theme_color_override("font_outline_color", SKY_OUTLINE)
	button.add_theme_constant_override("outline_size", 10)
	button.pressed.connect(callback)
	return button


func show_view(view: View) -> void:
	if _handover_target != null:
		return
	_view = view
	# Character editing keeps the HOME camera; the other views each have a pose.
	var pose_view := View.HOME if view == View.CHARACTER else view
	_apply_pose(pose_view, false)
	_set_notice("", false)
	if is_instance_valid(_screen):
		_screen.queue_free()
		_screen = null
		_editor_pages.clear()
	_menu.visible = view == View.HOME
	_pick_mode(false)
	_back.visible = view != View.HOME
	# The editor carries a name field of its own, so the one under the figure would
	# be a second field for the same name sitting beside it.
	if is_instance_valid(_name_row):
		_name_row.visible = view == View.HOME
	# The planet's limb runs across the foot of the frame in the ONLINE pose, and a
	# card sitting on it would hide the thing the pose was moved for. Settings has
	# no planet to protect and wants every pixel it can get. Character stays on
	# the home pose so the preview keeps facing the camera while you edit it.
	_screen_host.offset_bottom = -96.0 if view == View.ONLINE else -28.0
	# And the editor is held clear of the left of the frame, because the figure
	# standing there is the editor's preview. A full-width card would cover the
	# one thing it is for.
	#
	# Being over there is also what lets it start higher than every other screen.
	# The 136 px band exists to clear the title, and the title is 56 px from the
	# left edge — so a card that begins past the middle of the window is not under
	# it and the difference is height the equipment column needs.
	var editing := view == View.CHARACTER
	_screen_host.anchor_left = 1.0 - EDITOR_CARD_SHARE if editing else 0.0
	_screen_host.offset_right = -28.0 if editing else 0.0
	_screen_host.offset_top = EDITOR_TOP if editing else TITLE_BAND
	match view:
		View.ONLINE:
			var lobby := LobbyPanel.new()
			lobby.closed.connect(func() -> void: show_view(View.HOME))
			lobby.notice.connect(_set_notice)
			_screen = lobby
		View.SETTINGS:
			var settings := SettingsPanel.new()
			settings.configure(false)
			settings.closed.connect(func() -> void: show_view(View.HOME))
			_screen = settings
		View.CHARACTER:
			_screen = _character_editor()
	if _screen != null:
		_screen.modulate.a = 0.0
		_screen_host.add_child(_screen)
		create_tween().tween_property(_screen, "modulate:a", 1.0, 0.35) \
			.set_delay(MOVE_TIME * 0.45)


# --- The character editor -----------------------------------------------------
#
# It is the inventory screen, not a form of its own: dressing a character before
# the game starts and dressing one during it are the same job, and a second
# screen for the first would be a second place for the tiles, the slot filters
# and the quick-move rules to drift. The home screen's part is the state the
# screen deliberately does not keep — which body, which garments, which colours —
# because that is what has to outlive the editor and be handed to the spawn.


func _character_editor() -> Control:
	var body_id := CharacterDB.sanitize_body(str(_look.get("body", CharacterDB.DEFAULT_BODY)))
	if _worn_slots == null:
		_worn_slots = ItemContainer.new(ItemDB.SLOT_ORDER.size())
		for index in ItemDB.SLOT_ORDER.size():
			_worn_slots.set_filter(index, ItemDB.SLOT_ORDER[index])
		# One slot per garment cut for this body, worn or not. The editor's grid
		# is a catalogue rather than a bag, so nothing ever leaves it and there is
		# no free slot for anything to arrive in.
		_apparel_rail = ItemContainer.new(CharacterDB.apparel_ids(body_id).size())
		# Empty and unfillable — nothing has been picked up before the world
		# starts. It is here so the bar is where it will be, rather than as five
		# tiles that appear between the editor and the first time the menu is
		# opened and move everything under them when they do.
		_editor_weapons = ItemContainer.new(EDITOR_WEAPON_SLOTS)
		for index in EDITOR_WEAPON_SLOTS:
			_editor_weapons.set_filter(index, ItemDB.WEAPON)
		# The stats a new character starts with. `PlayerStats` needs nobody to
		# exist, so the editor can show the numbers you are about to play with
		# instead of a well explaining that it cannot.
		_editor_stats = PlayerStats.new()
		_worn_slots.changed.connect(_on_editor_changed)
	_stock_editor(body_id)

	var card := PanelContainer.new()
	PencilSurface.add_to(card, PencilSurface.Style.CARD)
	var padding := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		padding.add_theme_constant_override(side, 20)
	card.add_child(padding)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	padding.add_child(column)

	# The same two tabs the in-game menu has, from the same strip and against the
	# same two sections. Dressing a character and rummaging in what you own are
	# two jobs however far apart in the game they happen, and the editor showing
	# both at once was the one screen in the project that disagreed about that.
	_editor_tabs = HBoxContainer.new()
	_editor_tabs.add_theme_constant_override("separation", 10)
	column.add_child(_editor_tabs)

	_editor_host = MarginContainer.new()
	_editor_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_editor_host)

	_editor_pages.clear()
	_show_editor_tab(InventoryPage.Section.HERO)
	return card


func _show_editor_tab(section: InventoryPage.Section) -> void:
	MenuWidgets.fill_tab_row(_editor_tabs, EDITOR_TABS, int(section),
		func(index: int) -> void: _show_editor_tab(index as InventoryPage.Section))
	for child in _editor_host.get_children():
		child.visible = false
	_editor_pages.get_or_add(section, _new_editor_page(section))
	(_editor_pages[section] as Control).visible = true


## Built once per tab and kept, the way [GameMenu] keeps its pages.
##
## No preview on either, because there is already one: the figure hanging at the
## spawn behind this card is the character being edited, lit by the world's own
## sun and wearing exactly what the containers hold. The page used to render a
## second one into a SubViewport a couple of hundred pixels wide, which meant two
## models of the same character on screen at once, disagreeing about the light
## and about which way round they were turned.
func _new_editor_page(section: InventoryPage.Section) -> InventoryPage:
	var body_id := CharacterDB.sanitize_body(str(_look.get("body", CharacterDB.DEFAULT_BODY)))
	var page := InventoryPage.new()
	page.section = section
	page.show_preview = false
	page.catalogue = true
	page.configure(_worn_slots, _editor_weapons, _apparel_rail,
		_editor_stats, body_id, true)
	page.set_player_name(NetworkManager.saved_player_name())
	page.set_tints(_look.get("tints", {}))
	page.tint_picked.connect(_on_tint_picked)
	page.name_entered.connect(_rename)
	_editor_host.add_child(page)
	return page


## Puts the two containers in step with the look: what fits this body and is being
## worn goes on the body, and the whole of the body's wardrobe — including what is
## on the body — goes on the rail. Garments cut for the other skeleton are not
## offered at all.
##
## The rail listing the worn garments as well is what makes it a catalogue: an
## item is not in two places, it is in one list and worn or not, which is the only
## arrangement in which the grid can mark what is on the body.
func _stock_editor(body_id: String) -> void:
	_stocking = true
	var worn: Dictionary = _look.get("worn", {})
	for index in ItemDB.SLOT_ORDER.size():
		var slot: String = ItemDB.SLOT_ORDER[index]
		var item_id := str(worn.get(slot, ""))
		_worn_slots.set_item(index, item_id if CharacterDB.apparel_fits(body_id, item_id) else "")
	var wardrobe := CharacterDB.apparel_ids(body_id)
	for index in _apparel_rail.size():
		_apparel_rail.set_item(index, wardrobe[index] if index < wardrobe.size() else "")
	_stocking = false


func _on_editor_changed() -> void:
	if _stocking:
		return
	_capture_worn()
	_dress_preview()


## The equipment container is where a garment being worn is recorded; the look is
## a copy of it, taken whenever it moves.
func _capture_worn() -> void:
	var worn: Dictionary = {}
	for index in _worn_slots.size():
		var item_id := _worn_slots.get_item(index)
		if not item_id.is_empty():
			worn[_worn_slots.filter_of(index)] = item_id
	_look["worn"] = worn
	CharacterDB.save_look(_look)


## There is no body picker any more: [method CharacterDB.playable_ids] offers one
## body, so a picker would be a single button that does nothing. Turning the
## astronaut back on is the `playable` flag in `CharacterDB.BODIES`, and what has to
## come back with it is a row of buttons calling `_editor_page.set_body`, restocking
## through `_stock_editor` and respawning the figure — the containers and the look
## already handle a body change, and only the control for choosing it is gone.
func _on_tint_picked(target: String, colour: Color) -> void:
	var tints: Dictionary = (_look.get("tints", {}) as Dictionary).duplicate()
	tints[target] = colour.to_html(false)
	_look["tints"] = tints
	CharacterDB.save_look(_look)
	for page: Variant in _editor_pages.values():
		if is_instance_valid(page):
			(page as InventoryPage).set_tints(tints)
	_dress_preview()


func _set_notice(message: String, is_error: bool) -> void:
	_notice.text = message
	_notice.visible = not message.is_empty()
	_notice.add_theme_color_override(
		"font_color", PALETTE.danger if is_error else PALETTE.text_primary)


func _on_status_changed(message: String) -> void:
	if NetworkManager.state == NetworkManager.SessionState.IDLE:
		return
	_set_notice(message, NetworkManager.state == NetworkManager.SessionState.ERROR)


# --- Handing over ------------------------------------------------------------


func start_new_game() -> void:
	if _handover_target != null or _awaiting_player:
		return
	# The player starts exactly where the character they have been looking at was
	# standing, facing the way it was facing. Anything else would be a jump on the
	# frame the real body replaces the preview.
	CharacterDB.save_look(_look)
	_world().override_local_spawn(_preview.global_transform)
	_world().override_local_look(_look)
	NetworkManager.start_single_player()


func _on_session_started() -> void:
	if _handover_target != null:
		return
	_awaiting_player = true
	_dismiss_overlay()


func _dismiss_overlay() -> void:
	_menu.visible = false
	_back.visible = false
	if is_instance_valid(_screen):
		_screen.queue_free()
		_screen = null
	create_tween().tween_property(_title, "modulate:a", 0.0, 0.3)
	_notice.visible = false


func _begin_handover(player: OnlinePlayer) -> void:
	_handover_target = player
	player.controls_enabled = false
	player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
	# The real body is standing in the preview's shoes, so the swap is invisible.
	if is_instance_valid(_preview):
		_preview.queue_free()
	if _move != null and _move.is_valid():
		_move.kill()
	_handover_from = _camera.global_transform
	_handover_fov = _camera.fov
	_handover_at = 0.0
	# On the home screen the character is turned to face the camera, so "behind
	# them" points at empty sky. They turn back towards the planet as the camera
	# settles in, which is both the shot the player wants to be left holding and
	# the reason the sweep stays short: the camera barely has to travel, because
	# it was already standing where third person wants to be.
	_body_from = player.global_basis


func _advance_handover(delta: float) -> void:
	var player := _handover_target
	if not is_instance_valid(player):
		_handover_target = null
		queue_free()
		return
	_handover_at = minf(_handover_at + delta / HANDOVER_TIME, 1.0)
	var eased := ease(_handover_at, -1.8)
	player.global_basis = _body_from.slerp(frame.basis, eased).orthonormalized()
	_camera.global_transform = _handover_from.interpolate_with(
		player.camera.global_transform, eased)
	_camera.fov = lerpf(_handover_fov, player.camera.fov, eased)
	if _handover_at < 1.0:
		return
	player.take_camera()
	handed_over.emit()
	queue_free()


func _world() -> GameWorld:
	return get_parent() as GameWorld
