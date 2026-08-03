@tool
class_name RoadProfile
extends RefCounted

## What a road is seen end-on: the carriageway, the footways beside it, the kerb
## between the two, and the ramp back down to the ground at the outside.
##
## Nothing here draws. It is split out from [RoadMesh] because two separate things
## need these numbers and have to agree on them: the mesh extrudes the shapes,
## while [RoadNetwork] wants only the outermost offset, to know how far back from
## a crossing a road must stop. When those two disagreed the junction paving
## either floated clear of the roads reaching it or overlapped them, and neither
## is visible in a picture of one road on its own.
##
## A road kind is a dictionary of metres:
##
## [codeblock]
## {"road": 7.0, "walk": 2.2, "kerb": 0.16, "lift": 0.61,
##  "tone": "asphalt", "deck": false}
## [/codeblock]
##
## [code]road[/code] is the carriageway and [code]walk[/code] the footway on each
## side of it — [b]zero for a way with no kerb to step off[/b], which is what a
## one-lane back street and a park path have in common. [code]kerb[/code] is how
## far the footway stands over the carriageway and [code]lift[/code] how far the
## carriageway stands over the ground. [code]tone[/code] names the carriageway's
## surface, [code]asphalt[/code] or [code]paving[/code]; footways are always
## paved. [code]deck[/code] marks a road carried on piers instead of laid on the
## ground, which is the only kind you can walk under.

## Carriageway and footway, as vertex colours. Grey, and the ground under them is
## already carrying the district's own colour.
##
## Darker than they look. These are albedo, and the scene puts a sun and a sky
## worth about 1.4 through them before ACES tone maps the result — a nominal
## mid-grey 0.34 comes out of that at nearly 0.75, which is a road made of paper.
## Read them against a screenshot, never against a colour picker.
const ASPHALT := Color(0.16, 0.16, 0.175)
const PAVING := Color(0.42, 0.415, 0.40)
const DECK := Color(0.24, 0.24, 0.255)
const PIER := Color(0.20, 0.20, 0.21)

## Shortest the ramp at a road's outer edge may be, in metres. Without one the
## slab ends in a vertical drop onto the ground and the whole city reads as
## stickers laid on the grass rather than as ground that was built up.
const APRON := 0.45

## Steepest that ramp may be, as rise over run: 0.577 is thirty degrees.
##
## This is a hard constraint and not a taste, and it is the number that decides
## whether a raised city is walkable. [OnlinePlayer] steps up [code]step_height[/code]
## 0.3 m and treats anything past its own [code]floor_max_angle[/code] of 45° as a
## wall, so a roadbed lifted further than 0.3 m can only be got onto up a slope,
## and only if that slope is inside 45°. Thirty leaves the margin: at 45° a body
## arriving with any sideways speed slides back off.
const RAMP_GRADE := 0.577

## Viaducts: how deep the box girder is under the deck, how tall the parapet is,
## and how far in from the edge it stands.
const GIRDER := 1.1
const PARAPET := 0.85
const PARAPET_WIDTH := 0.35


## How far the ramp at a road's outer edge stands over the ground, which is what
## that ramp has to give back.
##
## A kerbed road's outer surface is its [i]footway[/i], not its carriageway, and a
## footway stands a kerb higher still. Sizing the apron from the lift alone built
## a ramp carrying 0.79 m of fall over 1.06 m of run — 36.7° where the table said
## 30, walkable by luck rather than by design, and found only by walking off a
## boulevard in [code]dev/_city_test.gd[/code] and measuring what was under foot.
static func fall(kind: Dictionary) -> float:
	var lift := float(kind["lift"])
	if float(kind["walk"]) <= 0.0:
		return lift
	return lift + float(kind["kerb"])


## How far a road's edge is ramped out sideways to reach the ground.
##
## Grown from the fall rather than fixed, so that lifting a carriageway does not
## quietly wall the player out of the street. A 0.10 m kerbline is off the ground
## by less than a boot and its 0.45 m apron is already a twelve-degree scuff; two
## feet up needs 1.06 m of ramp to stay inside [constant RAMP_GRADE], and gets it.
static func apron(kind: Dictionary) -> float:
	return maxf(APRON, fall(kind) / RAMP_GRADE)


