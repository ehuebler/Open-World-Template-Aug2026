class_name VolcanoBiome
extends Node3D

## Visible and interactive half of the south-pole volcano.
##
## PlanetField owns the mountain, crater, channels and pool basins because those
## must be part of terrain LOD and collision. This node draws the molten surfaces
## over those basins and answers an analytical liquid query for the player. No
## Area3D is needed, so a fast arrival cannot cross a thin trigger between ticks.

const LAVA_MATERIAL := preload("res://game/planet/volcano_lava.tres")
const POOL_RINGS := 5
const POOL_SPOKES := 64
const FLOW_STEPS := 56
const POOL_SKIRT_MARGIN := 2.0
const FLOW_SKIRT_DEPTH := 4.0

@export_group("Light")
@export var crater_light_range := 150.0
@export var pool_light_range := 82.0
@export var crater_light_energy := 5.2
@export var pool_light_energy := 3.2
@export_range(0.0, 0.5) var light_pulse := 0.08
@export var light_color := Color(1.0, 0.13, 0.015)

@export_group("Interaction")
## The body rides this far into the molten surface. It is enough to read as
## supported by liquid without allowing the player to disappear into it.
@export var surface_sink := 0.24
@export var query_above := 5.0
@export var query_below := 28.0

var _planet: Planet
var _shape: PlanetShape
var _south := Vector3.DOWN
var _east := Vector3.FORWARD
var _north := Vector3.LEFT
var _pools: Array[Dictionary] = []
var _lights: Array[OmniLight3D] = []
var _light_energy := PackedFloat32Array()
var _pulse_time := 0.0


func _ready() -> void:
	add_to_group(&"lava_fields")
	_planet = get_parent() as Planet
	if _planet == null or _planet.shape == null:
		push_error("VolcanoBiome must be a direct child of Planet")
		return
	_shape = _planet.shape
	_shape.prepare()
	if not _shape.volcano_enabled:
		visible = false
		set_process(false)
		return
	_south = _shape.volcano_axis()
	_east = _south.cross(
		Vector3.UP if absf(_south.y) < 0.9 else Vector3.RIGHT).normalized()
	_north = _south.cross(_east).normalized()
	_pools = _shape.volcano_lava_pools()
	_raise_pools()
	_raise_flows()
	_raise_lights()
	_raise_smoke()


func _process(delta: float) -> void:
	_pulse_time += delta
	for index in _lights.size():
		var phase := _pulse_time * (0.83 + float(index) * 0.07) \
			+ float(index) * 1.91
		_lights[index].light_energy = _light_energy[index] \
			* (1.0 + sin(phase) * light_pulse)


## The liquid under or near a world point, or an empty dictionary. [member depth]
## is positive below the surface and negative above it, like PlanetWater.
func lava_sample(global_point: Vector3) -> Dictionary:
	if _planet == null or _shape == null:
		return {}
	var local := _planet.to_local(global_point)
	var span := local.length()
	if span < 1.0:
		return {}
	var direction := local / span
	if _shape.volcano_influence(direction) <= 0.0:
		return {}
	var coordinates := _shape.volcano_coordinates(direction)

	for pool: Dictionary in _pools:
		var relative: Vector2 = coordinates - (pool["offset"] as Vector2)
		var angle := relative.angle()
		var edge := _pool_radius(
			float(pool["radius"]), angle, int(pool["seed"]))
		if relative.length() <= edge:
			var answer := _sample_at(
				global_point, direction, span, float(pool["height"]))
			if not answer.is_empty():
				answer["kind"] = &"crater" if bool(pool["crater"]) else &"pool"
				return answer

	for index in 3:
		var pool: Dictionary = _pools[index + 1]
		var distance := coordinates.length()
		var from := _shape.volcano_crater_radius * 0.45
		var to := float((pool["offset"] as Vector2).length())
		if distance < from or distance > to:
			continue
		var along := inverse_lerp(from, to, distance)
		var centre := _flow_centre(index, distance, along)
		if coordinates.distance_to(centre) > _flow_half_width(index, along):
			continue
		var surface_height := _flow_height(coordinates, pool, along)
		var answer := _sample_at(global_point, direction, span, surface_height)
		if not answer.is_empty():
			answer["kind"] = &"flow"
			return answer
	return {}


