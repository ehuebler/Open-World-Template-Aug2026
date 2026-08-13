class_name BigfootRoarWave
extends MeshInstance3D

## Client-side expanding roar shell. Gameplay radius is host-authoritative; this
## follows the replicated [member radius] and [member origin].

const SHADER := preload("res://game/enemies/bigfoot/bigfoot_roar_wave.gdshader")

## The enlarged arena reaches 200 m across and 260 m above the ground, whose
## diagonal is about 328 m. Stopping the drawing at 95 m made the warning vanish
## long before it reached a high or distant player even though the authoritative
## front kept travelling. The material is now one-sided and discards the clear
## centre, so the shell can remain visible over its full gameplay reach without
## restoring the old pair of full-screen blended passes.
const DRAW_LIMIT := 340.0

var origin := Vector3.ZERO
var radius := 0.0

var _material: ShaderMaterial


func _ready() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if DisplayServer.get_name() == "headless":
		visible = false
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
	top_level = true
	visible = false


func set_wave(at: Vector3, wave_radius: float) -> void:
	origin = at
	radius = maxf(wave_radius, 0.0)
	if DisplayServer.get_name() == "headless":
		return
	if radius > DRAW_LIMIT:
		visible = false
		return
	global_position = at
	# SphereMesh is already unit-radius. Scaling by diameter made the warning
	# shell arrive visually twice as early as the authoritative wave front.
	scale = Vector3.ONE * radius
	if _material != null:
		_material.set_shader_parameter(&"strength", clampf(radius / 40.0, 0.0, 1.0))
	visible = radius > 0.05


func clear() -> void:
	radius = 0.0
	visible = false
