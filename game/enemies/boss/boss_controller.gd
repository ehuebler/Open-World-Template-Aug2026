class_name BossController
extends CharacterBody3D

## Shared boss runtime. Every stored state value and signal is framework-prefixed
## so authored subclasses can retain their existing state machines unchanged.
## Calling super._ready() is safe for custom controllers: generic processing and
## generic RPC publication only run when the definition explicitly opts in.

signal framework_health_changed(current: float, maximum: float)
signal framework_engaged_changed(engaged: bool)
signal framework_damaged_flash(strength: float)
signal framework_arena_reset
signal framework_defeated

const _FRAMEWORK_ARENA := preload(
	"res://game/enemies/boss/boss_arena.gd")
const _FRAMEWORK_MOVE_REGISTRY := preload(
	"res://game/enemies/boss/boss_move_registry.gd")
const _FRAMEWORK_PRETRIGGER_REGISTRY := preload(
	"res://game/enemies/boss/boss_pretrigger_registry.gd")
const _FRAMEWORK_REPLICATION := preload(
	"res://game/enemies/boss/boss_replication.gd")
const _FRAMEWORK_PROJECTILE := preload(
	"res://game/enemies/boss/boss_projectile.gd")

@export var definition_id := ""

var _framework_definition: BossDefinition
var _framework_generic_enabled := false
var _framework_model: Node3D
var _framework_animator: AnimationPlayer
var _framework_boundary: Node

var _framework_health := 1.0
var _framework_engaged := false
var _framework_defeated := false
var _framework_target_peer := 0
var _framework_spawn_transform := Transform3D.IDENTITY
var _framework_arena_empty_time := 0.0

var _framework_moves: Dictionary = {}
var _framework_move_order: Array[StringName] = []
var _framework_active_move: BossMove
var _framework_move_cursor := 0
var _framework_pretriggers: Array[BossPretrigger] = []
var _framework_players: Array[Node3D] = []

var _framework_replication: BossReplication
var _framework_clip := &""
var _framework_clip_speed := 1.0
var _framework_clip_playing := &""
var _framework_clip_seek := -1.0
var _framework_clip_sequence := 0

var _framework_target_transform := Transform3D.IDENTITY
var _framework_target_velocity := Vector3.ZERO
var _framework_has_target_transform := false


func _ready() -> void:
	add_to_group(BossAdapter.GROUP)
	add_to_group(DamageHit.COMBATANT_GROUP)
	_framework_load_definition()
	_framework_generic_enabled = _framework_definition != null \
		and _framework_definition.controller_mode == &"generic"
	_framework_bind_visuals()
	_framework_spawn_transform = global_transform
	_framework_replication = _FRAMEWORK_REPLICATION.new().configure(self)
	_framework_initialize_state()
	_framework_initialize_moves()
	_framework_initialize_pretriggers()
	framework_play_animation_role(&"rest")
	if _framework_generic_enabled and framework_is_host():
		_framework_publish_snapshot(true)
	elif _framework_generic_enabled:
		_framework_target_transform = global_transform
		_framework_target_velocity = velocity
		_framework_has_target_transform = true


func _physics_process(delta: float) -> void:
	if not _framework_generic_enabled:
		return
	if framework_is_host():
		_framework_tick_host(delta)
		if _framework_replication.snapshot_due(delta):
			_framework_publish_snapshot(false)
	else:
		_framework_tick_listener(delta)
	_framework_update_presentation()


# --- Definition and authored lookup ----------------------------------------

func boss_id() -> String:
	if not definition_id.strip_edges().is_empty():
		return definition_id.strip_edges()
	var script := get_script() as Script
	if script != null:
		var constants: Dictionary = script.get_script_constant_map()
		var authored: Variant = constants.get("BOSS_ID", "")
		if authored is String or authored is StringName:
			return String(authored)
	return ""


func definition() -> BossDefinition:
	return _framework_definition


func animation_for(
		role: StringName, subrole: StringName = &"") -> StringName:
	return _framework_definition.animation(role, subrole) \
		if _framework_definition != null else &""


func move_definition(id: StringName) -> Dictionary:
	if _framework_definition == null:
		return {}
	for value: Variant in _framework_definition.moves:
		if value is Dictionary \
				and String((value as Dictionary).get("id", "")) == String(id):
			return (value as Dictionary).duplicate(true)
	return {}


func move_animation(id: StringName, stage: StringName) -> StringName:
	var move := move_definition(id)
	var mappings: Variant = move.get("animations", {})
	if mappings is Dictionary:
		var clip: Variant = (mappings as Dictionary).get(String(stage), "")
		if clip is String or clip is StringName:
			return StringName(String(clip))
	return &""


