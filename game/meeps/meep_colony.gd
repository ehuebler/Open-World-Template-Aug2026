class_name MeepColony
extends Node3D

## One settlement and everyone in it.
##
## The Meeps have no nodes. A settler is a row across a dozen packed arrays, and
## every one of them is drawn by a single [MultiMesh] — which is the same bargain
## [GroundCover] makes to put three hundred thousand plants on a planet, rather
## than the one [FaunaMob] makes to put fourteen creatures in a herd. The point is
## the end state: a world of towns growing at once, most of them with nobody
## watching, none of them costing a node each.
##
## What that costs is physics. A row in an array cannot be a [CharacterBody3D], so
## nothing here is swept against the world: Meeps walk on the analytical height
## field and keep out of holes by consulting a [MeepGrid] that was baked from it.
## That is not a compromise on this planet — the terrain only has colliders within
## a couple of hundred metres of a viewer, so a body would be walking on nothing
## most of the time anyway.
##
## What it does not cost is being able to point at one. See [MeepPickProxy].
##
## Everything below the tick is host-authoritative and every client is a viewer:
## clients rebuild the ground, the boundary and the wall for themselves, because
## the height field is the same on every peer, and are then told only where the
## Meeps are.

## How often a Meep thinks and moves, in ticks per second. Ten is well under a
## physics frame's rate and far above what the eye reads as choppy at walking pace,
## and it is the rate the state packets go out at.
const SIM_HZ := 10.0
const SIM_STEP := 1.0 / SIM_HZ
## Meeps stepped per tick. The ceiling on what a colony can cost in one frame; past
## it, a crowd degrades by thinking less often rather than by dropping the frame.
const STEPS_PER_TICK := 256

## Simulation detail, by distance to the nearest player.
enum Detail {
	## Close enough to be watched: every tick, drawn, and its ground read from the
	## field at the spacing the terrain is actually drawn at.
	HOT,
	## In sight but not underfoot. Quarter rate, drawn, ground read from the grid.
	WARM,
	## Nobody near. A tenth of the rate, never drawn — but still walking, still
	## working, still finishing jobs, which is the whole reason the simulation is
	## not tied to the renderer.
	COLD,
}

## Metres from a player inside which Meeps are HOT.
const HOT_RANGE := 120.0
## And WARM. Past this they are COLD.
const WARM_RANGE := 400.0
## Metres past which a Meep is not drawn even if it is being simulated.
const DRAW_RANGE := 260.0
## Seconds between steps for each detail level.
const HOT_INTERVAL := SIM_STEP
const WARM_INTERVAL := SIM_STEP * 4.0
const COLD_INTERVAL := SIM_STEP * 10.0

## What a Meep is doing. Sent to clients a byte at a time, so values are appended to
## rather than reordered.
enum State {
	IDLE,
	WALK,
	WORK,
	FLEE,
	DEAD,
	## Inside the cloner. Not drawn, not hit, not moved — the one state where a Meep
	## is somewhere the world cannot see it.
	INSIDE,
}

## Settlers in the first wave.
const FIRST_WAVE := 6
## Metres from the ship they are set down at.
const SPAWN_RING := 8.0
## Metres above the ground the centre of a Meep sits, on top of its own radius.
const FLOOR_CLEARANCE := 0.04
## How sharply a Meep turns onto a new heading, per second of steering.
const TURN_RATE := 7.0
## Cost fields kept for job destinations before the oldest is dropped.
const FIELD_CACHE := 12
## Fills allowed on worker threads at once. See [method _start_field].
const FIELD_BAKES := 2
## Proxies lent to nearby Meeps. See [MeepPickProxy].
const PROXY_POOL := 8
## Metres within which a Meep is worth lending a proxy to. A little past the
## interaction ray, so the prompt is ready before the player is in range.
const PROXY_RANGE := 5.0
## Meeps whose positions go out in one state packet. Only the ones near a player
## are sent at all, and this is the ceiling on how many that can be: a battle in a
## crowded town must not become a packet nobody can carry.
const PUBLISH_LIMIT := 128
## How much of the gap to a freshly received position a client closes per second.
## Fast enough not to lag behind a walk, slow enough to hide the ten-hertz steps.
const FOLLOW_RATE := 12.0
## Seconds between regradings of the population's detail. Bands are a hundred
## metres wide and nobody walks across one in a quarter of a second, so paying for
## this every frame would buy nothing.
const GRADE_INTERVAL := 0.25
## Metres above the ground the colony's own combat point sits, roughly a Meep's
## head. See [method combat_position].
const COMBAT_LIFT := 0.8
## Metres added to the claim when reporting the colony's combat bounds. See
## [method combat_radius].
const COMBAT_MARGIN := 48.0

## Seconds between reviews of what the town should be doing. The colony decides what
## work exists here; individual Meeps only ever choose between what has been posted.
const PLAN_INTERVAL := 2.0
## Settlers a colony will grow to before the cloner stops being offered work. Not a
## design ceiling — it is what stops one town eating the frame while the passes that
## would give a larger population something to do are still to come.
const POPULATION_CAP := 32
## Biomass one use of the cloner costs, and how long a Meep is inside for.
const CLONE_COST := 12.0
const CLONE_SECONDS := 1.0
## How many may be inside the cloner at once. The sixth to arrive waits outside, which
## is what the cap is for.
const CLONE_CREW := 5
## Settlers each hut is built for. The town grows because the population does.
const SETTLERS_PER_HUT := 3
## Job seconds to fell one tree, before the walk out to it.
const MINE_SECONDS := 6.0
## Open mining jobs per living settler, and the fewest a colony will post while there
## is anything left to cut. Enough that nobody is idle for want of a tree, few enough
## that the whole town is not out in the woods when there is building to do.
##
## Set against how far the timber is rather than by taste: the flower trees keep sixty
## metres clear of the lander, so a felling trip is a two-minute round walk and a colony
## with two miners earns about one tree a minute. Half the town out cutting is what makes
## the other half's work affordable.
const MINE_SHARE := 0.55
const MINE_JOBS_MIN := 3
## Seconds between rereads of what timber is left standing. The trees do not move and
## nothing but the colony fells them, so this is only here to notice the ones a
## player's abilities took down.
const TIMBER_INTERVAL := 12.0
## Metres a felling volume covers. Wide enough to reach a trunk the Meep is standing
## beside, tight enough that the tree next to it is somebody else's job.
const FELL_RADIUS := 1.2
## Damage in one felling blow. Far past the toughest colony tree's health, because the
## chopping is the timer that already ran; this is only the moment it comes down.
const FELL_DAMAGE := 100000.0
## Metres a Meep stands off a trunk to chop it. Clear of the trunk's own collider, so
## the walk there is not a walk into a tree.
const TRUNK_CLEARANCE := 3.0
## Metres beyond a footprint that a finished building clears flora from. Past the
## corners of the box, so the flowers standing in a doorway go with the ones under it.
const CLEAR_MARGIN := 1.6
## Unfinished sites a town will have at once. More than one so that a crew is not the
## only thing happening, few enough that they are finished rather than started.
const SITES_AT_ONCE := 2
## Places at the cloner beyond the five inside, which is what the line at the door is.
const CLONE_QUEUE := 3
## Seconds a Meep waits at a full cloner before deciding there is better to be done.
const QUEUE_PATIENCE := 8.0
## What each kind of work is worth against the walk to it. A hundred metres of walking is
## worth one point, so building beats cutting beats cloning at equal distance, and a
## nearer job of a lesser kind can still win. Mining above cloning on purpose: it is what
## pays for everything, including the cloning.
const BUILD_PRIORITY := 3.0
const MINE_PRIORITY := 2.0
const CLONE_PRIORITY := 1.2

signal settlers_released(count: int)
signal meep_died(index: int)
## A player used a Meep. Nothing consumes this yet; it is what a future Meep panel
## opens on.
signal meep_inspected(index: int, player: Node)

