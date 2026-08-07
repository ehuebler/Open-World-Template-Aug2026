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
# Arid country, in the order a cliff face stacks them. Sandstone reads as bands
# because it was laid down as bands, so these are a *sequence* and not a palette
# to pick from: [method _strata] walks them by altitude, which is what puts the
# same courses at the same height on every butte in sight of each other and is
# most of why the result looks deposited rather than noisy.
## Darker than sandstone looks in a photograph, and deliberately. The scene runs
## about 1.4 of light through a surface before ACES tone maps it, so a colour
## written at the value the rock reads at comes out washed pink — which is what
## the first pass at this did across a whole hemisphere. Judge these under
## `dev/_planet_test.tscn -- --tour` and nowhere else, the same rule the city
## road tones are held to.
const MESA_MAROON := Color(0.26, 0.10, 0.09)
const MESA_RED := Color(0.45, 0.16, 0.09)
const MESA_ORANGE := Color(0.62, 0.29, 0.11)
const MESA_CREAM := Color(0.70, 0.57, 0.36)
## Dust on anything flat enough to hold it. Bands are a cliff feature — a bench
## top is covered in its own debris — so the flats fade to this and only the
## risers carry the sequence above.
const DESERT_FLOOR := Color(0.56, 0.38, 0.22)
# A geyser basin: sinter white, the bacterial mats that ring a hot pool, and the
# pool itself. Placed on the lake field rather than a field of their own, so a
# basin sits exactly where an arid region would otherwise have had standing water.
const SINTER := Color(0.91, 0.89, 0.83)
const MAT_ORANGE := Color(0.88, 0.51, 0.16)
const POOL_BLUE := Color(0.13, 0.58, 0.70)
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

@export_group("Arid country")
## Share of the land that is desert. The whole look below hangs off this one
## number: at 0 the planet is the green one it was, at 1 there is no grass left
## anywhere. It is approximate rather than solved the way [member sea_fraction]
## is, because nothing downstream depends on the exact figure — no shoreline has
## to come out in the right place — so a threshold on the raw field is enough.
@export_range(0.0, 1.0) var aridity := 0.66
## Distance between deserts. Deliberately smaller than the continents so that a
## single landmass carries both, and a green valley is something you fly out of
## the red country to reach rather than a different continent.
@export var arid_wavelength := 4600.0

## Height of one bench, in metres.
##
## This is the number that turns hills into mesas, and the most powerful one in
## the file. The ground is quantised onto multiples of it, so a slope that used
## to run smoothly uphill becomes a staircase of flat tops and steep risers —
## which is what Monument Valley is, geologically and visually: level courses of
## rock, each eroding back at its own rate.
@export var terrace_height := 32.0
## Share of each bench spent climbing rather than flat. Small is dramatic: at
## 0.2 a fifth of the rise is cliff and four fifths is tableland. Past about 0.5
## it stops reading as terracing at all and is just a slightly lumpy hill.
@export_range(0.02, 0.9) var terrace_riser := 0.2
## The sample spacing at which benches stop being drawn, in metres. Cliffs are
## the one thing here that genuinely cannot survive a coarse mesh — a riser is
## near-vertical and a chunk stepping over it aliases into a sawtooth — so they
## fade like every other fine feature. Set generously: the fade is what a distant
## mesa loses, and losing it looks like a smooth hill rather than like an error.
@export var terrace_span := 120.0

## Extra depth of a slot canyon over an ordinary river, in metres.
##
## Cut from the same noise field the rivers use and therefore free, which is also
## why it is right: a canyon is what a river does to arid ground given time, so
## the two belong on the same lines. It is applied above the waterline only, so a
## canyon is a dry gorge and its lowland reaches are still the river they were.
@export var canyon_depth := 120.0
## Half-width of the slot, in noise units. Far narrower than [member river_width]
## — the point of a slot canyon is that it is a crack you could jump across at
## the top and a hundred metres deep.
@export_range(0.0, 0.05) var canyon_width := 0.0035

## Thickness of one colour course, in metres.
##
## **Must not divide [member terrace_height] evenly**, and that is not a nicety.
## Terracing quantises the ground onto multiples of the bench height, so if the
## courses shared a period with it every bench top in the world would land on the
## same colour and the banding would vanish everywhere except the risers — which
## is exactly what the first attempt did, and it came out a uniform salmon. Left
## incommensurate, successive benches land at different points in the sequence and
## a staircase of tablelands climbs through the whole palette.
@export var stratum_height := 11.5

