@tool
class_name Settlements
extends RefCounted

## Every town on the planet, in one list.
##
## This exists so that "how many cities are there" has one answer. [PlanetShape]
## needs all of their pads to build the height field; a [CityBuilder] needs one of
## them to build streets on; the harness wants to walk the lot. Without a list in the
## middle, each of those grows its own idea of what the planet contains, and the way
## that fails is a city whose roads are built on ground the terrain never flattened.
##
## Adding a town is a layout script with [code]plan()[/code] and [code]network()[/code]
## on it — see [CityLayout] or [MeridianLayout] — a name here, and a [CityBuilder]
## in `game/world.tscn` pointed at that name.

const LANDING := &"landing"
const MERIDIAN := &"meridian"


## The names of the settlements, in no meaningful order.
static func sites() -> Array[StringName]:
	return [LANDING, MERIDIAN]


## A fresh, unprepared [CityPlan] per town. [PlanetShape] takes these, prepares them
## and keeps them; everything else should read that list rather than call this, so
## that there is one set of pads and not one per caller.
static func plans() -> Array[CityPlan]:
	var made: Array[CityPlan] = []
	for site: StringName in sites():
		made.append(plan(site))
	return made


static func plan(site: StringName) -> CityPlan:
	var made: CityPlan = null
	match site:
		LANDING:
			made = CityLayout.plan()
		MERIDIAN:
			made = MeridianLayout.plan()
		_:
			push_error("Settlements: no town called '%s'" % site)
			return CityPlan.new()
	made.site = site
	return made


## One town's streets, resolved into lines but not yet built.
static func network(site: StringName) -> RoadNetwork:
	match site:
		LANDING:
			return CityLayout.network()
		MERIDIAN:
			return MeridianLayout.network()
	push_error("Settlements: no town called '%s'" % site)
	return null


## Places inside a town worth a [Landmark], as map coordinates in its own frame.
##
## Empty for Vacationer's Landing, whose one sign is placed by hand in
## `game/world.tscn` along with the rest of the planet's landmarks. Meridian Flats
## carries its own instead, so that moving a quarter moves its waypoint with it
## rather than leaving a label hanging over the ground it used to be on.
static func waypoints(site: StringName) -> Array[Dictionary]:
	match site:
		MERIDIAN:
			return MeridianLayout.WAYPOINTS
	return [] as Array[Dictionary]
