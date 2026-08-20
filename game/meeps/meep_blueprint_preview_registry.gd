class_name MeepBlueprintPreviewRegistry
extends Node3D

signal blueprint_added(blueprint_id: StringName)
signal blueprint_removed(blueprint_id: StringName)
signal blueprint_changed(blueprint_id: StringName)
signal projection_ready(blueprint_id: StringName, projection: Dictionary)

## Client-local planning registry. It reads real regional facts, but no method in
## this class writes to MeepColonies, sends an RPC, or participates in a save.

const DEFAULT_POPULATION := MeepColony.STARTER_POPULATION
const MIN_POPULATION := MeepColony.FIRST_WAVE
const MAX_POPULATION := MeepColony.MAX_CITY_POPULATION
const MAX_STABILIZATION_PASSES := 2

var planet: Planet
var colonies: MeepColonies

var _entries: Dictionary = {}
var _next_id := 1
var _task := -1
var _worker_output: Dictionary = {}
var _dirty := false
var _requested_generation := 0
var _stabilization_pass := 0
var _seen_context_revision := -1


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func configure(for_planet: Planet, for_colonies: MeepColonies) -> void:
	planet = for_planet
	colonies = for_colonies
	_seen_context_revision = colonies.regional_context_revision() \
		if colonies != null else -1
	if colonies != null and not colonies.regional_context_changed.is_connected(
			_on_regional_context_changed):
		colonies.regional_context_changed.connect(
			_on_regional_context_changed)


func _exit_tree() -> void:
	if colonies != null and colonies.regional_context_changed.is_connected(
			_on_regional_context_changed):
		colonies.regional_context_changed.disconnect(
			_on_regional_context_changed)
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_entries.clear()


func _process(_delta: float) -> void:
	if colonies != null:
		var revision := colonies.regional_context_revision()
		if revision != _seen_context_revision:
			_seen_context_revision = revision
			queue_rebuild()
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_finish_rebuild()
	if _dirty and _task < 0:
		_start_rebuild()


func add_blueprint(direction: Vector3, facing := 0.0,
		population := DEFAULT_POPULATION) -> StringName:
	if not valid_placement(direction):
		return &""
	var id := StringName("blueprint_%d" % _next_id)
	_next_id += 1
	var centre := direction.normalized()
	var seed_text := "%0.8f|%0.8f|%0.8f|%0.3f" % [
		centre.x, centre.y, centre.z, facing,
	]
	_entries[id] = {
		"id": id,
		"direction": centre,
		"facing": facing,
		"seed": int(seed_text.sha256_text().left(8).hex_to_int()),
		"population": clampi(population, MIN_POPULATION, MAX_POPULATION),
		"ground": {},
		"projection": {},
		"protected_directions": PackedVector3Array([centre]),
		"protected_signature": 0,
		"visual": null,
		"marker": null,
		"revision": 0,
	}
	blueprint_added.emit(id)
	queue_rebuild(true)
	return id


func remove_blueprint(id: StringName) -> bool:
	var entry := _entry(id)
	if entry.is_empty():
		return false
	for key in [&"visual", &"marker"]:
		var node := entry.get(key) as Node
		if is_instance_valid(node):
			node.queue_free()
	_entries.erase(id)
	blueprint_removed.emit(id)
	queue_rebuild(true)
	return true


func clear() -> void:
	var ids := blueprint_ids()
	for id in ids:
		remove_blueprint(id)


func blueprint_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id_variant: Variant in _entries:
		out.push_back(StringName(id_variant))
	out.sort_custom(func(a: StringName, b: StringName) -> bool:
		return String(a) < String(b))
	return out


func has_blueprint(id: StringName) -> bool:
	return _entries.has(id)


func blueprint_count() -> int:
	return _entries.size()


func population(id: StringName) -> int:
	return int(_entry(id).get("population", DEFAULT_POPULATION))


func direction(id: StringName) -> Vector3:
	return _entry(id).get("direction", Vector3.ZERO)


func facing(id: StringName) -> float:
	return float(_entry(id).get("facing", 0.0))


func seed(id: StringName) -> int:
	return int(_entry(id).get("seed", 0))


