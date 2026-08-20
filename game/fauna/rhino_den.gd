class_name RhinoDen
extends StaticBody3D

## A solid cave facade embedded into steep terrain near the Cinder-Plate herd.
##
## The host owns health and the spawn clock. Geometry is deliberately built from
## a handful of primitives: there is only one den, its broad UV paint gives the
## rocks their authored strata, and a backing slab makes the dark mouth read as
## depth without creating an interior players can enter.

signal health_changed(current: float, maximum: float)
signal destroyed

const ROCK_PAINT: Texture2D = preload(
	"res://assets/runtime/biomes/paint/cinder_plate_rhino_den_paint.png")

const MAXIMUM_HEALTH := 520.0
const DAMAGE_SHARE := 0.45
const FIRST_SPAWN_DELAY := 8.0
const SPAWN_INTERVAL := 58.0
const FULL_RETRY_DELAY := 8.0
const FLASH_SECONDS := 0.14
const DEN_HEIGHT := 5.8
const DEN_WIDTH := 8.4

var _spawner: Node
var _initial_transform := Transform3D.IDENTITY
var _exit_transform := Transform3D.IDENTITY
var _cliff_slope := 0.0
var _health := MAXIMUM_HEALTH
var _alive := true
var _spawn_left := FIRST_SPAWN_DELAY
var _flash_left := 0.0
var _state_sequence := 0
var _last_state_sequence := -1

var _visuals: Node3D
var _rubble: Node3D
var _collision: CollisionShape3D
var _collisions: Array[CollisionShape3D] = []
var _rock_material: StandardMaterial3D
var _dark_material: StandardMaterial3D


func configure(at: Transform3D, exit_at: Transform3D, cliff_slope: float,
		owner: Node) -> void:
	_initial_transform = at
	_exit_transform = exit_at
	_cliff_slope = maxf(cliff_slope, 0.0)
	_spawner = owner


func _ready() -> void:
	global_transform = _initial_transform
	collision_layer = 1
	collision_mask = 0
	add_to_group(DamageHit.COMBATANT_GROUP)
	add_to_group(&"rhino_dens")
	_build_materials()
	_build_visuals()
	_build_collision()
	_update_presentation()


func _process(delta: float) -> void:
	_flash_left = maxf(_flash_left - delta, 0.0)
	_update_flash()
	if not _alive or not _is_host():
		return
	_spawn_left = maxf(_spawn_left - delta, 0.0)
	if _spawn_left > 0.0:
		return
	var spawned := _spawner != null \
		and _spawner.has_method(&"spawn_rhino_from_den") \
		and bool(_spawner.call(&"spawn_rhino_from_den", self))
	_spawn_left = SPAWN_INTERVAL if spawned else FULL_RETRY_DELAY
	if spawned:
		_publish_state()


func combat_faction() -> int:
	return DamageHit.Faction.ENEMY


func combat_peer_id() -> int:
	return 0


func combat_display_name() -> String:
	return "Cinder-Plate Rhino Den"


func combat_position() -> Vector3:
	return global_position + global_basis.y.normalized() * DEN_HEIGHT * 0.46


func combat_radius() -> float:
	return DEN_WIDTH * 0.55


func health() -> float:
	return _health


func maximum_health() -> float:
	return MAXIMUM_HEALTH


func is_alive() -> bool:
	return _alive


func is_destroyed() -> bool:
	return not _alive


func apply_damage(hit: DamageHit) -> float:
	if hit == null or not _alive or not _is_host() \
			or hit.faction != DamageHit.Faction.PLAYER:
		return 0.0
	var delivered := maxf(hit.amount, 0.0) * DAMAGE_SHARE \
		if is_finite(hit.amount) else 0.0
	var actual := minf(delivered, _health)
	if actual <= 0.0:
		return 0.0
	_health -= actual
	_flash_left = FLASH_SECONDS
	health_changed.emit(_health, MAXIMUM_HEALTH)
	if _health <= 0.0:
		_alive = false
		_spawn_left = 0.0
		_update_presentation()
		_play_break_effect(maxf(hit.amount, 8.0))
		destroyed.emit()
	_publish_state()
	return actual


func state_wire() -> Dictionary:
	return {
		"sequence": _state_sequence,
		"health": _health,
		"alive": _alive,
		"spawn_left": _spawn_left,
		"flash": _flash_left,
	}


func apply_network_state(wire: Dictionary, snap := false) -> void:
	var sequence := int(wire.get("sequence", _last_state_sequence + 1))
	if not snap and sequence <= _last_state_sequence:
		return
	_last_state_sequence = maxi(sequence, _last_state_sequence)
	_state_sequence = maxi(sequence, _state_sequence)
	var was_alive := _alive
	_health = clampf(
		float(wire.get("health", _health)), 0.0, MAXIMUM_HEALTH)
	_alive = bool(wire.get("alive", _health > 0.0))
	_spawn_left = maxf(float(wire.get("spawn_left", _spawn_left)), 0.0)
	_flash_left = maxf(float(wire.get("flash", _flash_left)), 0.0)
	_update_presentation()
	health_changed.emit(_health, MAXIMUM_HEALTH)
	if was_alive and not _alive and not snap:
		_play_break_effect(MAXIMUM_HEALTH)
		destroyed.emit()


