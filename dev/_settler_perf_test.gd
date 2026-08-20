extends Node

## Replays a real named sandbox save as a performance benchmark.
##
##     godot --path . dev/_settler_perf_test.tscn -- --save=Lag --seconds=30
##     godot --path . dev/_settler_perf_test.tscn -- --save=Lag --seconds=30 --night
##     godot --path . dev/_settler_perf_test.tscn -- --resolution=1920x1080 --vsync
##     godot --path . dev/_settler_perf_test.tscn -- --cities=50 --ledger-only
##     godot --path . dev/_settler_perf_test.tscn -- --save=ER4 --in-crowd
##
## --in-crowd starts in the middle of the save's largest settlement rather than
## wherever the player happened to save, which is what makes the run comparable to
## an exported window from somebody playing. See [method _stand_in_the_crowd].
## --arrive additionally sends every settlement cold at the moment measuring
## begins, so the cost of walking back into one is inside the window rather than
## finished before it. See [method _send_the_cities_cold].
##
## --cities=N scatters N unwatched [MeepCityLedger] towns over the whole planet, which
## is the population a save cannot describe: the towns in a real save are the ones
## somebody walked to, all in one place. --ledger-only additionally distills the saved
## towns, so what is left on the frame is the planet rather than the street.
##
## The run starts from the exact saved player transform, freezes the saved
## daylight (or moves it half an orbit for --night), lets streaming settle, then
## holds the ordinary move_forward action for wall-clock time. Wall-clock
## duration matters here: 1,800 frames at 15 FPS would silently turn the
## requested 30-second benchmark into two minutes.
##
## Graphics come from the player's own settings.cfg, because [GameSettingsManager]
## is an autoload and has already applied it before this scene loads: the harness
## therefore renders the same pixels the reported framerate came from, MSAA and
## render scale included. Only the frame pacing is overridden, so that a measured
## 8 ms frame is not filed as 60 FPS; pass --vsync to leave even that alone.
## --resolution pins the window so a number belongs to a resolution rather than
## to whichever monitor happened to run it.
##
## Baseline on save Lag at --resolution=1920x1080, which the desktop's 150% scale
## turns into 2,736x1,539 shaded pixels, six colonies, 953 rows and 574 alive:
##
##     day             32.1 FPS  mean 31.12 ms  p99 108.26  worst 408.82
##     night           27.8 FPS  mean 36.00 ms  p99 142.57  worst 304.14
##     day --no-meeps  54.9 FPS  mean 18.22 ms  p99  35.04  worst  39.68
##
## GPU was 7.2-7.8 ms throughout, so none of this is fill rate: the settlements
## cost about 13 ms of CPU per frame and own every spike, and the world without
## them still only reaches 55 FPS.
##
## After the planet-scale work, same save and resolution, 947 rows and 568 alive:
##
##     day                  44.8 FPS  mean 22.34 ms  p99 90.05  worst 288.66
##     night                45.8 FPS  mean 21.83 ms  p99 77.54  worst 246.47
##     day --cities=50      43.7 FPS  mean 22.90 ms  p99 91.33  worst 290.11
##
## Two of those say more than the framerate does. Night is no longer the expensive
## half of the day — it was 5 FPS down and is now level, because what made it cost
## more was never the lamps but the work that happened to land on the same frames.
## And the last line carries 10,573 settlers planet-wide for a fifth of a millisecond,
## which is the point of the whole exercise: what costs a frame is the town you are
## standing in, not the planet.
##
## What is left is the tail. A 22 ms mean against a 288 ms worst frame is a smooth
## run interrupted, not a slow one, and the remaining spikes belong to terrain
## rebuilds rather than to settlers. Run-to-run spread on one configuration is about
## a tenth, so read these as the order rather than the number.

const WORLD := preload("res://game/world.tscn")
## Metres above the sampled ground the crowd start drops the player from. Enough to
## clear a raised street or a dock deck without being a fall worth measuring.
const PLAYER_DROP_METRES := 3.0

var _options: Dictionary
var _world: GameWorld
var _player: OnlinePlayer
var _planet: Planet


func _ready() -> void:
	_options = _arguments()
	_configure_display()
	await get_tree().process_frame
	await _run()


