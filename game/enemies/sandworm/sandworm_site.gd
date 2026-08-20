@tool
extends Landmark

## Named deterministic anchor for the Sandworm's open-desert arena. Its 185 m
## eruption core was surveyed from the live PlanetShape and the expanded 1.6 km
## hunting territory retains several kilometres of clearance from settlements,
## Bigfoot, and the south-pole volcano.

const SITE_DIRECTION := Vector3(0.939715624, -0.159266293, 0.302603334)

const SURVEY_SUMMARY := (
	"88.000 deg from ColonyShip; arid average/share 100%/100%, dry 100%; "
	+ "elevation 96.0 m (96.0..96.0 m); average/p90/max slope "
	+ "0.01/0.02/0.03 deg; nearest settlement Meridian Flats 7211 m; "
	+ "Bigfoot clearance 21929 m; volcano-edge clearance 9837 m."
)


func _init() -> void:
	direction = SITE_DIRECTION
	facing = 0.0
	title = "Sandworm"
	tint = Color("ff6b28")
	waypoint = true
	show_beyond = 0.0
	aimed_beyond = 0.0
	hide_beyond = 0.0


func survey_metrics() -> Dictionary:
	return {
		"arena_radius": 1600.0,
		"surveyed_core_radius": 185.0,
		"arc_degrees": 88.000,
		"arid_average": 1.0,
		"arid_share": 1.0,
		"dry_share": 1.0,
		"elevation": 96.0,
		"elevation_min": 96.0,
		"elevation_max": 96.0,
		"average_slope_degrees": 0.01,
		"p90_slope_degrees": 0.02,
		"max_slope_degrees": 0.03,
		"settlement_clearance": 7211.0,
		"bigfoot_clearance": 21929.0,
		"volcano_edge_clearance": 9837.0,
	}