func _sample_at(global_point: Vector3, direction: Vector3, span: float,
		height: float) -> Dictionary:
	var surface_radius := _shape.radius + height
	var depth := surface_radius - span
	if depth < -query_above or depth > query_below:
		return {}
	var local_surface := direction * surface_radius
	var world_up := (_planet.global_basis * direction).normalized()
	return {
		"depth": depth,
		"surface": _planet.to_global(local_surface),
		"surface_radius": surface_radius,
		"up": world_up,
		"sink": surface_sink,
		"field": self,
		"point": global_point,
	}


func _raise_pools() -> void:
	for index in _pools.size():
		var pool: Dictionary = _pools[index]
		var instance := MeshInstance3D.new()
		instance.name = "CraterLake" if index == 0 else "LowerPool%d" % index
		instance.mesh = _pool_mesh(pool)
		instance.material_override = LAVA_MATERIAL
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(instance, false, Node.INTERNAL_MODE_BACK)


func _raise_flows() -> void:
	for index in 3:
		var instance := MeshInstance3D.new()
		instance.name = "LavaFlow%d" % (index + 1)
		instance.mesh = _flow_mesh(index, _pools[index + 1])
		instance.material_override = LAVA_MATERIAL
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(instance, false, Node.INTERNAL_MODE_BACK)


func _pool_mesh(pool: Dictionary) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var centre: Vector2 = pool["offset"]
	var height := float(pool["height"])
	var radius_now := float(pool["radius"])
	var seed := int(pool["seed"])
	vertices.append(_point_at(centre, height))
	normals.append(_direction_at(centre))
	uvs.append(Vector2(0.5, 0.5))

	for ring in range(1, POOL_RINGS + 1):
		var share := float(ring) / float(POOL_RINGS)
		for spoke in POOL_SPOKES:
			var angle := TAU * float(spoke) / float(POOL_SPOKES)
			var edge := _pool_radius(radius_now, angle, seed)
			var offset := centre + Vector2(cos(angle), sin(angle)) * edge * share
			vertices.append(_point_at(offset, height))
			normals.append(_direction_at(offset))
			uvs.append(Vector2(0.5, 0.5)
				+ Vector2(cos(angle), sin(angle)) * share * 0.5)

	# The terrain now rises to this exact irregular shoreline, which is the real
	# fix for seeing beneath a surface-only pool. Keep a buried side skirt as
	# overlap for terrain LOD: a coarse triangle can cross the analytical bank a
	# little below the liquid before its finer replacement arrives.
	var skirt_top := vertices.size()
	var skirt_depth := maxf(
		_shape.volcano_pool_depth + POOL_SKIRT_MARGIN, POOL_SKIRT_MARGIN)
	for spoke in POOL_SPOKES:
		var angle := TAU * float(spoke) / float(POOL_SPOKES)
		var edge := _pool_radius(radius_now, angle, seed)
		var offset := centre + Vector2(cos(angle), sin(angle)) * edge
		var up := _direction_at(offset)
		var outward := _surface_tangent(
			up, Vector2(cos(angle), sin(angle)))
		vertices.append(_point_at(offset, height))
		normals.append(outward)
		uvs.append(Vector2(float(spoke) / float(POOL_SPOKES), 0.0))
	var skirt_bottom := vertices.size()
	for spoke in POOL_SPOKES:
		var angle := TAU * float(spoke) / float(POOL_SPOKES)
		var edge := _pool_radius(radius_now, angle, seed)
		var offset := centre + Vector2(cos(angle), sin(angle)) * edge
		var up := _direction_at(offset)
		vertices.append(_point_at(offset, height - skirt_depth))
		normals.append(_surface_tangent(
			up, Vector2(cos(angle), sin(angle))))
		uvs.append(Vector2(float(spoke) / float(POOL_SPOKES), 1.0))

	var indices := PackedInt32Array()
	for spoke in POOL_SPOKES:
		indices.append(0)
		indices.append(1 + spoke)
		indices.append(1 + (spoke + 1) % POOL_SPOKES)
	for ring in range(POOL_RINGS - 1):
		var inner := 1 + ring * POOL_SPOKES
		var outer := inner + POOL_SPOKES
		for spoke in POOL_SPOKES:
			var next := (spoke + 1) % POOL_SPOKES
			indices.append(inner + spoke)
			indices.append(outer + spoke)
			indices.append(inner + next)
			indices.append(inner + next)
			indices.append(outer + spoke)
			indices.append(outer + next)
	for spoke in POOL_SPOKES:
		var next := (spoke + 1) % POOL_SPOKES
		indices.append(skirt_top + spoke)
		indices.append(skirt_bottom + spoke)
		indices.append(skirt_top + next)
		indices.append(skirt_top + next)
		indices.append(skirt_bottom + spoke)
		indices.append(skirt_bottom + next)
	return _array_mesh(vertices, normals, uvs, indices)


