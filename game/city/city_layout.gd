@tool
class_name CityLayout
extends RefCounted

## Vacationer's Landing, as data: where it sits on the planet, how its ground is
## graded, what each district is, and the graph of streets that connects them.
##
## Nothing here does anything. [method plan] hands the site and the districts to a
## [CityPlan], which becomes a height field and a zoning raster; [method network]
## hands the road graph to a [RoadNetwork], which becomes lines and then meshes. A
## different city is a different table of the same shape — see [MeridianLayout],
## which is one — and [Settlements] is the list of them.
##
## All coordinates are metres in the city's own tangent frame, origin at the pad
## centre, [b]+y inland and -y out to sea[/b], +x to the local east. The frame is
## built once by [CityPlan] and is the only place the sphere shows through — a
## road here is written as if the ground were a sheet of paper.

# --- The site ---------------------------------------------------------------

## Where the city stands, as a direction from the planet's centre. Found by
## dev/_city_site.gd: the flattest coastal shelf inside the cone the spawn
## markers look down, 17 degrees off their line of sight with the sun 70 degrees
## up over it. The ground under it is an amphitheatre — bluffs climbing to 130 m
## on the east, north and west, one opening to the sea on the south — which is
## why the pad has to be graded rather than levelled.
const CENTRE := Vector3(-0.2958888, -0.0139250, 0.9551209)

## Degrees about the local up, in the same sense [SurfaceAnchor] uses, that turns
## the city's -y to face the water.
const FACING := -95.0

## Half the footprint, and the band outside it spent blending back into the
## untouched terrain.
const CORE := 900.0
const RIM := 260.0
## Corner rounding on the footprint. Square enough for a rectangular layout to
## use, round enough that the rim does not meet the terrain in four points.
const CORNER := 320.0

## How far out the pad can possibly reach, which is the cap [CityPlan] tests
## against before doing any city work at all. The rounded footprint's diagonal
## runs to CORE - CORNER, root two, plus CORNER; the rim and a little slack go
## on top of that.
const REACH := 1500.0


# --- The graded pad ---------------------------------------------------------

## The city's ground, as height above sea level against distance inland.
##
## Not one level. The shelf falls about 115 m from the inland bluffs to the
## waterline, and a single flat slab across that would either bury the beach
## under a 60 m sea wall or leave a 60 m cut across the top of the city. So the
## pad follows the shelf's own fall instead, spreading the cut and fill along it.
##
## Knots average 4.7% and the smooth interpolation between them peaks at 8% —
## steep for a driveway, ordinary for a hill street, and under five degrees, so
## it reads as flat underfoot. Across the other axis the pad is dead level, which
## is what turns the shelf into an amphitheatre facing the water.
##
## Roads inherit this for free: [CityBuilder] asks for the pad height at every
## station, so a street crossing the grade slopes with it.
const GRADE: Array[Vector2] = [
	Vector2(-900.0, 12.0),
	Vector2(-600.0, 26.0),
	Vector2(-300.0, 37.0),
	Vector2(0.0, 48.0),
	Vector2(300.0, 60.0),
	Vector2(600.0, 74.0),
	Vector2(900.0, 90.0),
]


# --- Zoning -----------------------------------------------------------------

# The zoning colours this city uses, named locally so the table below reads as a
# plan. The values live on [CityPlan], which is what every town's districts are
# painted through — two towns inventing their own grey for concrete is how a planet
# stops looking like one place.
const GROUND := CityPlan.GROUND
const SAND := CityPlan.SAND
const WHARF := CityPlan.WHARF
const NIGHTLIFE := CityPlan.NIGHTLIFE
const CONCRETE := CityPlan.CONCRETE
const STONE := CityPlan.STONE
const LAWN := CityPlan.LAWN
const SUBURB := CityPlan.SUBURB
const SCRUB := CityPlan.SCRUB

