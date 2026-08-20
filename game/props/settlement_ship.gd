class_name SettlementShip
extends Node3D

## Replicated expedition lander. Its immutable launch facts plus elapsed time are
## sufficient to reconstruct the same spherical arc for a late joiner.

const FOOTPRINT := Vector3(18.0, 5.0, 10.0)
const FLIGHT_DURATION := 8.0
const ARC_HEIGHT := 42.0
const LANDED_CLEARANCE := 2.6

var colony_site: StringName
var parent_site: StringName
var origin_direction := Vector3.UP
var target_direction := Vector3.UP
var expedition_seed := 0
var founder_manifest: Array = []
var flight_elapsed := 0.0
var landed := false

var _planet: Planet
var _body: StaticBody3D


func configure(planet: Planet, child: StringName, parent: StringName,
		origin: Vector3, target: Vector3, seed: int, founders: Array,
		elapsed := 0.0, is_landed := false) -> void:
	_planet = planet
	colony_site = child
	parent_site = parent
	origin_direction = origin.normalized()
	target_direction = target.normalized()
	expedition_seed = seed
	founder_manifest = founders.duplicate(true)
	flight_elapsed = clampf(elapsed, 0.0, FLIGHT_DURATION)
	# Reaching the visual endpoint is not authority to become interactive.
	landed = is_landed
	name = "SettlementShip_%s" % child
	add_to_group(Landmark.GROUP)
	_raise_placeholder()
	_set_pose(1.0 if landed else flight_elapsed / FLIGHT_DURATION)
	_set_landed_collision(landed)


func _raise_placeholder() -> void:
	if _body != null:
		return
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Hull"
	var mesh := BoxMesh.new()
	mesh.size = FOOTPRINT
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.12, 0.18)
	material.metallic = 0.48
	material.roughness = 0.34
	mesh.material = material
	mesh_instance.mesh = mesh
	add_child(mesh_instance)
	_body = StaticBody3D.new()
	_body.name = "SettlementShipCollision"
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = FOOTPRINT
	collider.shape = shape
	_body.add_child(collider)
	add_child(_body)


func advance(delta: float, authorize_landing := true) -> bool:
	if landed:
		return false
	flight_elapsed = minf(flight_elapsed + maxf(delta, 0.0), FLIGHT_DURATION)
	var progress := flight_elapsed / FLIGHT_DURATION
	_set_pose(progress)
	if progress < 1.0:
		return false
	if not authorize_landing:
		return false
	landed = true
	_set_landed_collision(true)
	return true


func set_flight_state(elapsed: float, is_landed: bool) -> void:
	flight_elapsed = clampf(elapsed, 0.0, FLIGHT_DURATION)
	landed = is_landed
	_set_pose(1.0 if landed else flight_elapsed / FLIGHT_DURATION)
	_set_landed_collision(landed)


func _set_pose(progress: float) -> void:
	if _planet == null or _planet.shape == null:
		return
	var direction := origin_direction.slerp(target_direction, progress).normalized()
	var ground := _planet.shape.elevation(direction)
	var altitude := sin(progress * PI) * ARC_HEIGHT + LANDED_CLEARANCE
	position = direction * (_planet.shape.radius + ground + altitude)
	var toward := target_direction - direction * target_direction.dot(direction)
	if toward.length_squared() < 0.000001:
		toward = Vector3.FORWARD - direction * Vector3.FORWARD.dot(direction)
	toward = toward.normalized()
	var right := toward.cross(direction).normalized()
	basis = Basis(right, direction, -toward)


func _set_landed_collision(enabled: bool) -> void:
	if _body != null:
		_body.collision_layer = 1 if enabled else 0
		_body.collision_mask = 0


func interact_prompt() -> String:
	return "Open City Control" if landed else "Settlement Ship in flight"


func interact(player: OnlinePlayer) -> void:
	if landed and player != null:
		player.open_city_menu(colony_site)


func flight_snapshot() -> Dictionary:
	return {
		"snapshot_kind": "settlement_expedition",
		"child_site": String(colony_site),
		"parent_site": String(parent_site),
		"origin_direction": origin_direction,
		"target_direction": target_direction,
		"seed": expedition_seed,
		"founders": founder_manifest.duplicate(true),
		"elapsed": flight_elapsed,
		"landed": landed,
	}


func collision_enabled() -> bool:
	return _body != null and _body.collision_layer != 0


func collision_matches_hull() -> bool:
	var hull := get_node_or_null("Hull") as MeshInstance3D
	var collider := _body.get_child(0) as CollisionShape3D \
		if _body != null and _body.get_child_count() > 0 else null
	var box_mesh := hull.mesh as BoxMesh if hull != null else null
	var box_shape := collider.shape as BoxShape3D if collider != null else null
	return box_mesh != null and box_shape != null \
		and box_mesh.size.is_equal_approx(box_shape.size) \
		and hull.position.is_equal_approx(_body.position) \
		and hull.rotation.is_equal_approx(_body.rotation) \
		and collider.position.is_equal_approx(Vector3.ZERO) \
		and collider.rotation.is_equal_approx(Vector3.ZERO)
