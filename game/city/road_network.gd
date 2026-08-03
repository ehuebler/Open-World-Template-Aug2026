@tool
class_name RoadNetwork
extends RefCounted

## The lines a city's streets run along, worked out in full before any of them is
## built.
##
## This is the whole reason the roads can be trusted. A junction graph is easy to
## write and easy to write wrong, and almost every way of writing it wrong is
## invisible in a picture of one street: two roads that cross with no junction
## between them, a block so short the street inside it disappears, a cul-de-sac
## that was meant to join something. Sweeping first and looking afterwards finds
## none of that, because a bad crossing still renders — it renders as two ribbons
## in the same place, which reads as a shadow.
##
## So the centreline comes first and stands on its own. [member traces] is every
## road as a polyline, [member runs] is those lines after each crossing has taken
## its bite out of them, and [method audit] answers whether the result is a street
## network or a pile of ribbons. [RoadMesh] then extrudes [member runs] and pays no
## attention to how they were arrived at, and `dev/_roads_test.gd` draws the lines
## on their own, which is what a fault here actually looks like.
##
## Reusable across cities: it is handed a graph and a table of road kinds and holds
## no opinion about either. Coordinates are metres in the city's own tangent frame,
## as [CityPlan] defines it, with the third component of a junction being metres
## above the graded ground — zero for everything in a city built on one level.

## Metres between samples along a road. The sphere's sag over one of these is under
## a tenth of a millimetre, so this is chosen for how tightly a curve is followed
## rather than for the curvature of the planet.
const STATION := 10.0

## How much of the shortest street at a junction that junction may eat, per end.
## Two ends at 0.35 leave 30% of the block as road, which is what stops a pair of
## crossings from swallowing the street between them and disconnecting by geometry
## a network that went to some trouble to be connected by construction.
const SETBACK_SHARE := 0.35

## Shortest ribbon worth sweeping, as a share of [constant STATION]. Two rings a
## centimetre apart have no usable tangent between them and their normals go to
## noise, so a run under this is dropped — and [method audit] says so, because a
## dropped run is a block with no street in it.
const RUNT := 0.4

## How close two roads' centrelines have to come, in metres, before they are
## treated as crossing. Wider than the roads themselves: two carriageways whose
## edges merely graze still need a junction between them, and the point of the
## audit is to be suspicious.
const TOUCH := 2.0

## Road kinds, as [RoadProfile] describes them, keyed by the name a road's
## [code]kind[/code] field uses.
var kinds: Dictionary
## Junction id to [code]Vector3(x, y, height above the ground)[/code].
var nodes: Dictionary
## The city's road table, untouched.
var roads: Array[Dictionary]

## Every road as one uncut polyline, in the order the table gave them:
## [code]{"road", "kind", "path", "marks"}[/code]. [code]marks[/code] indexes the
## station each junction of the chain landed on. This is the line, and it exists
## whether or not anything is ever swept along it.
var traces: Array[Dictionary] = []

## The pieces left after every junction has taken its setback out of the traces:
## [code]{"road", "kind", "path", "from", "to"}[/code], where [code]from[/code] and
## [code]to[/code] name the junctions the ends stopped at, or are empty at a free
## end. Decks are not cut and appear here whole, with both ends unnamed.
var runs: Array[Dictionary] = []

## Junctions that are really junctions, by id:
## [code]{"at", "setback", "arms", "roads"}[/code]. A node that one road passes
## straight through is a bend and is not here.
var junctions: Dictionary = {}

## Metres of centreline in the whole network, counted before any of it was cut.
var length := 0.0


func _init(graph: Dictionary, kind_table: Dictionary) -> void:
	nodes = graph["nodes"]
	roads = graph["roads"]
	kinds = kind_table
	_trace_all()
	_survey()
	_cut_all()


# --- The lines --------------------------------------------------------------

## Every road's centreline, sampled. Curves come from each segment's own
## [code]bend[/code], which pushes the midpoint of a quadratic sideways; height is
## carried along the chain from the junctions' heights, which is what makes a ramp
## a ramp.
func _trace_all() -> void:
	for road: Dictionary in roads:
		var trace := _trace(road)
		var path: PackedVector3Array = trace["path"]
		for index in range(1, path.size()):
			length += Vector2(path[index].x, path[index].y).distance_to(
				Vector2(path[index - 1].x, path[index - 1].y))
		traces.append(trace)


