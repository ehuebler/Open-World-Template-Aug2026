extends Node

## Flies a camera over a generated planet, surveys the terrain, and photographs it.
##
## Run it from the project root:
##
##     & $godot --path . dev/_planet_test.tscn
##
## WASD to fly, mouse to look, Space and Ctrl for up and down, Shift to go faster,
## Escape to release the mouse. Flight speed scales with altitude, so the same
## stick crosses the planet and lands on a beach.
##
## Flags:
##     -- --tour        take the screenshot tour and quit
##     -- --at=LAT,LON  photograph one place, quoted the way the in-game
##                      readout writes it: --at="34.21 S,118.55 W"
##     -- --seed=N      regenerate with a different seed
##     -- --radius=N    planet radius in metres, default 8000
##     -- --sea=F       share of the surface under water, 0..1
##     -- --set=N:V     any other exported number on the shape, comma separated:
##                      --set=aridity:0,terrace_height:40
##     -- --mat=N:V     the same for a uniform on the terrain material:
##                      --mat=water_specular:0
##     -- --split=F     chunk widths of viewer distance before a chunk subdivides
##     -- --regions     walk the colour wheel at ground level, measuring the sky
##     -- --night       pin the sun over the pole and photograph both sides of it
##     -- --air         the same frames with atmospheric scattering on and off
##     -- --noclouds    leave the cloud deck off
##     -- --nosea       leave the sea off, baring the sea bed
##     -- --noair       leave the atmosphere shell off
##     -- --skirt=F     skirt depth as a share of chunk width, 0 disables
##     -- --noshadow    drop the sun's shadows
##     -- --draw=MODE   wireframe, unshaded, normals or overdraw
##
## On startup it prints a survey of what the height field actually produced —
## water share, elevation range, how much of the land is flat, how far you can
## see — because those are the numbers that say whether the terrain matches the
## brief, and eyeballing a screenshot does not.
##
## The debug draw modes earn their place: the pencil shader darkens grazing
## surfaces so heavily that a hole in the ground, a bad normal and a hard band
## edge all look like the same dark polygon. --draw=unshaded is what separates
## them, and it is the fastest way to tell a terrain bug from a shading one.
##
## Shots land in dev/captures/. The tour swings the sun to face whatever it is
## photographing, which the game will not do; it is there so that no frame of the
## tour comes back as an unlit silhouette. --night is the answer to what that
## convenience hides: it pins the sun over the north pole and then walks from
## there to the south, so noon, dusk and midnight are all photographed under one
## unmoved light and the sky has to agree with the ground about which is which.
##
## Frame rate here is only indicative: an unfocused window is throttled by the
## engine, so the same shot can read 30 or 100 between runs. The LOD update cost
## and the chunk, triangle and draw counts beside it are stable.

const SPACE_SHADER := preload("res://shaders/vivid/vivid_space.gdshader")
const SHOT_DIR := "res://dev/captures/"
const SURVEY_SAMPLES := 20000
## Ground within this many degrees of level counts as flat.
const FLAT_DEGREES := 6.0
## Ring used to tell a river from a lake: a river is water with land close by on
## most sides, a lake is water with water on most sides.
const NEIGHBOUR_METRES := 90.0
## Stops around the colour wheel for --regions. Six is enough to see two full
## turns of a three-turn wheel and short enough to sit through.
const REGION_SAMPLES := 6

var _shape: PlanetShape
var _planet: Planet
var _camera: Camera3D
var _sun: DirectionalLight3D
var _readout: Label
var _hud: CanvasLayer
var _features: Dictionary = {}
var _options: Dictionary = {}
var _yaw := 0.0
var _pitch := 0.0
var _touring := false
## Where the sun is, as opposed to where its light goes. --night measures every
## frame against this.
var _to_sun := Vector3.UP


func _ready() -> void:
	_options = _arguments()
	_touring = _options.has("tour") or _options.has("regions") or _options.has("night") \
		or _options.has("at") or _options.has("air")

	_shape = PlanetShape.new()
	if _options.has("seed"):
		_shape.noise_seed = int(_options["seed"])
	if _options.has("radius"):
		_shape.radius = float(_options["radius"])
	if _options.has("sea"):
		_shape.sea_fraction = clampf(float(_options["sea"]), 0.0, 0.95)
	# Any other exported number on the shape, by name: --set=aridity:0. The
	# terrain has thirty of these and the interesting question is nearly always
	# "which of them is doing this", which wants one flag rather than thirty.
	if _options.has("set"):
		for pair in String(_options["set"]).split(",", false):
			var halves := pair.split(":", true, 1)
			if halves.size() == 2:
				_shape.set(StringName(halves[0].strip_edges()), halves[1].to_float())
				print("planet_test: set %s = %s" % [halves[0], halves[1]])
	# The same for a uniform on the terrain material, which is the other half of
	# where a terrain artefact can live. The shape is edited before `prepare`;
	# this can be edited whenever, since a uniform costs nothing to change.
	if _options.has("mat"):
		for pair in String(_options["mat"]).split(",", false):
			var halves := pair.split(":", true, 1)
			if halves.size() == 2:
				Planet.SURFACE_MATERIAL.set_shader_parameter(
					StringName(halves[0].strip_edges()), halves[1].to_float())
				print("planet_test: mat %s = %s" % [halves[0], halves[1]])

	var started := Time.get_ticks_msec()
	_shape.prepare()
	print("planet_test: height field ready in %d ms" % (Time.get_ticks_msec() - started))

	_build_scene()
	_survey()

	if _touring:
		if _options.has("regions"):
			await _region_shots()
		elif _options.has("air"):
			await _air()
		elif _options.has("night"):
			await _night()
		elif _options.has("at"):
			await _at(String(_options["at"]))
		else:
			await _tour()
		get_tree().quit()
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_place(_features.get("plain", Vector3.UP), 60.0, 2500.0)


