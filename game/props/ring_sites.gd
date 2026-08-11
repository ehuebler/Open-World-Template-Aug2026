class_name RingSites
extends Node3D

## Four deterministic fields of giant crystalline arches and partially buried
## rings. Every site is one MultiMesh draw call; curve shape comes from instance
## transforms around a reusable faceted segment rather than unique giant meshes.

const MODEL: PackedScene = preload(
	"res://blender_assets/ring_crystal_segment.glb")
const MATERIAL: ShaderMaterial = preload(
	"res://game/props/ring_crystal.tres")

const MODE_RING := 0
const MODE_ARCH := 1
const SITE_DIRECTIONS := [
	# Surveyed as pack ice across a 390 m footprint. Its centre is 2.5 km from
	# the north-pole tech field, leaving 1.39 km between their outer bounds.
	Vector3(-0.26625, 0.951568, -0.153719),
	Vector3(-0.469333, -0.847375, 0.248358),
	Vector3(-0.347432, 0.109542, 0.931285),
	Vector3(-0.388075, 0.499625, 0.77445),
]
const SITE_TITLES := [
	"Arctic Ring Site",
	"Ring Site I",
	"Ring Site II",
	"Ring Site III",
]
const SITE_EXTENTS := [390.0, 330.0, 300.0, 330.0]
const SITE_TINT := Color("4dff79")

const TECH_DIRECTIONS := [
	Vector3(0.0, 1.0, 0.0),
	Vector3(0.2092506, -0.6636111, -0.7182162),
	Vector3(0.9480415, -0.0496111, 0.3142548),
	Vector3(-0.9576977, -0.0256111, -0.2866342),
	Vector3(0.4662280, 0.3865, -0.7957696),
]
const MOUNTAIN_DIRECTIONS := [
	Vector3(-0.270521, -0.3052884, -0.9130266),
	Vector3(0.6848267, 0.0168872, 0.7285103),
	Vector3(0.2574172, -0.2996968, -0.9186503),
	Vector3(0.4474815, -0.0008659, -0.8942928),
]

