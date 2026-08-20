class_name MeepCityLedger
extends RefCounted

## A city advanced by arithmetic instead of by agents.
##
## [MeepColony] is the honest simulation: every settler is a row, walks to a tree,
## carries biomass back and works on a plot. It is also about six hundred kilobytes
## of navigation grid and a ten-hertz pass over every row, and it costs that whether
## the player is standing in the street or on the far side of the planet. Fifty of
## them is not a frame budget, it is a memory budget.
##
## So a city has two residency states. Near the player it is a [MeepColony] and
## nothing about it changes. Far away it is one of these: a few dozen scalars
## integrating the same rates the colony realises through its settlers, with no
## grid, no rows, no MultiMesh and no nodes at all. Score reads population from
## here either way, which is what keeps a planet-wide settler count continuously
## correct rather than correct only where somebody is looking.
##
## The constants are deliberately [MeepColony]'s own rather than a second set tuned
## to look similar, and its rules are copied rather than approximated: the same funded
## mining taper, the same two plots pegged out at once, the same street per building,
## the same housing-before-population order. Three rates cannot be borrowed, because the
## colony never states them — what a miner brings home, what a builder delivers, and how
## much street a town lays per house are all emergent there. Those three are named below,
## measured off the resident simulation by `dev/_scale_test.gd`, and held to it by the
## equivalence check rather than guessed at twice.
##
## What it cannot do is decide where a building goes. That is a question about the
## ground, and answering it needs the claim, the grid and the placement planner.
## So a ledger city banks what it has built as [member structures_owed] and the
## planner lays those plots out the moment the city is reified, which is the one
## thing a returning player sees resolve rather than having always been true.

## Biomass one miner brings in per second of being a miner.
##
## The colony never states this: it emerges from [constant MeepColony.MINE_SECONDS]
## of chopping, the walk out to the tree and back, and what the tree happened to
## pay. Measured by `dev/_scale_test.gd`, which runs the real town for twenty simulated
## minutes and divides the biomass it banked by the miner-seconds it spent banking it.
## That test is also what stops the two drifting apart the next time the walk or the
## flower yield is retuned.
##
## Measured against actual unstaffed Harvesters, not against all mining jobs the city
## would like to fill. Fixed roles deliberately leave some posted work unclaimed; using
## that larger request count as the denominator would discount the compact city twice.
## The value includes travel, idle turns and variable flora yield.
const BIOMASS_PER_MINER := 0.320
## Job seconds one settler on a construction crew contributes per second.
##
## Well short of [member MeepStats.work_rate], and that is the point: a settler with a
## building job spends much of its life not building. It walks to the plot, waits for the
## rest of the crew and walks home again. `dev/_scale_test.gd` measures it — the work of
## everything a real Tier 0 town finished, buildings and streets alike, over the
## settler-seconds its crews actually spent on them.
##
## Rarely the binding constraint. A Tier 0 town is short of biomass, not of hands, so
## this decides how promptly a hut goes up rather than how many the town ends with.
const BUILDER_EFFICIENCY := 0.32
## Two-metre road cells a town paves for each building it puts up.
##
## A resident town does not stand a hut in the grass and walk away: the planner runs a
## branch out to the plot and pays [constant MeepRoads.COST_PER_CELL] and
## [constant MeepRoads.WORK_PER_CELL] for every cell of it. Left out, an unwatched city
## would have a tenth of its income and a third of its labour free to spend on more
## housing than the settlers would ever have managed. Measured from the streets a real
## Tier 0 town laid per building by `dev/_scale_test.gd`. Founding blueprints replaced
## long ad-hoc branches with shared district trunks; the calibrated resident town now
## lays about eight new cells per completed building.
const STREET_CELLS_PER_STRUCTURE := 8.0
## Share of the living the town puts on building rather than mining or standing
## about, once mining is funded. The residual after [constant MeepColony.MINE_SHARE]
## in a town with nothing else to do.
const BUILD_SHARE := 0.35
## Longest span integrated in one step. A city returning from a save can owe hours;
## stepping it keeps the population/housing/tier feedback loop in the same order it
## would have happened in rather than resolving it all against the opening state.
const MAX_STEP := 5.0
## Steps one [method advance] will take, so a wildly stale timestamp cannot stall a
## frame. Anything past this is dropped rather than compressed, because a city that
## quietly ran a week in one frame is a bug either way.
const MAX_STEPS := 240

## Founding facts, exactly as [method MeepColonies._apply_found] would be given
## them. A ledger has to be able to become a colony without asking anything else
## where it is.
var site_id: StringName = &""
var direction := Vector3.UP
var facing := 0.0
var founded_seed := 0
var parent_site_id: StringName = &""
var display_name := ""
var claim_radius := MeepClaim.DEFAULT_RADIUS
var region_id: StringName = &""
var region_revision := -1

## Everything score and the city panel read.
var tier := 0
var alive := 0
var resources := 0.0
## Biomass already promised to a commissioned project. Compact simulation must
## preserve the same spendable-bank invariant as a resident colony.
var committed := 0.0
var housing_capacity := MeepColony.FIRST_WAVE
## Slots the town has actually raised, which is not the same number.
## [method MeepColony.housing_capacity] is `max(FIRST_WAVE, slots)`: the landed first
## wave sleeps in the ship, so the first three huts replace that allowance rather than
## adding to it. Adding instead would let an unwatched city house six more than a
## watched one all the way up, which is exactly the drift the equivalence test caught.
var residential_slots := 0
var harvester_rate := 0.0
## Everything physical about the town, in exactly the form the join snapshot
## carries it: structure placements and their progress, residential forms, streets,
## widths and surfaces, and the city's purchase history.
##
## Physical layout is held opaquely; only the progression scalars this ledger
## advances (bank, commitment, reach, and rate) are synchronized into its sidecar.
## A ledger cannot re-derive where a city stood without ground, and doing so would
## mean a returning player found its streets or purchases changed.
## The heavy part of a colony is its navigation grid and its ten-hertz pass over
## every settler, and neither of those is in here.
var physical: Dictionary = {}
## Placed layout, in the three-integers-per-site form
## [method MeepStructures.snapshot] uses. A live copy of `physical.structures`,
## because [method _wanted_kind] has to count cloners.
var structures := PackedInt32Array()
## Buildings finished while unwatched, counted per [enum MeepStructures.Kind]. The
## population and housing they granted are already in the fields above; only their
## plots are outstanding.
var structures_owed := PackedInt32Array()
## Job seconds left on the building currently going up, which kind it is, and the
## biomass promised to it. Promised rather than spent, exactly as
## [member MeepColony.committed] is, so [method available] reads the same either side
## of the residency line and a project given up hands its funding straight back.
var build_work_remaining := 0.0
var build_kind := -1
var build_cost := 0.0
## Completed labour waiting for an authored lot. The retained funding is retried
## only when the plan state or physical reach changes, never on every ledger tick.
var build_waiting_for_lot := false
var build_wait_radius := 0.0
var build_wait_plan_signature := 0
## Plots pegged out and paid for but not yet being worked on, up to
## [constant MeepColony.SITES_AT_ONCE] counting the one under way.
##
## A town with one project is not the town this models. The resident planner keeps two
## sites open and two paving branches going, and the biomass held against them is what
## keeps [method available] low enough that half the town stays in the woods. A ledger
## that commissioned one hut at a time read as well funded, sent its miners home, and
## grew at two thirds the rate the settlers managed.
var pegged_kinds := PackedInt32Array()
var pegged_costs := PackedFloat32Array()
var road_cells := 0
## Who lives here, in [method MeepColony.identity_snapshot]'s form, plus their
## deeds. Aggregates alone would be enough for the economy and for score, but a
## settler in this game has a name, an age, a house and a way they died; forgetting
## all of that because the player walked nine hundred metres would be a worse bug
## than the stall this whole mechanism exists to fix. It is a few strings per
## resident, which leaves the compact form compact.
var identities: Dictionary = {}
## Legacy and synthetic compact cities need no per-resident sidecar until somebody
## opens their roster or they reify. These four counts plus child ages preserve the
## role economy without manufacturing and scanning hundreds of placeholder rows.
var compact_roles := PackedInt32Array()
var compact_child_ages := PackedFloat64Array()
var compact_age_elapsed := 0.0
var compact_child_age_offset := 0.0
var deeds := PackedInt32Array()
## Last site-local position for every stable row, packed by
## [method MeepColony.resident_place_snapshot]. The compact simulation does not walk
## them, but returning to town resumes from here rather than from the colony ship.
var resident_places := PackedInt32Array()
## Fractional settlers, so a city advanced in short steps grows at the same rate as
## one advanced in long ones.
var clone_progress := 0.0
## This step's cloner count and next building, worked out once in [method advance].
var _cloners := 0
var _wanted := -1
## Seconds this ledger has integrated, for the equivalence test and for reports.
var elapsed := 0.0
var _lifecycle_rows_ready := false
var _role_cache_valid := false
var _cached_role_counts := PackedInt32Array()
var _child_rows := PackedInt32Array()
var _staffing_signature := -1
## Avoid recounting the four compact cohorts for every role lookup in one ledger
## step. All compact mutations preserve the total or change `alive`, so this is
## invalidated implicitly without another dirty flag.
var _compact_roles_for_alive := -1