## Districts, as rounded boxes and discs in the city frame. `turn` is degrees
## anticlockwise; `round` is the corner radius on a box and is ignored on a disc.
##
## The order is the order they are painted, so a later entry wins where two
## overlap — which is how the park's lawn cuts into the residential belt without
## either having to be described as a polygon with a bite out of it.
const DISTRICTS: Array[Dictionary] = [
	{"name": "Beachfront", "kind": "box", "at": Vector2(0.0, -800.0),
		"size": Vector2(1700.0, 260.0), "turn": 0.0, "round": 80.0, "color": SAND},
	{"name": "Marina", "kind": "box", "at": Vector2(-610.0, -830.0),
		"size": Vector2(440.0, 210.0), "turn": 0.0, "round": 60.0, "color": WHARF},
	{"name": "Harbour", "kind": "box", "at": Vector2(-620.0, -580.0),
		"size": Vector2(520.0, 440.0), "turn": 0.0, "round": 60.0, "color": WHARF},
	{"name": "The Strand", "kind": "box", "at": Vector2(-40.0, -540.0),
		"size": Vector2(640.0, 300.0), "turn": 0.0, "round": 90.0, "color": NIGHTLIFE},
	{"name": "Downtown", "kind": "box", "at": Vector2(390.0, -120.0),
		"size": Vector2(620.0, 700.0), "turn": -12.0, "round": 40.0, "color": CONCRETE},
	{"name": "Civic", "kind": "box", "at": Vector2(55.0, 140.0),
		"size": Vector2(330.0, 420.0), "turn": 8.0, "round": 60.0, "color": STONE},
	{"name": "Residential", "kind": "box", "at": Vector2(-180.0, 560.0),
		"size": Vector2(1120.0, 480.0), "turn": 0.0, "round": 140.0, "color": SUBURB},
	{"name": "Hillside", "kind": "box", "at": Vector2(640.0, 430.0),
		"size": Vector2(440.0, 600.0), "turn": 10.0, "round": 120.0, "color": SCRUB},
	{"name": "Central Park", "kind": "disc", "at": Vector2(-330.0, 60.0),
		"size": Vector2(340.0, 340.0), "turn": 0.0, "round": 0.0, "color": LAWN},
]

## Metres a district's colour takes to fade into its neighbour. Wide enough that
## the boundary does not alias on a raster sampled every 11 m, narrow enough to
## still read as a boundary from orbit.
const FEATHER := 30.0


# --- Streets ----------------------------------------------------------------

## What each kind of road is made of, in metres. [RoadProfile] is the authority on
## the fields; these are this city's values for them.
##
## Every lift here is well inside the player's [code]FOOT_REACH[/code], so a body
## standing on a kerbline never argues with the ground guard and no road needs a
## ramp to get onto. That is a property of these numbers and not of the system —
## [MeridianLayout] lifts its carriageways two feet and pays for it in apron.
const KINDS := {
	"skyway": {"road": 15.0, "walk": 0.0, "kerb": 0.0, "lift": 0.0,
		"tone": "asphalt", "deck": true},
	"ramp": {"road": 9.0, "walk": 0.0, "kerb": 0.0, "lift": 0.0,
		"tone": "asphalt", "deck": true},
	"boulevard": {"road": 18.0, "walk": 3.6, "kerb": 0.18, "lift": 0.10,
		"tone": "asphalt", "deck": false},
	"avenue": {"road": 9.5, "walk": 2.8, "kerb": 0.17, "lift": 0.10,
		"tone": "asphalt", "deck": false},
	"street": {"road": 7.0, "walk": 2.2, "kerb": 0.16, "lift": 0.10,
		"tone": "asphalt", "deck": false},
	"lane": {"road": 4.5, "walk": 1.6, "kerb": 0.15, "lift": 0.10,
		"tone": "asphalt", "deck": false},
	"promenade": {"road": 10.0, "walk": 0.0, "kerb": 0.0, "lift": 0.24,
		"tone": "paving", "deck": false},
	"path": {"road": 3.0, "walk": 0.0, "kerb": 0.0, "lift": 0.14,
		"tone": "paving", "deck": false},
}