# width/height are the outside curve dimensions in metres. Full rings use half
# height above and below their lifted centre; arches use height as their apex.
# exponent 2 is an ellipse, while larger values make long, grown-square arcs.
const SITE_RINGS := [
	[
		{"mode": MODE_RING, "offset": Vector2(0, 0),
			"width": 720.0, "height": 250.0, "thickness": 19.0,
			"depth": 14.0, "heading": 12.0, "lean": -3.0,
			"burial": 0.74, "exponent": 2.15, "segments": 104},
		{"mode": MODE_ARCH, "offset": Vector2(-185, 118),
			"width": 155.0, "height": 205.0, "thickness": 11.0,
			"depth": 8.0, "heading": 77.0, "lean": 9.0,
			"burial": 0.0, "exponent": 2.0, "segments": 42},
		{"mode": MODE_RING, "offset": Vector2(225, -92),
			"width": 118.0, "height": 165.0, "thickness": 9.0,
			"depth": 7.0, "heading": -34.0, "lean": -11.0,
			"burial": 0.68, "exponent": 2.0, "segments": 36},
	],
	[
		{"mode": MODE_RING, "offset": Vector2(-12, 8),
			"width": 214.0, "height": 214.0, "thickness": 13.0,
			"depth": 10.0, "heading": 28.0, "lean": 4.0,
			"burial": 0.72, "exponent": 2.0, "segments": 58},
		{"mode": MODE_ARCH, "offset": Vector2(-142, 38),
			"width": 104.0, "height": 260.0, "thickness": 10.0,
			"depth": 7.5, "heading": 78.0, "lean": -13.0,
			"burial": 0.0, "exponent": 2.0, "segments": 42},
		{"mode": MODE_ARCH, "offset": Vector2(68, 132),
			"width": 302.0, "height": 88.0, "thickness": 12.0,
			"depth": 9.0, "heading": -12.0, "lean": 6.0,
			"burial": 0.0, "exponent": 3.2, "segments": 48},
		{"mode": MODE_RING, "offset": Vector2(154, -82),
			"width": 82.0, "height": 124.0, "thickness": 7.0,
			"depth": 6.0, "heading": 51.0, "lean": 15.0,
			"burial": 0.64, "exponent": 2.0, "segments": 28},
		{"mode": MODE_ARCH, "offset": Vector2(-88, -132),
			"width": 142.0, "height": 178.0, "thickness": 9.0,
			"depth": 7.0, "heading": -58.0, "lean": -8.0,
			"burial": 0.0, "exponent": 2.45, "segments": 38},
	],
	[
		{"mode": MODE_ARCH, "offset": Vector2(5, -18),
			"width": 318.0, "height": 168.0, "thickness": 15.0,
			"depth": 11.0, "heading": 41.0, "lean": -6.0,
			"burial": 0.0, "exponent": 2.3, "segments": 56},
		{"mode": MODE_RING, "offset": Vector2(-128, 94),
			"width": 168.0, "height": 168.0, "thickness": 10.0,
			"depth": 8.0, "heading": -22.0, "lean": 12.0,
			"burial": 0.7, "exponent": 2.0, "segments": 46},
		{"mode": MODE_ARCH, "offset": Vector2(132, 96),
			"width": 94.0, "height": 244.0, "thickness": 9.0,
			"depth": 7.0, "heading": 83.0, "lean": -17.0,
			"burial": 0.0, "exponent": 2.0, "segments": 40},
		{"mode": MODE_RING, "offset": Vector2(102, -126),
			"width": 148.0, "height": 96.0, "thickness": 8.0,
			"depth": 6.0, "heading": 8.0, "lean": 8.0,
			"burial": 0.66, "exponent": 3.0, "segments": 36},
	],
	[
		{"mode": MODE_RING, "offset": Vector2(0, 0),
			"width": 188.0, "height": 248.0, "thickness": 13.0,
			"depth": 9.0, "heading": -31.0, "lean": 7.0,
			"burial": 0.72, "exponent": 2.0, "segments": 56},
		{"mode": MODE_ARCH, "offset": Vector2(-154, 80),
			"width": 282.0, "height": 84.0, "thickness": 11.0,
			"depth": 8.0, "heading": 16.0, "lean": -4.0,
			"burial": 0.0, "exponent": 3.4, "segments": 46},
		{"mode": MODE_RING, "offset": Vector2(145, 82),
			"width": 126.0, "height": 126.0, "thickness": 8.0,
			"depth": 6.0, "heading": 63.0, "lean": -14.0,
			"burial": 0.68, "exponent": 2.0, "segments": 36},
		{"mode": MODE_ARCH, "offset": Vector2(-96, -128),
			"width": 92.0, "height": 216.0, "thickness": 9.0,
			"depth": 7.0, "heading": -72.0, "lean": 16.0,
			"burial": 0.0, "exponent": 2.0, "segments": 38},
		{"mode": MODE_RING, "offset": Vector2(82, -142),
			"width": 168.0, "height": 92.0, "thickness": 8.0,
			"depth": 6.0, "heading": 4.0, "lean": 10.0,
			"burial": 0.62, "exponent": 3.2, "segments": 38},
	],
]

@export_group("Rendering")
@export var visible_beyond := 15000.0
@export var range_margin := 1000.0

@export_group("Collision")
@export var collisions := true
@export var collision_within := 420.0
@export var collision_margin := 160.0
@export_range(1, 16) var collision_builds_per_frame := 6
@export var collision_survey_interval := 0.16
@export var collision_ground_recess := 0.10

@export_group("Local green light")
@export var lights_per_site := 3
@export var light_color := Color(0.14, 1.0, 0.28, 1.0)
@export var light_energy := 7.0
@export var light_range := 105.0

var _host: Planet
var _shape: PlanetShape
var _radius := 1.0
var _mesh: Mesh
var _mesh_aabb := AABB()
var _mesh_faces := PackedVector3Array()
var _into_local := Transform3D.IDENTITY
var _segments: Array[Dictionary] = []

