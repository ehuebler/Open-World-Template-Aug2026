class_name MeteorPunch
extends Ability

## Fist out, and go.

## Thrown from the air it is a dive: the player accelerates along their look up
## to two hundred metres a second, and if the ground arrives first it opens as a
## crater with them planted at the bottom of it. Thrown from their feet it is a
## flat charge that tears through whatever is growing in front of them and ends
## the same way, in a cone of turned earth ahead of where they land.
##
## Almost none of that is here. The movement is a stance on the body — the punch
## is a way of moving, not a thing standing next to the movement code, and every
## other way the body can move already lives there — so this file is the button:
## it checks the punch is allowed, hands the body the numbers out of the
## catalogue, and charges the cooldown when the punch is over.

func _configure() -> void:
	# Not from a swim and not from a crash. Everything else is fair: standing,
	# walking, running, crouched, sliding, hovering and flying flat out.
	allowed_stances = [OnlinePlayer.Stance.STAND, OnlinePlayer.Stance.CROUCH,
		OnlinePlayer.Stance.SLIDE, OnlinePlayer.Stance.FLY]


func _press() -> bool:
	return player.begin_meteor_punch(stats)


## Held for as long as the punch is in the air, so the cooldown starts when the
## player lands rather than when they let go of the button. Letting go early
## does not cancel it: the whole point of the move is that it commits.
func _tick(_delta: float) -> void:
	if not player.meteor_flying():
		release()


## The button coming up while the punch is still flying is ignored, for the same
## reason. The controller calls this on both edges; only the one that finds the
## body back on the ground ends the ability.
func release() -> void:
	if is_held() and player != null and player.meteor_flying():
		return
	super()
