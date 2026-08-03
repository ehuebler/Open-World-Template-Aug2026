extends Node

## What the character looks like close up, and whether it holds still.
##
##     godot --path . dev/_character_look.tscn
##
## The black streaks that come and go across the body are invisible in a single
## frame and invisible at menu distance, which is why they survived this long. So
## this frames the model, stops its animation, and photographs a scene in which
## nothing at all moves. Two numbers come out of it:
##
##  - **shadow**, the difference between the frame as shipped and the same frame
##    with the sun's shadow off. That attributes the streaks: the surface shader
##    has no shadow term of its own, so anything that appears here is the shadow
##    map falling on the body rather than the material.
##  - **flicker**, the largest change between successive frames of the frozen
##    pose. Nothing is moving, so any change at all is the renderer disagreeing
##    with itself from one frame to the next — which is what "flickering" means.
##
## Both are measured only inside the body's own screen rectangle, worked out from
## the mesh bounds, so the planet and the drifting clouds behind it are not in the
## average. Flags: `-- --bias=0.03 --normalbias=0.6` to try shadow biases without
## editing the scene, `-- --outline=0` to see the model with its silhouette pass
## turned off.

const WORLD: PackedScene = preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
## Long enough for the planet to get off its coarsest chunks, so the body is lit
## by the terrain it will actually be standing on.
const SETTLE_FRAMES := 240
## How far the camera sits from the chest, in metres. Close enough that a streak is
## tens of pixels across rather than two.
const RANGE := 2.1
## Frames of the frozen pose taken for the flicker figure.
const HOLD_FRAMES := 8
## Luminance change counted as a visible difference rather than as dither. Sampled
## after the sRGB curve is undone, so this is a fraction of full brightness.
const VISIBLE := 0.02

var _world: GameWorld
var _sun: DirectionalLight3D
var _character: Node3D
var _camera: Camera3D
## The body's own pixels, in the captured frame's coordinates. Everything is measured
## over these and not over a box around the figure: the bounding box of a standing
## body is mostly the planet behind it, whose clouds drift, and averaging those in
## reported the weather as though it were the character.
var _body: Array[Vector2i] = []


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	for _frame in SETTLE_FRAMES:
		await get_tree().process_frame

	var home := _world.get_node_or_null("HomeScreen") as HomeScreen
	if home == null:
		push_error("_character_look: the world came up with no home screen")
		get_tree().quit(1)
		return
	home.show_view(HomeScreen.View.HOME)
	# The menu's own text and the name field are drawn straight over the body, and
	# they would go into the mask as brightly as the character does.
	for node in home.get_children():
		if node is CanvasLayer:
			(node as CanvasLayer).visible = false
	_character = home.get_node_or_null("PreviewCharacter") as Node3D
	_sun = _world.find_child("Sun", true, false) as DirectionalLight3D
	if _character == null or _sun == null:
		push_error("_character_look: no preview character or no sun")
		get_tree().quit(1)
		return
	print("_character_look: sun bias %.3f normal_bias %.3f blur %.2f, splits %.3f/%.3f/%.3f to %.0f m" % [
		_sun.shadow_bias, _sun.shadow_normal_bias, _sun.shadow_blur,
		_sun.directional_shadow_split_1, _sun.directional_shadow_split_2,
		_sun.directional_shadow_split_3, _sun.directional_shadow_max_distance])
	# For the whole run rather than for one shot, which is the attribution the
	# streaks need: if the frozen pose still changes from frame to frame with no
	# shadow in the scene at all, then whatever is moving is not the shadow map.
	if "--noshadow" in OS.get_cmdline_user_args():
		_sun.shadow_enabled = false
		print("_character_look: sun casts no shadow for this run")
	_apply_overrides()
	# Whether the body is shadowing itself or standing in the terrain's shadow. Stop
	# it casting and the first goes while the second stays, which is the only way to
	# tell the two apart from a picture.
	if "--nocast" in OS.get_cmdline_user_args():
		for node in _character.find_children("*", "MeshInstance3D", true, false):
			(node as MeshInstance3D).cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		print("_character_look: body casts no shadow")
	_freeze_pose()
	_frame_body()
	for _frame in 30:
		await get_tree().process_frame
	await _build_mask()

	# The two shots the shadow is measured from are taken back to back, because the
	# clouds behind the body drift and every frame between them is cloud that moved
	# charged to the sun.
	var lit := await _shot("character_lit")
	var shadowed := _sun.shadow_enabled
	_sun.shadow_enabled = false
	for _frame in 4:
		await get_tree().process_frame
	var flat := await _shot("character_noshadow")
	_sun.shadow_enabled = shadowed
	for _frame in 4:
		await get_tree().process_frame
	var flicker := await _flicker(await _shot(""))

	var shadow := _difference(lit, flat)
	_save_difference(lit, flat, "character_shadow")
	_save_crop(lit, "character_crop_lit")
	_save_crop(flat, "character_crop_noshadow")
	print("_character_look: shadow mean %.4f max %.4f over %.1f%% of the body" % [
		shadow["mean"], shadow["max"], shadow["share"] * 100.0])
	print("_character_look: flicker mean %.4f max %.4f over %.1f%% of the body" % [
		flicker["mean"], flicker["max"], flicker["share"] * 100.0])
	get_tree().quit()