var _collision_body: StaticBody3D
var _active_colliders := {}
var _queued_colliders := {}
var _collision_queue: Array[Dictionary] = []
var _collision_viewers: Array[Vector3] = []
var _collision_survey_in := 0.0


func _ready() -> void:
	_host = get_parent() as Planet
	if _host == null or _host.shape == null:
		push_error("RingSites must be a direct child of Planet")
		return
	_shape = _host.shape
	_shape.prepare()
	_radius = _shape.radius
	_into_local = transform.affine_inverse()
	if not _read_mesh():
		return
	_validate_clearance()
	_build_sites()
	if collisions and not _segments.is_empty():
		_prepare_collision_stream()


func _read_mesh() -> bool:
	var scene := MODEL.instantiate() as Node3D
	if scene == null:
		push_error("ring_crystal_segment.glb did not instantiate a Node3D")
		return false
	var segment := scene.find_child(
		"RingCrystalSegment", true, false) as MeshInstance3D
	if segment == null:
		scene.queue_free()
		push_error("ring crystal GLB is missing RingCrystalSegment")
		return false
	_mesh = segment.mesh
	if _mesh != null:
		_mesh_aabb = _mesh.get_aabb()
		_mesh_faces = _mesh.get_faces()
	scene.queue_free()
	if _mesh == null or _mesh_faces.is_empty():
		push_error("ring crystal mesh or collision faces are empty")
		return false
	return true


func _validate_clearance() -> void:
	for site_index in SITE_DIRECTIONS.size():
		var direction: Vector3 = SITE_DIRECTIONS[site_index]
		var tech := _nearest_arc(direction, TECH_DIRECTIONS)
		var mountain := _nearest_arc(direction, MOUNTAIN_DIRECTIONS)
		var tech_gap: float = (
			tech - float(SITE_EXTENTS[site_index]) - 720.0)
		var mountain_gap: float = (
			mountain - float(SITE_EXTENTS[site_index]) - 500.0)
		if tech_gap < 250.0:
			push_error("Ring site %d overlaps a tech formation by %.0f m"
				% [site_index, -tech_gap])
		if mountain_gap < 350.0:
			push_error("Ring site %d overlaps a giant mountain by %.0f m"
				% [site_index, -mountain_gap])


func _build_sites() -> void:
	for site_index in SITE_DIRECTIONS.size():
		var transforms: Array[Transform3D] = []
		var custom: Array[Color] = []
		var site_direction: Vector3 = SITE_DIRECTIONS[site_index].normalized()
		for ring_index in SITE_RINGS[site_index].size():
			_add_ring(
				site_index, ring_index, site_direction,
				SITE_RINGS[site_index][ring_index], transforms, custom)
		_raise_site(site_index, transforms, custom)
		_raise_waypoint(site_index)
		_raise_lights(site_index, site_direction)


