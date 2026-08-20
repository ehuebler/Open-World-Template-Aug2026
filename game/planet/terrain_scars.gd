class_name TerrainScars
extends RefCounted

## Every mark abilities have left on the ground, as part of the height field.
##
## A scar is not a decal and not a mesh. It is a term in [method
## PlanetShape.elevation] and in [method PlanetShape.color_at], which means the
## crater a meteor punch leaves is the same crater the chunk mesh is built from,
## the same one the collision shape is generated from, and the same one the
## player's ground guard reads when it decides where their feet are. There is no
## second representation to keep in step, and nothing has to know that terrain
## can now be dented.
##
## The cost of that is that this sits on the hottest path in the game. Elevation
## is called a few hundred thousand times per chunk, on four worker threads, and
## a linear walk of five hundred scars there would be the whole terrain pipeline.
## So scars are bucketed into a coarse cube-face grid and a query touches only
## the handful registered in its own cell — and when there are no scars at all,
## which is most of a session, the whole system is one integer comparison.
##
## Writes are rare (a few a second at worst) and reads are constant and
## threaded, so the bucket table is treated as immutable: adding a scar builds a
## new table and swaps the reference, rather than mutating one a build thread is
## halfway through reading.

## Cells per cube-face axis. At the shipped radius one cell spans about sixty
## metres, so most marks land in one bucket and a query walks one or two records.
## A nuke crater is wider than that and is filed across the handful of cells its
## footprint covers, which [method _cells_for] finds by walking the disc.
##
## Coarser than this and a player who stands and sweeps a beam over the same
## hillside for a while ends up with every mark they have made in one bucket,
## which is a linear walk on the per-vertex path: at five hundred marks in one
## cell a height sample went from under a microsecond to nineteen.
const RESOLUTION := 256

## How many scars the planet remembers. Oldest go first, which is the right
## order: the mark you just made is the one you are looking at.
const LIMIT := 512

enum Profile {
	## A round crater with a rounded floor. What an impact leaves.
	BOWL,
	## A pit that narrows to a point, offset ahead of a landing.
	CONE,
	## A broad, shallow, flat-floored dish. What a beam burns.
	GROOVE,
}


## How far off a circle a rim may wander, as a share of the radius. Bounded
## because everything that files and invalidates a scar works from its widest
## reach, and a mark allowed to bulge to several times its stated size would be
## queried in cells it was never filed under.
const MAX_WARP := 0.45


## One mark on the ground.
class Scar extends RefCounted:
	## Unit direction from the planet centre to the middle of the mark.
	var direction := Vector3.UP
	## Metres across the surface from that middle to the edge, on the bearings
	## where the rim sits exactly on its circle. See [member warp].
	var radius := 1.0
	## Metres the ground is taken down at the deepest point. May be zero for a
	## purely visual burn.
	var depth := 0.0
	var profile: Profile = Profile.BOWL
	## How blackened the ground is inside it, 0 to 1.
	var char := 0.0
	## What it is blackened toward.
	var tint := Color(0.05, 0.04, 0.035)
	## How far the rim wanders off its circle, as a share of [member radius].
	## Zero is the round mark a fist or a beam leaves. A blast big enough to throw
	## the ground about does not leave a round hole, and a perfect circle at
	## seventy metres across reads as a stamp rather than as damage.
	var warp := 0.0
	## Which set of lobes this rim wanders on. Two craters with the same warp and
	## different seeds are different holes; it is carried on the wire so every
	## peer digs the same one.
	var seed := 0.0
	## Buckets this scar was filed under, so eviction can find it again.
	var cells: Array[Vector3i] = []

	## Derived once when the scar is filed, because all three are wanted per
	## vertex on the terrain build threads and none of them changes afterwards.
	## The widest the rim reaches, and the tangent frame bearings are measured in.
	var outer := 1.0
	var east := Vector3.RIGHT
	var north := Vector3.FORWARD

	## Works out everything derived from [member direction], [member radius] and
	## [member warp]. Called by [method TerrainScars.add]; the frame has to match
	## the one bearings were authored against, so there is exactly one of it.
	func settle() -> void:
		direction = direction.normalized()
		warp = clampf(warp, 0.0, MAX_WARP)
		outer = radius * (1.0 + warp)
		east = direction.cross(Vector3.UP if absf(direction.y) < 0.9
			else Vector3.RIGHT).normalized()
		north = direction.cross(east)

	func to_wire() -> Dictionary:
		return {
			"direction": direction,
			"radius": radius,
			"depth": depth,
			"profile": int(profile),
			"char": char,
			"tint": tint,
			"warp": warp,
			"seed": seed,
		}

	static func from_wire(wire: Dictionary) -> Scar:
		var scar := Scar.new()
		scar.direction = (wire.get("direction", Vector3.UP) as Vector3).normalized()
		scar.radius = maxf(float(wire.get("radius", 1.0)), 0.05)
		scar.depth = float(wire.get("depth", 0.0))
		scar.profile = int(wire.get("profile", Profile.BOWL)) as Profile
		scar.char = clampf(float(wire.get("char", 0.0)), 0.0, 1.0)
		scar.tint = wire.get("tint", Color(0.05, 0.04, 0.035))
		scar.warp = clampf(float(wire.get("warp", 0.0)), 0.0, MAX_WARP)
		scar.seed = float(wire.get("seed", 0.0))
		# Settled here as well as when it is filed, so a caller that only wants
		# to know how far a received scar reaches can read it straight off.
		scar.settle()
		return scar


