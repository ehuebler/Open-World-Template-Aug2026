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
	## Large commissioned projects. Appended because structure kinds are replicated.
	HAT_HOUSE,
	ABILITIES_HOUSE,
	BIOMASS_HARVESTER,
	## Residential forms are append-only because kind is the first integer in every
	## structure snapshot.
	TOWNHOUSE,
	MID_RISE,
	SKYSCRAPER,
	## Coast housing is appended after every existing land form.
	DOCK_HUT,
	## Megacity forms are appended after every existing wire kind. They only begin
	## appearing once a city has filled its thousand-resident high-rise architecture.
	MEGA_SKYSCRAPER,
	SUPER_SKYSCRAPER,
	## A compact vertical city appended after every shipped wire kind. Its smaller
	## footprint can redevelop inside a mature road grid instead of demanding another
	## broad untouched campus at the edge of the claim.
	ARCLOGY,
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
	## Functional residential metadata. Zero capacity marks civic/non-residential.
	var tier := 0
	var floors := 1
	var maximum_floors := 1
	var resident_slots := 0
	var development_units := 0
	## Wider forms demand more open civic space, especially around towers.
	var spacing := SPACING
	var floor_height := 3.2
	## Large towers include a foundation podium that can absorb broader terrain
	## variation than a one-lot box without requiring an implausibly flat 30 m pad.
	var level_tolerance := 1.1


## Filled once for the whole game. Indexed by [enum Kind].
static var _plans: Array[Plan] = []

## How level a footprint has to be, in metres between its highest and lowest cell. A
## box has no foundations, so anything looser than this is a building with daylight
## under one corner.
const LEVEL_TOLERANCE := 1.1
## Radius around the colony ship kept as an open landing plaza. This is measured to
## the nearest edge of a complete footprint, not to a building's midpoint, so even a
## wide future structure cannot project back into the circle.
const SHIP_CLEAR_RADIUS := 20.0
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
	## Residential form state. Kept on every site so the wire sidecar remains a
	## fixed-width record even for civic buildings.
	var completed_floors := 1
	var target_floors := 1
	var resident_slots := 0
	var upgrade_progress := 0.0
	var district_tier := 0

	func built() -> bool:
		return progress >= 1.0

	func upgrading() -> bool:
		return target_floors > completed_floors


var site: MeepSite
var grid: MeepGrid
var claim: MeepClaim
var roads: MeepRoads