func _trace(road: Dictionary) -> Dictionary:
	var chain: Array = road["nodes"]
	var closed: bool = road.get("loop", false)
	var bends: Array = road.get("bend", [])
	var path := PackedVector3Array()
	var marks := PackedInt32Array()
	var segments := chain.size() - (0 if closed else 1)
	for step in segments:
		marks.append(path.size())
		var from: Vector3 = nodes[chain[step]]
		var to: Vector3 = nodes[chain[(step + 1) % chain.size()]]
		var a := Vector2(from.x, from.y)
		var b := Vector2(to.x, to.y)
		var bend: float = bends[step] if step < bends.size() else 0.0
		# A quadratic through a control point twice the bend out reaches exactly
		# the bend at its own midpoint, which is what makes the number readable as
		# "how far this road bows".
		var side := (b - a).orthogonal().normalized()
		var control := (a + b) * 0.5 + side * bend * 2.0
		var count := maxi(2, ceili(a.distance_to(b) / STATION))
		# The last station of a segment is the first of the next, so it is left to
		# the next one to emit — otherwise every junction is a doubled ring and the
		# normals crease there.
		var last := count if step == segments - 1 and not closed else count - 1
		for tick in last + 1:
			var t := float(tick) / float(count)
			var at := a.lerp(control, t).lerp(control.lerp(b, t), t)
			path.append(Vector3(at.x, at.y, lerpf(from.z, to.z, t)))
	if not closed:
		marks.append(path.size() - 1)
	return {"road": road, "kind": kinds[road["kind"]], "path": path, "marks": marks}


# --- Junctions --------------------------------------------------------------

## Every place a ground road meets another, and how far back each road has to stop
## so the meeting can be paved as one piece.
##
## A node the same road passes through twice and nobody else touches is a bend,
## not a junction: cutting the ribbon there would put a seam where the sweep
## already turns smoothly through it. A node touched once is the head of a
## cul-de-sac, and it is worth cutting for the rounded end that buys.
##
## Decks are left out. A viaduct crosses the city overhead and meets nothing at
## grade except at its ramps' feet, where a portal running into the road is closer
## to right than a junction built around a box girder would be.
func _survey() -> void:
	var seen := {}
	for trace: Dictionary in traces:
		var kind: Dictionary = trace["kind"]
		if bool(kind["deck"]):
			continue
		var road: Dictionary = trace["road"]
		var chain: Array = road["nodes"]
		var closed: bool = road.get("loop", false)
		var reach := RoadProfile.reach(kind)
		for step in chain.size() - (0 if closed else 1):
			var from: String = chain[step]
			var to: String = chain[(step + 1) % chain.size()]
			var a: Vector3 = nodes[from]
			var b: Vector3 = nodes[to]
			var span := Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
			for id: String in [from, to]:
				if not seen.has(id):
					seen[id] = {"arms": 0, "roads": {}, "reach": 0.0, "span": 1e9}
				var note: Dictionary = seen[id]
				note["arms"] = int(note["arms"]) + 1
				(note["roads"] as Dictionary)[road["name"]] = true
				note["reach"] = maxf(float(note["reach"]), reach)
				note["span"] = minf(float(note["span"]), span)

	for id: String in seen:
		var note: Dictionary = seen[id]
		if int(note["arms"]) == 2 and (note["roads"] as Dictionary).size() < 2:
			continue
		var at: Vector3 = nodes[id]
		junctions[id] = {
			"at": Vector2(at.x, at.y),
			"setback": minf(float(note["reach"]),
				float(note["span"]) * SETBACK_SHARE),
			"arms": int(note["arms"]),
			"roads": (note["roads"] as Dictionary).keys()}


# --- Cutting ----------------------------------------------------------------

func _cut_all() -> void:
	for trace: Dictionary in traces:
		var kind: Dictionary = trace["kind"]
		var path: PackedVector3Array = trace["path"]
		if path.size() < 2:
			continue
		if bool(kind["deck"]):
			runs.append({"road": trace["road"], "kind": kind, "path": path,
				"from": "", "to": ""})
			continue
		for piece: Dictionary in _cut(trace):
			runs.append(piece)