func _configure_display() -> void:
	var wanted := String(_options.get("resolution", ""))
	var parts := wanted.split("x")
	if parts.size() == 2:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(int(parts[0]), int(parts[1])))
	if bool(_options.get("fullscreen", false)):
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	if _options.has("render_scale"):
		get_tree().root.scaling_3d_scale = float(_options["render_scale"])
	_uncap()


## Frees the frame rate unless the run asked to keep the player's own pacing.
##
## Called again after streaming settles because loading a world touches enough
## of the settings that the cap can come back.
func _uncap() -> void:
	if bool(_options.get("vsync", false)):
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0


func _run() -> void:
	if bool(_options.get("no_deep_trace", false)):
		RuntimeTelemetry.set_deep_enabled(false)
	if _options.has("physics_steps"):
		Engine.max_physics_steps_per_frame = maxi(
			int(_options["physics_steps"]), 1)
	if _options.has("physics_hz"):
		Engine.physics_ticks_per_second = maxi(int(_options["physics_hz"]), 1)
	var wanted_name := String(_options.get("save", "Lag"))
	var save_id := _save_id_named(wanted_name)
	print("settler_perf: user data %s" % OS.get_user_data_dir())
	if save_id.is_empty():
		var names := PackedStringArray()
		for row: Dictionary in SaveManager.list_saves("sandbox"):
			names.append(String(row.get("name", "")))
		push_error("settler_perf: save '%s' not found; sandbox saves are %s"
			% [wanted_name, names])
		get_tree().quit(1)
		return

	_configure_session(save_id)
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	var opened := await _wait_for_world(25.0)
	if not opened:
		push_error("settler_perf: the saved world did not finish opening")
		get_tree().quit(1)
		return

	_planet = _world.planet()
	_freeze_light()
	_populate_planet()
	if bool(_options.get("in_crowd", false)) \
			or bool(_options.get("arrive", false)):
		_stand_in_the_crowd()
	_apply_isolations()
	var settle_seconds := maxf(float(_options.get("settle", 8.0)), 0.0)
	await _wait_wall(settle_seconds)
	_uncap()
	_report_scene()
	if bool(_options.get("price_fields", false)):
		_price_route_fields()
		get_tree().quit()
		return
	if bool(_options.get("price_surfaces", false)):
		_price_surface_scans()
		get_tree().quit()
		return
	if bool(_options.get("price_meeps", false)):
		await _price_meep_stages()
		get_tree().quit()
		return

	var viewport_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	await _wait_wall(1.0)
	if bool(_options.get("arrive", false)):
		_send_the_cities_cold()
	var trace_meeps := bool(_options.get("trace_meeps", false))
	_set_meep_profiling(trace_meeps)
	var seconds := maxf(float(_options.get("seconds", 30.0)), 0.5)
	var sample := await _measure_forward(seconds, viewport_rid)
	_report_sample(sample)
	if trace_meeps:
		_report_meep_profiles()
	get_tree().quit()


func _save_id_named(wanted_name: String) -> String:
	for row: Dictionary in SaveManager.list_saves("sandbox"):
		if String(row.get("name", "")).nocasecmp_to(wanted_name) == 0:
			return String(row.get("id", ""))
	return ""


func _configure_session(save_id: String) -> void:
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.session_options = {
		"mode": "sandbox",
		"name": "Settler Performance",
		"max_players": 1,
		"save_id": save_id,
	}
	NetworkManager.players = {
		1: {
			"peer_id": 1,
			"name": "Benchmark",
			"body": CharacterDB.DEFAULT_BODY,
			"skin": "",
			"worn": {},
			"tints": {},
		},
	}
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _wait_for_world(timeout_seconds: float) -> bool:
	var began := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - began) / 1000.0 < timeout_seconds:
		_player = _world.local_player()
		var colonies := _world.meep_colonies()
		if _player != null and colonies != null \
				and not colonies.colonies().is_empty():
			var ready := true
			for colony: MeepColony in colonies.colonies():
				ready = ready and bool(colony.get("_ground_ready"))
			if ready:
				return true
		await get_tree().process_frame
	return false