var _shape: PlanetShape
var _planet: Planet
var _colony: MeepColony
var _sites: Array[Site] = []
## Structure indices of huts in placement order. Sibling pair N owns hut N, so this
## compact indirection makes that answer O(1) without putting ownership on the wire.
var _hut_indices := PackedInt32Array()
## Kinds for which a complete placement scan found no valid plot in the current
## claim. Continuous border growth can make these answers false later, so the colony
## clears the cache whenever its claim gains territory. Between boundary steps this
## still avoids rescanning sixteen thousand cells every planning interval.
var _exhausted: Dictionary = {}
## Floods left in the placement attempt currently running. See [constant
## ACCESS_FLOODS_PER_ATTEMPT].
var _access_floods_left := 0
## Flattened walkable claim, buildable plots, and the ground revision and boundary
## size both were taken from. See [method _refresh_ground_masks].
var _open_mask := PackedByteArray()
var _plot_mask := PackedByteArray()
var _masks_revision := -1
var _masks_claim_count := -1
## Bumped whenever a site is added, moved, or dropped, so the tables the placement
## scan builds from the list know to expire. See [method _separations_for].
var _sites_stamp := 0
var _separations := PackedFloat64Array()
var _site_places := PackedVector2Array()
var _separation_kind := -1
var _separation_stamp := -1
var _stands: Array[MultiMeshInstance3D] = []
## Built once by [method _shared_stand_meshes] and shared by every town.
static var _shared_stands: Array[Mesh] = []
var _colliders: Array[StaticBody3D] = []
## Whether any of the pool is currently in the world. See [method lend_colliders].
var _colliders_lent := true
## Set when anything about the list changed, so the buffers are only rewritten on the
## frames that need it rather than every frame of a town standing still.
var _dirty := true
const CONNECTIVITY_CHOICES := 12
## Exhaustive connectivity floods one placement attempt may pay for.
##
## Each flood walks the whole claim with the proposed footprint treated as solid,
## which is tens of milliseconds once a town covers a hundred-metre radius. The
## cheap proof by the colony's own home field settles nearly every candidate; the
## flood is the fallback for one whose single cached route happens to cross the
## plot. A pass that spends this many without settling anything gives the plot up
## until the next planning interval instead of holding the physics step open for
## the rest of the ring — which is what a 175 ms hitch in [method
## MeepColony._plan_building] was.
const ACCESS_FLOODS_PER_ATTEMPT := 3


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
	hut.resident_slots = 2
	hut.development_units = 2
	hut.floors = 1
	hut.maximum_floors = 2
	hut.floor_height = 3.8
	_plans[Kind.HUT] = hut
	var hat_house := Plan.new()
	hat_house.kind = Kind.HAT_HOUSE
	hat_house.title = "Hat House"
	hat_house.span = Vector2i(6, 6)
	hat_house.size = Vector3(11.2, 7.6, 11.2)
	hat_house.colour = Color(0.18, 0.82, 0.28)
	hat_house.cost = MeepColony.SPECIALTY_HOUSE_COST
	hat_house.work = 110.0
	hat_house.crew = 6
	_plans[Kind.HAT_HOUSE] = hat_house
	var abilities_house := Plan.new()
	abilities_house.kind = Kind.ABILITIES_HOUSE
	abilities_house.title = "Abilities House"
	abilities_house.span = Vector2i(6, 6)
	abilities_house.size = Vector3(11.2, 7.6, 11.2)
	abilities_house.colour = Color(0.10, 0.38, 0.96)
	abilities_house.cost = MeepColony.SPECIALTY_HOUSE_COST
	abilities_house.work = 110.0
	abilities_house.crew = 6
	abilities_house.maximum_floors = 2
	abilities_house.floor_height = abilities_house.size.y
	_plans[Kind.ABILITIES_HOUSE] = abilities_house
	var harvester := Plan.new()
	harvester.kind = Kind.BIOMASS_HARVESTER
	harvester.title = "Biomass Harvester"
	harvester.span = Vector2i(9, 9)
	harvester.size = Vector3(17.2, 7.6, 17.2)
	harvester.colour = Color(0.96, 0.24, 0.62)
	harvester.cost = MeepColony.BIOMASS_HARVESTER_COST
	harvester.work = 288.0
	harvester.crew = 10
	_plans[Kind.BIOMASS_HARVESTER] = harvester
	var townhouse := Plan.new()
	townhouse.kind = Kind.TOWNHOUSE
	townhouse.title = "Townhouse"
	townhouse.span = Vector2i(6, 3)
	townhouse.size = Vector3(11.2, 7.6, 5.2)
	townhouse.colour = Color(0.94, 0.52, 0.12)
	townhouse.cost = 90.0
	townhouse.work = 44.0
	townhouse.crew = 4
	townhouse.tier = 1
	townhouse.floors = 2
	townhouse.maximum_floors = 2
	townhouse.resident_slots = 6
	townhouse.development_units = 6
	townhouse.floor_height = 3.8
	_plans[Kind.TOWNHOUSE] = townhouse
	var mid_rise := Plan.new()
	mid_rise.kind = Kind.MID_RISE
	mid_rise.title = "Mid-Rise"
	mid_rise.span = Vector2i(6, 6)
	mid_rise.size = Vector3(11.2, 17.5, 11.2)
	mid_rise.colour = Color(0.83, 0.31, 0.12)
	mid_rise.cost = 240.0
	mid_rise.work = 112.0
	mid_rise.crew = 7
	mid_rise.tier = 2
	mid_rise.floors = 5
	mid_rise.maximum_floors = 5
	mid_rise.resident_slots = 16
	mid_rise.development_units = 16
	mid_rise.spacing = 8.0
	mid_rise.floor_height = 3.5
	_plans[Kind.MID_RISE] = mid_rise
	var skyscraper := Plan.new()
	skyscraper.kind = Kind.SKYSCRAPER
	skyscraper.title = "Skyscraper"
	skyscraper.span = Vector2i(9, 9)
	skyscraper.size = Vector3(17.2, 49.0, 17.2)
	skyscraper.colour = Color(0.62, 0.17, 0.10)
	skyscraper.cost = 720.0
	skyscraper.work = 320.0
	skyscraper.crew = 12
	skyscraper.tier = 3
	skyscraper.floors = 14
	skyscraper.maximum_floors = 16
	skyscraper.resident_slots = 360
	skyscraper.development_units = 360
	skyscraper.spacing = 14.0
	skyscraper.floor_height = 3.5
	_plans[Kind.SKYSCRAPER] = skyscraper
	var dock_hut := Plan.new()
	dock_hut.kind = Kind.DOCK_HUT
	dock_hut.title = "Dock Hut"
	dock_hut.span = Vector2i(3, 3)
	dock_hut.size = Vector3(5.2, 4.6, 5.2)
	dock_hut.colour = Color(0.78, 0.34, 0.10)
	dock_hut.cost = 75.0
	dock_hut.work = 38.0
	dock_hut.crew = 3
	dock_hut.tier = 1
	dock_hut.floors = 1
	dock_hut.maximum_floors = 1
	dock_hut.resident_slots = 4
	dock_hut.development_units = 4
	dock_hut.floor_height = 4.6
	dock_hut.spacing = 4.0
	_plans[Kind.DOCK_HUT] = dock_hut
	var mega_skyscraper := Plan.new()
	mega_skyscraper.kind = Kind.MEGA_SKYSCRAPER
	mega_skyscraper.title = "Mega Skyscraper"
	mega_skyscraper.span = Vector2i(12, 12)
	mega_skyscraper.size = Vector3(23.2, 78.0, 23.2)
	mega_skyscraper.colour = Color(0.48, 0.12, 0.16)
	mega_skyscraper.cost = 1050.0
	mega_skyscraper.work = 390.0
	mega_skyscraper.crew = 16
	mega_skyscraper.tier = 4
	mega_skyscraper.floors = 22
	mega_skyscraper.maximum_floors = 26
	mega_skyscraper.resident_slots = 640
	mega_skyscraper.development_units = 640
	mega_skyscraper.spacing = 14.0
	mega_skyscraper.floor_height = 3.55
	mega_skyscraper.level_tolerance = 3.0
	_plans[Kind.MEGA_SKYSCRAPER] = mega_skyscraper
	var super_skyscraper := Plan.new()
	super_skyscraper.kind = Kind.SUPER_SKYSCRAPER
	super_skyscraper.title = "Super Skyscraper"
	super_skyscraper.span = Vector2i(15, 15)
	super_skyscraper.size = Vector3(29.2, 110.0, 29.2)
	super_skyscraper.colour = Color(0.35, 0.08, 0.20)
	super_skyscraper.cost = 1500.0
	super_skyscraper.work = 520.0
	super_skyscraper.crew = 20
	super_skyscraper.tier = 4
	super_skyscraper.floors = 30
	super_skyscraper.maximum_floors = 34
	super_skyscraper.resident_slots = 100
	super_skyscraper.development_units = 100
	super_skyscraper.spacing = 16.0
	super_skyscraper.floor_height = 3.67
	super_skyscraper.level_tolerance = 4.5
	_plans[Kind.SUPER_SKYSCRAPER] = super_skyscraper
	var arcology := Plan.new()
	arcology.kind = Kind.ARCLOGY
	arcology.title = "Vertical Arcology"
	arcology.span = Vector2i(9, 9)
	arcology.size = Vector3(17.2, 220.0, 17.2)
	arcology.colour = Color(0.22, 0.07, 0.32)
	arcology.cost = 4200.0
	arcology.work = 1100.0
	arcology.crew = 24
	arcology.tier = 4
	arcology.floors = 60
	arcology.maximum_floors = 64
	arcology.resident_slots = 3584
	arcology.development_units = 3584
	arcology.spacing = 14.0
	arcology.floor_height = 3.67
	arcology.level_tolerance = 4.5
	_plans[Kind.ARCLOGY] = arcology


static func plan_of(kind: int) -> Plan:
	return _plans[clampi(kind, 0, _plans.size() - 1)]


static func residential_kind_for_tier(tier: int) -> int:
	match clampi(tier, 0, 4):
		1:
			return Kind.TOWNHOUSE
		2:
			return Kind.MID_RISE
		3:
			return Kind.SKYSCRAPER
		4:
			return Kind.MEGA_SKYSCRAPER
		_:
			return Kind.HUT


## Tier 4 first fills a dense mega-tower grid, then adds compact vertical arcologies.
## Residents therefore reach 10k+ through a visible skyline rather than three
## isolated capacity boxes.
static func residential_kind_for_growth(tier: int, population: int) -> int:
	if tier >= 4:
		return Kind.ARCLOGY if population >= 6400 else Kind.MEGA_SKYSCRAPER
	return residential_kind_for_tier(tier)


static func is_residential_kind(kind: int) -> bool:
	return kind == Kind.HUT or kind == Kind.TOWNHOUSE \
		or kind == Kind.MID_RISE or kind == Kind.SKYSCRAPER \
		or kind == Kind.DOCK_HUT or kind == Kind.MEGA_SKYSCRAPER \
		or kind == Kind.SUPER_SKYSCRAPER or kind == Kind.ARCLOGY