## Splits a centreline at every junction it runs through, leaving that junction's
## setback clear on each side. Returns the surviving pieces, each naming the
## junction its ends stopped at, or one whole piece if it meets none.
func _cut(trace: Dictionary) -> Array[Dictionary]:
	var road: Dictionary = trace["road"]
	var path: PackedVector3Array = trace["path"]
	var marks: PackedInt32Array = trace["marks"]
	var chain: Array = road["nodes"]
	var closed: bool = road.get("loop", false)
	var line := path
	if closed:
		# A ring's last station joins back to its first, and the sweep only ever
		# walks forwards. Repeating the first station closes it.
		line = path.duplicate()
		line.append(path[0])

	var arc := PackedFloat32Array()
	arc.resize(line.size())
	for index in range(1, line.size()):
		arc[index] = arc[index - 1] + Vector2(line[index].x, line[index].y) \
			.distance_to(Vector2(line[index - 1].x, line[index - 1].y))
	var total := arc[arc.size() - 1]

	var stops: Array[Dictionary] = []
	for step in marks.size():
		var id: String = chain[step % chain.size()]
		if junctions.has(id):
			stops.append({"id": id, "at": arc[marks[step]],
				"reach": float((junctions[id] as Dictionary)["setback"])})
	if closed and junctions.has(chain[0] as String):
		stops.append({"id": chain[0], "at": total,
			"reach": float((junctions[chain[0]] as Dictionary)["setback"])})

	var stretches: Array[Dictionary] = []
	var began := 0.0
	var came_from := ""
	for stop: Dictionary in stops:
		stretches.append({"from": came_from, "to": String(stop["id"]),
			"start": began, "stop": float(stop["at"]) - float(stop["reach"])})
		began = float(stop["at"]) + float(stop["reach"])
		came_from = String(stop["id"])
	stretches.append({"from": came_from, "to": "", "start": began, "stop": total})

	var cut: Array[Dictionary] = []
	for stretch: Dictionary in stretches:
		var piece := _slice(line, arc, float(stretch["start"]),
			float(stretch["stop"]))
		if piece.size() < 2:
			continue
		cut.append({"road": road, "kind": trace["kind"], "path": piece,
			"from": stretch["from"], "to": stretch["to"]})
	return cut


## The part of a centreline between two arc lengths, with exact ends. Stations
## landing almost on an end are dropped: two rings a centimetre apart have no
## usable tangent between them and the normals go to noise.
func _slice(line: PackedVector3Array, arc: PackedFloat32Array,
		from: float, to: float) -> PackedVector3Array:
	var piece := PackedVector3Array()
	if to - from < STATION * RUNT:
		return piece
	piece.append(_at_arc(line, arc, from))
	for index in line.size():
		if arc[index] <= from + 0.5:
			continue
		if arc[index] >= to - 0.5:
			break
		piece.append(line[index])
	piece.append(_at_arc(line, arc, to))
	return piece


func _at_arc(line: PackedVector3Array, arc: PackedFloat32Array,
		at: float) -> Vector3:
	var last := arc.size() - 1
	if at <= 0.0:
		return line[0]
	if at >= arc[last]:
		return line[last]
	for index in range(1, arc.size()):
		if arc[index] < at:
			continue
		var span := arc[index] - arc[index - 1]
		var t := 0.0 if span < 1e-6 else (at - arc[index - 1]) / span
		return line[index - 1].lerp(line[index], t)
	return line[last]


# --- Audit ------------------------------------------------------------------

## Everything that can be known about the network without building it.
##
## Returns counts for a report plus [code]problems[/code], which is the part that
## matters: anything in there is a fault in the layout table and not in the mesh,
## and will still be a fault after the mesh is rebuilt.
func audit() -> Dictionary:
	var problems := PackedStringArray()
	for id: String in _named():
		if not nodes.has(id):
			problems.append("road uses junction '%s', which is not in the table" % id)
	var reached := _reachable()
	var stubs := _dead_ends()
	if reached.size() < _named().size():
		for id: String in _named():
			if not reached.has(id) and nodes.has(id):
				problems.append("junction '%s' is cut off from the rest of the city" % id)
	for gap: Dictionary in _starved():
		problems.append(("%s has no street between '%s' and '%s': %.1f m apart, "
			+ "and the two crossings eat %.1f m of it") % [gap["road"], gap["from"],
			gap["to"], gap["span"], gap["eaten"]])
	var grazes := PackedStringArray()
	for crossing: Dictionary in crossings():
		var at: Vector2 = crossing["at"]
		if bool(crossing["met"]):
			problems.append(("%s crosses %s at about (%.0f, %.0f) with no junction "
				+ "between them") % [crossing["one"], crossing["two"], at.x, at.y])
		else:
			grazes.append(("%s runs within a ribbon's width of %s at about "
				+ "(%.0f, %.0f), and neither knows about the other")
				% [crossing["one"], crossing["two"], at.x, at.y])
	return {
		"junctions": junctions.size(), "nodes": _named().size(),
		"roads": roads.size(), "runs": runs.size(), "length": length,
		"reached": reached.size(), "dead_ends": stubs, "problems": problems,
		"grazes": grazes}