func _flow_mesh(index: int, pool: Dictionary) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var edge_offsets := PackedVector2Array()
	var edge_heights := PackedFloat32Array()
	var edge_normals := PackedVector3Array()
	var from := _shape.volcano_crater_radius * 0.45
	var to := float((pool["offset"] as Vector2).length())
	for step in FLOW_STEPS:
		var along := float(step) / float(FLOW_STEPS - 1)
		var distance := lerpf(from, to, along)
		var centre := _flow_centre(index, distance, along)
		var before := _flow_centre(index, maxf(from, distance - 2.0), along)
		var after := _flow_centre(index, minf(to, distance + 2.0), along)
		var side := (after - before).normalized().orthogonal()
		var half_width := _flow_half_width(index, along)
		for edge_index in 2:
			var edge := -1.0 if edge_index == 0 else 1.0
			var offset: Vector2 = centre + side * half_width * edge
			var height := _flow_height(offset, pool, along)
			var up := _direction_at(offset)
			vertices.append(_point_at(offset, height))
			normals.append(up)
			uvs.append(Vector2((edge + 1.0) * 0.5, along * 8.0))
			edge_offsets.append(offset)
			edge_heights.append(height)
			edge_normals.append(_surface_tangent(up, side * edge))

	var indices := PackedInt32Array()
	for step in range(FLOW_STEPS - 1):
		var at := step * 2
		indices.append(at)
		indices.append(at + 2)
		indices.append(at + 1)
		indices.append(at + 1)
		indices.append(at + 2)
		indices.append(at + 3)
	# The moving sheet rides just above its analytical channel. Side skirts hide
	# that clearance without changing the liquid height used by the player.
	var skirt_top := vertices.size()
	for edge_index in edge_offsets.size():
		vertices.append(_point_at(
			edge_offsets[edge_index], edge_heights[edge_index]))
		normals.append(edge_normals[edge_index])
		uvs.append(Vector2(
			float(edge_index % 2), float(edge_index / 2) * 0.25))
	var skirt_bottom := vertices.size()
	for edge_index in edge_offsets.size():
		vertices.append(_point_at(
			edge_offsets[edge_index],
			edge_heights[edge_index] - FLOW_SKIRT_DEPTH))
		normals.append(edge_normals[edge_index])
		uvs.append(Vector2(
			float(edge_index % 2), float(edge_index / 2) * 0.25 + 1.0))
	for step in range(FLOW_STEPS - 1):
		for edge_index in 2:
			var here := step * 2 + edge_index
			var after := (step + 1) * 2 + edge_index
			indices.append(skirt_top + here)
			indices.append(skirt_bottom + here)
			indices.append(skirt_top + after)
			indices.append(skirt_top + after)
			indices.append(skirt_bottom + here)
			indices.append(skirt_bottom + after)
	return _array_mesh(vertices, normals, uvs, indices)


