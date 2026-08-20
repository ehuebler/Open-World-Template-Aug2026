class_name SandwormArcModifier
extends SkeletonModifier3D

## Post-animation chain solver. The imported clips keep the animal extended;
## during a leap this modifier lays that chain over the exact replicated attack
## curve, with the head at the current progress and the body trailing behind it.

const CHAIN_BONES := [
	&"Tail", &"Body01", &"Body02", &"Body03", &"Body04",
	&"Body05", &"Body06", &"Neck", &"Head",
]

var _points := PackedVector3Array()
var _distances := PackedFloat32Array()
var _curve_length := 0.0
var _progress := 0.0
var _planet_center := Vector3.ZERO
var _bone_indices := PackedInt32Array()
var _bone_offsets := PackedFloat32Array()
var _body_length := 0.0


func _init() -> void:
	active = false


func set_attack_curve(points: PackedVector3Array, progress: float,
		planet_center: Vector3) -> void:
	_points = points
	_progress = clampf(progress, 0.0, 1.0)
	_planet_center = planet_center
	_distances = PackedFloat32Array()
	_curve_length = 0.0
	if _points.is_empty():
		active = false
		return
	_distances.append(0.0)
	for index in range(1, _points.size()):
		_curve_length += _points[index - 1].distance_to(_points[index])
		_distances.append(_curve_length)
	active = _points.size() >= 2


func clear_attack_curve() -> void:
	active = false


func curve_point_count() -> int:
	return _points.size()


func body_length() -> float:
	return _body_length


func _process_modification() -> void:
	if not active or _points.size() < 2:
		return
	var skeleton := get_skeleton()
	if skeleton == null or not _bind_bones(skeleton):
		return
	var head_distance := _distance_at_progress(_progress)
	var skeleton_from_world := skeleton.global_transform.affine_inverse()
	for index in _bone_indices.size():
		var along := head_distance - (
			_body_length - _bone_offsets[index])
		var point := _sample_distance(along)
		var step := 8.0
		if index + 1 < _bone_offsets.size():
			step = maxf(
				_bone_offsets[index + 1] - _bone_offsets[index], 1.0)
		elif index > 0:
			step = maxf(
				_bone_offsets[index] - _bone_offsets[index - 1], 1.0)
		var next := _sample_distance(along + step)
		var direction := next - point
		if direction.length_squared() < 0.001:
			continue
		var up := point - _planet_center
		if up.length_squared() < 0.001:
			up = Vector3.UP
		var world_pose := Transform3D(
			_basis_with_y(direction, up), point)
		skeleton.set_bone_global_pose(
			_bone_indices[index], skeleton_from_world * world_pose)


func _bind_bones(skeleton: Skeleton3D) -> bool:
	if _bone_indices.size() == CHAIN_BONES.size():
		return true
	_bone_indices = PackedInt32Array()
	_bone_offsets = PackedFloat32Array()
	_body_length = 0.0
	for index in CHAIN_BONES.size():
		var bone := skeleton.find_bone(CHAIN_BONES[index])
		if bone < 0:
			_bone_indices = PackedInt32Array()
			_bone_offsets = PackedFloat32Array()
			return false
		if index > 0:
			_body_length += skeleton.get_bone_rest(bone).origin.length()
		_bone_indices.append(bone)
		_bone_offsets.append(_body_length)
	return true


func _distance_at_progress(progress: float) -> float:
	if _distances.size() < 2:
		return 0.0
	var scaled := clampf(progress, 0.0, 1.0) \
		* float(_distances.size() - 1)
	var first := mini(floori(scaled), _distances.size() - 2)
	var share := scaled - float(first)
	return lerpf(_distances[first], _distances[first + 1], share)


func _sample_distance(distance: float) -> Vector3:
	if distance <= 0.0:
		var direction := (_points[1] - _points[0]).normalized()
		return _points[0] + direction * distance
	if distance >= _curve_length:
		var last := _points.size() - 1
		var direction := (_points[last] - _points[last - 1]).normalized()
		return _points[last] + direction * (distance - _curve_length)
	var high := 1
	while high < _distances.size() and _distances[high] < distance:
		high += 1
	var low := high - 1
	var span := maxf(_distances[high] - _distances[low], 0.0001)
	return _points[low].lerp(
		_points[high], (distance - _distances[low]) / span)


func _basis_with_y(direction: Vector3, up_hint: Vector3) -> Basis:
	var y := direction.normalized()
	var up := up_hint.normalized()
	var z := y.cross(up)
	if z.length_squared() < 0.001:
		var fallback := Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT
		z = y.cross(fallback)
	z = z.normalized()
	var x := y.cross(z).normalized()
	return Basis(x, y, z).orthonormalized()
