class_name MeepRegionPlan
extends RefCounted

## Deterministic ownership for one connected cluster of Meep cities.
##
## The caller samples the planet into a rectangular, region-local cost map and may
## run [method solve] on a worker. This class deliberately contains no Nodes,
## Resources, callables, or scene-tree access: inputs, scratch, snapshots, and
## results are value types, dictionaries, and packed arrays.
##
## Grid coordinates name two-metre cells. [member _origin] is the region-local
## position of the grid's top-left corner; cell positions are sampled at centres.
## Terrain byte 255 is impassable, 0/1 has unit cost, and 2..254 is progressively
## slower. A protected cell is always traversable by its owner.

const VERSION := 1
const CELL_SIZE := 2.0
const DEFAULT_SETBACK_METRES := 8.0
const DEFAULT_GATE_WIDTH_METRES := 6.0

const TERRAIN_BLOCKED := 255

## Values in the decoded owner map. Non-negative values index [method site_ids].
const OWNER_NEUTRAL := -1
const OWNER_UNREACHABLE := -2

## Packed seam/gate record: orientation, fixed lattice coordinate, inclusive
## variable start, exclusive variable end. Coordinates are in grid-cell units.
const SPAN_STRIDE := 4
const SPAN_ORIENTATION := 0
const SPAN_FIXED := 1
const SPAN_START := 2
const SPAN_END := 3
const HORIZONTAL := 0
const VERTICAL := 1

const _LOCK_NONE := -1
const _RATE_QUANTIZATION := 1000
const _MOVE_TICKS := 1000
const _MAX_TIME: int = 0x3fffffffffffffff
const _GATE_MARGIN_CELLS := 2

var _revision := 0
var _terrain_revision := 0
var _origin := Vector2.ZERO
var _size := Vector2i.ZERO
var _setback_metres := DEFAULT_SETBACK_METRES
var _gate_width_metres := DEFAULT_GATE_WIDTH_METRES

var _site_ids := PackedStringArray()
var _centres := PackedVector2Array()
var _forecast_rates := PackedFloat32Array()
var _seeds := PackedInt64Array()
var _protected_by_site: Dictionary = {}
var _site_lookup: Dictionary = {}

var _owners := PackedInt32Array()
var _seam_spans: Dictionary = {}
var _gate_gaps: Dictionary = {}
var _pair_sites: Dictionary = {}
var _setback_by_site: Dictionary = {}
var _last_error := ""


## Computes a complete candidate and publishes it only after every input validates.
##
## City dictionaries accept:
##   site: String/StringName (required)
##   local_centre or local_center: Vector2 (required)
##   forecast_rate: positive float (required)
##   seed: integer
##   protected_cells: PackedInt32Array of regional flat cell indices
##   protected_local: PackedVector2Array of region-local positions
##
## Arrays containing integer indices, Vector2i cells, or Vector2 positions are also
## accepted for tests and migration. Protected overlap between different cities is
## rejected rather than silently confiscating developed ground.
func solve(region_origin: Vector2, dimensions: Vector2i,
		terrain_costs: PackedByteArray, cities: Array,
		setback_metres := DEFAULT_SETBACK_METRES,
		gate_width_metres := DEFAULT_GATE_WIDTH_METRES,
		terrain_revision := 0) -> bool:
	if dimensions.x <= 0 or dimensions.y <= 0:
		return _fail("regional dimensions must be positive")
	if not is_finite(region_origin.x) or not is_finite(region_origin.y):
		return _fail("regional origin must be finite")
	var total := dimensions.x * dimensions.y
	if terrain_costs.size() != total:
		return _fail("terrain cost map does not match regional dimensions")
	if not is_finite(setback_metres) or setback_metres < 0.0:
		return _fail("setback must be finite and non-negative")
	if not is_finite(gate_width_metres) or gate_width_metres <= 0.0:
		return _fail("gate width must be finite and positive")

	var normalised := _normalise_cities(
		cities, region_origin, dimensions)
	if not bool(normalised.get("ok", false)):
		return _fail(String(normalised.get("error", "invalid city inputs")))

	var ids: PackedStringArray = normalised["site_ids"]
	var centres: PackedVector2Array = normalised["centres"]
	var rates: PackedFloat32Array = normalised["forecast_rates"]
	var seeds: PackedInt64Array = normalised["seeds"]
	var protected: Dictionary = normalised["protected"]
	var partition := _partition(dimensions, region_origin, terrain_costs,
		ids, centres, rates, protected)
	if not bool(partition.get("ok", false)):
		return _fail(String(partition.get("error", "ownership partition failed")))

	var preliminary: PackedInt32Array = partition["owners"]
	var locks: PackedInt32Array = partition["locks"]
	var gate_cells := maxi(roundi(gate_width_metres / CELL_SIZE), 1)
	var seam_data := _derive_seams(
		preliminary, locks, dimensions, ids, seeds, gate_cells)

	# Publish only complete data. A failed rebuild leaves the previous revision
	# queryable, which lets a registry apply worker results atomically.
	_origin = region_origin
	_size = dimensions
	_setback_metres = setback_metres
	_gate_width_metres = gate_width_metres
	_terrain_revision = maxi(terrain_revision, 0)
	_site_ids = ids
	_centres = centres
	_forecast_rates = rates
	_seeds = seeds
	_protected_by_site = protected
	_owners = seam_data["owners"]
	_seam_spans = seam_data["spans"]
	_gate_gaps = seam_data["gates"]
	_pair_sites = seam_data["pair_sites"]
	_rebuild_site_lookup()
	_setback_by_site = _derive_setback_masks()
	_revision += 1
	_last_error = ""
	return true


## Alias suited to registry code that speaks in terms of building a plan.
func build(region_origin: Vector2, dimensions: Vector2i,
		terrain_costs: PackedByteArray, cities: Array,
		setback_metres := DEFAULT_SETBACK_METRES,
		gate_width_metres := DEFAULT_GATE_WIDTH_METRES,
		terrain_revision := 0) -> bool:
	return solve(region_origin, dimensions, terrain_costs, cities,
		setback_metres, gate_width_metres, terrain_revision)


