@tool
class_name CityPlan
extends Resource

## One city as the terrain sees it: a tangent frame on the sphere, a pad that
## replaces the height field inside its own footprint, and a zoning colour to tint
## the ground with.
##
## [PlanetShape] holds a list of these and asks each of them two questions per
## vertex, so everything here is a pure function of a direction and safe to call
## from the mesh worker threads — call [method prepare] once on the main thread
## first, the same contract the shape itself works under.
##
## Carries its own site, footprint, grade and districts rather than reading them
## off one city's table, which is what lets there be more than one town on the
## planet. [Settlements] is where the configured ones live; a bare
## [code]CityPlan.new()[/code] describes nowhere and [method near] is false
## everywhere, so a harness that wants untouched noise can simply not supply any.
##
## The pad has to live in the height field rather than be a mesh laid over it. That
## field is the single source of truth for the chunk meshes, the chunk colliders,
## [SurfaceAnchor] and the player's ground guard, and a plane floating above it
## would leave all four disagreeing about where the ground is.
##
## Note that unlike every other feature on the planet, the pad is [b]not[/b]
## band-limited by spacing. Coarse chunks fade fine detail out so they do not
## alias, but the pad is not detail: if it faded, a distant chunk would draw the
## hills the city was built over while the player's guard — which always samples at
## the finest spacing — held them on the flat. The rim is a couple of hundred metres
## wide, so the pad is resolvable at any spacing the planet ever uses anyway.

## Metres per pixel is the footprint's span over this. 256 across 3000 m is about
## 12 m, which is finer than the terrain's own vertex spacing anywhere the whole
## city is in view, and the roads carry the crisp edges regardless.
const ZONE_PIXELS := 256

# What a district's ground reads as from the air. Here rather than in any one city's
# table because two towns describing the same use in two slightly different greys is
# how a planet stops looking like one place.
#
# Deliberately muted: the surface shader runs these through a saturation of 1.35 and a
# region hue on top of that, so a colour picked to look right in the inspector arrives
# on screen as a paint pot. This is a city seen as a plan, and it has to sit under the
# roads rather than shout over them.
const GROUND := Color(0.46, 0.50, 0.40)
const SAND := Color(0.78, 0.71, 0.52)
const WHARF := Color(0.40, 0.43, 0.47)
const NIGHTLIFE := Color(0.48, 0.38, 0.46)
const CONCRETE := Color(0.47, 0.48, 0.52)
const STONE := Color(0.56, 0.53, 0.46)
const LAWN := Color(0.28, 0.48, 0.24)
const SUBURB := Color(0.52, 0.54, 0.42)
const SCRUB := Color(0.52, 0.50, 0.36)

## Which settlement this is, as [Settlements] names it. A [CityBuilder] finds its
## own ground by matching this against the list the shape prepared, because it has
## to build on the very [CityPlan] the height field used and not on an equal copy of
## it.
@export var site := &""
## For reports and for the harness to name a picture by.
@export var title := "City"
## Where the city stands, as a direction from the planet's centre.
@export var centre := Vector3.UP
## Degrees about the local up, in the same sense [SurfaceAnchor] uses, that turn the
## city's own +x to the local east.
@export var facing := 0.0
## Set false to get the untouched terrain back, which is what the planet export and
## any harness measuring raw noise wants.
@export var enabled := true

@export_group("Footprint")
## Half the flat footprint, and the band outside it spent blending back into the
## untouched terrain.
@export var core := 900.0
@export var rim := 260.0
## Corner rounding on the footprint. Square enough for a rectangular layout to use,
## round enough that the rim does not meet the terrain in four points.
@export var corner := 320.0
## How far out the pad can possibly reach, which is the cap [method near] tests
## against before doing any city work at all. The rounded footprint's diagonal runs
## to [member core] minus [member corner], root two, plus [member corner]; the rim
## and a little slack go on top of that. Zero means there is no city here.
@export var reach := 0.0

@export_group("Ground")
## The city's ground, as height above sea level against metres inland, which is the
## y of the city frame. Level across x either way.
##
## [b]One knot is a flat city[/b], which is the whole difference between a town
## built on a shelf that falls to the sea and one laid out on a plain. Several knots
## are interpolated smoothly, so the ground has no crease at any of them, and roads
## inherit the slope for free because every station asks for the height under it.
@export var grade: Array[Vector2] = []

@export_group("Zoning")
## Whatever no district claimed: the lots, verges and vacant ground the streets run
## between.
@export var ground_color := Color(0.46, 0.50, 0.40)
## Districts, as rounded boxes and discs in the city frame. See
## [method _district_distance] for the fields.
##
## The order is the order they are painted, so a later entry wins where two overlap
## — which is how a park's lawn cuts into a residential belt without either having
## to be described as a polygon with a bite out of it.
@export var districts: Array[Dictionary] = []
## Metres a district's colour takes to fade into its neighbour. Wide enough that the
## boundary does not alias on a raster sampled every 12 m, narrow enough to still
## read as a boundary from orbit.
@export var feather := 30.0