func _init() -> void:
	structures_owed.resize(MeepStructures.Kind.size())


## Runs the city forward. The only method that changes anything.
func advance(seconds: float) -> void:
	if not is_finite(seconds) or seconds <= 0.0 or alive <= 0:
		return
	var left := minf(seconds, MAX_STEP * float(MAX_STEPS))
	while left > 0.0:
		var step := minf(left, MAX_STEP)
		left -= step
		elapsed += step
		_advance_identity_lifecycle(step)
		# Once per step, and used by earning, building and cloning alike. Each of
		# them wants to know what the town is saving up for, and working it out
		# means counting the cloners a town of fifty structures has: cheap once,
		# and the whole cost of a ledger three times over.
		_cloners = _count_of(MeepStructures.Kind.CLONER)
		_wanted = _wanted_kind()
		_expand(step)
		_earn(step)
		_build(step)
		_clone(step)
		_advance_tier()
	_sync_progression_reach()


func population_ceiling() -> int:
	return MeepColony.TIER_POPULATION_CEILINGS[
		clampi(tier, 0, MeepColony.MAX_CITY_TIER)]


## Biomass free to promise, mirroring [method MeepColony.available].
func available() -> float:
	return maxf(resources - committed, 0.0)


func _advance_identity_lifecycle(seconds: float) -> void:
	if identities.is_empty():
		_advance_compact_lifecycle(seconds)
		return
	_ensure_lifecycle_rows()
	if not _role_cache_valid:
		_rebuild_lifecycle_caches(
			identities.get("states", PackedByteArray()),
			identities.get("roles", PackedByteArray()))
	identities["_age_offset"] = maxf(float(identities.get(
		"_age_offset", 0.0)), 0.0) + seconds
	identities["_dead_for_offset"] = maxf(float(identities.get(
		"_dead_for_offset", 0.0)), 0.0) + seconds
	var states: PackedByteArray = identities.get(
		"states", PackedByteArray())
	var roles: PackedByteArray = identities.get(
		"roles", PackedByteArray())
	var ages: PackedFloat64Array = identities.get(
		"ages", PackedFloat64Array())
	var age_offset := float(identities.get("_age_offset", 0.0))
	for child_slot in range(_child_rows.size() - 1, -1, -1):
		var index := _child_rows[child_slot]
		if index < 0 or index >= states.size() \
				or states[index] == MeepColony.State.DEAD \
				or states[index] == MeepColony.State.DEPARTED:
			_child_rows.remove_at(child_slot)
			continue
		if ages[index] + age_offset + 0.0001 \
				< MeepColony.CHILDHOOD_SECONDS:
			continue
		var role := _adult_role_from_counts()
		roles[index] = role
		_cached_role_counts[MeepColony.Role.CHILD] -= 1
		_cached_role_counts[role] += 1
		_child_rows.remove_at(child_slot)
		_staffing_signature = -1
	identities["roles"] = roles
	var harvester_structure := _first_structure_of(
		MeepStructures.Kind.BIOMASS_HARVESTER)
	var signature := (harvester_structure + 1) * 10000 \
		+ _cached_role_counts[MeepColony.Role.HARVESTER]
	if signature == _staffing_signature:
		return
	_staffing_signature = signature
	var workplaces: PackedInt32Array = (identities.get(
		"workplaces", PackedInt32Array()) as PackedInt32Array).duplicate()
	states = states.duplicate()
	var staff_left := MeepColony.HARVESTER_STAFF_SLOTS \
		if harvester_structure >= 0 else 0
	for index in states.size():
		if states[index] == MeepColony.State.DEAD \
				or states[index] == MeepColony.State.DEPARTED:
			continue
		if roles[index] == MeepColony.Role.HARVESTER and staff_left > 0:
			workplaces[index] = harvester_structure
			states[index] = MeepColony.State.AT_WORKPLACE
			staff_left -= 1
		else:
			workplaces[index] = -1
			if states[index] == MeepColony.State.AT_WORKPLACE:
				states[index] = MeepColony.State.IDLE
	identities["states"] = states
	identities["workplaces"] = workplaces


func _adult_role_from_counts() -> int:
	var adult_total := _cached_role_counts[MeepColony.Role.BUILDER] \
		+ _cached_role_counts[MeepColony.Role.HARVESTER] \
		+ _cached_role_counts[MeepColony.Role.HOMEBODY] + 1
	var builder_target := maxi(roundi(float(adult_total)
		* MeepColony.BUILDER_ROLE_SHARE),
		mini(MeepColony.site_limit_for(tier, alive), adult_total))
	var harvester_target := mini(roundi(float(adult_total)
		* MeepColony.HARVESTER_ROLE_SHARE),
		maxi(adult_total - builder_target, 0))
	var deficits := PackedInt32Array([
		builder_target - _cached_role_counts[MeepColony.Role.BUILDER],
		harvester_target - _cached_role_counts[MeepColony.Role.HARVESTER],
		adult_total - builder_target - harvester_target
			- _cached_role_counts[MeepColony.Role.HOMEBODY],
	])
	var choices := PackedInt32Array([
		MeepColony.Role.BUILDER,
		MeepColony.Role.HARVESTER,
		MeepColony.Role.HOMEBODY,
	])
	var best := 0
	for slot in range(1, deficits.size()):
		if deficits[slot] > deficits[best]:
			best = slot
	return choices[best]


func _advance_compact_lifecycle(seconds: float) -> void:
	_ensure_compact_roles()
	compact_age_elapsed += seconds
	compact_child_age_offset += seconds
	while not compact_child_ages.is_empty() \
			and compact_child_ages[0] + compact_child_age_offset + 0.0001 \
				>= MeepColony.CHILDHOOD_SECONDS:
		compact_child_ages.remove_at(0)
		compact_roles[MeepColony.Role.CHILD] -= 1
		compact_roles[_compact_adult_role()] += 1


func _ensure_compact_roles() -> void:
	if compact_roles.size() != MeepColony.Role.size():
		compact_roles.resize(MeepColony.Role.size())
		_compact_roles_for_alive = -1
	if _compact_roles_for_alive == alive:
		return
	var counted := 0
	for value in compact_roles:
		counted += value
	if counted == alive:
		_compact_roles_for_alive = alive
		return
	var children := mini(compact_child_ages.size(), alive)
	compact_roles.fill(0)
	compact_roles[MeepColony.Role.CHILD] = children
	var adults := alive - children
	var builders := maxi(roundi(float(adults)
		* MeepColony.BUILDER_ROLE_SHARE),
		mini(MeepColony.site_limit_for(tier, alive), adults))
	var harvesters := mini(roundi(float(adults)
		* MeepColony.HARVESTER_ROLE_SHARE), maxi(adults - builders, 0))
	compact_roles[MeepColony.Role.BUILDER] = builders
	compact_roles[MeepColony.Role.HARVESTER] = harvesters
	compact_roles[MeepColony.Role.HOMEBODY] = adults - builders - harvesters
	_compact_roles_for_alive = alive


