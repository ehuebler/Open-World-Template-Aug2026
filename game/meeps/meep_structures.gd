class_name MeepStructures
extends Node3D

## Everything the Meeps have put up, and the ground they took to do it.
##
## Structures are the other half of a colony from its people, and they are a
## different problem. A town holds tens of them where it holds hundreds of Meeps, and
## none of them ever move — so where [MeepColony] keeps its population in packed
## arrays and redraws every frame, this keeps a small typed list and only touches the
## buffers when something is actually raised or worked on.
##
## What is shared with the Meeps is the shape of the answer: one [MultiMesh] per kind
## so a town is a draw call rather than a scene, and a pool of colliders lent to
## whichever buildings are near enough for anyone to walk into. A planet of towns
## cannot afford a node per shed.
##
## Placeholder geometry on purpose: a purple box for the cloner and an orange one for
## a hut, as asked for. Everything else here — footprints, levelling, spacing, the
## cost, the work, what it blocks — is the part that stays when the boxes are replaced
## by models.

## What can be built. Values are on the wire, so they are appended to rather than
## reordered.
enum Kind {
	## The Meep cloner. Five may be inside at once and each one that goes in comes
	## back out as two. The colony's only way to grow, so it is the first thing built.
	CLONER,
	## A dwelling. Nothing happens inside one yet; what it does is take up room, so a
	## town reads as a town and the roads pass has something to lay streets between.
	HUT,
}

## One kind's numbers, resolved once. A class rather than a dictionary of strings
## because placement asks four of these questions per candidate cell.
class Plan extends RefCounted:
	var kind := Kind.HUT
	var title := "Structure"
	## Footprint in grid cells. Cells are two metres, so a 2x2 is four metres square.
	var span := Vector2i(2, 2)
	## Metres. X and Z should stay inside the footprint or a building will overhang
	## ground the grid still thinks anyone may walk on.
	var size := Vector3(3.6, 3.0, 3.6)
	var colour := Color(0.86, 0.44, 0.12)
	## Biomass taken from the colony's bank when the site is pegged out.
	var cost := 30.0
	## Job seconds to finish. Two Meeps halve it, which is the whole reason a crew is
	## worth gathering.
	var work := 16.0
	## How many may work on it at once.
	var crew := 2
	## Metres this must keep from the colony centre, so nothing is built against the
	## lander's legs.
	var keep_centre := 11.0


## Filled once for the whole game. Indexed by [enum Kind].
static var _plans: Array[Plan] = []

## How level a footprint has to be, in metres between its highest and lowest cell. A
## box has no foundations, so anything looser than this is a building with daylight
## under one corner.
const LEVEL_TOLERANCE := 1.1
## Metres of clear ground between two structures. Generous, because the roads and
## parks that go between them are the next pass and a town packed shoulder to
## shoulder now would have to be knocked down to make room for them.
const SPACING := 6.0
## Colliders lent to the nearest structures. A town has tens; this is how many of
## them anyone can be standing next to.
const COLLIDER_POOL := 12
## Metres from the viewer inside which a structure is given one.
const COLLIDER_RANGE := 90.0
## How much of its full height a site shows before any work is done, so a pegged-out
## plot reads as something rather than as nothing.
const FOUNDATION_SHARE := 0.12
## Multiplied into a kind's colour while it is unfinished.
const UNFINISHED_TINT := 0.42


## One built or half-built thing.
class Site extends RefCounted:
	var kind := Kind.HUT
	## Lowest-numbered cell of the footprint. The whole thing is derived from this and
	## the kind's span, so this is all that has to travel to a client.
	var corner := Vector2i.ZERO
	## Centre of the footprint on the site map, in metres.
	var local := Vector2.ZERO
	## Ground height under the centre.
	var height := 0.0
	## Zero to one. Work is added by whoever is stood on it.
	var progress := 0.0
	## The job Meeps claim to work on this, while it is unfinished.
	var job := 0
	## Meeps inside. Only the cloner uses it.
	var inside := 0

	func built() -> bool:
		return progress >= 1.0


