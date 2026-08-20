@tool
class_name BossWorldAnchor
extends Node3D

## A named boss location in GameWorld-relative Euclidean space.
##
## Unlike Landmark this deliberately does not inherit SurfaceAnchor: its local
## transform is authored relative to the parent named by BossDefinition and is
## never projected onto a planet.

@export var title := "Boss"
@export var waypoint := true
@export var tint := Color("f7b32b")
@export var show_beyond := 1600.0
@export var aimed_beyond := 2600.0
@export var hide_beyond := 4500.0

var definition_id := ""


func _ready() -> void:
	add_to_group(Landmark.GROUP)


## Applies a world-space definition in the declared parent's local frame.
## Orientation values are Euler degrees, matching Node3D.rotation_degrees.
func configure(definition: BossDefinition) -> bool:
	if definition == null or not definition.is_world_space():
		return false
	definition_id = definition.boss_id
	position = definition.world_origin()
	rotation_degrees = definition.world_orientation()
	_apply_waypoint(definition.waypoint, definition.display_name)
	return true


func landmark_title() -> String:
	return title


func landmark_waypoint_enabled() -> bool:
	return waypoint


func landmark_tint() -> Color:
	return tint


func landmark_show_beyond() -> float:
	return show_beyond


func landmark_aimed_beyond() -> float:
	return aimed_beyond


func landmark_hide_beyond() -> float:
	return hide_beyond


func _apply_waypoint(data: Dictionary, fallback_title: String) -> void:
	waypoint = bool(data.get("enabled", waypoint))
	title = String(data.get("title", fallback_title)).strip_edges()
	if title.is_empty():
		title = fallback_title
	var tint_value: Variant = data.get("tint", tint)
	if tint_value is String or tint_value is StringName:
		tint = Color(String(tint_value))
	elif tint_value is Color:
		tint = tint_value as Color
	show_beyond = _range(data.get("show_beyond", show_beyond), show_beyond)
	aimed_beyond = _range(data.get("aimed_beyond", aimed_beyond), aimed_beyond)
	hide_beyond = _range(data.get("hide_beyond", hide_beyond), hide_beyond)


func _range(value: Variant, fallback: float) -> float:
	if value is int or value is float:
		var amount := float(value)
		if is_finite(amount):
			return maxf(amount, 0.0)
	return maxf(fallback, 0.0)