func _compact_adult_role() -> int:
	var adults := alive - compact_roles[MeepColony.Role.CHILD]
	var builder_target := maxi(roundi(float(adults)
		* MeepColony.BUILDER_ROLE_SHARE),
		mini(MeepColony.site_limit_for(tier, alive), adults))
	var harvester_target := mini(roundi(float(adults)
		* MeepColony.HARVESTER_ROLE_SHARE),
		maxi(adults - builder_target, 0))
	var targets := PackedInt32Array([
		builder_target - compact_roles[MeepColony.Role.BUILDER],
		harvester_target - compact_roles[MeepColony.Role.HARVESTER],
		adults - builder_target - harvester_target
			- compact_roles[MeepColony.Role.HOMEBODY],
	])
	var choices := PackedInt32Array([
		MeepColony.Role.BUILDER,
		MeepColony.Role.HARVESTER,
		MeepColony.Role.HOMEBODY,
	])
	var best := 0
	for slot in range(1, targets.size()):
		if targets[slot] > targets[best]:
			best = slot
	return choices[best]


func _materialize_compact_identities() -> void:
	if not identities.is_empty():
		return
	_ensure_compact_roles()
	var states := PackedByteArray()
	var roles := PackedByteArray()
	var ages := PackedFloat64Array()
	states.resize(alive)
	roles.resize(alive)
	ages.resize(alive)
	var row := 0
	for role in [
			MeepColony.Role.BUILDER,
			MeepColony.Role.HARVESTER,
			MeepColony.Role.HOMEBODY,
	]:
		for _member in compact_roles[role]:
			roles[row] = role
			ages[row] = compact_age_elapsed
			row += 1
	for child_age in compact_child_ages:
		if row >= alive:
			break
		roles[row] = MeepColony.Role.CHILD
		ages[row] = child_age + compact_child_age_offset
		row += 1
	identities = {
		"states": states,
		"roles": roles,
		"ages": ages,
		"maximum_health": 24.0,
	}
	compact_roles = PackedInt32Array()
	compact_child_ages = PackedFloat64Array()
	compact_age_elapsed = 0.0
	compact_child_age_offset = 0.0
	_lifecycle_rows_ready = false
	_role_cache_valid = false
	_ensure_lifecycle_rows()


func _ensure_lifecycle_rows() -> void:
	if _lifecycle_rows_ready:
		return
	var names: PackedStringArray = (identities.get(
		"names", PackedStringArray()) as PackedStringArray).duplicate()
	var siblings: PackedInt32Array = (identities.get(
		"siblings", PackedInt32Array()) as PackedInt32Array).duplicate()
	var ages: PackedFloat64Array = (identities.get(
		"ages", PackedFloat64Array()) as PackedFloat64Array).duplicate()
	var dead_for: PackedFloat64Array = (identities.get(
		"dead_for", PackedFloat64Array()) as PackedFloat64Array).duplicate()
	var causes: PackedStringArray = (identities.get(
		"death_causes", PackedStringArray()) as PackedStringArray).duplicate()
	var states: PackedByteArray = (identities.get(
		"states", PackedByteArray()) as PackedByteArray).duplicate()
	var roles: PackedByteArray = (identities.get(
		"roles", PackedByteArray()) as PackedByteArray).duplicate()
	var workplaces: PackedInt32Array = (identities.get(
		"workplaces", PackedInt32Array()) as PackedInt32Array).duplicate()
	var health: PackedFloat32Array = (identities.get(
		"health", PackedFloat32Array()) as PackedFloat32Array).duplicate()
	var former: PackedInt32Array = (identities.get(
		"former_deeds", PackedInt32Array()) as PackedInt32Array).duplicate()
	var count := maxi(names.size(), states.size())
	count = maxi(count, ages.size())
	count = maxi(count, roles.size())
	count = maxi(count, workplaces.size())
	count = maxi(count, health.size())
	var living := 0
	for state in states:
		if state != MeepColony.State.DEAD \
				and state != MeepColony.State.DEPARTED:
			living += 1
	while living < alive:
		count += 1
		living += 1
	while names.size() < count:
		names.push_back(MeepColony.generated_name_for(
			names.size(), founded_seed))
	while siblings.size() < count:
		var index := siblings.size()
		siblings.push_back(index - 1 if (index & 1) != 0 else -1)
		if (index & 1) != 0:
			siblings[index - 1] = index
	while ages.size() < count:
		ages.push_back(0.0)
	while dead_for.size() < count:
		dead_for.push_back(-1.0)
	while causes.size() < count:
		causes.push_back("")
	while states.size() < count:
		states.push_back(MeepColony.State.IDLE)
	while roles.size() < count:
		roles.push_back(255)
	while workplaces.size() < count:
		workplaces.push_back(-1)
	while former.size() < count:
		former.push_back(-1)
	var maximum_health := maxf(float(identities.get(
		"maximum_health", 24.0)), 1.0)
	while health.size() < count:
		health.push_back(maximum_health)
	# Legacy living rows are adults. Only explicit compact births below become children.
	for index in count:
		if states[index] != MeepColony.State.DEAD \
				and states[index] != MeepColony.State.DEPARTED \
				and roles[index] > MeepColony.Role.HARVESTER:
			roles[index] = _choose_compact_adult_role(index, roles, states)
	identities["names"] = names
	identities["siblings"] = siblings
	identities["ages"] = ages
	identities["dead_for"] = dead_for
	identities["death_causes"] = causes
	identities["states"] = states
	identities["roles"] = roles
	identities["workplaces"] = workplaces
	identities["health"] = health
	identities["maximum_health"] = maximum_health
	identities["former_deeds"] = former
	_lifecycle_rows_ready = true
	_rebuild_lifecycle_caches(states, roles)


func _rebuild_lifecycle_caches(states: PackedByteArray,
		roles: PackedByteArray) -> void:
	_cached_role_counts.resize(MeepColony.Role.size())
	_cached_role_counts.fill(0)
	_child_rows.clear()
	for index in mini(states.size(), roles.size()):
		if states[index] == MeepColony.State.DEAD \
				or states[index] == MeepColony.State.DEPARTED:
			continue
		var role := clampi(roles[index], MeepColony.Role.CHILD,
			MeepColony.Role.HARVESTER)
		_cached_role_counts[role] += 1
		if role == MeepColony.Role.CHILD:
			_child_rows.push_back(index)
	_role_cache_valid = true
	_staffing_signature = -1


func _choose_compact_adult_role(index: int, roles: PackedByteArray,
		states: PackedByteArray) -> int:
	var builders := 0
	var harvesters := 0
	var homebodies := 0
	for row in roles.size():
		if row == index or states[row] == MeepColony.State.DEAD \
				or states[row] == MeepColony.State.DEPARTED:
			continue
		match roles[row]:
			MeepColony.Role.BUILDER:
				builders += 1
			MeepColony.Role.HARVESTER:
				harvesters += 1
			MeepColony.Role.HOMEBODY:
				homebodies += 1
	var adult_total := builders + harvesters + homebodies + 1
	var builder_target := maxi(roundi(float(adult_total)
		* MeepColony.BUILDER_ROLE_SHARE),
		mini(MeepColony.site_limit_for(tier, alive), adult_total))
	var harvester_target := mini(roundi(float(adult_total)
		* MeepColony.HARVESTER_ROLE_SHARE),
		maxi(adult_total - builder_target, 0))
	var targets := [
		builder_target - builders,
		harvester_target - harvesters,
		adult_total - builder_target - harvester_target - homebodies,
	]
	var choices := [
		MeepColony.Role.BUILDER,
		MeepColony.Role.HARVESTER,
		MeepColony.Role.HOMEBODY,
	]
	var best := 0
	for slot in range(1, targets.size()):
		if int(targets[slot]) > int(targets[best]):
			best = slot
	return choices[best]


