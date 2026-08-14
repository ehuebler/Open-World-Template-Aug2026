class_name Nausicaa
extends Ability

## A short blue eye beam that paints only real planet terrain.
##
## Each sufficiently separated landing point becomes its own replicated glow.
## Because the points are submitted in draw order and every one keeps the same
## one-second fuse, they erupt in that same order instead of turning the whole
## trail into one simultaneous blast.

var _request_sequence := 0
var _left := 0.0
var _since_paint := 0.0
var _last_painted := Vector3.ZERO


func _press() -> bool:
	if definition == null or definition.impact_type \
			!= AbilityDefinition.ImpactType.DELAYED_BLAST:
		return false
	var eyes := player.eye_points()
	var from: Vector3 = (eyes[0] + eyes[1]) * 0.5
	var landing := _terrain_landing(from)
	if landing.is_empty():
		return false
	_left = maxf(stat("duration", 0.75), 0.05)
	_since_paint = 0.0
	_last_painted = Vector3.ZERO
	return _paint(eyes, from, landing)


func _tick(delta: float) -> void:
	if player.submerged_share() > 0.0:
		release()
		return
	_left -= delta
	if _left <= 0.0:
		release()
		return

	var eyes := player.eye_points()
	var from: Vector3 = (eyes[0] + eyes[1]) * 0.5
	var landing := _terrain_landing(from)
	if landing.is_empty():
		player.laser_beams().stop()
		return
	var at: Vector3 = landing["position"]
	player.laser_beams().aim(eyes[0], eyes[1], at, definition.tint)

	_since_paint += delta
	var interval := maxf(stat("chain_interval", 0.08), 0.03)
	if _since_paint < interval:
		return
	_since_paint = fmod(_since_paint, interval)
	var spacing := maxf(stat("paint_spacing", 0.8), 0.1)
	if _last_painted != Vector3.ZERO \
			and at.distance_to(_last_painted) < spacing:
		return
	_paint(eyes, from, landing)


func _release() -> void:
	_request_sequence = 0
	_left = 0.0
	_since_paint = 0.0
	_last_painted = Vector3.ZERO
	if player != null:
		player.laser_beams().stop()


func _paint(eyes: Array[Vector3], from: Vector3,
		landing: Dictionary) -> bool:
	var at: Vector3 = landing["position"]
	_request_sequence = player.fire_ability_delayed_blast(
		ability_id, from, player.aim_direction(from))
	if _request_sequence <= 0:
		return false
	_last_painted = at
	player.laser_beams().aim(eyes[0], eyes[1], at, definition.tint)
	return true


func _terrain_landing(from: Vector3) -> Dictionary:
	var reach := maxf(stat("range", 14.0), 1.0)
	return LaserEyes.terrain_surface(
		player, from, from + player.aim_direction(from) * reach)
