class_name BossDefinitionRegression
extends RefCounted

## Shared catalog/runtime checks used by every authored boss suite.

const MANIFEST_DIRECTORY := "res://assets/runtime/bosses/manifests"
const AUTHORED_BOSS_PATHS := {
	"bigfoot": ^"Planet/BigfootTerritory/Bigfoot",
	"sandworm": ^"Planet/SandwormTerritory/Sandworm",
	"volcanoronomous":
		^"Planet/VolcanoronomousCaldera/Volcanoronomous",
}


static func validate(
		boss_id: String,
		boss: Node,
		expected: Dictionary) -> PackedStringArray:
	var failures: Array[String] = []
	if not BossCatalog.has(boss_id):
		failures.append("BossCatalog does not contain '%s'" % boss_id)
		return PackedStringArray(failures)
	var definition := BossCatalog.definition(boss_id)
	if definition == null:
		failures.append("BossCatalog could not load '%s'" % boss_id)
		return PackedStringArray(failures)
	if not definition.valid():
		failures.append("BossDefinition.valid() rejected '%s'" % boss_id)

	_check_loaded_resources(definition, failures)
	_check_runtime_boss(boss_id, boss, definition, expected, failures)
	_check_location(definition, expected, failures)
	_check_moves_and_pretriggers(definition, failures)
	_check_asset_files(definition, failures)
	_check_imported_animations(definition, failures)
	return PackedStringArray(failures)


## Verifies that manual initialization discovers, rather than respawns, the
## three authored encounters. The caller owns and frees the detached world.
static func validate_authored_director(world: Node) -> PackedStringArray:
	var failures: Array[String] = []
	if world == null:
		return PackedStringArray(["authored world is null"])
	var director := world.get_node_or_null(^"BossDirector") as BossDirector
	if director == null:
		return PackedStringArray(["authored world has no BossDirector"])

	var before_nodes: Dictionary = {}
	var before_parents: Dictionary = {}
	var before_transforms: Dictionary = {}
	var before_indices: Dictionary = {}
	for id_value: Variant in AUTHORED_BOSS_PATHS:
		var id := String(id_value)
		var path: NodePath = AUTHORED_BOSS_PATHS[id]
		var boss := world.get_node_or_null(path)
		if boss == null:
			failures.append("authored boss path is missing: %s" % path)
			continue
		before_nodes[id] = boss
		before_parents[id] = boss.get_parent()
		before_indices[id] = boss.get_index()
		if boss is Node3D:
			before_transforms[id] = (boss as Node3D).transform

	if not director.initialize(world) or not director.initialized():
		failures.append("BossDirector manual initialization failed")

	for id_value: Variant in AUTHORED_BOSS_PATHS:
		var id := String(id_value)
		var original := before_nodes.get(id) as Node
		if original == null:
			continue
		var path: NodePath = AUTHORED_BOSS_PATHS[id]
		var original_parent := before_parents.get(id) as Node3D
		if director.lookup_boss(id) != original:
			failures.append("BossDirector did not resolve existing '%s'" % id)
		if director.lookup_site(id) != original_parent:
			failures.append("BossDirector resolved the wrong '%s' site" % id)
		if world.get_node_or_null(path) != original \
				or original.get_parent() != original_parent:
			failures.append("BossDirector replaced or reparented %s" % path)
		if original.get_index() != int(before_indices.get(id, -1)):
			failures.append("BossDirector reordered %s" % path)
		if original is Node3D and before_transforms.has(id):
			var before: Transform3D = before_transforms[id]
			if not (original as Node3D).transform.is_equal_approx(before):
				failures.append("BossDirector moved %s" % path)
		if _boss_count(world, id) != 1:
			failures.append(
				"BossDirector left duplicate '%s' nodes" % id)
	return PackedStringArray(failures)


static func _check_loaded_resources(
		definition: BossDefinition,
		failures: Array[String]) -> void:
	if definition.boss_scene == null \
			or not definition.boss_scene.can_instantiate():
		failures.append("controller scene is not loaded/instantiable")
	elif not FileAccess.file_exists(definition.boss_scene.resource_path):
		failures.append("controller scene file is missing")
	if definition.controller_script == null \
			or not definition.controller_script.can_instantiate():
		failures.append("controller script is not loaded/instantiable")
	elif not FileAccess.file_exists(definition.controller_script.resource_path):
		failures.append("controller script file is missing")
	if definition.runtime_model == null \
			or not definition.runtime_model.can_instantiate():
		failures.append("runtime model is not loaded/instantiable")
	elif not FileAccess.file_exists(definition.runtime_model.resource_path):
		failures.append("runtime model file is missing")