func _append_compact_child() -> void:
	if identities.is_empty():
		_ensure_compact_roles()
		compact_child_ages.push_back(-compact_child_age_offset)
		compact_roles[MeepColony.Role.CHILD] += 1
		return
	_ensure_lifecycle_rows()
	var names: PackedStringArray = (identities["names"]
		as PackedStringArray).duplicate()
	var siblings: PackedInt32Array = (identities["siblings"]
		as PackedInt32Array).duplicate()
	var ages: PackedFloat64Array = (identities["ages"]
		as PackedFloat64Array).duplicate()
	var dead_for: PackedFloat64Array = (identities["dead_for"]
		as PackedFloat64Array).duplicate()
	var causes: PackedStringArray = (identities["death_causes"]
		as PackedStringArray).duplicate()
	var states: PackedByteArray = (identities["states"]
		as PackedByteArray).duplicate()
	var roles: PackedByteArray = (identities["roles"]
		as PackedByteArray).duplicate()
	var workplaces: PackedInt32Array = (identities["workplaces"]
		as PackedInt32Array).duplicate()
	var health: PackedFloat32Array = (identities["health"]
		as PackedFloat32Array).duplicate()
	var former: PackedInt32Array = (identities["former_deeds"]
		as PackedInt32Array).duplicate()
	var index := names.size()
	names.push_back(MeepColony.generated_name_for(index, founded_seed))
	siblings.push_back(index - 1 if (index & 1) != 0 else -1)
	if (index & 1) != 0:
		siblings[index - 1] = index
	ages.push_back(-maxf(float(identities.get("_age_offset", 0.0)), 0.0))
	dead_for.push_back(-1.0)
	causes.push_back("")
	states.push_back(MeepColony.State.IDLE)
	roles.push_back(MeepColony.Role.CHILD)
	workplaces.push_back(-1)
	health.push_back(maxf(float(identities.get(
		"maximum_health", 24.0)), 1.0))
	former.push_back(-1)
	identities["names"] = names
	identities["siblings"] = siblings
	identities["ages"] = ages
	identities["dead_for"] = dead_for
	identities["death_causes"] = causes
	identities["states"] = states
	identities["roles"] = roles
	identities["workplaces"] = workplaces
	identities["health"] = health
	identities["former_deeds"] = former
	_cached_role_counts[MeepColony.Role.CHILD] += 1
	_child_rows.push_back(index)
	_staffing_signature = -1


func _role_count(role: int) -> int:
	if identities.is_empty():
		_ensure_compact_roles()
		return compact_roles[clampi(
			role, MeepColony.Role.CHILD, MeepColony.Role.HARVESTER)]
	_ensure_lifecycle_rows()
	if not _role_cache_valid:
		_rebuild_lifecycle_caches(
			identities.get("states", PackedByteArray()),
			identities.get("roles", PackedByteArray()))
	return _cached_role_counts[clampi(
		role, MeepColony.Role.CHILD, MeepColony.Role.HARVESTER)]


func _first_structure_of(kind: int) -> int:
	var structure := 0
	for offset in range(0, structures.size(), 3):
		if structures[offset] == kind:
			return structure
		structure += 1
	return -1


func _staffed_harvesters() -> int:
	if _first_structure_of(MeepStructures.Kind.BIOMASS_HARVESTER) < 0:
		return 0
	return mini(_role_count(MeepColony.Role.HARVESTER),
		MeepColony.HARVESTER_STAFF_SLOTS)


func staffed_harvesters() -> int:
	return _staffed_harvesters()


func _unstaffed_harvesters() -> int:
	return maxi(_role_count(MeepColony.Role.HARVESTER)
		- _staffed_harvesters(), 0)


func structures_placed() -> int:
	return structures.size() / 3


func role_counts() -> PackedInt32Array:
	if identities.is_empty():
		_ensure_compact_roles()
		return compact_roles.duplicate()
	_ensure_lifecycle_rows()
	if not _role_cache_valid:
		_rebuild_lifecycle_caches(
			identities.get("states", PackedByteArray()),
			identities.get("roles", PackedByteArray()))
	return _cached_role_counts.duplicate()


func meep_roster() -> Array:
	_materialize_compact_identities()
	_ensure_lifecycle_rows()
	var rows: Array = []
	var names: PackedStringArray = identities.get("names", PackedStringArray())
	var ages: PackedFloat64Array = identities.get("ages", PackedFloat64Array())
	var dead_for: PackedFloat64Array = identities.get(
		"dead_for", PackedFloat64Array())
	var causes: PackedStringArray = identities.get(
		"death_causes", PackedStringArray())
	var states: PackedByteArray = identities.get("states", PackedByteArray())
	var roles: PackedByteArray = identities.get("roles", PackedByteArray())
	var health: PackedFloat32Array = identities.get(
		"health", PackedFloat32Array())
	var maximum_health := maxf(float(identities.get(
		"maximum_health", 24.0)), 1.0)
	var age_offset := maxf(float(identities.get("_age_offset", 0.0)), 0.0)
	var dead_offset := maxf(float(identities.get(
		"_dead_for_offset", 0.0)), 0.0)
	for index in states.size():
		if states[index] == MeepColony.State.DEPARTED:
			continue
		var role := clampi(roles[index], MeepColony.Role.CHILD,
			MeepColony.Role.HARVESTER) as MeepColony.Role
		var current_health := maxf(float(health[index]), 0.0)
		var row := {
			"index": index,
			"name": names[index],
			"age_seconds": float(ages[index]) + (
				0.0 if states[index] == MeepColony.State.DEAD
				else age_offset),
			"status": "dead" if states[index] == MeepColony.State.DEAD \
				else "alive",
			"health": current_health,
			"maximum_health": maximum_health,
			"type": MeepColony.role_name(role),
			"role": int(role),
			"activity": "Away from view",
			"home": "Home recorded",
			"sibling": "Recorded",
			"death_seconds_ago": maxf(float(dead_for[index])
				+ (dead_offset if states[index] == MeepColony.State.DEAD
					else 0.0), 0.0),
			"death_cause": causes[index] if not causes[index].is_empty() \
				else "Killed in combat",
			"tile_stats": {
				"TYPE": MeepColony.role_name(role),
				"HEALTH": "%d / %d" % [
					roundi(current_health), roundi(maximum_health)],
			},
		}
		rows.push_back(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_dead := String(a.get("status", "")) == "dead"
		var b_dead := String(b.get("status", "")) == "dead"
		if a_dead != b_dead:
			return not a_dead
		return String(a.get("name", "")).naturalnocasecmp_to(
			String(b.get("name", ""))) < 0)
	return rows


func identity_snapshot() -> Dictionary:
	_materialize_compact_identities()
	_ensure_lifecycle_rows()
	var snapshot := identities.duplicate(true)
	var states: PackedByteArray = snapshot.get(
		"states", PackedByteArray())
	var ages: PackedFloat64Array = (snapshot.get(
		"ages", PackedFloat64Array()) as PackedFloat64Array).duplicate()
	var dead_for: PackedFloat64Array = (snapshot.get(
		"dead_for", PackedFloat64Array()) as PackedFloat64Array).duplicate()
	var age_offset := maxf(float(snapshot.get("_age_offset", 0.0)), 0.0)
	var dead_offset := maxf(float(snapshot.get(
		"_dead_for_offset", 0.0)), 0.0)
	for index in states.size():
		if states[index] == MeepColony.State.DEAD:
			dead_for[index] = maxf(dead_for[index], 0.0) + dead_offset
		elif states[index] != MeepColony.State.DEPARTED:
			ages[index] = maxf(ages[index] + age_offset, 0.0)
	snapshot["ages"] = ages
	snapshot["dead_for"] = dead_for
	snapshot.erase("_age_offset")
	snapshot.erase("_dead_for_offset")
	return snapshot


func city_plan_style_name() -> String:
	var state := _city_plan_state()
	match clampi(int(state.get("style", 0)), 0,
			MeepCityPlan.Style.size() - 1):
		MeepCityPlan.Style.RING_AND_SPOKE:
			return "Ring and Spoke"
		MeepCityPlan.Style.ORGANIC_BRANCHES:
			return "Organic Branches"
		MeepCityPlan.Style.PARK_COURTYARDS:
			return "Park Courtyards"
		MeepCityPlan.Style.TERRACES:
			return "Terraces"
		_:
			return "Grid Boroughs"


func city_plan_active_districts() -> int:
	return maxi(int(_city_plan_state().get("active_districts", 1)), 1)


