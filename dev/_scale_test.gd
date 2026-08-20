extends Node

## Headless checks for the planet-scale settler framework: a planet's worth of
## unwatched cities, the price of holding them, and whether a city that is advanced by
## arithmetic ends up where the same city advanced by settlers would have.
##
##     godot --headless --path . dev/_scale_test.tscn
##
## Three separate questions, in ascending order of how long they take to answer.
##
## The town index: [method PlanetShape.elevation] is a few hundred thousand calls per
## terrain chunk and used to test every settlement on the planet per call. It now tests
## a bucket, and this checks the bucket answers what the full scan answered — for fifty
## cities, which is the case the bucket exists for and the case nothing else here
## covers.
##
## The planet of ledgers: fifty [MeepCityLedger] cities of two hundred settlers each,
## advanced for a minute of simulated time. What is asserted is the three things that
## make the architecture worth having — the settler total stays exactly right, the
## whole planet's growth costs a fraction of a frame, and the memory is a rounding
## error against the six hundred kilobytes of navigation grid one resident colony
## needs.
##
## Equivalence: the same town, run both ways for twenty simulated minutes. This is the
## check that makes leaving and coming back honest — a ledger that grew faster than the
## settlers would have is a city that rewards not looking at it — and it is where the
## three rates a ledger cannot borrow come from. Each is printed next to the shipped
## constant on every run, so recalibrating after the economy is retuned is a matter of
## reading the line and typing the number:
##
##     biomass per miner per second    MeepCityLedger.BIOMASS_PER_MINER
##     job seconds per builder-second  MeepCityLedger.BUILDER_EFFICIENCY
##     paved cells per building        MeepCityLedger.STREET_CELLS_PER_STRUCTURE
##
## The resident side is the real game — real ground, real flora, real settlers walking
## to real trees — so it lands within about a tenth of the same place each run rather
## than on the same number. The ledger is arithmetic and lands on the same number every
## time, which is why it is calibrated to the middle of that spread rather than to any
## one run of it.

const WORLD := preload("res://game/world.tscn")
## The ColonyShip's own placement from `game/world.tscn`, so the equivalence run is
## measured on the ground the game actually founds a town on.
const COLONY_DIRECTION := Vector3(-0.2881049, -0.1121179, 0.9510127)
const COLONY_FACING := 91.9
const SITE := &"landing"
const EQUIVALENCE_CITY_SEED := 0x5CA1E
const EQUIVALENCE_WAVE_SEED := 0x51A77

## A planet's worth of towns, and what lives in each. The plan's target is ten
## thousand settlers planet-wide.
const CITIES := 50
const CITY_POPULATION := 200
## Simulated seconds the planet of ledgers is advanced, at the cadence
## [MeepColonies] actually ticks them on.
const LEDGER_SECONDS := 60.0
## Microseconds of CPU the whole planet's unwatched growth may cost per simulated
## second. Measured per second rather than per tick so the figure means the same thing
## if [constant MeepColonies.LEDGER_INTERVAL] is ever retuned. A millisecond per second
## is about two thousandths of one core for fifty cities, including compact
## child-cohort maturation and fixed-role accounting.
const LEDGER_SECOND_BUDGET := 2000.0
## Bytes one unwatched city may take in a save file or a join packet. A resident town's
## snapshot runs to 150-600 KiB of grids, rows and sidecars; this is the number that
## makes fifty settled sites an unremarkable save.
const LEDGER_ENTRY_BUDGET := 4096