var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim

var _shape: PlanetShape
var _planet: Planet
var _sites: Array[Site] = []
var _stands: Array[MultiMeshInstance3D] = []
var _colliders: Array[StaticBody3D] = []
## Set when anything about the list changed, so the buffers are only rewritten on the
## frames that need it rather than every frame of a town standing still.
var _dirty := true


static func _static_init() -> void:
	_plans.resize(Kind.size())
	var cloner := Plan.new()
	cloner.kind = Kind.CLONER
	cloner.title = "Cloner"
	# Three cells across and taller than the flowers around it, because a building
	# that does not clear the undergrowth is a building nobody can see from the ship.
	cloner.span = Vector2i(3, 3)
	cloner.size = Vector3(4.4, 4.4, 4.4)
	cloner.colour = Color(0.55, 0.17, 0.86)
	cloner.cost = 60.0
	cloner.work = 26.0
	cloner.crew = 3
	cloner.keep_centre = 14.0
	_plans[Kind.CLONER] = cloner
	var hut := Plan.new()
	hut.kind = Kind.HUT
	hut.title = "Hut"
	hut.span = Vector2i(3, 3)
	hut.size = Vector3(4.6, 3.8, 4.6)
	# Deeper than it looks like it should be. The landing site's sun is bright enough
	# that a lighter orange reads as cardboard from the air.
	hut.colour = Color(0.97, 0.36, 0.05)
	hut.cost = 30.0
	hut.work = 16.0
	hut.crew = 2
	hut.keep_centre = 17.0
	_plans[Kind.HUT] = hut


static func plan_of(kind: int) -> Plan:
	return _plans[clampi(kind, 0, _plans.size() - 1)]


func _init() -> void:
	name = "Structures"


func configure(for_site: MeepSite, for_grid: MeepGrid, for_claim: MeepClaim,
		shape: PlanetShape, planet: Planet) -> void:
	site = for_site
	grid = for_grid
	claim = for_claim
	_shape = shape
	_planet = planet
	_raise_stands()
	_raise_colliders()


# --- The list ----------------------------------------------------------------

func count() -> int:
	return _sites.size()


func at(index: int) -> Site:
	return _sites[index] if index >= 0 and index < _sites.size() else null


func count_of(kind: int, only_built := false) -> int:
	var found := 0
	for entry in _sites:
		if entry.kind == kind and (entry.built() or not only_built):
			found += 1
	return found


func built_count() -> int:
	var found := 0
	for entry in _sites:
		if entry.built():
			found += 1
	return found


## The index of the nearest structure of a kind, or -1. Used to find the cloner
## without anything having to remember where it was put.
func nearest(kind: int, from: Vector2, only_built := true) -> int:
	var best := -1
	var best_away := INF
	for index in _sites.size():
		var entry := _sites[index]
		if entry.kind != kind or (only_built and not entry.built()):
			continue
		var away := entry.local.distance_squared_to(from)
		if away < best_away:
			best_away = away
			best = index
	return best


## The cell a Meep should stand in to work on a site: just outside the footprint, so
## the crew is around the building rather than inside the walls once it is up.
func work_cell(index: int) -> Vector2i:
	var entry := at(index)
	if entry == null:
		return Vector2i.ZERO
	var plan := plan_of(entry.kind)
	var middle := entry.corner + Vector2i(plan.span.x / 2, plan.span.y / 2)
	for offset: Vector2i in [Vector2i(-1, 0), Vector2i(plan.span.x, 0),
			Vector2i(0, -1), Vector2i(0, plan.span.y)]:
		var cell := entry.corner + offset
		if grid != null and grid.passable(cell):
			return cell
	return middle


# --- Placing -----------------------------------------------------------------

