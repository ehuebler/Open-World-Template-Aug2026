@tool
class_name PlanetShape
extends Resource

## The planet's height field: the one function that turns a direction from the
## centre into an elevation, a surface normal and a colour.
##
## The mesh builder and the player both read the ground through this, so there is
## no second copy of the terrain to drift out of step. Everything here is a pure
## function of position and is called from mesh worker threads, so nothing may
## cache per-call state on the resource — call [method prepare] once on the main
## thread before any chunk is built.
##
## Elevations are metres relative to sea level, so negative is under water and the
## shoreline is exactly zero. Feature sizes are wavelengths in metres, which is
## the only unit that stays meaningful if the radius changes.
##
## Every read takes the [code]spacing[/code] it is being sampled at, and features
## too fine to survive that spacing are faded out instead of aliased. Without it a
## chunk sampling every 25 m steps straight over a 45 m river gorge that its finer
## neighbour resolves in full, and the two meet in a cliff tens of metres tall.

## Fibonacci-sphere samples used to find the shoreline.
const SURVEY_SAMPLES := 4096

## How far the continent field has to travel inland from the shoreline before the
## ground is as inland as it gets. The sea has its own, shorter span; see
## [member abyss_span] for why the two are not the same number.
const CONTINENT_SPAN := 0.55

# Biome colours at map strength. They are the whole surface a chunk carries, so
# they are chosen to be told apart from orbit; the surface shader adds the grain,
# the region hue and the light that turn them into ground up close.
const DEEP_WATER := Color(0.04, 0.20, 0.46)
const SHALLOW_WATER := Color(0.15, 0.66, 0.74)
const SHORE := Color(0.92, 0.83, 0.56)
const GRASS := Color(0.33, 0.66, 0.25)
const UPLAND := Color(0.19, 0.45, 0.27)
const ROCK := Color(0.46, 0.42, 0.42)
const SNOW := Color(0.95, 0.96, 1.00)
## Pack ice, which is not snow: ice is dense enough to swallow the warm end of
## the light and hand back the blue, and reading as a paler shade of the snow
## beside it is what made the arctic one flat white field with no coastline in it.
const ICE := Color(0.76, 0.90, 0.97)

## Alpha at the waterline. Vertex alpha carries how wet the ground is, and the
## shader reads anything above zero as water; starting the ramp here rather than
## at zero leaves a band of damp sand that a triangle spanning the shore can
## interpolate across.
const SHORE_WETNESS := 0.2

## Height the frozen sea is lifted to, in metres above sea level.
##
## Pack ice is not drawn as water at all: [method elevation] raises everything
## under the waterline inside the cap to exactly this, so the arctic ocean
## becomes a flat plain in the ordinary height field. Every system downstream
## then gets the ice for free and with no new concepts — the mesh draws it, the
## chunk colliders collide with it, the player's ground guard stands on it, and
## the sea's own disc is left underneath where the depth test hides it. Sea
## level itself is untouched, so [method PlanetWater.depth_at] still reports the
## water it always did and nobody swims through the floe.
##
## Freeboard, and not the centimetre a floe really has, because a chunk's
## triangles are chords and a chord cuts inside the sphere it spans. Between two
## vertices s apart the mesh dips about s^2 / 8R below the surface it describes —
## a hand's width at the finest spacing, four metres at five hundred — so a floe
## sitting at sea level spends most of its area underneath the sea drawn over it,
## and the water disc shows through in rings. Three metres buys every LOD anyone
## stands on. It does not buy the coarse ones seen from orbit, where the dip is
## tens of metres; that is why `vivid_water` fades the sea out inside the cap
## rather than relying on this alone.
const ICE_TOP := 3.0

## Wetness written under pack ice. Enough that `vivid_terrain` shades it with the
## smooth, specular treatment it gives water — which is what ice wants too — and
## far enough under the deep-water ramp that none of the blue comes with it.
const SEA_ICE_WETNESS := 0.3

@export var radius := 8000.0
## Named to avoid shadowing GDScript's own seed().
@export var noise_seed := 20260801