## One immutable registry generation.
##
## Terrain and ground-cover workers pin this RefCounted owner before touching a
## Dictionary or Array inside it. Publishing the next generation can therefore
## never release a container while an older generation is still being read.
## Keeping the containers themselves directly on TerrainScars was not enough:
## assigning a replacement Dictionary could race Array::_ref() in a worker that
## had just fetched one of its buckets.
class RegistryState extends RefCounted:
	var scars: Array[Scar] = []
	var buckets: Dictionary = {}
	var count := 0


## Planet radius in metres, needed to turn an angle into a distance across the
## ground. Set by [method PlanetShape.prepare] before anything reads a height.
var planet_radius := 8000.0

## Oldest-first records and cube-cell buckets published as one generation. A
## writer never mutates a published state; readers retain their local state
## reference until the query is complete.
var _state := RegistryState.new()
## Bumped on every change. Anything caching a view of the ground — a built
## chunk, a collision body — can compare this to know it is out of date.
var revision := 0


## Metres to take off the ground at a direction, after fading out at spacings
## too coarse to resolve the mark.
##
## Overlapping scars take the deepest rather than the sum: a laser held on one
## spot for five seconds commits several marks over the same ground, and adding
## them would bore a shaft through the crust.
func depth_at(direction: Vector3, spacing := 0.0) -> float:
	var state := _state
	if state.count == 0:
		return 0.0
	var found: Variant = state.buckets.get(_cell_of(direction))
	if found == null:
		return 0.0
	var deepest := 0.0
	for scar: Scar in found:
		if scar.depth <= 0.0:
			continue
		var away := direction.distance_to(scar.direction) * planet_radius
		# Rejected on the widest reach first. Working out a bearing is worth it
		# only for a sample that could be inside the rim somewhere.
		if away >= scar.outer:
			continue
		var reach := _reach_of(scar, direction)
		if away >= reach:
			continue
		# The fade is judged on the nominal radius rather than the reach at this
		# bearing, or a mark near the limit of what a mesh can show would fade in
		# and out around its own rim.
		var cut := scar.depth * _profile_at(scar.profile, away / reach) \
			* _resolves(scar.radius, spacing)
		deepest = maxf(deepest, cut)
	return deepest