func _build_scene() -> void:
	var world_environment := WorldEnvironment.new()
	world_environment.environment = _make_environment()
	add_child(world_environment)

	_sun = DirectionalLight3D.new()
	# Lower than it looks like it should be, because the sky is now the ambient
	# source as well: sun plus sky bounce is most of a stop brighter than the
	# single directional light the pencil look was tuned against.
	_sun.light_energy = 1.05
	_sun.light_color = Color(1.0, 0.96, 0.9)
	_sun.shadow_enabled = not _options.has("noshadow")
	# Every chunk inside this radius is drawn again into the shadow map, and near
	# the ground there are hundreds of them. 500 m cost about a third of the frame
	# rate over 250 m and put shadows where nothing can read them anyway.
	_sun.directional_shadow_max_distance = 250.0
	add_child(_sun)
	_face_sun(Vector3.UP)

	_planet = Planet.new()
	_planet.name = "Planet"
	_planet.shape = _shape
	# Which side of the planet the atmosphere shell lights. The sky reads the
	# same light directly and does not go through the planet.
	_planet.sun = _sun
	if _options.has("skirt"):
		_planet.skirt_scale = float(_options["skirt"])
	if _options.has("split"):
		_planet.split_ratio = float(_options["split"])
	# A cloud deck is the one thing between a night sky and the ground, and a
	# faint one is hard to tell from a sky that never got dark. Being able to
	# take the deck away is how you tell which of the two you are looking at.
	_planet.has_clouds = not _options.has("noclouds")
	# The same switch for the sea. Every artefact along a shoreline has two
	# candidates — the water drawn over the bed, and the bed itself — and they
	# look alike in a photograph, so the only way to name one is to take the
	# other away.
	#
	# The surface is hidden rather than the node left unbuilt, because PlanetWater
	# also publishes the murk globals that the *terrain* reads. Skipping it takes
	# the sea bed's own shading away along with the sea, which makes the one
	# comparison this flag exists for prove nothing.
	add_child(_planet)
	if _options.has("nosea") and _planet.water != null:
		var surface := _planet.water.get_node_or_null("Surface") as MeshInstance3D
		if surface != null:
			surface.visible = false
	# And the third shell. Seen from inside, an additive sphere of a few dozen
	# segments is a handful of very large flat facets across the whole view, so
	# it is a candidate for any broad artefact that survives taking the ground
	# away — and it is the only one of the three that could not be switched off.
	if _options.has("noair"):
		var air := _planet.find_child("Atmosphere", false, false) as MeshInstance3D
		if air != null:
			air.visible = false

	_camera = Camera3D.new()
	_camera.fov = 62.0
	_camera.near = 0.5
	# Far enough to hold the whole planet in frame from three radii out.
	_camera.far = _shape.radius * 8.0
	add_child(_camera)
	_camera.current = true
	_planet.viewer = _camera

	# Separating a terrain bug from a shading bug is otherwise guesswork: the
	# surface shader bends normals and darkens grazing angles hard enough that a
	# bad normal and a hole in the ground look alike.
	match String(_options.get("draw", "")):
		"wireframe":
			RenderingServer.set_debug_generate_wireframes(true)
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		"unshaded":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_UNSHADED
		"normals":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_NORMAL_BUFFER
		"overdraw":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_OVERDRAW

	var plate := PanelContainer.new()
	# BLEED of the margin is spent on the gap between panel edge and drawn plate,
	# so 20/14 reads as 14/8.
	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", 20)
	padding.add_theme_constant_override("margin_right", 20)
	padding.add_theme_constant_override("margin_top", 14)
	padding.add_theme_constant_override("margin_bottom", 14)
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 14)
	padding.add_child(_readout)
	plate.add_child(padding)
	var anchor := MarginContainer.new()
	anchor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	anchor.add_theme_constant_override("margin_left", 24)
	anchor.add_theme_constant_override("margin_top", 24)
	anchor.add_child(plate)
	_hud = CanvasLayer.new()
	_hud.add_child(anchor)
	add_child(_hud)
	AuroraSurface.add_to(plate, AuroraSurface.Style.HUD)


## Sky, ambient and tonemapping. There is one background for the whole flight:
## vivid_space.gdshader reads the camera's own altitude and hands back either a
## daytime sky or open space, so nothing here has to switch at a boundary.
##
## The sky is also the ambient light source, which is what puts blue bounce on
## the shadow side of a hill at noon and takes it away in orbit. That is why the
## sky shader is written to keep TIME out of it: reading TIME would force the
## radiance cubemap to be rebuilt every frame.
func _make_environment() -> Environment:
	var sky_material := ShaderMaterial.new()
	sky_material.shader = SPACE_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_material
	# One cubemap face per frame. The sky changes only when the camera moves far
	# enough to matter, and a full rebuild while flying is a visible hitch.
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.38
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	# Above 1.0 so the sun's disc and the water's highlight have somewhere to go
	# instead of clipping to white the moment they are brighter than the sky. The
	# mobile renderer's colour buffer tops out near 2.0, so there is no point
	# asking for more headroom than that.
	environment.tonemap_white = 2.0
	environment.glow_enabled = true
	# Only the sun and the brightest water highlight are meant to bloom. On the
	# mobile renderer the threshold has to sit under 1.0 for anything to reach
	# it at all, which makes it easy to bloom the whole sky by accident.
	environment.glow_hdr_threshold = 0.95
	environment.glow_intensity = 0.7
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.0
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	return environment


