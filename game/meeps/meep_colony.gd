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

## How often authoritative Meep decisions are made and state packets go out.
## Presentation is smoothed every rendered frame below; this cadence is no longer
## exposed as ten-hertz stepping on either the host or a client.
const SIM_HZ := 10.0
const SIM_STEP := 1.0 / SIM_HZ
## Giant cities advance residents in stable round-robin chunks. Every row accrues
## the full elapsed time while waiting, so this bounds one tick without slowing the
## authoritative work, aging, or movement represented by its eventual step.
const STEPS_PER_TICK := 1024

## Simulation detail, by distance to the nearest player.
enum Detail {
	## Close enough to be watched: every tick, drawn, and its ground read from the
	## field at the spacing the terrain is actually drawn at.
	HOT,
	## In sight but not underfoot. Full movement rate, drawn, ground read from the
	## grid. Visible Meeps never enter a reduced-cadence presentation band.
	WARM,
	## Nobody near. Never drawn and grounded from the cached grid, but still thinking,
	## walking and working at the same authoritative cadence as a watched resident.
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
const WARM_INTERVAL := SIM_STEP
const COLD_INTERVAL := SIM_STEP

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
	## Walking to the doorway of this Meep's own hut.
	GO_HOME,
	## Waiting inside that hut. Kept separate from INSIDE because only the latter owns
	## one of the cloner's five machine slots.
	AT_HOME,
	## Following a short connected sequence of completed road cells for leisure.
	STROLL,
	## Transferred intact to a child settlement. The row and identity remain in
	## parent history but no longer count, work, draw, occupy a deed, or die.
	DEPARTED,
	## Hidden inside a staffed biomass harvester without per-tick wandering.
	AT_WORKPLACE,
}

## Fixed for life after maturation. Append-only because identity snapshots persist it.
enum Role {
	CHILD,
	BUILDER,
	HOMEBODY,
	HARVESTER,
}

## Telemetry labels for [method _do_work], indexed by [enum MeepTasks.Kind].
const WORK_TRACE_LABELS: Array[StringName] = [
	&"work_idle",
	&"work_wander",
	&"work_clone",
	&"work_road",
	&"work_build",
	&"work_mine",
	&"work_upgrade",
	&"work_shared_wall",
]

## Telemetry labels for [method _step], indexed by [enum State].
const STEP_TRACE_LABELS: Array[StringName] = [
	&"step_idle",
	&"step_walk",
	&"step_work",
	&"step_flee",
	&"step_dead",
	&"step_inside",
	&"step_go_home",
	&"step_at_home",
	&"step_stroll",
	&"step_departed",
	&"step_at_workplace",
]

## Shader clip IDs stored in INSTANCE_CUSTOM.x. Their order is part of the
## renderer contract rather than the network protocol.
enum AnimationClip {
	IDLE,
	WALK,
	RUN,
	BUILD,
}

## IDs sent by the city panel. A client asks for one exact level/project, and the
## host resolves its price and prerequisites. Exact IDs make repeated reliable RPCs
## idempotent; two BUILD_SPEED_1 requests cannot buy levels one and two.
enum CityPurchase {
	BUILD_SPEED_1,
	BUILD_SPEED_2,
	BUILD_SPEED_3,
	BUILD_SPEED_4,
	BUILD_SPEED_5,
	MOVE_SPEED_1,
	MOVE_SPEED_2,
	MOVE_SPEED_3,
	MOVE_SPEED_4,
	MOVE_SPEED_5,
	BRIDGES,
	COASTS,
	HAT_HOUSE,
	ABILITIES_HOUSE,
	BIOMASS_HARVESTER,
	SEND_SETTLEMENT,
	## Harvester speed purchases use exact levels so retries remain idempotent.
	HARVEST_RATE_1,
	HARVEST_RATE_2,
	HARVEST_RATE_3,
	HARVEST_RATE_4,
	HARVEST_RATE_5,
	## Doubles the completed Abilities House in place and unlocks stat training.
	ABILITIES_HOUSE_TOWER,
	## Commissions one additional physical Meep Cloner and its own working queue.
	SECOND_CLONER,
	## Further machines are independent commissions.
	THIRD_CLONER,
	FOURTH_CLONER,
}

const CITY_PURCHASE_COUNT := 25
const MAX_CITY_TIER := 4
## Tier 4 is a vertical arcology stage. Keeping the limit explicit lets compact
## simulation, live cities, and local Blueprint projections share one 10k+ contract.
const MAX_CITY_POPULATION := 12000
## Continuous growth stops inside the fixed 192 m half-grid, leaving enough route
## and footprint margin that edge structures never sample beyond measured terrain.
const MAX_CLAIM_RADIUS := 185.0
## Tiers now describe architectural density only. These are preferred inner
## development bands, not city boundaries; the border advances independently.
const CITY_TIER_DEVELOPMENT_INNER_RADII: Array[float] = [
	0.0, 100.0, 125.0, 150.0,
	# A 30 m super-tower cannot fit in the thin strip beyond the Tier 3 ring.
	# Megacity construction deliberately infills the broad civic gaps outside 130 m.
	130.0,
]
const MAX_SPEED_LEVEL := 5
const BUILD_SPEED_PER_LEVEL := 0.10
const MOVE_SPEED_PER_LEVEL := 0.08
const SPEED_UPGRADE_COSTS := [80.0, 130.0, 210.0, 340.0, 550.0]
## Metres per simulation second. The default frontier moves one grid cell every
## twenty seconds; population supplies the only automatic acceleration.
const EXPANSION_BASE_RATE := 0.10
## Large populations push survey crews outward even without another purchase.
const EXPANSION_POPULATION_STEP := 128
const EXPANSION_POPULATION_RATE := 0.05
const EXPANSION_POPULATION_BONUS_MAX := 0.25
const EXPANSION_SYNC_INTERVAL := 1.0
## The roster is virtualized in the menu, but formatting and sorting all 12,000
## records still has a cost. Reuse one immutable report snapshot between UI polls.
const REPORT_ROSTER_INTERVAL_MS := 2000
const ROSTER_SORT_LIMIT := 2048
const BRIDGES_COST := 150.0
const COASTS_COST := 175.0
const SPECIALTY_HOUSE_COST := 240.0
const ABILITIES_HOUSE_TOWER_COST := 800.0
const SECOND_CLONER_COST := 600.0
const THIRD_CLONER_COST := 900.0
const FOURTH_CLONER_COST := 1200.0
const BIOMASS_HARVESTER_COST := 1500.0
const SETTLEMENT_EXPEDITION_COST := 1000.0
const MAX_HARVEST_RATE_LEVEL := 5
const HARVEST_BASE_RATE := 1.0
const HARVEST_RATE_PER_LEVEL := 0.5
const HARVEST_RATE_COSTS := [500.0, 1000.0, 2000.0, 4000.0, 8000.0]
## A resumed or badly stalled frame may not mint an unbounded offline windfall.
## Normal distant simulation arrives far below this ceiling and remains exact.
const MAX_HARVEST_ELAPSED := 10.0
## Reliable whole-state refreshes are intentionally slower than the simulation tick.
const HARVEST_SYNC_INTERVAL := 1.0

## Sibling rows share a family name. There are enough families for every pair in a
## maximum Tier 0 town, so full names remain unique without numeric tags.
const GIVEN_NAMES: Array[String] = [
	"Ada", "Bibi", "Coco", "Dotti", "Fizz", "Gigi", "Hoku", "Ixi",
	"Juno", "Kiki", "Luma", "Momo", "Nib", "Oona", "Pip", "Quill",
	"Rolo", "Suki", "Tavi", "Umi", "Vivi", "Wisp", "Xixi", "Yoyo",
	"Zuzu", "Boop", "Nori", "Puck", "Rumi", "Tink", "Wally", "Yuki",
]
const FAMILY_NAMES: Array[String] = [
	"Acorn", "Amber", "Berry", "Birch", "Bloom", "Bramble", "Brook", "Button",
	"Clover", "Cloud", "Dandelion", "Dew", "Fern", "Finch", "Flax", "Glow",
	"Hazel", "Honey", "Juniper", "Lantern", "Leaf", "Lilac", "Maple", "Meadow",
	"Moon", "Moss", "Pebble", "Petal", "Pine", "Pollen", "Puddle", "Reed",
	"Ripple", "Root", "Seed", "Sprig", "Star", "Stone", "Sun", "Thistle",
	"Twig", "Vale", "Velvet", "Willow", "Wren", "Yarrow", "Zephyr", "Zinnia",
]

## Settlers in the first wave.
const FIRST_WAVE := 6
## The first permanent street is a circular plaza around either ship. Its centreline
## sits just inside the structure-clear radius, leaving room for the road surface
## without letting a future building overlap it.
const SHIP_ROAD_RADIUS := 18.0
## Everything inside the street is navigation-blocked. This covers the 26 m colony
## ship as well as the smaller settlement hull and prevents route fields from treating
## their physical collision as walkable ground.
const SHIP_NAVIGATION_RADIUS := 16.0
## Host-only road subject for the plaza ring. Negative values cannot collide with
## structure indices or the append-only synthetic surface subjects.
const SHIP_RING_ROAD_SUBJECT := -0x3F000001
## Founders start beyond the blocked plaza rather than being settled out of its hull.
const SPAWN_RING := 22.0
## Clearance between grounded visual geometry and the sampled walk surface.
## Combat adds its historical radius; upright proxies add half body height.
const FLOOR_CLEARANCE := 0.04
const MEEP_VAT_MODEL_PATH := "res://assets/runtime/vat/meep_idle_vat.glb"
const MEEP_SURFACE_PATH := "res://game/meeps/meep_surface.tres"
const MEEP_SHADER_PATH := "res://shaders/vivid/vivid_meep.gdshader"
const MEEP_VAT_PATHS: Array[String] = [
	"res://game/meeps/meep_idle_vat.tres",
	"res://game/meeps/meep_walk_vat.tres",
	"res://game/meeps/meep_run_vat.tres",
	"res://game/meeps/meep_build_vat.tres",
]
const MEEP_VAT_PREFIXES: Array[String] = ["idle", "walk", "run", "build"]
## How sharply a Meep turns onto a new heading, per second of steering.
const TURN_RATE := 7.0
## Local avoidance uses the navigation grid as a fixed spatial hash. Looking one
## cell out in each direction is exactly a 3x3 neighborhood at the two-metre cell
## size, and the per-cell cap keeps a deliberately stacked fixture linear too.
const CROWD_NEIGHBOR_CELL_RADIUS := 1
const CROWD_NEIGHBORS_PER_CELL := 32
## Personal-space reach in metres. Wider than the 0.64 m capsule diameter so a
## ten-hertz walker begins turning before its next stride intersects another row.
const CROWD_AVOID_RADIUS := 1.4
const CROWD_SEPARATION_WEIGHT := 1.35
## Every head-on meeting borrows the same right shoulder instead of choosing a
## random side and oscillating.
const CROWD_SHOULDER_WEIGHT := 0.42
## Avoidance changes direction only; this cap prevents a dense cell from
## overpowering route intent or adding displacement beyond speed * delta.
const CROWD_MAX_BLEND := 0.9
## Cost fields kept for job destinations before the oldest is dropped.
const FIELD_CACHE := 12
## Fills allowed on worker threads at once. See [method _start_field].
const FIELD_BAKES := 2
## Existing fields remain safe when the grid changes: walkers reject newly blocked
## cells before entering them. Refresh them gradually so one completed road does not
## turn every active destination into a continuous worker-thread rebuild queue.
const FIELD_STALE_REFRESH_INTERVAL := 1.0
## Pick proxies lent to nearby Meeps. See [MeepPickProxy].
const PROXY_POOL := 8
## Metres within which a Meep is worth lending a proxy to. A little past the
## interaction ray, so the prompt is ready before the player is in range.
const PROXY_RANGE := 5.0
## Physical bodies lent to the nearest HOT/visible rows on this peer. The pool is
## fixed regardless of population and reaches the local walking neighborhood.
const BLOCK_PROXY_POOL := 32
const BLOCK_PROXY_RANGE := 26.0
## Meeps whose positions go out in one state packet. Only the ones near a player
## are sent at all, and this is the ceiling on how many that can be: a battle in a
## crowded town must not become a packet nobody can carry.
const PUBLISH_LIMIT := 128
## How much of the gap to a freshly received position a client closes per second.
## Fast enough not to lag behind a walk, slow enough to hide the ten-hertz steps.
const FOLLOW_RATE := 12.0
## The host's packed simulation moves in authoritative ticks, while fauna bodies move
## every physics frame. These presentation-only rows chase each new simulation pose at
## the Meep's actual speed and turn each rendered frame, giving both the same cadence.
const RENDER_CATCHUP := 1.04
const RENDER_HEIGHT_SPEED := 8.0
const RENDER_SNAP_DISTANCE := 4.0
## Idle life alternates between a road stroll and a visit home. Waiting is long enough
## to make house occupancy legible when inspected, but not long enough to hide the town.
const HOME_WAIT_MIN := 10.0
const HOME_WAIT_MAX := 20.0
## Mature cities keep successively more off-duty residents inside their assigned
## buildings. They remain authoritative rows and wake for work after the home timer.
const HOME_VISIT_POPULATION_STEP := 128
const MAX_CONSECUTIVE_HOME_VISITS := 5
const HOME_WAIT_POPULATION_STEP := 256.0
const MAX_HOME_WAIT_MULTIPLIER := 2.0
## A quiet city must not look abandoned merely because every authoritative row is
## currently inside a home or workplace. A small, bounded cohort keeps walking its
## roads whenever ordinary jobs do not already provide enough visible street life.
const MIN_STREET_LIFE := 3
const MAX_STREET_LIFE := 24
const STREET_LIFE_POPULATION_STEP := 256
const STREET_LIFE_WAKE_SECONDS := 1.5
## Ledger cities keep one signed 16-bit decimetre pair per stable Meep row. This is
## exact enough for a doorway while remaining a four-byte location rather than a
## full live population snapshot.
const RETURN_PLACE_SCALE := 10.0
const STROLL_CELLS_MIN := 8
const STROLL_CELLS_MAX := 18
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
## Large cities complete posted work much faster than starter towns. Reviewing the
## whole claim at the starter cadence only invalidates routes and rebuilds city
## buffers repeatedly; strategic decisions can taper to this interval at 200+ Meeps.
const MATURE_PLAN_INTERVAL := 3.0
## The starter town established by the first pass. Sixteen sibling homes plus the
## cloner are the smallest physical town that can hold its 32 residents.
const STARTER_POPULATION := 32
const STARTER_STRUCTURES := 17
## Paid civic projects wait behind the housed starter city, then outrank routine
## growth. This keeps an early commission from pulling six settlers off the cloner
## runway while still making the player's explicit order the city's next milestone.
const COMMISSION_POPULATION := STARTER_POPULATION
## Tier 0 reserves one structure slot per this much claimed ground. A six-metre
## footprint and six-metre neighbour clearance can physically pack much more tightly;
## the lower civic density is deliberate room for parks, lookouts, future large
## buildings and readable road branches. The ceiling bounds simulation and replication
## on unusually broad claims while still scaling smaller terrain-limited settlements.
const TIER_ZERO_LOT_AREA := 150.0
const TIER_ZERO_MAX_STRUCTURES := 48
const TIER_POPULATION_CEILINGS := [
	94, 160, 320, 2800, MAX_CITY_POPULATION,
]
const TIER_BLOCK_SIZES := [0.0, 24.0, 32.0, 44.0, 56.0]
## Existing one-lot homes may safely gain one vertical floor, but denser tiers still
## establish their own wider forms instead of converting the whole old town.
const MAX_VERTICAL_HUT_UPGRADES := 4
## Biomass one use of the cloner costs, and how long a Meep is inside for.
const CLONE_COST := 12.0
const CLONE_SECONDS := 1.0
## How many may be inside the cloner at once. The sixth to arrive waits outside, which
## is what the cap is for.
const CLONE_CREW := 5
const CHILDHOOD_SECONDS := 120.0
const CHILD_START_SCALE := 0.55
const BUILDER_ROLE_SHARE := 0.35
const HARVESTER_ROLE_SHARE := 0.25
const HARVESTER_STAFF_SLOTS := 4
const HARVESTER_STAFF_BONUS := 0.25
const PREBUILD_SURPLUS_MULTIPLIER := 3.0
## Every hut is one sibling home. The landed first wave may arrive before its first
## three homes exist; after that, the next hut is completed before its next clone.
const STARTER_SETTLERS_PER_HUT := 2
const TIER_ZERO_SETTLERS_PER_HUT := 2
## Job seconds to fell one tree, before the walk out to it.
const MINE_SECONDS := 2.5
## Open mining jobs per living settler, and the fewest a colony will post while there
## is anything left to cut. Enough that nobody is idle for want of a tree, few enough
## that the whole town is not out in the woods when there is building to do.
##
## Set against how far the timber is rather than by taste: the flower trees keep sixty
## metres clear of the lander, so a felling trip is a two-minute round walk and a colony
## with two miners earns about one tree a minute. Half the town out cutting is what makes
## the other half's work affordable.
const MINE_SHARE := 0.55
## Once the free bank covers the next building/road/clone runway, harvesting
## tapers toward this background share instead of keeping half the city in the
## woods. One job remains so a donation accelerates growth without making the
## colony dependent on another donation forever.
const MINE_SHARE_FUNDED := 0.08
const MINE_JOBS_MIN := 3
const MINE_JOBS_FUNDED_MIN := 1
## Approximate one future street branch while its exact route does not exist
## yet. Current branches are already represented by `committed`.
const MINE_ROAD_RUNWAY := 18.0
## Seconds between attempts to discover more harvestable flora after the stable list is
## exhausted. This lets a localized GroundCover finish streaming after the colony grid
## without renumbering targets underneath jobs already in progress.
const TIMBER_INTERVAL := 12.0
## How long one simulation step will spend surveying woods. The reading resumes where
## it left off next step, so a large claim finishes over a second or two rather than in
## one visible stall.
const TIMBER_SURVEY_BUDGET_USEC := 1500
## Seconds between full-grid frontier scans for a bridge or a dock.
## See [member _surface_scan_left].
const SURFACE_SCAN_INTERVAL := 8.0
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
## Finished roads are cleared once as they appear, then nearby cells are swept again
## while somebody is near the town. GroundCover lands tiles over several frames, but
## cannot create several new generations a second at one point. Two cells four times
## per second keeps the same sweep rate without putting eight field hits on one frame.
const ROAD_CLEAR_INTERVAL := 0.25
const ROAD_CLEAR_BUDGET := 2
const ROAD_CLEAR_RADIUS := 2.15
## Seconds before an already-swept road cell is worth offering to the flora fields
## again. Long, because a cell that streams cover after it was paved has that cover
## hidden by the road clearance mask in the meantime: the sweep is what makes the
## removal permanent, not what makes the road look paved.
const ROAD_SWEEP_REARM := 20.0
## Buildings have the same streaming problem as roads, but tens rather than hundreds of
## cells. Re-sweep one nearby footprint twice a second so the same work cannot bunch.
const STRUCTURE_CLEAR_INTERVAL := 0.5
const STRUCTURE_CLEAR_BUDGET := 1
## Minimum road branches allowed to be unfinished at once. The limit rises by one per
## sixteen settlers, to six: a mature Tier 0 should not finish forty houses while two
## paving crews leave its outer districts disconnected.
const ROADS_AT_ONCE := 2
## Unfinished sites a town will have at once. More than one so that a crew is not the
## only thing happening, few enough that they are finished rather than started.
const SITES_AT_ONCE := 2
const MAX_SITES_AT_ONCE := 5
## Places at the cloner beyond the five inside, which is what the line at the door is.
const CLONE_QUEUE := 3
## Seconds a Meep waits at a full cloner before deciding there is better to be done.
const QUEUE_PATIENCE := 8.0
## What each kind of work is worth against the walk to it. A hundred metres of walking is
## worth one point, so building beats cutting beats cloning at equal distance, and a
## nearer job of a lesser kind can still win. Mining above cloning on purpose: it is what
## pays for everything, including the cloning.
const BUILD_PRIORITY := 3.0
## Five priority points over routine building are worth 500 route metres in the
## board's score, so even a future Tier 3 worker crosses town for this first.
const COMMISSION_PRIORITY := 8.0
const ROAD_PRIORITY := 2.7
const SURFACE_PRIORITY := 3.25
## Broad safe-grade hill ramps include flat approaches on both levels. Keep enough
## city-wide allowance for more than one such crossing instead of exhausting the
## Bridges upgrade on the first hillside.
const MAX_BRIDGE_SURFACE_CELLS := 192
const MAX_DOCK_SURFACE_CELLS := 72
const CLONE_PRIORITY := 2.45
const MINE_PRIORITY := 2.0
const BUILDER_JOB_KINDS: Array[int] = [
	MeepTasks.Kind.ROAD,
	MeepTasks.Kind.BUILD,
	MeepTasks.Kind.UPGRADE,
	MeepTasks.Kind.SHARED_WALL,
]
const HOMEBODY_JOB_KINDS: Array[int] = [MeepTasks.Kind.CLONE]
const HARVESTER_JOB_KINDS: Array[int] = [MeepTasks.Kind.MINE]

signal settlers_released(count: int)
signal meep_died(index: int)
## Presentation event emitted on each peer before its local HUD decides whether
## this exact Meep is close enough and on screen to show.
signal meep_damage_number(index: int, event: DamageNumberEvent)
## A player used a Meep. Nothing consumes this yet; it is what a future Meep panel
## opens on.
signal meep_inspected(index: int, player: Node)
signal structure_inspected(index: int, player: Node)

var site_id: StringName
var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim
var tasks := MeepTasks.new()
var stats: MeepStats
var structures: MeepStructures
var roads: MeepRoads
## Complete terrain-aware growth recipe generated once from the founding grid.
## Runtime planners consume its prepared lots and streets instead of rescanning.
var city_plan := MeepCityPlan.new()
var _city_plan_restore_state: Dictionary = {}
var _applied_city_plan_mask_revision := -1
var region_id: StringName = &""
var region_revision := -1
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
## Permanent, per-city progression. Paid, requested and physically complete are
## separate bitsets because an instant speed upgrade is all three at once, while a
## commissioned building is paid/requested now and completed by Meeps in a later pass.
var tier := 0
var build_speed_level := 0
var move_speed_level := 0
var purchased_flags := 0
var requested_flags := 0
var built_flags := 0
var _report_roster_cache: Array = []
var _report_roster_next_msec := 0
var _report_roster_source_size := -1
var _report_roster_revision := 0
## One bit per tier. Allocation means enough functional residential capacity has
## been planned; completion additionally requires every site and connecting road.
var tier_allocated_flags := 0
var tier_complete_flags := 0
## Permanent output progression and the exact amount this city's own machine made.
## Both are per-colony fields: descendants neither read nor write a parent's values.
var harvester_rate_level := 0
var harvester_lifetime := 0.0
## Number of paid launch authorizations not yet used from this colony. Player
## inventories carry the authoritative individual records; this counter keeps
## their ordinal names stable across several purchases before any are launched.
var settlement_tokens := 0
## Latest buyer, retained for old snapshots and diagnostics only.
var settlement_armed_owner := 0
var claim_radius := MeepClaim.DEFAULT_RADIUS
var founded_seed := 0
## Human-facing metadata never participates in node paths or networking keys.
var display_name := ""
var parent_site_id: StringName = &""
## A child settlement's landed expedition hull contains a completed cloner.
## The ordinary structure site is hidden inside the larger opaque ship, allowing
## the existing queue, biomass cost, incubation, saves, and replication to stay
## authoritative without constructing a second machine beside it.
var _settlement_ship_cloner := -1

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
var _roles := PackedByteArray()
## Structure index while walking to or hidden inside a staffed workplace.
var _workplaces := PackedInt32Array()
var _detail := PackedByteArray()
var _job := PackedInt32Array()
var _seed := PackedInt32Array()
## Seconds since this row was last stepped, which is the timestep it is given when
## its turn comes. Meeps thinking at different rates is the whole of the detail
## system, and this is what keeps them moving at the same speed while they do.
var _since := PackedFloat32Array()
## Countdown on whatever the current state is waiting for.
var _timer := PackedFloat32Array()
## Which idle choice comes next. Toggling rather than rolling every decision prevents a
## resident from repeatedly stepping through its door while still varying the first
## choice across the population.
var _idle_turn := PackedByteArray()
## Where the host last said this Meep was, for a client to walk towards.
var _target := PackedVector2Array()
## Presentation-only poses. Authoritative gameplay, collisions, saves, and replication
## continue to use the rows above; these remove visible ten-hertz position and turn
## steps on the host without changing any simulation result.
var _render_local := PackedVector2Array()
var _render_heading := PackedVector2Array()
var _render_height := PackedFloat32Array()
## Stable explicit deed per Meep row. Vacancies are assigned oldest-first and this
## sidecar is replicated with town state so variable-capacity residences stay exact.
var _deeds := PackedInt32Array()
## Rows born while this city was arithmetic rather than resident have no saved
## location. They are marked until returning buildings give them a deed, then moved
## directly into that home instead of appearing at the colony ship.
var _return_unplaced := PackedByteArray()
## Explicit identity sidecars preserve transferred founders across colony keys.
var _names := PackedStringArray()
var _siblings := PackedInt32Array()
## Simulation age follows the Meep across settlements and stops at death. Mortality
## records remain on the stable row so the city memorial survives saves and joins.
var _ages := PackedFloat64Array()
var _dead_for := PackedFloat64Array()
var _death_causes := PackedStringArray()
## Last parent-city home retained for departed founder history, never occupancy.
var _former_deeds := PackedInt32Array()
## Metres squared to the nearest eye, written by [method _grade]. Cached because
## three separate passes want it — detail, drawing and the proxy pool — and it is
## the most expensive thing any of them would otherwise work out for themselves.
var _near_squared := PackedFloat32Array()
## Who is worth walking, so that the per-tick and per-frame passes do not each
## rediscover it.
##
## Rows never compact: an index is the wire address of a Meep and the key its deed
## and its memorial are filed under, so a town carries every settler it ever had.
## Nine separate passes used to walk that whole history to find the people in it.
## These are the people, rebuilt once per [method _grade] — [member _active_rows]
## is everybody not dead or departed, [member _memorial_rows] is the dead, and
## [member _visible_rows] is the drawable subset of the living.
##
## Deliberately tolerant of being a tick out of date. A row that dies mid-tick stays
## in [member _active_rows] until the next grade, and every pass still asks the row
## itself what it is; the lists decide who is worth asking, never what the answer
## is. Only [method _add] has to update them eagerly, because a row nobody has
## looked at yet is the one thing a stale list could actually miss.
var _active_rows := PackedInt32Array()
var _memorial_rows := PackedInt32Array()
var _visible_rows := PackedInt32Array()
var _street_life_mask := PackedByteArray()
## Host-only fixed-bucket occupancy. Each navigation-grid cell owns the first row
## in a PackedInt32 linked list and each visible row owns one next pointer.
var _crowd_heads := PackedInt32Array()
var _crowd_next := PackedInt32Array()
## Buckets written by the last [method _rebuild_crowd_index], so the next one can
## clear those instead of all 36,864 of them.
var _crowd_touched := PackedInt32Array()
## Metres squared from the nearest eye to the nearest drawable row, from the last
## grade. What [method _process] early-outs on.
var _nearest_row_squared := INF
## Whether the last frame presented Meeps. Kept so the frame a town goes cold still
## runs the presentation pass once, which is what empties the batch and hands back
## the collider pools rather than leaving them attached to rows nobody can see.
var _presenting := false
var _crowd_indexed_rows := 0
var _crowd_rebuilds := 0
var _crowd_last_cells_checked := 0
var _crowd_last_neighbor_checks := 0
var _crowd_max_neighbor_checks := 0

var _planet: Planet
var _shape: PlanetShape
var _render: MultiMeshInstance3D
var _render_ready := false
var _render_mesh_transform := Transform3D.IDENTITY
var _vat_clips: Array[VatClip] = []
## Built once by [method _meep_rig] and shared by every colony on the planet.
static var _shared_rig: Dictionary = {}
var _wall: MeepBoundaryWall
var _proxies: Array[MeepPickProxy] = []
var _block_proxies: Array[MeepBlockProxy] = []
## Host-only road waypoints for current leisure walks. Only strolling Meeps have an
## entry; clients receive their resulting positions and never reproduce the choice.
var _stroll_paths: Dictionary = {}
## Shared regional segment metadata keyed by local job id.
var _wall_job_segments: Dictionary = {}
## Filled cost fields by destination cell, oldest wanted first in [member
## _field_order], and the ones a worker is filling right now.
var _fields: Dictionary = {}
var _field_order: Array[Vector2i] = []
var _field_tasks: Dictionary = {}
var _field_filling: Dictionary = {}
## Route bakes a reground abandoned, and whether one is owed once they have drained.
## See [method _advance_retired_fields].
var _retired_field_tasks := PackedInt32Array()
var _ground_owed := false
var _field_refresh_left := 0.0
var _tick_accum := 0.0
var _cursor := 0
var _alive := 0
## Nesting depth of the row fills that defer whole-population bookkeeping. See
## [method _begin_bulk_rows].
var _bulk_rows := 0
var _build_task := -1
var _ground_ready := false
var _rebuild_after_ground := false
## Radius captured by the current terrain worker. Growth can continue while it runs;
## a material difference requests one cheap claim-only refresh when it lands.
var _ground_bake_radius := 0.0
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
## Exterior home/gate cell on the circular ship road. Claim geometry remains centred
## at local zero; only navigation and road growth use this accessible root.
var _road_origin_cell := Vector2i(-1, -1)
var _rng := RandomNumberGenerator.new()
var _deaths := PackedInt32Array()
## Standing harvestable flora inside the claim, world position in `xyz` and payout in
## `w`, nearest the town first. A spent target keeps its slot with nothing left to pay,
## because the job board addresses it by this list. See [method _read_timber].
var _timber := PackedVector4Array()
## How far the worker stands from each aligned harvest target. A giant flower-tree has
## a real trunk collider; a one-metre meadow flower should be approached closely enough
## that the action visibly belongs to it.
var _timber_clearance := PackedFloat32Array()
var _timber_read_left := 0.0
## The reading in progress: the fields still to survey, and what the ones already
## surveyed found. Published over the two lists above only when the pass completes.
var _timber_fields_left: Array[Node] = []
var _timber_reading := PackedVector4Array()
var _timber_reading_clearance := PackedFloat32Array()
var _timber_reading_centre := Vector3.ZERO
## How far into the current field's own cover the reading has got. Meaningful only to
## that field, which hands back the cursor it wants next.
var _timber_cursor := 0
var _plan_left := 0.0
var _road_clear_left := 0.0
var _structure_clear_left := 0.0
## Newly completed branches are cleared one cell per simulation tick. Clearing a
## forty-cell road synchronously made its completion a visible hundred-millisecond
## hitch even though none of that flora affects authoritative navigation.
var _road_clear_pending := PackedInt32Array()
var _road_clear_pending_head := 0
## Road cell index to the time its loaded flora was last taken down, in seconds since
## start-up. Bounded by the paved cells of one claim. See [method _maintain_roads].
var _road_swept: Dictionary = {}
## Host decision that Tier 0 allocated its claim-area structure budget, or that terrain
## left fewer valid plots. Replicated so a client's city panel reports the same fill
## state without running the authoritative planner itself.
var _tier_zero_space_full := false
## Set once the final allocated plot and every road branch are actually complete. Kept
## separate from space allocation because clients receive road cells, not host-only
## branch subjects, and therefore cannot infer this transition themselves.
var _tier_zero_complete := false
## Set when the town gained a building, so the reliable packet describing what stands
## where only goes out when something does.
var _town_changed := false
## Reliable, whole progression packets are separate from town geometry. Purchases
## must reach every viewer even when no visible Meep caused an unreliable state packet.
var _progression_changed := false
var _harvester_sync_accum := 0.0
var _expansion_sync_accum := 0.0
## A paid civic project stays queued when its large footprint cannot yet fit. Routine
## work may continue until a later boundary step invalidates the negative plot scan.
var _commission_waiting_for_space := false
var _surface_scan_revision := -1
## Seconds before the frontier may be scanned again.
##
## The revision gate below already stops a settled town repeating the scan, but the
## scan is a flood over the whole grid and every paved cell is a new revision. A
## town paving steadily therefore earned itself a twenty-millisecond flood every few
## seconds. A crossing that has been there since the town landed can wait.
var _surface_scan_left := 0.0
## A frontier crossing that exists but is not affordable yet. The terrain and
## road revision invalidate it; an unchanged bank does not. Without this cache a
## child settlement repeated the same full frontier scan every planning pass.
var _surface_candidate_revision := -1
var _surface_candidate: Dictionary = {}
var _performance_profiling := false
var _performance_profile: Dictionary = {}


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
	# Abandoned bakes too: their result is unwanted but they are still reading the
	# grid, and this is the one place waiting for them is the right thing to do.
	for task in _retired_field_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_retired_field_tasks.clear()
	_ground_owed = false
	_field_tasks.clear()
	_field_filling.clear()


