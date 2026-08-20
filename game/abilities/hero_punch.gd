class_name HeroPunch
extends Ability

## One host-approved alternating fist strike. The player owns the short lunge;
## the host derives the damage tunnel from this ability's generated stats.

var _next_left := false
var _requested_left := false
var _request_sequence := 0


func _press() -> bool:
	_requested_left = _next_left
	var from := player.hand_point(_requested_left)
	var variant := 1 if _requested_left else 0
	if player.uses_float_pose():
		variant |= 2
	_request_sequence = player.request_hero_punch(
		ability_id, from, player.aim_direction(from), variant)
	return _request_sequence > 0


func _tick(_delta: float) -> void:
	if _request_sequence <= 0:
		cancel()
		return
	var state := player.hero_punch_request_state(_request_sequence)
	if state == OnlinePlayer.ProjectileRequestState.PENDING:
		return
	if state == OnlinePlayer.ProjectileRequestState.REJECTED:
		cancel()
		return
	# A rejected request neither changes hands nor charges cooldown.
	_accept_request()
	release()


## Keep a quick click alive while its host approval is in flight.
func release() -> void:
	if not is_held():
		return
	if _request_sequence > 0 and player != null:
		var state := player.hero_punch_request_state(_request_sequence)
		if state == OnlinePlayer.ProjectileRequestState.PENDING:
			return
		if state == OnlinePlayer.ProjectileRequestState.REJECTED:
			cancel()
			return
		_accept_request()
	super()


func _accept_request() -> void:
	_next_left = not _requested_left
	_request_sequence = 0


func _release() -> void:
	_request_sequence = 0