func city_plan_district_count() -> int:
	var districts: PackedInt32Array = _city_plan_state().get(
		"districts", PackedInt32Array())
	return districts.size() / MeepCityPlan.DISTRICT_STRIDE


func city_plan_has_pending_expansion() -> bool:
	return int(_city_plan_state().get("requested_district", -1)) >= 0


func city_plan_lot_summary() -> Dictionary:
	var state := _city_plan_state()
	var lots: PackedInt32Array = state.get("lots", PackedInt32Array())
	var states: PackedByteArray = state.get(
		"lot_states", PackedByteArray())
	var free := 0
	var owed := 0
	var blocked := 0
	for index in lots.size() / MeepCityPlan.LOT_STRIDE:
		var lot_state := states[index] \
			if index < states.size() else MeepCityPlan.LOT_FREE
		if lot_state == MeepCityPlan.LOT_FREE:
			free += 1
		elif lot_state == MeepCityPlan.LOT_OWED:
			owed += 1
		elif lot_state == MeepCityPlan.LOT_BLOCKED \
				or lot_state == MeepCityPlan.LOT_REGION_BLOCKED:
			blocked += 1
	return {
		"total": lots.size() / MeepCityPlan.LOT_STRIDE,
		"free": free,
		"owed": owed,
		"blocked": blocked,
	}


func structures_pending() -> int:
	var owed := 0
	for count in structures_owed:
		owed += count
	return owed


## Carries an interrupted return queue back across the residency line. Normal
## distance-based distillation waits for replay, but direct calls and save boundaries
## still use this guard so completed buildings can never be discarded.
func add_structures_owed(state: PackedInt32Array,
		grant_housing := true) -> void:
	for kind in mini(state.size(), structures_owed.size()):
		var count := maxi(state[kind], 0)
		if count <= 0:
			continue
		structures_owed[kind] += count
		if grant_housing:
			residential_slots += MeepStructures.plan_of(kind).resident_slots * count
	if grant_housing:
		housing_capacity = maxi(MeepColony.FIRST_WAVE, residential_slots)


## Old saves could retain a completed city-purchase flag after losing the replay
## queue that represented its physical building. Recreate only those explicit
## commissions; routine housing remains governed by its saved owed counts.
func repair_commissioned_owed() -> void:
	var progression_variant: Variant = physical.get("progression", {})
	if not progression_variant is Dictionary:
		return
	var built := int((progression_variant as Dictionary).get("built_flags", 0))
	_ensure_commissioned_count(MeepStructures.Kind.HAT_HOUSE, 1,
		built, MeepColony.CityPurchase.HAT_HOUSE)
	_ensure_commissioned_count(MeepStructures.Kind.ABILITIES_HOUSE, 1,
		built, MeepColony.CityPurchase.ABILITIES_HOUSE)
	_ensure_commissioned_count(MeepStructures.Kind.BIOMASS_HARVESTER, 1,
		built, MeepColony.CityPurchase.BIOMASS_HARVESTER)
	var cloners := 1
	if (built & (1 << MeepColony.CityPurchase.SECOND_CLONER)) != 0:
		cloners = 2
	if (built & (1 << MeepColony.CityPurchase.THIRD_CLONER)) != 0:
		cloners = 3
	if (built & (1 << MeepColony.CityPurchase.FOURTH_CLONER)) != 0:
		cloners = 4
	var missing_cloners := cloners - _count_of(MeepStructures.Kind.CLONER) \
		- _pegged_of(MeepStructures.Kind.CLONER)
	if missing_cloners > 0:
		structures_owed[MeepStructures.Kind.CLONER] += missing_cloners


func _ensure_commissioned_count(kind: int, wanted: int, flags: int,
		purchase: int) -> void:
	if (flags & (1 << purchase)) == 0:
		return
	var missing := wanted - _count_of(kind) - _pegged_of(kind)
	if missing > 0:
		structures_owed[kind] += missing


# --- Growth ------------------------------------------------------------------

func expansion_rate() -> float:
	return MeepColony.EXPANSION_BASE_RATE \
		+ MeepColony.population_expansion_bonus(alive)


## An unwatched city owns the same continuously advancing radius as a resident one.
## The terrain-shaped flood is rebuilt when the city is reified; the ledger only
## needs to preserve how far that flood is now allowed to reach.
## The sidecar is not synchronized here. Nothing reads it between steps — it is for
## saving, sending and reifying, all of which go through [method to_dictionary] or the
## end of [method advance], and writing three dictionary entries per step for fifty
## cities was most of what a planet-wide tick cost.
func _expand(seconds: float) -> void:
	# This runs for every compact city on every ledger step. Read the plan in place;
	# duplicating an often-empty progression dictionary made fifty idle cities spend
	# most of their planet-wide microsecond budget merely checking for border demand.
	var progression_variant: Variant = physical.get("progression", null)
	if progression_variant is Dictionary:
		var plan_variant: Variant = (progression_variant as Dictionary).get(
			"city_plan", null)
		if plan_variant is Dictionary:
			var plan := plan_variant as Dictionary
			if int(plan.get("version", 0)) == MeepCityPlan.VERSION:
				var target := MeepCityPlan.ledger_target_radius(plan)
				if target <= 0.0:
					return
				claim_radius = minf(claim_radius + expansion_rate() * seconds,
					minf(target, MeepColony.MAX_CLAIM_RADIUS))
				_store_city_plan_state(
					MeepCityPlan.ledger_finish_expansion(plan, claim_radius))
				return
	# A pre-blueprint ledger has no ground with which to choose a safe envelope.
	# Freeze its saved reach until reification can migrate it around developed cells.
	return


func _sync_progression_reach() -> void:
	var progression_variant: Variant = physical.get("progression", {})
	if progression_variant is Dictionary:
		var progression := progression_variant as Dictionary
		progression["claim_radius"] = claim_radius
		progression["resources"] = resources
		progression["committed"] = committed
		progression["region_id"] = String(region_id)
		progression["region_revision"] = region_revision
		physical["progression"] = progression


func _city_plan_state() -> Dictionary:
	var progression_variant: Variant = physical.get("progression", {})
	if not progression_variant is Dictionary:
		return {}
	var plan_variant: Variant = (progression_variant as Dictionary).get(
		"city_plan", {})
	return (plan_variant as Dictionary).duplicate(true) \
		if plan_variant is Dictionary else {}


func _has_packed_city_plan() -> bool:
	var progression_variant: Variant = physical.get("progression", null)
	if not progression_variant is Dictionary:
		return false
	var plan_variant: Variant = (progression_variant as Dictionary).get(
		"city_plan", null)
	return plan_variant is Dictionary \
		and not (plan_variant as Dictionary).is_empty()


func _store_city_plan_state(plan: Dictionary) -> void:
	var progression_variant: Variant = physical.get("progression", {})
	if not progression_variant is Dictionary:
		return
	var progression := progression_variant as Dictionary
	progression["city_plan"] = plan
	physical["progression"] = progression


func _city_plan_signature() -> int:
	var plan := _city_plan_state()
	if plan.is_empty():
		return 0
	return hash(plan.get("lot_states", PackedByteArray())) \
		^ (int(plan.get("active_districts", 1)) * 65537) \
		^ (int(plan.get("requested_district", -1)) * 104729) \
		^ int(plan.get("version", 0))


func _planned_kind(kind: int) -> int:
	if kind < 0:
		return -1
	if not _has_packed_city_plan():
		return kind
	var plan := _city_plan_state()
	if plan.is_empty():
		return kind
	var prepared := MeepCityPlan.ledger_prepare_lot(
		plan, kind, claim_radius, _pegged_of(kind), false)
	if not bool(prepared.get("managed", false)):
		return kind
	_store_city_plan_state(prepared.get("state", plan))
	return kind if bool(prepared.get("ready", false)) else -1


func _reserve_city_plan_lot(kind: int) -> bool:
	if not _has_packed_city_plan():
		return true
	var plan := _city_plan_state()
	if plan.is_empty():
		return true
	var prepared := MeepCityPlan.ledger_prepare_lot(
		plan, kind, claim_radius, 0, true)
	if not bool(prepared.get("managed", false)):
		return true
	_store_city_plan_state(prepared.get("state", plan))
	return bool(prepared.get("ready", false))


