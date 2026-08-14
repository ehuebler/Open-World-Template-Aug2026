class_name Nuke
extends Ability

## One host-approved, right-hand energy core. The projectile itself owns no
## combat numbers; its generated AbilityDefinition is resolved by AbilityImpact
## when the host copy collides or reaches maximum range.

var _request_sequence := 0


func _press() -> bool:
	if definition == null or definition.projectile_type \
			!= AbilityDefinition.ProjectileType.ENERGY_ORB:
		return false
	var from := player.hand_point(false)
	var variant := 2 if player.uses_float_pose() else 0
	_request_sequence = player.fire_ability_projectile(
		ability_id, from, player.aim_direction(from), variant)
	return _request_sequence > 0


func _tick(_delta: float) -> void:
	if _request_sequence <= 0:
		cancel()
		return
	var state := player.ability_projectile_request_state(_request_sequence)
	if state == OnlinePlayer.ProjectileRequestState.PENDING:
		return
	if state == OnlinePlayer.ProjectileRequestState.REJECTED:
		cancel()
		return
	_request_sequence = 0
	release()


func _release() -> void:
	_request_sequence = 0
