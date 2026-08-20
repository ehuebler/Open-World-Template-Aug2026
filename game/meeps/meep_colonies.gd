class_name MeepColonies
extends Node3D

signal regional_context_changed(revision: int)

## Every Meep settlement on the planet, and the only thing that founds one.
##
## Plural from the first colony on purpose. The eventual game is a world of towns
## that spread, and a single hard-wired settlement would have to be dismantled to
## get there; a registry that happens to hold one entry does not. It sits under
## [Planet] beside [FaunaSpawner] for the same reason that does: it is a population
## of things standing on the ground, and the ground is what places them.
##
## It also owns the network path. Colonies are created at runtime, so their nodes
## are named after their site rather than counted, which is what lets a colony's own
## state packets find the same node on every peer. What travels is only the founding
## facts and where the Meeps are; the ground each colony was measured against is the
## same height field everywhere, so every peer bakes its own grid, fills its own
## claim and raises its own wall.

## Shared settler numbers. One resource for every colony until there is a reason
## for more than one kind of Meep.
@export var stats: MeepStats
## Metres a new colony reaches for. What it gets is whatever the terrain allows;
## see [MeepClaim].
@export var claim_radius := MeepClaim.DEFAULT_RADIUS
## Settlers in the first wave out of a ship.
@export var first_wave := MeepColony.FIRST_WAVE
## Left empty it uses the nearest [Planet] ancestor, which is where this belongs.
@export var planet: Planet

const SETTLEMENT_CLAIM_RADIUS := 70.0
const SETTLEMENT_CLEARANCE := 150.0
const LANDING_HALF_SIZE := Vector2(9.0, 5.0)
const LANDING_LEVEL_TOLERANCE := 1.25

## Metres from the nearest player at which a ledger city becomes a full
## [MeepColony], and at which one stops being one.
##
## Both are well outside anything the colony itself reacts to — [constant
## MeepColony.WARM_RANGE] is 400 m and its draw range 260 m — so a city is always
## resident for some distance before there is anything to see, and the gap between
## the two is what stops a player pacing a boundary from founding and freeing the
## same town every few seconds.
const REIFY_RANGE := 700.0
const DISTILL_RANGE := 900.0
## Full agent simulations allowed at once, nearest first. A resident colony is
## around 600 KiB of navigation grid before anybody lives in it, so this is the
## memory ceiling as much as the frame budget.
const RESIDENT_LIMIT := 6
## Seconds between residency reviews. The decision is about hundreds of metres; a
## sprinting player covers about ten in this.
const REVIEW_INTERVAL := 0.5
## Residency changes one review will make. A city coming back rebuilds its grid,
## streets and population in a single tick, and a city leaving frees that whole node
## tree at the end of the frame. Walking towards a cluster used to do three of each at
## once — 127 ms of arrival in one frame, and the node frees behind it. The gap
## between [constant REIFY_RANGE] and where a colony reacts is hundreds of metres, so
## bringing them back one review apart is not something the player can see.
const RESIDENCY_CHANGES_PER_REVIEW := 1
## Buildings a returning player watches find their plots per frame. The placement
## planner is a ring search over the claim, and a city that grew for ten minutes can
## owe a dozen, which is a visible hitch if they all land at once.
const REPLAY_PER_FRAME := 1
## Seconds before a plot that would not fit is offered again. Only the border growing
## or a neighbouring plot finishing changes the answer, and neither happens in a frame.
const REPLAY_RETRY_SECONDS := 1.0
## Seconds between ledger ticks.
##
## Not every frame, which is what this was and what the arithmetic can afford. But a
## ledger integrates rates, so the interval it is handed makes no difference to where
## it ends up, and nothing reads a ledger faster than the city panel and score do —
## twice a second, on the review's own cadence. Sixty times a second was fifty cities'
## worth of dictionary writes to produce a number nobody would look at until the
## thirtieth of them.
const LEDGER_INTERVAL := 0.5
const REGION_CLUSTER_REACH := MeepColony.MAX_CLAIM_RADIUS * 2.0 + 16.0
const REGION_AUDIT_INTERVAL := 30.0
const REGION_ERROR_THRESHOLD := 0.25
const REGION_ERROR_PERSIST_SECONDS := 120.0
const REGION_REPLAN_COOLDOWN := 300.0
const REGION_TERRAIN_MIN_ARC := 4.0
const REGION_TERRAIN_MIN_DROP := 0.5
const REGION_MARGIN := 20.0
const REGION_PROJECTION_TILE_CELLS := 12

var _colonies: Dictionary = {}
var _expeditions: Dictionary = {}
var _landed_handled: Dictionary = {}
## Site to [MeepCityLedger] for every city that is not currently a colony. The
## population in here is as real as the population walking about; see
## [MeepCityLedger].
var _ledgers: Dictionary = {}
## Site to the per-kind counts still waiting for a plot, filled by [method reify].
var _replaying: Dictionary = {}
## Site to seconds before the next attempt, for the ones that would not fit.
var _replay_wait: Dictionary = {}
var _review_left := 0.0
var _ledger_left := 0.0
## The one batch that draws every ledger city. See [MeepDistantCities].
var _distant: MeepDistantCities
var _region_plans: Dictionary = {}
var _region_frames: Dictionary = {}
var _site_regions: Dictionary = {}
var _region_projection_cache: Dictionary = {}
var _forecast_rows: Dictionary = {}
var _region_task := -1
var _region_worker_output: Array = []
var _regions_dirty := false
var _regions_urgent := false
var _terrain_revision := 0
## Monotonic, local read-only invalidation token for planning overlays. It is not
## serialized or networked: every peer advances it when the real regional inputs
## visible on that peer change.
var _regional_context_revision := 0
var _region_clock := 0.0
var _region_audit_left := REGION_AUDIT_INTERVAL
var _next_region_replan_at := 0.0
var _border_walls: MeepBorderWalls
## Stable regional seam record -> canonical shared-wall contract.
var _wall_seam_links: Dictionary = {}


func _ready() -> void:
	if planet == null:
		planet = _planet_host()
	if stats == null:
		stats = MeepStats.new()
	_distant = MeepDistantCities.new()
	_distant.planet = planet
	add_child(_distant)
	_border_walls = MeepBorderWalls.new()
	add_child(_border_walls)


func _exit_tree() -> void:
	if _region_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_region_task)
		_region_task = -1


func _process(delta: float) -> void:
	if not RuntimeTelemetry.deep_enabled():
		_advance(delta)
		return
	var began := Time.get_ticks_usec()
	_advance(delta)
	RuntimeTelemetry.record_process_step(
		&"meeps", &"colonies_process", Time.get_ticks_usec() - began)


func _advance(delta: float) -> void:
	_region_clock += maxf(delta, 0.0)
	_advance_regions(delta)
	for site_variant: Variant in _expeditions:
		var child: StringName = site_variant
		var lander := _expeditions[child] as SettlementShip
		if lander == null:
			continue
		var host := _is_host()
		if lander.advance(delta, host) and host:
			_land_expedition(child)
	if _is_host():
		_ledger_left -= delta
		if _ledger_left <= 0.0:
			var span := LEDGER_INTERVAL - _ledger_left
			_ledger_left = LEDGER_INTERVAL
			for ledger: MeepCityLedger in _ledgers.values():
				ledger.advance(span)
			_advance_ledger_walls(span)
	_advance_replays(delta)
	_review_left -= delta
	if _review_left <= 0.0:
		_review_left = REVIEW_INTERVAL
		_review_residency()
		# On the review's cadence rather than the frame's: a ledger city's massing
		# only changes when it finishes a building, and it takes a town minutes to
		# do that.
		if _distant != null:
			_distant.refresh(ledgers())


# --- Regional planning -------------------------------------------------------

func _advance_regions(delta: float) -> void:
	if _region_task >= 0 and WorkerThreadPool.is_task_completed(_region_task):
		WorkerThreadPool.wait_for_task_completion(_region_task)
		_region_task = -1
		_apply_region_worker_output(_region_worker_output)
		_region_worker_output = []
	if not _is_host():
		return
	_region_audit_left -= maxf(delta, 0.0)
	if _region_audit_left <= 0.0:
		_region_audit_left = REGION_AUDIT_INTERVAL
		_audit_region_forecasts()
	if not _regions_dirty or _region_task >= 0 \
			or (not _regions_urgent and _region_clock < _next_region_replan_at) \
			or not _regional_inputs_ready():
		return
	var facts := _regional_city_facts()
	var shape := planet.shape if planet != null else null
	if shape == null:
		return
	var spacing := planet.finest_spacing()
	var revision := _terrain_revision
	_regions_dirty = false
	_regions_urgent = false
	_region_worker_output = []
	_region_task = WorkerThreadPool.add_task(
		_solve_region_worker.bind(facts, shape, spacing, revision))


func _regional_inputs_ready() -> bool:
	for here in colonies():
		if here.site == null or not here.ground_ready():
			return false
	return true


func _queue_region_replan(urgent := false) -> void:
	_regions_dirty = true
	_regions_urgent = _regions_urgent or urgent
	_touch_regional_context()


func _touch_regional_context() -> void:
	_regional_context_revision += 1
	regional_context_changed.emit(_regional_context_revision)


## Read-only invalidation token used by local planning tools. Blueprint previews
## compare this rather than copying the registry's private plan dictionaries.
func regional_context_revision() -> int:
	return _regional_context_revision


func region_replan_pending() -> bool:
	return _regions_dirty or _region_task >= 0


func region_replan_due() -> bool:
	return _regions_dirty and (
		_regions_urgent or _region_clock >= _next_region_replan_at)


func city_growth_contract_changed(_site: StringName) -> void:
	_queue_region_replan(true)


func terrain_deformed(direction: Vector3, arc: float, drop: float) -> void:
	if planet == null or planet.shape == null or not direction.is_finite():
		return
	var centre := direction.normalized()
	var affected := false
	for here in colonies():
		if here.site != null and _surface_distance(
				centre, here.site.centre) <= arc + MeepColony.MAX_CLAIM_RADIUS:
			here.reground()
			affected = true
	for compact in ledgers():
		if _surface_distance(centre, compact.direction) \
				<= arc + MeepColony.MAX_CLAIM_RADIUS:
			affected = true
	_terrain_revision += 1
	if affected and arc >= REGION_TERRAIN_MIN_ARC \
			and absf(drop) >= REGION_TERRAIN_MIN_DROP:
		_queue_region_replan(false)


## The observed Meep growth term currently used by regional prediction, in Meeps
## per second. Unknown hypothetical sites deliberately receive the same cold-start
## value as a newly founded real city without adding a row to the real registry.
func regional_population_growth(site_id: StringName,
		_population_override := -1) -> float:
	var row_value: Variant = _forecast_rows.get(site_id, {})
	if row_value is Dictionary and not (row_value as Dictionary).is_empty():
		return maxf(float((row_value as Dictionary).get(
			"forecast_growth", 0.05)), 0.0)
	return 0.05


## Exact scalar handed to MeepRegionPlan. Keeping the composition here makes local
## blueprints follow forecast-model changes instead of carrying a stale copy.
func regional_forecast_rate(site_id: StringName,
		population_override := -1) -> float:
	var population := maxi(population_override, 0)
	var expansion := MeepColony.EXPANSION_BASE_RATE \
		+ MeepColony.population_expansion_bonus(population)
	var here := colony(site_id)
	var compact := ledger(site_id)
	if population_override < 0:
		if here != null:
			population = here.alive_count()
			expansion = here.expansion_rate()
		elif compact != null:
			population = compact.alive
			expansion = compact.expansion_rate()
	return maxf(expansion + regional_population_growth(
		site_id, population) * 0.2, 0.01)


