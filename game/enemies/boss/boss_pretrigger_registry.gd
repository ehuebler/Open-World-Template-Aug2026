class_name BossPretriggerRegistry
extends RefCounted

const BASE := preload(
	"res://game/enemies/boss/boss_pretrigger.gd")
const PROXIMITY := preload(
	"res://game/enemies/boss/boss_proximity_pretrigger.gd")

const BUILT_INS := {
	"arena_entry": true,
	"desert_flyby": true,
	"caldera_run": true,
}

static var _implementations: Dictionary = {}


static func recognizes(id: StringName) -> bool:
	var name := String(id)
	if BUILT_INS.has(name):
		return true
	if not name.begins_with("custom:"):
		return false
	var suffix := name.trim_prefix("custom:")
	return not suffix.is_empty() and suffix.is_valid_identifier() \
		and suffix == suffix.to_lower()


static func create(id: StringName, owner: Node) -> BossPretrigger:
	var name := String(id)
	if not recognizes(id):
		return null
	var implementation := _implementations.get(name) as Script
	if implementation != null and implementation.can_instantiate():
		var custom: Variant = implementation.new()
		if custom is BossPretrigger:
			(custom as BossPretrigger).configure(owner, id, false)
			return custom as BossPretrigger
		push_error(
			"Boss pretrigger implementation '%s' must extend BossPretrigger"
			% name)
		if custom is Node:
			(custom as Node).free()
	match name:
		"arena_entry":
			return PROXIMITY.new().configure_proximity(
				owner, id, &"arena")
		"desert_flyby":
			return PROXIMITY.new().configure_proximity(
				owner, id, &"proximity")
		_:
			# The caldera trial and unregistered custom triggers are owned by
			# encounter code, not by generated definitions.
			return BASE.new().configure(owner, id, true)


static func register_implementation(
		id: StringName, implementation: Script) -> bool:
	if not recognizes(id) or implementation == null \
			or not implementation.can_instantiate():
		return false
	var probe: Variant = implementation.new()
	if not probe is BossPretrigger:
		if probe is Node:
			(probe as Node).free()
		return false
	_implementations[String(id)] = implementation
	return true


static func unregister_implementation(id: StringName) -> void:
	_implementations.erase(String(id))