## Mining and the harvester. Both are rates in the resident city too; the
## difference is only that there nobody is holding a stopwatch to a settler.
func _earn(seconds: float) -> void:
	var harvester_roles := _role_count(MeepColony.Role.HARVESTER)
	var staffed := mini(harvester_roles, MeepColony.HARVESTER_STAFF_SLOTS) \
		if _first_structure_of(
			MeepStructures.Kind.BIOMASS_HARVESTER) >= 0 else 0
	var outdoor := maxi(harvester_roles - staffed, 0)
	resources += float(_miners(outdoor)) * BIOMASS_PER_MINER * seconds
	resources += harvester_rate * (1.0 + float(staffed)
		* MeepColony.HARVESTER_STAFF_BONUS) * seconds


func effective_harvester_rate() -> float:
	return harvester_rate * (1.0 + float(_staffed_harvesters())
		* MeepColony.HARVESTER_STAFF_BONUS)


## [method MeepColony.mining_job_target] with the settlers taken out.
##
## Worth mirroring rather than approximating: a town does not switch between mining
## and building, it slides, and the slide is the whole reason a resident city keeps
## a modest bank instead of oscillating between hoarding and starving. An earlier
## version here flipped on a threshold and the equivalence test caught it at once as
## an unwatched city that could not afford to build.
func _miners(available_harvesters := -1) -> int:
	var runway := _runway()
	var coverage := clampf(available() / maxf(runway * 2.0, 0.001), 0.0, 1.0)
	var share := lerpf(MeepColony.MINE_SHARE, MeepColony.MINE_SHARE_FUNDED,
		coverage)
	var floor_jobs := MeepColony.MINE_JOBS_MIN if available() < runway \
		else MeepColony.MINE_JOBS_FUNDED_MIN
	var wanted := maxi(floor_jobs, roundi(float(alive) * share))
	var harvesters := _unstaffed_harvesters() \
		if available_harvesters < 0 else available_harvesters
	return clampi(wanted, 0, harvesters)


## Biomass the town wants on hand for its next move, by
## [method MeepColony.mining_resource_runway]'s reckoning: the next building, a street
## branch while the tier is unfinished, and whatever the cloner could currently use.
func _runway() -> float:
	var runway := 0.0
	if _wanted >= 0:
		runway += MeepStructures.plan_of(_wanted).cost
		runway += MeepColony.MINE_ROAD_RUNWAY
	if _cloners > 0:
		var room := maxi(housing_capacity - alive, 0)
		runway += float(mini(
			room, MeepColony.CLONE_CREW * _cloners)) \
			* MeepColony.CLONE_COST
	return maxf(runway, MeepColony.CLONE_COST)


## A project is a building and the street branch that reaches it, which is how the
## resident planner commissions them and where a tenth of a town's biomass and a third
## of its labour goes. Several are funded at once; one is worked on at a time.
func _build(seconds: float) -> void:
	_peg_out()
	if build_kind < 0:
		return
	var builders := _builders()
	if builders <= 0:
		return
	if build_waiting_for_lot:
		var signature := _city_plan_signature()
		if is_equal_approx(claim_radius, build_wait_radius) \
				and signature == build_wait_plan_signature:
			return
		build_waiting_for_lot = false
	var plan := MeepStructures.plan_of(build_kind)
	build_work_remaining -= float(_crew(plan, builders)) \
		* BUILDER_EFFICIENCY * seconds
	if build_work_remaining > 0.0:
		return
	_finish_project(plan)


## Hands on the work. Not one crew: a project is a building and a street, each with a
## crew of its own, and the resident planner keeps as many projects open as it can
## afford. Labour is therefore whichever runs out first — the settlers the town can
## spare for building, or the places there are to put them.
func _crew(plan: MeepStructures.Plan, builders := -1) -> int:
	var places := _projects() * (plan.crew + MeepRoads.CREW)
	var available_builders := _builders() if builders < 0 else builders
	return clampi(available_builders, 0, maxi(places, 1))


## Pegs out plots while the town wants one and can pay for it. Paying up front is what
## [member MeepColony.committed] means; the crew arrives later.
func _peg_out() -> void:
	var first := true
	while _projects() < MeepColony.site_limit_for(tier, alive):
		# Freshly each time rather than the step's cached answer: pegging out a plot
		# is what changes whether the town wants another.
		# The first answer is still current unless earning moved a surplus-only
		# city across its prebuild threshold; a negative answer is therefore
		# rechecked, while the ordinary positive path avoids a duplicate plan scan.
		var kind := _wanted if first and _wanted >= 0 else _wanted_kind()
		first = false
		if kind < 0:
			return
		var price := MeepStructures.plan_of(kind).cost \
			+ STREET_CELLS_PER_STRUCTURE * MeepRoads.COST_PER_CELL
		if available() < price:
			return
		committed += price
		if build_kind < 0:
			_start_project(kind, price)
		else:
			pegged_kinds.push_back(kind)
			pegged_costs.push_back(price)


func _start_project(kind: int, price: float) -> void:
	build_kind = kind
	build_cost = price
	build_waiting_for_lot = false
	build_work_remaining = MeepStructures.plan_of(kind).work \
		+ STREET_CELLS_PER_STRUCTURE * MeepRoads.WORK_PER_CELL


func _finish_project(plan: MeepStructures.Plan) -> void:
	if not _reserve_city_plan_lot(build_kind):
		# The physical lot remains authoritative. A compact city can finish the
		# labour early, but it may not mint virtual housing ahead of its border.
		build_work_remaining = 0.0
		build_waiting_for_lot = true
		build_wait_radius = claim_radius
		build_wait_plan_signature = _city_plan_signature()
		return
	resources = maxf(resources - build_cost, 0.0)
	committed = maxf(committed - build_cost, 0.0)
	road_cells += roundi(STREET_CELLS_PER_STRUCTURE)
	structures_owed[build_kind] += 1
	if plan.resident_slots > 0:
		residential_slots += plan.resident_slots
		housing_capacity = maxi(MeepColony.FIRST_WAVE, residential_slots)
	if build_kind == MeepStructures.Kind.BIOMASS_HARVESTER:
		harvester_rate = maxf(harvester_rate, MeepColony.HARVEST_BASE_RATE)
	build_kind = -1
	build_cost = 0.0
	build_work_remaining = 0.0
	build_waiting_for_lot = false
	if pegged_kinds.is_empty():
		return
	# The crew walks straight to the next plot it already has.
	var next_kind := pegged_kinds[0]
	var next_cost := pegged_costs[0]
	pegged_kinds.remove_at(0)
	pegged_costs.remove_at(0)
	_start_project(next_kind, next_cost)


func _builders() -> int:
	return _role_count(MeepColony.Role.BUILDER)


## What the town puts up next. The resident planner's order, minus the parts that
## are questions about the ground: a cloner first because it is the only way a city
## grows, then housing for the tier it has reached.
func _wanted_kind() -> int:
	if _cloners + _pegged_of(MeepStructures.Kind.CLONER) == 0:
		return _planned_kind(MeepStructures.Kind.CLONER)
	# Nothing else goes up while the cloner does, exactly as the resident planner
	# refuses to look past it: a town without one cannot grow at all.
	if _cloners == 0:
		return -1
	if tier <= 0 and structures_placed() + structures_pending() \
			+ _projects() >= _tier_zero_structure_target():
		return -1
	if housing_capacity >= population_ceiling():
		return -1
	# Match the resident city's clone -> housing -> clone cadence instead of silently
	# filling an unwatched settlement to its tier ceiling before anybody moves in.
	# A deliberate player stockpile is the exception: it wakes the fixed Builder
	# reserve and buys only the next authored lot, exactly like a resident city.
	if tier > 0 and alive < housing_capacity:
		var growth_kind := MeepStructures.residential_kind_for_growth(
			tier, alive)
		var runway := MeepStructures.plan_of(growth_kind).cost \
			+ MeepColony.MINE_ROAD_RUNWAY
		if available() < runway * MeepColony.PREBUILD_SURPLUS_MULTIPLIER:
			return -1
		return _planned_kind(growth_kind)
	return _planned_kind(
		MeepStructures.residential_kind_for_growth(tier, alive))


