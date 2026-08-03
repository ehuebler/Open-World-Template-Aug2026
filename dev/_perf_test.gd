extends Node

## Where the frame time goes, at the places in the world that cost the most.
##
##     & $godot --path . dev/_perf_test.tscn
##     & $godot --path . dev/_perf_test.tscn -- --noshadow --nooutline --draw=unshaded
##     & $godot --path . dev/_perf_test.tscn -- --distance
##
## Runs the real `world.tscn` with the real player, parks it at a series of
## vantage points, and reports the settled frame time at each along with what the
## renderer and the LOD were doing to earn it. **Vsync is off and the frame rate
## is uncapped**, because a capped 60 says nothing about how much headroom is
## left for the towns and water still to come.
##
## Flags peel one suspect off at a time, which is the only way to attribute cost
## honestly: `--noshadow` drops the sun's shadow map, `--nooutline` strips the
## outline pass off the terrain, `--noclouds` hides the cloud deck, which is the
## one thing here that is marched per pixel and so the one whose cost is all fill
## rate, `--draw=unshaded` takes the surface shader out of the picture, and
## `--near=` moves the LOD's collision range.
##
## `--distance` runs one stop at every level of [constant Planet.DETAIL_LEVELS]
## instead of the usual sweep, which is what the render distance setting is priced
## from. It reads at low air looking out: standing on the ground almost nothing is
## far enough away for the level to matter, and from orbit nothing is near enough,
## so either would price the setting at nothing.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

## Long enough for the LOD to settle. Counted in seconds rather than frames
## because the quadtree is walked on a clock now, so a fixed number of frames at
## 400 fps is a handful of LOD passes and nowhere near converged.
const SETTLE_SECONDS := 8.0
const SAMPLE_FRAMES := 180

## Ground speed and height of the moving pass. 200 m/s is close to what the
## flight model tops out at, and 80 m is low enough that the terrain under it is
## being built at full detail the whole way.
const TRAVERSE_SPEED := 200.0
const TRAVERSE_ALTITUDE := 80.0

## Where `--distance` prices the render distance: a name, an altitude and a pitch.
## Both are aimed so that the ground is the frame rather than the sky, since a
## level's whole effect is on ground it can barely be seen against otherwise.
const DISTANCE_STOPS: Array = [
	["air", 300.0, -0.32],
	["foot", 1.5, -0.06],
]

## Each stop is a name, an altitude in metres and whether to look out or down.
const STOPS: Array = [
	["orbit", 9000.0, true],
	["high air", 1800.0, false],
	["low air", 300.0, false],
	["treetop", 60.0, false],
	["standing", 1.5, true],
]

var _player: OnlinePlayer
var _planet: Planet
var _site: Node3D
var _sun: DirectionalLight3D
var _up := Vector3.UP
## Worst seen for each stage of the planet's update, by the key `statistics`
## reports it under.
var _parts := {"refine": 0.0, "dispatch": 0.0, "show": 0.0}
var _means := {
	"refine": 0.0, "dispatch": 0.0, "show": 0.0,
	"collision": 0.0, "apply": 0.0, "frame": 0.0,
}
var _worst_nodes := 0
var _worst_visible := 0


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	# The measurement is meaningless behind a vsync wait.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# Without a state the world opens its home screen instead of spawning
	# anybody, and there is no player here to park at the vantage points.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	add_child(WORLD.instantiate())
	# The world does not spawn anybody on the frame it is added: the roster is
	# walked from its own _ready, and the player arrives a frame or two later.
	for _frame in 30:
		await get_tree().process_frame
		_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
		if _player != null:
			break

	var scene := get_tree().current_scene
	_planet = scene.find_child("Planet", true, false) as Planet
	_site = scene.find_child("LandingSite", true, false) as Node3D
	_sun = scene.find_child("Sun", true, false) as DirectionalLight3D
	if _player == null or _planet == null or _site == null:
		push_error("perf_test: player=%s planet=%s site=%s" % [_player, _planet, _site])
		get_tree().quit(1)
		return
	_up = _site.global_basis.y
	_apply_flags()

	print("perf_test: %s, vsync off, %dx%d" % [
		RenderingServer.get_video_adapter_name(), 1600, 900])
	print("perf_test: %-18s %8s %8s %8s %7s %8s %7s %6s" % [
		"where", "fps", "frame", "worst", "lod", "tris", "draws", "bodies"])
	if "--distance" in OS.get_cmdline_user_args():
		await _distances()
		get_tree().quit()
		return
	for stop in STOPS:
		await _measure(str(stop[0]), float(stop[1]), bool(stop[2]))
	await _traverse()
	get_tree().quit()


