extends Node

## The sea: how deep the sea bed is, and what the water does to a body in it.
##
##     & $godot --path . dev/_water_test.tscn
##
## Four things are measured. The **survey** walks the height field over the whole
## planet and reports how much of it is under water and how far under, which is
## the answer to "is the blue sitting at sea level pretending to be the sea".
## The **plunge** drops a player into deep ocean from a height and reports the
## splash, how far the water let them sink and where they came to rest. The
## **stroke**, the **sprint** and the **dive** are what a swimmer can do. Shots
## land in dev/captures/.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

# OnlinePlayer.Stance, which is private to the player and read here by index.
const SWIM := 5
const FLY := 3

## Directions surveyed over the sphere. Enough that a per-cent of the surface is
## eighty samples and not eight.
const SURVEY := 8000

var _player: OnlinePlayer
var _planet: Planet
var _water: PlanetWater
## Somewhere with the whole ocean depth under it, and a patch of shallows to look
## at it from. Both are picked from the same pass over the sphere.
##
## The shallows are wanted a few metres under rather than at the waterline, and
## that is the whole difference between this harness showing the sea and not: the
## flattest ground on the planet is an inland river bank, and every coastal shot
## taken from there was of a river. Caustics, shafts and the surf all need a bed
## with water over it and sky over that.
var _deep := Vector3.UP
var _shallow := Vector3.UP
var _reef := Vector3.UP
## Open sea near the shallows, for the shot that puts a lagoon and a trench side
## by side. It has to be *near* them and not the planet's deepest point, which
## turned out to be at midnight: two shots under different suns say nothing about
## the depth between them.
var _offshore := Vector3.UP
## Bed on the slope out, deep enough that neither the caustic net nor the shafts
## reach it. It is the one vantage that asks the bed to read as ground on its own
## — with no light drawn on it, nothing is left but its slopes, its rock and its
## grain, which is exactly what a diver said was missing.
var _slope := Vector3.UP

## How far from the shallows the offshore sample may be taken, in radians. Wide
## enough to be past the shelf, narrow enough to be the same coast under the same
## light.
const OFFSHORE_ARC := 0.25
## Depths the coastal vantages are looked for at, in metres. The shallows are
## inside the surf zone and well inside the depth caustics survive; the reef is
## the deepest water the net still reaches the bottom of, so a shot taken there
## has the surface, the shafts and the bed in it at once. The slope is past both.
const WADE_DEPTH := 4.0
const REEF_DEPTH := 11.0
const SLOPE_DEPTH := 45.0
## Depths a diver is held at, in metres under the surface, over water with the
## whole ocean under it. The first is inside the shelf, the second past everything
## the caustics and the shafts reach, the third is dark water.
const DIVE_DEPTHS: Array[float] = [10.0, 45.0, 150.0]


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# Without a state the world opens its home screen and spawns nobody, which is
	# what left this harness reporting a null player and doing nothing at all.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	# The world builds its players from its own _ready, so they arrive a frame or
	# two behind the instance rather than on the next one.
	for frame in 30:
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if _player != null:
			break
	_planet = get_tree().current_scene.find_child("Planet", true, false) as Planet
	_water = _planet.water if _planet != null else null
	if _player == null or _planet == null or _water == null:
		push_error("water_test: player=%s planet=%s water=%s" % [_player, _planet, _water])
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	_survey()
	await _plunge()
	await _stroke()
	await _sprint()
	await _dive()
	await _launch()
	await _look()
	await _web()
	get_tree().quit()