@export_group("Feature sizes, metres")
## Distance between continents. At the default radius the equator is ~50 km, so
## 8.2 km gives a handful of landmasses rather than a marbled mess.
@export var continent_wavelength := 8200.0
@export var mountain_wavelength := 1500.0
@export var hill_wavelength := 300.0
@export var detail_wavelength := 52.0
@export var river_wavelength := 2400.0
## Controls where the ground is rough and where it is plain, independently of
## how high it is. Without it every inland acre would be hills.
@export var roughness_wavelength := 3600.0
@export var lake_wavelength := 950.0

@export_group("Elevations, metres")
## Relief is kept to under a tenth of the radius on purpose. A 500 m mountain is a
## serious climb at 1.45 m tall, but much more than that on a planet this size and
## the silhouette stops reading as a sphere and starts reading as a potato.
##
## The sea bed is exempt from that budget, because the water surface is what the
## silhouette is made of out there and the floor is under it either way.
##
## Depth of the abyssal plain, which is deliberately deeper than the mountains are
## tall: an ocean floor within a few tens of metres of its own surface reads as a
## flooded field, and worse, as the water itself.
@export var ocean_depth := 480.0
## Depth of the shelf, the apron of shallows a coast wades out across before the
## floor falls away. This is the only depth most swimming ever happens in.
@export var shelf_depth := 22.0
## Where the shelf breaks and the slope to the abyss begins, as a share of the
## span from shoreline to open ocean. Small, because a shelf that is most of the
## ocean puts the whole sea back at the surface.
@export_range(0.02, 0.6) var shelf_break := 0.16
## How far the continent field has to fall past the shoreline before the sea bed
## is at full depth. Much shorter than the span a coast takes to reach full
## height, and that asymmetry is the point: an ocean is a basin with a slope
## round its edge, not a bowl. Measured against the same field, so this is
## directly comparable to [constant CONTINENT_SPAN] — at a third of it, half the
## sea bed lies past the slope instead of on the shelf.
@export_range(0.05, 1.0) var abyss_span := 0.32
## Relief on the sea bed itself. Faded in with depth, so it is dunes and trenches
## out in the dark and nothing at all where it could break the surface.
@export var seabed_relief := 34.0
@export var land_height := 260.0
@export var mountain_height := 300.0
@export var hill_height := 24.0
@export var detail_height := 2.4
@export var river_depth := 45.0
@export var lake_depth := 38.0

@export_group("Water")
## Share of the surface below sea level. The raw noise's own zero crossing drifts
## with the seed, so the shoreline is solved for at prepare() rather than assumed.
@export_range(0.0, 0.95) var sea_fraction := 0.44
## Half-width of the river channel in noise units. ~0.012 reads as a river a few
## tens of metres across at the default wavelength.
@export_range(0.0, 0.2) var river_width := 0.012
## Roughly how wide a river ends up on the ground. Only used to decide the mesh
## spacing at which rivers stop being resolvable and start being faded out.
@export var river_channel := 45.0
## Noise level above which a lowland flat sinks into a lake bed. Lower floods more.
@export_range(0.0, 1.0) var lake_threshold := 0.60

@export_group("Polar cap")
## How much of the planet's surface is arctic, as a share of its area.
##
## Stated as an area rather than as an angle because that is the only form the
## number means anything in — "18% of the planet" against "50 degrees from the
## pole" — and the two are one line apart: a cap of area f subtends
## cos(theta) = 1 - 2f, which is the form every query below actually uses.
@export_range(0.0, 0.5) var frost_area := 0.18
## Width of the cap's edge, in the same units. The ground is fully arctic inside
## `frost_area - frost_blend / 2` and untouched outside `frost_area +
## frost_blend / 2`. It wants to be wide enough that the pack ice runs out into
## open sea over a kilometre or two rather than ending in a wall.
@export_range(0.0, 0.3) var frost_blend := 0.06
## Which way is north, in planet-local space.
@export var frost_axis := Vector3.UP

@export_group("Settlements")
## Whether the planet has towns on it at all. Clear it for the untouched noise, which
## is what the planet export and anything measuring raw terrain wants.
@export var settled := true
## The towns, each replacing the terrain inside its own footprint. Left empty and
## [member settled], it is filled from [Settlements], so a bare shape in a harness
## describes the same planet the game does.
##
## A list rather than one city, and the cost of that is a dot product per town on both
## hot paths below. That is affordable while this is a handful of settlements and would
## not be at a hundred: past that the caps want sorting into a coarse grid over the
## sphere so a direction tests against its own neighbourhood instead of against
## everywhere.
@export var cities: Array[CityPlan] = []

var _continent: FastNoiseLite
var _mountain: FastNoiseLite
var _hills: FastNoiseLite
var _detail: FastNoiseLite
var _rivers: FastNoiseLite
var _roughness: FastNoiseLite
var _lakes: FastNoiseLite
var _sea_bias := 0.0
var _pole := Vector3.UP
## Cosines of the cap's outer and inner edges, in that order, so [method frost]
## is one dot product and one smoothstep on the hot path.
var _frost_edge := 0.0
var _frost_full := 0.0
var _built := false


## Builds the noise fields and solves for the shoreline. Must run on the main
## thread before any worker calls [method elevation].
func prepare() -> void:
	if _built:
		return
	_continent = _make_noise(continent_wavelength, 5, 0)
	_mountain = _make_noise(mountain_wavelength, 5, 101)
	_hills = _make_noise(hill_wavelength, 3, 202)
	_detail = _make_noise(detail_wavelength, 2, 303)
	_rivers = _make_noise(river_wavelength, 3, 404)
	_roughness = _make_noise(roughness_wavelength, 2, 505)
	_lakes = _make_noise(lake_wavelength, 3, 606)
	_sea_bias = _solve_sea_bias()
	_pole = frost_axis.normalized() if frost_axis.length_squared() > 0.0 else Vector3.UP
	_frost_edge = 1.0 - 2.0 * clampf(frost_area + frost_blend * 0.5, 0.0, 1.0)
	_frost_full = 1.0 - 2.0 * clampf(frost_area - frost_blend * 0.5, 0.0, 1.0)
	if not settled:
		cities.clear()
	elif cities.is_empty():
		cities.assign(Settlements.plans())
	for town: CityPlan in cities:
		town.prepare(radius)
	_built = true


## How arctic a direction is: 0 outside the polar cap, 1 inside it, and a ramp
## across the edge.
##
## Everything that changes at the pole is this one number — the white ground, the
## pack ice, the deeper cloud deck, the snow the player wades through — so the
## cap has exactly one boundary and nothing downstream can disagree about where
## it is. The shader side reads the same figures through `vivid_frost`, which
## `Planet` keeps fed from here.
##
## Deliberately takes no [code]spacing[/code]. The cap moves the ground, and
## ground may not fade with detail: a chunk that dropped the ice at coarse
## spacing would draw the sea bed the finer chunk beside it draws as a floe, and
## they would meet in a cliff four hundred metres tall. Same reason the city pad
## ignores spacing; see the note on [method elevation].
func frost(direction: Vector3) -> float:
	return smoothstep(_frost_edge, _frost_full, direction.dot(_pole))


## Cosine of the cap's outer edge, where frost reaches zero. For `Planet` to
## publish to the shaders; nothing else should need it.
func frost_outer() -> float:
	return _frost_edge


## Cosine of the cap's inner edge, where frost reaches one.
func frost_inner() -> float:
	return _frost_full


# --- The height field -------------------------------------------------------

## Metres above sea level along a unit direction from the planet's centre.
##
## [param spacing] is the distance between the samples being taken, so that a
## coarse mesh gets a smoothed version of the same terrain rather than an aliased
## one. Pass 0 for the true surface.
##
## This is the hot path — a few hundred thousand calls per chunk — so it returns a
## bare float and leaves the breakdown to [method sample].
##
## The city is the one feature that ignores [param spacing] entirely. Everything
## else is faded out once the samples are too far apart to hold it, but a pad
## that faded would leave a distant chunk drawing the hills the city was built
## over while the player's ground guard — which always samples at the finest
## spacing — held them on the flat.
func elevation(direction: Vector3, spacing := 0.0) -> float:
	var point := direction * radius
	var continent := _continent.get_noise_3dv(point) + _sea_bias
	var height := 0.0
	if continent <= 0.0:
		height = _sea_floor(point, continent, spacing)
	else:
		var inland := clampf(continent / CONTINENT_SPAN, 0.0, 1.0)
		var rough := _roughness_at(point)
		height = _relief(point, inland, rough, spacing)
		height -= _lake_cut(point, height, rough, spacing)
		height -= _river_cut(point, height, spacing)
	height = _freeze(direction, height)
	for town: CityPlan in cities:
		if town.near(direction):
			return town.elevation(direction, height)
	return height