var site_id: StringName
var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim
var tasks := MeepTasks.new()
var stats: MeepStats
var structures: MeepStructures
## The colony's single resource bank, in units of biomass. Earned by felling trees and
## spent on everything the Meeps put up. Host-authoritative and replicated with the
## rest of the colony, because a client that worked its own bank out would disagree
## the first time a tree came down on one peer a frame before the other.
var resources := 0.0
## Biomass promised to work that has been posted but not finished. Held back rather
## than deducted so that a cancelled job can hand it straight back, and so that two
## sites cannot be pegged out against the same units — which is the failure that shows
## up as half a town of foundations and nothing finished.
var committed := 0.0
var claim_radius := MeepClaim.DEFAULT_RADIUS
var founded_seed := 0

# One row per Meep, in step with each other. Positions are kept on the site's flat
# map rather than in three dimensions: it is the space the grid, the boundary and
# the cost fields all speak, it is half the memory, and a Meep's third coordinate
# is not a fact about the Meep but about the ground under it.
var _local := PackedVector2Array()
var _heading := PackedVector2Array()
var _goal := PackedVector2Array()
var _height := PackedFloat32Array()
var _health := PackedFloat32Array()
var _state := PackedByteArray()
var _detail := PackedByteArray()
var _job := PackedInt32Array()
var _seed := PackedInt32Array()
## Seconds since this row was last stepped, which is the timestep it is given when
## its turn comes. Meeps thinking at different rates is the whole of the detail
## system, and this is what keeps them moving at the same speed while they do.
var _since := PackedFloat32Array()
## Countdown on whatever the current state is waiting for.
var _timer := PackedFloat32Array()
## Where the host last said this Meep was, for a client to walk towards.
var _target := PackedVector2Array()
## Metres squared to the nearest eye, written by [method _grade]. Cached because
## three separate passes want it — detail, drawing and the proxy pool — and it is
## the most expensive thing any of them would otherwise work out for themselves.
var _near_squared := PackedFloat32Array()

var _planet: Planet
var _shape: PlanetShape
var _render: MultiMeshInstance3D
var _wall: MeepBoundaryWall
var _proxies: Array[MeepPickProxy] = []
## Filled cost fields by destination cell, oldest wanted first in [member
## _field_order], and the ones a worker is filling right now.
var _fields: Dictionary = {}
var _field_order: Array[Vector2i] = []
var _field_tasks: Dictionary = {}
var _field_filling: Dictionary = {}
var _tick_accum := 0.0
var _cursor := 0
var _alive := 0
var _build_task := -1
var _ground_ready := false
## Site-local positions of everyone who could be watching, refreshed a few times a
## second rather than once per Meep.
var _eyes := PackedVector2Array()
## Where this peer's own camera is, on the site map. The player list is what detail
## is graded against — the host has to keep everybody's neighbourhood sharp — but
## the proxies are for whoever is sitting here.
var _view_eye := Vector2.ZERO
var _grade_left := 0.0
## Ground height at the middle of the town. Read once, because it is the ground and
## the town does not move; refreshed with the bake in case a scar has changed it.
var _centre_height := 0.0
var _rng := RandomNumberGenerator.new()
var _deaths := PackedInt32Array()
## Standing timber within reach, world position in `xyz` and what felling it pays in
## `w`, nearest the town first. Read once when the ground is; a spent tree keeps its
## place with nothing left to pay, because the job board refers to trees by where they
## are in this list. See [method _read_timber].
var _timber := PackedVector4Array()
var _plan_left := 0.0
## Set when the town gained a building, so the reliable packet describing what stands
## where only goes out when something does.
var _town_changed := false


func _init() -> void:
	# Renamed after its site by whatever founds it. This is only so that a colony
	# built by hand in a harness has a name at all.
	name = "MeepColony"


func _ready() -> void:
	add_to_group(DamageHit.COMBATANT_GROUP)


## A worker reading this colony's grid must not be left running into a freed colony,
## and a session can be left one frame after it was founded.
func _exit_tree() -> void:
	if _build_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1
	for task_variant: Variant in _field_tasks.values():
		WorkerThreadPool.wait_for_task_completion(int(task_variant))
	_field_tasks.clear()
	_field_filling.clear()


## Founds the colony. The direction and heading come from whatever authorised it —
## a colony ship here, and a Meep expedition later — so nothing about this is tied
## to Vacationer's Landing.
func configure(planet: Planet, id: StringName, direction: Vector3, facing: float,
		settler_stats: MeepStats, radius: float, colony_seed: int) -> void:
	_planet = planet
	_shape = planet.shape if planet != null else null
	if _shape != null:
		# Idempotent, and the bake is about to read the field from a worker thread.
		# A colony founded before the planet's own ready would otherwise be asking
		# a shape that has not built its native field yet.
		_shape.prepare()
	site_id = id
	stats = settler_stats if settler_stats != null else MeepStats.new()
	claim_radius = maxf(radius, 8.0)
	founded_seed = colony_seed
	_rng.seed = colony_seed
	site = MeepSite.new(direction, _shape.radius if _shape != null else 8000.0,
		facing, MeepGrid.CELLS * MeepGrid.CELL * 0.5)
	grid = MeepGrid.new(site)
	claim = MeepClaim.new()
	_centre_height = _shape.elevation(site.direction_at(Vector2.ZERO)) \
		if _shape != null else 0.0
	_raise_render()
	_raise_wall()
	_raise_proxies()
	structures = MeepStructures.new()
	add_child(structures)
	structures.configure(site, grid, claim, _shape, _planet)
	_start_ground()


## Whether the ground has been read and the boundary drawn. Until it is, settlers
## can be released and will stand about: the bake takes a few frames on a worker
## thread and a colony that refused to accept people until it finished would be a
## button that does nothing.
func ground_ready() -> bool:
	return _ground_ready


# --- Founding ----------------------------------------------------------------

## Bakes the navigation grid and fills the claim, off the main thread.
##
## The grid is sampled at the planet's finest spacing rather than at what is drawn
## underfoot. Two reasons, and they are the same reason: it is the true shape of
## the ground, so a crevasse is a crevasse whether or not a coarse chunk is
## currently drawing a lid over it; and it is identical on every peer, which is
## what lets a client rebuild all of this instead of being sent it.
func _start_ground() -> void:
	if _shape == null or _build_task >= 0:
		return
	_ground_ready = false
	_build_task = WorkerThreadPool.add_task(_bake_ground, true,
		"MeepColony ground bake")


func _bake_ground() -> void:
	var spacing := _planet.finest_spacing() if _planet != null else 0.0
	grid.build(_shape, spacing)
	claim.build(grid, Vector2.ZERO, claim_radius)


## Picks up the finished bake. Everything here touches the tree, so it waits for
## the main thread rather than being done at the end of the task.
func _finish_ground() -> void:
	_build_task = -1
	_ground_ready = true
	_fields.clear()
	_field_order.clear()
	# Targeted at the cell the claim actually grew from rather than the exact centre,
	# which can be a slope under the ship's legs. Asked for first of anything, because
	# it is the route a Meep follows out of anywhere it should not have got to.
	_start_field(claim.origin)
	# Now that there is a grid, the town's own middle rather than the point under the
	# ship, which the flood fill may have had to step away from.
	_centre_height = grid.height_at(claim.origin)
	if _wall != null:
		_wall.raise(site, claim, _shape, _spacing_drawn())
	# The ground a building stands on was taken out of the grid the bake just replaced,
	# so a client that has caught up with a town already standing has to take it out
	# again. Heights too: the sites were pegged out against whatever the grid held at
	# the time, which on a client is nothing.
	if structures != null:
		structures.resettle()
	# Reachability is a question about the grid, so the woods are read now rather than
	# when the colony was founded.
	_read_timber()
	# Anyone released while the ground was still being read is standing on an
	# unknown cell. Now that there is a map, put them back on it.
	for index in _local.size():
		if _state[index] != State.DEAD:
			_settle(index)


# --- Population --------------------------------------------------------------

## Sets down [param count] settlers around the colony centre and returns how many
## arrived. Host-side; the same call runs on every peer through the release packet,
## so the wave is laid out from the shared seed rather than sent position by
## position.
func release_settlers(count: int, wave_seed: int) -> int:
	if count <= 0:
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = wave_seed
	var added := 0
	for settler in count:
		# Spread around the ship rather than stacked at it, and off the ring by a
		# little so a wave does not read as a circle drawn on the ground.
		var angle := TAU * float(settler) / float(count) + rng.randf() * 0.4
		var away := SPAWN_RING * (0.65 + rng.randf() * 0.5)
		var at := Vector2(cos(angle), sin(angle)) * away
		if _add(at, rng.randi()) >= 0:
			added += 1
	if added > 0:
		settlers_released.emit(added)
	return added


