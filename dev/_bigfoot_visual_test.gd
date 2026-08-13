extends Node

## Runtime visual regression for the first boss encounter.
##
##     godot --path . dev/_bigfoot_visual_test.tscn
##
## This deliberately uses the shipped world, boss GLB, local HUD, roar shell,
## parry shield, and skinned damage overlay together. Headless runs perform the
## structural half and skip frame capture because the dummy renderer never
## emits frame_post_draw.

const WORLD := preload("res://game/world.tscn")
const ROCK := preload("res://game/enemies/bigfoot/bigfoot_rock.gd")
const SHOT_DIR := "res://dev/captures/"
const STREAM_FRAMES := 180
## Four seconds to walk ten metres, which is generous: a crater wall costs him
## about a second and a quarter of the second and a bit that ten metres of open
## ground would.
const ESCAPE_FRAMES := 240

var _failures := 0
var _world: GameWorld
var _planet: Planet
var _boss: BigfootBoss
var _player: OnlinePlayer
var _camera: Camera3D


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players.clear()
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME

	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(10)
	_planet = _world.find_child("Planet", true, false) as Planet
	_boss = _world.find_child("Bigfoot", true, false) as BigfootBoss
	_player = get_tree().get_first_node_in_group(&"network_players") \
		as OnlinePlayer
	if not _expect(_planet != null and _boss != null and _player != null,
			"world contains the planet, Bigfoot, and local player"):
		_finish()
		return
	_expect(_boss.get_parent() is Landmark
		and (_boss.get_parent() as Landmark).waypoint,
		"runtime Bigfoot remains attached to its public waypoint landmark")

	_boss.set_physics_process(false)
	var animator := _boss.get_node_or_null(
		"Model/AnimationPlayer") as AnimationPlayer
	if animator == null:
		animator = _boss.find_child("AnimationPlayer", true, false) \
			as AnimationPlayer
	if animator != null:
		animator.active = false

	var up := _boss.global_basis.y.normalized()
	var forward := -_boss.global_basis.z.normalized()
	var facing := _boss.global_basis.rotated(up, PI)
	_player.global_transform = Transform3D(
		facing, _boss.global_position + forward * 7.0)
	_player.velocity = Vector3.ZERO
	_player.set_physics_process(false)
	_player.set_camera_mode(OnlinePlayer.CameraMode.THIRD_FAR)

	_boss.set("_engaged", true)
	_boss.set("_health", 650.0)
	_boss.health_changed.emit(650.0, _boss.maximum_health())
	_boss.engaged_changed.emit(true)
	_player.statuses.apply_status(CombatStatuses.FLIGHTLESS, 8.0)
	_player.combat_hud().refresh(1.0)

	_camera = Camera3D.new()
	_camera.name = "BigfootReviewCamera"
	_camera.fov = 48.0
	add_child(_camera)
	var right := _boss.global_basis.x.normalized()
	_camera.global_position = _boss.global_position \
		+ forward * 10.0 + right * 8.0 + up * 4.0
	_camera.look_at(_boss.global_position + forward * 2.7 + up * 1.5, up)
	_camera.current = true

	await _wait(STREAM_FRAMES)
	_player.combat_hud().refresh(1.0)
	var status_layer: StatusChipLayer = _player.combat_hud().status_layer()
	var flightless_chip := status_layer.find_child(
		"Chip_flightless", true, false) as Control if status_layer != null \
		else null
	var viewport_size := get_viewport().get_visible_rect().size
	_expect(flightless_chip != null
		and flightless_chip.global_position.x >= 0.0
		and flightless_chip.global_position.x + flightless_chip.size.x \
			<= viewport_size.x,
		"runtime HUD presents the Flightless dodo status chip")
	var waypoints := _player.find_child(
		"Waypoints", true, false) as WaypointLayer
	var toggle := InputEventKey.new()
	toggle.physical_keycode = 96 as Key
	toggle.pressed = true
	_player._unhandled_input(toggle)
	await _wait(3)
	_expect(waypoints != null and "Bigfoot" in waypoints.drawn(),
		"tilde draws the Bigfoot waypoint in the runtime HUD")
	if DisplayServer.get_name() == "headless":
		print("bigfoot_visual_test: structural checks passed; renderer skipped")
		_finish()
		return
	await _frame("bigfoot_runtime_waypoint")
	_player._unhandled_input(toggle)
	await _wait(3)

	var encounter := await _frame("bigfoot_runtime_encounter")
	_expect(_image_has_range(encounter),
		"encounter frame contains a lit runtime scene")

	var model := _boss.get_node_or_null("Model") as Node3D
	CombatantFlash.flash(model)
	await _wait(2)
	var damaged := await _frame("bigfoot_runtime_damage")
	_expect(_mean_difference(encounter, damaged) > 0.0004,
		"skinned red damage flash changes the rendered boss")
	_clear_damage_overlays(model)

	# The thrown stone is the jungle's own rock at a throwable size, so this
	# checks the mesh it is drawn from, that it kept its colour paint, and that
	# it actually reaches the frame.
	var rock := ROCK.new()
	if not rock.launch(_planet,
			_camera.global_position - _camera.global_basis.z * 1.7,
			Vector3.ZERO, _boss):
		rock.free()
		rock = null
	if rock != null:
		rock.set_physics_process(false)
	await _wait(2)
	var drawn: Array[Node] = rock.find_children("*", "MeshInstance3D", true,
		false) if rock != null else ([] as Array[Node])
	var stone := drawn[0] as MeshInstance3D if not drawn.is_empty() else null
	var paint := stone.material_override as ShaderMaterial if stone != null \
		else null
	_expect(stone != null and stone.mesh != null,
		"a thrown rock is drawn from the shipped biome stone mesh")
	_expect(paint != null
		and bool(paint.get_shader_parameter(&"color_paint_enabled"))
		and paint.get_shader_parameter(&"color_paint") != null,
		"the thrown rock keeps its species colour paint")
	if stone != null:
		var across := stone.mesh.get_aabb().size * stone.scale
		_expect(across.y > 0.2 and across.y < 0.5,
			"the thrown rock is about basketball sized")
	var thrown := await _frame("bigfoot_runtime_rock")
	_expect(_mean_difference(encounter, thrown) > 0.002,
		"the thrown rock reaches the frame it is supposed to be in")
	# And again at the distance it is actually thrown from, where the paint has
	# to hold up small and mipped rather than filling the screen.
	if rock != null:
		rock.global_position = _boss.global_position + up * 2.4 \
			+ _boss.global_basis.x * 1.6
	await _wait(2)
	var sailing := await _frame("bigfoot_runtime_rock_far")
	_expect(_mean_difference(encounter, sailing) > 0.0004,
		"the thrown rock still reads at the range it crosses")
	if rock != null:
		rock.free()
	await _wait(2)

	# The whole path in the shipped world rather than a staged prop: he lets one
	# go, it crosses the ground under gravity, and it lands on somebody.
	var health_before := _player.stats.health()
	_boss.set("_target_peer", _player.peer_id)
	_boss.call(&"_hurl_rock", _player)
	var struck := false
	for _step in 90:
		await get_tree().physics_frame
		if _player.stats.health() < health_before:
			struck = true
			break
	_expect(struck, "a thrown rock crosses the world and lands on the player")
	_player.stats.set_health(health_before)

	# The real OnlinePlayer attachment path, not the lightweight boss-suite
	# stand-in. It has to reach the hand and place the torso there, because an
	# attached body with its feet on the socket reads in play as another miss.
	var before_grab := _player.global_transform
	_player.global_position = _boss.global_position \
		+ _boss.global_basis.x.normalized() * 2.2
	_player.stats.set_health(health_before)
	_boss.set("_target_peer", _player.peer_id)
	_boss.call(&"_update_bone_markers")
	_boss.call(&"_start_attack", &"grab")
	_boss.set("_attack_left", BigfootBoss.GRAB_DURATION \
		+ BigfootBoss.THROW_DURATION - BigfootBoss.GRAB_CONNECT)
	_boss.call(&"_tick_grab_throw", 0.0, _player)
	_player.call(&"_follow_grab_socket")
	var socket := _boss.get_node_or_null("GrabSocket") as Marker3D
	_expect(_player.is_grabbed() and socket != null
		and _player.combat_position().distance_to(socket.global_position) < 0.1,
		"the shipped player is visibly held in Bigfoot's animated hand")
	_boss.call(&"_release_grabbed")
	_boss.set("_attack", &"")
	_player.global_transform = before_grab
	_player.velocity = Vector3.ZERO
	_player.stats.set_health(health_before)

	# The corridor he leaves through the undergrowth, and the jungle standing
	# again once the encounter resets. Counted rather than eyeballed: what falls
	# is scattered cover, and a screenshot of a jungle with some of it missing
	# looks much like a screenshot of a jungle.
	var broken_before := _cover_broken()
	var walk := _boss.global_basis.x.normalized()
	var stood := _boss.global_transform
	_boss.set("_trample_from", Vector3.INF)
	for stride in 12:
		_boss.global_position = stood.origin \
			+ walk * (float(stride) * BigfootBoss.TRAMPLE_STRIDE)
		_boss.set("_trample_left", 0.0)
		_boss.call(&"_trample", 1.0)
	_boss.global_transform = stood
	var flattened := _cover_broken()
	_expect(flattened > broken_before,
		"he leaves a corridor through the undergrowth (%d plants down)"
			% [flattened - broken_before])
	_boss.call(&"_regrow_arena")
	_expect(_pending_breaks() == 0,
		"reset discards break notices from the encounter it just restored")
	await _wait(STREAM_FRAMES)
	_expect(_cover_broken() < flattened,
		"and the arena grows back when the encounter resets")

	var trench_before := _cover_broken()
	var trench_from := stood.origin + up * 0.5
	var trench_to := trench_from + walk * 18.0
	_boss.call(&"_cut_flora", trench_from, trench_to)
	var trench_after := _cover_broken()
	_expect(trench_after > trench_before,
		"the meteor travel trench uproots real streamed grass (%d plants down)"
			% [trench_after - trench_before])
	_boss.call(&"_regrow_arena")
	_expect(_pending_breaks() == 0,
		"restoring a travel trench also clears its pending break notices")
	await _wait(STREAM_FRAMES)

	# The landing, which is the one thing he does that takes the ground away
	# from under whatever is growing on it. Shot from the lip of the hole,
	# because the failure this guards against is not a plant that survived —
	# it is a plant left standing in mid-air where the surface used to be, and
	# no count of broken instances can tell you that happened.
	var intact := _cover_broken()
	_boss.set("_meteor_along", walk)
	_boss.set("_meteor_landed", false)
	_boss.call(&"_update_bone_markers")
	var fist := _boss.get_node_or_null("RightFist") as Marker3D
	var crater := fist.global_position if fist != null else _boss.global_position
	var survived := _player.stats.health()
	var watching_from := _player.global_transform
	_boss.call(&"_land_meteor", _player)
	_player.stats.set_health(survived)
	_player.global_transform = watching_from
	_player.velocity = Vector3.ZERO
	var uprooted := _cover_broken()
	_expect(uprooted > intact,
		"the landing takes the jungle inside it with the ground (%d plants down)"
			% [uprooted - intact])
	var camera_was := _camera.global_transform
	_camera.global_position = crater + walk * 15.0 + up * 5.0
	_camera.look_at(crater - up * BigfootBoss.METEOR_CRATER_DEPTH, up)
	await _wait(STREAM_FRAMES)
	var hole := await _frame("bigfoot_runtime_crater")
	_expect(_image_has_range(hole), "the crater is rendered rather than blank")
	_camera.global_transform = camera_was
	await _climbs_out(crater, walk)
	_boss.call(&"_regrow_arena")
	_expect(_pending_breaks() == 0,
		"crater flora cannot be re-broken by a stale network confirmation")
	await _wait(STREAM_FRAMES)

	# The player's version cuts the cone/bowl through a separate flora-only
	# volume. This is the screenshot case as well as the routing regression:
	# the wide actor blast must not be the tapered thing deciding which roots
	# remain over terrain that no longer exists.
	var hero_before := _cover_broken()
	var hero_at := _ground_under(crater + walk * 24.0)
	var hero_stood := _player.global_transform
	_player.set("_meteor_stats", ItemDB.stats_of("meteor_punch"))
	_player.set("_meteor_along", walk)
	_player.call(&"_land_meteor", hero_at, true, 200.0)
	var hero_after := _cover_broken()
	_expect(hero_after > hero_before,
		"a player meteor crater uproots the streamed flora over its whole footprint")
	_player.global_transform = hero_stood
	_player.call(&"_apply_stance", OnlinePlayer.Stance.STAND)
	_player.velocity = Vector3.ZERO
	_boss.call(&"_regrow_arena")
	_expect(_pending_breaks() == 0,
		"restoring the player crater also leaves no stale break confirmation")
	await _wait(STREAM_FRAMES)

	# What losing to him actually looks like, from the shipped kill path: the
	# notice is written from the boss node itself, so a rename there is a rename
	# on this screen.
	var stood_at := _player.global_transform
	var full_health := _player.stats.health()
	var killing_blow := DamageHit.impact(_player.combat_position(), 3.0,
		full_health + 100.0)
	killing_blow.faction = DamageHit.Faction.ENEMY
	killing_blow.target_peer = _player.peer_id
	killing_blow.ability_id = "bigfoot_meteor"
	killing_blow.set_source(_boss)
	# Killed off the ground on purpose. The screen takes the player's controls
	# with it, and a body that stopped simulating when they went would hang in
	# the air at head height for as long as it was left there.
	_player.set_physics_process(true)
	_player.global_position = stood_at.origin + up * 6.0
	var fell_from := _player.global_position
	_player.apply_damage(killing_blow)
	for _step in 150:
		await get_tree().physics_frame
	_expect(not _player.controls_enabled
		and (fell_from - _player.global_position).dot(up) > 4.0,
		"the corpse comes down under a screen that has taken the controls")
	_player.set_physics_process(false)
	_player.global_transform = stood_at
	await _wait(4)
	var screen := _player.death_screen()
	_expect(screen != null
		and screen.notice_text() \
			== "Killed by %s: Meteor Punch" % BigfootBoss.DISPLAY_NAME,
		"losing to him says who and which attack caused it: %s" % [
			screen.notice_text() if screen != null else "no screen"])
	# Shot with the button live, which is the state it spends all but its first
	# second in. Waited out in frames because the arming is in seconds and this
	# scene does not run at a fixed rate.
	var respawn := screen.respawn_button() if screen != null else null
	for _step in 240:
		if respawn != null and not respawn.disabled:
			break
		await get_tree().process_frame
	_expect(respawn != null and not respawn.disabled,
		"and offers a respawn once it has finished arriving")
	var died_frame := await _frame("bigfoot_runtime_death")
	_expect(_mean_difference(encounter, died_frame) > 0.01,
		"the death screen covers the encounter it interrupted")
	if respawn != null:
		respawn.pressed.emit()
	await _wait(4)
	_expect(not _player.is_dead() and _player.death_screen() == null,
		"pressing it puts the player back on their feet")
	_player.global_transform = stood_at
	_player.velocity = Vector3.ZERO
	_player.stats.set_health(full_health)
	await _wait(4)

	if animator != null and animator.has_animation("Roar"):
		animator.active = true
		animator.play("Roar")
		animator.advance(0.55)
		animator.active = false
	_boss.call(&"_update_bone_markers")
	var mouth := _boss.get_node_or_null("Mouth") as Marker3D
	var wave := _boss.get_node_or_null("RoarWave") as BigfootRoarWave
	if wave != null and mouth != null:
		wave.set_wave(mouth.global_position, 8.0)
	# Freeze the presentation after the HUD baseline is drawn so the player's
	# normal physics refresh cannot clear this deliberately staged parry state.
	_player.process_mode = Node.PROCESS_MODE_DISABLED
	var shield := _player.find_child("ParryShield", true, false) \
		as ParryShield
	if shield != null:
		shield.set_state(true, true, 1.0)
	_expect(shield != null and shield.get("_material") != null,
		"runtime player owns a render-ready parry shield")
	await _wait(2)
	var parry := await _frame("bigfoot_runtime_roar_parry")
	_expect(wave != null and is_equal_approx(wave.scale.x, 8.0),
		"roar shell's visible radius matches its authoritative front")
	_expect(shield != null and shield.visible,
		"perfect-parry shield is visible around the runtime player")
	_expect(_mean_difference(encounter, parry) > 0.0008,
		"Roar and perfect parry materially change the encounter frame")

	print("bigfoot_visual_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	_finish()


## Whether he can leave the hole he has just dug, walked out on his own legs
## over real physics frames against the collider the crater actually built.
##
## Nothing a screenshot could show, and it is here rather than in the headless
## suite because it needs a chunk with a collision mesh on it. The failure it
## guards against is a boss at a dead sprint who does not move: the inside of a
## crater bowl is the sharpest curve in the encounter, a collision mesh crosses
## it on flat chords that stand a quarter of a metre proud of the height field,
## and the guard that keeps him on the surface used to set him to the field
## regardless — a quarter of a metre inside the wall, every tick, with the next
## frame spent being pushed back out of it. He would reach the rim of his own
## crater and run there.
##
## Driven in a straight line rather than left to pick a heading, because what is
## under test is his legs and not his judgement.
func _climbs_out(centre: Vector3, walk: Vector3) -> void:
	var stood := _boss.global_transform
	var carried := _boss.velocity
	_boss.global_position = _ground_under(centre)
	_boss.velocity = Vector3.ZERO
	_boss.set("_ground_speed", 0.0)
	_boss.set("_blocked", 0.0)
	var clear := BigfootBoss.METEOR_CRATER_RADIUS + 1.5
	var climbed := -1
	for step in ESCAPE_FRAMES:
		_boss.call(&"_travel", -walk, BigfootBoss.CHASE_SPEED,
			get_physics_process_delta_time(), 4.0)
		_boss.call(&"_snap_to_ground")
		await get_tree().physics_frame
		if _flat_gap(_boss.global_position, centre) > clear:
			climbed = step
			break
	_expect(climbed >= 0, "he climbs out of the crater he digs (%s)"
		% ["%d frames" % climbed if climbed >= 0
			else "still %.1f m from the middle after %d"
				% [_flat_gap(_boss.global_position, centre), ESCAPE_FRAMES]])
	_boss.global_transform = stood
	_boss.velocity = carried


func _ground_under(near: Vector3) -> Vector3:
	var out := _planet.to_local(near).normalized()
	return _planet.to_global(out * (_planet.shape.radius
		+ _planet.shape.elevation(out, _planet.finest_spacing())))


func _flat_gap(from: Vector3, to: Vector3) -> float:
	var up := _planet.up_at(to)
	var offset := from - to
	return (offset - up * offset.dot(up)).length()


## Plants every field currently calls broken. A destroyed instance is scaled to
## nothing rather than removed, so the submitted count never moves and the
## field's own ledger is the only honest tally.
func _cover_broken() -> int:
	var down := 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		down += (field.call(&"broken_keys") as PackedInt32Array).size()
	return down


func _pending_breaks() -> int:
	var down := 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		down += (field.call(&"drain_new_breaks") as PackedInt32Array).size()
	return down


func _clear_damage_overlays(root: Node) -> void:
	if root == null:
		return
	for node: Node in root.find_children(
			"DamageFlashOverlay", "MeshInstance3D", true, false):
		node.free()


func _image_has_range(image: Image) -> bool:
	if image == null or image.is_empty():
		return false
	var darkest := 1.0
	var brightest := 0.0
	for y in range(0, image.get_height(), 8):
		for x in range(0, image.get_width(), 8):
			var level := image.get_pixel(x, y).get_luminance()
			darkest = minf(darkest, level)
			brightest = maxf(brightest, level)
	return brightest - darkest > 0.15


func _mean_difference(before: Image, after: Image) -> float:
	if before == null or after == null or before.is_empty() or after.is_empty() \
			or before.get_size() != after.get_size():
		return 0.0
	var changed := 0.0
	var samples := 0
	for y in range(0, before.get_height(), 4):
		for x in range(0, before.get_width(), 4):
			var delta := before.get_pixel(x, y) - after.get_pixel(x, y)
			changed += (absf(delta.r) + absf(delta.g) + absf(delta.b)) / 3.0
			samples += 1
	return changed / maxf(float(samples), 1.0)


func _frame(shot_name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(
		SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	_expect(error == OK, "saved %s.png" % shot_name)
	return image


func _wait(frames: int) -> void:
	for _frame_index in frames:
		await get_tree().process_frame


func _expect(condition: bool, message: String) -> bool:
	if condition:
		print("bigfoot_visual_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("bigfoot_visual_test: FAIL  %s" % message)
	return false


func _finish() -> void:
	get_tree().quit(1 if _failures > 0 else 0)