static func _check_runtime_boss(
		boss_id: String,
		boss: Node,
		definition: BossDefinition,
		expected: Dictionary,
		failures: Array[String]) -> void:
	var controller := boss as BossController
	if controller == null:
		failures.append("boss instance does not inherit BossController")
		return
	if controller.definition() != definition:
		failures.append("BossController inherited the wrong definition")
	if controller.definition_id != boss_id:
		failures.append(
			"BossController definition_id is '%s', expected '%s'"
			% [controller.definition_id, boss_id])
	if controller.get_script() != definition.controller_script:
		failures.append("boss instance does not use the catalog controller script")
	if controller.boss_id() != boss_id or definition.boss_id != boss_id:
		failures.append("runtime/catalog boss ID does not match '%s'" % boss_id)

	for key: String in [
			"node_name", "display_name", "max_health", "arena_radius",
			"detection_radius", "reset_delay", "arena_distance_mode",
			"location",
		]:
		if not expected.has(key):
			failures.append("expected contract is missing '%s'" % key)
	if expected.has("node_name") \
			and boss.name != StringName(String(expected["node_name"])):
		failures.append(
			"node name is '%s', expected '%s'"
			% [boss.name, expected["node_name"]])
	if expected.has("display_name"):
		var display_name := String(expected["display_name"])
		if definition.display_name != display_name \
				or controller.combat_display_name() != display_name:
			failures.append(
				"display name does not match '%s'" % display_name)
	if expected.has("max_health"):
		var health := float(expected["max_health"])
		if not is_equal_approx(definition.max_health, health) \
				or not is_equal_approx(controller.maximum_health(), health) \
				or not is_equal_approx(controller.health(), health):
			failures.append("health contract does not match %.3f" % health)
	if expected.has("arena_radius"):
		var radius := float(expected["arena_radius"])
		if not is_equal_approx(definition.arena_radius, radius) \
				or not is_equal_approx(controller.battle_radius(), radius):
			failures.append("arena radius does not match %.3f" % radius)
	if expected.has("detection_radius") and not is_equal_approx(
			definition.detection_radius, float(expected["detection_radius"])):
		failures.append("arena detection radius does not match")
	if expected.has("reset_delay") and not is_equal_approx(
			definition.reset_delay, float(expected["reset_delay"])):
		failures.append("arena reset delay does not match")
	if expected.has("arena_distance_mode") \
			and definition.arena_distance_mode != StringName(
				String(expected["arena_distance_mode"])):
		failures.append("arena distance mode does not match")


static func _check_location(
		definition: BossDefinition,
		expected: Dictionary,
		failures: Array[String]) -> void:
	var value: Variant = expected.get("location")
	if not value is Dictionary:
		return
	var location := value as Dictionary
	var mode := StringName(String(location.get("mode", "")))
	if definition.location_mode() != mode:
		failures.append("location mode does not match '%s'" % mode)
		return
	if mode == &"planet_surface":
		var direction: Variant = location.get("direction")
		if not direction is Vector3 \
				or not definition.surface_direction().is_equal_approx(
					direction as Vector3):
			failures.append("planet-surface direction does not match")
		if not is_equal_approx(
				definition.surface_facing(),
				float(location.get("facing", INF))):
			failures.append("planet-surface facing does not match")
		if not is_equal_approx(
				definition.surface_clearance(),
				float(location.get("clearance", INF))):
			failures.append("planet-surface clearance does not match")
	elif mode == &"world_space":
		if definition.world_parent() != NodePath(
				String(location.get("parent", ""))):
			failures.append("world-space parent does not match")
		var origin: Variant = location.get("origin")
		if not origin is Vector3 \
				or not definition.world_origin().is_equal_approx(
					origin as Vector3):
			failures.append("world-space origin does not match")
		var orientation: Variant = location.get("orientation")
		if not orientation is Vector3 \
				or not definition.world_orientation().is_equal_approx(
					orientation as Vector3):
			failures.append("world-space orientation does not match")


