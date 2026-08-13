class_name DamageNumberEvent
extends RefCounted

## Presentation-only description of one combat number.

var amount := 0.0
var world_position := Vector3.ZERO
var incoming := false
var blocked := false
var critical := false
var source_peer := 0
var target_peer := 0


func to_wire() -> Dictionary:
	return {
		"amount": amount,
		"world_position": world_position,
		"incoming": incoming,
		"blocked": blocked,
		"critical": critical,
		"source_peer": source_peer,
		"target_peer": target_peer,
	}


static func from_wire(wire: Dictionary) -> DamageNumberEvent:
	var event := DamageNumberEvent.new()
	event.amount = maxf(float(wire.get("amount", 0.0)), 0.0)
	var at: Variant = wire.get("world_position", Vector3.ZERO)
	event.world_position = at if at is Vector3 and (at as Vector3).is_finite() \
		else Vector3.ZERO
	event.incoming = bool(wire.get("incoming", false))
	event.blocked = bool(wire.get("blocked", false))
	event.critical = bool(wire.get("critical", false))
	event.source_peer = maxi(int(wire.get("source_peer", 0)), 0)
	event.target_peer = maxi(int(wire.get("target_peer", 0)), 0)
	return event