func valid() -> bool:
	return _size.x > 0 and _size.y > 0 \
		and _owners.size() == _size.x * _size.y \
		and not _site_ids.is_empty()


func region_revision() -> int:
	return _revision


func revision() -> int:
	return _revision


func terrain_revision() -> int:
	return _terrain_revision


func grid_origin() -> Vector2:
	return _origin


func grid_size() -> Vector2i:
	return _size


func cell_size() -> float:
	return CELL_SIZE


func cell_count() -> int:
	return _size.x * _size.y


func setback_metres() -> float:
	return _setback_metres


func gate_width_metres() -> float:
	return _gate_width_metres


func last_error() -> String:
	return _last_error


func site_ids() -> PackedStringArray:
	return _site_ids.duplicate()


func sites() -> PackedStringArray:
	return site_ids()


## One plan is one connected regional cluster.
func cluster_members() -> PackedStringArray:
	return site_ids()


func contains_site(site: Variant) -> bool:
	return _site_lookup.has(String(site))


func same_cluster(site_a: Variant, site_b: Variant) -> bool:
	return contains_site(site_a) and contains_site(site_b)


func site_index(site: Variant) -> int:
	return int(_site_lookup.get(String(site), -1))


func forecast_inputs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in _site_ids.size():
		var key := String(_site_ids[index])
		out.push_back({
			"site": key,
			"local_centre": _centres[index],
			"forecast_rate": float(_forecast_rates[index]),
			"seed": int(_seeds[index]),
			"protected_cells": (_protected_by_site.get(
				key, PackedInt32Array()) as PackedInt32Array).duplicate(),
		})
	return out


func forecast_input(site: Variant) -> Dictionary:
	var index := site_index(site)
	if index < 0:
		return {}
	var key := String(_site_ids[index])
	return {
		"site": key,
		"local_centre": _centres[index],
		"forecast_rate": float(_forecast_rates[index]),
		"seed": int(_seeds[index]),
		"protected_cells": (_protected_by_site.get(
			key, PackedInt32Array()) as PackedInt32Array).duplicate(),
	}


func inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < _size.x and cell.y < _size.y


func index_of(cell: Vector2i) -> int:
	return cell.y * _size.x + cell.x if inside(cell) else -1


func origin() -> Vector2:
	return _origin


func dimensions() -> Vector2i:
	return _size


func cell_of(region_local: Vector2) -> Vector2i:
	return Vector2i(
		floori((region_local.x - _origin.x) / CELL_SIZE),
		floori((region_local.y - _origin.y) / CELL_SIZE))


func centre_of(cell: Vector2i) -> Vector2:
	return _origin + (Vector2(cell) + Vector2(0.5, 0.5)) * CELL_SIZE


func owner_index_at(region_local: Vector2) -> int:
	var at := index_of(cell_of(region_local))
	return _owners[at] if at >= 0 and at < _owners.size() \
		else OWNER_UNREACHABLE


func owner_index_of_cell(cell: Vector2i) -> int:
	var at := index_of(cell)
	return _owners[at] if at >= 0 and at < _owners.size() \
		else OWNER_UNREACHABLE


## Empty means either a shared neutral seam or unreachable/out-of-bounds ground.
## Use [method owner_index_at] when that distinction matters.
func owner_at(region_local: Vector2) -> StringName:
	var owner := owner_index_at(region_local)
	return StringName(_site_ids[owner]) \
		if owner >= 0 and owner < _site_ids.size() else &""


func owner_of_cell(cell: Vector2i) -> StringName:
	var owner := owner_index_of_cell(cell)
	return StringName(_site_ids[owner]) \
		if owner >= 0 and owner < _site_ids.size() else &""


func is_shared_seam_at(region_local: Vector2) -> bool:
	return owner_index_at(region_local) == OWNER_NEUTRAL


func owner_map() -> PackedInt32Array:
	return _owners.duplicate()


func owner_map_rle() -> PackedInt32Array:
	return encode_owner_rle(_owners)


## A byte is 1 only where this site exclusively owns the regional cell.
func owner_mask(site: Variant) -> PackedByteArray:
	var wanted := site_index(site)
	var mask := PackedByteArray()
	mask.resize(_owners.size())
	if wanted < 0:
		return mask
	for index in _owners.size():
		if _owners[index] == wanted:
			mask[index] = 1
	return mask


## A byte is 1 where this site's construction must leave room for the shared wall.
func setback_mask(site: Variant) -> PackedByteArray:
	var value: Variant = _setback_by_site.get(String(site), null)
	return (value as PackedByteArray).duplicate() \
		if value is PackedByteArray else PackedByteArray()


func buildable_mask(site: Variant) -> PackedByteArray:
	var owned := owner_mask(site)
	var setback := setback_mask(site)
	for index in owned.size():
		if index < setback.size() and setback[index] != 0:
			owned[index] = 0
	return owned


## Projects regional ownership into another two-metre tangent grid.
##
## [param target_origin] is the target grid's top-left corner in target-local
## metres. [param target_to_region] maps those metres into this plan's regional
## tangent frame. The returned owner byte uses MeepGrid's contract (1 = own);
## setback uses 1 = reserved/no building.
func project_masks(site: Variant, target_origin: Vector2,
		target_size: Vector2i,
		target_to_region := Transform2D.IDENTITY) -> Dictionary:
	var total := maxi(target_size.x, 0) * maxi(target_size.y, 0)
	var owned := PackedByteArray()
	var setback := PackedByteArray()
	var buildable := PackedByteArray()
	owned.resize(total)
	setback.resize(total)
	buildable.resize(total)
	var wanted := site_index(site)
	if wanted < 0 or target_size.x <= 0 or target_size.y <= 0:
		return {
			"owner": owned,
			"setback": setback,
			"buildable": buildable,
		}
	var source_setback := setback_mask(site)
	for y in target_size.y:
		for x in target_size.x:
			var target_at := y * target_size.x + x
			var target_local := target_origin \
				+ (Vector2(x, y) + Vector2(0.5, 0.5)) * CELL_SIZE
			var regional: Vector2 = target_to_region * target_local
			var source_at := index_of(cell_of(regional))
			if source_at < 0 or source_at >= _owners.size():
				continue
			if source_at < source_setback.size() \
					and source_setback[source_at] != 0:
				setback[target_at] = 1
			if _owners[source_at] != wanted:
				continue
			owned[target_at] = 1
			if setback[target_at] == 0:
				buildable[target_at] = 1
	return {
		"owner": owned,
		"setback": setback,
		"buildable": buildable,
	}


func local_masks(site: Variant, local_origin: Vector2,
		local_size: Vector2i,
		local_to_region := Transform2D.IDENTITY) -> Dictionary:
	return project_masks(
		site, local_origin, local_size, local_to_region)


## Site IDs are escaped before joining so the key remains unambiguous.
static func pair_key(site_a: Variant, site_b: Variant) -> String:
	var a := String(site_a)
	var b := String(site_b)
	if b < a:
		var swap := a
		a = b
		b = swap
	return "%s|%s" % [_escape_pair_part(a), _escape_pair_part(b)]


func seam_pair_keys() -> PackedStringArray:
	var keys := PackedStringArray()
	for value: Variant in _seam_spans.keys():
		keys.push_back(String(value))
	keys.sort()
	return keys


func seam_spans() -> Dictionary:
	return _seam_spans.duplicate(true)


func gate_gaps() -> Dictionary:
	return _gate_gaps.duplicate(true)


func seam_spans_for_pair(pair_or_site_a: Variant,
		site_b: Variant = null) -> PackedInt32Array:
	var key := String(pair_or_site_a) if site_b == null \
		else pair_key(pair_or_site_a, site_b)
	var value: Variant = _seam_spans.get(key, null)
	return (value as PackedInt32Array).duplicate() \
		if value is PackedInt32Array else PackedInt32Array()


func gate_gaps_for_pair(pair_or_site_a: Variant,
		site_b: Variant = null) -> PackedInt32Array:
	var key := String(pair_or_site_a) if site_b == null \
		else pair_key(pair_or_site_a, site_b)
	var value: Variant = _gate_gaps.get(key, null)
	return (value as PackedInt32Array).duplicate() \
		if value is PackedInt32Array else PackedInt32Array()


## Metric records are a presentation/infrastructure convenience. Gate endpoints
## are packed in pairs in `gate_gaps`; all positions remain region-local.
func seam_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for key in seam_pair_keys():
		var spans := seam_spans_for_pair(key)
		var gates := gate_gaps_for_pair(key)
		var pair: PackedInt32Array = _pair_sites.get(
			String(key), PackedInt32Array())
		if pair.size() < 2:
			continue
		var names := PackedStringArray([
			_site_ids[pair[0]], _site_ids[pair[1]]])
		for offset in range(0, spans.size(), SPAN_STRIDE):
			var orientation := spans[offset + SPAN_ORIENTATION]
			var fixed := spans[offset + SPAN_FIXED]
			var start := spans[offset + SPAN_START]
			var end := spans[offset + SPAN_END]
			var endpoints := _metric_endpoints(
				orientation, fixed, start, end)
			var metric_gates := PackedVector2Array()
			for gate in range(0, gates.size(), SPAN_STRIDE):
				if gates[gate + SPAN_ORIENTATION] != orientation \
						or gates[gate + SPAN_FIXED] != fixed:
					continue
				var gate_start := gates[gate + SPAN_START]
				var gate_end := gates[gate + SPAN_END]
				if gate_start < start or gate_end > end:
					continue
				var gate_points := _metric_endpoints(
					orientation, fixed, gate_start, gate_end)
				metric_gates.push_back(gate_points[0])
				metric_gates.push_back(gate_points[1])
			records.push_back({
				"id": "%s#%d:%d:%d:%d" % [
					key, orientation, fixed, start, end],
				"pair_key": String(key),
				"sites": names,
				"from": endpoints[0],
				"to": endpoints[1],
				"gate_gaps": metric_gates,
			})
	return records


## Owner maps are persisted as `(value, run length)` integer pairs.
static func encode_owner_rle(owner_values: PackedInt32Array) -> PackedInt32Array:
	var encoded := PackedInt32Array()
	if owner_values.is_empty():
		return encoded
	var value := owner_values[0]
	var run := 1
	for index in range(1, owner_values.size()):
		if owner_values[index] == value and run < 0x7fffffff:
			run += 1
			continue
		encoded.push_back(value)
		encoded.push_back(run)
		value = owner_values[index]
		run = 1
	encoded.push_back(value)
	encoded.push_back(run)
	return encoded


## Returns empty on malformed data or a decoded-size mismatch.
static func decode_owner_rle(encoded: PackedInt32Array,
		expected_count: int) -> PackedInt32Array:
	var decoded := PackedInt32Array()
	if expected_count < 0 or (encoded.size() & 1) != 0:
		return decoded
	if expected_count == 0:
		return decoded if encoded.is_empty() else PackedInt32Array()
	decoded.resize(expected_count)
	var write := 0
	for index in range(0, encoded.size(), 2):
		var run := encoded[index + 1]
		if run <= 0 or write + run > expected_count:
			return PackedInt32Array()
		var value := encoded[index]
		for offset in run:
			decoded[write + offset] = value
		write += run
	if write != expected_count:
		return PackedInt32Array()
	return decoded


