extends Node

## Throwaway. Shoots the home screen four ways to find what draws the notched
## comb over the planet: everything, the sea alone against space, the ground
## alone, and the sea with its own ring-and-spoke grid painted on it.

const WORLD: PackedScene = preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

var _world: GameWorld
var _planet: Planet


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	for frame in 240:
		await get_tree().process_frame
	_planet = _world.find_child("Planet", true, false) as Planet
	var home := _world.get_node_or_null("HomeScreen") as HomeScreen
	if home != null:
		home.show_view(HomeScreen.View.HOME)
	for frame in 180:
		await get_tree().process_frame

	var camera := get_viewport().get_camera_3d()
	print("probe: eye %.0f m from centre, radius %.0f" % [ \
		camera.global_position.distance_to(_planet.global_position), _planet.shape.radius])
	# Numbers painted into a frame only come back as numbers if nothing between the
	# shader and the buffer bends them. Glow spreads a thin sliver's channels into
	# its neighbours and the tonemapper is a curve; with both off, a byte is the
	# value the shader wrote.
	var env := _world.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if env != null and env.environment != null:
		env.environment.glow_enabled = false
		env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.environment.tonemap_exposure = 1.0
		env.environment.tonemap_white = 1.0
		env.environment.adjustment_enabled = false
		print("probe: glow and tonemap off")

	# What the shader should be computing, from the same numbers it has.
	var reach := _planet.water._reach(17001.0 - 8000.0)
	var worst := 0.0
	var inner := 0.0
	for ring in range(1, PlanetWater.RINGS + 1):
		var share := float(ring) / float(PlanetWater.RINGS)
		var radius := share * share
		var flat := Vector2(radius - inner, radius * TAU / float(PlanetWater.SPOKES)) * reach
		inner = radius
		var slope := 8000.0 / sqrt(8000.0 * 8000.0 + radius * reach * radius * reach)
		var arc := Vector2(flat.x * slope * slope, flat.y * slope)
		worst = maxf(worst, arc.length_squared() / (8.0 * 8000.0))
	print("probe: reach %.0f m, worst chord gap %.2f m" % [reach, worst])

	# Where the disc's own centre is on screen, and how square-on the slivers are
	# being looked at. A grazing view changes what the depth behind the water
	# means: the bed is no longer under it, it is the far shore behind it.
	var centre := _planet.global_position
	var sub_eye := centre + (camera.global_position - centre).normalized() * 8000.0
	print("probe: sub-eye point at screen %s" % camera.unproject_position(sub_eye))
	var slant := ""
	for column in 8:
		var pixel := Vector2(915.0 + float(column) * 8.0, 215.0)
		var hit := _sea_hit(camera, pixel, centre)
		if hit == Vector3.ZERO:
			continue
		var facing := absf((hit - centre).normalized().dot(camera.project_ray_normal(pixel)))
		slant += "%.0fpx:%.2f " % [pixel.x, facing]
	print("probe: facing %s" % slant)

	# The terrain profile across the slivers, a pixel at a time.
	for row in 3:
		var line := ""
		for column in 24:
			var pixel := Vector2(950.0 + float(column) * 2.0, 210.0 + float(row) * 6.0)
			var hit := _sea_hit(camera, pixel, centre)
			if hit == Vector3.ZERO:
				line += "  .  "
				continue
			line += "%+5.0f" % _planet.shape.elevation((hit - centre).normalized())
		print("probe: lift %s" % line)
	await _shoot("ripple_all")

	# What the mesh actually carries, after Godot has stored it. The intended
	# values are printed beside them.
	var mesh := (_planet.water.find_child("Surface", true, false) as MeshInstance3D).mesh
	var stored: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	for ring in [1, 24, 47, 48]:
		var share := float(ring) / float(PlanetWater.RINGS)
		var before := float(ring - 1) / float(PlanetWater.RINGS)
		print("probe: ring %d stored %s wanted (%.6f, %.6f)" % [ring, \
			stored[1 + (ring - 1) * PlanetWater.SPOKES], \
			share * share - before * before, share * share * TAU / float(PlanetWater.SPOKES)])

	await RenderingServer.frame_post_draw
	var frame_image := get_viewport().get_texture().get_image()
	for row in 2:
		var line := ""
		for column in 60:
			var x := 1830 + column * 4
			var pixel := frame_image.get_pixelv(Vector2i(x, 420 + row * 20)).srgb_to_linear()
			if pixel.b < 0.95:
				continue
			line += "%d:%.3f/%+.2f " % [x, pixel.r * 0.01, pixel.g - 0.5]
		print("probe: water offray/nearer %s" % line)

	# The ground, and everything else the planet hangs off, without the sea.
	var ground: Array[Node3D] = []
	for child in _planet.get_children(true):
		if child is Node3D and child != _planet.water:
			ground.append(child as Node3D)
	print("probe: %d ground nodes beside the water" % ground.size())
	for node in ground:
		node.visible = false
	for frame in 8:
		await get_tree().process_frame
	await _shoot("ripple_sea_only")
	for node in ground:
		node.visible = true
	_planet.water.visible = false
	for frame in 8:
		await get_tree().process_frame
	await _shoot("ripple_ground_only")
	_planet.water.visible = true
	for frame in 8:
		await get_tree().process_frame
	get_tree().quit()


## Where the view ray through a pixel first meets the sea sphere, or ZERO past
## the limb.
func _sea_hit(camera: Camera3D, pixel: Vector2, centre: Vector3) -> Vector3:
	var from := camera.project_ray_origin(pixel)
	var dir := camera.project_ray_normal(pixel)
	var offset := from - centre
	var b := offset.dot(dir)
	var c := offset.length_squared() - _planet.water.sea_level * _planet.water.sea_level
	var disc := b * b - c
	if disc < 0.0:
		return Vector3.ZERO
	return from + dir * (-b - sqrt(disc))


func _shoot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(SHOT_DIR + shot_name + ".png")
	print("probe: shot %s" % shot_name)
