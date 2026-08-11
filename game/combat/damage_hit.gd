class_name DamageHit
extends RefCounted

## One volume of damage, handed to everything standing inside it.
##
## Abilities do not know what they are hitting. They describe a shape, an amount
## and how the amount falls off across it, and every damageable field works out
## for itself which of the things it owns are inside. That is what lets one laser
## tick damage grass, a tree and the ground with the same object, and what keeps
## the ability files free of any knowledge of MultiMesh buffers or tile cells.
##
## The shape is always a capsule. A point impact is a capsule of zero length, so
## there is one distance function rather than three, and a beam that sweeps
## between two ticks is the segment between where it was and where it is —
## which is what stops a fast sweep from stitching its damage into dots.
##
## Nothing here is per-target state. A hit is built, offered around, and dropped;
## the accumulated damage lives with whatever absorbed it.

## Group every field that can be damaged by an ability joins. Abilities reach
## their targets through this rather than through node paths, the same way
## [ImpactBreakEffects] is found.
const FIELD_GROUP := &"flora_damage_fields"

enum Kind {
	## A sustained cutting line, such as the laser. Damages along its length.
	BEAM,
	## A single violent contact, such as the meteor fist.
	IMPACT,
	## The dissipating spread left behind by an impact.
	AREA,
}

## Damage at the centre of the volume, before falloff and before the target's
## own toughness. For a sustained effect this is already the per-tick share, not
## a rate: an ability that ticks ten times a second passes a tenth of its
## quoted damage each time.
var amount := 0.0
## Ends of the capsule's axis, in world space. Equal for a point impact.
var origin := Vector3.ZERO
var toward := Vector3.ZERO
## Radius of the capsule in metres.
var radius := 1.0
var kind := Kind.IMPACT
## How much of the damage survives to the edge of the radius. 0 keeps the full
## amount everywhere inside (a clean cut), 1 falls linearly to nothing (the
## dissipating spread of a landing).
var falloff := 0.0
## Who caused it, so a host can attribute a break, and the ability that did, so
## a field can pick a matching break effect.
var source_peer := 0
var ability_id := ""


## A cutting line between two points.
static func beam(from: Vector3, to: Vector3, beam_radius: float,
		damage: float) -> DamageHit:
	var hit := DamageHit.new()
	hit.kind = Kind.BEAM
	hit.origin = from
	hit.toward = to
	hit.radius = maxf(beam_radius, 0.01)
	hit.amount = damage
	return hit


## A point contact with no spread.
static func impact(at: Vector3, impact_radius: float,
		damage: float) -> DamageHit:
	var hit := DamageHit.new()
	hit.kind = Kind.IMPACT
	hit.origin = at
	hit.toward = at
	hit.radius = maxf(impact_radius, 0.01)
	hit.amount = damage
	return hit


## A spread that dissipates toward its edge.
static func area(at: Vector3, area_radius: float, damage: float,
		edge_falloff := 1.0) -> DamageHit:
	var hit := DamageHit.new()
	hit.kind = Kind.AREA
	hit.origin = at
	hit.toward = at
	hit.radius = maxf(area_radius, 0.01)
	hit.amount = damage
	hit.falloff = clampf(edge_falloff, 0.0, 1.0)
	return hit


## Middle of the volume, which is what a field measures its tiles against.
## Offers a hit to every damageable field in the scene and returns how much of
## it was absorbed.
##
## [param anywhere] is any node already in the tree; only its tree is used. The
## group is the whole of the addressing here — an ability never holds a path to
## a flora field, and a field that is added or removed mid-session is picked up
## or dropped without anything being told.
static func apply_to_world(anywhere: Node, hit: DamageHit) -> float:
	if anywhere == null or hit == null or not anywhere.is_inside_tree():
		return 0.0
	var absorbed := 0.0
	for field in anywhere.get_tree().get_nodes_in_group(FIELD_GROUP):
		if field.has_method(&"apply_damage"):
			absorbed += float(field.call(&"apply_damage", hit))
	return absorbed


func centre() -> Vector3:
	return (origin + toward) * 0.5


## Distance from the centre out to the furthest point the volume can touch. A
## field uses this to reject whole tiles with one comparison.
func extent() -> float:
	return origin.distance_to(toward) * 0.5 + radius


## Shortest distance from a point to the capsule's axis.
func distance_to(point: Vector3) -> float:
	var along := toward - origin
	var length_squared := along.length_squared()
	if length_squared < 0.000001:
		return point.distance_to(origin)
	var share := clampf((point - origin).dot(along) / length_squared, 0.0, 1.0)
	return point.distance_to(origin + along * share)


## Share of [member amount] a point receives, 0 outside the volume.
func share_at(point: Vector3) -> float:
	var away := distance_to(point)
	if away >= radius:
		return 0.0
	if falloff <= 0.0:
		return 1.0
	return lerpf(1.0, 1.0 - falloff, away / radius)


## Damage a point receives, before the target's own toughness.
func damage_at(point: Vector3) -> float:
	return amount * share_at(point)


## Whether a sphere of [param bounds] around [param at] can touch this volume at
## all. Deliberately generous: it is the cheap test that lets a field skip a
## tile without decoding a single instance transform.
func reaches(at: Vector3, bounds: float) -> bool:
	return distance_to(at) <= radius + maxf(bounds, 0.0)


## The wire form. Effect volumes replicate rather than per-instance damage, so
## every peer applies the identical shape to its own deterministic flora.
func to_wire() -> Dictionary:
	return {
		"amount": amount,
		"origin": origin,
		"toward": toward,
		"radius": radius,
		"kind": int(kind),
		"falloff": falloff,
		"source_peer": source_peer,
		"ability_id": ability_id,
	}


static func from_wire(wire: Dictionary) -> DamageHit:
	var hit := DamageHit.new()
	hit.amount = float(wire.get("amount", 0.0))
	hit.origin = wire.get("origin", Vector3.ZERO)
	hit.toward = wire.get("toward", hit.origin)
	hit.radius = maxf(float(wire.get("radius", 1.0)), 0.01)
	hit.kind = int(wire.get("kind", Kind.IMPACT)) as Kind
	hit.falloff = clampf(float(wire.get("falloff", 0.0)), 0.0, 1.0)
	hit.source_peer = int(wire.get("source_peer", 0))
	hit.ability_id = String(wire.get("ability_id", ""))
	return hit
