extends Node

## Pictures of the rhino herd where it actually lives, on the settlement frontier.
##
##     godot --path . dev/_rhino_shot.tscn
##
## Not headless: the dummy renderer never draws a frame, so there is nothing to
## save. The colour-paint rule asks for one close view and one gameplay-distance
## view of anything whose look changes, and the night pass is here because the
## ember seams are authored into the paint's alpha and are invisible at noon.
##
## The rest of it is the attack, which cannot be posed for: the animal decides
## when to paw and when to run, so the camera waits on the states it wants and
## takes the picture when they come around.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
const SETTLE_FRAMES := 260
const DAY := 0.0
const NIGHT := 0.5
## Outside the rhino's notice range, so the quiet pictures are of an animal that
## has not seen anybody, and inside it, so the loud ones are.
const WATCH_FROM := 34.0
const PROVOKE_FROM := 15.0

var _world: GameWorld
var _planet: Planet
var _player: OnlinePlayer
var _spawner: FaunaSpawner
var _cycle: CelestialCycle
var _camera: Camera3D


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(10)

	_planet = _world.find_child("Planet", true, false) as Planet
	_spawner = _world.find_child(
		"FaunaPopulations", true, false) as FaunaSpawner
	_cycle = _world.find_child("CelestialCycle", true, false) as CelestialCycle
	_player = get_tree().get_first_node_in_group(
		"network_players") as OnlinePlayer
	if _planet == null or _spawner == null or _player == null:
		push_error("rhino_shot: planet=%s spawner=%s player=%s" % [
			_planet, _spawner, _player])
		get_tree().quit(1)
		return
	if _player.hud != null:
		_player.hud.visible = false
	if _cycle != null:
		_cycle.period_seconds = 0.0
		_cycle.set_phase(DAY)
	_camera = Camera3D.new()
	_camera.name = "ShotCamera"
	_camera.fov = 62.0
	_camera.far = 4000.0
	_planet.add_child(_camera)

	var rhino := _first_mob("cinder_plate_rhino")
	if rhino == null:
		push_error("rhino_shot: no rhino on the settlement frontier")
		get_tree().quit(1)
		return
	_stand_off(rhino, WATCH_FROM)
	await _wait(SETTLE_FRAMES)
	rhino = _first_mob("cinder_plate_rhino")
	_report(rhino)

	await _quiet_shots(rhino)
	await _night_shots(rhino)
	await _charge_shots(rhino)
	get_tree().quit()


## Where the herd ended up, in the terms the placement is expressed in: metres
## out from the ship, which is where the settlement's boundary is measured from.
func _report(rhino: FaunaMob) -> void:
	var ship := _planet.get_node_or_null("ColonyShip") as Node3D
	var out := 0.0
	if ship != null and rhino != null:
		out = _planet.to_local(ship.global_position).normalized().angle_to(
			_planet.to_local(rhino.global_position).normalized()) \
			* _planet.shape.radius
	print("rhino_shot: %d fauna live, %d rhinos, nearest %.0f m from the ship"
		% [_spawner.actor_count(),
			_spawner.species_count("cinder_plate_rhino"), out])


## Close enough to judge the paint, then from eye level at the distance one is
## normally first seen from. Deliberately not from above: the flora here is chest
## high on this animal, and a view over the top of it flatters the silhouette.
func _quiet_shots(rhino: FaunaMob) -> void:
	_frame_on(rhino, 5.0, 1.7)
	await _shot("fauna_rhino_close")
	_frame_on(rhino, 16.0, 3.0)
	await _shot("fauna_rhino_gameplay")


func _night_shots(rhino: FaunaMob) -> void:
	if _cycle != null:
		_cycle.set_phase(NIGHT)
	await _wait(150)
	_frame_on(rhino, 5.4, 1.8)
	await _shot("fauna_rhino_night_close")
	_frame_on(rhino, 16.0, 3.0)
	await _shot("fauna_rhino_night_gameplay")
	if _cycle != null:
		_cycle.set_phase(DAY)
	await _wait(90)