## A defensive copy of the production facts. Callers may append hypothetical
## cities and run a private solve, but cannot mutate real forecasts or anchors.
func regional_city_facts() -> Array:
	var out: Array = []
	for fact_variant: Variant in _regional_city_facts():
		if fact_variant is Dictionary:
			out.push_back((fact_variant as Dictionary).duplicate(true))
	return out


## Cheap centre-only view for a placement reticle that runs every frame. Regional
## facts include every developed cell and are intentionally reserved for rebuilds.
func founded_city_centres() -> PackedVector3Array:
	var out := PackedVector3Array()
	for site_text in _founded_site_ids():
		var site_id := StringName(site_text)
		var here := colony(site_id)
		var compact := ledger(site_id)
		if here != null and here.site != null:
			out.push_back(here.site.centre)
		elif compact != null:
			out.push_back(compact.direction.normalized())
	return out


func _regional_city_facts() -> Array:
	var facts: Array = []
	for site_text in _founded_site_ids():
		var site_id := StringName(site_text)
		var here := colony(site_id)
		var compact := ledger(site_id)
		var direction := Vector3.UP
		var facing := 0.0
		var seed := 0
		var population := 0
		var expansion := MeepColony.EXPANSION_BASE_RATE
		var protected := PackedVector3Array()
		if here != null and here.site != null:
			direction = here.site.centre
			facing = here.site.facing
			seed = here.founded_seed
			population = here.alive_count()
			expansion = here.expansion_rate()
			if here.claim != null and here.grid != null:
				for cell_index in here.claim.claimed_cells():
					var cell := Vector2i(cell_index % here.grid.cells,
						cell_index / here.grid.cells)
					protected.push_back(here.site.direction_at(
						here.grid.centre_of(cell)))
		elif compact != null:
			direction = compact.direction
			facing = compact.facing
			seed = compact.founded_seed
			population = compact.alive
			expansion = compact.expansion_rate()
			var compact_site := MeepSite.new(direction,
				planet.shape.radius, facing, MeepColony.MAX_CLAIM_RADIUS)
			protected.push_back(direction.normalized())
			for offset in range(0, compact.structures.size(), 3):
				var kind := compact.structures[offset]
				if kind < 0 or kind >= MeepStructures.Kind.size():
					continue
				var corner := Vector2i(compact.structures[offset + 1],
					compact.structures[offset + 2])
				var span := MeepStructures.plan_of(kind).span
				var local := _standard_grid_centre(corner) \
					+ Vector2(span - Vector2i.ONE) * MeepGrid.CELL * 0.5
				protected.push_back(compact_site.direction_at(local))
			var roads_value: Variant = compact.physical.get(
				"roads", PackedInt32Array())
			if roads_value is PackedInt32Array:
				for cell_index in roads_value as PackedInt32Array:
					var cell := Vector2i(cell_index % MeepGrid.CELLS,
						cell_index / MeepGrid.CELLS)
					protected.push_back(compact_site.direction_at(
						_standard_grid_centre(cell)))
		_forecast_row(site_id, population)
		facts.push_back({
			"site": String(site_id),
			"direction": direction.normalized(),
			"facing": facing,
			"seed": seed,
			"population": population,
			"forecast_rate": regional_forecast_rate(site_id, population),
			"protected_directions": protected,
		})
	return facts


static func _standard_grid_centre(cell: Vector2i) -> Vector2:
	var half := float(MeepGrid.CELLS) * MeepGrid.CELL * 0.5
	return Vector2(
		(float(cell.x) + 0.5) * MeepGrid.CELL - half,
		(float(cell.y) + 0.5) * MeepGrid.CELL - half)


func _solve_region_worker(facts: Array, shape: PlanetShape,
		spacing: float, terrain_revision: int) -> void:
	_region_worker_output = solve_region_facts(
		facts, shape, spacing, terrain_revision)


## Pure worker-safe regional solve shared by production and local hypothetical
## city overlays. The returned wrappers are snapshots; applying them remains the
## caller's explicit responsibility.
static func solve_region_facts(facts: Array, shape: PlanetShape,
		spacing: float, terrain_revision: int) -> Array:
	var output: Array = []
	if shape == null:
		return output
	var radius := shape.radius
	var visited: Dictionary = {}
	for start in facts.size():
		if visited.has(start):
			continue
		var component := PackedInt32Array([start])
		visited[start] = true
		var cursor := 0
		while cursor < component.size():
			var at := component[cursor]
			cursor += 1
			var a: Vector3 = facts[at].get("direction", Vector3.UP)
			for other in facts.size():
				if visited.has(other):
					continue
				var b: Vector3 = facts[other].get("direction", Vector3.UP)
				var distance := acos(clampf(a.dot(b), -1.0, 1.0)) * radius
				if distance <= REGION_CLUSTER_REACH:
					visited[other] = true
					component.push_back(other)
		if component.size() < 2:
			continue
		var members: Array = []
		var frame_direction := Vector3.ZERO
		for index in component:
			var fact := facts[index] as Dictionary
			members.push_back(fact)
			frame_direction += fact.get("direction", Vector3.UP) as Vector3
		if frame_direction.length_squared() < 0.5:
			frame_direction = members[0].get("direction", Vector3.UP)
		frame_direction = frame_direction.normalized()
		var frame := MeepSite.new(frame_direction, radius, 0.0,
			REGION_CLUSTER_REACH + MeepColony.MAX_CLAIM_RADIUS)
		var minimum := Vector2(INF, INF)
		var maximum := Vector2(-INF, -INF)
		for fact in members:
			var local := frame.to_local(
				(fact as Dictionary).get("direction", Vector3.UP))
			minimum.x = minf(minimum.x, local.x)
			minimum.y = minf(minimum.y, local.y)
			maximum.x = maxf(maximum.x, local.x)
			maximum.y = maxf(maximum.y, local.y)
		var pad := MeepColony.MAX_CLAIM_RADIUS + REGION_MARGIN
		minimum -= Vector2.ONE * pad
		maximum += Vector2.ONE * pad
		var origin := Vector2(
			floor(minimum.x / MeepRegionPlan.CELL_SIZE),
			floor(minimum.y / MeepRegionPlan.CELL_SIZE)) \
			* MeepRegionPlan.CELL_SIZE
		var dimensions := Vector2i(
			maxi(ceili((maximum.x - origin.x)
				/ MeepRegionPlan.CELL_SIZE), 8),
			maxi(ceili((maximum.y - origin.y)
				/ MeepRegionPlan.CELL_SIZE), 8))
		var terrain := _sample_region_terrain(
			frame, origin, dimensions, shape, spacing)
		var cities: Array = []
		var member_ids := PackedStringArray()
		for fact_variant in members:
			var fact := fact_variant as Dictionary
			var site := String(fact.get("site", ""))
			member_ids.push_back(site)
			var protected_local := PackedVector2Array()
			var protected_value: Variant = fact.get(
				"protected_directions", PackedVector3Array())
			if protected_value is PackedVector3Array:
				for protected_direction in protected_value as PackedVector3Array:
					protected_local.push_back(
						frame.to_local(protected_direction))
			cities.push_back({
				"site": site,
				"local_centre": frame.to_local(
					fact.get("direction", Vector3.UP)),
				"forecast_rate": float(fact.get("forecast_rate", 0.01)),
				"seed": int(fact.get("seed", 0)),
				"protected_local": protected_local,
			})
		member_ids.sort()
		var region_id := StringName("region_%s" % (
			"|".join(member_ids).sha256_text().left(12)))
		var plan := MeepRegionPlan.new()
		if not plan.solve(origin, dimensions, terrain, cities,
				MeepRegionPlan.DEFAULT_SETBACK_METRES,
				MeepRegionPlan.DEFAULT_GATE_WIDTH_METRES,
				terrain_revision):
			continue
		var projections: Dictionary = {}
		var owner_values := plan.owner_map()
		for fact_variant in members:
			var fact := fact_variant as Dictionary
			var site_name := String(fact.get("site", ""))
			var city_site := MeepSite.new(
				fact.get("direction", Vector3.UP), radius,
				float(fact.get("facing", 0.0)),
				MeepColony.MAX_CLAIM_RADIUS)
			projections[site_name] = _worker_region_projection(
				frame, city_site, plan, plan.site_index(site_name),
				owner_values, plan.setback_mask(site_name))
		output.push_back({
			"id": String(region_id),
			"frame_direction": frame_direction,
			"snapshot": plan.snapshot(),
			"projections": projections,
		})
	return output


static func _worker_region_projection(frame: MeepSite,
		city_site: MeepSite, plan: MeepRegionPlan, wanted: int,
		owners: PackedInt32Array,
		regional_setback: PackedByteArray) -> Dictionary:
	var side := MeepGrid.CELLS
	var coordinates := PackedInt32Array()
	var cursor := 0
	while cursor < side:
		coordinates.push_back(cursor)
		cursor += REGION_PROJECTION_TILE_CELLS
	if coordinates.is_empty() or coordinates[-1] != side - 1:
		coordinates.push_back(side - 1)
	var sample_side := coordinates.size()
	var samples := PackedVector2Array()
	samples.resize(sample_side * sample_side)
	for sample_y in sample_side:
		for sample_x in sample_side:
			var cell := Vector2i(
				coordinates[sample_x], coordinates[sample_y])
			samples[sample_y * sample_side + sample_x] = frame.to_local(
				city_site.direction_at(_standard_grid_centre(cell)))
	var owner := PackedByteArray()
	var setback := PackedByteArray()
	owner.resize(side * side)
	setback.resize(side * side)
	var region_origin := plan.origin()
	var region_dimensions := plan.dimensions()
	for tile_y in sample_side - 1:
		var y0 := coordinates[tile_y]
		var y1 := coordinates[tile_y + 1]
		var y_after := y1 + 1 if tile_y == sample_side - 2 else y1
		for tile_x in sample_side - 1:
			var x0 := coordinates[tile_x]
			var x1 := coordinates[tile_x + 1]
			var x_after := x1 + 1 if tile_x == sample_side - 2 else x1
			var p00 := samples[tile_y * sample_side + tile_x]
			var p10 := samples[tile_y * sample_side + tile_x + 1]
			var p01 := samples[(tile_y + 1) * sample_side + tile_x]
			var p11 := samples[(tile_y + 1) * sample_side + tile_x + 1]
			for y in range(y0, y_after):
				var v := float(y - y0) / float(maxi(y1 - y0, 1))
				var left := p00.lerp(p01, v)
				var right := p10.lerp(p11, v)
				for x in range(x0, x_after):
					var u := float(x - x0) / float(maxi(x1 - x0, 1))
					var regional := left.lerp(right, u)
					var source_x := floori((regional.x - region_origin.x)
						/ MeepRegionPlan.CELL_SIZE)
					var source_y := floori((regional.y - region_origin.y)
						/ MeepRegionPlan.CELL_SIZE)
					if source_x < 0 or source_y < 0 \
							or source_x >= region_dimensions.x \
							or source_y >= region_dimensions.y:
						continue
					var source := source_y * region_dimensions.x + source_x
					var target := y * side + x
					if source < owners.size() and owners[source] == wanted:
						owner[target] = 1
					if source < regional_setback.size() \
							and regional_setback[source] != 0:
						setback[target] = 1
	return {
		"owner": owner,
		"setback": setback,
	}