## Roads that overlap on the ground where the layout never said they meet.
##
## The one fault that a picture cannot show you and a build cannot refuse: two
## ribbons laid through the same ground are two surfaces at the same height for the
## depth buffer to argue over, and a kerb running out across the mouth of whatever
## it crossed. It happens whenever a road is extended past where its author was
## looking.
##
## Each entry says whether the two [code]met[/code]: centrelines that actually
## cross are a fault in the table, while ribbons that only graze are a road built
## too close to another and are reported apart from them.
##
## Decks are exempt. Flying over the city without meeting it is what they are for.
func crossings() -> Array[Dictionary]:
	var ribbons: Array[Dictionary] = []
	for trace: Dictionary in traces:
		var kind: Dictionary = trace["kind"]
		if bool(kind["deck"]):
			continue
		ribbons.append({
			"name": String((trace["road"] as Dictionary)["name"]),
			"path": trace["path"],
			"clear": RoadProfile.clearance(kind)})

	var found: Array[Dictionary] = []
	for first in ribbons.size():
		for second in range(first + 1, ribbons.size()):
			var one: Dictionary = ribbons[first]
			var two: Dictionary = ribbons[second]
			var reach := float(one["clear"]) + float(two["clear"])
			var foul := _foul(one["path"], two["path"], reach - TOUCH)
			if foul.is_empty():
				continue
			var where: Vector2 = foul["at"]
			if _marked(String(one["name"]), String(two["name"]), where, reach):
				continue
			found.append({"one": one["name"], "two": two["name"], "at": where,
				"met": foul["met"]})
	return found


## Where two centrelines first meet, or first come within [param gap] of each
## other: [code]{"at", "met"}[/code], where [code]met[/code] separates lines that
## actually cross from ribbons that only graze. Empty if they stay apart.
##
## The [b]tessellated[/b] lines, not the chords between the junctions. A segment
## with a [code]bend[/code] bows away from its chord by the bend itself, so a
## curve that clears another road by fifty metres reads as a crossing when the
## chords are tested — which is exactly what happened, and it reported nineteen
## crossings in a town whose roads all miss each other.
func _foul(one: PackedVector3Array, two: PackedVector3Array, gap: float) -> Dictionary:
	if one.size() < 2 or two.size() < 2:
		return {}
	var far := _rect(two).grow(maxf(gap, 0.0))
	var grazed := {}
	for step in range(1, one.size()):
		var a := Vector2(one[step - 1].x, one[step - 1].y)
		var b := Vector2(one[step].x, one[step].y)
		var span := Rect2(a, Vector2.ZERO).expand(b).grow(maxf(gap, 0.0))
		if not far.intersects(span):
			continue
		for tick in range(1, two.size()):
			var c := Vector2(two[tick - 1].x, two[tick - 1].y)
			var d := Vector2(two[tick].x, two[tick].y)
			if not span.intersects(Rect2(c, Vector2.ZERO).expand(d)):
				continue
			# Returns null when the two do not meet, so it cannot be typed
			# tighter than Variant here.
			var hit: Variant = Geometry2D.segment_intersects_segment(a, b, c, d)
			if hit != null:
				return {"at": hit as Vector2, "met": true}
			# Two roads can foul each other without their centrelines actually
			# meeting: a street ending a metre shy of a boulevard still lays its
			# ribbon across it. Worth reporting, but not the same fault, so the
			# search carries on in case they cross outright further along.
			if gap <= 0.0 or not grazed.is_empty():
				continue
			var near := _closest(a, b, c, d)
			if float(near["gap"]) <= gap:
				grazed = {"at": near["at"], "met": false}
	return grazed


