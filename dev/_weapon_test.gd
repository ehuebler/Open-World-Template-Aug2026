extends Node

## Arms the player and photographs every hold, the swing, and a shot in flight.
##
## Run it from the project root:
##
##     & $godot --path . dev/_weapon_test.tscn
##
## As well as the shots it measures the grip, which is the part that cannot be
## judged by eye: whether the blade really points up, whether the support hand is
## on the weapon rather than waving beside it, and whether a shot leaves the muzzle
## along the crosshair. Shots land in dev/captures/.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

var _player: OnlinePlayer
var _review: Camera3D
## Bone poses read off the skeleton are a frame behind the modifier that moved
## them, so the hands are measured through attachments, which are not.
var _hand_probes: Dictionary = {}
## The landing site's frame, which every position in this file is measured in.
## The world's origin is the planet's centre now — 8 km underground — so a bare
## world coordinate puts the player inside the core.
var _ground := Transform3D.IDENTITY


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# The world opens the home screen and spawns nobody while the session reads as
	# idle, so the state has to say "in game" before it comes up.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	for _frame in 10:
		await get_tree().process_frame
	_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
	var site := get_tree().current_scene.find_child("LandingSite", true, false) as Node3D
	if _player == null or site == null:
		push_error("weapon_test: player=%s site=%s" % [_player, site])
		get_tree().quit(1)
		return
	_ground = site.global_transform
	_review = Camera3D.new()
	_review.fov = 38.0
	add_child(_review)
	_add_hand_probes()
	await _run()
	get_tree().quit()


func _run() -> void:
	# Slots 1 and 3, leaving gaps, so the wheel has something to skip over.
	_player.weapons.set_item(0, "sword")
	_player.weapons.set_item(2, "laser_rifle")
	# Out on clear grass, and in third person: the body is drawn as shadow only
	# while the player's own camera is inside its head, whatever camera is looking.
	_place(Vector3(11.0, 0.4, 11.0), PI)
	_player._camera_mode = 1
	await _wait(40)

	await _selection()
	await _sword()
	await _walking()
	await _rifle()
	await _first_person()
	await _rack()


## Number keys reach every slot; the wheel only stops on the filled ones.
func _selection() -> void:
	_player.select_weapon(0)
	await _wait(10)
	var report := "1:%s" % _player.held_item()
	_player.select_weapon(1)
	await _wait(10)
	report += "  2(empty):'%s'" % _player.held_item()
	_player._cycle_weapon(1)
	await _wait(10)
	report += "  wheel up:%s" % _player.held_item()
	_player._cycle_weapon(1)
	await _wait(10)
	report += "  again:%s" % _player.held_item()
	_player._cycle_weapon(-1)
	await _wait(10)
	report += "  wheel down:%s" % _player.held_item()
	_report("selection", report)

	# Through the real event path this time, so a mis-mapped action cannot pass by
	# being called directly.
	_key(KEY_1)
	await _wait(10)
	report = "key 1:%s" % _player.held_item()
	_click(MOUSE_BUTTON_LEFT)
	await _wait(4)
	report += "  click swings:%s" % _player._weapon_pose.swinging()
	_report("input", report)
	await _wait(45)


func _sword() -> void:
	_player.select_weapon(0)
	await _wait(45)
	_report("sword hold", _grip())
	await _look_from(Vector3(1.2, 1.0, -1.6))
	await _shot("weapon_sword_hold")
	await _look_from(Vector3(2.1, 1.0, -0.1))
	await _shot("weapon_sword_side")

	# Frames through the cut, from the front: whether it travels across the body
	# from the right cannot be judged from behind.
	await _look_from(Vector3(0.3, 1.0, -2.2))
	_player._attack()
	for index in 4:
		await _wait(5)
		_report("swing %d" % index, _grip())
		await _shot("weapon_sword_swing_%d" % index)
	await _wait(40)


## The whole point of solving the arms rather than baking a hold clip: the legs
## should still be running their own clip underneath it.
func _walking() -> void:
	_place(Vector3(11.0, 0.4, 13.0), PI)
	_player.select_weapon(0)
	await _wait(30)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _wait(45)
	await _look_from(Vector3(2.2, 1.0, -0.2))
	_report("running", "clip=%s  %s" % [_player._clip, _grip()])
	await _shot("weapon_sword_running")
	Input.action_release("sprint")
	Input.action_release("move_forward")
	await _wait(20)