## Simulated seconds the equivalence run covers, and how far the resident town is
## stepped at a time. The step is the colony's own tick, so the resident side is
## running exactly what the game runs.
const EQUIVALENCE_SECONDS := 1200.0
const EQUIVALENCE_STEP := 0.1
const EQUIVALENCE_SLICES := 6
## How far apart the two may finish, as a share. Population is what score reads and
## structures are what the player sees, so both are held to it.
##
## Wider than the rate tolerance below, and it has to be. A real town's twenty minutes is
## not repeatable even on one world seed, because which trees its miners walk to decides
## what they earn: fixed-role warmed runs finish between roughly 32 and 50 settlers.
## Twenty minutes of housing feeding
## cloning feeding mining roughly doubles a difference in earnings into the outcome, so a
## deterministic ledger held to 10% of one sample would be failing on the reference's
## variance rather than on its own accuracy. This bounds that spread; the rate tolerance
## is what actually pins the arithmetic down.
const EQUIVALENCE_TOLERANCE := 0.25
## How far the ledger's rate may sit from the rate the resident town achieved on this run.
## The direct comparison: the constant against the thing it was measured from, with none
## of the compounding, so this is where a genuine drift shows up first — retune the walk
## to a tree or what a flower pays, and this moves before the outcome does.
##
## Still not tight, because the measured rate per actual unstaffed Harvester is itself
## a spread around 0.30-0.33. This leaves room for flora/path variance while failing on
## a real change in what one fixed-role Harvester can earn.
const RATE_TOLERANCE := 0.15
## Frames to give the terrain and flora to stream before the town is founded, and
## again once it is standing, so neither side is measured against a half-grown forest.
const TERRAIN_FRAMES := 200
const WARM_FRAMES := 240
## Frames the timber warm-up may spend waiting for the claim to finish surveying, and
## how many consecutive unchanged reads it takes to call it settled. See
## [method _warm_timber].
const TIMBER_WARM_FRAMES := 900
const TIMBER_STEADY_FRAMES := 30
## Simulated seconds the round-trip check spends away from its town, which is the ten
## minutes the bug report spent away from its own.
const AWAY_SECONDS := 600.0
## Frames a returning town is given to bake its ground and lay out the plots it owes.
const RETURN_FRAMES := 900

var _failures := 0


class TestWorld extends GameWorld:
	func _ready() -> void:
		pass


class TestCycle extends CelestialCycle:
	func _ready() -> void:
		set_process(false)


class TestPlanet extends Planet:
	static func world_shape() -> PlanetShape:
		var shape := PlanetShape.new()
		shape.settled = false
		return shape

	func _ready() -> void:
		if shape == null:
			shape = world_shape()
		shape.prepare()
		set_process(false)
		set_physics_process(false)

	func viewer_position() -> Vector3:
		return Vector3.ZERO

	func finest_spacing() -> float:
		return 1.5

	func spacing_underfoot() -> float:
		return 1.5


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	if OS.get_cmdline_user_args().has("--equivalence-only") \
			or OS.get_cmdline_user_args().has("--starter-only"):
		await _check_equivalence()
		_finish()
		return
	_check_town_index()
	_check_cluster_region_cost()
	await _check_planet_of_ledgers()
	if OS.get_cmdline_user_args().has("--ledger-only"):
		_finish()
		return
	await _check_equivalence()
	_finish()