func snapshot() -> Dictionary:
	return {
		"version": VERSION,
		"revision": _revision,
		"terrain_revision": _terrain_revision,
		"cell_size": CELL_SIZE,
		"origin": _origin,
		"size": _size,
		"setback_metres": _setback_metres,
		"gate_width_metres": _gate_width_metres,
		"site_ids": _site_ids.duplicate(),
		"centres": _centres.duplicate(),
		"forecast_rates": _forecast_rates.duplicate(),
		"seeds": _seeds.duplicate(),
		"protected": _protected_by_site.duplicate(true),
		"owner_rle": encode_owner_rle(_owners),
		"seam_spans": _seam_spans.duplicate(true),
		"gate_gaps": _gate_gaps.duplicate(true),
		"pair_sites": _pair_sites.duplicate(true),
	}


## Restores only an exact current-version snapshot. Validation is completed
## before publication, so a corrupt save cannot partially replace a live plan.
func apply_snapshot(state: Dictionary) -> bool:
	if int(state.get("version", 0)) != VERSION:
		return _fail("unsupported regional snapshot version")
	if not state.get("size", null) is Vector2i \
			or not state.get("origin", null) is Vector2:
		return _fail("regional snapshot is missing grid geometry")
	var dimensions: Vector2i = state["size"]
	var origin: Vector2 = state["origin"]
	if dimensions.x <= 0 or dimensions.y <= 0 \
			or not is_finite(origin.x) or not is_finite(origin.y):
		return _fail("regional snapshot has invalid grid geometry")
	if absf(float(state.get("cell_size", -1.0)) - CELL_SIZE) > 0.0001:
		return _fail("regional snapshot uses a different cell size")

	var ids_value: Variant = state.get("site_ids", null)
	var centres_value: Variant = state.get("centres", null)
	var rates_value: Variant = state.get("forecast_rates", null)
	var seeds_value: Variant = state.get("seeds", null)
	var rle_value: Variant = state.get("owner_rle", null)
	if not ids_value is PackedStringArray \
			or not centres_value is PackedVector2Array \
			or not rates_value is PackedFloat32Array \
			or not seeds_value is PackedInt64Array \
			or not rle_value is PackedInt32Array:
		return _fail("regional snapshot has invalid packed fields")
	var ids := (ids_value as PackedStringArray).duplicate()
	var centres := (centres_value as PackedVector2Array).duplicate()
	var rates := (rates_value as PackedFloat32Array).duplicate()
	var seeds := (seeds_value as PackedInt64Array).duplicate()
	if ids.is_empty() or centres.size() != ids.size() \
			or rates.size() != ids.size() or seeds.size() != ids.size():
		return _fail("regional snapshot forecast fields disagree")
	for index in ids.size():
		if String(ids[index]).is_empty() \
				or (index > 0 and String(ids[index - 1]) >= String(ids[index])):
			return _fail("regional snapshot site IDs are not strictly sorted")
		if not is_finite(centres[index].x) \
				or not is_finite(centres[index].y) \
				or not is_finite(rates[index]) or rates[index] <= 0.0:
			return _fail("regional snapshot has invalid forecast input")

	var owners := decode_owner_rle(
		rle_value as PackedInt32Array, dimensions.x * dimensions.y)
	if owners.size() != dimensions.x * dimensions.y:
		return _fail("regional owner RLE is malformed")
	for owner in owners:
		if owner < OWNER_UNREACHABLE or owner >= ids.size():
			return _fail("regional owner RLE names an invalid site")

	var protected_value: Variant = state.get("protected", {})
	var spans_value: Variant = state.get("seam_spans", {})
	var gates_value: Variant = state.get("gate_gaps", {})
	var pairs_value: Variant = state.get("pair_sites", {})
	if not protected_value is Dictionary or not spans_value is Dictionary \
			or not gates_value is Dictionary or not pairs_value is Dictionary:
		return _fail("regional snapshot seam/protected fields are invalid")
	var protected := _validate_protected_snapshot(
		protected_value as Dictionary, ids, owners.size())
	if not bool(protected.get("ok", false)):
		return _fail(String(protected.get("error", "invalid protected cells")))
	var seam_check := _validate_seam_snapshot(
		spans_value as Dictionary, gates_value as Dictionary,
		pairs_value as Dictionary, ids.size(), dimensions)
	if not bool(seam_check.get("ok", false)):
		return _fail(String(seam_check.get("error", "invalid seam records")))

	var setback := float(state.get(
		"setback_metres", DEFAULT_SETBACK_METRES))
	var gate_width := float(state.get(
		"gate_width_metres", DEFAULT_GATE_WIDTH_METRES))
	if not is_finite(setback) or setback < 0.0 \
			or not is_finite(gate_width) or gate_width <= 0.0:
		return _fail("regional snapshot has invalid wall dimensions")

	_origin = origin
	_size = dimensions
	_setback_metres = setback
	_gate_width_metres = gate_width
	_revision = maxi(int(state.get("revision", 0)), 0)
	_terrain_revision = maxi(int(state.get("terrain_revision", 0)), 0)
	_site_ids = ids
	_centres = centres
	_forecast_rates = rates
	_seeds = seeds
	_protected_by_site = protected["value"]
	_owners = owners
	_seam_spans = (spans_value as Dictionary).duplicate(true)
	_gate_gaps = (gates_value as Dictionary).duplicate(true)
	_pair_sites = (pairs_value as Dictionary).duplicate(true)
	_rebuild_site_lookup()
	_setback_by_site = _derive_setback_masks()
	_last_error = ""
	return true