## The shape of the sea bed, taken from the height field itself rather than from
## whatever chunks happen to be built. The share of the ocean that is deeper than
## the shelf is the number that matters: an ocean that is mostly shelf is an
## ocean whose floor is its own surface.
func _survey() -> void:
	var shape := _planet.shape
	var wet := 0
	var total := 0.0
	var deepest := 0.0
	var over_shelf := 0
	var tallest := 0.0
	var flattest := INF
	var reefiest := INF
	for index in SURVEY:
		var direction := PlanetShape.even_direction(index, SURVEY)
		var height := shape.elevation(direction)
		if absf(height + WADE_DEPTH) < flattest:
			flattest = absf(height + WADE_DEPTH)
			_shallow = direction
		if absf(height + REEF_DEPTH) < reefiest:
			reefiest = absf(height + REEF_DEPTH)
			_reef = direction
		if height > 0.0:
			tallest = maxf(tallest, height)
			continue
		wet += 1
		total += height
		if height < deepest:
			deepest = height
			_deep = direction
		if height < -shape.shelf_depth * 2.0:
			over_shelf += 1
	print("water_test: sea            %d%% of the surface, mean %.0f m deep, deepest %.0f m" % [
		wet * 100 / SURVEY, -total / maxf(float(wet), 1.0), -deepest])
	print("water_test: past the shelf %d%% of the sea bed, against %.0f m of mountain above it" % [
		over_shelf * 100 / maxi(wet, 1), tallest])
	# A second pass, because the arc is measured against the shallows and those are
	# not known until the first one has finished.
	var offshore := 0.0
	var slopiest := INF
	var limit := cos(OFFSHORE_ARC)
	for index in SURVEY:
		var direction := PlanetShape.even_direction(index, SURVEY)
		if direction.normalized().dot(_shallow.normalized()) < limit:
			continue
		var height := shape.elevation(direction)
		if height < offshore:
			offshore = height
			_offshore = direction
		if absf(height + SLOPE_DEPTH) < slopiest:
			slopiest = absf(height + SLOPE_DEPTH)
			_slope = direction
	print("water_test: offshore       %.0f m under, %.1f km from the shallows" % [
		-offshore, _shallow.normalized().angle_to(_offshore.normalized())
			* shape.radius * 0.001])
	if wet > 0 and -total / float(wet) < shape.shelf_depth * 2.0:
		push_error("water_test: the sea bed averages %.0f m, which is still the surface"
			% (-total / float(wet)))


## Dropped into open ocean from a height. Everything a body does in water is in
## this one fall: it crosses the surface hard enough to splash, the drag stops it
## in tens of metres instead of on the sea bed, and buoyancy brings it back to
## float with its head out.
func _plunge() -> void:
	_put(_deep, 40.0)
	_land_here()
	var splashes := _splash_count()
	var deepest := 0.0
	for frame in 600:
		await get_tree().physics_frame
		deepest = maxf(deepest, _water.depth_at(_player.global_position))
	# A body coming back up overshoots the float line and rings about it for a few
	# seconds — buoyancy is a spring, and a lightly damped one. Measured before it
	# has stopped, the resting depth is whichever part of the bob was sampled.
	await _wait(240)
	print("water_test: plunge         %d splash, sank %.1f m, settled %.0f%% under as %s" % [
		_splash_count() - splashes, deepest, _fill() * 100.0, _name_of(_player._stance)])
	if _player._stance != SWIM:
		push_error("water_test: 40 m of ocean left the player %s" % _name_of(_player._stance))
	if _fill() > 0.98:
		push_error("water_test: floating with the head under, %.0f%% submerged" % (_fill() * 100.0))
	await _shoot("water_float")


## Swimming forward. Slow is the point; what is being checked is that it goes
## anywhere at all and stays at the surface while it does.
func _stroke() -> void:
	var from := _player.global_position
	Input.action_press("move_forward")
	await _wait(120)
	Input.action_release("move_forward")
	var travelled := from.distance_to(_player.global_position)
	print("water_test: stroke         %.1f m in 2.0 s (%.1f m/s), %.0f%% under, playing %s" % [
		travelled, travelled / 2.0, _fill() * 100.0, _player._clip])
	if travelled < 2.0:
		push_error("water_test: two seconds of forward moved the swimmer %.1f m" % travelled)
	if _player._clip != "Swim":
		push_error("water_test: two seconds of swimming is playing %s" % _player._clip)


