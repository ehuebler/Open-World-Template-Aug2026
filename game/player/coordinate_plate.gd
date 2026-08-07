class_name CoordinatePlate
extends PanelContainer

## Where you are, in terms you can read out to somebody who is not here.
##
## A globe has no street to stand on and no world coordinate worth quoting — the
## origin is the planet's *centre*, eight kilometres underground, so a position
## vector is three large numbers that mean nothing on their own. So this reports
## a place the way a place on a globe is reported: latitude and longitude in the
## planet's own frame, height above sea level, and the nearest named thing.
##
## The last two lines are for reporting faults rather than for finding your way,
## which is what this exists for. [member Planet.statistics] knows the depth the
## ground under the viewer is drawn at and how many chunks near it have a
## collider, and those two numbers are what separates "the terrain looks wrong
## here" from "the terrain has not finished loading here" — a distinction no
## screenshot carries and the one most often needed to act on a report.
##
## The unit direction is the line to quote at a harness. Four decimals is 0.8 m
## on this planet, which is close enough to stand a camera on the same rock.

## Gap from the top and right edges of the screen, in pixels.
const MARGIN := 20.0
const LINE_SIZE := 14
## [constant PencilSurface.BLEED] of each of these is spent on the gap between
## the panel's edge and the drawn plate, so they read as 6 px less than they say.
const PAD_X := 20
const PAD_Y := 15
## Times a second the readout is rewritten. It is a number for a person to read,
## and one that changes every frame cannot be read at all — nor written down,
## which is the whole point of it. It is also what keeps
## [method Planet.statistics] off the frame: that call walks every drawn chunk.
const REFRESH_HZ := 6.0
## How far above and below the body the floor probe looks, in metres. Up enough
## to start clear of a body standing in a dip, down enough to find the seabed
## from the surface of shallow water.
const PROBE_UP := 3.0
const PROBE_DOWN := 30.0

## The body the readout is being taken for, excluded from the floor probe.
##
## Not optional, and setting the ray's mask does not do it: the player is on
## layer 1 like the terrain, so a probe cast from three metres up hit the top of
## the capsule it started inside and reported a floor 1.5 m *above* the feet. The
## one line on screen that says whether the ground you can see is solid was
## answering with the body standing on it — so it never once printed
## `NO COLLIDER`, and every real hole looked like a floor at a strange height.
var body: CollisionObject3D

var _lines: VBoxContainer
var _elapsed := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchored to the top right corner and grown leftward and downward from it,
	# so the plate stays the width of its own text instead of spanning the
	# screen. A preset would write offsets sized for a full rect.
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_END
	offset_right = -MARGIN
	offset_top = MARGIN
	theme = load("res://ui/themes/main_theme.tres") as Theme
	PencilSurface.add_to(self, PencilSurface.Style.HUD)

	var padding := MarginContainer.new()
	padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
	padding.add_theme_constant_override("margin_left", PAD_X)
	padding.add_theme_constant_override("margin_right", PAD_X)
	padding.add_theme_constant_override("margin_top", PAD_Y)
	padding.add_theme_constant_override("margin_bottom", PAD_Y)
	add_child(padding)

	_lines = VBoxContainer.new()
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines.add_theme_constant_override("separation", 4)
	padding.add_child(_lines)
	for row in 6:
		var label := Label.new()
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", LINE_SIZE)
		_lines.add_child(label)


## Rewrites the readout, at most [constant REFRESH_HZ] times a second.
func refresh(at: Vector3, planet: Planet, delta: float) -> void:
	_elapsed += delta
	if _elapsed < 1.0 / REFRESH_HZ:
		return
	_elapsed = 0.0
	if planet == null or planet.shape == null:
		_write(0, "no planet")
		return

	var local := planet.to_local(at)
	var direction := local.normalized()
	var stats := planet.statistics()
	# The spacing the ground under the viewer was actually built at, which is what
	# the player's own guard now samples at. Asking for unlimited detail instead
	# reports a terrain nothing in the game is standing on.
	var spacing := planet.spacing_underfoot()
	_write(0, _nearest_place(at))
	_write(1, "lat %s   lon %s" % [
		_degrees(rad_to_deg(asin(clampf(direction.y, -1.0, 1.0))), "N", "S"),
		_degrees(rad_to_deg(atan2(direction.x, direction.z)), "E", "W")])
	_write(2, "alt %d m   ground %d m" % [
		roundi(local.length() - planet.shape.radius),
		roundi(planet.shape.elevation(direction, spacing))])
	_write(3, "dir %.4f, %.4f, %.4f" % [direction.x, direction.y, direction.z])
	# A depth of -1 is nothing drawn over the viewer at all, which is not depth 0
	# and must not print as it: it is the one state in which the field the guard
	# is sampling belongs to no chunk on screen.
	var depth := int(stats["depth"])
	_write(4, "lod %s/%d   %d colliders%s" % [
		"-" if depth < 0 else str(depth), planet.max_depth, int(stats["bodies"]),
		# Only while it is happening. A queue that is draining is the normal
		# state on arrival and saying so every frame would train the eye to
		# ignore the line that matters when it is *not* draining.
		"   loading %d" % int(stats["floorless"]) if int(stats["floorless"]) > 0 else ""])
	_write(5, _floor_under(at, planet, direction, spacing))


## The two floors under the feet, and whether they agree.
##
## `field` is the height field, which is what the player's own ground guard is
## holding them up with and is always there. `mesh` is a real collider found by
## a real ray, and is the one that can be missing — when it is, the surface you
## can see is a surface you go through, and this line is the only thing on
## screen that says so. Reported apart rather than as a difference because the
## interesting reading is one of them being absent, not the two disagreeing.
func _floor_under(at: Vector3, planet: Planet, direction: Vector3,
		spacing: float) -> String:
	var up := planet.global_transform.basis * direction
	var field := at.distance_to(planet.global_position) \
		- planet.shape.radius - planet.shape.elevation(direction, spacing)
	var query := PhysicsRayQueryParameters3D.create(at + up * PROBE_UP, at - up * PROBE_DOWN)
	query.collision_mask = 1
	# The player's own capsule is not the floor, and it is on the same layer the
	# terrain is, so it has to be named rather than masked out.
	if body != null:
		query.exclude = [body.get_rid()]
	var hit := get_viewport().world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return "floor  NO COLLIDER   field %.1f m" % field
	return "floor  mesh %.1f m   field %.1f m" % [
		hit["position"].distance_to(at + up * PROBE_UP) - PROBE_UP, field]


## The planet's own frame, so the poles are where the ice is. Longitude runs from
## the planet's local +Z and counts east toward +X, which is a choice and not a
## convention — nothing else in the project measures one, so it only has to agree
## with itself.
func _degrees(value: float, positive: String, negative: String) -> String:
	return "%.2f %s" % [absf(value), positive if value >= 0.0 else negative]


func _nearest_place(at: Vector3) -> String:
	var closest: Landmark = null
	var nearest := INF
	for node in get_tree().get_nodes_in_group(Landmark.GROUP):
		var landmark := node as Landmark
		if landmark == null:
			continue
		var span := landmark.global_position.distance_to(at)
		if span < nearest:
			nearest = span
			closest = landmark
	if closest == null:
		return "nowhere named"
	return "%s  %s" % [closest.title, Landmark.distance_text(nearest)]


func _write(row: int, text: String) -> void:
	(_lines.get_child(row) as Label).text = text
