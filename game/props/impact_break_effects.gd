class_name ImpactBreakEffects
extends Node3D

## A fixed pool of short GPU debris bursts shared by flora and fauna impacts.
##
## Breakable plants are MultiMesh instances, not nodes, so attaching one emitter
## to every plant would undo the entire batching model. Call [method play_break]
## only when an impact actually destroys something; the next free slot is moved
## to that point, recoloured, restarted, and reused after its brief lifetime.

enum Preset { ORGANIC, WOOD, CRYSTAL }

@export_range(4, 48) var pool_size := 20
@export_range(8, 64) var maximum_fragments := 44

var _bursts: Array[GPUParticles3D] = []
var _processes: Array[ParticleProcessMaterial] = []
var _cursor := 0
var _fragment_mesh: BoxMesh
var _fade: GradientTexture1D


func _ready() -> void:
	add_to_group(&"impact_break_effects")
	_fragment_mesh = _make_fragment_mesh()
	_fade = _make_fade()
	for index in pool_size:
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
		process.direction = Vector3.UP
		process.spread = 118.0
		process.color_ramp = _fade
		process.angular_velocity_min = -420.0
		process.angular_velocity_max = 420.0
		var burst := GPUParticles3D.new()
		burst.name = "BreakBurst%d" % index
		burst.amount = 20
		burst.lifetime = 0.8
		burst.one_shot = true
		burst.explosiveness = 1.0
		burst.local_coords = false
		burst.fixed_fps = 30
		burst.draw_order = GPUParticles3D.DRAW_ORDER_LIFETIME
		burst.visibility_aabb = AABB(
			Vector3(-35.0, -35.0, -35.0), Vector3.ONE * 70.0)
		burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		burst.process_material = process
		burst.draw_pass_1 = _fragment_mesh
		burst.emitting = false
		add_child(burst, false, Node.INTERNAL_MODE_BACK)
		_processes.append(process)
		_bursts.append(burst)


## Throw one coloured debris burst from a destroyed instance.
##
## [param up] is radial planet-up at the impact. [param strength] is impact
## speed in m/s, and [param size] is the destroyed instance's visual height.
## Both are clamped before reaching particle counts or velocity, so a
## skyscraper struck at flight speed cannot turn one burst into a frame spike.
func play_break(at: Vector3, up: Vector3, strength: float, size: float,
		tint: Color, preset: int = Preset.ORGANIC) -> void:
	if _bursts.is_empty() or not at.is_finite():
		return
	var slot := _cursor
	_cursor = (_cursor + 1) % _bursts.size()
	var burst := _bursts[slot]
	var process := _processes[slot]
	var outward := up.normalized() if up.length_squared() > 0.0001 \
		else Vector3.UP
	var visual_size := clampf(size, 0.2, 8.0)
	var energy := clampf(strength, 4.0, 120.0)

	var colour := tint
	if colour.a <= 0.0:
		colour = Color(0.46, 0.27, 0.13, 1.0)
	colour.a = 1.0
	process.color = colour
	process.emission_sphere_radius = clampf(visual_size * 0.12, 0.08, 1.4)
	process.initial_velocity_min = 1.6 + energy * 0.045
	process.initial_velocity_max = 3.0 + energy * 0.11
	process.gravity = -outward * float(ProjectSettings.get_setting(
		"physics/3d/default_gravity", 24.0))
	process.damping_min = 0.8
	process.damping_max = 2.0
	process.scale_min = clampf(0.22 + visual_size * 0.045, 0.22, 0.62)
	process.scale_max = clampf(0.52 + visual_size * 0.09, 0.52, 1.25)

	match preset:
		Preset.WOOD:
			process.spread = 105.0
			process.damping_min = 0.55
			process.damping_max = 1.4
			process.scale_max *= 1.18
			burst.lifetime = 0.95
		Preset.CRYSTAL:
			process.spread = 132.0
			process.initial_velocity_min *= 1.18
			process.initial_velocity_max *= 1.28
			process.scale_min *= 0.72
			process.scale_max *= 0.8
			burst.lifetime = 1.05
		_:
			process.spread = 118.0
			process.damping_min = 1.0
			process.damping_max = 2.4
			burst.lifetime = 0.72

	burst.amount = clampi(
		10 + int(energy * 0.18 + sqrt(visual_size) * 6.0),
		10, maximum_fragments)
	var side := outward.cross(
		Vector3.UP if absf(outward.y) < 0.9 else Vector3.RIGHT).normalized()
	burst.global_transform = Transform3D(
		Basis(side, outward, side.cross(outward)).orthonormalized(), at)
	burst.restart()
	burst.emitting = true


func _make_fragment_mesh() -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.34, 0.075)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.roughness = 0.76
	material.metallic = 0.0
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	mesh.material = material
	return mesh


func _make_fade() -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.08, 0.72, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color.WHITE,
		Color.WHITE,
		Color(1.0, 1.0, 1.0, 0.0),
	])
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture
