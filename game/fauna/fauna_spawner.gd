class_name FaunaSpawner
extends Node3D

## Host-authoritative fauna streamed through deterministic spherical cells.
##
## Species own habitat, density, appearance, vitality, temperament, and moves.
## This node only decides which stable cells are live around the current players,
## guarantees authored showcase packs beside the Colony Ship, and replicates the
## resulting actors. Unlike flora, mobs carry state, so clients never generate
## their own independent simulation.

const CELL_CACHE_LIMIT := 2048
const GLOBAL_CENTRE_ATTEMPTS := 4
const PACK_PLACEMENT_ATTEMPTS := 6
const COLONY_PLACEMENT_ATTEMPTS := 64
const CACHE_KEEP_GENERATIONS := 3
## How far out to step when turning a bearing around the colony ship into a
## heading on the settlement's own flat map. Far enough to be a direction rather
## than rounding noise, near enough that the ship's offset from the town centre
## does not bend it.
const SETTLEMENT_BEARING_PROBE := 40.0
## Below this share of the claim cap a measured reach is treated as terrain
## cutting the boundary short rather than as the edge a herd should ring.
const SETTLEMENT_REACH_FLOOR := 0.35
const DEFAULT_COLONY_SITE := &"landing"
## Where in its own sector of the frontier one creature may be placed. The inset
## and the sweep leave a guard band on both sides, which is what keeps two
## neighbours from ending up shoulder to shoulder on their shared border.
const EDGE_SECTOR_INSET := 0.2
const EDGE_SECTOR_SWEEP := 0.6
## How far past its own sector a creature may be pushed by ground it cannot use.
const EDGE_SECTOR_WIDEN := 1.6
const FLOOR_CLEARANCE := 0.025
const LIGHT_UPDATE_INTERVAL := 0.05
const MATING_HEART := preload("res://game/fauna/fauna_mating_heart.gd")
const RHINO_DEN_SCRIPT := preload("res://game/fauna/rhino_den.gd")
const RHINO_SPECIES_ID := "cinder_plate_rhino"
const RHINO_DEN_SEARCH_ATTEMPTS := 96
const RHINO_DEN_NEAR := 48.0
const RHINO_DEN_FAR := 1200.0
const RHINO_DEN_IDEAL_SLOPE := 38.0
const RHINO_DEN_MAX_SLOPE := 76.0
const RHINO_DEN_EXIT_DISTANCE := 8.0
const RHINO_DEN_CITY_MARGIN := 10.0

@export var species: Array[FaunaSpecies] = []
@export var planet_path: NodePath
@export var terrain_claims: NodePath
@export var colony_anchor: NodePath

@export_category("Streaming")
@export_range(0.1, 10.0, 0.05) var survey_interval := 0.75
## Keeps terrain sampling and global actor construction out of the opening frame.
@export_range(0.0, 10.0, 0.05) var initial_survey_delay := 1.5
@export_range(1, 64) var max_spawns_per_survey := 4
@export_range(16, 2048) var candidate_limit_per_species := 256
## Pairing is one bounded pass over the live actors, not another think loop on
## every creature. This keeps a herd's courtship decisions staggered and cheap.
@export_range(0.2, 10.0, 0.1) var mating_survey_interval := 1.0

@export_category("Pooled night lights")
@export_range(0, 24) var light_limit := 7
@export_range(1.0, 500.0) var lights_within := 95.0
@export_range(0.1, 30.0) var light_follow_speed := 9.0
@export_range(0.1, 30.0) var light_fade_speed := 5.0

var _planet: Planet
var _cover: GroundCover
var _colony: Node3D
var _species_by_id: Dictionary = {}
var _grids: Dictionary = {}
var _actors: Dictionary = {}
var _global_ids: Dictionary = {}
## Deterministic actors killed in this world. Their cells may stream back into
## range, but these tombstones ensure the same individual never respawns.
var _dead_ids: Dictionary = {}
## Captured actors stay instantiated and hidden so a ball restores the exact
## creature rather than manufacturing a fresh copy from its species recipe.
var _captured_ids: Dictionary = {}
## A released global actor follows its new position until it streams out. Its
## deterministic cell still owns the id after that, so it may later repopulate.
var _relocated_ids: Dictionary = {}
var _cell_cache: Dictionary = {}
var _cache_generation := 0
var _pending_states: Dictionary = {}
var _birth_sequence := 0
var _den_spawn_sequence := 0
var _rhino_den
var _rhino_den_record: Dictionary = {}
var _last_den_placement_checks := 0
var _survey_left := 0.0
var _mating_left := 0.0
var _light_elapsed := 0.0
var _built := false
var _last_survey_micros := 0
var _last_survey_placement_checks := 0
var _last_colony_micros := 0
var _last_colony_placement_checks := 0
var _survey_placement_checks := 0

var _lights: Array[OmniLight3D] = []
var _light_actor_ids: PackedStringArray = PackedStringArray()


func _ready() -> void:
	set_process(false)
	if Engine.is_editor_hint():
		return
	call_deferred(&"_build")


func _build() -> void:
	_planet = _find_planet()
	if _planet == null or _planet.shape == null:
		push_error("FaunaSpawner must be under, or point to, a Planet")
		return
	_planet.shape.prepare()
	if not terrain_claims.is_empty():
		_cover = get_node_or_null(terrain_claims) as GroundCover
		if _cover == null:
			push_warning("FaunaSpawner terrain_claims does not point to GroundCover")
	if _cover == null:
		_cover = _planet.get_node_or_null("GlobalGrass") as GroundCover
	if not colony_anchor.is_empty():
		_colony = get_node_or_null(colony_anchor) as Node3D
	if _colony == null:
		_colony = _planet.get_node_or_null("ColonyShip") as Node3D

	for definition in species:
		if definition == null:
			continue
		for problem in definition.validate():
			push_error("FaunaSpawner: %s" % problem)
		if not definition.enabled:
			continue
		if definition.species_id.is_empty() \
				or _species_by_id.has(definition.species_id):
			push_error("FaunaSpawner has an empty or duplicate species id '%s'"
				% definition.species_id)
			continue
		_species_by_id[definition.species_id] = definition
		definition.prepare()
		if definition.global_population:
			_grids[definition.species_id] = SphericalCoverGrid.new(
				_planet.shape.radius, definition.cell_size)

	_make_light_pool()
	_built = true
	if _is_host():
		var colony_began := Time.get_ticks_usec()
		_survey_placement_checks = 0
		_place_colony_populations()
		_place_rhino_den()
		_last_colony_micros = Time.get_ticks_usec() - colony_began
		_last_colony_placement_checks = _survey_placement_checks
		_survey_left = maxf(initial_survey_delay, 0.0)
		_mating_left = maxf(mating_survey_interval, 0.2)
	elif multiplayer.has_multiplayer_peer():
		_request_fauna_snapshot.rpc_id(1)
	set_process(true)


func _process(delta: float) -> void:
	if not _built:
		return
	_survey_left -= delta
	if _is_host() and _survey_left <= 0.0:
		_survey_left = maxf(survey_interval, 0.1)
		_survey_global()
	if _is_host():
		_mating_left -= delta
		if _mating_left <= 0.0:
			_mating_left = maxf(mating_survey_interval, 0.2)
			_survey_mating()
	_light_elapsed += delta
	if _light_elapsed >= LIGHT_UPDATE_INTERVAL:
		_update_lights(_light_elapsed)
		_light_elapsed = 0.0


## The ledgers that explain fauna cost, sampled by RuntimeTelemetry.
##
## Actor and cell counts come from the dictionaries the spawner already uses, so
## opening the Admin page never performs a second population survey.
func statistics() -> Dictionary:
	var active_lights := 0
	for light: OmniLight3D in _lights:
		if light != null and light.visible and light.light_energy > 0.001:
			active_lights += 1
	return {
		"actors": _actors.size(),
		"stream_cells": _cell_cache.size(),
		"dead_ids": _dead_ids.size(),
		"captured_ids": _captured_ids.size(),
		"active_lights": active_lights,
		"last_survey_ms": float(_last_survey_micros) / 1000.0,
		"last_survey_checks": _last_survey_placement_checks,
		"last_colony_ms": float(_last_colony_micros) / 1000.0,
		"last_colony_checks": _last_colony_placement_checks,
	}


func _find_planet() -> Planet:
	if not planet_path.is_empty():
		var explicit := get_node_or_null(planet_path) as Planet
		if explicit != null:
			return explicit
	var walk := get_parent()
	while walk != null:
		if walk is Planet:
			return walk as Planet
		walk = walk.get_parent()
	return null


# --- Deterministic placement ------------------------------------------------

func _place_colony_populations() -> void:
	if _colony == null:
		if not species.is_empty():
			push_warning("FaunaSpawner has no Colony Ship anchor")
		return
	var anchor_local := _planet.to_local(_colony.global_position)
	if anchor_local.length_squared() < 1.0:
		return
	var anchor := anchor_local.normalized()
	var axes := _tangent_axes(anchor)
	var occupied := PackedVector3Array()
	for definition in species:
		if definition == null or not definition.enabled \
				or definition.colony_count <= 0:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = _mixed_seed(
			definition.random_seed, Vector3i(-1, definition.colony_count, 0), 0)
		var near := minf(definition.colony_near, definition.colony_far)
		var far := maxf(definition.colony_near, definition.colony_far)
		var edge := definition.settlement_edge
		var edge_near := minf(
			definition.edge_margin_near, definition.edge_margin_far)
		var edge_far := maxf(
			definition.edge_margin_near, definition.edge_margin_far)
		for index in definition.colony_count:
			var accepted := {}
			var direction := anchor
			for attempt in COLONY_PLACEMENT_ATTEMPTS:
				var angle := rng.randf() * TAU
				var reach := sqrt(lerpf(near * near, far * far, rng.randf()))
				if edge:
					# Spread by bearing rather than at random, so a frontier herd
					# rings the town instead of gathering on one side of it, and
					# measured out from the claim along that bearing. Retries
					# sweep within this creature's own share of the circle, so
					# ground it cannot stand on moves it along the frontier
					# rather than into its neighbour's stretch of it. A sector
					# that is all water widens rather than gives up: losing the
					# spacing is better than losing the animal.
					var share := (float(attempt) + rng.randf()) \
						/ float(COLONY_PLACEMENT_ATTEMPTS)
					angle = TAU * (float(index) + EDGE_SECTOR_INSET + share
						* (EDGE_SECTOR_SWEEP + EDGE_SECTOR_WIDEN * share)) \
						/ float(definition.colony_count)
					reach = _settlement_reach(anchor, axes, angle) \
						+ lerpf(edge_near, edge_far, rng.randf())
				direction = (anchor + (
					axes[0] * cos(angle) + axes[1] * sin(angle))
					* (reach / _planet.shape.radius)).normalized()
				accepted = _placement(definition, direction, true)
				if accepted.is_empty() \
						or not _clear_of_colony_mobs(
							accepted["point"] as Vector3, occupied,
							_definition_clearance(definition)):
					accepted = {}
					continue
				break
			if accepted.is_empty():
				push_warning("FaunaSpawner could not place colony %s %d"
					% [definition.species_id, index])
				continue
			var point: Vector3 = accepted["point"]
			occupied.append(point)
			var id := "c_%s_%d" % [definition.species_id, index]
			var record := _record_for(
				definition, id, direction, accepted, rng,
				_mixed_seed(definition.random_seed,
					Vector3i(-1, index, 0), index))
			_spawn_authoritative(record, false)


## How far the settlement's claim reaches along one bearing out of the ship.
##
## The nominal tier cap answers before anybody has founded anything, which is the
## usual case at world load: a frontier herd has to exist from the first frame
## whether or not the town does, and the cap is where the boundary will land on
## open ground anyway. Once the claim has been flood-filled, its own reach along
## the bearing is used instead, because the real edge follows the terrain and
## stops short wherever the ground does.
func _settlement_reach(anchor: Vector3, axes: Array[Vector3],
		angle: float) -> float:
	var colony := _settlement()
	if colony == null:
		return MeepClaim.DEFAULT_RADIUS
	var cap := maxf(colony.claim_radius, 1.0)
	if colony.claim == null or colony.site == null or not colony.ground_ready():
		return cap
	var probe := (anchor + (axes[0] * cos(angle) + axes[1] * sin(angle))
		* (SETTLEMENT_BEARING_PROBE / _planet.shape.radius)).normalized()
	var heading := colony.site.to_local(probe)
	if heading.length_squared() < 0.000001:
		return cap
	var found := colony.claim.reach_along(heading.normalized())
	var reach := float(found[0]) if not found.is_empty() else 0.0
	# A bearing that runs straight off a cliff or into water stops a few metres
	# out. Ringing the town there would put the herd inside it, so the cap wins.
	return reach if reach > cap * SETTLEMENT_REACH_FLOOR else cap


## The settlement this spawner's colony anchor belongs to, if it has been founded.
func _settlement() -> MeepColony:
	var colonies := _planet.get_node_or_null("MeepColonies") as MeepColonies
	if colonies == null:
		return null
	var ship := _colony as ColonyShip
	return colonies.colony(
		ship.colony_site if ship != null else DEFAULT_COLONY_SITE)


func _clear_of_colony_mobs(point: Vector3, occupied: PackedVector3Array,
		clearance: float) -> bool:
	for other in occupied:
		if point.distance_to(other) < clearance:
			return false
	return true


func _definition_clearance(definition: FaunaSpecies) -> float:
	return maxf(definition.height * definition.collision_radius_share * 2.4, 1.2)


## Finds the steepest usable face in a bounded ring around the authored frontier
## herd. The cave attaches to that face while its exit must still be ordinary
## rhino ground, so animals appear in front of it rather than inside terrain.
func _place_rhino_den() -> void:
	var definition := _species_by_id.get(RHINO_SPECIES_ID) as FaunaSpecies
	if definition == null or _planet == null or _planet.shape == null:
		return
	var anchors: Array[Vector3] = []
	for id in actor_ids():
		var mob := actor(id)
		if mob == null or mob.species == null \
				or mob.species.species_id != RHINO_SPECIES_ID:
			continue
		var local := _planet.to_local(mob.global_position)
		if local.length_squared() > 1.0:
			anchors.append(local.normalized())
	if anchors.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = _mixed_seed(
		definition.random_seed, Vector3i(-3, anchors.size(), 0), 31337)
	var best := {}
	var best_score := -INF
	var spacing := _planet.finest_spacing()
	_last_den_placement_checks = 0
	for attempt in RHINO_DEN_SEARCH_ATTEMPTS:
		_last_den_placement_checks += 1
		var anchor := anchors[attempt % anchors.size()]
		var axes := _tangent_axes(anchor)
		var reach_share := pow(rng.randf(), 1.35)
		var reach := lerpf(RHINO_DEN_NEAR, RHINO_DEN_FAR, reach_share)
		var angle := rng.randf() * TAU
		var direction := (anchor + (
			axes[0] * cos(angle) + axes[1] * sin(angle))
			* (reach / _planet.shape.radius)).normalized()
		var elevation := _planet.shape.elevation(direction, spacing)
		if elevation < definition.above_water:
			continue
		var sample := _planet.shape.sample(direction)
		if float(sample.get("river", 0.0)) > 0.0 \
				or float(sample.get("lake", 0.0)) > 0.0:
			continue
		var normal := _planet.shape.normal_at(direction, spacing).normalized()
		var slope := rad_to_deg(acos(clampf(
			normal.dot(direction), -1.0, 1.0)))
		if slope > RHINO_DEN_MAX_SLOPE:
			continue
		var outward := normal - direction * normal.dot(direction)
		if outward.length_squared() < 0.000001:
			continue
		outward = outward.normalized()
		var exit_direction := (direction + outward
			* (RHINO_DEN_EXIT_DISTANCE / _planet.shape.radius)).normalized()
		var exit_placement := _placement(
			definition, exit_direction, true)
		if exit_placement.is_empty():
			continue
		var score := slope * 4.0 - reach * 0.012
		if slope >= RHINO_DEN_IDEAL_SLOPE:
			score += 120.0
		if score <= best_score:
			continue
		var den_point := direction \
			* (_planet.shape.radius + elevation) + normal * 0.16
		var den_local := Transform3D(
			_upright_basis(outward, direction), den_point)
		var exit_normal := exit_placement["normal"] as Vector3
		var exit_local := Transform3D(
			_upright_basis(outward, exit_normal),
			exit_placement["point"] as Vector3)
		best_score = score
		best = {
			"transform": _planet.global_transform * den_local,
			"exit_transform": _planet.global_transform * exit_local,
			"cliff_slope": slope,
		}
		if slope >= RHINO_DEN_IDEAL_SLOPE:
			break
	if best.is_empty():
		push_warning("FaunaSpawner could not find a cliff for the rhino den")
		return
	_spawn_rhino_den_authoritative(best)


func _spawn_rhino_den_authoritative(record: Dictionary) -> void:
	_spawn_rhino_den_local(record)
	if _has_remote_peers():
		_spawn_rhino_den_remote.rpc(record)


@rpc("authority", "call_remote", "reliable")
func _spawn_rhino_den_remote(record: Dictionary) -> void:
	_spawn_rhino_den_local(record)


func _spawn_rhino_den_local(record: Dictionary,
		state := {}, snap := false) -> void:
	var transform_value: Variant = record.get("transform")
	var exit_value: Variant = record.get("exit_transform")
	if not transform_value is Transform3D or not exit_value is Transform3D:
		return
	if is_instance_valid(_rhino_den):
		remove_child(_rhino_den)
		_rhino_den.queue_free()
	var den: Node = RHINO_DEN_SCRIPT.new()
	den.name = &"RhinoDen"
	den.configure(
		transform_value as Transform3D,
		exit_value as Transform3D,
		float(record.get("cliff_slope", 0.0)), self)
	add_child(den)
	_rhino_den = den
	_rhino_den_record = record.duplicate(true)
	if state is Dictionary and not (state as Dictionary).is_empty():
		den.apply_network_state(state as Dictionary, snap)


## A den birth is an ecological spawn, not a deterministic cell refill. The
## animal receives a new stable id and persists like a mating-born creature.
func spawn_rhino_from_den(den: Node) -> bool:
	if not _is_host() or den == null or den != _rhino_den \
			or den.is_destroyed():
		return false
	var definition := _species_by_id.get(RHINO_SPECIES_ID) as FaunaSpecies
	if definition == null \
			or living_species_count(RHINO_SPECIES_ID) >= definition.population_limit:
		return false
	var record := _den_rhino_record(definition, den.exit_transform())
	if record.is_empty():
		return false
	var id := String(record["id"])
	_spawn_authoritative(record, false)
	return _actors.has(id)


func _den_rhino_record(definition: FaunaSpecies,
		exit_at: Transform3D) -> Dictionary:
	if _planet == null or _planet.shape == null:
		return {}
	var local_exit := _planet.to_local(exit_at.origin)
	if local_exit.length_squared() < 1.0:
		return {}
	var sequence := _den_spawn_sequence + 1
	var id := "d_%s_%d" % [definition.species_id, sequence]
	while _actors.has(id) or _dead_ids.has(id):
		sequence += 1
		id = "d_%s_%d" % [definition.species_id, sequence]
	var seed := _mixed_seed(
		definition.random_seed, Vector3i(-4, sequence, 0), sequence)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var centre := local_exit.normalized()
	var axes := _tangent_axes(centre)
	var direction := centre
	var placement := {}
	for attempt in 12:
		if attempt > 0:
			var reach := lerpf(0.8, 4.0, rng.randf())
			var angle := rng.randf() * TAU
			direction = (centre + (
				axes[0] * cos(angle) + axes[1] * sin(angle))
				* (reach / _planet.shape.radius)).normalized()
		placement = _placement(definition, direction, true)
		if not placement.is_empty():
			break
	if placement.is_empty():
		return {}
	var record := _record_for(
		definition, id, direction, placement, rng, seed)
	var migration := _nearest_city_migration(
		(record["transform"] as Transform3D).origin)
	record["migration_direction"] = migration.get(
		"direction", Vector3.ZERO)
	record["migration_stop"] = float(migration.get("stop_radius", 0.0))
	record["den_spawn"] = true
	_den_spawn_sequence = sequence
	return record


func _nearest_city_migration(from_world: Vector3) -> Dictionary:
	var found := {}
	var colonies := _planet.get_node_or_null("MeepColonies") as MeepColonies
	if colonies != null:
		found = colonies.nearest_city(from_world)
	if found.is_empty() and _colony != null:
		var fallback := _planet.to_local(_colony.global_position)
		if fallback.length_squared() > 1.0:
			found = {
				"direction": fallback.normalized(),
				"claim_radius": MeepClaim.DEFAULT_RADIUS,
			}
	var target_value: Variant = found.get("direction", Vector3.ZERO)
	if not target_value is Vector3 \
			or not (target_value as Vector3).is_finite() \
			or (target_value as Vector3).length_squared() < 0.5:
		return {}
	return {
		"direction": (target_value as Vector3).normalized(),
		"stop_radius": maxf(float(found.get(
			"claim_radius", MeepClaim.DEFAULT_RADIUS)), 1.0) \
			+ RHINO_DEN_CITY_MARGIN,
	}


func _survey_global() -> void:
	var began := Time.get_ticks_usec()
	_survey_placement_checks = 0
	var viewers := _viewer_positions()
	if viewers.is_empty():
		_last_survey_micros = Time.get_ticks_usec() - began
		_last_survey_placement_checks = 0
		return
	_cache_generation += 1
	var desired := {}
	for definition in species:
		if definition == null or not definition.global_population \
				or definition.maximum_instances <= 0:
			continue
		var grid := _grids.get(definition.species_id) as SphericalCoverGrid
		if grid == null:
			continue
		var keys: Array[Vector3i] = []
		var seen := {}
		var enumerate_reach := maxf(
			definition.spawn_within, definition.despawn_beyond)
		for viewer in viewers:
			var local_viewer := _planet.to_local(viewer)
			if local_viewer.length_squared() < 1.0:
				continue
			for key in _candidate_keys(
					grid, local_viewer.normalized(), enumerate_reach):
				if seen.has(key):
					continue
				seen[key] = true
				keys.append(key)
				if keys.size() >= candidate_limit_per_species:
					break
			if keys.size() >= candidate_limit_per_species:
				break

		var candidates: Array[Dictionary] = []
		for key in keys:
			for record_variant: Variant in _records_for_cell(
					definition, grid, key):
				var record := record_variant as Dictionary
				var away := _nearest_distance(
					(record["transform"] as Transform3D).origin, viewers)
				var id := String(record["id"])
				if _dead_ids.has(id):
					continue
				var existing := _actors.has(id)
				if (existing and away > definition.despawn_beyond) \
						or (not existing and away > definition.spawn_within):
					continue
				record = record.duplicate()
				record["away"] = away
				# Existing cells get a small hysteresis advantage so two packs
				# crossing rank do not despawn and respawn every survey.
				record["rank"] = away - (
					definition.cell_size * 0.28 if existing else 0.0)
				candidates.append(record)
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var rank_a := float(a["rank"])
			var rank_b := float(b["rank"])
			if not is_equal_approx(rank_a, rank_b):
				return rank_a < rank_b
			return String(a["id"]) < String(b["id"]))
		var persistent := _non_global_living_count(definition.species_id)
		var global_limit := mini(definition.maximum_instances,
			maxi(definition.population_limit - persistent, 0))
		if candidates.size() > global_limit:
			candidates.resize(global_limit)
		for record in candidates:
			desired[String(record["id"])] = record

	# A ball can travel far outside the creature's deterministic spawn cell.
	# Keep hidden captures regardless of viewer distance, and judge released
	# captures from where they actually landed until they naturally stream out.
	for id_variant: Variant in _captured_ids.keys():
		var id := String(id_variant)
		if _actors.has(id):
			desired[id] = {}
		else:
			_captured_ids.erase(id)
	for id_variant: Variant in _relocated_ids.keys():
		var id := String(id_variant)
		var mob := _actors.get(id) as FaunaMob
		if not is_instance_valid(mob) or mob.species == null \
				or not _global_ids.has(id):
			_relocated_ids.erase(id)
			continue
		if _nearest_distance(mob.global_position, viewers) \
				<= mob.species.despawn_beyond:
			desired[id] = {}
		else:
			_relocated_ids.erase(id)
			# If another viewer is near the actor's deterministic home, `desired`
			# may already contain that original record. Remove the relocated copy
			# now so the spawn pass can rebuild it at home rather than retaining a
			# far-away actor merely because both locations share a stable id.
			_despawn_authoritative(id)

	for id_variant: Variant in _global_ids.keys():
		var id := String(id_variant)
		if not desired.has(id):
			_despawn_authoritative(id)

	var spawn_budget := max_spawns_per_survey
	var wanted_ids := desired.keys()
	wanted_ids.sort()
	for id_variant: Variant in wanted_ids:
		if spawn_budget <= 0:
			break
		var id := String(id_variant)
		if _actors.has(id):
			continue
		_spawn_authoritative(desired[id] as Dictionary, true)
		spawn_budget -= 1
	_prune_cell_cache()
	_last_survey_micros = Time.get_ticks_usec() - began
	_last_survey_placement_checks = _survey_placement_checks


func _candidate_keys(grid: SphericalCoverGrid, eye_direction: Vector3,
		reach: float) -> Array[Vector3i]:
	var axes := _tangent_axes(eye_direction)
	var keys: Array[Vector3i] = []
	var seen := {}
	var rings := ceili(reach / maxf(
		2.0 * grid.radius / float(grid.resolution), 1.0)) + 2
	for ring in rings + 1:
		for row in range(-ring, ring + 1):
			for col in range(-ring, ring + 1):
				if maxi(absi(col), absi(row)) != ring:
					continue
				var offset := Vector2(col, row) \
					* (2.0 * grid.radius / float(grid.resolution))
				if offset.length() > reach + 2.0 * grid.radius \
						/ float(grid.resolution):
					continue
				var direction := (
					eye_direction + (axes[0] * offset.x + axes[1] * offset.y)
					/ _planet.shape.radius).normalized()
				var key := grid.key_for(direction)
				if seen.has(key):
					continue
				seen[key] = true
				keys.append(key)
				if keys.size() >= candidate_limit_per_species:
					return keys
	return keys


func _records_for_cell(definition: FaunaSpecies, grid: SphericalCoverGrid,
		key: Vector3i) -> Array:
	var cache_key := "%s:%d:%d:%d" % [
		definition.species_id, key.x, key.y, key.z]
	if _cell_cache.has(cache_key):
		var cached := _cell_cache[cache_key] as Dictionary
		cached["seen"] = _cache_generation
		return cached["records"] as Array
	var records: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = _mixed_seed(definition.random_seed, key, 0)
	if rng.randf() <= definition.spawn_chance:
		var centre := grid.centre(key)
		var centre_placement := {}
		for _attempt in GLOBAL_CENTRE_ATTEMPTS:
			centre = grid.direction_in(
				key, rng.randf_range(0.16, 0.84), rng.randf_range(0.16, 0.84))
			centre_placement = _placement(definition, centre, false)
			if not centre_placement.is_empty():
				break
		if not centre_placement.is_empty():
			var count := rng.randi_range(
				definition.pack_min, definition.pack_max)
			var axes := _tangent_axes(centre)
			for index in count:
				var direction := centre
				var accepted := centre_placement if index == 0 else {}
				if index > 0:
					for _attempt in PACK_PLACEMENT_ATTEMPTS:
						var reach := sqrt(rng.randf()) * definition.pack_radius
						var angle := rng.randf() * TAU
						direction = (centre + (
							axes[0] * cos(angle) + axes[1] * sin(angle))
							* (reach / _planet.shape.radius)).normalized()
						accepted = _placement(definition, direction, false)
						if not accepted.is_empty():
							break
				if accepted.is_empty():
					continue
				var id := "g_%s_%d_%d_%d_%d" % [
					definition.species_id, key.x, key.y, key.z, index]
				records.append(_record_for(
					definition, id, direction, accepted, rng,
					_mixed_seed(definition.random_seed, key, index + 1)))
	_cell_cache[cache_key] = {
		"records": records,
		"seen": _cache_generation,
	}
	return records


func _record_for(definition: FaunaSpecies, id: String, direction: Vector3,
		placement: Dictionary, rng: RandomNumberGenerator, seed: int) -> Dictionary:
	var normal: Vector3 = placement["normal"]
	var axes := _tangent_axes(normal)
	var heading := axes[0].rotated(normal, rng.randf() * TAU)
	var local_transform := Transform3D(
		_upright_basis(heading, normal), placement["point"] as Vector3)
	return {
		"id": id,
		"species_id": definition.species_id,
		"seed": seed,
		"transform": _planet.global_transform * local_transform,
		"biome": placement.get("biome", Color.WHITE),
	}


func _placement(definition: FaunaSpecies, direction: Vector3,
		colony_showcase: bool) -> Dictionary:
	_survey_placement_checks += 1
	var at := direction.normalized()
	var spacing := _planet.finest_spacing()
	var elevation := _planet.shape.elevation(at, spacing)
	if elevation < minf(definition.above_water, definition.below) \
			or elevation > maxf(definition.above_water, definition.below):
		return {}
	var sample := _planet.shape.sample(at)
	if definition.avoid_inland_water and (
			float(sample.get("river", 0.0)) > 0.0
			or float(sample.get("lake", 0.0)) > 0.0):
		return {}
	var normal := _planet.shape.normal_at(at, spacing).normalized()
	var slope := rad_to_deg(acos(clampf(normal.dot(at), -1.0, 1.0)))
	if slope > definition.max_slope:
		return {}
	if not _steady_enough(definition, at, elevation, spacing):
		return {}
	var biome := _planet.shape.color_at(at, elevation, normal)
	if not colony_showcase:
		var arid := float(sample.get("arid", 0.0))
		if arid < minf(definition.minimum_arid, definition.maximum_arid) \
				or arid > maxf(
					definition.minimum_arid, definition.maximum_arid):
			return {}
		var frost := _planet.shape.frost(at)
		if frost < minf(definition.minimum_frost, definition.maximum_frost) \
				or frost > maxf(
					definition.minimum_frost, definition.maximum_frost):
			return {}
		if definition.ground_layer != PlantSpecies.Ground.ANYWHERE:
			var claimed := _cover.terrain_claims(
				at, elevation, normal, biome, definition.ground_layer,
				definition.minimum_ground_claim) if _cover != null \
				else _fallback_terrain_claim(
					definition, at, elevation, normal, biome)
			if not claimed:
				return {}
	return {
		"height": elevation,
		"normal": normal,
		"biome": biome,
		"point": at * (_planet.shape.radius + elevation + FLOOR_CLEARANCE),
	}


func _steady_enough(definition: FaunaSpecies, direction: Vector3,
		centre_height: float, spacing: float) -> bool:
	if definition.steady_over <= 0.0 or definition.steady_within <= 0.0:
		return true
	var axes := _tangent_axes(direction)
	var step := definition.steady_over / _planet.shape.radius
	var low := centre_height
	var high := centre_height
	for axis in axes:
		for sign_value in [-1.0, 1.0]:
			var sample_direction: Vector3 = (
				direction + axis * step * sign_value).normalized()
			var height := _planet.shape.elevation(sample_direction, spacing)
			low = minf(low, height)
			high = maxf(high, height)
	return high - low <= definition.steady_within


func _fallback_terrain_claim(definition: FaunaSpecies, at: Vector3,
		height: float, normal: Vector3, biome: Color) -> bool:
	var brightest := maxf(maxf(biome.r, biome.g), biome.b)
	var darkest := minf(minf(biome.r, biome.g), biome.b)
	var chroma := brightest - darkest
	var green := clampf(
		(biome.g - maxf(biome.r, biome.b)) * 7.0, 0.0, 1.0)
	var red := clampf(
		(biome.r - maxf(biome.g, biome.b)) * 7.0, 0.0, 1.0)
	var grey := 1.0 - clampf(chroma * 7.0, 0.0, 1.0)
	var cool := clampf((biome.b - biome.r) * 7.0, 0.0, 1.0)
	var pale := maxf(grey, cool) * clampf(
		(brightest - 0.7) * 7.0, 0.0, 1.0)
	var frozen := _planet.shape.frost(at)
	var shore := 1.0 - smoothstep(0.0, 7.0, height)
	var ice := maxf(pale, frozen * 1.3)
	var sand := (red + shore) * (1.0 - minf(ice, 1.0))
	var slope := 1.0 - clampf(normal.dot(at), 0.0, 1.0)
	var cliff := smoothstep(0.22, 0.55, slope)
	var stone := maxf(grey - pale, 0.0) + cliff * 1.1
	var grass := maxf(green, 0.3 - maxf(maxf(sand, stone), ice))
	var scores := [grass, sand, stone, ice]
	var layer_index := int(definition.ground_layer) - 1
	var mine: float = scores[layer_index]
	if mine < definition.minimum_ground_claim:
		return false
	var ahead := 0
	for index in scores.size():
		if index != layer_index and float(scores[index]) > mine:
			ahead += 1
	return ahead <= 1


func _prune_cell_cache() -> void:
	if _cell_cache.size() <= CELL_CACHE_LIMIT:
		return
	var keep_after := _cache_generation - CACHE_KEEP_GENERATIONS
	for key in _cell_cache.keys():
		var cached := _cell_cache[key] as Dictionary
		if int(cached["seen"]) < keep_after:
			_cell_cache.erase(key)
			if _cell_cache.size() <= CELL_CACHE_LIMIT:
				return


# --- Reproduction -----------------------------------------------------------

