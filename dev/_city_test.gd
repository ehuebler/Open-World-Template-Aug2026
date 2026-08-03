extends Node3D

## The towns: the numbers and the pictures.
##
##     & $godot --path . dev/_city_test.tscn
##     & $godot --path . dev/_city_test.tscn -- --site=meridian
##     & $godot --path . dev/_city_test.tscn -- --site=meridian --lines
##     & $godot --path . dev/_city_test.tscn -- --bare
##     & $godot --path . dev/_city_test.tscn -- --hud
##
## By default it stands a planet up with one town on it, prints what the pad did to the
## terrain, what [RoadNetwork] made of the road table, whether the roads can be walked
## onto, and writes a dozen views to dev/captures/.
##
## `--site=` picks the town, by the names in [Settlements]; Vacationer's Landing by
## default. Every measurement and every view is read off that town's own [CityPlan], so
## the only per-town thing in here is the table of camera positions.
##
## `--lines` photographs the [b]line pass[/b] instead of the city: the centrelines
## [RoadNetwork] resolved, before and after every crossing took its bite, drawn over the
## ground with no road built. That is the one view in which a road laid through another
## road is obvious, and it is also the only way to see what the network thinks it did as
## opposed to what the mesh managed.
##
## `--bare` lifts the city out from under the planet and hides the terrain, so what is
## left on screen is exactly what [RoadMesh] made — which is how to tell a road that is
## missing from a road that is buried. `--hud` boots the real world with the real player
## instead, for the waypoints: it photographs the landmarks in [constant HUD_VIEWS] and
## prints which were drawn at each vantage, which is the measurement — whether a marker
## is up is the whole of that layer's behaviour and a screenshot is a poor way to read
## it. It then flies [constant DESCENT] down the spawn's own altitude and prints what is
## named at each rung, which is the check that the planet arrives unlabelled and puts
## its names on partway down rather than all at once from orbit.
##
## The lighting here is copied from game/world.tscn. Road tones are albedo and the scene
## runs about 1.4 of light through them before ACES tone maps the result, so a tone
## judged under any other lighting is judged wrong.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
## Mesh spacing at full detail, which is what the player's ground guard samples the
## height field at.
const SPACING := 1.5

## Steepest ground [OnlinePlayer] will stand on, in degrees: its `floor_max_angle` is
## left at Godot's default. A road edge steeper than this is a wall.
const FLOOR_MAX_ANGLE := 45.0
## The player's own step, in metres, which is the other way onto a raised road.
const STEP_HEIGHT := 0.3

## Name, where on the town's map, metres above the pad, degrees off the horizon, and
## optionally a point to look at instead of the town centre.
const VIEWS := {
	&"landing": [
		["city_plan", Vector2.ZERO, 2400.0, -90.0],
		["city_oblique", Vector2(0.0, -2200.0), 900.0, -22.0],
		["city_downtown", Vector2(390.0, -700.0), 180.0, -14.0],
		["city_street", Vector2(60.0, -450.0), 14.0, -4.0],
		["city_skyway", Vector2(300.0, -60.0), 55.0, 4.0],
		["city_beach", Vector2(0.0, -1500.0), 60.0, 3.0],
		# A plain downtown crossroads, an avenue crossing a street. Overhead is the only
		# view that shows all four corners at once, which is what says whether the
		# footways turn them or run out across the carriageway.
		["city_junction", Vector2(299.3, -162.0), 70.0, -90.0],
		["city_junction_low", Vector2(288.3, -213.8), 12.0, 0.0, Vector2(299.3, -162.0)],
		# A cul-de-sac head and the collector it hangs off, for the other end of the same
		# question.
		["city_close", Vector2(160.0, 390.0), 55.0, -90.0],
		# The ring road going round the outside of the harbour block. It used to run
		# down Crane Street and across the mouth of Dock Road, so this is the view
		# that says the detour is a road and not a kink.
		["city_harbour", Vector2(-790.0, -520.0), 260.0, -90.0],
		# The switchback's head, where the hill road, Hillside Head and Northeast Gate
		# now meet at one junction instead of crossing on open ground.
		["city_hillside", Vector2(540.0, 630.0), 130.0, -90.0],
		# Where the Skyway crosses Vacationer's Boulevard, from underneath and from
		# above. The one place in the city that answers all three of "is the soffit
		# there", "is the deck the right way out" and "did a leg land on the road".
		["city_viaduct", Vector2(85.0, 250.0), 6.0, 0.0, Vector2(85.0, 340.0)],
		["city_viaduct_plan", Vector2(85.0, 330.0), 110.0, -90.0],
	],
	&"meridian": [
		["meridian_plan", Vector2.ZERO, 2200.0, -90.0],
		["meridian_oblique", Vector2(0.0, -1600.0), 700.0, -20.0],
		# The market square: six roads at 45 degrees to each other, two of them
		# boulevards and one a diagonal promenade. The hardest rim in either town.
		["meridian_plaza", Vector2.ZERO, 95.0, -90.0],
		["meridian_plaza_low", Vector2(-150.0, -150.0), 11.0, 0.0, Vector2.ZERO],
		# The canted grid, and the three approaches arriving at it off the axes.
		["meridian_grid", Vector2(90.0, -40.0), 250.0, -12.0, Vector2(260.0, 270.0)],
		["meridian_grid_plan", Vector2(260.0, 270.0), 520.0, -90.0],
		# A proper street meeting two one-lane closes, which is the sidewalk-or-not
		# difference seen in one frame.
		["meridian_close", Vector2(-405.0, -60.0), 50.0, -90.0],
		["meridian_close_head", Vector2(-210.0, -300.0), 34.0, -90.0],
		# The nightclub strip, which is a promenade: no traffic on it at all.
		["meridian_neon", Vector2(150.0, -285.0), 8.0, -2.0, Vector2(480.0, -395.0)],
		# Where the service lane meets the ring road mid-face rather than at a chamfer
		# corner, which is why that extra ring node exists.
		["meridian_gate", Vector2(580.0, -190.0), 60.0, -90.0],
		# Park paths, and the one closed loop in the town apart from the ring road.
		["meridian_park", Vector2(-250.0, 430.0), 45.0, -90.0],
		# The two feet, from the height of somebody about to walk up it.
		["meridian_kerb", Vector2(190.0, 22.0), 1.4, -8.0, Vector2(150.0, 0.0)],
	],
}

## Where to cut across a road and probe what the ground does, per town: a point on the
## carriageway, the direction to walk out in, and how far. This is what says a raised road
## can be got onto.
##
## Every one of these sits mid-segment on a road with no [code]bend[/code], and away from
## any junction. Both of those matter and both were got wrong first time: a bend moves the
## carriageway off the chord between its junctions by the bend itself, so a point computed
## from the two node positions can be tens of metres into the grass, and a point on a
## junction is walking along a road rather than across one — which reads as a perfectly
## flat pass.
const CROSS_SECTIONS := {
	&"landing": [
		["Downtown Avenue 1", "avenue", Vector2(311.8, -103.4), Vector2(0.978, -0.208), 16.0],
	],
	&"meridian": [
		["Meridian Boulevard", "boulevard", Vector2(150.0, 0.0), Vector2(0.0, 1.0), 22.0],
		["Axis Avenue", "avenue", Vector2(0.0, -150.0), Vector2(1.0, 0.0), 16.0],
		["Backlot Lane", "lane", Vector2(492.5, -292.5), Vector2(0.993, -0.121), 10.0],
		["Market Walk", "promenade", Vector2(-50.0, 50.0), Vector2(0.707, 0.707), 10.0],
	],
}

## Junctions along the Skyway, which is where the deck is stood on. Only Vacationer's
## Landing has a deck; a town built on one level has nothing to stand on but the ground.
const DECK_AT := {
	&"landing": ["sk_e", "sk_1", "sk_2", "sk_3", "sk_w"],
}

## Shot, the landmark to stand over, metres out from it, and degrees to swing the camera
## off it. The pairs matter more than any one row: the same place at the same distance,
## looked at and looked past, is what shows the aimed range doing its job, and a landmark
## on the far side of the planet with nothing drawn for it is what shows the sight test
## doing its.
##
## The camera stands out to one side as well as up, so a row is 1.28 of its altitude away
## from the place — which is what the ranges are read against, and why these are not the
## round numbers the ranges are written as.
const HUD_VIEWS: Array = [
	# About where the player spawns, so this is the view the game actually opens on. It
	# should have nothing on it: the whole lit hemisphere is in frame and none of it is
	# anywhere you can get to from here.
	["waypoint_orbit", "VacationersLanding", 17000.0, 0.0],
	["waypoint_aimed", "VacationersLanding", 2650.0, 0.0],
	["waypoint_aside", "VacationersLanding", 2650.0, 34.0],
	["waypoint_behind", "VacationersLanding", 2650.0, 150.0],
	# Arrived: near enough that the place is its own sign and the marker has gone.
	["waypoint_close", "VacationersLanding", 900.0, 0.0],
	["waypoint_meridian", "MeridianFlats", 2800.0, 0.0],
	# Inside the town, where the district markers outrange the town's own name.
	["waypoint_meridian_in", "TheExchange", 1640.0, 0.0],
	["waypoint_iceland", "Iceland", 2650.0, 0.0],
]

## Altitudes the descent ladder reads the layer at, metres, from the spawn's own 9 km
## down to a walk across the pad. Nothing should be named at the top two rungs and the
## town should be named by the fourth; the rest is there to show the fade arriving
## rather than a marker snapping on between two rungs.
const DESCENT: Array[float] = [
	9000.0, 6000.0, 4500.0, 3400.0, 2400.0, 1200.0, 400.0,
]

## The line pass, drawn: the uncut centrelines in one colour and the runs the crossings
## left in another, so a road that stops in the wrong place is visible as a gap.
const TRACE_COLOR := Color(0.95, 0.35, 0.25)
const RUN_COLOR := Color(0.25, 0.85, 0.95)
## Metres over the ground to hang them, far enough to clear the roads themselves.
const LINE_LIFT := 3.0

var _site: StringName = Settlements.LANDING
var _planet: Planet
var _plan: CityPlan
var _camera: Camera3D


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--site="):
			_site = StringName(argument.trim_prefix("--site="))
	if "--hud" in OS.get_cmdline_user_args():
		await _waypoints()
	else:
		await _city()
	get_tree().quit()


# --- One town on its own ----------------------------------------------------

func _city() -> void:
	var shape := PlanetShape.new()
	shape.prepare()
	for town: CityPlan in shape.cities:
		if town.site == _site:
			_plan = town
	if _plan == null:
		push_error("city_test: the planet has no town called '%s'" % _site)
		return
	_measure(shape)

	add_child(_lighting())
	_planet = Planet.new()
	_planet.shape = shape
	# Nothing streams in a still, and the default budgets would leave the camera looking
	# at an unbuilt sphere for the first several seconds.
	_planet.splits_per_frame = 64
	_planet.applies_per_frame = 32
	_planet.pending_limit = 8
	_planet.lod_updates_per_second = 120
	add_child(_planet)

	var began := Time.get_ticks_msec()
	var city := CityBuilder.new()
	city.site = _site
	city.planet = _planet
	_planet.add_child(city)
	print("built in %d ms" % (Time.get_ticks_msec() - began))
	_count(city)
	_intersections(city)
	if "--bare" in OS.get_cmdline_user_args():
		# The planet has an identity transform here, so the city keeps its place when it
		# is lifted out from under it.
		_planet.remove_child(city)
		add_child(city)
		_planet.visible = false

	_camera = Camera3D.new()
	_camera.far = 40000.0
	_camera.near = 0.5
	add_child(_camera)
	_camera.current = true
	_planet.viewer = _camera
	await get_tree().physics_frame
	_piers(city)
	_stand()
	_profiles(city)
	await _walkable(city)

	if "--lines" in OS.get_cmdline_user_args():
		# Take the ribbons away before drawing the lines, not after: the sweep of every
		# MeshInstance3D under the builder catches the lines too if they are already there,
		# and the result is a photograph of bare zoning that looks like a build failure.
		for child in city.get_children(true):
			var view := child as MeshInstance3D
			if view != null:
				view.visible = false
		_draw_lines(city)
		await _shot("%s_lines" % _site, Vector2.ZERO,
			_plan.core * 3.0, -90.0)
		await _shot("%s_lines_close" % _site, Vector2.ZERO, _plan.core * 0.5, -90.0)
		return
	for view: Array in VIEWS.get(_site, []) as Array:
		await _shot(str(view[0]), view[1] as Vector2, view[2] as float,
			view[3] as float, view[4] as Vector2 if view.size() > 4 else Vector2.INF)


## What the pad did to the ground, and what the whole thing costs the height field per
## sample.
func _measure(shape: PlanetShape) -> void:
	var bare := PlanetShape.new()
	bare.settled = false
	bare.prepare()

	print("\n%s, pad against the terrain it replaced, metres above sea level" % _plan.title)
	print("  along y |    pad  terrain   | along x |    pad  terrain")
	for step in 7:
		var along := -_plan.core + _plan.core / 3.0 * float(step)
		var inland := _plan.direction_at(Vector2(0.0, along))
		var across := _plan.direction_at(Vector2(along, 0.0))
		print("  %6.0f | %6.1f  %7.1f   |  %6.0f | %6.1f  %7.1f" % [
			along, shape.elevation(inland, SPACING), bare.elevation(inland, SPACING),
			along, shape.elevation(across, SPACING), bare.elevation(across, SPACING)])
	print("  the rim reaches the untouched terrain by %.0f m out" % (
		_plan.core + _plan.rim))

	var steepest := 0.0
	for step in 360:
		var along := -_plan.core + _plan.core / 180.0 * float(step)
		steepest = maxf(steepest, absf(
			_plan.pad_height(Vector2(0.0, along + 5.0))
			- _plan.pad_height(Vector2(0.0, along))) / 5.0)
	print("  steepest grade on the pad  %.2f%%" % (steepest * 100.0))

	# The city is not band-limited, so every chunk built over it pays this on every
	# vertex. Off the pad it is one dot product per town.
	print("  elevation() costs %.2f us on the pad, %.2f us far from it" % [
		_time(shape, _plan.direction_at(Vector2(200.0, 100.0))),
		_time(shape, -_plan.centre.normalized())])


func _time(shape: PlanetShape, direction: Vector3) -> float:
	var runs := 40000
	var began := Time.get_ticks_usec()
	for index in runs:
		shape.elevation(direction, SPACING)
	return float(Time.get_ticks_usec() - began) / float(runs)


func _count(city: CityBuilder) -> void:
	var drawn := 0
	var faces := 0
	var tiles := 0
	var marks := 0
	# The builder parents everything internally, so the ordinary child list is empty and
	# these have to be asked for explicitly.
	for child in city.get_children(true):
		var view := child as MeshInstance3D
		if view != null:
			drawn += view.mesh.get_faces().size() / 3
			continue
		if child is Landmark:
			marks += 1
			continue
		var body := child as StaticBody3D
		if body == null:
			continue
		tiles += 1
		var collider := body.get_child(0) as CollisionShape3D
		faces += (collider.shape as ConcavePolygonShape3D).get_faces().size() / 3
	print("geometry: %d triangles drawn, %d in collision over %d tiles, %d waypoints" % [
		drawn, faces, tiles, marks])


## What the network made of the road table, and every place two roads foul each other
## without a junction between them.
##
## The audit is the point of the line pass and this is where it is read. A crossing
## reported here is a fault in the layout: two ribbons through the same ground, two
## surfaces at the same height for the depth buffer to argue over, and a kerb running out
## across whatever it crossed. It renders — that is the problem with it.
func _intersections(city: CityBuilder) -> void:
	var found := city.network.audit()
	print("network: %d junctions of %d nodes, %d roads cut into %d runs, %.2f km" % [
		found["junctions"], found["nodes"], found["roads"], found["runs"],
		(found["length"] as float) / 1000.0])
	var arms := {}
	for id: String in city.network.junctions:
		var count := int((city.network.junctions[id] as Dictionary)["arms"])
		arms[count] = int(arms.get(count, 0)) + 1
	var spread := PackedStringArray()
	for count: int in arms.keys():
		spread.append("%d x %d-arm" % [arms[count], count])
	spread.sort()
	print("  %s, %d dead ends" % [", ".join(spread),
		(found["dead_ends"] as Array[String]).size()])
	var grazes: PackedStringArray = found["grazes"]
	var crossed := 0
	for crossing: Dictionary in city.network.crossings():
		if bool(crossing["met"]):
			crossed += 1
	print("  %d centrelines crossing with no junction, %d ribbons grazing" % [
		crossed, grazes.size()])
	for graze: String in grazes:
		print("    %s" % graze)
	for problem: String in found["problems"] as PackedStringArray:
		push_error("city_test: %s" % problem)


## Where the viaducts' legs came down: how many, how close the nearest one got to a
## street it is supposed to be flying over, and whether stepping them past the streets
## stretched a span past the point of looking like a bridge.
##
## A town on one level has no legs, and that is not a failure.
func _piers(city: CityBuilder) -> void:
	var decks := 0
	for trace: Dictionary in city.network.traces:
		if bool((trace["kind"] as Dictionary)["deck"]):
			decks += 1
	if decks == 0:
		print("piers: none, and none wanted — every road here is on the ground")
		return
	if city.piers.is_empty():
		push_error("city_test: %d viaducts and no legs under any of them" % decks)
		return
	var fouled := 0
	for at: Vector2 in city.piers:
		if not city.clear_below(at, RoadMesh.PIER_FOOT):
			fouled += 1
	# Consecutive legs belong to the same viaduct only when they are near enough to be a
	# span; the jump from the end of one road to the start of the next is a kilometre and
	# is not one.
	var longest := 0.0
	var total := 0.0
	var spans := 0
	for index in range(1, city.piers.size()):
		var span := city.piers[index - 1].distance_to(city.piers[index])
		if span >= RoadMesh.PIER_SPACING * 4.0:
			continue
		longest = maxf(longest, span)
		total += span
		spans += 1
	print("piers: %d legs, %d on a carriageway, spans %.0f m mean %.0f m longest" % [
		city.piers.size(), fouled, total / maxf(float(spans), 1.0), longest])
	if fouled > 0:
		push_error("city_test: %d viaduct legs came down on a carriageway" % fouled)


## Whether a deck is something you can stand on.
##
## A ray from just over the carriageway down through it, at every junction the viaduct
## passes. It is worth a test of its own because the way this fails is silent and total:
## `ConcavePolygonShape3D` collides on its front faces alone, so a deck swept inside-out
## is not a weak floor or a rough one — it is not there, and the first anyone knows is
## walking out onto the viaduct and dropping through it into a box with no way out.
func _stand() -> void:
	var junctions: Array = DECK_AT.get(_site, [])
	if junctions.is_empty():
		return
	var space := get_viewport().world_3d.direct_space_state
	var missed: Array[String] = []
	for id: String in junctions:
		var node: Vector3 = CityLayout.JUNCTIONS[id]
		var at := Vector2(node.x, node.y)
		var up := _plan.direction_at(at)
		var deck := _planet.shape.radius + _plan.pad_height(at) + node.z
		var query := PhysicsRayQueryParameters3D.create(
			_planet.to_global(up * (deck + 3.0)),
			_planet.to_global(up * (deck - 3.0)))
		if space.intersect_ray(query).is_empty():
			missed.append(id)
	print("deck: stood on at %d of %d points along the viaduct" % [
		junctions.size() - missed.size(), junctions.size()])
	if not missed.is_empty():
		push_error("city_test: nothing to stand on over %s" % ", ".join(missed))


## Every road kind in the town as a cross-section, and whether the player can get onto
## it.
##
## Arithmetic rather than geometry, and it belongs here because it is the constraint that
## decides whether a raised city is a city or a set of walled enclosures. A carriageway
## lifted past `step_height` can only be reached up its apron, and only if that apron is
## inside `floor_max_angle`. Both numbers are the player's, neither is in the road code,
## and nothing else in the project would notice them drifting apart.
func _profiles(city: CityBuilder) -> void:
	print("cross-sections, metres:")
	print("  kind         road  walk  kerb  lift  fall  apron  slope   onto it")
	var failed := PackedStringArray()
	for name: String in city.network.kinds:
		var kind: Dictionary = city.network.kinds[name]
		var lift := float(kind["lift"])
		var apron := RoadProfile.apron(kind)
		# The fall, not the lift: a kerbed road's apron carries the footway down, and the
		# footway is a kerb above the carriageway this lift is measured to.
		var fall := RoadProfile.fall(kind)
		var slope := rad_to_deg(atan2(fall, apron))
		var stepped := fall <= STEP_HEIGHT
		var ramped := slope <= FLOOR_MAX_ANGLE
		var verdict := "step up" if stepped else ("walk up" if ramped else "WALLED OFF")
		if bool(kind["deck"]):
			verdict = "viaduct"
		elif not stepped and not ramped:
			failed.append(name)
		print("  %-11s %5.1f %5.1f %5.2f %5.2f %5.2f %6.2f %5.1f deg  %s" % [
			name, kind["road"], kind["walk"], kind["kerb"], lift, fall, apron, slope,
			verdict])
	for name: String in failed:
		push_error(("city_test: a '%s' is lifted past the player's %.2f m step and its "
			+ "edge is steeper than %.0f degrees, so it cannot be walked onto")
			% [name, STEP_HEIGHT, FLOOR_MAX_ANGLE])


## The same question asked of the collision instead of the table: walk out across a real
## road, sampling what is actually under foot, and report the worst step and the worst
## slope found.
##
## This is the one that catches a road floating over the ground rather than meeting it —
## the arithmetic above is happy with an apron that was computed and never built.
##
## The camera is walked to each section first and given a moment. The terrain's colliders
## are built by the quadtree around the viewer, so probing all four sections from orbit
## casts most of its rays through ground that does not exist yet: the first version of
## this reported a third of its samples missing and called it a pass.
## What is under a point on the pad, as metres above the pad itself, or NAN where
## nothing was hit. Dropped from well overhead so a coarse terrain chunk is still caught.
func _under(at: Vector2, space: PhysicsDirectSpaceState3D) -> float:
	var up := _plan.direction_at(at)
	var ground := _planet.shape.radius + _plan.pad_height(at)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
		_planet.to_global(up * (ground + 20.0)),
		_planet.to_global(up * (ground - 20.0))))
	if hit.is_empty():
		return NAN
	return (_planet.to_local(hit["position"] as Vector3).length()
		- _planet.shape.radius) - _plan.pad_height(at)


func _walkable(city: CityBuilder) -> void:
	var sections: Array = CROSS_SECTIONS.get(_site, [])
	if sections.is_empty():
		return
	var space := get_viewport().world_3d.direct_space_state
	print("walking out from each centreline, sampled every 0.25 m:")
	for section: Array in sections:
		var kind: Dictionary = city.network.kinds[String(section[1])]
		var reach := RoadProfile.reach(kind)
		var from: Vector2 = section[2]
		var out: Vector2 = (section[3] as Vector2).normalized()
		var span: float = section[4]
		var samples := int(span / 0.25)
		_camera.global_position = _planet.to_global(
			_plan.surface_at(from + out * span * 0.5, 12.0))
		for _frame in 110:
			await get_tree().process_frame
		var heights := PackedFloat32Array()
		for step in samples + 1:
			heights.append(_under(from + out * (0.25 * float(step)), space))
		var worst_rise := 0.0
		var worst_at := 0.0
		var edge_at := 0.0
		var edge_height := NAN
		for step in heights.size():
			if is_nan(heights[step]):
				continue
			edge_at = 0.25 * float(step)
			edge_height = heights[step]
			if step == 0 or is_nan(heights[step - 1]):
				continue
			var rise := absf(heights[step] - heights[step - 1])
			if rise > worst_rise:
				worst_rise = rise
				worst_at = 0.25 * float(step)
		var slope := rad_to_deg(atan2(worst_rise, 0.25))
		# The last sample is up to a step short of the outer edge and so is still that
		# much of the ramp above the ground. Judge the lip against the ramp it stands on,
		# with a step's slack, and leave catching an apron that was never built to the
		# check below: an unbuilt one is a whole apron short, which no slack covers.
		var left := maxf(0.0, reach - edge_at) + 0.25
		var allowed := left * (RoadProfile.fall(kind) / RoadProfile.apron(kind)) + 0.03
		print(("  %-20s edge %5.2f m out of %5.2f, lip %+.2f m of %+.2f allowed, "
			+ "worst rise %.2f m at %5.2f m (%4.1f deg)") % [section[0], edge_at, reach,
			edge_height, allowed, worst_rise, worst_at, slope])
		# A kerb is meant to be a step and is allowed to be one; anything past the player's
		# own step that is not a kerb is a wall it cannot climb.
		if worst_rise > STEP_HEIGHT + 0.01:
			push_error(("city_test: %s rises %.2f m in 0.25 m at %.2f m out, past the "
				+ "player's %.2f m step") % [section[0], worst_rise, worst_at,
				STEP_HEIGHT])
		# Where the road runs out it has to be at ground level. A lip left standing at the
		# lift is a slab dropped on the pad with a two-foot drop off the side, which is
		# what the apron exists to prevent and what nothing else here would see.
		if is_nan(edge_height) or edge_height > allowed:
			push_error(("city_test: %s ends %.2f m out still %.2f m above the ground, so "
				+ "its apron never reaches it") % [section[0], edge_at, edge_height])
		# And it has to run out where its own cross-section says it does, or the profile
		# the walkability arithmetic trusts is not the profile that got built.
		if edge_at < reach - 0.3 or edge_at > reach + 0.3:
			push_error(("city_test: %s is %.2f m wide from the centreline where its '%s' "
				+ "profile is %.2f m") % [section[0], edge_at, section[1], reach])


# --- The line pass ----------------------------------------------------------

## The centrelines, drawn over the ground: the uncut traces in one colour and the runs
## the crossings left behind in another.
##
## Two passes on purpose. The traces say what the layout table asked for; the runs say
## what survived being cut at every junction. A block whose street vanished shows up here
## as a trace with no run under it, which is a thing the audit also reports as a number
## and which nobody would ever spot in a picture of the built city.
func _draw_lines(city: CityBuilder) -> void:
	var lines := ImmediateMesh.new()
	_draw_set(lines, city.network.traces, TRACE_COLOR, LINE_LIFT + 2.0, city.position)
	_draw_set(lines, city.network.runs, RUN_COLOR, LINE_LIFT, city.position)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	var view := MeshInstance3D.new()
	view.name = "Lines"
	view.mesh = lines
	view.material_override = material
	# The vertices are already in the builder's own frame, which is what this hangs
	# under. Offsetting the node as well put the whole set a second city-radius out.
	city.add_child(view)
	print("lines: %d traces over %d runs, drawn %.0f m up" % [
		city.network.traces.size(), city.network.runs.size(), LINE_LIFT])


func _draw_set(lines: ImmediateMesh, paths: Array[Dictionary], tint: Color,
		lift: float, origin: Vector3) -> void:
	for entry: Dictionary in paths:
		var path: PackedVector3Array = entry["path"]
		if path.size() < 2:
			continue
		lines.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		lines.surface_set_color(tint)
		for point: Vector3 in path:
			var at := Vector2(point.x, point.y)
			lines.surface_add_vertex(_plan.direction_at(at)
				* (_planet.shape.radius + _plan.pad_height(at) + point.z + lift)
				- origin)
		lines.surface_end()


# --- The waypoints, which need the real HUD ---------------------------------

func _waypoints() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# Without a state the world opens its home screen instead of spawning anybody, and
	# there is no player here to park over the city.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())

	var player: OnlinePlayer = null
	for _frame in 30:
		await get_tree().process_frame
		player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if player != null:
			break
	var scene := get_tree().current_scene
	var layer: WaypointLayer = null
	if player != null:
		layer = player.find_child("Waypoints", true, false) as WaypointLayer
	if player == null or layer == null:
		push_error("city_test: player=%s layer=%s" % [player, layer])
		return

	var titles := PackedStringArray()
	for node in get_tree().get_nodes_in_group(Landmark.GROUP):
		titles.append((node as Landmark).title)
	titles.sort()
	print("landmarks (%d)      %s" % [titles.size(), ", ".join(titles)])

	for view: Array in HUD_VIEWS:
		var landmark := _find_landmark(scene, String(view[1]))
		if landmark == null:
			push_error("city_test: no landmark named %s" % view[1])
			continue
		await _hud_shot(layer, player, landmark, str(view[0]), view[2] as float,
			view[3] as float)

	await _ladder(layer, player, _find_landmark(scene, "VacationersLanding"))


## The descent, as the layer sees it. Flown down the town's own up rather than down the
## spawn marker's line — the spawn sits 9 km up and about 17 degrees off the Landing, and
## a player who is going there points at it, so this is both the honest approach and the
## one where altitude and distance are the same number.
##
## Read twice at each height, because the two ranges disagree on purpose and a single
## column would look like a marker flickering. **Aimed** is the descent itself, the town
## under the crosshair all the way down; it is the one that has to come up empty at the
## top. **Aside** is the same height with the town off to one side, which is the ordinary
## question of what the planet has names on from here.
func _ladder(layer: WaypointLayer, player: OnlinePlayer, landmark: Landmark) -> void:
	if landmark == null:
		push_error("city_test: no landmark to descend on")
		return
	print("descent over %s (drawn from %.0f m in, aimed inside %.0f m, gone by %.0f m)" % [
		landmark.title, landmark.hide_beyond, landmark.aimed_beyond, landmark.show_beyond])
	for altitude: float in DESCENT:
		await _pose(player, landmark, altitude, 0.0, 0.12, 60)
		var aimed := layer.drawn()
		await _pose(player, landmark, altitude, 40.0, 0.12, 60)
		var aside := layer.drawn()
		print("  %6.0f m   aimed %-28s aside %s" % [altitude,
			", ".join(aimed) if not aimed.is_empty() else "—",
			", ".join(aside) if not aside.is_empty() else "—"])


## A town's own waypoints are internal children of its [CityBuilder], which `find_child`
## does not walk, so the group is the only way to reach them.
func _find_landmark(scene: Node, wanted: String) -> Landmark:
	var direct := scene.find_child(wanted, true, false) as Landmark
	if direct != null:
		return direct
	for node in get_tree().get_nodes_in_group(Landmark.GROUP):
		if node.name == wanted:
			return node as Landmark
	return null


## Parks the player out along the landmark's own up and points the camera at it, or
## `swing` degrees past it.
func _hud_shot(layer: WaypointLayer, player: OnlinePlayer, landmark: Landmark,
		shot_name: String, altitude: float, swing: float) -> void:
	# Well off to one side, so the marker has somewhere to sit and the ground is seen at
	# an angle rather than as a map. The long hold is the terrain streaming in; the
	# measurements below want a fraction of it.
	await _pose(player, landmark, altitude, swing, 0.8, 260)
	_save(shot_name)
	var named := layer.drawn()
	print("%-20s %6.0f m out, %3.0f deg off   %s"
		% [shot_name, altitude, swing,
			", ".join(named) if not named.is_empty() else "(nothing drawn)"])


## Stands the player [param altitude] up the landmark's own up, [param aside] of that
## altitude to one side of it, looking at it or [param swing] degrees past it.
func _pose(player: OnlinePlayer, landmark: Landmark, altitude: float, swing: float,
		aside: float, frames: int) -> void:
	var up := landmark.global_basis.y
	var across := up.cross(Vector3.UP if absf(up.dot(Vector3.UP)) < 0.9 \
		else Vector3.RIGHT).normalized()
	var eye := landmark.global_position + up * altitude + across * altitude * aside
	var toward := (landmark.global_position - eye).normalized()
	# Swung about whichever axis actually takes the place off the crosshair. Turning
	# about the local up is the one that leaves the horizon level, but from directly
	# overhead the view lies along that axis and the turn is a roll: the place stays dead
	# centre and every reading is the aimed one.
	var axis := up if absf(toward.dot(up)) < 0.9 else across
	var look := toward.rotated(axis, deg_to_rad(swing))
	player.start_flying()
	for _frame in frames:
		await get_tree().process_frame
		# Held rather than placed: the player is still being simulated, and gravity would
		# have it somewhere else by the time the shot is taken.
		player.global_position = eye
		player.velocity = Vector3.ZERO
		player.camera.global_transform = Transform3D(Basis.looking_at(look, up), eye)


# --- Scaffolding ------------------------------------------------------------

## Stands the camera over a point on the town's map, looking toward the centre — or at
## [param target], for a view of one thing rather than of the whole place.
func _shot(shot_name: String, at: Vector2, altitude: float, pitch: float,
		target := Vector2.INF) -> void:
	var up := _plan.direction_at(at)
	var eye := _planet.to_global(up * (_planet.shape.radius + _plan.pad_height(at) + altitude))
	if target != Vector2.INF:
		# Aimed at a thing rather than posed over the town, so the pitch is whatever it
		# takes to have the thing in the middle of the frame.
		_camera.look_at_from_position(eye,
			_planet.to_global(_plan.surface_at(target)), up)
	else:
		var toward := _planet.to_global(_plan.surface_at(Vector2.ZERO)) - eye
		toward -= up * toward.dot(up)
		if toward.length_squared() < 1.0:
			toward = _planet.to_global(_plan.direction_at(Vector2(0.0, 100.0))) - eye
			toward -= up * toward.dot(up)
		toward = toward.normalized()
		var look := (toward * cos(deg_to_rad(pitch)) \
			+ up * sin(deg_to_rad(pitch))).normalized()
		_camera.look_at_from_position(eye, eye + look,
			toward if absf(pitch) > 88.0 else up)
	for _frame in 90:
		await get_tree().process_frame
	_save(shot_name)
	print("%-20s at %8.1v  alt %6.0f m" % [shot_name, at, altitude])


## Matched to the Environment and Sun in game/world.tscn.
func _lighting() -> Node:
	var holder := Node3D.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.55, 0.74, 0.92)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.62, 0.68, 0.78)
	settings.ambient_light_energy = 0.38
	settings.tonemap_mode = Environment.TONE_MAPPER_ACES
	settings.tonemap_white = 2.0
	settings.glow_enabled = true
	settings.glow_intensity = 0.7
	settings.glow_hdr_threshold = 0.95
	var world_environment := WorldEnvironment.new()
	world_environment.environment = settings
	holder.add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.shadow_blur = 0.0
	sun.directional_shadow_max_distance = 400.0
	holder.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -Vector3(-0.3501, 0.3201, 0.8803), Vector3.UP)
	return holder


func _save(shot_name: String) -> void:
	get_viewport().get_texture().get_image().save_png(
		ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png"))
