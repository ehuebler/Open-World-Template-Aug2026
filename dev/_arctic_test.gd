extends Node

## The polar cap: how big it is, what it did to the sea, and what it does to a
## walk.
##
##     & $godot --path . dev/_arctic_test.tscn
##
## The **survey** measures the cap off the height field itself — its share of the
## surface, and whether the arctic ocean actually froze — which is the half that
## can be wrong silently, because a cap the wrong size still looks like a cap.
## The **walk** puts a player on the floe and then in the snow and reports what
## each did to the same two seconds of holding forward, plus how many prints came
## out of it. Shots land in dev/captures/.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

## Directions surveyed over the sphere. Enough that a per-cent of the surface is
## eighty samples and not eight.
const SURVEY := 8000

# OnlinePlayer.Stance, which is private to the player and read here by index.
const FLY := 3

var _player: OnlinePlayer
var _planet: Planet
## Somewhere well inside the cap that is pack ice, and somewhere well inside it
## that is snow over ground. Both picked from the same pass.
var _floe := Vector3.UP
var _drift := Vector3.UP


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
	if _player == null or _planet == null or _planet.snowfield == null:
		push_error("arctic_test: player=%s planet=%s snowfield=%s" % [
			_player, _planet, _planet.snowfield if _planet != null else null])
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	_survey()
	await _walk()
	await _look()
	get_tree().quit()


## The cap as the height field has it. Two things can be wrong here without
## anything looking wrong: the cap can be the wrong size, and the sea inside it
## can have failed to freeze — a floe is flat and white, and so is deep water
## seen from far enough away.
func _survey() -> void:
	var shape := _planet.shape
	# Summed rather than counted. The cap has a soft edge, so "how much of the
	# planet is arctic" is the frost integrated over the sphere; counting every
	# sample the edge touches measures the outside of the band instead, and comes
	# out three points high however right the cap is.
	var covered := 0.0
	var inside := 0
	var ice := 0
	var snow := 0
	var open := 0
	# Nearest the pole, not deepest in the frost. Frost is a smoothstep and it
	# saturates: everything inside the inner edge reads exactly 1.0, so picking
	# the highest picks whichever sample happened to reach 1.0 first, which is on
	# the rim of the full-frost zone forty-odd degrees out. Photographed from
	# there the cap is half in night and the pictures say the ground never went
	# white — which is what the first three runs of this claimed.
	var on_floe := -1.0
	var in_snow := -1.0
	var north := shape.frost_axis.normalized()
	for index in SURVEY:
		var direction := PlanetShape.even_direction(index, SURVEY)
		var chill := shape.frost(direction)
		if chill <= 0.0:
			continue
		covered += chill
		if chill < 0.5:
			continue
		inside += 1
		var height := shape.elevation(direction)
		if height < 0.0:
			# The floe does not end in a wall: through the band its surface
			# ramps down to the sea bed it was lifted off, so the outer part of
			# the cap is open water and is meant to be.
			open += 1
		elif height <= PlanetShape.ICE_TOP + 0.05:
			ice += 1
			if direction.dot(north) > on_floe:
				on_floe = direction.dot(north)
				_floe = direction
		else:
			snow += 1
			if direction.dot(north) > in_snow:
				in_snow = direction.dot(north)
				_drift = direction
	print("arctic_test: cap    %.1f%% of the surface (asked for %.0f%%)" % [
		covered * 100.0 / SURVEY, shape.frost_area * 100.0])
	print("arctic_test: inside %d%% floe, %d%% snow, %d%% open water at the edge" % [
		ice * 100 / maxi(inside, 1), snow * 100 / maxi(inside, 1),
		open * 100 / maxi(inside, 1)])
	# The cap's own daylight, which is the sun's declination and nothing else: at
	# the pole the horizon *is* the equatorial plane. Below zero the arctic is in
	# polar night, every shot of it is a black disc, and no amount of white in
	# PlanetShape will show up in one.
	var sun := get_tree().current_scene.find_child("Sun", true, false) as DirectionalLight3D
	if sun != null:
		# A light shines along its own -Z, so +Z is the direction of the sun.
		print("arctic_test: sun    %.1f degrees over the pole" % rad_to_deg(
			asin(clampf(sun.global_basis.z.dot(_planet.shape.frost_axis.normalized()),
				-1.0, 1.0))))
	if ice == 0:
		push_error("arctic_test: nothing in the cap froze")
	if absf(covered * 100.0 / SURVEY - shape.frost_area * 100.0) > 1.5:
		push_error("arctic_test: the cap came out %.1f%% against the %.0f%% asked for" % [
			covered * 100.0 / SURVEY, shape.frost_area * 100.0])