## Dense-form capacity increased when Tier 4 became a 10k+ vertical city. Old form
## sidecars store their tuned slot count, so recognize only those former ranges and
## lift them to the equivalent number of floors without rewriting custom/new values.
static func migrated_resident_slots(kind: int,
		completed_floors: int, saved_slots: int) -> int:
	var legacy_base := 0
	match kind:
		Kind.SKYSCRAPER:
			legacy_base = 48
		Kind.MEGA_SKYSCRAPER:
			legacy_base = 72
		Kind.SUPER_SKYSCRAPER:
			legacy_base = 100
		_:
			return maxi(saved_slots, 0)
	var plan := plan_of(kind)
	var legacy_max := ceili(float(legacy_base)
		* float(plan.maximum_floors) / float(maxi(plan.floors, 1)))
	if saved_slots > legacy_max:
		return saved_slots
	var current := ceili(float(plan.resident_slots)
		* float(maxi(completed_floors, 1))
		/ float(maxi(plan.floors, 1)))
	return maxi(saved_slots, current)


func _init() -> void:
	name = "Structures"


func configure(for_site: MeepSite, for_grid: MeepGrid, for_claim: MeepClaim,
		shape: PlanetShape, planet: Planet, host: MeepColony = null,
		for_roads: MeepRoads = null, presentation := true,
		collisions := true) -> void:
	site = for_site
	grid = for_grid
	claim = for_claim
	_shape = shape
	_planet = planet
	_colony = host
	roads = for_roads
	if presentation:
		_raise_stands()
	if collisions:
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


func hut_at_ordinal(ordinal: int, only_built := true) -> int:
	if ordinal < 0 or ordinal >= _hut_indices.size():
		return -1
	var index := _hut_indices[ordinal]
	var entry := at(index)
	return index if entry != null and (entry.built() or not only_built) else -1


func hut_ordinal(structure: int) -> int:
	return _hut_indices.find(structure)


func hut_count(only_built := false) -> int:
	if not only_built:
		return _hut_indices.size()
	var found := 0
	for index in _hut_indices:
		var entry := at(index)
		if entry != null and entry.built():
			found += 1
	return found


func residential_count(only_built := false) -> int:
	var found := 0
	for entry in _sites:
		if is_residential_kind(entry.kind) \
				and (entry.built() or not only_built):
			found += 1
	return found


func residential_capacity(only_built := true) -> int:
	var capacity := 0
	for entry in _sites:
		if is_residential_kind(entry.kind) \
				and (entry.built() or not only_built):
			capacity += entry.resident_slots
	return capacity


func development_units(through_tier := 4, only_built := true) -> int:
	var units := 0
	for entry in _sites:
		var plan := plan_of(entry.kind)
		if plan.resident_slots <= 0 or entry.district_tier > through_tier \
				or (only_built and not entry.built()):
			continue
		units += entry.resident_slots
	return units


## The first residence with room for `needed` more, or -1.
##
## `from` resumes a scan that has already rejected everything below it. Housing a
## whole town means asking this once per household, and starting at zero every time
## re-walks the houses already filled by the households before it — which is the
## difference between a linear pass over the town and a quadratic one.
##
## Resuming is only sound for a repeated `needed`: a house without room for two may
## still have room for one, so a caller that asks for both keeps a cursor for each.
func first_residential_vacancy(occupancy: Dictionary, needed := 1,
		from := 0) -> int:
	for index in range(maxi(from, 0), _sites.size()):
		var entry := _sites[index]
		if entry.built() and is_residential_kind(entry.kind) \
				and entry.resident_slots - int(occupancy.get(index, 0)) \
					>= maxi(needed, 1):
			return index
	return -1


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
	var found := _work_cell_for(plan, entry.corner)
	if found.x >= 0:
		return found
	return entry.corner + Vector2i(plan.span.x / 2, plan.span.y / 2)


## Every legal place a road or worker may meet this footprint. The nominal work
## cell stays first for compatibility; the remainder are stable by grid index so
## large and dense forms never depend on one arbitrarily chosen doorway.
func access_cells(index: int) -> Array[Vector2i]:
	var entry := at(index)
	return _access_cells_for(plan_of(entry.kind), entry.corner) \
		if entry != null else []


func _access_cells_for(plan: Plan, corner: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for y in plan.span.y:
		candidates.push_back(corner + Vector2i(-1, y))
		candidates.push_back(corner + Vector2i(plan.span.x, y))
	for x in plan.span.x:
		candidates.push_back(corner + Vector2i(x, -1))
		candidates.push_back(corner + Vector2i(x, plan.span.y))
	var valid: Array[Vector2i] = []
	for cell in candidates:
		if grid != null and grid.passable(cell) \
				and (claim == null or claim.contains_cell(cell)) \
				and not valid.has(cell):
			valid.push_back(cell)
	valid.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return grid.index(a) < grid.index(b))
	var nominal := _work_cell_for(plan, corner)
	if nominal.x >= 0:
		valid.erase(nominal)
		valid.push_front(nominal)
	return valid


func _work_cell_for(plan: Plan, corner: Vector2i) -> Vector2i:
	for y in plan.span.y:
		var left := corner + Vector2i(-1, y)
		if _valid_work_cell(left):
			return left
		var right := corner + Vector2i(plan.span.x, y)
		if _valid_work_cell(right):
			return right
	for x in plan.span.x:
		var above := corner + Vector2i(x, -1)
		if _valid_work_cell(above):
			return above
		var below := corner + Vector2i(x, plan.span.y)
		if _valid_work_cell(below):
			return below
	return Vector2i(-1, -1)


func _valid_work_cell(cell: Vector2i) -> bool:
	return grid != null and grid.passable(cell) \
		and (claim == null or claim.contains_cell(cell))


func _perimeter_cells(plan: Plan, corner: Vector2i) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for y in plan.span.y:
		candidates.push_back(corner + Vector2i(-1, y))
		candidates.push_back(corner + Vector2i(plan.span.x, y))
	for x in plan.span.x:
		candidates.push_back(corner + Vector2i(x, -1))
		candidates.push_back(corner + Vector2i(x, plan.span.y))
	return candidates


# --- Placing -----------------------------------------------------------------

## Finds a spot for a new structure and pegs it out, returning its index or -1.
##
## Finds the nearest valid site during starter growth. Tier 0 expansion asks for
## [param spread_out], which scans the same dynamic claim but chooses the candidate
## furthest from existing plots. That carries the town toward all of its usable bounds
## instead of packing ninety boxes around the ship; the density budget in MeepColony
## stops while the broad gaps left by this coverage pass can still become parks,
## lookouts and larger civic buildings.
func place(kind: int, spread_out := false) -> int:
	_access_floods_left = ACCESS_FLOODS_PER_ATTEMPT
	return _place(kind, spread_out)