## Founds the colony. The direction and heading come from whatever authorised it —
## a colony ship here, and a Meep expedition later — so nothing about this is tied
## to Vacationer's Landing.
func configure(planet: Planet, id: StringName, direction: Vector3, facing: float,
		settler_stats: MeepStats, radius: float, colony_seed: int,
		parent_id: StringName = &"", shown_name := "") -> void:
	var clock := Time.get_ticks_usec()
	_planet = planet
	_shape = planet.shape if planet != null else null
	if _shape != null:
		# Idempotent, and the bake is about to read the field from a worker thread.
		# A colony founded before the planet's own ready would otherwise be asking
		# a shape that has not built its native field yet.
		_shape.prepare()
	clock = _charge_ground(&"found_shape", clock)
	site_id = id
	parent_site_id = parent_id
	display_name = shown_name.strip_edges()
	if display_name.is_empty():
		display_name = String(id).capitalize()
	stats = settler_stats if settler_stats != null else MeepStats.new()
	claim_radius = clampf(radius, 8.0, MAX_CLAIM_RADIUS)
	founded_seed = colony_seed
	_rng.seed = colony_seed
	# Several settlements otherwise start all three review clocks at zero and put
	# every planner, road sweep, and structure sweep on the same physics frame
	# forever. Stable seed phases preserve each cadence while distributing work.
	var cadence_phase := float(posmod(colony_seed, 1009)) / 1009.0
	_plan_left = PLAN_INTERVAL * (0.15 + cadence_phase * 0.85)
	_road_clear_left = ROAD_CLEAR_INTERVAL * fposmod(
		cadence_phase + 0.37, 1.0)
	_structure_clear_left = STRUCTURE_CLEAR_INTERVAL * fposmod(
		cadence_phase + 0.71, 1.0)
	site = MeepSite.new(direction, _shape.radius if _shape != null else 8000.0,
		facing, MeepGrid.CELLS * MeepGrid.CELL * 0.5)
	grid = MeepGrid.new(site)
	claim = MeepClaim.new()
	_centre_height = _shape.elevation(site.direction_at(Vector2.ZERO)) \
		if _shape != null else 0.0
	clock = _charge_ground(&"found_site", clock)
	_raise_render()
	clock = _charge_ground(&"found_render", clock)
	_raise_wall()
	_raise_proxies()
	clock = _charge_ground(&"found_wall", clock)
	roads = MeepRoads.new()
	add_child(roads)
	roads.configure(site, grid, claim, _shape, _planet, founded_seed)
	roads.set_centre_exclusion_radius(SHIP_NAVIGATION_RADIUS)
	clock = _charge_ground(&"found_roads", clock)
	structures = MeepStructures.new()
	add_child(structures)
	structures.configure(site, grid, claim, _shape, _planet, self, roads)
	clock = _charge_ground(&"found_structures", clock)
	_start_ground()
	_charge_ground(&"found_bake", clock)


## Whether the ground has been read and the boundary drawn. Until it is, settlers
## can be released and will stand about: the bake takes a few frames on a worker
## thread and a colony that refused to accept people until it finished would be a
## button that does nothing.
func ground_ready() -> bool:
	return _ground_ready


## Compact simulation has no physical job board. Residency may change only between
## construction operations and with no paid commission waiting, otherwise a
## half-built site, occupied cloner, or newly opened border would lose its retry.
func ready_for_distillation() -> bool:
	if not _ground_ready or structures == null or roads == null or tasks == null \
			or commissioned_work_pending() \
			or structures.count() != structures.built_count() \
			or roads.unfinished_count() > 0 \
			or not tasks.all_of(MeepTasks.Kind.UPGRADE).is_empty():
		return false
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null and (entry.inside > 0 or entry.upgrading()):
			return false
	return true


## Gives a newly landed child settlement a completed cloner inside its ship.
## Ordinary first colonies still construct their standalone purple machine.
## This is idempotent so late snapshots and old child saves can safely call it.
func ensure_settlement_ship_cloner() -> int:
	_settlement_ship_cloner = -1
	if parent_site_id == &"" or structures == null or grid == null:
		return -1
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null and entry.kind == MeepStructures.Kind.CLONER \
				and entry.local.length() < 5.0:
			_settlement_ship_cloner = index
			structures.set_progress(index, 1.0)
			return index
	# A migrated child that already built a separate cloner can already grow.
	# Do not add a second machine and disturb its established town indices.
	if structures.count_of(MeepStructures.Kind.CLONER) > 0:
		return -1
	var plan := MeepStructures.plan_of(MeepStructures.Kind.CLONER)
	var centre := grid.cell_of(Vector2.ZERO)
	var corner := centre - Vector2i(plan.span.x / 2, plan.span.y / 2)
	_settlement_ship_cloner = structures.place_at(
		MeepStructures.Kind.CLONER, corner)
	if _settlement_ship_cloner >= 0:
		structures.set_progress(_settlement_ship_cloner, 1.0)
		_town_changed = true
	return _settlement_ship_cloner


func settlement_ship_cloner_index() -> int:
	return _settlement_ship_cloner


## The hidden machine occupies the middle of the hull, but its queue belongs at
## a door beyond the hull's widest possible horizontal edge.
func _cloner_work_cell(cloner: int) -> Vector2i:
	if structures == null or grid == null \
			or cloner != _settlement_ship_cloner:
		return structures.work_cell(cloner) \
			if structures != null else Vector2i.ZERO
	var hull_radius := Vector2(
		SettlementShip.FOOTPRINT.x, SettlementShip.FOOTPRINT.z).length() * 0.5
	var doorway_radius := hull_radius + grid.cell_size * 1.5
	for direction in [
			Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP,
			Vector2(1.0, 1.0).normalized(),
			Vector2(-1.0, 1.0).normalized(),
			Vector2(-1.0, -1.0).normalized(),
			Vector2(1.0, -1.0).normalized(),
		]:
		var wanted := grid.cell_of(direction * doorway_radius)
		var doorway := grid.nearest_passable(wanted, 8)
		if grid.passable(doorway) \
				and (claim == null or claim.contains_cell(doorway)):
			return doorway
	return structures.work_cell(cloner)


## Reconstructs the non-replicated ship obstacle and chooses the east plaza gate.
## Existing saves are sanitized by the road collection before its flags are restored,
## so paving once laid under a hull disappears instead of remaining a collision trap.
func _prepare_ship_plaza() -> void:
	if grid == null or claim == null:
		return
	if roads != null:
		roads.set_centre_exclusion_radius(SHIP_NAVIGATION_RADIUS)
	var centre := grid.cell_of(Vector2.ZERO)
	var reach := ceili(SHIP_NAVIGATION_RADIUS / grid.cell_size) + 1
	var radius_squared := SHIP_NAVIGATION_RADIUS * SHIP_NAVIGATION_RADIUS
	for y in range(centre.y - reach, centre.y + reach + 1):
		for x in range(centre.x - reach, centre.x + reach + 1):
			var cell := Vector2i(x, y)
			if not grid.inside(cell):
				continue
			var inside := grid.centre_of(cell).length_squared() < radius_squared
			grid.set_flag(cell, MeepGrid.FLAG_SHIP, inside)
	var ring := ship_ring_cells()
	var wanted := Vector2(SHIP_ROAD_RADIUS, 0.0)
	var nearest := INF
	_road_origin_cell = Vector2i(-1, -1)
	for cell_index in ring:
		var cell := Vector2i(
			cell_index % grid.cells, cell_index / grid.cells)
		var away := grid.centre_of(cell).distance_squared_to(wanted)
		if away < nearest:
			nearest = away
			_road_origin_cell = cell
	if not grid.passable(_road_origin_cell):
		_road_origin_cell = grid.nearest_passable(
			grid.cell_of(wanted), ceili(SHIP_ROAD_RADIUS / grid.cell_size))


## One-cell digital circle in traversal order. Sampling at half-cell arc length keeps
## consecutive unique cells eight-connected, while the grid clips the ring to ground
## the colony can genuinely pave.
func ship_ring_cells() -> PackedInt32Array:
	var ring := PackedInt32Array()
	if grid == null or claim == null or not grid.built:
		return ring
	var seen: Dictionary = {}
	var samples := maxi(32, ceili(
		TAU * SHIP_ROAD_RADIUS / (grid.cell_size * 0.5)))
	for sample in samples:
		var angle := TAU * float(sample) / float(samples)
		var local := Vector2(cos(angle), sin(angle)) * SHIP_ROAD_RADIUS
		var cell := grid.cell_of(local)
		if not grid.passable(cell) or not claim.contains_cell(cell):
			continue
		var cell_index := grid.index(cell)
		if seen.has(cell_index):
			continue
		seen[cell_index] = true
		ring.push_back(cell_index)
	return ring


func road_origin_cell() -> Vector2i:
	if grid == null:
		return Vector2i.ZERO
	if grid.passable(_road_origin_cell):
		return _road_origin_cell
	var fallback := claim.origin if claim != null else grid.cell_of(Vector2.ZERO)
	return fallback if grid.passable(fallback) \
		else grid.nearest_passable(fallback, ceili(
			SHIP_ROAD_RADIUS / grid.cell_size) + 2)


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
	var coasts := city_upgrade_built(CityPurchase.COASTS)
	_ground_bake_radius = claim_radius
	var rivals := _claim_rival_state()
	_build_task = WorkerThreadPool.add_task(_bake_ground.bind(
		coasts, _ground_bake_radius,
		rivals["centres"], rivals["rival_wins_ties"]), true,
		"MeepColony ground bake")


func _bake_ground(coasts: bool, radius: float,
		rival_centres: PackedVector3Array,
		rival_wins_ties: PackedByteArray) -> void:
	var spacing := _planet.finest_spacing() if _planet != null else 0.0
	grid.build(_shape, spacing)
	claim.build(grid, Vector2.ZERO, radius, coasts,
		rival_centres, rival_wins_ties)


## Picks up the finished bake. Everything here touches the tree, so it waits for
## the main thread rather than being done at the end of the task.
func _finish_ground() -> void:
	_build_task = -1
	_ground_ready = true
	_fields.clear()
	_field_order.clear()
	var clock := Time.get_ticks_usec()
	# Now that there is a grid, the town's own middle rather than the point under the
	# ship, which the flood fill may have had to step away from.
	_centre_height = grid.height_at(claim.origin)
	_prepare_ship_plaza()
	clock = _charge_ground(&"ground_plaza", clock)
	# The ground a building stands on was taken out of the grid the bake just replaced,
	# so a client that has caught up with a town already standing has to take it out
	# again. Heights too: the sites were pegged out against whatever the grid held at
	# the time, which on a client is nothing.
	if structures != null:
		ensure_settlement_ship_cloner()
		structures.resettle()
	clock = _charge_ground(&"ground_structures", clock)
	if roads != null:
		roads.resettle()
	clock = _charge_ground(&"ground_roads", clock)
	# The ground this bake used went stale while it ran, so another is already owed and
	# its flood will supersede any claim, route or timber work done here. Restoring a
	# returning city always lands in this case: founding it starts a bake, and the
	# purchases restored a moment later can buy the coasts, which is a different
	# claim. Paying for the superseded fill anyway cost 220 ms of held physics step,
	# and the route bake below was started only to be waited on and thrown away.
	if _rebuild_after_ground and _shape != null:
		_charge_ground(&"ground_superseded", clock)
		_rebuild_after_ground = false
		_retire_route_fields()
		_ground_owed = true
		_advance_retired_fields()
		return
	_ensure_city_plan()
	var registry := get_parent()
	if registry != null and registry.has_method(&"apply_region_to_colony"):
		registry.call(&"apply_region_to_colony", self)
	clock = _charge_ground(&"ground_city_plan", clock)
	# The worker filled the claim before completed bridge and ramp surfaces were
	# restored. The claim has to notice them or the wall stays on the near bank, and
	# at maximum radius no later growth step would come along to repair it. Only the
	# overlay cells changed, so seed the repair from those instead of repeating the
	# worker's entire flood on the physics thread. Ordinary land roads do not change
	# claimability at all, so they keep the worker's exact result.
	_repair_claim_over_surfaces()
	_refresh_claim_boundary(true)
	clock = _charge_ground(&"ground_claim", clock)
	# Route only after standing structures and completed streets have restored their
	# flags. Starting it before resettle made every expansion immediately stale.
	_start_field(road_origin_cell())
	# Reachability is a question about the grid, so the woods are read now rather than
	# when the colony was founded — but spread across the coming simulation steps,
	# because surveying every field at once was most of this tick.
	_begin_timber_read()
	clock = _charge_ground(&"ground_timber", clock)
	# A returning ledger supplied exact last-known local positions. Validate them
	# only now, after restored structures and roads have reclaimed their cells.
	if not _return_unplaced.is_empty():
		rehome_returning_residents(founded_seed ^ 0x51A77E4)
	# Anyone released while the ground was still being read is standing on an
	# unknown cell. Now that there is a map, put them back on it.
	for index in _local.size():
		if _active_resident(index):
			_settle(index)
	_charge_ground(&"ground_settle", clock)


func _ensure_city_plan() -> void:
	if city_plan == null:
		city_plan = MeepCityPlan.new()
	if not _city_plan_restore_state.is_empty():
		city_plan.apply_snapshot(_city_plan_restore_state)
		_city_plan_restore_state.clear()
	city_plan.configure(grid, claim, founded_seed, structures, roads,
		MAX_CLAIM_RADIUS)
	_apply_city_plan_masks()


func bind_region_masks(owner: PackedByteArray, setback: PackedByteArray,
		for_region: StringName, plan_revision: int) -> void:
	region_id = for_region
	region_revision = plan_revision
	if grid == null:
		return
	grid.bind_region_masks(owner, setback, plan_revision)
	if city_plan != null and city_plan.generated():
		city_plan.reflow_region_clip()
		_applied_city_plan_mask_revision = -1
		_apply_city_plan_masks()
	if _build_task >= 0:
		_rebuild_after_ground = true
	elif _ground_ready:
		_refresh_claim_boundary()


## Publishes derived park intent and binds the district-development permit to the
## claim. Both arrays are regenerated from the compact founding blueprint.
func _apply_city_plan_masks(changed_cells := PackedInt32Array()) -> void:
	if city_plan == null or not city_plan.generated() or grid == null:
		return
	var current_revision := city_plan.mask_revision()
	if current_revision == _applied_city_plan_mask_revision:
		# The claim may have been replaced by a ground bake even when the plan did
		# not change, so binding remains cheap and unconditional.
		claim.bind_permit_mask(
			city_plan.permit_mask(), city_plan.permit_revision())
		return
	var parks := city_plan.park_mask()
	var planned_lots := city_plan.planned_lot_mask()
	var total := grid.cells * grid.cells
	var changed := false
	if changed_cells.is_empty():
		for index in total:
			var was := int(grid.flags[index])
			var wants_park := index < parks.size() and parks[index] != 0
			var wants_lot := index < planned_lots.size() \
				and planned_lots[index] != 0
			var now := was & ~(
				MeepGrid.FLAG_PARK | MeepGrid.FLAG_PLANNED_LOT)
			if wants_park:
				now |= MeepGrid.FLAG_PARK
			if wants_lot:
				now |= MeepGrid.FLAG_PLANNED_LOT
			if now == was:
				continue
			grid.flags[index] = now
			changed = true
	else:
		for index in changed_cells:
			if index < 0 or index >= total:
				continue
			var was := int(grid.flags[index])
			var now := was & ~(
				MeepGrid.FLAG_PARK | MeepGrid.FLAG_PLANNED_LOT)
			if index < parks.size() and parks[index] != 0:
				now |= MeepGrid.FLAG_PARK
			if index < planned_lots.size() and planned_lots[index] != 0:
				now |= MeepGrid.FLAG_PLANNED_LOT
			if now == was:
				continue
			grid.flags[index] = now
			changed = true
	if changed:
		grid.revision += 1
	_applied_city_plan_mask_revision = current_revision
	claim.bind_permit_mask(
		city_plan.permit_mask(), city_plan.permit_revision())


## Gets one prepared lot and notices when doing so activated a dormant district.
func _prepared_city_lot(kind: int, completed_owed := false) -> Dictionary:
	if city_plan == null or not city_plan.generated():
		return {}
	var old_revision := city_plan.permit_revision()
	var lot := city_plan.prepared_lot(kind, completed_owed)
	if city_plan.permit_revision() != old_revision:
		_apply_city_plan_masks()
		_progression_changed = true
		if _ground_ready:
			_refresh_claim_boundary(true)
	return lot


## Charges one stage of picking up a finished ground bake to the flight recorder.
##
## The bake itself is on a worker thread; this is the main-thread tick that adopts
## it, and it is the longest single tick a settled city produces. Unnamed, it can
## only be read as "the physics step took a hundred and sixty milliseconds".
func _charge_ground(stage: StringName, from: int) -> int:
	var now := Time.get_ticks_usec()
	RuntimeTelemetry.record_activity(&"meeps", stage, now - from)
	return now


func _claim_rival_state() -> Dictionary:
	var registry := get_parent()
	if registry != null and registry.has_method(&"claim_rivals"):
		return registry.call(&"claim_rivals", site_id) as Dictionary
	return {
		"centres": PackedVector3Array(),
		"rival_wins_ties": PackedByteArray(),
	}


## Grows the claim over bridge decks, ramps, and docks that were restored after the
## ground worker had already flooded. Costs the new cells rather than the town.
func _repair_claim_over_surfaces() -> void:
	if roads == null or claim == null or grid == null or not grid.built:
		return
	var overlays := roads.constructed_surface_cells()
	if overlays.is_empty():
		return
	var rivals := _claim_rival_state()
	var stage_started := Time.get_ticks_usec() if _profiling() else 0
	claim.repair(overlays, city_upgrade_built(CityPurchase.COASTS),
		rivals["centres"], rivals["rival_wins_ties"])
	_record_performance(&"claim_repair", stage_started)


## Re-floods only the cached navigation classifications. This is the frequent,
## inexpensive operation used by continuous growth; terrain sampling remains reserved
## for founding, scars, and completed constructed surfaces.
func _refresh_claim_boundary(growing := false) -> bool:
	if not _ground_ready or grid == null or not grid.built or claim == null:
		return false
	_apply_city_plan_masks()
	var old_count := claim.count
	var old_radius := claim.radius
	var rivals := _claim_rival_state()
	var stage_started := Time.get_ticks_usec() if _profiling() else 0
	if growing and claim_radius >= claim.radius:
		claim.expand(grid, Vector2.ZERO, claim_radius,
			city_upgrade_built(CityPurchase.COASTS),
			rivals["centres"], rivals["rival_wins_ties"])
	else:
		claim.build(grid, Vector2.ZERO, claim_radius,
			city_upgrade_built(CityPurchase.COASTS),
			rivals["centres"], rivals["rival_wins_ties"], false)
	# A growth step that had to re-flood the whole square is a different event from
	# one that added a band, and it is a hundred times dearer, so it is named for
	# what invalidated the claim rather than filed under expansion.
	var reason: StringName = claim.last_rebuild_reason if growing else &"asked"
	var stage := &"claim_expand"
	if not reason.is_empty():
		stage = StringName("claim_rebuild_%s" % reason)
	_record_performance(stage, stage_started)
	if structures != null:
		structures.clear_exhaustion()
	if _wall != null:
		stage_started = Time.get_ticks_usec() if _profiling() else 0
		var suppressed := PackedVector3Array()
		var registry := get_parent()
		if registry != null and registry.has_method(
				&"completed_wall_spans_for_city"):
			var spans: Variant = registry.call(
				&"completed_wall_spans_for_city", site_id)
			if spans is PackedVector3Array:
				suppressed = spans
		_wall.raise(site, claim, _shape, _spacing_drawn(), suppressed)
		_record_performance(&"claim_wall", stage_started)
	# Claim membership changed, not physical passability, so route fields stay valid.
	_surface_scan_revision = -1
	_surface_candidate_revision = -1
	_surface_candidate.clear()
	if _is_host():
		_set_commission_waiting_for_space(false)
	# Radius is already in the progression packet. A pure growth step does not
	# change a building, road, identity, or deed, so it must not also serialize the
	# entire reliable town snapshot every few seconds.
	if not growing:
		_town_changed = true
	return claim.count != old_count or not is_equal_approx(claim.radius, old_radius)


## Called by the registry when another founded centre creates a new shared frontier.
## Existing cities re-evaluate ownership immediately and never retain overlapping land.
func territory_rivals_changed() -> void:
	if _build_task >= 0:
		_rebuild_after_ground = true
	elif _ground_ready:
		_refresh_claim_boundary()


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
	_begin_bulk_rows()
	for settler in count:
		# Spread around the ship rather than stacked at it, and off the ring by a
		# little so a wave does not read as a circle drawn on the ground.
		var angle := TAU * float(settler) / float(count) + rng.randf() * 0.4
		var away := SPAWN_RING * (0.65 + rng.randf() * 0.5)
		var at := Vector2(cos(angle), sin(angle)) * away
		if _add(at, rng.randi()) >= 0:
			added += 1
	_end_bulk_rows()
	if added > 0:
		settlers_released.emit(added)
	return added


## Puts every living resident somewhere sensible around the ship.
##
## Legacy fallback for callers without a location sidecar. Ledger returns use
## [method restore_resident_places], because re-entering a city must not look like
## its whole population just emerged from the colony ship.
func scatter_residents(place_seed: int) -> void:
	var living := PackedInt32Array()
	for index in _state.size():
		if _active_resident(index):
			living.push_back(index)
	if living.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = place_seed
	for slot in living.size():
		var index := living[slot]
		var angle := TAU * float(slot) / float(living.size()) + rng.randf() * 0.4
		var away := SPAWN_RING * (0.65 + rng.randf() * 0.9)
		_local[index] = Vector2(cos(angle), sin(angle)) * away
		_goal[index] = _local[index]
		_heading[index] = Vector2.ZERO
		_state[index] = State.IDLE
		_since[index] = 0.0
	_refresh_rows()
	_settle_all_on_ground()


## Packs one site-local point into a signed decimetre pair. Stable row order means
## dead and departed entries remain in the array too, preserving every later index.
static func pack_resident_places(locals: PackedVector2Array) -> PackedInt32Array:
	var packed := PackedInt32Array()
	packed.resize(locals.size())
	for index in locals.size():
		var at := locals[index]
		var x := clampi(roundi(at.x * RETURN_PLACE_SCALE), -32768, 32767)
		var y := clampi(roundi(at.y * RETURN_PLACE_SCALE), -32768, 32767)
		packed[index] = (x & 0xffff) | ((y & 0xffff) << 16)
	return packed


static func unpack_resident_place(packed: int) -> Vector2:
	var x := packed & 0xffff
	var y := (packed >> 16) & 0xffff
	if x >= 0x8000:
		x -= 0x10000
	if y >= 0x8000:
		y -= 0x10000
	return Vector2(float(x), float(y)) / RETURN_PLACE_SCALE


func resident_place_snapshot() -> PackedInt32Array:
	return pack_resident_places(_local)


## Restores every pre-existing row where it last stood. Meeps cloned while the city
## was offscreen are distributed through the town or placed at an already available
## deed; they never emerge as one crowd at the colony ship.
func restore_resident_places(state: PackedInt32Array, place_seed: int) -> void:
	_return_unplaced.resize(_local.size())
	_return_unplaced.fill(0)
	for index in _local.size():
		if not _active_resident(index):
			continue
		var has_saved_place := index < state.size()
		var at := unpack_resident_place(state[index]) \
			if has_saved_place else _return_spread_place(index, place_seed)
		if not at.is_finite() or at.length() > MAX_CLAIM_RADIUS + COMBAT_MARGIN:
			has_saved_place = false
			at = _return_spread_place(index, place_seed)
		var home_at := _return_home_place(index)
		var at_home := home_at != Vector2.INF and (
			not has_saved_place or at.distance_to(home_at)
				<= maxf(grid.cell_size * 2.0, 4.0))
		if not has_saved_place:
			_return_unplaced[index] = 1
		if at_home:
			at = home_at
			_state[index] = State.AT_HOME
		else:
			_state[index] = State.IDLE
		_local[index] = at
		_goal[index] = at
		_heading[index] = Vector2.ZERO
		_job[index] = 0
		_since[index] = 0.0
		_timer[index] = _return_home_wait(index, place_seed) if at_home else 0.0
		_target[index] = at
		_render_local[index] = at
		_render_heading[index] = Vector2.ZERO
	_refresh_rows()
	if _ground_ready:
		rehome_returning_residents(place_seed)


## Revalidates saved points after the navigation grid and any ledger-built structures
## exist. Newly cloned rows gain their new deed here and start hidden inside that home.
func rehome_returning_residents(place_seed: int) -> void:
	if not _ground_ready or grid == null or claim == null:
		return
	_refresh_deeds()
	for index in _local.size():
		if not _active_resident(index):
			continue
		var home_at := _return_home_place(index)
		var gained_home := index < _return_unplaced.size() \
			and _return_unplaced[index] != 0 and home_at != Vector2.INF
		var cell := grid.cell_of(_local[index])
		var valid := grid.passable(cell) and claim.contains_cell(cell)
		if gained_home:
			_local[index] = home_at
			_goal[index] = home_at
			_state[index] = State.AT_HOME
			_timer[index] = _return_home_wait(index, place_seed)
			_return_unplaced[index] = 0
		elif not valid:
			var repaired := home_at if home_at != Vector2.INF \
				else _return_spread_place(index, place_seed)
			_local[index] = repaired
			_goal[index] = repaired
			_state[index] = State.AT_HOME \
				if home_at != Vector2.INF else State.IDLE
			_timer[index] = _return_home_wait(index, place_seed) \
				if home_at != Vector2.INF else 0.0
		_heading[index] = Vector2.ZERO
		_target[index] = _local[index]
		_render_local[index] = _local[index]
		_render_heading[index] = Vector2.ZERO
		_settle(index)
	_refresh_rows()


func _return_home_place(index: int) -> Vector2:
	var home := meep_home(index)
	if home < 0 or structures == null:
		return Vector2.INF
	var entry := structures.at(home)
	if entry == null or not entry.built():
		return Vector2.INF
	return grid.centre_of(structures.work_cell(home))


func _return_spread_place(index: int, place_seed: int) -> Vector2:
	var rng := RandomNumberGenerator.new()
	rng.seed = place_seed ^ int(_seed[index]) ^ (index * 0x45D9F3B)
	var inner := SPAWN_RING + grid.cell_size * 2.0
	var outer := maxf(claim_radius - grid.cell_size * 3.0, inner)
	var fallback := Vector2.RIGHT.rotated(rng.randf() * TAU) * inner
	for _attempt in 16:
		var angle := rng.randf() * TAU
		var away := lerpf(inner, outer, sqrt(rng.randf()))
		var at := Vector2(cos(angle), sin(angle)) * away
		fallback = at
		if not _ground_ready:
			return at
		var cell := grid.cell_of(at)
		if grid.passable(cell) and claim.contains_cell(cell):
			return grid.centre_of(cell)
	return fallback


func _return_home_wait(index: int, place_seed: int) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = place_seed ^ int(_seed[index]) ^ (index * 0x27D4EB2D)
	return rng.randf_range(HOME_WAIT_MIN, HOME_WAIT_MAX) \
		* _home_wait_multiplier()


## Drops everyone onto the height field they are standing over. Positions written
## from outside the simulation are two-dimensional; this is what gives them a third.
func _settle_all_on_ground() -> void:
	for index in _local.size():
		if _active_resident(index):
			_settle(index)


func _add(at: Vector2, row_seed: int, born_child := false) -> int:
	var index := _local.size()
	_local.push_back(at)
	_heading.push_back(Vector2.ZERO)
	_goal.push_back(at)
	_height.push_back(0.0)
	_health.push_back(stats.maximum_health)
	_state.push_back(State.IDLE)
	_roles.push_back(Role.CHILD)
	_workplaces.push_back(-1)
	_detail.push_back(Detail.COLD)
	_job.push_back(0)
	_seed.push_back(row_seed)
	_names.push_back(_generated_name(index))
	_siblings.push_back(-1)
	_ages.push_back(0.0)
	_dead_for.push_back(-1.0)
	_death_causes.push_back("")
	if (index & 1) != 0 and index - 1 < _siblings.size():
		_siblings[index] = index - 1
		_siblings[index - 1] = index
	_since.push_back(0.0)
	_timer.push_back(0.0)
	_idle_turn.push_back(posmod(row_seed + index, 2))
	_target.push_back(at)
	_render_local.push_back(at)
	_render_heading.push_back(Vector2.ZERO)
	_render_height.push_back(0.0)
	_near_squared.push_back(0.0)
	# Eagerly, unlike every other change to these: a row that has never been graded
	# is the one thing a list a tick out of date could genuinely lose.
	_active_rows.push_back(index)
	_visible_rows.push_back(index)
	if _deeds.size() <= index:
		_deeds.push_back(-1)
	if _former_deeds.size() <= index:
		_former_deeds.push_back(-1)
		_town_changed = true
	_alive += 1
	if not born_child:
		_assign_adult_role(index)
	if _bulk_rows == 0:
		_refresh_deeds()
	if _ground_ready:
		_settle(index)
	if _bulk_rows == 0 and _render_ready and _render != null \
			and _render.multimesh != null:
		_render.multimesh.instance_count = _local.size()
	return index


func _assign_adult_role(index: int) -> void:
	if index < 0 or index >= _roles.size() or not _active_resident(index):
		return
	var builders := 0
	var harvesters := 0
	var homebodies := 0
	for row in _roles.size():
		if row == index or not _active_resident(row):
			continue
		match _roles[row] as Role:
			Role.BUILDER:
				builders += 1
			Role.HARVESTER:
				harvesters += 1
			Role.HOMEBODY:
				homebodies += 1
	var adult_total := builders + harvesters + homebodies + 1
	var builder_target := maxi(roundi(float(adult_total)
		* BUILDER_ROLE_SHARE), mini(site_limit_for(tier, _alive), adult_total))
	var harvester_target := mini(roundi(float(adult_total)
		* HARVESTER_ROLE_SHARE), maxi(adult_total - builder_target, 0))
	var homebody_target := maxi(
		adult_total - builder_target - harvester_target, 0)
	var deficits := [
		builder_target - builders,
		harvester_target - harvesters,
		homebody_target - homebodies,
	]
	var choices := [Role.BUILDER, Role.HARVESTER, Role.HOMEBODY]
	var selected := 0
	for slot in range(1, deficits.size()):
		if int(deficits[slot]) > int(deficits[selected]):
			selected = slot
	_roles[index] = choices[selected]


func _mature_children() -> void:
	var changed := false
	for index in _roles.size():
		if _roles[index] != Role.CHILD or not _active_resident(index) \
				or meep_age(index) + 0.0001 < CHILDHOOD_SECONDS:
			continue
		_assign_adult_role(index)
		_stroll_paths.erase(index)
		if _state[index] == State.STROLL:
			_state[index] = State.IDLE
		_town_changed = true
		changed = true
	if changed:
		_invalidate_report_roster()


## Holds back the two pieces of [method _add] that are answers about the whole
## population rather than about the new row.
##
## Assigning households walks every resident and every residence, and growing the
## MultiMesh reallocates its instance buffer. Neither is wrong once; both are
## quadratic when a returning city lays down a thousand rows in a single tick,
## which is how reifying one town reached three hundred and fifty milliseconds.
## Nested, so a restore that releases settlers inside a larger fill still pays for
## the batch once.
func _begin_bulk_rows() -> void:
	_bulk_rows += 1