func move_module(id: StringName) -> BossMove:
	return _framework_moves.get(String(id)) as BossMove


func framework_model() -> Node3D:
	return _framework_model


func framework_animation_player() -> AnimationPlayer:
	return _framework_animator


func framework_replication() -> BossReplication:
	return _framework_replication


func _framework_load_definition() -> void:
	var resolved := definition_id.strip_edges()
	if resolved.is_empty():
		resolved = boss_id().strip_edges()
	if resolved.is_empty():
		push_error("BossController could not derive a definition_id")
		return
	definition_id = resolved
	_framework_definition = BossCatalog.definition(resolved)
	if _framework_definition == null:
		push_error("BossController definition '%s' could not be loaded" % resolved)


func _framework_bind_visuals() -> void:
	_framework_model = get_node_or_null(^"Model") as Node3D
	if _framework_model == null:
		_framework_model = self
	_framework_animator = _framework_model.find_child(
		"AnimationPlayer", true, false) as AnimationPlayer
	_framework_boundary = get_node_or_null(^"ArenaBoundary")
	if _framework_definition == null \
			or _framework_definition.material_override == null:
		return
	for node: Node in _framework_model.find_children(
			"*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override \
			= _framework_definition.material_override


func _framework_initialize_state() -> void:
	var maximum := _framework_definition.max_health \
		if _framework_definition != null else 1.0
	_framework_health = maxf(maximum, 0.001)
	_framework_engaged = false
	_framework_defeated = false
	_framework_target_peer = 0
	_framework_arena_empty_time = 0.0
	velocity = Vector3.ZERO


func _framework_initialize_moves() -> void:
	_framework_moves.clear()
	_framework_move_order.clear()
	_framework_active_move = null
	_framework_move_cursor = 0
	if _framework_definition == null:
		return
	for value: Variant in _framework_definition.moves:
		if not value is Dictionary:
			continue
		var move_data := value as Dictionary
		var id := String(move_data.get("id", ""))
		var behavior := StringName(String(move_data.get("behavior", "")))
		var module := _FRAMEWORK_MOVE_REGISTRY.create(behavior)
		if module == null:
			if _framework_generic_enabled:
				push_error(
					"Boss '%s' has no move implementation for '%s'"
					% [boss_id(), behavior])
			continue
		module.configure(self, move_data)
		_framework_moves[id] = module
		_framework_move_order.append(StringName(id))


func _framework_initialize_pretriggers() -> void:
	_framework_pretriggers.clear()
	if _framework_definition == null:
		return
	for value: String in _framework_definition.pretriggers:
		var pretrigger := _FRAMEWORK_PRETRIGGER_REGISTRY.create(
			StringName(value), self)
		if pretrigger != null:
			_framework_pretriggers.append(pretrigger)


# --- Generic host state -----------------------------------------------------

func _framework_tick_host(delta: float) -> void:
	_framework_collect_players()
	if _framework_defeated:
		framework_stop_movement()
		return
	if not _framework_engaged:
		if _framework_pretriggers_allow_engagement(delta):
			var first_target := framework_select_target(_framework_players)
			_framework_begin_engagement(first_target)
		else:
			framework_stop_movement()
		return
	if _framework_update_arena_presence(delta):
		return
	var target := _framework_player_by_peer(_framework_target_peer)
	if not _framework_valid_target(target) \
			or arena_distance_to(target) > battle_radius():
		target = framework_select_target(_framework_players)
		_framework_target_peer = _framework_peer_id(target)
	if target == null:
		framework_stop_movement()
		return
	for id: StringName in _framework_move_order:
		var module := move_module(id)
		if module != null:
			module.advance(delta)
	var context := _framework_move_context(target)
	if _framework_active_move != null:
		if _framework_active_move.tick_host(delta, target, context):
			var finished_id := _framework_active_move.move_id()
			_framework_active_move.finish(false)
			_framework_active_move = null
			framework_play_animation_role(&"rest")
			framework_publish_event({
				"kind": "move_finished",
				"move": String(finished_id),
			})
		return
	_framework_active_move = framework_select_move(target, context)
	if _framework_active_move == null:
		framework_play_animation_role(&"rest")
		framework_stop_movement()
		return
	_framework_active_move.start(target, context)
	framework_publish_event({
		"kind": "move_started",
		"move": String(_framework_active_move.move_id()),
	})
	_framework_publish_snapshot(true)


func _framework_pretriggers_allow_engagement(delta: float) -> bool:
	if _framework_pretriggers.is_empty():
		for player: Node3D in _framework_players:
			if arena_distance_to(player) <= _framework_detection_radius():
				return true
		return false
	for pretrigger: BossPretrigger in _framework_pretriggers:
		if not pretrigger.externally_owned() \
				and pretrigger.tick_host(delta, _framework_players):
			return true
	return false


## Returns true when a reset consumed this host tick.
func _framework_update_arena_presence(delta: float) -> bool:
	for player: Node3D in _framework_players:
		if arena_distance_to(player) <= battle_radius():
			_framework_arena_empty_time = 0.0
			return false
	_framework_arena_empty_time += maxf(delta, 0.0)
	if _framework_arena_empty_time >= _framework_reset_delay():
		_framework_reset_encounter()
		return true
	return false


func _framework_begin_engagement(target: Node3D) -> void:
	if _framework_engaged or _framework_defeated:
		return
	_framework_engaged = true
	_framework_arena_empty_time = 0.0
	_framework_target_peer = _framework_peer_id(target)
	framework_engaged_changed.emit(true)
	framework_on_engaged(target)
	framework_publish_event({"kind": "engaged"})
	_framework_publish_snapshot(true)


func _framework_reset_encounter() -> void:
	if _framework_active_move != null:
		_framework_active_move.finish(true)
		_framework_active_move = null
	set_arena_boundary_visible(false)
	_framework_initialize_state()
	global_transform = _framework_spawn_transform
	_framework_target_transform = global_transform
	_framework_target_velocity = Vector3.ZERO
	_framework_has_target_transform = true
	reset_physics_interpolation()
	_framework_initialize_moves()
	for pretrigger: BossPretrigger in _framework_pretriggers:
		pretrigger.reset()
	framework_play_animation_role(&"rest")
	framework_health_changed.emit(
		_framework_health, maximum_health())
	framework_engaged_changed.emit(false)
	framework_arena_reset.emit()
	framework_on_reset()
	framework_publish_event({"kind": "reset"})
	_framework_publish_snapshot(true)


func _framework_defeat(hit: DamageHit) -> void:
	if _framework_defeated:
		return
	_framework_defeated = true
	_framework_engaged = false
	_framework_target_peer = 0
	if _framework_active_move != null:
		_framework_active_move.finish(true)
		_framework_active_move = null
	framework_stop_movement()
	set_arena_boundary_visible(false)
	var defeat_clip := animation_for(&"defeat")
	if defeat_clip.is_empty():
		framework_play_animation_role(&"rest")
	else:
		framework_play_clip(defeat_clip, 1.0, true)
	framework_engaged_changed.emit(false)
	framework_defeated.emit()
	framework_on_defeated(hit)
	framework_publish_event({"kind": "defeated"})
	_framework_publish_snapshot(true)


func framework_select_move(
		target: Node3D, context: Dictionary) -> BossMove:
	if _framework_move_order.is_empty():
		return null
	var best: BossMove
	var best_priority := -INF
	var best_offset := 0
	for offset in _framework_move_order.size():
		var index := posmod(_framework_move_cursor + offset,
			_framework_move_order.size())
		var candidate := move_module(_framework_move_order[index])
		if candidate == null or not candidate.can_start(target, context):
			continue
		var priority := candidate.parameter_float(&"priority", 0.0)
		if best == null or priority > best_priority:
			best = candidate
			best_priority = priority
			best_offset = offset
	if best != null:
		_framework_move_cursor = posmod(
			_framework_move_cursor + best_offset + 1,
			_framework_move_order.size())
	return best


func _framework_move_context(target: Node3D) -> Dictionary:
	return {
		"definition": _framework_definition,
		"arena_origin": _framework_spawn_transform.origin,
		"arena_radius": battle_radius(),
		"target_peer": _framework_peer_id(target),
	}


# --- Overridable framework hooks -------------------------------------------

func framework_can_take_damage(_hit: DamageHit) -> bool:
	return true


func framework_on_engaged(_target: Node3D) -> void:
	pass


func framework_on_reset() -> void:
	pass


func framework_on_defeated(_hit: DamageHit) -> void:
	pass


func framework_snapshot_extras() -> Dictionary:
	return {}


func framework_apply_snapshot_extras(_wire: Dictionary) -> void:
	pass


func framework_apply_event(_event: Dictionary) -> void:
	pass


func framework_select_target(candidates: Array[Node3D]) -> Node3D:
	var best: Node3D
	var best_distance := INF
	for player: Node3D in candidates:
		var arena_distance := arena_distance_to(player)
		if arena_distance > battle_radius():
			continue
		var distance := combat_position().distance_to(
			_framework_combat_position(player))
		if distance < best_distance:
			best_distance = distance
			best = player
	return best


## Default ground/aerial movement. Custom subclasses may override this without
## replacing move modules.
func framework_move_toward(
		goal: Vector3,
		speed: float,
		acceleration: float,
		delta: float,
		flying := false) -> void:
	if not goal.is_finite() or not is_finite(delta) or delta <= 0.0:
		return
	speed = maxf(speed, 0.0)
	acceleration = maxf(acceleration, 0.0)
	var up := _framework_up_at(global_position)
	var along := goal - global_position
	if not flying:
		along -= up * along.dot(up)
	var desired := along.normalized() * speed \
		if along.length_squared() > 0.000001 else Vector3.ZERO
	if flying:
		velocity = velocity.move_toward(desired, acceleration * delta)
	else:
		var vertical := up * velocity.dot(up)
		var tangent := velocity - vertical
		tangent = tangent.move_toward(desired, acceleration * delta)
		var gravity := float(ProjectSettings.get_setting(
			"physics/3d/default_gravity", 34.0))
		velocity = tangent + vertical - up * gravity * delta
		up_direction = up
	if velocity.length_squared() > 0.000001:
		framework_face_direction(velocity, delta, 8.0)
	move_and_slide()
	global_position = _FRAMEWORK_ARENA.clamp_for_definition(
		_framework_definition,
		global_position,
		_framework_spawn_transform.origin,
		self,
		maxf(combat_radius(), 0.5))


func framework_stop_movement() -> void:
	velocity = Vector3.ZERO


func framework_face_target(
		target: Node3D, delta: float, turn_rate := 8.0) -> void:
	if target == null:
		return
	framework_face_direction(
		_framework_combat_position(target) - combat_position(),
		delta,
		turn_rate)


func framework_face_direction(
		direction: Vector3, delta: float, turn_rate := 8.0) -> void:
	if not direction.is_finite() or direction.length_squared() < 0.000001:
		return
	var up := _framework_up_at(global_position)
	var forward := direction - up * direction.dot(up)
	if forward.length_squared() < 0.000001:
		forward = direction
	var wanted := _framework_upright_basis(forward, up)
	global_basis = global_basis.slerp(
		wanted, clampf(delta * maxf(turn_rate, 0.0), 0.0, 1.0)
	).orthonormalized()


# --- BossAdapter and DamageHit contract ------------------------------------

func boss_display_name() -> String:
	return combat_display_name()


func combat_display_name() -> String:
	if _framework_definition != null \
			and not _framework_definition.display_name.strip_edges().is_empty():
		return _framework_definition.display_name
	return name


func health() -> float:
	return maxf(_framework_health, 0.0)


func maximum_health() -> float:
	return maxf(
		_framework_definition.max_health
		if _framework_definition != null else _framework_health,
		0.001)


func engaged() -> bool:
	return _framework_engaged


func defeated() -> bool:
	return _framework_defeated


func battle_radius() -> float:
	return maxf(
		_framework_definition.arena_radius
		if _framework_definition != null else BossAdapter.DEFAULT_RADIUS,
		1.0)


func arena_distance_to(body: Node3D) -> float:
	if body == null:
		return INF
	return _FRAMEWORK_ARENA.distance_for_definition(
		_framework_definition,
		_framework_spawn_transform.origin,
		body.global_position,
		self)


func combat_faction() -> int:
	return DamageHit.Faction.ENEMY


func combat_peer_id() -> int:
	return 0


func combat_position() -> Vector3:
	var height := 0.0
	if _framework_definition != null:
		var value: Variant = _framework_definition.combat.get(
			"center_height", 0.0)
		if value is int or value is float:
			height = maxf(float(value), 0.0)
	return global_position + _framework_up_at(global_position) * height


func combat_radius() -> float:
	if _framework_definition != null:
		var value: Variant = _framework_definition.combat.get("radius", 0.5)
		if value is int or value is float:
			var radius := float(value)
			if is_finite(radius):
				return maxf(radius, 0.01)
	return 0.5


func apply_damage(hit: DamageHit) -> float:
	if hit == null or not framework_is_host() or _framework_defeated \
			or hit.faction != DamageHit.Faction.PLAYER \
			or not framework_can_take_damage(hit):
		return 0.0
	var requested := hit.amount if is_finite(hit.amount) else 0.0
	var amount := minf(maxf(requested, 0.0), _framework_health)
	if amount <= 0.0:
		return 0.0
	_framework_health -= amount
	framework_health_changed.emit(_framework_health, maximum_health())
	flash_damage(clampf(
		amount / maxf(maximum_health() * 0.02, 1.0), 0.15, 1.0))
	framework_publish_event({
		"kind": "damaged",
		"amount": amount,
		"at": hit.centre(),
	})
	if not _framework_engaged:
		_framework_collect_players()
		var target := _framework_player_by_peer(hit.source_peer)
		if target == null:
			target = framework_select_target(_framework_players)
		_framework_begin_engagement(target)
	if _framework_health <= 0.0:
		_framework_defeat(hit)
	return amount


func receive_reflected_damage(amount: float, source_peer: int) -> void:
	if not framework_is_host() or not is_finite(amount) or amount <= 0.0:
		return
	var hit := DamageHit.impact(combat_position(), combat_radius(), amount)
	hit.faction = DamageHit.Faction.PLAYER
	hit.source_peer = maxi(source_peer, 0)
	hit.ability_id = "parry_reflect"
	var source := _framework_player_by_peer(source_peer)
	if source != null:
		hit.set_source(source, source_peer)
	var dealt := apply_damage(hit)
	if dealt > 0.0 and source != null \
			and source.has_method(&"combat_damage_dealt"):
		source.call(&"combat_damage_dealt", self, dealt, hit)


func set_arena_boundary_visible(shown: bool) -> void:
	if not is_instance_valid(_framework_boundary):
		_framework_boundary = get_node_or_null(^"ArenaBoundary")
	if not is_instance_valid(_framework_boundary):
		return
	if _framework_boundary.has_method(&"set_active"):
		_framework_boundary.call(
			&"set_active", shown and not _framework_defeated)
	elif _framework_boundary is CanvasItem:
		(_framework_boundary as CanvasItem).visible \
			= shown and not _framework_defeated
	elif _framework_boundary is Node3D:
		(_framework_boundary as Node3D).visible \
			= shown and not _framework_defeated


func flash_damage(strength := 1.0) -> void:
	framework_damaged_flash.emit(clampf(strength, 0.0, 1.0))


# --- Animation --------------------------------------------------------------

func framework_play_animation_role(
		role: StringName,
		subrole: StringName = &"",
		speed := 1.0) -> void:
	var clip := animation_for(role, subrole)
	if not clip.is_empty():
		framework_play_clip(clip, speed)


func framework_play_move_animation(
		move: BossMove,
		stage: StringName,
		fallback_role: StringName = &"") -> void:
	if move == null:
		return
	var clip := move.animation(stage)
	if clip.is_empty() and not fallback_role.is_empty():
		clip = animation_for(fallback_role)
	if clip.is_empty():
		clip = animation_for(&"rest")
	framework_play_clip(clip, 1.0, true)


func framework_play_clip(
		clip: StringName, speed := 1.0, restart := false) -> void:
	if clip.is_empty():
		return
	if restart or clip != _framework_clip:
		_framework_clip_sequence += 1
	if restart:
		_framework_clip_playing = &""
	_framework_clip = clip
	_framework_clip_speed = clampf(speed, 0.05, 8.0)


func _framework_update_presentation() -> void:
	if _framework_animator == null \
			or not _framework_animator.has_animation(_framework_clip):
		return
	var animation := _framework_animator.get_animation(_framework_clip)
	var looping := animation.loop_mode != Animation.LOOP_NONE
	var restart := _framework_clip_playing != _framework_clip \
		or (looping and _framework_animator.current_animation.is_empty())
	if restart:
		_framework_clip_playing = _framework_clip
		_framework_animator.play(_framework_clip, 0.1)
	if _framework_clip_seek >= 0.0:
		if restart:
			_framework_animator.seek(
				clampf(_framework_clip_seek, 0.0, animation.length), true)
		_framework_clip_seek = -1.0
	_framework_animator.speed_scale = _framework_clip_speed


func _framework_animation_position() -> float:
	if _framework_animator == null \
			or _framework_animator.current_animation.is_empty():
		return 0.0
	return _framework_animator.current_animation_position


# --- Generic projectile hook -----------------------------------------------

## Custom controllers may override this hook. The default always creates a
## replicated lightweight projectile, so the built-in move cannot fail silently.
func framework_launch_projectile(
		move: BossMove, target: Node3D) -> bool:
	if move == null or not framework_is_host() or target == null:
		return false
	var origin := framework_projectile_origin(move)
	var target_point := _framework_combat_position(target)
	var speed := maxf(move.parameter_float(&"speed", 24.0), 0.01)
	var lead := maxf(move.parameter_float(&"lead", 0.0), 0.0)
	var target_velocity: Variant = target.get(&"velocity")
	if target_velocity is Vector3 and (target_velocity as Vector3).is_finite():
		var flight := origin.distance_to(target_point) / speed
		target_point += (target_velocity as Vector3) * flight * lead
	var direction := target_point - origin
	if direction.length_squared() < 0.000001:
		direction = -global_basis.z
	direction = direction.normalized()
	var up := _framework_up_at(origin)
	var payload := {
		"origin": origin,
		"velocity": direction * speed,
		"acceleration": -up * maxf(
			move.parameter_float(&"gravity", 0.0), 0.0),
		"lifetime": maxf(move.parameter_float(&"lifetime", 4.0), 0.05),
		"radius": maxf(move.parameter_float(&"radius", 0.5), 0.01),
		"visual_size": maxf(
			move.parameter_float(&"visual_size",
				move.parameter_float(&"radius", 0.5)),
			0.01),
		"damage": maxf(move.parameter_float(&"damage", 12.0), 0.0),
		"target_peer": _framework_peer_id(target),
		"ability_id": move.parameter_string(
			&"ability_id",
			"%s_%s" % [boss_id(), String(move.move_id())]),
		"reaction": _framework_reaction(
			move.parameter(&"reaction", "none")),
		"world_impulse": direction * maxf(
			move.parameter_float(&"knockback", 0.0), 0.0)
			+ up * move.parameter_float(&"lift", 0.0)
			+ move.parameter_vector(&"world_impulse", Vector3.ZERO),
		"parryable": move.parameter_bool(&"parryable", false),
		"reflection": maxf(
			move.parameter_float(&"reflection", 0.0), 0.0),
		"blocked_by_world": move.parameter_bool(
			&"blocked_by_world", true),
		"color": move.parameter_string(&"color", "#ff5a18"),
	}
	_framework_spawn_projectile(payload, true)
	framework_publish_event({
		"kind": "projectile",
		"projectile": payload,
	})
	return true


func framework_projectile_origin(move: BossMove) -> Vector3:
	var marker_path := move.parameter_string(
		&"origin_marker", "ProjectileOrigin")
	var marker := get_node_or_null(NodePath(marker_path)) as Node3D
	if marker != null:
		return marker.global_position
	return combat_position() - global_basis.z \
		* (combat_radius() + move.parameter_float(&"radius", 0.5))


func _framework_spawn_projectile(
		payload: Dictionary, authoritative: bool) -> void:
	if not is_inside_tree():
		return
	var projectile := _FRAMEWORK_PROJECTILE.new()
	projectile.name = "BossProjectile"
	add_child(projectile, false, Node.INTERNAL_MODE_BACK)
	projectile.top_level = true
	projectile.configure(self, payload, authoritative)


# --- Snapshot and event replication ----------------------------------------

func boss_snapshot() -> Dictionary:
	var move_snapshots := {}
	for id: StringName in _framework_move_order:
		var module := move_module(id)
		if module != null:
			move_snapshots[String(id)] = module.snapshot()
	var pretrigger_snapshots: Array[Dictionary] = []
	for pretrigger: BossPretrigger in _framework_pretriggers:
		pretrigger_snapshots.append(pretrigger.snapshot())
	var wire := {
		"boss_id": boss_id(),
		"health": _framework_health,
		"maximum_health": maximum_health(),
		"engaged": _framework_engaged,
		"defeated": _framework_defeated,
		"target_peer": _framework_target_peer,
		"transform": global_transform,
		"velocity": velocity,
		"clip": String(_framework_clip),
		"clip_speed": _framework_clip_speed,
		"clip_position": _framework_animation_position(),
		"clip_sequence": _framework_clip_sequence,
		"active_move": String(_framework_active_move.move_id())
			if _framework_active_move != null else "",
		"moves": move_snapshots,
		"pretriggers": pretrigger_snapshots,
		"sync_sequence": _framework_replication.sync_sequence()
			if _framework_replication != null else 0,
	}
	var extras := framework_snapshot_extras()
	for key: Variant in extras:
		if not wire.has(key):
			wire[key] = extras[key]
	return wire


func apply_boss_snapshot(wire: Dictionary) -> void:
	if wire.is_empty() \
			or String(wire.get("boss_id", boss_id())) != boss_id():
		return
	if _framework_replication != null \
			and not _framework_replication.accept_snapshot(wire):
		return
	var previous_health := _framework_health
	var next_health := float(wire.get("health", _framework_health))
	if is_finite(next_health):
		_framework_health = clampf(
			next_health, 0.0, maximum_health())
	if not is_equal_approx(previous_health, _framework_health):
		framework_health_changed.emit(
			_framework_health, maximum_health())
	var was_engaged := _framework_engaged
	_framework_engaged = bool(wire.get("engaged", _framework_engaged))
	_framework_defeated = bool(wire.get("defeated", _framework_defeated))
	_framework_target_peer = maxi(
		int(wire.get("target_peer", _framework_target_peer)), 0)
	var transform_value: Variant = wire.get("transform", global_transform)
	if transform_value is Transform3D \
			and (transform_value as Transform3D).is_finite():
		var first := not _framework_has_target_transform
		_framework_target_transform = transform_value
		if first:
			global_transform = transform_value
		_framework_has_target_transform = true
	var velocity_value: Variant = wire.get("velocity", velocity)
	if velocity_value is Vector3 \
			and (velocity_value as Vector3).is_finite():
		_framework_target_velocity = velocity_value
		velocity = velocity_value
	var previous_clip := _framework_clip
	var incoming_clip_sequence := maxi(
		int(wire.get("clip_sequence", _framework_clip_sequence)), 0)
	var clip_restarted := incoming_clip_sequence != _framework_clip_sequence
	_framework_clip_sequence = incoming_clip_sequence
	_framework_clip = StringName(String(wire.get("clip", _framework_clip)))
	var speed := float(wire.get("clip_speed", _framework_clip_speed))
	if is_finite(speed):
		_framework_clip_speed = clampf(speed, 0.05, 8.0)
	if clip_restarted:
		_framework_clip_playing = &""
	if clip_restarted or _framework_clip != previous_clip \
			or _framework_clip_playing != _framework_clip:
		var seek := float(wire.get("clip_position", 0.0))
		_framework_clip_seek = maxf(seek, 0.0) if is_finite(seek) else 0.0
	var move_wires: Variant = wire.get("moves", {})
	if move_wires is Dictionary:
		for id: Variant in move_wires:
			var module := move_module(StringName(String(id)))
			var move_wire: Variant = (move_wires as Dictionary)[id]
			if module != null and move_wire is Dictionary:
				module.apply_snapshot(move_wire)
	var active_id := String(wire.get("active_move", ""))
	_framework_active_move = move_module(StringName(active_id)) \
		if not active_id.is_empty() else null
	var pretrigger_wires: Variant = wire.get("pretriggers", [])
	if pretrigger_wires is Array:
		var by_id := {}
		for pretrigger: BossPretrigger in _framework_pretriggers:
			by_id[String(pretrigger.pretrigger_id())] = pretrigger
		for value: Variant in pretrigger_wires:
			if value is Dictionary:
				var id := String((value as Dictionary).get("id", ""))
				var pretrigger := by_id.get(id) as BossPretrigger
				if pretrigger != null:
					pretrigger.apply_snapshot(value)
	if was_engaged != _framework_engaged:
		framework_engaged_changed.emit(_framework_engaged)
	framework_apply_snapshot_extras(wire)


func framework_publish_event(event: Dictionary) -> void:
	if _framework_replication == null or not framework_is_host():
		return
	var wire := _framework_replication.stamp_event(event)
	if not _framework_replication.has_listeners():
		return
	_apply_boss_framework_event.rpc(
		int(wire.get("sequence", 0)), wire)


func _framework_publish_snapshot(reliable: bool) -> void:
	if _framework_replication == null or not framework_is_host() \
			or not _framework_replication.has_listeners():
		return
	var wire := _framework_replication.stamp_snapshot(boss_snapshot())
	var sequence := int(wire.get("sync_sequence", 0))
	if reliable:
		_apply_boss_framework_sync_reliable.rpc(sequence, wire)
	else:
		_apply_boss_framework_sync.rpc(sequence, wire)


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_boss_framework_sync(
		sequence: int, wire: Dictionary) -> void:
	if framework_is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_remote", "reliable")
func _apply_boss_framework_sync_reliable(
		sequence: int, wire: Dictionary) -> void:
	if framework_is_host():
		return
	wire["sync_sequence"] = sequence
	apply_boss_snapshot(wire)


@rpc("authority", "call_remote", "reliable")
func _apply_boss_framework_event(
		sequence: int, wire: Dictionary) -> void:
	if framework_is_host() or _framework_replication == null:
		return
	wire["sequence"] = sequence
	if not _framework_replication.accept_event(wire):
		return
	match String(wire.get("kind", "")):
		"damaged":
			var amount := float(wire.get("amount", 0.0))
			flash_damage(clampf(
				amount / maxf(maximum_health() * 0.02, 1.0),
				0.15,
				1.0))
		"reset":
			framework_arena_reset.emit()
		"projectile":
			var payload: Variant = wire.get("projectile", {})
			if payload is Dictionary:
				_framework_spawn_projectile(payload, false)
	framework_apply_event(wire)


func _framework_tick_listener(delta: float) -> void:
	if not _framework_has_target_transform:
		return
	var share := clampf(delta * 16.0, 0.0, 1.0)
	global_transform = global_transform.interpolate_with(
		_framework_target_transform, share)
	velocity = _framework_target_velocity


func framework_is_host() -> bool:
	return _framework_replication.is_host() \
		if _framework_replication != null \
		else not multiplayer.has_multiplayer_peer() \
			or multiplayer.is_server()


# --- Player and geometry helpers -------------------------------------------

func _framework_collect_players() -> void:
	_framework_players.clear()
	if not is_inside_tree():
		return
	var local_world := DamageHit.game_world_of(self)
	var seen := {}
	var candidates := get_tree().get_nodes_in_group(&"network_players")
	candidates.append_array(
		get_tree().get_nodes_in_group(DamageHit.COMBATANT_GROUP))
	for value: Variant in candidates:
		var player := value as Node3D
		if player == null or player == self or not is_instance_valid(player) \
				or seen.has(player.get_instance_id()):
			continue
		seen[player.get_instance_id()] = true
		if local_world != null and DamageHit.game_world_of(player) != local_world:
			continue
		if not player.has_method(&"combat_faction") \
				or int(player.call(&"combat_faction")) \
				!= DamageHit.Faction.PLAYER:
			continue
		if player.has_method(&"is_dead") and bool(player.call(&"is_dead")):
			continue
		_framework_players.append(player)


func _framework_valid_target(target: Node3D) -> bool:
	return target != null and is_instance_valid(target) \
		and not (target.has_method(&"is_dead")
			and bool(target.call(&"is_dead")))


func _framework_player_by_peer(peer_id: int) -> Node3D:
	if peer_id <= 0:
		return null
	for player: Node3D in _framework_players:
		if _framework_peer_id(player) == peer_id:
			return player
	if is_inside_tree():
		_framework_collect_players()
		for player: Node3D in _framework_players:
			if _framework_peer_id(player) == peer_id:
				return player
	return null


func _framework_peer_id(player: Node) -> int:
	if player == null:
		return 0
	if player.has_method(&"combat_peer_id"):
		return maxi(int(player.call(&"combat_peer_id")), 0)
	var value: Variant = player.get(&"peer_id")
	return maxi(int(value), 0) \
		if value is int or value is float else 0


func _framework_combat_position(node: Node) -> Vector3:
	if node == null:
		return Vector3.ZERO
	if node.has_method(&"combat_position"):
		var value: Variant = node.call(&"combat_position")
		if value is Vector3 and (value as Vector3).is_finite():
			return value
	return (node as Node3D).global_position \
		if node is Node3D else Vector3.ZERO


func _framework_detection_radius() -> float:
	return maxf(
		_framework_definition.detection_radius
		if _framework_definition != null else battle_radius(),
		0.0)


func _framework_reset_delay() -> float:
	return maxf(
		_framework_definition.reset_delay
		if _framework_definition != null else 5.0,
		0.05)


func _framework_up_at(point: Vector3) -> Vector3:
	if _framework_definition != null \
			and _framework_definition.arena_distance_mode == &"surface_arc":
		var planet := _FRAMEWORK_ARENA.planet_of(self)
		if planet != null:
			return _FRAMEWORK_ARENA.surface_up(planet, point)
	var up := global_basis.y
	return up.normalized() \
		if up.is_finite() and up.length_squared() > 0.000001 \
		else Vector3.UP


func _framework_upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.000001:
		var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
		forward = hint - up * hint.dot(up)
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(
		right, up, right.cross(up).normalized()).orthonormalized()


func _framework_reaction(value: Variant) -> int:
	if value is int or value is float:
		return clampi(
			int(value), DamageHit.Reaction.NONE, DamageHit.Reaction.RAGDOLL)
	match String(value).to_lower():
		"stagger":
			return DamageHit.Reaction.STAGGER
		"knockback":
			return DamageHit.Reaction.KNOCKBACK
		"ragdoll":
			return DamageHit.Reaction.RAGDOLL
	return DamageHit.Reaction.NONE