# --- Survey -----------------------------------------------------------------

## Samples the height field evenly over the sphere and reports what came out,
## while noting one direction of each kind for the tour to visit.
func _survey() -> void:
	var started := Time.get_ticks_msec()
	var ocean := 0
	var lake := 0
	var river := 0
	var land := 0
	var flat := 0
	var valley := 0
	var lowest := INF
	var highest := -INF
	var peak := Vector3.UP
	var flat_level := cos(deg_to_rad(FLAT_DEGREES))
	# Desert country is the one thing the tour could not previously be aimed at,
	# and terracing and strata are only judgeable there. Tracked as the *highest*
	# arid ground rather than the first found, because a bench is only visible
	# where there is enough altitude to have stacked a few of them.
	var arid_land := 0
	var mesa_top := -INF

	for index in SURVEY_SAMPLES:
		var direction := PlanetShape.even_direction(index, SURVEY_SAMPLES)
		var reading := _shape.sample(direction)
		var height := float(reading["elevation"])
		lowest = minf(lowest, height)
		if height > highest:
			highest = height
			peak = direction
		if float(reading["river"]) > 1.0:
			valley += 1
		if height > 0.0:
			land += 1
			var arid := float(reading.get("arid", 0.0))
			if arid > 0.5:
				arid_land += 1
				if height > mesa_top:
					mesa_top = height
					_features["mesa"] = direction
			if _shape.normal_at(direction, 6.0).dot(direction) >= flat_level:
				flat += 1
				if not _features.has("plain") and height > 8.0:
					_features["plain"] = direction
			continue
		# Water. Which kind it is depends on what took the ground under, which is
		# why the survey reads the breakdown instead of guessing from the shape.
		if float(reading["continent"]) <= 0.0:
			ocean += 1
			if not _features.has("coast") and float(reading["continent"]) > -0.02:
				_features["coast"] = direction
		elif float(reading["river"]) >= float(reading["lake"]):
			river += 1
			if not _features.has("river"):
				_features["river"] = direction
		else:
			lake += 1
			if not _features.has("lake") and _water_width(direction) >= 6:
				_features["lake"] = direction

	_features["peak"] = peak
	var total := float(SURVEY_SAMPLES)
	var water := ocean + lake + river
	print("planet_test: radius %.0f m   circumference %.1f km   surface %.0f km2" % [
		_shape.radius, 2.0 * PI * _shape.radius / 1000.0,
		4.0 * PI * _shape.radius * _shape.radius / 1.0e6])
	print("planet_test: water %.1f%%  (ocean %.1f%%, lakes %.2f%%, rivers %.2f%%)" % [
		100.0 * float(water) / total, 100.0 * float(ocean) / total,
		100.0 * float(lake) / total, 100.0 * float(river) / total])
	print("planet_test: elevation %.0f m .. %.0f m   relief %.0f m  (%.1f%% of radius)" % [
		lowest, highest, highest - lowest,
		100.0 * (highest - lowest) / _shape.radius])
	print("planet_test: land %.1f%% flat (under %.0f degrees), %.1f%% river valley" % [
		100.0 * float(flat) / maxf(float(land), 1.0), FLAT_DEGREES,
		100.0 * float(valley) / maxf(float(land), 1.0)])
	print("planet_test: land %.1f%% arid, highest desert ground %.0f m" % [
		100.0 * float(arid_land) / maxf(float(land), 1.0), maxf(mesa_top, 0.0)])
	# The one number that decides how the world feels on foot. It is a property of
	# the radius, not of the terrain: a smaller planet cannot be given a longer
	# view by any amount of tuning.
	print("planet_test: horizon %.0f m at eye height, %.0f m from a 40 m hill" % [
		horizon_at(1.7), horizon_at(40.0)])
	print("planet_test: found %s" % [_features.keys()])
	print("planet_test: survey of %d points in %d ms" % [
		SURVEY_SAMPLES, Time.get_ticks_msec() - started])


## How many of eight neighbours a short walk away are also under water, so the
## tour parks at a lake worth photographing rather than at a puddle.
func _water_width(direction: Vector3) -> int:
	var up := direction.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var other := up.cross(side)
	var step := NEIGHBOUR_METRES / _shape.radius
	var wet := 0
	for turn in 8:
		var angle := TAU * float(turn) / 8.0
		var offset := side * cos(angle) + other * sin(angle)
		if _shape.elevation((up + offset * step).normalized()) <= 0.0:
			wet += 1
	return wet


# --- One reported place -----------------------------------------------------