## The same two seconds of forward, on ice and then in snow. What is being
## checked is that the two are different and in the right direction: the floe
## should carry further than a stride would and the snow should not reach one.
func _walk() -> void:
	var slid := await _hold(_floe, "floe")
	var trudged := await _hold(_drift, "snow")
	print("arctic_test: walk   %.1f m on the floe against %.1f m through the snow" % [
		slid, trudged])
	if slid <= trudged:
		push_error("arctic_test: the ice is no faster than the snow")


## Drops the player on a spot, holds forward for two seconds, and reports the
## ground covered and — for snow — the prints left behind.
func _hold(direction: Vector3, what: String) -> float:
	await _put(direction)
	# Long enough for the quadtree to build ground under a viewer that arrived by
	# teleport, and for the drop onto it to settle.
	await _wait(240)
	if _player._stance == FLY:
		push_error("arctic_test: still flying over the %s — measuring a hover" % what)
	var prints := _print_count()
	var from := _player.global_position
	Input.action_press("move_forward")
	await _wait(120)
	Input.action_release("move_forward")
	var travelled := from.distance_to(_player.global_position)
	print("arctic_test: %-6s %.1f m in 2.0 s (%.1f m/s), %d prints, %s underfoot" % [
		what, travelled, travelled / 2.0, _print_count() - prints,
		"ice" if _player._on_ice else "snow at %.2f" % _player._frost])
	# Photographed here rather than only from orbit, because the floe and the snow
	# are two different colours and from eleven kilometres up the cap is one wash of
	# whichever covers more of it. Aimed down: what is being looked at is the ground.
	_player._pitch = -0.5
	_player.head.rotation.x = -0.5
	await _wait(30)
	await _shoot("arctic_" + what)
	return travelled


## The cap from two distances: standing on it, where the snow has to be falling
## and the prints have to be visible, and from orbit, where the whole white
## circle and the deck over it are one picture. The snow is measured twice on the
## ground, stood still and walking, because those were once very different things.
func _look() -> void:
	await _put(_drift)
	await _wait(240)
	# Walked, then turned round to face the way back. A trail is behind a walker
	# by definition, so a shot taken where they stopped is a shot of clean snow
	# however many prints came out of the walk.
	Input.action_press("move_forward")
	await _wait(90)
	Input.action_release("move_forward")
	await _wait(30)
	_player.rotate_object_local(Vector3.UP, PI)
	# Down enough to hold the prints, up enough to hold the falling snow. Aimed
	# at the feet the frame is all ground and the snowfall is behind the camera.
	_player._pitch = -0.28
	_player.head.rotation.x = -0.28
	await _wait(30)
	print("arctic_test: ground %d fps, %d flakes falling" % [
		Engine.get_frames_per_second(), _flakes()])
	var standing := await _flakes_seen("arctic_ground")
	print("arctic_test: flakes %.2f%% of the frame standing still" % standing)
	# A handful of flakes is not a snowfall. Two hundredths of a per cent is what
	# four of them cover, and that is what "emitting = true" bought on its own.
	if standing < 0.3:
		push_error("arctic_test: the snow covers %.2f%% of the frame, which is nothing"
			% standing)

	# And the same thing on the move, which is the measurement that matters and
	# was missing. The fall used to be sown from a slab eleven metres overhead,
	# and a flake takes four seconds to come down from there — so the air around
	# a walker was filled by whatever had been released before they set off, and
	# the snowfall was a snowfall for as long as they stood in it. It measured
	# 2.6% standing against 0.5% walking, and both shots looked plausible on
	# their own. Only the pair says which.
	Input.action_press("move_forward")
	await _wait(180)
	var walking := await _flakes_seen("arctic_walking")
	Input.action_release("move_forward")
	print("arctic_test: flakes %.2f%% of the frame at %.1f m/s" % [
		walking, _player.velocity.length()])
	if walking < standing * 0.6:
		push_error("arctic_test: walking through the snow left %.2f%% of it against %.2f%% stood still"
			% [walking, standing])

	await _wall()

	# Stood upright and looking down, rather than with the whole body aimed at
	# the planet. `_align_to_planet` rolls the body back level within a second of
	# a teleport, so a basis pointed at the ground does not survive the wait —
	# the first run of this spent four seconds turning to face open space. Pitch
	# is the head's own and nothing argues with it.
	var up := _floe.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (_planet.shape.radius + 11000.0))
	_player.velocity = Vector3.ZERO
	_player.set_camera_mode(OnlinePlayer.CameraMode.FIRST)
	_player.start_flying()
	await _wait(240)
	_player._pitch = -1.4
	_player.head.rotation.x = -1.4
	await _wait(10)
	print("arctic_test: orbit  %d fps" % Engine.get_frames_per_second())
	await _shoot("arctic_orbit")

	# And again with the deck hidden. From orbit the polar cloud is doing exactly
	# what it was asked to do, which is cover the pole, so one picture cannot say
	# whether the ground under it came out white or was never built. Two can.
	var shell := _cloud_shell()
	if shell != null:
		shell.visible = false
		await _wait(4)
		await _shoot("arctic_orbit_clear")
	# And once more without the sea. The floe clears sea level by
	# PlanetShape.ICE_TOP and nothing else in the cap is round, so concentric
	# rings over the ice can only be the water disc — which is radially
	# tessellated and centred under the viewer — drawing where it should be
	# hidden underneath.
	_planet.water.visible = false
	await _wait(4)
	await _shoot("arctic_orbit_dry")
	_planet.water.visible = true
	if shell != null:
		shell.visible = true