## Every junction in the city: x and y on the map, z metres above the pad.
##
## This is the whole reason the network cannot come apart. A road is a list of
## these names, so two roads that meet at a junction are holding the same point
## by construction rather than by two authors typing the same coordinates. The
## only way to disconnect the city is to write a name nothing else uses, and
## [method validate] fails on exactly that.
const JUNCTIONS := {
	# Shore Drive, along the top of the beach. Doubles as the Landing Loop's
	# southern arc, so the seafront is on the ring road rather than behind it.
	"sd_w": Vector3(-720.0, -700.0, 0.0),
	"sd_m": Vector3(-380.0, -740.0, 0.0),
	"sd_c": Vector3(0.0, -760.0, 0.0),
	"sd_e": Vector3(330.0, -740.0, 0.0),
	"sd_x": Vector3(620.0, -680.0, 0.0),
	"sd_ne": Vector3(800.0, -480.0, 0.0),

	# The rest of the Landing Loop. Every district touches it, so nowhere in the
	# city is more than one turn from a way out.
	"ll_e": Vector3(830.0, -120.0, 0.0),
	"re": Vector3(855.0, 60.0, 0.0),
	"ll_ne": Vector3(800.0, 260.0, 0.0),
	"ll_n2": Vector3(640.0, 590.0, 0.0),
	"ll_n": Vector3(250.0, 790.0, 0.0),
	"ll_nw": Vector3(-250.0, 800.0, 0.0),
	"ll_w2": Vector3(-640.0, 640.0, 0.0),
	"ll_w": Vector3(-820.0, 260.0, 0.0),
	"rw": Vector3(-825.0, 60.0, 0.0),
	"ll_sw": Vector3(-840.0, -140.0, 0.0),
	# The loop's last corner before the shore. It exists to carry the ring around
	# the *outside* of the harbour block: the straight run from ll_sw to sd_w lies
	# along Crane Street and then across the mouth of Dock Road.
	"ll_hb": Vector3(-880.0, -640.0, 0.0),

	# Vacationer's Boulevard, the spine from the sand to the hills.
	"vb_1": Vector3(30.0, -540.0, 0.0),
	"vb_2": Vector3(60.0, -350.0, 0.0),
	"vb_3": Vector3(80.0, -170.0, 0.0),
	"vb_4": Vector3(100.0, 40.0, 0.0),
	"vb_5": Vector3(120.0, 250.0, 0.0),
	"vb_6": Vector3(100.0, 460.0, 0.0),

	# Park Circuit. The park has no roads in it, so the ring is how anything gets
	# past, and the two paths across it are for feet only.
	"pc_e": Vector3(-10.0, 60.0, 0.0),
	"pc_ne": Vector3(-120.0, 340.0, 0.0),
	"pc_n": Vector3(-380.0, 430.0, 0.0),
	"pc_nw": Vector3(-640.0, 340.0, 0.0),
	"pc_w": Vector3(-750.0, 60.0, 0.0),
	"pc_sw": Vector3(-640.0, -220.0, 0.0),
	"pc_s": Vector3(-380.0, -310.0, 0.0),
	"pc_se": Vector3(-120.0, -220.0, 0.0),
	"pk_c": Vector3(-380.0, 60.0, 0.0),

	# The Strand. Three gates on the road network and nothing but promenade
	# inside them, which is what makes the bar quarter walkable.
	"st_w": Vector3(-380.0, -540.0, 0.0),
	"st_n": Vector3(-40.0, -370.0, 0.0),
	"st_e": Vector3(300.0, -520.0, 0.0),
	"sp_1": Vector3(-240.0, -580.0, 0.0),
	"sp_2": Vector3(-100.0, -470.0, 0.0),
	"sp_3": Vector3(90.0, -570.0, 0.0),

	# Harbour: a block of service roads behind the wharves.
	"hb_1": Vector3(-780.0, -420.0, 0.0),
	"hb_2": Vector3(-560.0, -400.0, 0.0),
	"hb_3": Vector3(-800.0, -600.0, 0.0),
	"hb_4": Vector3(-580.0, -610.0, 0.0),

	# Down onto the sand. All dead ends, which is what a beach access is.
	"mr_1": Vector3(-610.0, -860.0, 0.0),
	"ba_1": Vector3(-380.0, -880.0, 0.0),
	"ba_2": Vector3(0.0, -870.0, 0.0),
	"ba_3": Vector3(330.0, -870.0, 0.0),

	# Residential: two curving collectors, a rung between them, and cul-de-sacs
	# hanging off both.
	"rs_a1": Vector3(-560.0, 420.0, 0.0),
	"rs_a2": Vector3(-380.0, 520.0, 0.0),
	"rs_a3": Vector3(-150.0, 560.0, 0.0),
	"rs_a4": Vector3(80.0, 540.0, 0.0),
	"rs_a5": Vector3(280.0, 470.0, 0.0),
	"rs_b1": Vector3(-500.0, 680.0, 0.0),
	"rs_b2": Vector3(-250.0, 730.0, 0.0),
	"rs_b3": Vector3(60.0, 720.0, 0.0),
	"rs_b4": Vector3(270.0, 650.0, 0.0),
	"cds_1": Vector3(-680.0, 330.0, 0.0),
	"cds_2": Vector3(-290.0, 400.0, 0.0),
	"cds_3": Vector3(160.0, 390.0, 0.0),
	# These two hang back into the block between the collectors rather than north
	# off Collector B. There is only about 60 m between B and the ring up there,
	# which is not a cul-de-sac, and both used to end outside the ring entirely.
	"cds_4": Vector3(-430.0, 570.0, 0.0),
	"cds_5": Vector3(150.0, 610.0, 0.0),

	# Hillside, switchbacking up the eastern bluff.
	"hs_1": Vector3(490.0, 210.0, 0.0),
	"hs_2": Vector3(760.0, 330.0, 0.0),
	"hs_3": Vector3(480.0, 420.0, 0.0),
	# The top two are pulled inside the ring, which the bluff's own turns used to
	# swing out through. hs_5 also came down on Northeast Gate's line, so the
	# switchback's head and the road under it were the same ground.
	"hs_4": Vector3(670.0, 520.0, 0.0),
	"hs_5": Vector3(520.0, 660.0, 0.0),

	# The Skyway, nine metres up, crossing the city east to west over downtown's
	# north edge and the top of the park. Deliberately over the park rather than
	# through it: an elevated road is the only kind that can cross open ground
	# without taking it away.
	"sk_e": Vector3(700.0, 120.0, 9.0),
	"sk_1": Vector3(420.0, 250.0, 9.0),
	"sk_2": Vector3(60.0, 330.0, 9.0),
	"sk_3": Vector3(-320.0, 390.0, 9.0),
	"sk_w": Vector3(-660.0, 330.0, 9.0),

	# Coast Expressway, seven metres up over the harbour and the marina.
	"ce_e": Vector3(-180.0, -720.0, 7.0),
	"ce_m": Vector3(-620.0, -660.0, 7.0),
	"ce_w": Vector3(-830.0, -480.0, 7.0),
}

