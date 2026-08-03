extends Node

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"

# OnlinePlayer.Stance, which is private to the player and read here by index.
const STAND := 0
const SLIDE := 2
const FLY := 3

## Clear of the wardrobe, which stands on the landing site's origin, and facing
## back out of the site so a wind-up has open ground in front of it.
const RUN_START := Vector3(0.0, 0.4, 8.0)
const RUN_YAW := PI
## Off the site's centre for the same reason, for anything that only needs the
## character standing somewhere with room around it.
const CLEAR := Vector3(7.0, 0.4, 7.0)

var _player: OnlinePlayer
var _planet: Planet
## The landing site's frame, which every offset in this file is measured in. The
## world's origin is the planet's centre, 8 km underground, so a bare world
## coordinate puts the player in the core. Only good near the site: its up is a
## single direction, and the ground curves away from it by 16 m over 500 m.
var _ground := Transform3D.IDENTITY


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	# The world opens the home screen and spawns nobody while the session reads as
	# idle, so the state has to say "in game" before it comes up.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	var world := WORLD.instantiate()
	add_child(world)
	await _wait(10)
	_player = get_tree().get_first_node_in_group("network_players") as OnlinePlayer
	var site := world.find_child("LandingSite", true, false) as Node3D
	_planet = world.find_child("Planet", true, false) as Planet
	if _player == null or site == null or _planet == null:
		push_error("player_test: player=%s site=%s planet=%s" % [_player, site, _planet])
		get_tree().quit(1)
		return
	_ground = site.global_transform
	# The terrain builds on worker threads around whatever is looking at it, and
	# a player dropped onto a chunk that has no collider yet falls through the
	# planet. Everything here waits for the ground to exist first.
	await _wait(120)
	await _run()
	get_tree().quit()


func _run() -> void:
	var only: PackedStringArray = OS.get_cmdline_user_args()
	if "--sheet" in only:
		await _clip_report()
		await _clip_sheet()
		return
	if "--collision" in only:
		await _prop_checks()
		await _step_checks()
		return
	if "--flight" in only:
		await _flight_checks()
		await _flight_shots()
		return
	if "--run" in only:
		await _run_checks()
		return
	await _movement_checks()
	await _run_checks()
	await _flight_checks()
	await _flight_shots()
	# Props first: the kerb course is scenery the prop checks should not meet.
	await _prop_checks()
	await _step_checks()
	await _camera_shots()
	await _clip_report()
	await _clip_sheet()


## Kerbs of rising height walked into head-on. Anything up to the step limit
## should be climbed without stopping; anything above it should still block.
func _step_checks() -> void:
	var heights := [0.12, 0.22, 0.3, 0.36, 0.5]
	for index in heights.size():
		var height: float = heights[index]
		var base := Vector3(14.0, 0.0, -14.0 + index * 5.0)
		_add_kerb(base, height)
		await _place(base + Vector3(0.0, 0.4, 2.4), 0.0)
		await _wait(20)
		var floor_at := _altitude()
		Input.action_press("move_forward")
		var peak := 0.0
		var clips := {}
		# Short enough to stop on top of the kerb rather than cross it.
		for _i in 34:
			await get_tree().physics_frame
			peak = maxf(peak, _altitude() - floor_at)
			# A step that dropped ground contact would show up here as Fall.
			clips[_player._clip] = true
		Input.action_release("move_forward")
		await _wait(10)
		var risen := _altitude() - floor_at
		print("player_test: kerb %.2f  rise=%.3f  peak=%.3f  clips=%-16s climbed=%s" % [
			height, risen, peak, ",".join(clips.keys()),
			"yes" if risen > height - 0.08 else "no",
		])
		if is_equal_approx(height, 0.3):
			_player._camera_mode = 2
			await _wait(40)
			await _shot("kerb_step_up")
			_player._camera_mode = 0
			await _wait(20)


func _add_kerb(base: Vector3, height: float) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, height, 3.0)
	shape.shape = box
	body.add_child(shape)
	var visual := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box.size
	visual.mesh = box_mesh
	body.add_child(visual)
	get_tree().current_scene.add_child(body)
	# Standing on the site's ground and square to it, not to the world's axes,
	# which here run through the planet rather than along it.
	body.global_transform = _ground.translated_local(base + Vector3(0.0, height * 0.5, 0.0))


## Walks into every prop at the landing site head-on, then turns 55 degrees and
## keeps walking. That second leg is the tell: a player wedged against a prop
## stops moving entirely, while a clean contact slides them around it.
func _prop_checks() -> void:
	for prop in _site_props():
		# The site's frame, so the approach runs along its ground rather than
		# along a world axis that points into the sky here.
		var at := _ground.affine_inverse() * prop.global_position
		await _place(Vector3(at.x, 0.4, at.z + 4.0), 0.0)
		await _wait(20)
		Input.action_press("move_forward")
		var peak := 0.0
		for _i in 70:
			await get_tree().physics_frame
			peak = maxf(peak, _altitude())
		var contact := _player.global_position
		_player.global_basis = _player.global_basis.rotated(_player.global_basis.y, deg_to_rad(55.0))
		await _wait(60)
		Input.action_release("move_forward")
		print("player_test: prop %-9s stopped_at=%5.2f  rode_up=%.2f  alt=%5.2f  slid_around=%5.2f" % [
			prop.name,
			contact.distance_to(prop.global_position),
			peak, _altitude(), contact.distance_to(_player.global_position),
		])


## Everything standing on the landing site. The world used to be a flat floor
## with a `Props` node on it; on the planet the anchor is the only place a prop
## can be, so the anchor's children are the props.
func _site_props() -> Array[Node3D]:
	var found: Array[Node3D] = []
	var site := get_tree().current_scene.find_child("LandingSite", true, false)
	if site == null:
		return found
	for child in site.get_children():
		if child is Node3D:
			found.append(child as Node3D)
	return found


## Foot and hip heights sampled across each clip. The rest sole sits at bone
## height 0.103, so a grounded clip should hold its planted foot near that and
## never dip far below it.
func _clip_report() -> void:
	await _place(CLEAR, 0.0)
	await _wait(20)
	var animator: AnimationPlayer = _player.animator
	var skeleton: Skeleton3D = _player.character.find_child("Skeleton3D", true, false)
	var feet := [skeleton.find_bone("LeftFoot"), skeleton.find_bone("RightFoot")]
	var hips := skeleton.find_bone("Hips")
	for clip in animator.get_animation_list():
		var length := animator.get_animation(clip).length
		var lowest := [1.0e9, 1.0e9]
		var planted := [-1.0e9, -1.0e9]
		var hip_low := 1.0e9
		for step in 24:
			animator.play(clip, 0.0)
			animator.seek(length * step / 24.0, true)
			await get_tree().process_frame
			for i in 2:
				var y: float = skeleton.get_bone_global_pose(feet[i]).origin.y
				lowest[i] = minf(lowest[i], y)
				planted[i] = maxf(planted[i], y)
			hip_low = minf(hip_low, skeleton.get_bone_global_pose(hips).origin.y)
		print("player_test: %-11s foot_low=(%.3f, %.3f) foot_high=(%.3f, %.3f) hips_low=%.3f" % [
			clip, lowest[0], lowest[1], planted[0], planted[1], hip_low,
		])


