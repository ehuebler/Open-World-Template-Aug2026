class_name AbilityProjectile
extends Node3D

## Runtime projectile selected by AbilityDefinition.projectile_type.
##
## The projectile is simulated visually on every peer, while only the owning
## peer dispatches its definition's impact. Damage and terrain then use their
## existing host-approved replication paths.

var shooter: OnlinePlayer
var definition: AbilityDefinition
var stats: Dictionary = {}
var authoritative := false

var _along := Vector3.FORWARD
var _velocity := Vector3.FORWARD
var _speed := 1.0
var _range := 1.0
var _travelled := 0.0
var _shooter_rid := RID()
var _disk: MeshInstance3D
var _poke_ball_releasing := false


static func launch(world: Node, source: OnlinePlayer, ability_id: String,
		from: Vector3, along: Vector3, owns_impact: bool,
		inherited_velocity: Vector3 = Vector3.ZERO,
		poke_ball_releasing := false,
		resolved_stats: Dictionary = {}) -> AbilityProjectile:
	var authored := ItemDB.ability_definition(ability_id)
	if world == null or source == null or authored == null \
			or authored.projectile_type == AbilityDefinition.ProjectileType.NONE:
		return null
	var projectile := AbilityProjectile.new()
	projectile.shooter = source
	projectile.definition = authored
	projectile.stats = resolved_stats.duplicate(true) \
		if not resolved_stats.is_empty() else source.ability_stats(ability_id)
	projectile.authoritative = owns_impact
	projectile._along = along.normalized() \
		if along.length_squared() > 0.001 else -source.global_basis.z
	projectile._speed = maxf(float(projectile.stats.get("speed", 1.0)), 1.0)
	var carried := inherited_velocity if inherited_velocity.is_finite() \
		else Vector3.ZERO
	projectile._velocity = projectile._along * projectile._speed + carried
	projectile._range = maxf(float(projectile.stats.get("range", 1.0)), 1.0)
	projectile._shooter_rid = source.get_rid()
	projectile._poke_ball_releasing = poke_ball_releasing
	world.add_child(projectile)
	projectile.global_position = from
	var facing := projectile._velocity.normalized() \
		if projectile._velocity.length_squared() > 0.001 else projectile._along
	projectile.look_at(from + facing, source.global_basis.y)
	return projectile


func _ready() -> void:
	match definition.projectile_type:
		AbilityDefinition.ProjectileType.ENERGY_DISK:
			_build_energy_disk()
		AbilityDefinition.ProjectileType.ENERGY_ORB:
			_build_energy_orb()
		AbilityDefinition.ProjectileType.POKE_BALL:
			_build_poke_ball()
		_:
			queue_free()


func _build_energy_disk() -> void:
	var quoted_radius := maxf(
		float(stats.get("projectile_radius", 0.36)), 0.08)
	var mesh := CylinderMesh.new()
	mesh.top_radius = quoted_radius
	mesh.bottom_radius = quoted_radius
	mesh.height = maxf(quoted_radius * 0.18, 0.035)
	mesh.radial_segments = 24
	mesh.rings = 1

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = definition.tint
	material.emission_enabled = true
	material.emission = definition.tint
	material.emission_energy_multiplier = 4.2
	mesh.material = material

	_disk = MeshInstance3D.new()
	_disk.mesh = mesh
	# CylinderMesh stands on Y already. Keeping that spin axis aligned with the
	# launch up makes the thin rim lead and the broad faces ride above and below
	# the path, like a thrown frisbee rather than a coin flying face-first.
	add_child(_disk)

	var light := OmniLight3D.new()
	light.light_color = definition.tint
	light.light_energy = 2.4
	light.omni_range = maxf(quoted_radius * 7.0, 2.5)
	add_child(light)


func _build_energy_orb() -> void:
	var quoted_radius := maxf(
		float(stats.get("projectile_radius", 1.0)), 0.15)
	var sphere := SphereMesh.new()
	sphere.radius = quoted_radius
	sphere.height = quoted_radius * 2.0
	sphere.radial_segments = 28
	sphere.rings = 16
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = definition.tint.lightened(0.28)
	material.emission_enabled = true
	material.emission = definition.tint
	material.emission_energy_multiplier = 7.5
	sphere.material = material
	_disk = MeshInstance3D.new()
	_disk.mesh = sphere
	_disk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disk)

	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = quoted_radius * 1.32
	halo_mesh.height = quoted_radius * 2.64
	halo_mesh.radial_segments = 24
	halo_mesh.rings = 12
	var halo_material := StandardMaterial3D.new()
	halo_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	halo_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	halo_material.albedo_color = Color(definition.tint, 0.38)
	halo_material.emission_enabled = true
	halo_material.emission = definition.tint
	halo_material.emission_energy_multiplier = 4.5
	halo_mesh.material = halo_material
	var halo := MeshInstance3D.new()
	halo.mesh = halo_mesh
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(halo)

	var light := OmniLight3D.new()
	light.light_color = definition.tint
	light.light_energy = 5.5
	light.omni_range = maxf(quoted_radius * 10.0, 7.0)
	add_child(light)