func _normalise_cities(cities: Array, region_origin: Vector2,
		dimensions: Vector2i) -> Dictionary:
	if cities.is_empty():
		return {"ok": false, "error": "at least one city is required"}
	var by_site: Dictionary = {}
	for value: Variant in cities:
		if not value is Dictionary:
			return {"ok": false, "error": "city input is not a dictionary"}
		var city := value as Dictionary
		var site := String(city.get("site", ""))
		if site.is_empty():
			return {"ok": false, "error": "city input has an empty site ID"}
		if by_site.has(site):
			return {"ok": false, "error": "city site IDs must be unique"}
		by_site[site] = city
	var keys: Array = by_site.keys()
	keys.sort()
	var ids := PackedStringArray()
	var centres := PackedVector2Array()
	var rates := PackedFloat32Array()
	var seeds := PackedInt64Array()
	var protected: Dictionary = {}
	for key_value: Variant in keys:
		var key := String(key_value)
		var city := by_site[key] as Dictionary
		var centre_value: Variant = city.get("local_centre",
			city.get("local_center", city.get("centre", null)))
		if not centre_value is Vector2:
			return {
				"ok": false,
				"error": "city %s has no local Vector2 centre" % key,
			}
		var centre := centre_value as Vector2
		var rate := float(city.get("forecast_rate", 0.0))
		if not is_finite(centre.x) or not is_finite(centre.y) \
				or not is_finite(rate) or rate <= 0.0:
			return {
				"ok": false,
				"error": "city %s has invalid forecast input" % key,
			}
		var centre_cell := _cell_for(centre, region_origin)
		if not _inside_size(centre_cell, dimensions):
			return {
				"ok": false,
				"error": "city %s centre lies outside the region" % key,
			}
		var protected_result := _normalise_protected(
			city, region_origin, dimensions)
		if not bool(protected_result.get("ok", false)):
			return {
				"ok": false,
				"error": "city %s: %s" % [
					key, protected_result.get("error", "invalid protected cells")],
			}
		ids.push_back(key)
		centres.push_back(centre)
		rates.push_back(rate)
		seeds.push_back(int(city.get("seed", 0)))
		protected[key] = protected_result["value"]
	return {
		"ok": true,
		"site_ids": ids,
		"centres": centres,
		"forecast_rates": rates,
		"seeds": seeds,
		"protected": protected,
	}


func _normalise_protected(city: Dictionary, region_origin: Vector2,
		dimensions: Vector2i) -> Dictionary:
	var unique: Dictionary = {}
	var raw: Variant = city.get("protected_cells", PackedInt32Array())
	if raw is PackedInt32Array:
		for at in raw as PackedInt32Array:
			if at < 0 or at >= dimensions.x * dimensions.y:
				return {"ok": false, "error": "protected index is outside region"}
			unique[at] = true
	elif raw is PackedVector2Array:
		for local in raw as PackedVector2Array:
			var cell := _cell_for(local, region_origin)
			if not _inside_size(cell, dimensions):
				return {"ok": false, "error": "protected point is outside region"}
			unique[_flat_index(cell, dimensions)] = true
	elif raw is Array:
		for item: Variant in raw:
			var at := -1
			if item is int:
				at = int(item)
			elif item is Vector2i:
				var cell := item as Vector2i
				at = _flat_index(cell, dimensions) \
					if _inside_size(cell, dimensions) else -1
			elif item is Vector2:
				var cell := _cell_for(item as Vector2, region_origin)
				at = _flat_index(cell, dimensions) \
					if _inside_size(cell, dimensions) else -1
			else:
				return {"ok": false, "error": "unsupported protected cell value"}
			if at < 0 or at >= dimensions.x * dimensions.y:
				return {"ok": false, "error": "protected cell is outside region"}
			unique[at] = true
	else:
		return {"ok": false, "error": "protected_cells is not packed data"}
	var local_value: Variant = city.get(
		"protected_local", PackedVector2Array())
	if local_value is PackedVector2Array:
		for local in local_value as PackedVector2Array:
			var cell := _cell_for(local, region_origin)
			if not _inside_size(cell, dimensions):
				return {"ok": false, "error": "protected point is outside region"}
			unique[_flat_index(cell, dimensions)] = true
	elif local_value is Array:
		for item: Variant in local_value:
			if not item is Vector2:
				return {"ok": false, "error": "protected_local requires Vector2"}
			var cell := _cell_for(item as Vector2, region_origin)
			if not _inside_size(cell, dimensions):
				return {"ok": false, "error": "protected point is outside region"}
			unique[_flat_index(cell, dimensions)] = true
	else:
		return {"ok": false, "error": "protected_local is not packed data"}
	var indices := PackedInt32Array()
	for value: Variant in unique.keys():
		indices.push_back(int(value))
	indices.sort()
	return {"ok": true, "value": indices}


