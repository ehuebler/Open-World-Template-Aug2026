class_name BossDirector
extends Node

## Deterministic local catalog placement. Every peer runs the same catalog over
## the same authored world; boss combat replication remains controller-owned.

const SURFACE_BOUNDARY := preload(
	"res://game/enemies/bigfoot/bigfoot_arena_boundary.gd")
const SPACE_BOUNDARY := preload(
	"res://game/enemies/boss/boss_space_arena_boundary.gd")

const SITE_NAME_EXTENSION := "site_node_name"
const BOSS_NAME_EXTENSION := "boss_node_name"
const SITE_SCRIPT_EXTENSION := "site_script"

var _world_root: Node
var _bosses: Dictionary = {}
var _sites: Dictionary = {}
var _initialized := false


func _ready() -> void:
	# Children ready before their parent, and authored boss controllers add their
	# groups from _ready. Deferring one turn makes discovery happen only after
	# the complete World/Planet branch has entered the tree.
	call_deferred(&"initialize")


## Safe to call repeatedly. Each pass rediscovers authored/runtime bosses first
## and creates only catalog IDs that remain absent.
func initialize(world_override: Node = null) -> bool:
	if world_override != null:
		_world_root = world_override
	elif not is_instance_valid(_world_root):
		_world_root = _find_world_root()
	if not is_instance_valid(_world_root):
		push_error("BossDirector has no GameWorld to initialize")
		return false

	_bosses.clear()
	_sites.clear()
	_scan_existing_bosses()

	var complete := true
	for boss_id: String in BossCatalog.ids():
		var definition := BossCatalog.definition(boss_id)
		if definition == null:
			complete = false
			continue
		var existing := lookup_boss(boss_id)
		if existing != null:
			_bind_definition_id(existing, boss_id)
			continue
		if not _spawn_definition(definition):
			complete = false
	_initialized = true
	return complete


func initialized() -> bool:
	return _initialized


func lookup_boss(boss_id: String) -> Node:
	var boss := _bosses.get(boss_id) as Node
	return boss if is_instance_valid(boss) else null


func lookup_site(boss_id: String) -> Node3D:
	var site := _sites.get(boss_id) as Node3D
	return site if is_instance_valid(site) else null


func lookup_definition(boss_id: String) -> BossDefinition:
	return BossCatalog.definition(boss_id)


func _find_world_root() -> Node:
	var current := get_parent()
	while current != null:
		if current is GameWorld:
			return current
		current = current.get_parent()
	# A bare Node/Node3D parent keeps focused fixtures useful without weakening
	# production placement, where this node is a direct GameWorld child.
	return get_parent()


func _scan_existing_bosses() -> void:
	var candidates: Array[Node] = [_world_root]
	candidates.append_array(
		_world_root.find_children("*", "", true, false))
	var seen: Dictionary = {}
	for candidate: Node in candidates:
		if candidate == null or seen.has(candidate.get_instance_id()) \
				or not candidate.has_method(&"boss_id"):
			continue
		seen[candidate.get_instance_id()] = true
		var id := String(candidate.call(&"boss_id")).strip_edges()
		if id.is_empty():
			continue
		_bind_definition_id(candidate, id)
		if _bosses.has(id):
			continue
		_bosses[id] = candidate
		var parent := candidate.get_parent() as Node3D
		if parent != null:
			_sites[id] = parent


func _spawn_definition(definition: BossDefinition) -> bool:
	if definition.is_planet_surface():
		return _spawn_surface(definition)
	if definition.is_world_space():
		return _spawn_world_space(definition)
	push_error("Boss '%s' has no supported location mode" % definition.boss_id)
	return false


