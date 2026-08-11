class_name TechFormationSites
extends Node3D

## Five deterministic fields of partly buried alien-tech fragments.
##
## The mesh carries hundreds of real panel extrusions but is instanced, so a
## whole site is one draw call. Placement is rebuilt from the height field on
## every peer rather than replicated; the fixed seed and fixed planet make the
## answer identical. Site zero is constrained to pack ice at the north pole.

const MODEL: PackedScene = preload("res://assets/runtime/environment/tech_fragment.glb")
const COLLISION_MODEL: PackedScene = preload(
	"res://assets/runtime/environment/tech_fragment_collision.glb")
const SURFACE: ShaderMaterial = preload("res://game/props/tech_formation.tres")
const MESH_HALF := 0.66

# The four dry centres came from an even-direction survey of the current
# unsettled PlanetShape. The pole is not surveyed: frost_axis is the authority
# for north, and the local candidates below still prove they landed on a floe.
const SITE_DIRECTIONS := [
	Vector3(0.0, 1.0, 0.0),
	Vector3(0.2092506, -0.6636111, -0.7182162),
	Vector3(0.9480415, -0.0496111, 0.3142548),
	Vector3(-0.9576977, -0.0256111, -0.2866342),
	Vector3(0.4662280, 0.3865, -0.7957696),
]
const SITE_TITLES := [
	"Arctic Tech Site",
	"Tech Site I",
	"Tech Site II",
	"Tech Site III",
	"Tech Site IV",
]
const SITE_TINT := Color("35e6d1")

@export_group("Sites")
@export_range(3, 64) var fragments_per_site := 36
@export var site_spread := 720.0
@export var minimum_spacing := 24.0
@export var random_seed := 20261003
@export_range(10, 300) var attempts_per_fragment := 140

@export_group("Fragment size")
@export var minimum_height := 7.0
## The tallest natural summit is 620 m; this keeps the largest fragments at
## roughly half a mountain rather than quietly making them the new terrain.
@export var maximum_height := 300.0
@export var minimum_width := 3.2
@export var maximum_width := 130.0
@export var minimum_depth := 3.0
@export var maximum_depth := 105.0
@export_range(0.0, 1.0) var giant_share := 0.08
@export_range(0.0, 1.0) var medium_share := 0.24
@export_range(0.0, 80.0) var minimum_tilt := 24.0
@export_range(0.0, 80.0) var maximum_tilt := 58.0

@export_group("Rendering")
@export var visible_beyond := 12000.0
@export var range_margin := 800.0

@export_group("Collision")
@export var collisions := true
## Exact panel collision is substantially richer than one primitive. Keep it
## around nearby players only; the radius includes each fragment's own reach.
@export var collision_within := 700.0
@export var collision_margin := 240.0
@export_range(1, 4) var collision_builds_per_frame := 1
@export var collision_survey_interval := 0.18
## Removes the buried cut edge from collision. Without this small recess the
## player's lower capsule can catch the hidden fragment where terrain covers it.
@export var collision_ground_recess := 0.12

var _host: Planet
var _shape: PlanetShape
var _radius := 1.0
var _spacing := 1.0
var _mesh: Mesh
var _collision_mesh: Mesh
var _collision_faces := PackedVector3Array()
var _into_local := Transform3D.IDENTITY
var _pieces: Array[Dictionary] = []
var _collision_body: StaticBody3D
var _active_colliders := {}
var _queued_colliders := {}
var _collision_queue: Array[Dictionary] = []
var _collision_viewers: Array[Vector3] = []
var _collision_survey_in := 0.0


func _ready() -> void:
	_host = get_parent() as Planet
	if _host == null or _host.shape == null:
		push_error("TechFormationSites must be a direct child of Planet")
		return
	_shape = _host.shape
	_shape.prepare()
	_radius = _shape.radius
	_spacing = _host.finest_spacing()
	_into_local = transform.affine_inverse()
	if not _read_mesh():
		return
	_grow()


