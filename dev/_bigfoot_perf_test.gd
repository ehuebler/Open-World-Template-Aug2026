extends Node

## What the boss costs per frame, measured against the shipped world.
##
##     godot --headless --path . dev/_bigfoot_perf_test.tscn
##
## Three passes over the same loaded world: the boss switched off, the boss
## patrolling, and the boss in a fight with a player standing in his arena. The
## difference between the first and the last is his whole cost, script and
## physics and animation together, which is the number worth watching. Headless
## measures CPU only; the renderer's share is what the graphical run of
## dev/_bigfoot_visual_test.tscn is for.
##
## Run it without --headless as well, and believe that run over this one for
## anything he does to the jungle. Headless grows a few hundred plants where a
## session with a renderer carries tens of thousands, and it has no render
## thread to wait for — the two together understated a charge through cover by
## a factor of fifty, and the budgets below were all met for months by a run
## that was not touching a jungle at all.

const WORLD := preload("res://game/world.tscn")
const SETTLE_FRAMES := 150
const SETTLE_LIMIT := 3000
const SETTLE_QUIET := 90
const SAMPLE_FRAMES := 240
## He is a single character in a world already streaming terrain and flora, so
## anything approaching a millisecond of frame time is him misbehaving rather
## than him being expensive.
const BUDGET_MS := 0.75
## The two halves of a meteor impact, which are the only single frames in this
## fight that ever cost real time. Ceilings rather than targets: the flatten was
## 296 ms when this was written and both are worth catching if they climb back.
const FLATTEN_BUDGET_MS := 90.0
const CRATER_BUDGET_MS := 60.0
## Stricter than either, because a charge pays it several times over on its way
## in: one tick that costs a frame on its own is a stutter through the whole
## run-up rather than a single hitch. Under a renderer it was 16 ms of waiting
## on the render thread and is 7 ms of work; headless it has always read as
## half a millisecond, which is the number that let it sit at 16.
const SWEEP_BUDGET_MS := 14.0
## Walking through cover is not an ability and is never over, so what it costs is
## measured as a share of an ordinary frame rather than as a single stall, and
## held to a fraction of what he is allowed in total.
const TRAMPLE_STRIDES := 8
const TRAMPLE_BUDGET_MS := 0.15
const TRAMPLE_STRIDE_BUDGET_MS := 3.0

var _failures := 0
var _world: GameWorld
var _boss: BigfootBoss
var _player: OnlinePlayer
var _animator: AnimationPlayer
var _stand := Transform3D.IDENTITY
var _no_meteor := false