## The same stroke with sprint held. Two things can go wrong here and only one of
## them is visible in a screenshot: the boost can fail to arrive, and it can fail
## to *stay*. The second is the one worth a harness — the stroke's acceleration
## has to beat a drag that grows with the speed it reaches, so a `swim_surge` set
## too low winds the target up to a hundred and leaves the body ringing around a
## third of it. Sampled to the end of the wind-up and a second past it, so the
## number reported is a speed held rather than a peak touched.
func _sprint() -> void:
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _wait(int(_player.swim_boost_time * 60.0))
	var top := 0.0
	var slowest := INF
	for frame in 60:
		await get_tree().physics_frame
		top = maxf(top, _player.velocity.length())
		slowest = minf(slowest, _player.velocity.length())
	# Taken while it is held, so the plate in it reads the speed. Released first,
	# the shot is of an ordinary swim.
	await _shoot("water_sprint")
	Input.action_release("sprint")
	await _wait(int(_player.swim_ease_time * 60.0) + 30)
	var eased := _player.velocity.length()
	Input.action_release("move_forward")
	print("water_test: sprint         %.0f m/s held (%.0f low) after %.1f s, %.1f m/s eased off" % [
		top, slowest, _player.swim_boost_time, eased])
	var asked := _player.swim_sprint_speed
	if top < asked * 0.9:
		push_error("water_test: %.0f s of held sprint reached %.0f of %.0f m/s"
			% [_player.swim_boost_time, top, asked])
	if slowest < asked * 0.8:
		push_error("water_test: the boost sagged to %.0f m/s while it was held" % slowest)
	# The stroke it eases back to, not a standstill: forward is still held.
	if eased > _player.swim_speed * 2.0:
		push_error("water_test: sprint released and the swimmer is still at %.0f m/s" % eased)
	# Back to the plunge's own water before anything else measures the sea. Half a
	# kilometre of it has gone past under the boost, and the dive that follows
	# reports metres under a bed this may well have left behind.
	_put(_deep, 2.0)
	_land_here()
	await _wait(240)


## Down and back up, which is the whole of what buoyancy has to get right: crouch
## has to beat the lift on the way down, and the lift has to win once it is let go.
func _dive() -> void:
	Input.action_press("crouch")
	await _wait(180)
	var down := _water.depth_at(_player.global_position)
	Input.action_release("crouch")
	await _wait(300)
	var back := _water.depth_at(_player.global_position)
	print("water_test: dive           %.1f m down in 3.0 s, back to %.1f m in 5.0 s" % [down, back])
	if down < 3.0:
		push_error("water_test: three seconds of down went %.1f m" % down)
	if back > down - 1.0:
		push_error("water_test: let go at %.1f m and the body stayed at %.1f m" % [down, back])
	await _shoot("water_under")


## Out of the water under power. Jump is also the up-stroke, so the first press
## has to leave the swimmer swimming or nobody can reach the surface; the second
## inside SWIM_LAUNCH_WINDOW is what launches. Both halves are checked, because
## the failure that matters is the one where a single press takes off and the
## sea becomes somewhere you cannot swim upward in.
func _launch() -> void:
	await _tap("jump")
	await _wait(6)
	var after_one := _player._stance
	await _tap("jump")
	await _wait(4)
	print("water_test: launch         one press left %s, two left %s" % [
		_name_of(after_one), _name_of(_player._stance)])
	if after_one != SWIM:
		push_error("water_test: one press of jump took off out of the water")
	if _player._stance != FLY:
		push_error("water_test: two presses left the swimmer %s" % _name_of(_player._stance))


## Two views the numbers cannot check: a coast, where the water has to meet ground
## it does not share a mesh with, and the limb from orbit, where the disc has to
## reach all the way to the edge of what can be seen. Both are where a
## follow-the-viewer surface would show its seams if it had any.
func _look() -> void:
	_put(_shallow, 130.0)
	_player._pitch = -0.35
	_player.head.rotation.x = -0.35
	# Long enough for the quadtree to build the ground under a viewer that arrived
	# by teleport; the sea needs no such thing, which is half its point.
	await _wait(360)
	# The sea is one draw of nine thousand triangles, but it is a transparent one
	# that can fill the screen, and the ripples are a noise field per pixel of it.
	# Over a coast is the worst of both: water to the horizon and terrain under it.
	print("water_test: over a coast   %d fps, %d triangles of ground in %d chunks" % [
		Engine.get_frames_per_second(), int(_planet.statistics().get("triangles", 0)),
		int(_planet.statistics().get("visible", 0))])
	await _shoot("water_coast")

	# The surf, as a pair. It is the one part of the sea with no number behind it
	# — a depth read back out of the buffer — and a single picture of a coast
	# cannot say which of the pale band along it is foam and which is the shallow
	# water that was always there. The same frame with surf_strength at zero can.
	_put(_shallow, 26.0)
	_player._pitch = -0.42
	_player.head.rotation.x = -0.42
	await _wait(180)
	print("water_test: at the shore   %d fps" % Engine.get_frames_per_second())
	var on := await _frame("water_surf")

	var sea := PlanetWater.SURFACE_MATERIAL
	var was: Variant = sea.get_shader_parameter(&"surf_strength")
	sea.set_shader_parameter(&"surf_strength", 0.0)
	await _wait(2)
	var off := await _frame("water_surf_off")
	sea.set_shader_parameter(&"surf_strength", was)
	_compare(on, off)

	var up := _deep.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	_player.global_transform = Transform3D(Basis.looking_at(-up, side),
		_planet.global_position + up * (_planet.shape.radius + 9000.0))
	_player.velocity = Vector3.ZERO
	_player._pitch = 0.0
	_player.head.rotation.x = 0.0
	_player.start_flying()
	await _wait(240)
	await _shoot("water_orbit")