## Height of a hoodoo above the bench it stands on, in metres.
##
## Spires stand on the lip of a riser, which is where they form: a bench erodes
## back and leaves columns of the harder course behind it. They are the finest
## thing on the planet and the first to fade, so they are only ever seen from
## close to — which is the honest treatment, since at 1.5 m between vertices a
## spire is four vertices across and would read as speckle at any distance.
@export var hoodoo_height := 17.0
## Distance between spires, in metres.
@export var hoodoo_wavelength := 21.0

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

## A cosine no unit dot product can reach, which is how a town that is switched
## off keeps its row in the tables below without ever matching.
const UNREACHABLE_CAP := 2.0

## Where a feature is fully resolved, as a fraction of its own width. See
## [method _resolves], which is this rule written out.
const RESOLVE_FLOOR := 0.33

## [member cities]' `near` test, flattened: the cap axis and the cosine to beat,
## one row per town in the same order. See `prepare`.
var _town_up: PackedVector3Array = []
var _town_cap: PackedFloat32Array = []

## The native height field. Built in [method prepare] and read-only afterwards,
## which is what makes it safe on the mesh worker threads.
##
## Typed, and that is a performance requirement rather than tidiness. Held as an
## [Object] the call is resolved by name against [ClassDB] every time, which
## takes a global read lock — four build threads asking a few thousand times each
## per chunk turned a sample that had got cheaper into one that was twenty times
## dearer, and it reads as the whole terrain pipeline stalling rather than as a
## slow function. Typed, GDScript binds the method once and calls it directly.
var _field: PlanetField

## Where the arid field is cut to leave [member aridity] of the land desert.
var _arid_edge := 0.0
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
	# The arithmetic lives in the native field; this resource owns the numbers,
	# the towns and the API. See AGENTS.md for why the split is here and not
	# somewhere more convenient — briefly, everything above this line is data a
	# designer edits and everything below it is a few thousand samples per chunk.
	_field = PlanetField.new()
	_field.configure(native_settings(self))
	# Simplex clusters around zero rather than spreading evenly, so the useful
	# half of this range is the middle: the ends are asking for a threshold the
	# field almost never crosses, which is why it stops short of +-1.
	_arid_edge = lerpf(-0.5, 0.5, 1.0 - aridity)
	_sea_bias = float(_field.solve_sea_bias(SURVEY_SAMPLES, sea_fraction))
	_pole = frost_axis.normalized() if frost_axis.length_squared() > 0.0 else Vector3.UP
	_frost_edge = 1.0 - 2.0 * clampf(frost_area + frost_blend * 0.5, 0.0, 1.0)
	_frost_full = 1.0 - 2.0 * clampf(frost_area - frost_blend * 0.5, 0.0, 1.0)
	if not settled:
		cities.clear()
	elif cities.is_empty():
		cities.assign(Settlements.plans())
	for town: CityPlan in cities:
		town.prepare(radius)
	# `near()` is two comparisons and a dot product, and calling it costs several
	# times what it does: at two towns the test was 0.82 µs of a 6.7 µs sample,
	# 12% of every height on the planet spent on cross-resource call overhead
	# rather than on arithmetic. Cached flat so the hot paths can ask inline.
	#
	# One row per town whether or not it is switched on, so an index into these
	# is an index into `cities`: a town that can never answer yes is given a cap
	# no dot product can reach rather than being left out, because dropping it
	# would silently shift every later town onto the wrong plan.
	_town_up.clear()
	_town_cap.clear()
	for town: CityPlan in cities:
		var bounds := town.near_bounds()
		var live := bounds != Vector4.ZERO
		_town_up.append(Vector3(bounds.x, bounds.y, bounds.z) if live else Vector3.UP)
		_town_cap.append(bounds.w if live else UNREACHABLE_CAP)
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
	var height: float = _field.elevation(direction, spacing)
	for index in _town_up.size():
		if direction.dot(_town_up[index]) >= _town_cap[index]:
			return cities[index].elevation(direction, height)
	return height


## The parts an elevation was made of: what the water is, how rough the ground is,
## how high it would have been dry. Surveys need this to tell a river from a lake,
## which cannot be done from the finished height alone. Built by the native field
## from the same helpers as [method elevation], so the two cannot drift apart.
func sample(direction: Vector3) -> Dictionary:

	var parts: Dictionary = _field.sample(direction)
	for index in _town_up.size():
		if direction.dot(_town_up[index]) >= _town_cap[index]:
			parts["elevation"] = cities[index].elevation(direction, parts["elevation"])
			break
	return parts


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


