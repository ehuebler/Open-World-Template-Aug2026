class_name BigfootArenaBoundary
extends MeshInstance3D

## Terrain-following combat boundary for Bigfoot's arena.
##
## The arena is measured as an arc around its fixed landmark, so a flat ring
## would float on one side of the planet and sink on the other. This ribbon uses
## the same band-limited height field as the terrain mesh and samples both of its
## edges around the corresponding small circle on the sphere.

const SHADER := preload(
	"res://game/enemies/bigfoot/bigfoot_arena_boundary.gdshader")

const SEGMENTS := 256
const HALF_WIDTH := 0.70
const GROUND_LIFT := 0.18

var _planet: Planet
var _centre_direction := Vector3.UP
var _arena_radius := 0.0
var _material: ShaderMaterial


func _init() -> void:
	name = "ArenaBoundary"
	top_level = true
	visible = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 8.0


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter(&"line_color", Color(1.0, 0.015, 0.01, 0.86))
	material_override = _material


func configure(planet: Planet, centre_direction: Vector3,
		arena_radius: float) -> void:
	if planet == null or planet.shape == null \
			or centre_direction.length_squared() < 0.5 \
			or arena_radius <= HALF_WIDTH:
		_planet = null
		_arena_radius = 0.0
		mesh = null
		visible = false
		return
	_planet = planet
	_centre_direction = centre_direction.normalized()
	_arena_radius = arena_radius
	global_transform = planet.global_transform
	_build_ribbon()


func set_active(active: bool) -> void:
	visible = active and mesh != null


func arena_radius() -> float:
	return _arena_radius


func segment_count() -> int:
	return SEGMENTS


func _build_ribbon() -> void:
	if _planet == null or _planet.shape == null:
		mesh = null
		return
	var shape := _planet.shape
	var spacing := _planet.finest_spacing()
	var hint := Vector3.UP if absf(_centre_direction.y) < 0.9 \
		else Vector3.RIGHT
	var east := _centre_direction.cross(hint).normalized()
	var north := _centre_direction.cross(east).normalized()
	var inner_angle := maxf(_arena_radius - HALF_WIDTH, 0.0) / shape.radius
	var outer_angle := (_arena_radius + HALF_WIDTH) / shape.radius

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index in SEGMENTS + 1:
		var share := float(index) / float(SEGMENTS)
		var angle := share * TAU
		var radial := east * cos(angle) + north * sin(angle)
		var inner_direction := (
			_centre_direction * cos(inner_angle)
			+ radial * sin(inner_angle)
		).normalized()
		var outer_direction := (
			_centre_direction * cos(outer_angle)
			+ radial * sin(outer_angle)
		).normalized()

		surface.set_uv(Vector2(share, 0.0))
		surface.set_normal(inner_direction)
		surface.add_vertex(
			shape.surface_point(inner_direction, spacing)
			+ inner_direction * GROUND_LIFT)
		surface.set_uv(Vector2(share, 1.0))
		surface.set_normal(outer_direction)
		surface.add_vertex(
			shape.surface_point(outer_direction, spacing)
			+ outer_direction * GROUND_LIFT)
	mesh = surface.commit()
