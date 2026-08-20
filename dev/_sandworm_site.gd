extends Node

## Deterministic, read-only desert arena survey and baked-site regression.
##
##     godot --headless --path . dev/_sandworm_site.tscn -- --survey-only
##     godot --headless --path . dev/_sandworm_site.tscn

const WORLD_PATH := "res://game/world.tscn"
const SITE_PATH := "res://game/enemies/sandworm/sandworm_site.gd"
const BOSS_PATH := "res://game/enemies/sandworm/sandworm.tscn"
const SANDWORM_SCRIPT := preload(
	"res://game/enemies/sandworm/sandworm.gd")

const SEARCH_ARCS := [48.0, 56.0, 64.0, 72.0, 80.0, 88.0]
const BEARINGS := 360
const ENCOUNTER_RADIUS := 1600.0
const SURVEYED_CORE_RADIUS := 185.0
const TERRAIN_SPACING := 1.5
const MIN_ARID := 0.72
const MIN_DRY_SHARE := 0.96
const MIN_ARID_SHARE := 0.88
const MAX_AVERAGE_SLOPE := 10.0
const MAX_SLOPE := 19.0
const MAX_HEIGHT_SPREAD := 10.0
const MIN_SETTLEMENT_CLEARANCE := 2600.0
const MIN_BIGFOOT_CLEARANCE := 2200.0
const MIN_VOLCANO_EDGE_CLEARANCE := 1800.0

var _failures := 0
var _shape: PlanetShape
var _planet: Planet
var _colony := Vector3.UP
var _settlements: Array[Dictionary] = []
var _bigfoot := Vector3.ZERO


func _ready() -> void:
	var packed := load(WORLD_PATH) as PackedScene
	if packed == null:
		_fail("could not load " + WORLD_PATH)
		get_tree().quit(_failures)
		return
	var world := packed.instantiate()
	_planet = world.get_node_or_null("Planet") as Planet
	var colony := world.get_node_or_null("Planet/ColonyShip") as SurfaceAnchor
	var bigfoot := world.get_node_or_null("Planet/BigfootTerritory") as SurfaceAnchor
	if _planet == null or _planet.shape == null:
		_fail("world has no configured PlanetShape")
	if colony == null:
		_fail("world has no ColonyShip anchor")
	if _failures > 0:
		world.free()
		get_tree().quit(_failures)
		return
	_shape = _planet.shape
	_shape.prepare()
	_colony = colony.direction.normalized()
	_bigfoot = bigfoot.direction.normalized() if bigfoot != null \
		else Vector3.ZERO
	_collect_clearances()

	var winner := _search()
	if winner.is_empty():
		_fail("no desert arena met the survey limits")
	else:
		print("\nWINNER")
		_say(winner, "winner")
		if not OS.get_cmdline_user_args().has("--survey-only"):
			_verify_baked(world, winner)
	world.free()
	print("\nSANDWORM SITE VALIDATION %s" % (
		"PASSED" if _failures == 0 else "FAILED (%d)" % _failures))
	get_tree().quit(_failures)


func _collect_clearances() -> void:
	_settlements.append({"name": "ColonyShip", "direction": _colony})
	for plan: CityPlan in Settlements.plans():
		_settlements.append({
			"name": plan.title,
			"direction": plan.centre.normalized(),
		})


func _search() -> Dictionary:
	print("Sandworm desert survey: six colony-distance rings, %d bearings" \
		% BEARINGS)
	var coarse: Array[Dictionary] = []
	for arc: float in SEARCH_ARCS:
		for index in BEARINGS:
			var direction := _on_colony_ring(
				arc, 360.0 * float(index) / float(BEARINGS))
			if not _clearances_allowed(direction):
				continue
			var measured := _measure(direction, _coarse_offsets())
			if float(measured["dry_share"]) < 0.78 \
					or float(measured["arid_share"]) < 0.72:
				continue
			coarse.append(measured)
	coarse.sort_custom(_better)
	print("  coarse survivors: %d / %d" % [
		coarse.size(), SEARCH_ARCS.size() * BEARINGS])
	if coarse.is_empty():
		return {}

	var detailed: Array[Dictionary] = []
	for candidate: Dictionary in coarse:
		if detailed.size() >= 28:
			break
		var direction: Vector3 = candidate["direction"]
		var duplicate := false
		for kept: Dictionary in detailed:
			if direction.angle_to(kept["direction"]) * _shape.radius < 300.0:
				duplicate = true
				break
		if duplicate:
			continue
		detailed.append(_measure(direction, _detail_offsets()))
	detailed.sort_custom(_better)
	print("\nDetailed candidates:")
	for index in mini(8, detailed.size()):
		_say(detailed[index], "#%d" % (index + 1))
	for candidate: Dictionary in detailed:
		if bool(candidate["qualified"]):
			return candidate
	return {}