## The imported scene is discarded: only its one mesh survives into the five
## MultiMeshes, so widening a field adds instances rather than draw calls.
func _read_mesh() -> bool:
	var scene := MODEL.instantiate() as Node3D
	if scene == null:
		push_error("tech_fragment.glb did not instantiate a Node3D")
		return false
	var fragment := scene.find_child("TechFragment", true, false) as MeshInstance3D
	if fragment == null:
		scene.queue_free()
		push_error("tech_fragment.glb is missing TechFragment")
		return false
	_mesh = fragment.mesh
	scene.queue_free()

	var collision_scene := COLLISION_MODEL.instantiate() as Node3D
	if collision_scene == null:
		push_error("tech_fragment_collision.glb did not instantiate a Node3D")
		return false
	var collision_fragment := collision_scene.find_child(
		"TechFragmentCollision", true, false) as MeshInstance3D
	if collision_fragment == null:
		collision_scene.queue_free()
		push_error(
			"tech_fragment_collision.glb is missing TechFragmentCollision")
		return false
	_collision_mesh = collision_fragment.mesh
	if _collision_mesh != null:
		_collision_faces = _collision_mesh.get_faces()
	collision_scene.queue_free()
	if _mesh == null or _collision_faces.is_empty():
		push_error("tech formation mesh or collision triangles are empty")
		return false
	return true


func _grow() -> void:
	for site_index in SITE_DIRECTIONS.size():
		var transforms: Array[Transform3D] = []
		var custom: Array[Color] = []
		_grow_site(site_index, transforms, custom)
		if transforms.is_empty():
			push_warning("Tech formation site %d found no valid ground" % site_index)
			continue
		_raise_site(site_index, transforms, custom)
		_raise_waypoint(site_index)
	if collisions and not _pieces.is_empty():
		_prepare_collision_stream()


func _grow_site(site_index: int, transforms: Array[Transform3D],
		custom: Array[Color]) -> void:
	var centre := _site_direction(site_index)
	var east := centre.cross(Vector3.UP if absf(centre.y) < 0.9
		else Vector3.RIGHT).normalized()
	var north := centre.cross(east).normalized()
	var occupied: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed + site_index * 104729

	for fragment_index in fragments_per_site:
		var found := false
		var dimensions := _dimensions(rng, fragment_index == 0)
		var footprint := _footprint(dimensions)
		for attempt in attempts_per_fragment:
			var offset := Vector2.ZERO
			if fragment_index > 0 or attempt > 0:
				var spin := rng.randf() * TAU
				var reach := sqrt(rng.randf()) * site_spread
				offset = Vector2(cos(spin), sin(spin)) * reach
			var at := (centre
				+ (east * offset.x + north * offset.y) / _radius).normalized()
			var ground := _ground(at, site_index == 0)
			if is_nan(ground):
				continue
			var point := at * (_radius + ground)
			if not _separate(point, footprint, occupied):
				continue

			var stood_planet := _fragment_transform(
				at, point, dimensions, rng, fragment_index == 0)
			var stood := _into_local * stood_planet
			transforms.append(stood)
			custom.append(Color(rng.randf(), rng.randf(), 0.0, 0.0))
			occupied.append({
				"point": point,
				"footprint": footprint,
			})
			_pieces.append({
				"transform": stood,
				"dimensions": dimensions,
				"ground_point": _into_local * point,
				"ground_up": (_into_local.basis * at).normalized(),
				"reach": dimensions.length() * MESH_HALF,
			})
			found = true
			break
		if not found:
			break

	if transforms.size() < fragments_per_site:
		push_warning("Tech formation site %d placed %d of %d fragments"
			% [site_index, transforms.size(), fragments_per_site])


func _ground(direction: Vector3, on_ice: bool) -> float:
	var height := _shape.elevation(direction, _spacing)
	if on_ice:
		if _shape.frost(direction) < 0.5 \
				or absf(height - PlanetShape.ICE_TOP) > 0.08:
			return NAN
		return height
	if _shape.frost(direction) > 0.02 or height < 2.0:
		return NAN
	var parts := _shape.sample(direction)
	if float(parts["river"]) > 0.0 or float(parts["lake"]) > 0.0:
		return NAN
	var normal := _shape.normal_at(direction, _spacing)
	if normal.dot(direction) < cos(deg_to_rad(32.0)):
		return NAN
	return height


func _site_direction(site_index: int) -> Vector3:
	# The exact pole is the only place the scene's hard-coded Vector3.UP and the
	# shape's authored north can drift apart after a frost-axis edit.
	if site_index == 0:
		return _shape.frost_axis.normalized()
	var direction: Vector3 = SITE_DIRECTIONS[site_index]
	return direction.normalized()


func _raise_waypoint(site_index: int) -> void:
	var marker := Landmark.new()
	marker.name = "TechSiteWaypoint%d" % site_index
	marker.direction = _site_direction(site_index)
	marker.title = SITE_TITLES[site_index]
	marker.tint = SITE_TINT
	marker.waypoint = false
	marker.show_beyond = 300.0
	marker.aimed_beyond = 650.0
	# These are map marks: unlike ordinary nearby landmarks they remain on the
	# orbital globe, with the planet's own horizon still hiding the far side.
	marker.hide_beyond = 0.0
	add_child(marker, false, Node.INTERNAL_MODE_BACK)