## Photographs the spot a player read off [CoordinatePlate], from four heights.
##
## This is the other half of that readout and the reason it quotes latitude and
## longitude rather than a position: a place on this planet has to survive being
## spoken aloud, written down and typed back in, and three large world
## coordinates measured from a point eight kilometres underground do not. The
## letters are taken as written — `34.21 S` — so the string on the screen can be
## copied across without being converted to a sign first, which is exactly the
## step that would get it wrong.
func _at(quoted: String) -> void:
	var parts := quoted.split(",", false)
	if parts.size() != 2:
		push_error("--at wants LAT,LON, for example --at=\"34.21 S,118.55 W\"")
		return
	var latitude := _signed(parts[0], "S")
	var longitude := _signed(parts[1], "W")
	# The inverse of the readout: latitude off the planet's local Y, longitude
	# from local +Z counting east toward +X.
	var lat := deg_to_rad(latitude)
	var lon := deg_to_rad(longitude)
	var direction := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)).normalized()
	var reading := _shape.sample(direction)
	print("planet_test: at %.2f, %.2f  dir %.4f, %.4f, %.4f  ground %.0f m" % [
		latitude, longitude, direction.x, direction.y, direction.z,
		float(reading["elevation"])])
	_transect(direction)
	await _shot_from("planet_at_air", direction, 2000.0, 3000.0)
	await _shot_from("planet_at_low", direction, 300.0, 900.0)
	await _shot_from("planet_at_near", direction, 60.0, 300.0)
	await _shot_from("planet_at_ground", direction, 2.0, 120.0)


## How much of the ground around a place is level, as a share of its area.
##
## A photograph cannot tell a bench from a gentle slope seen at a grazing angle,
## and at the range these faults show up everything is at a grazing angle. So
## this reads the field the chunks are built from, at the spacing they are built
## at, and measures the local gradient over a square: **flat area is the fault,
## stated as a number.** Natural relief at this spacing is level almost nowhere;
## a quantised one is level over whole benches, and a bench is as wide as the
## slope under it is gentle — which on a coastal plain is very wide indeed.
##
## A line across the site was the first version of this and it under-reported
## badly: one line through one point misses every bench it happens not to cross,
## and it read 6 m of flat ground in a view full of slabs.
func _transect(direction: Vector3) -> void:
	var spacing := _planet.finest_spacing()
	var across := direction.cross(Vector3.UP).normalized()
	var along := direction.cross(across).normalized()
	var side := 240
	# The field is read at the spacing the chunks read it at, but stepped much
	# wider than that: what is being looked for is a bench tens of metres across,
	# and a square only as wide as the view is not a square that contains one.
	var step := 10.0
	var heights := PackedFloat32Array()
	heights.resize(side * side)
	for v in side:
		for u in side:
			var spot := (direction * _shape.radius
				+ across * ((u - side * 0.5) * step)
				+ along * ((v - side * 0.5) * step)).normalized()
			heights[v * side + u] = _shape.elevation(spot, spacing)
	# Level enough that a bench would be caught and a natural slope would not.
	# Half a per cent is under a third of a degree; the gentlest real ground in
	# this field is the abyssal plain and it is steeper than that.
	var level_grade := 0.005 * step
	var level := 0
	var counted := 0
	for v in range(1, side - 1):
		for u in range(1, side - 1):
			var here := heights[v * side + u]
			var grade := maxf(
				absf(heights[v * side + u + 1] - here),
				absf(heights[(v + 1) * side + u] - here))
			counted += 1
			if grade < level_grade:
				level += 1
	print("planet_test: transect  %.0f m square stepped %.0f m, %.1f%% of it level" % [
		side * step, step, 100.0 * float(level) / maxf(counted, 1)])


## Degrees with a hemisphere letter after them, which is how the readout writes
## one. A bare number is taken as already signed.
func _signed(text: String, negative: String) -> float:
	var trimmed := text.strip_edges().to_upper()
	var flip := trimmed.ends_with(negative)
	var digits := trimmed.trim_suffix("N").trim_suffix("S").trim_suffix("E") \
		.trim_suffix("W").strip_edges()
	return -absf(digits.to_float()) if flip else digits.to_float()


# --- Tour -------------------------------------------------------------------

func _tour() -> void:
	# The three that are about the look rather than the terrain: the colour wheel
	# from far enough out to see more than one region of it, the atmosphere shell
	# against the stars, and the altitude where the sky is halfway to space.
	await _shot_from("planet_space", Vector3.UP, _shape.radius * 4.0, 0.0)
	await _shot_from("planet_orbit", _features.get("coast", Vector3.UP), _shape.radius * 0.9, 0.0)
	await _shot_from("planet_edge_of_air", _features.get("plain", Vector3.UP), 2200.0, 40000.0)
	await _shot_from("planet_whole", Vector3.UP, _shape.radius * 2.2, 0.0)
	await _shot_from("planet_limb", _features.get("peak", Vector3.UP), _shape.radius * 0.35, 0.0)
	await _shot_from("planet_coast", _features.get("coast", Vector3.UP), 900.0, 6000.0)
	await _shot_from("planet_mountains", _features.get("peak", Vector3.UP), 500.0, 4000.0)
	# The same peak from under it, for the same reason the desert gets two ranges.
	# How pointed a summit is only reads against something to be pointed next to:
	# from 500 m a range is a silhouette and every profile between a spire and a
	# dome draws the same grey wedge, so the number that decides which of those it
	# is cannot be judged from the shot above.
	await _shot_from("planet_peak_low", _features.get("peak", Vector3.UP), 70.0, 900.0)
	# Two ranges over the same desert, because terracing and strata fail at
	# different ones: benches read from the air and the courses in a riser only
	# resolve from close to.
	await _shot_from("planet_mesa", _features.get("mesa", Vector3.UP), 420.0, 3000.0)
	await _shot_from("planet_mesa_low", _features.get("mesa", Vector3.UP), 90.0, 900.0)
	await _shot_from("planet_lake", _features.get("lake", Vector3.UP), 120.0, 1400.0)
	await _shot_from("planet_river", _features.get("river", Vector3.UP), 130.0, 1200.0)
	await _shot_from("planet_ground", _features.get("plain", Vector3.UP), 1.7, 4000.0)