## What each render distance costs, which is the only honest way to choose the
## scales in [constant Planet.DETAIL_LEVELS]: they are an area of ground held at
## each level of detail, so the triangle count goes up with the square of them and
## guessing lands an order of magnitude out.
func _distances() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	_check_wire()
	# Both vantages, because they disagree about which end of the ladder matters.
	# From the air the near ground dominates and a longer reach buys little for a
	# lot; on foot almost everything in frame is far away, which is the case a top
	# level has to earn its triangles in.
	for stop: Array in DISTANCE_STOPS:
		for level in Planet.DETAIL_LEVELS.size():
			_planet.detail_level = level
			var named: Dictionary = Planet.DETAIL_LEVELS[level]
			await _measure("%s %s %.1fx" % [stop[0], named["label"], named["scale"]],
				stop[1] as float, true, stop[2] as float)
			# The one setting in the menu whose whole point is what it looks like,
			# so the frame times are only half the answer. A level that costs more
			# and cannot be told apart from the one under it is not a level.
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
				"%sdistance_%s_%d.png" % [SHOT_DIR, stop[0], level])


## The case the parked stops cannot show. Standing still, the LOD has nothing to
## do and the thread pool is idle; crossing the ground at 200 m/s it is building,
## uploading and throwing away chunks continuously, and that is where a stutter
## would live. Reported as a distribution, because the mean is the one number
## guaranteed to hide it.
func _traverse() -> void:
	_park(TRAVERSE_ALTITUDE, true)
	await _settle()

	# Driven rather than flown. The flight model winds its speed up over seconds,
	# so a run that stutters flies slower and therefore stutters less — a
	# benchmark whose load depends on its own result cannot be compared with
	# anything, which is exactly what the first attempts at this did.
	var axis := _up.cross(_site.global_basis.z).normalized()
	var angle := 0.0
	var samples: Array[float] = []
	var built_before := int(_planet.statistics()["built"])
	var until := Time.get_ticks_msec() + 20000
	var worst_apply := 0.0
	var worst_collision := 0.0
	var worst_lod := 0.0
	while Time.get_ticks_msec() < until:
		var started := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - started) / 1000.0
		samples.append(spent)
		angle += TRAVERSE_SPEED * (spent / 1000.0) / _planet.shape.radius
		var direction := _up.rotated(axis, angle)
		_player.global_position = _planet.standing_position(direction, TRAVERSE_ALTITUDE)
		var stats := _planet.statistics()
		worst_apply = maxf(worst_apply, float(stats["apply_ms"]))
		worst_collision = maxf(worst_collision, float(stats["collision_ms"]))
		worst_lod = maxf(worst_lod, float(stats["frame_ms"]))
		for part in _parts:
			_parts[part] = maxf(float(_parts[part]), float(stats[part + "_ms"]))
			_means[part] = float(_means[part]) + float(stats[part + "_ms"])
		_means["collision"] = float(_means["collision"]) + float(stats["collision_ms"])
		_means["apply"] = float(_means["apply"]) + float(stats["apply_ms"])
		_means["frame"] = float(_means["frame"]) + float(stats["frame_ms"])
		_worst_nodes = maxi(_worst_nodes, int(stats["nodes"]))
		_worst_visible = maxi(_worst_visible, int(stats["visible"]))
	var top := TRAVERSE_SPEED

	samples.sort()
	var total := 0.0
	var dropped := 0
	for sample in samples:
		total += sample
		if sample > 16.7:
			dropped += 1
	var mean := total / float(samples.size())
	# Median as well as mean: one 200 ms hiccup from something outside the game
	# moves a mean of a thousand frames by a fifth of a millisecond per frame, and
	# the runs this is comparing differ by less than that.
	var median := samples[samples.size() / 2]
	print("perf_test: %-9s %8.1f %7.2fms  median %5.2fms  p99 %5.2fms  worst %5.2fms  built %d at %.0f m/s" % [
		"crossing", 1000.0 / maxf(median, 0.001), mean, median,
		samples[int(float(samples.size()) * 0.99)], samples[samples.size() - 1],
		int(_planet.statistics()["built"]) - built_before, top])
	print("perf_test: dropped frames  %d of %d over 16.7 ms" % [dropped, samples.size()])
	print("perf_test: planet update   worst %.2fms, of which colliders %.2fms and mesh upload %.2fms" % [
		worst_lod, worst_collision, worst_apply])
	print("perf_test: of which        refine %.2fms  dispatch %.2fms  show %.2fms" % [
		_parts["refine"], _parts["dispatch"], _parts["show"]])
	print("perf_test: tree            %d nodes at its largest, %d chunks drawn" % [
		_worst_nodes, _worst_visible])
	var count := float(samples.size())
	print("perf_test: mean planet     %.2fms = refine %.2f + dispatch %.2f + show %.2f + collide %.2f + apply %.2f" % [
		float(_means["frame"]) / count, float(_means["refine"]) / count,
		float(_means["dispatch"]) / count, float(_means["show"]) / count,
		float(_means["collision"]) / count, float(_means["apply"]) / count])
	print("perf_test: unaccounted     %.2fms of the %.2fms frame is outside the planet" % [
		mean - float(_means["frame"]) / count, mean])


