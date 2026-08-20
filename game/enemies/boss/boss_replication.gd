class_name BossReplication
extends RefCounted

const SNAPSHOT_HZ := 20.0
const SNAPSHOT_INTERVAL := 1.0 / SNAPSHOT_HZ

var _owner: Node
var _snapshot_left := 0.0
var _sync_sequence := 0
var _accepted_sync_sequence := 0
var _event_sequence := 0
var _accepted_event_sequence := 0
var _accepted_unsequenced_snapshot := false
var _accepted_unsequenced_event := false


func configure(owner: Node) -> BossReplication:
	_owner = owner
	reset()
	return self


func reset() -> void:
	_snapshot_left = 0.0
	_sync_sequence = 0
	_accepted_sync_sequence = 0
	_event_sequence = 0
	_accepted_event_sequence = 0
	_accepted_unsequenced_snapshot = false
	_accepted_unsequenced_event = false


func is_host() -> bool:
	return _owner != null and (
		not _owner.multiplayer.has_multiplayer_peer()
		or _owner.multiplayer.is_server())


func is_listener() -> bool:
	return _owner != null \
		and _owner.multiplayer.has_multiplayer_peer() \
		and not _owner.multiplayer.is_server()


func has_listeners() -> bool:
	return _owner != null \
		and _owner.multiplayer.has_multiplayer_peer() \
		and not _owner.multiplayer.get_peers().is_empty()


## Returns true at most twenty times a second while preserving fractional time.
func snapshot_due(delta: float, force := false) -> bool:
	if force:
		_snapshot_left = SNAPSHOT_INTERVAL
		return true
	if not is_finite(delta) or delta <= 0.0:
		return false
	_snapshot_left -= delta
	if _snapshot_left > 0.0:
		return false
	_snapshot_left += SNAPSHOT_INTERVAL
	if _snapshot_left <= 0.0:
		_snapshot_left = SNAPSHOT_INTERVAL
	return true


func stamp_snapshot(snapshot: Dictionary) -> Dictionary:
	_sync_sequence += 1
	var wire := snapshot.duplicate(true)
	wire["sync_sequence"] = _sync_sequence
	return wire


func stamp_event(event: Dictionary) -> Dictionary:
	_event_sequence += 1
	var wire := event.duplicate(true)
	wire["sequence"] = _event_sequence
	return wire


func accept_snapshot(snapshot: Dictionary, sequence := -1) -> bool:
	var incoming := int(snapshot.get("sync_sequence", 0)) \
		if sequence < 0 else int(sequence)
	if incoming <= 0:
		if _accepted_sync_sequence > 0 or _accepted_unsequenced_snapshot:
			return false
		_accepted_unsequenced_snapshot = true
		return true
	if incoming <= _accepted_sync_sequence:
		return false
	_accepted_sync_sequence = incoming
	return true


func accept_event(event: Dictionary, sequence := -1) -> bool:
	var incoming := int(event.get("sequence", 0)) \
		if sequence < 0 else int(sequence)
	if incoming <= 0:
		if _accepted_event_sequence > 0 or _accepted_unsequenced_event:
			return false
		_accepted_unsequenced_event = true
		return true
	if incoming <= _accepted_event_sequence:
		return false
	_accepted_event_sequence = incoming
	return true


func sync_sequence() -> int:
	return _sync_sequence


func accepted_sync_sequence() -> int:
	return _accepted_sync_sequence


func event_sequence() -> int:
	return _event_sequence


func accepted_event_sequence() -> int:
	return _accepted_event_sequence