## The search itself, without claiming a fresh flood budget. A spread pass falls back
## to the nearest-site pass, and the two together are one attempt.
func _place(kind: int, spread_out: bool) -> int:
	if grid == null or claim == null:
		return -1
	if full_for(kind):
		return -1
	var plan := plan_of(kind)
	var from := claim.origin
	var rings := int(ceil(claim.radius / grid.cell_size)) + 2
	var choices: Array[Vector3] = []
	# A spread pass judges one non-overlapping footprint lattice. Adjacent corners
	# describe almost the same 3x3 (or larger) plot, and scoring all of them made
	# each child-town house placement rescan hundreds of thousands of equivalent
	# structure pairs. The nearest full scan below remains the saturation fallback,
	# so coarse coverage never declares usable land exhausted.
	var stride := maxi(mini(plan.span.x, plan.span.y), 1) if spread_out else 1
	# The plot search walks the whole claim, ring by ring, and scores every corner a
	# form of this size could sit on. Reported with that count, because the same
	# milliseconds mean different things: a scan that scored the claim and found
	# nothing is a full town, and a short one that cost as much was the access floods.
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	var scored := 0
	for ring in rings:
		for cell in _ring_cells(from, ring):
			if spread_out and (posmod(cell.x - from.x, stride) != 0 \
					or posmod(cell.y - from.y, stride) != 0):
				continue
			scored += 1
			var score := _placement_score(plan, cell)
			if score == -INF:
				continue
			if not spread_out:
				if _access_reachable_after_block(plan, cell):
					_trace_scan(&"place_scan", began, scored)
					return place_at(kind, cell)
				continue
			_keep_connectivity_choice(choices, score, cell)
	_trace_scan(&"place_scan", began, scored)
	if not choices.is_empty():
		_sort_connectivity_choices(choices)
		for choice in choices:
			var candidate := Vector2i(roundi(choice.y), roundi(choice.z))
			if _access_reachable_after_block(plan, candidate):
				return place_at(kind, candidate)
		# A broad form can occasionally cover the only neck used by its pre-build
		# route field. Fall back to the nearest legal plot instead of accepting a
		# permanently disconnected commission or declaring the whole claim full.
		return _place(kind, false)
	_note_exhausted(kind)
	return -1


## One plot search, with how many corners it scored. Zero [param began] means deep
## tracing is off and there is nothing to report.
func _trace_scan(label: StringName, began: int, scored: int) -> void:
	if began > 0:
		RuntimeTelemetry.record_activity(&"meeps", label,
			Time.get_ticks_usec() - began, float(scored))


## Civic commissions first try wholly outside the preceding tier's radius. If the
## expanded ring has no valid level plot, the ordinary spread-out scan falls back to
## unallocated inner gaps — the same open cells that read as parks before they are used.
func place_commissioned(kind: int, previous_tier_radius: float) -> int:
	if grid == null or claim == null:
		return -1
	if full_for(kind):
		return -1
	_access_floods_left = ACCESS_FLOODS_PER_ATTEMPT
	var plan := plan_of(kind)
	if previous_tier_radius > 0.0:
		var from := claim.origin
		var rings := int(ceil(claim.radius / grid.cell_size)) + 2
		var best := Vector2i(-1, -1)
		var best_score := -INF
		for ring in rings:
			for cell in _ring_cells(from, ring):
				var score := _placement_score(plan, cell)
				if score == -INF or not _wholly_outside(
						plan, cell, previous_tier_radius):
					continue
				if score > best_score:
					best = cell
					best_score = score
		if best.x >= 0 and _access_reachable_after_block(plan, best):
			return place_at(kind, best)
	# Tier 0 comes directly here. Its low civic density deliberately left these
	# valid, road-connected gaps open for projects, parks and lookouts.
	return _place(kind, true)


## Places a residential form in the newly claimed annulus. The lattice is local to
## this colony and clipped by `_suits`, so it describes small terrain-shaped blocks
## rather than stamping one planet-wide grid across water and cliffs.
func place_district(kind: int, previous_tier_radius: float,
		block_size: float, district_tier: int) -> int:
	if grid == null or claim == null or not is_residential_kind(kind):
		return -1
	if full_for(kind):
		return -1
	_access_floods_left = ACCESS_FLOODS_PER_ATTEMPT
	var plan := plan_of(kind)
	var from := claim.origin
	var rings := int(ceil(claim.radius / grid.cell_size)) + 2
	var choices: Array[Vector3] = []
	var block := maxf(block_size, grid.cell_size * 4.0)
	var stride := maxi(mini(plan.span.x, plan.span.y), 2)
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	var scored := 0
	for ring in rings:
		for cell in _ring_cells(from, ring):
			if posmod(cell.x - from.x, stride) != 0 \
					or posmod(cell.y - from.y, stride) != 0:
				continue
			scored += 1
			var score := _placement_score(plan, cell)
			if score == -INF \
					or not _wholly_outside(plan, cell, previous_tier_radius):
				continue
			var middle := _centre_of(plan, cell)
			var within := Vector2(
				posmod(floori(middle.x + block * 0.5), floori(block)),
				posmod(floori(middle.y + block * 0.5), floori(block)))
			# Prefer the interior corners of a block, leaving broad repeated lanes
			# between blocks for the wider connectors planned by the road pass.
			var lane_clearance := minf(
				minf(within.x, block - within.x),
				minf(within.y, block - within.y))
			score += lane_clearance * 18.0
			_keep_connectivity_choice(choices, score, cell)
	_trace_scan(&"place_district_scan", began, scored)
	if not choices.is_empty():
		_sort_connectivity_choices(choices)
		for choice in choices:
			var candidate := Vector2i(roundi(choice.y), roundi(choice.z))
			if _access_reachable_after_block(plan, candidate):
				return place_at(kind, candidate, district_tier)
		began = Time.get_ticks_usec() if began > 0 else 0
		scored = 0
		for ring in rings:
			for cell in _ring_cells(from, ring):
				scored += 1
				if _suits(plan, cell) \
						and _wholly_outside(plan, cell, previous_tier_radius) \
						and _access_reachable_after_block(plan, cell):
					_trace_scan(&"place_district_rescan", began, scored)
					return place_at(kind, cell, district_tier)
		_trace_scan(&"place_district_rescan", began, scored)
	_note_exhausted(kind)
	return -1