func _ready() -> void:
	# Frame time is the measurement, so nothing may pace the loop.
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players.clear()
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME

	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	await _wait(10)
	_boss = _world.find_child("Bigfoot", true, false) as BigfootBoss
	_player = get_tree().get_first_node_in_group(&"network_players") \
		as OnlinePlayer
	if not _expect(_boss != null and _player != null,
			"world contains Bigfoot and the local player"):
		_finish()
		return
	_animator = _boss.find_child("AnimationPlayer", true, false) \
		as AnimationPlayer

	# Standing in the arena, at the range the fight is actually had at, and held
	# there: a player left to their own physics gets punched, thrown, killed and
	# respawned at the colony nine kilometres away, and the terrain that streams
	# in behind them dwarfs everything this is trying to measure.
	var up := _boss.global_basis.y.normalized()
	var forward := -_boss.global_basis.z.normalized()
	_stand = Transform3D(_boss.global_basis.rotated(up, PI),
		_boss.global_position + forward * 9.0)
	_player.set_physics_process(false)
	_hold_player()
	await _settle()

	# The world is still streaming terrain and flora for the first few seconds
	# and every measurement taken during that describes the streaming, not the
	# boss. One pass is thrown away, then each state is measured twice and the
	# pair averaged, so what drift is left falls on all of them equally.
	await _measure(true, true, false)
	var idle_a := await _measure(false, false, false)
	var patrol_a := await _measure(true, false, false)
	var fight_a := await _measure(true, true, false)
	var roar := await _measure(true, true, true)
	var meteor := await _meteor_pass()
	await _time_impact_halves()
	await _time_ground_sweep()
	await _time_trample()
	# The same fight with the meteor held back, to separate what melee costs
	# from what cutting a crater and sweeping a shock through the flora costs.
	_no_meteor = true
	var melee := await _measure(true, true, false)
	_no_meteor = false
	print("bigfoot_perf_test: melee only    %s" % _row(melee))
	var idle_b := await _measure(false, false, false)
	var patrol_b := await _measure(true, false, false)
	var fight_b := await _measure(true, true, false)
	var idle := _mean(idle_a, idle_b)
	var patrol := _mean(patrol_a, patrol_b)
	var fight := _mean(fight_a, fight_b)

	print("bigfoot_perf_test: boss off      %s" % _row(idle))
	print("bigfoot_perf_test: patrolling    %s" % _row(patrol))
	print("bigfoot_perf_test: in a fight    %s" % _row(fight))
	print("bigfoot_perf_test: mid-roar      %s" % _row(roar))
	print("bigfoot_perf_test: meteor impact %s" % _row(meteor))
	var patrol_cost := float(patrol["frame"]) - float(idle["frame"])
	var fight_cost := float(fight["frame"]) - float(idle["frame"])
	print("bigfoot_perf_test: roar shell    %.3f ms over an ordinary fight frame"
		% [float(roar["frame"]) - float(fight["frame"])])
	print("bigfoot_perf_test: his share     patrol %.3f ms, fight %.3f ms"
		% [patrol_cost, fight_cost])
	_expect(patrol_cost < BUDGET_MS,
		"patrolling costs under %.2f ms a frame" % BUDGET_MS)
	_expect(fight_cost < BUDGET_MS,
		"fighting costs under %.2f ms a frame" % BUDGET_MS)
	_expect(float(fight["worst"])
			< float(idle["worst"]) + FLATTEN_BUDGET_MS + CRATER_BUDGET_MS,
		"no single fight frame stalls the session")
	_expect(float(meteor["worst"])
			< float(idle["worst"]) + FLATTEN_BUDGET_MS + CRATER_BUDGET_MS,
		"a meteor from wind-up to crater does not lock the session up")
	_finish()


## The meteor impact taken apart: the blast that flattens whatever is standing in
## it, and the hole it leaves. Both are asked for in the same frame by
## BigfootBoss._land_meteor, so a stall there has to be attributed to one of them
## before anything is tuned.
func _time_impact_halves() -> void:
	# Off to one side of the ground the sampling passes have been fighting over,
	# because four staged meteors have already been through there and a landing
	# measured on the bare floor they left reported 325 plants where virgin
	# jungle carries forty thousand. Near enough to still be streamed at full
	# density around the player, far enough not to be second-hand.
	var at := _boss.global_position + _boss.global_basis.x.normalized() * 30.0
	# The landing's own volume, which uproots rather than scorches: what a break
	# costs and what a char costs are not the same, so measuring the tapered
	# player-damage version of this would be measuring the cheaper half.
	var blow := DamageHit.area(at, BigfootBoss.METEOR_FLATTEN,
		BigfootBoss.METEOR_FLATTEN_DAMAGE, 0.0)
	blow.faction = DamageHit.Faction.ENEMY
	blow.ability_id = "bigfoot_meteor"
	blow.plant_break_effects = false
	blow.set_source(_boss)
	var standing := _cover_broken()
	var began := Time.get_ticks_usec()
	DamageHit.apply_to_fields(_boss, blow)
	var blast := float(Time.get_ticks_usec() - began) / 1000.0
	# Reported alongside the time, because a cheap number here means nothing
	# unless the ground under the boss was actually carrying a jungle. Whether
	# the budget was met and whether the budget was tested are two questions.
	var felled := _cover_broken() - standing
	var after_blast := await _frame_cost(20)

	var planet := _world.find_child("Planet", true, false) as Planet
	var scar := TerrainScars.Scar.new()
	scar.direction = planet.to_local(at).normalized()
	scar.radius = BigfootBoss.METEOR_CRATER_RADIUS
	scar.depth = BigfootBoss.METEOR_CRATER_DEPTH
	scar.profile = TerrainScars.Profile.BOWL
	scar.char = 0.35
	began = Time.get_ticks_usec()
	_world.request_scar(scar)
	var cut := float(Time.get_ticks_usec() - began) / 1000.0
	var after_cut := await _frame_cost(20)

	print("bigfoot_perf_test: blast call %.1f ms over %d plants,"
		% [blast, felled]
		+ " then worst %.1f ms over 20 frames" % after_blast)
	# Which is worth reading before the millisecond count above it. Headless
	# streams a few hundred instances where a session with a renderer carries
	# seventeen thousand, so run that way this is a measurement of bare ground
	# and says nothing about what a landing in a jungle costs.
	if DisplayServer.get_name() == "headless":
		print("bigfoot_perf_test: %d plants is what headless grows;" % felled
			+ " the cost above is not the cost of a landing in cover")
	else:
		_expect(felled > 5000,
			"the landing was measured over standing jungle (%d plants)" % felled)
	print("bigfoot_perf_test: crater call %.1f ms, then worst %.1f ms over 20 frames"
		% [cut, after_cut])
	_expect(blast < FLATTEN_BUDGET_MS,
		"flattening the jungle under a landing stays under %d ms"
			% FLATTEN_BUDGET_MS)
	_expect(after_cut < CRATER_BUDGET_MS,
		"the ground rebuilt under a crater stays under %d ms" % CRATER_BUDGET_MS)
	await _settle()