## A road laid on the ground: the ramp up to the footway, the kerb up from the
## carriageway, and the same back down the other side. Offsets are metres across
## from the centreline, heights metres above the carriageway.
static func ground(kind: Dictionary) -> Dictionary:
	var half := float(kind["road"]) * 0.5
	var walk := float(kind["walk"])
	var lift := float(kind["lift"])
	var ramp := apron(kind)
	var surface := tone(kind)
	if walk <= 0.0:
		# Paths, promenades and one-lane streets: no footway, so no kerb, and the
		# ramp runs straight off the edge of the carriageway.
		return {
			"points": PackedVector2Array([
				Vector2(-half - ramp, -lift), Vector2(-half, 0.0),
				Vector2(half, 0.0), Vector2(half + ramp, -lift)]),
			"tones": PackedColorArray([surface, surface, surface, surface])}
	var kerb := float(kind["kerb"])
	return {
		"points": PackedVector2Array([
			Vector2(-half - walk - ramp, -lift),
			Vector2(-half - walk, kerb),
			Vector2(-half, kerb),
			Vector2(-half, 0.0),
			Vector2(half, 0.0),
			Vector2(half, kerb),
			Vector2(half + walk, kerb),
			Vector2(half + walk + ramp, -lift)]),
		"tones": PackedColorArray([
			PAVING, PAVING, PAVING, surface, surface, PAVING, PAVING, PAVING])}


## A viaduct: a closed box girder with a parapet standing on each edge. Closed,
## because the underside of this one is something you can fly along and it needs
## to be there when you do.
##
## Runs from the right edge to the left, which is backwards from every other
## profile here and is the whole point. A closed loop's faces all turn together,
## so the direction the carriageway is traced in decides which way the entire box
## faces — and traced left to right, like a ground road, this one comes out
## inside-out. That is not only a dark viaduct: [ConcavePolygonShape3D] collides
## on its front faces alone, so an inside-out deck is a deck you fall through and
## then cannot get back out of, which is exactly what it did.
static func deck(kind: Dictionary) -> Dictionary:
	var half := float(kind["road"]) * 0.5
	var inner := half - PARAPET_WIDTH
	return {
		"points": PackedVector2Array([
			Vector2(inner, 0.0),
			Vector2(inner, PARAPET),
			Vector2(half, PARAPET),
			Vector2(half, -GIRDER),
			Vector2(-half, -GIRDER),
			Vector2(-half, PARAPET),
			Vector2(-inner, PARAPET),
			Vector2(-inner, 0.0)]),
		"tones": PackedColorArray([
			DECK, PIER, PIER, PIER, PIER, PIER, PIER, DECK])}


## Half a road's cross-section reduced to the four points a junction rim is built
## from, outermost first: the ramp's outer lip, the footway's outer edge, the top
## of the kerb, and the edge of the carriageway. Offsets are metres across from
## the centreline, heights metres above it.
##
## A kind with no footway collapses the middle two onto the carriageway edge,
## which leaves every road the same shape as far as a junction is concerned — so a
## one-lane street can meet a boulevard without either side knowing.
static func rim(kind: Dictionary) -> Dictionary:
	var half := float(kind["road"]) * 0.5
	var walk := float(kind["walk"])
	var lift := float(kind["lift"])
	var ramp := apron(kind)
	if walk <= 0.0:
		return {
			"offsets": PackedFloat32Array([half + ramp, half, half, half]),
			"heights": PackedFloat32Array([-lift, 0.0, 0.0, 0.0])}
	var kerb := float(kind["kerb"])
	return {
		"offsets": PackedFloat32Array([half + walk + ramp, half + walk, half, half]),
		"heights": PackedFloat32Array([-lift, kerb, kerb, 0.0])}


## The rim's tones, taken off the profile rather than restated, so a paved path's
## surface stays paved where it meets a junction.
static func rim_tones(kind: Dictionary) -> PackedColorArray:
	var tones: PackedColorArray = (ground(kind))["tones"]
	if tones.size() == 4:
		return PackedColorArray([tones[3], tones[2], tones[2], tones[2]])
	return PackedColorArray([tones[7], tones[6], tones[5], tones[4]])


## How far this kind reaches from its own centreline, which is what a junction has
## to set every road back by before the crossing can be paved as one piece.
static func reach(kind: Dictionary) -> float:
	return (rim(kind)["offsets"] as PackedFloat32Array)[0]


## Half the width of the carriageway alone, plus its ramp. What a viaduct's leg
## has to stay clear of, and what an audit measures overlap against.
static func clearance(kind: Dictionary) -> float:
	return float(kind["road"]) * 0.5 + apron(kind)


static func tone(kind: Dictionary) -> Color:
	return PAVING if String(kind.get("tone", "asphalt")) == "paving" else ASPHALT