var _up := Vector3.UP
var _east := Vector3.RIGHT
var _north := Vector3.FORWARD
var _radius := 0.0
## Cosine of the angle subtended by [member reach]. One dot product against this is
## all the 99.9% of the planet that is not this city ever pays.
var _cap := 1.0
var _span := 0.0
var _zones: Image
var _built := false

# The grade unpacked into two flat arrays. The height field asks for the pad height
# several million times per chunk it builds over a city, and indexing a packed float
# array is a good deal cheaper per knot than reading a Vector2 out of a typed Array.
var _grade_y := PackedFloat32Array()
var _grade_height := PackedFloat32Array()
# core - corner, which is all the footprint test needs.
var _inner := 0.0


## Builds the tangent frame and bakes the zoning raster. Idempotent, and must run on
## the main thread before any worker touches the shape.
func prepare(planet_radius: float) -> void:
	if _built:
		return
	_radius = planet_radius
	_up = centre.normalized()
	# The same arbitrary tangent SurfaceAnchor picks, turned by the same facing, so a
	# landmark dropped at this direction and this facing lines up with the streets
	# instead of sitting across them.
	var hint := Vector3.FORWARD if absf(_up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - _up * hint.dot(_up)).normalized()
	var turn := Basis(_up, deg_to_rad(facing))
	_east = turn * _up.cross(forward)
	_north = turn * -forward
	_span = reach
	_cap = cos(reach / _radius) if reach > 0.0 else 1.0
	_inner = core - corner
	if grade.is_empty():
		_grade_y.append(0.0)
		_grade_height.append(0.0)
	for knot: Vector2 in grade:
		_grade_y.append(knot.x)
		_grade_height.append(knot.y)
	_bake_zones()
	_built = true


# --- Queries ----------------------------------------------------------------

## Whether a direction is close enough to this city for any of the rest of this to
## matter. One dot product, and it is the first thing both hot paths in
## [PlanetShape] do.
func near(direction: Vector3) -> bool:
	return enabled and _span > 0.0 and direction.dot(_up) >= _cap


## Metres east and inland from the pad centre.
##
## Azimuthal equidistant, so a road written as 1800 m long is 1800 m of ground. The
## obvious tangent-plane projection would stretch by 0.4% at the footprint's edge,
## which is four metres of drift between the layout and the map.
func to_local(direction: Vector3) -> Vector2:
	var along := direction.dot(_up)
	var tangent := direction - _up * along
	var reach_out := tangent.length()
	if reach_out < 1e-9:
		return Vector2.ZERO
	tangent /= reach_out
	var arc := atan2(reach_out, along) * _radius
	return Vector2(tangent.dot(_east), tangent.dot(_north)) * arc


## The inverse: a unit direction from the planet's centre for a point on the map.
func direction_at(local: Vector2) -> Vector3:
	var metres := local.length()
	if metres < 1e-6:
		return _up
	var arc := metres / _radius
	var tangent := (_east * local.x + _north * local.y) / metres
	return _up * cos(arc) + tangent * sin(arc)


## A point on the finished pad, in planet-local space.
func surface_at(local: Vector2, clearance := 0.0) -> Vector3:
	return direction_at(local) * (_radius + pad_height(local) + clearance)


## Height of the graded pad, interpolated smoothly between the [member grade] knots.
## Level across the city, so only the inland coordinate is read.
func pad_height(local: Vector2) -> float:
	var last := _grade_y.size() - 1
	if local.y <= _grade_y[0]:
		return _grade_height[0]
	if local.y >= _grade_y[last]:
		return _grade_height[last]
	for index in last:
		if local.y > _grade_y[index + 1]:
			continue
		return lerpf(_grade_height[index], _grade_height[index + 1],
			smoothstep(_grade_y[index], _grade_y[index + 1], local.y))
	return _grade_height[last]


## How much of the pad applies here: 1 across the footprint, easing to 0 over the
## rim. The footprint is a rounded box, so this is its signed distance fed through a
## smoothstep.
func weight(local: Vector2) -> float:
	var corner_x := absf(local.x) - _inner
	var corner_y := absf(local.y) - _inner
	var distance := Vector2(maxf(corner_x, 0.0), maxf(corner_y, 0.0)).length() \
		+ minf(maxf(corner_x, corner_y), 0.0) - corner
	if distance <= 0.0:
		return 1.0
	return 1.0 - smoothstep(0.0, rim, distance)


## The height field with the city in it. Takes whatever the terrain would have been
## and pulls it toward the pad.
##
## Inside the footprint this is the pad outright, which is also what erases any river
## or lake the noise had put through the middle of the city — they are cuts made
## before this runs and there is nothing left of them to see.
func elevation(direction: Vector3, natural: float) -> float:
	var local := to_local(direction)
	var mix := weight(local)
	if mix <= 0.0:
		return natural
	return lerpf(natural, pad_height(local), mix)