## Shadow biases from the command line, so a sweep does not mean editing world.tscn
## between runs. An outline width of zero is how the silhouette pass is judged: the
## same body with and without it.
func _apply_overrides() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=")
		if parts.size() != 2:
			continue
		var value := parts[1].to_float()
		match parts[0]:
			"bias":
				_sun.shadow_bias = value
			"normalbias":
				_sun.shadow_normal_bias = value
			"outline":
				_set_outline_width(value)


func _set_outline_width(pixels: float) -> void:
	for node in _character.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.mesh.get_surface_count():
			var material := mesh_instance.get_surface_override_material(surface) as ShaderMaterial
			if material == null or material.next_pass == null:
				continue
			var line := material.next_pass as ShaderMaterial
			line.set_shader_parameter(&"width_pixels", pixels)


## The pose has to stop, or every frame differs because the body moved and the
## flicker figure means nothing. Held part-way through the clip rather than at zero,
## where the arms are at their rest angles and away from the body — the streaks are
## worst where a limb is near the torso.
func _freeze_pose() -> void:
	var animator := _character.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animator == null:
		return
	animator.seek(0.4, true)
	animator.pause()


## Square on to the chest, from the character's own left, with its own up. Taken off
## the body's transform rather than the menu camera's so the shot is the same
## whatever pose the home screen is in.
func _frame_body() -> void:
	_camera = Camera3D.new()
	_camera.fov = 50.0
	# The world is 8 km across and the body is 1.45 m of it. A default near plane
	# throws away the depth precision this needs.
	_camera.near = 0.05
	_camera.far = 20000.0
	add_child(_camera)
	var basis := _character.global_basis
	var chest := _character.global_position + basis.y * 0.95
	var eye := chest + basis.x * RANGE * 0.55 - basis.z * RANGE * 0.83
	_camera.global_transform = Transform3D(Basis.looking_at(chest - eye, basis.y), eye)
	_camera.current = true


## The biggest change across a run of frames of a scene where nothing is moving.
## The frame that produced it is kept: the streaks are only on the body for some of
## these frames, and that is the one worth looking at.
func _flicker(against: Image) -> Dictionary:
	var worst := {"mean": 0.0, "max": 0.0, "share": 0.0}
	for _step in HOLD_FRAMES:
		await get_tree().process_frame
		var frame := await _shot("")
		var change := _difference(against, frame)
		if change["max"] > worst["max"]:
			worst = change
			frame.save_png(SHOT_DIR + "character_worst.png")
	return worst