func exit_transform() -> Transform3D:
	return _exit_transform


func cliff_slope_degrees() -> float:
	return _cliff_slope


func spawn_left() -> float:
	return _spawn_left


func make_spawn_due() -> void:
	if _is_host() and _alive:
		_spawn_left = 0.0


func _publish_state() -> void:
	_state_sequence += 1
	if _spawner != null and _spawner.has_method(&"publish_rhino_den_state"):
		_spawner.call(&"publish_rhino_den_state", state_wire())


func _build_materials() -> void:
	_rock_material = StandardMaterial3D.new()
	_rock_material.resource_name = "Rhino Den Painted Strata"
	_rock_material.albedo_texture = ROCK_PAINT
	_rock_material.albedo_color = Color(0.86, 0.88, 1.0)
	_rock_material.roughness = 0.88
	_rock_material.metallic = 0.04
	_rock_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	_dark_material = StandardMaterial3D.new()
	_dark_material.resource_name = "Rhino Den Unlit Depth"
	_dark_material.albedo_color = Color(0.012, 0.008, 0.018)
	_dark_material.roughness = 1.0


func _build_visuals() -> void:
	_visuals = Node3D.new()
	_visuals.name = &"Visuals"
	add_child(_visuals)
	_rubble = Node3D.new()
	_rubble.name = &"DestroyedRubble"
	add_child(_rubble)

	var boulder := _make_boulder_mesh()

	# A short natural bluff makes the selected slope read as a cliff even where
	# the height field rolls gradually between its steeper samples.
	var shoulder_positions := [
		Vector3(-4.25, 1.45, 1.12),
		Vector3(-3.52, 3.40, 1.42),
		Vector3(4.08, 1.62, 1.04),
		Vector3(3.68, 3.52, 1.55),
	]
	var shoulder_scales := [
		Vector3(2.12, 1.72, 1.42),
		Vector3(1.82, 1.44, 1.54),
		Vector3(2.02, 1.86, 1.34),
		Vector3(1.72, 1.38, 1.50),
	]
	for index in shoulder_positions.size():
		_add_mesh(_visuals, "CliffShoulder%d" % index, boulder,
			shoulder_positions[index], shoulder_scales[index],
			_rock_material,
			Vector3(0.08 * index, -0.11 + 0.09 * index,
				-0.10 + 0.07 * index))
	for index in 4:
		_add_mesh(_visuals, "CliffCap%d" % index, boulder,
			Vector3(-3.05 + index * 2.05,
				4.38 + 0.24 * ((index + 1) % 2), 1.32),
			Vector3(1.52, 1.08 + 0.10 * (index % 2), 1.48),
			_rock_material,
			Vector3(0.08 * index, -0.10 * index, 0.07 * (index - 1)))

	# Recessed oval and lower shadow together form one arch-shaped black mouth.
	_add_mesh(_visuals, "CaveShadow", boulder,
		Vector3(0.0, 1.75, 0.36), Vector3(2.05, 1.55, 0.18),
		_dark_material)
	var lower_shadow := BoxMesh.new()
	lower_shadow.size = Vector3(4.08, 1.7, 0.34)
	_add_mesh(_visuals, "LowerShadow", lower_shadow,
		Vector3(0.0, 0.82, 0.38), Vector3.ONE, _dark_material)

	# Irregular plated stones around the mouth. Wide scales keep the paint's
	# strata readable from the settlement instead of turning into texture noise.
	for index in 11:
		var share := float(index) / 10.0
		var angle := lerpf(PI, 0.0, share)
		var position := Vector3(
			cos(angle) * 2.32,
			1.58 + sin(angle) * 1.77,
			0.02 - 0.11 * sin(angle))
		var scale := Vector3(
			0.72 + 0.13 * sin(index * 2.17),
			0.62 + 0.15 * cos(index * 1.43),
			0.58 + 0.10 * sin(index * 0.91))
		_add_mesh(_visuals, "ArchRock%d" % index, boulder,
			position, scale, _rock_material,
			Vector3(0.12 * sin(index), 0.18 * cos(index * 0.7),
				0.15 * sin(index * 1.8)))

	for side in [-1.0, 1.0]:
		for row in 2:
			_add_mesh(_visuals,
				"Pillar_%s_%d" % ["L" if side < 0.0 else "R", row],
				boulder,
				Vector3(side * (2.30 + row * 0.08), 0.48 + row * 0.78, 0.0),
				Vector3(0.78, 0.70, 0.68) * (1.0 - row * 0.07),
				_rock_material,
				Vector3(row * 0.2, side * 0.12, side * row * 0.16))

	for index in 7:
		_add_mesh(_visuals, "ThresholdRock%d" % index, boulder,
			Vector3(-2.55 + index * 0.85,
				0.02 + 0.04 * (index % 2), -0.70 - 0.08 * absf(3 - index)),
			Vector3(0.62, 0.18, 0.70), _rock_material,
			Vector3(0.0, index * 0.31, 0.05 * (index - 3)))

	for index in 7:
		_add_mesh(_rubble, "Rubble%d" % index, boulder,
			Vector3(-2.1 + index * 0.7, 0.18,
				-0.25 - absf(3.0 - index) * 0.13),
			Vector3(0.50 + 0.08 * (index % 2), 0.20, 0.42),
			_rock_material,
			Vector3(index * 0.31, index * 0.18, index * 0.27))