static func _sample_region_terrain(frame: MeepSite, origin: Vector2,
		dimensions: Vector2i, shape: PlanetShape,
		spacing: float) -> PackedByteArray:
	var costs := PackedByteArray()
	costs.resize(dimensions.x * dimensions.y)
	var slope_limit := tan(deg_to_rad(MeepGrid.MAX_SLOPE_DEGREES))
	for y in dimensions.y:
		for x in dimensions.x:
			var at := y * dimensions.x + x
			var local := origin + (Vector2(x, y)
				+ Vector2(0.5, 0.5)) * MeepRegionPlan.CELL_SIZE
			var direction := frame.direction_at(local)
			var height := shape.elevation(direction, spacing)
			if height < -MeepGrid.SHALLOW_DEPTH:
				costs[at] = MeepRegionPlan.TERRAIN_BLOCKED
				continue
			if height < MeepGrid.SHORE_MARGIN:
				costs[at] = 10
				continue
			var rise := 0.0
			var drop := 0.0
			for offset in [Vector2.RIGHT, Vector2.DOWN]:
				var neighbour := shape.elevation(
					frame.direction_at(local
						+ offset * MeepRegionPlan.CELL_SIZE), spacing)
				rise = maxf(rise, absf(neighbour - height)
					/ MeepRegionPlan.CELL_SIZE)
				drop = maxf(drop, absf(neighbour - height))
			if drop > MeepGrid.FALL_LIMIT:
				costs[at] = 20
			elif rise > slope_limit:
				costs[at] = 12
			else:
				costs[at] = 1
	return costs


func _apply_region_worker_output(output: Array,
		broadcast := true, preserve_revisions := false,
		define_walls := true) -> void:
	var old_plans := _region_plans
	_region_plans = {}
	_region_frames = {}
	_site_regions = {}
	_region_projection_cache = {}
	for wrapper_variant: Variant in output:
		if not wrapper_variant is Dictionary:
			continue
		var wrapper := wrapper_variant as Dictionary
		var id := StringName(wrapper.get("id", ""))
		var frame_direction: Vector3 = wrapper.get(
			"frame_direction", Vector3.UP)
		var snapshot_value: Variant = wrapper.get("snapshot", {})
		if id == &"" or not snapshot_value is Dictionary:
			continue
		var snapshot := (snapshot_value as Dictionary).duplicate(true)
		var previous := old_plans.get(id) as MeepRegionPlan
		if not preserve_revisions:
			snapshot["revision"] = (previous.revision() + 1) \
				if previous != null \
				else maxi(int(snapshot.get("revision", 1)), 1)
		var plan := MeepRegionPlan.new()
		if not plan.apply_snapshot(snapshot):
			continue
		_region_plans[id] = plan
		_region_frames[id] = MeepSite.new(frame_direction.normalized(),
			planet.shape.radius, 0.0, REGION_CLUSTER_REACH
				+ MeepColony.MAX_CLAIM_RADIUS)
		for site_text in plan.site_ids():
			_site_regions[StringName(site_text)] = id
		var projections_value: Variant = wrapper.get("projections", {})
		if projections_value is Dictionary:
			for site_variant: Variant in projections_value:
				var projection_value: Variant = (
					projections_value as Dictionary)[site_variant]
				if not projection_value is Dictionary:
					continue
				var projection := (
					projection_value as Dictionary).duplicate(true)
				projection["region"] = id
				projection["revision"] = plan.revision()
				_region_projection_cache[
					StringName(site_variant)] = projection
	if define_walls:
		_define_region_walls()
	for here in colonies():
		apply_region_to_colony(here)
	for compact in ledgers():
		_apply_region_to_ledger(compact)
	_next_region_replan_at = _region_clock + REGION_REPLAN_COOLDOWN
	if not preserve_revisions:
		_update_forecasts_after_plan()
	if broadcast and _is_host() and multiplayer.has_multiplayer_peer():
		_apply_region_registry_state.rpc(_region_registry_state())
	_touch_regional_context()


func apply_region_to_colony(here: MeepColony) -> void:
	if here == null or here.grid == null or here.site == null:
		return
	var id := StringName(_site_regions.get(here.site_id, &""))
	var plan := _region_plans.get(id) as MeepRegionPlan
	var frame := _region_frames.get(id) as MeepSite
	if plan == null or frame == null:
		here.bind_region_masks(
			PackedByteArray(), PackedByteArray(), &"", -1)
		return
	var total := here.grid.cells * here.grid.cells
	var wanted := plan.site_index(here.site_id)
	var owners := plan.owner_map()
	var regional_setback := plan.setback_mask(here.site_id)
	var projected_value: Variant = _region_projection_cache.get(
		here.site_id, {})
	var projected := projected_value as Dictionary \
		if projected_value is Dictionary else {}
	if StringName(projected.get("region", &"")) != id \
			or int(projected.get("revision", -1)) != plan.revision():
		projected = _project_region_masks(
			here, plan, frame, wanted, owners, regional_setback)
	var owner: PackedByteArray = projected.get(
		"owner", PackedByteArray())
	var setback: PackedByteArray = projected.get(
		"setback", PackedByteArray())
	if owner.size() != total:
		return
	here.bind_region_masks(owner, setback, id, plan.revision())


## Exact spherical projections are sampled at coarse tile corners; bilinear
## interpolation then classifies the 36,864 local cells. The neutral regional seam
## and legacy rival clip remain conservative guards, while apply cost stays well
## below doing two trigonometric maps per cell on the main thread.
func _project_region_masks(here: MeepColony, plan: MeepRegionPlan,
		frame: MeepSite, wanted: int, owners: PackedInt32Array,
		regional_setback: PackedByteArray) -> Dictionary:
	var side := here.grid.cells
	var coordinates := PackedInt32Array()
	var cursor := 0
	while cursor < side:
		coordinates.push_back(cursor)
		cursor += REGION_PROJECTION_TILE_CELLS
	if coordinates.is_empty() or coordinates[-1] != side - 1:
		coordinates.push_back(side - 1)
	var sample_side := coordinates.size()
	var samples := PackedVector2Array()
	samples.resize(sample_side * sample_side)
	for sample_y in sample_side:
		for sample_x in sample_side:
			var cell := Vector2i(
				coordinates[sample_x], coordinates[sample_y])
			samples[sample_y * sample_side + sample_x] = frame.to_local(
				here.site.direction_at(here.grid.centre_of(cell)))
	var owner := PackedByteArray()
	var setback := PackedByteArray()
	owner.resize(side * side)
	setback.resize(side * side)
	var origin := plan.origin()
	var dimensions := plan.dimensions()
	for tile_y in sample_side - 1:
		var y0 := coordinates[tile_y]
		var y1 := coordinates[tile_y + 1]
		var y_after := y1 + 1 if tile_y == sample_side - 2 else y1
		for tile_x in sample_side - 1:
			var x0 := coordinates[tile_x]
			var x1 := coordinates[tile_x + 1]
			var x_after := x1 + 1 if tile_x == sample_side - 2 else x1
			var p00 := samples[tile_y * sample_side + tile_x]
			var p10 := samples[tile_y * sample_side + tile_x + 1]
			var p01 := samples[(tile_y + 1) * sample_side + tile_x]
			var p11 := samples[(tile_y + 1) * sample_side + tile_x + 1]
			for y in range(y0, y_after):
				var v := float(y - y0) / float(maxi(y1 - y0, 1))
				var left := p00.lerp(p01, v)
				var right := p10.lerp(p11, v)
				for x in range(x0, x_after):
					var u := float(x - x0) / float(maxi(x1 - x0, 1))
					var regional := left.lerp(right, u)
					var source_x := floori((regional.x - origin.x)
						/ MeepRegionPlan.CELL_SIZE)
					var source_y := floori((regional.y - origin.y)
						/ MeepRegionPlan.CELL_SIZE)
					if source_x < 0 or source_y < 0 \
							or source_x >= dimensions.x \
							or source_y >= dimensions.y:
						continue
					var source := source_y * dimensions.x + source_x
					var target := y * side + x
					if source < owners.size() and owners[source] == wanted:
						owner[target] = 1
					if source < regional_setback.size() \
							and regional_setback[source] != 0:
						setback[target] = 1
	return {
		"owner": owner,
		"setback": setback,
	}


func _apply_region_to_ledger(compact: MeepCityLedger) -> void:
	if compact == null:
		return
	var id := StringName(_site_regions.get(compact.site_id, &""))
	var plan := _region_plans.get(id) as MeepRegionPlan
	var frame := _region_frames.get(id) as MeepSite
	compact.region_id = id
	compact.region_revision = plan.revision() if plan != null else -1
	var city_plan := compact._city_plan_state()
	if city_plan.is_empty():
		return
	var states: PackedByteArray = (city_plan.get(
		"lot_states", PackedByteArray()) as PackedByteArray).duplicate()
	var lots: PackedInt32Array = city_plan.get("lots", PackedInt32Array())
	var count := lots.size() / MeepCityPlan.LOT_STRIDE
	while states.size() < count:
		states.push_back(MeepCityPlan.LOT_FREE)
	if plan == null or frame == null:
		for index in states.size():
			if states[index] == MeepCityPlan.LOT_REGION_BLOCKED:
				states[index] = MeepCityPlan.LOT_FREE
	else:
		var city_site := MeepSite.new(compact.direction,
			planet.shape.radius, compact.facing,
			MeepColony.MAX_CLAIM_RADIUS)
		var wanted := plan.site_index(compact.site_id)
		var owners := plan.owner_map()
		var regional_setback := plan.setback_mask(compact.site_id)
		for lot in count:
			if states[lot] != MeepCityPlan.LOT_FREE \
					and states[lot] != MeepCityPlan.LOT_REGION_BLOCKED:
				continue
			var kind := lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_KIND]
			var maximum := lots[lot * MeepCityPlan.LOT_STRIDE
				+ MeepCityPlan.LOT_MAX_SPAN]
			var span := Vector2i(maximum, maximum) \
				if kind == MeepCityPlan.CIVIC_LOT \
				else MeepStructures.plan_of(kind).span
			var centre := Vector2i(
				lots[lot * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_X],
				lots[lot * MeepCityPlan.LOT_STRIDE + MeepCityPlan.LOT_Y])
			var corner := centre - Vector2i(span.x / 2, span.y / 2)
			var allowed := true
			for y in span.y:
				for x in span.x:
					var local := _standard_grid_centre(
						corner + Vector2i(x, y))
					var regional := frame.to_local(
						city_site.direction_at(local))
					var source := plan.index_of(plan.cell_of(regional))
					if source < 0 or source >= owners.size() \
							or owners[source] != wanted \
							or (source < regional_setback.size()
								and regional_setback[source] != 0):
						allowed = false
						break
				if not allowed:
					break
			states[lot] = MeepCityPlan.LOT_FREE \
				if allowed else MeepCityPlan.LOT_REGION_BLOCKED
	city_plan["lot_states"] = states
	compact._store_city_plan_state(city_plan)