func _measure(direction: Vector3, offsets: Array[Vector2]) -> Dictionary:
	var arid_total := 0.0
	var arid_count := 0
	var dry_count := 0
	var slopes := PackedFloat32Array()
	var heights := PackedFloat32Array()
	for offset: Vector2 in offsets:
		var at := _at_offset(direction, offset)
		var parts := _shape.sample(at)
		var arid := clampf(float(parts.get("arid", 0.0)), 0.0, 1.0)
		var height := _shape.elevation(at, TERRAIN_SPACING)
		var dry := height > 8.0 \
			and float(parts.get("river", 0.0)) <= 0.0 \
			and float(parts.get("lake", 0.0)) <= 0.0
		arid_total += arid
		arid_count += int(arid >= MIN_ARID)
		dry_count += int(dry)
		heights.append(height)
		slopes.append(_slope(at))
	slopes.sort()
	heights.sort()
	var count := maxf(float(offsets.size()), 1.0)
	var average_slope := 0.0
	for value: float in slopes:
		average_slope += value
	average_slope /= count
	var dry_share := float(dry_count) / count
	var arid_share := float(arid_count) / count
	var arid_average := arid_total / count
	var maximum_slope := slopes[-1]
	var spread := heights[-1] - heights[0]
	var settlement := _nearest_settlement(direction)
	var bigfoot_distance := direction.angle_to(_bigfoot) * _shape.radius \
		if _bigfoot.length_squared() > 0.5 else INF
	var volcano_distance := direction.angle_to(
		_shape.volcano_axis()) * _shape.radius
	var volcano_edge := volcano_distance - _shape.volcano_radius
	var qualified := dry_share >= MIN_DRY_SHARE \
		and arid_share >= MIN_ARID_SHARE \
		and average_slope <= MAX_AVERAGE_SLOPE \
		and maximum_slope <= MAX_SLOPE \
		and spread <= MAX_HEIGHT_SPREAD \
		and float(settlement["distance"]) >= MIN_SETTLEMENT_CLEARANCE \
		and bigfoot_distance >= MIN_BIGFOOT_CLEARANCE \
		and volcano_edge >= MIN_VOLCANO_EDGE_CLEARANCE
	var score := arid_average * 8.0 + arid_share * 4.0 + dry_share * 2.0 \
		- average_slope * 0.22 - maximum_slope * 0.06 - spread * 0.08
	return {
		"direction": direction,
		"arc_degrees": rad_to_deg(direction.angle_to(_colony)),
		"arid_average": arid_average,
		"arid_share": arid_share,
		"dry_share": dry_share,
		"elevation": _shape.elevation(direction, TERRAIN_SPACING),
		"elevation_min": heights[0],
		"elevation_max": heights[-1],
		"average_slope": average_slope,
		"p90_slope": slopes[clampi(
			roundi(float(slopes.size() - 1) * 0.9), 0, slopes.size() - 1)],
		"max_slope": maximum_slope,
		"height_spread": spread,
		"settlement_clearance": settlement["distance"],
		"nearest_settlement": settlement["name"],
		"bigfoot_clearance": bigfoot_distance,
		"volcano_edge_clearance": volcano_edge,
		"qualified": qualified,
		"score": score + (100.0 if qualified else 0.0),
	}


func _coarse_offsets() -> Array[Vector2]:
	var result: Array[Vector2] = [Vector2.ZERO]
	for radius: float in [
		SURVEYED_CORE_RADIUS * 0.48, SURVEYED_CORE_RADIUS * 0.94]:
		for index in 8:
			var angle := TAU * float(index) / 8.0
			result.append(Vector2(cos(angle), sin(angle)) * radius)
	return result


func _detail_offsets() -> Array[Vector2]:
	var result: Array[Vector2] = []
	for row in range(-5, 6):
		for column in range(-5, 6):
			var offset := Vector2(column, row) * 34.0
			if offset.length() <= SURVEYED_CORE_RADIUS:
				result.append(offset)
	return result


func _on_colony_ring(arc_degrees: float, bearing_degrees: float) -> Vector3:
	var east := _tangent_east(_colony)
	var north := _colony.cross(east).normalized()
	var bearing := deg_to_rad(bearing_degrees)
	var radial := east * cos(bearing) + north * sin(bearing)
	var arc := deg_to_rad(arc_degrees)
	return (_colony * cos(arc) + radial * sin(arc)).normalized()