## The charge rather than the landing. A meteor punch thrown along the ground
## pushes a capsule through the canopy twenty times a second for the whole run
## in, so unlike the crater this cost is paid on eight frames in a row — which is
## what a charge through cover feels like, as against a single stall.
##
## Swept sideways from where he stands, across jungle the passes above have not
## already knocked down.
func _time_ground_sweep() -> void:
	var along := _boss.global_basis.x.normalized()
	var step := BigfootBoss.METEOR_FLY_SPEED * BigfootBoss.METEOR_SWEEP_STEP \
		* float(BigfootBoss.METEOR_FLORA_EVERY)
	var from := _boss.global_position + _boss.global_basis.y * 1.6
	var ticks := int(BigfootBoss.METEOR_FLY_MAX * BigfootBoss.METEOR_SWEEP_HZ) \
		/ BigfootBoss.METEOR_FLORA_EVERY
	var worst := 0.0
	var total := 0.0
	for _tick in ticks:
		var to := from + along * step
		var beam := DamageHit.beam(from, to, BigfootBoss.METEOR_FLORA_RADIUS,
			BigfootBoss.METEOR_SWEEP_DAMAGE * BigfootBoss.METEOR_SWEEP_STEP
			* float(BigfootBoss.METEOR_FLORA_EVERY))
		beam.faction = DamageHit.Faction.ENEMY
		beam.ability_id = "bigfoot_meteor"
		beam.set_source(_boss)
		var began := Time.get_ticks_usec()
		DamageHit.apply_to_fields(_boss, beam)
		var cost := float(Time.get_ticks_usec() - began) / 1000.0
		worst = maxf(worst, cost)
		total += cost
		from = to
		await get_tree().process_frame
	var after := await _frame_cost(20)
	print("bigfoot_perf_test: ground sweep %d ticks, worst %.1f ms, total %.1f ms,"
		% [ticks, worst, total]
		+ " then worst %.1f ms over 20 frames" % after)
	_expect(worst < SWEEP_BUDGET_MS,
		"one tick of a meteor charge through jungle stays under %d ms"
			% SWEEP_BUDGET_MS)
	await _settle()


## The undergrowth he flattens simply by moving, which unlike a meteor is a cost
## he pays for the whole session rather than for eight frames of an ability. It
## is a narrower volume over a shorter stretch, and it has to stay far under one
## sweep of the charge or patrolling the jungle costs more than fighting in it.
func _time_trample() -> void:
	var along := _boss.global_basis.x.normalized()
	var at := _boss.global_position
	_boss.set("_trample_from", Vector3.INF)
	var worst := 0.0
	var total := 0.0
	for tick in TRAMPLE_STRIDES:
		_boss.global_position = at \
			+ along * (float(tick) * BigfootBoss.TRAMPLE_STRIDE)
		_boss.set("_trample_left", 0.0)
		var began := Time.get_ticks_usec()
		_boss.call(&"_trample", 1.0)
		var cost := float(Time.get_ticks_usec() - began) / 1000.0
		worst = maxf(worst, cost)
		total += cost
		await get_tree().process_frame
	_boss.global_position = at
	# What it comes to while he is actually running, which is the number that
	# matters: a sweep is earned by ground covered, so his speed sets the rate.
	var covered := float(TRAMPLE_STRIDES) * BigfootBoss.TRAMPLE_STRIDE
	var seconds := covered / BigfootBoss.CHASE_SPEED
	var per_frame := total / maxf(seconds, 0.001) / 60.0
	print("bigfoot_perf_test: trample %d strides, worst %.2f ms,"
		% [TRAMPLE_STRIDES, worst]
		+ " %.3f ms a frame at a chase" % per_frame)
	_expect(per_frame < TRAMPLE_BUDGET_MS,
		"flattening undergrowth while running costs under %.2f ms a frame"
			% TRAMPLE_BUDGET_MS)
	# And separately as a single frame, because an average hides a stride that
	# hitches: it was 13.7 ms before the volume learned to leave the lawn alone.
	_expect(worst < TRAMPLE_STRIDE_BUDGET_MS,
		"and no one stride costs %.1f ms" % TRAMPLE_STRIDE_BUDGET_MS)
	await _settle()