## Whether a patch of ground this wide, centred here, could touch a town.
##
## Conservative on purpose: it is the test that decides whether a chunk may be
## built by the native field, which knows nothing about towns, and a false
## negative would build a pad as though the hills under it were still there.
## The chunk's own width is turned into an angle and taken straight off the cap's
## cosine, which over-estimates the reach — a cosine never falls faster than its
## angle — and so can only ever err toward the slower path.
func overlaps_town(centre: Vector3, arc: float) -> bool:
	if _town_up.is_empty():
		return false
	var direction := centre.normalized()
	var margin := arc / maxf(radius, 1.0)
	for index in _town_up.size():
		if direction.dot(_town_up[index]) >= _town_cap[index] - margin:
			return true
	return false


## One chunk's mesh, built in the native field. See [method Planet._build_natively].
func build_patch(face_origin: Vector3, face_u: Vector3, face_v: Vector3,
		offset: Vector2, size: float, resolution: int, spacing: float,
		skirt: float, chunk_origin: Vector3, want_collision: bool) -> Dictionary:
	return _field.build_patch(face_origin, face_u, face_v, offset, size,
		resolution, spacing, skirt, chunk_origin, want_collision)


## The biome colour for a point, with how wet it is in the alpha channel.
##
## Alpha is the one signal the surface shader cannot work out for itself: a chunk
## carries no elevation, and water has to be shaded as a smooth surface rather
## than as blue ground. 0 is dry, [constant SHORE_WETNESS] is the waterline, 1 is
## open ocean.
func color_at(direction: Vector3, height: float, normal: Vector3) -> Color:
	var ground: Color = _field.color_at(direction, height, normal)
	# Water is not zoned. The town cap is a disc on the sphere and the Landing's
	# reaches the sea, so a pad's concrete would otherwise be mixed into the
	# harbour — which is what happened for as long as this loop ran over every
	# colour rather than over the dry ones. Height, not alpha, decides: the
	# alpha channel is wetness and the shore is wet without being sea.
	if height <= 0.0:
		return ground
	for index in _town_up.size():
		if direction.dot(_town_up[index]) >= _town_cap[index]:
			return cities[index].tint(direction, ground)
	return ground


## Every tuning number the native field needs, by the name it has here.
##
## A dictionary rather than a setter per field because the alternative is fifty
## of them that all have to be kept in step with the exports above by hand, and
## a name missed is a number silently left at the C++ side's own default —
## which produces a plausible planet that is not this one. Keyed off the export
## list so adding a number here is the only edit a new tuning knob needs.
static func native_settings(shape: PlanetShape) -> Dictionary:
	var settings := {}
	for entry in shape.get_property_list():
		if int(entry["usage"]) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var named: String = entry["name"]
		var value: Variant = shape.get(named)
		if value is float or value is int or value is Vector3:
			settings[named] = value
	# The constants go over too, so this file stays the one place the planet's
	# palette and thresholds are written down. They could be literals on the
	# other side — they were, for one version — but a colour is the kind of thing
	# somebody edits without ever opening the C++, and a palette that exists twice
	# is a palette that will disagree.
	settings["CONTINENT_SPAN"] = CONTINENT_SPAN
	settings["RESOLVE_FLOOR"] = RESOLVE_FLOOR
	settings["SHORE_WETNESS"] = SHORE_WETNESS
	settings["ICE_TOP"] = ICE_TOP
	settings["SEA_ICE_WETNESS"] = SEA_ICE_WETNESS
	settings["palette"] = {
		"DEEP_WATER": DEEP_WATER, "SHALLOW_WATER": SHALLOW_WATER,
		"SHORE": SHORE, "GRASS": GRASS, "UPLAND": UPLAND, "ROCK": ROCK,
		"SNOW": SNOW, "ICE": ICE, "MESA_MAROON": MESA_MAROON,
		"MESA_RED": MESA_RED, "MESA_ORANGE": MESA_ORANGE,
		"MESA_CREAM": MESA_CREAM, "DESERT_FLOOR": DESERT_FLOOR,
	}
	return settings


## One of [param count] directions spread evenly over the sphere, so a survey
## does not over-sample the poles the way a lat/long grid would.
static func even_direction(index: int, count: int) -> Vector3:
	var y := 1.0 - 2.0 * (float(index) + 0.5) / float(count)
	var ring := sqrt(maxf(0.0, 1.0 - y * y))
	var angle := PI * (3.0 - sqrt(5.0)) * float(index)
	return Vector3(cos(angle) * ring, y, sin(angle) * ring)
