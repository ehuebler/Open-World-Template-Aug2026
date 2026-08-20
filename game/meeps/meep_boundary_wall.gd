class_name MeepBoundaryWall
extends MultiMeshInstance3D

## The low purple wall the Meeps run around the edge of their town.
##
## One instance per boundary cell edge, which is a few hundred posts for a hundred
## metre claim and one draw call for all of them. A [MultiMesh] rather than a
## welded [ArrayMesh] because the boundary is not finished: every time the town
## grows the wall is the same mesh with more instances in it, and a buffer that
## gets longer is cheaper than geometry that gets rebuilt.
##
## It is a marker and not a barrier. Nothing collides with it — players walk in and
## out, and so do the mobs the colony has to be defended from. What it is for is
## being able to see, from outside, where the town thinks it ends.

## Metres tall. Knee height on a Meep: enough to read as a wall from inside the
## town and from the air, low enough not to hide the town behind it.
const HEIGHT := 0.6
const THICKNESS := 0.35
## How far the base is pushed under the ground, so a wall crossing a slope has no
## daylight beneath it.
const SINK := 0.22
const PURPLE := Color(0.45, 0.20, 0.72)

var _mesh: BoxMesh
var _material: StandardMaterial3D


func _init() -> void:
	name = "BoundaryWall"
	# Marker geometry on a wall that can ring a whole town would otherwise cost a
	# shadow pass for something knee high.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Rebuilds the wall for a claim. Cheap enough to call whenever the boundary moves.
##
## Heights come from the field rather than the navigation grid: the grid holds one
## height per two metres and the wall sits on the cell edges between them, so
## reading the grid would step the wall by up to a cell's worth of slope where it
## matters most, along the rim of the drop it is marking.
func raise(site: MeepSite, claim: MeepClaim, shape: PlanetShape,
		spacing := 0.0,
		suppressed_spans := PackedVector3Array()) -> void:
	var edges := claim.border_edges() if claim != null else PackedVector2Array()
	var heights := claim.border_heights() \
		if claim != null else PackedFloat32Array()
	var segments := edges.size() / 2
	if site == null or shape == null or segments == 0:
		clear()
		return
	if multimesh == null:
		multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
	if _mesh == null:
		_mesh = BoxMesh.new()
		_mesh.size = Vector3(claim.grid.cell_size, HEIGHT, THICKNESS)
		multimesh.mesh = _mesh
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.albedo_color = PURPLE
		# A town boundary is a thing you look for at night as much as by day.
		_material.emission_enabled = true
		_material.emission = PURPLE
		_material.emission_energy_multiplier = 0.35
		material_override = _material
	var kept := PackedInt32Array()
	for segment in segments:
		var middle := (edges[segment * 2] + edges[segment * 2 + 1]) * 0.5
		var direction := site.direction_at(middle)
		var height := heights[segment] if segment < heights.size() \
			else shape.elevation(direction, spacing)
		var world_point := direction * (site.planet_radius + height)
		if not _near_suppressed_span(world_point, suppressed_spans,
				claim.grid.cell_size * 1.25):
			kept.push_back(segment)
	multimesh.instance_count = kept.size()
	var buffer := PackedFloat32Array()
	buffer.resize(kept.size() * 12)
	for output_index in kept.size():
		var segment := kept[output_index]
		var from := edges[segment * 2]
		var to := edges[segment * 2 + 1]
		var middle := (from + to) * 0.5
		var direction := site.direction_at(middle)
		var height := heights[segment] if segment < heights.size() \
			else shape.elevation(direction, spacing)
		var run := to - from
		# The edge's heading as a direction on the sphere. Over two metres the
		# difference between this and a proper great-circle tangent is far below
		# the thickness of the post.
		var along := site.east * run.x + site.north * run.y
		var up := direction
		along = (along - up * along.dot(up)).normalized()
		if along.length_squared() < 0.5:
			along = up.cross(site.east).normalized()
		var basis := Basis(along, up, along.cross(up))
		var origin := direction * (
			site.planet_radius + height + HEIGHT * 0.5 - SINK)
		var row := output_index * 12
		# MultiMesh's packed Transform3D is three rows of four. One buffer upload
		# avoids a rendering-server round trip for every boundary post: several
		# hundred set_instance_transform calls were 60+ ms by themselves.
		buffer[row] = basis.x.x
		buffer[row + 1] = basis.y.x
		buffer[row + 2] = basis.z.x
		buffer[row + 3] = origin.x
		buffer[row + 4] = basis.x.y
		buffer[row + 5] = basis.y.y
		buffer[row + 6] = basis.z.y
		buffer[row + 7] = origin.y
		buffer[row + 8] = basis.x.z
		buffer[row + 9] = basis.y.z
		buffer[row + 10] = basis.z.z
		buffer[row + 11] = origin.z
	multimesh.buffer = buffer
	visible = true


static func _near_suppressed_span(point: Vector3,
		spans: PackedVector3Array, tolerance: float) -> bool:
	for index in range(0, spans.size(), 2):
		if index + 1 >= spans.size():
			break
		var from := spans[index]
		var to := spans[index + 1]
		var run := to - from
		var divisor := run.length_squared()
		var along := clampf((point - from).dot(run)
			/ divisor, 0.0, 1.0) if divisor > 0.000001 else 0.0
		if point.distance_squared_to(from + run * along) \
				<= tolerance * tolerance:
			return true
	return false


func clear() -> void:
	if multimesh != null:
		multimesh.instance_count = 0
	visible = false


## Posts standing. Reported for tests and for the city panel later.
func segment_count() -> int:
	return multimesh.instance_count if multimesh != null else 0
