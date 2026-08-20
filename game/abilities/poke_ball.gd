class_name PokeBall
extends Ability

## A host-approved capture ball. The projectile only carries the throw; the
## host player resolves capture or release when its authoritative copy lands.

var _request_sequence := 0


func _press() -> bool:
	if definition == null or definition.projectile_type \
			!= AbilityDefinition.ProjectileType.POKE_BALL:
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


## Full-health creatures are difficult to catch; wearing their health down
## smoothly raises the host's probability toward the authored low-health value.
static func capture_chance(current_health: float, maximum_health: float,
		stats: Dictionary) -> float:
	if not is_finite(current_health) or not is_finite(maximum_health) \
			or maximum_health <= 0.0:
		return 0.0
	var full_health := clampf(
		float(stats.get("capture_full_health", 20.0)) * 0.01, 0.0, 1.0)
	var low_health := clampf(
		float(stats.get("capture_low_health", 90.0)) * 0.01, 0.0, 1.0)
	var health_share := clampf(current_health / maximum_health, 0.0, 1.0)
	return lerpf(low_health, full_health, health_share)