## Freezes the rig at a few points in every baked clip, from a fixed side-on
## camera, so the poses can be judged without playing the game.
func _clip_sheet() -> void:
	await _place(CLEAR, 0.0)
	# Third person, so the player script keeps its own mesh visible.
	_player._camera_mode = 2
	await _wait(30)

	# Props out of the way, so anything coloured showing up on the character is
	# the character's own shading rather than scenery seen through it.
	for prop in _site_props():
		prop.visible = false

	# Parented to the player: the review positions below are body-relative, and
	# on a sphere the body's own frame is the only one they mean anything in.
	var review := Camera3D.new()
	_player.add_child(review)
	review.fov = 34.0
	review.position = Vector3(2.6, 0.8, -0.3)
	_aim(review, Vector3(0.0, 0.68, 0.0))
	review.current = true
	await _wait(2)

	var animator: AnimationPlayer = _player.animator
	print("player_test: clips %s" % [animator.get_animation_list()])
	for clip in animator.get_animation_list():
		var length := animator.get_animation(clip).length
		for step in 3:
			var at := length * (0.08 + 0.42 * step)
			animator.play(clip, 0.0)
			animator.seek(at, true)
			animator.speed_scale = 0.0
			await _shot("clip_%s_%d" % [clip, step])

	# Head-on as well, which is the view that shows how wide the arms are held.
	review.fov = 34.0
	review.position = Vector3(0.0, 0.8, -2.6)
	_aim(review, Vector3(0.0, 0.68, 0.0))
	for clip in ["Idle", "Walk", "Run", "CrouchIdle"]:
		var length := animator.get_animation(clip).length
		for step in 2:
			animator.play(clip, 0.0)
			animator.seek(length * (0.08 + 0.42 * step), true)
			await _shot("front_%s_%d" % [clip, step])

	review.fov = 30.0
	review.position = Vector3(1.15, 0.45, -0.25)
	_aim(review, Vector3(0.0, 0.44, 0.0))
	for clip in ["Run", "CrouchIdle", "Walk"]:
		animator.play(clip, 0.0)
		animator.seek(animator.get_animation(clip).length * 0.5, true)
		await _shot("hips_%s" % clip)
	animator.speed_scale = 1.0
	review.queue_free()
	for prop in _site_props():
		prop.visible = true


## Points a review camera at a spot in the player's own frame. Both halves of this
## are corrections for standing on a sphere, and each one on its own produced a
## sheet of unusable screenshots:
##
## - `look_at` takes a **world** point, and this world's origin is the planet's
##   centre 8 km underground. Aiming at a bare `Vector3(0, 0.68, 0)` — which is what
##   you write when the origin is the ground at the player's feet — pointed every
##   shot straight down into the core, and the whole sheet came out as the inside of
##   a hillside.
## - Its up hint defaults to **world** up, which anywhere but one point on the
##   planet is not the body's up. Left alone it rolled the head-on view by ninety
##   degrees and laid the character on its side.
func _aim(camera: Camera3D, at: Vector3) -> void:
	camera.look_at(_player.to_global(at), _player.global_basis.y)


func _movement_checks() -> void:
	await _place(Vector3(0.0, 0.4, 12.0), PI)
	_report("idle")

	Input.action_press("move_forward")
	await _wait(45)
	_report("walk")
	# Only as long as shift's step up to a sprint. Holding it winds the run on
	# past that, and past that there is not enough floor here to hold the run or
	# the slide it earns: `_run_checks` has the strip for it.
	Input.action_press("sprint")
	await _wait(10)
	_report("sprint")
	Input.action_release("sprint")

	Input.action_press("crouch")
	await _wait(5)
	_report("slide start")
	await _wait(35)
	_report("slide mid")
	await _wait(60)
	_report("slide over")
	Input.action_release("crouch")
	Input.action_release("move_forward")

	await _place(Vector3(0.0, 0.4, 12.0), PI)
	Input.action_press("crouch")
	Input.action_press("move_forward")
	await _wait(45)
	_report("crouch walk")
	Input.action_release("crouch")
	Input.action_release("move_forward")
	await _wait(20)
	_report("stood back up")

	await _place(Vector3(0.0, 0.4, 12.0), PI)
	await _wait(25)
	Input.action_press("jump")
	await _wait(3)
	Input.action_release("jump")
	await _wait(12)
	_report("jump rising")
	await _wait(70)
	_report("landed")

	# Pressed 4 frames before touchdown, which only becomes a jump if the input
	# buffer survived the airborne frames.
	await _place(Vector3(0.0, 0.55, 12.0), PI)
	await _wait(2)
	Input.action_press("jump")
	await _wait(3)
	Input.action_release("jump")
	await _wait(12)
	_report("buffered jump")
	await _wait(70)