## The webbed light, from the three places it is drawn: the net on the bed, the
## shafts hanging in the water over it, and the swell that bends the surface into
## throwing either. Each vantage is a pair — the frame, and the same frame with
## that one effect turned off — because a picture of bright water cannot say on
## its own which part of it is new.
##
## The player's own physics is switched off for the lot. Buoyancy will not let a
## body sit two metres under in four metres of water, and every one of these
## wants the eye held exactly where it was put.
func _web() -> void:
	var sea := PlanetWater.SURFACE_MATERIAL
	var bed := Planet.SURFACE_MATERIAL
	_player.set_physics_process(false)

	await _hold(_shallow, 9.0, -0.75, false)
	print("water_test: over shallows  %d fps" % Engine.get_frames_per_second())
	await _pair("water_caustics", bed, &"caustic_strength", "the net on the bed")

	# The same vantage, the same coast and the same sun, over water that is deep.
	# The pair of them is the check that the column in front of the bed is being
	# measured at all: a lagoon and a trench looked alike from the air while the
	# tint was read off the vertex alpha, and the point of measuring it is that
	# they no longer do.
	await _hold(_offshore, 9.0, -0.75, false)
	print("water_test: over the deep  bed %.0f m down against %.0f m in the shallows, %d fps" % [
		-_planet.shape.elevation(_offshore), -_planet.shape.elevation(_shallow),
		Engine.get_frames_per_second()])
	await _pair_clear("water_column", "the water over the bed")

	# Under, standing on the reef and looking along the water at the sun. Shafts
	# are drawn only from inside the sea and lean over only when the sun is off
	# to one side, so this is the one vantage with any of them in it.
	await _hold(_reef, -REEF_DEPTH + 0.5, 0.12, true)
	var eye := _water.depth_at(_player.head.global_position)
	print("water_test: under          %.1f m down, %d fps" % [
		eye, Engine.get_frames_per_second()])
	if eye <= 0.0:
		push_error("water_test: the underwater shot has its eye %.1f m in the air" % -eye)
	await _pair("water_shafts", bed, &"shaft_strength", "shafts in the water")

	await _hold(_shallow, 1.4, -0.06, false)
	print("water_test: at eye level   %d fps" % Engine.get_frames_per_second())
	await _pair("water_swell", sea, &"swell_height", "the swell")

	await _dive_shots()
	_player.set_physics_process(true)


