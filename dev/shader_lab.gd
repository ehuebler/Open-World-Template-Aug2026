extends Node3D

## Test bed for the pencil shader. Drag to orbit, wheel to zoom, and use the
## panel on the left to push uniforms around while the scene is running.
## Run it directly: Godot --path . res://dev/shader_lab.tscn
## Add `-- --shot` to save one screenshot and quit (used for automated checks).

const PENCIL_MATERIAL: ShaderMaterial = preload("res://shaders/pencil/pencil_material.tres")
const CAPTURE_DIR := "res://dev/captures"

const PALETTE: Array[Color] = [
	Color(0.84, 0.44, 0.36),
	Color(0.45, 0.62, 0.48),
	Color(0.38, 0.52, 0.72),
	Color(0.86, 0.74, 0.42),
	Color(0.62, 0.48, 0.70),
	Color(0.80, 0.60, 0.48),
	Color(0.52, 0.68, 0.72),
]

const FLOOR_COLOR := Color(0.76, 0.73, 0.62)
## The floor stretches to the horizon, where world-space strokes fall below pixel
## size, so it hatches in screen space instead. 14 strokes per 100 px.
const FLOOR_HATCH_SPACE := 3
const FLOOR_HATCH_SCALE := 14.0

## Uniforms exposed in the live panel. Types: "float", "int", "bool", "enum".
const CONTROLS: Array = [
	{"uniform": &"hatch_space", "type": "enum", "options": ["Model UV", "Model Triplanar", "World Triplanar", "Screen"]},
	{"uniform": &"hatch_scale", "type": "float", "min": 2.0, "max": 60.0, "step": 0.5},
	{"uniform": &"stroke_thickness", "type": "float", "min": 0.05, "max": 1.0, "step": 0.01},
	{"uniform": &"stroke_wobble", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
	{"uniform": &"stroke_breakup", "type": "float", "min": 0.0, "max": 0.9, "step": 0.01},
	{"uniform": &"ink_strength", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"ink_tint", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"parallax_strength", "type": "float", "min": 0.0, "max": 0.5, "step": 0.005},
	{"uniform": &"height_scale", "type": "float", "min": 0.2, "max": 12.0, "step": 0.1},
	{"uniform": &"tone_gamma", "type": "float", "min": 0.2, "max": 3.0, "step": 0.05},
	{"uniform": &"light_bands", "type": "int", "min": 1, "max": 6},
	{"uniform": &"band_softness", "type": "float", "min": 0.0, "max": 0.5, "step": 0.005},
	{"uniform": &"light_wrap", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"shadow_leak", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"terminator_wobble", "type": "float", "min": 0.0, "max": 0.5, "step": 0.005},
	{"uniform": &"fill_energy", "type": "float", "min": 0.0, "max": 2.0, "step": 0.01},
	{"uniform": &"fill_tone", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"edge_ink", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"edge_width", "type": "float", "min": 0.05, "max": 1.0, "step": 0.01},
	{"uniform": &"paper_grain", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
	{"uniform": &"paper_grain_scale", "type": "float", "min": 20.0, "max": 800.0, "step": 5.0},
	{"uniform": &"paper_grain_screen_space", "type": "bool"},
	{"uniform": &"redraw_jitter", "type": "float", "min": 0.0, "max": 4.0, "step": 0.05},
	{"uniform": &"redraw_fps", "type": "float", "min": 0.0, "max": 24.0, "step": 1.0},
	{"uniform": &"color_steps", "type": "int", "min": 0, "max": 12},
]

@onready var sun: DirectionalLight3D = $Sun
@onready var camera_rig: Node3D = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var props: Node3D = $Props
@onready var controls_panel: PanelContainer = $UI/ControlsPanel
@onready var controls_box: VBoxContainer = $UI/ControlsPanel/Scroll/Controls
@onready var info_label: Label = $UI/Info

var _materials: Array[ShaderMaterial] = []
var _outline_chain: Material = null
var _outlines_enabled := true
var _orbit_sun := false
var _orbit_camera := false
var _dragging := false
var _zoom := 8.0
var _shot_requested := false
var _shot_path := ""
var _shot_delay := 12


func _ready() -> void:
	_outline_chain = PENCIL_MATERIAL.next_pass
	_apply_materials()
	_build_controls()
	_parse_cmdline()
	camera.position.z = _zoom


func _apply_materials() -> void:
	var meshes := _collect_meshes(props)
	for index in meshes.size():
		var mesh_instance := meshes[index]
		var material := PENCIL_MATERIAL.duplicate() as ShaderMaterial
		var is_floor := mesh_instance.name == "Floor"
		material.set_shader_parameter(&"base_color", FLOOR_COLOR if is_floor else PALETTE[index % PALETTE.size()])
		if is_floor:
			material.set_shader_parameter(&"hatch_space", FLOOR_HATCH_SPACE)
			material.set_shader_parameter(&"hatch_scale", FLOOR_HATCH_SCALE)
		mesh_instance.material_override = material
		_materials.append(material)


func _collect_meshes(root: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child is MeshInstance3D:
			found.append(child)
		found.append_array(_collect_meshes(child))
	return found


func _build_controls() -> void:
	for spec_variant in CONTROLS:
		var spec: Dictionary = spec_variant
		var uniform: StringName = spec["uniform"]
		var row := VBoxContainer.new()
		row.add_theme_constant_override(&"separation", 0)
		var label := Label.new()
		label.text = String(uniform)
		label.add_theme_font_size_override(&"font_size", 12)
		row.add_child(label)
		row.add_child(_make_widget(spec, label))
		controls_box.add_child(row)


func _make_widget(spec: Dictionary, label: Label) -> Control:
	var uniform: StringName = spec["uniform"]
	var current: Variant = _shader_default(uniform)
	match String(spec["type"]):
		"bool":
			var check := CheckBox.new()
			check.button_pressed = bool(current)
			check.text = "on"
			check.toggled.connect(func(pressed: bool) -> void: _set_uniform(uniform, pressed))
			return check
		"enum":
			var options := OptionButton.new()
			for option in spec["options"]:
				options.add_item(String(option))
			options.selected = int(current)
			options.item_selected.connect(func(index: int) -> void: _set_uniform(uniform, index))
			return options
		"int":
			var int_slider := HSlider.new()
			int_slider.min_value = float(spec["min"])
			int_slider.max_value = float(spec["max"])
			int_slider.step = 1.0
			int_slider.value = float(current)
			label.text = "%s  %d" % [uniform, int(current)]
			int_slider.value_changed.connect(func(value: float) -> void:
				label.text = "%s  %d" % [uniform, int(value)]
				_set_uniform(uniform, int(value)))
			return int_slider
		_:
			var slider := HSlider.new()
			slider.min_value = float(spec["min"])
			slider.max_value = float(spec["max"])
			slider.step = float(spec["step"])
			slider.value = float(current)
			label.text = "%s  %.3f" % [uniform, float(current)]
			slider.value_changed.connect(func(value: float) -> void:
				label.text = "%s  %.3f" % [uniform, value]
				_set_uniform(uniform, value))
			return slider


func _shader_default(uniform: StringName) -> Variant:
	var value: Variant = PENCIL_MATERIAL.get_shader_parameter(uniform)
	if value != null:
		return value
	return RenderingServer.shader_get_parameter_default(PENCIL_MATERIAL.shader.get_rid(), uniform)


func _set_uniform(uniform: StringName, value: Variant) -> void:
	for material in _materials:
		material.set_shader_parameter(uniform, value)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_set_zoom(_zoom - 0.6)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_set_zoom(_zoom + 0.6)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		camera_rig.rotation.y -= motion.relative.x * 0.006
		camera_rig.rotation.x = clampf(camera_rig.rotation.x - motion.relative.y * 0.006, -1.4, 1.4)
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_TAB:
			controls_panel.visible = not controls_panel.visible
		KEY_SPACE:
			_orbit_sun = not _orbit_sun
		KEY_C:
			_orbit_camera = not _orbit_camera
		KEY_O:
			_toggle_outlines(not _outlines_enabled)
		KEY_F12:
			_save_screenshot(_timestamped_capture_path())
		KEY_ESCAPE:
			get_tree().quit()


## Sets one uniform on every material, matching the type the shader declares.
func _override_uniform(uniform: StringName, value: float) -> void:
	var default: Variant = _shader_default(uniform)
	var typed: Variant = value
	if default is int:
		typed = int(value)
	elif default is bool:
		typed = value > 0.5
	_set_uniform(uniform, typed)


## Stops the hand-redraw jitter on every pass, so captures are comparable.
func _freeze_redraw() -> void:
	for material in _materials:
		var pass_material: Material = material
		while pass_material is ShaderMaterial:
			(pass_material as ShaderMaterial).set_shader_parameter(&"redraw_fps", 0.0)
			pass_material = pass_material.next_pass


func _toggle_outlines(enabled: bool) -> void:
	_outlines_enabled = enabled
	for material in _materials:
		material.next_pass = _outline_chain if enabled else null


func _set_zoom(value: float) -> void:
	_zoom = clampf(value, 1.5, 40.0)
	camera.position.z = _zoom


func _process(delta: float) -> void:
	if _orbit_sun:
		sun.rotation.y += delta * 0.5
	if _orbit_camera:
		camera_rig.rotation.y += delta * 0.25
	info_label.text = "%d FPS   drag orbit / wheel zoom   Tab panel   Space sun   C camera   O outlines   F12 shot   Esc quit" % Engine.get_frames_per_second()

	if _shot_requested:
		_shot_delay -= 1
		if _shot_delay <= 0:
			_shot_requested = false
			_shoot_and_quit()


func _shoot_and_quit() -> void:
	await _save_screenshot(_shot_path)
	get_tree().quit()


func _parse_cmdline() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--shot":
			_shot_requested = true
			if _shot_path.is_empty():
				_shot_path = _timestamped_capture_path()
		elif argument.begins_with("--shot-path="):
			_shot_path = argument.split("=", true, 1)[1]
			_shot_requested = true
		elif argument.begins_with("--frames="):
			_shot_delay = int(argument.split("=", true, 1)[1])
		elif argument == "--no-outlines":
			_toggle_outlines(false)
		elif argument == "--freeze":
			_freeze_redraw()
		elif argument.begins_with("--set="):
			var assignment := argument.split("=", true, 1)[1].split(":")
			_override_uniform(StringName(assignment[0]), float(assignment[1]))
		elif argument.begins_with("--zoom="):
			_zoom = float(argument.split("=", true, 1)[1])
		elif argument.begins_with("--yaw="):
			camera_rig.rotation.y = deg_to_rad(float(argument.split("=", true, 1)[1]))
		elif argument.begins_with("--pitch="):
			camera_rig.rotation.x = deg_to_rad(float(argument.split("=", true, 1)[1]))
		elif argument.begins_with("--look="):
			var parts := argument.split("=", true, 1)[1].split(",")
			camera_rig.position = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		elif argument.begins_with("--hide="):
			var target := props.get_node_or_null(argument.split("=", true, 1)[1]) as Node3D
			if target != null:
				target.visible = false


func _timestamped_capture_path() -> String:
	return "%s/lab_%d.png" % [CAPTURE_DIR, Time.get_ticks_msec()]


func _save_screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var absolute := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var error := image.save_png(absolute)
	if error == OK:
		print("shader_lab: saved %s at %d FPS" % [absolute, Engine.get_frames_per_second()])
	else:
		push_error("shader_lab: screenshot failed (%d) for %s" % [error, absolute])