func _spawn_surface(definition: BossDefinition) -> bool:
	var planet := _world_root.get_node_or_null(^"Planet") as Planet
	if planet == null:
		push_error(
			"Boss '%s' needs the GameWorld Planet" % definition.boss_id)
		return false
	var site_name := _stable_node_name(
		definition, SITE_NAME_EXTENSION, "Site")
	var existing := planet.get_node_or_null(NodePath(site_name))
	var site := existing as Landmark
	if existing != null and site == null:
		push_error(
			"Boss '%s' site name '%s' is already occupied"
			% [definition.boss_id, site_name])
		return false
	if site == null:
		site = _instantiate_surface_site(definition)
		if site == null:
			return false
		site.name = site_name
		_configure_surface_site(site, planet, definition)
		planet.add_child(site)
	else:
		_configure_surface_site(site, planet, definition)
	return _spawn_boss(definition, site, planet)


func _instantiate_surface_site(
		definition: BossDefinition) -> Landmark:
	var script_path := _extension_string(
		definition, SITE_SCRIPT_EXTENSION)
	if script_path.is_empty():
		return Landmark.new()
	var site_script := load(script_path) as Script
	if site_script == null or not site_script.can_instantiate():
		push_error(
			"Boss '%s' site script could not be loaded: %s"
			% [definition.boss_id, script_path])
		return null
	var instance: Object = site_script.new()
	var site := instance as Landmark
	if site == null:
		if instance is Node:
			(instance as Node).free()
		push_error(
			"Boss '%s' site script must extend Landmark: %s"
			% [definition.boss_id, script_path])
	return site


func _configure_surface_site(
		site: Landmark,
		planet: Planet,
		definition: BossDefinition) -> void:
	site.planet = planet
	site.direction = definition.surface_direction()
	site.facing = definition.surface_facing()
	site.clearance = definition.surface_clearance()
	_apply_waypoint(site, definition)


func _spawn_world_space(definition: BossDefinition) -> bool:
	var parent := _world_parent(definition)
	if parent == null:
		return false
	var site_name := _stable_node_name(
		definition, SITE_NAME_EXTENSION, "Anchor")
	var existing := parent.get_node_or_null(NodePath(site_name))
	var anchor := existing as BossWorldAnchor
	if existing != null and anchor == null:
		push_error(
			"Boss '%s' anchor name '%s' is already occupied"
			% [definition.boss_id, site_name])
		return false
	if anchor == null:
		anchor = BossWorldAnchor.new()
		anchor.name = site_name
		anchor.configure(definition)
		parent.add_child(anchor)
	else:
		anchor.configure(definition)
	return _spawn_boss(definition, anchor)


func _world_parent(definition: BossDefinition) -> Node:
	var path := definition.world_parent()
	if path.is_empty() or path.is_absolute():
		push_error(
			"Boss '%s' world parent must be GameWorld-relative"
			% definition.boss_id)
		return null
	for index in path.get_name_count():
		if path.get_name(index) == &"..":
			push_error(
				"Boss '%s' world parent cannot leave GameWorld"
				% definition.boss_id)
			return null
	var parent := _world_root.get_node_or_null(path)
	if parent == null:
		push_error(
			"Boss '%s' world parent does not exist: %s"
			% [definition.boss_id, String(path)])
	return parent


func _spawn_boss(
		definition: BossDefinition,
		site: Node3D,
		planet: Planet = null) -> bool:
	var boss_name := _stable_node_name(
		definition, BOSS_NAME_EXTENSION, "")
	var occupied := site.get_node_or_null(NodePath(boss_name))
	if occupied != null:
		if occupied.has_method(&"boss_id") \
				and String(occupied.call(&"boss_id")) == definition.boss_id:
			_bind_definition_id(occupied, definition.boss_id)
			_bosses[definition.boss_id] = occupied
			_sites[definition.boss_id] = site
			return true
		push_error(
			"Boss '%s' node name '%s' is already occupied"
			% [definition.boss_id, boss_name])
		return false

	var boss := definition.boss_scene.instantiate()
	var boss_3d := boss as Node3D
	if boss_3d == null:
		if boss != null:
			boss.free()
		push_error(
			"Boss '%s' scene root must be a Node3D" % definition.boss_id)
		return false
	boss_3d.name = boss_name
	# BossController reads this from _ready, so the definition must be bound
	# before add_child can enter the new node into an active SceneTree.
	_bind_definition_id(boss_3d, definition.boss_id)
	var boundary := _ensure_generic_boundary(boss_3d, definition)
	site.add_child(boss_3d)
	_configure_boundary(boundary, definition, site, planet)
	_bosses[definition.boss_id] = boss_3d
	_sites[definition.boss_id] = site
	return true


