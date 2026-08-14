class_name MeepColonies
extends Node3D

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

var _colonies: Dictionary = {}


func _ready() -> void:
	if planet == null:
		planet = _planet_host()
	if stats == null:
		stats = MeepStats.new()


func colony(site: StringName) -> MeepColony:
	var found := _colonies.get(site) as MeepColony
	return found if is_instance_valid(found) else null


func colonies() -> Array[MeepColony]:
	var out: Array[MeepColony] = []
	for entry: Variant in _colonies.values():
		var here := entry as MeepColony
		if is_instance_valid(here):
			out.push_back(here)
	return out


## The ship that controls a site, by the name it carries. Found through the
## landmarks group rather than a node path, so a second lander dropped anywhere
## works without this file knowing where.
func ship(site: StringName) -> ColonyShip:
	for landmark_variant: Variant in get_tree().get_nodes_in_group(Landmark.GROUP):
		var lander := landmark_variant as ColonyShip
		if lander == null or not DamageHit.in_same_world(self, lander):
			continue
		if lander.colony_site == site:
			return lander
	return null


## What the city panel shows for a site, settled or not.
func report(site: StringName) -> Dictionary:
	var here := colony(site)
	return here.report() if here != null else {}


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
	if lander == null:
		push_warning("MeepColonies has no colony ship for site '%s'" % site)
		return null
	# The seed is drawn once, here, and carried. It is what makes a wave's layout
	# and a Meep's choices the same on every peer without any of them being sent.
	var colony_seed := randi()
	var direction := lander.direction.normalized()
	if multiplayer.has_multiplayer_peer():
		_apply_found.rpc(site, direction, lander.facing, colony_seed)
	else:
		_apply_found(site, direction, lander.facing, colony_seed)
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
		colony_seed: int) -> void:
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
	here.configure(host, site, direction, facing, stats, claim_radius,
		colony_seed)
	_colonies[site] = here


@rpc("authority", "call_local", "reliable")
func _apply_settlers(site: StringName, count: int, wave_seed: int) -> void:
	var here := colony(site)
	if here != null:
		here.release_settlers(count, wave_seed)


# --- Late joiners ------------------------------------------------------------

## The founding facts for every settled site. Deliberately not the Meeps: rows are
## addressed by index and the next state packet fills them in, so a joiner needs to
## be told that a town exists and nothing about who is in it.
func snapshot() -> Array:
	var out: Array = []
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
			"resources": here.resources,
			# What stands where, and how far along the unfinished ones are. Not
			# derivable from the seed: where a building went was decided against the
			# ground and the bank at the moment the colony chose it.
			"structures": here.structures.snapshot() \
				if here.structures != null else PackedInt32Array(),
			"raised": here.structures.progress_snapshot() \
				if here.structures != null else PackedFloat32Array(),
		})
	return out


func apply_snapshot(snapshot_state: Array) -> void:
	for entry_variant: Variant in snapshot_state:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		var site := StringName(entry.get("site", ""))
		if site == &"":
			continue
		_apply_found(site, entry.get("direction", Vector3.UP),
			float(entry.get("facing", 0.0)), int(entry.get("seed", 0)))
		var here := colony(site)
		if here == null:
			continue
		here.resources = float(entry.get("resources", 0.0))
		if here.structures == null:
			continue
		here.structures.apply_snapshot(entry.get("structures",
			PackedInt32Array()))
		here.structures.apply_progress(entry.get("raised",
			PackedFloat32Array()))


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func _planet_host() -> Planet:
	var node := get_parent()
	while node != null:
		if node is Planet:
			return node as Planet
		node = node.get_parent()
	return null
