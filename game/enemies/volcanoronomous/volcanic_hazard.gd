class_name VolcanicHazard
extends Node3D

## One deterministic warning/impact used by the caldera trial. The host applies
## damage when [signal resolved] fires; every peer runs the same short visual.

signal resolved(kind: int, at: Vector3)

enum Kind {
	FIRE_SPOUT,
	LAVA_BALL,
}

const SPOUT_WARNING := 0.82
const SPOUT_LIFETIME := 1.72
## Long enough to read while sprinting, with multiple balls visible in flight.
const BALL_FALL := 2.25
const BALL_LIFETIME := 2.82
const BALL_HEIGHT := 96.0

var kind := Kind.FIRE_SPOUT
var _age := 0.0
var _fired := false
var _warning: MeshInstance3D
var _pillar: MeshInstance3D
var _ball: MeshInstance3D
var _particles: GPUParticles3D
var _ball_start := Vector3.UP * BALL_HEIGHT


func configure(hazard_kind: int, at: Vector3, up: Vector3, seed: int,
		launch_point := Vector3.ZERO) -> void:
	add_to_group(&"volcanic_hazards")
	kind = clampi(hazard_kind, Kind.FIRE_SPOUT, Kind.LAVA_BALL)
	name = "FireSpout" if kind == Kind.FIRE_SPOUT else "LavaBall"
	top_level = true
	var normal := up.normalized() if up.length_squared() > 0.5 else Vector3.UP
	global_transform = Transform3D(_upright(normal, seed), at)
	if kind == Kind.LAVA_BALL and launch_point.is_finite() \
			and launch_point.distance_squared_to(at) > 1.0:
		_ball_start = global_transform.affine_inverse() * launch_point
	_build_warning()
	if kind == Kind.FIRE_SPOUT:
		_build_spout()
	else:
		_build_ball()


func _process(delta: float) -> void:
	_age += delta
	if kind == Kind.FIRE_SPOUT:
		_tick_spout()
	else:
		_tick_ball()


func _tick_spout() -> void:
	var warning_share := clampf(_age / SPOUT_WARNING, 0.0, 1.0)
	if _warning != null:
		_warning.visible = _age < SPOUT_WARNING
		var pulse := 0.90 + warning_share * 0.55 \
			+ sin(_age * 28.0) * (0.04 + warning_share * 0.08)
		_warning.scale = Vector3(pulse, 1.0, pulse)
	if _age >= SPOUT_WARNING and not _fired:
		_fired = true
		if _particles != null:
			_particles.restart()
		resolved.emit(kind, global_position)
	if _pillar != null:
		_pillar.visible = _age >= SPOUT_WARNING
		if _pillar.visible:
			var live := clampf((_age - SPOUT_WARNING) / 0.18, 0.0, 1.0)
			var fade := 1.0 - clampf(
				(_age - SPOUT_WARNING - 0.42) / 0.42, 0.0, 1.0)
			_pillar.scale = Vector3(
				0.70 + live * 0.55, maxf(live * fade, 0.02),
				0.70 + live * 0.55)
	if _age >= SPOUT_LIFETIME:
		queue_free()


func _tick_ball() -> void:
	var share := clampf(_age / BALL_FALL, 0.0, 1.0)
	if _warning != null:
		var pulse := 0.85 + share * 0.62 + sin(_age * 24.0) * 0.07
		_warning.scale = Vector3(pulse, 1.0, pulse)
		_warning.visible = share < 1.0
	if _ball != null:
		# Start high and farther down the runner's forward lane, then accelerate
		# into the predicted impact point. It remains visibly in front throughout.
		_ball.position = _ball_start * (1.0 - share * share)
		_ball.visible = share < 1.0
		var spin := _age * 5.8
		_ball.rotation = Vector3(spin * 0.72, spin, spin * 0.38)
	if share >= 1.0 and not _fired:
		_fired = true
		if _particles != null:
			_particles.position = Vector3.ZERO
			_particles.restart()
		resolved.emit(kind, global_position)
	if _age >= BALL_LIFETIME:
		queue_free()