## The sea, frozen over. Inside the cap anything under the waterline comes up to
## [constant ICE_TOP]; ground already above it is left exactly where it was, so
## the coast, the hills and the mountains of the arctic are the same landscape
## they would have been with the floe laid across the water between them.
##
## Blended by [method frost] rather than switched, which is what makes the edge
## read: through the band the ice thins toward the sea it came from, so the floe
## breaks up into open water over a kilometre or two instead of ending in a wall.
func _freeze(direction: Vector3, height: float) -> float:
	if height >= ICE_TOP:
		return height
	var chill := frost(direction)
	if chill <= 0.0:
		return height
	return lerpf(height, ICE_TOP, chill)


## The parts an elevation was made of: what the water is, how rough the ground is,
## how high it would have been dry. Surveys need this to tell a river from a lake,
## which cannot be done from the finished height alone. Built from the same
## helpers as [method elevation], so the two cannot drift apart.
func sample(direction: Vector3) -> Dictionary:
	var point := direction * radius
	var continent := _continent.get_noise_3dv(point) + _sea_bias
	if continent <= 0.0:
		return {"elevation": _freeze(direction, _sea_floor(point, continent, 0.0)),
			"dry": 0.0, "river": 0.0, "lake": 0.0, "rough": 0.0, "continent": continent}
	var inland := clampf(continent / CONTINENT_SPAN, 0.0, 1.0)
	var rough := _roughness_at(point)
	var dry := _relief(point, inland, rough, 0.0)
	var lake := _lake_cut(point, dry, rough, 0.0)
	var river := _river_cut(point, dry - lake, 0.0)
	var height := _freeze(direction, dry - lake - river)
	for town: CityPlan in cities:
		if town.near(direction):
			height = town.elevation(direction, height)
			break
	return {"elevation": height, "dry": dry, "river": river,
		"lake": lake, "rough": rough, "continent": continent}


## The point on the surface below a unit direction, in planet-local space.
func surface_point(direction: Vector3, spacing := 0.0) -> Vector3:
	return direction * (radius + elevation(direction, spacing))


## Surface normal from central differences of the height field.
##
## [param spacing] is both how far apart the samples are taken and which features
## the height field is allowed to include, so the normals describe the mesh being
## built rather than a finer one it does not have the triangles for.
func normal_at(direction: Vector3, spacing: float) -> Vector3:
	var up := direction.normalized()
	var tangent := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var bitangent := up.cross(tangent)
	var step := maxf(spacing, 0.05) / radius
	var along_u := surface_point((up + tangent * step).normalized(), spacing) \
		- surface_point((up - tangent * step).normalized(), spacing)
	var along_v := surface_point((up + bitangent * step).normalized(), spacing) \
		- surface_point((up - bitangent * step).normalized(), spacing)
	var normal := along_u.cross(along_v)
	if normal.length_squared() < 1e-12:
		return up
	normal = normal.normalized()
	return normal if normal.dot(up) > 0.0 else -normal


