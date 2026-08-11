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
	_check_stat_lines()
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

	_check_cooldown()
	_check_gating()
	_check_controller()
	_check_eye_points()

	_player.queue_free()
	await get_tree().process_frame
	print("ability_model_test: %s" % (
		"all checks passed" if _failures == 0 else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_catalogue() -> void:
	var ids := ItemDB.ability_ids()
	_expect(ids.has("laser_eyes") and ids.has("meteor_punch"),
		"both abilities are in the catalogue")
	for id: String in ["laser_eyes", "meteor_punch"]:
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
		var stats := ItemDB.stats_of(id)
		_expect(stats.has("damage") and stats.has("range")
			and stats.has("cooldown"),
			"%s quotes damage, range and cooldown" % id)


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
	_expect(ItemDB.stat_lines("sword").is_empty(),
		"an item with no stats gets no lines")


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


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("ability_model_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("ability_model_test: FAIL  %s" % message)