## One matching pass pairs available adults without giving every animal its own
## scene-tree scan. Stable id order makes simultaneous candidates deterministic.
func _survey_mating() -> void:
	for definition in species:
		if definition == null or not definition.enabled \
				or not definition.reproduces:
			continue
		var living: Array[FaunaMob] = []
		var reserved_births := 0
		for mob_variant: Variant in _actors.values():
			var mob := mob_variant as FaunaMob
			if not is_instance_valid(mob) or not mob.is_alive() \
					or mob.species == null \
					or mob.species.species_id != definition.species_id:
				continue
			living.append(mob)
			if mob.is_courtship_leader():
				reserved_births += 1
		# One survivor is an extinction bottleneck, not a source of replacement
		# actors. Juveniles count toward the ceiling but cannot enter candidates.
		if living.size() < 2:
			continue
		var room := definition.population_limit - living.size() - reserved_births
		if room <= 0:
			continue
		living.sort_custom(func(a: FaunaMob, b: FaunaMob) -> bool:
			return a.mob_id < b.mob_id)
		var used := {}
		for first in living:
			if room <= 0:
				break
			if used.has(first.mob_id) or not first.can_start_courtship():
				continue
			var partner: FaunaMob
			var nearest_squared := definition.mate_search_range \
				* definition.mate_search_range
			for second in living:
				if second == first or used.has(second.mob_id) \
						or not second.can_start_courtship():
					continue
				var away := first.global_position.distance_squared_to(
					second.global_position)
				if away >= nearest_squared:
					continue
				nearest_squared = away
				partner = second
			if partner == null:
				continue
			if not first.begin_courtship(partner):
				continue
			if not partner.begin_courtship(first):
				first.cancel_courtship()
				continue
			used[first.mob_id] = true
			used[partner.mob_id] = true
			room -= 1


## Called only by the stable-id leader after both partners have stood face to
## face for the authored courtship. Revalidating here closes races with damage,
## capture, another birth, or a sandbox load changing the population ceiling.
func complete_mating(first: FaunaMob, second: FaunaMob) -> void:
	if not _is_host() or not is_instance_valid(first) \
			or not is_instance_valid(second) or first == second \
			or not first.is_courting_with(second) \
			or first.species == null or second.species == null \
			or first.species.species_id != second.species.species_id:
		return
	var definition := first.species
	if living_species_count(definition.species_id) >= definition.population_limit:
		first.finish_courtship(false)
		second.finish_courtship(false)
		return
	var record := _birth_record(definition, first, second)
	if record.is_empty():
		first.finish_courtship(false)
		second.finish_courtship(false)
		return
	first.finish_courtship(true)
	second.finish_courtship(true)
	_spawn_authoritative(record, false)
	var transform := record["transform"] as Transform3D
	var height := maxf(first.instance_height(), second.instance_height())
	_show_mating_heart(transform.origin, transform.basis.y.normalized(), height)
	if _has_remote_peers():
		_show_mating_heart_remote.rpc(
			transform.origin, transform.basis.y.normalized(), height)


func _birth_record(definition: FaunaSpecies, first: FaunaMob,
		second: FaunaMob) -> Dictionary:
	if _planet == null or _planet.shape == null:
		return {}
	var first_local := _planet.to_local(first.global_position)
	var second_local := _planet.to_local(second.global_position)
	if first_local.length_squared() < 1.0 or second_local.length_squared() < 1.0:
		return {}
	var direction := (
		first_local.normalized() + second_local.normalized()).normalized()
	if direction.is_zero_approx():
		direction = first_local.normalized()
	var placement := _placement(definition, direction, true)
	if placement.is_empty():
		direction = first_local.normalized()
		placement = _placement(definition, direction, true)
	if placement.is_empty():
		direction = second_local.normalized()
		placement = _placement(definition, direction, true)
	if placement.is_empty():
		return {}
	var sequence := _birth_sequence + 1
	var id := "b_%s_%d" % [definition.species_id, sequence]
	while _actors.has(id) or _dead_ids.has(id):
		sequence += 1
		id = "b_%s_%d" % [definition.species_id, sequence]
	_birth_sequence = sequence
	var seed := _mixed_seed(
		definition.random_seed, Vector3i(-2, sequence, 0), sequence)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var record := _record_for(
		definition, id, direction, placement, rng, seed)
	record["growth"] = definition.newborn_scale
	record["born"] = true
	return record


func _show_mating_heart(at: Vector3, up: Vector3, height: float) -> void:
	if not at.is_finite() or not up.is_finite():
		return
	var heart := MATING_HEART.new() as FaunaMatingHeart
	add_child(heart, false, Node.INTERNAL_MODE_BACK)
	heart.configure(at, up, height)


@rpc("authority", "call_remote", "reliable")
func _show_mating_heart_remote(at: Vector3, up: Vector3, height: float) -> void:
	_show_mating_heart(at, up, height)


# --- Actor lifetime and replication ----------------------------------------

func actor(id: String) -> FaunaMob:
	return _actors.get(id) as FaunaMob


func _on_actor_died(id: String) -> void:
	if not _is_host() or id.is_empty():
		return
	_dead_ids[id] = true
	_captured_ids.erase(id)
	_relocated_ids.erase(id)
	call_deferred(&"_retire_dead_actor", id)


func _retire_dead_actor(id: String) -> void:
	var mob := actor(id)
	if is_instance_valid(mob) and not mob.is_alive():
		_despawn_authoritative(id)


## Claims before hiding so simultaneous throws cannot both put the same actor
## in a ball. The player owns the cargo id; this spawner owns the streaming pin.
func capture_actor(id: String, captor_peer: int) -> bool:
	if not _is_host() or captor_peer <= 0 or _captured_ids.has(id):
		return false
	var mob := actor(id)
	if not is_instance_valid(mob) or not mob.can_be_captured():
		return false
	_captured_ids[id] = captor_peer
	if not mob.begin_capture(captor_peer):
		_captured_ids.erase(id)
		return false
	return true


func release_captured_actor(id: String, captor_peer: int,
		at: Vector3, forward: Vector3) -> bool:
	if not _is_host() or int(_captured_ids.get(id, 0)) != captor_peer:
		return false
	var mob := actor(id)
	if not is_instance_valid(mob) or not mob.end_capture(at, forward):
		return false
	_captured_ids.erase(id)
	if _global_ids.has(id):
		_relocated_ids[id] = true
	return true


func _spawn_authoritative(record: Dictionary, global_actor: bool) -> void:
	var id := String(record.get("id", ""))
	if id.is_empty() or _actors.has(id) or _dead_ids.has(id):
		return
	_spawn_local(record)
	if global_actor:
		_global_ids[id] = true
	if _has_remote_peers():
		_spawn_actor.rpc(record, global_actor)


@rpc("authority", "call_remote", "reliable")
func _spawn_actor(record: Dictionary, global_actor: bool) -> void:
	var id := String(record.get("id", ""))
	_spawn_local(record)
	if global_actor and not id.is_empty():
		_global_ids[id] = true