## The colour wheel, walked. Six points evenly spaced around the great circle at
## right angles to region_axis, which is where the hue changes fastest, each shot
## from standing height looking at the horizon.
##
## The sky over each is measured as well as photographed: the numbers are the mean
## colour of the top eighth of the frame, which is sky and nothing else at this
## pitch. Neighbouring rows should differ and the row after the last should be on
## its way back to the first, because the wheel wraps. Two rows the same mean the
## sky has stopped following the ground under it.
func _region_shots() -> void:
	# Read from the project settings, not from RenderingServer: reading a global
	# shader parameter back is an editor-only call and errors out in a game build.
	var declared: Dictionary = ProjectSettings.get_setting("shader_globals/region_axis", {})
	var axis: Vector3 = declared.get("value", Vector3(0.0, 1.0, 0.0))
	axis = axis.normalized()
	var side := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var front := axis.cross(side)
	for step in REGION_SAMPLES:
		var angle := TAU * float(step) / float(REGION_SAMPLES)
		var direction := (side * cos(angle) + front * sin(angle)).normalized()
		_face_sun(direction)
		_place(direction, 1.7, 4000.0)
		await _settle()
		var name := "region_%d" % roundi(rad_to_deg(angle))
		await _shot(name)
		var sky := await _sky_color()
		print("planet_test: %-12s longitude %3d deg  ground %5.0f m  sky %.2f %.2f %.2f" % [
			name, roundi(rad_to_deg(angle)), _shape.elevation(direction),
			sky.r, sky.g, sky.b])


# --- Atmospheric scattering -------------------------------------------------

## Photographs the same six views with the wavelength model on and off.
##
## The sun is pinned the way [method _night] pins it rather than swung to face
## each shot, and for the same reason: everything the scattering does depends on
## the angle between the view and the sun and on how much air the sunlight
## crossed to get here, so a light that follows the camera would hold both of
## those constant and the mode would photograph nothing.
##
## Read the numbers beside the pictures. Each pair is one frame twice, so the two
## rows differ by exactly the effect: `air_dusk` should warm sharply, `air_noon_up`
## should barely move because straight up is the shortest path through the air, and
## the `off` rows should match what the game looked like before any of this. The
## region walk at the end is the other half — three places under the same sun,
## which have to come back as three different hues or the planet's colour wheel has
## stopped reaching its sky.
func _air() -> void:
	# Same reasoning as --night: every figure below is a mean colour, and a pale
	# HUD plate is brighter than the sky at dusk.
	_hud.hide()
	_sun.global_position = Vector3.RIGHT * _shape.radius * 4.0
	_sun.look_at(Vector3.ZERO, Vector3.UP)
	_to_sun = _sun.global_basis.z
	var noon := _land_near(Vector3.RIGHT)
	var dusk := _land_near(Vector3.BACK)
	print("planet_test: sun pinned toward (%.2f, %.2f, %.2f)" % [
		_to_sun.x, _to_sun.y, _to_sun.z])

	for lit: bool in [true, false]:
		# The same global the player's toggle writes. Set here rather than
		# through GameSettingsManager so the harness does not save a setting into
		# the player's own settings.cfg on its way past.
		RenderingServer.global_shader_parameter_set(&"air_chroma", 1.0 if lit else 0.0)
		var tag := "on" if lit else "off"
		# Into the sun sitting on the horizon: the sunset band, and the one view
		# where the sunlight's own trip through the air is longest.
		_stand(dusk, 1.7, 0.08, Vector3.RIGHT)
		await _air_shot("air_dusk_" + tag)
		# The other way, which is where the blue that is left over shows.
		_stand(dusk, 1.7, 0.08, Vector3.LEFT)
		await _air_shot("air_dusk_away_" + tag)
		# Straight up at noon: the shortest path through the air, and therefore
		# the control. A large change here means the model is being applied as a
		# flat tint rather than as a path length.
		_stand(noon, 1.7, 1.2, Vector3.UP)
		await _air_shot("air_noon_up_" + tag)
		# Gameplay distance, which is the range this is actually seen at: a few
		# hundred metres up with the horizon across the middle of the frame.
		_camera.global_position = _planet.standing_position(dusk, 400.0)
		_camera.look_at(_planet.standing_position(
			_slide(dusk, Vector3.RIGHT, 3000.0)), dusk.normalized())
		await _air_shot("air_flight_" + tag)
		# The limb from outside the air, with the terminator across it. This is
		# where the shell rather than the sky is doing the work.
		_camera.global_position = (Vector3.RIGHT + Vector3.BACK).normalized() \
			* _shape.radius * 2.0
		_camera.look_at(Vector3.ZERO, Vector3.UP)
		await _air_shot("air_limb_" + tag)
		# And from just outside the shell's fade-in altitude, where the sky and
		# the shell have to agree with each other or a band appears.
		_camera.global_position = _planet.standing_position(dusk, 2600.0)
		_camera.look_at(_planet.standing_position(
			_slide(dusk, Vector3.RIGHT, 20000.0)), dusk.normalized())
		await _air_shot("air_shell_edge_" + tag)

	RenderingServer.global_shader_parameter_set(&"air_chroma", 1.0)
	# Three places a third of a turn apart around the colour wheel, under the
	# harness's usual 35-degree sun so each is lit the same way as the others.
	var declared: Dictionary = ProjectSettings.get_setting(
		"shader_globals/region_axis", {})
	var axis: Vector3 = declared.get("value", Vector3(0.0, 1.0, 0.0))
	axis = axis.normalized()
	var side := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var front := axis.cross(side)
	for step in 3:
		var angle := TAU * float(step) / 3.0
		# On land, which `--regions` does not bother with and should: two thirds
		# of this planet is sea, and a camera 1.7 m over a sea bed is under
		# water. The sky then comes back through several metres of it, which is
		# black in red and reads as the scattering having failed.
		var direction := _land_near(
			(side * cos(angle) + front * sin(angle)).normalized())
		_face_sun(direction)
		_place(direction, 1.7, 4000.0)
		await _air_shot("air_region_%d" % roundi(rad_to_deg(angle)))


