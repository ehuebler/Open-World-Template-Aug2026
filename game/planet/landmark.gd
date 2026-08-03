@tool
class_name Landmark
extends SurfaceAnchor

## A place on the planet worth naming, and the anchor whatever stands there is
## parented to.
##
## An eight kilometre sphere is big enough to lose a city on. From orbit
## Vacationer's Landing is a grey smudge a few pixels across, and from the far
## side of the planet it is not there at all — so the thing that makes it
## findable is a name floating over it, which is what [WaypointLayer] draws for
## every landmark in the [code]landmarks[/code] group.
##
## It is a [SurfaceAnchor] rather than a bare marker so it stands on the ground
## the same way a prop does, and so the buildings that eventually go up in the
## city can hang off it and inherit its place and its heading.

const GROUP := &"landmarks"

## What the waypoint calls this place.
@export var title := "Landmark"

## The colour its name is written in. A palette token or a mix of two of them,
## so the set of waypoints stays in the UI's family rather than becoming a
## rainbow of arbitrary hues; the ink outline behind the type is what makes it
## legible, so this is free to carry meaning instead of contrast.
@export var tint := Color("f7b32b")

## Metres away before the marker appears. Close up the place speaks for itself
## and a name over it is just something in the way of it.
@export var show_beyond := 1600.0

## The same cutoff for a place under the crosshair. Looking straight at
## somewhere is the strongest possible statement that you have found it, so the
## name gets out of the way sooner — which is what keeps the view clear on the
## approach, when the marker is both largest and least needed.
##
## Has to stay well under [member hide_beyond] or there is no band left to draw
## in: the two cutoffs close on each other, and an aimed marker that only exists
## across a few hundred metres of approach never fades in far enough to read.
@export var aimed_beyond := 2600.0

## Metres away past which the marker stops being drawn.
##
## The spawn markers hang 9 km over the ground, and from up there the whole
## planet is in frame — every name on it at once, over a surface too small to
## put any of them on. So the default is half that descent: nothing is named
## from orbit, and the names arrive at about the point the ground stops being a
## map and starts being a place. Raise it for somewhere that should be visible
## across a continent, and lower it for a marker on something you have to be in
## the same district to care about.
##
## Zero switches the far cutoff off entirely, which is a marker that is drawn
## from anywhere it is not hidden by the planet itself.
@export var hide_beyond := 4500.0


func _ready() -> void:
	add_to_group(GROUP)
	super()


## The distance as a waypoint should say it: metres under a kilometre, and
## kilometres to one decimal above, because "1400 m" reads as a number and
## "1.4 km" reads as a journey.
static func distance_text(metres: float) -> String:
	if metres < 1000.0:
		return "%d m" % roundi(metres)
	return "%.1f km" % (metres / 1000.0)