func _spawn_local(record: Dictionary) -> void:
	var id := String(record.get("id", ""))
	var definition := _species_by_id.get(
		String(record.get("species_id", ""))) as FaunaSpecies
	var transform_value: Variant = record.get("transform", Transform3D.IDENTITY)
	if id.is_empty() or _actors.has(id) or definition == null \
			or not transform_value is Transform3D \
			or (_is_host() and _dead_ids.has(id)):
		return
	var biome_value: Variant = record.get("biome", Color.WHITE)
	var biome := biome_value as Color if biome_value is Color else Color.WHITE
	var growth := clampf(float(record.get("growth", 1.0)), 0.1, 1.0)
	var migration_value: Variant = record.get(
		"migration_direction", Vector3.ZERO)
	var migration_direction := migration_value as Vector3 \
		if migration_value is Vector3 else Vector3.ZERO
	var migration_stop := maxf(float(record.get("migration_stop", 0.0)), 0.0)
	var mob := FaunaMob.new()
	mob.name = id
	mob.configure(
		definition, id, maxi(int(record.get("seed", 1)), 1),
		transform_value as Transform3D, biome, self, growth,
		migration_direction, migration_stop)
	mob.died.connect(_on_actor_died.bind(id))
	add_child(mob)
	_actors[id] = mob
	if _pending_states.has(id):
		mob.apply_network_state(_pending_states[id] as Dictionary, true)
		_pending_states.erase(id)


func _despawn_authoritative(id: String) -> void:
	if not _actors.has(id):
		_global_ids.erase(id)
		return
	_despawn_local(id)
	if _has_remote_peers():
		_despawn_actor.rpc(id)


@rpc("authority", "call_remote", "reliable")
func _despawn_actor(id: String) -> void:
	_despawn_local(id)


func _despawn_local(id: String) -> void:
	var mob := _actors.get(id) as FaunaMob
	_actors.erase(id)
	_global_ids.erase(id)
	_captured_ids.erase(id)
	_relocated_ids.erase(id)
	_pending_states.erase(id)
	if is_instance_valid(mob):
		mob.queue_free()


func publish_actor_state(id: String, wire: Dictionary) -> void:
	if not _is_host() or not _actors.has(id) or not _has_remote_peers():
		return
	_apply_actor_state.rpc(id, wire)


func publish_actor_event(id: String, wire: Dictionary) -> void:
	if not _is_host() or not _actors.has(id) or not _has_remote_peers():
		return
	_apply_actor_event.rpc(id, wire)


func publish_rhino_den_state(wire: Dictionary) -> void:
	if not _is_host() or not is_instance_valid(_rhino_den) \
			or not _has_remote_peers():
		return
	_apply_rhino_den_state.rpc(wire)


@rpc("authority", "call_remote", "reliable")
func _apply_rhino_den_state(wire: Dictionary) -> void:
	if is_instance_valid(_rhino_den):
		_rhino_den.apply_network_state(wire)


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_actor_state(id: String, wire: Dictionary) -> void:
	var mob := _actors.get(id) as FaunaMob
	if is_instance_valid(mob):
		mob.apply_network_state(wire)
	else:
		_pending_states[id] = wire


@rpc("authority", "call_remote", "reliable")
func _apply_actor_event(id: String, wire: Dictionary) -> void:
	var mob := _actors.get(id) as FaunaMob
	if is_instance_valid(mob):
		mob.apply_network_state(wire)
	else:
		_pending_states[id] = wire


@rpc("any_peer", "call_remote", "reliable")
func _request_fauna_snapshot() -> void:
	if not _is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	_apply_fauna_snapshot.rpc_id(sender, fauna_snapshot())
	_apply_rhino_den_snapshot.rpc_id(sender, rhino_den_snapshot())


@rpc("authority", "call_remote", "reliable")
func _apply_fauna_snapshot(snapshot: Array) -> void:
	var wanted := {}
	for entry_variant: Variant in snapshot:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		var spawn_value: Variant = entry.get("spawn", {})
		var state_value: Variant = entry.get("state", {})
		if not spawn_value is Dictionary:
			continue
		var spawn := spawn_value as Dictionary
		var id := String(spawn.get("id", ""))
		if id.is_empty():
			continue
		wanted[id] = true
		_spawn_local(spawn)
		if bool(entry.get("global", false)):
			_global_ids[id] = true
		var mob := _actors.get(id) as FaunaMob
		if is_instance_valid(mob) and state_value is Dictionary:
			mob.apply_network_state(state_value as Dictionary, true)
	for id_variant: Variant in _actors.keys():
		var id := String(id_variant)
		if not wanted.has(id):
			_despawn_local(id)


@rpc("authority", "call_remote", "reliable")
func _apply_rhino_den_snapshot(snapshot: Dictionary) -> void:
	var spawn_value: Variant = snapshot.get("spawn", {})
	var state_value: Variant = snapshot.get("state", {})
	if spawn_value is Dictionary and not (spawn_value as Dictionary).is_empty():
		_spawn_rhino_den_local(
			spawn_value as Dictionary,
			state_value as Dictionary if state_value is Dictionary else {},
			true)


func rhino_den_snapshot() -> Dictionary:
	return {
		"spawn": _rhino_den_record.duplicate(true),
		"state": _rhino_den.state_wire(),
	} if is_instance_valid(_rhino_den) else {}


func fauna_snapshot() -> Array:
	var snapshot: Array = []
	var ids := _actors.keys()
	ids.sort()
	for id_variant: Variant in ids:
		var id := String(id_variant)
		var mob := _actors[id] as FaunaMob
		if not is_instance_valid(mob) or not mob.is_alive() \
				or mob.species == null:
			continue
		snapshot.append({
			"spawn": {
				"id": id,
				"species_id": mob.species.species_id,
				"seed": mob.spawn_seed,
				"transform": mob.global_transform,
				"biome": mob.biome_tint(),
				"growth": mob.growth_share(),
				"migration_direction": mob.migration_direction(),
				"migration_stop": mob.migration_stop_radius(),
			},
			"state": mob.state_wire(),
			"global": _global_ids.has(id),
		})
	return snapshot


func sandbox_snapshot() -> Dictionary:
	return {
		"actors": fauna_snapshot(),
		"captured": _captured_ids.duplicate(true),
		"relocated": _relocated_ids.keys(),
		"dead": _dead_ids.keys(),
		"birth_sequence": _birth_sequence,
		"den_spawn_sequence": _den_spawn_sequence,
		"rhino_den": rhino_den_snapshot(),
	}


func snapshot_ready() -> bool:
	return _built


func apply_sandbox_snapshot(state: Dictionary) -> void:
	_dead_ids.clear()
	var dead_value: Variant = state.get("dead", [])
	if dead_value is Array or dead_value is PackedStringArray:
		for id_value: Variant in dead_value:
			var id := String(id_value)
			if not id.is_empty():
				_dead_ids[id] = true
	_birth_sequence = maxi(int(state.get("birth_sequence", 0)), 0)
	_den_spawn_sequence = maxi(int(state.get(
		"den_spawn_sequence", _den_spawn_sequence)), 0)
	var actor_value: Variant = state.get("actors", [])
	if actor_value is Array:
		_apply_fauna_snapshot(actor_value as Array)
	var den_value: Variant = state.get("rhino_den", {})
	if den_value is Dictionary and not (den_value as Dictionary).is_empty():
		_apply_rhino_den_snapshot(den_value as Dictionary)
	_captured_ids.clear()
	var captured_value: Variant = state.get("captured", {})
	if captured_value is Dictionary:
		for id_value: Variant in captured_value:
			var id := String(id_value)
			var captor := maxi(int((captured_value as Dictionary)[id_value]), 0)
			if captor > 0 and _actors.has(id):
				_captured_ids[id] = captor
	_relocated_ids.clear()
	var relocated_value: Variant = state.get("relocated", [])
	if relocated_value is Array or relocated_value is PackedStringArray:
		for id_value: Variant in relocated_value:
			var id := String(id_value)
			if _actors.has(id) and _global_ids.has(id):
				_relocated_ids[id] = true