func _add_ring(site_index: int, ring_index: int, site_direction: Vector3,
		ring: Dictionary, transforms: Array[Transform3D],
		custom: Array[Color]) -> void:
	var site_frame := _surface_frame(site_direction)
	var offset: Vector2 = ring["offset"]
	var centre_direction := (
		site_direction
		+ (site_frame.x * offset.x + site_frame.z * offset.y) / _radius
	).normalized()
	var frame := _surface_frame(centre_direction)
	var heading := deg_to_rad(float(ring["heading"]))
	var right := (frame.x * cos(heading) + frame.z * sin(heading)).normalized()
	var plane_normal := right.cross(centre_direction).normalized()
	var segments: int = ring["segments"]
	var mode: int = ring["mode"]
	var extent := TAU if mode == MODE_RING else PI
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261010 + site_index * 104729 + ring_index * 7919

	for segment_index in segments:
		var theta0 := extent * float(segment_index) / float(segments)
		var theta1 := extent * float(segment_index + 1) / float(segments)
		var theta_mid := (theta0 + theta1) * 0.5
		var before := _curve_point(
			centre_direction, right, plane_normal, ring, theta0)
		var after := _curve_point(
			centre_direction, right, plane_normal, ring, theta1)
		var centre := _curve_point(
			centre_direction, right, plane_normal, ring, theta_mid)
		var tangent := (after - before).normalized()
		var depth_axis := (
			plane_normal - tangent * plane_normal.dot(tangent)).normalized()
		if depth_axis == Vector3.ZERO:
			depth_axis = centre_direction.cross(tangent).normalized()
		var thickness_axis := depth_axis.cross(tangent).normalized()
		var roll := rng.randf_range(-0.055, 0.055)
		var rolled := Basis(tangent, roll)
		thickness_axis = (rolled * thickness_axis).normalized()
		depth_axis = (rolled * depth_axis).normalized()

		var length := before.distance_to(after) * 1.075
		var cross_variation := rng.randf_range(0.88, 1.13)
		var basis := Basis(
			tangent * length,
			thickness_axis * float(ring["thickness"]) * cross_variation,
			depth_axis * float(ring["depth"])
				* rng.randf_range(0.9, 1.1))
		var stood := Transform3D(basis, _into_local * centre)
		transforms.append(stood)
		custom.append(Color(
			fposmod(
				float(segment_index) / float(segments)
				+ ring_index * 0.173 + site_index * 0.237, 1.0),
			rng.randf(), float(ring_index) / 8.0, 1.0))

		var horizontal := _curve_horizontal(ring, theta_mid)
		var surface_direction := (
			centre_direction + right * horizontal / _radius).normalized()
		var ground_point := _ground_point(surface_direction)
		_segments.append({
			"transform": stood,
			"ground_point": _into_local * ground_point,
			"ground_up": (_into_local.basis * surface_direction).normalized(),
			"reach": length * 0.52
				+ maxf(float(ring["thickness"]), float(ring["depth"])) * 0.6,
			"site": site_index,
		})


func _curve_point(centre_direction: Vector3, right: Vector3,
		plane_normal: Vector3, ring: Dictionary, theta: float) -> Vector3:
	var horizontal := _curve_horizontal(ring, theta)
	var vertical := _curve_vertical(ring, theta)
	var phase := float(ring["heading"]) * 0.031
	horizontal += float(ring["width"]) * 0.0075 * sin(
		theta * 3.0 + phase)
	vertical *= 1.0 + 0.018 * sin(theta * 2.0 + phase * 1.7)
	var surface_direction := (
		centre_direction + right * horizontal / _radius).normalized()
	var ground := _ground_point(surface_direction)
	var lean := deg_to_rad(float(ring["lean"]))
	var raised := (
		surface_direction * cos(lean) + plane_normal * sin(lean)).normalized()
	return ground + raised * vertical


func _curve_horizontal(ring: Dictionary, theta: float) -> float:
	var value := cos(theta)
	return float(ring["width"]) * 0.5 * _super(value, float(ring["exponent"]))


func _curve_vertical(ring: Dictionary, theta: float) -> float:
	var value := sin(theta)
	var shaped := _super(value, float(ring["exponent"]))
	if int(ring["mode"]) == MODE_RING:
		var half_height := float(ring["height"]) * 0.5
		return half_height * (shaped + float(ring["burial"]))
	return float(ring["height"]) * maxf(shaped, 0.0) \
		- float(ring["thickness"]) * 0.08


func _super(value: float, exponent: float) -> float:
	return signf(value) * pow(absf(value), 2.0 / maxf(exponent, 0.5))


func _ground_point(direction: Vector3) -> Vector3:
	return direction * (
		_radius + _shape.elevation(direction, _host.finest_spacing()))


func _surface_frame(up: Vector3) -> Basis:
	var hint := Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT
	var east := up.cross(hint).normalized()
	var north := up.cross(east).normalized()
	return Basis(east, up, north)


func _raise_site(site_index: int, transforms: Array[Transform3D],
		custom: Array[Color]) -> void:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_custom_data = true
	multimesh.instance_count = transforms.size()
	multimesh.mesh = _mesh
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
		multimesh.set_instance_custom_data(index, custom[index])
	multimesh.custom_aabb = _bounds(transforms)

	var field := MultiMeshInstance3D.new()
	field.name = "ArcticRings" if site_index == 0 else "RingSite%d" % site_index
	field.multimesh = multimesh
	field.material_override = MATERIAL
	field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	field.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	field.visibility_range_end = visible_beyond
	field.visibility_range_end_margin = range_margin
	field.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(field, false, Node.INTERNAL_MODE_BACK)