func _rifle() -> void:
	_player.select_weapon(2)
	await _wait(45)
	_report("rifle hold", _grip())
	await _look_from(Vector3(1.3, 1.0, -1.6))
	await _shot("weapon_rifle_hold")
	await _look_from(Vector3(2.1, 1.0, -0.1))
	await _shot("weapon_rifle_side")

	# Held as a player holds it: the controller reads the polled action every frame,
	# so setting the pose directly would be undone by the next one.
	Input.action_press("aim")
	await _wait(30)
	_report("rifle aimed", _grip())
	await _shot("weapon_rifle_aimed")
	await _look_from(Vector3(2.1, 1.0, -0.1))
	await _shot("weapon_rifle_aimed_side")

	# Watched from the side with the view opened up: a bolt covers more than a metre
	# per frame, so a shot photographed down its own line is a dot.
	_place(Vector3(0.0, 0.4, 6.0), 0.0)
	await _look_from(Vector3(3.0, 0.9, -1.2))
	_review.fov = 74.0
	var before := _player._charge()
	_player._shoot()
	await _wait(2)
	await _shot("weapon_bolt")
	_review.fov = 38.0
	await _wait(2)
	var bolts := _bolts()
	var offset := "none"
	if not bolts.is_empty():
		var bolt := bolts[0]
		var along := -bolt.global_basis.z
		offset = "%.1f°" % rad_to_deg(along.angle_to(-_player.camera.global_basis.z))
	_report("shot", "cell %d -> %d  bolts=%d  off crosshair=%s" % [
		before, _player._charge(), bolts.size(), offset])
	await _shot("weapon_rifle_shot")

	# Empty the cell, then let it trickle back.
	for _index in 20:
		_player._shoot()
		await _wait(2)
	var emptied := _player._charge()
	await _wait(150)
	_report("cell", "emptied to %d, back to %d after 2.5s (pause %.2f, charge %.2f)" % [
		emptied, _player._charge(), _player._cell_pause,
		float(_player._cells.get("laser_rifle", -1.0))])
	Input.action_release("aim")
	await _wait(30)


## First person is the case the body is hidden in, so what is left of the weapon
## has to be looked at rather than assumed.
func _first_person() -> void:
	_player.camera.current = true
	_player._camera_mode = 0
	_player.select_weapon(0)
	await _wait(50)
	await _shot("weapon_first_person_sword")
	_player.select_weapon(2)
	await _wait(50)
	await _shot("weapon_first_person_rifle")
	Input.action_press("aim")
	await _wait(40)
	await _shot("weapon_first_person_aimed")
	Input.action_release("aim")
	await _wait(20)


## Weapons are armed the way a player arms them — into the backpack, then
## shift-clicked onto the rack — rather than by writing to the weapons container.
## The wardrobe they used to be taken off is gone; the admin tab is where an item
## comes from now, so the backpack is where this starts.
func _rack() -> void:
	_player.weapons.clear()
	_player.select_weapon(0)
	_place(Vector3(0.0, 0.4, 1.7), 0.0)
	await _wait(30)
	for id in ["sword", "laser_rifle"]:
		_player.backpack.set_item(_player.backpack.first_accepting(id), id)
	# Opening the menu is what builds the tiles, and the tiles are the path being
	# measured: a weapon that reaches the hand only when written straight to the
	# container is a weapon the rack cannot actually arm.
	_player._open_game_menu(GameMenu.Tab.INVENTORY)
	# The menu stops a single-player world, which is right in the game and wrong
	# here: the weapon pose runs after the locomotion clip, so a stopped body would
	# be photographed holding the weapon in whatever pose it had before the hold was
	# applied.
	get_tree().paused = false
	await _wait(60)

	for id in ["sword", "laser_rifle"]:
		var tile := _tile_for(_player.backpack, _player.backpack.find(id))
		if tile == null:
			_report("rack", "no backpack tile for %s" % id)
			continue
		tile.quick_move_requested.emit(tile)
		await _wait(12)
	_report("rack", "racked %s  held=%s  rack tiles=%d" % [
		_player.weapons.items(), _player.held_item(), _rack_tiles()])
	await _shot("weapon_rack")


func _rack_tiles() -> int:
	var found := 0
	for tile in _tiles(_player.hud):
		if tile.container == _player.weapons:
			found += 1
	return found


func _tile_for(container: ItemContainer, index: int) -> ItemSlot:
	if index < 0:
		return null
	for tile in _tiles(_player.hud):
		if tile.container == container and tile.index == index:
			return tile
	return null


func _tiles(root: Node) -> Array[ItemSlot]:
	var found: Array[ItemSlot] = []
	for node in root.find_children("*", "Control", true, false):
		if node is ItemSlot:
			found.append(node as ItemSlot)
	return found