func _add(at: Vector2, row_seed: int) -> int:
	var index := _local.size()
	_local.push_back(at)
	_heading.push_back(Vector2.ZERO)
	_goal.push_back(at)
	_height.push_back(0.0)
	_health.push_back(stats.maximum_health)
	_state.push_back(State.IDLE)
	_detail.push_back(Detail.COLD)
	_job.push_back(0)
	_seed.push_back(row_seed)
	_since.push_back(0.0)
	_timer.push_back(0.0)
	_target.push_back(at)
	_near_squared.push_back(0.0)
	_alive += 1
	if _ground_ready:
		_settle(index)
	if _render != null and _render.multimesh != null:
		_render.multimesh.instance_count = _local.size()
	return index


## Puts a Meep on the ground, and off any cell it should not be standing on. Used
## when one is released and when the ground under a colony is rebuilt.
func _settle(index: int) -> void:
	var cell := grid.cell_of(_local[index])
	if not grid.passable(cell):
		var found := grid.nearest_passable(cell)
		if found != cell:
			_local[index] = grid.centre_of(found)
			cell = found
	# From the field rather than the cell's cached height, which is a two-metre
	# average and would leave a settler visibly buried on a slope until its first
	# step corrected it.
	_height[index] = _shape.elevation(site.direction_at(_local[index]),
		_spacing_drawn()) if _shape != null else grid.height_at(cell)


func count() -> int:
	return _local.size()


func alive_count() -> int:
	return _alive


# --- The tick ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _build_task >= 0 and WorkerThreadPool.is_task_completed(_build_task):
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_finish_ground()
	_collect_fields()
	if not _is_host():
		_follow(delta)
		return
	_tick_accum += delta
	if _tick_accum < SIM_STEP:
		return
	# The whole accumulated time, not one nominal step. A frame that took longer
	# than a tick has to move the colony that far, or a busy scene runs the town in
	# slow motion.
	var elapsed := _tick_accum
	_tick_accum = 0.0
	_simulate(elapsed)


func _process(delta: float) -> void:
	if not _ground_ready:
		return
	# The host has already graded this tick, as part of deciding who thinks. A
	# client never ticks, and still has to know who to draw.
	if not _is_host():
		_grade_left -= delta
		if _grade_left <= 0.0:
			_grade_left = GRADE_INTERVAL
			_refresh_eyes()
			_grade()
	_draw()
	_lend_proxies()
	if structures != null:
		structures.draw()
		structures.lend_colliders(_view_eye)


func _simulate(elapsed: float) -> void:
	if not _ground_ready or _local.is_empty():
		return
	_refresh_eyes()
	_grade()
	_plan_left -= elapsed
	if _plan_left <= 0.0:
		_plan_left = PLAN_INTERVAL
		_plan_town()
	var total := _local.size()
	for index in total:
		if _state[index] != State.DEAD:
			_since[index] += elapsed
	# A rotating window rather than the whole population, so one colony can never
	# cost more than its share of a frame however many people are in it. What a
	# crowded town loses is reaction time, which is the right thing to lose.
	var budget := mini(STEPS_PER_TICK, total)
	for _slot in budget:
		if _cursor >= total:
			_cursor = 0
		var index := _cursor
		_cursor += 1
		if _state[index] == State.DEAD:
			continue
		var due := _interval(_detail[index] as Detail)
		if _since[index] < due:
			continue
		var step := _since[index]
		_since[index] = 0.0
		_step(index, step)
	_publish()


func _interval(detail: Detail) -> float:
	match detail:
		Detail.HOT:
			return HOT_INTERVAL
		Detail.WARM:
			return WARM_INTERVAL
		_:
			return COLD_INTERVAL


# --- What the town does ------------------------------------------------------

## The colony's own decisions, a couple of seconds apart: what is worth cutting down,
## what is worth building, and whether anyone should be making more Meeps.
##
## The colony's job rather than each Meep's, and that is the load-bearing part. A
## settler deciding for itself what the town needs has to look at the whole town to
## decide, and a hundred of them doing that is a hundred surveys of the same town every
## tick. Here it happens once and what reaches a Meep is a short list of work with
## somewhere to stand. It is also why a Meep never has an opinion about biomass: what
## the colony cannot afford is never posted, so nobody sets off to build something that
## will not be paid for.
func _plan_town() -> void:
	_plan_mining()
	_plan_building()
	_plan_cloning()


## Reads what timber is standing within reach of the town, nearest first.
##
## Once, when the ground is read, and only ever spent from afterwards. Trees do not
## move and nothing else fells them on purpose, so the list stays true; one taken down
## by something else simply absorbs nothing when a Meep swings at it, and the trip goes
## unpaid. That is cheaper than rereading the woods on a timer, and it is what keeps
## the job board's references to trees valid — a list that resorted itself would
## renumber the tree every posted job was about.
##
## Only a field that keeps its plants whether or not anyone is looking can answer this.
## [GroundCover] streams its tiles around a viewer, so the grass and flowers a Meep
## walked past this morning are not there to be asked about once the player is on the
## far side of the planet. The colony's own flower trees are always resident, which is
## why timber is what Meeps harvest first.
func _read_timber() -> void:
	_timber = PackedVector4Array()
	if _planet == null or site == null or grid == null or not _is_host():
		return
	var centre := _planet.to_global(site.point_at(Vector2.ZERO, _centre_height))
	# Inside the grid, since a route can only be worked out where there are cells.
	var reach := grid.half_span() - grid.cell_size * 2.0
	for field_variant: Variant in get_tree().get_nodes_in_group(
			DamageHit.FIELD_GROUP):
		var field := field_variant as Node
		if field == null or not DamageHit.in_same_world(self, field) \
				or not field.has_method(&"standing_near") \
				or not field.has_method(&"harvest_value"):
			continue
		var standing: PackedVector4Array = field.call(
			&"standing_near", centre, reach)
		for tree in standing:
			var pays := float(field.call(&"harvest_value", tree.w))
			if pays > 0.0:
				_timber.push_back(Vector4(tree.x, tree.y, tree.z, pays))
	_sort_timber(centre)


## Nearest the middle of town first, which is what makes the cleared ring grow outward
## from the ship rather than appearing wherever a Meep happened to look.
func _sort_timber(centre: Vector3) -> void:
	var order: Array[Vector2i] = []
	for slot in _timber.size():
		var tree := _timber[slot]
		order.push_back(Vector2i(roundi(Vector3(tree.x, tree.y, tree.z)
			.distance_to(centre) * 10.0), slot))
	order.sort()
	var sorted := PackedVector4Array()
	for entry in order:
		sorted.push_back(_timber[entry.y])
	_timber = sorted


## Keeps a few felling jobs open at the nearest trees left standing.
##
## A share of the population rather than a fixed number, so a bigger colony cuts
## faster, and a share well under all of it, so a town is never entirely out in the
## woods when there is building to do.
func _plan_mining() -> void:
	if _timber.is_empty() or grid == null:
		return
	var open := tasks.count_of(MeepTasks.Kind.MINE)
	var wanted := maxi(MINE_JOBS_MIN, roundi(_alive * MINE_SHARE))
	for slot in _timber.size():
		if open >= wanted:
			return
		var tree := _timber[slot]
		if tree.w <= 0.0 or tasks.any_about(MeepTasks.Kind.MINE, slot):
			continue
		var stand := _stand_beside(tree)
		if not grid.passable(stand) or not grid.inside(stand):
			# Rooted somewhere nobody can stand next to. Nothing about that changes,
			# so it stops being timber rather than being offered again every review.
			_timber[slot] = Vector4(tree.x, tree.y, tree.z, 0.0)
			continue
		var posted := tasks.job(tasks.post(MeepTasks.Kind.MINE, stand,
			MINE_PRIORITY, 1, MINE_SECONDS))
		if posted == null:
			continue
		posted.subject = slot
		posted.spot = Vector3(tree.x, tree.y, tree.z)
		posted.payout = tree.w
		open += 1