func _end_bulk_rows() -> void:
	_bulk_rows = maxi(_bulk_rows - 1, 0)
	if _bulk_rows > 0:
		return
	_refresh_deeds()
	if _render_ready and _render != null and _render.multimesh != null:
		_render.multimesh.instance_count = _local.size()


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
	_height[index] = grid.walk_height_at(cell) \
		if grid.has_walk_surface(cell) \
		else (_shape.elevation(site.direction_at(_local[index]),
			_spacing_drawn()) if _shape != null else grid.height_at(cell))
	_snap_render_pose(index)


func count() -> int:
	return _local.size()


func alive_count() -> int:
	return _alive


## Durable simulation rows for a cold sandbox restore. The multiplayer founding
## snapshot can omit these because a live host sends positions ten times a
## second; a save has no old host to send that first packet.
func population_snapshot() -> Dictionary:
	return {
		"local": _local.duplicate(),
		"heading": _heading.duplicate(),
		"goal": _goal.duplicate(),
		"height": _height.duplicate(),
		"health": _health.duplicate(),
		"maximum_health": stats.maximum_health if stats != null else 24.0,
		"state": _state.duplicate(),
		"detail": _detail.duplicate(),
		"job": _job.duplicate(),
		"seed": _seed.duplicate(),
		"since": _since.duplicate(),
		"timer": _timer.duplicate(),
		"idle_turn": _idle_turn.duplicate(),
		"target": _target.duplicate(),
		"cursor": _cursor,
		"tick_accum": _tick_accum,
	}


func apply_population_snapshot(snapshot: Dictionary) -> void:
	var local_value: Variant = snapshot.get("local", PackedVector2Array())
	if not local_value is PackedVector2Array:
		return
	var saved_local := local_value as PackedVector2Array
	var row_count := mini(saved_local.size(), 65536)
	_begin_bulk_rows()
	while _local.size() < row_count:
		_add(Vector2.ZERO, _local.size())
	_end_bulk_rows()
	if _local.size() > row_count:
		_local.resize(row_count)
		_heading.resize(row_count)
		_goal.resize(row_count)
		_height.resize(row_count)
		_health.resize(row_count)
		_state.resize(row_count)
		_detail.resize(row_count)
		_job.resize(row_count)
		_seed.resize(row_count)
		_names.resize(row_count)
		_siblings.resize(row_count)
		_ages.resize(row_count)
		_dead_for.resize(row_count)
		_death_causes.resize(row_count)
		_since.resize(row_count)
		_timer.resize(row_count)
		_idle_turn.resize(row_count)
		_target.resize(row_count)
		_near_squared.resize(row_count)
		_deeds.resize(row_count)
		_former_deeds.resize(row_count)
	_local = saved_local.slice(0, row_count)

	var heading_value: Variant = snapshot.get("heading", PackedVector2Array())
	if heading_value is PackedVector2Array \
			and (heading_value as PackedVector2Array).size() >= row_count:
		_heading = (heading_value as PackedVector2Array).slice(0, row_count)
	var goal_value: Variant = snapshot.get("goal", PackedVector2Array())
	if goal_value is PackedVector2Array \
			and (goal_value as PackedVector2Array).size() >= row_count:
		_goal = (goal_value as PackedVector2Array).slice(0, row_count)
	var height_value: Variant = snapshot.get("height", PackedFloat32Array())
	if height_value is PackedFloat32Array \
			and (height_value as PackedFloat32Array).size() >= row_count:
		_height = (height_value as PackedFloat32Array).slice(0, row_count)
	var health_value: Variant = snapshot.get("health", PackedFloat32Array())
	if health_value is PackedFloat32Array \
			and (health_value as PackedFloat32Array).size() >= row_count:
		_health = (health_value as PackedFloat32Array).slice(0, row_count)
	var state_value: Variant = snapshot.get("state", PackedByteArray())
	if state_value is PackedByteArray \
			and (state_value as PackedByteArray).size() >= row_count:
		_state = (state_value as PackedByteArray).slice(0, row_count)
	var detail_value: Variant = snapshot.get("detail", PackedByteArray())
	if detail_value is PackedByteArray \
			and (detail_value as PackedByteArray).size() >= row_count:
		_detail = (detail_value as PackedByteArray).slice(0, row_count)
	var job_value: Variant = snapshot.get("job", PackedInt32Array())
	if job_value is PackedInt32Array \
			and (job_value as PackedInt32Array).size() >= row_count:
		_job = (job_value as PackedInt32Array).slice(0, row_count)
	var seed_value: Variant = snapshot.get("seed", PackedInt32Array())
	if seed_value is PackedInt32Array \
			and (seed_value as PackedInt32Array).size() >= row_count:
		_seed = (seed_value as PackedInt32Array).slice(0, row_count)
	var since_value: Variant = snapshot.get("since", PackedFloat32Array())
	if since_value is PackedFloat32Array \
			and (since_value as PackedFloat32Array).size() >= row_count:
		_since = (since_value as PackedFloat32Array).slice(0, row_count)
	var timer_value: Variant = snapshot.get("timer", PackedFloat32Array())
	if timer_value is PackedFloat32Array \
			and (timer_value as PackedFloat32Array).size() >= row_count:
		_timer = (timer_value as PackedFloat32Array).slice(0, row_count)
	var turn_value: Variant = snapshot.get("idle_turn", PackedByteArray())
	if turn_value is PackedByteArray \
			and (turn_value as PackedByteArray).size() >= row_count:
		_idle_turn = (turn_value as PackedByteArray).slice(0, row_count)
	var target_value: Variant = snapshot.get("target", PackedVector2Array())
	if target_value is PackedVector2Array \
			and (target_value as PackedVector2Array).size() >= row_count:
		_target = (target_value as PackedVector2Array).slice(0, row_count)

	_alive = 0
	for index in row_count:
		_state[index] = clampi(
			int(_state[index]), State.IDLE, State.AT_WORKPLACE)
		_health[index] = clampf(
			_health[index] if is_finite(_health[index]) else stats.maximum_health,
			0.0, stats.maximum_health)
		if _job[index] > 0 and (
				tasks == null or tasks.job(_job[index]) == null):
			_job[index] = 0
		if _active_resident(index):
			_alive += 1
	_near_squared.resize(row_count)
	_near_squared.fill(0.0)
	_crowd_next.resize(row_count)
	_refresh_rows()
	_cursor = posmod(int(snapshot.get("cursor", 0)), maxi(row_count, 1))
	_tick_accum = maxf(float(snapshot.get("tick_accum", 0.0)), 0.0)
	_town_changed = true
	_snap_render_poses()
	if _render_ready and _render != null and _render.multimesh != null:
		_render.multimesh.instance_count = row_count


# --- The tick ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var profile_started := Time.get_ticks_usec() if _profiling() else 0
	if _build_task >= 0 and WorkerThreadPool.is_task_completed(_build_task):
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_finish_ground()
	var stage_started := Time.get_ticks_usec() if _profiling() else 0
	_collect_fields()
	_record_performance(&"physics_collect_fields", stage_started)
	if not _is_host():
		_advance_life_clocks(delta)
		_follow(delta)
		_record_performance(&"physics_total", profile_started, &"physics")
		return
	_tick_accum += delta
	if _tick_accum < SIM_STEP:
		_record_performance(&"physics_total", profile_started, &"physics")
		return
	# The whole accumulated time, not one nominal step. A frame that took longer
	# than a tick has to move the colony that far, or a busy scene runs the town in
	# slow motion.
	var elapsed := _tick_accum
	_tick_accum = 0.0
	_simulate(elapsed)
	_record_performance(&"physics_total", profile_started, &"physics")


func _process(delta: float) -> void:
	if not _ground_ready:
		return
	var profile_started := Time.get_ticks_usec() if _profiling() else 0
	# The host has already graded this tick, as part of deciding who thinks. A
	# client never ticks, and still has to know who to draw.
	if not _is_host():
		_grade_left -= delta
		if _grade_left <= 0.0:
			_grade_left = GRADE_INTERVAL
			_refresh_eyes()
			_grade()
	# Nobody within four hundred metres of anybody who lives here. The town itself
	# still draws — a building is visible long past the distance its occupants are —
	# but interpolating, batching and lending colliders for two hundred settlers who
	# resolve to nothing is the bulk of a resident colony's frame cost, and a planet
	# of towns is mostly towns in exactly this state.
	var wants_presentation := _nearest_row_squared <= WARM_RANGE * WARM_RANGE
	var stage_started := Time.get_ticks_usec() if _profiling() else 0
	if wants_presentation or _presenting:
		_presenting = wants_presentation
		_smooth_render(delta)
		_draw()
		_record_performance(&"process_meep_draw", stage_started)
		stage_started = Time.get_ticks_usec() if _profiling() else 0
		_lend_proxies()
		_lend_block_proxies()
		_record_performance(&"process_proxies", stage_started)
	if structures != null:
		stage_started = Time.get_ticks_usec() if _profiling() else 0
		structures.draw()
		structures.lend_colliders(_view_eye, claim_radius)
		_record_performance(&"process_structures", stage_started)
	if roads != null:
		stage_started = Time.get_ticks_usec() if _profiling() else 0
		roads.draw(MeepRoads.RIBBON_PATCHES_PER_FRAME)
		roads.advance_flora_clearance()
		roads.update_lights(delta, _view_eye)
		_record_performance(&"process_roads", stage_started)
	_record_performance(&"process_total", profile_started, &"process")


func _simulate(elapsed: float) -> void:
	var profile_started := Time.get_ticks_usec() if _profiling() else 0
	_field_refresh_left = maxf(_field_refresh_left - elapsed, 0.0)
	_simulate_harvester(elapsed)
	_advance_life_clocks(elapsed)
	_mature_children()
	var border_started := Time.get_ticks_usec() if _profiling() else 0
	_simulate_border_growth(elapsed)
	_record_performance(&"simulate_border_growth", border_started)
	if not _ground_ready or _local.is_empty():
		# Production is independent of navigation and workers. It can therefore need
		# to publish while a ground rebuild is in flight or after a town is emptied.
		_publish()
		_record_performance(&"simulate_total", profile_started)
		return
	_refresh_eyes()
	_grade()
	_rebuild_crowd_index()
	_plan_left -= elapsed
	_surface_scan_left = maxf(_surface_scan_left - elapsed, 0.0)
	if _plan_left <= 0.0:
		_plan_left = _planning_interval()
		var stage_started := Time.get_ticks_usec() if _profiling() else 0
		_plan_town()
		_record_performance(&"simulate_plan", stage_started)
	_timber_read_left -= elapsed
	if _timber_read_left <= 0.0 and not _reading_timber():
		_timber_read_left = TIMBER_INTERVAL
		if standing_timber() == 0 \
				and tasks.count_of(MeepTasks.Kind.MINE) == 0:
			# A localized GroundCover may still have been streaming when the navigation
			# bake first finished. Re-read only after the old stable list is exhausted,
			# when replacing its slot numbers cannot invalidate an open mining job.
			_begin_timber_read()
	if _reading_timber():
		var stage_started := Time.get_ticks_usec() if _profiling() else 0
		_advance_timber_read()
		_record_performance(&"simulate_read_timber", stage_started)
	if _road_clear_pending_head < _road_clear_pending.size():
		var stage_started := Time.get_ticks_usec() \
			if _profiling() else 0
		_clear_next_completed_road_cell()
		_record_performance(&"simulate_clear_completed_road", stage_started)
	_road_clear_left -= elapsed
	if _road_clear_left <= 0.0:
		_road_clear_left = ROAD_CLEAR_INTERVAL
		var stage_started := Time.get_ticks_usec() if _profiling() else 0
		_maintain_roads()
		_record_performance(&"simulate_maintain_roads", stage_started)
	_structure_clear_left -= elapsed
	if _structure_clear_left <= 0.0:
		_structure_clear_left = STRUCTURE_CLEAR_INTERVAL
		var stage_started := Time.get_ticks_usec() if _profiling() else 0
		_maintain_structures()
		_record_performance(&"simulate_maintain_structures", stage_started)
	var residents_started := Time.get_ticks_usec() if _profiling() else 0
	_advance_residents(elapsed)
	_record_performance(&"simulate_residents", residents_started)
	_publish()
	_record_performance(&"simulate_total", profile_started)


## Ages are simulation time, not wall-clock time. A transferred founder carries this
## clock to the child city; dead rows retain their final age while their memorial clock
## records how long ago the death occurred.
func _advance_life_clocks(elapsed: float) -> void:
	if elapsed <= 0.0:
		return
	for index in _memorial_rows:
		if _state[index] == State.DEAD:
			_dead_for[index] = maxf(float(_dead_for[index]), 0.0) + elapsed
	# The living, plus anybody who has died or left since the last grade — the state
	# test is what sorts those, exactly as it did when this walked every row.
	for index in _active_rows:
		if _state[index] == State.DEAD:
			_dead_for[index] = maxf(float(_dead_for[index]), 0.0) + elapsed
		elif _state[index] != State.DEPARTED:
			_ages[index] = maxf(float(_ages[index]), 0.0) + elapsed


## Advances living rows independently of camera distance. Dead and departed history
## does not consume the active-row budget: a parent city can therefore keep all 512
## current residents working even after several settlement expeditions have left
## immutable founder rows behind.
func _advance_residents(elapsed: float) -> void:
	var total := _local.size()
	for index in _active_rows:
		if _active_resident(index):
			_since[index] += elapsed
	var active_budget := mini(STEPS_PER_TICK, _alive)
	var visited := 0
	var considered := 0
	var trace := RuntimeTelemetry.deep_enabled()
	while visited < total and considered < active_budget:
		if _cursor >= total:
			_cursor = 0
		var index := _cursor
		_cursor += 1
		visited += 1
		if not _active_resident(index):
			continue
		considered += 1
		var due := _interval(_detail[index] as Detail)
		if _since[index] < due:
			continue
		var step := _since[index]
		_since[index] = 0.0
		if not trace:
			_step(index, step)
			continue
		# Every resident steps on every tick, so a burst inside this pass is one
		# behaviour going expensive rather than the pass growing. Splitting the
		# trace by state is what names it.
		var doing := _state[index] as State
		var began := Time.get_ticks_usec()
		_step(index, step)
		RuntimeTelemetry.record_activity(&"meeps",
			STEP_TRACE_LABELS[doing], Time.get_ticks_usec() - began)


## Credits only this host-owned bank, and only while the commissioned physical
## structure is complete. Snapshot application never calls this method, so receiving
## current resources/lifetime cannot itself produce another interval.
func _simulate_harvester(elapsed: float) -> float:
	if not _is_host() or not is_finite(elapsed) or elapsed <= 0.0 \
			or biomass_harvester_index() < 0:
		return 0.0
	var bounded := minf(elapsed, MAX_HARVEST_ELAPSED)
	var produced := harvester_rate() * bounded
	if produced <= 0.0:
		return 0.0
	credit(produced)
	harvester_lifetime += produced
	_harvester_sync_accum += bounded
	if _harvester_sync_accum >= HARVEST_SYNC_INTERVAL:
		_harvester_sync_accum = fmod(
			_harvester_sync_accum, HARVEST_SYNC_INTERVAL)
		_progression_changed = true
	return produced


static func population_expansion_bonus(population: int) -> float:
	var steps := floori(float(maxi(population, 0))
		/ float(EXPANSION_POPULATION_STEP))
	return minf(float(steps) * EXPANSION_POPULATION_RATE,
		EXPANSION_POPULATION_BONUS_MAX)


func expansion_rate() -> float:
	return EXPANSION_BASE_RATE \
		+ population_expansion_bonus(_alive)


## Radius is continuous authoritative state; the cell claim and visible wall update
## only after another two-metre grid band can actually change. Large distant-simulation
## steps collapse to one flood rather than replaying every intermediate ring.
func _simulate_border_growth(elapsed: float) -> void:
	if not _is_host() or _alive <= 0 or not is_finite(elapsed) \
			or elapsed <= 0.0:
		return
	var target := MAX_CLAIM_RADIUS
	if city_plan != null and city_plan.generated():
		target = city_plan.target_radius()
		if target <= 0.0:
			return
	target = minf(target, MAX_CLAIM_RADIUS)
	if claim_radius >= target:
		if city_plan != null:
			city_plan.finish_expansion(claim_radius)
		return
	var was := claim_radius
	claim_radius = minf(
		claim_radius + expansion_rate() * elapsed, target)
	if claim_radius <= was:
		return
	if city_plan != null:
		city_plan.finish_expansion(claim_radius)
	_expansion_sync_accum += elapsed
	if _expansion_sync_accum >= EXPANSION_SYNC_INTERVAL \
			or claim_radius >= target:
		_expansion_sync_accum = fmod(
			_expansion_sync_accum, EXPANSION_SYNC_INTERVAL)
		_progression_changed = true
	var material_growth := grid != null and (
		claim_radius - claim.radius >= grid.cell_size - 0.0001
		or claim_radius >= target)
	if not material_growth:
		return
	if _build_task >= 0:
		if claim_radius >= target \
				or claim_radius - _ground_bake_radius \
					>= grid.cell_size - 0.0001:
			_rebuild_after_ground = true
	elif _ground_ready:
		_refresh_claim_boundary(true)


func _interval(detail: Detail) -> float:
	match detail:
		Detail.HOT:
			return HOT_INTERVAL
		Detail.WARM:
			return WARM_INTERVAL
		_:
			return COLD_INTERVAL


func _planning_interval() -> float:
	var maturity := clampf(
		float(_alive - STARTER_POPULATION) / 168.0, 0.0, 1.0)
	return lerpf(PLAN_INTERVAL, MATURE_PLAN_INTERVAL, maturity)


## Opt-in timings for deterministic performance harnesses. Normal gameplay pays
## only the disabled boolean branches; no wall clock or Dictionary work occurs.
func set_performance_profiling(enabled: bool) -> void:
	_performance_profiling = enabled
	_performance_profile.clear()


func performance_profile() -> Dictionary:
	var report := {}
	for label_variant: Variant in _performance_profile:
		var label := label_variant as StringName
		var row: Dictionary = _performance_profile[label]
		report[label] = {
			"calls": int(row["calls"]),
			"total_ms": float(row["total_usec"]) / 1000.0,
			"max_ms": float(row["max_usec"]) / 1000.0,
		}
	return report


func _profiling() -> bool:
	return _performance_profiling or RuntimeTelemetry.deep_enabled()


## [param step] names the callback when the label covers a whole one, so that the
## recorder can tell a roll-up apart from the stages nested inside it. See
## [method RuntimeTelemetry.record_process_step].
func _record_performance(label: StringName, began_usec: int,
		step := &"") -> void:
	if began_usec <= 0:
		return
	var spent := maxi(Time.get_ticks_usec() - began_usec, 0)
	if RuntimeTelemetry.deep_enabled():
		match step:
			&"process":
				RuntimeTelemetry.record_process_step(&"meeps", label, spent)
			&"physics":
				RuntimeTelemetry.record_physics_step(&"meeps", label, spent)
			_:
				RuntimeTelemetry.record_activity(&"meeps", label, spent)
	if not _performance_profiling:
		return
	var row: Dictionary = _performance_profile.get(label, {
		"calls": 0,
		"total_usec": 0,
		"max_usec": 0,
	})
	row["calls"] = int(row["calls"]) + 1
	row["total_usec"] = int(row["total_usec"]) + spent
	row["max_usec"] = maxi(int(row["max_usec"]), spent)
	_performance_profile[label] = row


# --- What the town does ------------------------------------------------------

