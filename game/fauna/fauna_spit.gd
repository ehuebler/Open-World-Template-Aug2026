class_name FaunaSpit
extends Node3D

## A ball of liquid an animal spits at whoever provoked it.
##
## Built the same way as the boss's thrown rock, and for the same reasons: a body
## this small at this speed would tunnel through whatever it was aimed at, so it
## sweeps the ground it covered each frame instead — a ray for the world and a
## capsule against everyone standing in it, which is what lets it catch a player
## mid-jump. Every peer flies its own copy from the launch the host published, so
## the throw reads the same everywhere; only the host turns a hit into damage.
##
## See [method FaunaMob._launch_spit].

const LIFETIME := 3.0
## Rings out from the ball as it flies, so a wet ball reads as wet rather than as
## a bead of glass. Cheap: two spheres and one light, no particles in flight.
const HALO_SHARE := 2.4
const WOBBLE := 9.0
const SPLASH_TINT_MIX := 0.35

var damage := 8.0
var knockback := 4.0
var gravity := 9.0
var ball_radius := 0.13
var hit_radius := 0.6
var tint := Color(0.58, 0.93, 1.0)
var glow := 1.8
var parryable := true
var spitter: Node

var _velocity := Vector3.ZERO
var _planet: Planet
var _blocker := RID()
var _live := 0.0
var _core: MeshInstance3D
var _halo: MeshInstance3D


## Puts this ball in the air over [param planet] and sets it going, answering
## whether the throw was one that could be made. The animal that spat it is
## skipped by the sweep, and built by the caller rather than by a static factory
## here, so this script never has to name its own global class to construct it.
func launch(planet: Planet, from: Vector3, along: Vector3, by: Node) -> bool:
	if planet == null or not from.is_finite() or not along.is_finite() \
			or along.is_zero_approx():
		return false
	name = "FaunaSpit"
	_velocity = along
	spitter = by
	var body := by as CollisionObject3D
	if body != null:
		_blocker = body.get_rid()
	planet.add_child(self)
	global_position = from
	return true


func _ready() -> void:
	_planet = get_parent() as Planet
	var core_mesh := SphereMesh.new()
	core_mesh.radius = ball_radius
	core_mesh.height = ball_radius * 2.0
	core_mesh.radial_segments = 10
	core_mesh.rings = 6
	_core = MeshInstance3D.new()
	_core.mesh = core_mesh
	_core.material_override = _liquid_material(tint, 0.92, glow)
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)

	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = ball_radius * HALO_SHARE * 0.5
	halo_mesh.height = ball_radius * HALO_SHARE
	halo_mesh.radial_segments = 8
	halo_mesh.rings = 5
	_halo = MeshInstance3D.new()
	_halo.mesh = halo_mesh
	_halo.material_override = _liquid_material(
		tint.lightened(0.2), 0.22, glow * 0.5)
	_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_halo)

	if glow > 0.0:
		var lamp := OmniLight3D.new()
		lamp.light_color = tint
		lamp.light_energy = glow * 0.8
		lamp.omni_range = maxf(ball_radius * 22.0, 2.0)
		lamp.shadow_enabled = false
		add_child(lamp)