func place_dock_hut(district_tier := 1) -> int:
	if grid == null or claim == null or roads == null:
		return -1
	_access_floods_left = ACCESS_FLOODS_PER_ATTEMPT
	var plan := plan_of(Kind.DOCK_HUT)
	var choices: Array[Vector3] = []
	var seen := PackedByteArray()
	seen.resize(grid.cells * grid.cells)
	# A valid dock hut contains at least one completed dock cell. Enumerating the
	# few corners around those cells is exact and replaces a whole 128x128-grid
	# scan every time coastal housing is considered.
	for slot in roads.cell_count():
		var road_index := roads.cell_index_at(slot)
		if roads.surface_kind_at(road_index) != MeepRoads.SurfaceKind.DOCK:
			continue
		var dock_cell := roads._cell(road_index)
		for offset_y in range(-plan.span.y + 1, 1):
			for offset_x in range(-plan.span.x + 1, 1):
				var corner := dock_cell + Vector2i(offset_x, offset_y)
				if corner.x < 0 or corner.y < 0 \
						or corner.x + plan.span.x > grid.cells \
						or corner.y + plan.span.y > grid.cells:
					continue
				var corner_index := grid.index(corner)
				if seen[corner_index] != 0:
					continue
				seen[corner_index] = 1
				if not _suits_dock(plan, corner):
					continue
				choices.push_back(Vector3(
					_coverage_score(plan, corner),
					float(corner.x), float(corner.y)))
	if choices.is_empty():
		_exhausted[Kind.DOCK_HUT] = true
		return -1
	_sort_connectivity_choices(choices)
	for choice in choices:
		var candidate := Vector2i(roundi(choice.y), roundi(choice.z))
		if _access_reachable_after_block(plan, candidate):
			return place_at(Kind.DOCK_HUT, candidate, district_tier)
	_note_exhausted(Kind.DOCK_HUT)
	return -1


func _keep_connectivity_choice(choices: Array[Vector3], score: float,
		cell: Vector2i) -> void:
	choices.push_back(Vector3(score, float(cell.x), float(cell.y)))
	if choices.size() <= CONNECTIVITY_CHOICES:
		return
	var worst := 0
	for index in range(1, choices.size()):
		var candidate := choices[index]
		var current := choices[worst]
		if candidate.x < current.x \
				or (candidate.x == current.x and grid.index(Vector2i(
					roundi(candidate.y), roundi(candidate.z))) > grid.index(
						Vector2i(roundi(current.y), roundi(current.z)))):
			worst = index
	choices.remove_at(worst)


func _sort_connectivity_choices(choices: Array[Vector3]) -> void:
	choices.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		if a.x != b.x:
			return a.x > b.x
		return grid.index(Vector2i(roundi(a.y), roundi(a.z))) \
			< grid.index(Vector2i(roundi(b.y), roundi(b.z))))


func _suits_dock(plan: Plan, corner: Vector2i) -> bool:
	var lowest := INF
	var highest := -INF
	for x in plan.span.x:
		for y in plan.span.y:
			var cell := corner + Vector2i(x, y)
			if not grid.inside(cell) or not claim.contains_cell(cell) \
					or not grid.passable(cell) \
					or not grid.region_buildable(cell) \
					or grid.has_flag(cell, MeepGrid.FLAG_BUILDING) \
					or grid.has_flag(cell, MeepGrid.FLAG_RESERVED) \
					or grid.has_flag(cell, MeepGrid.FLAG_PARK) \
					or grid.has_flag(cell, MeepGrid.FLAG_PLANNED_LOT):
				return false
			var index := grid.index(cell)
			if roads.surface_kind_at(index) != MeepRoads.SurfaceKind.DOCK:
				return false
			var height := roads.deck_height_at(index)
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > plan.level_tolerance \
			or _work_cell_for(plan, corner).x < 0:
		return false
	var middle := _centre_of(plan, corner)
	if _footprint_clearance(plan, middle) < SHIP_CLEAR_RADIUS:
		return false
	for entry in _sites:
		var theirs := plan_of(entry.kind)
		var apart := (maxf(plan.size.x, plan.size.z)
			+ maxf(theirs.size.x, theirs.size.z)) * 0.5 \
			+ maxf(plan.spacing, theirs.spacing)
		if middle.distance_to(entry.local) < apart:
			return false
	return true


func _wholly_outside(plan: Plan, corner: Vector2i, radius: float) -> bool:
	var middle := _centre_of(plan, corner)
	var half_diagonal := (Vector2(plan.span) * grid.cell_size * 0.5).length()
	return middle.length() - half_diagonal >= radius


func _coverage_score(plan: Plan, corner: Vector2i) -> float:
	var middle := _centre_of(plan, corner)
	var nearest := INF
	for entry in _sites:
		nearest = minf(nearest, middle.distance_squared_to(entry.local))
	# Existing starter plots already make distance favour the outskirts. A small radial
	# term resolves broad ties toward unexplored land without stamping a perimeter ring.
	return nearest + middle.length_squared() * 0.08


## Validity and coverage in one footprint pass. Spread placement used to call
## `_suits` and then walk every existing site a second time in `_coverage_score`.
## At a mature settlement that duplicated the population-independent half of a
## 16k-cell search every two seconds.
func _placement_score(plan: Plan, corner: Vector2i,
		allow_planned_lot := false) -> float:
	var side := grid.cells
	if corner.x < 0 or corner.y < 0 \
			or corner.x + plan.span.x > side or corner.y + plan.span.y > side:
		return -INF
	# This runs for every cell of a ring scan across the whole claim, so the ground
	# questions are read from the flattened plot mask rather than asked five method
	# calls deep per footprint cell.
	var plot := _plot_cells()
	var heights := grid.heights
	var lowest := INF
	var highest := -INF
	for offset_y in plan.span.y:
		var row := (corner.y + offset_y) * side + corner.x
		for offset_x in plan.span.x:
			var at := row + offset_x
			if plot[at] == 0:
				var bits := int(grid.flags[at])
				var blocked_except_plan := MeepGrid.FLAG_ROAD \
					| MeepGrid.FLAG_RESERVED | MeepGrid.FLAG_PARK
				if not allow_planned_lot \
						or (bits & MeepGrid.FLAG_PLANNED_LOT) == 0 \
						or _open_mask[at] == 0 \
						or not grid.region_buildable_index(at) \
						or (bits & blocked_except_plan) != 0:
					return -INF
			var height := heights[at]
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > plan.level_tolerance \
			or _work_cell_for(plan, corner).x < 0:
		return -INF
	var middle := _centre_of(plan, corner)
	if _footprint_clearance(plan, middle) < SHIP_CLEAR_RADIUS:
		return -INF
	# Spacing against everything already built is the other half of the per-cell
	# cost, and the separation a given neighbour demands of this plan is a constant
	# for the whole scan. Resolving it once leaves float arithmetic over packed
	# arrays here instead of two plan lookups and a Vector2 method per site.
	var separations := _separations_for(plan)
	var places := _site_places
	var nearest := INF
	for index in separations.size():
		var away := middle.distance_squared_to(places[index])
		if away < separations[index]:
			return -INF
		nearest = minf(nearest, away)
	return nearest + middle.length_squared() * 0.08


## Whether adding more buildings and roads has left no valid plot of this kind.
func full_for(kind: int) -> bool:
	return bool(_exhausted.get(kind, false))


## A larger or newly connected claim can expose plots that did not exist during a
## previous complete scan. No sites move; only the negative placement cache expires.
func clear_exhaustion() -> void:
	_exhausted.clear()