func _partition(dimensions: Vector2i, region_origin: Vector2,
		terrain_costs: PackedByteArray, ids: PackedStringArray,
		centres: PackedVector2Array, rates: PackedFloat32Array,
		protected: Dictionary) -> Dictionary:
	var total := dimensions.x * dimensions.y
	var locks := PackedInt32Array()
	locks.resize(total)
	locks.fill(_LOCK_NONE)
	var sources: Array[PackedInt32Array] = []
	sources.resize(ids.size())
	for owner in ids.size():
		var owner_sources := PackedInt32Array()
		var centre_cell := _cell_for(centres[owner], region_origin)
		var centre_at := _flat_index(centre_cell, dimensions)
		var protected_cells: PackedInt32Array = protected.get(
			String(ids[owner]), PackedInt32Array())
		owner_sources.push_back(centre_at)
		owner_sources.append_array(protected_cells)
		var deduplicated := PackedInt32Array()
		for at in owner_sources:
			if locks[at] >= 0 and locks[at] != owner:
				return {
					"ok": false,
					"error": "protected cells overlap between %s and %s" % [
						ids[locks[at]], ids[owner]],
				}
			locks[at] = owner
			if deduplicated.is_empty() or deduplicated[-1] != at:
				deduplicated.push_back(at)
		sources[owner] = deduplicated

	var owners := PackedInt32Array()
	owners.resize(total)
	owners.fill(OWNER_UNREACHABLE)
	var arrival := PackedInt64Array()
	arrival.resize(total)
	arrival.fill(_MAX_TIME)
	var rate_q := PackedInt64Array()
	rate_q.resize(ids.size())
	for owner in ids.size():
		rate_q[owner] = maxi(
			roundi(float(rates[owner]) * _RATE_QUANTIZATION), 1)

	var heap_times := PackedInt64Array()
	var heap_owners := PackedInt32Array()
	var heap_cells := PackedInt32Array()
	for owner in ids.size():
		for at in sources[owner]:
			if arrival[at] == 0 and owners[at] == owner:
				continue
			arrival[at] = 0
			owners[at] = owner
			_heap_push(heap_times, heap_owners, heap_cells, 0, owner, at)

	var popped := PackedInt64Array()
	popped.resize(3)
	while not heap_times.is_empty():
		_heap_pop(heap_times, heap_owners, heap_cells, popped)
		var time := popped[0]
		var owner := int(popped[1])
		var at := int(popped[2])
		if arrival[at] != time or owners[at] != owner:
			continue
		var x := at % dimensions.x
		var y := at / dimensions.x
		for neighbour in [
				at - 1 if x > 0 else -1,
				at + 1 if x + 1 < dimensions.x else -1,
				at - dimensions.x if y > 0 else -1,
				at + dimensions.x if y + 1 < dimensions.y else -1,
			]:
			if neighbour < 0:
				continue
			var target_lock := locks[neighbour]
			if target_lock >= 0 and target_lock != owner:
				continue
			var terrain := int(terrain_costs[neighbour])
			if terrain == TERRAIN_BLOCKED and target_lock != owner:
				continue
			var cost := maxi(terrain, 1) \
				if terrain != TERRAIN_BLOCKED else 1
			var numerator: int = _MOVE_TICKS * cost * _RATE_QUANTIZATION
			var edge_time: int = (numerator + rate_q[owner] - 1) \
				/ rate_q[owner]
			if time > _MAX_TIME - edge_time:
				continue
			var candidate := time + edge_time
			if candidate > arrival[neighbour] \
					or (candidate == arrival[neighbour] \
						and owners[neighbour] >= 0 \
						and owner >= owners[neighbour]):
				continue
			arrival[neighbour] = candidate
			owners[neighbour] = owner
			_heap_push(heap_times, heap_owners, heap_cells,
				candidate, owner, neighbour)
	return {"ok": true, "owners": owners, "locks": locks}


func _derive_seams(preliminary: PackedInt32Array,
		locks: PackedInt32Array, dimensions: Vector2i,
		ids: PackedStringArray, seeds: PackedInt64Array,
		gate_cells: int) -> Dictionary:
	var owners := preliminary.duplicate()
	var edge_sets: Dictionary = {}
	var pair_sites: Dictionary = {}
	var variable_base := maxi(dimensions.x, dimensions.y) + 1
	var edge_base := variable_base * variable_base
	for y in dimensions.y:
		for x in dimensions.x:
			var at := y * dimensions.x + x
			var owner := preliminary[at]
			if owner < 0:
				continue
			if x + 1 < dimensions.x:
				_record_boundary(at, at + 1, VERTICAL, x + 1, y,
					preliminary, locks, owners, ids,
					edge_sets, pair_sites, variable_base, edge_base)
			if y + 1 < dimensions.y:
				_record_boundary(at, at + dimensions.x, HORIZONTAL, y + 1, x,
					preliminary, locks, owners, ids,
					edge_sets, pair_sites, variable_base, edge_base)

	var pair_keys := PackedStringArray()
	for value: Variant in edge_sets.keys():
		pair_keys.push_back(String(value))
	pair_keys.sort()
	var spans_by_pair: Dictionary = {}
	var gates_by_pair: Dictionary = {}
	for key in pair_keys:
		var edge_set := edge_sets[String(key)] as Dictionary
		var spans := PackedInt32Array()
		for fixed in range(1, dimensions.y):
			_append_edge_runs(spans, edge_set, HORIZONTAL, fixed,
				dimensions.x, variable_base, edge_base)
		for fixed in range(1, dimensions.x):
			_append_edge_runs(spans, edge_set, VERTICAL, fixed,
				dimensions.y, variable_base, edge_base)
		spans_by_pair[String(key)] = spans
		var pair: PackedInt32Array = pair_sites[String(key)]
		gates_by_pair[String(key)] = _derive_gate_gaps(
			String(key), spans, gate_cells,
			seeds[pair[0]], seeds[pair[1]])
	return {
		"owners": owners,
		"spans": spans_by_pair,
		"gates": gates_by_pair,
		"pair_sites": pair_sites,
	}


func _record_boundary(at: int, neighbour: int, orientation: int,
		fixed: int, variable: int, preliminary: PackedInt32Array,
		locks: PackedInt32Array, owners: PackedInt32Array,
		ids: PackedStringArray, edge_sets: Dictionary,
		pair_sites: Dictionary, variable_base: int, edge_base: int) -> void:
	var first := preliminary[at]
	var second := preliminary[neighbour]
	if second < 0 or first == second:
		return
	var low := mini(first, second)
	var high := maxi(first, second)
	var key := pair_key(ids[low], ids[high])
	var edge_set: Dictionary = edge_sets.get(key, {})
	var code := orientation * edge_base + fixed * variable_base + variable
	edge_set[code] = true
	edge_sets[key] = edge_set
	if not pair_sites.has(key):
		pair_sites[key] = PackedInt32Array([low, high])
	if locks[at] == _LOCK_NONE:
		owners[at] = OWNER_NEUTRAL
	if locks[neighbour] == _LOCK_NONE:
		owners[neighbour] = OWNER_NEUTRAL


func _append_edge_runs(spans: PackedInt32Array, edge_set: Dictionary,
		orientation: int, fixed: int, variable_limit: int,
		variable_base: int, edge_base: int) -> void:
	var variable := 0
	while variable < variable_limit:
		var code := orientation * edge_base \
			+ fixed * variable_base + variable
		if not edge_set.has(code):
			variable += 1
			continue
		var start := variable
		while variable < variable_limit:
			code = orientation * edge_base \
				+ fixed * variable_base + variable
			if not edge_set.has(code):
				break
			variable += 1
		spans.append_array(PackedInt32Array([
			orientation, fixed, start, variable]))