func _finish() -> void:
	print("scale_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(passed: bool, what: String) -> void:
	if passed:
		print("scale_test: PASS  %s" % what)
		return
	_failures += 1
	print("scale_test: FAIL  %s" % what)


# --- The town index ----------------------------------------------------------

func _check_cluster_region_cost() -> void:
	var dimensions := Vector2i(240, 120)
	var terrain := PackedByteArray()
	terrain.resize(dimensions.x * dimensions.y)
	terrain.fill(1)
	var cities: Array[Dictionary] = []
	for index in 8:
		var angle := TAU * float(index) / 8.0
		var centre := Vector2(cos(angle) * 150.0, sin(angle) * 70.0)
		cities.push_back({
			"site": "cluster_%d" % index,
			"local_centre": centre,
			"forecast_rate": 0.8 + float(index) * 0.1,
			"seed": 1000 + index,
			"protected_local": PackedVector2Array([centre]),
		})
	var began := Time.get_ticks_usec()
	var region := MeepRegionPlan.new()
	var solved := region.solve(Vector2(-240.0, -120.0),
		dimensions, terrain, cities)
	var elapsed_ms := float(Time.get_ticks_usec() - began) / 1000.0
	var bytes := var_to_bytes(region.snapshot()).size()
	_expect(solved and elapsed_ms < 750.0,
		"an eight-ledger cluster plans once in %.1f ms, below 750 ms"
			% elapsed_ms)
	_expect(bytes < 256 * 1024,
		"an eight-city RLE owner grid stays below 256 KiB (%d bytes)" % bytes)


## Every direction has to resolve to the same pad the full scan would have given it.

## Every direction has to resolve to the same pad the full scan would have given it.
##
## Checked at fifty cities rather than at the handful the planet ships, because a
## bucket grid at two towns is one bucket and proves nothing: the interesting cases are
## a town straddling a cell boundary and a direction landing in a cell whose own
## neighbourhood is crowded.
func _check_town_index() -> void:
	var shape := PlanetShape.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5CA1E
	var towns: Array[CityPlan] = []
	for index in CITIES:
		var plan := CityPlan.new()
		plan.site = StringName("scale_city_%d" % index)
		plan.centre = _spread_direction(index, CITIES)
		plan.facing = rng.randf() * 360.0
		plan.core = 900.0
		plan.rim = 260.0
		plan.corner = 320.0
		# The real spread: the shipped settlements run from a few hundred metres to
		# a couple of kilometres, and a bucket that only ever saw one size would not
		# be tested on the town that spans several cells.
		plan.reach = 400.0 + rng.randf() * 1600.0
		towns.append(plan)
	shape.cities = towns
	shape.prepare()

	var mismatches := 0
	var pads := 0
	var samples := 0
	for index in CITIES:
		# Around each town, where the answer is not "nothing": the boundary of a cap
		# is the only place an index can disagree.
		for _try in 40:
			samples += 1
			var away := towns[index].reach * (0.2 + rng.randf() * 1.6)
			var swing := Basis(
				_any_tangent(towns[index].centre), away / shape.radius)
			var turn := Basis(towns[index].centre, rng.randf() * TAU)
			var direction := (turn * (swing * towns[index].centre)).normalized()
			if not _agrees(shape, direction):
				mismatches += 1
			elif _flat_town(shape, direction) >= 0:
				pads += 1
	for _try in 4000:
		samples += 1
		var direction := Vector3(
			rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		if not _agrees(shape, direction):
			mismatches += 1
	_expect(mismatches == 0,
		"the bucketed pad lookup answers what the full scan answered"
		+ " (%d samples, %d on a pad)" % [samples, pads])
	_expect(pads > 200,
		"the index check actually landed on pads (%d of them)" % pads)


## Whether the shape's own bucket lookup and a plain scan over every town agree.
func _agrees(shape: PlanetShape, direction: Vector3) -> bool:
	return shape._town_at(direction) == _flat_town(shape, direction)


## The first town containing a direction, tested the slow way.
func _flat_town(shape: PlanetShape, direction: Vector3) -> int:
	for index in shape.cities.size():
		if shape.cities[index].near(direction):
			return index
	return -1


## Directions spread evenly over the sphere, by the Fibonacci lattice: a settled
## planet's towns are not clustered on one face, and an index tested only on one face
## is an index whose other five are untested.
func _spread_direction(index: int, total: int) -> Vector3:
	var height := 1.0 - 2.0 * (float(index) + 0.5) / float(total)
	var ring := sqrt(maxf(1.0 - height * height, 0.0))
	var turn := float(index) * PI * (3.0 - sqrt(5.0))
	return Vector3(cos(turn) * ring, height, sin(turn) * ring).normalized()


func _any_tangent(direction: Vector3) -> Vector3:
	var hint := Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT
	return direction.cross(hint).normalized()


# --- A planet of ledgers -----------------------------------------------------

func _check_planet_of_ledgers() -> void:
	var world := TestWorld.new()
	world.name = "TestWorld"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	world.add_child(spawn_points)
	var cycle := TestCycle.new()
	cycle.name = "CelestialCycle"
	world.add_child(cycle)
	add_child(world)
	var planet := TestPlanet.new()
	planet.name = "Planet"
	planet.shape = TestPlanet.world_shape()
	world.add_child(planet)
	await get_tree().process_frame

	var colonies := MeepColonies.new()
	colonies.name = "MeepColonies"
	planet.add_child(colonies)
	await get_tree().process_frame
	colonies.apply_snapshot(_ledger_planet())
	await get_tree().process_frame

	_expect(colonies.ledgers().size() == CITIES,
		"a planet of %d unwatched cities loads as %d ledgers"
			% [CITIES, CITIES])
	_expect(colonies.planet_population() == CITIES * CITY_POPULATION,
		"the planet-wide settler count is exactly %d"
			% (CITIES * CITY_POPULATION))
	_expect(colonies.colonies().is_empty(),
		"not one of them is a resident colony")

	# Advanced directly rather than by waiting for frames: the assertion is what the
	# growth costs, and a headless frame is mostly other things.
	var ledgers := colonies.ledgers()
	var ticks := int(LEDGER_SECONDS / MeepColonies.LEDGER_INTERVAL)
	# A wall-clock sample can include an unrelated scheduler stall. Keep the best
	# of three identical fresh planets: the assertion is the ledger's CPU work,
	# while the first sample remains the functional state inspected below.
	var cost_samples := PackedFloat64Array([
		_advance_ledger_planet(ledgers, ticks),
	])
	for _sample in 2:
		cost_samples.push_back(_advance_ledger_planet(
			_fresh_scale_ledgers(), ticks))
	var spent := INF
	for sample in cost_samples:
		spent = minf(spent, sample)
	print("scale_test: %d cities cost %.1f us per simulated second"
		% [CITIES, spent])
	print("scale_test: ledger cost samples ", cost_samples)
	_expect(spent < LEDGER_SECOND_BUDGET,
		"a planet of %d cities costs %.1f us per simulated second,"
			% [CITIES, spent]
		+ " under the %.0f us budget" % LEDGER_SECOND_BUDGET)

	var grown := colonies.planet_population()
	_expect(grown >= CITIES * CITY_POPULATION,
		"a minute of growth loses nobody (%d settlers)" % grown)
	var owed := 0
	for ledger in ledgers:
		owed += ledger.structures_pending()
	print("scale_test: the planet banked %d buildings and %d settlers in %.0f s"
		% [owed, grown - CITIES * CITY_POPULATION, LEDGER_SECONDS])

	# What the planet costs to write down, which is the other half of why a city that
	# nobody is looking at should not be a colony.
	var largest := 0
	var whole := 0
	for entry_variant: Variant in colonies.snapshot():
		var size := var_to_bytes(entry_variant).size()
		largest = maxi(largest, size)
		whole += size
	print("scale_test: the planet serializes to %.1f KiB, largest city %d bytes"
		% [float(whole) / 1024.0, largest])
	_expect(largest < LEDGER_ENTRY_BUDGET,
		"an unwatched city serializes to %d bytes, under the %d byte ceiling"
			% [largest, LEDGER_ENTRY_BUDGET])

	world.queue_free()
	await get_tree().process_frame


func _advance_ledger_planet(
		ledgers: Array[MeepCityLedger], ticks: int) -> float:
	var began := Time.get_ticks_usec()
	for _tick in ticks:
		for ledger in ledgers:
			ledger.advance(MeepColonies.LEDGER_INTERVAL)
	return float(Time.get_ticks_usec() - began) / LEDGER_SECONDS


func _fresh_scale_ledgers() -> Array[MeepCityLedger]:
	var ledgers: Array[MeepCityLedger] = []
	for state: Dictionary in _ledger_planet():
		ledgers.push_back(MeepCityLedger.from_dictionary(state))
	return ledgers


## Fifty towns as a join snapshot of ledger cities, which is the form a save carries
## them in.
func _ledger_planet() -> Array:
	var out: Array = []
	for index in CITIES:
		var ledger := MeepCityLedger.new()
		ledger.site_id = StringName("scale_city_%d" % index)
		ledger.direction = _spread_direction(index, CITIES)
		ledger.facing = float(index) * 7.0
		ledger.founded_seed = 0x5CA1E ^ index
		ledger.display_name = "Scale City %d" % index
		ledger.alive = CITY_POPULATION
		ledger.tier = 1
		ledger.resources = 400.0
		ledger.housing_capacity = CITY_POPULATION
		ledger.residential_slots = CITY_POPULATION
		ledger.claim_radius = 120.0
		var entry := ledger.to_dictionary()
		entry["snapshot_kind"] = "city_ledger"
		out.append(entry)
	return out


# --- Resident and ledger, side by side ---------------------------------------

## The same town for twenty simulated minutes, once with settlers walking about and
## once as arithmetic.
##
## Run in the real world rather than in the lean fixture above, and that is not
## incidental: a resident colony earns its biomass by sending settlers to standing
## flora, so a town with no [GroundCover] near it earns nothing and would agree with a
## ledger only by both being empty.
func _check_equivalence() -> void:
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	var world := WORLD.instantiate() as GameWorld
	add_child(world)
	for _frame in 10:
		await get_tree().process_frame
	var planet := world.find_child("Planet", true, false) as Planet
	var player := get_tree().get_first_node_in_group("network_players") \
		as OnlinePlayer
	if planet == null or player == null:
		push_error("scale_test: no world to run a town in")
		return
	for spawner_variant in world.find_children("*", "FaunaSpawner", true, false):
		var spawner := spawner_variant as FaunaSpawner
		if spawner != null:
			spawner.set_process(false)
	var ship := world.find_child("ColonyShip", true, false) as ColonyShip
	if ship == null:
		push_error("scale_test: the world has no colony ship")
		return
	_stand_at(planet, player, ship.global_position)
	for _frame in TERRAIN_FRAMES:
		await get_tree().process_frame
	var equivalence_colonies := world.meep_colonies()
	equivalence_colonies._apply_found(SITE, COLONY_DIRECTION, COLONY_FACING,
		EQUIVALENCE_CITY_SEED, MeepClaim.DEFAULT_RADIUS, &"", "Landing")
	equivalence_colonies._apply_settlers(
		SITE, MeepColony.FIRST_WAVE, EQUIVALENCE_WAVE_SEED)
	var colony := equivalence_colonies.colony(SITE)
	if colony == null:
		push_error("scale_test: the world would not found a colony")
		return
	for _frame in 600:
		if colony.ground_ready():
			break
		await get_tree().process_frame
	if not colony.ground_ready():
		push_error("scale_test: the town's ground never finished baking")
		return
	# Let the flora around the ship finish streaming and surveying before anything is
	# measured. A town that spends its first minutes discovering trees earns at a rate
	# that says more about the harness than about the game.
	for _frame in WARM_FRAMES:
		await get_tree().process_frame
	var timber := await _warm_timber(colony)
	if timber <= 0:
		push_error("scale_test: the town found no timber to measure a rate against")
		return
	# From here the test owns the clock. Leaving the physics tick on would add however
	# many seconds of town life the machine happened to fit alongside the loop below,
	# which is the difference between a calibration and a coin toss.
	colony.set_physics_process(false)
	print("scale_test: starter city wanted=%d cloner_lots=%s roles=%s"
		% [colony._wanted_kind(),
			str(colony.city_plan.availability_summary(
				MeepStructures.Kind.CLONER)),
			str(colony.role_counts())])
	var starter_road := colony.city_plan.road_project_status(
		colony.roads, colony.claim, colony.grid)
	var starter_cells: PackedInt32Array = starter_road.get(
		"cells", PackedInt32Array())
	print("scale_test: starter road state=%d cells=%d cost=%.0f"
		% [int(starter_road.get("state", -1)), starter_cells.size(),
			colony.roads.cost_for(starter_cells)])
	if OS.get_cmdline_user_args().has("--starter-only"):
		colony.resources = 100.0
		var starter_lot := colony.city_plan.prepared_lot(
			MeepStructures.Kind.CLONER)
		var starter_placed := colony._peg_out(
			MeepStructures.Kind.CLONER)
		print("scale_test: starter lot=%s peg=%s structures=%d"
			% [str(starter_lot), str(starter_placed),
				colony.structures.count()])
		world.queue_free()
		await get_tree().process_frame
		return

	# The ledger starts from exactly what the colony is at this instant, which is what
	# makes the comparison a comparison of growth rather than of starting points.
	var ledger := MeepCityLedger.new()
	ledger.absorb(colony)
	# What the ledger's own rates are measured against: the miner-seconds and
	# builder-seconds the town spends, the biomass they bring in, and the streets they
	# leave behind. The resident simulation is the only place any of those figures
	# exists.
	var miner_seconds := 0.0
	var harvester_seconds := 0.0
	var builder_seconds := 0.0
	var earned := 0.0
	var banked := colony.resources
	var work_at_start := _work_standing(colony)
	var paved_at_start := colony.roads.cell_count() if colony.roads != null else 0
	var lived := 0.0
	while lived < EQUIVALENCE_SECONDS:
		for _slice in EQUIVALENCE_SLICES:
			colony.step_simulation(EQUIVALENCE_STEP)
			lived += EQUIVALENCE_STEP
			miner_seconds += float(colony.mining_job_target()) \
				* EQUIVALENCE_STEP
			var roles := colony.role_counts()
			harvester_seconds += float(maxi(
				roles[MeepColony.Role.HARVESTER]
					- colony.staffed_harvester_count(), 0)) \
				* EQUIVALENCE_STEP
			builder_seconds += float(_on_construction(colony)) \
				* EQUIVALENCE_STEP
			# Positive movement only: a step that both earned and spent is
			# undercounted, which biases the measured rate down rather than
			# flattering it.
			earned += maxf(colony.resources - banked, 0.0)
			banked = colony.resources
		# Accelerated simulation must not turn wall-clock worker scheduling into
		# economic randomness. Finish the route fields posted by this slice before
		# advancing another 0.6 seconds of resident life.
		for _worker_frame in 120:
			colony._collect_fields()
			if colony._field_tasks.is_empty():
				break
			await get_tree().process_frame
		await get_tree().physics_frame
	ledger.advance(lived)

	var resident_alive := colony.alive_count()
	var resident_built := colony.structures.built_count()
	var ledger_alive := ledger.alive
	var ledger_built := ledger.structures_placed() + ledger.structures_pending()
	print(("scale_test: %.0f s lived — resident %d settlers %d structures,"
		+ " ledger %d settlers %d structures")
		% [lived, resident_alive, resident_built, ledger_alive, ledger_built])
	print(("scale_test: the resident town earned %.0f biomass over %.0f"
		+ " requested miner-seconds and %.0f actual Harvester-seconds;"
		+ " rates are %.3f per request and %.3f per Harvester against the"
		+ " ledger's %.3f")
		% [earned, miner_seconds, harvester_seconds,
			earned / maxf(miner_seconds, 0.001),
			earned / maxf(harvester_seconds, 0.001),
			MeepCityLedger.BIOMASS_PER_MINER])
	# The other two. Everything the town finished, buildings and the streets that reach
	# them alike, against the settler-seconds its crews spent finishing them.
	var paved := float(maxi((colony.roads.cell_count() \
		if colony.roads != null else 0) - paved_at_start, 0))
	var delivered := _work_standing(colony) - work_at_start \
		+ paved * MeepRoads.WORK_PER_CELL
	print(("scale_test: it delivered %.0f job seconds over %.0f builder-seconds,"
		+ " which is %.3f per builder per second against the ledger's %.3f")
		% [delivered, builder_seconds,
			delivered / maxf(builder_seconds, 0.001),
			MeepCityLedger.BUILDER_EFFICIENCY])
	print(("scale_test: it paved %.0f cells for %d buildings, which is %.1f"
		+ " cells each against the ledger's %.1f")
		% [paved, resident_built, paved / maxf(float(resident_built), 1.0),
			MeepCityLedger.STREET_CELLS_PER_STRUCTURE])
	# Which of the three gates each of them finished against, so a mismatch says
	# where to look instead of only that there is one.
	print(("scale_test: resident banked %.0f of %.0f biomass, housing %d,"
		+ " ceiling %d, tier %d, plan %d of %d lots")
		% [colony.available(), colony.resources, colony.housing_capacity(),
			colony.population_ceiling(), colony.tier,
			colony.structures.count_of(MeepStructures.Kind.HUT),
			colony.tier_zero_structure_target()])
	print(("scale_test: ledger banked %.0f of %.0f biomass, housing %d,"
		+ " ceiling %d, tier %d, wants %d")
		% [ledger.available(), ledger.resources, ledger.housing_capacity,
			ledger.population_ceiling(), ledger.tier, ledger._wanted_kind()])
	var mined := earned / maxf(harvester_seconds, 0.001)
	_expect(_within(MeepCityLedger.BIOMASS_PER_MINER, mined, RATE_TOLERANCE),
		"the ledger mines within %.0f%% of what actual Harvesters brought home"
			% (RATE_TOLERANCE * 100.0))
	_expect(_within(float(ledger_alive), float(resident_alive)),
		"an unwatched city grows its population within %.0f%% of a watched one"
			% (EQUIVALENCE_TOLERANCE * 100.0))
	_expect(_within(float(ledger_built), float(resident_built)),
		"an unwatched city builds within %.0f%% of what a watched one builds"
			% (EQUIVALENCE_TOLERANCE * 100.0))

	await _check_round_trip(world, colony)
	world.queue_free()
	await get_tree().process_frame


## Walking away from a town and coming back to it.
##
## The bug this whole architecture answers: a player left a city, returned ten minutes
## later, and found nothing built, nothing cloned and settlers wandering. So this is the
## report as a check. The town is distilled exactly as leaving would distil it, advanced
## for the ten minutes nobody was watching, and reified exactly as returning would — and
## then the settlers it gained have to be walking about and the buildings it banked have
## to be standing on real ground.
func _check_round_trip(world: GameWorld, colony: MeepColony) -> void:
	var colonies := world.meep_colonies()
	if colonies == null:
		return
	var site := colony.site_id
	var before_alive := colony.alive_count()
	var before_built := colony.structures.count()
	var before_finished := colony.structures.built_count()
	var tracked_row := -1
	var tracked_place := Vector2.ZERO
	for index in colony._state.size():
		if colony._active_resident(index):
			tracked_row = index
			tracked_place = colony._local[index]
			break
	# No frames in between, so the residency review cannot decide any of this for us:
	# the player is standing in the town, and left to itself the review would reify the
	# city before it had a chance to grow.
	var ledger := colonies.distill(site)
	if ledger == null:
		_expect(false, "a town can be distilled where it stands")
		return
	_expect(colonies.colony(site) == null
		and colonies.planet_population() == before_alive,
		"leaving a town frees its simulation without losing a settler")
	_expect(tracked_row >= 0 and ledger.resident_places.size() > tracked_row,
		"leaving records each resident's last site-local position")
	ledger.advance(AWAY_SECONDS)
	var grown_alive := ledger.alive
	var owed := ledger.structures_pending()
	_expect(grown_alive > before_alive and owed > 0,
		"ten minutes away builds %d and clones %d settlers"
			% [owed, grown_alive - before_alive])
	var returned := colonies.reify(site)
	if returned == null:
		_expect(false, "a town can be reified where it stood")
		return
	_expect(tracked_row < returned._local.size()
		and returned._local[tracked_row].distance_to(tracked_place) <= 0.11,
		"coming back restores an existing Meep where it was, not at city centre")
	# The plots are deliberately not placed on the reify frame: the ground is not even
	# baked yet, and a dozen buildings appearing at once is a hitch. They arrive over the
	# following frames. Waited out on the replay queue rather than on a structure count,
	# because the town is alive again from the reify frame onward and a plot it
	# commissions for itself would answer a count target the banked buildings had not
	# actually met yet.
	for _frame in RETURN_FRAMES:
		if not colonies.replaying(site):
			break
		await get_tree().process_frame
	_expect(returned.alive_count() == grown_alive,
		"coming back finds the settlers it gained (%d) walking about"
			% grown_alive)
	_expect(not colonies.replaying(site)
		and returned.structures.count() >= before_built + owed,
		"coming back stands all %d buildings it banked on real ground" % owed)
	# Measured against what was finished when we left rather than against the whole town:
	# a plot the settlers had half-built when the player walked off is still half-built
	# when they come back, which is honest. The banked ones are the claim here.
	_expect(returned.structures.built_count() >= before_finished + owed,
		"and finds those %d finished rather than as foundations" % owed)


## Settlers with their hands on a building or a street right now, which is the honest
## denominator for a per-builder rate. A resident town's labour is not one crew: it keeps
## two plots open and up to six paving branches, so its capacity grows with its
## population and a rate measured against a fixed crew would climb with every run.
func _on_construction(colony: MeepColony) -> int:
	if colony.tasks == null:
		return 0
	var hands := 0
	for kind in [MeepTasks.Kind.BUILD, MeepTasks.Kind.ROAD,
			MeepTasks.Kind.UPGRADE]:
		for job in colony.tasks.all_of(kind):
			hands += job.workers
	return hands


## Job seconds embodied in everything the town has finished, by the same price list
## the ledger burns work from.
func _work_standing(colony: MeepColony) -> float:
	var total := 0.0
	if colony.structures == null:
		return total
	for kind in MeepStructures.Kind.size():
		total += float(colony.structures.count_of(kind, true)) \
			* MeepStructures.plan_of(kind).work
	return total


## Reads the town's timber until the answer stops changing, and reports how many trees
## it settled on.
##
## Timber is the one genuinely nondeterministic input to a resident economy.
## [method GroundCover.survey_harvestable] answers from streamed tiles at once but
## resolves the rest of a claim on worker threads a few cells per call, so which trees
## the first miners are told about depends on when those threads finish. That decides
## whether the first hut goes up in the first minute or the fourth, and twenty minutes of
## housing feeding cloning feeding mining compounds it into a town half again as large:
## four unwarmed runs of this check finished anywhere between 32 and 48 settlers. All of
## that is variance in the reference the ledger is measured against, so it is worth a few
## hundred frames to have the claim surveyed before the clock starts.
func _warm_timber(colony: MeepColony) -> int:
	var seen := -1
	var steady := 0
	for _frame in TIMBER_WARM_FRAMES:
		colony._read_timber()
		var found := colony._timber.size()
		if found != seen:
			seen = found
			steady = 0
		else:
			steady += 1
			if steady >= TIMBER_STEADY_FRAMES:
				break
		await get_tree().process_frame
	return seen


func _within(measured: float, reference: float,
		tolerance := EQUIVALENCE_TOLERANCE) -> bool:
	if reference <= 0.0:
		return measured <= 0.0
	return absf(measured - reference) / reference <= tolerance


func _stand_at(planet: Planet, player: OnlinePlayer, at: Vector3) -> void:
	var up := planet.up_at(at)
	player.global_position = at + up * 2.0
	player.velocity = Vector3.ZERO