## Records that a complete scan found nowhere to build.
##
## A pass that ran out of connectivity floods did not finish proving anything, so it
## must not leave the kind marked full: the plot it gave up on is offered again on
## the next planning interval.
func _note_exhausted(kind: int) -> void:
	if _access_floods_left > 0:
		_exhausted[kind] = true


## Pegs out a structure at a known corner, whatever the ground thinks.
##
## Separate from [method place] because a client is told where the host put a building
## rather than working it out again: the search reads a claim, and a claim is filled
## from a grid a client may still be baking.
func place_at(kind: int, corner: Vector2i, district_tier := 0) -> int:
	var plan := plan_of(kind)
	var entry := Site.new()
	entry.kind = kind
	entry.corner = corner
	entry.local = _centre_of(plan, corner)
	entry.height = _ground(entry.local, plan, corner)
	entry.completed_floors = plan.floors
	entry.target_floors = plan.floors
	entry.resident_slots = plan.resident_slots
	entry.district_tier = clampi(district_tier, 0, 4)
	_sites.push_back(entry)
	if kind == Kind.HUT:
		_hut_indices.push_back(_sites.size() - 1)
	_dirty = true
	_sites_stamp += 1
	return _sites.size() - 1


## Consumes a founding-blueprint lot through the same ground, spacing, and access
## checks used by a live placement scan, without searching for another corner.
func place_planned(kind: int, corner: Vector2i, district_tier := 0) -> int:
	_access_floods_left = ACCESS_FLOODS_PER_ATTEMPT
	var plan := plan_of(kind)
	# -2 is a permanent geometry conflict (another standing structure, road, or
	# scar); -1 is a temporarily unreachable lot whose connecting street may still
	# make it usable.
	if _placement_score(plan, corner, true) == -INF:
		return -2
	if not _access_reachable_after_block(plan, corner):
		return -1
	return place_at(kind, corner, district_tier)


## Whether a footprint can go here: inside the town, on ground everyone may walk on,
## level enough to stand a box on, clear of the lander and clear of everything already
## built.
func _suits(plan: Plan, corner: Vector2i) -> bool:
	return _placement_score(plan, corner) != -INF


## Placement-time connectivity with the proposed footprint treated as already
## blocked. Temporary road reservations remain traversable for this proof: they
## become roads or are released, and must not make a viable plot permanently fail.
func _access_reachable_after_block(plan: Plan, corner: Vector2i) -> bool:
	var access := _access_cells_for(plan, corner)
	var navigation_origin := _navigation_origin()
	if grid == null or claim == null or access.is_empty() \
			or not _walkable_outside(plan, corner, navigation_origin):
		return false
	# The colony already owns a shortest-path field to its exterior plaza gate.
	# Following one of those routes while treating this footprint as blocked is a
	# constructive proof of connectivity and normally costs only the route length.
	# The exhaustive flood remains below for a candidate whose one cached route
	# crosses the proposed building even though another route may exist.
	if _home_field_proves_access(plan, corner, access):
		return true
	if _access_floods_left <= 0:
		return false
	_access_floods_left -= 1
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	var side := grid.cells
	var cell_count := side * side
	var open := _open_cells_without(plan, corner)
	var goals := PackedByteArray()
	goals.resize(cell_count)
	for cell in access:
		goals[cell.y * side + cell.x] = 1
	var origin := navigation_origin.y * side + navigation_origin.x
	var queue := PackedInt32Array([origin])
	var seen := PackedByteArray()
	seen.resize(cell_count)
	seen[origin] = 1
	var cursor := 0
	var reached := false
	while cursor < queue.size():
		var at := queue[cursor]
		cursor += 1
		if goals[at] != 0:
			reached = true
			break
		var x := at % side
		var y := at / side
		for offset in MeepFlowField.STEPS:
			var next_x := x + offset.x
			var next_y := y + offset.y
			if next_x < 0 or next_y < 0 or next_x >= side or next_y >= side:
				continue
			var index := next_y * side + next_x
			if seen[index] != 0 or open[index] == 0:
				continue
			# A diagonal may not cut a corner between two blocked shoulders, the
			# same rule the cost fields walk by.
			if offset.x != 0 and offset.y != 0 \
					and (open[y * side + next_x] == 0 \
						or open[next_y * side + x] == 0):
				continue
			seen[index] = 1
			queue.push_back(index)
	if began > 0:
		RuntimeTelemetry.record_activity(&"meeps", &"place_access_flood",
			Time.get_ticks_usec() - began)
	return reached


func _home_field_proves_access(plan: Plan, corner: Vector2i,
		access: Array[Vector2i]) -> bool:
	if _colony == null:
		return false
	var field := _colony.call(&"_home_field") as MeepFlowField
	if field == null:
		return false
	var side := grid.cells
	var open := _open_cells_without(plan, corner)
	var step_limit := side * side
	for start in access:
		var cell := start
		for _step_index in step_limit:
			if cell == field.target:
				return true
			var offset := field.step_at(cell)
			if offset == Vector2i.ZERO:
				break
			var next_x := cell.x + offset.x
			var next_y := cell.y + offset.y
			if next_x < 0 or next_y < 0 or next_x >= side or next_y >= side:
				break
			if open[next_y * side + next_x] == 0:
				break
			if offset.x != 0 and offset.y != 0 \
					and (open[cell.y * side + next_x] == 0 \
						or open[next_y * side + cell.x] == 0):
				break
			cell = Vector2i(next_x, next_y)
	return false


## The walkable claim with a proposed footprint punched out of it.
##
## Connectivity is asked of eight neighbours and both shoulders of every diagonal for
## every cell a proof touches, and the honest form of that question is three method
## calls deep through the claim and the ground. Flattening it to one byte per cell
## turns each of those into an array read; the flattening itself is shared until the
## ground or the boundary changes.
func _open_cells_without(plan: Plan, corner: Vector2i) -> PackedByteArray:
	var side := grid.cells
	var open := _open_cells().duplicate()
	for offset_y in plan.span.y:
		var y := corner.y + offset_y
		if y < 0 or y >= side:
			continue
		for offset_x in plan.span.x:
			var x := corner.x + offset_x
			if x < 0 or x >= side:
				continue
			open[y * side + x] = 0
	return open


## Claimed cells a Meep may stand on, one byte each. See [method
## _open_cells_without].
func _open_cells() -> PackedByteArray:
	_refresh_ground_masks()
	return _open_mask


## Claimed cells a footprint may sit on: walkable, and not already spoken for by a
## building, a street, or a job's reservation.
func _plot_cells() -> PackedByteArray:
	_refresh_ground_masks()
	return _plot_mask