## The cell to chop from: beside the trunk, on the town side of it. The cell a tree is
## rooted in is filled by the tree, so a job posted there is a job nobody can arrive at.
func _stand_beside(tree: Vector4) -> Vector2i:
	var local := _site_local_of(Vector3(tree.x, tree.y, tree.z))
	var inward := local.normalized() if local.length() > 0.01 else Vector2.RIGHT
	return grid.cell_of(local - inward * TRUNK_CLEARANCE)


## What the town would put up next if it could pay for it, or -1 if it wants nothing.
##
## Asked by the cloner as well as by the builders, which is the point of it being a
## question rather than a branch: population is what the colony spends on last, so
## something has to be able to say what the building would have cost.
func _wanted_kind() -> int:
	if structures == null or not _ground_ready:
		return -1
	# A cloner before anything else, since it is the only way a colony grows and
	# biomass spent on housing first would be biomass spent housing nobody. Nothing
	# else while it is going up, either.
	if structures.count_of(MeepStructures.Kind.CLONER) == 0:
		return MeepStructures.Kind.CLONER
	if structures.count_of(MeepStructures.Kind.CLONER, true) == 0:
		return -1
	# A cap on unfinished sites, not on sites. Pegging out everything the bank can
	# afford would spread one crew across a field of foundations, and a town of
	# foundations is not a town.
	if structures.count() - structures.built_count() >= SITES_AT_ONCE:
		return -1
	if structures.count_of(MeepStructures.Kind.HUT) < _alive / SETTLERS_PER_HUT:
		return MeepStructures.Kind.HUT
	return -1


func _plan_building() -> void:
	var kind := _wanted_kind()
	if kind >= 0:
		_peg_out(kind)


## Pegs out a site, posts the work, and holds back what it will cost.
##
## Held rather than spent, so the bank cannot promise the same biomass to two sites and
## leave the second one standing half-built forever.
func _peg_out(kind: int) -> bool:
	var plan := MeepStructures.plan_of(kind)
	if available() < plan.cost:
		return false
	var index := structures.place(kind)
	if index < 0:
		# No room left in the claim that is level, clear of the ship and clear of
		# everything else. The roads pass is what reclaims the space between.
		return false
	var entry := structures.at(index)
	var posted := tasks.job(tasks.post(MeepTasks.Kind.BUILD,
		structures.work_cell(index), BUILD_PRIORITY, plan.crew, plan.work,
		plan.cost))
	if posted == null:
		return false
	posted.subject = index
	entry.job = posted.id
	committed += plan.cost
	_town_changed = true
	return true


## Keeps one standing offer of a place at the cloner while the colony can pay for it and
## has room to grow. One job with room for the whole crew and a few more waiting, rather
## than one job per clone: the queue at the door is a queue because the board let them
## all claim the same work.
func _plan_cloning() -> void:
	if structures == null:
		return
	var cloner := structures.nearest(MeepStructures.Kind.CLONER, Vector2.ZERO)
	var open := tasks.all_of(MeepTasks.Kind.CLONE)
	# Whatever the town still wants to build is paid for before anyone is made. This is
	# only ever load-bearing when the building could not be afforded — an affordable one
	# was pegged out a moment ago by [method _plan_building] and its cost is already held
	# back — and that is exactly the case worth catching: a colony that cloned away the
	# last of its biomass is a bigger colony with nothing to live in and nothing to do.
	var reserve := 0.0
	var next := _wanted_kind()
	if next >= 0:
		reserve = MeepStructures.plan_of(next).cost
	var wanted := cloner >= 0 and _alive < POPULATION_CAP \
		and available() >= reserve + CLONE_COST
	if wanted and open.is_empty():
		var posted := tasks.job(tasks.post(MeepTasks.Kind.CLONE,
			structures.work_cell(cloner), CLONE_PRIORITY,
			CLONE_CREW + CLONE_QUEUE))
		if posted != null:
			posted.subject = cloner
		return
	if not wanted:
		# Nothing to give back: the cloner is paid for a use at a time, at the door.
		for entry in open:
			tasks.finish(entry.id)


# --- The bank ----------------------------------------------------------------

## Biomass the colony may promise to something new: what it has, less what it has
## already promised to work in progress.
func available() -> float:
	return maxf(resources - committed, 0.0)


## Pays biomass in. Public because harvesting is the only thing that earns, and it is
## worth being able to see that from the outside.
func credit(amount: float) -> void:
	if amount > 0.0:
		resources += amount


## Spends what a finished job had been holding.
func _spend_reserved(amount: float) -> void:
	committed = maxf(committed - amount, 0.0)
	resources = maxf(resources - amount, 0.0)


## Spends on the spot, for work paid for as it happens rather than promised up front.
func _spend(amount: float) -> void:
	resources = maxf(resources - amount, 0.0)


## Where everyone who could be watching is, on the site's flat map. Gathered once a
## tick: the alternative is every Meep asking the scene tree for the player list,
## which is the same answer looked up a thousand times.
func _refresh_eyes() -> void:
	_eyes.clear()
	if site == null:
		return
	if _planet != null:
		var viewer := _planet.viewer_position()
		_view_eye = site.to_local(viewer.normalized()) \
			if viewer.length_squared() > 1.0 else Vector2.ZERO
	for player_variant: Variant in get_tree().get_nodes_in_group(&"network_players"):
		var player := player_variant as Node3D
		if player == null or not DamageHit.in_same_world(self, player):
			continue
		_eyes.push_back(_site_local_of(player.global_position))
	# Before anyone has spawned — the home screen, a dev harness — the camera is
	# still somebody looking, and a colony that graded itself COLD then would not
	# draw for the one view there is.
	if _eyes.is_empty():
		_eyes.push_back(_view_eye)


func _site_local_of(global_point: Vector3) -> Vector2:
	if _planet == null or site == null:
		return Vector2.ZERO
	var local := _planet.to_local(global_point)
	if local.length_squared() < 1.0:
		return Vector2.ZERO
	return site.to_local(local.normalized())


## Sorts the population into detail bands. Measured on the flat map, in metres, so
## this costs a subtraction per Meep per eye rather than a projection.
func _grade() -> void:
	var hot := HOT_RANGE * HOT_RANGE
	var warm := WARM_RANGE * WARM_RANGE
	if _near_squared.size() != _local.size():
		_near_squared.resize(_local.size())
	for index in _local.size():
		if _state[index] == State.DEAD:
			continue
		var nearest := INF
		for eye in _eyes:
			nearest = minf(nearest, _local[index].distance_squared_to(eye))
		_near_squared[index] = nearest
		if nearest <= hot:
			_detail[index] = Detail.HOT
		elif nearest <= warm:
			_detail[index] = Detail.WARM
		else:
			_detail[index] = Detail.COLD


# --- One Meep ----------------------------------------------------------------

func _step(index: int, delta: float) -> void:
	match _state[index] as State:
		State.IDLE:
			_decide(index)
		State.WALK:
			_walk(index, delta)
		State.WORK:
			_work(index, delta)
		State.INSIDE:
			_incubate(index, delta)
		State.FLEE:
			_flee(index, delta)
		_:
			pass


## What to do next. The board is asked first and wandering is what is left, which
## is the order the later passes need: a colony with a cloner to use and a road to
## lay should have nobody strolling.
func _decide(index: int) -> void:
	var cell := grid.cell_of(_local[index])
	var chosen := tasks.best_for(cell, grid.cell_size, _seed[index])
	if chosen != 0 and tasks.claim(chosen):
		var job := tasks.job(chosen)
		_job[index] = chosen
		_goal[index] = grid.centre_of(job.at)
		_state[index] = State.WALK
		_timer[index] = _patience(cell, job.at)
		return
	_wander(index)


## How long a Meep will spend getting to a job before giving it up.
##
## The straight walk with generous slack, because a route around a chasm is much longer
## than the line across it. It exists for the goal that was walled off after it was
## picked, or was never reachable in the first place: without it a Meep with an
## impossible job walks at a wall until the session ends.
func _patience(from: Vector2i, to: Vector2i) -> float:
	var away := Vector2(to - from).length() * grid.cell_size
	return away / maxf(stats.walk_speed, 0.1) * 2.5 + 8.0