func _build_poke_ball() -> void:
	var quoted_radius := maxf(
		float(stats.get("projectile_radius", 0.28)), 0.12)
	var white := StandardMaterial3D.new()
	white.albedo_color = Color("f4f7fb")
	white.metallic = 0.08
	white.roughness = 0.3

	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("121720")
	dark.metallic = 0.22
	dark.roughness = 0.24

	var red := StandardMaterial3D.new()
	red.albedo_color = definition.tint
	red.metallic = 0.08
	red.roughness = 0.28

	var sphere := SphereMesh.new()
	sphere.radius = quoted_radius
	sphere.height = quoted_radius * 2.0
	sphere.radial_segments = 28
	sphere.rings = 16
	sphere.material = white
	_disk = MeshInstance3D.new()
	_disk.name = &"Ball"
	_disk.mesh = sphere
	add_child(_disk)

	# A slightly larger upper hemisphere avoids coplanar flicker while leaving
	# the white lower shell visible.
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = quoted_radius * 1.008
	cap_mesh.height = quoted_radius * 2.016
	cap_mesh.radial_segments = 28
	cap_mesh.rings = 8
	cap_mesh.is_hemisphere = true
	cap_mesh.material = red
	var cap := MeshInstance3D.new()
	cap.name = &"RedCap"
	cap.mesh = cap_mesh
	_disk.add_child(cap)

	var band_mesh := TorusMesh.new()
	band_mesh.inner_radius = quoted_radius * 0.88
	band_mesh.outer_radius = quoted_radius * 1.025
	band_mesh.rings = 32
	band_mesh.ring_segments = 8
	band_mesh.material = dark
	var band := MeshInstance3D.new()
	band.name = &"Band"
	band.mesh = band_mesh
	_disk.add_child(band)

	var button_back_mesh := CylinderMesh.new()
	button_back_mesh.top_radius = quoted_radius * 0.28
	button_back_mesh.bottom_radius = quoted_radius * 0.28
	button_back_mesh.height = quoted_radius * 0.13
	button_back_mesh.radial_segments = 20
	button_back_mesh.material = dark
	var button_back := MeshInstance3D.new()
	button_back.name = &"ButtonBack"
	button_back.mesh = button_back_mesh
	button_back.position = Vector3(0.0, 0.0, -quoted_radius * 1.015)
	button_back.rotation.x = PI * 0.5
	_disk.add_child(button_back)

	var button_mesh := CylinderMesh.new()
	button_mesh.top_radius = quoted_radius * 0.17
	button_mesh.bottom_radius = quoted_radius * 0.17
	button_mesh.height = quoted_radius * 0.145
	button_mesh.radial_segments = 20
	button_mesh.material = white
	var button := MeshInstance3D.new()
	button.name = &"Button"
	button.mesh = button_mesh
	button.position = Vector3(0.0, 0.0, -quoted_radius * 1.055)
	button.rotation.x = PI * 0.5
	_disk.add_child(button)

	var light := OmniLight3D.new()
	light.light_color = definition.tint
	light.light_energy = 0.65
	light.omni_range = maxf(quoted_radius * 8.0, 2.2)
	add_child(light)


func _physics_process(delta: float) -> void:
	if not is_instance_valid(shooter) or definition == null \
			or not is_instance_valid(_disk):
		queue_free()
		return
	var step_vector := _velocity * delta
	var from := global_position
	var to := from + step_vector
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [_shooter_rid] if _shooter_rid.is_valid() else []
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit["position"]
		if authoritative:
			var normal: Vector3 = hit.get("normal", -_along)
			_resolve_authoritative_impact(hit, normal)
		queue_free()
		return
	global_position = to
	# Range is relative to the thrower at the instant of release. Inherited
	# player motion moves the whole flight through the world without consuming
	# the disk's authored 70 m of forward travel in a handful of frames.
	_travelled += _speed * delta
	if definition.projectile_type == AbilityDefinition.ProjectileType.POKE_BALL:
		_disk.rotate_object_local(Vector3.RIGHT, delta * 10.0)
		_disk.rotate_object_local(Vector3.FORWARD, delta * 4.0)
	else:
		_disk.rotation.y += delta * 24.0
	if _travelled >= _range:
		if authoritative:
			var facing := -_velocity.normalized() \
				if _velocity.length_squared() > 0.001 else -_along
			if definition.projectile_type \
					== AbilityDefinition.ProjectileType.POKE_BALL:
				_resolve_authoritative_impact({}, facing)
			elif definition.projectile_type \
					== AbilityDefinition.ProjectileType.ENERGY_ORB:
				AbilityImpact.apply(
					shooter, definition, global_position, facing)
		queue_free()


func _resolve_authoritative_impact(hit: Dictionary, normal: Vector3) -> void:
	if definition.projectile_type != AbilityDefinition.ProjectileType.POKE_BALL:
		AbilityImpact.apply(shooter, definition, global_position, normal)
		return
	var collider_value: Variant = hit.get("collider")
	var collider := collider_value as Node if collider_value is Node else null
	shooter.resolve_poke_ball_impact(
		collider, global_position, normal, _poke_ball_releasing)