## Structures this claim allocates to Tier 0, by the rule
## [method MeepColony.tier_zero_structure_target] uses. The claim's real traced area
## is not available without a grid, so the disc it was asked for stands in for it.
func _tier_zero_structure_target() -> int:
	var area := PI * claim_radius * claim_radius
	return clampi(floori(area / MeepColony.TIER_ZERO_LOT_AREA),
		MeepColony.STARTER_STRUCTURES, MeepColony.TIER_ZERO_MAX_STRUCTURES)


## Plots pegged out and unfinished, the one being worked on included. What
## [method MeepStructures.count] less its built sites is for a resident town.
func _projects() -> int:
	return pegged_kinds.size() + (1 if build_kind >= 0 else 0)


func _pegged_of(kind: int) -> int:
	var found := 1 if build_kind == kind else 0
	for pegged in pegged_kinds:
		if pegged == kind:
			found += 1
	return found


func _count_of(kind: int) -> int:
	var found := structures_owed[clampi(kind, 0, structures_owed.size() - 1)]
	var index := 0
	while index < structures.size():
		if structures[index] == kind:
			found += 1
		index += 3
	return found


## The cloners. Biomass is the real gate here exactly as it is in the resident city:
## every completed machine contributes five simultaneous one-second incubation slots.
func _clone(seconds: float) -> void:
	var room := mini(housing_capacity, population_ceiling()) - alive
	var clone_workers := mini(_role_count(MeepColony.Role.HOMEBODY),
		MeepColony.CLONE_CREW * _cloners)
	if room <= 0 or _cloners == 0 or clone_workers <= 0:
		clone_progress = 0.0
		return
	clone_progress += seconds * float(clone_workers) \
		/ maxf(MeepColony.CLONE_SECONDS, 0.001)
	while clone_progress >= 1.0 and room > 0 \
			and available() >= MeepColony.CLONE_COST:
		clone_progress -= 1.0
		resources -= MeepColony.CLONE_COST
		_append_compact_child()
		alive += 1
		room -= 1
	clone_progress = minf(clone_progress, 1.0)


## Architectural tiers advance from completed development, the same trigger
## [method MeepColony._refresh_current_tier_completion] uses. A ledger city has no
## unfinished roads or upgrades to wait on, so housing for the whole ceiling is the
## whole of the test.
func _advance_tier() -> void:
	while tier < MeepColony.MAX_CITY_TIER \
			and housing_capacity >= population_ceiling() \
			and build_kind < 0:
		tier += 1


# --- Crossing the residency line --------------------------------------------

## Gives up every plot pegged out here and hands their funding back to the bank.
##
## Called as a city becomes resident. The planner is about to decide for itself what to
## build and where, and it knows nothing of promises made while it did not exist; left
## standing, those promises would hold biomass the town could never spend again. What is
## lost is the part-finished work on one building, which the planner re-posts within a
## tick.
func abandon_projects() -> void:
	var held := build_cost
	for cost in pegged_costs:
		held += cost
	committed = maxf(committed - held, 0.0)
	pegged_kinds.clear()
	pegged_costs.clear()
	build_kind = -1
	build_cost = 0.0
	build_work_remaining = 0.0
	build_waiting_for_lot = false


## Takes the aggregates off a colony that is about to be freed.
func absorb(from: MeepColony) -> void:
	site_id = from.site_id
	direction = from.site.centre if from.site != null else direction
	facing = from.site.facing if from.site != null else facing
	founded_seed = from.founded_seed
	parent_site_id = from.parent_site_id
	display_name = from.display_name
	region_id = from.region_id
	region_revision = from.region_revision
	claim_radius = from.claim_radius
	tier = from.tier
	alive = from.alive_count()
	resources = from.resources
	committed = clampf(from.committed, 0.0, resources)
	residential_slots = from.structures.residential_capacity(true) \
		if from.structures != null else 0
	housing_capacity = maxi(MeepColony.FIRST_WAVE, residential_slots)
	harvester_rate = from.harvester_base_rate()
	structures = from.structures.snapshot() \
		if from.structures != null else PackedInt32Array()
	road_cells = from.roads.cell_count() if from.roads != null else 0
	identities = from.identity_snapshot()
	deeds = from.deed_snapshot()
	resident_places = from.resident_place_snapshot()
	physical = {
		"progression": from.city_progression_snapshot(),
		"structures": structures,
		"raised": from.structures.progress_snapshot() \
			if from.structures != null else PackedFloat32Array(),
		"structure_forms": from.structures.form_snapshot() \
			if from.structures != null else PackedInt32Array(),
		"structure_upgrades": from.structures.upgrade_progress_snapshot() \
			if from.structures != null else PackedFloat32Array(),
		"roads": from.roads.snapshot() \
			if from.roads != null else PackedInt32Array(),
		"road_widths": from.roads.width_snapshot() \
			if from.roads != null else PackedInt32Array(),
		"road_surfaces": from.roads.surface_snapshot() \
			if from.roads != null else PackedInt32Array(),
		"tier_space_full": from.tier_zero_space_exhausted(),
		"tier_complete": from.tier_zero_full(),
	}
	# Nothing is owed at the moment of distilling: every structure the colony had
	# is in the layout above, plots and all.
	structures_owed.fill(0)
	pegged_kinds.clear()
	pegged_costs.clear()
	build_kind = -1
	build_cost = 0.0
	build_work_remaining = 0.0
	build_waiting_for_lot = false
	clone_progress = 0.0


## The compact form for saves and join packets. A few hundred bytes against the
## 150-600 KiB a colony snapshot costs, which is what makes fifty cities in a save
## file unremarkable.
func to_dictionary() -> Dictionary:
	_sync_progression_reach()
	return {
		"site": String(site_id),
		"direction": direction,
		"facing": facing,
		"seed": founded_seed,
		"parent_site": String(parent_site_id),
		"display_name": display_name,
		"claim_radius": claim_radius,
		"region_id": String(region_id),
		"region_revision": region_revision,
		"tier": tier,
		"alive": alive,
		"resources": resources,
		"committed": committed,
		"housing": housing_capacity,
		"slots": residential_slots,
		"harvester_rate": harvester_rate,
		"structures": structures,
		"owed": structures_owed,
		"build_kind": build_kind,
		"build_work": build_work_remaining,
		"build_cost": build_cost,
		"build_waiting_for_lot": build_waiting_for_lot,
		"build_wait_radius": build_wait_radius,
		"build_wait_plan_signature": build_wait_plan_signature,
		"pegged": pegged_kinds,
		"pegged_costs": pegged_costs,
		"road_cells": road_cells,
		"identities": identities,
		"compact_roles": compact_roles,
		"compact_child_ages": compact_child_ages,
		"compact_age_elapsed": compact_age_elapsed,
		"compact_child_age_offset": compact_child_age_offset,
		"deeds": deeds,
		"resident_places": resident_places,
		"physical": physical,
		"elapsed": elapsed,
	}