func projection(id: StringName) -> Dictionary:
	var value: Variant = _entry(id).get("projection", {})
	return (value as Dictionary).duplicate(true) \
		if value is Dictionary else {}


func set_population(id: StringName, value: int) -> bool:
	var entry := _entry(id)
	if entry.is_empty():
		return false
	var bounded := clampi(value, MIN_POPULATION, MAX_POPULATION)
	if int(entry.get("population", DEFAULT_POPULATION)) == bounded:
		return true
	entry["population"] = bounded
	entry["revision"] = int(entry.get("revision", 0)) + 1
	_entries[id] = entry
	blueprint_changed.emit(id)
	queue_rebuild(true)
	return true


func attach_marker(id: StringName, marker: Node3D) -> void:
	var entry := _entry(id)
	if entry.is_empty():
		return
	entry["marker"] = marker
	_entries[id] = entry


func attach_visual(id: StringName, visual: Node3D) -> void:
	var entry := _entry(id)
	if entry.is_empty():
		return
	entry["visual"] = visual
	_entries[id] = entry
	var projected_value: Variant = entry.get("projection", {})
	if visual != null and projected_value is Dictionary \
			and not (projected_value as Dictionary).is_empty() \
			and visual.has_method(&"apply_projection"):
		visual.call(&"apply_projection",
			(projected_value as Dictionary).duplicate(true))


func report(id: StringName) -> Dictionary:
	var entry := _entry(id)
	if entry.is_empty():
		return {}
	var projected_value: Variant = entry.get("projection", {})
	var projected := projected_value as Dictionary \
		if projected_value is Dictionary else {}
	var growth := colonies.regional_population_growth(
		id, int(entry.get("population", DEFAULT_POPULATION))) \
		if colonies != null else 0.05
	return {
		"id": String(id),
		"population": int(entry.get("population", DEFAULT_POPULATION)),
		"growth_per_second": growth,
		"growth_per_minute": growth * 60.0,
		"forecast_rate": colonies.regional_forecast_rate(
			id, int(entry.get("population", DEFAULT_POPULATION))) \
			if colonies != null else 0.0,
		"calculating": _dirty or _task >= 0
			or projected.is_empty(),
		"tier": int(projected.get("tier", 0)),
		"housing_capacity": int(projected.get(
			"housing_capacity", MeepColony.FIRST_WAVE)),
		"stalled": bool(projected.get("stalled", false)),
		"revision": int(entry.get("revision", 0)),
	}


func queue_rebuild(reset_stabilization := false) -> void:
	if _entries.is_empty():
		_dirty = false
		return
	if reset_stabilization:
		_stabilization_pass = 0
	_requested_generation += 1
	_dirty = true


func rebuilding() -> bool:
	return _dirty or _task >= 0


func valid_placement(target: Vector3,
		ignore_id: StringName = &"") -> bool:
	if planet == null or planet.shape == null or not target.is_finite() \
			or target.length_squared() < 0.5:
		return false
	var centre := target.normalized()
	if colonies != null:
		if not colonies.valid_blueprint_landing(centre):
			return false
	elif not _valid_landing_terrain(centre):
		return false
	for id in blueprint_ids():
		if id == ignore_id:
			continue
		if _surface_distance(centre, direction(id)) \
				< MeepColonies.SETTLEMENT_CLEARANCE:
			return false
	return true


func _valid_landing_terrain(centre: Vector3) -> bool:
	var landing := MeepSite.new(
		centre, planet.shape.radius, 0.0, 24.0)
	var lowest := INF
	var highest := -INF
	var samples: Dictionary = {}
	for x in range(-3, 4):
		for y in range(-2, 3):
			var local := Vector2(
				MeepColonies.LANDING_HALF_SIZE.x * float(x) / 3.0,
				MeepColonies.LANDING_HALF_SIZE.y * float(y) / 2.0)
			var height := planet.shape.elevation(
				landing.direction_at(local))
			if height < MeepGrid.SHORE_MARGIN:
				return false
			samples[Vector2i(x, y)] = height
			lowest = minf(lowest, height)
			highest = maxf(highest, height)
	if highest - lowest > MeepColonies.LANDING_LEVEL_TOLERANCE:
		return false
	for cell_variant: Variant in samples:
		var cell: Vector2i = cell_variant
		var here := float(samples[cell])
		for step in [Vector2i.RIGHT, Vector2i.DOWN]:
			if samples.has(cell + step):
				var run := 3.0 if step.x != 0 else 2.5
				if absf(float(samples[cell + step]) - here) / run \
						> tan(deg_to_rad(MeepGrid.MAX_SLOPE_DEGREES)):
					return false
	return true


func _entry(id: StringName) -> Dictionary:
	var value: Variant = _entries.get(id, {})
	return value as Dictionary if value is Dictionary else {}


func _on_regional_context_changed(revision: int) -> void:
	_seen_context_revision = revision
	queue_rebuild()


func _start_rebuild() -> void:
	if planet == null or planet.shape == null or _entries.is_empty():
		_dirty = false
		return
	_dirty = false
	var input_entries: Array = []
	for id in blueprint_ids():
		var entry := _entry(id)
		var assumed_population := int(entry.get(
			"population", DEFAULT_POPULATION))
		input_entries.push_back({
			"id": String(id),
			"direction": entry.get("direction", Vector3.UP),
			"facing": float(entry.get("facing", 0.0)),
			"seed": int(entry.get("seed", 0)),
			"population": assumed_population,
			"forecast_rate": colonies.regional_forecast_rate(
				id, assumed_population) if colonies != null else 0.11,
			"ground": (entry.get("ground", {}) as Dictionary).duplicate(true)
				if entry.get("ground", {}) is Dictionary else {},
			"protected_directions": (entry.get(
				"protected_directions", PackedVector3Array())
				as PackedVector3Array).duplicate(),
		})
	var real_facts := colonies.regional_city_facts() \
		if colonies != null else []
	var spacing := planet.finest_spacing()
	var generation := _requested_generation
	var terrain_revision := colonies.regional_context_revision() \
		if colonies != null else 0
	_worker_output = {}
	_task = WorkerThreadPool.add_task(_solve_worker.bind(
		input_entries, real_facts, planet.shape, spacing,
		terrain_revision, generation), true,
		"Meep blueprint region preview")


func _solve_worker(input_entries: Array, real_facts: Array,
		shape: PlanetShape, spacing: float, terrain_revision: int,
		generation: int) -> void:
	var facts := real_facts.duplicate(true)
	var grounds: Dictionary = {}
	for entry_variant: Variant in input_entries:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		var id := String(entry.get("id", ""))
		var site := MeepSite.new(
			entry.get("direction", Vector3.UP), shape.radius,
			float(entry.get("facing", 0.0)),
			MeepColony.MAX_CLAIM_RADIUS)
		var ground_value: Variant = entry.get("ground", {})
		var ground := (ground_value as Dictionary).duplicate(true) \
			if ground_value is Dictionary else {}
		if ground.is_empty():
			ground = MeepCityProjection.bake_ground(
				site, shape, spacing)
		grounds[id] = ground
		var population := int(entry.get(
			"population", DEFAULT_POPULATION))
		facts.push_back({
			"site": id,
			"direction": site.centre,
			"facing": site.facing,
			"seed": int(entry.get("seed", 0)),
			"population": population,
			"forecast_rate": float(entry.get(
				"forecast_rate", 0.11)),
			"protected_directions": (entry.get(
				"protected_directions", PackedVector3Array())
				as PackedVector3Array).duplicate(),
		})
	var regions := MeepColonies.solve_region_facts(
		facts, shape, spacing, terrain_revision)
	var projections: Dictionary = {}
	for entry_variant: Variant in input_entries:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		var id := String(entry.get("id", ""))
		var site := MeepSite.new(
			entry.get("direction", Vector3.UP), shape.radius,
			float(entry.get("facing", 0.0)),
			MeepColony.MAX_CLAIM_RADIUS)
		var region_projection := _region_projection_for(
			id, regions)
		var rivals := _rivals_for(StringName(id), facts)
		var projected := MeepCityProjection.project({
			"site": site,
			"shape": shape,
			"ground": grounds.get(id, {}),
			"population": int(entry.get(
				"population", DEFAULT_POPULATION)),
			"seed": int(entry.get("seed", 0)),
			"owner_mask": region_projection.get(
				"owner", PackedByteArray()),
			"setback_mask": region_projection.get(
				"setback", PackedByteArray()),
			"region_revision": int(region_projection.get(
				"revision", -1)),
			"rival_centres": rivals.get(
				"centres", PackedVector3Array()),
			"rival_wins_ties": rivals.get(
				"ties", PackedByteArray()),
		})
		if not projected.is_empty():
			projections[id] = projected
	_worker_output = {
		"generation": generation,
		"grounds": grounds,
		"regions": regions,
		"facts": facts,
		"projections": projections,
	}