## The wall: the ring of cloud standing on the ground around the rim of the cap,
## seen from three kilometres outside it.
##
## Photographed with the deck and then without it, because the only thing being
## claimed here is that the arctic cannot be seen into, and one picture of cloud
## cannot say whether there was anything behind it. The share of the frame that
## changes between the two is how much of the view the wall took, and a wall you
## can see through moves a fraction of what a solid one does.
func _wall() -> void:
	var north := _planet.shape.frost_axis.normalized()
	# The rim is a circle of latitude, so the place on it to photograph is a
	# choice of longitude and the only thing that decides it is where the sun is.
	# Taken from the survey's land samples instead, it came out on the night side
	# about as often as not, and a wall of iridescent cloud photographed in the
	# dark is a picture of a dark wall.
	var sunward := north.cross(Vector3.FORWARD).normalized()
	var sun := get_tree().current_scene.find_child("Sun", true, false) as DirectionalLight3D
	if sun != null:
		var across := sun.global_basis.z - north * sun.global_basis.z.dot(north)
		if across.length_squared() > 1.0e-6:
			sunward = across.normalized()
	# Halfway through the cap's edge, which is where the band peaks and the wall
	# is thickest. A smoothstep is at a half midway between its two edges.
	var lean := (_planet.shape.frost_outer() + _planet.shape.frost_inner()) * 0.5
	var rim := (north * lean + sunward * sqrt(maxf(1.0 - lean * lean, 0.0))).normalized()
	var outward := (rim - north * rim.dot(north)).normalized()
	var angle := 3000.0 / _planet.shape.radius
	var stand := (rim * cos(angle) + outward * sin(angle)).normalized()
	# Poleward along the ground from where the camera ends up, which is what the
	# wall is across from there.
	var up := stand
	var toward := (north - up * up.dot(north)).normalized()
	var side := toward.cross(up).normalized()
	# High enough to see the whole height of it: the deck's roof is 1550 m up and
	# from down at head height the top of the wall is behind the top of the wall.
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (_planet.shape.radius
			+ _planet.shape.elevation(up) + 400.0))
	_player.velocity = Vector3.ZERO
	_player.set_camera_mode(OnlinePlayer.CameraMode.FIRST)
	_player.start_flying()
	await _wait(180)
	_player._pitch = 0.12
	_player.head.rotation.x = 0.12
	await _wait(10)
	var on := await _frame("arctic_wall")
	var shell := _cloud_shell()
	if shell == null:
		return
	shell.visible = false
	await _wait(4)
	var off := await _frame("arctic_wall_clear")
	shell.visible = true
	var moved := 0
	var total := on.get_width() * on.get_height()
	for y in on.get_height():
		for x in on.get_width():
			if absf(_grey(on.get_pixel(x, y)) - _grey(off.get_pixel(x, y))) > 0.03:
				moved += 1
	print("arctic_test: wall   %.1f%% of the view from 3 km outside the rim" % [
		moved * 100.0 / float(total)])


