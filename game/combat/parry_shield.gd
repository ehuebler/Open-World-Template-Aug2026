class_name ParryShield
extends MeshInstance3D

## Reusable parry bubble. Gameplay owns the clock; this node only draws it.

const SHADER := preload("res://game/combat/parry_shield.gdshader")
const BLUE := Color(0.16, 0.52, 1.0, 0.23)
const GOLD := Color(1.0, 0.68, 0.12, 0.3)

var _material: ShaderMaterial
var _active := false
var _perfect := false
var _celebration_left := 0.0
var _phase := 0.0


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Dedicated/headless peers still own the gameplay node, but the dummy
	# renderer has nothing to draw and should not allocate shader instances.
	if DisplayServer.get_name() == "headless":
		visible = false
		set_process(false)
		return
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 32
	sphere.rings = 16
	sphere.material = _material
	mesh = sphere
	visible = false
	set_process(false)


func fit_body(height: float, width := 0.55) -> void:
	position.y = height * 0.5
	scale = Vector3(maxf(width, 0.35), maxf(height * 0.58, 0.55),
		maxf(width, 0.35))


func set_state(active: bool, perfect: bool, window_share := 1.0) -> void:
	_active = active
	visible = active or _celebration_left > 0.0
	_perfect = perfect
	if _material == null:
		visible = false
		set_process(false)
		return
	if _material != null:
		_material.set_shader_parameter(&"shield_color", GOLD if perfect else BLUE)
		_material.set_shader_parameter(&"ripple", clampf(window_share, 0.0, 1.0))
	set_process(active or _celebration_left > 0.0)


func celebrate_perfect() -> void:
	_celebration_left = 0.28
	if _material == null:
		visible = false
		return
	visible = true
	set_process(true)


func _process(delta: float) -> void:
	_phase += delta * 18.0
	_celebration_left = maxf(_celebration_left - delta, 0.0)
	var golden := _perfect or _celebration_left > 0.0
	var pulse := (0.5 + 0.5 * sin(_phase)) if golden else 0.0
	if _material != null:
		_material.set_shader_parameter(&"shield_color", GOLD if golden else BLUE)
		_material.set_shader_parameter(&"pulse", pulse)
	visible = _active or _celebration_left > 0.0
	if not _active and _celebration_left <= 0.0:
		set_process(false)