func _define_region_walls() -> void:
	if _border_walls == null or planet == null or planet.shape == null:
		return
	var valid_ids := PackedStringArray()
	for region_variant: Variant in _region_plans:
		var region_id: StringName = region_variant
		var plan := _region_plans[region_id] as MeepRegionPlan
		var frame := _region_frames.get(region_id) as MeepSite
		if plan == null or frame == null:
			continue
		for record in plan.seam_records():
			var sites: PackedStringArray = record.get(
				"sites", PackedStringArray())
			if sites.size() < 2:
				continue
			var from_local: Vector2 = record.get("from", Vector2.ZERO)
			var to_local: Vector2 = record.get("to", Vector2.ZERO)
			var from_direction := frame.direction_at(from_local)
			var to_direction := frame.direction_at(to_local)
			var from_point := frame.point_at(from_local,
				planet.shape.elevation(from_direction, planet.finest_spacing()))
			var to_point := frame.point_at(to_local,
				planet.shape.elevation(to_direction, planet.finest_spacing()))
			var gates := PackedVector2Array()
			var metric_gates: PackedVector2Array = record.get(
				"gate_gaps", PackedVector2Array())
			var along := to_local - from_local
			var length_squared := maxf(along.length_squared(), 0.0001)
			for gate in range(0, metric_gates.size(), 2):
				if gate + 1 >= metric_gates.size():
					break
				var a := clampf((metric_gates[gate] - from_local).dot(along)
					/ length_squared, 0.0, 1.0)
				var b := clampf((metric_gates[gate + 1] - from_local).dot(along)
					/ length_squared, 0.0, 1.0)
				gates.push_back(Vector2(minf(a, b), maxf(a, b)))
			var seam_key := "%s|%s" % [
				String(region_id), String(record.get("id", ""))]
			var linked_id := String(_wall_seam_links.get(seam_key, ""))
			var result: Dictionary
			if not linked_id.is_empty() \
					and not _border_walls.segment_record(linked_id).is_empty():
				result = _border_walls.resettle_segment(
					linked_id, from_point, to_point, gates,
					plan.revision(),
					(from_direction + to_direction).normalized())
			else:
				result = _border_walls.define_segment(
					StringName(sites[0]), StringName(sites[1]),
					from_point, to_point, gates,
					MeepBorderWalls.DEFAULT_COST,
					maxf(from_point.distance_to(to_point) * 2.0, 8.0),
					plan.revision(),
					(from_direction + to_direction).normalized(),
					region_id)
			if bool(result.get("ok", false)):
				var segment_id := String(result.get("segment_id", ""))
				_wall_seam_links[seam_key] = segment_id
				valid_ids.push_back(segment_id)
				_update_wall_reach(segment_id)
	_retire_superseded_wall_contracts(valid_ids)
	_border_walls.prune_open_except(valid_ids)


func _retire_superseded_wall_contracts(
		valid_ids: PackedStringArray) -> void:
	var valid: Dictionary = {}
	for segment_id in valid_ids:
		valid[String(segment_id)] = true
	var wall_state := _border_walls.snapshot()
	var records: Variant = wall_state.get("segments", [])
	if not records is Array:
		return
	for value: Variant in records:
		if not value is Dictionary:
			continue
		var record := value as Dictionary
		var segment_id := String(record.get("id", ""))
		if valid.has(segment_id) or int(record.get(
				"state", MeepBorderWalls.SegmentState.OPEN)) \
				!= MeepBorderWalls.SegmentState.RESERVED:
			continue
		var payer := StringName(record.get("reserved_by", ""))
		var cancelled := _border_walls.cancel_segment(
			segment_id, payer,
			int(record.get("reservation_id", 0)),
			StringName(record.get("active_builder", "")))
		if not bool(cancelled.get("ok", false)):
			continue
		var refund := float(cancelled.get("refund_amount", 0.0))
		var here := colony(payer)
		var compact := ledger(payer)
		if here != null:
			here.resources += refund
		elif compact != null:
			compact.resources += refund


func _update_wall_reach(segment_id: String) -> void:
	var record := _border_walls.segment_record(segment_id)
	var cities: PackedStringArray = record.get(
		"cities", PackedStringArray())
	var from_q: Vector3i = record.get("from_q", Vector3i.ZERO)
	var to_q: Vector3i = record.get("to_q", Vector3i.ZERO)
	var midpoint := (Vector3(from_q) + Vector3(to_q)) \
		* MeepBorderWalls.ENDPOINT_QUANTUM * 0.5
	for site_text in cities:
		var site_id := StringName(site_text)
		var here := colony(site_id)
		var compact := ledger(site_id)
		var direction := here.site.centre \
			if here != null and here.site != null \
			else compact.direction if compact != null else Vector3.UP
		var reach := here.claim_radius if here != null \
			else compact.claim_radius if compact != null else 0.0
		var world_direction := midpoint.normalized()
		var reached := _surface_distance(
			direction, world_direction) <= reach \
			+ MeepRegionPlan.DEFAULT_SETBACK_METRES
		_border_walls.set_city_reached(segment_id, site_id, reached)


func _advance_ledger_walls(seconds: float) -> void:
	if _border_walls == null:
		return
	_reserve_open_shared_walls()
	for compact in ledgers():
		for record in _border_walls.segments_for_city(compact.site_id):
			if int(record.get("state", MeepBorderWalls.SegmentState.OPEN)) \
					!= MeepBorderWalls.SegmentState.RESERVED \
					or String(record.get("reserved_by", "")) \
						!= String(compact.site_id):
				continue
			var builders := compact.role_counts()[
				MeepColony.Role.BUILDER]
			var contribution := float(builders) \
				* MeepCityLedger.BUILDER_EFFICIENCY * seconds
			advance_shared_wall(compact.site_id,
				String(record.get("id", "")),
				int(record.get("reservation_id", 0)), contribution)


func _reserve_open_shared_walls() -> void:
	if _border_walls == null:
		return
	for site_text in _founded_site_ids():
		var site_id := StringName(site_text)
		for record in _border_walls.segments_for_city(site_id):
			var segment_id := String(record.get("id", ""))
			_update_wall_reach(segment_id)
			if int(record.get("state", MeepBorderWalls.SegmentState.OPEN)) \
					== MeepBorderWalls.SegmentState.OPEN \
					and _border_walls.is_eligible(segment_id):
				var here := colony(site_id)
				var compact := ledger(site_id)
				var bank := here.available() if here != null \
					else compact.available() if compact != null else 0.0
				var reserved := _border_walls.reserve_segment(
					segment_id, site_id, site_id, bank)
				if bool(reserved.get("ok", false)) \
						and StringName(reserved.get("status", &"")) \
							== &"reserved":
					var charge := float(reserved.get("charge_amount", 0.0))
					if here != null:
						here.resources = maxf(here.resources - charge, 0.0)
					elif compact != null:
						compact.resources = maxf(
							compact.resources - charge, 0.0)
			var latest := _border_walls.segment_record(segment_id)
			if int(latest.get("state", MeepBorderWalls.SegmentState.OPEN)) \
					== MeepBorderWalls.SegmentState.RESERVED:
				var payer := StringName(latest.get("reserved_by", ""))
				var resident := colony(payer)
				if resident != null:
					var from_q: Vector3i = latest.get(
						"from_q", Vector3i.ZERO)
					var to_q: Vector3i = latest.get(
						"to_q", Vector3i.ZERO)
					var midpoint := (Vector3(from_q) + Vector3(to_q)) \
						* MeepBorderWalls.ENDPOINT_QUANTUM * 0.5
					resident.offer_shared_wall(segment_id,
						planet.to_global(midpoint),
						int(latest.get("reservation_id", 0)),
						maxf(float(latest.get("work_required", 0.0))
							- float(latest.get("progress", 0.0)), 0.001))


func advance_shared_wall(city: StringName, segment_id: String,
		reservation_id: int, work: float) -> bool:
	if _border_walls == null:
		return true
	var record := _border_walls.segment_record(segment_id)
	if record.is_empty():
		return true
	if int(record.get("state", MeepBorderWalls.SegmentState.OPEN)) \
			== MeepBorderWalls.SegmentState.COMPLETE:
		return true
	var total := float(record.get("progress", 0.0)) + maxf(work, 0.0)
	var builder := StringName(record.get("active_builder", String(city)))
	var result := _border_walls.report_progress(
		segment_id, city, reservation_id, builder, total)
	if not bool(result.get("ok", false)):
		return StringName(result.get("status", &"")) == &"already_complete"
	if bool(result.get("ready_to_complete", false)):
		var completed := _border_walls.complete_segment(
			segment_id, city, reservation_id, builder)
		if bool(completed.get("ok", false)) \
				and bool(completed.get("newly_completed", false)):
			var cities: PackedStringArray = record.get(
				"cities", PackedStringArray())
			for site_text in cities:
				var here := colony(StringName(site_text))
				if here != null:
					here.shared_wall_completed()
		return bool(completed.get("ok", false))
	return false


func completed_wall_spans_for_city(
		site: StringName) -> PackedVector3Array:
	var spans := PackedVector3Array()
	if _border_walls == null:
		return spans
	for record in _border_walls.segments_for_city(site, true):
		var from_q: Vector3i = record.get("from_q", Vector3i.ZERO)
		var to_q: Vector3i = record.get("to_q", Vector3i.ZERO)
		spans.push_back(Vector3(from_q)
			* MeepBorderWalls.ENDPOINT_QUANTUM)
		spans.push_back(Vector3(to_q)
			* MeepBorderWalls.ENDPOINT_QUANTUM)
	return spans


func _forecast_row(site: StringName, population: int) -> Dictionary:
	var row: Dictionary = _forecast_rows.get(site, {})
	if row.is_empty():
		row = {
			"last_population": population,
			"last_time": _region_clock,
			"growth_ema": 0.0,
			"forecast_growth": 0.05,
			"error_seconds": 0.0,
		}
		_forecast_rows[site] = row
	return row


func _audit_region_forecasts() -> void:
	for site_variant: Variant in _site_regions:
		var site_text := String(site_variant)
		var site_id := StringName(site_text)
		var here := colony(site_id)
		var compact := ledger(site_id)
		var population := here.alive_count() if here != null \
			else compact.alive if compact != null else 0
		var row := _forecast_row(site_id, population)
		var last_time := float(row.get("last_time", _region_clock))
		var span := maxf(_region_clock - last_time, 0.001)
		var observed := maxf(float(population
			- int(row.get("last_population", population))) / span, 0.0)
		var old_ema := float(row.get("growth_ema", observed))
		var ema := lerpf(old_ema, observed, 0.25)
		var expected := maxf(float(row.get("forecast_growth", 0.05)), 0.01)
		var error := absf(ema - expected) / expected
		var error_seconds := float(row.get("error_seconds", 0.0))
		error_seconds = error_seconds + span \
			if error > REGION_ERROR_THRESHOLD else 0.0
		row["last_population"] = population
		row["last_time"] = _region_clock
		row["growth_ema"] = ema
		row["error_seconds"] = error_seconds
		_forecast_rows[site_id] = row
		if error_seconds >= REGION_ERROR_PERSIST_SECONDS:
			row["error_seconds"] = 0.0
			_forecast_rows[site_id] = row
			_queue_region_replan(false)


