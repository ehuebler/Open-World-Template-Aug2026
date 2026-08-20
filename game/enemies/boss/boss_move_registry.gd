class_name BossMoveRegistry
extends RefCounted

const IDLE := preload(
	"res://game/enemies/boss/moves/boss_move_idle.gd")
const CHASE := preload(
	"res://game/enemies/boss/moves/boss_move_chase.gd")
const FLY := preload(
	"res://game/enemies/boss/moves/boss_move_fly.gd")
const MELEE := preload(
	"res://game/enemies/boss/moves/boss_move_melee.gd")
const AREA := preload(
	"res://game/enemies/boss/moves/boss_move_area.gd")
const CHARGE := preload(
	"res://game/enemies/boss/moves/boss_move_charge.gd")
const PROJECTILE := preload(
	"res://game/enemies/boss/moves/boss_move_projectile.gd")

const BUILT_INS := {
	"idle": IDLE,
	"chase": CHASE,
	"fly": FLY,
	"melee": MELEE,
	"area": AREA,
	"charge": CHARGE,
	"projectile": PROJECTILE,
}

static var _custom_implementations: Dictionary = {}


static func built_in_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for id: Variant in BUILT_INS:
		result.append(String(id))
	result.sort()
	return result


static func recognizes(behavior: StringName) -> bool:
	var id := String(behavior)
	return BUILT_INS.has(id) or _custom_implementations.has(id)


static func create(behavior: StringName) -> BossMove:
	var id := String(behavior)
	var implementation: Script = _custom_implementations.get(id) as Script
	if implementation == null:
		implementation = BUILT_INS.get(id) as Script
	if implementation == null or not implementation.can_instantiate():
		return null
	var instance: Variant = implementation.new()
	if instance is BossMove:
		return instance as BossMove
	push_error("Boss move implementation '%s' must extend BossMove" % id)
	if instance is Node:
		(instance as Node).free()
	return null


static func register_custom(
		behavior: StringName, implementation: Script) -> bool:
	var id := String(behavior)
	if not id.begins_with("custom:") or id.length() <= "custom:".length() \
			or implementation == null or not implementation.can_instantiate():
		return false
	var probe: Variant = implementation.new()
	var valid := probe is BossMove
	if probe is Node:
		(probe as Node).free()
	if not valid:
		return false
	_custom_implementations[id] = implementation
	return true


static func unregister_custom(behavior: StringName) -> void:
	_custom_implementations.erase(String(behavior))