## The streets themselves. [code]nodes[/code] is a chain through [constant
## JUNCTIONS]; [code]bend[/code] is an optional sideways push on each segment's
## midpoint in metres, which is what curves a road without needing a spline
## editor. Positive bends left of the direction of travel.
##
## [code]loop[/code] closes the chain back onto its first junction.
const ROADS: Array[Dictionary] = [
	{"name": "Shore Drive", "kind": "boulevard",
		"nodes": ["sd_w", "sd_m", "sd_c", "sd_e", "sd_x", "sd_ne"],
		"bend": [26.0, 20.0, 20.0, 26.0, 34.0]},
	{"name": "Landing Loop", "kind": "avenue",
		"nodes": ["sd_ne", "ll_e", "re", "ll_ne", "ll_n2", "ll_n", "ll_nw",
			"ll_w2", "ll_w", "rw", "ll_sw", "ll_hb", "sd_w"],
		"bend": [24.0, 8.0, 12.0, 30.0, 40.0, 26.0, 40.0, 30.0, 8.0, 12.0, 24.0,
			0.0]},
	{"name": "Vacationer's Boulevard", "kind": "boulevard",
		"nodes": ["sd_c", "vb_1", "vb_2", "vb_3", "vb_4", "vb_5", "vb_6", "rs_a4"],
		"bend": [10.0, -8.0, 6.0, -6.0, 8.0, -10.0, 0.0]},

	{"name": "Park Circuit", "kind": "avenue", "loop": true,
		"nodes": ["pc_e", "pc_ne", "pc_n", "pc_nw", "pc_w", "pc_sw", "pc_s", "pc_se"],
		"bend": [-22.0, -22.0, -22.0, -22.0, -22.0, -22.0, -22.0, -22.0]},
	{"name": "Park Gate", "kind": "street", "nodes": ["pc_e", "vb_4"]},
	{"name": "Lawn Walk", "kind": "path", "nodes": ["pc_se", "pk_c", "pc_nw"]},
	{"name": "Playground Walk", "kind": "path", "nodes": ["pc_sw", "pk_c", "pc_ne"]},

	{"name": "Strand Approach", "kind": "street", "nodes": ["sd_m", "st_w"]},
	{"name": "Quay Street", "kind": "street", "nodes": ["st_w", "pc_s"], "bend": [18.0]},
	{"name": "Strand North Gate", "kind": "street", "nodes": ["st_n", "vb_2"]},
	{"name": "Strand East Gate", "kind": "street", "nodes": ["st_e", "vb_1"]},
	{"name": "Strand Shore Gate", "kind": "street", "nodes": ["st_e", "sd_e"]},
	# Through vb_1 rather than past it: the promenade's third leg ran within two
	# metres of the boulevard's foot, which is a crossing whichever way it is read.
	{"name": "The Strand", "kind": "promenade",
		"nodes": ["st_w", "sp_1", "sp_2", "vb_1", "sp_3", "st_e"],
		"bend": [-14.0, 16.0, -8.0, -8.0, 14.0]},
	{"name": "Neon Walk", "kind": "promenade", "nodes": ["st_n", "sp_2"]},

	{"name": "Wharf Road", "kind": "avenue", "nodes": ["hb_1", "hb_2"]},
	{"name": "Dock Road", "kind": "avenue", "nodes": ["hb_3", "hb_4"]},
	{"name": "Crane Street", "kind": "street", "nodes": ["hb_1", "hb_3"]},
	{"name": "Net Street", "kind": "street", "nodes": ["hb_2", "hb_4"]},
	{"name": "Harbour Approach", "kind": "street", "nodes": ["hb_3", "sd_w"]},
	{"name": "Harbour Hill", "kind": "street", "nodes": ["hb_1", "ll_sw"]},
	{"name": "Fishmarket Street", "kind": "street", "nodes": ["hb_2", "pc_sw"], "bend": [24.0]},

	{"name": "Marina Wharf", "kind": "lane", "nodes": ["sd_w", "mr_1"], "dead_end": true},
	{"name": "West Beach Access", "kind": "lane", "nodes": ["sd_m", "ba_1"], "dead_end": true},
	{"name": "The Pier", "kind": "promenade", "nodes": ["sd_c", "ba_2"], "dead_end": true},
	{"name": "East Beach Access", "kind": "lane", "nodes": ["sd_e", "ba_3"], "dead_end": true},

	{"name": "Collector A", "kind": "avenue",
		"nodes": ["rs_a1", "rs_a2", "rs_a3", "rs_a4", "rs_a5"],
		"bend": [-26.0, -22.0, 20.0, 24.0]},
	{"name": "Collector B", "kind": "avenue",
		"nodes": ["rs_b1", "rs_b2", "rs_b3", "rs_b4"],
		"bend": [-24.0, -18.0, 22.0]},
	{"name": "Rung West", "kind": "street", "nodes": ["rs_a1", "rs_b1"]},
	{"name": "Rung Middle", "kind": "street", "nodes": ["rs_a3", "rs_b2"]},
	{"name": "Rung East", "kind": "street", "nodes": ["rs_a5", "rs_b4"]},
	{"name": "Wren Close", "kind": "lane", "nodes": ["rs_a1", "cds_1"], "dead_end": true},
	{"name": "Alder Close", "kind": "lane", "nodes": ["rs_a2", "cds_2"], "dead_end": true},
	{"name": "Linden Close", "kind": "lane", "nodes": ["rs_a4", "cds_3"], "dead_end": true},
	{"name": "Kestrel Close", "kind": "lane", "nodes": ["rs_b1", "cds_4"], "dead_end": true},
	{"name": "Juniper Close", "kind": "lane", "nodes": ["rs_b3", "cds_5"], "dead_end": true},
	{"name": "Park Rise", "kind": "street", "nodes": ["rs_a1", "pc_nw"]},
	{"name": "West Ridge Road", "kind": "street", "nodes": ["rs_b1", "ll_w2"]},
	{"name": "North Gate", "kind": "street", "nodes": ["rs_b3", "ll_n"]},
	{"name": "Northwest Gate", "kind": "street", "nodes": ["rs_b2", "ll_nw"]},
	# Runs to the switchback's head rather than past it to the ring. Hillside Head
	# carries the last leg on to ll_n2, so the route is the same one node later,
	# and hs_5 becomes the junction the two roads were already sharing ground at.
	{"name": "Northeast Gate", "kind": "street", "nodes": ["rs_b4", "hs_5"]},

	{"name": "Hillside Switchback", "kind": "street",
		"nodes": ["hs_1", "hs_2", "hs_3", "hs_4", "hs_5"],
		"bend": [22.0, -22.0, 22.0, -22.0]},
	{"name": "Hillside Foot", "kind": "street", "nodes": ["hs_1", "ll_ne"]},
	{"name": "Hillside Head", "kind": "street", "nodes": ["hs_5", "ll_n2"]},
	{"name": "Terrace Road", "kind": "street", "nodes": ["hs_3", "rs_a5"], "bend": [-20.0]},

	{"name": "The Skyway", "kind": "skyway",
		"nodes": ["sk_e", "sk_1", "sk_2", "sk_3", "sk_w"],
		"bend": [-18.0, -22.0, -22.0, -18.0]},
	{"name": "Skyway East Ramp", "kind": "ramp", "nodes": ["sk_e", "re"]},
	{"name": "Skyway Downtown Ramp", "kind": "ramp", "nodes": ["sk_1", "dt_3_4"]},
	{"name": "Skyway Civic Ramp", "kind": "ramp", "nodes": ["sk_2", "vb_6"]},
	{"name": "Skyway West Ramp", "kind": "ramp", "nodes": ["sk_w", "pc_w"]},

	{"name": "Coast Expressway", "kind": "skyway",
		"nodes": ["ce_e", "ce_m", "ce_w"], "bend": [-16.0, -16.0]},
	{"name": "Expressway East Ramp", "kind": "ramp", "nodes": ["ce_e", "sd_c"]},
	{"name": "Expressway West Ramp", "kind": "ramp", "nodes": ["ce_w", "ll_sw"]},

	# Ends at the Strand's east gate instead of running past it to the shore. It
	# used to pass nine metres from st_e, laying its ribbon over the three roads
	# that meet there; Strand Shore Gate already carries the last leg to sd_e.
	{"name": "Marine Parade", "kind": "street", "nodes": ["dt_1_0", "st_e"]},
	{"name": "Exchange Street", "kind": "street", "nodes": ["dt_3_0", "sd_x"]},
	{"name": "Harbour View Avenue", "kind": "avenue", "nodes": ["dt_3_2", "ll_e"]},
	{"name": "Summit Avenue", "kind": "avenue", "nodes": ["dt_3_4", "ll_ne"]},
	{"name": "Union Street", "kind": "street", "nodes": ["dt_0_2", "vb_3"]},
	{"name": "Bank Street", "kind": "street", "nodes": ["dt_0_4", "vb_4"]},
	{"name": "Civic Way", "kind": "avenue", "nodes": ["dt_2_5", "vb_5"], "bend": [30.0]},
]


