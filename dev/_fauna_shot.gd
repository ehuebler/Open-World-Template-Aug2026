extends Node

## Pictures of the alpaca herd where it actually lives, at the colony site.
##
##     godot --path . dev/_fauna_shot.tscn
##
## Not headless: the dummy renderer never draws a frame, so there is nothing to
## save. The colour-paint rule asks for one close view and one gameplay-distance
## view of anything whose look changes, and a new species changes all of it. The
## night pass is here for the same reason: the glow mask is authored into the
## paint's alpha and is invisible at noon.
##
## The camera is this file's own rather than the player's, because the subject is
## an animal standing several metres away and the player has to be left standing
## outside its flee range for it to keep standing there at all.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
const SETTLE_FRAMES := 220
const DAY := 0.0
const NIGHT := 0.5
## Far enough that the herd carries on grazing: inside its flee range every
## picture is of an alpaca leaving.
const WATCH_FROM := 13.0

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
		push_error("fauna_shot: planet=%s spawner=%s player=%s" % [
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

	var alpaca := _first_mob("aurora_fleece_alpaca")
	if alpaca == null:
		push_error("fauna_shot: no alpaca at the colony site")
		get_tree().quit(1)
		return
	_stand_off(alpaca)
	await _wait(SETTLE_FRAMES)
	# Re-read: the herd streams and the actor watched during the settle may have
	# been replaced by the time the pictures start.
	alpaca = _first_mob("aurora_fleece_alpaca")
	print("fauna_shot: %d fauna live, %d of them alpacas" % [
		_spawner.actor_count(),
		_spawner.species_count("aurora_fleece_alpaca")])

	await _quiet_shots(alpaca)
	await _night_shot(alpaca)
	await _provoked_shots(alpaca)
	get_tree().quit()


## The animal itself, and then the herd from where it is normally seen.
func _quiet_shots(alpaca: FaunaMob) -> void:
	alpaca.set(&"_graze_left", 8.0)
	await _wait(45)
	_frame_on(alpaca, 3.4, 1.1)
	await _shot("fauna_alpaca_close_graze")
	alpaca.set(&"_graze_left", 0.0)
	await _wait(120)
	_frame_on(alpaca, 4.2, 1.4)
	await _shot("fauna_alpaca_close_stand")
	_frame_on(alpaca, 17.0, 5.0)
	await _shot("fauna_alpaca_gameplay")


## After sunset, when the paint's alpha becomes the glow and the spawner's light
## pool is what puts the herd on the ground rather than floating in the dark.
func _night_shot(alpaca: FaunaMob) -> void:
	if _cycle != null:
		_cycle.set_phase(NIGHT)
	await _wait(150)
	_frame_on(alpaca, 4.6, 1.5)
	await _shot("fauna_alpaca_night_close")
	_frame_on(alpaca, 17.0, 5.0)
	await _shot("fauna_alpaca_night_gameplay")
	if _cycle != null:
		_cycle.set_phase(DAY)
	await _wait(90)


## Hurt one and watch what a friendly animal does about it: hold a ring around
## whoever hurt it and throw. The ball is caught by waiting for one to exist
## rather than by guessing at the windup.
func _provoked_shots(alpaca: FaunaMob) -> void:
	var hit := DamageHit.impact(alpaca.combat_position(), 1.0, 6.0)
	hit.faction = DamageHit.Faction.PLAYER
	hit.set_source(_player)
	alpaca.apply_damage(hit)
	await _wait(24)
	_frame_across(alpaca)
	await _shot("fauna_alpaca_provoked")
	for attempt in 4:
		var ball := await _wait_for_ball(150)
		if ball == null:
			print("fauna_shot: no spit in the air on attempt %d" % (attempt + 1))
			continue
		_frame_ball(ball)
		await _shot("fauna_alpaca_spit")
		print("fauna_shot: caught a spit %.1f m from the player" % ball
			.global_position.distance_to(_player.global_position))
		return


func _wait_for_ball(frames: int) -> Node3D:
	for _frame in frames:
		await get_tree().process_frame
		var balls := _planet.find_children("*", "FaunaSpit", false, false)
		if not balls.is_empty():
			return balls[0] as Node3D
	return null


## Puts the player where it can be spat at but not so close that the herd bolts.
func _stand_off(alpaca: FaunaMob) -> void:
	var up := _planet.up_at(alpaca.global_position)
	var at := alpaca.global_position + _side(up) * WATCH_FROM
	_player.global_position = _planet.standing_position(
		_planet.to_local(at).normalized(), 0.4)
	_player.velocity = Vector3.ZERO
	_player.look_at(alpaca.global_position, up)


## Three-quarter view from the animal's front left, which is the angle that shows
## the saddle, the face, and the legs in one frame.
func _frame_on(mob: Node3D, away: float, height: float) -> void:
	var up := _planet.up_at(mob.global_position)
	var forward := -mob.global_basis.z
	var eye := mob.global_position + forward * away * 0.72 \
		+ _side(up) * away * 0.68 + up * height
	_aim(eye, mob.global_position + up * 0.55)


## Square across the line between the animal and the player, close to the animal:
## far enough back to hold the ring it is circling on, near enough that the animal
## is more than a speck.
func _frame_across(mob: Node3D) -> void:
	var up := _planet.up_at(mob.global_position)
	var toward := _flat(mob.global_position - _player.global_position, up)
	var eye := mob.global_position + up.cross(toward).normalized() * 5.0 \
		+ toward * 1.5 + up * 1.9
	_aim(eye, mob.global_position + up * 0.7)


## On the ball itself, from beside its flight, with whatever threw it behind it.
## A thirteen-centimetre ball is invisible in any wider view than this.
func _frame_ball(ball: Node3D) -> void:
	var up := _planet.up_at(ball.global_position)
	var along := _flat(_player.global_position - ball.global_position, up)
	var eye := ball.global_position + up.cross(along).normalized() * 3.0 \
		+ up * 1.0 - along * 1.4
	_aim(eye, ball.global_position)


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
		print("fauna_shot: %s skipped, no renderer" % shot_name)
		return
	_camera.make_current()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	print("fauna_shot: %s %s" % [
		shot_name, "saved" if error == OK else error_string(error)])