func _update_forecasts_after_plan() -> void:
	for site_variant: Variant in _forecast_rows.keys():
		if not _site_regions.has(StringName(site_variant)):
			_forecast_rows.erase(site_variant)
	for site_variant: Variant in _site_regions:
		var site_text := String(site_variant)
		var site_id := StringName(site_text)
		var here := colony(site_id)
		var compact := ledger(site_id)
		var population := here.alive_count() if here != null \
			else compact.alive if compact != null else 0
		var row := _forecast_row(site_id, population)
		row["forecast_growth"] = maxf(float(row.get(
			"growth_ema", 0.0)), 0.01)
		row["error_seconds"] = 0.0
		_forecast_rows[site_id] = row


func _region_registry_state() -> Dictionary:
	var regions: Array = []
	var ids: Array = _region_plans.keys()
	ids.sort_custom(func(a: Variant, b: Variant) -> bool:
		return String(a) < String(b))
	for id_variant: Variant in ids:
		var id: StringName = id_variant
		var plan := _region_plans[id] as MeepRegionPlan
		var frame := _region_frames.get(id) as MeepSite
		if plan == null or frame == null:
			continue
		regions.push_back({
			"id": String(id),
			"frame_direction": frame.centre,
			"snapshot": plan.snapshot(),
		})
	var forecasts: Dictionary = {}
	for site_variant: Variant in _forecast_rows:
		forecasts[String(site_variant)] = (
			_forecast_rows[site_variant] as Dictionary).duplicate(true)
	return {
		"version": 1,
		"terrain_revision": _terrain_revision,
		"cooldown_remaining": maxf(
			_next_region_replan_at - _region_clock, 0.0),
		"regions": regions,
		"walls": _border_walls.snapshot() \
			if _border_walls != null else {},
		"wall_seam_links": _wall_seam_links.duplicate(true),
		"forecasts": forecasts,
	}


func _has_region_registry_state() -> bool:
	if not _region_plans.is_empty():
		return true
	if _border_walls == null:
		return false
	var wall_state := _border_walls.snapshot()
	var segments: Variant = wall_state.get("segments", [])
	return segments is Array and not (segments as Array).is_empty()


func _restore_region_registry_state(state: Dictionary) -> void:
	if int(state.get("version", 0)) != 1:
		_queue_region_replan(true)
		return
	_terrain_revision = maxi(int(state.get(
		"terrain_revision", _terrain_revision)), _terrain_revision)
	_forecast_rows.clear()
	var forecasts_value: Variant = state.get("forecasts", {})
	if forecasts_value is Dictionary:
		for site_variant: Variant in forecasts_value:
			var row: Variant = (forecasts_value as Dictionary)[site_variant]
			if row is Dictionary:
				_forecast_rows[StringName(site_variant)] = (
					row as Dictionary).duplicate(true)
	var regions_value: Variant = state.get("regions", [])
	var regions: Array = regions_value if regions_value is Array else []
	_apply_region_worker_output(regions, false, true, false)
	var walls_value: Variant = state.get("walls", {})
	if _border_walls != null and walls_value is Dictionary:
		_border_walls.apply_snapshot(walls_value as Dictionary)
	_wall_seam_links.clear()
	var links_value: Variant = state.get("wall_seam_links", {})
	if links_value is Dictionary:
		for seam_variant: Variant in links_value:
			var segment_value: Variant = (
				links_value as Dictionary)[seam_variant]
			_wall_seam_links[String(seam_variant)] = String(segment_value)
	_next_region_replan_at = _region_clock + maxf(float(state.get(
		"cooldown_remaining", 0.0)), 0.0)
	_regions_dirty = false
	_regions_urgent = false


@rpc("authority", "call_remote", "reliable")
func _apply_region_registry_state(state: Dictionary) -> void:
	_restore_region_registry_state(state)


# --- Residency ---------------------------------------------------------------

## Total settlers on the planet, walking about or not. What score is for.
func planet_population() -> int:
	var total := 0
	for here in colonies():
		total += here.alive_count()
	for ledger: MeepCityLedger in _ledgers.values():
		total += ledger.alive
	return total


## Resident and ledger footprint for the rolling performance recorder.
##
## These are counts from ledgers already maintained by each town. No row is
## inspected and no snapshot is built, which keeps the diagnostic independent of
## the population it is meant to measure.
func statistics() -> Dictionary:
	var resident_population := 0
	var active_rows := 0
	var visible_rows := 0
	var presenting := 0
	var structures := 0
	var road_cells := 0
	var street_lights := 0
	for here: MeepColony in colonies():
		resident_population += here.alive_count()
		active_rows += here._active_rows.size()
		visible_rows += here._visible_rows.size()
		if here._presenting:
			presenting += 1
		if here.structures != null:
			structures += here.structures.count()
		if here.roads != null:
			road_cells += here.roads.cell_count()
			street_lights += here.roads.active_light_count()
	var ledger_population := 0
	for compact: MeepCityLedger in _ledgers.values():
		ledger_population += compact.alive
	var distant_instances := 0
	if _distant != null and _distant.multimesh != null:
		distant_instances = _distant.multimesh.visible_instance_count
	return {
		"population": resident_population + ledger_population,
		"resident_population": resident_population,
		"ledger_population": ledger_population,
		"resident_cities": _colonies.size(),
		"ledger_cities": _ledgers.size(),
		"active_rows": active_rows,
		"visible_rows": visible_rows,
		"presenting_cities": presenting,
		"structures": structures,
		"road_cells": road_cells,
		"street_lights": street_lights,
		"distant_instances": distant_instances,
		"expeditions": _expeditions.size(),
		"replays": _replaying.size(),
	}


func ledger(site: StringName) -> MeepCityLedger:
	return _ledgers.get(site) as MeepCityLedger


func ledgers() -> Array[MeepCityLedger]:
	var out: Array[MeepCityLedger] = []
	for entry: Variant in _ledgers.values():
		out.push_back(entry as MeepCityLedger)
	return out


## Decides which cities are worth simulating in full.
##
## Host only, and replicated, so every peer holds the same set: the distance used is
## to the nearest player rather than to the local camera, which is what lets a host
## keep a town resident because somebody else is standing in it.
func _review_residency() -> void:
	if not _is_host() or planet == null or planet.shape == null:
		return
	var watchers := _watchers()
	if watchers.is_empty():
		return
	var resident := 0
	var distilled := 0
	for here in colonies():
		if here.site == null:
			continue
		resident += 1
		if distilled >= RESIDENCY_CHANGES_PER_REVIEW:
			continue
		# Wait for a physical-work boundary. A bake, half-built site, bridge, upgrade,
		# or occupied cloner has state the compact arithmetic model cannot finish.
		# Reviews run twice a second, so the city distils as soon as that work settles.
		if not replaying(here.site_id) and here.ready_for_distillation() \
				and _nearest_watcher(here.site.centre, watchers) > DISTILL_RANGE:
			distill(here.site_id)
			resident -= 1
			distilled += 1
	if _ledgers.is_empty():
		return
	# Nearest first, so a limit that bites gives the player the towns they can
	# actually reach rather than whichever the dictionary happened to list first.
	var ordered := ledgers()
	ordered.sort_custom(func(a: MeepCityLedger, b: MeepCityLedger) -> bool:
		return _nearest_watcher(a.direction, watchers) \
			< _nearest_watcher(b.direction, watchers))
	var reified := 0
	for ledger in ordered:
		if resident >= RESIDENT_LIMIT \
				or reified >= RESIDENCY_CHANGES_PER_REVIEW:
			return
		if _nearest_watcher(ledger.direction, watchers) > REIFY_RANGE:
			return
		if reify(ledger.site_id) != null:
			resident += 1
			reified += 1


## Where everybody who could walk into a town is, as planet-space directions.
##
## Player bodies only, and deliberately no fallback to the camera: residency is a
## question about who can reach a town, and a world with nobody in it — a capture
## scene, a fixture assembling a planet, a host between sessions — has no answer to
## it. Empty means leave every city exactly as it is.
func _watchers() -> PackedVector3Array:
	var found := PackedVector3Array()
	if planet == null:
		return found
	for node in get_tree().get_nodes_in_group(&"network_players"):
		var body := node as Node3D
		if body == null or not DamageHit.in_same_world(self, body):
			continue
		found.push_back(planet.to_local(body.global_position).normalized())
	return found


func _nearest_watcher(centre: Vector3, watchers: PackedVector3Array) -> float:
	var nearest := INF
	for watcher in watchers:
		nearest = minf(nearest, _surface_distance(centre, watcher))
	return nearest


## Turns a ledger city back into a full simulation.
func reify(site: StringName) -> MeepColony:
	var ledger := _ledgers.get(site) as MeepCityLedger
	if ledger == null or colony(site) != null:
		return colony(site)
	if multiplayer.has_multiplayer_peer():
		_apply_reify.rpc(ledger.to_dictionary())
	else:
		_apply_reify(ledger.to_dictionary())
	return colony(site)


## Turns a full simulation back into a ledger, releasing its navigation grid, flow
## fields, settler rows and MultiMesh.
func distill(site: StringName) -> MeepCityLedger:
	var here := colony(site)
	if here == null or here.site == null:
		return _ledgers.get(site) as MeepCityLedger
	var ledger := MeepCityLedger.new()
	ledger.absorb(here)
	var replay_variant: Variant = _replaying.get(site)
	if replay_variant is PackedInt32Array:
		ledger.add_structures_owed(replay_variant as PackedInt32Array)
	if multiplayer.has_multiplayer_peer():
		_apply_distill.rpc(ledger.to_dictionary())
	else:
		_apply_distill(ledger.to_dictionary())
	return _ledgers.get(site) as MeepCityLedger


@rpc("authority", "call_local", "reliable")
func _apply_distill(state: Dictionary) -> void:
	var ledger := MeepCityLedger.from_dictionary(state)
	if ledger.site_id == &"":
		return
	var here := colony(ledger.site_id)
	_colonies.erase(ledger.site_id)
	_replaying.erase(ledger.site_id)
	_replay_wait.erase(ledger.site_id)
	_ledgers[ledger.site_id] = ledger
	if here != null:
		here.queue_free()
	# The compact city keeps this exact centre in claim_rivals(), so residency
	# changes cannot make a neighbour's border consume unwatched territory.


@rpc("authority", "call_local", "reliable")
func _apply_reify(state: Dictionary) -> void:
	var ledger := MeepCityLedger.from_dictionary(state)
	if ledger.site_id == &"" or colony(ledger.site_id) != null:
		return
	_ledgers.erase(ledger.site_id)
	var clock := Time.get_ticks_usec()
	_apply_found(ledger.site_id, ledger.direction, ledger.facing,
		ledger.founded_seed, ledger.claim_radius, ledger.parent_site_id,
		ledger.display_name)
	var here := colony(ledger.site_id)
	if here == null:
		_ledgers[ledger.site_id] = ledger
		return
	clock = _charge_reify(&"reify_found", clock)
	# The physical half goes back exactly as it was, through the same paths a late
	# joiner uses. Then the economic half is laid over it, because that is the part
	# the ledger has been running.
	_apply_physical_state(here, ledger.physical)
	clock = _charge_reify(&"reify_physical", clock)
	ledger.abandon_projects()
	here.resources = ledger.resources
	here.committed = clampf(ledger.committed, 0.0, here.resources)
	here.tier = ledger.tier
	here.ensure_settlement_ship_cloner()
	# Identities first, because they are what decide how many rows there are and
	# which of them are dead. Only then is the shortfall the settlers born while the
	# city was a ledger, and only those need names invented for them.
	if not ledger.identities.is_empty() \
			or not ledger.compact_roles.is_empty():
		here.apply_identity_snapshot(ledger.identity_snapshot())
		here.apply_deed_snapshot(ledger.deeds)
	clock = _charge_reify(&"reify_identities", clock)
	here.release_settlers(maxi(ledger.alive - here.alive_count(), 0),
		ledger.founded_seed ^ 0x5EED1E)
	here.restore_resident_places(ledger.resident_places,
		ledger.founded_seed ^ 0x51A77E4)
	clock = _charge_reify(&"reify_settlers", clock)
	here.reground()
	_charge_reify(&"reify_reground", clock)
	# Deferred rather than placed now: the planner is a ring search over the whole
	# claim, and the ground it searches is not even baked yet on the frame a city is
	# founded. See [method _advance_replays].
	if ledger.structures_pending() > 0:
		_replaying[ledger.site_id] = ledger.structures_owed.duplicate()