func _bounds(transforms: Array[Transform3D]) -> AABB:
	var corners := [
		_mesh_aabb.position,
		_mesh_aabb.position + Vector3(_mesh_aabb.size.x, 0, 0),
		_mesh_aabb.position + Vector3(0, _mesh_aabb.size.y, 0),
		_mesh_aabb.position + Vector3(0, 0, _mesh_aabb.size.z),
		_mesh_aabb.end - Vector3(_mesh_aabb.size.x, 0, 0),
		_mesh_aabb.end - Vector3(0, _mesh_aabb.size.y, 0),
		_mesh_aabb.end - Vector3(0, 0, _mesh_aabb.size.z),
		_mesh_aabb.end,
	]
	var bounds := AABB(transforms[0] * corners[0], Vector3.ZERO)
	for stood in transforms:
		for corner in corners:
			bounds = bounds.expand(stood * corner)
	return bounds.grow(3.0)


func _raise_waypoint(site_index: int) -> void:
	var marker := Landmark.new()
	marker.name = "RingSiteWaypoint%d" % site_index
	marker.direction = SITE_DIRECTIONS[site_index]
	marker.title = SITE_TITLES[site_index]
	marker.tint = SITE_TINT
	marker.show_beyond = 320.0
	marker.aimed_beyond = 720.0
	marker.hide_beyond = 0.0
	add_child(marker, false, Node.INTERNAL_MODE_BACK)


func _raise_lights(site_index: int, site_direction: Vector3) -> void:
	var frame := _surface_frame(site_direction)
	var main: Dictionary = SITE_RINGS[site_index][0]
	var heading := deg_to_rad(float(main["heading"]))
	var right := (frame.x * cos(heading) + frame.z * sin(heading)).normalized()
	var count := maxi(lights_per_site, 1)
	for index in count:
		var share := 0.0 if count == 1 else (
			float(index) / float(count - 1) * 2.0 - 1.0)
		var horizontal := share * float(main["width"]) * 0.32
		var direction := (
			site_direction + right * horizontal / _radius).normalized()
		var light := OmniLight3D.new()
		light.name = "RingGlow%d_%d" % [site_index, index]
		light.position = _into_local * (
			_ground_point(direction) + direction * minf(
				24.0, maxf(8.0, float(main["height"]) * 0.08)))
		light.light_color = light_color
		light.light_energy = light_energy * (
			1.25 if site_index == 0 else 1.0)
		light.light_specular = 0.72
		light.omni_range = light_range * (
			1.3 if site_index == 0 else 1.0)
		light.omni_attenuation = 1.15
		light.shadow_enabled = false
		add_child(light, false, Node.INTERNAL_MODE_BACK)


func _prepare_collision_stream() -> void:
	_collision_body = StaticBody3D.new()
	_collision_body.name = "RingSiteCollision"
	_collision_body.collision_layer = 1
	_collision_body.collision_mask = 1
	add_child(_collision_body, false, Node.INTERNAL_MODE_BACK)
	_collision_survey_in = 0.0
	set_process(true)


func _process(delta: float) -> void:
	if _collision_body == null:
		return
	_collision_survey_in -= delta
	if _collision_survey_in <= 0.0:
		_collision_survey_in = maxf(collision_survey_interval, 0.02)
		_survey_collisions()
	var built := 0
	while built < collision_builds_per_frame and not _collision_queue.is_empty():
		var request: Dictionary = _collision_queue.pop_front()
		var index: int = request["index"]
		_queued_colliders.erase(index)
		if _active_colliders.has(index) \
				or _collision_distance(index) > collision_within:
			continue
		_activate_collision(index)
		built += 1