func _build_warning() -> void:
	_warning = MeshInstance3D.new()
	_warning.name = "WarningRing"
	var torus := TorusMesh.new()
	torus.inner_radius = 3.0 if kind == Kind.FIRE_SPOUT else 5.2
	torus.outer_radius = 3.36 if kind == Kind.FIRE_SPOUT else 5.72
	torus.rings = 8
	torus.ring_segments = 36
	torus.material = _emissive(
		Color(1.0, 0.055, 0.01, 0.84), 3.4, true)
	_warning.mesh = torus
	_warning.position.y = 0.16
	_warning.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_warning)


func _build_spout() -> void:
	_pillar = MeshInstance3D.new()
	_pillar.name = "FlameColumn"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.55
	cone.bottom_radius = 2.35
	cone.height = 17.0
	cone.radial_segments = 10
	cone.rings = 1
	cone.material = _emissive(Color(1.0, 0.16, 0.015, 0.64), 4.8, true)
	_pillar.mesh = cone
	_pillar.position.y = cone.height * 0.5
	_pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pillar.visible = false
	add_child(_pillar)
	_particles = _eruption_particles(96, 1.05, 18.0, 39.0, 0.55, 1.8)
	add_child(_particles)


func _build_ball() -> void:
	_ball = MeshInstance3D.new()
	_ball.name = "FallingLava"
	var sphere := SphereMesh.new()
	sphere.radius = 2.6
	sphere.height = 5.2
	sphere.radial_segments = 20
	sphere.rings = 12
	sphere.material = _emissive(Color(1.0, 0.29, 0.018), 8.0, false)
	_ball.mesh = sphere
	_ball.position = _ball_start
	_ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ball)

	var halo := MeshInstance3D.new()
	halo.name = "FireHalo"
	var halo_sphere := SphereMesh.new()
	halo_sphere.radius = 3.8
	halo_sphere.height = 7.6
	halo_sphere.radial_segments = 16
	halo_sphere.rings = 9
	halo_sphere.material = _emissive(
		Color(1.0, 0.10, 0.005, 0.34), 6.2, true)
	halo.mesh = halo_sphere
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ball.add_child(halo)
	_particles = _eruption_particles(76, 0.68, 7.0, 22.0, 0.28, 1.0)
	_particles.emitting = false
	add_child(_particles)


func _eruption_particles(amount: int, lifetime: float, speed_min: float,
		speed_max: float, scale_min: float, scale_max: float) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "Eruption"
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 0.92
	particles.randomness = 0.52
	particles.local_coords = true
	particles.emitting = false
	particles.visibility_aabb = AABB(
		Vector3(-18.0, -3.0, -18.0), Vector3(36.0, 42.0, 36.0))
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 2.0
	process.direction = Vector3.UP
	process.spread = 38.0 if kind == Kind.FIRE_SPOUT else 82.0
	process.initial_velocity_min = speed_min
	process.initial_velocity_max = speed_max
	process.gravity = Vector3(0.0, -18.0, 0.0)
	process.damping_min = 0.2
	process.damping_max = 0.7
	process.scale_min = scale_min
	process.scale_max = scale_max
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.28, 0.72, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 0.78, 0.12, 1.0),
		Color(1.0, 0.18, 0.015, 0.95),
		Color(0.34, 0.055, 0.018, 0.66),
		Color(0.08, 0.045, 0.035, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.48, 0.48)
	var material := _emissive(Color(1.0, 0.22, 0.025, 0.86), 2.8, true)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = material
	particles.draw_pass_1 = quad
	return particles


func _emissive(tint: Color, energy: float,
		transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = Color(tint.r, tint.g, tint.b)
	material.emission_energy_multiplier = energy
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.no_depth_test = false
	return material


func _upright(up: Vector3, seed: int) -> Basis:
	var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - up * hint.dot(up)).normalized()
	var basis := Basis(up.cross(forward), up, -forward)
	return Basis(up, float(posmod(seed, 360)) * PI / 180.0) * basis