func _make_boulder_mesh() -> ArrayMesh:
	const SEGMENTS := 8
	var vertices := PackedVector3Array([Vector3(0.0, 1.0, 0.0)])
	for ring in 2:
		var y := 0.46 if ring == 0 else -0.48
		var base_radius := 0.76 if ring == 0 else 0.92
		for segment in SEGMENTS:
			var angle := TAU * float(segment) / float(SEGMENTS)
			var radius := base_radius * (
				1.0 + 0.09 * sin(segment * 2.31 + ring * 1.77))
			vertices.append(Vector3(
				cos(angle) * radius,
				y + 0.06 * sin(segment * 1.61 + ring),
				sin(angle) * radius * (
					0.82 + 0.07 * cos(segment * 1.37))))
	var bottom := vertices.size()
	vertices.append(Vector3(0.0, -0.94, 0.0))
	var faces: Array[PackedInt32Array] = []
	for segment in SEGMENTS:
		var next := (segment + 1) % SEGMENTS
		var upper := 1 + segment
		var next_upper := 1 + next
		var lower := 1 + SEGMENTS + segment
		var next_lower := 1 + SEGMENTS + next
		faces.append(PackedInt32Array([0, next_upper, upper]))
		faces.append(PackedInt32Array([
			upper, next_upper, next_lower, lower]))
		faces.append(PackedInt32Array([bottom, lower, next_lower]))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face: PackedInt32Array in faces:
		var indices := [face[0], face[1], face[2]] \
			if face.size() == 3 \
			else [face[0], face[1], face[2],
				face[0], face[2], face[3]]
		for index in indices:
			var vertex := vertices[index]
			surface.set_uv(Vector2(
				atan2(vertex.z, vertex.x) / TAU + 0.5,
				vertex.y * 0.44 + 0.5))
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()


func _add_mesh(parent: Node3D, node_name: String, mesh: Mesh,
		position: Vector3, scale: Vector3, material: Material,
		rotation := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = position
	instance.scale = scale
	instance.rotation = rotation
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _build_collision() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(4.35, 3.15, 0.64)
	_collision = CollisionShape3D.new()
	_collision.name = &"SealedEntrance"
	_collision.position = Vector3(0.0, 1.48, 0.28)
	_collision.shape = shape
	add_child(_collision)
	_collisions.append(_collision)
	for side in [-1.0, 1.0]:
		_add_collision(
			"CliffShoulderCollisionL" if side < 0.0
				else "CliffShoulderCollisionR",
			Vector3(side * 3.75, 2.25, 0.85),
			Vector3(3.0, 4.5, 2.1))
	_add_collision("CliffCapCollision",
		Vector3(0.0, 4.45, 0.9), Vector3(4.4, 2.0, 2.1))


func _add_collision(node_name: String, position: Vector3,
		size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var collision := CollisionShape3D.new()
	collision.name = node_name
	collision.position = position
	collision.shape = shape
	add_child(collision)
	_collisions.append(collision)


func _update_presentation() -> void:
	if _visuals != null:
		_visuals.visible = _alive
	if _rubble != null:
		_rubble.visible = not _alive
	for collision in _collisions:
		if collision != null:
			collision.set_deferred(&"disabled", not _alive)


func _update_flash() -> void:
	if _rock_material == null:
		return
	var share := _flash_left / FLASH_SECONDS if _flash_left > 0.0 else 0.0
	_rock_material.albedo_color = Color(0.86, 0.88, 1.0).lerp(
		Color(1.45, 0.62, 0.34), share)


func _play_break_effect(strength: float) -> void:
	if not is_inside_tree():
		return
	var effects := get_tree().get_first_node_in_group(&"impact_break_effects")
	if effects != null and effects.has_method(&"play_break"):
		effects.call(&"play_break", combat_position(), global_basis.y.normalized(),
			strength, DEN_HEIGHT, Color(0.48, 0.43, 0.62),
			ImpactBreakEffects.Preset.CRYSTAL)


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()
