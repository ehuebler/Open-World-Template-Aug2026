class_name BossSpaceArenaBoundary
extends MeshInstance3D

## Glowing Euclidean arena shell made from three crossed great-circle ribbons.
## It remains world-fixed while its boss moves inside the arena.

const SHADER := preload(
	"res://game/enemies/bigfoot/bigfoot_arena_boundary.gdshader")

const RING_COUNT := 3
const SEGMENTS := 192
const MIN_HALF_WIDTH := 0.22
const MAX_HALF_WIDTH := 2.4
const WIDTH_SHARE := 0.0035

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
	_material.set_shader_parameter(
		&"line_color", Color(1.0, 0.015, 0.01, 0.88))
	material_override = _material


func configure(center: Vector3, radius: float) -> void:
	if not center.is_finite() or not is_finite(radius) \
			or radius <= MIN_HALF_WIDTH:
		_arena_radius = 0.0
		mesh = null
		visible = false
		return
	_arena_radius = radius
	global_transform = Transform3D(Basis.IDENTITY, center)
	_build_ribbons()


func set_active(active: bool) -> void:
	visible = active and mesh != null


func arena_radius() -> float:
	return _arena_radius


func segment_count() -> int:
	return SEGMENTS


func ring_count() -> int:
	return RING_COUNT


func _build_ribbons() -> void:
	var half_width := clampf(
		_arena_radius * WIDTH_SHARE, MIN_HALF_WIDTH, MAX_HALF_WIDTH)
	var inner := _arena_radius - half_width
	var outer := _arena_radius + half_width
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in RING_COUNT:
		for index in SEGMENTS:
			var share_a := float(index) / float(SEGMENTS)
			var share_b := float(index + 1) / float(SEGMENTS)
			var angle_a := share_a * TAU
			var angle_b := share_b * TAU
			var inner_a := _ring_point(ring, angle_a, inner)
			var outer_a := _ring_point(ring, angle_a, outer)
			var inner_b := _ring_point(ring, angle_b, inner)
			var outer_b := _ring_point(ring, angle_b, outer)
			_add_vertex(surface, inner_a, Vector2(share_a, 0.0))
			_add_vertex(surface, outer_a, Vector2(share_a, 1.0))
			_add_vertex(surface, outer_b, Vector2(share_b, 1.0))
			_add_vertex(surface, inner_a, Vector2(share_a, 0.0))
			_add_vertex(surface, outer_b, Vector2(share_b, 1.0))
			_add_vertex(surface, inner_b, Vector2(share_b, 0.0))
	mesh = surface.commit()


func _add_vertex(
		surface: SurfaceTool, point: Vector3, uv: Vector2) -> void:
	surface.set_uv(uv)
	surface.set_normal(point.normalized())
	surface.add_vertex(point)


func _ring_point(ring: int, angle: float, radius: float) -> Vector3:
	var along := cos(angle) * radius
	var across := sin(angle) * radius
	match ring:
		0:
			return Vector3(along, across, 0.0)
		1:
			return Vector3(along, 0.0, across)
		_:
			return Vector3(0.0, along, across)
