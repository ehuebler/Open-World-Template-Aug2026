extends Node

## Headless checks for the Meep colony: the site's projection, the navigation grid
## read off the height field, the boundary the flood fill derives from it, the cost
## field every walk uses, the settlers themselves, and the colony taking damage on
## their behalf.
##
##     godot --headless --path . dev/_meep_test.tscn
##
## Run with a renderer it also captures the boundary wall and the Meeps close up and
## at the distance they are actually played at, which is the half of this that a
## number cannot answer:
##
##     godot --path . dev/_meep_test.tscn

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
## The ColonyShip's own placement from `game/world.tscn`. The point of the checks
## below is what the terrain there does to a town, so they are run against the
## terrain the game actually founds one on.
const COLONY_DIRECTION := Vector3(-0.2881049, -0.1121179, 0.9510127)
const COLONY_FACING := 91.9
const SITE := &"landing"
## Simulated seconds of colony life the movement checks are run over. Long enough
## for every settler to have picked several wander targets and walked to them.
const WALK_SECONDS := 60.0
const WALK_STEP := 0.1
## Bearings the claim's reach is measured along.
const BEARINGS := 32
## Frames to give the terrain to stream in before a capture.
const TERRAIN_FRAMES := 200
## How long the town in the real world is given to get itself going, and how many ticks
## of it are run per frame. Together they are about twenty minutes of colony life: a
## mining trip is a hundred metres each way at walking pace, and the cloner is three
## trees' worth of biomass, so a town cannot be judged on less.
const LIVE_FRAMES := 3200
const LIVE_SLICES := 5
## Houses that make a town, for the purpose of stopping early.
const LIVE_UNTIL_HUTS := 3
## Trees the colony expects to find worth cutting at the landing site. Not asserted as
## an exact figure — it is a property of the world's flower-tree scatter, not of the
## Meeps — but the economy checks compare against it, so it is written down once.
const STANDING_AT_START := 14

var _failures := 0


class TestWorld extends GameWorld:
	func _ready() -> void:
		pass


class TestCycle extends CelestialCycle:
	func _ready() -> void:
		set_process(false)


class TestPlanet extends Planet:
	var test_viewer := Vector3.ZERO

	## The height field `game/world.tscn` ships, which means unsettled: the town pads
	## are off there, and leaving them on here would flatten the exact chasm and
	## shoreline these checks exist to meet. Everything else about the shape is its
	## default, because that is what the world's own sub-resource is.
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
		return test_viewer

	func finest_spacing() -> float:
		return 1.5

	## Pinned, where the real one follows whichever chunk is under the camera. A
	## colony's grid is baked at the finest spacing on every peer precisely so it
	## does not depend on this, and a test that let it drift would be measuring the
	## quadtree rather than the town.
	func spacing_underfoot() -> float:
		return 1.5


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
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

	var direction := COLONY_DIRECTION.normalized()
	var ship := ColonyShip.new()
	ship.name = "ColonyShip"
	ship.direction = direction
	ship.facing = COLONY_FACING
	ship.colony_site = SITE
	planet.add_child(ship)
	# Everything is HOT for the checks: the sharpest ground reads and the local
	# obstacle ray are the code paths worth testing, and the cheaper ones are the
	# same arithmetic against a cached height.
	planet.test_viewer = planet.to_local(ship.global_position)
	await get_tree().process_frame

	_check_site(planet, direction)
	_check_ship(ship)

	var colonies := MeepColonies.new()
	colonies.name = "MeepColonies"
	planet.add_child(colonies)
	await get_tree().process_frame
	_expect(colonies.ship(SITE) == ship,
		"the registry finds the colony ship by its site name")
	_expect(world.meep_colonies() == colonies,
		"the world finds the registry under the planet")

	var released := colonies.release_settlers(SITE)
	var colony := colonies.colony(SITE)
	_expect(colony != null, "releasing settlers founds the colony")
	if colony == null:
		_finish()
		return
	_expect(released == MeepColony.FIRST_WAVE and colony.alive_count()
		== MeepColony.FIRST_WAVE,
		"the first wave is the whole population")
	_expect(colonies.release_settlers(SITE) == 0,
		"the ship cannot be asked for a second wave")

	# The bake is a worker task picked up by the colony's own physics step.
	var bake_from := Time.get_ticks_msec()
	for _frame in 900:
		if colony.ground_ready():
			break
		await get_tree().physics_frame
	_expect(colony.ground_ready(), "the ground bake finishes")
	if not colony.ground_ready():
		_finish()
		return
	var phase := _took("ground bake", bake_from)

	_check_grid(colony)
	phase = _took("grid", phase)
	_check_claim(colony)
	phase = _took("claim", phase)
	_check_routes(colony)
	phase = _took("routes", phase)
	_check_wall(colony)
	phase = _took("wall", phase)
	_check_walking(colony)
	phase = _took("%.0f s of walking" % WALK_SECONDS, phase)
	_check_damage(planet, colony)
	_took("damage", phase)
	_check_report(world, colony)
	await _check_menu(colony)
	_check_snapshot(colonies, colony)

	world.queue_free()
	await get_tree().process_frame
	await _town()
	_finish()