## Finds a spot for a new structure and pegs it out, returning its index or -1.
##
## The first valid cell going outward from the middle of town, which is what makes a
## colony grow from its ship rather than in a ring or a grid: every new building takes
## the closest room left, so the town fills like something poured rather than
## something planned. Nothing about the search knows what a street is; when the roads
## pass lands it becomes one more test in [method _suits] rather than a different
## algorithm.
func place(kind: int) -> int:
	if grid == null or claim == null:
		return -1
	var plan := plan_of(kind)
	var from := claim.origin
	var rings := int(ceil(claim.radius / grid.cell_size)) + 2
	for ring in rings:
		for cell in _ring_cells(from, ring):
			if _suits(plan, cell):
				return place_at(kind, cell)
	return -1


## Pegs out a structure at a known corner, whatever the ground thinks.
##
## Separate from [method place] because a client is told where the host put a building
## rather than working it out again: the search reads a claim, and a claim is filled
## from a grid a client may still be baking.
func place_at(kind: int, corner: Vector2i) -> int:
	var plan := plan_of(kind)
	var entry := Site.new()
	entry.kind = kind
	entry.corner = corner
	entry.local = _centre_of(plan, corner)
	entry.height = _ground(entry.local, plan, corner)
	_sites.push_back(entry)
	_dirty = true
	return _sites.size() - 1


## Whether a footprint can go here: inside the town, on ground everyone may walk on,
## level enough to stand a box on, clear of the lander and clear of everything already
## built.
func _suits(plan: Plan, corner: Vector2i) -> bool:
	var lowest := INF
	var highest := -INF
	for x in plan.span.x:
		for y in plan.span.y:
			var cell := corner + Vector2i(x, y)
			if not grid.passable(cell) or not claim.contains_cell(cell):
				return false
			if grid.has_flag(cell, MeepGrid.FLAG_BUILDING):
				return false
			var height := grid.height_at(cell)
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > LEVEL_TOLERANCE:
		return false
	var middle := _centre_of(plan, corner)
	if middle.length() < plan.keep_centre:
		return false
	for entry in _sites:
		var theirs := plan_of(entry.kind)
		var apart := (maxf(plan.size.x, plan.size.z)
			+ maxf(theirs.size.x, theirs.size.z)) * 0.5 + SPACING
		if middle.distance_to(entry.local) < apart:
			return false
	return true


func _centre_of(plan: Plan, corner: Vector2i) -> Vector2:
	return grid.centre_of(corner) \
		+ Vector2(plan.span - Vector2i.ONE) * grid.cell_size * 0.5


## Ground for a footprint, taken as the lowest cell under it rather than the middle.
## A box sunk to its lowest corner has no gap under it anywhere; one sat on the
## average has daylight under the low side of every slope in town.
func _ground(_middle: Vector2, plan: Plan, corner: Vector2i) -> float:
	var lowest := INF
	for x in plan.span.x:
		for y in plan.span.y:
			lowest = minf(lowest, grid.height_at(corner + Vector2i(x, y)))
	return lowest if lowest < INF else 0.0