## A point [param metres] along the surface from [param direction], in the
## direction of [param toward]. Used to aim a camera at the ground ahead of it
## when the sun is pinned and [method _place] cannot be used.
func _slide(direction: Vector3, toward: Vector3, metres: float) -> Vector3:
	var up := direction.normalized()
	var heading := toward - up * up.dot(toward)
	if heading.length_squared() < 1.0e-6:
		heading = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	var angle := metres / _shape.radius
	return (up * cos(angle) + heading.normalized() * sin(angle)).normalized()


## One scattering shot, with the sky's own colour reported beside it.
##
## Hue is printed as well as the three channels because that is the thing being
## judged: two skies of the same brightness and different hue is the whole effect,
## and comparing three pairs of decimals by eye is exactly how a change of hue gets
## missed. Saturation goes with it so a warm sky can be told from a pale one.
func _air_shot(shot_name: String) -> void:
	await _settle()
	await _shot(shot_name)
	var sky := await _sky_color()
	print("planet_test: %-22s sky %.3f %.3f %.3f   hue %3.0f deg  sat %.2f  luma %.3f" % [
		shot_name, sky.r, sky.g, sky.b, sky.h * 360.0, sky.s, sky.get_luminance()])


# --- Night ------------------------------------------------------------------

## Pins the sun over the north pole and walks from noon to midnight beneath it.
##
## Every other shot in this file swings the sun to light whatever the camera is
## pointed at, which is what a screenshot tour wants and is also exactly what hid
## a flipped sun in the sky shader: with the light following the camera, the lit
## side of the planet and the side with the sun in its sky are never seen apart.
## Here the light does not move, so they have to agree.
##
## Read the numbers, not just the pictures. night_sun is aimed squarely at the sun
## the scene is lit by, so its bright spot has to come back at zero degrees off it
## and nothing else in the set means anything until it does. night_day_orbit and
## night_orbit are the same planet from opposite sides and should differ in mean
## brightness by most of an order. Star share is around zero by day and a per cent
## or so at midnight.
func _night() -> void:
	# Every number below is a measurement of a dark frame, and a pale HUD plate
	# with white text on it is brighter than anything the night sky contains —
	# including, after tonemapping, the sun.
	_hud.hide()
	# Over the equator rather than over a pole. A meridian walk from a pinned
	# polar sun photographs the arctic cap three times out of three — snowbound
	# ground under a deck of its own — and never sees the rest of the planet.
	_sun.global_position = Vector3.RIGHT * _shape.radius * 4.0
	# A DirectionalLight3D emits down its own -Z, so aiming the node at the
	# centre from out along +X puts the day side on +X and midnight on -X.
	_sun.look_at(Vector3.ZERO, Vector3.UP)
	_to_sun = _sun.global_basis.z
	var travel := -_to_sun
	print("planet_test: sun pinned, light travelling (%.2f, %.2f, %.2f)" % [
		travel.x, travel.y, travel.z])

	var noon := _land_near(Vector3.RIGHT)
	var edge := _land_near(Vector3.BACK)
	var midnight := _land_near(Vector3.LEFT)

	# Pointed straight at the sun the scene is lit by. The sky draws its own disc
	# from LIGHT0_DIRECTION rather than from the frame, so if the two disagree
	# about sign this frame comes back with the sun behind the camera — which is
	# exactly what a planet lit on the wrong side looks like from the inside.
	# Everything after it is only worth reading once this one is near zero.
	_camera.global_position = _planet.standing_position(noon, 1.7)
	# Not `noon` as the up hint: with the sun overhead the two are the same
	# vector and the basis is degenerate.
	_camera.look_at(_camera.global_position + _to_sun, Vector3.UP)
	await _night_shot("night_sun")
	_stand(noon, 1.7, 1.4, Vector3.UP)
	await _night_shot("night_noon_up")
	_stand(noon, 1.7, 0.05, Vector3.UP)
	await _night_shot("night_noon")
	# The terminator, looking along the ground at the sun sitting on the horizon.
	_stand(edge, 1.7, 0.08, Vector3.RIGHT)
	await _night_shot("night_dusk")
	# The far side of the terminator: same place, facing away from the sun.
	_stand(edge, 1.7, 0.08, Vector3.LEFT)
	await _night_shot("night_twilight")
	_stand(midnight, 1.7, 0.3, Vector3.UP)
	await _night_shot("night_ground")
	_stand(midnight, 1.7, 1.4, Vector3.UP)
	await _night_shot("night_up")
	# The pair the whole mode is for: the same planet from opposite sides of it,
	# under a light that did not move in between. One is lit and one is not, and
	# which is which is the thing that was wrong.
	_camera.global_position = Vector3.RIGHT * _shape.radius * 2.2
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	await _night_shot("night_day_orbit")
	_camera.global_position = Vector3.LEFT * _shape.radius * 2.2
	_camera.look_at(Vector3.ZERO, Vector3.UP)
	await _night_shot("night_orbit")
	_camera.look_at(Vector3.LEFT * _shape.radius * 4.0, Vector3.UP)
	await _night_shot("night_deep")
	# Along the galactic band rather than across it. Star density leans on the
	# band, so night_deep is by construction the emptiest sky the shader draws
	# and this is the fullest; tuning against either one alone gets it wrong.
	var declared: Variant = RenderingServer.shader_get_parameter_default(
		SPACE_SHADER.get_rid(), &"galaxy_axis")
	if declared is Vector3:
		var axis := (declared as Vector3).normalized()
		_camera.look_at(_camera.global_position + axis.cross(Vector3.RIGHT), axis)
		await _night_shot("night_galaxy")