## The ground colour with the city's zoning over it, fading out across the rim the
## same way the pad's height does so the two edges coincide.
func tint(direction: Vector3, ground: Color) -> Color:
	var local := to_local(direction)
	var mix := weight(local)
	if mix <= 0.0:
		return ground
	var zoned := zone_color(local)
	zoned.a = ground.a
	return ground.lerp(zoned, mix)


## The zoning colour at a point, read from the baked raster.
func zone_color(local: Vector2) -> Color:
	if _zones == null:
		return ground_color
	var uv := (local / _span) * 0.5 + Vector2(0.5, 0.5)
	var pixel := Vector2i(
		clampi(int(uv.x * float(ZONE_PIXELS)), 0, ZONE_PIXELS - 1),
		clampi(int(uv.y * float(ZONE_PIXELS)), 0, ZONE_PIXELS - 1))
	return _zones.get_pixelv(pixel)


# --- Baking -----------------------------------------------------------------

## Paints the districts into one small image so the hot path is a texture read
## rather than a distance field evaluated against every district in the table.
##
## Walked per district over its own bounding box rather than per pixel over every
## district: the districts cover about twice the raster between them, so this is a
## few hundred thousand distance tests instead of several million.
func _bake_zones() -> void:
	if _span <= 0.0:
		return
	var pixels := PackedFloat32Array()
	pixels.resize(ZONE_PIXELS * ZONE_PIXELS * 4)
	var step := _span * 2.0 / float(ZONE_PIXELS)
	for shape: Dictionary in districts:
		var at: Vector2 = shape["at"]
		var size: Vector2 = shape["size"]
		# A disc carries its radius in x. A box is bounded by its half-diagonal,
		# which holds it at any turn; squaring that off costs a few empty pixels and
		# saves rotating the bounds.
		var half := (size.length() * 0.5 if String(shape["kind"]) == "box" else size.x) \
			+ feather
		var color: Color = shape["color"]
		var low := _to_pixel(at - Vector2(half, half))
		var high := _to_pixel(at + Vector2(half, half))
		for row in range(low.y, high.y + 1):
			for column in range(low.x, high.x + 1):
				var local := Vector2(
					(float(column) + 0.5) * step - _span,
					(float(row) + 0.5) * step - _span)
				var inside := smoothstep(feather, -feather,
					_district_distance(shape, local))
				if inside <= 0.0:
					continue
				var index := (row * ZONE_PIXELS + column) * 4
				pixels[index] = lerpf(pixels[index], color.r, inside)
				pixels[index + 1] = lerpf(pixels[index + 1], color.g, inside)
				pixels[index + 2] = lerpf(pixels[index + 2], color.b, inside)
				pixels[index + 3] = maxf(pixels[index + 3], inside)

	_zones = Image.create_empty(ZONE_PIXELS, ZONE_PIXELS, false, Image.FORMAT_RGBA8)
	for row in ZONE_PIXELS:
		for column in ZONE_PIXELS:
			var index := (row * ZONE_PIXELS + column) * 4
			var painted := pixels[index + 3]
			var color := Color(pixels[index], pixels[index + 1], pixels[index + 2])
			_zones.set_pixel(column, row, ground_color.lerp(color, painted))


## Signed distance to a district, negative inside.
##
## A district is [code]{"name", "kind", "at", "size", "turn", "round", "color"}[/code]:
## [code]kind[/code] is [code]box[/code] or [code]disc[/code], [code]at[/code] is its
## centre in the city frame, [code]size[/code] is a box's full extents or a disc's
## radius in x, [code]turn[/code] is degrees anticlockwise and [code]round[/code] the
## corner radius, both boxes only.
##
## Rounded boxes and discs are the only two shapes on offer on purpose: both are a
## handful of operations, and a raster this size cannot afford a polygon test per
## pixel.
func _district_distance(shape: Dictionary, local: Vector2) -> float:
	var size: Vector2 = shape["size"]
	var point: Vector2 = local - (shape["at"] as Vector2)
	if String(shape["kind"]) == "disc":
		return point.length() - size.x
	var turn: float = shape["turn"]
	if not is_zero_approx(turn):
		point = point.rotated(-deg_to_rad(turn))
	var radius: float = shape["round"]
	var box := Vector2(
		absf(point.x) - (size.x * 0.5 - radius),
		absf(point.y) - (size.y * 0.5 - radius))
	return Vector2(maxf(box.x, 0.0), maxf(box.y, 0.0)).length() \
		+ minf(maxf(box.x, box.y), 0.0) - radius


func _to_pixel(local: Vector2) -> Vector2i:
	var uv := (local / _span) * 0.5 + Vector2(0.5, 0.5)
	return Vector2i(
		clampi(int(uv.x * float(ZONE_PIXELS)), 0, ZONE_PIXELS - 1),
		clampi(int(uv.y * float(ZONE_PIXELS)), 0, ZONE_PIXELS - 1))
