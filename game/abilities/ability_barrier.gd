class_name AbilityBarrier
extends StaticBody3D

## Indestructible layer-one collision with a locally animated translucent shell.
## Lifetime is replicated at spawn; GameWorld also snapshots the remaining time
## for peers that join while a wall is still standing.

signal expired(construct_id: int)

var construct_id := 0
var owner_peer := 0
var ability_id := "wall"
var _size := Vector3(8.0, 4.0, 0.35)
var _duration := 7.0
var _fade_duration := 4.0
var _age := 0.0
var _tint := Color(0.27, 0.69, 1.0)
var _initial_alpha := 0.52
var _material: StandardMaterial3D
var _collision: CollisionShape3D


static func create(world: Node, id: int, source_peer: int,
		at: Transform3D, size: Vector3, duration: float,
		fade_duration: float, tint: Color,
		initial_alpha := 0.52) -> AbilityBarrier:
	if world == null or id <= 0 or not at.is_finite() or not size.is_finite():
		return null
	var barrier := AbilityBarrier.new()
	barrier.name = "AbilityWall_%d" % id
	barrier.construct_id = id
	barrier.owner_peer = maxi(source_peer, 0)
	barrier._size = Vector3(
		maxf(size.x, 0.2), maxf(size.y, 0.2), maxf(size.z, 0.05))
	barrier._duration = clampf(duration, 0.2, 30.0)
	barrier._fade_duration = clampf(
		fade_duration, 0.0, barrier._duration)
	barrier._tint = tint
	barrier._initial_alpha = clampf(initial_alpha, 0.0, 0.52)
	world.add_child(barrier)
	barrier.global_transform = at
	return barrier


func _ready() -> void:
	collision_layer = 1
	collision_mask = 1
	add_to_group(&"ability_barriers")
	var shape := BoxShape3D.new()
	shape.size = _size
	_collision = CollisionShape3D.new()
	_collision.shape = shape
	add_child(_collision)

	var mesh := BoxMesh.new()
	mesh.size = _size
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = Color(_tint, _initial_alpha)
	_material.emission_enabled = true
	_material.emission = _tint
	_material.emission_energy_multiplier = 1.8
	_material.disable_receive_shadows = true
	mesh.material = _material
	var visual := MeshInstance3D.new()
	visual.mesh = mesh
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)


func _process(delta: float) -> void:
	_age += delta
	var fade_start := _duration - _fade_duration
	var alpha := _initial_alpha
	if _fade_duration > 0.0 and _age > fade_start:
		var share := clampf(
			(_age - fade_start) / _fade_duration, 0.0, 1.0)
		alpha = _initial_alpha * pow(1.0 - share, 1.35)
	var colour := _tint
	colour.a = alpha
	_material.albedo_color = colour
	_material.emission_energy_multiplier = 0.7 + alpha * 2.2
	if _age < _duration:
		return
	if _collision != null:
		_collision.set_deferred(&"disabled", true)
	expired.emit(construct_id)
	queue_free()


func remaining() -> float:
	return maxf(_duration - _age, 0.0)


func fade_duration() -> float:
	return minf(_fade_duration, remaining())


func size() -> Vector3:
	return _size


func tint() -> Color:
	return _tint


func current_alpha() -> float:
	return _material.albedo_color.a if _material != null else _initial_alpha
