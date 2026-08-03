extends Node

## Throwaway. What draws each part of an underwater frame, found by taking the same
## shot with one shell at a time removed.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
const REEF_DEPTH := 11.0
const SURVEY := 8000

var _player: OnlinePlayer
var _planet: Planet
var _water: PlanetWater
var _reef := Vector3.UP


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	for frame in 30:
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if _player != null:
			break
	_planet = get_tree().current_scene.find_child("Planet", true, false) as Planet
	_water = _planet.water

	var reefiest := INF
	for index in SURVEY:
		var direction := PlanetShape.even_direction(index, SURVEY)
		var height := _planet.shape.elevation(direction)
		if absf(height + REEF_DEPTH) < reefiest:
			reefiest = absf(height + REEF_DEPTH)
			_reef = direction

	_player.set_physics_process(false)
	_player.hud.visible = false
	await _hold(_reef, -(REEF_DEPTH - 2.5) - _player.head.position.y, -0.15)
	print("probe: eye %.1f m under, disc reach %.0f m" % [
		_water.depth_at(_player.head.global_position),
		_water.get_node("Surface").scale.x])

	await _shot("probe_all")

	var surface := _water.get_node("Surface") as MeshInstance3D
	surface.visible = false
	await _wait(4)
	await _shot("probe_no_sea")
	surface.visible = true

	for child: Node in _planet.get_children(true):
		if child.name in ["Clouds", "Atmosphere", "Snowfield"] and child is Node3D:
			(child as Node3D).visible = false
			print("probe: hid %s" % child.name)
	await _wait(4)
	await _shot("probe_no_sky")
	get_tree().quit()


func _hold(direction: Vector3, altitude: float, pitch: float) -> void:
	var up := direction.normalized()
	var facing := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var side := facing.cross(up).normalized()
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (_planet.shape.radius + altitude))
	_player.velocity = Vector3.ZERO
	_player.set_camera_mode(OnlinePlayer.CameraMode.FIRST)
	_player._pitch = pitch
	_player.head.rotation.x = pitch
	await _wait(200)


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(SHOT_DIR + shot_name + ".png")
	var lines := PackedStringArray()
	for share: float in [0.38, 0.40, 0.42, 0.44, 0.46, 0.50]:
		var y := int(image.get_height() * share)
		var colour := image.get_pixel(int(image.get_width() * 0.93), y)
		lines.append("y%.2f %.2f/%.2f/%.2f" % [share, colour.r, colour.g, colour.b])
	print("probe: %-14s %s" % [shot_name, " ".join(lines)])


func _wait(frames: int) -> void:
	for frame in frames:
		await get_tree().physics_frame