## The cells exactly [param ring] steps out from a centre, as a square shell. Walked
## rather than sorted, because sorting a claim's worth of cells by distance to place
## one hut is thousands of comparisons for an answer a shell gives for free.
func _ring_cells(from: Vector2i, ring: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if ring == 0:
		cells.push_back(from)
		return cells
	for step in range(-ring, ring + 1):
		cells.push_back(from + Vector2i(step, -ring))
		cells.push_back(from + Vector2i(step, ring))
	for step in range(-ring + 1, ring):
		cells.push_back(from + Vector2i(-ring, step))
		cells.push_back(from + Vector2i(ring, step))
	return cells


# --- Building ----------------------------------------------------------------

## Adds work to a site and reports whether that finished it. The caller is one Meep's
## turn on the job, so a crew of three arrives here three times a tick.
func advance(index: int, seconds: float) -> bool:
	var entry := at(index)
	if entry == null or entry.built():
		return false
	var plan := plan_of(entry.kind)
	entry.progress = clampf(
		entry.progress + seconds / maxf(plan.work, 0.001), 0.0, 1.0)
	_dirty = true
	return entry.built()


## Sets a site's progress from the host's copy. Clients do no work of their own.
func set_progress(index: int, progress: float) -> void:
	var entry := at(index)
	if entry == null:
		return
	var was := entry.built()
	entry.progress = clampf(progress, 0.0, 1.0)
	_dirty = true
	if entry.built() and not was:
		block(index)


## Takes the ground a finished structure stands on out of circulation.
##
## Only once it is finished, so a crew can stand in the footprint while they raise it.
## Every flag written here bumps the grid's revision, which is what makes every cached
## route in town rebuild itself around the new building without anything telling it to.
func block(index: int) -> void:
	var entry := at(index)
	if entry == null or grid == null:
		return
	var plan := plan_of(entry.kind)
	for x in plan.span.x:
		for y in plan.span.y:
			grid.set_flag(entry.corner + Vector2i(x, y), MeepGrid.FLAG_BUILDING)


## The world point at the middle of a structure's floor, for clearing flora and for
## anything that wants to stand something there later.
func world_centre(index: int) -> Vector3:
	var entry := at(index)
	if entry == null or site == null or _planet == null:
		return Vector3.ZERO
	return _planet.to_global(site.point_at(entry.local, entry.height))


func footprint_radius(index: int) -> float:
	var entry := at(index)
	if entry == null:
		return 0.0
	var plan := plan_of(entry.kind)
	return maxf(plan.size.x, plan.size.z) * 0.5


# --- Presentation ------------------------------------------------------------

func _raise_stands() -> void:
	for kind in Kind.size():
		var plan := plan_of(kind)
		var stand := MultiMeshInstance3D.new()
		stand.name = plan.title
		var mesh := BoxMesh.new()
		mesh.size = plan.size
		var material := StandardMaterial3D.new()
		# White, with the kind's colour coming from the instance buffer instead. The
		# buffer has to speak so that an unfinished building can read as unfinished,
		# and an albedo tinted as well would multiply the colour into itself — which
		# is what turned a purple cloner navy and an orange hut brown.
		material.albedo_color = Color.WHITE
		material.roughness = 0.6
		material.vertex_color_use_as_albedo = true
		mesh.material = material
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = true
		batch.mesh = mesh
		stand.multimesh = batch
		add_child(stand)
		_stands.push_back(stand)


func _raise_colliders() -> void:
	for _slot in COLLIDER_POOL:
		var body := StaticBody3D.new()
		body.name = "Wall%d" % _colliders.size()
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		body.add_child(shape)
		# On the world layer, unlike the Meeps themselves: a building is exactly the
		# sort of thing a player, a mob and a thrown rock should all stop at.
		body.collision_layer = 1
		body.collision_mask = 0
		body.process_mode = Node.PROCESS_MODE_DISABLED
		add_child(body)
		_colliders.push_back(body)


## Writes the town into the buffers, and only when it has changed.
func draw() -> void:
	if not _dirty or site == null:
		return
	_dirty = false
	var counts := PackedInt32Array()
	counts.resize(Kind.size())
	for entry in _sites:
		counts[entry.kind] += 1
	for kind in _stands.size():
		var batch := _stands[kind].multimesh
		if batch.instance_count < counts[kind]:
			batch.instance_count = counts[kind]
	var shown := PackedInt32Array()
	shown.resize(Kind.size())
	for entry in _sites:
		var plan := plan_of(entry.kind)
		var batch := _stands[entry.kind].multimesh
		var slot := shown[entry.kind]
		shown[entry.kind] += 1
		var grow := maxf(entry.progress, FOUNDATION_SHARE)
		var up := site.direction_at(entry.local)
		var east := site.east - up * site.east.dot(up)
		if east.length_squared() < 0.000001:
			east = site.north - up * site.north.dot(up)
		east = east.normalized()
		batch.set_instance_transform(slot, Transform3D(
			Basis(east, up * grow, east.cross(up)),
			up * (site.planet_radius + entry.height
				+ plan.size.y * grow * 0.5)))
		batch.set_instance_color(slot, plan.colour if entry.built()
			else plan.colour * UNFINISHED_TINT)
	for kind in _stands.size():
		_stands[kind].multimesh.visible_instance_count = shown[kind]


## Hands the collider pool to the structures nearest the local camera. Same bargain
## as the Meeps' pick proxies and as flora collision: a fixed number of real shapes,
## given to whatever is close enough to be walked into this frame.
func lend_colliders(eye: Vector2) -> void:
	if _colliders.is_empty() or site == null:
		return
	var reach := COLLIDER_RANGE * COLLIDER_RANGE
	var nearby: Array[Vector2i] = []
	for index in _sites.size():
		var entry := _sites[index]
		if not entry.built():
			continue
		var away := entry.local.distance_squared_to(eye)
		if away <= reach:
			nearby.push_back(Vector2i(roundi(away * 100.0), index))
	nearby.sort()
	for slot in _colliders.size():
		var body := _colliders[slot]
		if slot >= nearby.size():
			if body.process_mode != Node.PROCESS_MODE_DISABLED:
				body.process_mode = Node.PROCESS_MODE_DISABLED
				body.collision_layer = 0
			continue
		var entry := _sites[nearby[slot].y]
		var plan := plan_of(entry.kind)
		var shape := body.get_child(0) as CollisionShape3D
		(shape.shape as BoxShape3D).size = plan.size
		var up := site.direction_at(entry.local)
		var east := site.east - up * site.east.dot(up)
		east = east.normalized()
		body.transform = Transform3D(
			Basis(east, up, east.cross(up)),
			site.point_at(entry.local, entry.height + plan.size.y * 0.5))
		body.collision_layer = 1
		body.process_mode = Node.PROCESS_MODE_INHERIT


# --- Replication -------------------------------------------------------------

## The founding facts of every structure: kind and corner, three numbers each. What
## they are made of, where the ground is and how they are drawn is worked out from the
## same grid on every peer.
func snapshot() -> PackedInt32Array:
	var out := PackedInt32Array()
	for entry in _sites:
		out.push_back(entry.kind)
		out.push_back(entry.corner.x)
		out.push_back(entry.corner.y)
	return out


func progress_snapshot() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for entry in _sites:
		out.push_back(entry.progress)
	return out


## Rebuilds the list from a host's snapshot, keeping any progress already known for
## the structures that were already there.
func apply_snapshot(state: PackedInt32Array) -> void:
	var wanted := state.size() / 3
	while _sites.size() > wanted:
		_sites.pop_back()
		_dirty = true
	for index in wanted:
		var kind := state[index * 3]
		var corner := Vector2i(state[index * 3 + 1], state[index * 3 + 2])
		if index < _sites.size():
			var entry := _sites[index]
			if entry.kind == kind and entry.corner == corner:
				continue
			entry.kind = kind
			entry.corner = corner
			var plan := plan_of(kind)
			entry.local = _centre_of(plan, corner)
			entry.height = _ground(entry.local, plan, corner)
			_dirty = true
			continue
		place_at(kind, corner)


func apply_progress(state: PackedFloat32Array) -> void:
	for index in mini(state.size(), _sites.size()):
		set_progress(index, state[index])


## Re-reads the ground under every structure and puts the finished ones' cells back
## out of circulation.
##
## Called when the grid underneath has been replaced — a client catching up with a town
## that was already standing, or a colony rebaking after the terrain was recut. A site
## pegged out before its peer had a grid has no real height yet, and the flags a
## finished building wrote went with the grid that held them.
func resettle() -> void:
	if grid == null:
		return
	for index in _sites.size():
		var entry := _sites[index]
		var plan := plan_of(entry.kind)
		entry.local = _centre_of(plan, entry.corner)
		entry.height = _ground(entry.local, plan, entry.corner)
		if entry.built():
			block(index)
	_dirty = true