func _wander(index: int) -> void:
	# The colony's own generator rather than one per decision: a settler picking a
	# stroll should not allocate, and only the host ever wanders — where a Meep
	# went is replicated, so it does not have to be reproducible.
	var reach := claim_radius * stats.wander_share
	for _attempt in 6:
		var angle := _rng.randf() * TAU
		# Square-rooted so targets are spread evenly over the town rather than
		# bunched at its middle.
		var away := sqrt(_rng.randf()) * reach
		var at := Vector2(cos(angle), sin(angle)) * away
		var cell := grid.cell_of(at)
		if grid.passable(cell) and claim.contains_cell(cell):
			_goal[index] = grid.centre_of(cell)
			_state[index] = State.WALK
			_timer[index] = stats.wander_seconds
			return
	# A colony whose claim is a handful of cells — founded on a ledge, or with the
	# sea on three sides — can legitimately have nowhere to stroll.
	_state[index] = State.IDLE
	_timer[index] = stats.wander_seconds


func _walk(index: int, delta: float) -> void:
	_timer[index] -= delta
	var here := _local[index]
	if here.distance_to(_goal[index]) <= stats.arrive_within:
		_arrive(index)
		return
	# A walk that has gone on too long is a walk that is not working: the goal may have
	# been walled off by a building since it was picked.
	if _timer[index] <= 0.0:
		if _job[index] == 0:
			_wander(index)
		else:
			_give_up(index)
		return
	_advance(index, delta, stats.walk_speed)


func _arrive(index: int) -> void:
	var job := tasks.job(_job[index])
	if job == null:
		_leave_job(index)
		return
	_state[index] = State.WORK
	if job.kind == MeepTasks.Kind.CLONE:
		# The wait at the door, rather than the work: there may be five inside already.
		_timer[index] = QUEUE_PATIENCE


## Work in progress, which is different work depending on what was claimed. A job whose
## board entry has gone was cancelled from under this Meep, which is also how the rest
## of a crew learn that somebody else finished what they were all doing.
func _work(index: int, delta: float) -> void:
	var job := tasks.job(_job[index])
	if job == null:
		_leave_job(index)
		return
	var seconds := delta * stats.work_rate
	match job.kind:
		MeepTasks.Kind.MINE:
			_chop(index, job, seconds)
		MeepTasks.Kind.BUILD:
			_build(index, job, seconds)
		MeepTasks.Kind.CLONE:
			_queue_at_cloner(index, job, delta)
		_:
			if tasks.work(job.id, seconds):
				_finish_job(index, job)


## Felling a tree. The timer is the chopping; the blow at the end of it is the tree
## coming down.
##
## Down through [DamageHit] rather than by asking the field to delete something, because
## that is the path a felled plant already travels: the break lands in the ledger the
## world reconciles a few times a second, the break effect plays, the collider goes, and
## a client watches the tree fall without this colony sending anything of its own. A
## volume that absorbs nothing means somebody else got there first, and the trip goes
## unpaid.
func _chop(index: int, job: MeepTasks.Job, seconds: float) -> void:
	if not tasks.work(job.id, seconds):
		return
	if job.spot != Vector3.ZERO:
		var hit := DamageHit.impact(job.spot, FELL_RADIUS, FELL_DAMAGE)
		hit.affects_combatants = false
		if DamageHit.apply_to_fields(self, hit) > 0.0:
			credit(job.payout)
	if job.subject >= 0 and job.subject < _timber.size():
		var felled := _timber[job.subject]
		_timber[job.subject] = Vector4(felled.x, felled.y, felled.z, 0.0)
	_finish_job(index, job)


## Building. Every Meep on the site pushes the same progress, which is the whole reason
## a crew is worth gathering: three of them raise a hut in a third of the time, and the
## one who happens to lay the last of it is the one who finishes the job for all of them.
func _build(index: int, job: MeepTasks.Job, seconds: float) -> void:
	if structures == null:
		_leave_job(index)
		return
	var done := structures.advance(job.subject, seconds)
	tasks.work(job.id, seconds)
	if not done:
		return
	_complete_building(job.subject)
	_spend_reserved(job.reserved)
	_finish_job(index, job)


## A building completes: the ground it stands on leaves the map, the flora it stands in
## comes down, and the crew who were standing in the footprint are put outside it.
func _complete_building(structure: int) -> void:
	structures.block(structure)
	_clear_footprint(structure)
	_town_changed = true
	for index in _local.size():
		if _state[index] != State.DEAD \
				and not grid.passable(grid.cell_of(_local[index])):
			_settle(index)


## Tears the flora out of a finished building's footprint.
##
## One area volume, the same trick an explosion uses, through the same ledger: what is
## cleared is cleared on every peer and stays cleared when the tile streams out again.
## What it cannot do is stop new grass being scattered there afterwards — region
## suppression is a world-space registry the flora system does not have yet — so a
## building raised while nobody was near enough for the undergrowth to have streamed in
## will have some of it inside.
func _clear_footprint(structure: int) -> void:
	if not _is_host() or structures == null:
		return
	var hit := DamageHit.area(structures.world_centre(structure),
		structures.footprint_radius(structure) + CLEAR_MARGIN, FELL_DAMAGE, 0.0)
	hit.affects_combatants = false
	DamageHit.apply_to_fields(self, hit)


## At the cloner's door. Five may be inside; whoever arrives after that waits, which is
## all a queue is. Nothing is spent until a Meep is actually in the machine, so the last
## twelve biomass cannot be promised to three of them at once.
func _queue_at_cloner(index: int, job: MeepTasks.Job, delta: float) -> void:
	var entry := structures.at(job.subject) if structures != null else null
	if entry == null or not entry.built():
		_leave_job(index)
		return
	_timer[index] -= delta
	if entry.inside >= CLONE_CREW or available() < CLONE_COST \
			or _alive >= POPULATION_CAP:
		# Not waiting forever: a colony that has run out of biomass has better things
		# for the line at the door to be doing.
		if _timer[index] <= 0.0:
			_leave_job(index)
		return
	entry.inside += 1
	_spend(CLONE_COST)
	_state[index] = State.INSIDE
	_timer[index] = CLONE_SECONDS


## A second inside the cloner, and then two Meeps where one went in.
func _incubate(index: int, delta: float) -> void:
	_timer[index] -= delta
	if _timer[index] > 0.0:
		return
	var job := tasks.job(_job[index])
	var entry: MeepStructures.Site = null
	if job != null and structures != null:
		entry = structures.at(job.subject)
	if entry != null:
		entry.inside = maxi(entry.inside - 1, 0)
	_leave_job(index)
	# Beside the door rather than in the machine: the footprint is not ground anyone may
	# stand on, and [method _add] settles a newcomer onto the nearest cell that is.
	var angle := _rng.randf() * TAU
	_add(_local[index] + Vector2(cos(angle), sin(angle))
		* stats.body_radius * 3.0, _rng.randi())


## Puts a job down without finishing it, handing the place on the crew back.
func _leave_job(index: int) -> void:
	if _job[index] != 0:
		tasks.release(_job[index])
		_job[index] = 0
	_state[index] = State.IDLE


## Work that is done: the crew place goes back and the job comes off the board, which is
## how the rest of the crew find out there is nothing left to do.
func _finish_job(index: int, job: MeepTasks.Job) -> void:
	tasks.release(job.id)
	tasks.finish(job.id)
	_job[index] = 0
	_state[index] = State.IDLE


## A walk to a job that took too long. Mining gives the tree up as well as the job:
## nothing about a tree nobody can walk to is going to change, so offering it to the next
## Meep is the same trip wasted again.
func _give_up(index: int) -> void:
	var job := tasks.job(_job[index])
	if job != null and job.kind == MeepTasks.Kind.MINE:
		if job.subject >= 0 and job.subject < _timber.size():
			var stranded := _timber[job.subject]
			_timber[job.subject] = Vector4(
				stranded.x, stranded.y, stranded.z, 0.0)
		_finish_job(index, job)
		return
	_leave_job(index)


## Away from whatever hurt this Meep, using the goal as the place it is running to.
## Set by [method apply_damage]; the mobs pass is what will keep it running.
func _flee(index: int, delta: float) -> void:
	_timer[index] -= delta
	if _timer[index] <= 0.0:
		_state[index] = State.IDLE
		return
	_advance(index, delta, stats.flee_speed)