## The ground colour with any burning over it laid on top.
func tint(direction: Vector3, ground: Color) -> Color:
	var state := _state
	if state.count == 0:
		return ground
	var found: Variant = state.buckets.get(_cell_of(direction))
	if found == null:
		return ground
	for scar: Scar in found:
		if scar.char <= 0.0:
			continue
		var away := direction.distance_to(scar.direction) * planet_radius
		if away >= scar.outer:
			continue
		var reach := _reach_of(scar, direction)
		if away >= reach:
			continue
		# Squared falloff rather than linear. A burn is dark in the middle and
		# frays at its edge; a linear ramp reads as a painted disc.
		var edge := 1.0 - away / reach
		var burn := clampf(scar.char * edge * edge, 0.0, 1.0)
		# Wetness is preserved. Scorching ground does not make it dry, and
		# writing alpha here would have the terrain shader treat a burned
		# shoreline as land.
		var alpha := ground.a
		ground = ground.lerp(scar.tint, burn)
		ground.a = alpha
	return ground


## Whether a patch of ground this wide, centred here, could touch a scar that a
## mesh of this vertex spacing would show any of.
##
## Conservative about position, and for the same reason [method
## PlanetShape.overlaps_town] is: a false negative there builds a chunk through
## the native field, which knows nothing about scars, and the crater would
## silently be filled back in.
##
## Not conservative about spacing, deliberately. A scar already fades to nothing
## at spacings too coarse to resolve it — see [method _resolves] — so a chunk
## whose vertices are further apart than the mark is wide would come back from
## the slow path with exactly the terrain the fast path produces. Passing zero
## asks the unqualified question, for callers that have no mesh in mind.
func overlaps(centre: Vector3, arc: float, spacing := 0.0) -> bool:
	var state := _state
	if state.count == 0:
		return false
	var direction := centre.normalized()
	for scar: Scar in state.scars:
		if not resolves(scar.radius, spacing):
			continue
		if direction.distance_to(scar.direction) * planet_radius \
				<= arc + scar.outer:
			return true
	return false


## Whether a mark this wide leaves anything at all in a mesh sampled this
## coarsely. The threshold [method _resolves] fades out at, as a yes or no, for
## the callers that only want to know whether there is any point looking.
func resolves(radius: float, spacing: float) -> bool:
	return spacing <= 0.0 or spacing < radius * 1.5


## Adds one mark and returns it. The caller owns invalidating whatever chunks it
## touched; this deliberately knows nothing about the scene.
func add(scar: Scar) -> Scar:
	scar.settle()
	var previous := _state
	var scars: Array[Scar] = previous.scars.duplicate()
	var buckets := previous.buckets.duplicate()
	if scars.size() >= LIMIT:
		_unfile(buckets, scars.pop_front())
	scar.cells = _cells_for(scar)
	for cell in scar.cells:
		var filed: Array = (buckets.get(cell, []) as Array).duplicate()
		filed.append(scar)
		buckets[cell] = filed
	scars.append(scar)
	var next := RegistryState.new()
	next.scars = scars
	next.buckets = buckets
	next.count = scars.size()
	_state = next
	revision += 1
	return scar


## Forgets everything. For harnesses and for leaving a session.
func clear() -> void:
	_state = RegistryState.new()
	revision += 1


func count() -> int:
	var state := _state
	return state.count


## Every scar, oldest first, for the join snapshot a late peer receives.
func to_wire() -> Array:
	var state := _state
	var wire := []
	for scar: Scar in state.scars:
		wire.append(scar.to_wire())
	return wire


func from_wire(wire: Array) -> void:
	clear()
	for entry in wire:
		if entry is Dictionary:
			add(Scar.from_wire(entry))


## How much of a mark this wide survives being sampled this coarsely.
##
## The same rule every other fine feature on the planet follows: a chunk whose
## vertices are further apart than the thing it is describing cannot describe
## it, and fading it out is what stops it aliasing into a spike at the one
## vertex that happened to land inside.
func _resolves(radius: float, spacing: float) -> float:
	if spacing <= 0.0:
		return 1.0
	return 1.0 - smoothstep(radius * 0.5, radius * 1.5, spacing)