## Unshaded and additive: the ball is its own light source, and one that has to
## be picked out against both a bright hillside and a night sky.
static func _liquid_material(colour: Color, alpha: float,
		energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = maxf(energy, 0.0)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.disable_receive_shadows = true
	return material


func _physics_process(delta: float) -> void:
	_live += delta
	if _live >= LIFETIME:
		queue_free()
		return
	var up := _up()
	_velocity -= up * maxf(gravity, 0.0) * delta
	var from := global_position
	var to := from + _velocity * delta
	if _halo != null:
		# A slight breathing wobble, so the ball does not read as a solid pellet.
		var pulse := 1.0 + sin(_live * WOBBLE) * 0.12
		_halo.scale = Vector3(pulse, 1.0 / pulse, pulse)

	var struck := _combatant_along(from, to)
	if not struck.is_empty():
		global_position = struck.get("point", from) as Vector3
		_strike(struck)
		return
	var query := PhysicsRayQueryParameters3D.create(from, to)
	if _blocker.is_valid():
		query.exclude = [_blocker]
	var landed := get_world_3d().direct_space_state.intersect_ray(query)
	if landed.is_empty():
		global_position = to
		return
	global_position = landed["position"]
	_burst(landed.get("normal", up) as Vector3)


## Nearest PLAYER-faction body crossed this step. Data-oriented combatants may
## refine their broad combat node into one actual row; ordinary actors retain
## their spherical combat bounds.
func _combatant_along(from: Vector3, to: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_distance := INF
	var span := from.distance_to(to)
	for combatant_variant: Variant in get_tree().get_nodes_in_group(
			DamageHit.COMBATANT_GROUP):
		var combatant := combatant_variant as Node
		if combatant == null or combatant == spitter \
				or not DamageHit.in_same_world(self, combatant) \
				or not combatant.has_method(&"combat_faction") \
				or int(combatant.call(&"combat_faction")) \
					!= DamageHit.Faction.PLAYER:
			continue
		if combatant.has_method(&"is_dead") \
				and bool(combatant.call(&"is_dead")):
			continue
		var row := -1
		var point := Vector3.ZERO
		var body_point := Vector3.ZERO
		var distance := INF
		if combatant.has_method(&"combat_target_along"):
			var found: Variant = combatant.call(
				&"combat_target_along", from, to, hit_radius)
			if not found is Dictionary or (found as Dictionary).is_empty():
				continue
			var candidate := found as Dictionary
			row = int(candidate.get("row", -1))
			var point_value: Variant = candidate.get("point")
			if row < 0 or not point_value is Vector3:
				continue
			point = point_value as Vector3
			var body_value: Variant = candidate.get("body_point", point)
			body_point = body_value as Vector3 \
				if body_value is Vector3 else point
			distance = float(candidate.get(
				"distance", from.distance_to(point)))
		else:
			var centre := _combat_position(combatant)
			if not centre.is_finite():
				continue
			var bounds := 0.4
			if combatant.has_method(&"combat_radius"):
				bounds = maxf(float(combatant.call(&"combat_radius")), 0.0)
			var entry := _sphere_entry_share(
				from, to, centre, hit_radius + bounds)
			if entry < 0.0:
				continue
			point = from.lerp(to, entry)
			body_point = centre
			distance = span * entry
		if not point.is_finite() or distance >= best_distance:
			continue
		best_distance = distance
		best = {
			"target": combatant,
			"row": row,
			"point": point,
			"body_point": body_point,
			"distance": distance,
		}
	return best


func _strike(struck: Dictionary) -> void:
	var target := struck.get("target") as Node
	var row := int(struck.get("row", -1))
	if _is_host() and target != null:
		var along := _velocity.normalized() \
			if _velocity.length_squared() > 0.01 else -_up()
		var impact_at := struck.get("body_point", global_position) as Vector3 \
			if row >= 0 else global_position
		var hit := DamageHit.impact(impact_at, hit_radius, damage)
		hit.faction = DamageHit.Faction.ENEMY
		hit.parryable = parryable
		# A wet slap staggers rather than knocks down: this is an animal warning
		# somebody off, not the boss taking them off their feet.
		hit.reaction = DamageHit.Reaction.STAGGER
		hit.world_impulse = along * knockback + _up() * knockback * 0.2
		hit.ability_id = "fauna_spit"
		hit.set_source(spitter)
		if row >= 0 and target.has_method(&"apply_damage_to_row"):
			target.call(&"apply_damage_to_row", row, hit)
		elif target.has_method(&"apply_damage"):
			hit.target_peer = _peer_of(target)
			target.call(&"apply_damage", hit)
	_burst(-_velocity.normalized() if _velocity.length_squared() > 0.01 \
		else _up())


func _burst(normal: Vector3) -> void:
	var effects := get_tree().get_first_node_in_group(&"impact_break_effects")
	if effects != null and effects.has_method(&"play_break"):
		var facing := normal if normal.length_squared() > 0.0001 else _up()
		effects.call(&"play_break", global_position, facing,
			_velocity.length() * 0.5, maxf(ball_radius * 3.4, 0.2),
			tint.lerp(Color(0.86, 0.97, 1.0), SPLASH_TINT_MIX),
			ImpactBreakEffects.Preset.CRYSTAL)
	queue_free()


func _sphere_entry_share(from: Vector3, to: Vector3,
		centre: Vector3, radius: float) -> float:
	var along := to - from
	var span := along.length_squared()
	var offset := from - centre
	var radius_squared := maxf(radius, 0.0) * maxf(radius, 0.0)
	if offset.length_squared() <= radius_squared:
		return 0.0
	if span < 0.000001:
		return -1.0
	var b := 2.0 * offset.dot(along)
	var c := offset.length_squared() - radius_squared
	var discriminant := b * b - 4.0 * span * c
	if discriminant < 0.0:
		return -1.0
	var entry := (-b - sqrt(discriminant)) / (2.0 * span)
	return entry if entry >= 0.0 and entry <= 1.0 else -1.0


func _combat_position(target: Node) -> Vector3:
	if target.has_method(&"combat_position"):
		var value: Variant = target.call(&"combat_position")
		if value is Vector3:
			return value as Vector3
	if target is Node3D:
		return (target as Node3D).global_position
	return Vector3(INF, INF, INF)


func _peer_of(target: Node) -> int:
	if target.has_method(&"combat_peer_id"):
		return int(target.call(&"combat_peer_id"))
	var peer: Variant = target.get("peer_id")
	return int(peer) if peer != null else 0


func _up() -> Vector3:
	if _planet != null:
		return _planet.up_at(global_position)
	return Vector3.UP


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()