## Prints how long a phase took and returns the clock for the next one. These are
## the numbers to watch if a later pass makes the town bigger: the grid, the flood
## fill and the cost field are all O(cells), and the walk is the tick itself.
func _took(phase: String, from: int) -> int:
	var now := Time.get_ticks_msec()
	print("meep_test: %s took %.2f s" % [phase, float(now - from) / 1000.0])
	return now


func _finish() -> void:
	print("meep_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


# --- Site --------------------------------------------------------------------

func _check_site(planet: TestPlanet, direction: Vector3) -> void:
	var site := MeepSite.new(direction, planet.shape.radius, COLONY_FACING, 128.0)
	_expect(site.to_local(direction).length() < 0.001,
		"the colony centre is the origin of its own map")
	_expect(absf(site.up.dot(site.east)) < 0.0001
		and absf(site.up.dot(site.north)) < 0.0001
		and absf(site.east.dot(site.north)) < 0.0001,
		"the site frame is orthonormal")
	var worst := 0.0
	for point: Vector2 in [Vector2(40.0, 0.0), Vector2(0.0, -95.0),
			Vector2(70.0, 70.0), Vector2(-120.0, 30.0)]:
		var round_trip := site.to_local(site.direction_at(point))
		worst = maxf(worst, round_trip.distance_to(point))
	_expect(worst < 0.01,
		"the projection round-trips to within a centimetre over the map")
	# The reason the projection is equidistant rather than a plain tangent plane:
	# a hundred metres on the map has to be a hundred metres of ground.
	var measured := planet.shape.radius \
		* site.up.angle_to(site.direction_at(Vector2(100.0, 0.0)))
	_expect(absf(measured - 100.0) < 0.05,
		"a hundred metres on the map is a hundred metres of ground")
	_expect(site.near(direction) and not site.near(-direction),
		"the cheap nearness test accepts the site and rejects the far side")


func _check_ship(ship: ColonyShip) -> void:
	_expect(ship.has_method("interact") and ship.has_method("interact_prompt"),
		"the colony ship satisfies the interaction contract")
	_expect(not ship.interact_prompt().is_empty(),
		"the ship offers a prompt to open city control")


# --- Ground ------------------------------------------------------------------

func _check_grid(colony: MeepColony) -> void:
	var grid := colony.grid
	_expect(grid.built and grid.terrain.size() == grid.cells * grid.cells,
		"the grid classifies every cell it holds")
	var tally := {}
	for at in grid.terrain.size():
		var kind := grid.terrain[at]
		tally[kind] = int(tally.get(kind, 0)) + 1
	var passable := int(tally.get(MeepGrid.Terrain.PASSABLE, 0))
	var water := int(tally.get(MeepGrid.Terrain.WATER, 0))
	var void_cells := int(tally.get(MeepGrid.Terrain.VOID, 0))
	var steep := int(tally.get(MeepGrid.Terrain.STEEP, 0))
	print("meep_test: grid passable=%d water=%d void=%d steep=%d" % [
		passable, water, void_cells, steep])
	_expect(passable > grid.terrain.size() / 8,
		"most of the landing site is walkable ground")
	_expect(water > 0,
		"the sea inside the grid is classified as water")
	_expect(void_cells + steep > 0,
		"the chasm beside the ship is classified as unwalkable")
	# The classification is only as good as its agreement with the field it came
	# from, which is also what every peer rebuilding this depends on.
	var slipped := 0
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			var kind := grid.terrain_at(cell)
			var height := grid.height_at(cell)
			if kind == MeepGrid.Terrain.WATER \
					and height >= MeepGrid.SHORE_MARGIN:
				slipped += 1
			elif kind == MeepGrid.Terrain.PASSABLE \
					and height < MeepGrid.SHORE_MARGIN:
				slipped += 1
	_expect(slipped == 0,
		"no cell is walkable below the waterline or wet above it")


func _check_claim(colony: MeepColony) -> void:
	var grid := colony.grid
	var claim := colony.claim
	_expect(claim.count > 0, "the claim is not empty")
	var wrong := 0
	var outside := 0
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			if not claim.contains_cell(cell):
				continue
			if not grid.passable(cell):
				wrong += 1
			if grid.centre_of(cell).length() > claim.radius + 0.001:
				outside += 1
	_expect(wrong == 0, "every claimed cell is walkable ground")
	_expect(outside == 0, "no claimed cell is beyond the claim's radius")

	# How far the town got on each bearing, and what stopped it. This is the whole
	# argument for deriving the boundary: on the open flats it should reach its cap,
	# and on the chasm and the shore it should stop well short of it without
	# anything in the code naming either.
	var shortest := INF
	var longest := 0.0
	var stopped_by := {}
	for bearing in BEARINGS:
		var angle := TAU * float(bearing) / float(BEARINGS)
		var found := claim.reach_along(Vector2(cos(angle), sin(angle)))
		var reach := float(found[0])
		var blocker := int(found[1])
		shortest = minf(shortest, reach)
		longest = maxf(longest, reach)
		stopped_by[blocker] = int(stopped_by.get(blocker, 0)) + 1
	print("meep_test: claim reach %.0f m to %.0f m of a %.0f m cap, stopped by %s"
		% [shortest, longest, claim.radius, stopped_by])
	_expect(longest >= claim.radius * 0.9,
		"the claim reaches its radius across the open ground")
	_expect(shortest <= claim.radius * 0.75,
		"the claim stops well short of its radius on at least one bearing")
	_expect(int(stopped_by.get(MeepGrid.Terrain.WATER, 0)) > 0,
		"the waterline is one of the things that stops the claim")
	_expect(int(stopped_by.get(MeepGrid.Terrain.VOID, 0))
		+ int(stopped_by.get(MeepGrid.Terrain.STEEP, 0)) > 0,
		"the chasm is one of the things that stops the claim")


func _check_wall(colony: MeepColony) -> void:
	var claim := colony.claim
	var edges := claim.border_edges()
	_expect(edges.size() >= 8 and edges.size() % 2 == 0,
		"the boundary traces as whole segments")
	var report := colony.report()
	_expect(int(report.get("wall_segments", 0)) == edges.size() / 2,
		"the wall stands one post per boundary segment")
	var loops := claim.border_loops()
	_expect(not loops.is_empty(),
		"the boundary stitches into at least one ring for the roads pass")
	var stitched := 0
	for loop in loops:
		stitched += loop.size()
	_expect(stitched == edges.size() / 2,
		"every boundary segment lands in exactly one ring")


# --- Routes ------------------------------------------------------------------

## Every walk in the town, checked against the two things a walk must never do:
## cross water, or step into a hole.
func _check_routes(colony: MeepColony) -> void:
	var grid := colony.grid
	var field := MeepFlowField.new()
	# The cell the claim grew from, which is where every route in the town leads.
	var home := colony.claim.origin
	field.build(grid, home)
	_expect(field.reached > 0 and not field.stale(),
		"the cost field fills from the colony centre")
	var unreachable := 0
	var wet := 0
	var stranded := 0
	var checked := 0
	var ceiling := grid.cells * 4
	for y in grid.cells:
		for x in grid.cells:
			var cell := Vector2i(x, y)
			# Sampled rather than exhaustive: one in seven claimed cells is
			# thousands of routes and a second of wall time.
			if not colony.claim.contains_cell(cell) or (y * grid.cells + x) % 7 != 0:
				continue
			checked += 1
			if not field.reachable(cell):
				unreachable += 1
				continue
			var walk := cell
			var steps := 0
			while walk != home and steps < ceiling:
				var kind := grid.terrain_at(walk)
				if kind == MeepGrid.Terrain.WATER \
						or kind == MeepGrid.Terrain.VOID:
					wet += 1
					break
				var step := field.step_at(walk)
				if step == Vector2i.ZERO:
					break
				walk = walk + step
				steps += 1
			if walk != home:
				stranded += 1
	print("meep_test: routed %d claimed cells home" % checked)
	_expect(checked > 32, "there is a town's worth of routes to check")
	_expect(unreachable == 0,
		"every claimed cell has a route to the colony centre")
	_expect(wet == 0,
		"no route crosses water or a crevasse")
	_expect(stranded == 0,
		"every route arrives rather than giving up part way")


# --- Settlers ----------------------------------------------------------------

## A minute of colony life, run at the tick rate rather than in real time, checking
## after every step that nobody is anywhere they should not be.
func _check_walking(colony: MeepColony) -> void:
	var grid := colony.grid
	var off_ground := 0.0
	var trespassing := 0
	var strayed := 0
	var moved := 0.0
	var start := PackedVector2Array()
	for index in colony.count():
		start.push_back(colony.meep_local(index))
	var steps := int(WALK_SECONDS / WALK_STEP)
	for _tick in steps:
		colony.step_simulation(WALK_STEP)
		for index in colony.count():
			if colony.meep_state(index) == MeepColony.State.DEAD:
				continue
			var at := colony.meep_local(index)
			if not grid.passable(grid.cell_of(at)):
				trespassing += 1
			if at.length() > colony.claim_radius + grid.cell_size * 2.0:
				strayed += 1
			# The one failure a data-oriented crowd hides best: a Meep whose height
			# drifts from the ground under it shows up as a sphere buried in a
			# hillside, not as an error.
			off_ground = maxf(off_ground, absf(
				colony.meep_height(index) - colony.ground_height_at(at)))
	for index in colony.count():
		moved = maxf(moved,
			colony.meep_local(index).distance_to(start[index]))
	print("meep_test: after %.0f s the furthest Meep had walked %.1f m, worst"
		% [WALK_SECONDS, moved] + " ground error %.3f m" % off_ground)
	_expect(trespassing == 0,
		"no Meep ever stands on water, a crevasse or a slope")
	_expect(strayed == 0,
		"no Meep wanders out of its own colony's reach")
	_expect(moved > colony.stats.arrive_within,
		"the settlers actually walk")
	_expect(off_ground < 0.25,
		"every Meep stays on the ground rather than sinking or floating")


func _check_damage(planet: Planet, colony: MeepColony) -> void:
	var before := colony.alive_count()
	var at := colony.meep_position(0)
	_expect(colony.is_in_group(DamageHit.COMBATANT_GROUP),
		"the colony stands in the combatants group for its Meeps")
	_expect(colony.combat_faction() == DamageHit.Faction.PLAYER,
		"Meeps are on the player's side")
	_expect(colony.combat_radius() >= colony.claim_radius,
		"the colony reports the whole town, so falloff is not applied twice")
	# The site map's zero is sea level, and this town is not at sea level. A centre
	# reported down there is inside the hill: out of range of hits that landed in the
	# town, and behind cover for anything that checks line of sight.
	var stands := planet.to_local(colony.combat_position()).length() \
		- planet.shape.radius - colony.ground_height_at(Vector2.ZERO)
	_expect(stands > 0.0 and stands < 4.0,
		"the colony's combat point stands on the ground at its centre")
	_expect(colony.combat_position().distance_to(at) < colony.combat_radius(),
		"and every Meep is inside the bounds it reports with it")

	var friendly := DamageHit.area(at, 4.0, 12.0)
	friendly.faction = DamageHit.Faction.PLAYER
	_expect(colony.apply_damage(friendly) == 0.0,
		"a player's own blast passes through the Meeps")

	var graze := DamageHit.area(at, 4.0, 6.0)
	graze.faction = DamageHit.Faction.ENEMY
	var dealt := colony.apply_damage(graze)
	_expect(dealt > 0.0, "an enemy blast lands on the Meeps inside it")
	_expect(colony.alive_count() == before,
		"a graze hurts without killing")
	_expect(colony.meep_health(0) < colony.stats.maximum_health,
		"the Meep at the centre of the blast takes the damage")

	var far := DamageHit.area(at + Vector3(0.0, 400.0, 0.0), 4.0, 60.0)
	far.faction = DamageHit.Faction.ENEMY
	_expect(colony.apply_damage(far) == 0.0,
		"a blast nowhere near the town reaches nobody")

	var lethal := DamageHit.area(colony.meep_position(0), 3.0, 999.0)
	lethal.faction = DamageHit.Faction.ENEMY
	_expect(colony.apply_damage(lethal) > 0.0, "a lethal blast connects")
	_expect(colony.alive_count() < before, "Meeps in it die")
	_expect(colony.meep_state(0) == MeepColony.State.DEAD,
		"a killed Meep leaves the simulation")


func _check_report(world: GameWorld, colony: MeepColony) -> void:
	_expect(world.has_method("request_release_settlers")
		and world.has_method("colony_report"),
		"the world exposes the release request and the panel's report")
	var report := world.colony_report(SITE)
	_expect(bool(report.get("founded", false)),
		"the report says the site is settled")
	_expect(int(report.get("settlers", -1)) == colony.alive_count(),
		"the report's settler count is the live population")
	_expect(float(report.get("resources", -1.0)) == 0.0,
		"the resource bank ships at zero, ready for the mining pass")
	_expect(world.colony_report(&"nowhere").is_empty(),
		"an unsettled site reports nothing rather than failing")


func _check_menu(colony: MeepColony) -> void:
	var menu := CityMenu.new()
	menu.configure(func() -> Dictionary: return colony.report())
	add_child(menu)
	await get_tree().process_frame
	_expect(menu.row_text("settlers") == str(colony.alive_count()),
		"the city panel shows the live settler count")
	_expect(menu.row_text("resources") == "0",
		"the city panel shows the resource bank")
	var button := menu.release_button()
	_expect(button != null and button.disabled,
		"the release button reports the settled state rather than asking again")
	var closed := [false]
	menu.closed.connect(func() -> void: closed[0] = true)
	menu.close()
	_expect(bool(closed[0]), "the panel raises its own close")
	await get_tree().process_frame


func _check_snapshot(colonies: MeepColonies, colony: MeepColony) -> void:
	var snapshot := colonies.snapshot()
	_expect(snapshot.size() == 1, "the settled site is in the joiner snapshot")
	if snapshot.is_empty():
		return
	var entry := snapshot[0] as Dictionary
	_expect(String(entry.get("site", "")) == String(SITE)
		and int(entry.get("seed", -1)) == colony.founded_seed,
		"the snapshot carries the founding facts and nothing else")
	_expect(not entry.has("meeps"),
		"the Meeps themselves are left to the state packets")


# --- The town, in the real world ---------------------------------------------

## The half of this that needs the world the game ships.
##
## Everything above runs against a bare planet, which is the right place to check a
## projection and a flood fill. The economy cannot be checked there: what a colony earns
## comes out of the flower trees standing around the landing site, and what it spends it
## on has to fit between them. So this loads `game/world.tscn`, presses the button
## through the same request a player's press goes through, and then runs the town until
## it has cut something down, built a cloner, made a Meep out of it and put up a house —
## or until it is clear that it will not.
##
## Runs headless as well as with a renderer. The captures are the part that needs a
## screen; the milestones are not.
func _town() -> void:
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	var world := WORLD.instantiate() as GameWorld
	add_child(world)
	for _frame in 10:
		await get_tree().process_frame
	var planet := world.find_child("Planet", true, false) as Planet
	var ship := world.find_child("ColonyShip", true, false) as ColonyShip
	var timber := world.find_child("LandingFlowerTrees", true, false)
	var player := get_tree().get_first_node_in_group("network_players") \
		as OnlinePlayer
	if planet == null or ship == null or player == null or timber == null:
		push_error("meep_test: no world to run a town in")
		return
	# Stood at the ship rather than at the spawn marker, because the host checks
	# that whoever pressed the button is actually there.
	_stand_facing(planet, player, ship.global_position, 14.0)
	for _frame in TERRAIN_FRAMES:
		await get_tree().process_frame
	world.request_release_settlers(1, SITE)
	var colony := world.meep_colonies().colony(SITE)
	if colony == null:
		push_error("meep_test: the world would not found a colony")
		return
	for _frame in 600:
		if colony.ground_ready():
			break
		await get_tree().process_frame
	if not colony.ground_ready():
		push_error("meep_test: the town's ground never finished baking")
		return

	_check_timber(colony, timber)
	await _live(colony, timber)
	_check_economy(colony, timber)
	_check_town_ground(colony)
	_check_town_snapshot(world, colony)
	await _capture(planet, player, colony)
	# Last, because it works by cutting flora down and everything above it wants the
	# town photographed as the Meeps left it.
	_check_cleared(colony, _built_in(colony))


## What the colony found to cut, before anyone has cut any of it.
func _check_timber(colony: MeepColony, timber: Node) -> void:
	var standing: PackedVector4Array = timber.call("standing_near",
		colony.combat_position(), colony.grid.half_span())
	print("meep_test: %d trees within the town's grid, %d of them worth cutting"
		% [standing.size(), colony.standing_timber()])
	_expect(colony.standing_timber() > 0,
		"the colony finds standing timber to harvest within its grid")
	_expect(colony.standing_timber() <= standing.size(),
		"and never more of it than the field says is there")
	_expect(colony.resources == 0.0 and colony.committed == 0.0,
		"a colony starts with an empty bank and nothing promised")


## Runs the town until it has done everything it is meant to do, or until it is clear it
## will not, and prints when each of those things first happened.
##
## Stepped faster than the clock, several tenths of a second per frame, because a mining
## trip is a hundred-metre walk each way and a test that waited for one in real time
## would take minutes. The step itself stays small: a Meep moves a couple of metres in a
## tenth of a second and the cells are two metres wide, so a coarser one would let
## somebody stride over the lip of the chasm the rest of these checks are about.
func _live(colony: MeepColony, timber: Node) -> void:
	var reached := {}
	var lived := 0.0
	for frame in LIVE_FRAMES:
		for _slice in LIVE_SLICES:
			colony.step_simulation(WALK_STEP)
			lived += WALK_STEP
		await get_tree().physics_frame
		if colony.resources > 0.0 and not reached.has("earned"):
			reached["earned"] = lived
			print("meep_test: first biomass banked after %.0f s" % lived)
		if not reached.has("cloner") and colony.structures.count_of(
				MeepStructures.Kind.CLONER, true) > 0:
			reached["cloner"] = lived
			print("meep_test: the cloner was finished after %.0f s" % lived)
		if not reached.has("cloned") \
				and colony.alive_count() > MeepColony.FIRST_WAVE:
			reached["cloned"] = lived
			print("meep_test: the first cloned Meep walked out after %.0f s"
				% lived)
		var huts := colony.structures.count_of(MeepStructures.Kind.HUT, true)
		if not reached.has("hut") and huts > 0:
			reached["hut"] = lived
			print("meep_test: the first hut was finished after %.0f s" % lived)
		# Not stopped at the first one. A colony that has built a second and a third
		# has shown the thing a single building cannot: that placement keeps finding
		# room, outward, without walling itself in.
		if huts >= LIVE_UNTIL_HUTS:
			print("meep_test: %d houses stood after %.0f s" % [huts, lived])
			break
	print("meep_test: %.0f s of town life in %d frames: %d settlers, %.0f"
		% [lived, LIVE_FRAMES, colony.alive_count(), colony.resources]
		+ " biomass, %d structures, %d trees felled"
		% [colony.structures.built_count(),
		int(timber.call("broken_keys").size())])


## The economy end to end: trees came down, biomass was earned for them, buildings were
## paid for out of it, and the population grew because they were.
func _check_economy(colony: MeepColony, timber: Node) -> void:
	var felled := int((timber.call("broken_keys") as PackedInt32Array).size())
	_expect(felled > 0,
		"the Meeps felled real trees out of the world's own flower-tree field")
	_expect(colony.resources > 0.0 or colony.structures.built_count() > 0,
		"and were paid biomass for them")
	_expect(colony.standing_timber() < STANDING_AT_START
		or colony.standing_timber() == 0,
		"the timber they cut stops being offered as work")
	_expect(colony.structures.count_of(MeepStructures.Kind.CLONER, true) > 0,
		"the first thing the town finishes is a cloner")
	_expect(colony.alive_count() > MeepColony.FIRST_WAVE,
		"the cloner turns one Meep into two, so the colony grows past its wave")
	_expect(colony.alive_count() <= MeepColony.POPULATION_CAP,
		"and stops at the population cap rather than printing Meeps")
	_expect(colony.structures.count_of(MeepStructures.Kind.HUT, true) > 0,
		"housing follows the cloner")
	# Every unit promised to a site is a unit that cannot be promised to another, and
	# the promise is released when the building is finished or never.
	_expect(colony.committed <= colony.resources + 0.001,
		"the bank never promises biomass it does not have")
	var spent := 0.0
	for index in colony.structures.count():
		spent += MeepStructures.plan_of(colony.structures.at(index).kind).cost
	print("meep_test: %.0f biomass banked, %.0f promised, %.0f of building"
		% [colony.resources, colony.committed, spent] + " paid for")
	_expect(spent > 0.0, "the town spent its biomass on what it put up")


## The ground a finished building stands on stops being ground.
func _check_town_ground(colony: MeepColony) -> void:
	var built := _built_in(colony)
	if built < 0:
		_expect(false, "something in the town is finished")
		return
	var entry := colony.structures.at(built)
	var plan := MeepStructures.plan_of(entry.kind)
	var blocked := 0
	for x in plan.span.x:
		for y in plan.span.y:
			if not colony.grid.passable(entry.corner + Vector2i(x, y)):
				blocked += 1
	_expect(blocked == plan.span.x * plan.span.y,
		"a finished building takes its whole footprint out of the grid")
	_expect(entry.local.length() >= plan.keep_centre,
		"and it was not built against the lander")
	var inside := 0
	for index in colony.count():
		if colony.meep_state(index) == MeepColony.State.DEAD:
			continue
		if not colony.grid.passable(
				colony.grid.cell_of(colony.meep_local(index))):
			inside += 1
	_expect(inside == 0,
		"nobody is left standing inside the walls of what they built")
	# Two structures cannot be pegged out on top of each other, whatever else is
	# true about the ground they were offered.
	var overlapping := 0
	for first in colony.structures.count():
		for second in range(first + 1, colony.structures.count()):
			var one := colony.structures.at(first)
			var two := colony.structures.at(second)
			if one.local.distance_to(two.local) < MeepStructures.SPACING:
				overlapping += 1
	_expect(overlapping == 0, "no two buildings were put in the same place")


## The first thing the town finished, or -1 if it finished nothing.
func _built_in(colony: MeepColony) -> int:
	for index in colony.structures.count():
		if colony.structures.at(index).built():
			return index
	return -1


## Whether a finished building is standing on bare ground, asked by trying to clear it
## a second time: if the first attempt worked there is nothing left there to cut.
##
## Which is the one form of this question that answers itself. Counting what stands
## inside the footprint cannot answer it — the far-distance grass field ignores damage
## the way it ignores craters, so a cleared building still has a dozen of its blades
## standing in it and always will. Offering the same volume again asks only about the
## plants that were ever removable.
##
## Only asked with a renderer, and that is the difficulty rather than a detail: the cover
## fields sow the tiles a viewer is near, so a headless run has no grass anywhere near
## the town and would pass this by having nothing to find. The control below is what
## stops a graphical run from passing the same empty way.
func _check_cleared(colony: MeepColony, built: int) -> void:
	if DisplayServer.get_name() == "headless" or built < 0:
		return
	var middle := colony.structures.world_centre(built)
	var reach := colony.structures.footprint_radius(built)
	var span := reach + MeepColony.CLEAR_MARGIN
	var control := DamageHit.area(colony.combat_position(), span,
		MeepColony.FELL_DAMAGE, 0.0)
	control.affects_combatants = false
	var growing := DamageHit.apply_to_fields(colony, control)
	var again := DamageHit.area(middle, span, MeepColony.FELL_DAMAGE, 0.0)
	again.affects_combatants = false
	var absorbed := DamageHit.apply_to_fields(colony, again)
	print("meep_test: clearing the building again cut %.0f of flora, the same"
		% absorbed + " volume by the ship cut %.0f" % growing)
	if growing <= 0.0:
		return # Nothing was sown near the town at all; the question is unanswerable.
	_expect(absorbed == 0.0,
		"a finished building has already cleared everything it stands on")


func _check_town_snapshot(world: GameWorld, colony: MeepColony) -> void:
	var snapshot := world.meep_colonies().snapshot()
	if snapshot.is_empty():
		_expect(false, "the grown town is in the joiner snapshot")
		return
	var entry := snapshot[0] as Dictionary
	var built: PackedInt32Array = entry.get("structures", PackedInt32Array())
	var raised: PackedFloat32Array = entry.get("raised", PackedFloat32Array())
	_expect(built.size() == colony.structures.count() * 3,
		"the snapshot carries a kind and a corner for every structure")
	_expect(raised.size() == colony.structures.count(),
		"and how far along each of them is")
	# What a joiner does with it: a fresh set of structures rebuilt from the wire has
	# to stand in the same places as the ones it was told about.
	var copy := MeepStructures.new()
	copy.configure(colony.site, colony.grid, colony.claim, null, null)
	copy.apply_snapshot(built)
	copy.apply_progress(raised)
	var moved := 0.0
	for index in copy.count():
		moved = maxf(moved,
			copy.at(index).local.distance_to(colony.structures.at(index).local))
	_expect(copy.count() == colony.structures.count() and moved < 0.001,
		"a client rebuilds the same town from it")
	copy.free()


# --- Captures ----------------------------------------------------------------

## The views a number cannot answer: the settlers up close, the boundary they claimed,
## the cloner they built and the town from the distance it is played at.
func _capture(planet: Planet, player: OnlinePlayer,
		colony: MeepColony) -> void:
	if DisplayServer.get_name() == "headless":
		return

	# The settlers themselves, at the distance you would walk up to one at. The thing
	# to look for is a sphere sitting on the grass rather than in it.
	var settler := -1
	for index in colony.count():
		if colony.meep_state(index) != MeepColony.State.DEAD \
				and colony.meep_state(index) != MeepColony.State.INSIDE:
			settler = index
			break
	if settler >= 0:
		_stand_facing(planet, player, colony.meep_position(settler), 3.5)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 30:
			await get_tree().process_frame
		await _shot("meep_settlers_close")

	var edges := colony.claim.border_edges()
	if not edges.is_empty():
		var post := (edges[0] + edges[1]) * 0.5
		_stand_facing(planet, player,
			planet.to_global(colony.site.point_at(post,
				colony.grid.height_at(colony.grid.cell_of(post)))), 4.0)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 30:
			await get_tree().process_frame
		await _shot("meep_boundary_close")

	# What they built, from the distance you would stand at to watch them build it.
	var cloner := colony.structures.nearest(
		MeepStructures.Kind.CLONER, Vector2.ZERO)
	if cloner >= 0:
		_stand_facing(planet, player, colony.structures.world_centre(cloner), 9.0)
		player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_NEAR)
		for _frame in 30:
			await get_tree().process_frame
		await _shot("meep_cloner")

	_stand_facing(planet, player,
		planet.to_global(colony.site.point_at(Vector2.ZERO, 0.0)), 60.0)
	player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_FAR)
	for _frame in 60:
		await get_tree().process_frame
	await _shot("meep_colony_gameplay")

	# The whole town, from above. The only view that shows how it grew — the cloner
	# nearest the lander, the houses filling in around it, the boundary out at the
	# chasm — and it needs its own camera: at head height in a metre of grass, a town
	# eighty metres away is grass.
	await _overhead(planet, colony, 96.0, 52.0, "meep_town")


