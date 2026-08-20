class_name BossProjectile
extends Node3D

## Lightweight projectile used by the built-in projectile move. The host owns
## damage; listeners only reproduce the deterministic flight and visual.

var _projectile_source: Node
var _projectile_authoritative := false
var _projectile_velocity := Vector3.ZERO
var _projectile_acceleration := Vector3.ZERO
var _projectile_life := 0.0
var _projectile_radius := 0.5
var _projectile_damage := 0.0
var _projectile_target_peer := 0
var _projectile_ability := ""
var _projectile_reaction := DamageHit.Reaction.NONE
var _projectile_impulse := Vector3.ZERO
var _projectile_parryable := false
var _projectile_reflection := 0.0
var _projectile_blocked_by_world := false


func configure(
		source: Node, payload: Dictionary, authoritative: bool) -> void:
	_projectile_source = source
	_projectile_authoritative = authoritative
	var origin: Variant = payload.get("origin", global_position)
	if origin is Vector3 and (origin as Vector3).is_finite():
		global_position = origin
	var launch: Variant = payload.get("velocity", Vector3.ZERO)
	if launch is Vector3 and (launch as Vector3).is_finite():
		_projectile_velocity = launch
	var acceleration: Variant = payload.get("acceleration", Vector3.ZERO)
	if acceleration is Vector3 and (acceleration as Vector3).is_finite():
		_projectile_acceleration = acceleration
	_projectile_life = _finite_positive(payload.get("lifetime", 4.0), 4.0)
	_projectile_radius = _finite_positive(payload.get("radius", 0.5), 0.5)
	_projectile_damage = _finite_nonnegative(payload.get("damage", 0.0), 0.0)
	_projectile_target_peer = maxi(int(payload.get("target_peer", 0)), 0)
	_projectile_ability = String(payload.get("ability_id", "boss_projectile"))
	_projectile_reaction = clampi(
		int(payload.get("reaction", DamageHit.Reaction.NONE)),
		DamageHit.Reaction.NONE,
		DamageHit.Reaction.RAGDOLL)
	var impulse: Variant = payload.get("world_impulse", Vector3.ZERO)
	if impulse is Vector3 and (impulse as Vector3).is_finite():
		_projectile_impulse = impulse
	_projectile_parryable = bool(payload.get("parryable", false))
	_projectile_reflection = _finite_nonnegative(
		payload.get("reflection", 0.0), 0.0)
	_projectile_blocked_by_world = bool(
		payload.get("blocked_by_world", false))
	_build_visual(payload)


func _physics_process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_projectile_life -= delta
	if _projectile_life <= 0.0:
		queue_free()
		return
	var previous := global_position
	_projectile_velocity += _projectile_acceleration * delta
	global_position += _projectile_velocity * delta
	if _projectile_velocity.length_squared() > 0.000001:
		look_at(global_position + _projectile_velocity, global_basis.y)
	if _projectile_authoritative and _projectile_damage > 0.0:
		var hit := DamageHit.beam(
			previous,
			global_position,
			_projectile_radius,
			_projectile_damage)
		hit.faction = DamageHit.Faction.ENEMY
		hit.target_peer = _projectile_target_peer
		hit.ability_id = _projectile_ability
		hit.reaction = _projectile_reaction
		hit.world_impulse = _projectile_impulse
		hit.parryable = _projectile_parryable
		hit.reflection = _projectile_reflection
		hit.blocked_by_world = _projectile_blocked_by_world
		hit.set_source(_projectile_source)
		if DamageHit.apply_to_combatants(self, hit) > 0.0:
			queue_free()


func _build_visual(payload: Dictionary) -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Visual"
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sphere := SphereMesh.new()
	var visual_size := _finite_positive(
		payload.get("visual_size", _projectile_radius), _projectile_radius)
	sphere.radius = visual_size
	sphere.height = visual_size * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var material := StandardMaterial3D.new()
	var color := Color(1.0, 0.35, 0.08)
	var authored: Variant = payload.get("color", "")
	if authored is String and not String(authored).is_empty():
		color = Color.from_string(String(authored), color)
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.5
	sphere.material = material
	mesh_instance.mesh = sphere
	add_child(mesh_instance)


static func _finite_positive(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		var number := float(value)
		if is_finite(number) and number > 0.0:
			return number
	return fallback


static func _finite_nonnegative(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		var number := float(value)
		if is_finite(number) and number >= 0.0:
			return number
	return fallback