func _refresh_ground_masks() -> void:
	var total := grid.cells * grid.cells
	# The claim writes its membership straight into the grid flags, and the grid
	# bumps its revision for every other change these read, so those two numbers
	# together describe the whole input. Cell count catches a boundary that grew
	# without disturbing the ground under it.
	if _masks_revision == grid.revision and _masks_claim_count == claim.count \
			and _open_mask.size() == total:
		return
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_open_mask.resize(total)
	_plot_mask.resize(total)
	var flags := grid.flags
	var terrain := grid.terrain
	var taken := MeepGrid.FLAG_BUILDING | MeepGrid.FLAG_SHIP
	var spoken_for := MeepGrid.FLAG_ROAD | MeepGrid.FLAG_RESERVED \
		| MeepGrid.FLAG_PARK | MeepGrid.FLAG_PLANNED_LOT
	for at in total:
		var bits := int(flags[at])
		var standable := (bits & MeepGrid.FLAG_CLAIMED) != 0 \
			and (terrain[at] == MeepGrid.Terrain.PASSABLE
				or (bits & MeepGrid.FLAG_SURFACE) != 0) \
			and (bits & taken) == 0
		_open_mask[at] = 1 if standable else 0
		_plot_mask[at] = 1 if standable and grid.region_buildable_index(at) \
			and (bits & spoken_for) == 0 else 0
	_masks_revision = grid.revision
	_masks_claim_count = claim.count
	if began > 0:
		RuntimeTelemetry.record_activity(&"meeps", &"place_ground_masks",
			Time.get_ticks_usec() - began)


## The squared separation each existing site demands of one proposed plan, alongside
## the flat site positions the scan measures against.
##
## Spacing is symmetric in the two forms and neither moves during a scan, so the
## whole table is a constant of the placement pass.
func _separations_for(plan: Plan) -> PackedFloat64Array:
	if _separation_kind == plan.kind and _separation_stamp == _sites_stamp \
			and _separations.size() == _sites.size():
		return _separations
	var count := _sites.size()
	_separations.resize(count)
	_site_places.resize(count)
	var mine := maxf(plan.size.x, plan.size.z)
	for index in count:
		var entry := _sites[index]
		var theirs := plan_of(entry.kind)
		var apart := (mine + maxf(theirs.size.x, theirs.size.z)) * 0.5 \
			+ maxf(plan.spacing, theirs.spacing)
		_separations[index] = apart * apart
		_site_places[index] = entry.local
	_separation_kind = plan.kind
	_separation_stamp = _sites_stamp
	return _separations


func _navigation_origin() -> Vector2i:
	if _colony != null:
		return _colony.road_origin_cell()
	return claim.origin if claim != null else Vector2i.ZERO


func _walkable_outside(plan: Plan, corner: Vector2i, cell: Vector2i) -> bool:
	if not grid.inside(cell) or not claim.contains_cell(cell) \
			or not grid.passable(cell):
		return false
	var within := cell - corner
	return within.x < 0 or within.y < 0 \
		or within.x >= plan.span.x or within.y >= plan.span.y


## Distance from the ship to the nearest edge of a building plot. The grid footprints
## are axis-aligned in site space even while the whole site curves over the planet, so
## this is the exact circle-versus-rectangle separation needed by placement.
func _footprint_clearance(plan: Plan, middle: Vector2) -> float:
	var half := Vector2(plan.span) * grid.cell_size * 0.5
	var nearest := Vector2(
		maxf(absf(middle.x) - half.x, 0.0),
		maxf(absf(middle.y) - half.y, 0.0))
	return nearest.length()


## Public form used by validation and, later, anything drawing the landing plaza.
func clearance_from_ship(index: int) -> float:
	var entry := at(index)
	if entry == null or grid == null:
		return 0.0
	return _footprint_clearance(plan_of(entry.kind), entry.local)


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
			var cell := corner + Vector2i(x, y)
			lowest = minf(lowest, grid.walk_height_at(cell) \
				if plan.kind == Kind.DOCK_HUT else grid.height_at(cell))
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


func can_upgrade_vertical(index: int) -> bool:
	var entry := at(index)
	if entry == null or not entry.built() \
			or (not is_residential_kind(entry.kind) \
				and entry.kind != Kind.ABILITIES_HOUSE) \
			or entry.upgrading():
		return false
	var plan := plan_of(entry.kind)
	if entry.completed_floors >= plan.maximum_floors:
		return false
	# Vertical work never widens the footprint. Its reserved envelope is therefore
	# the existing deed plus a clear one-cell work ring; established roads may touch
	# that ring, but another building or active reservation may not.
	if grid == null:
		return true
	for x in range(-1, plan.span.x + 1):
		for y in range(-1, plan.span.y + 1):
			if x >= 0 and x < plan.span.x and y >= 0 and y < plan.span.y:
				continue
			var cell := entry.corner + Vector2i(x, y)
			if not grid.inside(cell):
				return false
			if grid.has_flag(cell, MeepGrid.FLAG_BUILDING) \
					or grid.has_flag(cell, MeepGrid.FLAG_RESERVED):
				return false
	return true


func begin_vertical_upgrade(index: int) -> bool:
	if not can_upgrade_vertical(index):
		return false
	var entry := at(index)
	entry.target_floors = entry.completed_floors + 1
	entry.upgrade_progress = 0.0
	_dirty = true
	return true


func upgrade_cost(index: int) -> float:
	var entry := at(index)
	return plan_of(entry.kind).cost * 0.5 if entry != null else INF


func upgrade_work(index: int) -> float:
	var entry := at(index)
	return plan_of(entry.kind).work * 0.65 if entry != null else INF


func advance_upgrade(index: int, seconds: float) -> bool:
	var entry := at(index)
	if entry == null or not entry.upgrading():
		return false
	entry.upgrade_progress = clampf(entry.upgrade_progress
		+ seconds / maxf(upgrade_work(index), 0.001), 0.0, 1.0)
	_dirty = true
	return entry.upgrade_progress >= 1.0


func complete_upgrade(index: int) -> bool:
	var entry := at(index)
	if entry == null or not entry.upgrading() or entry.upgrade_progress < 1.0:
		return false
	var plan := plan_of(entry.kind)
	entry.completed_floors = entry.target_floors
	entry.resident_slots = ceili(float(plan.resident_slots)
		* float(entry.completed_floors) / float(maxi(plan.floors, 1)))
	entry.upgrade_progress = 0.0
	_dirty = true
	return true


func display_height(index: int) -> float:
	var entry := at(index)
	if entry == null:
		return 0.0
	var plan := plan_of(entry.kind)
	var floors := float(entry.completed_floors)
	if entry.upgrading():
		floors += clampf(entry.upgrade_progress, 0.0, 1.0)
	return maxf(plan.floor_height * floors, plan.size.y \
		if plan.resident_slots <= 0 else plan.floor_height)


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
	var meshes := _shared_stand_meshes()
	for kind in Kind.size():
		var stand := MultiMeshInstance3D.new()
		stand.name = plan_of(kind).title
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = true
		batch.mesh = meshes[kind]
		stand.multimesh = batch
		add_child(stand)
		_stands.push_back(stand)


