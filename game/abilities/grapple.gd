class_name Grapple
extends Ability

## Committed close-range carry and slam.

var _started := false


func _press() -> bool:
	_started = false
	return player.begin_ability_grapple(ability_id, stats)


func _tick(_delta: float) -> void:
	if player.grapple_active():
		_started = true
		return
	if player.grapple_pending():
		return
	if _started:
		release()
	else:
		# Host rejection, timeout, or a pending request the player cancelled:
		# nothing fired, so there is no cooldown to charge.
		cancel()


## Letting go does not drop the target halfway through the authored move.
func release() -> void:
	if is_held() and player != null:
		# A click often comes back up before a client has received the host's
		# approval. Keep the committed cast alive through that round trip just as
		# we keep it alive once the target is in hand.
		if player.grapple_active_or_pending():
			return
	super()


func _release() -> void:
	if player != null:
		player.cancel_ability_grapple()
	_started = false


func _can_continue_when_attack_blocked() -> bool:
	return player != null and player.grapple_active_or_pending()
