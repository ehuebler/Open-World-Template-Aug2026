class_name CombatStatuses
extends RefCounted

## Small, temporary combat effects shared by players and future enemies.
##
## Durations are authoritative on the host, but the same snapshot can be ticked
## locally for responsive HUD countdowns. Unknown ids are ignored so malformed
## packets cannot invent gameplay rules.

const FLIGHTLESS := &"flightless"
const MAX_DURATION := 3600.0

const DEFINITIONS := {
	FLIGHTLESS: {
		"title": "Flightless",
		"description": "Flight is disabled.",
	},
}

signal changed(id: StringName, remaining: float)

var _remaining: Dictionary = {}
## Reused by [method tick] so the physics hot path does not allocate an array.
var _expired: Array[StringName] = []


static func is_known(id: StringName) -> bool:
	return DEFINITIONS.has(id)


func has(id: StringName) -> bool:
	return float(_remaining.get(id, 0.0)) > 0.0


func remaining(id: StringName) -> float:
	return maxf(float(_remaining.get(id, 0.0)), 0.0)


## Adds or refreshes an effect. The longer authored duration wins.
func apply_status(id: StringName, duration: float) -> bool:
	if not is_known(id) or not is_finite(duration) or duration <= 0.0:
		return false
	var next := minf(duration, MAX_DURATION)
	var before := remaining(id)
	if before >= next:
		return false
	_remaining[id] = next
	changed.emit(id, next)
	return true


## Compatibility-friendly short form for combatants authoring an effect.
func apply(id: StringName, duration: float) -> bool:
	return apply_status(id, duration)


## Advances countdowns and returns whether an effect expired.
func tick(delta: float) -> bool:
	if delta <= 0.0 or _remaining.is_empty():
		return false
	_expired.clear()
	for id_variant: Variant in _remaining:
		var id := StringName(id_variant)
		var left := maxf(float(_remaining[id]) - delta, 0.0)
		if left <= 0.0:
			_expired.append(id)
		else:
			_remaining[id] = left
			changed.emit(id, left)
	for id in _expired:
		_remaining.erase(id)
		changed.emit(id, 0.0)
	return not _expired.is_empty()


## Clears one effect, or all effects when no id is supplied.
func clear(id := &"") -> bool:
	var status_id := StringName(id)
	if not status_id.is_empty():
		if not _remaining.erase(status_id):
			return false
		changed.emit(status_id, 0.0)
		return true
	if _remaining.is_empty():
		return false
	_expired.clear()
	for id_variant: Variant in _remaining:
		_expired.append(StringName(id_variant))
	_remaining.clear()
	for expired_id in _expired:
		changed.emit(expired_id, 0.0)
	return true


## Stable HUD/stat rows. Callers may redraw these only when [signal changed] fires.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: StringName in DEFINITIONS:
		var left := remaining(id)
		if left <= 0.0:
			continue
		var definition: Dictionary = DEFINITIONS[id]
		out.append({
			"id": id,
			"title": String(definition.get("title", String(id))),
			"description": String(definition.get("description", "")),
			"remaining": left,
			"text": "%.1f s" % left,
		})
	return out


## Compact wire snapshot. Dictionary keys are strings for RPC compatibility.
func to_wire() -> Dictionary:
	var wire := {}
	for id_variant: Variant in _remaining:
		var id := StringName(id_variant)
		var left := remaining(id)
		if left > 0.0:
			wire[String(id)] = left
	return wire


func snapshot() -> Dictionary:
	return to_wire()


func apply_wire(wire: Dictionary) -> void:
	var next := {}
	for id_variant: Variant in wire:
		var id := StringName(id_variant)
		if not is_known(id):
			continue
		var left := float(wire[id_variant])
		if not is_finite(left) or left <= 0.0:
			continue
		next[id] = minf(left, MAX_DURATION)

	_expired.clear()
	for id_variant: Variant in _remaining:
		var old_id := StringName(id_variant)
		if not next.has(old_id):
			_expired.append(old_id)
	for old_id in _expired:
		changed.emit(old_id, 0.0)
	_remaining = next
	for id_variant: Variant in _remaining:
		var id := StringName(id_variant)
		changed.emit(id, float(_remaining[id]))


func apply_snapshot(wire: Dictionary) -> void:
	apply_wire(wire)