func _finish_rebuild() -> void:
	var output := _worker_output
	_worker_output = {}
	if output.is_empty():
		return
	var grounds_value: Variant = output.get("grounds", {})
	var grounds := grounds_value as Dictionary \
		if grounds_value is Dictionary else {}
	for id in blueprint_ids():
		var entry := _entry(id)
		var id_text := String(id)
		var ground_value: Variant = grounds.get(id_text, {})
		if ground_value is Dictionary and not (
				ground_value as Dictionary).is_empty():
			entry["ground"] = (ground_value as Dictionary).duplicate(true)
			_entries[id] = entry
	if int(output.get("generation", -1)) != _requested_generation:
		_dirty = true
		return

	var projections_value: Variant = output.get("projections", {})
	var projections := projections_value as Dictionary \
		if projections_value is Dictionary else {}
	var protected_changed := false
	for id in blueprint_ids():
		var entry := _entry(id)
		var projected_value: Variant = projections.get(
			String(id), {})
		var projected := projected_value as Dictionary \
			if projected_value is Dictionary else {}
		if projected.is_empty():
			continue
		var protected: PackedVector3Array = projected.get(
			"protected_directions", PackedVector3Array())
		var signature := hash(protected)
		if signature != int(entry.get("protected_signature", 0)):
			protected_changed = true
		entry["protected_directions"] = protected.duplicate()
		entry["protected_signature"] = signature
		entry["projection"] = projected
		entry["revision"] = int(entry.get("revision", 0)) + 1
		_entries[id] = entry
		var visual := entry.get("visual") as Node
		if is_instance_valid(visual) \
				and visual.has_method(&"apply_projection"):
			visual.call(&"apply_projection", projected.duplicate(true))
		projection_ready.emit(id, projected.duplicate(true))
		blueprint_changed.emit(id)
	if protected_changed \
			and _stabilization_pass < MAX_STABILIZATION_PASSES:
		_stabilization_pass += 1
		queue_rebuild()
	else:
		_stabilization_pass = 0


static func _region_projection_for(id: String,
		regions: Array) -> Dictionary:
	for wrapper_variant: Variant in regions:
		if not wrapper_variant is Dictionary:
			continue
		var wrapper := wrapper_variant as Dictionary
		var projections_value: Variant = wrapper.get("projections", {})
		if not projections_value is Dictionary \
				or not (projections_value as Dictionary).has(id):
			continue
		var value: Variant = (projections_value as Dictionary)[id]
		var projected := (value as Dictionary).duplicate(true) \
			if value is Dictionary else {}
		var snapshot_value: Variant = wrapper.get("snapshot", {})
		if snapshot_value is Dictionary:
			projected["revision"] = int(
				(snapshot_value as Dictionary).get("revision", -1))
		return projected
	return {}


static func _rivals_for(id: StringName, facts: Array) -> Dictionary:
	var centres := PackedVector3Array()
	var ties := PackedByteArray()
	var mine := String(id)
	for fact_variant: Variant in facts:
		if not fact_variant is Dictionary:
			continue
		var fact := fact_variant as Dictionary
		var other := String(fact.get("site", ""))
		if other == mine:
			continue
		var centre: Vector3 = fact.get("direction", Vector3.ZERO)
		if centre.length_squared() < 0.5:
			continue
		centres.push_back(centre.normalized())
		ties.push_back(1 if other < mine else 0)
	return {
		"centres": centres,
		"ties": ties,
	}


func _surface_distance(a: Vector3, b: Vector3) -> float:
	if planet == null or planet.shape == null \
			or a.length_squared() < 0.5 or b.length_squared() < 0.5:
		return INF
	return acos(clampf(a.normalized().dot(
		b.normalized()), -1.0, 1.0)) * planet.shape.radius
