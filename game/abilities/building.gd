class_name BuildingAbility
extends Ability

## Keeps the utility wheel open for as long as its assigned mouse button is
## held. The wheel owns presentation; this ability only gives it the same
## press/release lifecycle as every other power.


func _press() -> bool:
	return player != null and player.open_building_wheel(slot)


func _release() -> void:
	if player != null:
		player.finish_building_wheel(slot)


## A slot replacement, death, or other controller cancellation must close the
## wheel without choosing whatever segment the cursor happened to cross.
func cancel() -> void:
	if not _held:
		return
	_held = false
	if player != null:
		player.cancel_building_wheel(slot)
