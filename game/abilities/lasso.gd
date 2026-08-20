class_name Lasso
extends Ability

## A replicated string cast that becomes a host-validated physics tether on hit.
## The local Ability owns input lifetime and animation choice; the runtime owns
## hit simulation or the short outbound-and-retract presentation for a miss.

var _started := false
var _hold_pose_started := false
var _cast_left := 0.0


func _press() -> bool:
	if definition == null or definition.grapple_type \
			!= AbilityDefinition.GrappleType.PHYSICS_TETHER:
		return false
	_started = false
	_hold_pose_started = false
	_cast_left = maxf(float(stats.get("animation_duration", 0.3)), 0.0)
	return player.begin_ability_lasso(ability_id, stats)


func _tick(delta: float) -> void:
	_cast_left = maxf(_cast_left - delta, 0.0)
	if player.ability_lasso_active():
		_started = true
		if not _hold_pose_started and _cast_left <= 0.0:
			_hold_pose_started = true
			var clip := definition.held_hover_animation \
				if player.uses_float_pose() \
					and not definition.held_hover_animation.is_empty() \
				else definition.held_animation
			player.play_ability_animation(
				clip, maxf(float(stats.get("duration", 2.0)), 0.1))
		return
	if player.ability_lasso_casting():
		_started = true
		return
	if player.ability_lasso_pending():
		return
	if _started:
		release()
	else:
		cancel()


func _release() -> void:
	if player != null and player.ability_lasso_active_or_pending():
		player.release_ability_lasso()
	_started = false
	_hold_pose_started = false
	_cast_left = 0.0