## The wind-up, what survives letting go of shift, the skid when forward is
## released, what a wall does to it, and the slide and the jump it buys. Watch
## `run=`: that is the speed the legs are being asked for, and the gap between it
## and `speed=` is how far behind the body is running.
func _run_checks() -> void:
	# The baseline the run is measured against: what the terrain costs and how
	# much of it is standing when nobody is going anywhere.
	await _place(RUN_START, RUN_YAW)
	await _wait(180)
	var rest := _planet.statistics()
	print("player_test: standing still     colliders=%3d  pending=%2d  lod=%5.1f ms  visible=%d" % [
		rest["bodies"], rest["pending"], rest["update_ms"], rest["visible"]])

	await _wind_up(0.0)
	# Counted, not sampled: a run that skips off the ground loses its ground
	# acceleration for those frames, and a single report can easily land on a
	# frame either side of that. It is also the honest test of whether the
	# terrain's collision chunks keep up — they are built on worker threads
	# within `Planet.collision_range` of the camera, and a flat-out run crosses
	# that range in a little over a second.
	var airborne := 0
	for second in 6:
		var missed := 0
		for _i in 60:
			await get_tree().physics_frame
			missed += 0 if _player.is_on_floor() else 1
		airborne += missed
		var stats := _planet.statistics()
		print("player_test: winding up %ds  speed=%6.1f  off_ground=%2d/60  colliders=%3d  pending=%2d  lod=%5.1f ms" % [
			second + 1, _player._horizontal_speed(), missed,
			stats["bodies"], stats["pending"], stats["update_ms"]])
	print("player_test: %-22s %d of 360 frames off the ground, %.0f m out" % [
		"wind-up contact", airborne, _ranged()])
	var wound: float = _player._horizontal_speed()
	if _fell_through("the wind-up"):
		pass
	elif wound < _player.run_top_speed * 0.9:
		push_error("player_test: six seconds of shift only reached %.0f m/s" % wound)

	# The whole point of the wind-up: shift buys the speed, and letting go of it
	# does not hand the speed back.
	Input.action_release("sprint")
	await _wait(120)
	_report_run("shift released, 2s")
	if _player._horizontal_speed() < wound * 0.95:
		push_error("player_test: the run bled off after shift was released")

	# Forward released. Not a stop, a skid.
	Input.action_release("move_forward")
	var from := _player.global_position
	await _wait(15)
	_report_run("coasting")
	var frames := 0
	while _player._horizontal_speed() > 0.5 and frames < 600:
		await get_tree().physics_frame
		frames += 1
	print("player_test: %-22s skidded %.0f m in %.2fs" % [
		"coast to a stop", from.distance_to(_player.global_position), frames / 60.0])

	# Into a wall flat out. `move_and_slide` alone would keep every metre per
	# second of it and just turn the run sideways.
	await _wind_up(6.0)
	var wall := _wall_ahead(250.0)
	_report_run("approaching the wall")
	frames = 0
	while not _player.is_on_wall() and frames < 900:
		await get_tree().physics_frame
		frames += 1
	await _wait(8)
	_report_run("hit the wall" if frames < 900 else "never met the wall")
	if _fell_through("the wall run"):
		pass
	elif _player._run_speed > _player.sprint_speed:
		push_error("player_test: the run survived a wall at %.0f m/s" % _player._run_speed)
	Input.action_release("sprint")
	Input.action_release("move_forward")
	wall.queue_free()

	await _wind_up(6.0)
	var entry: float = _player._horizontal_speed()
	from = _player.global_position
	Input.action_press("crouch")
	await _wait(4)
	_report_run("slide start")
	var span: float = _player._slide_span
	frames = 0
	while _player._stance == SLIDE and frames < 900:
		await get_tree().physics_frame
		frames += 1
	Input.action_release("crouch")
	print("player_test: %-22s from %.0f m/s, ran %.2fs of a %.2fs span for %.0f m" % [
		"slide", entry, frames / 60.0, span, from.distance_to(_player.global_position)])
	await _wait(12)
	_report_run("slide over")
	Input.action_release("move_forward")
	Input.action_release("sprint")

	# The same jump from a standstill and flat out, which is the only honest way
	# to read "proportional to the run".
	var standing := await _measure_jump(false)
	var flying := await _measure_jump(true)
	print("player_test: %-22s standing %.2f m, flat out %.2f m (%.1fx)" % [
		"jump apex", standing, flying, flying / maxf(standing, 0.01)])
	if _fell_through("the flat-out jump"):
		pass
	elif flying <= standing * 1.5:
		push_error("player_test: a flat-out jump is no higher than a standing one")

	await _run_shots()
	await _place(Vector3(0.0, 0.4, 12.0), PI)
	await _wait(20)