## Moves the player to the middle of the most populous settlement in the save.
##
## A save records where somebody happened to stop, which is usually on the way
## somewhere: opening one and walking forward from it had thirty settlers on
## screen, while the exported window from the session that prompted this work had
## three hundred. Ten times the crowd is not a detail of the measurement, it is
## the measurement — every per-settler cost in the frame scales with what is
## presented, and the framerate a player complains about is the one they get
## standing in their own city.
func _stand_in_the_crowd() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null or _player == null or _planet == null:
		return
	var busiest: MeepColony = null
	for colony: MeepColony in colonies.colonies():
		if busiest == null or colony.alive_count() > busiest.alive_count():
			busiest = colony
	if busiest == null or busiest.site == null:
		return
	var ground := busiest.site.ground_at(
		Vector2.ZERO, _planet.shape, _planet.finest_spacing())
	# Above the surface rather than on it, so the body settles onto the terrain
	# instead of starting inside a street the colony has raised.
	var stood := _planet.to_global(
		ground + ground.normalized() * PLAYER_DROP_METRES)
	_player.global_position = stood
	_player.velocity = Vector3.ZERO
	print("settler_perf: standing in %s, %d alive"
		% [busiest.site_id, busiest.alive_count()])


## Distills every settlement to a ledger just before measuring, so the residency
## machine has to build them all back while the frame is being watched.
##
## The harness otherwise waits for every colony to report ready before it starts
## timing, which excludes the one thing the exported windows from real sessions
## blame most: arriving. Rebuilding a town's navigation grid, boundary flood,
## plan and settler rows is the largest single piece of work the game does, and a
## player meets it by walking towards their own city.
func _send_the_cities_cold() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	var sites: Array[StringName] = []
	for colony: MeepColony in colonies.colonies():
		sites.append(colony.site_id)
	for site in sites:
		colonies.distill(site)
	print("settler_perf: sent %d settlement(s) cold before measuring"
		% sites.size())


func _freeze_light() -> void:
	var cycle := _world.celestial_cycle
	if cycle == null:
		return
	cycle.period_seconds = 0.0
	if bool(_options.get("night", false)):
		cycle.set_phase(cycle.phase() + 0.5)
	else:
		cycle.set_phase(cycle.phase())


## Fills the rest of the planet with unwatched cities, and optionally turns the saved
## ones into unwatched cities too.
##
## `--cities=N` is what the save cannot provide: a real save has the towns somebody
## actually founded, all within walking distance of each other, and the question this
## framework exists to answer is what fifty of them scattered over a planet cost.
## `--ledger-only` then removes the agent simulation from the picture entirely, which
## is the difference between measuring the ledgers and measuring the town underfoot.
func _populate_planet() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	if bool(_options.get("ledger_only", false)):
		for colony: MeepColony in colonies.colonies():
			colonies.distill(colony.site_id)
	var wanted := int(_options.get("cities", 0))
	if wanted <= 0:
		return
	var planted: Array = []
	for index in wanted:
		var ledger := MeepCityLedger.new()
		ledger.site_id = StringName("perf_city_%d" % index)
		# Spread by the Fibonacci lattice, so the towns are over the whole planet
		# rather than in a belt, and none of them lands on the saved ones.
		var height := 1.0 - 2.0 * (float(index) + 0.5) / float(wanted)
		var ring := sqrt(maxf(1.0 - height * height, 0.0))
		var turn := float(index) * PI * (3.0 - sqrt(5.0))
		ledger.direction = Vector3(
			cos(turn) * ring, height, sin(turn) * ring).normalized()
		ledger.facing = float(index) * 7.0
		ledger.founded_seed = 0x5CA1E ^ index
		ledger.display_name = "Perf City %d" % index
		ledger.alive = maxi(int(_options.get("city_population", 200)), 1)
		ledger.tier = 1
		ledger.resources = 400.0
		ledger.housing_capacity = ledger.alive
		ledger.residential_slots = ledger.alive
		ledger.claim_radius = 120.0
		var entry := ledger.to_dictionary()
		entry["snapshot_kind"] = "city_ledger"
		planted.append(entry)
	colonies.apply_snapshot(planted)
	print("settler_perf: planted %d ledger cities, planet population %d"
		% [wanted, colonies.planet_population()])


