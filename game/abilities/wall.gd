class_name WallAbility
extends Ability

## One host-approved temporary barrier placement.

var _request_sequence := 0


func _press() -> bool:
	if definition == null or definition.construct_type \
			!= AbilityDefinition.ConstructType.BARRIER:
		return false
	_request_sequence = player.place_ability_wall(ability_id)
	return _request_sequence > 0


func _tick(_delta: float) -> void:
	if _request_sequence <= 0:
		cancel()
		return
	var state := player.ability_wall_request_state(_request_sequence)
	if state == OnlinePlayer.ProjectileRequestState.PENDING:
		return
	if state == OnlinePlayer.ProjectileRequestState.REJECTED:
		cancel()
		return
	_request_sequence = 0
	release()


func _release() -> void:
	_request_sequence = 0
