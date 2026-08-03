@tool
class_name SurfaceAnchor
extends Node3D

## Stands whatever is parented to it on the planet's ground.
##
## Props cannot be placed by hand on a procedural sphere. The ground is 8 km from
## the origin in a direction nobody wants to type, its height is not known until
## the terrain is asked for it, and "upright" there is not [constant Vector3.UP]
## but the direction out from the centre. This takes a direction and does all
## three: height from the same band-limited field the chunk meshes are built
## from, local up radial, and a yaw for aiming a door or a work face.
##
## Parent it to the [Planet] so it inherits whatever transform the planet has,
## and parent the prop to it. A prop whose origin sits at its base — which is the
## convention the Blender assets follow — then needs no offset of its own.
##
## In the editor it is dragged rather than typed: move it with the gizmo and it
## drops back onto the ground under wherever it was let go, and turn it with the
## rotate gizmo and it keeps the heading while staying flat. Duplicating a placed
## one and dragging the copy is how a row of houses or a street gets laid out.

## Direction from the planet's centre. Normalised on use, so it can be typed
## roughly in the inspector rather than having to be a unit vector.
@export var direction := Vector3.UP:
	set(value):
		direction = value
		if is_inside_tree() and not _placing:
			place()

## Degrees about the local up.
@export_range(-180.0, 180.0) var facing := 0.0:
	set(value):
		facing = value
		if is_inside_tree() and not _placing:
			place()

## Metres above the ground, for anything whose origin is not at its base.
@export var clearance := 0.0:
	set(value):
		clearance = value
		if is_inside_tree() and not _placing:
			place()

## The planet to stand on. Left empty it walks up to the nearest [Planet]
## ancestor, which is where one of these belongs anyway.
@export var planet: Planet

## Guards the round trip: [method place] writes the transform, writing the
## transform notifies, and the notification would place again forever.
var _placing := false


func _ready() -> void:
	# Dragging is only a thing in the editor, and at runtime this would fire on
	# every move of a moving planet for no gain.
	set_notify_transform(Engine.is_editor_hint())
	place()


## The gizmo has been used. Whatever it did, the answer is the same: take the
## direction from where the node was left and the heading from how it was turned,
## then put both back on the ground.
func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSFORM_CHANGED or _placing or not Engine.is_editor_hint():
		return
	# Read in the planet's frame, which is the frame `place` solves in; the gizmo
	# leaves the node wherever it was dropped in the parent's.
	var host := planet_host()
	if host == null:
		return
	var here := host.to_local(global_position)
	# Below the centre of the planet there is no direction to read.
	if here.length_squared() < 1.0:
		return
	var up := here.normalized()
	var turned := host.to_local(global_position - global_basis.z) - here
	turned -= up * turned.dot(up)
	_placing = true
	if turned.length_squared() > 0.000001:
		# Measured against the same arbitrary tangent `place` will rebuild from,
		# so the prop keeps the heading it looks like it has rather than spinning
		# as it is dragged across the sphere.
		facing = rad_to_deg((-_upright(up).z).signed_angle_to(turned.normalized(), up))
	direction = up
	_placing = false
	place()


## Recomputes the transform. Runs before [method Planet._ready] does, because
## Godot readies children first — which is safe only because [method
## PlanetShape.prepare] is guarded and the second call is a no-op.
func place() -> void:
	var host := planet_host()
	if host == null or host.shape == null:
		push_warning("SurfaceAnchor '%s' has no planet to stand on" % name)
		return
	var shape := host.shape
	shape.prepare()
	var up := direction.normalized()
	if up.length_squared() < 0.5:
		up = Vector3.UP
	var was := _placing
	_placing = true
	var stood := Transform3D(
		# About the local up, not the world's. The two only agree at the north pole,
		# and anywhere else spinning about the wrong one tips the prop off the ground.
		Basis(up, deg_to_rad(facing)) * _upright(up),
		up * (shape.radius + shape.elevation(up, host.finest_spacing()) + clearance))
	# Solved in the planet's frame and then written in the parent's. Hung directly off
	# the planet the two are the same and this is an identity, but an anchor under
	# something that is itself standing on the ground — a [CityBuilder] sits at its own
	# town — would otherwise take that 8 km a second time and end up in orbit.
	var above := get_parent_node_3d()
	if above != null and above != host:
		stood = above.global_transform.affine_inverse() * host.global_transform * stood
	transform = stood
	_placing = was


## The planet this is standing on: the one it was given, or the nearest [Planet]
## ancestor. Public because anything that wants to ask the world a question about
## where this anchor is — how far, whether it can be seen from here — needs the
## same planet the anchor placed itself against.
func planet_host() -> Planet:
	if planet != null:
		return planet
	var node := get_parent()
	while node != null:
		if node is Planet:
			return node as Planet
		node = node.get_parent()
	return null


## An orthonormal basis whose y is the given up. The tangent it picks for -Z is
## arbitrary — [member facing] is what actually aims the prop — but it has to be
## chosen off an axis the up is not already parallel to, or the cross product
## collapses at the poles.
func _upright(up: Vector3) -> Basis:
	var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
	var forward := (hint - up * hint.dot(up)).normalized()
	return Basis(up.cross(forward), up, forward)