## Plants every field currently calls broken. A destroyed instance is scaled to
## nothing rather than removed, so the only honest tally is each field's ledger.
func _cover_broken() -> int:
	var down := 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		down += (field.call(&"broken_keys") as PackedInt32Array).size()
	return down


func _frame_cost(frames: int) -> float:
	var worst := 0.0
	var previous := Time.get_ticks_usec()
	for _frame in frames:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, float(now - previous) / 1000.0)
		previous = now
	return worst


func _hold_player() -> void:
	_player.global_transform = _stand
	_player.velocity = Vector3.ZERO
	_player.stats.set_health(_player.stats.base_of(PlayerStats.HEALTH))


## Waits until the planet has stopped building ground.
##
## Worth doing properly: a world that is still streaming spends tens of
## milliseconds a frame in physics building chunk colliders, and measuring the
## boss against that reads whatever the terrain happened to be doing. The first
## attempt at this test waited a fixed number of frames, blamed a 158 ms
## streaming stall on him patrolling, and nearly bought a fix for it.
func _settle() -> void:
	var planet := _world.find_child("Planet", true, false) as Planet
	if planet == null:
		await _wait(SETTLE_FRAMES)
		return
	var last := -1
	var quiet := 0
	for _frame in SETTLE_LIMIT:
		await get_tree().process_frame
		var stats: Dictionary = planet.call(&"statistics")
		var built := int(stats.get("built", 0))
		var waiting := int(stats.get("pending", 0)) + int(stats.get("requests", 0))
		if built == last and waiting == 0:
			quiet += 1
			if quiet >= SETTLE_QUIET:
				return
		else:
			quiet = 0
			last = built
	push_warning("bigfoot_perf_test: planet never went quiet; numbers are noisy")


## The frames either side of a meteor landing. The crater is the one thing in
## the fight that reaches outside him — it rewrites the height field and every
## ground chunk under it — so it is measured on its own rather than averaged
## into a pass it would dominate.
func _meteor_pass() -> Dictionary:
	_boss.set_physics_process(true)
	_boss.set_process(true)
	if _animator != null:
		_animator.active = true
	_boss.set("_engaged", true)
	_boss.call(&"_pick_target")
	await _wait(10)
	var began := Time.get_ticks_usec()
	var previous := began
	var worst := 0.0
	var physics := 0.0
	var process := 0.0
	for frame in SAMPLE_FRAMES:
		_hold_player()
		if frame == 10:
			# The whole move, not just the hole it leaves: the charge sweeps a
			# damage beam through every flora field twenty times a second on its
			# way in, which is the expensive half.
			_boss.set("_target_peer", _player.peer_id)
			_boss.call(&"_start_attack", &"meteor")
			_boss.set("_attack_left",
				_boss.call(&"_attack_duration", &"meteor")
				- BigfootBoss.METEOR_WINDUP)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, float(now - previous) / 1000.0)
		previous = now
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		process += Performance.get_monitor(Performance.TIME_PROCESS)
	return {
		"frame": float(Time.get_ticks_usec() - began)
			/ float(SAMPLE_FRAMES) / 1000.0,
		"physics": physics / float(SAMPLE_FRAMES) * 1000.0,
		"process": process / float(SAMPLE_FRAMES) * 1000.0,
		"worst": worst,
	}


