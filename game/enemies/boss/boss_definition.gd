class_name BossDefinition
extends Resource

## Authored boss data after deterministic JSON generation. Core values stay
## typed while move, collision, animation, and placement payloads remain open
## dictionaries so later runtime layers do not require a resource migration for
## every controller-specific field.

@export var boss_id: String = ""
@export var boss_class_name: String = ""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export var controller_mode: StringName = &""
@export var boss_scene: PackedScene
@export var controller_script: Script
@export var runtime_model: PackedScene
@export var asset: Dictionary = {}

@export var max_health := 0.0
@export var arena_radius := 0.0
@export var detection_radius := 0.0
@export var reset_delay := 0.0
@export var arena_distance_mode: StringName = &""

@export var combat: Dictionary = {}
@export var collision: Dictionary = {}
@export var animations: Dictionary = {}
@export var moves: Array = []
@export var pretriggers := PackedStringArray()

@export var location: Dictionary = {}
@export var waypoint: Dictionary = {}
@export var material_override: Material
@export var tags := PackedStringArray()
@export var extensions: Dictionary = {}


func valid() -> bool:
	if boss_id.is_empty() or boss_id != boss_id.to_lower() \
			or not boss_id.is_valid_identifier():
		return false
	if boss_class_name.is_empty() or not boss_class_name.is_valid_identifier() \
			or display_name.strip_edges().is_empty() \
			or description.strip_edges().is_empty():
		return false
	if controller_mode != &"custom" and controller_mode != &"generic":
		return false
	if boss_scene == null or controller_script == null or runtime_model == null:
		return false
	if String(asset.get("source", "")).is_empty() \
			or String(asset.get("runtime_glb", "")).is_empty():
		return false
	if not _positive(max_health) or not _positive(arena_radius) \
			or not _positive(detection_radius) or not _positive(reset_delay):
		return false
	if arena_distance_mode != &"surface_arc" \
			and arena_distance_mode != &"euclidean":
		return false
	if not _positive(combat.get("radius", 0.0)) \
			or not _positive(combat.get("center_height", 0.0)):
		return false
	if not _valid_collision() or animation(&"rest").is_empty() \
			or not _valid_moves() or not _valid_location():
		return false
	return _valid_waypoint()


## Resolves either a direct role (`rest`) or a nested role/stage
## (`locomotion`, `run`). Nested roles may use `default` when no subrole is
## supplied.
func animation(role: StringName, subrole: StringName = &"") -> StringName:
	var value: Variant = animations.get(String(role))
	if value is String or value is StringName:
		return StringName(value) if String(subrole).is_empty() else &""
	if not value is Dictionary:
		return &""
	var mapping := value as Dictionary
	var key := String(subrole)
	if key.is_empty():
		key = "default"
	var clip: Variant = mapping.get(key, "")
	if clip is String or clip is StringName:
		return StringName(clip)
	return &""


func all_animation_clips() -> PackedStringArray:
	var found: Dictionary = {}
	for value: Variant in animations.values():
		if value is String or value is StringName:
			var clip := String(value)
			if not clip.is_empty():
				found[clip] = true
		elif value is Dictionary:
			for nested: Variant in (value as Dictionary).values():
				if nested is String or nested is StringName:
					var clip := String(nested)
					if not clip.is_empty():
						found[clip] = true
	var result := PackedStringArray()
	for clip: Variant in found:
		result.append(String(clip))
	result.sort()
	return result


func location_mode() -> StringName:
	return StringName(String(location.get("mode", "")))


func is_planet_surface() -> bool:
	return location_mode() == &"planet_surface"


func is_world_space() -> bool:
	return location_mode() == &"world_space"


func surface_direction() -> Vector3:
	return _vector3(location.get("direction"), Vector3.UP)


func surface_facing() -> float:
	return float(location.get("facing", 0.0))


func surface_clearance() -> float:
	return float(location.get("clearance", 0.0))


func world_parent() -> NodePath:
	return NodePath(String(location.get("parent", "")))


func world_origin() -> Vector3:
	return _vector3(location.get("origin"), Vector3.ZERO)


func world_orientation() -> Vector3:
	return _vector3(location.get("orientation"), Vector3.ZERO)


func _valid_collision() -> bool:
	var shape := String(collision.get("shape", ""))
	if not _valid_vector3(collision.get("offset")):
		return false
	match shape:
		"sphere":
			return _positive(collision.get("radius", 0.0))
		"capsule":
			return _positive(collision.get("radius", 0.0)) \
				and _positive(collision.get("height", 0.0))
		"box":
			var size := _vector3(collision.get("size"), Vector3.ZERO)
			return size.is_finite() and size.x > 0.0 \
				and size.y > 0.0 and size.z > 0.0
	return false


func _valid_moves() -> bool:
	if moves.is_empty():
		return false
	var known: Dictionary = {}
	for clip: String in all_animation_clips():
		known[clip] = true
	var ids: Dictionary = {}
	for value: Variant in moves:
		if not value is Dictionary:
			return false
		var move := value as Dictionary
		var move_id := String(move.get("id", ""))
		var behavior := String(move.get("behavior", ""))
		var mapping: Variant = move.get("animations")
		if move_id.is_empty() or ids.has(move_id) or behavior.is_empty() \
				or not mapping is Dictionary \
				or (mapping as Dictionary).is_empty():
			return false
		ids[move_id] = true
		for clip_value: Variant in (mapping as Dictionary).values():
			var clip := String(clip_value)
			if clip.is_empty() or not known.has(clip):
				return false
	return true


func _valid_location() -> bool:
	if is_planet_surface():
		if not location.has("direction") or not location.has("facing") \
				or not location.has("clearance") \
				or not _valid_vector3(location.get("direction")) \
				or not _finite(location.get("facing")) \
				or not _finite(location.get("clearance")):
			return false
		var direction := surface_direction()
		return arena_distance_mode == &"surface_arc" \
			and direction.is_finite() and direction.length_squared() > 0.5 \
			and surface_clearance() >= 0.0
	if is_world_space():
		if not location.has("origin") or not location.has("orientation") \
				or not _valid_vector3(location.get("origin")) \
				or not _valid_vector3(location.get("orientation")):
			return false
		return arena_distance_mode == &"euclidean" \
			and not world_parent().is_empty() \
			and world_origin().is_finite() \
			and world_orientation().is_finite()
	return false


func _valid_waypoint() -> bool:
	if not waypoint.has("enabled") or not waypoint.get("enabled") is bool:
		return false
	if String(waypoint.get("title", "")).strip_edges().is_empty() \
			or String(waypoint.get("tint", "")).is_empty():
		return false
	for key: String in ["show_beyond", "aimed_beyond", "hide_beyond"]:
		var raw: Variant = waypoint.get(key)
		if not _finite(raw) or float(raw) < 0.0:
			return false
	return true


static func _positive(value: Variant) -> bool:
	return _finite(value) and float(value) > 0.0


static func _finite(value: Variant) -> bool:
	if value is bool or not (value is int or value is float):
		return false
	return is_finite(float(value))


static func _valid_vector3(value: Variant) -> bool:
	if value is Vector3:
		return (value as Vector3).is_finite()
	if not value is Array or (value as Array).size() != 3:
		return false
	for component: Variant in value:
		if not _finite(component):
			return false
	return true


static func _vector3(value: Variant, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value
	if not _valid_vector3(value):
		return fallback
	var row := value as Array
	return Vector3(float(row[0]), float(row[1]), float(row[2]))