## Moves a Meep towards its goal and puts it back on the ground.
##
## The route comes from the shared cost field when the direct line is blocked,
## which is what keeps a Meep out of the chasm without giving it a path of its own
## to store and follow. Cells are never entered unless the grid says they can be
## stood in, so the failure mode of a bad route is a Meep that stops rather than
## one that walks into a hole.
func _advance(index: int, delta: float, speed: float) -> void:
	var here := _local[index]
	var cell := grid.cell_of(here)
	var wanted := (_goal[index] - here).normalized()
	var straight := grid.cell_of(here + wanted * grid.cell_size)
	if not grid.passable(straight):
		wanted = _detour(index, cell, wanted)
	if wanted == Vector2.ZERO:
		return
	# Turned onto rather than snapped to, so a Meep rounding an obstacle reads as
	# having chosen to.
	var heading := _heading[index]
	heading = wanted if heading == Vector2.ZERO \
		else heading.lerp(wanted, clampf(delta * TURN_RATE, 0.0, 1.0))
	if heading.length_squared() < 0.0001:
		heading = wanted
	heading = heading.normalized()
	_heading[index] = heading
	var next := here + heading * speed * delta
	var into := grid.cell_of(next)
	if into != cell and not grid.passable(into):
		# Steered into something between deciding and moving. Give up the step
		# rather than the cell: next tick it will ask the field instead.
		return
	if _detail[index] == Detail.HOT and _obstructed(index, here, heading):
		return
	_local[index] = next
	_height[index] = _ground_height(index, into)


## The way around whatever is in front of a Meep.
##
## A cost field is worth building for a job: many Meeps walk to it, they keep
## walking to it, and the field outlives all of their trips. It is not worth
## building for a stroll — that would be one full field per Meep per minute, which
## is the cost this whole design exists to avoid — so a wanderer rounds the
## obstruction by shoulder instead, which is also what keeps it heading where it
## meant to go.
func _detour(index: int, cell: Vector2i, wanted: Vector2) -> Vector2:
	if _job[index] != 0:
		# Null while the fill is still on a worker, which is the first few tenths of
		# a second after a crew is handed work at a place nobody has walked to yet.
		# They shoulder their way there in the meantime and pick the route up when it
		# arrives, which for the first stretch of a long walk is the same line.
		var field := _field_for(grid.cell_of(_goal[index]))
		var step := field.step_at(cell) if field != null else Vector2i.ZERO
		if step != Vector2i.ZERO:
			return (grid.centre_of(cell + step) - _local[index]).normalized()
	# Least deviation first, so a Meep skirting a boulder does not set off at right
	# angles to it.
	for turn: float in [PI * 0.25, -PI * 0.25, PI * 0.5, -PI * 0.5,
			PI * 0.75, -PI * 0.75]:
		var aside := wanted.rotated(turn)
		if grid.passable(grid.cell_of(_local[index] + aside * grid.cell_size)):
			return aside
	# Boxed in on every side. The route home is the field the colony keeps whatever
	# else it drops, so it is the one thing that can be followed out of a corner.
	var home := _home_field()
	var home_step := home.step_at(cell) if home != null else Vector2i.ZERO
	if home_step != Vector2i.ZERO:
		return (grid.centre_of(cell + home_step) - _local[index]).normalized()
	return Vector2.ZERO


## Anything solid in the way, for the Meeps close enough that walking through a
## tree would be seen.
##
## Only the world layer, and only for HOT Meeps: grass has no collider to begin
## with, and the trees and flower trees that do only have one while a player is near
## enough for their field to have streamed collision in. Everything further out is
## the grid's problem, and the grid does not know about plants — which is the trade
## this build makes, and the roads pass is what closes it.
func _obstructed(index: int, from: Vector2, heading: Vector2) -> bool:
	if _planet == null:
		return false
	var lift := stats.body_radius + FLOOR_CLEARANCE
	# Far enough ahead to turn in. A ray only as long as one tick's walk would find
	# the tree at the moment the Meep was already inside it.
	var probe := from + heading * (stats.body_radius + grid.cell_size * 0.5)
	var start := _planet.to_global(site.point_at(from, _height[index] + lift))
	var end := _planet.to_global(site.point_at(probe, _height[index] + lift))
	var query := PhysicsRayQueryParameters3D.create(start, end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	# Turn away from it, so the next step has somewhere to go.
	var aside := _heading[index].rotated(PI * 0.5 if (_seed[index] & 1) == 0 \
		else -PI * 0.5)
	_heading[index] = aside
	return true


## Where the ground is under a Meep.
##
## HOT Meeps are read from the field at the spacing the terrain is being drawn at,
## because they are the ones whose feet can be seen and the drawn surface is the one
## they have to stand on. Everyone else takes the grid's cached height, which is one
## array read and correct to within a cell.
func _ground_height(index: int, cell: Vector2i) -> float:
	if _detail[index] != Detail.HOT or _shape == null:
		return grid.height_at(cell)
	return _shape.elevation(site.direction_at(_local[index]), _spacing_drawn())


func _spacing_drawn() -> float:
	return _planet.spacing_underfoot() if _planet != null else 0.0


# --- Cost fields -------------------------------------------------------------

## The field for a destination, shared by everyone walking there.
##
## Never fills one here. A pass over sixteen thousand cells is about a tenth of a
## second, and the moments something wants a new route are the worst possible moments
## to spend that on the main thread: a crew being handed a job, or a building
## completing and invalidating every route in town at once. So this answers with what
## it has — nothing, or the field from before the ground changed — and puts the fill
## on a worker.
##
## A stale field is worth more than no field. It was measured against ground that has
## since gained a building, and the only way it can be wrong is by routing somebody
## at a cell that is now blocked, which [method _advance] refuses to enter anyway. A
## Meep that pauses for a step is a better failure than a Meep with no idea where to
## go.
func _field_for(target: Vector2i) -> MeepFlowField:
	var field := _fields.get(target) as MeepFlowField
	if field == null or field.stale():
		_start_field(target)
	return field


## Puts a fill on a worker thread, unless that target is already being filled or the
## colony has as many in flight as it is allowed.
##
## The cap is what stops a town whose ground just changed from queueing a dozen
## simultaneous passes: the fields are wanted one at a time by whoever asks first, and
## the rest of the callers are content with steering until their turn comes.
func _start_field(target: Vector2i) -> void:
	if not _is_host() or _field_tasks.has(target) \
			or _field_tasks.size() >= FIELD_BAKES \
			or grid == null or not _ground_ready:
		return
	var field := MeepFlowField.new()
	_field_filling[target] = field
	# Bound rather than looked up in the task, because the task runs on another
	# thread and the dictionaries it would have to read are written on this one.
	_field_tasks[target] = WorkerThreadPool.add_task(
		_bake_field.bind(field, target), true, "MeepColony route bake")


## Worker body. Touches only the field it was handed and the grid, which is read-only
## for the duration: flags do change under it when a building completes, and the
## revision that change bumps is what makes the field this produces stale on arrival
## rather than wrong in use.
func _bake_field(field: MeepFlowField, target: Vector2i) -> void:
	field.build(grid, target)


## Picks up finished fills. Same place the ground bake is collected, for the same
## reason: the tree is only safe to touch here.
func _collect_fields() -> void:
	if _field_tasks.is_empty():
		return
	for target_variant: Variant in _field_tasks.keys():
		var target := target_variant as Vector2i
		var task := int(_field_tasks[target])
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		_field_tasks.erase(target)
		var field := _field_filling.get(target) as MeepFlowField
		_field_filling.erase(target)
		if field == null:
			continue
		if not _fields.has(target):
			_field_order.push_back(target)
		_fields[target] = field
		_evict_fields()


## Drops the least recently wanted routes. The way home is never one of them: it is
## what a Meep boxed into a corner follows out, so a town that had dropped it would
## have nothing to offer whoever needed it most.
func _evict_fields() -> void:
	while _field_order.size() > FIELD_CACHE:
		var oldest: Vector2i = _field_order.pop_front()
		if claim != null and oldest == claim.origin:
			_field_order.push_back(oldest)
			continue
		_fields.erase(oldest)


## The route to the middle of town, if one has been filled. See [method _detour].
func _home_field() -> MeepFlowField:
	return _field_for(claim.origin) if claim != null else null


## Rebuilds the boundary and drops every route. Called when the ground changes
## under a town — a crater cut inside it, or a building put up.
func reground() -> void:
	if _build_task >= 0:
		return
	_start_ground()


# --- Presentation ------------------------------------------------------------

func _raise_render() -> void:
	_render = MultiMeshInstance3D.new()
	_render.name = "Meeps"
	var mesh := SphereMesh.new()
	mesh.radius = stats.body_radius
	mesh.height = stats.body_radius * 2.0
	# A placeholder body, so it costs a placeholder's worth of geometry.
	mesh.radial_segments = 10
	mesh.rings = 5
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.94, 0.95, 0.97)
	material.roughness = 0.55
	mesh.material = material
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.mesh = mesh
	_render.multimesh = batch
	add_child(_render)