## The nearest direction to [param direction] with dry land under it.
##
## Two thirds of this planet is ocean, so a bearing picked for where the sun is
## rather than for what is under it lands in the sea about that often — and a
## camera 1.7 m over a sea bed 13 m down is eleven metres under water. What comes
## back is a navy frame with the stars dimmed out of it, which is indistinguishable
## from the bug this whole mode exists to catch.
func _land_near(direction: Vector3) -> Vector3:
	var up := direction.normalized()
	if _shape.elevation(up) > 5.0:
		return up
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var other := up.cross(side)
	# Golden-angle spiral, so the search reaches outward evenly instead of
	# combing one bearing at a time.
	for step in range(1, 600):
		var angle := 2.39996 * float(step)
		var reach := 0.011 * sqrt(float(step))
		var candidate := (up + (side * cos(angle) + other * sin(angle)) * reach).normalized()
		if _shape.elevation(candidate) > 5.0:
			return candidate
	push_warning("planet_test: no land within reach of %v, standing in the sea" % direction)
	return up


## Camera [param altitude] metres over [param direction], facing the tangent of
## [param toward] and pitched [param pitch] radians above the horizon.
func _stand(direction: Vector3, altitude: float, pitch: float, toward: Vector3) -> void:
	var up := direction.normalized()
	_camera.global_position = _planet.standing_position(up, altitude)
	var heading := toward - up * up.dot(toward)
	if heading.length_squared() < 1.0e-6:
		heading = up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.FORWARD)
	_camera.look_at(_camera.global_position + heading.normalized(), up)
	_camera.rotate_object_local(Vector3.RIGHT, pitch)


func _night_shot(shot_name: String) -> void:
	await _settle()
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_save(image, shot_name)
	# Brightness over the whole frame, star share over the top third — which at
	# every pitch used here is sky and nothing else.
	#
	# A star is a pixel much brighter than the sky a few pixels beside it, and
	# not a pixel over a threshold. The obvious version of this called all of a
	# blue noon sky a star field and read a flat 100% down every daytime row,
	# which is worse than no number at all.
	var height := image.get_height()
	var width := image.get_width()
	# The gap the sky is sampled across, in pixels. Wider than a star and much
	# narrower than anything else in the frame that varies.
	var gap := maxi(4, width / 400)
	var total := 0.0
	var counted := 0
	var lit := 0
	var sky := 0
	var brightest := 0.0
	var spot := Vector2.ZERO
	var spread := 0
	for y in range(0, height, 2):
		for x in range(0, width, 2):
			var value := image.get_pixel(x, y).get_luminance()
			total += value
			counted += 1
			brightest = maxf(brightest, value)
			if y >= height / 3 or x + gap >= width or y + gap >= height:
				continue
			sky += 1
			if value - maxf(image.get_pixel(x + gap, y).get_luminance(),
					image.get_pixel(x, y + gap).get_luminance()) > 0.2:
				lit += 1
	# The centre of the brightest region, not the first pixel to reach the top.
	# The sun's core and most of its glow clip to pure white, so a plain running
	# maximum reports the corner of that patch the scan happened to enter first
	# — which on a frame aimed squarely at the sun came back fifty degrees off.
	for y in range(0, height, 2):
		for x in range(0, width, 2):
			if image.get_pixel(x, y).get_luminance() >= brightest - 0.01:
				spot += Vector2(x, y)
				spread += 1
	# Back into the viewport's own coordinates before asking the camera about it.
	# A grab off the viewport texture comes back at the render scale and not at
	# the logical size project_ray_normal measures in, which here is two and a
	# half times larger and read a spot at dead centre as fifty degrees off axis.
	var frame := Vector2(float(width), float(height))
	spot = spot / maxf(float(spread), 1.0) / frame * get_viewport().get_visible_rect().size
	# How far that is from the sun the scene is lit by. On night_sun, which is
	# aimed at it, anything past a couple of degrees means the sky is drawing
	# its disc somewhere the light is not.
	var bearing := rad_to_deg(_camera.project_ray_normal(spot).angle_to(_to_sun))
	print("planet_test: %-14s mean %.3f   stars %.2f%% of the sky   brightest %3.0f deg off the sun" % [
		shot_name, total / maxf(float(counted), 1.0),
		100.0 * float(lit) / maxf(float(sky), 1.0), bearing])