func _survey_collisions() -> void:
	_collision_viewers.clear()
	var local_peer := multiplayer.get_unique_id()
	for node in get_tree().get_nodes_in_group(&"network_players"):
		var viewer := node as Node3D
		if viewer == null:
			continue
		var peer: Variant = viewer.get("peer_id")
		if peer != null and int(peer) != local_peer:
			continue
		_collision_viewers.append(to_local(viewer.global_position))
	if _collision_viewers.is_empty():
		for index: Variant in _active_colliders.keys():
			_deactivate_collision(int(index))
		_collision_queue.clear()
		_queued_colliders.clear()
		return

	var additions: Array[Dictionary] = []
	for index in _segments.size():
		var distance := _collision_distance(index)
		if distance <= collision_within:
			if not _active_colliders.has(index) \
					and not _queued_colliders.has(index):
				additions.append({"index": index, "distance": distance})
				_queued_colliders[index] = true
		elif _active_colliders.has(index) \
				and distance > collision_within + collision_margin:
			_deactivate_collision(index)
	additions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"]))
	_collision_queue.append_array(additions)


func _collision_distance(index: int) -> float:
	if _collision_viewers.is_empty():
		return INF
	var segment: Dictionary = _segments[index]
	var stood: Transform3D = segment["transform"]
	var reach: float = segment["reach"]
	var nearest := INF
	for viewer in _collision_viewers:
		nearest = minf(nearest, viewer.distance_to(stood.origin) - reach)
	return nearest


func _activate_collision(index: int) -> void:
	var points := _clipped_segment_points(index)
	if points.size() < 4:
		return
	var segment: Dictionary = _segments[index]
	var stood: Transform3D = segment["transform"]
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var collider := CollisionShape3D.new()
	collider.name = "RingSegment%d" % index
	collider.shape = shape
	collider.transform = Transform3D(_rotation_of(stood.basis), stood.origin)
	_collision_body.add_child(collider)
	_active_colliders[index] = collider


func _clipped_segment_points(index: int) -> PackedVector3Array:
	var segment: Dictionary = _segments[index]
	var stood: Transform3D = segment["transform"]
	var rotation := _rotation_of(stood.basis)
	var dimensions := Vector3(
		stood.basis.x.length(), stood.basis.y.length(), stood.basis.z.length())
	var ground_point: Vector3 = segment["ground_point"]
	var ground_up: Vector3 = segment["ground_up"]
	var normal := (rotation.transposed() * ground_up).normalized()
	var offset := ground_up.dot(ground_point - stood.origin) \
		+ collision_ground_recess
	var points := PackedVector3Array()
	for triangle in range(0, _mesh_faces.size(), 3):
		var triangle_points := [
			_scaled(_mesh_faces[triangle], dimensions),
			_scaled(_mesh_faces[triangle + 1], dimensions),
			_scaled(_mesh_faces[triangle + 2], dimensions),
		]
		for point in triangle_points:
			if normal.dot(point) >= offset:
				points.append(point)
		for edge in 3:
			var a: Vector3 = triangle_points[edge]
			var b: Vector3 = triangle_points[(edge + 1) % 3]
			var da := normal.dot(a) - offset
			var db := normal.dot(b) - offset
			if (da < 0.0 and db > 0.0) or (da > 0.0 and db < 0.0):
				var t := da / (da - db)
				points.append(a.lerp(b, clampf(t, 0.0, 1.0)))
	return points


func _deactivate_collision(index: int) -> void:
	var collider := _active_colliders.get(index) as CollisionShape3D
	_active_colliders.erase(index)
	if collider != null:
		collider.queue_free()


func _scaled(point: Vector3, dimensions: Vector3) -> Vector3:
	return Vector3(
		point.x * dimensions.x,
		point.y * dimensions.y,
		point.z * dimensions.z)


func _rotation_of(basis: Basis) -> Basis:
	return Basis(
		basis.x.normalized(),
		basis.y.normalized(),
		basis.z.normalized())


func _nearest_arc(direction: Vector3, others: Array) -> float:
	var nearest := INF
	for other: Vector3 in others:
		nearest = minf(nearest, acos(clampf(
			direction.normalized().dot(other.normalized()), -1.0, 1.0))
			* _radius)
	return nearest