# --- Helpers ----------------------------------------------------------------

## Prints standing on the ground. They are a ring rather than a queue, so this
## stops climbing at Snowfield.PRINTS however far anyone walks.
func _print_count() -> int:
	var found := 0
	for child in _planet.snowfield.get_children(true):
		if child is Decal and (child as Decal).visible:
			found += 1
	return found


## The deck. Raised as an internal child, so it has to be fetched off the planet
## rather than found by path.
func _cloud_shell() -> MeshInstance3D:
	for child in _planet.get_children(true):
		var shell := child as MeshInstance3D
		if shell != null and shell.name == "Clouds":
			return shell
	return null


func _snow_node() -> GPUParticles3D:
	for child in _planet.snowfield.get_children(true):
		var snow := child as GPUParticles3D
		if snow != null:
			return snow
	return null


func _flakes() -> int:
	var snow := _snow_node()
	return snow.amount if snow != null and snow.emitting else 0


## Puts the player a couple of metres over a spot and lets them fall onto it.
##
## The landing is not optional and is the whole reason this waits: the world
## starts everyone in orbit in flight, so a teleport on its own leaves the player
## hovering, and a hover holding forward covers ground at flight speed on ice and
## snow alike — which is what the first run of this measured.
func _put(direction: Vector3) -> void:
	var up := direction.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var ground := _planet.shape.radius + _planet.shape.elevation(up)
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (ground + 2.0))
	_player.velocity = Vector3.ZERO
	_player._pitch = 0.0
	_player.head.rotation.x = 0.0
	if _player._stance != FLY:
		return
	Input.action_press("land")
	await get_tree().physics_frame
	Input.action_release("land")


func _wait(frames: int) -> void:
	for frame in frames:
		await get_tree().physics_frame


func _shoot(shot_name: String) -> void:
	await _frame(shot_name)


## Saves a shot and hands the image back, for the pair that has to be compared.
func _frame(shot_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(SHOT_DIR + shot_name + ".png")
	return image


## What the snowfall is worth, as the share of the frame that changes when the
## emitter is hidden. An emitter that says it is emitting is not a snowfall
## anybody can see — white flakes over white ground is the one case where the
## count and the picture can disagree completely — and only the flakes are hidden,
## not the whole snowfield, or the footprints would be counted as snow.
##
## Counted either way round rather than as a gain: a flake against the sky is
## darker than what it covers and a flake against a shadow is lighter, and both
## are snow.
##
## **The player's physics is stopped for the pair**, which is the whole reason this
## is one function and not two shots at the call site. Everything in the frame
## slides between two frames taken while walking, so a walk measured this way
## without the freeze comes out at 26% of the frame and the number is the ground.
func _flakes_seen(shot_name: String) -> float:
	_player.set_physics_process(false)
	var snow := _snow_node()
	var on := await _frame(shot_name)
	if snow == null:
		_player.set_physics_process(true)
		return 0.0
	snow.visible = false
	# One rendered frame, not two physics ticks: the flakes are still falling and
	# a thirtieth of a second moves them the better part of their own width.
	await get_tree().process_frame
	var off := await _frame(shot_name + "_bare")
	snow.visible = true
	_player.set_physics_process(true)
	var lit := 0
	for y in on.get_height():
		for x in on.get_width():
			if absf(_grey(on.get_pixel(x, y)) - _grey(off.get_pixel(x, y))) > 0.03:
				lit += 1
	return lit * 100.0 / float(on.get_width() * on.get_height())


func _grey(colour: Color) -> float:
	return colour.r * 0.2126 + colour.g * 0.7152 + colour.b * 0.0722