## Which pixels of the rectangle are the body. The body is painted flat white and
## everything else is taken out of the frame, so the mask is decided by geometry
## rather than by what happens to be bright. Two earlier attempts at this failed
## honestly enough to be worth recording: diffing the body against the planet behind
## it returns the silhouette and not the body, because a lit arm and the terrain past
## it are about equally bright; and hiding the planet leaves the body black, because
## the ambient light on this world comes from the sky it just removed. Nothing is
## moved, so the mask still describes the frames taken afterwards.
func _build_mask() -> void:
	var planet := _world.find_child("Planet", true, false) as Node3D
	var world_environment := _world.find_child("WorldEnvironment", true, false) as WorldEnvironment
	var environment := world_environment.environment
	var background := environment.background_mode
	var flat := StandardMaterial3D.new()
	flat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flat.albedo_color = Color.WHITE
	planet.visible = false
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	var meshes := _character.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		(node as MeshInstance3D).material_override = flat
	for _frame in 4:
		await get_tree().process_frame
	var alone := await _shot("character_alone")

	for node in meshes:
		(node as MeshInstance3D).material_override = null
	planet.visible = true
	environment.background_mode = background
	for _frame in 4:
		await get_tree().process_frame

	# Scanned in the captured image's own pixels rather than in a rectangle
	# unprojected from the camera. Those are not the same grid: the canvas this
	# project lays out in is 1280x720 and what the renderer hands back here is
	# smaller, so a screen position taken from `unproject_position` indexes the wrong
	# part of the frame. Everything below is in image pixels for that reason.
	var found := {}
	for y in alone.get_height():
		for x in alone.get_width():
			if _luma(alone.get_pixel(x, y).srgb_to_linear()) > 0.5:
				found[Vector2i(x, y)] = true
	# Eroded, because the outermost pixel of the silhouette is a blend with whatever
	# is behind it, and behind it in the real frames is a planet with weather on it.
	var edge := found.size()
	found = _eroded(found)
	_body.clear()
	for at: Vector2i in found:
		_body.append(at)
	print("_character_look: frame %dx%d in a %s canvas, body %d px, %d after the edge comes off" % [
		alone.get_width(), alone.get_height(), get_viewport().get_visible_rect().size,
		edge, _body.size()])


## Pixels all four of whose neighbours are also in the set.
func _eroded(found: Dictionary) -> Dictionary:
	var inside := {}
	for at: Vector2i in found:
		if found.has(at + Vector2i.LEFT) and found.has(at + Vector2i.RIGHT) \
				and found.has(at + Vector2i.UP) and found.has(at + Vector2i.DOWN):
			inside[at] = true
	return inside


## Per-pixel luminance difference over the body: the average, the worst, and the
## share of it that changed by more than [constant VISIBLE].
func _difference(before: Image, after: Image) -> Dictionary:
	var total := 0.0
	var worst := 0.0
	var changed := 0
	for at in _body:
		var was := before.get_pixelv(at).srgb_to_linear()
		var now := after.get_pixelv(at).srgb_to_linear()
		var gap := absf(_luma(was) - _luma(now))
		total += gap
		worst = maxf(worst, gap)
		if gap > VISIBLE:
			changed += 1
	if _body.is_empty():
		return {"mean": 0.0, "max": 0.0, "share": 0.0}
	return {"mean": total / float(_body.size()), "max": worst,
		"share": float(changed) / float(_body.size())}


## The frame cropped to the body, which is the only part of it worth looking at and
## is otherwise a tenth of a picture of a planet.
func _save_crop(frame: Image, shot_name: String) -> void:
	frame.get_region(_bounds()).save_png(SHOT_DIR + shot_name + ".png")
	print("_character_look: shot %s" % shot_name)


func _bounds() -> Rect2i:
	var least := Vector2i(1 << 24, 1 << 24)
	var most := Vector2i.ZERO
	for at in _body:
		least = least.min(at)
		most = most.max(at)
	return Rect2i(least, most - least + Vector2i.ONE)


## The difference as a picture, cropped to the body and nothing else, so what the
## numbers are averaging can be looked at. Red is the frame having got darker and
## green lighter, both at four times the value, because the interesting marks here
## are a tenth of full brightness and invisible drawn honestly.
func _save_difference(before: Image, after: Image, shot_name: String) -> void:
	var bounds := _bounds()
	var picture := Image.create_empty(bounds.size.x, bounds.size.y, false, Image.FORMAT_RGB8)
	for at in _body:
		var gap := _luma(before.get_pixelv(at).srgb_to_linear()) \
			- _luma(after.get_pixelv(at).srgb_to_linear())
		picture.set_pixelv(at - bounds.position,
			Color(maxf(-gap, 0.0) * 4.0, maxf(gap, 0.0) * 4.0, 0.0))
	picture.save_png(SHOT_DIR + shot_name + ".png")
	print("_character_look: shot %s" % shot_name)


func _luma(colour: Color) -> float:
	return colour.r * 0.2126 + colour.g * 0.7152 + colour.b * 0.0722


## An empty name takes the frame without writing it, which is what the flicker run
## wants — eight PNGs of a body that is not moving are eight copies of one picture.
func _shot(shot_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if not shot_name.is_empty():
		image.save_png(SHOT_DIR + shot_name + ".png")
		print("_character_look: shot %s" % shot_name)
	return image