func _apply_isolations() -> void:
	var colonies := _world.meep_colonies()
	if colonies != null:
		for colony: MeepColony in colonies.colonies():
			if bool(_options.get("no_meep_sim", false)) \
					or bool(_options.get("no_meeps", false)):
				colony.set_physics_process(false)
			if bool(_options.get("no_meep_planning", false)):
				colony.set("_plan_left", INF)
			if bool(_options.get("no_meep_maintenance", false)):
				colony.set("_road_clear_left", INF)
				colony.set("_structure_clear_left", INF)
			if bool(_options.get("no_meep_present", false)) \
					or bool(_options.get("no_meeps", false)):
				colony.set_process(false)
			if bool(_options.get("no_meep_render", false)):
				var render := colony.get("_render") as MultiMeshInstance3D
				if render != null:
					render.visible = false
			if bool(_options.get("no_meeps", false)):
				colony.visible = false
			if bool(_options.get("no_city_render", false)):
				if colony.structures != null:
					colony.structures.visible = false
				if colony.roads != null:
					colony.roads.visible = false
	if bool(_options.get("no_shadows", false)):
		for light: Light3D in _lights_under(self):
			light.shadow_enabled = false
	if bool(_options.get("no_omni", false)):
		for light: Light3D in _lights_under(self):
			if light is OmniLight3D:
				light.light_cull_mask = 0