## Charges one stage of a residency change to the flight recorder.
##
## Reification is a single indivisible tick that founds a colony, rebuilds every
## building and street, and invents the settlers born while nobody was watching.
## As one unnamed lump it is only ever visible as "the physics step was slow".
func _charge_reify(stage: StringName, from: int) -> int:
	var now := Time.get_ticks_usec()
	RuntimeTelemetry.record_activity(&"meeps", stage, now - from)
	return now


## Puts a town's buildings, streets and purchases back on a freshly founded colony.
## The same sequence [method apply_snapshot] performs for a late joiner, shared so
## that a returning city and a joining peer cannot drift apart.
func _apply_physical_state(here: MeepColony, state: Dictionary) -> void:
	if state.is_empty():
		return
	var progression: Variant = state.get("progression", {})
	if progression is Dictionary:
		here.apply_city_progression(progression as Dictionary)
	var clock := Time.get_ticks_usec()
	if here.structures != null:
		here.structures.apply_snapshot(
			state.get("structures", PackedInt32Array()))
		here.structures.apply_progress(
			state.get("raised", PackedFloat32Array()))
		here.structures.apply_form_snapshot(
			state.get("structure_forms", PackedInt32Array()),
			state.get("structure_upgrades", PackedFloat32Array()))
	clock = _charge_reify(&"reify_structures", clock)
	if here.roads != null:
		here.roads.apply_snapshot(state.get("roads", PackedInt32Array()))
		here.roads.apply_width_snapshot(
			state.get("road_widths", PackedInt32Array()))
		here.roads.apply_surface_snapshot(
			state.get("road_surfaces", PackedInt32Array()))
	_charge_reify(&"reify_roads", clock)
	here.apply_tier_zero_space_exhausted(
		bool(state.get("tier_space_full", false)))
	here.apply_tier_zero_complete(bool(state.get("tier_complete", false)))


## Lays out the buildings a returning city banked while nobody was watching, a
## couple per frame, once its ground is ready.
func _advance_replays(delta: float) -> void:
	if _replaying.is_empty():
		return
	for site_variant: Variant in _replaying.keys():
		var site: StringName = site_variant
		var here := colony(site)
		if here == null:
			_replaying.erase(site)
			_replay_wait.erase(site)
			continue
		if not here.ground_ready():
			continue
		# A plot that will not fit now may fit once the border has grown, so this keeps
		# offering it rather than throwing away a building the town paid for. But the
		# planner is a ring search over the whole claim, so a town owed something
		# unplaceable would run one of those every frame forever; failure waits.
		var waiting := float(_replay_wait.get(site, 0.0)) - delta
		if waiting > 0.0:
			_replay_wait[site] = waiting
			continue
		_replay_wait.erase(site)
		var owed := _replaying[site] as PackedInt32Array
		var placed := 0
		for kind in owed.size():
			while owed[kind] > 0 and placed < REPLAY_PER_FRAME:
				if not here.place_completed_structure(kind):
					break
				owed[kind] -= 1
				placed += 1
			if placed >= REPLAY_PER_FRAME:
				break
		if placed <= 0:
			_replay_wait[site] = REPLAY_RETRY_SECONDS
		var left := 0
		for count in owed:
			left += count
		if left <= 0:
			# Completing the banked homes assigns deeds to settlers cloned while the
			# city was compact. Start those rows indoors at their actual building.
			here.rehome_returning_residents(
				here.founded_seed ^ 0x51A77E4)
			_replaying.erase(site)
			_replay_wait.erase(site)
		else:
			_replaying[site] = owed


func colony(site: StringName) -> MeepColony:
	var found := _colonies.get(site) as MeepColony
	return found if is_instance_valid(found) else null


## Whether a reified town still owes itself buildings it finished while unwatched.
## True for the handful of frames after a return, and for as long as anything owed
## cannot be fitted onto the ground the town currently holds.
func replaying(site: StringName) -> bool:
	return _replaying.has(site)


func colonies() -> Array[MeepColony]:
	var out: Array[MeepColony] = []
	for entry: Variant in _colonies.values():
		var here := entry as MeepColony
		if is_instance_valid(here):
			out.push_back(here)
	return out


## The closest founded city whether it is currently a full simulation or a
## compact ledger. Fauna migration cannot depend on residency: a city remains a
## real destination when every player is far enough away that its agents sleep.
func nearest_city(from_world: Vector3) -> Dictionary:
	if planet == null or planet.shape == null or not from_world.is_finite():
		return {}
	var local := planet.to_local(from_world)
	if local.length_squared() < 1.0:
		return {}
	var from_direction := local.normalized()
	var nearest := {}
	var nearest_distance := INF
	for here in colonies():
		if here.site == null:
			continue
		var direction := here.site.centre.normalized()
		var distance := _surface_distance(from_direction, direction)
		if distance >= nearest_distance:
			continue
		nearest_distance = distance
		nearest = {
			"site": String(here.site_id),
			"direction": direction,
			"claim_radius": here.claim_radius,
			"distance": distance,
		}
	for compact in ledgers():
		if compact == null or compact.direction.length_squared() < 0.5:
			continue
		var direction := compact.direction.normalized()
		var distance := _surface_distance(from_direction, direction)
		if distance >= nearest_distance:
			continue
		nearest_distance = distance
		nearest = {
			"site": String(compact.site_id),
			"direction": direction,
			"claim_radius": compact.claim_radius,
			"distance": distance,
		}
	return nearest


func _founded_site_ids() -> PackedStringArray:
	var found: Dictionary = {}
	for site_variant: Variant in _colonies:
		var resident_site: StringName = site_variant
		if colony(resident_site) != null:
			found[String(resident_site)] = true
	for ledger_site_variant: Variant in _ledgers:
		var ledger_site: StringName = ledger_site_variant
		if ledger(ledger_site) != null:
			found[String(ledger_site)] = true
	var ordered := PackedStringArray()
	for site_variant: Variant in found:
		ordered.push_back(String(site_variant))
	ordered.sort()
	return ordered


## Immutable worker-safe inputs for one city's spherical Voronoi claim. Stable site
## ordering makes exact centre-line ownership deterministic on every peer. Distilled
## cities remain rivals: simulation residency never changes ownership of land.
func claim_rivals(for_site: StringName) -> Dictionary:
	var centres := PackedVector3Array()
	var rival_wins_ties := PackedByteArray()
	for rival_name in _founded_site_ids():
		var rival_site := StringName(rival_name)
		if rival_site == for_site:
			continue
		var rival := colony(rival_site)
		var centre := Vector3.ZERO
		if rival != null and rival.site != null:
			centre = rival.site.centre
		else:
			var compact := ledger(rival_site)
			if compact != null:
				centre = compact.direction
		if not centre.is_finite() or centre.length_squared() < 0.5:
			continue
		centres.push_back(centre.normalized())
		rival_wins_ties.push_back(
			1 if String(rival_site).casecmp_to(String(for_site)) < 0 else 0)
	return {
		"centres": centres,
		"rival_wins_ties": rival_wins_ties,
	}


func expedition(site: StringName) -> SettlementShip:
	var found := _expeditions.get(site) as SettlementShip
	return found if is_instance_valid(found) else null


## The ship that controls a site, by the name it carries. Found through the
## landmarks group rather than a node path, so a second lander dropped anywhere
## works without this file knowing where.
func ship(site: StringName) -> Node3D:
	for landmark_variant: Variant in get_tree().get_nodes_in_group(Landmark.GROUP):
		var lander := landmark_variant as Node3D
		if lander == null or not DamageHit.in_same_world(self, lander):
			continue
		if (lander is ColonyShip and (lander as ColonyShip).colony_site == site) \
				or (lander is SettlementShip \
					and lander.get_parent() == self \
					and (lander as SettlementShip).colony_site == site):
			return lander
	return null


## What the city panel shows for a site, settled or not.
func report(site: StringName) -> Dictionary:
	var here := colony(site)
	if here == null:
		return _ledger_report(site)
	var out := here.report()
	var parent := colony(here.parent_site_id)
	out["parent_name"] = parent.display_name if parent != null else ""
	var children: Array = []
	for child in colonies():
		if child.parent_site_id == site:
			children.push_back({
				"name": child.display_name,
				"tier": child.tier,
				"settlers": child.alive_count(),
				"site": String(child.site_id),
			})
	children.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("site", "")) < String(b.get("site", "")))
	out["children"] = children
	return out


## What the city panel can honestly say about a town that is currently a ledger.
##
## Deliberately the aggregates and nothing else. A distant city has no structures
## list, no roads and no job board to report on, and inventing plausible numbers for
## those fields would make the panel lie rather than be brief.
func _ledger_report(site: StringName) -> Dictionary:
	var ledger := _ledgers.get(site) as MeepCityLedger
	if ledger == null:
		return {}
	return {
		"site": String(site),
		"name": ledger.display_name,
		"display_name": ledger.display_name,
		"tier": ledger.tier,
		"population": ledger.alive,
		"alive": ledger.alive,
		"meeps": ledger.meep_roster(),
		"role_counts": ledger.role_counts(),
		"resources": ledger.resources,
		"committed": ledger.committed,
		"housing_capacity": ledger.housing_capacity,
		"population_ceiling": ledger.population_ceiling(),
		"structures": ledger.structures_placed(),
		"raising": ledger.structures_pending(),
		"road_cells": ledger.road_cells,
		"claim_radius": ledger.claim_radius,
		"max_claim_radius": MeepColony.MAX_CLAIM_RADIUS,
		"city_style": ledger.city_plan_style_name(),
		"districts_active": ledger.city_plan_active_districts(),
		"districts_total": ledger.city_plan_district_count(),
		"border_expanding": ledger.city_plan_has_pending_expansion(),
		"city_lots": ledger.city_plan_lot_summary(),
		"expansion_rate": ledger.expansion_rate(),
		"harvester_rate": ledger.effective_harvester_rate(),
		"harvester_base_rate": ledger.harvester_rate,
		"staffed_harvesters": ledger.staffed_harvesters(),
		"ground_ready": false,
		"resident": false,
		"parent_name": "",
		"children": [],
	}