# --- Downtown ---------------------------------------------------------------

## Downtown is the one district that wants a grid, and a grid is better counted
## than typed. Turned off the pad's axes so it reads as its own quarter rather
## than as the map's, and blocked at 160 by 120 m, which is a tower and its
## service yard.
const DOWNTOWN_AT := Vector2(390.0, -120.0)
const DOWNTOWN_TURN := -12.0
const DOWNTOWN_ACROSS: Array[float] = [-240.0, -80.0, 80.0, 240.0]
const DOWNTOWN_ALONG: Array[float] = [-300.0, -180.0, -60.0, 60.0, 180.0, 300.0]


## The whole network, junctions and roads together, with downtown counted in.
## Everything that draws or checks the city starts here.
static func graph() -> Dictionary:
	var nodes := {}
	for id: String in JUNCTIONS:
		nodes[id] = JUNCTIONS[id] as Vector3
	var roads: Array[Dictionary] = []

	var turn := deg_to_rad(DOWNTOWN_TURN)
	var across := Vector2(cos(turn), sin(turn))
	var along := Vector2(-sin(turn), cos(turn))
	for column in DOWNTOWN_ACROSS.size():
		for row in DOWNTOWN_ALONG.size():
			var at := DOWNTOWN_AT + across * DOWNTOWN_ACROSS[column] \
				+ along * DOWNTOWN_ALONG[row]
			nodes["dt_%d_%d" % [column, row]] = Vector3(at.x, at.y, 0.0)
	# Avenues run the long way, streets the short way, so the blocks read as
	# blocks rather than as squares.
	for column in DOWNTOWN_ACROSS.size():
		var chain: Array[String] = []
		for row in DOWNTOWN_ALONG.size():
			chain.append("dt_%d_%d" % [column, row])
		roads.append({"name": "Downtown Avenue %d" % column, "kind": "avenue",
			"nodes": chain})
	for row in DOWNTOWN_ALONG.size():
		var chain: Array[String] = []
		for column in DOWNTOWN_ACROSS.size():
			chain.append("dt_%d_%d" % [column, row])
		roads.append({"name": "Downtown Street %d" % row, "kind": "street",
			"nodes": chain})

	for road: Dictionary in ROADS:
		roads.append(road)
	return {"nodes": nodes, "roads": roads}


## This city's ground: the site, the footprint, the grade and the districts, as the
## terrain wants them.
static func plan() -> CityPlan:
	var made := CityPlan.new()
	made.title = "Vacationer's Landing"
	made.centre = CENTRE
	made.facing = FACING
	made.core = CORE
	made.rim = RIM
	made.corner = CORNER
	made.reach = REACH
	made.grade = GRADE
	made.ground_color = GROUND
	made.districts = DISTRICTS
	made.feather = FEATHER
	return made


## This city's streets, resolved into lines. Building the network is what checks it,
## so anything that wants to know whether the layout is sound asks this and then
## asks the network to [method RoadNetwork.audit] itself.
static func network() -> RoadNetwork:
	return RoadNetwork.new(graph(), KINDS)