## Walk into its notice range and let it do the rest. Each picture is taken on
## the state it belongs to rather than on a timer, because the length of a paw
## and the moment of a hit are the animal's to decide.
func _charge_shots(rhino: FaunaMob) -> void:
	_stand_off(rhino, PROVOKE_FROM)
	await _wait(20)
	if await _wait_for_state(rhino, FaunaMob.MotionState.PAW, 400):
		_frame_across(rhino, 7.0, 2.0)
		await _shot("fauna_rhino_paw")
	else:
		print("rhino_shot: it never squared up")
	if await _wait_for_state(rhino, FaunaMob.MotionState.CHARGE, 300):
		_frame_across(rhino, 9.0, 2.2)
		await _shot("fauna_rhino_charge")
	else:
		print("rhino_shot: it never committed")
	if await _wait_for_gore(rhino, 300):
		_frame_across(rhino, 6.0, 2.0)
		await _shot("fauna_rhino_gore")
		print("rhino_shot: the horn connected %.1f m from the player"
			% rhino.global_position.distance_to(_player.global_position))
	else:
		print("rhino_shot: the charge missed")


func _wait_for_state(rhino: FaunaMob, state: int, frames: int) -> bool:
	for _frame in frames:
		if not is_instance_valid(rhino):
			return false
		if rhino.motion_state() == state:
			return true
		await get_tree().process_frame
	return false


func _wait_for_gore(rhino: FaunaMob, frames: int) -> bool:
	for _frame in frames:
		if not is_instance_valid(rhino):
			return false
		if float(rhino.get(&"_gore_show_left")) > 0.0:
			return true
		await get_tree().process_frame
	return false


## Puts the player out in front of the animal at a chosen distance, facing it,
## which is both what a player walking up to one looks like and what decides
## whether it has seen them.
func _stand_off(rhino: FaunaMob, away: float) -> void:
	if rhino == null:
		return
	var up := _planet.up_at(rhino.global_position)
	var at := rhino.global_position - rhino.global_basis.z * away
	_player.global_position = _planet.standing_position(
		_planet.to_local(at).normalized(), 0.4)
	_player.velocity = Vector3.ZERO
	_player.look_at(rhino.global_position, up)


## Three-quarter view from the animal's front left: the angle that shows the
## horn, the shoulder plates, and the legs in one frame.
func _frame_on(mob: Node3D, away: float, height: float) -> void:
	var up := _planet.up_at(mob.global_position)
	var forward := -mob.global_basis.z
	var eye := mob.global_position + forward * away * 0.72 \
		+ _side(up) * away * 0.68 + up * height
	_aim(eye, mob.global_position + up * 0.9)


## Square across the line between the animal and the player, which is the view a
## charge reads in: both ends of it are in frame and the closing is visible.
func _frame_across(mob: Node3D, away: float, height: float) -> void:
	var up := _planet.up_at(mob.global_position)
	var toward := _flat(_player.global_position - mob.global_position, up)
	var middle := mob.global_position.lerp(_player.global_position, 0.35)
	var eye := middle + up.cross(toward).normalized() * away + up * height
	_aim(eye, middle + up * 0.9)


func _flat(direction: Vector3, up: Vector3) -> Vector3:
	var flat := direction - up * direction.dot(up)
	return flat.normalized() if flat.length_squared() > 0.000001 \
		else _side(up)


func _aim(eye: Vector3, at: Vector3) -> void:
	_camera.global_position = eye
	_camera.look_at(at, _planet.up_at(eye))
	_camera.make_current()


func _side(up: Vector3) -> Vector3:
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		side = up.cross(Vector3.FORWARD)
	return side.normalized()


func _first_mob(species_id: String) -> FaunaMob:
	for child_variant: Variant in _spawner.get_children():
		var mob := child_variant as FaunaMob
		if mob != null and mob.species != null \
				and mob.species.species_id == species_id:
			return mob
	return null


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		print("rhino_shot: %s skipped, no renderer" % shot_name)
		return
	_camera.make_current()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	print("rhino_shot: %s %s" % [
		shot_name, "saved" if error == OK else error_string(error)])
