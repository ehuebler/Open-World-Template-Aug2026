extends Node

## Close and gameplay-distance validation of the painted den on its real cliff.
##
##     godot --path . dev/_rhino_den_shot.tscn

const WORLD := preload("res://game/world.tscn")
const PREVIEW_DIR := "res://assets/previews/fauna/"
const SETTLE_FRAMES := 300

var _world: GameWorld
var _planet: Planet
var _player: OnlinePlayer
var _camera: Camera3D
var _den: RhinoDen


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(12)
	_planet = _world.find_child("Planet", true, false) as Planet
	var spawner := _world.find_child(
		"FaunaPopulations", true, false) as FaunaSpawner
	_player = get_tree().get_first_node_in_group(
		"network_players") as OnlinePlayer
	_den = spawner.rhino_den() as RhinoDen if spawner != null else null
	if _planet == null or _player == null or _den == null:
		push_error("rhino_den_shot: missing planet, player, spawner, or den")
		get_tree().quit(1)
		return
	if _player.hud != null:
		_player.hud.visible = false
	var cycle := _world.find_child(
		"CelestialCycle", true, false) as CelestialCycle
	if cycle != null:
		cycle.period_seconds = 0.0
		cycle.set_phase(0.0)

	_camera = Camera3D.new()
	_camera.name = &"RhinoDenCamera"
	_camera.fov = 60.0
	_camera.far = 4000.0
	_planet.add_child(_camera)
	_move_player_to_den(18.0)
	await _wait(SETTLE_FRAMES)
	print("rhino_den_shot: %.1f degree site" % _den.cliff_slope_degrees())
	# Both views use the same known-clear overlook. The close validation narrows
	# the lens instead of putting the camera into the water below this cliff.
	_frame_den(34.0, 5.8, 0.20, 20.0)
	await _shot("cinder_plate_rhino_den_close")
	_frame_den(34.0, 5.8, 0.20, 60.0)
	await _shot("cinder_plate_rhino_den_gameplay")
	get_tree().quit()


func _move_player_to_den(away: float) -> void:
	var up := _planet.up_at(_den.global_position)
	var forward := -_den.global_basis.z.normalized()
	var wanted := _den.global_position + forward * away
	_player.global_position = _planet.standing_position(
		_planet.to_local(wanted).normalized(), 0.4)
	_player.velocity = Vector3.ZERO
	_player.look_at(_den.global_position + up * 2.0, up)


func _frame_den(away: float, height: float, side_share: float,
		fov: float) -> void:
	var up := _planet.up_at(_den.global_position)
	var forward := -_den.global_basis.z.normalized()
	var side := up.cross(forward).normalized()
	var eye := _den.global_position + forward * away \
		+ side * away * side_share + up * height
	_camera.global_position = eye
	_camera.fov = fov
	_camera.look_at(_den.global_position + up * 2.0, up)
	_camera.make_current()


func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		push_error("rhino_den_shot: no renderer")
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(
		PREVIEW_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	print("rhino_den_shot: %s %s" % [
		shot_name, "saved" if error == OK else error_string(error)])


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame
