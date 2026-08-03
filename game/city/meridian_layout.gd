@tool
class_name MeridianLayout
extends RefCounted

## Meridian Flats, as data: a planned town on one level, out on the sunlit plain.
##
## The same shape of table as [CityLayout] and deliberately the opposite kind of
## place. Vacationer's Landing grew on a coastal shelf: it is graded down 78 m from
## its bluffs to the water, its main roads bow round the terrain, and it carries
## viaducts because a hillside gives you somewhere to run them. This one was
## surveyed onto flat ground by `dev/_city_site.gd` and drawn with a ruler — one
## level throughout, a ring road that is a rounded square, two straight axes
## crossing at a market square, and a downtown grid canted off those axes so it
## reads as its own quarter.
##
## That contrast is the point. Two towns built by the same code and looking like the
## same town would mean the layout tables are not carrying enough, and the second
## one exists partly to find out. It is also the harder test of [RoadNetwork]: the
## canted grid meets the square ring and the straight axes at every angle there is,
## and a diagonal promenade crosses the lot, so the acute junctions the first city
## never had are all here.
##
## Coordinates are metres in the city's own frame, origin at the market square, +y
## north and +x east. [b]The roads stand two feet above the ground[/b], which is a
## request and has a cost — see [constant LIFT].

# --- The site ---------------------------------------------------------------

## Where the town stands, as a direction from the planet's centre. Found by
## [code]dev/_city_site.gd --core=700 --rim=300 --sun=40 --apart=25 --skip=meridian[/code]:
## an upland plateau at 119 m, 38 degrees round the planet from Vacationer's Landing and
## on the same hemisphere the spawn markers look down, with the sun 43.5 degrees up over
## it at noon.
##
## It is the flattest dry ground that meets those limits and it is still not flat: 16 m
## of cut and fill on average, 72 m between its highest and lowest corner. That is what
## this planet's uplands are — the same probe over a footprint half the area only reaches
## 11 m, and the one genuinely level surface on the whole sphere is the polar ice, which
## the probe now refuses for the obvious reason.
const CENTRE := Vector3(0.3540399, -0.0313069, 0.9347062)

## Degrees about the local up. Zero: there is no coast to face and no reason to turn
## the grid off the frame it is written in, which is itself the difference from the
## first city.
const FACING := 0.0

## Half the footprint, the band outside it spent blending back into the terrain, and the
## corner rounding on both.
##
## The rim is wider than the first city's, which is the price of one level. A graded pad
## spreads the height it has to lose along its own slope; a flat one has to lose all of
## it across the rim, and 300 m puts the worst embankment at about seven degrees instead
## of nine.
const CORE := 700.0
const RIM := 300.0
const CORNER := 260.0

## How far out the pad can possibly reach, which is the cap [CityPlan] tests against
## before doing any city work at all. The rounded footprint's diagonal runs to
## [constant CORE] minus [constant CORNER], root two, plus [constant CORNER]; the rim
## and a little slack go on top.
const REACH := 1250.0

## The one height the whole city sits at, in metres above sea level: the mean of the
## natural ground under the footprint, so the pad cuts and fills about equally rather
## than standing on a plinth or sitting in a pit. One knot, which is the whole of what
## makes this a flat city — see [member CityPlan.grade].
const LEVEL := 119.0


# --- Streets ----------------------------------------------------------------

## How far a carriageway stands above the ground, in metres. Two feet, as asked.
##
## This is six times the first city's kerbline and it is not free. [OnlinePlayer]
## steps up [code]step_height[/code] 0.3 m, so a body cannot get onto this at all
## except up a slope — which is why [method RoadProfile.apron] grows the ramp at each
## road's edge out of the lift instead of using a fixed chamfer, and why every road
## here is 1.06 m wider on each side than its carriageway and footway account for.
## Drop this below 0.3 and that metre of ramp collapses back to the 0.45 m scuff the
## first city uses.
##
## The pedestrian ways do not take it. A park path standing two feet off the grass is
## a causeway, and "the roads" was the request.
const LIFT := 0.61
const WALK_LIFT := 0.22

## What each kind of road is made of, in metres. [RoadProfile] is the authority on
## the fields.
##
## Two grades of street, on purpose. [code]boulevard[/code], [code]avenue[/code] and
## [code]street[/code] carry a proper footway either side with a kerb to step off;
## [code]lane[/code] is one lane of tarmac and nothing else, which is what a
## residential close and a service road behind a nightclub actually are. The
## difference is one field, [code]walk[/code], and everything downstream — the
## profile, the junction rim, the kerb that turns a corner — follows from it.
const KINDS := {
	"boulevard": {"road": 18.0, "walk": 3.6, "kerb": 0.18, "lift": LIFT,
		"tone": "asphalt", "deck": false},
	"avenue": {"road": 9.5, "walk": 2.8, "kerb": 0.17, "lift": LIFT,
		"tone": "asphalt", "deck": false},
	"street": {"road": 7.0, "walk": 2.4, "kerb": 0.16, "lift": LIFT,
		"tone": "asphalt", "deck": false},
	"lane": {"road": 4.2, "walk": 0.0, "kerb": 0.0, "lift": LIFT,
		"tone": "asphalt", "deck": false},
	"promenade": {"road": 9.0, "walk": 0.0, "kerb": 0.0, "lift": WALK_LIFT,
		"tone": "paving", "deck": false},
	"path": {"road": 3.0, "walk": 0.0, "kerb": 0.0, "lift": WALK_LIFT,
		"tone": "paving", "deck": false},
}


# --- Zoning -----------------------------------------------------------------

## The five quarters, painted in order, so a later one wins where two overlap — which
## is how the park bites into the residential belt without either being described as
## a polygon with a piece missing.
const DISTRICTS: Array[Dictionary] = [
	{"name": "Willow Park", "kind": "box", "at": Vector2(-390.0, 20.0),
		"size": Vector2(460.0, 900.0), "turn": 0.0, "round": 180.0,
		"color": CityPlan.SUBURB},
	{"name": "The Exchange", "kind": "box", "at": Vector2(260.0, 270.0),
		"size": Vector2(420.0, 440.0), "turn": 18.0, "round": 40.0,
		"color": CityPlan.CONCRETE},
	{"name": "The Neon", "kind": "box", "at": Vector2(300.0, -330.0),
		"size": Vector2(560.0, 360.0), "turn": -22.0, "round": 70.0,
		"color": CityPlan.NIGHTLIFE},
	{"name": "Meadow Park", "kind": "disc", "at": Vector2(-250.0, 430.0),
		"size": Vector2(250.0, 250.0), "turn": 0.0, "round": 0.0,
		"color": CityPlan.LAWN},
	{"name": "Market Square", "kind": "disc", "at": Vector2(0.0, 0.0),
		"size": Vector2(110.0, 110.0), "turn": 0.0, "round": 0.0,
		"color": CityPlan.STONE},
]

const FEATHER := 30.0


# --- Junctions --------------------------------------------------------------

## Every junction the tables name: x and y on the map, z metres above the ground.
##
## Every z is zero, and that is the whole of "one level". The first city's skyway
## nodes sit at 9 and carry a viaduct; nothing here leaves the ground, so nothing
## here needs a soffit, a parapet or a leg.
const JUNCTIONS := {
	# The ring road: a rounded square rather than a loop that follows anything,
	# because there is nothing out here to follow. Sixteen nodes, so the corners are
	# chamfered instead of mitred to a point, and one extra on the east face —
	# `ring_gate_e` — purely so the lane out of the nightclub can meet it square. A
	# road arriving at a chamfer corner meets the two ring arms at about 35 degrees
	# and the junction has to chamfer straight across; arriving mid-face it is a
	# proper tee.
	"ring_e": Vector3(580.0, 0.0, 0.0),
	"ring_ene": Vector3(580.0, 300.0, 0.0),
	"ring_ne": Vector3(500.0, 500.0, 0.0),
	"ring_nne": Vector3(300.0, 580.0, 0.0),
	"ring_n": Vector3(0.0, 580.0, 0.0),
	"ring_nnw": Vector3(-300.0, 580.0, 0.0),
	"ring_nw": Vector3(-500.0, 500.0, 0.0),
	"ring_wnw": Vector3(-580.0, 300.0, 0.0),
	"ring_w": Vector3(-580.0, 0.0, 0.0),
	"ring_wsw": Vector3(-580.0, -300.0, 0.0),
	"ring_sw": Vector3(-500.0, -500.0, 0.0),
	"ring_ssw": Vector3(-300.0, -580.0, 0.0),
	"ring_s": Vector3(0.0, -580.0, 0.0),
	"ring_sse": Vector3(300.0, -580.0, 0.0),
	"ring_se": Vector3(500.0, -500.0, 0.0),
	"ring_ese": Vector3(580.0, -300.0, 0.0),
	"ring_gate_e": Vector3(580.0, -190.0, 0.0),

	# The two axes and the square they cross at. Six roads leave the square, and they
	# are spaced at 45 degrees on purpose: six arms in a circle average 60 apart, and
	# a rim built from arms much closer than 45 spends its corners chamfering instead
	# of turning.
	"plaza": Vector3(0.0, 0.0, 0.0),
	"mw": Vector3(-400.0, 0.0, 0.0),
	"me": Vector3(290.0, 0.0, 0.0),
	"mn": Vector3(0.0, 290.0, 0.0),
	"ms": Vector3(0.0, -290.0, 0.0),

	# Willow Park: a crescent off the ring's west face with three closes hanging from
	# it. Every close is a cul-de-sac, which is what gets the rounded head swept.
	"wc_1": Vector3(-430.0, -170.0, 0.0),
	"wc_2": Vector3(-405.0, -60.0, 0.0),
	"wc_3": Vector3(-430.0, 190.0, 0.0),
	"alder_1": Vector3(-300.0, -230.0, 0.0),
	"alder_2": Vector3(-210.0, -300.0, 0.0),
	"birch_1": Vector3(-260.0, -90.0, 0.0),
	"birch_2": Vector3(-190.0, -160.0, 0.0),
	"cedar_1": Vector3(-300.0, 150.0, 0.0),
	"cedar_2": Vector3(-215.0, 90.0, 0.0),

	# The Neon: a pedestrian strip with a service lane behind it and one lane out to
	# the ring. Nobody drives down the strip itself.
	"neon_1": Vector3(170.0, -290.0, 0.0),
	"neon_2": Vector3(340.0, -330.0, 0.0),
	"neon_3": Vector3(480.0, -395.0, 0.0),
	"neon_yard": Vector3(320.0, -450.0, 0.0),
	"backlot": Vector3(505.0, -190.0, 0.0),

	# Meadow Park and the walk out to it. Paths only.
	"walk_1": Vector3(-120.0, 370.0, 0.0),
	"walk_2": Vector3(-250.0, 430.0, 0.0),
	"walk_3": Vector3(-370.0, 400.0, 0.0),
	"lake_1": Vector3(-190.0, 500.0, 0.0),
	"lake_2": Vector3(-300.0, 520.0, 0.0),
	"lake_3": Vector3(-345.0, 440.0, 0.0),
	"market_1": Vector3(-100.0, 100.0, 0.0),
	"market_2": Vector3(-175.0, 255.0, 0.0),

	# The one node the downtown grid is reached by that is not in the grid, put where
	# it is so the approach leaves the square at 45 degrees and not at 28.
	"approach": Vector3(120.0, 120.0, 0.0),
}


# --- Roads ------------------------------------------------------------------

const ROADS: Array[Dictionary] = [
	{"name": "Ring Road", "kind": "boulevard", "loop": true,
		"nodes": ["ring_e", "ring_ene", "ring_ne", "ring_nne", "ring_n",
			"ring_nnw", "ring_nw", "ring_wnw", "ring_w", "ring_wsw", "ring_sw",
			"ring_ssw", "ring_s", "ring_sse", "ring_se", "ring_ese",
			"ring_gate_e"]},
	{"name": "Meridian Boulevard", "kind": "boulevard",
		"nodes": ["ring_w", "mw", "plaza", "me", "ring_e"]},
	{"name": "Axis Avenue", "kind": "avenue",
		"nodes": ["ring_s", "ms", "plaza", "mn", "ring_n"]},

	# Willow Park. The crescent bows west so the belt reads as laid out round
	# something rather than as a road with houses on it; the closes are lanes, one
	# lane wide and no footway, which is what a close is.
	{"name": "Willow Crescent", "kind": "street",
		"nodes": ["ring_wsw", "wc_1", "wc_2", "mw", "wc_3", "ring_wnw"],
		"bend": [-20.0, -12.0, -8.0, 12.0, 20.0]},
	{"name": "Alder Close", "kind": "lane", "dead_end": true,
		"nodes": ["wc_1", "alder_1", "alder_2"]},
	{"name": "Birch Close", "kind": "lane", "dead_end": true,
		"nodes": ["wc_2", "birch_1", "birch_2"]},
	{"name": "Cedar Close", "kind": "lane", "dead_end": true,
		"nodes": ["wc_3", "cedar_1", "cedar_2"]},

	# The Neon. The strip is a promenade, so the nightclub quarter is somewhere you
	# walk; the traffic is kept to a service lane off the ring's south face and one
	# lane out to its east face.
	{"name": "Neon Walk", "kind": "promenade",
		"nodes": ["ms", "neon_1", "neon_2", "neon_3"],
		"bend": [0.0, -18.0, -12.0]},
	{"name": "Neon Service", "kind": "lane",
		"nodes": ["ring_sse", "neon_yard", "neon_2"]},
	{"name": "Backlot Lane", "kind": "lane",
		"nodes": ["neon_3", "backlot", "ring_gate_e"]},

	# Meadow Park. Paths and a promenade, nothing a car can use, and the loop round
	# the lawn is the only closed ring in the city apart from the ring road.
	{"name": "Park Walk", "kind": "path",
		"nodes": ["mn", "walk_1", "walk_2", "walk_3", "wc_3"],
		"bend": [14.0, 10.0, -12.0, -18.0]},
	{"name": "Lakeside Loop", "kind": "path", "loop": true,
		"nodes": ["walk_2", "lake_1", "lake_2", "lake_3"],
		"bend": [12.0, 10.0, 12.0, 10.0]},
	{"name": "Market Walk", "kind": "promenade",
		"nodes": ["plaza", "market_1", "market_2", "walk_2"],
		"bend": [0.0, -10.0, -14.0]},

	# Downtown's three approaches. Each one meets a named node on an axis rather than
	# running into the side of it, which is the difference between a junction and a
	# road laid across another road.
	{"name": "Exchange Approach", "kind": "avenue",
		"nodes": ["plaza", "approach", "dt_0_0"], "bend": [0.0, 14.0]},
	{"name": "Bourse Avenue", "kind": "avenue", "nodes": ["me", "dt_3_0"]},
	{"name": "North Reach", "kind": "avenue", "nodes": ["mn", "dt_0_3"]},
	{"name": "Exchange Spur", "kind": "street", "nodes": ["dt_3_3", "ring_ne"]},
]


# --- Downtown ---------------------------------------------------------------

## The Exchange is the one quarter that wants a grid, and a grid is better counted
## than typed.
##
## Canted 18 degrees off the city's own axes, which is the whole reason it is here:
## every road that reaches it arrives at some angle nobody chose, and those are the
## junctions that find the faults in [RoadMesh]'s mitring. Blocks are 90 by 93 m,
## which is tight — a tower and a light well, against the first city's 160 by 120 of
## tower and service yard.
const GRID_AT := Vector2(260.0, 270.0)
const GRID_TURN := 18.0
const GRID_ACROSS: Array[float] = [-135.0, -45.0, 45.0, 135.0]
const GRID_ALONG: Array[float] = [-140.0, -47.0, 47.0, 140.0]


## This city's ground, as the terrain wants it.
static func plan() -> CityPlan:
	var made := CityPlan.new()
	made.title = "Meridian Flats"
	made.centre = CENTRE
	made.facing = FACING
	made.core = CORE
	made.rim = RIM
	made.corner = CORNER
	made.reach = REACH
	made.grade = [Vector2(0.0, LEVEL)] as Array[Vector2]
	made.ground_color = CityPlan.GROUND
	made.districts = DISTRICTS
	made.feather = FEATHER
	return made


## This city's streets, resolved into lines.
static func network() -> RoadNetwork:
	return RoadNetwork.new(graph(), KINDS)


## The whole network, junctions and roads together, with the grid counted in.
static func graph() -> Dictionary:
	var nodes := {}
	for id: String in JUNCTIONS:
		nodes[id] = JUNCTIONS[id] as Vector3
	var roads: Array[Dictionary] = []

	var turn := deg_to_rad(GRID_TURN)
	var across := Vector2(cos(turn), sin(turn))
	var along := Vector2(-sin(turn), cos(turn))
	for column in GRID_ACROSS.size():
		for row in GRID_ALONG.size():
			var at := GRID_AT + across * GRID_ACROSS[column] \
				+ along * GRID_ALONG[row]
			nodes["dt_%d_%d" % [column, row]] = Vector3(at.x, at.y, 0.0)
	# Avenues run the way the quarter is canted, streets across it, so a block reads
	# as a block and the grain of downtown is visible from the air.
	for column in GRID_ACROSS.size():
		var up_chain: Array[String] = []
		for row in GRID_ALONG.size():
			up_chain.append("dt_%d_%d" % [column, row])
		roads.append({"name": "Exchange Avenue %d" % column, "kind": "avenue",
			"nodes": up_chain})
	for row in GRID_ALONG.size():
		var across_chain: Array[String] = []
		for column in GRID_ACROSS.size():
			across_chain.append("dt_%d_%d" % [column, row])
		roads.append({"name": "Exchange Street %d" % row, "kind": "street",
			"nodes": across_chain})

	for road: Dictionary in ROADS:
		roads.append(road)
	return {"nodes": nodes, "roads": roads}


## Places worth a waypoint, as map coordinates. [CityBuilder] turns these into
## [Landmark]s, which is why they are here and not as hand-computed direction vectors
## in `game/world.tscn` — a district that moves takes its own sign with it.
##
## [code]clearance[/code] lifts the marker off the ground so it reads over the roofs
## a quarter will eventually have.
##
## Six of these stand within 500 m of each other, so they are ranged as a set rather
## than each on its own merits: the town's own name carries the default far cutoff
## and the districts inside it drop out a good deal earlier. Give them all the same
## reach and arriving at Meridian means six labels landing in one stack, naming
## quarters that are still a single grey patch.
const WAYPOINTS: Array[Dictionary] = [
	{"name": "MeridianFlats", "title": "Meridian Flats", "at": Vector2(0.0, 0.0),
		"clearance": 30.0, "tint": Color(0.92, 0.78, 0.36), "show_beyond": 2000.0,
		"aimed_beyond": 3000.0},
	{"name": "TheExchange", "title": "The Exchange", "at": Vector2(260.0, 270.0),
		"clearance": 18.0, "tint": Color(0.72, 0.76, 0.84), "show_beyond": 900.0,
		"aimed_beyond": 1600.0, "hide_beyond": 2800.0},
	{"name": "TheNeon", "title": "The Neon", "at": Vector2(300.0, -330.0),
		"clearance": 14.0, "tint": Color(0.85, 0.46, 0.78), "show_beyond": 900.0,
		"aimed_beyond": 1600.0, "hide_beyond": 2800.0},
	{"name": "WillowPark", "title": "Willow Park", "at": Vector2(-390.0, 20.0),
		"clearance": 12.0, "tint": Color(0.62, 0.74, 0.48), "show_beyond": 900.0,
		"aimed_beyond": 1600.0, "hide_beyond": 2800.0},
	{"name": "MeadowPark", "title": "Meadow Park", "at": Vector2(-250.0, 430.0),
		"clearance": 12.0, "tint": Color(0.44, 0.78, 0.42), "show_beyond": 900.0,
		"aimed_beyond": 1600.0, "hide_beyond": 2800.0},
	{"name": "MarketSquare", "title": "Market Square", "at": Vector2(0.0, 0.0),
		"clearance": 6.0, "tint": Color(0.86, 0.82, 0.68), "show_beyond": 0.0,
		"aimed_beyond": 1200.0, "hide_beyond": 900.0},
]
