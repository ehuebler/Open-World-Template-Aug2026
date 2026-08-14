class_name MeepSite
extends RefCounted

## A colony's own flat map of the planet: metres east and north of wherever it was
## founded.
##
## Everything a settlement decides — which cells are walkable, where the boundary
## runs, which way a Meep is facing — is easier to think about on a plane than on
## a sphere, and cheaper: a grid index is two divisions, where the same question
## asked in three dimensions is a normalise and two dot products per cell per
## lookup. So the colony holds one of these and works in [Vector2] almost
## everywhere, converting back to a direction only to ask the terrain a question
## or to draw something.
##
## The projection is azimuthal equidistant, taken from [CityPlan], which is what
## makes those metres real: a hundred-metre claim is a hundred metres of ground in
## every direction rather than a hundred metres of tangent plane that has drifted
## from the surface by the time it gets there. This is deliberately not a
## [CityPlan] — that class also grades a pad into the height field and erases the
## rivers under it, and a Meep town is built on the ground as found.

## Unit direction from the planet's centre to the colony centre.
var centre := Vector3.UP
## Degrees the map is turned about [member centre]. Aligns a colony's north with
## the heading of whatever founded it, so a ship's own facing and the streets that
## grow off it agree.
var facing := 0.0
var planet_radius := 0.0
## How far out this map is meant to be trusted, in metres. Past it the projection
## is still correct but nothing has been measured, and [method near] says no.
var reach := 0.0

var up := Vector3.UP
var east := Vector3.RIGHT
var north := Vector3.FORWARD

## Cosine of the angle [member reach] subtends. One dot product is then the whole
## of "is this anywhere near that colony", which is what a planet covered in them
## needs to be able to ask cheaply.
var _cap := 1.0


func _init(direction: Vector3, radius: float, turn := 0.0, span := 0.0) -> void:
	planet_radius = maxf(radius, 1.0)
	centre = direction.normalized()
	if centre.length_squared() < 0.5:
		centre = Vector3.UP
	facing = turn
	reach = maxf(span, 0.0)
	up = centre
	# The same arbitrary tangent SurfaceAnchor picks, turned by the same facing, so
	# a colony founded at a ship's direction and heading lines up with the ship
	# instead of sitting across it.
	var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - up * hint.dot(up)).normalized()
	var rotation := Basis(up, deg_to_rad(facing))
	east = rotation * up.cross(forward)
	north = rotation * -forward
	_cap = cos(reach / planet_radius) if reach > 0.0 else -1.0


## Whether a direction is close enough to this colony for any of the rest of this
## to matter.
func near(direction: Vector3) -> bool:
	return direction.dot(up) >= _cap


## Metres east and north of the colony centre.
func to_local(direction: Vector3) -> Vector2:
	var along := direction.dot(up)
	var tangent := direction - up * along
	var out := tangent.length()
	if out < 1e-9:
		return Vector2.ZERO
	tangent /= out
	var arc := atan2(out, along) * planet_radius
	return Vector2(tangent.dot(east), tangent.dot(north)) * arc


## The inverse: a unit direction from the planet's centre for a point on the map.
func direction_at(local: Vector2) -> Vector3:
	var metres := local.length()
	if metres < 1e-6:
		return up
	var arc := metres / planet_radius
	var tangent := (east * local.x + north * local.y) / metres
	return up * cos(arc) + tangent * sin(arc)


## A point on the map at a given height above sea level, in planet-local space —
## which is the space the planet's own children are drawn in.
func point_at(local: Vector2, height: float) -> Vector3:
	return direction_at(local) * (planet_radius + height)


## Where the ground is at a point on the map. Sampled rather than remembered, so
## callers that already hold a cached height should use [method point_at] with it
## instead of paying for the field again.
func ground_at(local: Vector2, shape: PlanetShape, spacing := 0.0) -> Vector3:
	var direction := direction_at(local)
	return direction * (planet_radius + shape.elevation(direction, spacing))
