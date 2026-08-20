@tool
extends Landmark

## The encounter uses PlanetShape's authored south-pole volcano directly. Its
## centre is deterministic, and the boss script measures the moving trial ring
## against the same analytical caldera radius that built terrain and lava.

const SITE_DIRECTION := Vector3.DOWN


func _init() -> void:
	direction = SITE_DIRECTION
	facing = 0.0
	clearance = 18.0
	title = "Volcanoronomous"
	tint = Color("ff3b16")
	waypoint = true
	show_beyond = 0.0
	aimed_beyond = 0.0
	hide_beyond = 0.0


func survey_metrics() -> Dictionary:
	return {
		"volcano_radius": 1450.0,
		"cone_radius": 980.0,
		"caldera_radius": 190.0,
		"trial_inner_radius": 142.0,
		"trial_outer_radius": 252.0,
		"arena_radius": 900.0,
	}