func _raise_wall() -> void:
	_wall = MeepBoundaryWall.new()
	add_child(_wall)


func _raise_proxies() -> void:
	for _slot in PROXY_POOL:
		var proxy := MeepPickProxy.new()
		proxy.configure(self, stats.body_radius)
		add_child(proxy)
		_proxies.push_back(proxy)


## Whether a Meep is anywhere the world can see it. Dead ones are gone and the ones
## inside the cloner are inside the cloner: neither is drawn, lent a collider, or hit by
## anything. Which is why the state has to reach a client — a client that only knew who
## was alive would draw the queue at the door and everybody in the machine as well.
func _visible(index: int) -> bool:
	var state := _state[index]
	return state != State.DEAD and state != State.INSIDE


## Writes the drawn Meeps into the batch.
##
## Only the ones close enough to see, and the count is what changes rather than the
## contents: a colony nobody is at draws nothing while still being simulated, which
## is the difference between a planet of towns and a planet of draw calls.
func _draw() -> void:
	if _render == null or _render.multimesh == null:
		return
	var batch := _render.multimesh
	if batch.instance_count < _local.size():
		batch.instance_count = _local.size()
	var lift := stats.body_radius + FLOOR_CLEARANCE
	var draw_range := DRAW_RANGE * DRAW_RANGE
	var graded := _near_squared.size() == _local.size()
	var shown := 0
	for index in _local.size():
		if not _visible(index) or _detail[index] == Detail.COLD:
			continue
		if graded and _near_squared[index] > draw_range:
			continue
		var at := _local[index]
		var direction := site.direction_at(at)
		var up := direction
		var forward := site.east * _heading[index].x \
			+ site.north * _heading[index].y
		forward = forward - up * forward.dot(up)
		if forward.length_squared() < 0.0001:
			forward = site.north - up * site.north.dot(up)
		forward = forward.normalized()
		# -Z down the heading, which is the way a model is authored to face, so the
		# sphere standing in for a Meep can be replaced without touching this.
		batch.set_instance_transform(shown, Transform3D(
			Basis(forward.cross(up), up, -forward),
			direction * (site.planet_radius + _height[index] + lift)))
		shown += 1
	batch.visible_instance_count = shown


## Hands the pool to the nearest Meeps. Same idea as the light pool in
## [FaunaSpawner]: a fixed number of real objects, given to whoever is close enough
## for them to matter this frame.
func _lend_proxies() -> void:
	if _proxies.is_empty():
		return
	var reach := PROXY_RANGE * PROXY_RANGE
	var nearby: Array[Vector2i] = []
	for index in _local.size():
		if not _visible(index) or _detail[index] != Detail.HOT:
			continue
		# Against this peer's own camera, not the nearest player anywhere: a proxy
		# is only ever wanted for the person who might point at it.
		var away := _local[index].distance_squared_to(_view_eye)
		if away <= reach:
			# Distance in millimetres as an integer key, so the sort is on a plain
			# vector rather than through a comparator closure per pair.
			nearby.push_back(Vector2i(roundi(away * 1000.0), index))
	nearby.sort()
	var lift := stats.body_radius + FLOOR_CLEARANCE
	for slot in _proxies.size():
		var proxy := _proxies[slot]
		if slot >= nearby.size():
			proxy.set_lent(-1)
			continue
		var index := nearby[slot].y
		proxy.set_lent(index)
		proxy.position = site.point_at(_local[index], _height[index] + lift)


# --- Being pointed at --------------------------------------------------------

## The live one-line report the prompt plate shows over a Meep.
func meep_summary(index: int) -> String:
	if index < 0 or index >= _local.size():
		return "Meep"
	var doing := "Idle"
	var job := tasks.job(_job[index])
	match _state[index] as State:
		State.WALK:
			doing = _errand(job) if job != null else "Walking"
		State.WORK:
			doing = _at_work(job) if job != null else "Working"
		State.INSIDE:
			doing = "In the cloner"
		State.FLEE:
			doing = "Fleeing"
		State.DEAD:
			doing = "Dead"
		_:
			doing = "Idle"
	return "Meep - %s - %d/%d" % [doing, roundi(_health[index]),
		roundi(stats.maximum_health)]


## Where a Meep is going, in the words a player reading the prompt plate would use.
func _errand(job: MeepTasks.Job) -> String:
	match job.kind:
		MeepTasks.Kind.MINE:
			return "Off to fell a tree"
		MeepTasks.Kind.BUILD:
			return "Off to the site"
		MeepTasks.Kind.CLONE:
			return "Off to the cloner"
		_:
			return "Walking"


func _at_work(job: MeepTasks.Job) -> String:
	match job.kind:
		MeepTasks.Kind.MINE:
			return "Chopping"
		MeepTasks.Kind.BUILD:
			return "Building"
		MeepTasks.Kind.CLONE:
			return "Waiting at the cloner"
		_:
			return "Working"


func inspect(index: int, player: Node) -> void:
	meep_inspected.emit(index, player)


func meep_position(index: int) -> Vector3:
	if index < 0 or index >= _local.size() or _planet == null:
		return Vector3.ZERO
	return _planet.to_global(site.point_at(_local[index],
		_height[index] + stats.body_radius + FLOOR_CLEARANCE))


func meep_health(index: int) -> float:
	return _health[index] if index >= 0 and index < _health.size() else 0.0


func meep_state(index: int) -> State:
	if index < 0 or index >= _state.size():
		return State.DEAD
	return _state[index] as State


func meep_local(index: int) -> Vector2:
	return _local[index] if index >= 0 and index < _local.size() else Vector2.ZERO


## The ground height a Meep is standing at, as the colony believes it.
func meep_height(index: int) -> float:
	return _height[index] if index >= 0 and index < _height.size() else 0.0


## The ground height anywhere on the site map, read from the field at the spacing
## the terrain is being drawn at. What [method meep_height] is checked against.
func ground_height_at(local: Vector2) -> float:
	if _shape == null or site == null:
		return 0.0
	return _shape.elevation(site.direction_at(local), _spacing_drawn())


## Advances the colony by hand. The tick is driven by the physics step in play; this
## is for the harness, which has to run minutes of town life in a second and cannot
## wait for the clock to do it.
func step_simulation(seconds: float) -> void:
	if _is_host():
		_simulate(maxf(seconds, 0.0))


# --- Damage ------------------------------------------------------------------

## The colony answers for everyone in it.
##
## [method DamageHit.apply_to_combatants] does not test geometry — it filters by
## faction and hands the volume over — so one node in the group can stand for a
## whole population and sort out who was actually in the blast itself. This is the
## same arrangement [GroundCover] uses to take a hit on behalf of three hundred
## thousand plants.
func apply_damage(hit: DamageHit) -> float:
	if hit == null or not _is_host() or _planet == null:
		return 0.0
	# Meeps are on the player's side, so what can hurt them is what hurts players.
	if hit.faction != DamageHit.Faction.ENEMY:
		return 0.0
	var dealt := 0.0
	var lift := stats.body_radius + FLOOR_CLEARANCE
	for index in _local.size():
		# Whoever is in the cloner is not anywhere to be shot at.
		if not _visible(index):
			continue
		var at := _planet.to_global(site.point_at(_local[index],
			_height[index] + lift))
		if not hit.reaches(at, stats.body_radius):
			continue
		# Falloff resolved per Meep rather than once for the colony, which is why
		# combat_radius reports the whole town: it stops the shared copy of the hit
		# being scaled down against a centre nobody was standing at.
		var amount := minf(maxf(hit.damage_at(at), 0.0), _health[index])
		if amount <= 0.0:
			continue
		_health[index] -= amount
		dealt += amount
		if _health[index] <= 0.0:
			_kill(index)
			continue
		# Being hit is how a colony learns anything. Running is all it does with
		# that in this build; the mobs pass is what marks the ground dangerous.
		_state[index] = State.FLEE
		_timer[index] = 4.0
		_goal[index] = _local[index] + (_local[index] - _site_local_of(
			hit.origin)).normalized() * 24.0
		_since[index] = HOT_INTERVAL
	if dealt > 0.0:
		_flush_deaths()
	return dealt