## Side on to the run at a walk, a sprint and flat out, plus the readout the
## player actually sees. The clip sheet cannot cover this: the lean is not in the
## clip, it is applied over the top of it.
func _run_shots() -> void:
	_player._camera_mode = 2
	_player.hud.visible = false
	# Parented to the player: at 200 m/s a camera placed in the world is a body
	# length behind by the time the frame is drawn.
	var review := Camera3D.new()
	_player.add_child(review)
	review.fov = 40.0
	review.position = Vector3(3.4, 0.72, 0.0)
	review.rotation.y = PI * 0.5
	review.current = true

	await _place(RUN_START, RUN_YAW)
	Input.action_press("move_forward")
	await _wait(45)
	await _rig_shot(review, "run_walk")
	Input.action_press("sprint")
	await _wait(10)
	await _rig_shot(review, "run_sprint")
	await _wait(300)
	await _rig_shot(review, "run_flat_out")

	review.current = false
	review.queue_free()
	_player.hud.visible = true
	_player._camera_mode = 0
	await _wait(20)
	await _shot("run_hud")
	Input.action_release("sprint")
	Input.action_release("move_forward")


## Runs out from the landing site with shift held for `seconds`, and leaves both
## keys down so the caller can carry the run into whatever it is measuring.
func _wind_up(seconds: float) -> void:
	Input.action_release("crouch")
	await _place(RUN_START, RUN_YAW)
	await _wait(20)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	if seconds > 0.0:
		await _wait(roundi(seconds * 60.0))


## Height gained by one jump, from a standstill or from the top of a run.
func _measure_jump(wound_up: bool) -> float:
	if wound_up:
		await _wind_up(6.0)
	else:
		await _place(RUN_START, RUN_YAW)
		await _wait(25)
	# Against the ground rather than against world Y, which is a direction the
	# run is mostly travelling sideways to by the time it is flat out.
	var base := _altitude()
	Input.action_press("jump")
	await _wait(3)
	Input.action_release("jump")
	var apex := base
	for _i in 240:
		await get_tree().physics_frame
		apex = maxf(apex, _altitude())
		if _player.is_on_floor() and _i > 20:
			break
	Input.action_release("move_forward")
	Input.action_release("sprint")
	return apex - base