## A dive, as three depths of the same water and then the bed at two of them.
##
## Nothing about the deep can be checked from one frame. What makes water read as
## deep is that it is darker than the shallows and lighter overhead than
## underfoot, and both of those are comparisons — a single picture of a blue
## screen cannot say which blue it should have been. So the sweep is the shot and
## the ladder of them is the measurement.
##
## Two numbers per frame. **Light** is its mean brightness, which has to fall as
## the dive goes down and has to be higher looking up than looking down at every
## step, or the sea has no bottom and a swimmer has no up. **Relief** is the mean
## step between neighbouring pixels: how much shape is in the picture at all. It
## is the number the bed shots are for — a sea floor drawn as a flat panel of
## colour scores near nothing however blue and however lit it is.
##
## The HUD comes off for these. It is a tenth of the frame in hard-edged white on
## black, which is most of the relief in any shot that has it and none of the sea.
func _dive_shots() -> void:
	_player.hud.visible = false
	for depth: float in DIVE_DEPTHS:
		await _sink(_offshore, depth, -0.30)
		var down := await _frame("water_deep_%d_down" % int(depth))
		await _sink(_offshore, depth, 0.60)
		var up := await _frame("water_deep_%d_up" % int(depth))
		var below := _read(down)
		var above := _read(up)
		print("water_test: %3d m under    down light %.3f relief %4.1f   up light %.3f relief %4.1f" % [
			int(depth), below.x, below.y, above.x, above.y])
		if above.x <= below.x:
			push_error("water_test: at %d m under, up is no brighter than down" % int(depth))

	# The bed itself, from close enough to it that the water is not the subject.
	# The reef has the net and the shafts on it; the slope has neither, and is the
	# one that says whether the ground under the sea is ground.
	for site: Array in [[_reef, REEF_DEPTH, "reef"], [_slope, SLOPE_DEPTH, "slope"]]:
		var bed := float(site[1])
		await _sink(site[0] as Vector3, bed - 2.5, -0.35)
		var shot := await _frame("water_bed_%s" % site[2])
		var seen := _read(shot)
		print("water_test: bed at %3d m   light %.3f relief %4.1f" % [
			int(bed), seen.x, seen.y])
		if seen.y < 2.0:
			push_error("water_test: the bed %d m down has no shape in it at all" % int(bed))
	# What the bed's shape is actually made of, split into the two things that make
	# it. Worth having as a pair rather than as one relief number, because the pair
	# is what found the fault the number only reported: the bed's whole appearance
	# was coming from the metre-scale bump, so nothing about it answered to depth,
	# to colour or to the light, and a lattice in that one field was the sea floor.
	await _sink(_reef, REEF_DEPTH - 2.5, -0.35)
	await _pair("water_bed_bump", Planet.SURFACE_MATERIAL, &"bump_strength", "the bed's bumps")
	await _pair("water_bed_grain", Planet.SURFACE_MATERIAL, &"detail_amount", "the bed's grain")
	_player.hud.visible = true


## Puts the *eye* a given depth under the surface, which is not where [method
## _hold] puts anything: that takes an altitude for the feet, and the head stands
## a stance's worth above them.
func _sink(direction: Vector3, depth: float, pitch: float) -> void:
	await _hold(direction, -depth - _player.head.position.y, pitch, true)
	var eye := _water.depth_at(_player.head.global_position)
	if absf(eye - depth) > 1.0:
		push_error("water_test: asked for %.0f m under and got %.1f m" % [depth, eye])


## Places the eye by hand: [param altitude] is metres above sea level, [param
## pitch] is radians below the horizon, and [param sunward] turns the body to
## face the sun rather than out to sea.
##
## [param altitude] places the body's origin, which is its feet — the eye is a
## standing height above that, and the underwater shot is the one that has to
## remember it. The first run of it asked for 1.6 m under and photographed the
## sea from a metre in the air.
func _hold(direction: Vector3, altitude: float, pitch: float, sunward: bool) -> void:
	var up := direction.normalized()
	var facing := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	if sunward:
		var sun := get_tree().current_scene.find_child("Sun", true, false) as DirectionalLight3D
		if sun != null:
			var toward := sun.global_basis.z
			var flat := toward - up * up.dot(toward)
			if flat.length_squared() > 0.01:
				facing = flat.normalized()
	var side := facing.cross(up).normalized()
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (_planet.shape.radius + altitude))
	_player.velocity = Vector3.ZERO
	_player.set_camera_mode(OnlinePlayer.CameraMode.FIRST)
	_player._pitch = pitch
	_player.head.rotation.x = pitch
	# Long enough for the quadtree to build the bed under a viewer that arrived
	# by teleport, which is the thing every one of these shots is of.
	await _wait(200)


## A shot and its control, and what one parameter was worth between them.
##
## [param muted] is the value that turns the effect off, which is zero for a
## strength and very large for a **visibility**: a distance the light survives is
## muted by making it further than anything can be, and setting it to zero would
## divide by it and leave the effect at full instead.
func _pair(shot_name: String, material: ShaderMaterial, parameter: StringName,
		what: String, muted := 0.0) -> void:
	var on := await _frame(shot_name)
	var was: Variant = material.get_shader_parameter(parameter)
	material.set_shader_parameter(parameter, muted)
	await _wait(2)
	var off := await _frame(shot_name + "_off")
	material.set_shader_parameter(parameter, was)
	_measure(on, off, what)


## The same, for the one thing here that is not on a material: how clear the water
## is, which four shaders read as a global because they have to agree on it. Muted
## by putting the far side of it further than anything can be.
func _pair_clear(shot_name: String, what: String) -> void:
	var on := await _frame(shot_name)
	RenderingServer.global_shader_parameter_set(&"murk_visibility", 1.0e9)
	await _wait(2)
	var off := await _frame(shot_name + "_off")
	_water.publish_clarity()
	_measure(on, off, what)