# --- Measurements -----------------------------------------------------------

## What the hold is actually doing, in numbers: where the weapon points, and how
## far the supporting hand is off its axis.
func _grip() -> String:
	var mesh := _player._held_mesh
	if mesh == null:
		return "nothing in hand"
	var origin := mesh.global_position
	var along := -mesh.global_basis.z
	var support := _grip_point("LeftHand")
	var lead := _grip_point("RightHand")
	return "points %s  up=%+.2f  cant %.0f°  support %.0f mm off the axis  grips %.0f mm apart" % [
		_compass(along), along.dot(Vector3.UP),
		rad_to_deg(_cant(along)),
		_distance_to_axis(support, origin, along) * 1000.0,
		support.distance_to(lead) * 1000.0]


## How far off the way the character faces the weapon points, measured flat: a
## carbine held across the chest reads as wrong however good the grip is.
func _cant(along: Vector3) -> float:
	var local: Vector3 = _player.global_basis.inverse() * along
	return absf(atan2(local.x, -local.z))


## The weapon's direction in the character's own terms, which is what a pose is
## described in.
func _compass(direction: Vector3) -> String:
	var local: Vector3 = _player.global_basis.inverse() * direction
	var parts := PackedStringArray()
	if absf(local.z) > 0.3:
		parts.append("forward" if local.z < 0.0 else "back")
	if absf(local.y) > 0.3:
		parts.append("up" if local.y > 0.0 else "down")
	if absf(local.x) > 0.3:
		parts.append("right" if local.x > 0.0 else "left")
	return " ".join(parts) if parts.size() > 0 else "level"


func _distance_to_axis(point: Vector3, origin: Vector3, along: Vector3) -> float:
	var offset := point - origin
	return (offset - along.normalized() * offset.dot(along.normalized())).length()


func _add_hand_probes() -> void:
	var skeleton := Weapons.skeleton_of(_player.character)
	for bone_name in ["LeftHand", "RightHand"]:
		var probe := BoneAttachment3D.new()
		skeleton.add_child(probe)
		probe.bone_name = bone_name
		_hand_probes[bone_name] = probe


## Where the hand grips, rather than where its wrist is: a weapon sits part way
## down the hand bone, and the wrist trailing the grip is not a miss.
func _grip_point(bone_name: String) -> Vector3:
	var probe := _hand_probes.get(bone_name) as BoneAttachment3D
	if probe == null:
		return Vector3.ZERO
	var skeleton := Weapons.skeleton_of(_player.character)
	var bone := skeleton.find_bone(bone_name)
	var along := skeleton.get_bone_rest(bone).origin.length() * Weapons.GRIP_ALONG_HAND
	return probe.global_position + probe.global_basis.y.normalized() * along


func _bolts() -> Array[LaserBolt]:
	var found: Array[LaserBolt] = []
	for node in get_tree().current_scene.find_children("*", "Node3D", true, false):
		if node is LaserBolt:
			found.append(node as LaserBolt)
	return found


# --- Helpers ----------------------------------------------------------------

## [param offset] is metres in the landing site's frame — its +Y is up out of the
## planet there — and [param yaw] turns about that up rather than the world's.
func _place(offset: Vector3, yaw: float) -> void:
	_player.global_transform = Transform3D(
		_ground.basis * Basis(Vector3.UP, yaw), _ground * offset)
	_player.velocity = Vector3.ZERO


## Reviews the character from `offset` in its own frame: +X its right, -Z the way
## it faces, so the same offset frames every pose the same way.
func _look_from(offset: Vector3) -> void:
	var eye: Vector3 = _player.global_position + _player.global_basis * offset
	_review.global_position = eye
	_review.look_at(_player.global_position + Vector3(0.0, 0.95, 0.0), Vector3.UP)
	_review.current = true
	await _wait(2)


func _key(code: Key) -> void:
	var press := InputEventKey.new()
	press.keycode = code
	press.physical_keycode = code
	press.pressed = true
	Input.parse_input_event(press)
	var release := press.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)


func _click(button: MouseButton) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = button
	press.pressed = true
	Input.parse_input_event(press)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	Input.parse_input_event(release)


func _wait(frames: int) -> void:
	for _index in frames:
		await get_tree().process_frame


func _report(step: String, detail: String) -> void:
	print("weapon_test: %-14s %s" % [step, detail])


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		print("weapon_test: shot %s failed: %s" % [shot_name, error_string(error)])