## Whether a meeting is one the network already knows about: a junction both roads
## are named on, near enough to the point found.
##
## The radius is the junction's setback plus the two ribbons' reach twice over,
## because two arms leaving one junction at an acute angle keep overlapping well
## past the paving — that overlap is the junction, seen from further along.
func _marked(one: String, two: String, at: Vector2, reach: float) -> bool:
	for id: String in junctions:
		var note: Dictionary = junctions[id]
		var named: Array = note["roads"]
		if not (one in named and two in named):
			continue
		if (note["at"] as Vector2).distance_to(at) \
				<= float(note["setback"]) + reach * 2.0:
			return true
	return false


func _rect(path: PackedVector3Array) -> Rect2:
	var box := Rect2(Vector2(path[0].x, path[0].y), Vector2.ZERO)
	for step in range(1, path.size()):
		box = box.expand(Vector2(path[step].x, path[step].y))
	return box


## The closest approach of two segments, and the point midway between them there.
func _closest(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Dictionary:
	var best := 1e9
	var at := Vector2.ZERO
	for probe: Array in [[a, c, d], [b, c, d], [c, a, b], [d, a, b]]:
		var point: Vector2 = probe[0]
		var on := Geometry2D.get_closest_point_to_segment(
			point, probe[1], probe[2])
		var gap := point.distance_to(on)
		if gap < best:
			best = gap
			at = (point + on) * 0.5
	return {"gap": best, "at": at}


## Blocks whose street vanished: two junctions close enough that their setbacks
## leave less than a ribbon between them.
##
## Not the same fault as a disconnected graph, and worse to find later. The
## junctions still pave, so the city looks joined from above while the ground
## between them is bare — and the connectivity check passes, because by the table
## they are neighbours.
func _starved() -> Array[Dictionary]:
	var starved: Array[Dictionary] = []
	for trace: Dictionary in traces:
		if bool((trace["kind"] as Dictionary)["deck"]):
			continue
		var road: Dictionary = trace["road"]
		var chain: Array = road["nodes"]
		var closed: bool = road.get("loop", false)
		for step in chain.size() - (0 if closed else 1):
			var from: String = chain[step]
			var to: String = chain[(step + 1) % chain.size()]
			if not junctions.has(from) or not junctions.has(to):
				continue
			var a: Vector3 = nodes[from]
			var b: Vector3 = nodes[to]
			var span := Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
			var eaten := float((junctions[from] as Dictionary)["setback"]) \
				+ float((junctions[to] as Dictionary)["setback"])
			if span - eaten >= STATION * RUNT:
				continue
			starved.append({"road": road["name"], "from": from, "to": to,
				"span": span, "eaten": eaten})
	return starved


## Every junction id any road names, whether or not it turned out to be a real
## junction. A bend is still a point the network is holding.
func _named() -> Dictionary:
	var used := {}
	for road: Dictionary in roads:
		for id: String in road["nodes"] as Array:
			used[id] = true
	return used


## Junctions with exactly one road at them. Some are meant to be — a cul-de-sac
## head, a ramp's foot — so this is reported and not complained about.
func _dead_ends() -> Array[String]:
	var stubs: Array[String] = []
	for id: String in junctions:
		if int((junctions[id] as Dictionary)["arms"]) == 1:
			stubs.append(id)
	stubs.sort()
	return stubs


## Which junctions can be walked to from the first one any road names.
func _reachable() -> Dictionary:
	var neighbours := {}
	for road: Dictionary in roads:
		var chain: Array = road["nodes"]
		var closed: bool = road.get("loop", false)
		for step in chain.size() - (0 if closed else 1):
			var from: String = chain[step]
			var to: String = chain[(step + 1) % chain.size()]
			if not neighbours.has(from):
				neighbours[from] = [] as Array[String]
			if not neighbours.has(to):
				neighbours[to] = [] as Array[String]
			(neighbours[from] as Array[String]).append(to)
			(neighbours[to] as Array[String]).append(from)
	var seen := {}
	if neighbours.is_empty():
		return seen
	var queue: Array[String] = [neighbours.keys()[0] as String]
	seen[queue[0]] = true
	while not queue.is_empty():
		var id: String = queue.pop_back()
		for next: String in neighbours.get(id, [] as Array[String]) as Array[String]:
			if seen.has(next):
				continue
			seen[next] = true
			queue.append(next)
	return seen