## One box and one material per building kind, shared by every town.
##
## Nothing writes to either after this: a building's colour, its unfinished shade and
## its footprint all come from the instance buffer. Building them per colony compiled
## a material variant per kind per town, which cost 19 ms the first time a city
## arrived and was repeated for every city after it.
static func _shared_stand_meshes() -> Array[Mesh]:
	if not _shared_stands.is_empty():
		return _shared_stands
	for kind in Kind.size():
		var mesh := BoxMesh.new()
		mesh.size = plan_of(kind).size
		var material := StandardMaterial3D.new()
		# White, with the kind's colour coming from the instance buffer instead. The
		# buffer has to speak so that an unfinished building can read as unfinished,
		# and an albedo tinted as well would multiply the colour into itself — which
		# is what turned a purple cloner navy and an orange hut brown.
		material.albedo_color = Color.WHITE
		material.roughness = 0.6
		material.vertex_color_use_as_albedo = true
		mesh.material = material
		_shared_stands.push_back(mesh)
	return _shared_stands


func _raise_colliders() -> void:
	for _slot in COLLIDER_POOL:
		var body := MeepStructureProxy.new()
		body.name = "Wall%d" % _colliders.size()
		body.configure(_colony)
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
	for index in _sites.size():
		var entry := _sites[index]
		var plan := plan_of(entry.kind)
		var batch := _stands[entry.kind].multimesh
		var slot := shown[entry.kind]
		shown[entry.kind] += 1
		var grow := maxf(entry.progress, FOUNDATION_SHARE)
		var height := display_height(index)
		var vertical_scale := height / maxf(plan.size.y, 0.001)
		var up := site.direction_at(entry.local)
		var east := site.east - up * site.east.dot(up)
		if east.length_squared() < 0.000001:
			east = site.north - up * site.north.dot(up)
		east = east.normalized()
		batch.set_instance_transform(slot, Transform3D(
			Basis(east, up * grow * vertical_scale, east.cross(up)),
			up * (site.planet_radius + entry.height
				+ height * grow * 0.5)))
		batch.set_instance_color(slot, plan.colour \
			if entry.built() and not entry.upgrading()
			else plan.colour * UNFINISHED_TINT)
	for kind in _stands.size():
		_stands[kind].multimesh.visible_instance_count = shown[kind]


## Hands the collider pool to the structures nearest the local camera. Same bargain
## as the Meeps' pick proxies and as flora collision: a fixed number of real shapes,
## given to whatever is close enough to be walked into this frame.
## [param eye] beyond [param town_radius] of the middle of town — the claim's own
## reach — means nothing here can be within collider range of it, and the pool can be
## handed back once instead of every structure being measured every frame. A planet
## of towns is mostly towns nobody is standing in.
func lend_colliders(eye: Vector2, town_radius := INF) -> void:
	if _colliders.is_empty() or site == null:
		return
	var reach := COLLIDER_RANGE * COLLIDER_RANGE
	if eye.length() > town_radius + COLLIDER_RANGE:
		if _colliders_lent:
			_colliders_lent = false
			_park_colliders()
		return
	_colliders_lent = true
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
			(body as MeepStructureProxy).set_lent(-1)
			if body.process_mode != Node.PROCESS_MODE_DISABLED:
				body.process_mode = Node.PROCESS_MODE_DISABLED
				body.collision_layer = 0
			continue
		var structure := nearby[slot].y
		var entry := _sites[structure]
		var plan := plan_of(entry.kind)
		var height := display_height(structure)
		var shape := body.get_child(0) as CollisionShape3D
		(shape.shape as BoxShape3D).size = Vector3(
			plan.size.x, height, plan.size.z)
		var up := site.direction_at(entry.local)
		var east := site.east - up * site.east.dot(up)
		east = east.normalized()
		body.transform = Transform3D(
			Basis(east, up, east.cross(up)),
			site.point_at(entry.local, entry.height + height * 0.5))
		body.collision_layer = 1
		body.process_mode = Node.PROCESS_MODE_INHERIT
		(body as MeepStructureProxy).set_lent(structure)


## Takes every shape back out of the world. Anything else would leave a town nobody
## is near still solid, which is a collision query cost and, on a returning player, a
## building whose collision is where the building used to be.
func _park_colliders() -> void:
	for body in _colliders:
		(body as MeepStructureProxy).set_lent(-1)
		if body.process_mode != Node.PROCESS_MODE_DISABLED:
			body.process_mode = Node.PROCESS_MODE_DISABLED
			body.collision_layer = 0


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


## Integers [method form_snapshot] carries per structure.
const FORM_STRIDE := 4
## Where the residential slot count sits inside one of those runs, so a reader that
## only wants housing does not have to reconstruct every site.
const FORM_SLOTS := 2


## Additive sidecar for residential state. The original three-integer placement
## snapshot remains unchanged for older peers and saved test fixtures.
func form_snapshot() -> PackedInt32Array:
	var out := PackedInt32Array()
	for entry in _sites:
		out.append_array(PackedInt32Array([
			entry.completed_floors,
			entry.target_floors,
			entry.resident_slots,
			entry.district_tier,
		]))
	return out


func upgrade_progress_snapshot() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for entry in _sites:
		out.push_back(entry.upgrade_progress)
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
			entry.completed_floors = plan.floors
			entry.target_floors = plan.floors
			entry.resident_slots = plan.resident_slots
			entry.district_tier = plan.tier
			entry.upgrade_progress = 0.0
			_dirty = true
			continue
		place_at(kind, corner)
	_sites_stamp += 1
	_rebuild_hut_indices()


func _rebuild_hut_indices() -> void:
	_hut_indices.clear()
	for index in _sites.size():
		if _sites[index].kind == Kind.HUT:
			_hut_indices.push_back(index)


func apply_progress(state: PackedFloat32Array) -> void:
	for index in mini(state.size(), _sites.size()):
		set_progress(index, state[index])


func apply_form_snapshot(state: PackedInt32Array,
		upgrades: PackedFloat32Array = PackedFloat32Array()) -> void:
	for index in mini(state.size() / FORM_STRIDE, _sites.size()):
		var entry := _sites[index]
		var plan := plan_of(entry.kind)
		entry.completed_floors = clampi(
			state[index * FORM_STRIDE], 1, plan.maximum_floors)
		entry.target_floors = clampi(
			state[index * FORM_STRIDE + 1],
			entry.completed_floors, plan.maximum_floors)
		entry.resident_slots = migrated_resident_slots(
			entry.kind, entry.completed_floors,
			state[index * FORM_STRIDE + FORM_SLOTS])
		entry.district_tier = clampi(state[index * FORM_STRIDE + 3], 0, 4)
		entry.upgrade_progress = clampf(upgrades[index], 0.0, 1.0) \
			if index < upgrades.size() else 0.0
	_dirty = true


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
	_sites_stamp += 1