static func _check_moves_and_pretriggers(
		definition: BossDefinition,
		failures: Array[String]) -> void:
	var clips := definition.all_animation_clips()
	var rest := definition.animation(&"rest")
	if rest.is_empty() or not clips.has(String(rest)):
		failures.append("animations.rest does not map a declared clip")
	var move_ids: Dictionary = {}
	for value: Variant in definition.moves:
		if not value is Dictionary:
			failures.append("move entry is not a dictionary")
			continue
		var move := value as Dictionary
		var move_id := String(move.get("id", ""))
		if move_id.is_empty() or not move_id.is_valid_identifier() \
				or move_id != move_id.to_lower() or move_ids.has(move_id):
			failures.append("move ID is invalid or duplicated: '%s'" % move_id)
		else:
			move_ids[move_id] = true
		var behavior := String(move.get("behavior", ""))
		if behavior.begins_with("custom:"):
			var custom_id := behavior.trim_prefix("custom:")
			if definition.controller_mode != &"custom" \
					or custom_id.is_empty() \
					or not custom_id.is_valid_identifier() \
					or custom_id != custom_id.to_lower():
				failures.append(
					"custom behavior is invalid for this controller: '%s'"
					% behavior)
		elif not BossMoveRegistry.recognizes(StringName(behavior)):
			failures.append("move behavior is not registered: '%s'" % behavior)
		var mappings_value: Variant = move.get("animations")
		if not mappings_value is Dictionary \
				or (mappings_value as Dictionary).is_empty():
			failures.append("move '%s' has no animation mappings" % move_id)
			continue
		for stage_value: Variant in mappings_value:
			var stage := String(stage_value)
			var clip := String((mappings_value as Dictionary)[stage_value])
			if stage.is_empty() or not stage.is_valid_identifier() \
					or stage != stage.to_lower() \
					or clip.is_empty() or not clips.has(clip):
				failures.append(
					"move '%s' has invalid mapping '%s' -> '%s'"
					% [move_id, stage, clip])

	var trigger_ids: Dictionary = {}
	for trigger: String in definition.pretriggers:
		if trigger_ids.has(trigger) \
				or not BossPretriggerRegistry.recognizes(StringName(trigger)):
			failures.append(
				"pretrigger is invalid or duplicated: '%s'" % trigger)
		else:
			trigger_ids[trigger] = true


static func _check_asset_files(
		definition: BossDefinition,
		failures: Array[String]) -> void:
	var manifest := "%s/%s.json" % [
		MANIFEST_DIRECTORY, definition.boss_id]
	_require_file("manifest", manifest, failures)
	var source := String(definition.asset.get("source", ""))
	var runtime := String(definition.asset.get("runtime_glb", ""))
	var builder := String(definition.asset.get("builder", ""))
	_require_file("asset source", source, failures)
	_require_file("runtime GLB", runtime, failures)
	if source.get_extension().to_lower() == "blend" and builder.is_empty():
		failures.append("a .blend source requires an asset builder")
	elif not builder.is_empty():
		_require_file("asset builder", builder, failures)
	if definition.runtime_model != null \
			and definition.runtime_model.resource_path != runtime:
		failures.append("runtime model does not match asset.runtime_glb")


static func _check_imported_animations(
		definition: BossDefinition,
		failures: Array[String]) -> void:
	if definition.runtime_model == null \
			or not definition.runtime_model.can_instantiate():
		return
	var model := definition.runtime_model.instantiate()
	if model == null:
		failures.append("runtime GLB could not be instantiated")
		return
	var animator := model as AnimationPlayer
	if animator == null:
		var players := model.find_children(
			"*", "AnimationPlayer", true, false)
		if not players.is_empty():
			animator = players[0] as AnimationPlayer
	if animator == null:
		failures.append("runtime GLB has no AnimationPlayer")
	else:
		for clip: String in definition.all_animation_clips():
			if not animator.has_animation(StringName(clip)):
				failures.append(
					"runtime GLB is missing animation '%s'" % clip)
	model.free()


static func _require_file(
		label: String,
		path: String,
		failures: Array[String]) -> void:
	if path.is_empty() or not path.begins_with("res://") \
			or not FileAccess.file_exists(path):
		failures.append("%s file is missing: %s" % [label, path])


static func _boss_count(world: Node, boss_id: String) -> int:
	var count := 0
	for candidate: Node in world.find_children("*", "", true, false):
		if candidate.has_method(&"boss_id") \
				and String(candidate.call(&"boss_id")) == boss_id:
			count += 1
	return count