## Mean colour of the top eighth of the frame. Sampled every fourth pixel, which
## is plenty for an average and keeps a 1024-wide grab off the main thread's back.
func _sky_color() -> Color:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var total := Vector3.ZERO
	var counted := 0
	for y in range(0, image.get_height() / 8, 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			total += Vector3(pixel.r, pixel.g, pixel.b)
			counted += 1
	total /= maxf(float(counted), 1.0)
	return Color(total.x, total.y, total.z)


## Parks the camera and waits for the LOD to stop building before the shutter, so
## a shot is never of half-loaded ground.
func _shot_from(shot_name: String, direction: Vector3, altitude: float,
		ahead: float) -> void:
	_face_sun(direction)
	_place(direction, altitude, ahead)
	await _settle()
	var stats := _planet.statistics()
	print("planet_test: %-16s alt %7.0f m  chunks %4d  tris %7d  bodies %3d  draws %4d  lod %.2f ms  fps %d" % [
		shot_name, altitude, stats["visible"], stats["triangles"], stats["bodies"],
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		stats["update_ms"], Engine.get_frames_per_second()])
	await _shot(shot_name)


## Aims the camera at a point [param ahead] metres along the surface, which turns
## altitude into pitch on its own: high up looks down, standing looks at the
## horizon.
func _place(direction: Vector3, altitude: float, ahead: float) -> void:
	var up := direction.normalized()
	var eye := _planet.standing_position(up, altitude)
	_camera.global_position = eye
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	if ahead <= 0.0:
		# Looking straight down the local up, so the up hint has to be something
		# else or the basis is degenerate.
		_camera.look_at(_planet.global_position, side)
	else:
		# Never past the horizon. On a planet this size the horizon at eye height
		# is a couple of hundred metres away, and aiming beyond it points the
		# camera into the dirt instead of along the ground.
		var heading := up.cross(side)
		var angle := minf(ahead, horizon_at(altitude)) / _shape.radius
		var target := (up * cos(angle) + heading * sin(angle)).normalized()
		_camera.look_at(_planet.standing_position(target), up)
	_yaw = _camera.rotation.y
	_pitch = _camera.rotation.x


## Waits for the LOD to stop building, then holds still for a second more. The
## extra wait is what makes the frame rate printed beside each shot mean anything:
## measured any earlier it is an average over the build hitches, not over the
## steady state the player would actually sit in.
func _settle(frames := 900) -> void:
	var quiet := 0
	for _index in frames:
		await get_tree().process_frame
		if int(_planet.statistics()["pending"]) == 0:
			quiet += 1
			if quiet >= 10:
				break
		else:
			quiet = 0
	for _index in 90:
		await get_tree().process_frame


## How far you can see from [param altitude] above a sphere of this radius, before
## the ground itself gets in the way.
func horizon_at(altitude: float) -> float:
	return sqrt(maxf(0.0, 2.0 * _shape.radius * altitude + altitude * altitude))


func _face_sun(direction: Vector3) -> void:
	var up := direction.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	# 35 degrees off vertical, so slopes get shadow instead of flat noon.
	var from := up.rotated(side, deg_to_rad(35.0))
	_sun.global_position = from * _shape.radius * 4.0
	_sun.look_at(Vector3.ZERO, up)


# --- Free flight ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _touring:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * 0.0022
		_pitch = clampf(_pitch - motion.relative.y * 0.0022, -1.5, 1.5)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if not _touring:
		_fly(delta)
	_update_readout()


func _fly(delta: float) -> void:
	var up := _camera.global_position.normalized()
	# Rebuild the basis from the local up every frame, so "forward" stays level
	# with the ground as the camera travels around the sphere.
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var north := up.cross(side)
	var level := Basis(side, up, -north).rotated(up, _yaw)
	_camera.global_basis = level.rotated(level.x, _pitch)

	var wish := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		wish -= _camera.global_basis.z
	if Input.is_key_pressed(KEY_S):
		wish += _camera.global_basis.z
	if Input.is_key_pressed(KEY_A):
		wish -= _camera.global_basis.x
	if Input.is_key_pressed(KEY_D):
		wish += _camera.global_basis.x
	if Input.is_key_pressed(KEY_SPACE):
		wish += up
	if Input.is_key_pressed(KEY_CTRL):
		wish -= up
	if wish == Vector3.ZERO:
		return
	var speed := clampf(_altitude() * 0.9, 6.0, 5000.0)
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 6.0
	_camera.global_position += wish.normalized() * speed * delta


func _altitude() -> float:
	var direction := _camera.global_position.normalized()
	return maxf(0.5, _camera.global_position.length() - _shape.radius
		- _shape.elevation(direction))


func _update_readout() -> void:
	var stats := _planet.statistics()
	var direction := _camera.global_position.normalized()
	_readout.text = "\n".join([
		"alt    %.0f m" % _altitude(),
		"ground %.0f m" % _shape.elevation(direction),
		"chunks %d  building %d" % [stats["visible"], stats["pending"]],
		"tris   %d  draws %d" % [stats["triangles"],
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)],
		"bodies %d" % stats["bodies"],
		"lod    %.2f ms" % stats["update_ms"],
		"fps    %d" % Engine.get_frames_per_second(),
	])


# --- Plumbing ---------------------------------------------------------------

func _arguments() -> Dictionary:
	var parsed := {}
	for argument in OS.get_cmdline_user_args():
		var text := String(argument).lstrip("-")
		var split := text.split("=", true, 1)
		parsed[split[0]] = split[1] if split.size() > 1 else true
	return parsed


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	_save(get_viewport().get_texture().get_image(), shot_name)


func _save(image: Image, shot_name: String) -> void:
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		print("planet_test: shot %s failed: %s" % [shot_name, error_string(error)])