func _measure_forward(seconds: float, viewport_rid: RID) -> Dictionary:
	var frames: Array[float] = []
	var process_ms := 0.0
	var physics_ms := 0.0
	var gpu_ms := 0.0
	var render_cpu_ms := 0.0
	var draws := 0.0
	var objects := 0.0
	var primitives := 0.0
	var active_bodies := 0.0
	var collision_pairs := 0.0
	var islands := 0.0
	var began := Time.get_ticks_usec()
	var previous := began
	# Standing still leaves the towns, mobs, and flora running while nothing new
	# streams in, which separates a cost that belongs to the world from one that
	# belongs to walking into unseen ground.
	var walking := not bool(_options.get("still", false))
	if walking:
		Input.action_press("move_forward")
	while float(Time.get_ticks_usec() - began) / 1000000.0 < seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - previous) / 1000.0)
		previous = now
		process_ms += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics_ms += (
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		gpu_ms += RenderingServer.viewport_get_measured_render_time_gpu(
			viewport_rid)
		render_cpu_ms += RenderingServer.viewport_get_measured_render_time_cpu(
			viewport_rid)
		draws += Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objects += Performance.get_monitor(
			Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		primitives += Performance.get_monitor(
			Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		active_bodies += Performance.get_monitor(
			Performance.PHYSICS_3D_ACTIVE_OBJECTS)
		collision_pairs += Performance.get_monitor(
			Performance.PHYSICS_3D_COLLISION_PAIRS)
		islands += Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)
	if walking:
		Input.action_release("move_forward")
	var elapsed := float(Time.get_ticks_usec() - began) / 1000000.0
	var ranked := frames.duplicate()
	ranked.sort()
	var count := maxf(float(frames.size()), 1.0)
	var total := 0.0
	for frame in frames:
		total += frame
	return {
		"elapsed": elapsed,
		"frames": frames.size(),
		"fps": count / maxf(elapsed, 0.001),
		"mean": total / count,
		"median": _percentile(ranked, 0.5),
		"p95": _percentile(ranked, 0.95),
		"p99": _percentile(ranked, 0.99),
		"worst": ranked.back() if not ranked.is_empty() else 0.0,
		"process": process_ms / count,
		"physics": physics_ms / count,
		"gpu": gpu_ms / count,
		"render_cpu": render_cpu_ms / count,
		"draws": draws / count,
		"objects": objects / count,
		"primitives": primitives / count,
		"active_bodies": active_bodies / count,
		"collision_pairs": collision_pairs / count,
		"islands": islands / count,
	}


func _report_sample(sample: Dictionary) -> void:
	var phase_name := "night" if bool(_options.get("night", false)) else "day"
	var display := _display_summary()
	print(("settler_perf: RESULT %s %s  %.2f s  %d frames  %.1f FPS  "
		+ "frame mean %.2f ms median %.2f p95 %.2f p99 %.2f worst %.2f")
		% [phase_name, _display_tag(display), sample["elapsed"],
			sample["frames"], sample["fps"], sample["mean"], sample["median"],
			sample["p95"], sample["p99"], sample["worst"]])
	print(("settler_perf: CPU process %.2f ms physics %.2f ms  "
		+ "render CPU %.2f ms GPU %.2f ms")
		% [sample["process"], sample["physics"], sample["render_cpu"],
			sample["gpu"]])
	print("settler_perf: render %.0f draws  %.0f objects  %.0f primitives/frame"
		% [sample["draws"], sample["objects"], sample["primitives"]])
	print(("settler_perf: physics %.0f active bodies  %.0f collision pairs  "
		+ "%.0f islands")
		% [sample["active_bodies"], sample["collision_pairs"],
			sample["islands"]])
	_report_attribution()
	if _planet != null:
		print("settler_perf: planet %s" % _planet.statistics())


## The recorder's own division of the frame, printed here so that a benchmark run
## and a player's exported capture are read the same way.
func _report_attribution() -> void:
	var snapshot := RuntimeTelemetry.latest_snapshot()
	var budget := snapshot.get("frame_budget", {}) as Dictionary
	var per_frame := budget.get("per_frame_ms", {}) as Dictionary
	if per_frame.is_empty():
		return
	print(("settler_perf: frame %.2f ms = script %.2f + physics %.2f "
		+ "+ engine %.2f (deferred %.2f, free %.2f, draw %.2f, wait %.2f)"
		+ "  (traced %.2f, unnamed %.2f = %.2f process + %.2f physics)")
		% [
			float(per_frame.get("wall", 0.0)),
			float(per_frame.get("script_process", 0.0)),
			float(per_frame.get("script_physics", 0.0)),
			float(per_frame.get("engine", 0.0)),
			float(per_frame.get("deferred", 0.0)),
			float(per_frame.get("scene_flush", 0.0)),
			float(per_frame.get("render_draw", 0.0)),
			float(per_frame.get("engine_gap", 0.0)),
			float(per_frame.get("traced", 0.0)),
			float(per_frame.get("untraced_script", 0.0)),
			float(per_frame.get("process_untraced", 0.0)),
			float(per_frame.get("physics_untraced", 0.0)),
		])
	var scene := snapshot.get("scene", {}) as Dictionary
	var census := scene.get("processing_census", []) as Array
	var busiest := PackedStringArray()
	for index in mini(census.size(), 10):
		var row := census[index] as Dictionary
		busiest.append("%s %dp/%df" % [
			String(row.get("script", "?")),
			int(row.get("process", 0)),
			int(row.get("physics", 0)),
		])
	print("settler_perf: callbacks %d process / %d physics — %s"
		% [
			int(scene.get("processing_nodes", 0)),
			int(scene.get("physics_processing_nodes", 0)),
			", ".join(busiest),
		])
	var activity := snapshot.get("activity", []) as Array
	for index in mini(activity.size(), 12):
		var row := activity[index] as Dictionary
		print("settler_perf: traced %-34s %7.2f ms  max %6.2f  %d calls"
			% [
				"%s/%s" % [row.get("category", ""), row.get("label", "")],
				float(row.get("total_ms", 0.0)),
				float(row.get("max_ms", 0.0)),
				int(row.get("calls", 0)),
			])
	if bool(_options.get("export_log", false)):
		print("settler_perf: exported %s"
			% RuntimeTelemetry.export_last_window().get("path", "nothing"))


func _report_scene() -> void:
	var rows := 0
	var alive := 0
	var visible := 0
	var structures := 0
	var road_cells := 0
	var lamps := 0
	var active_lights := 0
	var colonies := _world.meep_colonies()
	if colonies != null:
		for colony: MeepColony in colonies.colonies():
			rows += colony.count()
			alive += colony.alive_count()
			var render := colony.get("_render") as MultiMeshInstance3D
			if render != null and render.multimesh != null:
				visible += render.multimesh.visible_instance_count
			if colony.structures != null:
				structures += colony.structures.count()
			if colony.roads != null:
				road_cells += colony.roads.cell_count()
				lamps += colony.roads.lamp_count()
				active_lights += colony.roads.active_light_count()
	var light_total := 0
	var omni_total := 0
	var visible_omni := 0
	for light: Light3D in _lights_under(self):
		light_total += 1
		if light is OmniLight3D:
			omni_total += 1
			if light.visible and light.light_energy > 0.001:
				visible_omni += 1
	print(("settler_perf: scene rows=%d alive=%d visible=%d structures=%d "
		+ "road_cells=%d lamps=%d street_lights=%d")
		% [rows, alive, visible, structures, road_cells, lamps, active_lights])
	print("settler_perf: lights total=%d omni=%d active_omni=%d phase=%.4f"
		% [light_total, omni_total, visible_omni,
			_world.celestial_cycle.phase()])
	print("settler_perf: display %s" % _display_summary())


## What the frame is actually being asked to draw, in the terms the settings menu
## uses.
##
## `get_visible_rect()` is deliberately not the source for the resolution: the
## project stretches on `canvas_items`, so the root viewport carries a size
## override at the 1280x720 design size and reports that no matter how many
## pixels the window really has. The render target is the honest figure, and
## `scaling_3d_scale` then says how much of it the 3D pass fills.
func _display_summary() -> Dictionary:
	var root := get_tree().root
	var target := root.get_texture()
	var render_size: Vector2i = DisplayServer.window_get_size()
	if target != null:
		render_size = target.get_size()
	var scale := root.scaling_3d_scale
	var quality := ["off", "2x", "4x", "8x"]
	var shadows := "n/a"
	var glow := "n/a"
	var cycle: CelestialCycle = null
	if _world != null:
		cycle = _world.celestial_cycle
	if cycle != null:
		if cycle.sun != null:
			shadows = "on" if cycle.sun.shadow_enabled else "off"
		var holder := cycle.world_environment
		if holder != null and holder.environment != null:
			glow = "on" if holder.environment.glow_enabled else "off"
	return {
		"window": DisplayServer.window_get_size(),
		"render": render_size,
		"shaded": Vector2i(roundi(float(render_size.x) * scale),
			roundi(float(render_size.y) * scale)),
		"render_scale": scale,
		"msaa": quality[clampi(int(root.msaa_3d), 0, 3)],
		"detail": Planet.DETAIL_LEVELS[clampi(
			_planet.detail_level if _planet != null else 1,
			0, Planet.DETAIL_LEVELS.size() - 1)]["label"],
		"flora_range": PlantSpecies.view_range,
		"shadows": shadows,
		"glow": glow,
		"god_rays": SettingsManager.get_setting(&"graphics", &"god_rays", true),
		"vsync": DisplayServer.window_get_vsync_mode() \
			!= DisplayServer.VSYNC_DISABLED,
		"max_fps": Engine.max_fps,
	}


func _display_tag(display: Dictionary) -> String:
	var shaded := display["shaded"] as Vector2i
	return "%dx%d@%.2f %s detail=%s flora=%.1f shadows=%s glow=%s%s" % [
		shaded.x, shaded.y, display["render_scale"], display["msaa"],
		display["detail"], display["flora_range"], display["shadows"],
		display["glow"], " vsync" if bool(display["vsync"]) else ""]


func _set_meep_profiling(enabled: bool) -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	for colony: MeepColony in colonies.colonies():
		colony.set_performance_profiling(enabled)


func _price_surface_scans() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	for colony: MeepColony in colonies.colonies():
		colony.set_physics_process(false)
		var bridge := _call_ms(
			colony.roads, &"next_surface_candidate", [true, false])
		var coast := _call_ms(
			colony.roads, &"next_surface_candidate", [false, true])
		var both := _call_ms(
			colony.roads, &"next_surface_candidate", [true, true])
		print("settler_perf: surfaces %s bridge=%.3f coast=%.3f both=%.3f ms"
			% [colony.site_id, bridge, coast, both])


func _price_route_fields() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	for colony: MeepColony in colonies.colonies():
		colony.set_physics_process(false)
		var samples: Array[float] = []
		var reached := 0
		for _sample in 3:
			var field := MeepFlowField.new()
			var began := Time.get_ticks_usec()
			field.build(colony.grid, colony.claim.origin)
			samples.push_back(float(Time.get_ticks_usec() - began) / 1000.0)
			reached = field.reached
		print("settler_perf: fields %s samples=%s reached=%d"
			% [colony.site_id, samples, reached])


func _report_meep_profiles() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	for colony: MeepColony in colonies.colonies():
		print("settler_perf: profile %s %s"
			% [colony.site_id, colony.performance_profile()])


func _price_meep_stages() -> void:
	var colonies := _world.meep_colonies()
	if colonies == null:
		return
	for colony: MeepColony in colonies.colonies():
		colony.set_physics_process(false)
	await get_tree().process_frame
	for colony: MeepColony in colonies.colonies():
		var state_counts := PackedInt32Array()
		state_counts.resize(MeepColony.State.size())
		for state in colony.get("_state") as PackedByteArray:
			if state >= 0 and state < state_counts.size():
				state_counts[state] += 1
		var detail_counts := PackedInt32Array()
		detail_counts.resize(MeepColony.Detail.size())
		for detail in colony.get("_detail") as PackedByteArray:
			if detail >= 0 and detail < detail_counts.size():
				detail_counts[detail] += 1
		var stages := {
			"life": 0.0,
			"eyes": 0.0,
			"grade": 0.0,
			"crowd": 0.0,
			"residents": 0.0,
		}
		var passes := 12
		for _pass in passes:
			stages["life"] += _call_ms(
				colony, &"_advance_life_clocks", [0.1])
			stages["eyes"] += _call_ms(colony, &"_refresh_eyes")
			stages["grade"] += _call_ms(colony, &"_grade")
			stages["crowd"] += _call_ms(colony, &"_rebuild_crowd_index")
			stages["residents"] += _call_ms(
				colony, &"_advance_residents", [0.1])
		print(("settler_perf: colony %s rows=%d alive=%d states=%s detail=%s "
			+ "per tick life=%.3f eyes=%.3f grade=%.3f crowd=%.3f residents=%.3f ms")
			% [colony.site_id, colony.count(), colony.alive_count(),
				state_counts, detail_counts,
				float(stages["life"]) / passes,
				float(stages["eyes"]) / passes,
				float(stages["grade"]) / passes,
				float(stages["crowd"]) / passes,
				float(stages["residents"]) / passes])
		var planning := {}
		for method: StringName in [
				&"_plan_mining", &"_plan_surfaces", &"_plan_commissioned",
				&"_plan_dock_hut", &"_plan_roads", &"_plan_vertical_upgrade",
				&"_plan_building", &"_plan_cloning",
				&"_refresh_current_tier_completion"]:
			planning[String(method)] = _call_ms(colony, method)
		print("settler_perf: colony %s planning %s"
			% [colony.site_id, planning])
		print(("settler_perf: colony %s maintenance roads=%.3f "
			+ "structures=%.3f collect=%.3f ms")
			% [colony.site_id,
				_call_ms(colony, &"_maintain_roads"),
				_call_ms(colony, &"_maintain_structures"),
				_call_ms(colony, &"_collect_fields")])


func _call_ms(target: Object, method: StringName,
		arguments: Array = []) -> float:
	var began := Time.get_ticks_usec()
	target.callv(method, arguments)
	return float(Time.get_ticks_usec() - began) / 1000.0


func _lights_under(root: Node) -> Array[Light3D]:
	var found: Array[Light3D] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is Light3D:
			found.append(node as Light3D)
		for child: Node in node.get_children(true):
			pending.append(child)
	return found


func _wait_wall(seconds: float) -> void:
	var began := Time.get_ticks_msec()
	while float(Time.get_ticks_msec() - began) / 1000.0 < seconds:
		await get_tree().process_frame


func _percentile(ranked: Array[float], share: float) -> float:
	if ranked.is_empty():
		return 0.0
	return ranked[clampi(
		roundi(float(ranked.size() - 1) * share), 0, ranked.size() - 1)]


func _arguments() -> Dictionary:
	var parsed := {}
	for argument in OS.get_cmdline_user_args():
		var text := String(argument).trim_prefix("--")
		var split := text.split("=", true, 1)
		parsed[split[0].replace("-", "_")] = (
			split[1] if split.size() > 1 else true)
	return parsed