## One pass with the boss in a given state, returning mean and worst frame times
## in milliseconds. Physics and idle process are read separately because a boss
## that is cheap on average and hitches once a second is not cheap.
func _measure(active: bool, engaged: bool, roaring: bool) -> Dictionary:
	_boss.set_physics_process(active)
	_boss.set_process(active)
	if _animator != null:
		_animator.active = active
	if active and engaged:
		_boss.set("_engaged", true)
		_boss.set("_phase", 1)
		_boss.call(&"_pick_target")
	else:
		_boss.call(&"_reset_arena")
		_boss.set("_engaged", false)
	if roaring:
		# Held at the widest the shell is ever drawn: the worst frame the roar
		# can ask the renderer for, with the party inside the sphere.
		_boss.call(&"_start_attack", &"roar")
		_boss.set("_roar_elapsed", BigfootBoss.ROAR_WAVE_END)
		_boss.set("_roar_radius", BigfootRoarWave.DRAW_LIMIT - 1.0)
	# Let the change take, let the first frame's one-off work fall outside the
	# window, and let any ground his last pass wandered into finish arriving.
	await _wait(20)
	await _settle()
	var began := Time.get_ticks_usec()
	var previous := began
	var worst := 0.0
	var physics := 0.0
	var process := 0.0
	for _frame in SAMPLE_FRAMES:
		_hold_player()
		if _no_meteor:
			var cooldowns: Dictionary = _boss.get("_cooldowns")
			cooldowns[&"meteor"] = 60.0
		if roaring:
			# Pinned open: the attack would otherwise run its 1.8 s and take the
			# shell with it a third of the way into the sample.
			_boss.set("_attack", &"roar")
			_boss.set("_attack_left", 1.0)
			_boss.set("_roar_elapsed", BigfootBoss.ROAR_WAVE_END)
			_boss.set("_roar_radius", BigfootRoarWave.DRAW_LIMIT - 1.0)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, float(now - previous) / 1000.0)
		previous = now
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		process += Performance.get_monitor(Performance.TIME_PROCESS)
	var sample := {
		"frame": float(Time.get_ticks_usec() - began)
			/ float(SAMPLE_FRAMES) / 1000.0,
		"physics": physics / float(SAMPLE_FRAMES) * 1000.0,
		"process": process / float(SAMPLE_FRAMES) * 1000.0,
		"worst": worst,
	}
	# Printed per pass as well as averaged, because an average hides which of
	# two identical passes was the one that stalled — and that is the difference
	# between a boss that is expensive and a world that was still streaming.
	print("bigfoot_perf_test:   pass on=%s fight=%s roar=%s %s  %s"
		% [active, engaged, roaring, _row(sample), _planet_load()])
	return sample


## What the planet was doing during a pass, so terrain streaming can be told
## apart from anything the boss is spending.
func _planet_load() -> String:
	var planet := _world.find_child("Planet", true, false) as Planet
	if planet == null:
		return ""
	var stats: Dictionary = planet.call(&"statistics")
	var viewer := planet.viewer
	return "planet %.2f ms, pending %s, requests %s, built %s, viewer %s at %.1f m, boss at %.1f m" % [
		float(stats.get("update_ms", 0.0)), stats.get("pending", "?"),
		stats.get("requests", "?"), stats.get("built", "?"),
		viewer.name if viewer != null else "camera",
		_player.global_position.distance_to(_boss.global_position),
		_boss.global_position.distance_to(
			(_boss.get("_spawn_transform") as Transform3D).origin)]


func _mean(first: Dictionary, second: Dictionary) -> Dictionary:
	var out := {}
	for key: Variant in first:
		if key == "worst":
			out[key] = maxf(float(first[key]), float(second[key]))
		else:
			out[key] = (float(first[key]) + float(second[key])) * 0.5
	return out


func _row(sample: Dictionary) -> String:
	return "frame %.3f ms  physics %.3f ms  process %.3f ms  worst %.2f ms" % [
		sample["frame"], sample["physics"], sample["process"], sample["worst"]]


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame


func _expect(condition: bool, message: String) -> bool:
	if condition:
		print("bigfoot_perf_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("bigfoot_perf_test: FAIL  %s" % message)
	return false


func _finish() -> void:
	if _failures == 0:
		print("bigfoot_perf_test: all checks passed")
	else:
		push_error("bigfoot_perf_test: %d check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