## How far this scar's rim reaches on the bearing of a sample.
##
## Lobes rather than noise. Three overlapping harmonics are enough that no two
## bearings agree, they stay smooth — so the rim still meets the surrounding
## ground at a tangent instead of in a step — and they cost three sines on a path
## that runs a few hundred thousand times per chunk, which a noise lookup does
## not. The frame the bearing is measured in is cached on the scar; see [method
## Scar.settle].
func _reach_of(scar: Scar, direction: Vector3) -> float:
	if scar.warp <= 0.0:
		return scar.radius
	var offset := direction - scar.direction * direction.dot(scar.direction)
	var bearing := atan2(offset.dot(scar.north), offset.dot(scar.east))
	# Amplitudes sum to one, so the rim stays inside the outer bound everything
	# else is filed and invalidated against.
	var lobes := sin(bearing * 3.0 + scar.seed) * 0.60 \
		+ sin(bearing * 5.0 - scar.seed * 1.7) * 0.28 \
		+ sin(bearing * 8.0 + scar.seed * 2.9) * 0.12
	return scar.radius * (1.0 + scar.warp * lobes)


## Shape of the floor, as a share of full depth at a distance from the middle
## expressed as a share of the radius.
func _profile_at(profile: Profile, share: float) -> float:
	match profile:
		Profile.CONE:
			return 1.0 - share
		Profile.GROOVE:
			# Flat across most of its width, then a shoulder. A beam does not
			# dig a pit; it planes a strip off the top.
			return 1.0 - smoothstep(0.4, 1.0, share)
		_:
			# Paraboloid. Steep sides, rounded floor, and — importantly for
			# something a player lands in — a rim that meets the surrounding
			# ground at a tangent rather than in a lip.
			return 1.0 - share * share


## Which cube cell a direction falls in.
func _cell_of(direction: Vector3) -> Vector3i:
	var ax := absf(direction.x)
	var ay := absf(direction.y)
	var az := absf(direction.z)
	var face := 0
	var u := 0.0
	var v := 0.0
	if ax >= ay and ax >= az:
		face = 0 if direction.x > 0.0 else 1
		u = direction.y / ax
		v = direction.z / ax
	elif ay >= az:
		face = 2 if direction.y > 0.0 else 3
		u = direction.x / ay
		v = direction.z / ay
	else:
		face = 4 if direction.z > 0.0 else 5
		u = direction.x / az
		v = direction.y / az
	return Vector3i(face,
		clampi(int((u * 0.5 + 0.5) * RESOLUTION), 0, RESOLUTION - 1),
		clampi(int((v * 0.5 + 0.5) * RESOLUTION), 0, RESOLUTION - 1))


## Every cell a scar's footprint reaches.
##
## The whole disc is walked, not just its rim: a nuke crater is wider than a cell
## and a ring of samples around its edge can straddle a cell that lies entirely
## between the middle and the rim, which would leave a square of untouched ground
## inside the hole. Rings at a third, two thirds and the full outer reach, each of
## sixteen bearings, cover a footprint several cells across without assuming a
## size. This runs a few times a second at worst against a per-vertex read, so it
## is worth being thorough here rather than clever.
func _cells_for(scar: Scar) -> Array[Vector3i]:
	var cells: Array[Vector3i] = [_cell_of(scar.direction)]
	var step := scar.outer / maxf(planet_radius, 1.0)
	for ring in 3:
		var out := step * float(ring + 1) / 3.0
		for angle in 16:
			var turn := TAU * float(angle) / 16.0
			var rim := (scar.direction
				+ (scar.east * cos(turn) + scar.north * sin(turn)) * out) \
				.normalized()
			var cell := _cell_of(rim)
			if not cells.has(cell):
				cells.append(cell)
	return cells


func _unfile(buckets: Dictionary, scar: Scar) -> void:
	for cell in scar.cells:
		var filed: Array = (buckets.get(cell, []) as Array).duplicate()
		filed.erase(scar)
		if filed.is_empty():
			buckets.erase(cell)
		else:
			buckets[cell] = filed