func _separate(point: Vector3, footprint: float,
		occupied: Array[Dictionary]) -> bool:
	for other: Dictionary in occupied:
		var other_point: Vector3 = other["point"]
		var other_footprint: float = other["footprint"]
		# Some overlap is deliberate — these are broken complexes — but a
		# three-hundred-metre slab cannot use the seven-metre spacing of a shard.
		var clearance := maxf(minimum_spacing,
			(footprint + other_footprint) * 0.68)
		if point.distance_squared_to(other_point) < clearance * clearance:
			return false
	return true


func _dimensions(rng: RandomNumberGenerator, hero: bool) -> Vector3:
	if hero:
		return Vector3(
			rng.randf_range(maxf(minimum_width, 72.0), maximum_width),
			rng.randf_range(maxf(minimum_height, 230.0), maximum_height),
			rng.randf_range(maxf(minimum_depth, 58.0), maximum_depth))
	var size_roll := rng.randf()
	if size_roll < giant_share:
		return Vector3(
			rng.randf_range(maxf(minimum_width, 48.0), maximum_width),
			rng.randf_range(maxf(minimum_height, 150.0), maximum_height),
			rng.randf_range(maxf(minimum_depth, 40.0), maximum_depth))
	if size_roll < giant_share + medium_share:
		return Vector3(
			rng.randf_range(maxf(minimum_width, 14.0), minf(maximum_width, 48.0)),
			rng.randf_range(maxf(minimum_height, 38.0), minf(maximum_height, 125.0)),
			rng.randf_range(maxf(minimum_depth, 12.0), minf(maximum_depth, 42.0)))
	if rng.randf() < 0.28:
		# Broad chunks make the cluster read as broken architecture rather than
		# a field of crystals, while the same cube mesh still supplies the skin.
		return Vector3(
			rng.randf_range(maxf(minimum_width, 7.0), minf(maximum_width, 14.0)),
			rng.randf_range(minimum_height, minf(maximum_height, 15.0)),
			rng.randf_range(maxf(minimum_depth, 6.0), minf(maximum_depth, 12.0)))
	return Vector3(
		rng.randf_range(minimum_width, minf(maximum_width, 8.5)),
		rng.randf_range(minimum_height, minf(maximum_height, 31.0)),
		rng.randf_range(minimum_depth, minf(maximum_depth, 8.0)))


func _footprint(dimensions: Vector3) -> float:
	# Height joins the footprint because a tilted slab spends most of its length
	# sideways; width/depth alone would let two giants intersect at their middles.
	return maxf(dimensions.x, dimensions.z) * 0.45 + dimensions.y * 0.28


func _fragment_transform(up: Vector3, point: Vector3, dimensions: Vector3,
		rng: RandomNumberGenerator, hero: bool) -> Transform3D:
	var orientation := Basis(up, rng.randf() * TAU) * _upright(up)
	var tilt_heading := rng.randf() * TAU
	var tilt_axis := (orientation.x * cos(tilt_heading)
		+ orientation.z * sin(tilt_heading)).normalized()
	var tilt := deg_to_rad(rng.randf_range(minimum_tilt, maximum_tilt))
	orientation = Basis(tilt_axis, tilt) * orientation
	orientation = Basis(orientation.z.normalized(),
		deg_to_rad(rng.randf_range(-14.0, 14.0))) * orientation
	var basis := Basis(
		orientation.x * dimensions.x,
		orientation.y * dimensions.y,
		orientation.z * dimensions.z)
	var radial_half := 0.5 * (
		absf(up.dot(basis.x))
		+ absf(up.dot(basis.y))
		+ absf(up.dot(basis.z)))
	var visible_share := 0.58 if hero else (
		rng.randf_range(0.28, 0.43) if rng.randf() < 0.38
		else rng.randf_range(0.46, 0.7))
	var centre_height := (visible_share * 2.0 - 1.0) * radial_half
	return Transform3D(basis, point + up * centre_height)


func _upright(up: Vector3) -> Basis:
	var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - up * hint.dot(up)).normalized()
	return Basis(up.cross(forward), up, forward)


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
	field.name = "NorthPoleTech" if site_index == 0 else "TechSite%d" % site_index
	field.multimesh = multimesh
	field.material_override = SURFACE
	field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	field.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	field.visibility_range_end = visible_beyond
	field.visibility_range_end_margin = range_margin
	field.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(field, false, Node.INTERNAL_MODE_BACK)


