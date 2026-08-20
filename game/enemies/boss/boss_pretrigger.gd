class_name BossPretrigger
extends RefCounted

## Pretriggers decide when a generic encounter may engage. Complex authored
## sequences remain external metadata and can register their own implementation.

var _pretrigger_owner: Node
var _pretrigger_id := &""
var _pretrigger_external := true
var _pretrigger_triggered := false


func configure(
		owner: Node,
		id: StringName,
		externally_owned := true) -> BossPretrigger:
	_pretrigger_owner = owner
	_pretrigger_id = id
	_pretrigger_external = externally_owned
	_pretrigger_triggered = false
	return self


func tick_host(_delta: float, _players: Array) -> bool:
	return false


func reset() -> void:
	_pretrigger_triggered = false


func pretrigger_id() -> StringName:
	return _pretrigger_id


func externally_owned() -> bool:
	return _pretrigger_external


func triggered() -> bool:
	return _pretrigger_triggered


func snapshot() -> Dictionary:
	return {
		"id": String(_pretrigger_id),
		"external": _pretrigger_external,
		"triggered": _pretrigger_triggered,
	}


func apply_snapshot(wire: Dictionary) -> void:
	if wire.has("id") \
			and String(wire.get("id", "")) != String(_pretrigger_id):
		return
	_pretrigger_triggered = bool(
		wire.get("triggered", _pretrigger_triggered))


func owner_node() -> Node:
	return _pretrigger_owner \
		if is_instance_valid(_pretrigger_owner) else null