## Parks the player and reports what the frame costs there. Frame time is taken
## as a distribution rather than an average: a mean of 8 ms with a worst of 40 is
## a stutter, and a mean on its own cannot tell the two apart.
func _measure(where: String, altitude: float, outward: bool, aim := INF) -> void:
	_park(altitude, outward, aim)
	await _settle()

	var total := 0.0
	var worst := 0.0
	var lod := 0.0
	var triangles := 0
	var draws := 0
	var bodies := 0
	for frame in SAMPLE_FRAMES:
		var started := Time.get_ticks_usec()
		await get_tree().process_frame
		var spent := float(Time.get_ticks_usec() - started) / 1000.0
		total += spent
		worst = maxf(worst, spent)
		var stats := _planet.statistics()
		lod += float(stats["update_ms"])
		triangles = maxi(triangles, int(stats["triangles"]))
		bodies = maxi(bodies, int(stats["bodies"]))
		draws = maxi(draws, int(Performance.get_monitor(
			Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	var mean := total / float(SAMPLE_FRAMES)
	print("perf_test: %-18s %8.1f %7.2fms %7.2fms %6.2fms %8s %7d %6d" % [
		where, 1000.0 / maxf(mean, 0.001), mean, worst, lod / float(SAMPLE_FRAMES),
		_thousands(triangles), draws, bodies])


## The wire the sweep below assumes, and the half of this feature the sweep cannot
## see: the menu writes an index into the settings, and the planet has to be
## following it. Left unchecked, a planet that never read the setting would sweep
## exactly as well as one that did, and the row in the menu would do nothing.
func _check_wire() -> void:
	var settings := get_node_or_null("/root/SettingsManager") as GameSettingsManager
	if settings == null:
		push_error("perf_test: no SettingsManager to write the render distance through")
		return
	var was := int(settings.get_setting(&"graphics", &"render_distance", 1))
	var wanted := Planet.DETAIL_LEVELS.size() - 1
	# Not saved: `set_setting` applies and announces, and writing settings.cfg is a
	# separate call. A benchmark should not leave the player on a new setting.
	settings.set_setting(&"graphics", &"render_distance", wanted)
	var took := _planet.detail_level
	settings.set_setting(&"graphics", &"render_distance", was)
	print("perf_test: settings wire   wrote %d, the planet went to %d, back to %d" % [
		wanted, took, _planet.detail_level])
	if took != wanted:
		push_error("perf_test: the planet is not following graphics/render_distance")


## Puts the player where the stop asks for, flying unless it is on the ground.
## [param aim] overrides the pitch, in radians, for a stop that wants neither of
## the two the flag offers.
func _park(altitude: float, outward: bool, aim := INF) -> void:
	_player.global_transform = Transform3D(
		_site.global_basis, _site.global_position + _up * altitude)
	_player.velocity = Vector3.ZERO
	if altitude > 3.0:
		_player.start_flying()
	# Looking out along the ground is the expensive view: it puts the whole
	# visible cap of the planet in shot instead of a few chunks underfoot.
	var pitch := (0.0 if outward else -0.9) if is_inf(aim) else aim
	_player.rotation = _player.rotation
	_player.camera.rotation.x = pitch


## Waits for the LOD to stop changing, or for the patience to run out. Settled
## means the tree has stopped growing, which is a better test than any fixed wait
## when the walk runs on its own clock.
func _settle() -> void:
	# Steadiness measured in seconds, not frames. Twenty frames at 800 fps is
	# twenty-five milliseconds, which every run cleared long before the LOD had
	# converged — and left each run starting from a different tree, which is why
	# the same code first measured anywhere between 37 and 94 fps.
	var deadline := Time.get_ticks_msec() + int(SETTLE_SECONDS * 1000.0)
	var was := -1
	var steady_since := Time.get_ticks_msec()
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var now := int(_planet.statistics()["visible"])
		if now != was:
			steady_since = Time.get_ticks_msec()
			was = now
		elif Time.get_ticks_msec() - steady_since > 750:
			return


func _apply_flags() -> void:
	var arguments := OS.get_cmdline_user_args()
	for argument in arguments:
		if argument == "--noshadow" and _sun != null:
			_sun.shadow_enabled = false
		elif argument == "--noclouds":
			var deck := _planet.find_child("Clouds", false, false) as MeshInstance3D
			if deck != null:
				deck.visible = false
		elif argument == "--nooutline":
			var material := _planet.SURFACE_MATERIAL as ShaderMaterial
			material.next_pass = null
		elif argument.begins_with("--draw="):
			var mode := argument.split("=")[1]
			var viewport := get_viewport()
			if mode == "unshaded":
				viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
			elif mode == "wireframe":
				viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
			elif mode == "overdraw":
				viewport.debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
		elif argument.begins_with("--near="):
			_planet.collision_range = float(argument.split("=")[1])
		elif argument.begins_with("--splits="):
			_planet.splits_per_frame = int(argument.split("=")[1])
		elif argument.begins_with("--bodies="):
			_planet.bodies_per_frame = int(argument.split("=")[1])
		elif argument.begins_with("--lodhz="):
			_planet.lod_updates_per_second = int(argument.split("=")[1])
		elif argument.begins_with("--pending="):
			_planet.pending_limit = int(argument.split("=")[1])


func _thousands(value: int) -> String:
	if value < 1000:
		return str(value)
	return "%.1fk" % (float(value) / 1000.0)
