extends Node

## Rendering-free checks for the ability catalogue and the ability base class.
##
##     godot --headless --path . dev/_ability_model_test.tscn
##
## The catalogue half needs nothing at all. The gating half needs a body, so it
## builds one — without the planet, which means no water to stand in, so the
## submersion guard is driven through the lava reading instead. That is the same
## number [method OnlinePlayer.submerged_share] answers with and the same guard
## it feeds, and a beam refusing to fire from inside a lava lake is right anyway.

const PLAYER := preload("res://game/player/player.tscn")

var _failures := 0
var _player: OnlinePlayer


## Gated the way [LaserEyes] is, without the beams.
class GatedAbility extends Ability:
	func _configure() -> void:
		blocked_underwater = true


## Gated the way [MeteorPunch] is.
class GroundAbility extends Ability:
	func _configure() -> void:
		allowed_stances = [OnlinePlayer.Stance.STAND, OnlinePlayer.Stance.FLY]


func _ready() -> void:
	_check_catalogue()
	_check_authored_ability_shapes()
	_check_stat_lines()
	_check_progression_scaling()
	_check_slot_filters()

	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	for item_id: String in ItemDB.ITEMS:
		ItemIcons._cache[item_id] = ImageTexture.new()
	_player = PLAYER.instantiate() as OnlinePlayer
	_player.peer_id = multiplayer.get_unique_id()
	add_child(_player)
	# Nothing here moves; the body is only here to be asked questions.
	_player.set_process(false)
	_player.set_physics_process(false)
	await get_tree().process_frame

	_check_starfire_alternation()
	_check_starfire_motion()
	_check_starfire_rejection()
	_check_hero_punch_runtime()
	_check_grapple_pending_release()
	await _check_new_ability_runtime()
	await _check_blast_self_launch()
	await _check_blast_presentation()
	_check_training_dummy()
	_check_cooldown()
	_check_gating()
	_check_controller()
	_check_host_cast_authority()
	_check_eye_points()

	_player.queue_free()
	await get_tree().process_frame
	print("ability_model_test: %s" % (
		"all checks passed" if _failures == 0 else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_catalogue() -> void:
	var ids := ItemDB.ability_ids()
	var expected := PackedStringArray(
		["laser_eyes", "meteor_punch", "starfire", "grapple",
			"nuke", "lasso", "wall", "nausicaa", "poke_ball",
			"hero_punch", "building", "settlement_launcher"])
	_expect(ids == expected, "all twelve abilities are in manifest order")
	for id: String in expected:
		_expect(ItemDB.kind_of(id) == ItemDB.KIND_ABILITY,
			"%s is an ability" % id)
		_expect(not ItemDB.description(id).is_empty(),
			"%s has a description for the menu" % id)
		var path := ItemDB.ability_script(id)
		_expect(ResourceLoader.exists(path),
			"%s names a script that exists" % id)
		var script := load(path) as GDScript
		_expect(script != null and script.new() is Ability,
			"%s script is an Ability" % id)
		_expect(ItemDB.ability_icon(id) != null,
			"%s has a menu icon" % id)
		var stats := ItemDB.stats_of(id)
		_expect(stats.has("damage") and stats.has("range")
			and stats.has("cooldown"),
			"%s quotes damage, range and cooldown" % id)


func _check_authored_ability_shapes() -> void:
	var meteor := ItemDB.ability_definition("meteor_punch")
	var starfire := ItemDB.ability_definition("starfire")
	var grapple := ItemDB.ability_definition("grapple")
	var nuke := ItemDB.ability_definition("nuke")
	var lasso := ItemDB.ability_definition("lasso")
	var wall := ItemDB.ability_definition("wall")
	var nausicaa := ItemDB.ability_definition("nausicaa")
	var poke_ball := ItemDB.ability_definition("poke_ball")
	var hero_punch := ItemDB.ability_definition("hero_punch")
	var building := ItemDB.ability_definition("building")
	var settlement_launcher := ItemDB.ability_definition("settlement_launcher")
	_expect(starfire != null
		and starfire.activation_type
			== AbilityDefinition.ActivationType.SUSTAINED
		and starfire.projectile_type
			== AbilityDefinition.ProjectileType.ENERGY_DISK
		and starfire.impact_type
			== AbilityDefinition.ImpactType.EXPLOSION_CRATER,
		"Starfire dispatches a sustained stream of exploding energy disks")
	_expect(starfire != null and not starfire.animation.is_empty()
		and not starfire.alternate_animation.is_empty()
		and not starfire.hover_animation.is_empty()
		and not starfire.alternate_hover_animation.is_empty()
		and starfire.animation != starfire.alternate_animation,
		"Starfire has standing and raised-knee clips for both hands")
	_expect(meteor != null and starfire != null
		and is_equal_approx(
			float(starfire.stats.get("crater_radius", 0.0)) * 2.0,
			float(meteor.stats.get("crater_radius", -1.0)))
		and is_equal_approx(
			float(starfire.stats.get("crater_depth", 0.0)) * 2.0,
			float(meteor.stats.get("crater_depth", -1.0))),
		"Starfire's crater dimensions are half Meteor Punch's")
	_expect(grapple != null
		and grapple.grapple_type
			== AbilityDefinition.GrappleType.CARRY_SLAM
		and grapple.impact_type
			== AbilityDefinition.ImpactType.GRAPPLE_SLAM,
		"Grapple dispatches a carry slam")
	_expect(grapple != null
		and is_equal_approx(float(grapple.stats.get("range", 0.0)), 2.0)
		and is_equal_approx(
			float(grapple.stats.get("launch_height", 0.0)), 20.0)
		and not grapple.animation.is_empty()
		and not grapple.held_animation.is_empty()
		and not grapple.impact_animation.is_empty(),
		"Grapple authors its two-metre reach, twenty-metre rise, and clips")
	_expect(nuke != null
		and nuke.projectile_type
			== AbilityDefinition.ProjectileType.ENERGY_ORB
		and nuke.impact_type
			== AbilityDefinition.ImpactType.MASSIVE_BLAST
		and nuke.reaction_type == AbilityDefinition.ReactionType.RAGDOLL
		and nuke.affects_players and nuke.self_launch
		and nuke.blast_occlusion,
		"Nuke authors a host-resolved occluded orb blast and self-launch")
	_expect(nuke != null
		and is_equal_approx(float(nuke.stats.get("range", 0.0)), 240.0)
		and is_equal_approx(float(nuke.stats.get("radius", 0.0)), 110.0)
		and is_equal_approx(
			float(nuke.stats.get("crater_radius", 0.0)), 72.0)
		and is_equal_approx(
			float(nuke.stats.get("crater_depth", 0.0)), 20.0)
		and float(nuke.stats.get("crater_warp", 0.0)) > 0.0,
		"Nuke carries the authored range, blast, and massive crater profile")
	# The blast has to stay inside the reach it can be thrown, or every shot of it
	# catches its own caster and there is no way to use it at a distance.
	_expect(nuke != null
		and float(nuke.stats.get("range", 0.0))
			> float(nuke.stats.get("radius", 0.0)),
		"and can be thrown further than it reaches")
	_expect(lasso != null
		and lasso.activation_type
			== AbilityDefinition.ActivationType.SUSTAINED
		and lasso.projectile_type
			== AbilityDefinition.ProjectileType.TETHER
		and lasso.grapple_type
			== AbilityDefinition.GrappleType.PHYSICS_TETHER
		and not lasso.held_animation.is_empty()
		and not lasso.held_hover_animation.is_empty(),
		"Lasso authors a sustained physical tether and both hold poses")
	_expect(lasso != null
		and is_equal_approx(float(lasso.stats.get("range", 0.0)), 30.0)
		and is_equal_approx(
			float(lasso.stats.get("rope_length", 0.0)), 10.0)
		and is_equal_approx(float(lasso.stats.get("duration", 0.0)), 2.0),
		"Lasso carries its reach, rope length, and two-second hold")
	_expect(wall != null
		and wall.construct_type == AbilityDefinition.ConstructType.BARRIER
		and is_equal_approx(float(wall.stats.get("wall_width", 0.0)), 8.0)
		and is_equal_approx(float(wall.stats.get("wall_height", 0.0)), 4.0)
		and is_equal_approx(float(wall.stats.get("duration", 0.0)), 7.0)
		and is_equal_approx(
			float(wall.stats.get("fade_duration", 0.0)), 4.0),
		"Wall authors an eight-by-four indestructible fading barrier")
	_expect(nausicaa != null
		and nausicaa.activation_type
			== AbilityDefinition.ActivationType.SUSTAINED
		and nausicaa.impact_type
			== AbilityDefinition.ImpactType.DELAYED_BLAST
		and nausicaa.blast_occlusion
		and nausicaa.animation.is_empty()
		and nausicaa.hover_animation.is_empty()
		and is_equal_approx(
			float(nausicaa.stats.get("delay", 0.0)), 1.0)
		and is_equal_approx(
			float(nausicaa.stats.get("duration", 0.0)), 0.75)
		and float(nausicaa.stats.get("duration", 0.0))
			< float(ItemDB.stats_of("laser_eyes").get("duration", 0.0))
		and is_equal_approx(
			float(nausicaa.stats.get("range", 0.0)), 60.0)
		and is_equal_approx(
			float(nausicaa.stats.get("radius", 0.0)), 18.0)
		and is_equal_approx(
			float(nausicaa.stats.get("paint_spacing", 0.0)), 1.25)
		and is_equal_approx(
			float(nausicaa.stats.get("crater_depth", 0.0)), 0.55),
		"Nausicaä authors a brief long-range terrain chain with broad blasts and shallow indents")
	_expect(poke_ball != null
		and poke_ball.activation_type
			== AbilityDefinition.ActivationType.INSTANT
		and poke_ball.projectile_type
			== AbilityDefinition.ProjectileType.POKE_BALL
		and is_zero_approx(float(poke_ball.stats.get("damage", -1.0)))
		and float(poke_ball.stats.get("capture_low_health", 0.0))
			> float(poke_ball.stats.get("capture_full_health", 0.0)),
		"Poké Ball authors a harmless capture projectile weighted by mob health")
	_expect(hero_punch != null
		and hero_punch.activation_type
			== AbilityDefinition.ActivationType.INSTANT
		and hero_punch.projectile_type
			== AbilityDefinition.ProjectileType.NONE
		and hero_punch.blocked_underwater
		and hero_punch.allowed_stances.has(OnlinePlayer.Stance.STAND)
		and hero_punch.allowed_stances.has(OnlinePlayer.Stance.FLY)
		and hero_punch.allowed_stances.has(OnlinePlayer.Stance.HERO)
		and not hero_punch.allowed_stances.has(OnlinePlayer.Stance.SWIM)
		and is_equal_approx(
			float(hero_punch.stats.get("range", 0.0)), 1.0)
		and float(hero_punch.stats.get("damage", 0.0))
			< float(starfire.stats.get("damage", 0.0))
		and not hero_punch.alternate_animation.is_empty()
		and not hero_punch.alternate_hover_animation.is_empty(),
		"Hero Punch authors a light one-metre alternating strike for every ordinary non-swim pose")
	_expect(building != null
		and building.activation_type
			== AbilityDefinition.ActivationType.SUSTAINED
		and building.projectile_type
			== AbilityDefinition.ProjectileType.NONE
		and building.direct_equip
		and building.overrides_weapon_input
		and building.allowed_stances.has(OnlinePlayer.Stance.SWIM)
		and ItemDB.ability_directly_equippable("building"),
		"Building is an equipable held utility wheel in every ordinary stance")
	_expect(settlement_launcher != null
		and settlement_launcher.use_type
			== AbilityDefinition.UseType.ONE_TIME
		and settlement_launcher.activation_type
			== AbilityDefinition.ActivationType.INSTANT
		and settlement_launcher.projectile_type
			== AbilityDefinition.ProjectileType.NONE
		and not settlement_launcher.direct_equip
		and not settlement_launcher.overrides_weapon_input
		and not ItemDB.ability_directly_equippable("settlement_launcher")
		and is_zero_approx(float(
			settlement_launcher.stats.get("damage", -1.0))),
		"Settlement Launcher is harmless one-time Building inventory, not a direct cast")


func _check_stat_lines() -> void:
	var lines := ItemDB.stat_lines("laser_eyes")
	_expect(lines.size() == ItemDB.stats_of("laser_eyes").size() - 1,
		"every stat but the damage unit gets a line")
	var written := "\n".join(lines)
	_expect(written.contains("Damage\t1200/s"),
		"the damage unit is appended to the number")
	_expect(written.contains("Range\t60 m"), "range is written in metres")
	# Against the catalogue rather than against a copy of the number in it. What
	# this line is for is the label, the tab and the unit suffix; pinning the
	# value as well only means the formatting test fails when somebody retunes
	# the ability, which is the one thing it has no opinion about.
	_expect(written.contains("Cooldown\t%d s" % int(
		ItemDB.stats_of("laser_eyes").get("cooldown", -1))),
		"cooldown is written in seconds")
	_expect(not written.contains(".0"),
		"whole numbers lose their decimal point")
	var capture_lines := "\n".join(ItemDB.stat_lines("poke_ball"))
	_expect(capture_lines.contains("Full-Health Capture\t20%")
		and capture_lines.contains("Low-Health Capture\t90%"),
		"Poké Ball capture chances are readable percentages")
	var punch_lines := "\n".join(ItemDB.stat_lines("hero_punch"))
	_expect(punch_lines.contains("Punch Reach\t")
		and punch_lines.contains("Wind Tunnel\t"),
		"Hero Punch labels its damaging reach and compressed-air tunnel")
	_expect(ItemDB.stat_lines("sword").is_empty(),
		"an item with no stats gets no lines")


func _check_progression_scaling() -> void:
	var laser_one := ItemDB.stats_of("laser_eyes", 1)
	var laser_five := ItemDB.stats_of("laser_eyes", 5)
	_expect(is_equal_approx(
		float(laser_five["damage"]), float(laser_one["damage"]) * 1.32),
		"level five adds thirty-two percent primary PvE damage")
	var starfire_one := ItemDB.stats_of("starfire", 1)
	var starfire_five := ItemDB.stats_of("starfire", 5)
	_expect(is_equal_approx(
		float(starfire_five["cooldown"]),
		float(starfire_one["cooldown"]) * 0.8),
		"level five removes twenty percent cooldown")
	var wall_one := ItemDB.stats_of("wall", 1)
	var wall_five := ItemDB.stats_of("wall", 5)
	_expect(is_equal_approx(
		float(wall_five["duration"]), float(wall_one["duration"]) * 1.32)
		and is_equal_approx(
			float(wall_five["cooldown"]), float(wall_one["cooldown"]) * 0.8),
		"Wall scales duration and cooldown")
	var nuke_one := ItemDB.stats_of("nuke", 1)
	var nuke_five := ItemDB.stats_of("nuke", 5)
	_expect(float(nuke_five["damage"]) > float(nuke_one["damage"])
		and nuke_five["player_damage"] == nuke_one["player_damage"]
		and nuke_five["radius"] == nuke_one["radius"],
		"Nuke scales PvE damage without changing player damage or radius")
	var trained_starfire := ItemDB.stats_of("starfire", 1, {
		"cooldown": 5,
		"size": 5,
		"speed": 5,
	})
	_expect(is_equal_approx(
			float(trained_starfire["cooldown"]),
			float(starfire_one["cooldown"]) * 0.6)
		and is_equal_approx(
			float(trained_starfire["projectile_radius"]),
			float(starfire_one["projectile_radius"]) * 1.5)
		and is_equal_approx(
			float(trained_starfire["speed"]),
			float(starfire_one["speed"]) * 1.5),
		"independent training reduces cooldown and increases size and speed")
	var trained_nuke := ItemDB.stats_of("nuke", 1, {
		"power": 5,
		"size": 5,
	})
	_expect(is_equal_approx(
			float(trained_nuke["damage"]), float(nuke_one["damage"]) * 1.5)
		and trained_nuke["player_damage"] == nuke_one["player_damage"]
		and is_equal_approx(
			float(trained_nuke["radius"]), float(nuke_one["radius"]) * 1.5),
		"explicit Power and Size tracks scale PvE output without scaling player damage")
	_expect(ItemDB.ability_stat_ids("starfire").has("cooldown")
		and ItemDB.ability_stat_ids("starfire").has("size")
		and ItemDB.ability_stat_ids("starfire").has("speed")
		and ItemDB.ability_stat_ids("settlement_launcher").is_empty()
		and ItemDB.sanitize_ability_stat_levels("starfire", {
			"speed": 99, "unknown": 4,
		}) == {"speed": ItemDB.MAX_ABILITY_STAT_LEVEL},
		"training exposes only authored reusable stat tracks and clamps its wire data")
	_expect(ItemDB.hat_shop_ids().size() >= 4
		and ItemDB.hat_price(ItemDB.hat_shop_ids()[0]) == 0
		and ItemDB.ability_unlock_price("starfire") == 0
		and ItemDB.ability_upgrade_price("starfire", 1) == 0
		and ItemDB.ability_unlock_price("settlement_launcher") < 0,
		"reusable specialty prices are free while one-time stock stays source-exclusive")


func _check_slot_filters() -> void:
	var abilities := ItemContainer.new(CharacterDB.ABILITY_SLOTS)
	for index in abilities.size():
		abilities.set_filter(index, ItemDB.ABILITY)
	abilities.set_item(0, "laser_eyes")
	abilities.set_item(1, "sword")
	_expect(abilities.get_item(0) == "laser_eyes",
		"an ability slot takes an ability")
	_expect(abilities.get_item(1).is_empty(),
		"an ability slot still refuses a weapon")


## The beams leave the face.
##
## They used to leave the back of the neck: the offset was measured out along the
## Head bone's own axes, and on this body that bone's forward is the model's
## backward. Worth a standing check rather than a one-off look, because the
## symptom is only visible from outside the character — aim it from the back of
## the head and it still lands on the crosshair, so nothing else in the game
## notices.
func _check_eye_points() -> void:
	var eyes := _player.eye_points()
	var to_body := _player.global_transform.affine_inverse()
	var left := to_body * eyes[0]
	var right := to_body * eyes[1]
	var middle := (left + right) * 0.5
	# The head joint sits on the body's centre line, so anything on the face is
	# ahead of the origin in z and anything on the neck is behind it.
	_expect(middle.z < -0.05,
		"the eyes are out on the face, %.3f m ahead of the body's centre"
		% -middle.z)
	_expect(left.x < right.x, "the left eye is the left one")
	var apart := right.x - left.x
	_expect(apart > 0.02 and apart < 0.2,
		"and the two are a face apart (%.3f m)" % apart)
	_expect(middle.y > 1.0, "at head height (%.2f m)" % middle.y)
	# Both eyes, not just their midpoint: a pair straddling the nose averages out
	# to the right place even if one of them is inside an ear.
	_expect(absf(left.z - right.z) < 0.02 and absf(left.y - right.y) < 0.02,
		"and they are level with each other")


func _check_starfire_alternation() -> void:
	var definition := ItemDB.ability_definition("starfire")
	var ability := Starfire.new()
	ability.configure(_player, 0, "starfire", definition)
	var fired := ability.press()
	var first_clip := _player._ability_clip
	ability.tick(0.0)
	ability.tick(ability.cooldown() + 0.01)
	var second_clip := _player._ability_clip
	ability.tick(0.0)
	ability.tick(ability.cooldown() + 0.01)
	var third_clip := _player._ability_clip
	ability.tick(0.0)
	_expect(fired and ability.is_held(),
		"holding Starfire launches each authored disk automatically")
	_expect(first_clip == String(definition.animation)
		and second_clip == String(definition.alternate_animation)
		and third_clip == String(definition.animation),
		"Starfire casts right, left, then right again")
	ability.release()
	for child: Node in get_children():
		if child is AbilityProjectile:
			child.queue_free()


func _check_starfire_motion() -> void:
	var definition := ItemDB.ability_definition("starfire")
	var ability := Starfire.new()
	ability.configure(_player, 0, "starfire", definition)
	_player._apply_stance(OnlinePlayer.Stance.FLY)
	_player._fly_blend = 0.0
	var carried := Vector3(7.0, 2.0, -3.0)
	_player.velocity = carried
	_expect(ability.press(), "Starfire throws while floating")
	_expect(_player.animator != null
		and _player.animator.has_animation(definition.hover_animation)
		and _player.animator.has_animation(definition.alternate_hover_animation),
		"the player rig ships both raised-knee Starfire clips")
	var projectile: AbilityProjectile
	for child: Node in get_children():
		if child is AbilityProjectile:
			projectile = child as AbilityProjectile
	_expect(_player._ability_clip == String(definition.hover_animation),
		"a floating throw keeps the raised-knee animation")
	_expect(projectile != null and projectile._velocity.is_equal_approx(
		projectile._along * projectile._speed + carried),
		"Starfire adds the player's velocity to disk launch velocity")
	_expect(projectile != null and is_zero_approx(projectile._disk.rotation.x),
		"the disk leads on its thin rim like a frisbee")
	ability.tick(0.0)
	ability.release()
	_player.velocity = Vector3.ZERO
	_player._fly_blend = 0.0
	_player._apply_stance(OnlinePlayer.Stance.STAND)
	for child: Node in get_children():
		if child is AbilityProjectile:
			child.queue_free()


func _check_starfire_rejection() -> void:
	var definition := ItemDB.ability_definition("starfire")
	var ability := Starfire.new()
	ability.configure(_player, 0, "starfire", definition)
	_expect(ability.press(), "Starfire can wait for projectile approval")
	_player._projectile_result = OnlinePlayer.ProjectileRequestState.REJECTED
	ability.tick(0.0)
	_expect(not ability.is_held() and ability.can_use(),
		"a rejected Starfire cast spends no cooldown")

	_player._ability_clip = ""
	_expect(ability.press(), "Starfire retries immediately after rejection")
	ability.tick(0.0)
	_expect(_player._ability_clip == String(definition.animation),
		"a rejected cast does not advance the alternating hand")
	ability.release()
	for child: Node in get_children():
		if child is AbilityProjectile:
			child.queue_free()


func _check_hero_punch_runtime() -> void:
	var definition := ItemDB.ability_definition("hero_punch")
	var ability := HeroPunch.new()
	ability.configure(_player, 0, "hero_punch", definition)
	_player._applying_loadout = true
	_player.ability_progress["hero_punch"] = 1
	_player.abilities.set_item(0, "hero_punch")
	_player._applying_loadout = false
	_player._apply_stance(OnlinePlayer.Stance.STAND)
	_player._lava_state = {}
	var start := _player.global_position
	_expect(ability.press(), "Hero Punch sends its host-approved right fist")
	var first_clip := _player._ability_clip
	ability.release()
	_expect(not ability.is_held(),
		"an immediately approved quick Hero Punch still commits its hand")
	_player._hero_punch_move(1.0)
	var travelled := _player.global_position.distance_to(start)
	var shock := _player.hero_punch_shock()
	_expect(travelled >= 0.95 and travelled <= 1.01,
		"Hero Punch lunges the body one measured metre (%.2f m)" % travelled)
	_expect(shock != null
		and is_equal_approx(shock.radius,
			float(definition.stats.get("radius", 0.0)))
		and is_equal_approx(shock.minimum_reach,
			float(definition.stats.get("wind_length", 0.0))),
		"Hero Punch draws a narrow authored wind tunnel from its fist")
	ability.tick(ability.cooldown() + 0.01)
	_expect(ability.press(), "Hero Punch can strike again after its short cooldown")
	var second_clip := _player._ability_clip
	ability.tick(0.0)
	_expect(first_clip == String(definition.animation)
		and second_clip == String(definition.alternate_animation),
		"Hero Punch alternates right then left only after approved casts")

	var pose_gate := HeroPunch.new()
	pose_gate.configure(_player, 0, "hero_punch", definition)
	for allowed: int in [
		OnlinePlayer.Stance.STAND, OnlinePlayer.Stance.CROUCH,
		OnlinePlayer.Stance.SLIDE, OnlinePlayer.Stance.FLY,
		OnlinePlayer.Stance.HERO,
	]:
		_player._apply_stance(allowed)
		_expect(pose_gate.can_use(),
			"Hero Punch works from %s" % OnlinePlayer.Stance.keys()[allowed])
	_player._apply_stance(OnlinePlayer.Stance.SWIM)
	_expect(not pose_gate.can_use(), "Hero Punch refuses the swim stance")
	_player._apply_stance(OnlinePlayer.Stance.STAND)

	# A quick mouse-up must not discard a cast still travelling to the host.
	pose_gate._held = true
	pose_gate._request_sequence = 91
	_player._hero_punch_result_sequence = 91
	_player._hero_punch_result = OnlinePlayer.ProjectileRequestState.PENDING
	pose_gate.release()
	_expect(pose_gate.is_held(),
		"Hero Punch keeps a quick click alive while host approval is pending")
	_player._hero_punch_result = OnlinePlayer.ProjectileRequestState.REJECTED
	pose_gate.tick(0.0)
	_expect(not pose_gate.is_held() and pose_gate.can_use(),
		"a rejected Hero Punch spends no cooldown")

	_player.global_position = start
	_player.reset_physics_interpolation()
	_player._hero_punch_move_left = 0.0
	_player._hero_punch_effect_left = 0.0
	_player.abilities.clear()
	_player.ability_progress.erase("hero_punch")


func _check_grapple_pending_release() -> void:
	var ability := Grapple.new()
	ability.configure(
		_player, 0, "grapple", ItemDB.ability_definition("grapple"))
	# The real press is waiting on a remote host at this point. Releasing a
	# normal click must not cancel the request before that answer returns.
	ability._held = true
	_player._ability_grapple_id = "grapple"
	_player._ability_grapple_pending_left = 0.5
	ability.release()
	_expect(ability.is_held() and _player.grapple_pending(),
		"Grapple keeps a quick click alive while host approval is pending")
	_player._ability_grapple_pending_left = 0.0
	ability.tick(0.0)
	_expect(not ability.is_held() and is_zero_approx(ability.cooldown_left()),
		"a rejected Grapple still clears without charging cooldown")


func _check_new_ability_runtime() -> void:
	var nuke_definition := ItemDB.ability_definition("nuke")
	var nuke := Nuke.new()
	nuke.configure(_player, 0, "nuke", nuke_definition)
	_player.velocity = Vector3(4.0, 1.0, -2.0)
	_expect(nuke.press(), "Nuke launches its host-approved hand projectile")
	var orb: AbilityProjectile
	for child: Node in get_children():
		if child is AbilityProjectile \
				and (child as AbilityProjectile).definition == nuke_definition:
			orb = child as AbilityProjectile
	_expect(orb != null and orb._disk.mesh is SphereMesh
		and orb.authoritative,
		"Nuke builds a spherical orb whose offline copy owns impact")
	nuke.tick(0.0)
	_player.velocity = Vector3.ZERO
	if orb != null:
		orb.queue_free()

	var poke_definition := ItemDB.ability_definition("poke_ball")
	var poke_ball := PokeBall.new()
	poke_ball.configure(_player, 0, "poke_ball", poke_definition)
	_expect(poke_ball.press(), "Poké Ball launches its host-approved hand projectile")
	var ball: AbilityProjectile
	for child: Node in get_children():
		if child is AbilityProjectile \
				and (child as AbilityProjectile).definition == poke_definition:
			ball = child as AbilityProjectile
	_expect(ball != null and ball._disk.mesh is SphereMesh
		and ball._disk.get_node_or_null("RedCap") is MeshInstance3D
		and ball._disk.get_node_or_null("Band") is MeshInstance3D
		and ball._disk.get_node_or_null("Button") is MeshInstance3D,
		"Poké Ball builds a tumbling red-and-white ball with a band and button")
	var capture_stats := ItemDB.stats_of("poke_ball")
	_expect(is_equal_approx(PokeBall.capture_chance(
			100.0, 100.0, capture_stats), 0.2)
		and is_equal_approx(PokeBall.capture_chance(
			0.0, 100.0, capture_stats), 0.9)
		and PokeBall.capture_chance(25.0, 100.0, capture_stats) > 0.7,
		"Poké Ball capture chance rises smoothly as a mob is weakened")
	poke_ball.tick(0.0)
	if ball != null:
		ball.queue_free()

	var clips := [
		"NukeThrow", "NukeFloatThrow",
		"LassoThrow", "LassoFloatThrow", "LassoHold", "LassoFloatHold",
		"WallPlace", "WallFloatPlace",
		"HeroPunchRight", "HeroPunchLeft",
		"HeroPunchFloatRight", "HeroPunchFloatLeft",
	]
	var clips_present := _player.animator != null
	for clip: String in clips:
		clips_present = clips_present and _player.animator.has_animation(clip)
	_expect(clips_present,
		"both character exports expose the authored cast and hover clips")

	var barrier := AbilityBarrier.create(
		self, 77, _player.peer_id, Transform3D.IDENTITY,
		Vector3(8.0, 4.0, 0.35), 7.0, 4.0, Color.CORNFLOWER_BLUE)
	_expect(barrier != null and barrier.collision_layer == 1
		and barrier.size().is_equal_approx(Vector3(8.0, 4.0, 0.35)),
		"Wall creates solid layer-one collision at its authored size")
	if barrier != null:
		barrier._process(4.0)
		_expect(barrier._material.albedo_color.a < 0.52
			and barrier.remaining() > 0.0,
			"Wall fades gradually while its lifetime is still active")
		barrier.queue_free()

	var first_warning := AbilityDelayedBlast.create(
		self, _player, ItemDB.ability_definition("nausicaa"),
		Vector3(0.0, 2.0, 0.0), Vector3(0.0, 0.0, -8.0),
		Vector3.UP, 1.0, false)
	var second_warning := AbilityDelayedBlast.create(
		self, _player, ItemDB.ability_definition("nausicaa"),
		Vector3(0.0, 2.0, 0.0), Vector3(1.4, 0.0, -8.0),
		Vector3.UP, 1.0, false)
	_expect(first_warning != null and second_warning != null
		and first_warning._marker.mesh is CylinderMesh
		and first_warning._lamp.light_color \
			== ItemDB.ability_definition("nausicaa").tint,
		"Nausicaä paints replicated blue glow patches instead of a ground line")
	if first_warning != null and second_warning != null:
		first_warning.set_process(false)
		second_warning.set_process(false)
		# The second patch is painted a tenth of a second later. Equal fuses
		# therefore preserve draw order without a separate chain controller.
		first_warning._process(0.1)
		first_warning._process(0.91)
		second_warning._process(0.91)
		_expect(first_warning._detonated and not second_warning._detonated,
			"Nausicaä's first painted patch detonates first after one second")
		second_warning._process(0.1)
		_expect(second_warning._detonated,
			"Nausicaä's detonation then advances along the painted trail")

	var beams := _player.laser_beams()
	var nausicaa_tint := ItemDB.ability_definition("nausicaa").tint
	beams.aim(Vector3(-0.05, 1.8, 0.0), Vector3(0.05, 1.8, 0.0),
		Vector3(0.0, 0.0, -8.0), nausicaa_tint)
	_expect(beams._colour == nausicaa_tint
		and beams._glow_material.emission == nausicaa_tint,
		"Nausicaä reuses the Laser Eyes beams with a blue glow")
	beams.stop()

	var player_target := PLAYER.instantiate() as OnlinePlayer
	player_target.peer_id = 2
	player_target.defer_camera = true
	add_child(player_target)
	player_target.set_process(false)
	player_target.set_physics_process(false)
	_expect(player_target.begin_lasso(_player)
		and player_target.is_lassoed(),
		"Lasso temporarily transfers a player target to host movement")
	var lasso_definition := ItemDB.ability_definition("lasso")
	var tether := AbilityLassoTether.create(
		self, _player, player_target, lasso_definition, NodePath(), true)
	if tether != null:
		tether.set_physics_process(false)
		var first_string_segment := tether._string[0].mesh as CylinderMesh \
			if not tether._string.is_empty() else null
		_expect(tether._string.size() == AbilityLassoTether.STRING_SEGMENTS
			and first_string_segment != null
			and is_equal_approx(first_string_segment.top_radius,
				AbilityLassoTether.STRING_RADIUS),
			"Lasso renders as a thin segmented string instead of a glowing line")
		var target_at := _player.hand_point(false) \
			+ _player.global_basis.x.normalized() * 5.0
		var up := _player.global_basis.y.normalized()
		var radial := (target_at - _player.hand_point(false)).normalized()
		var movement := radial.cross(up).normalized() * 20.0
		player_target.global_position = target_at
		_player.velocity = Vector3.ZERO
		tether._velocity = Vector3.ZERO
		tether._simulate_target(0.05)
		var without_movement := tether.throw_velocity()
		player_target.global_position = target_at
		_player.velocity = movement
		tether._velocity = Vector3.ZERO
		tether._simulate_target(0.05)
		var with_movement := tether.throw_velocity()
		_expect((with_movement - without_movement).dot(
			movement.normalized()) > 1.0,
			"caster movement adds tangential Lasso momentum")
		tether.queue_free()
	_player.velocity = Vector3.ZERO
	player_target.lasso_simulate(
		Vector3.RIGHT * 0.3, Vector3(9.0, 2.0, 0.0))
	player_target.end_lasso(Vector3.ZERO)
	_expect(player_target.can_be_lassoed()
		and not player_target.is_lassoed(),
		"Lasso release restores normal player control")
	player_target.global_position = Vector3(100.0, 0.0, 0.0)
	var missed_lasso := AbilityLassoTether.create_miss(
		self, _player, lasso_definition)
	var miss_ended := [false]
	if missed_lasso != null:
		missed_lasso.set_physics_process(false)
		missed_lasso.miss_finished.connect(
			func(_tether: AbilityLassoTether) -> void:
				miss_ended[0] = true)
		missed_lasso._physics_process(missed_lasso._miss_out * 0.5)
		var visible_segments := 0
		for segment: MeshInstance3D in missed_lasso._string:
			visible_segments += 1 if segment.visible else 0
		_expect(missed_lasso.is_miss_cast() and visible_segments > 0,
			"a missed Lasso still fires a visible string into the world")
		missed_lasso._physics_process(
			missed_lasso._miss_out + AbilityLassoTether.MISS_HOLD
				+ AbilityLassoTether.MISS_RETRACT + 0.1)
	_expect(missed_lasso != null and bool(miss_ended[0])
		and missed_lasso._miss_done,
		"a missed Lasso retracts and disappears after failing to grab")

	var player_health_before := player_target.health()
	var nuke_player_blast := DamageHit.area(
		player_target.combat_position(), 22.0, 25.0, 1.0)
	nuke_player_blast.ability_id = "nuke"
	nuke_player_blast.faction = DamageHit.Faction.ENEMY
	nuke_player_blast.reaction = DamageHit.Reaction.RAGDOLL
	nuke_player_blast.world_impulse = Vector3(18.0, 8.0, 0.0)
	var nuke_player_damage := player_target.apply_damage(nuke_player_blast)
	_expect(nuke_player_damage > 0.0
		and player_target.health() < player_health_before
		and player_target._forced_ragdoll
		and player_target.velocity.length() > 1.0,
		"Nuke-style player damage ragdolls and blows the target away")
	player_target._clear_ragdoll()
	player_target.stats.set_health(player_target.maximum_health())

	_player.global_position = Vector3.ZERO
	player_target.global_position = Vector3(4.0, 0.0, 0.0)
	var blocker := StaticBody3D.new()
	blocker.collision_layer = 1
	var blocker_shape := CollisionShape3D.new()
	var blocker_box := BoxShape3D.new()
	blocker_box.size = Vector3(0.25, 3.0, 3.0)
	blocker_shape.shape = blocker_box
	blocker.add_child(blocker_shape)
	add_child(blocker)
	blocker.global_position = Vector3(
		2.0, player_target.combat_position().y, 0.0)
	await get_tree().physics_frame
	var occluded := DamageHit.area(
		_player.combat_position(), 10.0, 1.0, 1.0)
	occluded.blocked_by_world = true
	_expect(occluded._world_blocks(_player, _player, player_target),
		"opt-in blast damage is stopped by layer-one Wall geometry")
	blocker.queue_free()
	player_target.queue_free()


## A blast that launches its caster has to take the caster's body with it. The
## camera, the eye line and the position peers are told about all hang off the
## capsule and not off the bones, so a launch the bones are not allowed to match
## is a view that flies up on its own while the character stays where it stood.
func _check_blast_self_launch() -> void:
	var ragdoll := _player._ragdoll
	if ragdoll == null or not ragdoll.built():
		_expect(false, "the test body has a ragdoll to launch")
		return
	_player.global_position = Vector3.ZERO
	var up := _player.global_basis.y.normalized()
	# Nuke's authored `self_launch_speed`, which is well past the ceiling the
	# ragdoll holds a body to once it is merely falling.
	var launch := up * 68.0
	_player.velocity = Vector3.ZERO
	_player._force_full_ragdoll_local(launch, 0.5)
	_expect(ragdoll.limp() and _player.velocity.is_equal_approx(launch),
		"a self-launch hands the capsule and the bones the same velocity")
	await get_tree().physics_frame
	_expect(ragdoll.drift().dot(up) > Ragdoll.MAX_SPEED,
		"limp bones keep an authored launch past their own safety ceiling")

	# Half a second of the arc, with the capsule driven the way its own physics
	# step would drive it. The bones shed some of the launch to their damping and
	# gain some off the ground they left; either way the capsule goes where they
	# go, because everything the player sees and aims with hangs off it.
	var from := _player.global_position
	var body_from := ragdoll.centre()
	for _frame in 30:
		await get_tree().physics_frame
		_player._crash_move(get_physics_process_delta_time())
	var capsule_climb := (_player.global_position - from).dot(up)
	var body_climb := (ragdoll.centre() - body_from).dot(up)
	# Left to its own gravity the capsule would be some thirty metres up by here,
	# which is the whole of the fault: it is the camera, and the body is not.
	_expect(body_climb > 1.0 and absf(capsule_climb - body_climb) < 1.0,
		"the crash capsule climbs with the launched body and not past it")
	_player._clear_ragdoll()
	_player.velocity = Vector3.ZERO
	_player.global_position = Vector3.ZERO


## The staged detonation. A nuclear burst is not one shell that swells and stops:
## it flashes, throws two fronts out along the ground, and stands a cloud up for
## several times as long as the fireball it came out of.
func _check_blast_presentation() -> void:
	var nuke := ItemDB.ability_definition("nuke")
	var radius := float(nuke.stats.get("radius", 0.0))
	_expect(radius <= EnergyExplosion.MAX_RADIUS,
		"the authored nuke fireball fits inside what the wire will carry (%.0f m)"
			% radius)

	var small := EnergyExplosion.burst(
		self, Vector3.ZERO, 4.0, Color.ORANGE, 0.3, false)
	var massive := EnergyExplosion.burst(
		self, Vector3.ZERO, 16.0, Color.CYAN, 0.9, true, false)
	var big := EnergyExplosion.burst(
		self, Vector3.ZERO, radius, nuke.tint,
		float(nuke.stats.get("explosion_duration", 0.8)), true, true)
	_expect(small != null and big != null
		and big.span() > small.span() * 4.0,
		"a nuclear burst outlasts its own fireball and a small one does not")
	_expect(massive != null and is_equal_approx(massive.span(), 0.9),
		"a massive non-nuclear blast keeps its brighter shell without the cloud")

	await get_tree().process_frame
	await get_tree().process_frame
	var rings := 0
	var clouds := 0
	var flashes := 0
	for child: Node in big.get_children():
		if not (child is Node3D and (child as Node3D).top_level):
			continue
		if child is MeshInstance3D:
			flashes += 1
		for piece: Node in child.get_children():
			var shape := piece as MeshInstance3D
			if shape == null:
				continue
			if shape.mesh is TorusMesh:
				rings += 1
			else:
				clouds += 1
	_expect(flashes == 1 and rings == 2 and clouds >= 3,
		"it builds a flash, two fronts, and a cloud (%d/%d/%d)"
			% [flashes, rings, clouds])
	# Both stand outside the fireball's own transform, which opens from a twelfth
	# of full size: parented under it they would be multiplied by it.
	_expect(big.scale.length() < radius,
		"and the fireball is still opening while they run")

	# The screen goes with it for anyone standing inside. Local only and nothing
	# is sent — every peer already has the blast, so every peer's own distance to
	# it is enough.
	var feedback := CombatFeedback.new()
	add_child(feedback)
	feedback.configure(null, null)
	_expect(is_zero_approx(feedback.blast_flash_remaining()),
		"a view outside a blast is left alone")
	feedback.blast_flash(0.8)
	_expect(feedback.blast_flash_remaining()
		> CombatFeedback.BLAST_FLASH_TIME * 0.9,
		"and one inside it is turned inside out for about a second")
	feedback.queue_free()
	small.queue_free()
	massive.queue_free()
	big.queue_free()


func _check_training_dummy() -> void:
	var packed := load(
		"res://game/enemies/training_dummy.tscn") as PackedScene
	var dummy := packed.instantiate() as TrainingDummy
	add_child(dummy)
	dummy.set_physics_process(false)
	_expect(not dummy.anchor_path.is_empty()
		and is_finite(dummy.anchor_right_offset)
		and is_finite(dummy.anchor_forward_offset),
		"the training dummy can settle beside an authored surface anchor")
	var carried_to := Vector3(3.0, 8.0, -2.0)
	_expect(dummy.begin_grapple(_player),
		"the training dummy accepts a grapple while alive")
	dummy.grapple_follow(carried_to, Vector3.UP)
	_expect(dummy.global_position.is_equal_approx(carried_to - Vector3.UP),
		"the training dummy follows the carry socket")
	dummy.end_grapple(Vector3(2.0, 0.0, 1.0), Vector3.UP)
	_expect(dummy.can_be_grappled(),
		"ending a carry releases the training dummy")
	_expect(dummy.begin_lasso(_player) and dummy.is_lassoed(),
		"the training dummy accepts a physical Lasso")
	var lasso_tether := AbilityLassoTether.create(
		self, _player, dummy, ItemDB.ability_definition("lasso"),
		NodePath(), true)
	if lasso_tether != null:
		lasso_tether.set_physics_process(false)
		lasso_tether._velocity = Vector3.RIGHT * 20.0
		var before_collision := dummy.health()
		lasso_tether._damage_combatant(
			dummy, dummy.combat_position(), 20.0)
		_expect(dummy.health() < before_collision,
			"a high-speed Lasso collision damages its captured target")
		dummy.set("_health", dummy.maximum_health)
		lasso_tether.queue_free()
	dummy.end_lasso(Vector3(12.0, 4.0, 0.0))
	_expect(dummy.can_be_lassoed() and dummy.velocity.length() > 10.0,
		"Lasso release restores the dummy and preserves throw velocity")

	var radial := DamageHit.area(
		dummy.combat_position() - Vector3.RIGHT * 2.0, 10.0, 100.0, 1.0)
	radial.radial_impulse = 20.0
	radial.radial_lift = 5.0
	var resolved := radial.resolved_for(dummy)
	_expect(resolved.world_impulse.x > 0.0
		and resolved.world_impulse.y > 0.0,
		"host-authored radial reactions resolve outward impulse and lift")

	var hit := DamageHit.area(dummy.combat_position(), 2.0,
		dummy.maximum_health, 0.0)
	hit.faction = DamageHit.Faction.PLAYER
	_expect(is_equal_approx(dummy.apply_damage(hit), dummy.maximum_health)
		and not dummy.can_be_grappled(),
		"the training dummy takes lethal ability damage")
	dummy._physics_process(dummy.respawn_delay + 0.01)
	_expect(dummy.can_be_grappled()
		and is_equal_approx(dummy.health(), dummy.maximum_health),
		"the training dummy respawns at full health")
	dummy.queue_free()


func _check_cooldown() -> void:
	var ability := GatedAbility.new()
	ability.configure(_player, 0, "laser_eyes", {"cooldown": 2.0})
	_expect(ability.can_use(), "a fresh ability is ready")
	_expect(ability.press(), "pressing starts it")
	_expect(ability.is_held(), "and it stays held until released")
	ability.release()
	_expect(not ability.can_use(), "it is not ready again immediately")
	_expect(is_equal_approx(ability.cooldown_left(), 2.0),
		"releasing charges the whole cooldown")
	_expect(not ability.press(), "and pressing it again does nothing")
	ability.tick(1.5)
	_expect(not ability.can_use(), "it is still cooling down part way through")
	ability.tick(0.6)
	_expect(ability.can_use(), "it is ready once the cooldown runs out")


func _check_gating() -> void:
	var wet := GatedAbility.new()
	wet.configure(_player, 0, "laser_eyes", {})
	_player._lava_state = {"depth": 0.6}
	_expect(_player.submerged_share() > 0.0, "the body reads as submerged")
	_expect(not wet.can_use(), "an underwater ability refuses to start")
	_expect(not wet.press(), "and pressing it does nothing")
	_player._lava_state = {}
	_expect(wet.can_use(), "it works again out of the water")

	var grounded := GroundAbility.new()
	grounded.configure(_player, 1, "meteor_punch", {})
	_player._apply_stance(OnlinePlayer.Stance.SWIM)
	_expect(not grounded.can_use(), "a stance-gated ability refuses a swim")
	_player._apply_stance(OnlinePlayer.Stance.FLY)
	_expect(grounded.can_use(), "and allows a flight")
	# Cancelling rather than releasing is the path a player leaving the world
	# takes, and it must not leave a cooldown behind on an ability nobody owns.
	grounded.press()
	grounded.cancel()
	_expect(is_equal_approx(grounded.cooldown_left(), 0.0),
		"cancelling charges no cooldown")
	_player._apply_stance(OnlinePlayer.Stance.STAND)


## The slot plumbing: filling an ability slot builds the right ability, and the
## mouse button reaches it.
func _check_controller() -> void:
	var controller := _player.ability_controller()
	_expect(controller != null, "a local player has an ability controller")
	if controller == null:
		return
	_player.abilities.set_item(0, "hero_punch")
	_expect(controller.ability_in(0) is HeroPunch,
		"the controller builds the authored Hero Punch implementation")
	_player.abilities.set_item(0, "laser_eyes")
	_expect(controller.ability_in(0) is LaserEyes,
		"filling a slot builds that ability")
	_player.abilities.set_item(1, "meteor_punch")
	_expect(controller.ability_in(1) is MeteorPunch,
		"the second slot builds its own")
	_player.abilities.set_item(0, "")
	_expect(controller.ability_in(0) == null,
		"emptying a slot takes the ability away")
	_expect(controller.ability_in(1) is MeteorPunch,
		"and leaves the other slot alone")
	_player.abilities.clear()


func _check_host_cast_authority() -> void:
	var saved_launchers := _player.one_time_ability_records(
		"settlement_launcher")
	_player.one_time_abilities.erase("settlement_launcher")
	_player.ability_progress = {"laser_eyes": 1, "starfire": 1}
	var all_unlocked := true
	for id: String in ItemDB.reusable_ability_ids():
		all_unlocked = all_unlocked and _player.ability_unlocked(id)
	_expect(all_unlocked,
		"every reusable ability is currently unlocked at level one")
	_expect(not _player.ability_unlocked("settlement_launcher"),
		"an unowned one-time ability is not manufactured by the unlock policy")
	_player.abilities.set_item(0, "laser_eyes")
	_expect(_player._host_can_cast_ability("laser_eyes"),
		"host accepts an unlocked equipped ability")
	_expect(not _player._host_can_cast_ability("starfire"),
		"host rejects an unlocked but unequipped ability")
	_player.abilities.set_item(0, "starfire")
	_expect(_player._host_can_cast_ability("starfire")
		and not _player._host_can_cast_ability("nuke"),
		"host still rejects unlocked abilities outside the authoritative loadout")
	_player.ability_stat_progress.clear()
	var base_speed := float(ItemDB.stats_of("starfire").get("speed", 0.0))
	_expect(_player.authoritative_ability_stat_upgrade("starfire", "speed")
		and _player.authoritative_ability_stat_upgrade("starfire", "speed")
		and _player.ability_stat_level("starfire", "speed") == 2
		and is_equal_approx(
			float(_player.ability_stats("starfire").get("speed", 0.0)),
			base_speed * 1.2)
		and not _player.authoritative_ability_stat_upgrade(
			"settlement_launcher", "speed"),
		"host authoritatively trains only unlocked reusable ability stats")
	var live_ability := _player.ability_controller().ability_in(0)
	_expect(live_ability != null and is_equal_approx(
			float(live_ability.stats.get("speed", 0.0)), base_speed * 1.2),
		"training refreshes an equipped ability immediately")
	var trained_projectile := AbilityProjectile.launch(
		self, _player, "starfire", Vector3.ZERO, Vector3.FORWARD, false)
	_expect(trained_projectile != null and is_equal_approx(
			trained_projectile._speed,
			float(_player.ability_stats("starfire").get("speed", 0.0))),
		"launched projectiles use the trained runtime speed")
	if trained_projectile != null:
		trained_projectile.queue_free()
	_player.abilities.clear()
	_expect(_player.authoritative_grant_one_time_ability(
		"settlement_launcher", {
			"parent_site": "landing",
			"title": "First Settlement of Colony Ship",
		}) and _player.authoritative_grant_one_time_ability(
			"settlement_launcher", {
				"parent_site": "ridge",
				"title": "First Settlement of Ridge City",
			})
		and _player.one_time_ability_count("settlement_launcher") == 2
		and _player.abilities.find("settlement_launcher") < 0,
		"repeat one-time grants queue in inventory without auto-equipping")
	_expect(not _player.equip_ability("settlement_launcher", 0)
		and _player.equip_ability("building", 0)
		and _player._host_can_cast_ability("building")
		and not _player._host_can_cast_ability("settlement_launcher")
		and _player.one_time_ability_title("settlement_launcher")
			== "First Settlement of Colony Ship",
		"Building is the equipped authority while launch records stay inventory-only")
	_expect(_player.authoritative_consume_one_time_ability(
		"settlement_launcher", "parent_site", "ridge")
		and _player.one_time_ability_count("settlement_launcher") == 1
		and _player.abilities.get_item(0) == "building"
		and _player.one_time_ability_title("settlement_launcher")
			== "First Settlement of Colony Ship",
		"one successful use consumes the selected parent-city launcher")
	_expect(_player.authoritative_consume_one_time_ability(
		"settlement_launcher", "parent_site", "landing")
		and not _player.owns_one_time_ability("settlement_launcher")
		and _player.abilities.get_item(0) == "building",
		"the last successful use removes inventory while preserving Building")
	_player.one_time_abilities.erase("settlement_launcher")
	if not saved_launchers.is_empty():
		_player.one_time_abilities["settlement_launcher"] = \
			saved_launchers.duplicate(true)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("ability_model_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("ability_model_test: FAIL  %s" % message)