func _derive_gate_gaps(key: String, spans: PackedInt32Array,
		wanted_width: int, first_seed: int, second_seed: int) -> PackedInt32Array:
	var gates := PackedInt32Array()
	var longest_offset := -1
	var longest_length := -1
	for offset in range(0, spans.size(), SPAN_STRIDE):
		var length := spans[offset + SPAN_END] - spans[offset + SPAN_START]
		if length > longest_length:
			longest_length = length
			longest_offset = offset
		if length < wanted_width + _GATE_MARGIN_CELLS * 2:
			continue
		_append_gate(gates, key, spans, offset, wanted_width,
			_GATE_MARGIN_CELLS, first_seed, second_seed)
	# Stair-stepped terrain can consist solely of short spans. It still receives
	# one deterministic crossing instead of producing an accidentally sealed pair.
	if gates.is_empty() and longest_offset >= 0:
		_append_gate(gates, key, spans, longest_offset,
			mini(wanted_width, longest_length), 0, first_seed, second_seed)
	return gates


func _append_gate(gates: PackedInt32Array, key: String,
		spans: PackedInt32Array, offset: int, width: int, margin: int,
		first_seed: int, second_seed: int) -> void:
	var orientation := spans[offset + SPAN_ORIENTATION]
	var fixed := spans[offset + SPAN_FIXED]
	var start := spans[offset + SPAN_START]
	var end := spans[offset + SPAN_END]
	width = clampi(width, 1, end - start)
	var available := maxi(end - start - width - margin * 2, 0)
	var fingerprint := "%s:%d:%d:%d:%d:%d:%d" % [
		key, orientation, fixed, start, end, first_seed, second_seed]
	var gate_start := start + margin
	if available > 0:
		gate_start += _stable_hash(fingerprint) % (available + 1)
	gate_start = mini(gate_start, end - width)
	gates.append_array(PackedInt32Array([
		orientation, fixed, gate_start, gate_start + width]))


func _derive_setback_masks() -> Dictionary:
	var masks: Array = []
	for _site in _site_ids:
		var mask := PackedByteArray()
		mask.resize(_owners.size())
		masks.push_back(mask)
	var radius := _setback_metres / CELL_SIZE
	if radius <= 0.0:
		var empty_result: Dictionary = {}
		for index in _site_ids.size():
			empty_result[String(_site_ids[index])] = masks[index]
		return empty_result
	var radius_squared := radius * radius
	for key in seam_pair_keys():
		var pair: PackedInt32Array = _pair_sites.get(
			String(key), PackedInt32Array())
		if pair.size() < 2:
			continue
		var first_mask := masks[pair[0]] as PackedByteArray
		var second_mask := masks[pair[1]] as PackedByteArray
		var spans := seam_spans_for_pair(key)
		for offset in range(0, spans.size(), SPAN_STRIDE):
			var orientation := spans[offset + SPAN_ORIENTATION]
			var fixed := spans[offset + SPAN_FIXED]
			var start := spans[offset + SPAN_START]
			var end := spans[offset + SPAN_END]
			var min_x: int
			var max_x: int
			var min_y: int
			var max_y: int
			if orientation == HORIZONTAL:
				min_x = maxi(floori(float(start) - radius) - 1, 0)
				max_x = mini(ceili(float(end) + radius) + 1, _size.x)
				min_y = maxi(floori(float(fixed) - radius) - 1, 0)
				max_y = mini(ceili(float(fixed) + radius) + 1, _size.y)
			else:
				min_x = maxi(floori(float(fixed) - radius) - 1, 0)
				max_x = mini(ceili(float(fixed) + radius) + 1, _size.x)
				min_y = maxi(floori(float(start) - radius) - 1, 0)
				max_y = mini(ceili(float(end) + radius) + 1, _size.y)
			for y in range(min_y, max_y):
				for x in range(min_x, max_x):
					if _distance_squared_to_span(
							Vector2(float(x) + 0.5, float(y) + 0.5),
							orientation, fixed, start, end) >= radius_squared:
						continue
					var at := y * _size.x + x
					var owner := _owners[at]
					if owner == pair[0] or owner == OWNER_NEUTRAL:
						first_mask[at] = 1
					if owner == pair[1] or owner == OWNER_NEUTRAL:
						second_mask[at] = 1
		masks[pair[0]] = first_mask
		masks[pair[1]] = second_mask
	var result: Dictionary = {}
	for index in _site_ids.size():
		result[String(_site_ids[index])] = masks[index]
	return result


func _validate_protected_snapshot(protected: Dictionary,
		ids: PackedStringArray, total: int) -> Dictionary:
	var copy: Dictionary = {}
	for site in ids:
		var value: Variant = protected.get(String(site), PackedInt32Array())
		if not value is PackedInt32Array:
			return {"ok": false, "error": "protected snapshot is not packed"}
		var indices := (value as PackedInt32Array).duplicate()
		var previous := -1
		for at in indices:
			if at < 0 or at >= total or at <= previous:
				return {
					"ok": false,
					"error": "protected snapshot index is invalid or unsorted",
				}
			previous = at
		copy[String(site)] = indices
	for value: Variant in protected.keys():
		if not String(value) in ids:
			return {"ok": false, "error": "protected snapshot names unknown site"}
	return {"ok": true, "value": copy}