func _array_mesh(vertices: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _raise_lights() -> void:
	for index in _pools.size():
		var pool: Dictionary = _pools[index]
		var light := OmniLight3D.new()
		light.name = "CraterGlow" if index == 0 else "PoolGlow%d" % index
		light.light_color = light_color
		light.light_energy = crater_light_energy if index == 0 else pool_light_energy
		light.omni_range = crater_light_range if index == 0 else pool_light_range
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = light.omni_range * 2.0
		light.distance_fade_length = light.omni_range
		light.position = _point_at(
			pool["offset"] as Vector2, float(pool["height"]) + 5.0)
		add_child(light, false, Node.INTERNAL_MODE_BACK)
		_lights.append(light)
		_light_energy.append(light.light_energy)


func _raise_smoke() -> void:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = _shape.volcano_crater_radius * 0.18
	process.direction = Vector3.UP
	process.spread = 24.0
	process.initial_velocity_min = 11.0
	process.initial_velocity_max = 24.0
	process.gravity = Vector3(0.0, 1.7, 0.0)
	process.damping_min = 0.28
	process.damping_max = 0.72
	process.scale_min = 9.0
	process.scale_max = 27.0
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.08, 0.62, 1.0])
	fade.colors = PackedColorArray([
		Color(0.16, 0.12, 0.12, 0.0),
		Color(0.12, 0.085, 0.085, 0.72),
		Color(0.075, 0.06, 0.065, 0.4),
		Color(0.055, 0.05, 0.06, 0.0),
	])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp

	var smoke := GPUParticles3D.new()
	smoke.name = "CalderaPlume"
	smoke.amount = 76
	smoke.lifetime = 13.0
	smoke.preprocess = 13.0
	smoke.randomness = 0.72
	smoke.local_coords = true
	smoke.fixed_fps = 24
	smoke.visibility_aabb = AABB(
		Vector3(-260.0, -50.0, -260.0), Vector3(520.0, 540.0, 520.0))
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smoke.process_material = process
	smoke.draw_pass_1 = _smoke_quad()
	smoke.position = _point_at(
		Vector2.ZERO, _shape.volcano_crater_lava_height + 16.0)
	smoke.basis = Basis(_east, _south, -_north).orthonormalized()
	add_child(smoke, false, Node.INTERNAL_MODE_BACK)


func _smoke_quad() -> QuadMesh:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var point := (Vector2(x, y) + Vector2(0.5, 0.5)) / 64.0 \
				* 2.0 - Vector2.ONE
			var radius_now := point.length()
			var billow := 0.82 + sin(point.x * 9.0 + point.y * 5.0) * 0.055 \
				+ sin(point.x * 17.0 - point.y * 13.0) * 0.035
			var alpha := 1.0 - smoothstep(0.34, billow, radius_now)
			alpha *= smoothstep(1.0, 0.42, radius_now)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	var texture := ImageTexture.create_from_image(image)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = texture
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.disable_receive_shadows = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = material
	return quad


func _pool_radius(base: float, angle: float, seed: int) -> float:
	return _shape.volcano_pool_radius(base, angle, seed)


func _flow_centre(index: int, distance: float, along: float) -> Vector2:
	var angle := _shape.volcano_flow_angles[index]
	var forward := Vector2(cos(angle), sin(angle))
	var side := forward.orthogonal()
	var wander := sin(along * TAU * (1.12 + float(index) * 0.17)
		+ float(index) * 2.13) * (7.0 + along * 11.0) * sin(along * PI)
	return forward * distance + side * wander


func _flow_half_width(index: int, along: float) -> float:
	return lerpf(26.0, 15.0 + float(index) * 2.0, along) \
		* (0.88 + sin(along * TAU * 2.4 + float(index)) * 0.12)


func _flow_height(offset: Vector2, pool: Dictionary, along: float) -> float:
	var direction := _direction_at(offset)
	var ground := _shape.elevation(direction, 0.0) + 0.85
	var distance := offset.length()
	var from_lake := 1.0 - smoothstep(
		_shape.volcano_crater_radius * 0.48,
		_shape.volcano_crater_radius * 1.08, distance)
	var height := lerpf(ground, _shape.volcano_crater_lava_height + 0.15, from_lake)
	var into_pool := smoothstep(0.82, 1.0, along)
	return lerpf(height, float(pool["height"]) + 0.18, into_pool)


func _direction_at(offset: Vector2) -> Vector3:
	var distance := offset.length()
	if distance < 0.0001:
		return _south
	var tangent := (_east * offset.x + _north * offset.y) / distance
	var angle := distance / maxf(_shape.radius, 1.0)
	return (_south * cos(angle) + tangent * sin(angle)).normalized()


func _point_at(offset: Vector2, height: float) -> Vector3:
	return _direction_at(offset) * (_shape.radius + height)


func _surface_tangent(up: Vector3, direction: Vector2) -> Vector3:
	var tangent := _east * direction.x + _north * direction.y
	tangent -= up * tangent.dot(up)
	return tangent.normalized()