## Metadata carried by the unique inventory ability bought from this parent.
## Stable child ids count used launchers; the parent's outstanding paid-token
## count gives several pre-purchased launchers distinct future ordinals.
func settlement_launcher_record(parent_id: StringName) -> Dictionary:
	var parent := colony(parent_id)
	if parent == null:
		return {}
	var child_ids: Dictionary = {}
	for child in colonies():
		if child.parent_site_id == parent_id:
			child_ids[child.site_id] = true
	for child_variant: Variant in _expeditions:
		var child_id := StringName(child_variant)
		var expedition := _expeditions[child_id] as SettlementShip
		if expedition != null and expedition.parent_site == parent_id:
			child_ids[child_id] = true
	var sequence := child_ids.size() + parent.settlement_tokens + 1
	return {
		"parent_site": String(parent_id),
		"sequence": sequence,
		"title": "%s Settlement of %s" % [
			_ordinal_word(sequence), parent.display_name],
	}


static func _ordinal_word(value: int) -> String:
	var words := [
		"First", "Second", "Third", "Fourth", "Fifth",
		"Sixth", "Seventh", "Eighth", "Ninth", "Tenth",
	]
	if value >= 1 and value <= words.size():
		return words[value - 1]
	var last_two := value % 100
	var suffix := "th"
	if last_two < 11 or last_two > 13:
		match value % 10:
			1:
				suffix = "st"
			2:
				suffix = "nd"
			3:
				suffix = "rd"
	return "%d%s" % [value, suffix]


## Moves already-validated player biomass into a founded colony's shared bank.
## GameWorld owns the player debit and proximity checks; the registry only
## answers whether this site can receive it.
func deposit_biomass(site: StringName, amount: float) -> float:
	if not _is_host() or not is_finite(amount) or amount <= 0.0:
		return 0.0
	var here := colony(site)
	if here == null or here.count() <= 0:
		return 0.0
	return here.receive_biomass(amount)


## Applies one already-authenticated city action. Prices and prerequisites are
## deliberately resolved by the colony rather than accepted from the caller.
func purchase(site: StringName, purchase_id: int, requesting_peer := 1) -> bool:
	if not _is_host():
		return false
	var here := colony(site)
	return here != null and here.count() > 0 \
		and here.try_city_purchase(purchase_id, requesting_peer)


# --- Founding ----------------------------------------------------------------

## Founds the colony a ship controls, if it has not been founded already. Host
## only; every peer is told, and each one builds the same town for itself.
func found(site: StringName) -> MeepColony:
	if not _is_host():
		return colony(site)
	var existing := colony(site)
	if existing != null:
		return existing
	var lander := ship(site)
	var colony_lander := lander as ColonyShip
	if colony_lander == null:
		push_warning("MeepColonies has no colony ship for site '%s'" % site)
		return null
	# The seed is drawn once, here, and carried. It is what makes a wave's layout
	# and a Meep's choices the same on every peer without any of them being sent.
	var colony_seed := randi()
	var direction := colony_lander.direction.normalized()
	var shown_name := colony_lander.title if not colony_lander.title.is_empty() \
		else String(site).capitalize()
	if multiplayer.has_multiplayer_peer():
		_apply_found.rpc(site, direction, colony_lander.facing, colony_seed,
			claim_radius, &"", shown_name)
	else:
		_apply_found(site, direction, colony_lander.facing, colony_seed, claim_radius,
			&"", shown_name)
	return colony(site)


## Sends out the first settlers, founding the colony first if nobody has. Returns
## how many left the ship.
func release_settlers(site: StringName) -> int:
	if not _is_host():
		return 0
	var here := found(site)
	if here == null:
		return 0
	# The button is one-shot: population after the first wave comes from the
	# cloner, and a ship that can be asked twice is a ship that prints Meeps.
	if here.count() > 0:
		return 0
	var wave_seed := randi()
	if multiplayer.has_multiplayer_peer():
		_apply_settlers.rpc(site, first_wave, wave_seed)
	else:
		_apply_settlers(site, first_wave, wave_seed)
	return here.count()


@rpc("authority", "call_local", "reliable")
func _apply_found(site: StringName, direction: Vector3, facing: float,
		colony_seed: int, radius: float, parent_id: StringName = &"",
		shown_name := "") -> void:
	if colony(site) != null:
		return
	var host := planet if planet != null else _planet_host()
	if host == null or host.shape == null:
		push_warning("MeepColonies cannot found '%s' without a planet" % site)
		return
	var here := MeepColony.new()
	# Named from the site rather than counted, so the node is at the same path on
	# every peer and its state packets arrive somewhere.
	here.name = "Colony_%s" % site
	add_child(here)
	here.configure(host, site, direction, facing, stats, radius,
		colony_seed, parent_id, shown_name)
	_colonies[site] = here
	# The new city baked against every older centre during configure. Older claims
	# now need the reciprocal competitor so their shared boundary cannot overlap.
	for existing in colonies():
		if existing != here:
			existing.territory_rivals_changed()
	_touch_regional_context()
	if not _site_regions.has(site) and _founded_site_ids().size() > 1:
		_queue_region_replan(true)


@rpc("authority", "call_local", "reliable")
func _apply_settlers(site: StringName, count: int, wave_seed: int) -> void:
	var here := colony(site)
	if here != null:
		here.release_settlers(count, wave_seed)


# --- Settlement expeditions -------------------------------------------------

func valid_settlement_landing(parent: StringName, target: Vector3) -> bool:
	if planet == null or planet.shape == null or not target.is_finite() \
			or absf(target.length() - 1.0) > 0.01 or colony(parent) == null:
		return false
	return valid_blueprint_landing(
		target, colony(parent).site.facing)


## The production terrain and real-city spacing contract without inventory,
## parent-city, or authority requirements. Local blueprint previews use this
## read-only path so a green footprint means the same thing as a real lander.
func valid_blueprint_landing(target: Vector3, facing := 0.0) -> bool:
	if planet == null or planet.shape == null or not target.is_finite() \
			or absf(target.length() - 1.0) > 0.01:
		return false
	var direction := target.normalized()
	var landing := MeepSite.new(direction, planet.shape.radius,
		facing, 24.0)
	var lowest := INF
	var highest := -INF
	var samples: Dictionary = {}
	for x in range(-3, 4):
		for y in range(-2, 3):
			var local := Vector2(
				LANDING_HALF_SIZE.x * float(x) / 3.0,
				LANDING_HALF_SIZE.y * float(y) / 2.0)
			var height := planet.shape.elevation(landing.direction_at(local))
			if height < MeepGrid.SHORE_MARGIN:
				return false
			samples[Vector2i(x, y)] = height
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > LANDING_LEVEL_TOLERANCE:
		return false
	for cell_variant: Variant in samples:
		var cell: Vector2i = cell_variant
		var here := float(samples[cell])
		for step in [Vector2i.RIGHT, Vector2i.DOWN]:
			if samples.has(cell + step):
				var run := 3.0 if step.x != 0 else 2.5
				if absf(float(samples[cell + step]) - here) / run \
						> tan(deg_to_rad(MeepGrid.MAX_SLOPE_DEGREES)):
					return false
	for existing_name in _founded_site_ids():
		var existing_site := StringName(existing_name)
		var existing := colony(existing_site)
		var existing_centre := Vector3.ZERO
		var existing_radius := 0.0
		var target_already_claimed := false
		if existing != null and existing.site != null:
			existing_centre = existing.site.centre
			existing_radius = existing.claim_radius
			target_already_claimed = existing.ground_ready() \
				and existing.claim != null and existing.claim.contains(
					existing.site.to_local(direction))
		else:
			var compact := ledger(existing_site)
			if compact == null:
				continue
			existing_centre = compact.direction
			existing_radius = compact.claim_radius
		# A settlement may approach a future frontier, but it cannot be founded
		# close enough for the stable midpoint frontier to retract territory another
		# city already owns. This includes compact offscreen cities: residency is
		# never permission to settle in somebody else's land.
		var separation := _surface_distance(direction, existing_centre)
		var preserves_existing := separation >= existing_radius * 2.0 \
			+ MeepGrid.CELL * 3.0
		if target_already_claimed or separation < SETTLEMENT_CLEARANCE \
				or not preserves_existing:
			return false
	for expedition_variant: Variant in _expeditions.values():
		var expedition := expedition_variant as SettlementShip
		if expedition != null and _surface_distance(
				direction, expedition.target_direction) < SETTLEMENT_CLEARANCE:
			return false
	return true


func launch_settlement(parent_id: StringName, target: Vector3,
		owner_peer: int) -> StringName:
	if not _is_host() or owner_peer <= 0:
		return &""
	var parent := colony(parent_id)
	if parent == null or not valid_settlement_landing(parent_id, target):
		return &""
	var rows := parent.settlement_founder_rows()
	var founders := parent.settlement_founder_manifest(rows)
	if rows.size() != 6 or founders.size() != 6:
		return &""
	var number := _next_settlement_number()
	var child := StringName("settlement_%d" % number)
	var shown_name := "Settlement %d" % number
	var seed := randi()
	var parent_ship := ship(parent_id)
	if parent_ship == null:
		return &""
	var origin := planet.to_local(parent_ship.global_position).normalized()
	if multiplayer.has_multiplayer_peer():
		_apply_expedition_launch.rpc(parent_id, child, shown_name, origin,
			target.normalized(), seed, owner_peer, rows, founders)
	else:
		_apply_expedition_launch(parent_id, child, shown_name, origin,
			target.normalized(), seed, owner_peer, rows, founders)
	return child


@rpc("authority", "call_local", "reliable")
func _apply_expedition_launch(parent_id: StringName, child: StringName,
		shown_name: String, origin: Vector3, target: Vector3, seed: int,
		owner_peer: int, rows: PackedInt32Array, founders: Array) -> void:
	if _expeditions.has(child):
		return
	var parent := colony(parent_id)
	if parent != null:
		parent.depart_founders(rows, founders)
		parent.apply_settlement_token_consumed(owner_peer)
	var lander := SettlementShip.new()
	add_child(lander)
	lander.configure(planet, child, parent_id, origin, target, seed, founders)
	lander.set_meta(&"display_name", shown_name)
	_expeditions[child] = lander


func _land_expedition(child: StringName) -> void:
	if _landed_handled.has(child):
		return
	var lander := _expeditions.get(child) as SettlementShip
	if lander == null:
		return
	_landed_handled[child] = true
	var shown_name := String(lander.get_meta(
		&"display_name", String(child).capitalize()))
	if multiplayer.has_multiplayer_peer():
		_apply_expedition_landed.rpc(child, lander.parent_site,
			shown_name, lander.target_direction, lander.expedition_seed,
			lander.founder_manifest)
	else:
		_apply_expedition_landed(child, lander.parent_site,
			shown_name, lander.target_direction, lander.expedition_seed,
			lander.founder_manifest)


@rpc("authority", "call_local", "reliable")
func _apply_expedition_landed(child: StringName, parent_id: StringName,
		shown_name: String, target: Vector3, seed: int, founders: Array) -> void:
	var lander := _expeditions.get(child) as SettlementShip
	if lander != null:
		lander.set_flight_state(SettlementShip.FLIGHT_DURATION, true)
	_landed_handled[child] = true
	_apply_found(child, target, colony(parent_id).site.facing \
		if colony(parent_id) != null else 0.0, seed,
		SETTLEMENT_CLAIM_RADIUS, parent_id, shown_name)
	var child_colony := colony(child)
	if child_colony != null and child_colony.count() == 0:
		child_colony.release_transferred_founders(founders, seed ^ 0x51E771E)


func rename_settlement(site: StringName, wanted: String) -> bool:
	var here := colony(site)
	return _is_host() and here != null and here.rename_settlement(wanted)


