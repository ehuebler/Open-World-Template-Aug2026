extends Node

## Photographs the cloud deck from the five places it has to work, and quits.
##
##     & $godot --path . dev/_cloud_probe.tscn
##
## The planet tour does this too, but it settles a full LOD tree at every stop
## and takes two minutes. The deck does not care how the terrain under it is
## tessellated, so this runs the same viewpoints with a shallow quadtree and
## comes back in fifteen seconds, which is the difference between tuning a
## shader and guessing at one.
##
## The five are not arbitrary. A shell shader can be made to look right at any
## one of them and wrong at the other four, and the failures are different in
## kind: speckle from orbit, banding inside the deck, a hard edge at the horizon
## from underneath.

const SPACE_SHADER := preload("res://shaders/vivid/vivid_space.gdshader")
const SHOT_DIR := "res://dev/captures/"

var _shape: PlanetShape
var _planet: Planet
var _camera: Camera3D
var _sun: DirectionalLight3D


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_shape = PlanetShape.new()
	_shape.prepare()

	var sky_material := ShaderMaterial.new()
	sky_material.shader = SPACE_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128

	var world_environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_SKY
	settings.sky = sky
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	settings.ambient_light_energy = 0.38
	settings.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	settings.tonemap_mode = Environment.TONE_MAPPER_ACES
	settings.tonemap_white = 2.0
	settings.glow_enabled = true
	settings.glow_hdr_threshold = 0.95
	settings.glow_intensity = 0.7
	settings.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	world_environment.environment = settings
	add_child(world_environment)

	_sun = DirectionalLight3D.new()
	_sun.light_energy = 1.05
	_sun.light_color = Color(1.0, 0.96, 0.9)
	_sun.shadow_enabled = false
	add_child(_sun)

	_planet = Planet.new()
	_planet.name = "Planet"
	_planet.shape = _shape
	_planet.sun = _sun
	# The deck is a field and does not care what the ground under it is made of.
	_planet.max_depth = 4
	_planet.has_clouds = not OS.get_cmdline_user_args().has("--noclouds")
	add_child(_planet)

	_camera = Camera3D.new()
	_camera.fov = 62.0
	_camera.near = 0.5
	_camera.far = _shape.radius * 8.0
	add_child(_camera)
	_camera.current = true
	_planet.viewer = _camera

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	# Over land. A cloud photographed against an ocean is a cloud photographed
	# against a flat blue card, and half of what these shots are for is whether
	# the deck sits over the ground or floats away from it.
	var land := _dry_land()

	await _shot("cloud_orbit", land, _shape.radius * 2.2, -90.0)
	# Pitch is off the local horizontal, and the horizon is a long way below that
	# on a planet this small: 41 degrees down from 2600 m, 30 from 1200 m. Aim
	# level from up there and the shot comes back as a picture of space.
	await _shot("cloud_above", land, _planet.cloud_height + 1400.0, -50.0)
	await _shot("cloud_inside", land, _planet.cloud_height, -32.0)
	await _shot("cloud_bases", land, 350.0, 55.0)
	await _shot("cloud_ground", land, 2.0, 22.0)
	print("cloud_probe: deck middle at %.0f m, ground under it %.0f m"
		% [_planet.cloud_height, _shape.elevation(land)])
	get_tree().quit()


## Low ground well clear of the sea, out of a few hundred evenly spread
## directions. Not the highest point: standing on the one mountain on the planet
## puts the camera a third of the way to the deck and answers a question nobody
## asked.
const WANTED_GROUND := 80.0

func _dry_land() -> Vector3:
	var best := Vector3.UP
	var closest := INF
	for index in 400:
		var direction := PlanetShape.even_direction(index, 400)
		var miss := absf(_shape.elevation(direction) - WANTED_GROUND)
		if miss < closest:
			closest = miss
			best = direction
	return best


## [param pitch] is degrees off the local horizon: 90 straight up at the cloud
## bases, 0 along it, -90 straight down at the planet.
func _shot(shot_name: String, direction: Vector3, altitude: float, pitch: float) -> void:
	var up := direction.normalized()
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var heading := up.cross(side)
	# The sun off to one side rather than behind the camera: the deck is shaded
	# by where the light is coming from, and straight-on light flattens it.
	_sun.look_at_from_position(Vector3.ZERO,
		-(up * 0.45 + side * 0.9).normalized(), Vector3.RIGHT)
	var eye := _planet.standing_position(up, altitude)
	_camera.global_position = eye
	var angle := deg_to_rad(pitch)
	var look := (heading * cos(angle) + up * sin(angle)).normalized()
	# Straight up or straight down leaves the heading as the only usable hint.
	_camera.look_at_from_position(eye, eye + look,
		heading if absf(pitch) > 88.0 else up)
	for frame in 45:
		await get_tree().process_frame
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("cloud_probe: %-13s alt %6.0f m  pitch %4.0f deg" % [shot_name, altitude, pitch])
