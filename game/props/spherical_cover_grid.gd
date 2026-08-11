class_name SphericalCoverGrid
extends RefCounted

## Stable square keys over a sphere, using the six faces of a cube.
##
## Terrain has its own quadtree, but ground cover must not inherit those LOD
## swaps: grass density is based on metres and stays the same while terrain
## parents split underneath it. This grid only supplies deterministic keys and
## directions; GroundCover still owns streaming and MultiMeshes.

const POS_X := 0
const NEG_X := 1
const POS_Y := 2
const NEG_Y := 3
const POS_Z := 4
const NEG_Z := 5

var radius := 1.0
var resolution := 8


func _init(planet_radius: float, metres_per_cell: float) -> void:
	radius = maxf(planet_radius, 1.0)
	# A cube face is two radii wide at its centre.
	resolution = maxi(8, ceili(2.0 * radius / maxf(metres_per_cell, 1.0)))


func key_for(direction: Vector3) -> Vector3i:
	var at := direction.normalized()
	var absolute := at.abs()
	var face := POS_X
	var u := 0.0
	var v := 0.0
	if absolute.x >= absolute.y and absolute.x >= absolute.z:
		if at.x >= 0.0:
			face = POS_X
			u = -at.z / absolute.x
			v = at.y / absolute.x
		else:
			face = NEG_X
			u = at.z / absolute.x
			v = at.y / absolute.x
	elif absolute.y >= absolute.z:
		if at.y >= 0.0:
			face = POS_Y
			u = at.x / absolute.y
			v = -at.z / absolute.y
		else:
			face = NEG_Y
			u = at.x / absolute.y
			v = at.z / absolute.y
	else:
		if at.z >= 0.0:
			face = POS_Z
			u = at.x / absolute.z
			v = at.y / absolute.z
		else:
			face = NEG_Z
			u = -at.x / absolute.z
			v = at.y / absolute.z
	return Vector3i(face, _coordinate(u), _coordinate(v))


func direction_in(key: Vector3i, across: float, down: float) -> Vector3:
	var u := -1.0 + 2.0 * (float(key.y) + across) / float(resolution)
	var v := -1.0 + 2.0 * (float(key.z) + down) / float(resolution)
	match key.x:
		POS_X:
			return Vector3(1.0, v, -u).normalized()
		NEG_X:
			return Vector3(-1.0, v, u).normalized()
		POS_Y:
			return Vector3(u, 1.0, -v).normalized()
		NEG_Y:
			return Vector3(u, -1.0, v).normalized()
		POS_Z:
			return Vector3(u, v, 1.0).normalized()
		_:
			return Vector3(-u, v, -1.0).normalized()


func centre(key: Vector3i) -> Vector3:
	return direction_in(key, 0.5, 0.5)


## Chord-area of the two triangles making the projected cell. At cube corners
## it is smaller than at face centres; using this instead of tile_size² keeps
## grass density per square metre stable over the whole planet.
func area(key: Vector3i) -> float:
	var a := direction_in(key, 0.0, 0.0) * radius
	var b := direction_in(key, 1.0, 0.0) * radius
	var c := direction_in(key, 1.0, 1.0) * radius
	var d := direction_in(key, 0.0, 1.0) * radius
	return 0.5 * (b - a).cross(c - a).length() \
		+ 0.5 * (c - a).cross(d - a).length()


func _coordinate(value: float) -> int:
	return clampi(floori((clampf(value, -1.0, 1.0) + 1.0)
		* 0.5 * float(resolution)), 0, resolution - 1)
