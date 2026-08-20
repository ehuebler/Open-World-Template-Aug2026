class_name FloraBudget
extends RefCounted

## One frame's worth of flora streaming, shared by every field on the planet.
##
## A [GroundCover] field does four optional things per frame: it surveys which tiles
## it wants, dispatches the missing ones to the worker pool, applies the ones that
## came back, and re-dresses the standing ones for distance. Each of those is capped
## per field — `applies_per_frame`, `pending_limit`, [constant
## GroundCover.DRESS_SLICES] — and a planet carries seventeen fields. The caps
## therefore describe a seventeenth of what actually happens, and the fields all pay
## in full whether the viewer is standing in them or on the other side of the world.
##
## So the cap moves here. There is one microsecond budget per frame; fields are
## served nearest first, out of what each of them was measured costing last time,
## and one field beyond the budget is served in turn every frame so a distant field
## is late rather than never. A field that is not served this frame loses nothing:
## its timers keep running and its wanted set keeps standing, so the work happens on
## the frame its turn comes round.
##
## Static rather than an autoload because it is a scheduling decision and not a
## thing in the world; the fields find it by name and there is nothing to place,
## configure or replicate.

## Microseconds of flora streaming allowed per frame across the whole planet. About
## a fifth of a sixty-hertz frame, which is what the fields were spending on their
## own before flying pushed them to eight and twenty-one milliseconds.
const FRAME_USEC := 3000
## Assumed cost of a field nobody has timed yet, so a new field is granted a turn
## rather than being priced out of the first frame it exists in.
const UNKNOWN_USEC := 400
## Weight of the newest measurement in a field's running cost. One frame that
## happened to raise four tiles is not what that field costs.
const COST_BLEND := 0.25

static var _frame := -1
## Field instance id to whether it may work this frame, decided from last frame's
## distances.
static var _granted: Dictionary = {}
## Field instance id to metres from the viewer, filled by this frame's claims and
## used to rank the next one.
static var _reported: Dictionary = {}
## Field instance id to measured microseconds.
static var _cost: Dictionary = {}
## Which of the fields the budget could not reach gets the extra turn.
static var _rotation := 0
## What this frame's granted fields have really cost so far, and the field that must
## be served whatever that comes to. See [method claim].
static var _spent_usec := 0
static var _nearest := 0


## Whether [param field] may do its streaming work this frame, and what to price it
## at next frame. [param away] is metres from the viewer to the nearest ground the
## field covers, so the meadow underfoot outranks one over the horizon.
static func claim(field: int, away: float) -> bool:
	var frame := Engine.get_process_frames()
	if frame != _frame:
		_frame = frame
		_spent_usec = 0
		_rank()
	_reported[field] = away
	if not bool(_granted.get(field, false)):
		return false
	# Measured as well as predicted. A field is priced at what it cost last time, and
	# the frame a distant meadow finally has four finished tiles to raise costs
	# several times that — sixteen fields whose predictions add to one and a half
	# milliseconds spent five between them, all on the same frame, because each was
	# individually plausible. The ranking above decides who is served; this decides
	# when the frame has had enough of it.
	#
	# Except the nearest, which is the ground underfoot and is what the ranking exists
	# to protect. Refused fields lose nothing: their timers keep running and their
	# wanted sets keep standing.
	if field != _nearest and _spent_usec >= FRAME_USEC:
		return false
	return true


## What the granted work actually cost, which is what the next ranking spends.
static func spend(field: int, used: int) -> void:
	var spent := maxi(used, 0)
	var before := float(_cost.get(field, UNKNOWN_USEC))
	_cost[field] = lerpf(before, float(spent), COST_BLEND)
	_spent_usec += spent


## Serves the fields reported last frame, nearest first, until the budget runs out.
static func _rank() -> void:
	var away := _reported
	_reported = {}
	_granted = {}
	if away.is_empty():
		return
	var ranked := away.keys()
	ranked.sort_custom(func(a: Variant, b: Variant) -> bool:
		return float(away[a]) < float(away[b]))
	_nearest = int(ranked[0])
	var spent := 0.0
	var served := 0
	for field_variant: Variant in ranked:
		var cost := float(_cost.get(field_variant, UNKNOWN_USEC))
		# The nearest field is always served, however expensive it turned out to
		# be: a budget that can refuse the ground underfoot is a budget that stops
		# the world growing.
		if served > 0 and spent + cost > float(FRAME_USEC):
			break
		_granted[field_variant] = true
		spent += cost
		served += 1
	if served < ranked.size():
		var tail := ranked.size() - served
		_granted[ranked[served + _rotation % tail]] = true
		_rotation += 1
	# Costs are keyed by instance id, and a scene reload issues new ones. Kept to
	# the fields that reported, so a long session of loading worlds cannot leave a
	# ledger of prices for fields that no longer exist.
	for field_variant: Variant in _cost.keys():
		if not away.has(field_variant):
			_cost.erase(field_variant)


## Scheduler state without walking any field or changing the next grant.
static func statistics() -> Dictionary:
	var estimated := 0.0
	var most_expensive := 0.0
	for value: Variant in _cost.values():
		var usec := float(value)
		estimated += usec
		most_expensive = maxf(most_expensive, usec)
	return {
		"budget_usec": FRAME_USEC,
		"reported_fields": _reported.size(),
		"granted_fields": _granted.size(),
		"estimated_total_usec": estimated,
		"most_expensive_field_usec": most_expensive,
		"spent_usec": _spent_usec,
	}


## Forgets everything. For a harness measuring a field on its own.
static func reset() -> void:
	_frame = -1
	_granted = {}
	_reported = {}
	_cost = {}
	_rotation = 0
	_spent_usec = 0
	_nearest = 0