func _bounds(transforms: Array[Transform3D]) -> AABB:
	var bounds := AABB(transforms[0].origin, Vector3.ZERO)
	for stood in transforms:
		for x in [-MESH_HALF, MESH_HALF]:
			for y in [-MESH_HALF, MESH_HALF]:
				for z in [-MESH_HALF, MESH_HALF]:
					bounds = bounds.expand(stood * Vector3(x, y, z))
	return bounds.grow(2.0)


## The old collider was one box expanded from the core's +/-0.5 to the deepest
## stud at +/-0.66. On a 300 m fragment that filled nearly fifty metres of empty
## air around every shallow panel. The streamed trimesh below contains the core,
## broad rectangles and bars themselves, with non-uniform instance scale baked
## into its vertices so Godot's physics server never receives a scaled shape.
func _prepare_collision_stream() -> void:
	_collision_body = StaticBody3D.new()
	_collision_body.name = "TechFormationCollision"
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
		_survey_collision_stream()

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


func _survey_collision_stream() -> void:
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
	for index in _pieces.size():
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
	var piece: Dictionary = _pieces[index]
	var stood: Transform3D = piece["transform"]
	var reach: float = piece["reach"]
	var nearest := INF
	for viewer in _collision_viewers:
		nearest = minf(nearest, viewer.distance_to(stood.origin) - reach)
	return nearest


func _activate_collision(index: int) -> void:
	var faces := _piece_collision_faces(index)
	if faces.is_empty():
		return
	var piece: Dictionary = _pieces[index]
	var stood: Transform3D = piece["transform"]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# GLB axis conversion and the overlapping panel boxes do not provide a
	# dependable single "outside" winding for every exposed rectangle. Static
	# ruins need to stop a body approaching either side of a broken slab.
	shape.backface_collision = true
	var collider := CollisionShape3D.new()
	collider.name = "Fragment%d" % index
	collider.shape = shape
	collider.transform = Transform3D(_rotation_of(stood.basis), stood.origin)
	_collision_body.add_child(collider)
	_active_colliders[index] = collider


func _deactivate_collision(index: int) -> void:
	var collider := _active_colliders.get(index) as CollisionShape3D
	_active_colliders.erase(index)
	if collider != null:
		collider.queue_free()


func _piece_collision_faces(index: int) -> PackedVector3Array:
	var piece: Dictionary = _pieces[index]
	var stood: Transform3D = piece["transform"]
	var dimensions: Vector3 = piece["dimensions"]
	var rotation := _rotation_of(stood.basis)
	var ground_point: Vector3 = piece["ground_point"]
	var ground_up: Vector3 = piece["ground_up"]
	# Plane in the collider's unrotated, already-scaled local coordinates.
	var plane_normal := (rotation.transposed() * ground_up).normalized()
	var plane_offset := (
		ground_up.dot(ground_point - stood.origin) + collision_ground_recess)
	var result := PackedVector3Array()
	for triangle in range(0, _collision_faces.size(), 3):
		var a := _scaled(_collision_faces[triangle], dimensions)
		var b := _scaled(_collision_faces[triangle + 1], dimensions)
		var c := _scaled(_collision_faces[triangle + 2], dimensions)
		_append_clipped_triangle(
			result, a, b, c, plane_normal, plane_offset)
	return result


func _append_clipped_triangle(result: PackedVector3Array,
		a: Vector3, b: Vector3, c: Vector3,
		plane_normal: Vector3, plane_offset: float) -> void:
	# Sutherland-Hodgman against the intentional burial plane. Keeping this in
	# local coordinates preserves triangle winding and avoids large planet-space
	# numbers in the physics resource.
	var polygon: Array[Vector3] = [a, b, c]
	var clipped: Array[Vector3] = []
	var previous := polygon[-1]
	var previous_distance := plane_normal.dot(previous) - plane_offset
	for current in polygon:
		var current_distance := plane_normal.dot(current) - plane_offset
		if current_distance >= 0.0:
			if previous_distance < 0.0:
				var t := previous_distance / (
					previous_distance - current_distance)
				clipped.append(previous.lerp(current, clampf(t, 0.0, 1.0)))
			clipped.append(current)
		elif previous_distance >= 0.0:
			var t := previous_distance / (
				previous_distance - current_distance)
			clipped.append(previous.lerp(current, clampf(t, 0.0, 1.0)))
		previous = current
		previous_distance = current_distance
	if clipped.size() < 3:
		return
	for corner in range(1, clipped.size() - 1):
		result.append(clipped[0])
		result.append(clipped[corner])
		result.append(clipped[corner + 1])


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