# --- Helpers ----------------------------------------------------------------

## How much of the body is under, the way the player works it out.
func _fill() -> float:
	return clampf(_water.depth_at(_player.global_position) / 1.45, 0.0, 1.0)


## Splashes standing in the scene. They free themselves when they finish, so this
## is only meaningful read either side of a crossing.
func _splash_count() -> int:
	var found := 0
	for child in _water.get_children(true):
		if child is GPUParticles3D:
			found += 1
	return found


func _put(direction: Vector3, altitude: float) -> void:
	var up := direction.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	_player.global_transform = Transform3D(Basis(side, up, side.cross(up)),
		_planet.global_position + up * (_planet.shape.radius + altitude))
	_player.velocity = Vector3.ZERO
	# Written in rather than pitched into place with mouse events. Swimming steers
	# off the camera, so a view left looking at its own feet by whatever ran before
	# turns a stroke forward into a dive and the numbers stop meaning anything.
	_player._pitch = 0.0
	_player.head.rotation.x = 0.0
	_player.start_flying()


## Ends the hover the placement left the player in, so the drop is a drop.
func _land_here() -> void:
	Input.action_press("land")
	await get_tree().physics_frame
	Input.action_release("land")


## One physics frame of a press. The take-off reads the edge rather than the
## hold, so a press left down would arm the window and never close it.
func _tap(action: String) -> void:
	Input.action_press(action)
	await get_tree().physics_frame
	Input.action_release(action)


## Physics frames, not rendered ones. Everything here is quoted per second, and
## the render loop runs at whatever the machine manages — on this one, twice the
## physics rate, which halves every speed reported against it.
func _wait(frames: int) -> void:
	for frame in frames:
		await get_tree().physics_frame


func _name_of(stance: int) -> String:
	return ["stand", "crouch", "slide", "fly", "crash", "swim"][stance]


func _shoot(shot_name: String) -> void:
	await _frame(shot_name)


## Saves a shot and hands the image back, for the pair that has to be compared.
func _frame(shot_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(SHOT_DIR + shot_name + ".png")
	return image


func _compare(on: Image, off: Image) -> void:
	_measure(on, off, "the surf")


## What one effect is actually worth, as the difference between two shots taken
## with it on and off. Anything else moving between them drifts far slower than
## the threshold — the two frames are a thirtieth of a second apart and the
## clouds cross the sky at half a centimetre a second — so everything counted
## here belongs to whatever was switched.
##
## Brightening only. Every one of these adds light, and a wave that moved a
## reflection somewhere darker is not evidence against it.
func _measure(on: Image, off: Image, what: String) -> void:
	var lit := 0
	var total := on.get_width() * on.get_height()
	var brightest := 0.0
	var sum := 0.0
	for y in on.get_height():
		for x in on.get_width():
			var gain := _grey(on.get_pixel(x, y)) - _grey(off.get_pixel(x, y))
			if gain < 0.05:
				continue
			lit += 1
			sum += gain
			brightest = maxf(brightest, gain)
	print("water_test: %-14s %.1f%% of the frame, mean +%.2f, peak +%.2f" % [
		what, lit * 100.0 / float(total), sum / maxf(float(lit), 1.0), brightest])
	if lit == 0:
		push_error("water_test: %s draws nothing at all" % what)


## A frame as the two numbers a view under water lives or dies by: its mean
## brightness in x, and in y the mean step between neighbouring pixels — the shape
## in it — scaled to levels out of 255 so the figure is readable.
##
## Every other pixel, which is plenty for both and a quarter of the work.
func _read(image: Image) -> Vector2:
	var light := 0.0
	var relief := 0.0
	var taken := 0
	for y in range(0, image.get_height() - 2, 2):
		for x in range(0, image.get_width() - 2, 2):
			var here := _grey(image.get_pixel(x, y))
			light += here
			relief += absf(_grey(image.get_pixel(x + 2, y)) - here) \
				+ absf(_grey(image.get_pixel(x, y + 2)) - here)
			taken += 1
	var count := maxf(float(taken), 1.0)
	return Vector2(light / count, relief / count * 255.0)


func _grey(colour: Color) -> float:
	return colour.r * 0.2126 + colour.g * 0.7152 + colour.b * 0.0722