func _kill(index: int) -> void:
	_state[index] = State.DEAD
	_health[index] = 0.0
	_alive = maxi(_alive - 1, 0)
	if _job[index] != 0:
		tasks.release(_job[index])
		_job[index] = 0
	_deaths.push_back(index)
	meep_died.emit(index)


func combat_faction() -> int:
	return DamageHit.Faction.PLAYER


func combat_peer_id() -> int:
	return 0


func combat_display_name() -> String:
	return "Meep"


## Standing height at the middle of the town.
##
## Above the ground and not at sea level, which is what the site map's own zero is:
## a town a hundred metres up a hillside would otherwise report a centre a hundred
## metres inside the rock, and [method DamageHit.affects_combatant] measures its
## volume against this point. A hit that blocks on the world casts at it too, so a
## buried centre would put the whole colony permanently behind cover.
func combat_position() -> Vector3:
	if _planet == null or site == null:
		return global_position
	return _planet.to_global(site.point_at(Vector2.ZERO,
		_centre_height + COMBAT_LIFT))


## The whole town, not one Meep. See the note in [method apply_damage].
##
## With margin, because this is the test that decides whether the colony is offered
## the hit at all: a Meep working up a slope at the edge of the claim is further from
## the middle than the claim is wide, and one that has walked out to mine is further
## still. Being offered a hit that turns out to reach nobody costs one pass over the
## population; not being offered one that did is a Meep that cannot be shot.
func combat_radius() -> float:
	return claim_radius + COMBAT_MARGIN


# --- Reporting ---------------------------------------------------------------

## What the city panel shows.
func report() -> Dictionary:
	return {
		"founded": true,
		"settlers": _alive,
		"resources": resources,
		"committed": committed,
		"claimed_cells": claim.count if claim != null else 0,
		"claimed_area": claim.area() if claim != null else 0.0,
		"wall_segments": _wall.segment_count() if _wall != null else 0,
		"ground_ready": _ground_ready,
		"structures": structures.built_count() if structures != null else 0,
		"raising": structures.count() - structures.built_count() \
			if structures != null else 0,
		"cloners": structures.count_of(MeepStructures.Kind.CLONER, true) \
			if structures != null else 0,
		"timber": standing_timber(),
		"doing": _busiest(),
	}


## Trees left standing that the colony still means to cut.
func standing_timber() -> int:
	var left := 0
	for tree in _timber:
		if tree.w > 0.0:
			left += 1
	return left


## What most of the town is up to, for the one line in the panel that says so. Read off
## the job board rather than the population, because the board is what the answer is
## about: a Meep walking to a tree and a Meep chopping it are both mining.
func _busiest() -> String:
	if structures != null and structures.count() > structures.built_count():
		return "Building"
	if tasks.count_of(MeepTasks.Kind.MINE) > 0:
		return "Harvesting"
	if tasks.count_of(MeepTasks.Kind.CLONE) > 0:
		return "Cloning"
	if _timber.is_empty() or standing_timber() == 0:
		return "Out of timber"
	return "Settling in"


# --- Replication -------------------------------------------------------------

func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


## Sends where the Meeps are, ten times a second, for the ones anybody is near.
##
## Positions only. The ground under them, the boundary around them and the wall on
## it are all worked out from the same height field on every peer, so what has to
## travel is the part that is genuinely a decision: which way somebody walked. A
## COLD Meep is out of everyone's sight by definition and is left out entirely.
func _publish() -> void:
	if not multiplayer.has_multiplayer_peer() \
			or multiplayer.get_peers().is_empty():
		return
	if _town_changed:
		_town_changed = false
		if structures != null:
			_apply_town.rpc(structures.snapshot())
	var indices := PackedInt32Array()
	var locals := PackedVector2Array()
	var health := PackedByteArray()
	var states := PackedByteArray()
	for index in _local.size():
		if _state[index] == State.DEAD or _detail[index] == Detail.COLD:
			continue
		indices.push_back(index)
		locals.push_back(_local[index])
		health.push_back(clampi(roundi(
			_health[index] / stats.maximum_health * 255.0), 0, 255))
		states.push_back(_state[index])
		if indices.size() >= PUBLISH_LIMIT:
			break
	# A town with something going up keeps sending even when there is nobody in sight to
	# send: the building is what a client is watching, and it is the one thing here that
	# moves without a Meep near it.
	if indices.is_empty() and not _raising():
		return
	# The population, the bank and the scaffolding ride along rather than being asked
	# for. All three are on the city panel, the packet is already going, and a client
	# that had to request them would show a stale number every time it opened it.
	_apply_state.rpc(indices, locals, health, states, _alive, resources,
		structures.progress_snapshot() if structures != null
		else PackedFloat32Array())


## Whether anything is half-built.
func _raising() -> bool:
	return structures != null and structures.built_count() < structures.count()


func _flush_deaths() -> void:
	if _deaths.is_empty():
		return
	if multiplayer.has_multiplayer_peer() \
			and not multiplayer.get_peers().is_empty():
		_apply_deaths.rpc(_deaths.duplicate())
	_deaths.clear()


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_state(indices: PackedInt32Array, locals: PackedVector2Array,
		health: PackedByteArray, states: PackedByteArray, alive: int, bank: float,
		raised: PackedFloat32Array) -> void:
	if _is_host():
		return
	for slot in indices.size():
		var index := indices[slot]
		# A position can arrive before the release that explains it, and rows have
		# to keep their indices to stay addressable. Pad rather than drop.
		while _local.size() <= index:
			var padded := _add(locals[slot], index)
			_state[padded] = State.DEAD
			_alive = maxi(_alive - 1, 0)
		if _state[index] == State.DEAD:
			# Newly known here — a clone, or somebody who was too far away to be in
			# the last packet. Put down where the host says rather than walked there
			# from wherever this row was last used.
			_local[index] = locals[slot]
		_state[index] = states[slot]
		_target[index] = locals[slot]
		_health[index] = float(health[slot]) / 255.0 * stats.maximum_health
	# The host's count, not one derived from the rows here: distant Meeps are left
	# out of the packet entirely and would otherwise go missing from the panel.
	_alive = alive
	resources = bank
	if structures != null:
		structures.apply_progress(raised)


## What stands where. Reliable and whole rather than incremental: a town is a handful of
## kinds and corners, so sending all of it is cheaper than the bookkeeping to send the
## difference, and a client that missed one packet is not left with a gap in its town.
@rpc("authority", "call_remote", "reliable")
func _apply_town(state: PackedInt32Array) -> void:
	if _is_host() or structures == null:
		return
	structures.apply_snapshot(state)


@rpc("authority", "call_remote", "reliable")
func _apply_deaths(indices: PackedInt32Array) -> void:
	if _is_host():
		return
	for index in indices:
		if index >= 0 and index < _state.size() \
				and _state[index] != State.DEAD:
			_kill(index)


## A client's whole simulation: walk each Meep towards where the host last said it
## was. Cheap, and it hides the ten-hertz packets without predicting anything that
## could be wrong.
func _follow(delta: float) -> void:
	if _local.is_empty():
		return
	var closing := clampf(delta * FOLLOW_RATE, 0.0, 1.0)
	for index in _local.size():
		if not _visible(index):
			continue
		var was := _local[index]
		var now := was.lerp(_target[index], closing)
		var moved := now - was
		if moved.length_squared() > 0.000001:
			_heading[index] = moved.normalized()
		_local[index] = now
		if _ground_ready:
			_height[index] = grid.height_at(grid.cell_of(now))