## Looks down on the colony from [param up] metres up and [param away] metres out, with
## a camera of its own rather than the player's.
##
## The player's camera is on a spring arm behind their shoulders and pitched by the
## mouse, so an aerial framing cannot be asked of it without driving the input. This is a
## screenshot, so it borrows the viewport for one instead and gives it straight back.
func _overhead(planet: Planet, colony: MeepColony, away: float, up: float,
		shot_name: String) -> void:
	var centre := planet.to_global(colony.site.point_at(Vector2.ZERO,
		colony.ground_height_at(Vector2.ZERO)))
	var overhead := planet.to_local(centre).normalized()
	var side := colony.site.east
	var eye := planet.to_global(planet.to_local(centre)
		+ overhead * up + side * away)
	var camera := Camera3D.new()
	camera.name = "TownCamera"
	camera.far = 6000.0
	add_child(camera)
	camera.global_transform = Transform3D(
		Basis.looking_at(centre - eye, planet.global_basis * overhead), eye)
	var was := get_viewport().get_camera_3d()
	camera.make_current()
	# Long enough for the flora to have streamed to the new eye, which is what the
	# ground under a town looks like from up here.
	for _frame in 90:
		await get_tree().process_frame
	await _shot(shot_name)
	camera.queue_free()
	if is_instance_valid(was):
		was.make_current()


## Puts the player on the ground [param away] metres to one side of a target and
## turns them to look at it. Lifted from dev/_ability_shot.gd, which needs the same
## thing for the same reason: a shot of something on a sphere cannot be framed by
## typing a transform.
func _stand_facing(planet: Planet, player: OnlinePlayer, target: Vector3,
		away: float) -> void:
	var direction := planet.to_local(target).normalized()
	var up := planet.global_basis * direction
	var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	if side.length_squared() < 0.000001:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var stand_at := (direction + planet.to_local(
		planet.global_position + side).normalized()
		* (away / planet.shape.radius)).normalized()
	player.global_transform = Transform3D(
		Basis.looking_at(-side, planet.global_basis * stand_at),
		planet.standing_position(stand_at, 0.4))
	player.velocity = Vector3.ZERO


func _shot(shot_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	print("meep_test: %s %s" % [
		shot_name, "saved" if error == OK else error_string(error)])


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("meep_test: PASS  ", message)
		return
	_failures += 1
	push_error("meep_test: FAIL  %s" % message)