## The biome colour for a point, with how wet it is in the alpha channel.
##
## Alpha is the one signal the surface shader cannot work out for itself: a chunk
## carries no elevation, and water has to be shaded as a smooth surface rather
## than as blue ground. 0 is dry, [constant SHORE_WETNESS] is the waterline, 1 is
## open ocean.
func color_at(direction: Vector3, height: float, normal: Vector3) -> Color:
	if height <= 0.0:
		var depth := smoothstep(-1.0, -70.0, height)
		var water := DEEP_WATER.lerp(SHALLOW_WATER, 1.0 - depth)
		water.a = lerpf(SHORE_WETNESS, 1.0, depth)
		return water
	# The sand band is deliberately narrow. Coastal plains here run for kilometres
	# at only a few metres of altitude, so a wide band turns every one of them
	# into a desert.
	var ground := SHORE.lerp(GRASS, smoothstep(0.5, 7.0, height))
	ground = ground.lerp(UPLAND, smoothstep(25.0, 110.0, height))
	ground = ground.lerp(ROCK, smoothstep(150.0, 300.0, height))
	ground = ground.lerp(SNOW, smoothstep(330.0, 460.0, height))
	# Anything too steep to hold soil reads as bare rock whatever its altitude.
	var slope := 1.0 - clampf(normal.dot(direction.normalized()), 0.0, 1.0)
	ground = ground.lerp(ROCK, smoothstep(0.32, 0.62, slope))
	ground.a = 0.0
	ground = _whiten(direction, height, ground)
	for town: CityPlan in cities:
		if town.near(direction):
			return town.tint(direction, ground)
	return ground


## Snow over the arctic, and pack ice where the arctic is sea.
##
## The two are told apart by height alone, which they can be because
## [method _freeze] put the ice at exactly [constant ICE_TOP] and left everything
## else alone: ground sitting at the ice line was sea, ground above it was always
## ground. That saves recomputing the sea floor here purely to ask a question the
## height already answers.
##
## They differ in colour and in wetness, and the same height ramp carries both:
## [constant ICE] and [constant SEA_ICE_WETNESS] on the floe, so the surface shader
## gives it the smooth, mirror-ish treatment it gives water — which is what ice
## wants too — and [constant SNOW] bone dry and matte on the land above it.
func _whiten(direction: Vector3, height: float, ground: Color) -> Color:
	var chill := frost(direction)
	if chill <= 0.0:
		return ground
	var ashore := smoothstep(ICE_TOP, ICE_TOP + 1.5, height)
	var arctic := ICE.lerp(SNOW, ashore)
	arctic.a = SEA_ICE_WETNESS * (1.0 - ashore)
	return ground.lerp(arctic, chill)


# --- Layers -----------------------------------------------------------------

## The sea bed: an apron of shallows out to the shelf break, then a slope into an
## abyss. Not one curve from shore to deepest point, because a single smoothstep
## spends most of the ocean's width barely under water and the result is a blue
## surface sitting at sea level pretending to be the sea.
##
## It passes through exactly zero at the waterline, so the floor meets the land it
## was carved out of without a step, and it is strictly below zero everywhere else
## — the relief term is faded in with depth faster than it can grow, so no dune
## out there can surface as an island the shoreline solver never counted.
func _sea_floor(point: Vector3, continent: float, spacing: float) -> float:
	# 0 at the shoreline, 1 out where the ocean stops getting any more oceanic.
	var out := clampf(-continent / abyss_span, 0.0, 1.0)
	var depth := shelf_depth * smoothstep(0.0, shelf_break, out) \
		+ (ocean_depth - shelf_depth) * smoothstep(shelf_break, 1.0, out)
	# The same hill field the land above uses, so the two are one landscape with
	# a waterline drawn across it rather than two that meet at the coast.
	var relief := _hills.get_noise_3dv(point) * seabed_relief \
		* _resolves(hill_wavelength, spacing) \
		* smoothstep(0.0, seabed_relief * 2.0, depth)
	return relief - depth


## How much relief the ground is allowed here, independently of how high it is.
## This is what makes plains possible: without it, altitude would imply hills.
func _roughness_at(point: Vector3) -> float:
	return smoothstep(0.42, 0.86, _roughness.get_noise_3dv(point) * 0.5 + 0.5)


