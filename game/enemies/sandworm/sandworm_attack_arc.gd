class_name SandwormAttackArc
extends MeshInstance3D

## Bright crossed-ribbon preview of the replicated bite path. Two ribbons keep
## the trajectory legible from the side, above, or directly down the launch.

const HALF_WIDTH := 2.5
const PURPLE := Color(0.69, 0.16, 1.0, 0.86)

var _point_count := 0
var _first := Vector3.INF
var _middle := Vector3.INF
var _last := Vector3.INF


func _init() -> void:
	name = "AttackArc"
	top_level = true
	visible = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 5000.0
	var material := StandardMaterial3D.new()
	material.albedo_color = PURPLE
	material.emission_enabled = true
	material.emission = Color(PURPLE.r, PURPLE.g, PURPLE.b)
	material.emission_energy_multiplier = 5.0
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = material


func set_attack_curve(points: PackedVector3Array,
		planet_center: Vector3) -> void:
	if points.size() < 2:
		clear_attack_curve()
		return
	var middle := points[points.size() / 2]
	if _point_count == points.size() \
			and _first.distance_squared_to(points[0]) < 0.0001 \
			and _middle.distance_squared_to(middle) < 0.0001 \
			and _last.distance_squared_to(points[-1]) < 0.0001:
		visible = true
		return
	_point_count = points.size()
	_first = points[0]
	_middle = middle
	_last = points[-1]
	global_transform = Transform3D.IDENTITY
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(points.size() - 1):
		var from := points[index]
		var to := points[index + 1]
		var tangent := to - from
		if tangent.length_squared() < 0.001:
			continue
		tangent = tangent.normalized()
		var up := ((from + to) * 0.5 - planet_center).normalized()
		var side := tangent.cross(up)
		if side.length_squared() < 0.001:
			var fallback := Vector3.UP \
				if absf(tangent.y) < 0.9 else Vector3.RIGHT
			side = tangent.cross(fallback)
		side = side.normalized()
		var second := tangent.cross(side).normalized()
		_add_quad(surface, from, to, side * HALF_WIDTH)
		_add_quad(surface, from, to, second * HALF_WIDTH)
	mesh = surface.commit()
	visible = mesh != null


func clear_attack_curve() -> void:
	_point_count = 0
	_first = Vector3.INF
	_middle = Vector3.INF
	_last = Vector3.INF
	visible = false
	mesh = null


func point_count() -> int:
	return _point_count


func line_color() -> Color:
	return PURPLE


func _add_quad(surface: SurfaceTool, from: Vector3, to: Vector3,
		across: Vector3) -> void:
	surface.add_vertex(from - across)
	surface.add_vertex(to - across)
	surface.add_vertex(to + across)
	surface.add_vertex(from - across)
	surface.add_vertex(to + across)
	surface.add_vertex(from + across)