func _validate_seam_snapshot(spans: Dictionary, gates: Dictionary,
		pairs: Dictionary, site_count: int,
		dimensions: Vector2i) -> Dictionary:
	for key_value: Variant in spans.keys():
		var key := String(key_value)
		var span_value: Variant = spans[key]
		var gate_value: Variant = gates.get(key, null)
		var pair_value: Variant = pairs.get(key, null)
		if not span_value is PackedInt32Array \
				or not gate_value is PackedInt32Array \
				or not pair_value is PackedInt32Array:
			return {"ok": false, "error": "seam record is not packed"}
		var pair := pair_value as PackedInt32Array
		if pair.size() != 2 or pair[0] < 0 or pair[1] <= pair[0] \
				or pair[1] >= site_count:
			return {"ok": false, "error": "seam pair indices are invalid"}
		if not _spans_valid(
				span_value as PackedInt32Array, dimensions):
			return {"ok": false, "error": "seam span is invalid"}
		if not _spans_valid(
				gate_value as PackedInt32Array, dimensions):
			return {"ok": false, "error": "gate gap is invalid"}
	for key_value: Variant in gates.keys():
		if not spans.has(String(key_value)):
			return {"ok": false, "error": "gate has no seam pair"}
	for key_value: Variant in pairs.keys():
		if not spans.has(String(key_value)):
			return {"ok": false, "error": "pair has no seam spans"}
	return {"ok": true}


func _spans_valid(values: PackedInt32Array,
		dimensions: Vector2i) -> bool:
	if (values.size() % SPAN_STRIDE) != 0:
		return false
	for offset in range(0, values.size(), SPAN_STRIDE):
		var orientation := values[offset + SPAN_ORIENTATION]
		var fixed := values[offset + SPAN_FIXED]
		var start := values[offset + SPAN_START]
		var end := values[offset + SPAN_END]
		if end <= start or orientation < HORIZONTAL or orientation > VERTICAL:
			return false
		if orientation == HORIZONTAL:
			if fixed <= 0 or fixed >= dimensions.y \
					or start < 0 or end > dimensions.x:
				return false
		else:
			if fixed <= 0 or fixed >= dimensions.x \
					or start < 0 or end > dimensions.y:
				return false
	return true


func _metric_endpoints(orientation: int, fixed: int,
		start: int, end: int) -> PackedVector2Array:
	if orientation == HORIZONTAL:
		return PackedVector2Array([
			_origin + Vector2(start, fixed) * CELL_SIZE,
			_origin + Vector2(end, fixed) * CELL_SIZE])
	return PackedVector2Array([
		_origin + Vector2(fixed, start) * CELL_SIZE,
		_origin + Vector2(fixed, end) * CELL_SIZE])


func _rebuild_site_lookup() -> void:
	_site_lookup.clear()
	for index in _site_ids.size():
		_site_lookup[String(_site_ids[index])] = index


func _fail(message: String) -> bool:
	_last_error = message
	return false


static func _cell_for(local: Vector2, origin: Vector2) -> Vector2i:
	return Vector2i(
		floori((local.x - origin.x) / CELL_SIZE),
		floori((local.y - origin.y) / CELL_SIZE))


static func _inside_size(cell: Vector2i, dimensions: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 \
		and cell.x < dimensions.x and cell.y < dimensions.y


static func _flat_index(cell: Vector2i, dimensions: Vector2i) -> int:
	return cell.y * dimensions.x + cell.x


static func _escape_pair_part(value: String) -> String:
	return value.replace("%", "%25").replace("|", "%7C")


static func _stable_hash(value: String) -> int:
	var hashed: int = 2166136261
	for index in value.length():
		hashed = int((hashed ^ value.unicode_at(index)) * 16777619) \
			& 0x7fffffff
	return hashed


static func _distance_squared_to_span(point: Vector2, orientation: int,
		fixed: int, start: int, end: int) -> float:
	if orientation == HORIZONTAL:
		var nearest_x := clampf(point.x, float(start), float(end))
		return point.distance_squared_to(Vector2(nearest_x, float(fixed)))
	var nearest_y := clampf(point.y, float(start), float(end))
	return point.distance_squared_to(Vector2(float(fixed), nearest_y))


static func _heap_push(times: PackedInt64Array,
		owners: PackedInt32Array, cells: PackedInt32Array,
		time: int, owner: int, cell: int) -> void:
	times.push_back(time)
	owners.push_back(owner)
	cells.push_back(cell)
	var at := times.size() - 1
	while at > 0:
		var parent := (at - 1) / 2
		if not _heap_less(times[at], owners[at], cells[at],
				times[parent], owners[parent], cells[parent]):
			break
		_heap_swap(times, owners, cells, at, parent)
		at = parent


static func _heap_pop(times: PackedInt64Array,
		owners: PackedInt32Array, cells: PackedInt32Array,
		out: PackedInt64Array) -> void:
	out[0] = times[0]
	out[1] = owners[0]
	out[2] = cells[0]
	var last := times.size() - 1
	if last == 0:
		times.resize(0)
		owners.resize(0)
		cells.resize(0)
		return
	times[0] = times[last]
	owners[0] = owners[last]
	cells[0] = cells[last]
	times.resize(last)
	owners.resize(last)
	cells.resize(last)
	var at := 0
	while true:
		var left := at * 2 + 1
		if left >= times.size():
			break
		var right := left + 1
		var child := left
		if right < times.size() and _heap_less(
				times[right], owners[right], cells[right],
				times[left], owners[left], cells[left]):
			child = right
		if not _heap_less(times[child], owners[child], cells[child],
				times[at], owners[at], cells[at]):
			break
		_heap_swap(times, owners, cells, at, child)
		at = child


static func _heap_less(first_time: int, first_owner: int, first_cell: int,
		second_time: int, second_owner: int, second_cell: int) -> bool:
	if first_time != second_time:
		return first_time < second_time
	if first_owner != second_owner:
		return first_owner < second_owner
	return first_cell < second_cell


static func _heap_swap(times: PackedInt64Array,
		owners: PackedInt32Array, cells: PackedInt32Array,
		first: int, second: int) -> void:
	var time := times[first]
	times[first] = times[second]
	times[second] = time
	var owner := owners[first]
	owners[first] = owners[second]
	owners[second] = owner
	var cell := cells[first]
	cells[first] = cells[second]
	cells[second] = cell