## The colony's own decisions, a couple of seconds apart: what is worth cutting down,
## what is worth paving or building, and whether anyone should be making more Meeps.
##
## The colony's job rather than each Meep's, and that is the load-bearing part. A
## settler deciding for itself what the town needs has to look at the whole town to
## decide, and a hundred of them doing that is a hundred surveys of the same town every
## tick. Here it happens once and what reaches a Meep is a short list of work with
## somewhere to stand. It is also why a Meep never has an opinion about biomass: what
## the colony cannot afford is never posted, so nobody sets off to build something that
## will not be paid for.
func _plan_town() -> void:
	var stage_started := Time.get_ticks_usec() if _profiling() else 0
	_plan_mining()
	_record_performance(&"plan_mining", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_surfaces()
	_record_performance(&"plan_surfaces", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_commissioned()
	_record_performance(&"plan_commissioned", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_dock_hut()
	_record_performance(&"plan_dock_hut", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_roads()
	_record_performance(&"plan_roads", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_vertical_upgrade()
	_record_performance(&"plan_vertical_upgrade", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_building()
	_record_performance(&"plan_building", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_plan_cloning()
	_record_performance(&"plan_cloning", stage_started)
	stage_started = Time.get_ticks_usec() if _profiling() else 0
	_refresh_current_tier_completion()
	_record_performance(&"plan_refresh_tier", stage_started)


func _plan_surfaces() -> void:
	if roads == null or grid == null or claim == null or not _ground_ready \
			or roads.has_unfinished_surface_project():
		return
	var bridges := city_upgrade_built(CityPurchase.BRIDGES) \
		and roads.surface_cell_count(MeepRoads.SurfaceKind.BRIDGE) \
			+ roads.surface_cell_count(MeepRoads.SurfaceKind.RAMP) \
			< MAX_BRIDGE_SURFACE_CELLS
	var coasts := city_upgrade_built(CityPurchase.COASTS) \
		and roads.surface_cell_count(MeepRoads.SurfaceKind.DOCK) \
			< MAX_DOCK_SURFACE_CELLS
	if not bridges and not coasts:
		return
	if _surface_candidate_revision != grid.revision:
		_surface_candidate.clear()
		_surface_candidate_revision = grid.revision
	if _surface_scan_revision == grid.revision:
		return
	if _surface_candidate.is_empty():
		if _surface_scan_left > 0.0:
			return
		_surface_scan_left = SURFACE_SCAN_INTERVAL
		_surface_candidate = roads.next_surface_candidate(bridges, coasts)
		if _surface_candidate.is_empty():
			_surface_scan_revision = grid.revision
			return
	var candidate := _surface_candidate
	var start: Vector2i = candidate["start"]
	var width_class := MeepRoads.width_class_for_tier(maxi(tier, 1))
	# A bridge starts at concrete, not at an arbitrary frontier cell. Pave the
	# connected land approach first, then reconsider the same shortest crossing.
	if not grid.has_flag(start, MeepGrid.FLAG_ROAD):
		var field := _home_field()
		if field == null:
			return
		var approach := roads.path_home_from(start, field)
		if approach.is_empty():
			return
		if _post_surface_road(approach, PackedFloat32Array(),
				MeepRoads.SurfaceKind.LAND, width_class, start):
			_surface_candidate.clear()
		return
	var cells: PackedInt32Array = candidate["cells"]
	var heights: PackedFloat32Array = candidate["heights"]
	var surface_kind := int(candidate["surface_kind"])
	if _post_surface_road(
			cells, heights, surface_kind, width_class, start):
		_surface_candidate.clear()


func _plan_dock_hut() -> void:
	if not city_upgrade_built(CityPurchase.COASTS) or structures == null \
			or roads == null or _alive < housing_capacity() \
			or structures.count() > structures.built_count() \
			or commissioned_work_blocks_routine():
		return
	var dock_cells := roads.surface_cell_count(MeepRoads.SurfaceKind.DOCK)
	var dock_huts := structures.count_of(MeepStructures.Kind.DOCK_HUT)
	var allowance := mini(floori(float(dock_cells) / 12.0), 4 + tier * 2)
	if dock_huts >= allowance:
		return
	var plan := MeepStructures.plan_of(MeepStructures.Kind.DOCK_HUT)
	if available() < plan.cost:
		return
	var structure := structures.place_dock_hut(maxi(tier, 1))
	if structure < 0:
		return
	var posted := tasks.job(tasks.post(MeepTasks.Kind.BUILD,
		structures.work_cell(structure), BUILD_PRIORITY + 0.1,
		plan.crew, plan.work, plan.cost))
	if posted == null:
		return
	posted.subject = structure
	structures.at(structure).job = posted.id
	committed += plan.cost
	_town_changed = true


func _post_surface_road(cells: PackedInt32Array,
		heights: PackedFloat32Array, surface_kind: int,
		width_class: int, work_cell: Vector2i) -> bool:
	if cells.is_empty():
		return false
	var cost := roads.cost_for(cells, width_class, surface_kind)
	if available() < cost:
		return false
	var posted := tasks.job(tasks.post(MeepTasks.Kind.ROAD, work_cell,
		SURFACE_PRIORITY, MeepRoads.CREW,
		roads.work_for(cells, width_class, surface_kind), cost))
	if posted == null:
		return false
	var road := roads.plan(-100000 - roads.count(), cells,
		width_class, surface_kind, heights, true)
	posted.subject = road
	roads.at(road).job = posted.id
	committed += cost
	_town_changed = true
	return true


func development_inner_radius_for_tier(target_tier: int) -> float:
	return CITY_TIER_DEVELOPMENT_INNER_RADII[
		clampi(target_tier, 0, MAX_CITY_TIER)]


## Reads harvestable non-grass flora inside the claim, nearest first.
##
## Each field owns the promise behind its answer. FlowerTreeField is resident;
## harvest-enabled GroundCover answers from [method GroundCover.survey_harvestable],
## which resows the claim's cells in memory instead of reading the streamed tiles.
## That distinction is the whole of the town's independence from the camera: asking
## for standing plants only found them while somebody was there to see them, so a
## town nobody was watching had no timber, earned no biomass, and stood about.
##
## The list is replaced only when exhausted and no mining jobs remain, keeping the
## slot carried by every posted job stable.
## Reads the harvestable woods inside the claim, all of it, now.
##
## Kept for callers that need an answer in the same frame they asked. The town itself
## uses [method _begin_timber_read] instead.
func _read_timber() -> void:
	_begin_timber_read()
	while _reading_timber():
		_advance_timber_read(0)


## Begins a fresh reading of the harvestable woods inside the claim.
##
## Surveying every flora field on the planet at once cost 58 ms of the single
## main-thread tick that adopts a finished ground bake, which was most of the worst
## frame a settled city produced. The pass now takes a slice of one field per
## simulation step.
func _begin_timber_read() -> void:
	_timber = PackedVector4Array()
	_timber_clearance = PackedFloat32Array()
	_timber_read_left = TIMBER_INTERVAL
	_timber_reading = PackedVector4Array()
	_timber_reading_clearance = PackedFloat32Array()
	_timber_fields_left.clear()
	_timber_cursor = 0
	if _planet == null or site == null or grid == null or not _is_host():
		return
	_timber_reading_centre = _planet.to_global(
		site.point_at(Vector2.ZERO, _centre_height))
	for field_variant: Variant in get_tree().get_nodes_in_group(
			DamageHit.FIELD_GROUP):
		var field := field_variant as Node
		if field == null or not DamageHit.in_same_world(self, field) \
				or not field.has_method(&"harvest_value") \
				or not field.has_method(&"harvest_at"):
			continue
		_timber_fields_left.push_back(field)


func _reading_timber() -> bool:
	return not _timber_fields_left.is_empty()


## Surveys part of one field's woods, and publishes the whole reading once the last
## field is in. Job board entries address timber by slot number, so a half-read list
## can never be the published one.
##
## A field is left on the stack until it says it has no more to give: one field of a
## grown claim is tens of thousands of plants and thirty-nine milliseconds, which is
## not a slice of anything. [param budget_usec] of zero reads each field whole, which
## is what the synchronous [method _read_timber] wants.
func _advance_timber_read(budget_usec := TIMBER_SURVEY_BUDGET_USEC) -> void:
	if _timber_fields_left.is_empty() or grid == null or claim == null:
		return
	var field := _timber_fields_left.back() as Node
	var finished := true
	if is_instance_valid(field) and field.is_inside_tree():
		# Inside the grid, since a route can only be worked out where there are cells.
		var reach := grid.half_span() - grid.cell_size * 2.0
		if field.has_method(&"survey_harvestable_slice"):
			var slice := field.call(&"survey_harvestable_slice",
				_timber_reading_centre, reach, _timber_cursor,
				budget_usec) as Dictionary
			_gather_timber(field, slice["found"] as PackedVector4Array)
			_timber_cursor = int(slice["next"])
			finished = _timber_cursor < 0
		else:
			var reader := &"survey_harvestable" \
				if field.has_method(&"survey_harvestable") else &"standing_near"
			if field.has_method(reader):
				_gather_timber(field, field.call(
					reader, _timber_reading_centre, reach))
	if not finished:
		return
	_timber_fields_left.pop_back()
	_timber_cursor = 0
	if not _timber_fields_left.is_empty():
		return
	_timber = _timber_reading
	_timber_clearance = _timber_reading_clearance
	_timber_reading = PackedVector4Array()
	_timber_reading_clearance = PackedFloat32Array()
	_sort_timber(_timber_reading_centre)


## Keeps the harvestable part of what one field reported.
func _gather_timber(field: Node, standing: PackedVector4Array) -> void:
	for tree in standing:
		var root := Vector3(tree.x, tree.y, tree.z)
		var root_cell := grid.cell_of(_site_local_of(root))
		# A colony consumes only what its wall encloses. The surrounding grid is
		# wider than the claim so path fields have a safe border, but it is not
		# additional timber rights.
		if not claim.contains_cell(root_cell):
			continue
		var pays := float(field.call(&"harvest_value", tree.w))
		if pays <= 0.0:
			continue
		_timber_reading.push_back(Vector4(tree.x, tree.y, tree.z, pays))
		_timber_reading_clearance.push_back(clampf(
			tree.w * 0.32 + 0.4, 0.7, TRUNK_CLEARANCE))


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
	var clearances := PackedFloat32Array()
	for entry in order:
		sorted.push_back(_timber[entry.y])
		clearances.push_back(_timber_clearance[entry.y])
	_timber = sorted
	_timber_clearance = clearances


## Free biomass the planner would like on hand for the next growth turn. Work
## already posted is excluded by [method available], so this is only the next
## structure, a plausible street branch, and currently usable cloner places.
func mining_resource_runway() -> float:
	var runway := 0.0
	var kind := _wanted_kind()
	if kind >= 0:
		runway += MeepStructures.plan_of(kind).cost
	if not current_tier_full() and structures != null and roads != null:
		runway += MINE_ROAD_RUNWAY
	if structures != null:
		var cloners := structures.count_of(MeepStructures.Kind.CLONER, true)
		var projected := _alive + _cloners_inside()
		var room := maxi(
			mini(housing_capacity(), population_ceiling()) - projected, 0)
		runway += float(mini(room, CLONE_CREW * cloners)) * CLONE_COST
	return maxf(runway, CLONE_COST)


## Zero is an empty next-turn buffer; one means two complete runways are already
## free. The second runway is deliberate hysteresis: one funded hut should start
## building, while a larger player contribution is what releases nearly every
## harvester to construction.
func mining_funding_coverage() -> float:
	var runway := mining_resource_runway()
	return clampf(available() / maxf(runway * 2.0, 0.001), 0.0, 1.0)


func mining_job_target() -> int:
	if _alive <= 0:
		return 0
	var coverage := mining_funding_coverage()
	var share := lerpf(MINE_SHARE, MINE_SHARE_FUNDED, coverage)
	var floor := MINE_JOBS_MIN \
		if available() < mining_resource_runway() else MINE_JOBS_FUNDED_MIN
	var wanted := maxi(floor, roundi(float(_alive) * share))
	# Preserve somebody for the higher-priority work the bank just enabled.
	return clampi(wanted, 1, maxi(_alive - 1, 1))


## Keeps the funded number of felling offers open at the nearest trees. Existing
## miners finish their current chop when a donation lowers the target, but closed
## offers are not claimed again; the next decisions therefore flow to buildings,
## roads and the cloner.
func _plan_mining() -> void:
	if _timber.is_empty() or grid == null:
		return
	var wanted := mining_job_target()
	var coverage := mining_funding_coverage()
	var priority := lerpf(MINE_PRIORITY, MINE_PRIORITY * 0.62, coverage)
	var mining_jobs := tasks.all_of(MeepTasks.Kind.MINE)
	# Keep occupied work in the retained set first so lowering the target never
	# opens replacement jobs while those Meeps are still walking or chopping.
	mining_jobs.sort_custom(func(a: MeepTasks.Job, b: MeepTasks.Job) -> bool:
		if (a.workers > 0) != (b.workers > 0):
			return a.workers > b.workers
		return a.subject < b.subject)
	for index in mining_jobs.size():
		var entry := mining_jobs[index]
		entry.enabled = index < wanted
		entry.priority = priority
	var open := mini(wanted, mining_jobs.size())
	for slot in _timber.size():
		if open >= wanted:
			return
		var tree := _timber[slot]
		if tree.w <= 0.0 or tasks.any_about(MeepTasks.Kind.MINE, slot):
			continue
		var stand := _stand_beside(tree, slot)
		if not grid.passable(stand) or not claim.contains_cell(stand):
			# Rooted somewhere nobody can stand next to. Nothing about that changes,
			# so it stops being timber rather than being offered again every review.
			_timber[slot] = Vector4(tree.x, tree.y, tree.z, 0.0)
			continue
		var posted := tasks.job(tasks.post(MeepTasks.Kind.MINE, stand,
			priority, 1, MINE_SECONDS))
		if posted == null:
			continue
		posted.subject = slot
		posted.spot = Vector3(tree.x, tree.y, tree.z)
		posted.payout = tree.w
		open += 1


## The cell to chop from: beside the trunk, on the town side of it. The cell a tree is
## rooted in is filled by the tree, so a job posted there is a job nobody can arrive at.
func _stand_beside(tree: Vector4, slot: int) -> Vector2i:
	var local := _site_local_of(Vector3(tree.x, tree.y, tree.z))
	var inward := local.normalized() if local.length() > 0.01 else Vector2.RIGHT
	var clearance := _timber_clearance[slot] \
		if slot >= 0 and slot < _timber_clearance.size() else TRUNK_CLEARANCE
	return grid.cell_of(local - inward * clearance)


static func commissioned_work_unlocked(population: int) -> bool:
	return population >= COMMISSION_POPULATION


func commissioned_work_pending() -> bool:
	return _next_commission_purchase() >= 0


func commissioned_work_blocks_routine() -> bool:
	return commissioned_work_pending() and not _commission_waiting_for_space


func _set_commission_waiting_for_space(waiting: bool) -> void:
	if _commission_waiting_for_space == waiting:
		return
	_commission_waiting_for_space = waiting
	_progression_changed = true


## One explicit player order at a time, in stable purchase-ID order. Multiple
## commissions remain paid and queued; the next begins as soon as the current one
## completes, keeping crews concentrated on what was deliberately requested.
func _next_commission_purchase() -> int:
	for purchase_id in [
			CityPurchase.HAT_HOUSE,
			CityPurchase.ABILITIES_HOUSE,
			CityPurchase.BIOMASS_HARVESTER,
			CityPurchase.ABILITIES_HOUSE_TOWER,
			CityPurchase.SECOND_CLONER,
			CityPurchase.THIRD_CLONER,
			CityPurchase.FOURTH_CLONER]:
		if city_upgrade_requested(purchase_id):
			return purchase_id
	return -1


static func _cloner_purchase_ordinal(purchase_id: int) -> int:
	match purchase_id:
		CityPurchase.SECOND_CLONER:
			return 1
		CityPurchase.THIRD_CLONER:
			return 2
		CityPurchase.FOURTH_CLONER:
			return 3
		_:
			return -1


static func _cloner_purchase_for_ordinal(ordinal: int) -> int:
	match ordinal:
		1:
			return CityPurchase.SECOND_CLONER
		2:
			return CityPurchase.THIRD_CLONER
		3:
			return CityPurchase.FOURTH_CLONER
		_:
			return -1


func cloner_index(wanted_ordinal: int, only_built := true) -> int:
	if structures == null:
		return -1
	var ordinal := 0
	for index in structures.count():
		var entry := structures.at(index)
		if entry == null or entry.kind != MeepStructures.Kind.CLONER \
				or (only_built and not entry.built()):
			continue
		if ordinal == wanted_ordinal:
			return index
		ordinal += 1
	return -1


func second_cloner_index(only_built := true) -> int:
	return cloner_index(1, only_built)


func _cloner_ordinal(structure: int) -> int:
	if structures == null:
		return -1
	var ordinal := 0
	for index in structures.count():
		var entry := structures.at(index)
		if entry == null or entry.kind != MeepStructures.Kind.CLONER:
			continue
		if index == structure:
			return ordinal
		ordinal += 1
	return -1


func _commission_structure_kind(purchase_id: int) -> int:
	match purchase_id:
		CityPurchase.SECOND_CLONER, CityPurchase.THIRD_CLONER, \
				CityPurchase.FOURTH_CLONER:
			return MeepStructures.Kind.CLONER
		CityPurchase.HAT_HOUSE:
			return MeepStructures.Kind.HAT_HOUSE
		CityPurchase.ABILITIES_HOUSE:
			return MeepStructures.Kind.ABILITIES_HOUSE
		CityPurchase.BIOMASS_HARVESTER:
			return MeepStructures.Kind.BIOMASS_HARVESTER
		_:
			return -1


func _commission_purchase_for_structure(structure: int) -> int:
	if structures == null:
		return -1
	var entry := structures.at(structure)
	if entry == null:
		return -1
	if entry.kind == MeepStructures.Kind.CLONER:
		return _cloner_purchase_for_ordinal(_cloner_ordinal(structure))
	match entry.kind:
		MeepStructures.Kind.HAT_HOUSE:
			return CityPurchase.HAT_HOUSE
		MeepStructures.Kind.ABILITIES_HOUSE:
			return CityPurchase.ABILITIES_HOUSE
		MeepStructures.Kind.BIOMASS_HARVESTER:
			return CityPurchase.BIOMASS_HARVESTER
		_:
			return -1


## Starter growth comes first. At 32 living settlers, a commissioned structure gets
## a priority above every routine job and suppresses new ordinary sites until it is
## complete. Mining retains its bounded floor, so a city can never strand itself.
func _plan_commissioned() -> void:
	if not commissioned_work_unlocked(_alive) or structures == null \
			or not _ground_ready:
		return
	var purchase_id := _next_commission_purchase()
	_set_commission_waiting_for_space(false)
	if purchase_id == CityPurchase.ABILITIES_HOUSE_TOWER:
		_plan_abilities_house_tower()
		return
	var kind := _commission_structure_kind(purchase_id)
	if kind < 0:
		return
	var cloner_ordinal := _cloner_purchase_ordinal(purchase_id)
	var structure := cloner_index(cloner_ordinal, false) \
		if cloner_ordinal >= 0 \
		else structures.nearest(kind, Vector2.ZERO, false)
	if structure < 0:
		var planned := _prepared_city_lot(kind)
		if not planned.is_empty():
			structure = structures.place_planned(kind,
				planned.get("corner", Vector2i.ZERO),
				int(planned.get("district_tier", tier)))
			if structure >= 0:
				var planned_index := int(planned.get("index", -1))
				city_plan.commit_lot(planned_index)
				_apply_city_plan_masks(
					city_plan.lot_cell_indices(planned_index))
			elif structure == -2:
				var planned_index := int(planned.get("index", -1))
				city_plan.block_lot(planned_index)
				_apply_city_plan_masks(
					city_plan.lot_cell_indices(planned_index))
		elif city_plan == null or not city_plan.generated() \
				or city_plan.free_lot_count(kind) <= 0:
			structure = structures.place_commissioned(
				kind, _commission_preferred_outer_radius())
		if structure < 0:
			# The order remains paid and requested. Continuous border growth (or a
			# newly completed connecting road) clears the negative plot cache and
			# this same commission is attempted again without another player action.
			_set_commission_waiting_for_space(true)
			return
	var entry := structures.at(structure)
	if entry == null:
		return
	if entry.built():
		complete_city_purchase(purchase_id)
		return
	var existing := tasks.job(entry.job)
	if existing != null:
		existing.priority = COMMISSION_PRIORITY
		existing.enabled = true
		return
	var plan := MeepStructures.plan_of(kind)
	var posted := tasks.job(tasks.post(MeepTasks.Kind.BUILD,
		structures.work_cell(structure), COMMISSION_PRIORITY, plan.crew,
		plan.work, city_purchase_cost(purchase_id)))
	if posted == null:
		return
	posted.subject = structure
	entry.job = posted.id
	_town_changed = true


func _plan_abilities_house_tower() -> void:
	var structure := abilities_house_index()
	if structure < 0:
		return
	var entry := structures.at(structure)
	if entry == null:
		return
	if entry.completed_floors >= 2:
		complete_city_purchase(CityPurchase.ABILITIES_HOUSE_TOWER)
		return
	if not entry.upgrading() and not structures.begin_vertical_upgrade(structure):
		return
	var existing := tasks.job(entry.job)
	if existing != null:
		existing.priority = COMMISSION_PRIORITY
		existing.enabled = true
		return
	var plan := MeepStructures.plan_of(MeepStructures.Kind.ABILITIES_HOUSE)
	var posted := tasks.job(tasks.post(MeepTasks.Kind.UPGRADE,
		structures.work_cell(structure), COMMISSION_PRIORITY, plan.crew,
		structures.upgrade_work(structure), ABILITIES_HOUSE_TOWER_COST))
	if posted == null:
		return
	posted.subject = structure
	entry.job = posted.id
	_town_changed = true


func _commission_preferred_outer_radius() -> float:
	# Expanded cities use newly claimed land first. If that ring cannot hold the
	# project, MeepStructures falls back to the deliberately open park/civic gaps.
	return development_inner_radius_for_tier(tier)


## What the town would put up next if it could pay for it, or -1 if it wants nothing.
##
## Asked by the cloner as well as by the builders, which is the point of it being a
## question rather than a branch: population is what the colony spends on last, so
## something has to be able to say what the building would have cost.
static func site_limit_for(city_tier: int, population: int) -> int:
	var mature_bonus := maxi(city_tier - 1, 0)
	if population >= 512:
		mature_bonus = maxi(mature_bonus, 3)
	return clampi(SITES_AT_ONCE + mature_bonus,
		SITES_AT_ONCE, MAX_SITES_AT_ONCE)


## Economy-free core of the resident building order. The live planner layers
## funding, unfinished-site and task gates around this answer; local city
## projections call it directly so a population preview cannot drift to a second
## architectural progression.
static func projected_growth_kind(city_tier: int, population: int,
		housing: int, cloners: int, huts: int,
		tier_zero_target: int) -> int:
	if cloners <= 0:
		return MeepStructures.Kind.CLONER
	var bounded_tier := clampi(city_tier, 0, MAX_CITY_TIER)
	if bounded_tier > 0:
		if housing >= TIER_POPULATION_CEILINGS[bounded_tier]:
			return -1
		return MeepStructures.residential_kind_for_growth(
			bounded_tier, population)
	if population < STARTER_POPULATION:
		var wanted_huts := ceili(float(mini(
			population + 1, STARTER_POPULATION))
			/ float(STARTER_SETTLERS_PER_HUT))
		return MeepStructures.Kind.HUT if huts < wanted_huts else -1
	return MeepStructures.Kind.HUT \
		if mini(cloners, 1) + huts < maxi(
			tier_zero_target, STARTER_STRUCTURES) else -1


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
	if structures.count() - structures.built_count() >= site_limit_for(
			tier, _alive):
		return -1
	if tier > 0:
		if not tasks.all_of(MeepTasks.Kind.UPGRADE).is_empty():
			return -1
		var ceiling := population_ceiling()
		if housing_capacity() >= ceiling:
			_mark_tier_allocated(tier)
			return -1
		# Existing vacancies, including older parent-district homes, are populated
		# before another block is normally reserved. A large biomass surplus may
		# prebuild the next authored lot so the fixed Builder reserve stays useful.
		var growth_kind := projected_growth_kind(
			tier, _alive, housing_capacity(),
			structures.count_of(MeepStructures.Kind.CLONER),
			structures.count_of(MeepStructures.Kind.HUT),
			tier_zero_structure_target())
		var surplus_price := MeepStructures.plan_of(growth_kind).cost \
			+ MINE_ROAD_RUNWAY
		if _alive < housing_capacity() and available() \
				< surplus_price * PREBUILD_SURPLUS_MULTIPLIER:
			return -1
		return growth_kind \
			if not current_tier_space_exhausted() else -1
	# After the starter milestone, houses keep moving outward whenever the bank can pay.
	# Cloning independently consumes only capacity from completed houses, which produces
	# the requested house -> two settlers -> next house cycle without stopping either
	# builders or miners while the other half of the cycle catches up.
	if _starter_complete():
		if _tier_zero_growth_structure_count() >= tier_zero_structure_target():
			_mark_tier_allocated(0)
			return -1
		return projected_growth_kind(
			tier, _alive, housing_capacity(),
			structures.count_of(MeepStructures.Kind.CLONER),
			structures.count_of(MeepStructures.Kind.HUT),
			tier_zero_structure_target()) \
			if not _tier_zero_space_full else -1
	# Make the next pair's room first. At even population this deliberately asks for
	# one empty sibling home; its two places are what let the next two clones happen.
	return projected_growth_kind(
		tier, _alive, housing_capacity(),
		structures.count_of(MeepStructures.Kind.CLONER),
		structures.count_of(MeepStructures.Kind.HUT),
		tier_zero_structure_target())


func _tier_zero_growth_structure_count() -> int:
	if structures == null:
		return 0
	# A commissioned second machine is civic infrastructure, not a replacement for
	# one of the residential lots allocated by Tier 0's density budget.
	return mini(structures.count_of(MeepStructures.Kind.CLONER), 1) \
		+ structures.count_of(MeepStructures.Kind.HUT)


func _plan_building() -> void:
	if commissioned_work_unlocked(_alive) and commissioned_work_blocks_routine():
		return
	# One placement scan per review keeps the main-thread cost bounded. Because dense
	# tiers no longer wait for the prior envelope to finish, successive reviews fill
	# the scaled site allowance and separate crews build across the skyline together.
	var kind := _wanted_kind()
	if kind >= 0:
		_peg_out(kind)


func _plan_vertical_upgrade() -> void:
	if tier <= 0 or structures == null or _alive < housing_capacity() \
			or housing_capacity() >= population_ceiling() \
			or structures.count() > structures.built_count():
		return
	if not tasks.all_of(MeepTasks.Kind.UPGRADE).is_empty():
		return
	var upgraded := 0
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null and entry.kind == MeepStructures.Kind.HUT \
				and entry.completed_floors > 1:
			upgraded += 1
	if upgraded >= MAX_VERTICAL_HUT_UPGRADES:
		return
	for index in structures.count():
		var entry := structures.at(index)
		if entry == null or entry.kind != MeepStructures.Kind.HUT \
				or not structures.can_upgrade_vertical(index):
			continue
		var cost := structures.upgrade_cost(index)
		if available() < cost or not structures.begin_vertical_upgrade(index):
			return
		var posted := tasks.job(tasks.post(MeepTasks.Kind.UPGRADE,
			structures.work_cell(index), BUILD_PRIORITY + 0.2, 3,
			structures.upgrade_work(index), cost))
		if posted == null:
			return
		posted.subject = index
		committed += cost
		_town_changed = true
		return


## Connects every finished structure back to the street already growing from the ship.
##
## Every passable perimeter cell is considered against the shared home field. Existing
## street contact wins; otherwise the shortest reachable perimeter route wins with a
## stable cell-index tie break. A reserved route is temporary, so failure to route
## around one simply leaves the structure eligible for the next planning pass.
func _plan_roads() -> void:
	var mature_road_limit := 6 + maxi(tier - 2, 0) * 2
	var road_limit := clampi(ceili(float(_alive) / 16.0),
		ROADS_AT_ONCE, mature_road_limit)
	if roads == null or structures == null or grid == null:
		return
	# The cloner remains the first standalone structure, then every town establishes
	# its complete plaza ring before any branch can grow inward toward the hull.
	if not _ship_ring_ready():
		if roads.unfinished_count() == 0:
			_plan_ship_ring()
		return
	if roads.unfinished_count() >= road_limit:
		return
	if city_plan != null and city_plan.generated():
		var prepared_road := city_plan.road_project_status(roads, claim, grid)
		var road_state := int(prepared_road.get(
			"state", MeepCityPlan.RoadProjectState.NONE))
		if road_state == MeepCityPlan.RoadProjectState.WAITING_FOR_CLAIM \
				or road_state == MeepCityPlan.RoadProjectState.WAITING_FOR_SURFACE:
			# Authored trunks keep their build order. Do not invent a competing
			# ad-hoc street while the next one awaits claim or bridge/coast work.
			return
		if road_state == MeepCityPlan.RoadProjectState.READY:
			var cells: PackedInt32Array = prepared_road.get(
				"cells", PackedInt32Array())
			var subject := int(prepared_road.get("subject", 0))
			var width_class := int(prepared_road.get(
				"width_class", MeepRoads.WidthClass.STREET))
			if cells.is_empty():
				roads.plan(subject, cells, width_class)
			else:
				var cost := roads.cost_for(cells, width_class)
				if available() >= cost:
					var target_index := cells[0]
					var target := Vector2i(target_index % grid.cells,
						target_index / grid.cells)
					var posted := tasks.job(tasks.post(MeepTasks.Kind.ROAD,
						target, ROAD_PRIORITY + 0.35, MeepRoads.CREW,
						roads.work_for(cells, width_class), cost))
					if posted != null:
						var road := roads.plan(subject, cells, width_class)
						posted.subject = road
						roads.at(road).job = posted.id
						committed += cost
						_town_changed = true
			return
	for structure in structures.count():
		var entry := structures.at(structure)
		if entry == null or not entry.built() or roads.has_subject(structure):
			continue
		# The child lander's cloner is already part of the ship at the road
		# origin; routing a street to its hidden inner box would enter the hull.
		if structure == _settlement_ship_cloner:
			continue
		var width_class := MeepRoads.width_class_for_tier(
			maxi(tier, entry.district_tier))
		var access := structures.access_cells(structure)
		var road_contacts: Array[Vector2i] = []
		for cell in access:
			if grid.has_flag(cell, MeepGrid.FLAG_ROAD):
				road_contacts.push_back(cell)
		if not road_contacts.is_empty():
			road_contacts.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return grid.index(a) < grid.index(b))
			roads.plan(structure, PackedInt32Array(), width_class)
			continue
		var field := _home_field()
		if field == null:
			continue
		var reachable: Array[Vector2i] = []
		for cell in access:
			if not grid.has_flag(cell, MeepGrid.FLAG_RESERVED) \
					and field.reachable(cell):
				reachable.push_back(cell)
		reachable.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var a_distance := field.distance_at(a)
			var b_distance := field.distance_at(b)
			return a_distance < b_distance \
				or (a_distance == b_distance and grid.index(a) < grid.index(b)))
		var target := Vector2i(-1, -1)
		var cells := PackedInt32Array()
		for candidate in reachable:
			var candidate_cells := roads.path_home_from(candidate, field)
			if candidate_cells.is_empty():
				continue
			target = candidate
			cells = candidate_cells
			break
		if cells.is_empty():
			continue
		var cost := roads.cost_for(cells, width_class)
		if available() < cost:
			continue
		var posted := tasks.job(tasks.post(MeepTasks.Kind.ROAD, target,
			ROAD_PRIORITY, MeepRoads.CREW,
			roads.work_for(cells, width_class), cost))
		if posted == null:
			continue
		var road := roads.plan(structure, cells, width_class)
		posted.subject = road
		roads.at(road).job = posted.id
		committed += cost
		_town_changed = true
		if roads.unfinished_count() >= road_limit:
			return


func _ship_ring_ready() -> bool:
	# Focused navigation fixtures and any future shipless colony can opt out by
	# leaving the road collection's centre exclusion unset.
	if roads == null or roads.centre_exclusion_radius() <= 0.0:
		return true
	var ring := ship_ring_cells()
	if ring.size() < 16:
		return false
	for cell_index in ring:
		if not roads.has_cell(cell_index):
			return false
	return true


func _plan_ship_ring() -> bool:
	if structures == null or structures.count_of(
			MeepStructures.Kind.CLONER, true) == 0:
		return false
	var ring := ship_ring_cells()
	if ring.size() < 16 or roads.has_subject(SHIP_RING_ROAD_SUBJECT):
		return false
	var missing := PackedInt32Array()
	for cell_index in ring:
		if roads.has_cell(cell_index):
			continue
		var cell := Vector2i(
			cell_index % grid.cells, cell_index / grid.cells)
		if grid.has_flag(cell, MeepGrid.FLAG_RESERVED):
			return false
		missing.push_back(cell_index)
	if missing.is_empty():
		return true
	var cost := roads.cost_for(missing)
	if available() < cost:
		return false
	var posted := tasks.job(tasks.post(MeepTasks.Kind.ROAD,
		road_origin_cell(), ROAD_PRIORITY + 0.5, MeepRoads.CREW,
		roads.work_for(missing), cost))
	if posted == null:
		return false
	var road := roads.plan(SHIP_RING_ROAD_SUBJECT, missing)
	posted.subject = road
	roads.at(road).job = posted.id
	committed += cost
	_town_changed = true
	return true


## Pegs out a site, posts the work, and holds back what it will cost.
##
## Held rather than spent, so the bank cannot promise the same biomass to two sites and
## leave the second one standing half-built forever.
func _peg_out(kind: int) -> bool:
	var plan := MeepStructures.plan_of(kind)
	if available() < plan.cost:
		return false
	var index := -1
	var planned := _prepared_city_lot(kind)
	if not planned.is_empty():
		index = structures.place_planned(kind,
			planned.get("corner", Vector2i.ZERO),
			int(planned.get("district_tier", tier)))
		if index >= 0:
			var planned_index := int(planned.get("index", -1))
			city_plan.commit_lot(planned_index)
			_apply_city_plan_masks(city_plan.lot_cell_indices(planned_index))
		elif index == -2:
			var planned_index := int(planned.get("index", -1))
			city_plan.block_lot(planned_index)
			_apply_city_plan_masks(city_plan.lot_cell_indices(planned_index))
	elif city_plan != null and city_plan.generated() \
			and city_plan.free_lot_count(kind) > 0:
		# The next real lot belongs to a district whose border or streets are still
		# being built. Keep the construction order instead of scattering a fallback.
		return false
	else:
		# Migration safety for an old or terrain-invalid blueprint.
		index = structures.place_district(kind,
			development_inner_radius_for_tier(tier),
			TIER_BLOCK_SIZES[tier], tier) \
			if tier > 0 and MeepStructures.is_residential_kind(kind) \
			else structures.place(kind, _starter_complete())
	if index < 0:
		# No plot fits the boundary as it stands. The structure collection caches
		# that negative scan until continuous growth adds another band; lack of room
		# is no longer treated as completion of a development tier.
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


## Stands up a building the city finished while it was a [MeepCityLedger], already
## paid for and already counted.
##
## The ledger reserved its founding-blueprint lot, but only a resident grid can stand
## the physical mesh and collision there. The building therefore appears complete:
## the work was done while away, and its housing has counted the whole time.
func place_completed_structure(kind: int) -> bool:
	if structures == null or not _ground_ready:
		return false
	var index := -1
	var planned := _prepared_city_lot(kind, true)
	if not planned.is_empty():
		index = structures.place_planned(kind,
			planned.get("corner", Vector2i.ZERO),
			int(planned.get("district_tier", tier)))
		if index >= 0:
			var planned_index := int(planned.get("index", -1))
			city_plan.commit_lot(planned_index)
			_apply_city_plan_masks(city_plan.lot_cell_indices(planned_index))
		elif index == -2:
			var planned_index := int(planned.get("index", -1))
			city_plan.block_lot(planned_index)
			_apply_city_plan_masks(city_plan.lot_cell_indices(planned_index))
	elif city_plan == null or not city_plan.generated() \
			or city_plan.free_lot_count(kind) <= 0:
		index = structures.place_district(kind,
			development_inner_radius_for_tier(tier),
			TIER_BLOCK_SIZES[tier], tier) \
			if tier > 0 and MeepStructures.is_residential_kind(kind) \
			else structures.place(kind, _starter_complete())
	# A ledger already paid for this building and counted its beds. If the preferred
	# tier annulus filled while the city was away, use any legal inner park or gap
	# rather than leaving virtual housing that can disappear on the next distillation.
	if index < 0 and MeepStructures.is_residential_kind(kind) \
			and (city_plan == null or city_plan.free_lot_count(kind) <= 0):
		structures.clear_exhaustion()
		index = structures.place(kind, true)
	if index < 0:
		return false
	structures.set_progress(index, 1.0)
	_complete_building(index)
	return true


func _built_cloner_indices() -> PackedInt32Array:
	var out := PackedInt32Array()
	if structures == null:
		return out
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null and entry.kind == MeepStructures.Kind.CLONER \
				and entry.built():
			out.push_back(index)
	return out


func _cloners_inside() -> int:
	var inside := 0
	if structures == null:
		return inside
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null and entry.kind == MeepStructures.Kind.CLONER:
			inside += maxi(entry.inside, 0)
	return inside


## Keeps one standing queue at every completed cloner while the colony can pay and
## has room to grow. Each machine gets five independent incubation slots.
func _plan_cloning() -> void:
	if structures == null:
		return
	var cloners := _built_cloner_indices()
	var open := tasks.all_of(MeepTasks.Kind.CLONE)
	var by_cloner: Dictionary = {}
	# Retain at most one valid job per machine. This also cleans up a stale queue if a
	# malformed old snapshot points at a missing or unfinished structure.
	for entry in open:
		var cloner := entry.subject
		if cloners.has(cloner) and not by_cloner.has(cloner):
			by_cloner[cloner] = entry
			continue
		entry.enabled = false
		if entry.workers == 0:
			tasks.finish(entry.id)
	# `available` has already removed every unit promised to a building or road. The old
	# gate also reserved the *next hypothetical hut* here, which charged housing twice
	# and left colonies with enough for a clone staring at an unused cloner.
	# Each occupied slot will add one net Meep when it returns two. Count that future
	# output across every machine so simultaneous uses cannot overrun housing.
	var projected := _alive + _cloners_inside()
	var wanted := not cloners.is_empty() \
		and projected < mini(housing_capacity(), population_ceiling()) \
		and available() >= CLONE_COST
	for cloner in cloners:
		var entry := by_cloner.get(cloner) as MeepTasks.Job
		if wanted and entry == null:
			entry = tasks.job(tasks.post(MeepTasks.Kind.CLONE,
				_cloner_work_cell(cloner), CLONE_PRIORITY,
				CLONE_CREW + CLONE_QUEUE))
			if entry != null:
				entry.subject = cloner
		if entry == null:
			continue
		entry.enabled = wanted
		if wanted:
			entry.worker_cap = CLONE_CREW + CLONE_QUEUE
		# A job with somebody inside cannot be erased: it is also the reference used
		# to decrement that exact machine's occupied slots when they emerge.
		elif entry.workers == 0:
			tasks.finish(entry.id)


## Whether the former starter population milestone has been established. The stricter
## two-per-hut rule means it now necessarily owns more than the old twelve structures.
func _starter_complete() -> bool:
	return structures != null and _alive >= STARTER_POPULATION \
		and structures.built_count() >= STARTER_STRUCTURES


## Population the cloner may currently support. The landed first wave is the only
## exception to house-first growth; every additional slot comes from a completed hut.
func housing_capacity() -> int:
	var housed := structures.residential_capacity(true) \
		if structures != null else 0
	return maxi(FIRST_WAVE, housed)


func population_ceiling(for_tier := -1) -> int:
	var target := tier if for_tier < 0 else for_tier
	return TIER_POPULATION_CEILINGS[clampi(target, 0, MAX_CITY_TIER)]


func current_tier_development_units() -> int:
	if structures == null:
		return 0
	var before := structures.development_units(tier - 1, true) if tier > 0 else 0
	return structures.development_units(tier, true) - before


func current_tier_capacity_target() -> int:
	return population_ceiling(tier) \
		- (population_ceiling(tier - 1) if tier > 0 else 0)


## Structures this terrain-shaped claim allocates to Tier 0, including the cloner.
func tier_zero_structure_target() -> int:
	if claim == null:
		return STARTER_STRUCTURES
	return clampi(floori(claim.area() / TIER_ZERO_LOT_AREA),
		STARTER_STRUCTURES, TIER_ZERO_MAX_STRUCTURES)


# --- The bank ----------------------------------------------------------------

## Biomass the colony may promise to something new: what it has, less what it has
## already promised to work in progress.
func available() -> float:
	return maxf(resources - committed, 0.0)


## Pays biomass in. Harvesting and player contributions share this bank so a
## donated unit is immediately eligible for roads, buildings, and cloning.
func credit(amount: float) -> void:
	if amount > 0.0:
		resources += amount


func receive_biomass(amount: float) -> float:
	if not _is_host() or not is_finite(amount) or amount <= 0.0:
		return 0.0
	credit(amount)
	return amount


static func city_purchase_valid(purchase_id: int) -> bool:
	return purchase_id >= 0 and purchase_id < CITY_PURCHASE_COUNT


static func is_harvester_rate_purchase(purchase_id: int) -> bool:
	return purchase_id >= CityPurchase.HARVEST_RATE_1 \
		and purchase_id <= CityPurchase.HARVEST_RATE_5


## Canonical prices live on the simulation, never in a request from the panel.
static func city_purchase_cost(purchase_id: int) -> float:
	if purchase_id >= CityPurchase.BUILD_SPEED_1 \
			and purchase_id <= CityPurchase.BUILD_SPEED_5:
		return SPEED_UPGRADE_COSTS[
			purchase_id - CityPurchase.BUILD_SPEED_1]
	if purchase_id >= CityPurchase.MOVE_SPEED_1 \
			and purchase_id <= CityPurchase.MOVE_SPEED_5:
		return SPEED_UPGRADE_COSTS[
			purchase_id - CityPurchase.MOVE_SPEED_1]
	if is_harvester_rate_purchase(purchase_id):
		return HARVEST_RATE_COSTS[
			purchase_id - CityPurchase.HARVEST_RATE_1]
	match purchase_id:
		CityPurchase.BRIDGES:
			return BRIDGES_COST
		CityPurchase.COASTS:
			return COASTS_COST
		CityPurchase.HAT_HOUSE, CityPurchase.ABILITIES_HOUSE:
			return SPECIALTY_HOUSE_COST
		CityPurchase.BIOMASS_HARVESTER:
			return BIOMASS_HARVESTER_COST
		CityPurchase.ABILITIES_HOUSE_TOWER:
			return ABILITIES_HOUSE_TOWER_COST
		CityPurchase.SECOND_CLONER:
			return SECOND_CLONER_COST
		CityPurchase.THIRD_CLONER:
			return THIRD_CLONER_COST
		CityPurchase.FOURTH_CLONER:
			return FOURTH_CLONER_COST
		CityPurchase.SEND_SETTLEMENT:
			return SETTLEMENT_EXPEDITION_COST
		_:
			return INF


## Host-only, atomic city purchase. It checks the exact requested level/project
## against current state, then spends only the bank that is not held by active work.
func try_city_purchase(purchase_id: int, requesting_peer := 1) -> bool:
	if not _is_host() or not city_purchase_valid(purchase_id) \
			or _city_purchase_status(purchase_id) != "available":
		return false
	if purchase_id == CityPurchase.SEND_SETTLEMENT and requesting_peer <= 0:
		return false
	var cost := city_purchase_cost(purchase_id)
	if not is_finite(cost) or available() + 0.0001 < cost:
		return false
	if _purchase_reserves_construction(purchase_id):
		committed += cost
	else:
		_spend(cost)
	if purchase_id == CityPurchase.SEND_SETTLEMENT:
		settlement_tokens += 1
		settlement_armed_owner = requesting_peer
	elif purchase_id >= CityPurchase.BUILD_SPEED_1 \
			and purchase_id <= CityPurchase.BUILD_SPEED_5:
		_mark_purchase_built(purchase_id)
		build_speed_level += 1
	elif purchase_id >= CityPurchase.MOVE_SPEED_1 \
			and purchase_id <= CityPurchase.MOVE_SPEED_5:
		_mark_purchase_built(purchase_id)
		move_speed_level += 1
	elif is_harvester_rate_purchase(purchase_id):
		_mark_purchase_built(purchase_id)
		harvester_rate_level += 1
	elif purchase_id == CityPurchase.BRIDGES \
			or purchase_id == CityPurchase.COASTS:
		_mark_purchase_built(purchase_id)
		_surface_scan_revision = -1
		_surface_candidate_revision = -1
		_surface_candidate.clear()
		if purchase_id == CityPurchase.COASTS:
			reground()
	else:
		var flag := _purchase_flag(purchase_id)
		purchased_flags |= flag
		requested_flags |= flag
	if purchase_id == CityPurchase.BRIDGES \
			or purchase_id == CityPurchase.COASTS:
		var registry := get_parent()
		if registry != null and registry.has_method(&"city_growth_contract_changed"):
			registry.call(&"city_growth_contract_changed", site_id)
	_progression_changed = true
	return true


## Called by the later expansion/building passes when paid work physically finishes.
## Keeping it here now makes the phase-one state usable without changing its wire form.
func complete_city_purchase(purchase_id: int,
		spend_construction_reservation := true) -> bool:
	if not _is_host() or not city_purchase_valid(purchase_id):
		return false
	var flag := _purchase_flag(purchase_id)
	if (requested_flags & flag) == 0:
		return false
	if spend_construction_reservation \
			and _purchase_reserves_construction(purchase_id):
		_spend_reserved(city_purchase_cost(purchase_id))
	requested_flags &= ~flag
	built_flags |= flag
	_progression_changed = true
	return true


## Explicitly withdraws a commission. Normal space exhaustion never calls this:
## paid work stays queued until continuous border growth opens a legal plot.
func cancel_city_purchase(purchase_id: int) -> bool:
	if not _is_host() or not _purchase_reserves_construction(purchase_id):
		return false
	var flag := _purchase_flag(purchase_id)
	if (requested_flags & flag) == 0:
		return false
	committed = maxf(committed - city_purchase_cost(purchase_id), 0.0)
	requested_flags &= ~flag
	purchased_flags &= ~flag
	_progression_changed = true
	return true


func consume_settlement_token(owner_peer := 0) -> bool:
	if not _is_host() or settlement_tokens <= 0:
		return false
	settlement_tokens -= 1
	if settlement_tokens <= 0:
		settlement_armed_owner = 0
	_progression_changed = true
	return true


func apply_settlement_token_consumed(owner_peer: int) -> void:
	if settlement_tokens <= 0:
		return
	settlement_tokens -= 1
	if settlement_tokens <= 0:
		settlement_armed_owner = 0
	_progression_changed = true


func city_upgrade_built(purchase_id: int) -> bool:
	return city_purchase_valid(purchase_id) \
		and (built_flags & _purchase_flag(purchase_id)) != 0


func city_upgrade_requested(purchase_id: int) -> bool:
	return city_purchase_valid(purchase_id) \
		and (requested_flags & _purchase_flag(purchase_id)) != 0


func biomass_harvester_index() -> int:
	if structures == null \
			or not city_upgrade_built(CityPurchase.BIOMASS_HARVESTER):
		return -1
	return structures.nearest(
		MeepStructures.Kind.BIOMASS_HARVESTER, Vector2.ZERO, true)


func abilities_house_index() -> int:
	if structures == null \
			or not city_upgrade_built(CityPurchase.ABILITIES_HOUSE):
		return -1
	return structures.nearest(
		MeepStructures.Kind.ABILITIES_HOUSE, Vector2.ZERO, true)


func abilities_house_stats_unlocked() -> bool:
	var index := abilities_house_index()
	var entry := structures.at(index) if index >= 0 and structures != null else null
	return city_upgrade_built(CityPurchase.ABILITIES_HOUSE_TOWER) \
		and entry != null and entry.completed_floors >= 2


func harvester_rate() -> float:
	if biomass_harvester_index() < 0:
		return 0.0
	return harvester_base_rate() * (1.0 + float(staffed_harvester_count())
		* HARVESTER_STAFF_BONUS)


func harvester_base_rate() -> float:
	if biomass_harvester_index() < 0:
		return 0.0
	return HARVEST_BASE_RATE \
		+ float(harvester_rate_level) * HARVEST_RATE_PER_LEVEL


func staffed_harvester_count() -> int:
	var workplace := biomass_harvester_index()
	if workplace < 0:
		return 0
	var staffed := 0
	for row in _workplaces.size():
		if _active_resident(row) and _workplaces[row] == workplace \
				and _state[row] == State.AT_WORKPLACE:
			staffed += 1
	return mini(staffed, HARVESTER_STAFF_SLOTS)


func harvester_upgrade_offer() -> Dictionary:
	var level := clampi(harvester_rate_level, 0, MAX_HARVEST_RATE_LEVEL)
	if biomass_harvester_index() < 0:
		return {
			"purchase_id": -1,
			"cost": 0.0,
			"status": "locked",
			"enabled": false,
			"shortfall": 0.0,
			"value": "HARVESTER INCOMPLETE",
		}
	if level >= MAX_HARVEST_RATE_LEVEL:
		return {
			"purchase_id": CityPurchase.HARVEST_RATE_5,
			"cost": HARVEST_RATE_COSTS[MAX_HARVEST_RATE_LEVEL - 1],
			"status": "maxed",
			"enabled": false,
			"shortfall": 0.0,
			"value": "LEVEL %d/%d" % [level, MAX_HARVEST_RATE_LEVEL],
		}
	var purchase_id := CityPurchase.HARVEST_RATE_1 + level
	var offer := _city_purchase_offer(purchase_id)
	offer["value"] = "LEVEL %d/%d  (%.1f / SEC)" % [
		level, MAX_HARVEST_RATE_LEVEL, harvester_rate()]
	return offer


func work_multiplier() -> float:
	return 1.0 + float(build_speed_level) * BUILD_SPEED_PER_LEVEL


func move_multiplier() -> float:
	return 1.0 + float(move_speed_level) * MOVE_SPEED_PER_LEVEL


func effective_work_rate() -> float:
	return (stats.work_rate if stats != null else 0.0) * work_multiplier()


func effective_walk_speed() -> float:
	return (stats.walk_speed if stats != null else 0.0) * move_multiplier()


func effective_flee_speed() -> float:
	return (stats.flee_speed if stats != null else 0.0) * move_multiplier()


## One additive dictionary is used both by late join and the reliable live RPC.
## Missing keys retain old/default values so snapshots from before city upgrades load.
func city_progression_snapshot() -> Dictionary:
	return {
		"resources": resources,
		"committed": committed,
		"tier": tier,
		"claim_radius": claim_radius,
		"tier_allocated_flags": tier_allocated_flags,
		"tier_complete_flags": tier_complete_flags,
		"population_ceiling": population_ceiling(),
		"housing_capacity": housing_capacity(),
		"current_tier_development_units": current_tier_development_units(),
		"build_speed_level": build_speed_level,
		"move_speed_level": move_speed_level,
		"expansion_rate": expansion_rate(),
		"max_claim_radius": MAX_CLAIM_RADIUS,
		"purchased_flags": purchased_flags,
		"requested_flags": requested_flags,
		"built_flags": built_flags,
		"commission_waiting_for_space": _commission_waiting_for_space,
		"harvester_rate_level": harvester_rate_level,
		"harvester_rate": harvester_rate(),
		"harvester_base_rate": harvester_base_rate(),
		"harvester_lifetime": harvester_lifetime,
		"settlement_tokens": settlement_tokens,
		"settlement_armed_owner": settlement_armed_owner,
		"display_name": display_name,
		"parent_site_id": String(parent_site_id),
		"region_id": String(region_id),
		"region_revision": region_revision,
		"city_plan": city_plan.snapshot() \
			if city_plan != null else _city_plan_restore_state,
	}


func apply_city_progression(state: Dictionary) -> void:
	var old_radius := claim_radius
	var had_coasts := city_upgrade_built(CityPurchase.COASTS)
	resources = maxf(float(state.get("resources", resources)), 0.0)
	committed = clampf(float(state.get("committed", committed)),
		0.0, resources)
	tier = clampi(int(state.get("tier", tier)), 0, MAX_CITY_TIER)
	claim_radius = clampf(float(state.get("claim_radius", claim_radius)),
		8.0, MAX_CLAIM_RADIUS)
	tier_allocated_flags = maxi(int(state.get(
		"tier_allocated_flags", tier_allocated_flags)), 0)
	tier_complete_flags = maxi(int(state.get(
		"tier_complete_flags", tier_complete_flags)), 0)
	build_speed_level = clampi(int(state.get(
		"build_speed_level", build_speed_level)), 0, MAX_SPEED_LEVEL)
	move_speed_level = clampi(int(state.get(
		"move_speed_level", move_speed_level)), 0, MAX_SPEED_LEVEL)
	purchased_flags = maxi(int(state.get(
		"purchased_flags", purchased_flags)), 0)
	requested_flags = maxi(int(state.get(
		"requested_flags", requested_flags)), 0)
	built_flags = maxi(int(state.get("built_flags", built_flags)), 0)
	_commission_waiting_for_space = bool(state.get(
		"commission_waiting_for_space", _commission_waiting_for_space))
	harvester_rate_level = clampi(int(state.get(
		"harvester_rate_level", harvester_rate_level)),
		0, MAX_HARVEST_RATE_LEVEL)
	harvester_lifetime = maxf(float(state.get(
		"harvester_lifetime", harvester_lifetime)), 0.0)
	settlement_tokens = maxi(int(state.get(
		"settlement_tokens", settlement_tokens)), 0)
	settlement_armed_owner = maxi(int(state.get(
		"settlement_armed_owner", settlement_armed_owner)), 0)
	display_name = String(state.get("display_name", display_name)).strip_edges()
	parent_site_id = StringName(state.get(
		"parent_site_id", String(parent_site_id)))
	region_id = StringName(state.get("region_id", String(region_id)))
	region_revision = int(state.get("region_revision", region_revision))
	var plan_value: Variant = state.get("city_plan", {})
	if plan_value is Dictionary:
		_city_plan_restore_state = (plan_value as Dictionary).duplicate(true)
		if city_plan != null and city_plan.generated() \
				and grid != null and grid.built:
			city_plan.apply_snapshot(_city_plan_restore_state)
			city_plan.configure(grid, claim, founded_seed, structures, roads,
				MAX_CLAIM_RADIUS)
			_city_plan_restore_state.clear()
			_apply_city_plan_masks()
	# Active levels are duplicated deliberately for readable reports/snapshots, but
	# their exact level purchases still become part of the immutable paid history.
	for level in build_speed_level:
		_mark_purchase_built(CityPurchase.BUILD_SPEED_1 + level)
	for level in move_speed_level:
		_mark_purchase_built(CityPurchase.MOVE_SPEED_1 + level)
	for level in harvester_rate_level:
		_mark_purchase_built(CityPurchase.HARVEST_RATE_1 + level)
	purchased_flags |= requested_flags | built_flags
	var gained_coasts := not had_coasts \
		and city_upgrade_built(CityPurchase.COASTS)
	# Old snapshots carried only the Tier 0 compatibility booleans in the town
	# packet. Never discard them when newer progression state is applied first.
	if _tier_zero_space_full:
		tier_allocated_flags |= 1
	if _tier_zero_complete:
		tier_complete_flags |= 1
	# Old saves could have a physically complete tier waiting for the removed
	# expansion purchase. Development now advances immediately while preserving the
	# independently saved continuous border radius.
	while tier < MAX_CITY_TIER \
			and (tier_complete_flags & (1 << tier)) != 0:
		tier += 1
	if (not is_equal_approx(old_radius, claim_radius) or gained_coasts) \
			and grid != null and _shape != null and is_inside_tree():
		if _build_task >= 0:
			var bake_difference := absf(
				claim_radius - _ground_bake_radius)
			if gained_coasts or bake_difference >= grid.cell_size - 0.0001 \
					or claim_radius < _ground_bake_radius \
					or claim_radius >= MAX_CLAIM_RADIUS:
				_rebuild_after_ground = true
		elif gained_coasts:
			reground()
		else:
			var claim_difference := absf(claim_radius - claim.radius)
			if claim_radius < claim.radius \
					or claim_difference >= grid.cell_size - 0.0001 \
					or claim_radius >= MAX_CLAIM_RADIUS:
				_refresh_claim_boundary(claim_radius >= claim.radius)


## Report-ready offers. The panel presents these values, but the host recomputes all
## of them when the request arrives; stale UI therefore cannot buy an invalid upgrade.
func city_purchase_offers() -> Dictionary:
	var build_id := CityPurchase.BUILD_SPEED_1 \
		+ mini(build_speed_level, MAX_SPEED_LEVEL - 1)
	var build := _city_purchase_offer(build_id)
	build["value"] = "LEVEL %d/%d  (+%d%%)" % [
		build_speed_level, MAX_SPEED_LEVEL,
		roundi(float(build_speed_level) * BUILD_SPEED_PER_LEVEL * 100.0)]
	if build_speed_level >= MAX_SPEED_LEVEL:
		build["status"] = "maxed"
		build["enabled"] = false

	var move_id := CityPurchase.MOVE_SPEED_1 \
		+ mini(move_speed_level, MAX_SPEED_LEVEL - 1)
	var move := _city_purchase_offer(move_id)
	move["value"] = "LEVEL %d/%d  (+%d%%)" % [
		move_speed_level, MAX_SPEED_LEVEL,
		roundi(float(move_speed_level) * MOVE_SPEED_PER_LEVEL * 100.0)]
	if move_speed_level >= MAX_SPEED_LEVEL:
		move["status"] = "maxed"
		move["enabled"] = false

	return {
		"build_speed": build,
		"move_speed": move,
		"bridges": _city_purchase_offer(CityPurchase.BRIDGES),
		"coasts": _city_purchase_offer(CityPurchase.COASTS),
		"second_cloner": _commission_offer(CityPurchase.SECOND_CLONER),
		"third_cloner": _commission_offer(CityPurchase.THIRD_CLONER),
		"fourth_cloner": _commission_offer(CityPurchase.FOURTH_CLONER),
		"hat_house": _commission_offer(CityPurchase.HAT_HOUSE),
		"abilities_house": _commission_offer(
			CityPurchase.ABILITIES_HOUSE),
		"abilities_house_tower": _commission_offer(
			CityPurchase.ABILITIES_HOUSE_TOWER),
		"biomass_harvester": _commission_offer(
			CityPurchase.BIOMASS_HARVESTER),
		"send_settlement": _city_purchase_offer(
			CityPurchase.SEND_SETTLEMENT),
	}


func _commission_offer(purchase_id: int) -> Dictionary:
	var offer := _city_purchase_offer(purchase_id)
	if String(offer.get("status", "")) == "requested":
		if not commissioned_work_unlocked(_alive):
			offer["value"] = "QUEUED — STARTS AT %d SETTLERS" \
				% COMMISSION_POPULATION
		elif _commission_waiting_for_space:
			offer["value"] = "WAITING FOR BORDER SPACE"
		else:
			offer["value"] = "PRIORITY COMMISSION"
	return offer


func _city_purchase_offer(purchase_id: int) -> Dictionary:
	var cost := city_purchase_cost(purchase_id)
	var status := _city_purchase_status(purchase_id)
	var shortfall := maxf(cost - available(), 0.0)
	return {
		"purchase_id": purchase_id,
		"cost": cost,
		"status": status,
		"enabled": (status == "available" and shortfall <= 0.0001) \
			or status == "token_ready",
		"shortfall": shortfall,
		"value": status.to_upper(),
	}


func _city_purchase_status(purchase_id: int) -> String:
	if not city_purchase_valid(purchase_id):
		return "locked"
	if purchase_id == CityPurchase.SEND_SETTLEMENT:
		return "available" if settlement_founder_rows().size() == 6 else "locked"
	var flag := _purchase_flag(purchase_id)
	if (built_flags & flag) != 0:
		return "built"
	if (requested_flags & flag) != 0:
		return "requested"
	if purchase_id >= CityPurchase.BUILD_SPEED_1 \
			and purchase_id <= CityPurchase.BUILD_SPEED_5:
		var build_level := purchase_id - CityPurchase.BUILD_SPEED_1
		return "available" if build_speed_level == build_level else "locked"
	if purchase_id >= CityPurchase.MOVE_SPEED_1 \
			and purchase_id <= CityPurchase.MOVE_SPEED_5:
		var move_level := purchase_id - CityPurchase.MOVE_SPEED_1
		return "available" if move_speed_level == move_level else "locked"
	if is_harvester_rate_purchase(purchase_id):
		var harvest_level := purchase_id - CityPurchase.HARVEST_RATE_1
		if biomass_harvester_index() < 0:
			return "locked"
		return "available" \
			if harvester_rate_level == harvest_level else "locked"
	if purchase_id == CityPurchase.ABILITIES_HOUSE_TOWER:
		return "available" if abilities_house_index() >= 0 else "locked"
	var cloner_ordinal := _cloner_purchase_ordinal(purchase_id)
	if cloner_ordinal >= 0:
		return "available" if structures != null and structures.count_of(
			MeepStructures.Kind.CLONER, true) >= cloner_ordinal else "locked"
	if (purchased_flags & flag) != 0:
		return "requested"
	return "available"


func _current_tier_full() -> bool:
	return (tier_complete_flags & (1 << tier)) != 0


func _mark_purchase_built(purchase_id: int) -> void:
	var flag := _purchase_flag(purchase_id)
	purchased_flags |= flag
	requested_flags &= ~flag
	built_flags |= flag


func _purchase_reserves_construction(purchase_id: int) -> bool:
	return purchase_id == CityPurchase.HAT_HOUSE \
		or purchase_id == CityPurchase.ABILITIES_HOUSE \
		or purchase_id == CityPurchase.BIOMASS_HARVESTER \
		or purchase_id == CityPurchase.ABILITIES_HOUSE_TOWER \
		or purchase_id == CityPurchase.SECOND_CLONER \
		or purchase_id == CityPurchase.THIRD_CLONER \
		or purchase_id == CityPurchase.FOURTH_CLONER


func _purchase_flag(purchase_id: int) -> int:
	return 1 << purchase_id


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


## Sorts the population into detail bands, and is the one pass that walks the town's
## whole history. Measured on the flat map, in metres, so this costs a subtraction
## per Meep per eye rather than a projection.
func _grade() -> void:
	var hot := HOT_RANGE * HOT_RANGE
	var warm := WARM_RANGE * WARM_RANGE
	if _near_squared.size() != _local.size():
		_near_squared.resize(_local.size())
	_active_rows.clear()
	_memorial_rows.clear()
	_visible_rows.clear()
	_nearest_row_squared = INF
	for index in _local.size():
		var state := _state[index]
		if state == State.DEAD:
			_memorial_rows.push_back(index)
			continue
		if state == State.DEPARTED:
			continue
		_active_rows.push_back(index)
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
		if state != State.INSIDE and state != State.AT_HOME \
				and state != State.AT_WORKPLACE:
			_visible_rows.push_back(index)
			_nearest_row_squared = minf(_nearest_row_squared, nearest)
	_refresh_street_life()


## Rebuilds the iteration lists without regrading, for the paths that change who is
## alive from outside the simulation: a joiner's identity sidecar, a cold restore's
## simulation rows, and the client-side death and position packets.
func _refresh_rows() -> void:
	_active_rows.clear()
	_memorial_rows.clear()
	_visible_rows.clear()
	for index in _state.size():
		var state := _state[index]
		if state == State.DEAD:
			_memorial_rows.push_back(index)
			continue
		if state == State.DEPARTED:
			continue
		_active_rows.push_back(index)
		if state != State.INSIDE and state != State.AT_HOME \
				and state != State.AT_WORKPLACE:
			_visible_rows.push_back(index)
	_refresh_street_life()


func _street_life_target() -> int:
	return mini(_alive, clampi(
		MIN_STREET_LIFE + floori(float(_alive)
			/ float(STREET_LIFE_POPULATION_STEP)),
		MIN_STREET_LIFE, MAX_STREET_LIFE))


func _refresh_street_life() -> void:
	_street_life_mask.resize(_state.size())
	_street_life_mask.fill(0)
	var target := _street_life_target()
	var assigned := 0
	# Preserve residents who are already outdoors first. When they next become idle,
	# their normal decision pass chooses another road stroll instead of all heading
	# through their doors in the same quiet interval.
	for index in _visible_rows:
		if assigned >= target:
			return
		if not _active_resident(index):
			continue
		_street_life_mask[index] = 1
		assigned += 1
	# Wake only enough hidden residents to meet the floor. Workplaces and cloners
	# remain honest indoor assignments; off-duty residents at home are the reserve.
	for index in _active_rows:
		if assigned >= target:
			return
		if _street_life_mask[index] != 0 \
				or _state[index] == State.INSIDE \
				or _state[index] == State.AT_WORKPLACE:
			continue
		_street_life_mask[index] = 1
		assigned += 1
		if _state[index] == State.AT_HOME:
			_timer[index] = minf(_timer[index],
				STREET_LIFE_WAKE_SECONDS + float(assigned) * 0.1)


func _keeps_street_life(index: int) -> bool:
	return index >= 0 and index < _street_life_mask.size() \
		and _street_life_mask[index] != 0


## Rebuilds the host's occupancy once for this simulation tick. Every visible
## resident is linked into one fixed navigation-grid bucket regardless of detail;
## drawing distance can therefore never switch authoritative avoidance on or off.
func _rebuild_crowd_index() -> void:
	_crowd_indexed_rows = 0
	_crowd_last_cells_checked = 0
	_crowd_last_neighbor_checks = 0
	_crowd_max_neighbor_checks = 0
	if grid == null:
		_crowd_heads.clear()
		_crowd_next.clear()
		_crowd_touched.clear()
		return
	var bucket_count := grid.cells * grid.cells
	if _crowd_heads.size() != bucket_count:
		_crowd_heads.resize(bucket_count)
		_crowd_heads.fill(-1)
		_crowd_touched.clear()
	# Only the buckets somebody was standing in last time. A colony's grid is 192
	# cells square, so emptying it wholesale is 36,864 writes ten times a second for
	# a town of two hundred — two orders of magnitude more work than the occupancy
	# it is clearing, and paid by every resident colony whether anyone is there or
	# not.
	for bucket in _crowd_touched:
		_crowd_heads[bucket] = -1
	_crowd_touched.clear()
	if _crowd_next.size() != _local.size():
		_crowd_next.resize(_local.size())
	# `_crowd_next` deliberately keeps whatever it held. Every link this pass writes
	# is written before it can be read, and a row that is not indexed is not in any
	# bucket's chain, so nothing ever reaches a stale one.
	for index in _visible_rows:
		if not _visible(index):
			continue
		var cell := grid.cell_of(_local[index])
		if not grid.inside(cell):
			continue
		var bucket := grid.index(cell)
		if _crowd_heads[bucket] < 0:
			_crowd_touched.push_back(bucket)
		_crowd_next[index] = _crowd_heads[bucket]
		_crowd_heads[bucket] = index
		_crowd_indexed_rows += 1
	_crowd_rebuilds += 1


## Deterministic tangent-space direction for two rows occupying the exact same
## point. Pair order reverses the axis, so the two participants push apart rather
## than agreeing on a random teleport.
func _overlap_axis(index: int, other: int) -> Vector2:
	var low := mini(index, other)
	var high := maxi(index, other)
	var mixed: int = (low * 73856093) ^ (high * 19349663) ^ founded_seed
	mixed = posmod(mixed ^ (mixed >> 13), 65536)
	var angle := TAU * float(mixed) / 65536.0
	var axis := Vector2(cos(angle), sin(angle))
	return axis if index == low else -axis


## Blends personal-space separation and a consistent right-shoulder pass into the
## route direction. It reads at most 32 links from each of the 3x3 nearby buckets:
## both ordinary and deliberately stacked crowds remain linear in row count.
func _crowd_direction(index: int, route: Vector2) -> Vector2:
	_crowd_last_cells_checked = 0
	_crowd_last_neighbor_checks = 0
	if index < 0 or index >= _local.size() or grid == null \
			or _crowd_heads.is_empty() or route.length_squared() < 0.0001:
		return route
	var wanted := route.normalized()
	var cell := grid.cell_of(_local[index])
	if not grid.inside(cell):
		return wanted
	var here := _local[index]
	var separation := Vector2.ZERO
	var shoulder := 0.0
	var right := Vector2(wanted.y, -wanted.x)
	var reach_squared := CROWD_AVOID_RADIUS * CROWD_AVOID_RADIUS
	for y in range(cell.y - CROWD_NEIGHBOR_CELL_RADIUS,
			cell.y + CROWD_NEIGHBOR_CELL_RADIUS + 1):
		for x in range(cell.x - CROWD_NEIGHBOR_CELL_RADIUS,
				cell.x + CROWD_NEIGHBOR_CELL_RADIUS + 1):
			var nearby_cell := Vector2i(x, y)
			if not grid.inside(nearby_cell):
				continue
			_crowd_last_cells_checked += 1
			var other := _crowd_heads[grid.index(nearby_cell)]
			var checked_in_cell := 0
			while other >= 0 and checked_in_cell < CROWD_NEIGHBORS_PER_CELL:
				var next := _crowd_next[other] \
					if other < _crowd_next.size() else -1
				checked_in_cell += 1
				_crowd_last_neighbor_checks += 1
				if other != index and other < _local.size() and _visible(other):
					var offset := here - _local[other]
					var away_squared := offset.length_squared()
					if away_squared < reach_squared:
						var distance := sqrt(maxf(away_squared, 0.0))
						var away := offset / distance if distance > 0.0001 \
							else _overlap_axis(index, other)
						var proximity := 1.0 - distance / CROWD_AVOID_RADIUS
						separation += away * proximity
						if distance > 0.0001:
							var toward := -away
							var ahead := maxf(toward.dot(wanted), 0.0)
							var frontal := 1.0 - minf(absf(toward.dot(right)), 1.0)
							shoulder += proximity * ahead \
								* (0.35 + frontal * 0.65)
				other = next
	_crowd_max_neighbor_checks = maxi(
		_crowd_max_neighbor_checks, _crowd_last_neighbor_checks)
	var blend := separation * CROWD_SEPARATION_WEIGHT \
		+ right * shoulder * CROWD_SHOULDER_WEIGHT
	if blend.length_squared() > CROWD_MAX_BLEND * CROWD_MAX_BLEND:
		blend = blend.normalized() * CROWD_MAX_BLEND
	var steered := wanted + blend
	return steered.normalized() if steered.length_squared() >= 0.0001 else wanted


## Read-only seams used by the headless crowd checks.
func crowd_spatial_stats() -> Dictionary:
	var side := CROWD_NEIGHBOR_CELL_RADIUS * 2 + 1
	return {
		"buckets": _crowd_heads.size(),
		"links": _crowd_next.size(),
		"indexed_rows": _crowd_indexed_rows,
		"rebuilds": _crowd_rebuilds,
		"last_cells_checked": _crowd_last_cells_checked,
		"last_neighbor_checks": _crowd_last_neighbor_checks,
		"max_neighbor_checks": _crowd_max_neighbor_checks,
		"neighbor_check_cap":
			side * side * CROWD_NEIGHBORS_PER_CELL,
	}


func crowd_steering_for_test(index: int, route: Vector2) -> Vector2:
	return _crowd_direction(index, route)


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
		State.GO_HOME:
			_walk_home(index, delta)
		State.AT_HOME:
			_wait_at_home(index, delta)
		State.STROLL:
			_walk_stroll(index, delta)
		State.AT_WORKPLACE:
			_wait_at_workplace(index)
		State.FLEE:
			_flee(index, delta)
		_:
			pass


## What to do next. The board is asked first and wandering is what is left, which
## is the order the later passes need: a colony with a cloner to use and a road to
## lay should have nobody strolling.
func _consecutive_home_visits() -> int:
	return clampi(1 + floori(float(_alive)
		/ float(HOME_VISIT_POPULATION_STEP)),
		1, MAX_CONSECUTIVE_HOME_VISITS)


func _home_wait_multiplier() -> float:
	var maturity := clampf(float(_alive - HOME_VISIT_POPULATION_STEP)
		/ HOME_WAIT_POPULATION_STEP, 0.0, 1.0)
	return lerpf(1.0, MAX_HOME_WAIT_MULTIPLIER, maturity)


func _decide(index: int) -> void:
	var cell := grid.cell_of(_local[index])
	if meep_role(index) == Role.CHILD:
		_child_play(index)
		return
	if meep_role(index) == Role.HARVESTER and _try_staff_harvester(index):
		return
	var allowed: Array[int] = BUILDER_JOB_KINDS
	match meep_role(index):
		Role.HOMEBODY:
			allowed = HOMEBODY_JOB_KINDS
		Role.HARVESTER:
			allowed = HARVESTER_JOB_KINDS
	var chosen := tasks.best_for_kinds(
		cell, grid.cell_size, _seed[index], allowed)
	if chosen != 0 and tasks.claim(chosen):
		var job := tasks.job(chosen)
		_job[index] = chosen
		var destination := _construction_work_cell(index, job) \
			if _construction_job(job) else job.at
		_goal[index] = grid.centre_of(destination)
		_state[index] = State.WALK
		_timer[index] = _patience(cell, destination)
		if _job_prefers_roads(job):
			# Ask before the first stride. Until the worker returns a field the same
			# safe straight-line fallback still applies. A construction crew shares
			# the nominal approach field, then fans out around the footprint nearby.
			_field_for(job.at)
		return
	if _keeps_street_life(index):
		_idle_turn[index] = 0
		_wander(index)
		return
	var home := meep_home(index)
	if home >= 0 and _idle_turn[index] < _consecutive_home_visits():
		_idle_turn[index] += 1
		_go_home(index, home)
		return
	_idle_turn[index] = 0
	_wander(index)


func _child_play(index: int) -> void:
	if roads != null and roads.cell_count() > 1:
		var path := roads.stroll_path(_local[index],
			_rng.randi_range(STROLL_CELLS_MIN, STROLL_CELLS_MAX),
			_seed[index] ^ _rng.randi())
		if path.size() > 1:
			_stroll_paths[index] = path
			_state[index] = State.STROLL
			_timer[index] = maxf(stats.wander_seconds,
				float(path.size()) * grid.cell_size
					/ maxf(effective_walk_speed(), 0.1) * 2.0)
			_next_stroll_goal(index)
			return
	var plaza := ship_ring_cells()
	if not plaza.is_empty():
		var slot := posmod(_seed[index] + roundi(meep_age(index)), plaza.size())
		_stroll_paths[index] = PackedInt32Array([plaza[slot]])
		_state[index] = State.STROLL
		_timer[index] = stats.wander_seconds
		_next_stroll_goal(index)
		return
	_state[index] = State.IDLE


func _try_staff_harvester(index: int) -> bool:
	var workplace := biomass_harvester_index()
	if workplace < 0 or structures == null:
		return false
	var staffed := 0
	for row in _workplaces.size():
		if _active_resident(row) and _workplaces[row] == workplace:
			staffed += 1
	if staffed >= HARVESTER_STAFF_SLOTS:
		return false
	_workplaces[index] = workplace
	var destination := structures.work_cell(workplace)
	_goal[index] = grid.centre_of(destination)
	_state[index] = State.WALK
	_timer[index] = _patience(grid.cell_of(_local[index]), destination)
	_field_for(destination)
	return true


func _wait_at_workplace(index: int) -> void:
	var workplace := _workplaces[index] if index < _workplaces.size() else -1
	var entry := structures.at(workplace) \
		if workplace >= 0 and structures != null else null
	if meep_role(index) != Role.HARVESTER or entry == null \
			or not entry.built() \
			or entry.kind != MeepStructures.Kind.BIOMASS_HARVESTER:
		_workplaces[index] = -1
		_state[index] = State.IDLE


func _construction_job(job: MeepTasks.Job) -> bool:
	return job != null and (job.kind == MeepTasks.Kind.BUILD
		or job.kind == MeepTasks.Kind.UPGRADE) \
		and structures != null and job.subject >= 0


## Gives every builder its own perimeter cell. The first takes the shortest approach;
## each later claim maximizes its distance from the already assigned crew, producing
## opposite sides before filling the gaps. A vacated cell can be selected again without
## storing another replicated sidecar because live row goals are the assignment ledger.
func _construction_work_cell(index: int, job: MeepTasks.Job) -> Vector2i:
	if not _construction_job(job) or index < 0 or index >= _local.size():
		return job.at if job != null else Vector2i.ZERO
	var candidates := structures.access_cells(job.subject)
	if candidates.is_empty():
		return job.at

	var assigned: Array[Vector2i] = []
	var use_counts: Dictionary = {}
	for other in _local.size():
		if other == index or not _active_resident(other) \
				or _job[other] != job.id:
			continue
		var occupied := grid.cell_of(_goal[other])
		if not candidates.has(occupied):
			continue
		assigned.push_back(occupied)
		use_counts[occupied] = int(use_counts.get(occupied, 0)) + 1

	var from := grid.cell_of(_local[index])
	var best := candidates[0]
	var best_uses := 0x7fffffff
	var best_separation := -1.0
	var best_travel := INF
	var best_key := 0x7fffffff
	for candidate in candidates:
		var uses := int(use_counts.get(candidate, 0))
		var separation := 0.0
		if not assigned.is_empty():
			separation = INF
			for occupied in assigned:
				separation = minf(separation,
					Vector2(candidate - occupied).length_squared())
		var travel := Vector2(candidate - from).length_squared()
		var key := grid.index(candidate)
		if uses < best_uses \
				or (uses == best_uses and separation > best_separation) \
				or (uses == best_uses
					and is_equal_approx(separation, best_separation)
					and travel < best_travel) \
				or (uses == best_uses
					and is_equal_approx(separation, best_separation)
					and is_equal_approx(travel, best_travel) and key < best_key):
			best = candidate
			best_uses = uses
			best_separation = separation
			best_travel = travel
			best_key = key
	return best


## How long a Meep will spend getting to a job before giving it up.
##
## The straight walk with generous slack, because a route around a chasm is much longer
## than the line across it. It exists for the goal that was walled off after it was
## picked, or was never reachable in the first place: without it a Meep with an
## impossible job walks at a wall until the session ends.
func _patience(from: Vector2i, to: Vector2i) -> float:
	var away := Vector2(to - from).length() * grid.cell_size
	return away / maxf(effective_walk_speed(), 0.1) * 2.5 + 8.0


func _wander(index: int) -> void:
	# The colony's own generator rather than one per decision: a settler picking a
	# stroll should not allocate, and only the host ever wanders — where a Meep
	# went is replicated, so it does not have to be reproducible.
	if roads != null and roads.cell_count() > 1:
		var path := roads.stroll_path(_local[index],
			_rng.randi_range(STROLL_CELLS_MIN, STROLL_CELLS_MAX),
			_seed[index] ^ _rng.randi())
		if path.size() > 1:
			_stroll_paths[index] = path
			_state[index] = State.STROLL
			_timer[index] = maxf(stats.wander_seconds,
				float(path.size()) * grid.cell_size
					/ maxf(effective_walk_speed(), 0.1) * 2.0)
			_next_stroll_goal(index)
			return
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


func _go_home(index: int, home: int) -> void:
	if structures == null:
		_wander(index)
		return
	var destination := structures.work_cell(home)
	if not grid.passable(destination):
		_wander(index)
		return
	_goal[index] = grid.centre_of(destination)
	_state[index] = State.GO_HOME
	_timer[index] = _patience(grid.cell_of(_local[index]), destination)
	# Homes are one destination per sibling pair, unlike a construction site shared
	# by a whole crew. Baking a 16k-cell field for every house made a mature city
	# continuously evict and rebuild routes while 80+ residents went home. The
	# direct walker still uses grid legality, crowd avoidance, local detours, and
	# the shared centre field if boxed in; only the wasteful per-house road bias is
	# omitted.


func _walk_home(index: int, delta: float) -> void:
	if meep_home(index) < 0:
		_state[index] = State.IDLE
		return
	_timer[index] -= delta
	if _local[index].distance_to(_goal[index]) <= stats.arrive_within:
		_state[index] = State.AT_HOME
		_heading[index] = Vector2.ZERO
		_timer[index] = _rng.randf_range(
			HOME_WAIT_MIN, HOME_WAIT_MAX) * _home_wait_multiplier()
		return
	if _timer[index] <= 0.0:
		_state[index] = State.IDLE
		return
	_advance(index, delta, effective_walk_speed())


func _wait_at_home(index: int, delta: float) -> void:
	if meep_home(index) < 0:
		_state[index] = State.IDLE
		return
	_timer[index] -= delta
	if _timer[index] <= 0.0:
		_state[index] = State.IDLE


func _walk_stroll(index: int, delta: float) -> void:
	_timer[index] -= delta
	if _local[index].distance_to(_goal[index]) <= stats.arrive_within:
		if not _next_stroll_goal(index):
			_stroll_paths.erase(index)
			_state[index] = State.IDLE
		return
	if _timer[index] <= 0.0:
		_stroll_paths.erase(index)
		_state[index] = State.IDLE
		return
	_advance(index, delta, effective_walk_speed())


func _next_stroll_goal(index: int) -> bool:
	var path: PackedInt32Array = _stroll_paths.get(index, PackedInt32Array())
	if path.is_empty():
		return false
	var cell_index := path[0]
	path.remove_at(0)
	_stroll_paths[index] = path
	var cell := Vector2i(cell_index % grid.cells, cell_index / grid.cells)
	_goal[index] = grid.centre_of(cell)
	return true


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
			if index < _workplaces.size() and _workplaces[index] >= 0:
				_workplaces[index] = -1
				_state[index] = State.IDLE
				return
			_wander(index)
		else:
			_give_up(index)
		return
	_advance(index, delta, effective_walk_speed())


func _arrive(index: int) -> void:
	var job := tasks.job(_job[index])
	if job == null:
		if index < _workplaces.size() and _workplaces[index] >= 0:
			var workplace := structures.at(_workplaces[index]) \
				if structures != null else null
			if workplace != null and workplace.built() \
					and workplace.kind == MeepStructures.Kind.BIOMASS_HARVESTER:
				_state[index] = State.AT_WORKPLACE
				_heading[index] = Vector2.ZERO
				return
			_workplaces[index] = -1
		_leave_job(index)
		return
	_state[index] = State.WORK
	if job.kind == MeepTasks.Kind.CLONE:
		# The wait at the door, rather than the work: there may be five inside already.
		_timer[index] = QUEUE_PATIENCE
	elif _construction_job(job):
		var entry := structures.at(job.subject)
		var toward := entry.local - _local[index] \
			if entry != null else Vector2.ZERO
		if toward.length_squared() > 0.0001:
			_heading[index] = toward.normalized()


## Work in progress, which is different work depending on what was claimed. A job whose
## board entry has gone was cancelled from under this Meep, which is also how the rest
## of a crew learn that somebody else finished what they were all doing.
func _work(index: int, delta: float) -> void:
	var job := tasks.job(_job[index])
	if job == null:
		_leave_job(index)
		return
	var seconds := delta * effective_work_rate()
	if not RuntimeTelemetry.deep_enabled():
		_do_work(index, job, seconds, delta)
		return
	# The blow that finishes a job is inside the same call as the thousand that
	# only advanced a timer, so the trace has to name the kind of work rather than
	# the fact that somebody was working.
	var began := Time.get_ticks_usec()
	_do_work(index, job, seconds, delta)
	RuntimeTelemetry.record_activity(&"meeps",
		WORK_TRACE_LABELS[job.kind], Time.get_ticks_usec() - began)


func _do_work(index: int, job: MeepTasks.Job, seconds: float,
		delta: float) -> void:
	match job.kind:
		MeepTasks.Kind.MINE:
			_chop(index, job, seconds)
		MeepTasks.Kind.BUILD:
			_build(index, job, seconds)
		MeepTasks.Kind.UPGRADE:
			_upgrade_building(index, job, seconds)
		MeepTasks.Kind.ROAD:
			_pave(index, job, seconds)
		MeepTasks.Kind.CLONE:
			_queue_at_cloner(index, job, delta)
		MeepTasks.Kind.SHARED_WALL:
			_build_shared_wall(index, job, seconds)
		_:
			if tasks.work(job.id, seconds):
				_finish_job(index, job)


func offer_shared_wall(segment_id: String, world_point: Vector3,
		reservation_id: int, work_remaining: float) -> bool:
	if segment_id.is_empty() or reservation_id <= 0 or not _ground_ready \
			or grid == null or tasks == null:
		return false
	for value: Variant in _wall_job_segments.values():
		if value is Dictionary and String((value as Dictionary).get(
				"segment_id", "")) == segment_id:
			return true
	var local := _site_local_of(world_point)
	var target := grid.nearest_passable(grid.cell_of(local), 12)
	if not grid.inside(target) or not claim.contains_cell(target):
		return false
	var id := tasks.post(MeepTasks.Kind.SHARED_WALL, target,
		BUILD_PRIORITY + 0.25, MeepRoads.CREW,
		maxf(work_remaining, 0.001), 0.0)
	if id <= 0:
		return false
	_wall_job_segments[id] = {
		"segment_id": segment_id,
		"reservation_id": reservation_id,
	}
	return true


func shared_wall_completed() -> void:
	if _ground_ready:
		_refresh_claim_boundary(false)


func _build_shared_wall(index: int, job: MeepTasks.Job,
		seconds: float) -> void:
	var contract: Variant = _wall_job_segments.get(job.id)
	if not contract is Dictionary:
		_finish_job(index, job)
		return
	var registry := get_parent()
	if registry == null or not registry.has_method(&"advance_shared_wall"):
		_finish_job(index, job)
		return
	var row := contract as Dictionary
	var complete := bool(registry.call(&"advance_shared_wall", site_id,
		String(row.get("segment_id", "")),
		int(row.get("reservation_id", 0)), maxf(seconds, 0.0)))
	var locally_done := tasks.work(job.id, seconds)
	if complete or locally_done:
		_finish_job(index, job)


## Felling a tree. The timer is the chopping; the blow at the end of it is the tree
## coming down.
##
## The field is asked for the exact root selected when the job was posted. A generic
## volume can report success because nearby grass absorbed it while leaving that flower
## standing; `harvest_at` only succeeds after the selected resident plant is hidden and
## put through the same replicated break ledger as ability damage.
##
## The pay does not depend on that answer, only on the plant having been standing
## when the job was posted, which the timber slot below is the record of. A field
## that has since forgotten the exact instance — because its cache turned over, or
## the plant was felled by something else in the meantime — used to mean a Meep
## spent its whole chopping timer for nothing and the town's income silently
## depended on the camera. The slot is cleared either way, so the same tree cannot
## be billed twice.
func _chop(index: int, job: MeepTasks.Job, seconds: float) -> void:
	if not tasks.work(job.id, seconds):
		return
	if job.spot != Vector3.ZERO:
		for field_variant: Variant in get_tree().get_nodes_in_group(
				DamageHit.FIELD_GROUP):
			var field := field_variant as Node
			if field == null or not DamageHit.in_same_world(self, field) \
					or not field.has_method(&"harvest_at"):
				continue
			if bool(field.call(&"harvest_at", job.spot, FELL_RADIUS,
					FELL_DAMAGE)):
				break
	if job.subject >= 0 and job.subject < _timber.size() \
			and _timber[job.subject].w > 0.0:
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
	var entry := structures.at(job.subject)
	var commission := _commission_purchase_for_structure(job.subject) \
		if entry != null else -1
	var done := structures.advance(job.subject, seconds)
	tasks.work(job.id, seconds)
	if not done:
		return
	_complete_building(job.subject)
	_spend_reserved(job.reserved)
	if commission >= 0:
		complete_city_purchase(commission, false)
	_finish_job(index, job)


func _upgrade_building(index: int, job: MeepTasks.Job, seconds: float) -> void:
	if structures == null:
		_leave_job(index)
		return
	tasks.work(job.id, seconds)
	if not structures.advance_upgrade(job.subject, seconds):
		return
	var entry := structures.at(job.subject)
	var abilities_tower := entry != null \
		and entry.kind == MeepStructures.Kind.ABILITIES_HOUSE \
		and city_upgrade_requested(CityPurchase.ABILITIES_HOUSE_TOWER)
	if structures.complete_upgrade(job.subject):
		_spend_reserved(job.reserved)
		if abilities_tower:
			complete_city_purchase(
				CityPurchase.ABILITIES_HOUSE_TOWER, false)
		_refresh_deeds()
		_town_changed = true
	_finish_job(index, job)


## Paving. A branch is deliberately one shared job: several Meeps working at its end
## contribute to the same strip, then the whole path becomes cheap ground together.
func _pave(index: int, job: MeepTasks.Job, seconds: float) -> void:
	if roads == null:
		_leave_job(index)
		return
	if not roads.advance(job.subject, seconds):
		return
	var segment := roads.at(job.subject)
	var surface_kind := segment.surface_kind \
		if segment != null else MeepRoads.SurfaceKind.LAND
	var cells := roads.complete(job.subject)
	if surface_kind == MeepRoads.SurfaceKind.LAND:
		_queue_road_clear_cells(cells)
	if structures != null:
		structures.clear_exhaustion()
	_set_commission_waiting_for_space(false)
	_spend_reserved(job.reserved)
	_town_changed = true
	_finish_job(index, job)
	if surface_kind != MeepRoads.SurfaceKind.LAND:
		reground()


## A building completes: the ground it stands on leaves the map, the flora it stands in
## comes down, and the crew who were standing in the footprint are put outside it.
func _complete_building(structure: int) -> void:
	structures.block(structure)
	_clear_footprint(structure)
	_refresh_deeds()
	_town_changed = true
	for index in _local.size():
		if _active_resident(index) \
				and not grid.passable(grid.cell_of(_local[index])):
			_settle(index)


## Tears the flora out of a finished building's footprint.
##
## One area volume, the same trick an explosion uses, through the same ledger: what is
## cleared is cleared on every peer and stays cleared when the tile streams out again.
## A finer tile may later scatter instances that did not exist to enter that ledger;
## [method _maintain_structures] catches those only for the nearest visible footprints.
## [param seen] is false for the maintenance sweep below, which is catching plants
## that streamed in at a finer density under a building that went up long ago. A burst
## of leaves per plant is right for the moment a building lands and wrong for that: one
## sweep found two hundred and ninety of them and spent twenty-four milliseconds
## playing an effect for each, behind a wall, for nobody.
func _clear_footprint(structure: int, seen := true) -> void:
	if not _is_host() or structures == null:
		return
	var entry := structures.at(structure)
	if entry != null and entry.kind == MeepStructures.Kind.DOCK_HUT:
		return
	var hit := DamageHit.area(structures.world_centre(structure),
		structures.footprint_radius(structure) + CLEAR_MARGIN, FELL_DAMAGE, 0.0)
	hit.affects_combatants = false
	hit.plant_break_effects = seen
	hit.ability_id = "clear_footprint"
	DamageHit.apply_to_fields(self, hit)


## Clears every loaded plant from newly paved cells through the same persistent break
## ledger as buildings and abilities. It is intentionally unpaid work: clearing a road
## through a bush is part of the road's cost, not a way to manufacture biomass.
func _clear_road_cells(cells: PackedInt32Array, seen := true) -> void:
	if not _is_host() or roads == null:
		return
	for cell_index in cells:
		_clear_road_cell(cell_index, seen)


## [param seen] carries the same meaning as in [method _clear_footprint].
func _clear_road_cell(cell_index: int, seen := true) -> void:
	var point := roads.world_point(cell_index)
	if point == Vector3.ZERO:
		return
	_road_swept[cell_index] = float(Time.get_ticks_msec()) * 0.001
	var hit := DamageHit.area(point, ROAD_CLEAR_RADIUS, FELL_DAMAGE, 0.0)
	hit.affects_combatants = false
	hit.plant_break_effects = seen
	hit.ability_id = "clear_road_cell"
	DamageHit.apply_to_fields(self, hit)


func _queue_road_clear_cells(cells: PackedInt32Array) -> void:
	if cells.is_empty():
		return
	_road_clear_pending.append_array(cells)


func _clear_next_completed_road_cell() -> void:
	if not _is_host() or roads == null \
			or _road_clear_pending_head >= _road_clear_pending.size():
		return
	_clear_road_cell(_road_clear_pending[_road_clear_pending_head])
	_road_clear_pending_head += 1
	if _road_clear_pending_head >= _road_clear_pending.size():
		_road_clear_pending.clear()
		_road_clear_pending_head = 0


## Ground cover is streamed around the viewer. A road built while nobody watched may
## therefore meet grass that did not exist at build time; sweep the few cells nearest
## the viewer while somebody is near rather than paying to revisit the whole town.
##
## The nearest cells to somebody standing still are the same two cells every quarter
## second, and they are bare after the first sweep. A recorded run spent a fifth of a
## second offering volumes to the flora fields for cells that gave up nothing at all,
## so a swept cell is left alone until [constant ROAD_SWEEP_REARM] has passed and cover
## could plausibly have streamed in over it again.
func _maintain_roads() -> void:
	if roads == null or roads.cell_count() == 0 \
			or _view_eye.length() > claim_radius + HOT_RANGE:
		return
	var now := float(Time.get_ticks_msec()) * 0.001
	var due := PackedInt32Array()
	for cell in roads.nearest_cells(_view_eye, ROAD_CLEAR_BUDGET):
		if now - float(_road_swept.get(cell, -ROAD_SWEEP_REARM)) \
				< ROAD_SWEEP_REARM:
			continue
		due.push_back(cell)
	if due.is_empty():
		return
	_clear_road_cells(due, false)


## Ground cover can stream at a finer density after an unwatched building was finished.
## Keep only the nearest visible footprints bare; scanning every structure in every
## distant colony would turn a visual maintenance rule into planet-wide simulation cost.
func _maintain_structures() -> void:
	if structures == null or structures.built_count() == 0 \
			or _view_eye.length() > claim_radius + HOT_RANGE:
		return
	var nearby: Array[Vector2i] = []
	for index in structures.count():
		var entry := structures.at(index)
		if entry == null or not entry.built():
			continue
		var away := entry.local.distance_squared_to(_view_eye)
		nearby.push_back(Vector2i(roundi(away * 100.0), index))
	nearby.sort()
	for slot in mini(STRUCTURE_CLEAR_BUDGET, nearby.size()):
		_clear_footprint(nearby[slot].y, false)


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
			or _alive + _cloners_inside() \
				>= mini(housing_capacity(), population_ceiling()):
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
		* stats.body_radius * 3.0, _rng.randi(), true)


## Puts a job down without finishing it, handing the place on the crew back.
func _leave_job(index: int) -> void:
	if _job[index] != 0:
		tasks.release(_job[index])
		_job[index] = 0
	if index < _workplaces.size():
		_workplaces[index] = -1
	_state[index] = State.IDLE


## Work that is done: the crew place goes back and the job comes off the board, which is
## how the rest of the crew find out there is nothing left to do.
func _finish_job(index: int, job: MeepTasks.Job) -> void:
	tasks.release(job.id)
	tasks.finish(job.id)
	_wall_job_segments.erase(job.id)
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
	_advance(index, delta, effective_flee_speed())


## Moves a Meep towards its goal and puts it back on the ground.
##
## Shared town errands follow their cost field even across open ground; that is what
## makes cheap completed roads visible in behaviour rather than only when a straight
## line meets a chasm. Mining and the one-destination-per-home commute use the direct
## local walker. Cells are never entered unless the grid says they can be stood in.
func _advance(index: int, delta: float, speed: float) -> void:
	var here := _local[index]
	var cell := grid.cell_of(here)
	var wanted := (_goal[index] - here).normalized()
	var routed := _route_direction(index, cell)
	if routed != Vector2.ZERO:
		wanted = routed
	var straight := grid.cell_of(here + wanted * grid.cell_size)
	if not grid.passable(straight):
		wanted = _detour(index, cell, wanted)
	if wanted == Vector2.ZERO:
		return
	# The spatial index is host-only and contains every visible detail band. Route
	# intent stays primary; a crowd turn is accepted only when its look-ahead cell
	# remains legal, so separation cannot shoulder a walker off a road into a hole.
	var crowd_wanted := _crowd_direction(index, wanted)
	var crowd_cell := grid.cell_of(here + crowd_wanted * grid.cell_size)
	if grid.passable(crowd_cell):
		wanted = crowd_wanted
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
		# A watched Meep used to spend this tick merely turning, then steer back into
		# the same trunk next tick. Move along the open shoulder now so nearby crowds
		# do not become slower than the same colony while nobody is watching it.
		var turn := PI * 0.5 if (_seed[index] & 1) == 0 else -PI * 0.5
		var aside := heading.rotated(turn)
		if _obstructed(index, here, aside):
			aside = heading.rotated(-turn)
		if _obstructed(index, here, aside):
			return
		var side_cell := grid.cell_of(here + aside * speed * delta)
		if not grid.passable(side_cell):
			return
		heading = aside
		_heading[index] = heading
		next = here + heading * speed * delta
		into = side_cell
	_local[index] = next
	_height[index] = _ground_height(index, into)


func _job_prefers_roads(job: MeepTasks.Job) -> bool:
	if job == null:
		return false
	return job.kind == MeepTasks.Kind.CLONE \
		or job.kind == MeepTasks.Kind.BUILD \
		or job.kind == MeepTasks.Kind.UPGRADE \
		or job.kind == MeepTasks.Kind.ROAD


## Far from a structure, every builder shares its one cached road-biased approach
## field. Once it reaches the structure's neighborhood it leaves that common route
## and takes the direct final path to its own perimeter slot.
func _construction_fanout_near(job: MeepTasks.Job, cell: Vector2i) -> bool:
	if not _construction_job(job):
		return false
	var entry := structures.at(job.subject)
	if entry == null:
		return false
	var plan := MeepStructures.plan_of(entry.kind)
	var centre := grid.cell_of(entry.local)
	var reach := float(maxi(plan.span.x, plan.span.y) + 2)
	return Vector2(cell - centre).length_squared() <= reach * reach


func _route_direction(index: int, cell: Vector2i) -> Vector2:
	var job: MeepTasks.Job = tasks.job(_job[index]) \
		if _job[index] != 0 else null
	if job == null or not _job_prefers_roads(job):
		return Vector2.ZERO
	if _construction_job(job) and _construction_fanout_near(job, cell):
		return Vector2.ZERO
	var destination := job.at \
		if _construction_job(job) else grid.cell_of(_goal[index])
	var field := _field_for(destination)
	var step := field.step_at(cell) if field != null else Vector2i.ZERO
	if step == Vector2i.ZERO or not grid.passable(cell + step):
		return Vector2.ZERO
	return (grid.centre_of(cell + step) - _local[index]).normalized()


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
		var job: MeepTasks.Job = tasks.job(_job[index])
		# Null while the fill is still on a worker, which is the first few tenths of
		# a second after a crew is handed work at a place nobody has walked to yet.
		# They shoulder their way there in the meantime and pick the route up when it
		# arrives, which for the first stretch of a long walk is the same line.
		if not (_construction_job(job)
				and _construction_fanout_near(job, cell)):
			var destination := job.at \
				if _construction_job(job) else grid.cell_of(_goal[index])
			var field := _field_for(destination)
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
	var lift := stats.body_height * 0.5 + FLOOR_CLEARANCE
	# Far enough ahead to turn in. A ray only as long as one tick's walk would find
	# the tree at the moment the Meep was already inside it.
	var probe := from + heading * (stats.collision_radius + grid.cell_size * 0.5)
	var probe_cell := grid.cell_of(probe)
	var probe_height := grid.walk_height_at(probe_cell) \
		if grid.has_walk_surface(probe_cell) \
		else (_shape.elevation(site.direction_at(probe), _spacing_drawn()) \
			if _shape != null else grid.height_at(probe_cell))
	var start := _planet.to_global(site.point_at(from, _height[index] + lift))
	# Follow the ground at both ends. A horizontal ray from the lower endpoint of an
	# uphill stride enters the terrain and used to call every ordinary slope a wall.
	var end := _planet.to_global(site.point_at(probe, probe_height + lift))
	var query := PhysicsRayQueryParameters3D.create(start, end, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	return true


## Where the ground is under a Meep.
##
## HOT Meeps are read from the field at the spacing the terrain is being drawn at,
## because they are the ones whose feet can be seen and the drawn surface is the one
## they have to stand on. Everyone else takes the grid's cached height, which is one
## array read and correct to within a cell.
func _ground_height(index: int, cell: Vector2i) -> float:
	if grid.has_walk_surface(cell):
		return grid.walk_height_at(cell)
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
	if field == null:
		_start_field(target)
	elif field.stale() and _field_refresh_left <= 0.0 \
			and _start_field(target):
		_field_refresh_left = FIELD_STALE_REFRESH_INTERVAL
	return field


## Puts a fill on a worker thread, unless that target is already being filled or the
## colony has as many in flight as it is allowed.
##
## The cap is what stops a town whose ground just changed from queueing a dozen
## simultaneous passes: the fields are wanted one at a time by whoever asks first, and
## the rest of the callers are content with steering until their turn comes.
func _start_field(target: Vector2i) -> bool:
	var is_home := claim != null and target == road_origin_cell()
	# A watched town may have dozens of distinct hut destinations. Keep one worker
	# lane reserved for the shared centre field: road planning depends on it and must
	# not be starved by residents asking for their individual route home.
	var target_limit := FIELD_BAKES if is_home else maxi(FIELD_BAKES - 1, 1)
	# Nothing new while a rebake is owed: the grid this would read is about to be
	# recut, and a task still reading it is what the rebake is waiting for.
	if not _is_host() or _field_tasks.has(target) \
			or _field_tasks.size() >= target_limit \
			or grid == null or not _ground_ready or _ground_owed:
		return false
	var field := MeepFlowField.new()
	_field_filling[target] = field
	# Bound rather than looked up in the task, because the task runs on another
	# thread and the dictionaries it would have to read are written on this one.
	_field_tasks[target] = WorkerThreadPool.add_task(
		_bake_field.bind(field, target), true, "MeepColony route bake")
	return true


## Worker body. Touches only the field it was handed and the grid, which is read-only
## for the duration: flags do change under it when a building completes, and the
## revision that change bumps is what makes the field this produces stale on arrival
## rather than wrong in use.
func _bake_field(field: MeepFlowField, target: Vector2i) -> void:
	field.build(grid, target)


## Picks up finished fills. Same place the ground bake is collected, for the same
## reason: the tree is only safe to touch here.
func _collect_fields() -> void:
	_advance_retired_fields()
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
		if claim != null and oldest == road_origin_cell():
			_field_order.push_back(oldest)
			continue
		_fields.erase(oldest)


## The route to the middle of town, if one has been filled. See [method _detour].
func _home_field() -> MeepFlowField:
	return _field_for(road_origin_cell()) if claim != null else null


## Drops every route and hands the bakes still running to [method
## _advance_retired_fields]. Their results are no longer wanted, but the pool has to
## finish with them before the ground under them may be recut.
func _retire_route_fields() -> void:
	for task_variant: Variant in _field_tasks.values():
		_retired_field_tasks.push_back(int(task_variant))
	_field_tasks.clear()
	_field_filling.clear()
	_fields.clear()
	_field_order.clear()


## Rebuilds the boundary and drops every route. Called when the ground changes
## under a town — a crater cut inside it, a building put up, or a bridge finished.
func reground() -> void:
	if _build_task >= 0:
		_rebuild_after_ground = true
		return
	_retire_route_fields()
	_ground_owed = true
	_advance_retired_fields()


## Starts an owed ground bake once the pool has finished with the route bakes that
## were abandoned for it.
##
## The bake rewrites the navigation grid those bakes are still reading, so it cannot
## start while one of them runs. Waiting for them here rather than on the tick that
## abandoned them is what stops a finished bridge or dock — the one thing that
## regrounds a busy town — from being a seventy-millisecond stall.
func _advance_retired_fields() -> void:
	if not _retired_field_tasks.is_empty():
		var running := PackedInt32Array()
		for task in _retired_field_tasks:
			if WorkerThreadPool.is_task_completed(task):
				WorkerThreadPool.wait_for_task_completion(task)
			else:
				running.push_back(task)
		_retired_field_tasks = running
	if _ground_owed and _retired_field_tasks.is_empty() and _build_task < 0:
		_ground_owed = false
		_start_ground()


# --- Presentation ------------------------------------------------------------

func _raise_render() -> void:
	_render = MultiMeshInstance3D.new()
	_render.name = "Meeps"
	_render.visible = false
	_render.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Vertex-animated residents move too often to contribute useful baked GI.
	_render.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# MultiMesh transforms are written from _process, not a physics transform.
	_render.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_render)

	var rig := _meep_rig()
	var fault := String(rig.get("error", ""))
	if not fault.is_empty():
		_disable_render(fault)
		return
	var mesh := rig["mesh"] as Mesh
	var material := rig["material"] as ShaderMaterial
	var clips: Array[VatClip] = rig["clips"]
	_render_mesh_transform = rig["transform"] as Transform3D

	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	# Spatial COLOR is the mesh COLOR_0 multiplied by the MultiMesh instance
	# colour. Compatibility rendering supplies black when that stream is disabled,
	# so keep an explicit white instance stream to preserve the authored paint.
	batch.use_colors = true
	batch.use_custom_data = true
	batch.mesh = mesh
	batch.instance_count = _local.size()
	batch.visible_instance_count = 0
	_render.multimesh = batch
	_render.material_override = material
	_render.extra_cull_margin = float(rig["cull_margin"])
	_vat_clips = clips
	_render_ready = true
	_render.visible = true


## The mesh, material and prepared VAT clips every colony's residents are drawn
## with, built on first use and then shared.
##
## Loading the VAT scene, instancing it to extract its mesh, preparing four clip
## textures and validating their vertex identifiers against that mesh cost 54 ms the
## first time a city arrived and 13 ms every time after. None of it varies per city
## and nothing writes to it once built, so a returning town no longer pays for it at
## all. A non-empty "error" means the rig could not be built and residents will not
## be drawn; it is cached too, so a broken import reports once rather than per city.
static func _meep_rig() -> Dictionary:
	if not _shared_rig.is_empty():
		return _shared_rig
	_shared_rig = _build_meep_rig()
	return _shared_rig


static func _build_meep_rig() -> Dictionary:
	var packed := load(MEEP_VAT_MODEL_PATH) as PackedScene
	if packed == null:
		return {"error": "could not load Idle VAT mesh scene '%s'"
			% MEEP_VAT_MODEL_PATH}
	var extracted := _largest_render_mesh(packed)
	var mesh := extracted.get("mesh") as Mesh
	if mesh == null:
		return {"error": "Idle VAT scene contains no usable MeshInstance3D"}
	if mesh.get_surface_count() != 1:
		return {"error": ("Idle VAT mesh has %d surfaces; one surface is "
			+ "required for one batched draw") % mesh.get_surface_count()}
	var source_material := load(MEEP_SURFACE_PATH) as ShaderMaterial
	if source_material == null or source_material.shader == null:
		return {"error": "could not load Meep ShaderMaterial '%s'"
			% MEEP_SURFACE_PATH}
	if source_material.shader.resource_path != MEEP_SHADER_PATH:
		return {"error": "Meep material must use '%s', got '%s'" % [
			MEEP_SHADER_PATH, source_material.shader.resource_path]}
	var clips: Array[VatClip] = []
	for clip_index in MEEP_VAT_PATHS.size():
		var clip := load(MEEP_VAT_PATHS[clip_index]) as VatClip
		if clip == null:
			return {"error": "could not load %s VAT resource '%s'" % [
				MEEP_VAT_PREFIXES[clip_index], MEEP_VAT_PATHS[clip_index]]}
		if not clip.prepare():
			return {"error": "%s VAT metadata or texture is invalid"
				% MEEP_VAT_PREFIXES[clip_index]}
		if not clip.validate_mesh(mesh):
			return {"error": "%s VAT TEXCOORD_1 IDs do not match the Idle mesh"
				% MEEP_VAT_PREFIXES[clip_index]}
		clips.append(clip)
	# Duplicated rather than written through, so the material on disk keeps whatever
	# the editor authored and a reimport is not fighting the runtime.
	var material := source_material.duplicate(false) as ShaderMaterial
	if material == null:
		return {"error": "could not duplicate the Meep runtime material"}
	for clip_index in clips.size():
		_apply_vat_clip(material, MEEP_VAT_PREFIXES[clip_index],
			clips[clip_index])
	return {
		"error": "",
		"mesh": mesh,
		"transform": extracted.get("transform", Transform3D.IDENTITY),
		"material": material,
		"clips": clips,
		"cull_margin": _vat_cull_margin(clips),
	}


## Finds the actual render mesh rather than relying on importer child order. The
## accumulated node transform is retained so extracting the Mesh resource does
## not discard any transform authored in the GLB hierarchy.
static func _largest_render_mesh(packed: PackedScene) -> Dictionary:
	var root := packed.instantiate()
	if root == null:
		return {}
	var best: Mesh
	var best_transform := Transform3D.IDENTITY
	var most_vertices := -1
	var pending: Array[Dictionary] = [{
		"node": root,
		"transform": Transform3D.IDENTITY,
	}]
	while not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		var node := entry.get("node") as Node
		var accumulated: Transform3D = entry.get(
			"transform", Transform3D.IDENTITY)
		if node is Node3D:
			accumulated *= (node as Node3D).transform
		if node is MeshInstance3D:
			var candidate := (node as MeshInstance3D).mesh
			if candidate != null:
				var vertices := 0
				for surface in candidate.get_surface_count():
					vertices += candidate.surface_get_array_len(surface)
				if vertices > most_vertices:
					most_vertices = vertices
					best = candidate
					best_transform = accumulated
		for child in node.get_children():
			pending.append({
				"node": child,
				"transform": accumulated,
			})
	root.free()
	if best == null:
		return {}
	return {
		"mesh": best,
		"transform": best_transform,
		"vertices": most_vertices,
	}


static func _apply_vat_clip(material: ShaderMaterial, prefix: String,
		clip: VatClip) -> void:
	material.set_shader_parameter(
		StringName("%s_vat_positions" % prefix), clip.positions)
	material.set_shader_parameter(
		StringName("%s_vat_frame_count" % prefix), clip.frame_count)
	material.set_shader_parameter(
		StringName("%s_vat_fps" % prefix), clip.frames_per_second)
	material.set_shader_parameter(
		StringName("%s_vat_delta_min" % prefix), clip.delta_minimum)
	material.set_shader_parameter(
		StringName("%s_vat_delta_max" % prefix), clip.delta_maximum)


static func _vat_cull_margin(clips: Array[VatClip]) -> float:
	var margin := 0.0
	for clip in clips:
		var extent := Vector3(
			maxf(absf(clip.delta_minimum.x), absf(clip.delta_maximum.x)),
			maxf(absf(clip.delta_minimum.y), absf(clip.delta_maximum.y)),
			maxf(absf(clip.delta_minimum.z), absf(clip.delta_maximum.z)))
		margin = maxf(margin, extent.length())
	return margin + FLOOR_CLEARANCE


func _disable_render(reason: String) -> void:
	_render_ready = false
	_vat_clips.clear()
	if _render != null:
		_render.visible = false
		_render.multimesh = null
	push_error(("MeepColony VAT renderer disabled: %s. No fallback geometry "
		+ "will be drawn.") % reason)


func _raise_wall() -> void:
	_wall = MeepBoundaryWall.new()
	add_child(_wall)


func _raise_proxies() -> void:
	for _slot in PROXY_POOL:
		var proxy := MeepPickProxy.new()
		proxy.configure(self, stats.collision_radius, stats.body_height)
		add_child(proxy)
		_proxies.push_back(proxy)
	for _slot in BLOCK_PROXY_POOL:
		var proxy := MeepBlockProxy.new()
		proxy.configure(self, stats.collision_radius, stats.body_height)
		add_child(proxy)
		_block_proxies.push_back(proxy)


## Whether a Meep is anywhere the world can see it. Dead residents, cloner occupants
## and residents waiting inside their home are not drawn, lent a collider, or hit.
func _visible(index: int) -> bool:
	var state := _state[index]
	return state != State.DEAD and state != State.DEPARTED \
		and state != State.INSIDE \
		and state != State.AT_HOME \
		and state != State.AT_WORKPLACE


## Pure state-to-clip mapping for the renderer and focused tests. A worker
## waiting at the cloner door uses the relaxed Idle pose instead of Build.
static func meep_animation_clip(state: State,
		clone_wait := false) -> AnimationClip:
	match state:
		State.WALK, State.GO_HOME, State.STROLL:
			return AnimationClip.WALK
		State.FLEE:
			return AnimationClip.RUN
		State.WORK:
			return AnimationClip.IDLE if clone_wait else AnimationClip.BUILD
		_:
			return AnimationClip.IDLE


func _row_animation_clip(index: int) -> AnimationClip:
	var clone_wait := false
	if _state[index] == State.WORK and _job[index] != 0:
		var job := tasks.job(_job[index])
		clone_wait = job != null and job.kind == MeepTasks.Kind.CLONE
	return meep_animation_clip(_state[index] as State, clone_wait)


func _animation_playback_rate(clip: AnimationClip) -> float:
	var clip_index := int(clip)
	var rate := _vat_clips[clip_index].playback_speed \
		if clip_index >= 0 and clip_index < _vat_clips.size() else 1.0
	match clip:
		AnimationClip.WALK, AnimationClip.RUN:
			rate *= move_multiplier()
		AnimationClip.BUILD:
			rate *= work_multiplier()
	return maxf(rate, 0.001)


static func _render_seed(seed: int, salt: int) -> float:
	var mixed := (seed ^ salt) & 0x7fffffff
	mixed = (mixed * 1103515245 + 12345) & 0x7fffffff
	mixed = (mixed ^ (mixed >> 16)) & 0x7fffffff
	return float(mixed) / 2147483647.0


## Exact CPU payload written to one compact MultiMesh slot. Kept public because
## dummy headless rendering does not support reading instance custom data back.
func meep_render_instance_data(index: int) -> Color:
	if index < 0 or index >= _local.size():
		return Color(0.0, 0.0, 0.0, 0.0)
	var clip := _row_animation_clip(index)
	return Color(
		float(clip),
		_render_seed(_seed[index], 0x2c9277b5),
		_animation_playback_rate(clip),
		_render_seed(_seed[index], 0x68e31da4))


func _resize_render_poses() -> void:
	var preserved := mini(_render_local.size(),
		mini(_render_heading.size(), _render_height.size()))
	_render_local.resize(_local.size())
	_render_heading.resize(_local.size())
	_render_height.resize(_local.size())
	for index in range(preserved, _local.size()):
		_render_local[index] = _local[index]
		_render_heading[index] = _heading[index]
		_render_height[index] = _height[index]


func _snap_render_pose(index: int) -> void:
	if index < 0 or index >= _local.size():
		return
	_resize_render_poses()
	_render_local[index] = _local[index]
	_render_heading[index] = _heading[index]
	_render_height[index] = _height[index]


func _snap_render_poses() -> void:
	_resize_render_poses()
	for index in _local.size():
		_render_local[index] = _local[index]
		_render_heading[index] = _heading[index]
		_render_height[index] = _height[index]


## Advances presentation at render cadence. Clients already interpolate their
## authoritative targets in physics, so they copy that smooth pose directly. The
## host chases each discrete simulation destination at the same linear speed the row
## used to reach it, rather than displaying the authoritative ten-hertz jumps.
func _smooth_render(delta: float) -> void:
	if _local.is_empty() or not is_finite(delta) or delta <= 0.0:
		return
	_resize_render_poses()
	var host := _is_host()
	var snap_squared := RENDER_SNAP_DISTANCE * RENDER_SNAP_DISTANCE
	# The living, including the ones indoors: a resident waiting inside its hut is
	# not drawn, but its render pose has to keep following its real one or it glides
	# across the street on the frame it steps back out.
	for index in _active_rows:
		if not host or not _visible(index) or _detail[index] == Detail.COLD:
			_render_local[index] = _local[index]
			_render_heading[index] = _heading[index]
			_render_height[index] = _height[index]
			continue

		var target_local := _local[index]
		var gap := target_local - _render_local[index]
		if gap.length_squared() > snap_squared:
			_render_local[index] = target_local
			_render_height[index] = _height[index]
		elif not gap.is_zero_approx():
			var speed := effective_flee_speed() \
				if _state[index] == State.FLEE else effective_walk_speed()
			_render_local[index] = _render_local[index].move_toward(
				target_local, maxf(speed, 0.01) * RENDER_CATCHUP * delta)
			_render_height[index] = move_toward(
				_render_height[index], _height[index],
				RENDER_HEIGHT_SPEED * move_multiplier() * delta)
		else:
			_render_height[index] = _height[index]

		var target_heading := _heading[index]
		if target_heading.length_squared() < 0.0001:
			continue
		target_heading = target_heading.normalized()
		var shown_heading := _render_heading[index]
		if shown_heading.length_squared() < 0.0001:
			_render_heading[index] = target_heading
			continue
		var shown_angle := shown_heading.angle()
		var turn := wrapf(target_heading.angle() - shown_angle, -PI, PI)
		shown_angle += clampf(turn, -TURN_RATE * delta, TURN_RATE * delta)
		_render_heading[index] = Vector2(cos(shown_angle), sin(shown_angle))


func meep_render_local(index: int) -> Vector2:
	if index < 0 or index >= _render_local.size():
		return Vector2.ZERO
	return _render_local[index]


## Shared radial frame for render, combat, and both collider pools. Local +Y is
## the site's planet-normal up, while the authored -Z front follows travel. The
## locomotion VATs retain their baked frame order: their planted feet already move
## backward against that forward displacement.
func _meep_upright_transform(index: int, lift: float,
		use_render_pose := false) -> Transform3D:
	if index < 0 or index >= _local.size() or site == null:
		return Transform3D.IDENTITY
	var has_render_pose := use_render_pose \
		and index < _render_local.size() \
		and index < _render_heading.size() \
		and index < _render_height.size()
	var at := _render_local[index] if has_render_pose else _local[index]
	var heading := _render_heading[index] if has_render_pose else _heading[index]
	var height := _render_height[index] if has_render_pose else _height[index]
	var direction := site.direction_at(at)
	var up := direction
	var forward := site.east * heading.x + site.north * heading.y
	forward = forward - up * forward.dot(up)
	if forward.length_squared() < 0.0001:
		forward = site.north - up * site.north.dot(up)
	if forward.length_squared() < 0.0001:
		forward = site.east - up * site.east.dot(up)
	forward = forward.normalized()
	return Transform3D(
		Basis(forward.cross(up), up, -forward),
		direction * (site.planet_radius + height + lift))


func _meep_body_lift(index := -1) -> float:
	return stats.body_height * meep_scale(index) * 0.5 + FLOOR_CLEARANCE \
		if stats != null else FLOOR_CLEARANCE


## Exact grounded transform written for one VAT row.
func meep_render_transform(index: int) -> Transform3D:
	var scale_transform := Transform3D(
		Basis.IDENTITY.scaled(Vector3.ONE * meep_scale(index)), Vector3.ZERO)
	return _meep_upright_transform(index, FLOOR_CLEARANCE, true) \
		* scale_transform * _render_mesh_transform


## Upright capsule transform shared by combat, pick, and physical block proxies.
func meep_collision_transform(index: int) -> Transform3D:
	if stats == null:
		return Transform3D.IDENTITY
	return _meep_upright_transform(index, _meep_body_lift(index))


## Writes the drawn Meeps into the batch.
##
## Only the ones close enough to see, and the count is what changes rather than the
## contents: a colony nobody is at draws nothing while still being simulated, which
## is the difference between a planet of towns and a planet of draw calls.
func _draw() -> void:
	if not _render_ready or _render == null or _render.multimesh == null:
		return
	var batch := _render.multimesh
	if batch.instance_count < _local.size():
		batch.instance_count = _local.size()
	var draw_range := DRAW_RANGE * DRAW_RANGE
	var graded := _near_squared.size() == _local.size()
	var shown := 0
	for index in _visible_rows:
		if not _visible(index) or _detail[index] == Detail.COLD:
			continue
		if graded and _near_squared[index] > draw_range:
			continue
		batch.set_instance_transform(shown, meep_render_transform(index))
		batch.set_instance_color(shown, Color.WHITE)
		batch.set_instance_custom_data(
			shown, meep_render_instance_data(index))
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
	for index in _visible_rows:
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
	for slot in _proxies.size():
		var proxy := _proxies[slot]
		if slot >= nearby.size():
			proxy.set_lent(-1)
			continue
		var index := nearby[slot].y
		proxy.transform = meep_collision_transform(index)
		proxy.set_lent(index)


## Gives this peer's fixed physical pool to the nearest HOT/visible rows. Camera
## locality keeps one player's collision budget at 32 even in multiplayer; remote
## peers independently lend their own pools around their own views.
func _lend_block_proxies() -> void:
	if _block_proxies.is_empty():
		return
	var reach := BLOCK_PROXY_RANGE * BLOCK_PROXY_RANGE
	var nearby: Array[Vector2i] = []
	for index in _visible_rows:
		if not _visible(index) or _detail[index] != Detail.HOT:
			continue
		var away := _local[index].distance_squared_to(_view_eye)
		if away <= reach:
			nearby.push_back(Vector2i(roundi(away * 1000.0), index))
	nearby.sort()
	for slot in _block_proxies.size():
		var proxy := _block_proxies[slot]
		if slot >= nearby.size():
			proxy.set_lent(-1)
			continue
		var index := nearby[slot].y
		proxy.transform = meep_collision_transform(index)
		proxy.set_lent(index)


# --- Being pointed at --------------------------------------------------------

## Stable identity from colony and row only. Rows never compact after a death, and the
## same index is what clients receive, so names need no replication. Adjacent rows are
## one sibling pair and therefore deliberately share the family half.
func _generated_name(index: int) -> String:
	return generated_name_for(index, founded_seed)


static func generated_name_for(index: int, city_seed: int) -> String:
	if index < 0:
		return "Meep"
	var pair := index >> 1
	var given := GIVEN_NAMES[posmod(pair * 7 + (index & 1) * 13
		+ city_seed, GIVEN_NAMES.size())]
	var family := FAMILY_NAMES[posmod(pair + (city_seed >> 8),
		FAMILY_NAMES.size())]
	return "%s %s" % [given, family]


func meep_name(index: int) -> String:
	if index >= 0 and index < _names.size() and not _names[index].is_empty():
		return _names[index]
	return _generated_name(index)


func meep_sibling(index: int) -> int:
	if index < 0 or index >= _local.size():
		return -1
	if index < _siblings.size():
		var explicit := _siblings[index]
		if explicit >= 0 and explicit < _local.size():
			return explicit
	var legacy := index ^ 1
	return legacy if legacy < _local.size() else -1


func _active_resident(index: int) -> bool:
	return index >= 0 and index < _state.size() \
		and _state[index] != State.DEAD and _state[index] != State.DEPARTED


func settlement_founder_rows() -> PackedInt32Array:
	var rows := PackedInt32Array()
	var used: Dictionary = {}
	for index in _local.size():
		if used.has(index) or not _active_resident(index) \
				or meep_role(index) == Role.CHILD:
			continue
		var sibling := meep_sibling(index)
		if sibling < 0 or sibling == index or used.has(sibling) \
				or not _active_resident(sibling) \
				or meep_sibling(sibling) != index:
			continue
		rows.push_back(index)
		rows.push_back(sibling)
		used[index] = true
		used[sibling] = true
		if rows.size() == 6:
			break
	return rows


func settlement_founder_manifest(rows := PackedInt32Array()) -> Array:
	var selected: PackedInt32Array = rows \
		if not rows.is_empty() else settlement_founder_rows()
	if selected.size() != 6:
		return []
	var slot_by_row: Dictionary = {}
	for slot in selected.size():
		slot_by_row[selected[slot]] = slot
	var manifest: Array = []
	for row in selected:
		if not _active_resident(row):
			return []
		manifest.push_back({
			"name": meep_name(row),
			"seed": _seed[row],
			"sibling": int(slot_by_row.get(meep_sibling(row), -1)),
			"age": meep_age(row),
			"role": int(meep_role(row)),
			"parent_row": row,
			"former_deed": _deeds[row] if row < _deeds.size() else -1,
		})
	return manifest


func depart_founders(rows: PackedInt32Array, manifest: Array = []) -> bool:
	if rows.size() != 6:
		return false
	var former_by_row: Dictionary = {}
	for entry_variant: Variant in manifest:
		if entry_variant is Dictionary:
			var entry := entry_variant as Dictionary
			former_by_row[int(entry.get("parent_row", -1))] = int(
				entry.get("former_deed", -1))
	for row in rows:
		if row < 0 or row >= _state.size():
			return false
		if _state[row] != State.DEPARTED and not _active_resident(row):
			return false
	for row in rows:
		if _state[row] == State.DEPARTED:
			continue
		if _state[row] == State.INSIDE and structures != null:
			var clone_job := tasks.job(_job[row])
			if clone_job != null:
				var machine := structures.at(clone_job.subject)
				if machine != null:
					machine.inside = maxi(machine.inside - 1, 0)
		if _job[row] != 0:
			_leave_job(row)
		_stroll_paths.erase(row)
		if row < _workplaces.size():
			_workplaces[row] = -1
		_state[row] = State.DEPARTED
		_alive = maxi(_alive - 1, 0)
		if row < _deeds.size():
			while _former_deeds.size() <= row:
				_former_deeds.push_back(-1)
			_former_deeds[row] = int(former_by_row.get(row, _deeds[row]))
			_deeds[row] = -1
	_refresh_deeds()
	_town_changed = true
	return true


func release_transferred_founders(manifest: Array, wave_seed: int) -> int:
	if not _local.is_empty() or manifest.size() != 6:
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = wave_seed
	for slot in manifest.size():
		var entry: Dictionary = manifest[slot] \
			if manifest[slot] is Dictionary else {}
		var angle := TAU * float(slot) / 6.0
		var row := _add(Vector2(cos(angle), sin(angle)) * SPAWN_RING,
			int(entry.get("seed", rng.randi())))
		_names[row] = String(entry.get("name", _generated_name(row)))
		_ages[row] = maxf(float(entry.get("age", 0.0)), 0.0)
		_roles[row] = clampi(int(entry.get(
			"role", Role.HOMEBODY)), Role.BUILDER, Role.HARVESTER)
	for slot in manifest.size():
		var entry: Dictionary = manifest[slot] \
			if manifest[slot] is Dictionary else {}
		_siblings[slot] = clampi(
			int(entry.get("sibling", slot ^ 1)), -1, manifest.size() - 1)
	_refresh_deeds()
	_town_changed = true
	return _alive


func identity_snapshot() -> Dictionary:
	var durable_states := PackedByteArray()
	durable_states.resize(_state.size())
	for index in _state.size():
		durable_states[index] = _state[index] \
			if _state[index] == State.DEAD \
				or _state[index] == State.DEPARTED \
				or _state[index] == State.AT_WORKPLACE else State.IDLE
	return {
		"names": _names.duplicate(),
		"siblings": _siblings.duplicate(),
		"ages": _ages.duplicate(),
		"dead_for": _dead_for.duplicate(),
		"death_causes": _death_causes.duplicate(),
		"states": durable_states,
		"roles": _roles.duplicate(),
		"workplaces": _workplaces.duplicate(),
		"health": _health.duplicate(),
		"maximum_health": stats.maximum_health if stats != null else 24.0,
		"former_deeds": _former_deeds.duplicate(),
	}


func apply_identity_snapshot(state: Dictionary) -> void:
	var names: PackedStringArray = state.get("names", PackedStringArray())
	var siblings: PackedInt32Array = state.get("siblings", PackedInt32Array())
	var ages: PackedFloat64Array = state.get("ages", PackedFloat64Array())
	var dead_for: PackedFloat64Array = state.get(
		"dead_for", PackedFloat64Array())
	var death_causes: PackedStringArray = state.get(
		"death_causes", PackedStringArray())
	var states: PackedByteArray = state.get("states", PackedByteArray())
	var roles: PackedByteArray = state.get("roles", PackedByteArray())
	var workplaces: PackedInt32Array = state.get(
		"workplaces", PackedInt32Array())
	var health: PackedFloat32Array = state.get(
		"health", PackedFloat32Array())
	var former_deeds: PackedInt32Array = state.get(
		"former_deeds", PackedInt32Array())
	var identity_count := maxi(names.size(), siblings.size())
	identity_count = maxi(identity_count, ages.size())
	identity_count = maxi(identity_count, dead_for.size())
	identity_count = maxi(identity_count, death_causes.size())
	identity_count = maxi(identity_count, states.size())
	identity_count = maxi(identity_count, roles.size())
	identity_count = maxi(identity_count, workplaces.size())
	identity_count = maxi(identity_count, health.size())
	identity_count = maxi(identity_count, former_deeds.size())
	_begin_bulk_rows()
	while _local.size() < identity_count:
		_add(Vector2.ZERO, _local.size())
	_end_bulk_rows()
	if not names.is_empty():
		_names = names.duplicate()
	if not siblings.is_empty():
		_siblings = siblings.duplicate()
	if not ages.is_empty():
		_ages = ages.duplicate()
	if not dead_for.is_empty():
		_dead_for = dead_for.duplicate()
	if not death_causes.is_empty():
		_death_causes = death_causes.duplicate()
	if not former_deeds.is_empty():
		_former_deeds = former_deeds.duplicate()
	if not roles.is_empty():
		_roles = roles.duplicate()
	if not workplaces.is_empty():
		_workplaces = workplaces.duplicate()
	if not health.is_empty():
		_health = health.duplicate()
	while _former_deeds.size() < _local.size():
		_former_deeds.push_back(-1)
	while _names.size() < _local.size():
		_names.push_back(_generated_name(_names.size()))
	while _siblings.size() < _local.size():
		_siblings.push_back(-1)
	while _ages.size() < _local.size():
		_ages.push_back(0.0)
	while _dead_for.size() < _local.size():
		_dead_for.push_back(-1.0)
	while _death_causes.size() < _local.size():
		_death_causes.push_back("")
	while _roles.size() < _local.size():
		_roles.push_back(Role.HOMEBODY)
		_assign_adult_role(_roles.size() - 1)
	while _workplaces.size() < _local.size():
		_workplaces.push_back(-1)
	for index in _roles.size():
		if _roles[index] > Role.HARVESTER:
			_roles[index] = Role.HOMEBODY
			_assign_adult_role(index)
	if not states.is_empty():
		for index in mini(states.size(), _state.size()):
			if states[index] == State.DEAD \
					or states[index] == State.DEPARTED \
					or states[index] == State.AT_WORKPLACE \
					or _state[index] == State.DEAD:
				_state[index] = states[index]
			if _state[index] == State.DEAD:
				if _dead_for[index] < 0.0:
					_dead_for[index] = 0.0
				if _death_causes[index].is_empty():
					_death_causes[index] = "Killed in combat"
	_alive = 0
	for index in _state.size():
		if _active_resident(index):
			_alive += 1
	_refresh_rows()
	_refresh_deeds()


func meep_home(index: int) -> int:
	if index < 0 or index >= _deeds.size() or structures == null:
		return -1
	var home := _deeds[index]
	var entry := structures.at(home)
	return home if entry != null and entry.built() \
		and MeepStructures.is_residential_kind(entry.kind) else -1


func _refresh_deeds() -> void:
	if structures == null:
		return
	var changed := false
	while _deeds.size() < _local.size():
		_deeds.push_back(-1)
		changed = true
	# A complete sibling pair is one household. If an older snapshot or a
	# temporarily odd vacancy split it, release both claims and reassign atomically.
	for first in range(0, _local.size(), 2):
		var second := first + 1
		if second < _local.size() and _active_resident(first) \
				and _active_resident(second) \
				and _deeds[first] != _deeds[second]:
			changed = changed or _deeds[first] >= 0 or _deeds[second] >= 0
			_deeds[first] = -1
			_deeds[second] = -1
	var occupancy: Dictionary = {}
	for index in _local.size():
		if not _active_resident(index):
			changed = changed or _deeds[index] != -1
			_deeds[index] = -1
			continue
		var home := _deeds[index]
		var entry := structures.at(home)
		if entry == null or not entry.built() \
				or not MeepStructures.is_residential_kind(entry.kind):
			changed = changed or _deeds[index] != -1
			_deeds[index] = -1
			continue
		occupancy[home] = int(occupancy.get(home, 0)) + 1
	# Assign stable sibling pairs together whenever one residence has two vacancies.
	# The two cursors resume each size of search past the houses it has already
	# filled; see [method MeepStructures.first_residential_vacancy].
	var scanned_for_one := 0
	var scanned_for_pair := 0
	for first in range(0, _local.size(), 2):
		var members := PackedInt32Array()
		for index in [first, first + 1]:
			if index < _local.size() and _active_resident(index) \
					and _deeds[index] < 0:
				members.push_back(index)
		if members.is_empty():
			continue
		var paired := members.size() > 1
		var home := structures.first_residential_vacancy(occupancy,
			members.size(),
			scanned_for_pair if paired else scanned_for_one)
		if home < 0:
			break
		if paired:
			scanned_for_pair = home
		else:
			scanned_for_one = home
		for index in members:
			var entry := structures.at(home)
			if entry == null or int(occupancy.get(home, 0)) \
					>= entry.resident_slots:
				home = structures.first_residential_vacancy(
					occupancy, 1, scanned_for_one)
				if home < 0:
					break
				scanned_for_one = home
			_deeds[index] = home
			changed = true
			occupancy[home] = int(occupancy.get(home, 0)) + 1
	if changed:
		_town_changed = true


func deed_snapshot() -> PackedInt32Array:
	return _deeds.duplicate()


func apply_deed_snapshot(state: PackedInt32Array) -> void:
	_deeds = state.duplicate()
	while _deeds.size() < _local.size():
		_deeds.push_back(-1)


func home_occupancy(structure: int) -> int:
	var occupied := 0
	for index in _state.size():
		if _active_resident(index) and meep_home(index) == structure:
			occupied += 1
	return occupied


## The live report on a lent building collider.
func structure_summary(structure: int) -> String:
	var entry := structures.at(structure) if structures != null else null
	if entry == null:
		return "Building"
	if entry.kind == MeepStructures.Kind.HAT_HOUSE:
		return "Open Hat House" if entry.built() \
			else "Hat House - %d%% complete" % roundi(entry.progress * 100.0)
	if entry.kind == MeepStructures.Kind.ABILITIES_HOUSE:
		return "Open Abilities House" if entry.built() \
			else "Abilities House - %d%% complete" % roundi(
				entry.progress * 100.0)
	if entry.kind == MeepStructures.Kind.BIOMASS_HARVESTER:
		return "Open Biomass Harvester" if entry.built() \
			else "Biomass Harvester - %d%% complete" % roundi(
				entry.progress * 100.0)
	if entry.kind == MeepStructures.Kind.CLONER:
		return "Meep Cloner - %d/%d inside" % [entry.inside, CLONE_CREW]
	if not MeepStructures.is_residential_kind(entry.kind):
		return MeepStructures.plan_of(entry.kind).title
	var residents: Array[String] = []
	for owner in _local.size():
		if _active_resident(owner) and meep_home(owner) == structure:
			residents.push_back(meep_name(owner))
	var plan := MeepStructures.plan_of(entry.kind)
	if entry.kind != MeepStructures.Kind.HUT:
		return "%s - %d/%d residents - Open resident list" % [
			plan.title, residents.size(), entry.resident_slots]
	var shown := residents.slice(0, mini(residents.size(), 4))
	var resident_text := ", ".join(shown) if not shown.is_empty() else "Vacant"
	if residents.is_empty():
		var former := _former_owners_of(structure)
		if not former.is_empty():
			resident_text += " - Formerly %s" % " & ".join(former)
	if residents.size() > shown.size():
		resident_text += " +%d more" % (residents.size() - shown.size())
	return "%s - %d floors - Occupied %d/%d - %s" % [
		plan.title, entry.completed_floors, residents.size(),
		entry.resident_slots, resident_text]


func _former_owners_of(structure: int) -> Array[String]:
	var former: Array[String] = []
	for index in _state.size():
		if _state[index] == State.DEPARTED \
				and index < _former_deeds.size() \
				and _former_deeds[index] == structure:
			former.push_back(meep_name(index))
	return former


func resident_report(structure: int) -> Dictionary:
	var entry := structures.at(structure) if structures != null else null
	if entry == null or not entry.built() \
			or not MeepStructures.is_residential_kind(entry.kind):
		return {}
	var residents: Array[String] = []
	for index in _state.size():
		if _active_resident(index) and meep_home(index) == structure:
			residents.push_back(meep_name(index))
	return {
		"title": MeepStructures.plan_of(entry.kind).title,
		"floors": entry.completed_floors,
		"capacity": entry.resident_slots,
		"residents": residents,
		"former_owners": _former_owners_of(structure),
	}


## Interaction routing is local, while every purchase request separately
## revalidates this completed structure and distance on the host.
func interact_structure(structure: int, player: OnlinePlayer) -> void:
	var entry := structures.at(structure) if structures != null else null
	if entry == null or not entry.built():
		inspect_structure(structure, player)
		return
	match entry.kind:
		MeepStructures.Kind.HAT_HOUSE:
			player.open_hat_house(site_id, structure)
		MeepStructures.Kind.ABILITIES_HOUSE:
			player.open_abilities_house(site_id, structure)
		MeepStructures.Kind.BIOMASS_HARVESTER:
			player.open_biomass_harvester(site_id, structure)
		_:
			if MeepStructures.is_residential_kind(entry.kind) \
					and entry.kind != MeepStructures.Kind.HUT:
				player.open_resident_list(site_id, structure)
			else:
				inspect_structure(structure, player)


func specialty_interaction_valid(structure: int, expected_kind: int,
		player_position: Vector3, max_distance: float) -> bool:
	var entry := structures.at(structure) if structures != null else null
	return entry != null and entry.built() and entry.kind == expected_kind \
		and player_position.is_finite() \
		and structures.world_centre(structure).distance_to(player_position) \
			<= maxf(max_distance, 0.0)


func meep_activity(index: int) -> String:
	if index < 0 or index >= _local.size():
		return "Unknown"
	var doing := "Idle"
	var job := tasks.job(_job[index])
	match _state[index] as State:
		State.WALK:
			doing = _errand(job) if job != null else "Walking"
		State.WORK:
			doing = _at_work(job) if job != null else "Working"
		State.INSIDE:
			doing = "In the cloner"
		State.GO_HOME:
			doing = "Walking home"
		State.AT_HOME:
			doing = "At home"
		State.STROLL:
			doing = "Going for a walk"
		State.FLEE:
			doing = "Fleeing"
		State.DEAD:
			doing = "Dead"
		State.DEPARTED:
			doing = "Departed"
		State.AT_WORKPLACE:
			doing = "Staffing the biomass harvester"
		_:
			doing = "Idle"
	return doing


func meep_age(index: int) -> float:
	return maxf(float(_ages[index]), 0.0) \
		if index >= 0 and index < _ages.size() else 0.0


func meep_role(index: int) -> Role:
	if index < 0 or index >= _roles.size():
		return Role.HOMEBODY
	return clampi(int(_roles[index]), Role.CHILD, Role.HARVESTER) as Role


static func role_name(role: Role) -> String:
	match role:
		Role.CHILD:
			return "Child"
		Role.BUILDER:
			return "Builder"
		Role.HARVESTER:
			return "Harvester"
		_:
			return "Homebody"


func meep_scale(index: int) -> float:
	if meep_role(index) != Role.CHILD:
		return 1.0
	return lerpf(CHILD_START_SCALE, 1.0,
		clampf(meep_age(index) / CHILDHOOD_SECONDS, 0.0, 1.0))


func role_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(Role.size())
	for index in _roles.size():
		if _active_resident(index):
			counts[meep_role(index)] += 1
	return counts


## The live one-line report the prompt plate shows over a Meep.
func meep_summary(index: int) -> String:
	if index < 0 or index >= _local.size():
		return "Meep"
	var doing := meep_activity(index)
	return "%s - %s - %d/%d" % [meep_name(index), doing, roundi(_health[index]),
		roundi(stats.maximum_health)]


## Where a Meep is going, in the words a player reading the prompt plate would use.
func _errand(job: MeepTasks.Job) -> String:
	match job.kind:
		MeepTasks.Kind.MINE:
			return "Off to fell a tree"
		MeepTasks.Kind.BUILD:
			return "Off to the site"
		MeepTasks.Kind.UPGRADE:
			return "Off to add a floor"
		MeepTasks.Kind.ROAD:
			return "Off to pave"
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
		MeepTasks.Kind.UPGRADE:
			return "Adding a floor"
		MeepTasks.Kind.ROAD:
			return "Paving"
		MeepTasks.Kind.CLONE:
			return "Waiting at the cloner"
		_:
			return "Working"


func inspect(index: int, player: Node) -> void:
	meep_inspected.emit(index, player)


func inspect_structure(index: int, player: Node) -> void:
	structure_inspected.emit(index, player)


## World-space centre of one upright Meep body. Projectile queries, damage, and
## physical proxy placement all use this same body-height-based point.
func meep_combat_position(index: int) -> Vector3:
	if index < 0 or index >= _local.size() or _planet == null \
			or site == null or stats == null:
		return Vector3.ZERO
	return _planet.to_global(site.point_at(_local[index],
		_height[index] + _meep_body_lift(index)))


func meep_position(index: int) -> Vector3:
	return meep_combat_position(index)


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
##
## Picks up finished routing work first, exactly as the physics tick does. A caller
## stepping the town by hand has usually turned the physics tick off to keep the
## elapsed time it controls the only elapsed time there is, and a colony that never
## collects its flow fields is a colony whose settlers cannot find their way to work.
func step_simulation(seconds: float) -> void:
	if _is_host():
		_collect_fields()
		_simulate(maxf(seconds, 0.0))


# --- Damage ------------------------------------------------------------------

func _meep_body_radius(index := -1) -> float:
	if stats == null:
		return 0.0
	var scale := meep_scale(index)
	return clampf(stats.collision_radius * scale, 0.05,
		maxf(stats.body_height * scale * 0.5, 0.05))


func _meep_body_half_axis(index := -1) -> float:
	return maxf(stats.body_height * meep_scale(index) * 0.5 \
		- _meep_body_radius(index), 0.0) \
		if stats != null else 0.0


func _meep_body_up(index: int) -> Vector3:
	if index < 0 or index >= _local.size() or _planet == null or site == null:
		return Vector3.UP
	var world_up := _planet.global_basis * site.direction_at(_local[index])
	return world_up.normalized() if world_up.length_squared() > 0.000001 \
		else Vector3.UP


## Three overlapping spheres describe the same upright capsule used by the proxy
## pool. The spacing is never wider than their diameter, so a narrow strike can
## meet feet, torso, or head without broadening the colony's town-wide bounds.
func _meep_body_points(index: int) -> Array[Vector3]:
	var centre := meep_combat_position(index)
	var half_axis := _meep_body_half_axis(index)
	if half_axis <= 0.0001:
		return [centre]
	var up := _meep_body_up(index)
	return [centre - up * half_axis, centre, centre + up * half_axis]


func _nearest_meep_axis_point(index: int, at: Vector3) -> Vector3:
	var centre := meep_combat_position(index)
	var half_axis := _meep_body_half_axis(index)
	if half_axis <= 0.0001:
		return centre
	var up := _meep_body_up(index)
	return centre + up * clampf((at - centre).dot(up), -half_axis, half_axis)


static func _segment_sphere_entry(from: Vector3, to: Vector3,
		centre: Vector3, radius: float) -> float:
	if not from.is_finite() or not to.is_finite() or not centre.is_finite():
		return -1.0
	var along := to - from
	var span := along.length_squared()
	var offset := from - centre
	var radius_squared := maxf(radius, 0.0) * maxf(radius, 0.0)
	if offset.length_squared() <= radius_squared:
		return 0.0
	if span < 0.000001:
		return -1.0
	var b := 2.0 * offset.dot(along)
	var c := offset.length_squared() - radius_squared
	var discriminant := b * b - 4.0 * span * c
	if discriminant < 0.0:
		return -1.0
	var entry := (-b - sqrt(discriminant)) / (2.0 * span)
	return entry if entry >= 0.0 and entry <= 1.0 else -1.0


## Stable per-row target data for actor AI. Rows are never compacted, so a
## hostile creature can keep following this index while the Meep moves; hidden
## or dead residents deliberately become invalid targets.
func combat_target_position(index: int) -> Vector3:
	if index < 0 or index >= _local.size() or not _visible(index):
		return Vector3(INF, INF, INF)
	return meep_combat_position(index)


func combat_target_velocity(index: int) -> Vector3:
	if index < 0 or index >= _local.size() or not _visible(index) \
			or _planet == null or site == null:
		return Vector3.ZERO
	var speed := 0.0
	match _state[index] as State:
		State.WALK, State.GO_HOME, State.STROLL:
			speed = effective_walk_speed()
		State.FLEE:
			speed = effective_flee_speed()
	if speed <= 0.0 or _heading[index].length_squared() < 0.000001:
		return Vector3.ZERO
	var direction := site.direction_at(_local[index])
	var along := site.east * _heading[index].x \
		+ site.north * _heading[index].y
	along -= direction * along.dot(direction)
	if along.length_squared() < 0.000001:
		return Vector3.ZERO
	return (_planet.global_basis * along.normalized()).normalized() * speed


func combat_target_radius(index: int) -> float:
	return _meep_body_radius(index) \
		if index >= 0 and index < _local.size() and _visible(index) else 0.0


## Optional combat-target seam for swept point attacks. It scans only when an
## active attack asks and returns the first actual visible row along the beam,
## never the colony's coarse broad-phase centre.
func combat_target_along(from: Vector3, to: Vector3,
		sweep_radius: float) -> Dictionary:
	if _planet == null or stats == null or not from.is_finite() \
			or not to.is_finite():
		return {}
	var best: Dictionary = {}
	var best_distance := INF
	var span := from.distance_to(to)
	for index in _local.size():
		if not _visible(index):
			continue
		var expanded := maxf(sweep_radius, 0.0) + _meep_body_radius(index)
		for body_point in _meep_body_points(index):
			var entry := _segment_sphere_entry(
				from, to, body_point, expanded)
			if entry < 0.0:
				continue
			var distance := span * entry
			if distance >= best_distance:
				continue
			best_distance = distance
			best = {
				"row": index,
				"point": from.lerp(to, entry),
				"body_point": body_point,
				"distance": distance,
			}
	return best


## Optional combat-target seam for contact attacks. Reach is measured from the
## caller's point to the outside of each upright capsule; the nearest visible row
## wins, with stable row order breaking exact ties.
func combat_target_within(at: Vector3, reach: float) -> Dictionary:
	if _planet == null or stats == null or not at.is_finite():
		return {}
	var best: Dictionary = {}
	var best_distance := INF
	var allowed := maxf(reach, 0.0)
	# Same reasoning as [method apply_damage]: every hostile creature in the world
	# asks every city whether it holds a target, so the answer "not this city" has
	# to cost one distance rather than one pass over the roster.
	if at.distance_to(combat_position()) > allowed + combat_radius():
		return {}
	for index in _visible_rows:
		var body_radius := _meep_body_radius(index)
		var body_point := _nearest_meep_axis_point(index, at)
		var distance := maxf(at.distance_to(body_point) - body_radius, 0.0)
		if distance > allowed or distance >= best_distance:
			continue
		best_distance = distance
		best = {
			"row": index,
			"point": body_point,
			"body_point": body_point,
			"distance": distance,
		}
	return best


func _accepts_meep_damage(hit: DamageHit) -> bool:
	if hit == null or not _is_host() or _planet == null or stats == null:
		return false
	return (hit.faction == DamageHit.Faction.ENEMY
			or hit.faction == DamageHit.Faction.PLAYER) \
		and hit.target_peer <= 0 \
		and is_finite(hit.amount) and hit.amount > 0.0 \
		and hit.origin.is_finite() and hit.toward.is_finite()


## The colony answers for everyone in it.
##
## [method DamageHit.apply_to_combatants] does not test geometry — it filters by
## faction and hands the volume over — so one node in the group can stand for a
## whole population and sort out who was actually in the blast itself. This is the
## same arrangement [GroundCover] uses to take a hit on behalf of three hundred
## thousand plants.
func apply_damage(hit: DamageHit) -> float:
	if not _accepts_meep_damage(hit):
		return 0.0
	# One sphere test for the whole town before any pass over its population.
	# [method DamageHit.apply_to_combatants] tests faction rather than geometry, so
	# every attack anywhere in the world is offered to every city on the planet: a
	# charging rhino was walking a thousand rows of four cities fifty times a
	# second to find out that it had swung at nobody. The margin already built into
	# [method combat_radius] is what makes rejecting here identical to rejecting
	# row by row.
	if hit.damage_for_sphere(combat_position(), combat_radius()) <= 0.0:
		return 0.0
	var dealt := 0.0
	for index in _visible_rows:
		dealt += _apply_damage_to_row(index, hit)
	if dealt > 0.0:
		_flush_deaths()
	return dealt


## Exact-row counterpart used only with a row returned by one of the optional
## combat-target queries. Point projectiles and contacts therefore cannot splash
## a second resident merely because the colony represents both in the combat group.
func apply_damage_to_row(index: int, hit: DamageHit) -> float:
	if not _accepts_meep_damage(hit):
		return 0.0
	var dealt := _apply_damage_to_row(index, hit)
	if dealt > 0.0:
		_flush_deaths()
	return dealt


func _apply_damage_to_row(index: int, hit: DamageHit) -> float:
	if index < 0 or index >= _local.size() or not _visible(index):
		return 0.0
	var body_radius := _meep_body_radius(index)
	var half_axis := _meep_body_half_axis(index)
	var centre := meep_combat_position(index)
	# One sphere around the whole standing body before the three that describe it.
	# The three lie inside this one, so nothing it rejects could have been touched by
	# them, and a horn swung at one Meep in a crowded street rejects its neighbours
	# for a subtraction each instead of building three points and testing all of them.
	# A charging rhino inside a claim was walking the roster fifty times a second.
	if hit.damage_for_sphere(centre, body_radius + half_axis) <= 0.0:
		return 0.0
	var quoted := 0.0
	for body_point in _meep_body_points(index):
		quoted = maxf(quoted,
			maxf(hit.damage_for_sphere(body_point, body_radius), 0.0))
	var amount := minf(quoted, _health[index])
	if amount <= 0.0:
		return 0.0
	_health[index] -= amount
	_invalidate_report_roster()
	_publish_meep_damage_number(index, amount, hit)
	if _health[index] <= 0.0:
		_kill(index, hit)
		return amount
	# Being hit is how a colony learns anything. Running is all a Meep does with
	# that knowledge; the hostile actor independently follows this stable row.
	_stroll_paths.erase(index)
	if _job[index] != 0:
		tasks.release(_job[index])
		_job[index] = 0
	_state[index] = State.FLEE
	_timer[index] = 4.0
	var away := _local[index] - _site_local_of(hit.origin)
	if away.length_squared() < 0.000001:
		var source := hit.source_node(self)
		var source_point := Vector3.ZERO
		if source != null and source.has_method(&"combat_position"):
			var source_value: Variant = source.call(&"combat_position")
			if source_value is Vector3:
				source_point = source_value as Vector3
		elif source is Node3D:
			source_point = (source as Node3D).global_position
		if source_point.is_finite() and not source_point.is_zero_approx():
			away = _local[index] - _site_local_of(source_point)
	if away.length_squared() < 0.000001:
		var angle := TAU * _render_seed(_seed[index], 0x1f123bb5)
		away = Vector2(cos(angle), sin(angle))
	else:
		away = away.normalized()
	_goal[index] = _local[index] + away * 24.0
	_since[index] = HOT_INTERVAL
	return amount


## One exact row owns its number rather than the colony's town-wide combat bounds.
## The event is cosmetic and unordered: losing one under network congestion must
## never hold up authoritative health, movement, or construction.
func _publish_meep_damage_number(index: int, amount: float,
		hit: DamageHit) -> void:
	if index < 0 or index >= _local.size() or amount <= 0.0 or hit == null:
		return
	var event := DamageNumberEvent.new()
	event.amount = amount
	event.world_position = meep_combat_position(index) \
		+ _meep_body_up(index) * stats.body_height * 0.62
	event.incoming = hit.faction == DamageHit.Faction.ENEMY
	event.source_peer = maxi(hit.source_peer, 0)
	event.target_key = "%s:%d" % [String(site_id), index]
	var wire := event.to_wire()
	if multiplayer.has_multiplayer_peer() \
			and not multiplayer.get_peers().is_empty():
		_apply_meep_damage_number.rpc(index, wire)
	else:
		_apply_meep_damage_number(index, wire)


@rpc("authority", "call_local", "unreliable")
func _apply_meep_damage_number(index: int, wire: Dictionary) -> void:
	if index < 0:
		return
	var event := DamageNumberEvent.from_wire(wire)
	if event.amount <= 0.0 or event.target_key.is_empty():
		return
	meep_damage_number.emit(index, event)
	for player_variant: Variant in get_tree().get_nodes_in_group(
			&"network_players"):
		var player := player_variant as Node
		if player == null or not DamageHit.in_same_world(self, player) \
				or not player.has_method(&"combat_peer_id") \
				or int(player.call(&"combat_peer_id")) \
					!= multiplayer.get_unique_id() \
				or not player.has_method(&"combat_feedback"):
			continue
		var feedback := player.call(&"combat_feedback") as CombatFeedback
		if feedback != null:
			feedback.world_damage(event)
		return


func _death_cause_for(hit: DamageHit) -> String:
	if hit == null:
		return "Killed in combat"
	var attacker := hit.attacker_name(self).strip_edges()
	var ability := hit.ability_display_name().strip_edges()
	if not attacker.is_empty() and not ability.is_empty():
		return "Killed by %s using %s" % [attacker, ability]
	if not attacker.is_empty():
		return "Killed by %s" % attacker
	if not ability.is_empty():
		return "Killed by %s" % ability
	return "Killed in combat"


func _kill(index: int, hit: DamageHit = null) -> void:
	if index < 0 or index >= _state.size() or _state[index] == State.DEAD:
		return
	if _state[index] == State.INSIDE and structures != null:
		var clone_job := tasks.job(_job[index])
		if clone_job != null:
			var machine := structures.at(clone_job.subject)
			if machine != null:
				machine.inside = maxi(machine.inside - 1, 0)
	_stroll_paths.erase(index)
	if index < _workplaces.size():
		_workplaces[index] = -1
	_state[index] = State.DEAD
	_health[index] = 0.0
	_dead_for[index] = 0.0
	_invalidate_report_roster()
	if hit != null or _death_causes[index].is_empty():
		_death_causes[index] = _death_cause_for(hit)
	_alive = maxi(_alive - 1, 0)
	if index < _deeds.size():
		_deeds[index] = -1
	if _bulk_rows == 0:
		_refresh_deeds()
	if _job[index] != 0:
		tasks.release(_job[index])
		_job[index] = 0
	if _is_host():
		_deaths.push_back(index)
	meep_died.emit(index)


func combat_faction() -> int:
	return DamageHit.Faction.PLAYER


## Meeps remain allied for enemy targeting, but an actual player attack may hurt
## the exact resident it reaches.
func combat_accepts_player_damage() -> bool:
	return true


## A broad colony hit is resolved into per-row damage numbers here. The attacking
## player must not also draw one aggregate number at the city centre.
func combat_reports_own_damage_feedback() -> bool:
	return true


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

## Stable city roster. Departed founders belong to their child settlement and are
## intentionally absent here; dead rows remain as the city's permanent memorial.
func meep_roster() -> Array:
	var living: Array = []
	var memorial: Array = []
	for index in _state.size():
		if _state[index] == State.DEPARTED:
			continue
		var sibling := meep_sibling(index)
		var home_name := "Unhoused"
		var home := meep_home(index)
		if home >= 0 and structures != null:
			var residence := structures.at(home)
			if residence != null:
				home_name = "%s #%d" % [
					MeepStructures.plan_of(residence.kind).title, home + 1]
		var row := {
			"index": index,
			"name": meep_name(index),
			"age_seconds": meep_age(index),
			"status": "dead" if _state[index] == State.DEAD else "alive",
			"health": maxf(float(_health[index]), 0.0),
			"maximum_health": stats.maximum_health if stats != null else 0.0,
			"type": role_name(meep_role(index)),
			"role": int(meep_role(index)),
			"tile_stats": {
				"TYPE": role_name(meep_role(index)),
				"HEALTH": "%d / %d" % [
					roundi(maxf(float(_health[index]), 0.0)),
					roundi(stats.maximum_health if stats != null else 0.0)],
			},
			"activity": meep_activity(index),
			"home": home_name,
			"sibling": meep_name(sibling) if sibling >= 0 else "None",
			"death_seconds_ago": maxf(float(_dead_for[index]), 0.0),
			"death_cause": _death_causes[index] if not \
				_death_causes[index].is_empty() else "Killed in combat",
		}
		if _state[index] == State.DEAD:
			memorial.push_back(row)
		else:
			living.push_back(row)
	if living.size() + memorial.size() <= ROSTER_SORT_LIMIT:
		living.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("name", "")).naturalnocasecmp_to(
				String(b.get("name", ""))) < 0)
		memorial.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_when := float(a.get("death_seconds_ago", 0.0))
			var b_when := float(b.get("death_seconds_ago", 0.0))
			return a_when < b_when if not is_equal_approx(a_when, b_when) \
				else int(a.get("index", 0)) < int(b.get("index", 0)))
	living.append_array(memorial)
	return living


func _reported_meep_roster() -> Array:
	var now := Time.get_ticks_msec()
	if _report_roster_cache.is_empty() \
			or _report_roster_source_size != _state.size() \
			or now >= _report_roster_next_msec:
		_report_roster_cache = meep_roster()
		_report_roster_source_size = _state.size()
		_report_roster_next_msec = now + REPORT_ROSTER_INTERVAL_MS
		_report_roster_revision += 1
	return _report_roster_cache


func _invalidate_report_roster() -> void:
	_report_roster_next_msec = 0


## What the city panel shows.
func report() -> Dictionary:
	return {
		"founded": true,
		"site_id": String(site_id),
		"display_name": display_name,
		"parent_site_id": String(parent_site_id),
		"can_rename": parent_site_id != &"",
		"tier": tier,
		"tier_full": _current_tier_full(),
		"tier_space_exhausted": current_tier_space_exhausted(),
		"tier_allocated_flags": tier_allocated_flags,
		"tier_complete_flags": tier_complete_flags,
		"structure_target": tier_zero_structure_target() if tier == 0 else 0,
		"population_ceiling": population_ceiling(),
		"current_tier_development_units": current_tier_development_units(),
		"current_tier_capacity_target": current_tier_capacity_target(),
		"district_block_size": TIER_BLOCK_SIZES[tier],
		"settlers": _alive,
		"meeps": _reported_meep_roster(),
		"meep_roster_revision": _report_roster_revision,
		"role_counts": role_counts(),
		"staffed_harvesters": staffed_harvester_count(),
		"housing": housing_capacity(),
		"resources": resources,
		"committed": committed,
		"build_speed_level": build_speed_level,
		"move_speed_level": move_speed_level,
		"claim_radius": claim_radius,
		"max_claim_radius": MAX_CLAIM_RADIUS,
		"city_style": city_plan.style_name() \
			if city_plan != null and city_plan.generated() else "Planning",
		"districts_active": city_plan.active_districts \
			if city_plan != null and city_plan.generated() else 0,
		"districts_total": city_plan.district_count() \
			if city_plan != null and city_plan.generated() else 0,
		"border_expanding": city_plan.has_pending_expansion(claim_radius) \
			if city_plan != null and city_plan.generated() else false,
		"city_lots": city_plan.lot_summary() \
			if city_plan != null and city_plan.generated() else {},
		"next_hut_lots": city_plan.availability_summary(
			MeepStructures.Kind.HUT) \
				if city_plan != null and city_plan.generated() else {},
		"expansion_rate": expansion_rate(),
		"purchase_offers": city_purchase_offers(),
		"purchased_flags": purchased_flags,
		"requested_flags": requested_flags,
		"built_flags": built_flags,
		"abilities_house_upgraded": abilities_house_stats_unlocked(),
		"harvester_built": biomass_harvester_index() >= 0,
		"harvester_rate_level": harvester_rate_level,
		"harvester_rate": harvester_rate(),
		"harvester_lifetime": harvester_lifetime,
		"harvester_upgrade": harvester_upgrade_offer(),
		"settlement_tokens": settlement_tokens,
		"settlement_armed_owner": settlement_armed_owner,
		"departed": _state.count(State.DEPARTED),
		"claimed_cells": claim.count if claim != null else 0,
		"claimed_area": claim.area() if claim != null else 0.0,
		"wall_segments": _wall.segment_count() if _wall != null else 0,
		"ground_ready": _ground_ready,
		"structures": structures.built_count() if structures != null else 0,
		"raising": structures.count() - structures.built_count() \
			if structures != null else 0,
		"road_cells": roads.cell_count() if roads != null else 0,
		"bridge_cells": roads.surface_cell_count(
			MeepRoads.SurfaceKind.BRIDGE) if roads != null else 0,
		"ramp_cells": roads.surface_cell_count(
			MeepRoads.SurfaceKind.RAMP) if roads != null else 0,
		"dock_cells": roads.surface_cell_count(
			MeepRoads.SurfaceKind.DOCK) if roads != null else 0,
		"paving": roads.unfinished_count() if roads != null else 0,
		"cloners": structures.count_of(MeepStructures.Kind.CLONER, true) \
			if structures != null else 0,
		"settlement_ship_cloner": _settlement_ship_cloner >= 0,
		"houses": structures.count_of(MeepStructures.Kind.HUT, true) \
			if structures != null else 0,
		"townhouses": structures.count_of(
			MeepStructures.Kind.TOWNHOUSE, true) if structures != null else 0,
		"mid_rises": structures.count_of(
			MeepStructures.Kind.MID_RISE, true) if structures != null else 0,
		"skyscrapers": structures.count_of(
			MeepStructures.Kind.SKYSCRAPER, true) if structures != null else 0,
		"mega_skyscrapers": structures.count_of(
			MeepStructures.Kind.MEGA_SKYSCRAPER, true) \
				if structures != null else 0,
		"super_skyscrapers": structures.count_of(
			MeepStructures.Kind.SUPER_SKYSCRAPER, true) \
				if structures != null else 0,
		"arcologies": structures.count_of(
			MeepStructures.Kind.ARCLOGY, true) \
				if structures != null else 0,
		"dock_huts": structures.count_of(
			MeepStructures.Kind.DOCK_HUT, true) if structures != null else 0,
		"timber": standing_timber(),
		"doing": _busiest(),
	}


static func moderated_settlement_name(wanted: String, fallback: String) -> String:
	var cleaned := ""
	for character in wanted.strip_edges():
		if character == " " or character == "-" or character == "'" \
				or (character >= "0" and character <= "9") \
				or character.to_lower() != character.to_upper():
			cleaned += character
		if cleaned.length() >= 24:
			break
	cleaned = " ".join(cleaned.split(" ", false))
	return cleaned if not cleaned.is_empty() else fallback


func rename_settlement(wanted: String) -> bool:
	if not _is_host() or parent_site_id == &"":
		return false
	var fallback := display_name if not display_name.is_empty() \
		else String(site_id).capitalize()
	var moderated := moderated_settlement_name(wanted, fallback)
	if moderated == display_name:
		return true
	display_name = moderated
	_progression_changed = true
	return true


func tier_zero_full() -> bool:
	return (tier_complete_flags & 1) != 0


func current_tier_space_exhausted() -> bool:
	return (tier_allocated_flags & (1 << tier)) != 0


func current_tier_full() -> bool:
	return _current_tier_full()


func _mark_tier_allocated(for_tier: int) -> void:
	var bit := 1 << clampi(for_tier, 0, MAX_CITY_TIER)
	if (tier_allocated_flags & bit) != 0:
		return
	tier_allocated_flags |= bit
	if for_tier == 0:
		_tier_zero_space_full = true
	_town_changed = true
	_progression_changed = true


func _refresh_current_tier_completion() -> void:
	if structures == null:
		return
	if structures.residential_capacity(false) >= population_ceiling():
		_mark_tier_allocated(tier)
	var completed_tier := tier
	var bit := 1 << completed_tier
	if (tier_complete_flags & bit) != 0 or not _current_tier_ready():
		return
	tier_complete_flags |= bit
	if completed_tier == 0:
		_tier_zero_complete = true
	# Architectural tiers advance from completed city development, not from a
	# boundary purchase. The continuously growing claim is untouched.
	if completed_tier < MAX_CITY_TIER:
		tier = completed_tier + 1
		structures.clear_exhaustion()
		_set_commission_waiting_for_space(false)
	_town_changed = true
	_progression_changed = true


func _current_tier_ready() -> bool:
	var bit := 1 << tier
	if (tier_allocated_flags & bit) == 0 or structures == null or roads == null \
			or _raising() or roads.unfinished_count() > 0 \
			or not tasks.all_of(MeepTasks.Kind.UPGRADE).is_empty():
		return false
	for structure in structures.count():
		if not _structure_has_completed_road_access(structure):
			return false
	return true


func _structure_has_completed_road_access(structure: int) -> bool:
	if roads == null or structures == null or grid == null:
		return false
	if roads.has_subject(structure) or structure == _settlement_ship_cloner:
		return true
	for cell in structures.access_cells(structure):
		if grid.has_flag(cell, MeepGrid.FLAG_ROAD):
			return true
	return false


func tier_zero_space_exhausted() -> bool:
	return (tier_allocated_flags & 1) != 0


func apply_tier_zero_space_exhausted(exhausted: bool) -> void:
	_tier_zero_space_full = exhausted
	if exhausted:
		tier_allocated_flags |= 1
	else:
		tier_allocated_flags &= ~1


func apply_tier_zero_complete(complete: bool) -> void:
	_tier_zero_complete = complete
	if complete:
		tier_allocated_flags |= 1
		tier_complete_flags |= 1
		if tier == 0:
			tier = 1
			if structures != null:
				structures.clear_exhaustion()
	else:
		tier_complete_flags &= ~1


## Structure/form state is an additive sidecar while the job board is a separate
## snapshot. Reconnect their IDs after both have loaded so commission planning sees
## the restored build or tower crew instead of posting a duplicate job.
func reconnect_restored_tasks() -> void:
	if structures == null or tasks == null:
		return
	for index in structures.count():
		var entry := structures.at(index)
		if entry != null:
			entry.job = 0
	for job in tasks.all_of(MeepTasks.Kind.BUILD):
		if job.subject < 0 or job.subject >= structures.count():
			continue
		var entry := structures.at(job.subject)
		if entry != null and not entry.built():
			entry.job = job.id
	for job in tasks.all_of(MeepTasks.Kind.UPGRADE):
		if job.subject < 0 or job.subject >= structures.count():
			continue
		var entry := structures.at(job.subject)
		if entry != null and entry.upgrading():
			entry.job = job.id


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
	var commission := _next_commission_purchase()
	if commission >= 0:
		if not commissioned_work_unlocked(_alive):
			return "Commission queued for %d settlers" % COMMISSION_POPULATION
		if _commission_waiting_for_space:
			return "Commission waiting for border space"
		var commissioned_kind := _commission_structure_kind(commission)
		if commissioned_kind >= 0:
			return "Prioritising %s" % MeepStructures.plan_of(
				commissioned_kind).title
	if structures != null and structures.count() > structures.built_count():
		return "Building"
	if roads != null and roads.unfinished_count() > 0:
		return "Paving roads"
	if tasks.count_of(MeepTasks.Kind.MINE) > 0:
		return "Harvesting"
	if tasks.count_of(MeepTasks.Kind.CLONE) > 0:
		return "Cloning"
	if current_tier_full() and _alive >= housing_capacity():
		return "Tier %d space filled" % tier
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
	if _progression_changed:
		_progression_changed = false
		_apply_city_progression.rpc(city_progression_snapshot())
	if _town_changed:
		_town_changed = false
		if structures != null and roads != null:
			_apply_town.rpc(structures.snapshot(), roads.snapshot(),
				_tier_zero_space_full, _tier_zero_complete,
				structures.form_snapshot(),
				structures.upgrade_progress_snapshot(), deed_snapshot(),
				tier_allocated_flags, tier_complete_flags,
				roads.width_snapshot(), roads.surface_snapshot(),
				identity_snapshot())
	var indices := PackedInt32Array()
	var locals := PackedVector2Array()
	var health := PackedByteArray()
	var states := PackedByteArray()
	for index in _active_rows:
		if not _active_resident(index) or _detail[index] == Detail.COLD:
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
	_apply_state.rpc(indices, locals, health, states, _alive, resources, committed,
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
		var ages := PackedFloat64Array()
		var causes := PackedStringArray()
		for index in _deaths:
			ages.push_back(_ages[index])
			causes.push_back(_death_causes[index])
		_apply_deaths.rpc(_deaths.duplicate(), ages, causes)
	_deaths.clear()


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_state(indices: PackedInt32Array, locals: PackedVector2Array,
		health: PackedByteArray, states: PackedByteArray, alive: int, bank: float,
		held: float, raised: PackedFloat32Array) -> void:
	if _is_host():
		return
	_begin_bulk_rows()
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
	_end_bulk_rows()
	# A packet can bring a row back — a clone reusing a padded index — so the
	# iteration lists are rebuilt rather than left to the next grade.
	_refresh_rows()
	# The host's count, not one derived from the rows here: distant Meeps are left
	# out of the packet entirely and would otherwise go missing from the panel.
	_alive = alive
	resources = bank
	committed = clampf(held, 0.0, resources)
	if structures != null:
		structures.apply_progress(raised)


## What stands where. Reliable and whole rather than incremental: a town is a handful of
## kinds and corners, so sending all of it is cheaper than the bookkeeping to send the
## difference, and a client that missed one packet is not left with a gap in its town.
@rpc("authority", "call_remote", "reliable")
func _apply_town(state: PackedInt32Array, street_state: PackedInt32Array,
		tier_space_full: bool, tier_complete: bool,
		form_state: PackedInt32Array = PackedInt32Array(),
		upgrade_state: PackedFloat32Array = PackedFloat32Array(),
		deed_state: PackedInt32Array = PackedInt32Array(),
		allocated_flags := -1, complete_flags := -1,
		road_width_state: PackedInt32Array = PackedInt32Array(),
		surface_state: PackedInt32Array = PackedInt32Array(),
		identity_state: Dictionary = {}) -> void:
	if _is_host() or structures == null or roads == null:
		return
	var surfaces_changed := roads.surface_snapshot() != surface_state
	structures.apply_snapshot(state)
	structures.apply_form_snapshot(form_state, upgrade_state)
	ensure_settlement_ship_cloner()
	roads.apply_snapshot(street_state)
	roads.apply_width_snapshot(road_width_state)
	roads.apply_surface_snapshot(surface_state)
	_tier_zero_space_full = tier_space_full
	_tier_zero_complete = tier_complete
	apply_deed_snapshot(deed_state)
	if not identity_state.is_empty():
		apply_identity_snapshot(identity_state)
	if allocated_flags >= 0:
		tier_allocated_flags = allocated_flags
	elif tier_space_full:
		tier_allocated_flags |= 1
	if complete_flags >= 0:
		tier_complete_flags = complete_flags
	elif tier_complete:
		tier_complete_flags |= 1
	if surfaces_changed:
		reground()


@rpc("authority", "call_remote", "reliable")
func _apply_city_progression(state: Dictionary) -> void:
	if _is_host():
		return
	apply_city_progression(state)


@rpc("authority", "call_remote", "reliable")
func _apply_deaths(indices: PackedInt32Array,
		ages := PackedFloat64Array(),
		causes := PackedStringArray()) -> void:
	if _is_host():
		return
	_begin_bulk_rows()
	for slot in indices.size():
		var index := indices[slot]
		while _local.size() <= index:
			_add(Vector2.ZERO, _local.size())
		if slot < ages.size():
			_ages[index] = maxf(float(ages[slot]), 0.0)
		if slot < causes.size():
			_death_causes[index] = String(causes[slot])
		if _active_resident(index):
			_kill(index)
	_end_bulk_rows()


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
			_height[index] = grid.walk_height_at(grid.cell_of(now))