## Drops a wall across the player's path, [param metres] ahead of wherever they
## are now and square to the ground under them. Placed live rather than in
## advance, because a run that is flat out is a kilometre from the landing site
## and the site's frame has the ground 60 m below where it actually is by then.
func _wall_ahead(metres: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Tall and sunk well below the feet: over 250 m the planet's own curve drops
	# the ground four metres, and terrain adds more, so a wall sized to the
	# player's height would be flown under rather than hit.
	box.size = Vector3(120.0, 90.0, 1.0)
	shape.shape = box
	body.add_child(shape)
	get_tree().current_scene.add_child(body)
	var basis := _player.global_basis
	body.global_transform = Transform3D(basis,
		_player.global_position - basis.z * metres + basis.y * 15.0)
	return body


func _report_run(label: String) -> void:
	print("player_test: %-22s stance=%-6s speed=%6.1f run=%6.1f alt=%5.2f rise=%6.1f floor=%-5s blend=%.2f lean=%5.1f clip=%s" % [
		label,
		_stance_name(_player._stance),
		_player._horizontal_speed(),
		_player._run_speed,
		_altitude(),
		_player.velocity.dot(_player.global_basis.y),
		_player.is_on_floor(),
		_player._run_blend,
		rad_to_deg(_player.character.rotation.x),
		_player._clip,
	])


## Take-off, the climb, the boost up to flat out, the brake, and the dive back
## down. Speed and lean are the two to watch: lean is what carries the change
## from an upright hover to flying flat, and it should track the speed.
func _flight_checks() -> void:
	await _place(Vector3(0.0, 60.0, 12.0), PI)
	# Long enough for the coyote window to lapse, which is what separates a
	# take-off from a jump made just after walking off something.
	await _wait(14)
	_report_flight("falling")

	# Polled, not parsed: the take-off is read with is_action_just_pressed.
	Input.action_press("jump")
	await _wait(4)
	Input.action_release("jump")
	await _wait(10)
	_report_flight("took off")
	if _player._stance != FLY:
		push_error("player_test: space in clear air did not take off")

	Input.action_press("jump")
	await _wait(45)
	_report_flight("rising")
	Input.action_release("jump")
	await _wait(30)
	_report_flight("hovering")

	Input.action_press("move_forward")
	await _wait(45)
	_report_flight("floating forward")

	Input.action_press("sprint")
	for second in 5:
		await _wait(60)
		_report_flight("boosting %ds" % (second + 1))
	var top: float = _player.velocity.length()
	if top < _player.fly_speed * 0.9:
		push_error("player_test: five seconds of boost only reached %.0f m/s" % top)
	Input.action_release("sprint")
	await _wait(60)
	_report_flight("coasting")

	# Releasing the direction is the only brake there is, so it has to actually
	# haul a thousand metres a second back down to a hover on its own.
	Input.action_release("move_forward")
	await _wait(240)
	_report_flight("let go, 4s")
	if _player.velocity.length() > _player.float_speed:
		push_error("player_test: coasting left %.0f m/s" % _player.velocity.length())

	# X out of a hover with nothing underneath: the flight ends where it is and
	# the player falls the rest of the way.
	await _wait(20)
	# Polled, like the take-off: a parsed InputEventAction never satisfies
	# is_action_just_pressed.
	Input.action_press("land")
	await _wait(4)
	Input.action_release("land")
	_report_flight("cancelled")
	if _player._stance != STAND:
		push_error("player_test: the land key left the player in stance %d" % _player._stance)
	await _wait(90)

	# Drifting down onto the floor, which is the other way out and the one a
	# player finds without being told. A fresh take-off: the cancel above put the
	# feet back down.
	await _place(Vector3(0.0, 14.0, 12.0), PI)
	await _wait(14)
	Input.action_press("jump")
	await _wait(4)
	Input.action_release("jump")
	await _wait(10)
	_look(-1.35)
	Input.action_press("move_forward")
	await _wait(150)
	Input.action_release("move_forward")
	_look(0.0)
	await _wait(25)
	_report_flight("landed")
	if _player._stance != STAND:
		push_error("player_test: still in stance %d after a dive into the floor" % _player._stance)


## Side on to the body at each point along the hover-to-flat-out continuum. The
## clip sheet cannot cover these two: its camera is framed for a standing figure,
## and flying puts the body through ninety degrees and the arms above the frame.
func _flight_shots() -> void:
	# High up, so every pose is read against sky rather than against scenery.
	await _place(Vector3(0.0, 40.0, 0.0), 0.0)
	await _wait(14)
	Input.action_press("jump")
	await _wait(4)
	Input.action_release("jump")
	await _wait(30)

	_player._camera_mode = 2
	_player.hud.visible = false
	# Parented to the player rather than placed each shot: these are taken at
	# 200 m/s, where even one frame of lag leaves the body out of the frame.
	# Level with the hips, which is what the lean turns about.
	var review := Camera3D.new()
	_player.add_child(review)
	review.fov = 40.0
	review.position = Vector3(3.4, 0.72, 0.0)
	review.rotation.y = PI * 0.5
	review.current = true
	await _wait(10)
	await _rig_shot(review, "flight_hover")

	Input.action_press("move_forward")
	await _wait(50)
	await _rig_shot(review, "flight_float_forward")

	Input.action_press("sprint")
	await _wait(45)
	await _rig_shot(review, "flight_leaning_over")
	await _wait(135)
	await _rig_shot(review, "flight_flat_out")

	# Nose up on the boost: the lean should stand the body back upright rather
	# than leave it flying flat while it climbs.
	_look(1.35)
	await _wait(90)
	await _rig_shot(review, "flight_climbing")
	Input.action_release("sprint")
	Input.action_release("move_forward")
	await _wait(180)
	_look(0.0)
	await _wait(30)

	# Back to the player's own camera, which is where the controls card is read.
	review.current = false
	review.queue_free()
	_player.hud.visible = true
	_player._camera_mode = 0
	await _wait(40)
	await _shot("flight_hud")

	# The climbing shot is taken under full boost, which leaves the player some
	# kilometres up. Brought back down before the dive home, or the checks that
	# follow inherit a player still in the air.
	await _place(Vector3(0.0, 14.0, 12.0), PI)
	_look(-1.35)
	Input.action_press("move_forward")
	await _wait(180)
	Input.action_release("move_forward")
	_look(0.0)
	await _wait(30)
	_report_flight("shots done")
	if _player._stance != STAND:
		push_error("player_test: shots left the player airborne in stance %d" % _player._stance)


## The same moment from the player's right and from above it. Side on is what
## reads the lean; overhead is the only view that separates the arms from the
## torso once the body is lying along them.
func _rig_shot(review: Camera3D, shot_name: String) -> void:
	review.position = Vector3(3.4, 0.72, 0.0)
	review.rotation = Vector3(0.0, PI * 0.5, 0.0)
	await _shot(shot_name)
	review.position = Vector3(0.0, 3.6, 0.0)
	review.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	await _shot(shot_name + "_above")


func _look(pitch: float) -> void:
	_player._pitch = pitch
	_player.head.rotation.x = pitch


func _report_flight(label: String) -> void:
	print("player_test: %-18s stance=%-6s speed=%6.1f m/s  cruise=%6.1f  blend=%4.2f  lean=%7.1f deg  clip=%-6s y=%7.2f  fov=%5.1f" % [
		label,
		_stance_name(_player._stance),
		_player.velocity.length(),
		_player._cruise,
		_player._fly_blend,
		rad_to_deg(_player.character.rotation.x),
		_player._clip,
		_altitude(),
		_player.camera.fov,
	])


func _camera_shots() -> void:
	# Facing the wardrobe across the landing site, so the shots have the character
	# against scenery rather than against bare terrain.
	await _place(Vector3(-6.0, 0.4, -2.0), atan2(3.0, 5.0))
	await _wait(20)
	await _shot("player_first_person")

	await _tap("cycle_camera")
	await _wait(30)
	_report("third near")
	await _shot("player_third_near")

	await _tap("cycle_camera")
	await _wait(30)
	_report("third far")
	await _shot("player_third_far")

	await _tap("swap_shoulder")
	await _wait(30)
	await _shot("player_third_far_left")

	Input.action_press("crouch")
	await _wait(30)
	_report("crouch, third person")
	await _shot("player_crouch_third")
	Input.action_release("crouch")
	await _wait(20)

	await _place(Vector3(2.0, 0.4, -11.0), 0.0)
	Input.action_press("move_forward")
	# A sprint's worth of shift and no more. Held for the fifty frames this used
	# to run for, the run winds up past what the test floor is long enough to
	# slide across, and the shot is of a body leaving the edge of the world.
	Input.action_press("sprint")
	await _wait(10)
	Input.action_release("sprint")
	await _wait(30)
	Input.action_press("crouch")
	await _wait(12)
	_report("slide, third person")
	await _shot("player_slide_third")
	Input.action_release("crouch")
	Input.action_release("move_forward")


## [param offset] is metres in the landing site's frame — its +Y is up out of the
## planet there, -Z the way a zero yaw faces — and [param yaw] turns about that up
## rather than about the world's.
func _place(offset: Vector3, yaw: float) -> void:
	_player.global_transform = Transform3D(
		_ground.basis * Basis(Vector3.UP, yaw), _ground * offset)
	_player.velocity = Vector3.ZERO
	await _wait(10)


## Whether the run left the planet through the inside. The terrain's colliders are
## built on worker threads around the camera, and past roughly 120 m/s the run
## arrives somewhere before its ground does; the body then falls through the shell
## and any measurement taken after that is about gravity, not about running. Said
## once, plainly, rather than left to surface as a run that "survived a wall".
func _fell_through(what: String) -> bool:
	if _altitude() > -20.0:
		return false
	push_warning("player_test: %s outran the terrain's colliders and fell through the planet" % what)
	print("player_test: !! %s fell through unbuilt ground at %.0f m/s" % [
		what, _player._horizontal_speed()])
	return true


## Metres between the feet and the ground under them. World Y means nothing on a
## sphere, so every height printed here is this.
func _altitude() -> float:
	var centre := _planet.global_position
	var out := _player.global_position - centre
	return out.length() - (_planet.standing_position(out) - centre).length()


## How far the player has travelled across the ground from the landing site,
## measured along the surface rather than through it.
func _ranged() -> float:
	var centre := _planet.global_position
	var here := (_player.global_position - centre).normalized()
	var there := (_ground.origin - centre).normalized()
	return acos(clampf(here.dot(there), -1.0, 1.0)) * _planet.shape.radius


## Parsed as a real event so it reaches _unhandled_input, and held for a few
## frames so a polled is_action_just_pressed() sees it too.
func _tap(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	await _wait(3)
	var release := InputEventAction.new()
	release.action = action
	release.pressed = false
	Input.parse_input_event(release)
	await _wait(2)


func _wait(frames: int) -> void:
	for _i in frames:
		await get_tree().physics_frame


## Row order follows OnlinePlayer.Stance, so a stance added there without a name
## added here reports as its number rather than taking the harness down.
func _stance_name(stance: int) -> String:
	const NAMES := ["stand", "crouch", "slide", "fly", "crash", "swim"]
	return NAMES[stance] if stance < NAMES.size() else str(stance)


func _report(label: String) -> void:
	print("player_test: %-22s stance=%-6s speed=%5.2f alt=%5.2f out=%6.1f floor=%-5s cam=%d arm=%4.2f shoulder=%5.2f" % [
		label,
		_stance_name(_player._stance),
		_player._horizontal_speed(),
		_altitude(),
		_ranged(),
		_player.is_on_floor(),
		_player._camera_mode,
		_player.camera_arm.spring_length,
		_player.camera_arm.position.x,
	])


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		print("player_test: shot %s failed: %s" % [shot_name, error_string(error)])