# --- Bounded physical night lights -----------------------------------------

func _make_light_pool() -> void:
	for index in light_limit:
		var light := OmniLight3D.new()
		light.name = "FaunaLight%d" % index
		light.light_energy = 0.0
		light.shadow_enabled = false
		light.visible = false
		add_child(light, false, Node.INTERNAL_MODE_BACK)
		_lights.append(light)
		_light_actor_ids.append("")


func _update_lights(delta: float) -> void:
	if _lights.is_empty() or _planet == null:
		return
	var eye := _planet.to_global(_planet.viewer_position())
	var candidates: Array[Dictionary] = []
	for id_variant: Variant in _actors.keys():
		var id := String(id_variant)
		var mob := _actors[id] as FaunaMob
		if not is_instance_valid(mob) or not mob.is_alive() or mob.is_captured() \
				or mob.species.local_light_energy <= 0.0:
			continue
		var away := eye.distance_to(mob.glow_position())
		if away <= lights_within:
			candidates.append({"id": id, "away": away, "mob": mob})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["away"]) < float(b["away"]))
	if candidates.size() > _lights.size():
		candidates.resize(_lights.size())

	for index in _lights.size():
		var light := _lights[index]
		var target_energy := 0.0
		if index < candidates.size():
			var candidate := candidates[index]
			var mob := candidate["mob"] as FaunaMob
			var definition := mob.species
			_light_actor_ids[index] = String(candidate["id"])
			var follow := 1.0 - exp(-delta * light_follow_speed)
			light.global_position = light.global_position.lerp(
				mob.glow_position() + mob.global_basis.y \
					* definition.local_light_height_share * mob.instance_height(),
				clampf(follow, 0.0, 1.0))
			light.light_color = definition.local_light_color
			light.omni_range = definition.local_light_range
			var night := _night_at(mob.global_position) \
				if definition.glow_night_only else 1.0
			target_energy = definition.local_light_energy * night
		else:
			_light_actor_ids[index] = ""
		light.light_energy = move_toward(
			light.light_energy, target_energy,
			delta * maxf(maxf(target_energy, light.light_energy), 0.1)
				* light_fade_speed)
		light.visible = light.light_energy > 0.001


func _night_at(world_point: Vector3) -> float:
	if _planet.sun == null:
		return 1.0
	var local := _planet.to_local(world_point)
	if local.length_squared() < 1.0:
		return 0.0
	var world_up := (_planet.global_basis * local.normalized()).normalized()
	var to_sun := _planet.sun.global_basis.z.normalized()
	return 1.0 - smoothstep(-0.16, 0.12, world_up.dot(to_sun))


# --- Utilities and diagnostics ---------------------------------------------

func _viewer_positions() -> Array[Vector3]:
	var viewers: Array[Vector3] = []
	for player_variant: Variant in get_tree().get_nodes_in_group(&"network_players"):
		var player := player_variant as Node3D
		if player != null and DamageHit.in_same_world(self, player):
			viewers.append(player.global_position)
	if viewers.is_empty():
		viewers.append(_planet.to_global(_planet.viewer_position()))
	return viewers


func _nearest_distance(point: Vector3, viewers: Array[Vector3]) -> float:
	var nearest := INF
	for viewer in viewers:
		nearest = minf(nearest, point.distance_to(viewer))
	return nearest


func _tangent_axes(direction: Vector3) -> Array[Vector3]:
	var up := direction.normalized()
	var east := up.cross(Vector3.UP if absf(up.y) < 0.9 \
		else Vector3.RIGHT).normalized()
	return [east, up.cross(east).normalized()]


func _upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.000001:
		forward = _tangent_axes(up)[0]
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(right, up, right.cross(up).normalized()).orthonormalized()


func _mixed_seed(base: int, key: Vector3i, member: int) -> int:
	var mixed := int(base) ^ ((key.x + 17) * 73856093)
	mixed ^= (key.y + 104729) * 19349663
	mixed ^= (key.z + 130363) * 83492791
	mixed ^= (member + 8191) * 2654435761
	mixed ^= mixed >> 13
	mixed *= 1274126177
	mixed ^= mixed >> 16
	return absi(mixed) + 1


func _has_remote_peers() -> bool:
	return multiplayer.has_multiplayer_peer() \
		and multiplayer.is_server() and not multiplayer.get_peers().is_empty()


func _is_host() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


func actor_count() -> int:
	return _actors.size()


func actor_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id_variant: Variant in _actors.keys():
		ids.append(String(id_variant))
	ids.sort()
	return ids


func species_count(species_id: String) -> int:
	var count := 0
	for mob_variant: Variant in _actors.values():
		var mob := mob_variant as FaunaMob
		if is_instance_valid(mob) and mob.species != null \
				and mob.species.species_id == species_id:
			count += 1
	return count


func living_species_count(species_id: String) -> int:
	var count := 0
	for mob_variant: Variant in _actors.values():
		var mob := mob_variant as FaunaMob
		if is_instance_valid(mob) and mob.is_alive() and mob.species != null \
				and mob.species.species_id == species_id:
			count += 1
	return count


func _non_global_living_count(species_id: String) -> int:
	var count := 0
	for id_variant: Variant in _actors.keys():
		var id := String(id_variant)
		var mob := _actors[id] as FaunaMob
		if not _global_ids.has(id) and is_instance_valid(mob) \
				and mob.is_alive() and mob.species != null \
				and mob.species.species_id == species_id:
			count += 1
	return count


func is_permanently_dead(id: String) -> bool:
	return _dead_ids.has(id)


func rhino_den() -> Node:
	return _rhino_den if is_instance_valid(_rhino_den) else null


func last_den_placement_checks() -> int:
	return _last_den_placement_checks


func colony_actor_count() -> int:
	var count := 0
	for id_variant: Variant in _actors.keys():
		if String(id_variant).begins_with("c_"):
			count += 1
	return count


func light_pool_size() -> int:
	return _lights.size()


func last_survey_micros() -> int:
	return _last_survey_micros


func last_survey_placement_checks() -> int:
	return _last_survey_placement_checks


func last_colony_micros() -> int:
	return _last_colony_micros


func last_colony_placement_checks() -> int:
	return _last_colony_placement_checks


func should_publish_actor_state() -> bool:
	return _has_remote_peers()