## The same city out of a full resident-colony snapshot, without founding one.
##
## Saves written before this file existed, and hosts that still send everything,
## describe a town as its whole physical state. Loading fifty of those by founding
## fifty colonies would bake fifty navigation grids to throw all but a handful of
## them away moments later, which is precisely the load spike the two residency
## states exist to avoid. Everything the ledger needs is already in the entry: the
## progression sidecar carries housing and the harvester, and the identity sidecar
## says which rows are still alive.
static func from_city_snapshot(entry: Dictionary) -> MeepCityLedger:
	var ledger := MeepCityLedger.new()
	ledger.site_id = StringName(entry.get("site", ""))
	ledger.direction = entry.get("direction", Vector3.UP)
	ledger.facing = float(entry.get("facing", 0.0))
	ledger.founded_seed = int(entry.get("seed", 0))
	ledger.parent_site_id = StringName(entry.get("parent_site", ""))
	ledger.display_name = String(entry.get("display_name", ""))
	ledger.resources = maxf(float(entry.get("resources", 0.0)), 0.0)
	ledger.structures = entry.get("structures", PackedInt32Array())
	var progression: Dictionary = {}
	var progression_variant: Variant = entry.get("progression", {})
	if progression_variant is Dictionary:
		progression = progression_variant as Dictionary
	ledger.committed = clampf(float(progression.get("committed", 0.0)),
		0.0, ledger.resources)
	ledger.tier = clampi(int(progression.get("tier", 0)), 0,
		MeepColony.MAX_CITY_TIER)
	ledger.claim_radius = clampf(float(progression.get("claim_radius",
		MeepClaim.DEFAULT_RADIUS)), 8.0, MeepColony.MAX_CLAIM_RADIUS)
	ledger.region_id = StringName(progression.get("region_id", ""))
	ledger.region_revision = int(progression.get("region_revision", -1))
	ledger.residential_slots = _slots_standing(
		entry.get("structure_forms", PackedInt32Array()),
		entry.get("raised", PackedFloat32Array()),
		ledger.structures)
	ledger.housing_capacity = maxi(
		int(progression.get(
			"housing_capacity", MeepColony.FIRST_WAVE)),
		maxi(ledger.residential_slots, MeepColony.FIRST_WAVE))
	ledger.harvester_rate = maxf(float(progression.get(
		"harvester_base_rate", progression.get(
			"harvester_rate", 0.0))), 0.0)
	var identity_state: Variant = entry.get("identities", {})
	if identity_state is Dictionary:
		ledger.identities = identity_state as Dictionary
	ledger.deeds = entry.get("deeds", PackedInt32Array())
	var population_variant: Variant = entry.get("population", {})
	if population_variant is Dictionary:
		var locals_variant: Variant = (population_variant as Dictionary).get(
			"local", PackedVector2Array())
		if locals_variant is PackedVector2Array:
			ledger.resident_places = MeepColony.pack_resident_places(
				locals_variant as PackedVector2Array)
	ledger.alive = _living_rows(ledger.identities, entry)
	ledger.road_cells = (entry.get("roads", PackedInt32Array())
		as PackedInt32Array).size()
	ledger.physical = {
		"progression": progression,
		"structures": ledger.structures,
		"raised": entry.get("raised", PackedFloat32Array()),
		"structure_forms": entry.get("structure_forms", PackedInt32Array()),
		"structure_upgrades": entry.get(
			"structure_upgrades", PackedFloat32Array()),
		"roads": entry.get("roads", PackedInt32Array()),
		"road_widths": entry.get("road_widths", PackedInt32Array()),
		"road_surfaces": entry.get("road_surfaces", PackedInt32Array()),
		"tier_space_full": bool(entry.get("tier_space_full", false)),
		"tier_complete": bool(entry.get("tier_complete", false)),
	}
	ledger.repair_commissioned_owed()
	return ledger


## Housing standing in a full snapshot, read off the residential sidecar rather than
## re-priced from the plans, so a half-upgraded tower counts the floors it has.
static func _slots_standing(forms: PackedInt32Array,
		raised: PackedFloat32Array,
		structure_state: PackedInt32Array) -> int:
	var slots := 0
	for index in forms.size() / MeepStructures.FORM_STRIDE:
		if index < raised.size() and raised[index] < 1.0:
			continue
		var saved_slots := forms[index * MeepStructures.FORM_STRIDE
			+ MeepStructures.FORM_SLOTS]
		var kind := structure_state[index * 3] \
			if index * 3 < structure_state.size() \
			else MeepStructures.Kind.HUT
		var floors := forms[index * MeepStructures.FORM_STRIDE]
		slots += MeepStructures.migrated_resident_slots(
			kind, floors, saved_slots)
	return slots


## Settlers still walking about, from whichever sidecar the snapshot carried. The
## identity states are the durable record; the simulation rows are the fallback for
## a snapshot that predates them.
static func _living_rows(identities: Dictionary, entry: Dictionary) -> int:
	var states: PackedByteArray = identities.get("states", PackedByteArray())
	if states.is_empty():
		var population_variant: Variant = entry.get("population", {})
		if population_variant is Dictionary:
			var rows: PackedByteArray = (population_variant as Dictionary).get(
				"state", PackedByteArray())
			states = rows
	var living := 0
	for row_state in states:
		if row_state != MeepColony.State.DEAD \
				and row_state != MeepColony.State.DEPARTED:
			living += 1
	return living


static func from_dictionary(state: Dictionary) -> MeepCityLedger:
	var ledger := MeepCityLedger.new()
	ledger.site_id = StringName(state.get("site", ""))
	ledger.direction = state.get("direction", Vector3.UP)
	ledger.facing = float(state.get("facing", 0.0))
	ledger.founded_seed = int(state.get("seed", 0))
	ledger.parent_site_id = StringName(state.get("parent_site", ""))
	ledger.display_name = String(state.get("display_name", ""))
	ledger.region_id = StringName(state.get("region_id", ""))
	ledger.region_revision = int(state.get("region_revision", -1))
	ledger.claim_radius = clampf(float(state.get("claim_radius",
		MeepClaim.DEFAULT_RADIUS)), 8.0, MeepColony.MAX_CLAIM_RADIUS)
	ledger.tier = clampi(int(state.get("tier", 0)), 0,
		MeepColony.MAX_CITY_TIER)
	ledger.alive = maxi(int(state.get("alive", 0)), 0)
	ledger.resources = maxf(float(state.get("resources", 0.0)), 0.0)
	ledger.committed = clampf(float(state.get("committed", -1.0)),
		-1.0, ledger.resources)
	ledger.housing_capacity = maxi(int(state.get("housing",
		MeepColony.FIRST_WAVE)), 0)
	# A ledger saved before housing and raised slots were told apart only has the
	# capacity, which is the better of the two guesses either way.
	ledger.residential_slots = maxi(int(state.get("slots",
		ledger.housing_capacity)), 0)
	ledger.harvester_rate = maxf(float(state.get("harvester_rate", 0.0)), 0.0)
	ledger.structures = state.get("structures", PackedInt32Array())
	var owed: PackedInt32Array = state.get("owed", PackedInt32Array())
	for kind in mini(owed.size(), ledger.structures_owed.size()):
		ledger.structures_owed[kind] = maxi(owed[kind], 0)
	ledger.build_kind = int(state.get("build_kind", -1))
	ledger.build_work_remaining = maxf(float(state.get("build_work", 0.0)), 0.0)
	ledger.build_cost = maxf(float(state.get("build_cost", 0.0)), 0.0)
	ledger.build_waiting_for_lot = bool(
		state.get("build_waiting_for_lot", false))
	ledger.build_wait_radius = maxf(float(state.get(
		"build_wait_radius", ledger.claim_radius)), 0.0)
	ledger.build_wait_plan_signature = int(state.get(
		"build_wait_plan_signature", 0))
	ledger.pegged_kinds = state.get("pegged", PackedInt32Array())
	ledger.pegged_costs = state.get("pegged_costs", PackedFloat32Array())
	ledger.road_cells = maxi(int(state.get("road_cells", 0)), 0)
	var identity_state: Variant = state.get("identities", {})
	if identity_state is Dictionary:
		ledger.identities = identity_state as Dictionary
	ledger.compact_roles = state.get(
		"compact_roles", PackedInt32Array())
	ledger.compact_child_ages = state.get(
		"compact_child_ages", PackedFloat64Array())
	ledger.compact_age_elapsed = maxf(float(state.get(
		"compact_age_elapsed", 0.0)), 0.0)
	ledger.compact_child_age_offset = maxf(float(state.get(
		"compact_child_age_offset", 0.0)), 0.0)
	ledger.deeds = state.get("deeds", PackedInt32Array())
	ledger.resident_places = state.get(
		"resident_places", PackedInt32Array())
	var physical_state: Variant = state.get("physical", {})
	if physical_state is Dictionary:
		ledger.physical = physical_state as Dictionary
	if ledger.committed < 0.0:
		var progression_variant: Variant = ledger.physical.get("progression", {})
		ledger.committed = clampf(float((progression_variant as Dictionary).get(
			"committed", 0.0)), 0.0, ledger.resources) \
			if progression_variant is Dictionary else 0.0
	ledger.repair_commissioned_owed()
	ledger._sync_progression_reach()
	ledger.elapsed = maxf(float(state.get("elapsed", 0.0)), 0.0)
	return ledger