## Land height before any water is carved out of it.
func _relief(point: Vector3, inland: float, rough: float, spacing: float) -> float:
	# Coasts stay low and interiors climb, so a beach is a beach and not a cliff.
	var height := pow(inland, 1.4) * land_height
	# Everything the ground is made of is faded in over the first stretch inland.
	# The hill term does not start at zero — half its amplitude is a constant —
	# so without this the land begins at whatever the hill noise happens to read
	# on the waterline, and every shore in the world is a step of up to
	# hill_height with nowhere to wade in from.
	var ashore := smoothstep(0.0, 0.1, inland)
	# Ridged noise cubed leaves sparse sharp crests rather than a lumpy field.
	var ridge := 1.0 - absf(_mountain.get_noise_3dv(point))
	height += pow(ridge, 3.0) * mountain_height * rough \
		* smoothstep(0.05, 0.45, inland) * _resolves(mountain_wavelength, spacing)
	height += (_hills.get_noise_3dv(point) * 0.5 + 0.5) * hill_height \
		* (0.2 + 0.8 * rough) * ashore * _resolves(hill_wavelength, spacing)
	return height + _detail.get_noise_3dv(point) * detail_height * ashore \
		* _resolves(detail_wavelength, spacing)


## Rivers are the zero crossing of a noise field, which gives a network of
## meandering lines for the cost of one lookup. They are not solved from flow, so
## they run downhill only in the statistical sense; the altitude fade is what
## keeps them out of the summits, and only the lowland reaches cut deep enough to
## fall below sea level and read as water.
func _river_cut(point: Vector3, height: float, spacing: float) -> float:
	if height <= 0.0:
		return 0.0
	# A channel is far narrower than its wavelength, and it is the channel a
	# coarse mesh cannot resolve. Faded on its own width, not the noise's.
	var resolves := _resolves(river_channel * 2.0, spacing)
	if resolves <= 0.0:
		return 0.0
	var channel := 1.0 - absf(_rivers.get_noise_3dv(point))
	var across := smoothstep(1.0 - river_width, 1.0, channel)
	if across <= 0.0:
		return 0.0
	return river_depth * across * resolves * (1.0 - smoothstep(90.0, 380.0, height))


## Broad shallow basins on lowland flats. Where one takes the ground under sea
## level it fills, so lakes and ponds are a consequence of the terrain rather
## than objects placed on it.
func _lake_cut(point: Vector3, height: float, rough: float, spacing: float) -> float:
	var resolves := _resolves(lake_wavelength * 0.35, spacing)
	if resolves <= 0.0:
		return 0.0
	var level := _lakes.get_noise_3dv(point) * 0.5 + 0.5
	var pool := smoothstep(lake_threshold, lake_threshold + 0.14, level)
	if pool <= 0.0:
		return 0.0
	return lake_depth * pool * resolves * (1.0 - rough) \
		* (1.0 - smoothstep(70.0, 240.0, height))


## How much of a feature [param size] metres across survives being sampled every
## [param spacing] metres: all of it below a third of its size, none of it once
## the samples are as far apart as the feature is wide.
func _resolves(size: float, spacing: float) -> float:
	if spacing <= 0.0:
		return 1.0
	return smoothstep(size, size * 0.33, spacing)


# --- Setup ------------------------------------------------------------------

func _make_noise(wavelength: float, octaves: int, seed_offset: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = noise_seed + seed_offset
	noise.frequency = 1.0 / maxf(wavelength, 1.0)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	return noise


## Finds the offset that puts sea_fraction of the surface below zero, by sampling
## the continent field evenly over the sphere and reading off the quantile.
func _solve_sea_bias() -> float:
	var values := PackedFloat32Array()
	values.resize(SURVEY_SAMPLES)
	for index in SURVEY_SAMPLES:
		values[index] = _continent.get_noise_3dv(even_direction(index, SURVEY_SAMPLES) * radius)
	values.sort()
	return -values[clampi(int(SURVEY_SAMPLES * sea_fraction), 0, SURVEY_SAMPLES - 1)]


## One of [param count] directions spread evenly over the sphere, so a survey
## does not over-sample the poles the way a lat/long grid would.
static func even_direction(index: int, count: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(index) + 0.5) / float(count)
	var ring := sqrt(maxf(0.0, 1.0 - y * y))
	var angle := PI * (3.0 - sqrt(5.0)) * float(index)
	return Vector3(cos(angle) * ring, y, sin(angle) * ring)