func _next_settlement_number() -> int:
	var number := 1
	while _colonies.has(StringName("settlement_%d" % number)) \
			or _ledgers.has(StringName("settlement_%d" % number)) \
			or _expeditions.has(StringName("settlement_%d" % number)):
		number += 1
	return number


func _surface_distance(a: Vector3, b: Vector3) -> float:
	return acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)) \
		* (planet.shape.radius if planet != null and planet.shape != null else 0.0)


# --- Late joiners ------------------------------------------------------------

## The founding facts for every settled site. Deliberately not the Meeps: rows are
## addressed by index and the next state packet fills them in, so a joiner needs to
## be told that a town exists and nothing about who is in it.
func snapshot() -> Array:
	var out: Array = []
	if _has_region_registry_state():
		out.push_back({
			"snapshot_kind": "meep_region_registry",
			"region_registry": _region_registry_state(),
		})
	for site_variant: Variant in _colonies:
		var site: StringName = site_variant
		var here := colony(site)
		if here == null or here.site == null:
			continue
		out.append({
			"site": String(site),
			"direction": here.site.centre,
			"facing": here.site.facing,
			"seed": here.founded_seed,
			"parent_site": String(here.parent_site_id),
			"display_name": here.display_name,
			"resources": here.resources,
			# Whole per-city purchase state, including held biomass. Additive and
			# optional so a pre-upgrade snapshot still reconstructs a Tier 0 city.
			"progression": here.city_progression_snapshot(),
			# What stands where, and how far along the unfinished ones are. Not
			# derivable from the seed: where a building went was decided against the
			# ground and the bank at the moment the colony chose it.
			"structures": here.structures.snapshot() \
				if here.structures != null else PackedInt32Array(),
			"raised": here.structures.progress_snapshot() \
				if here.structures != null else PackedFloat32Array(),
			"structure_forms": here.structures.form_snapshot() \
				if here.structures != null else PackedInt32Array(),
			"structure_upgrades": here.structures.upgrade_progress_snapshot() \
				if here.structures != null else PackedFloat32Array(),
			"deeds": here.deed_snapshot(),
			"identities": here.identity_snapshot(),
			"population": here.population_snapshot(),
			"tasks": here.tasks.snapshot() \
				if here.tasks != null else {},
			# Completed road cells are colony intent just like structure corners.
			# Their concrete meshes and cheaper route cost are rebuilt locally.
			"roads": here.roads.snapshot() \
				if here.roads != null else PackedInt32Array(),
			"road_widths": here.roads.width_snapshot() \
				if here.roads != null else PackedInt32Array(),
			"road_surfaces": here.roads.surface_snapshot() \
				if here.roads != null else PackedInt32Array(),
			"tier_space_full": here.tier_zero_space_exhausted(),
			"tier_complete": here.tier_zero_full(),
		})
	# Ledger cities, as a few hundred bytes each rather than the 150-600 KiB a
	# resident town's sidecars come to. This is what makes fifty settled sites an
	# unremarkable save file. Marked so `apply_snapshot` can tell the two apart
	# without inspecting which keys are present.
	for ledger: MeepCityLedger in _ledgers.values():
		var entry := ledger.to_dictionary()
		entry["snapshot_kind"] = "city_ledger"
		out.append(entry)
	for expedition_variant: Variant in _expeditions.values():
		var expedition := expedition_variant as SettlementShip
		if expedition != null:
			var flight := expedition.flight_snapshot()
			flight["display_name"] = String(expedition.get_meta(
				&"display_name", String(expedition.colony_site).capitalize()))
			out.append(flight)
	return out


## [param watcher_hints] is for a caller that knows where the players are about to
## be but has not put them there yet, which is every cold save restore: the bodies
## are spawned after the world they stand in.
func apply_snapshot(snapshot_state: Array,
		watcher_hints := PackedVector3Array()) -> void:
	var watchers := _watchers()
	var restored_regions := false
	for hint in watcher_hints:
		if hint.is_finite() and hint.length_squared() > 0.5:
			watchers.push_back(hint.normalized())
	for entry_variant: Variant in snapshot_state:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		if String(entry.get("snapshot_kind", "")) \
				== "meep_region_registry":
			var regions_value: Variant = entry.get("region_registry", {})
			if regions_value is Dictionary:
				_restore_region_registry_state(regions_value as Dictionary)
				restored_regions = true
			continue
		if String(entry.get("snapshot_kind", "")) \
				== "settlement_expedition":
			_apply_expedition_snapshot(entry)
			continue
		if String(entry.get("snapshot_kind", "")) == "city_ledger":
			var ledger := MeepCityLedger.from_dictionary(entry)
			if ledger.site_id != &"":
				_ledgers[ledger.site_id] = ledger
			continue
		var site := StringName(entry.get("site", ""))
		if site == &"":
			continue
		if _distils_on_load(entry, watchers):
			var compact := MeepCityLedger.from_city_snapshot(entry)
			if compact.site_id != &"":
				_ledgers[compact.site_id] = compact
			continue
		var progression: Variant = entry.get("progression", {})
		var radius := claim_radius
		if progression is Dictionary:
			radius = float((progression as Dictionary).get(
				"claim_radius", radius))
		_apply_found(
			site,
			entry.get("direction", Vector3.UP),
			float(entry.get("facing", 0.0)),
			int(entry.get("seed", 0)),
			radius,
			StringName(entry.get("parent_site", "")),
			String(entry.get("display_name", "")))
		var here := colony(site)
		if here == null:
			continue
		here.resources = float(entry.get("resources", 0.0))
		if progression is Dictionary:
			here.apply_city_progression(progression as Dictionary)
		if here.structures == null or here.roads == null:
			continue
		here.structures.apply_snapshot(entry.get("structures",
			PackedInt32Array()))
		here.structures.apply_progress(entry.get("raised",
			PackedFloat32Array()))
		here.structures.apply_form_snapshot(entry.get("structure_forms",
			PackedInt32Array()), entry.get("structure_upgrades",
			PackedFloat32Array()))
		here.ensure_settlement_ship_cloner()
		here.apply_deed_snapshot(entry.get("deeds", PackedInt32Array()))
		here.apply_identity_snapshot(entry.get("identities", {}))
		var tasks_value: Variant = entry.get("tasks", {})
		if here.tasks != null and tasks_value is Dictionary:
			here.tasks.apply_snapshot(tasks_value as Dictionary)
			here.reconnect_restored_tasks()
		var population_value: Variant = entry.get("population", {})
		if population_value is Dictionary:
			here.apply_population_snapshot(population_value as Dictionary)
		here.roads.apply_snapshot(entry.get("roads", PackedInt32Array()))
		here.roads.apply_width_snapshot(entry.get(
			"road_widths", PackedInt32Array()))
		var road_surfaces: PackedInt32Array = entry.get(
			"road_surfaces", PackedInt32Array())
		here.roads.apply_surface_snapshot(road_surfaces)
		here.apply_tier_zero_space_exhausted(
			bool(entry.get("tier_space_full", false)))
		here.apply_tier_zero_complete(bool(entry.get("tier_complete", false)))
		# Every restored town, including expanded land-only cities, needs one
		# derived claim/wall/route pass after all physical sidecars are present.
		# reground coalesces safely behind an already-running founding bake.
		here.reground()
	for here in colonies():
		apply_region_to_colony(here)
	for compact in ledgers():
		_apply_region_to_ledger(compact)
	if not restored_regions and _is_host():
		# Regionless saves retain all developed cells and migrate once after restore.
		_queue_region_replan(true)


## Whether a full city snapshot should be taken straight into a ledger instead of
## founding a colony for it.
##
## No watchers means no opinion: a save being restored before its player exists, or
## a fixture assembling a planet, gets the whole town it asked for. Otherwise the
## test is [constant REIFY_RANGE] rather than [constant DISTILL_RANGE], so a city
## the review would not have reified anyway is never built just to be freed. There
## is deliberately no resident cap here — a town within seven hundred metres of a
## player is one they can walk into before the next review.
func _distils_on_load(entry: Dictionary, watchers: PackedVector3Array) -> bool:
	if watchers.is_empty() or planet == null or planet.shape == null:
		return false
	if _snapshot_has_physical_work(entry):
		return false
	var direction: Vector3 = entry.get("direction", Vector3.UP)
	if not direction.is_finite() or direction.length_squared() < 0.5:
		return false
	return _nearest_watcher(direction.normalized(), watchers) > REIFY_RANGE


func _snapshot_has_physical_work(entry: Dictionary) -> bool:
	var progression_variant: Variant = entry.get("progression", {})
	if progression_variant is Dictionary:
		var requested := int((progression_variant as Dictionary).get(
			"requested_flags", 0))
		var commission_mask := 0
		for purchase_id: int in [
				MeepColony.CityPurchase.HAT_HOUSE,
				MeepColony.CityPurchase.ABILITIES_HOUSE,
				MeepColony.CityPurchase.BIOMASS_HARVESTER,
				MeepColony.CityPurchase.ABILITIES_HOUSE_TOWER,
				MeepColony.CityPurchase.SECOND_CLONER,
				MeepColony.CityPurchase.THIRD_CLONER,
				MeepColony.CityPurchase.FOURTH_CLONER,
			]:
			commission_mask |= 1 << purchase_id
		if (requested & commission_mask) != 0:
			return true
	var placements: PackedInt32Array = entry.get(
		"structures", PackedInt32Array())
	var raised: PackedFloat32Array = entry.get(
		"raised", PackedFloat32Array())
	if placements.size() / 3 > raised.size():
		return true
	for progress in raised:
		if progress < 0.999999:
			return true
	var tasks_variant: Variant = entry.get("tasks", {})
	if not tasks_variant is Dictionary:
		return false
	var jobs_variant: Variant = (tasks_variant as Dictionary).get("jobs", [])
	if not jobs_variant is Array:
		return false
	for row_variant: Variant in jobs_variant:
		if not row_variant is Dictionary:
			continue
		var row := row_variant as Dictionary
		var kind := int(row.get("kind", MeepTasks.Kind.IDLE))
		if kind == MeepTasks.Kind.BUILD or kind == MeepTasks.Kind.ROAD \
				or kind == MeepTasks.Kind.UPGRADE \
				or (kind == MeepTasks.Kind.CLONE \
					and int(row.get("workers", 0)) > 0):
			return true
	return false


func _apply_expedition_snapshot(entry: Dictionary) -> void:
	var child := StringName(entry.get("child_site", ""))
	var parent_id := StringName(entry.get("parent_site", ""))
	if child == &"" or parent_id == &"":
		return
	if not _expeditions.has(child):
		var lander := SettlementShip.new()
		add_child(lander)
		lander.configure(planet, child, parent_id,
			entry.get("origin_direction", Vector3.UP),
			entry.get("target_direction", Vector3.UP),
			int(entry.get("seed", 0)), entry.get("founders", []),
			float(entry.get("elapsed", 0.0)),
			bool(entry.get("landed", false)))
		lander.set_meta(&"display_name", String(entry.get(
			"display_name", String(child).capitalize())))
		_expeditions[child] = lander
	else:
		var existing := _expeditions[child] as SettlementShip
		existing.set_flight_state(float(entry.get("elapsed", 0.0)),
			bool(entry.get("landed", false)))
	if bool(entry.get("landed", false)):
		_landed_handled[child] = true


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _planet_host() -> Planet:
	var node := get_parent()
	while node != null:
		if node is Planet:
			return node as Planet
		node = node.get_parent()
	return null