func _at_offset(centre: Vector3, offset: Vector2) -> Vector3:
	if offset.length_squared() < 0.000001:
		return centre.normalized()
	var east := _tangent_east(centre)
	var north := centre.cross(east).normalized()
	var tangent := east * offset.x + north * offset.y
	var distance := tangent.length()
	return (
		centre.normalized() * cos(distance / _shape.radius)
		+ tangent.normalized() * sin(distance / _shape.radius)
	).normalized()


func _slope(direction: Vector3) -> float:
	var normal := _shape.normal_at(direction, TERRAIN_SPACING)
	return rad_to_deg(acos(clampf(normal.dot(direction), -1.0, 1.0)))


func _clearances_allowed(direction: Vector3) -> bool:
	var settlement := _nearest_settlement(direction)
	if float(settlement["distance"]) < MIN_SETTLEMENT_CLEARANCE:
		return false
	if _bigfoot.length_squared() > 0.5 \
			and direction.angle_to(_bigfoot) * _shape.radius \
				< MIN_BIGFOOT_CLEARANCE:
		return false
	var volcano_edge := direction.angle_to(
		_shape.volcano_axis()) * _shape.radius - _shape.volcano_radius
	return volcano_edge >= MIN_VOLCANO_EDGE_CLEARANCE


func _nearest_settlement(direction: Vector3) -> Dictionary:
	var result := {"name": "", "distance": INF}
	for row: Dictionary in _settlements:
		var distance := direction.angle_to(
			row["direction"] as Vector3) * _shape.radius
		if distance < float(result["distance"]):
			result = {"name": row["name"], "distance": distance}
	return result


func _better(a: Dictionary, b: Dictionary) -> bool:
	return float(a["score"]) > float(b["score"])


func _say(row: Dictionary, label: String) -> void:
	var direction: Vector3 = row["direction"]
	print("  %s dir=(%.9f, %.9f, %.9f), arc %.3f deg, "
		% [label, direction.x, direction.y, direction.z,
			float(row["arc_degrees"])]
		+ "arid avg/share %.3f/%.1f%%, dry %.1f%%, "
		% [float(row["arid_average"]), float(row["arid_share"]) * 100.0,
			float(row["dry_share"]) * 100.0]
		+ "elev %.1f (%.1f..%.1f), slope avg/p90/max %.2f/%.2f/%.2f, "
		% [float(row["elevation"]), float(row["elevation_min"]),
			float(row["elevation_max"]), float(row["average_slope"]),
			float(row["p90_slope"]), float(row["max_slope"])]
		+ "nearest %s %.0f m, Bigfoot %.0f m, volcano edge %.0f m, %s"
		% [String(row["nearest_settlement"]),
			float(row["settlement_clearance"]),
			float(row["bigfoot_clearance"]),
			float(row["volcano_edge_clearance"]),
			"QUALIFIED" if bool(row["qualified"]) else "rejected"])


func _verify_baked(world: Node, winner: Dictionary) -> void:
	var site := world.get_node_or_null("Planet/SandwormTerritory")
	_check(site != null, "world contains Planet/SandwormTerritory")
	if site == null:
		return
	_check(site is Landmark, "territory is a public Landmark")
	var landmark := site as Landmark
	_check(landmark.waypoint and landmark.title == "Sandworm",
		"territory exposes the enabled Sandworm waypoint")
	var expected: Vector3 = winner["direction"]
	_check(landmark.direction.normalized().angle_to(expected) \
			* _shape.radius < 2.0,
		"baked direction still matches the best deterministic desert")
	var boss := site.get_node_or_null("Sandworm")
	_check(boss != null and boss.get_script() == SANDWORM_SCRIPT,
		"territory contains the Sandworm boss scene")
	var metrics := site.call(&"survey_metrics") as Dictionary
	_check(is_equal_approx(
			float(metrics.get("arena_radius", 0.0)), ENCOUNTER_RADIUS),
		"territory records the expanded 1.6 km hunting radius")
	var packed := load(BOSS_PATH) as PackedScene
	_check(packed != null, "Sandworm boss scene loads")


func _tangent_east(up: Vector3) -> Vector3:
	var hint := Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT
	return up.cross(hint).normalized()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("sandworm_site: PASS  " + message)
	else:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	push_error("sandworm_site: FAIL  " + message)
