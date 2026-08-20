class_name MeepDistantCities
extends MultiMeshInstance3D

## Every unwatched city on the planet, in one draw call.
##
## A [MeepCityLedger] has no nodes: that is the whole point of it. But a planet whose
## towns exist only as arithmetic reads as empty from any hilltop, and the settlements
## are the thing the player has been building. So the ledgers get a single planet-wide
## MultiMesh of massing boxes — one box per structure the town has actually placed, at
## that structure's own footprint, height and colour — which is what a city looks like
## from far enough away that its doors and streets are below a pixel anyway.
##
## Boxes fade out as they are approached rather than switching off, because the city
## they stand for becomes a real [MeepColony] at [constant
## MeepColonies.REIFY_RANGE] and the two must never be on screen together. The fade
## band sits inside that range, so by the time the buildings arrive their stand-ins
## have gone.
##
## Rebuilt one city per frame at most. Placing a box needs the ground under it, which
## is a height-field sample per structure, and a planet of fifty towns is a few
## thousand samples: fine spread over fifty frames, a stall in one.

## Metres from the camera at which a massing box has faded to nothing, and at which it
## is fully solid. Both inside [constant MeepColonies.REIFY_RANGE] so the handover
## from boxes to buildings has finished before the buildings exist.
const FADE_CLEAR := 480.0
const FADE_SOLID := 660.0
## Cities whose boxes are rebuilt per frame. See the note above about height samples.
const REBUILD_PER_FRAME := 1
## Shortest a massing box is drawn, so a hut is not lost in the ground at distance
## while its town's towers stand.
const MINIMUM_HEIGHT := 4.0


## One city's boxes, in planet-local space.
class CityMassing extends RefCounted:
	## Structures this was built from, so a town that has placed another since is
	## known to be out of date without comparing every box.
	var structures := 0
	var placements: Array[Transform3D] = []
	var colours := PackedColorArray()


var planet: Planet

## Site to that city's boxes.
var _massing: Dictionary = {}
## Site to the [MeepCityLedger] currently answering for it.
var _cities: Dictionary = {}
## Sites whose boxes have not been worked out yet, oldest first.
var _stale: Array[StringName] = []


func _init() -> void:
	name = "DistantCities"
	# Massing is a stand-in for a town, not a thing in the world: it must not cast
	# shadows onto ground the real town would have shadowed differently, and at this
	# distance a shadow costs a cascade update to draw nothing anybody can see.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var paint := StandardMaterial3D.new()
	paint.vertex_color_use_as_albedo = true
	paint.roughness = 0.85
	# Dither rather than alpha: fifty towns of overlapping boxes in the transparency
	# pipeline is a sorting problem, and at half a kilometre the dither pattern is
	# finer than a pixel.
	paint.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER
	paint.distance_fade_min_distance = FADE_CLEAR
	paint.distance_fade_max_distance = FADE_SOLID
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	box.material = paint
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_3D
	batch.use_colors = true
	batch.mesh = box
	multimesh = batch


## Which cities to draw. Called whenever the ledger set changes; cities already known
## keep their boxes, so a distill or a reify costs one city's work rather than the
## planet's.
func refresh(ledgers: Array[MeepCityLedger]) -> void:
	_cities.clear()
	for ledger in ledgers:
		_cities[ledger.site_id] = ledger
		var known := _massing.get(ledger.site_id) as CityMassing
		if known == null or known.structures != ledger.structures_placed():
			if not _stale.has(ledger.site_id):
				_stale.push_back(ledger.site_id)
	var gone := false
	for site_variant: Variant in _massing.keys():
		if _cities.has(site_variant):
			continue
		_massing.erase(site_variant)
		_stale.erase(site_variant)
		gone = true
	if gone:
		_write()


## Works through the backlog, so the height samples a new town needs cannot land in
## the same frame as another's.
func _process(_delta: float) -> void:
	if _stale.is_empty() or planet == null or planet.shape == null:
		return
	var began := Time.get_ticks_usec() if RuntimeTelemetry.deep_enabled() else 0
	_rebuild_some()
	if began > 0:
		RuntimeTelemetry.record_process_step(
			&"meeps", &"distant_massing", Time.get_ticks_usec() - began)


func _rebuild_some() -> void:
	var built := 0
	while built < REBUILD_PER_FRAME and not _stale.is_empty():
		var site: StringName = _stale.pop_front()
		var ledger := _cities.get(site) as MeepCityLedger
		if ledger == null:
			continue
		_massing[site] = _mass(ledger)
		built += 1
	if built > 0:
		_write()


func _mass(ledger: MeepCityLedger) -> CityMassing:
	var massing := CityMassing.new()
	massing.structures = ledger.structures_placed()
	var site := MeepSite.new(ledger.direction, planet.shape.radius,
		ledger.facing, ledger.claim_radius)
	var index := 0
	while index + 2 < ledger.structures.size():
		var plan := MeepStructures.plan_of(ledger.structures[index])
		var local := _centre_of(plan, Vector2i(
			ledger.structures[index + 1], ledger.structures[index + 2]))
		index += 3
		var up := site.direction_at(local)
		var ground := planet.shape.elevation(up)
		var tall := maxf(maxf(plan.floor_height * float(plan.floors),
			plan.size.y), MINIMUM_HEIGHT)
		var east := (site.east - up * site.east.dot(up)).normalized()
		# Scaled by scaling the axes rather than through Basis.scaled, so that the
		# box's own local axes are the ones being stretched and the footprint cannot
		# come out turned on its side.
		massing.placements.push_back(Transform3D(
			Basis(east * plan.size.x, up * tall,
				east.cross(up) * plan.size.z),
			site.point_at(local, ground + tall * 0.5)))
		massing.colours.push_back(plan.colour)
	return massing


## The same footprint centre [method MeepStructures._centre_of] works out, from the
## grid's constants rather than from a grid: a ledger city has none, and the numbers
## are what make a corner mean a place.
func _centre_of(plan: MeepStructures.Plan, corner: Vector2i) -> Vector2:
	var half := float(MeepGrid.CELLS) * MeepGrid.CELL * 0.5
	return Vector2(
		(float(corner.x) + 0.5) * MeepGrid.CELL - half,
		(float(corner.y) + 0.5) * MeepGrid.CELL - half
	) + Vector2(plan.span - Vector2i.ONE) * MeepGrid.CELL * 0.5


## Lays every known city's boxes into the one buffer.
func _write() -> void:
	var total := 0
	for entry: Variant in _massing.values():
		total += (entry as CityMassing).placements.size()
	multimesh.instance_count = total
	multimesh.visible_instance_count = total
	if total == 0:
		return
	var slot := 0
	for entry: Variant in _massing.values():
		var massing := entry as CityMassing
		for box in massing.placements.size():
			multimesh.set_instance_transform(slot, massing.placements[box])
			multimesh.set_instance_color(slot, massing.colours[box])
			slot += 1