func _ensure_generic_boundary(
		boss: Node3D, definition: BossDefinition) -> Node:
	if definition.controller_mode != &"generic":
		return null
	var boundary := boss.find_child("ArenaBoundary", true, false)
	if boundary == null:
		for candidate: Node in boss.find_children("*", "", true, false):
			if candidate.has_method(&"set_active") \
					and candidate.has_method(&"arena_radius"):
				boundary = candidate
				break
	if boundary != null:
		return boundary
	boundary = SPACE_BOUNDARY.new() \
		if definition.is_world_space() else SURFACE_BOUNDARY.new()
	boundary.name = "ArenaBoundary"
	boss.add_child(boundary)
	return boundary


func _configure_boundary(
		boundary: Node,
		definition: BossDefinition,
		site: Node3D,
		planet: Planet) -> void:
	if boundary == null or not boundary.has_method(&"configure"):
		return
	if definition.is_planet_surface():
		if planet == null:
			return
		boundary.call(
			&"configure",
			planet,
			definition.surface_direction(),
			definition.arena_radius)
	else:
		boundary.call(
			&"configure", site.global_position, definition.arena_radius)
	if boundary.has_method(&"set_active"):
		boundary.call(&"set_active", false)


func _bind_definition_id(boss: Node, boss_id: String) -> void:
	if _has_property(boss, &"definition_id"):
		boss.set(&"definition_id", boss_id)
	elif boss.has_method(&"set_definition_id"):
		boss.call(&"set_definition_id", boss_id)


func _has_property(object: Object, wanted: StringName) -> bool:
	for property: Dictionary in object.get_property_list():
		if StringName(property.get("name", "")) == wanted:
			return true
	return false


func _apply_waypoint(site: Landmark, definition: BossDefinition) -> void:
	var data := definition.waypoint
	site.waypoint = bool(data.get("enabled", site.waypoint))
	site.title = String(
		data.get("title", definition.display_name)).strip_edges()
	if site.title.is_empty():
		site.title = definition.display_name
	var tint_value: Variant = data.get("tint", site.tint)
	if tint_value is String or tint_value is StringName:
		site.tint = Color(String(tint_value))
	elif tint_value is Color:
		site.tint = tint_value as Color
	site.show_beyond = _range(
		data.get("show_beyond", site.show_beyond), site.show_beyond)
	site.aimed_beyond = _range(
		data.get("aimed_beyond", site.aimed_beyond), site.aimed_beyond)
	site.hide_beyond = _range(
		data.get("hide_beyond", site.hide_beyond), site.hide_beyond)


func _range(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		var amount := float(value)
		if is_finite(amount):
			return maxf(amount, 0.0)
	return maxf(fallback, 0.0)


func _stable_node_name(
		definition: BossDefinition,
		extension_key: String,
		default_suffix: String) -> String:
	var fallback := _default_name_stem(definition.boss_id) + default_suffix
	var requested := _extension_string(definition, extension_key)
	if requested.is_empty() or requested == "." or requested == "..":
		return fallback
	var validated := requested.validate_node_name()
	return validated if not validated.is_empty() else fallback


func _default_name_stem(boss_id: String) -> String:
	var result := ""
	for part: String in boss_id.split("_", false):
		result += part.capitalize()
	return result if not result.is_empty() else "Boss"


func _extension_string(
		definition: BossDefinition, key: String) -> String:
	var value: Variant = definition.extensions.get(key, "")
	return String(value).strip_edges() \
		if value is String or value is StringName else ""
