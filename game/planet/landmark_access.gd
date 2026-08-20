class_name LandmarkAccess
extends RefCounted

## Narrow adapter for nodes participating in Landmark.GROUP. Surface landmarks
## retain their concrete type, while non-surface named locations can provide the
## same values through the small method contract below.

const _TITLE_METHOD := &"landmark_title"
const _WAYPOINT_METHOD := &"landmark_waypoint_enabled"
const _TINT_METHOD := &"landmark_tint"
const _SHOW_METHOD := &"landmark_show_beyond"
const _AIMED_METHOD := &"landmark_aimed_beyond"
const _HIDE_METHOD := &"landmark_hide_beyond"


static func as_location(value: Variant) -> Node3D:
	var node := value as Node3D
	if node == null:
		return null
	if node is Landmark:
		return node
	if node.has_method(_TITLE_METHOD) \
			and node.has_method(_WAYPOINT_METHOD) \
			and node.has_method(_TINT_METHOD):
		return node
	return null


static func title(location: Node3D) -> String:
	if location is Landmark:
		return (location as Landmark).title
	return String(location.call(_TITLE_METHOD)) \
		if location != null and location.has_method(_TITLE_METHOD) else ""


static func waypoint_enabled(location: Node3D) -> bool:
	if location is Landmark:
		return (location as Landmark).waypoint
	return bool(location.call(_WAYPOINT_METHOD)) \
		if location != null and location.has_method(_WAYPOINT_METHOD) else false


static func tint(location: Node3D) -> Color:
	if location is Landmark:
		return (location as Landmark).tint
	var value: Variant = location.call(_TINT_METHOD) \
		if location != null and location.has_method(_TINT_METHOD) else null
	return value as Color if value is Color else Color.WHITE


static func show_beyond(location: Node3D) -> float:
	if location is Landmark:
		return (location as Landmark).show_beyond
	return _range_value(location, _SHOW_METHOD)


static func aimed_beyond(location: Node3D) -> float:
	if location is Landmark:
		return (location as Landmark).aimed_beyond
	return _range_value(location, _AIMED_METHOD)


static func hide_beyond(location: Node3D) -> float:
	if location is Landmark:
		return (location as Landmark).hide_beyond
	return _range_value(location, _HIDE_METHOD)


static func _range_value(location: Node3D, method: StringName) -> float:
	if location == null or not location.has_method(method):
		return 0.0
	var value: Variant = location.call(method)
	if value is int or value is float:
		var amount := float(value)
		return maxf(amount, 0.0) if is_finite(amount) else 0.0
	return 0.0
