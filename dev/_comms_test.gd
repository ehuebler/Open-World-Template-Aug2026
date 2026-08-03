extends Node

## Chat and voice, driven the way a player drives them. Run windowed, since both
## halves need real devices: rendering for the screenshots and an audio device for
## the microphone bus.
##
##     godot --path . dev/_comms_test.tscn
##
## The session is faked with an offline peer standing in for a host, so the local
## player is peer 1 and a second name sits in the roster to be talked at.

const WORLD := preload("res://game/world.tscn")
const SHOT_DIR := "res://dev/captures/"
## The peer id the pretend second player answers to.
const OTHER := 2

var _player: OnlinePlayer
var _world: GameWorld


func _ready() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_host = true
	# Not single player: chat and voice both stay out of the way of a solo game,
	# so the harness has to look like a session with someone else in it.
	NetworkManager.is_single_player = false
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.local_player_name = "Player"
	NetworkManager.players[1] = {"name": "Player", "peer_id": 1}
	NetworkManager.players[OTHER] = {"name": "Rowan", "peer_id": OTHER}
	# The world opens the home screen and spawns nobody while the session reads as
	# idle, so the state has to say "in game" before it comes up.
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	_world = WORLD.instantiate() as GameWorld
	add_child(_world)
	for _frame in 10:
		await get_tree().process_frame
	_player = get_tree().get_first_node_in_group(&"network_players") as OnlinePlayer
	ChatHud._on_session_changed()
	await _run()
	get_tree().quit()


func _run() -> void:
	await _chat_flow()
	await _movement_lockout()
	await _escape_closes()
	await _chat_while_paused()
	_codec()
	await _capture()
	await _playback()
	await _log_shot()
	await _teardown()


## Enter opens the line, typing goes into it, Enter sends it.
func _chat_flow() -> void:
	await _wait(20)
	var before := ChatHud.typing
	_tap(&"chat")
	await _wait(4)
	var opened := ChatHud.typing
	await _type("hello team")
	var drafted: String = ChatHud._entry.text
	# V is a letter while the field has the keyboard, not the talk key.
	Input.action_press(&"push_to_talk")
	await _wait(3)
	var talked := VoiceChat.transmitting
	Input.action_release(&"push_to_talk")
	_key(KEY_ENTER)
	await _wait(6)
	_report("chat flow", "closed:%s  opened:%s  typed:%s  still typing:%s" % [
		not before, opened, drafted, ChatHud.typing,
	])
	_report("v while typing", "transmitting:%s" % talked)
	_report("history", "%s" % [_lines()])
	await _shot("chat_line")


## Movement is polled, so a focused field is not enough on its own: the player
## should stay put while a message is being typed and walk again once it is sent.
func _movement_lockout() -> void:
	_place(Vector3(0.0, 0.2, 6.0))
	await _wait(20)
	_tap(&"chat")
	await _wait(4)
	var start := _player.global_position
	Input.action_press(&"move_forward")
	await _wait(30)
	var while_typing := _player.global_position.distance_to(start)
	Input.action_release(&"move_forward")
	_key(KEY_ESCAPE)
	await _wait(6)
	start = _player.global_position
	Input.action_press(&"move_forward")
	await _wait(30)
	var after := _player.global_position.distance_to(start)
	Input.action_release(&"move_forward")
	await _wait(10)
	_report("movement", "typing moved %.2f m, then %.2f m once closed" % [while_typing, after])


## Escape has to belong to the field while it is open, or the pause card comes up
## over a half-typed message.
func _escape_closes() -> void:
	_tap(&"chat")
	await _wait(4)
	await _type("half a thought")
	_key(KEY_ESCAPE)
	await _wait(6)
	var paused := _world.locally_paused()
	_report("escape", "typing:%s  paused:%s  history %d lines" % [
		ChatHud.typing, paused, ChatHud._log_column.get_child_count(),
	])


## Chat is wanted from the menu too, which is the nearest thing this project has to
## sitting in a lobby. Escape belongs to whichever of the two was opened last, and
## since Escape is now what opens the menu, getting that wrong means abandoning a
## message shuts the menu underneath it.
func _chat_while_paused() -> void:
	_tap(&"pause")
	await _wait(6)
	var paused := _world.locally_paused()
	# A real Enter, because the menu has focusable buttons that Enter would
	# otherwise press: whichever of the two gets it has to be the same in the game
	# as it is here.
	_key(KEY_ENTER)
	await _wait(4)
	var opened := ChatHud.typing
	_key(KEY_ESCAPE)
	await _wait(6)
	var still_paused := _world.locally_paused()
	await _shot("chat_paused")
	_tap(&"pause")
	await _wait(6)
	_report("paused", "paused:%s  chat opened:%s  still paused after escape:%s  resumed:%s" % [
		paused, opened, still_paused, not _world.locally_paused(),
	])


## What the compression costs, measured rather than assumed.
func _codec() -> void:
	var samples := PackedFloat32Array()
	for index in 2400:
		var time := float(index) / VoiceChat.RATE
		samples.append(0.6 * sin(TAU * 220.0 * time) + 0.2 * sin(TAU * 1500.0 * time))
	var payload := VoiceChat.encode(samples)
	var restored := VoiceChat.decode(payload)
	var error := 0.0
	var signal_power := 0.0
	for index in samples.size():
		error += pow(samples[index] - restored[index], 2.0)
		signal_power += pow(samples[index], 2.0)
	var noise_db := 10.0 * log(error / maxf(signal_power, 0.0001)) / log(10.0)
	_report("codec", "%d samples -> %d bytes, %.1f KB/s, noise %.1f dB below signal" % [
		samples.size(), payload.size(), VoiceChat.RATE / 1024.0, noise_db,
	])


## A tone played into the microphone bus should reach the capture effect at full
## level, which is the whole capture path bar the microphone itself. Push-to-talk
## is left alone for that measurement, since talking drains the same buffer, and
## only then held down to see the packets come out.
func _capture() -> void:
	var tone := AudioStreamPlayer.new()
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = AudioServer.get_mix_rate()
	generator.buffer_length = 0.3
	tone.stream = generator
	tone.bus = VoiceChat.MIC_BUS
	add_child(tone)
	tone.play()
	var playback := tone.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		_report("capture", "no audio device, skipped")
		tone.queue_free()
		return

	var quiet := _capture_peak()
	var phase := 0.0
	var feed := func() -> void:
		for _index in playback.get_frames_available():
			phase += TAU * 440.0 / generator.mix_rate
			var value := 0.5 * sin(phase)
			playback.push_frame(Vector2(value, value))
	for _frame in 24:
		feed.call()
		await get_tree().process_frame
	var loud := _capture_peak()

	var packets := VoiceChat.packets_sent
	var started := Time.get_ticks_msec()
	Input.action_press(&"push_to_talk")
	for _frame in 40:
		feed.call()
		await get_tree().process_frame
	Input.action_release(&"push_to_talk")
	var elapsed := Time.get_ticks_msec() - started
	await _wait(4)
	_report("capture", "bus peak %.3f silent, %.3f with a tone" % [quiet, loud])
	_report("talking", "%d packets, %d ms of audio sent while held for %d ms" % [
		VoiceChat.packets_sent - packets,
		(VoiceChat.packets_sent - packets) * VoiceChat.PACKET_SAMPLES * 1000 / int(VoiceChat.RATE),
		elapsed,
	])
	tone.stop()
	tone.queue_free()


## Packets from somebody else, fed in the way the RPC would.
func _playback() -> void:
	var samples := PackedFloat32Array()
	for index in VoiceChat.PACKET_SAMPLES:
		samples.append(0.4 * sin(TAU * 300.0 * float(index) / VoiceChat.RATE))
	var payload := VoiceChat.encode(samples)
	# Enough packets to pass the prebuffer and start playing.
	for _packet in 6:
		VoiceChat.receive(OTHER, payload)
	var queued: int = VoiceChat._voices[OTHER]["queue"].size()
	await _wait(2)
	var left: int = VoiceChat._voices[OTHER]["queue"].size()
	var player: AudioStreamPlayer = VoiceChat._voices[OTHER]["player"]
	_report("playback", "%d samples queued, %d handed to the stream, playing:%s, talkers %s" % [
		queued, queued - left, player != null and player.playing, VoiceChat.talkers(),
	])
	await _shot("chat_talking")
	# And it stops saying so once the packets stop.
	await _wait(60)
	_report("silence", "talkers %s" % [VoiceChat.talkers()])


## A conversation rather than one message, with the arriving and leaving lines
## coming from the signals that really write them. The leaving one is worth
## driving properly: the roster forgets a peer before it announces the departure,
## so a naive lookup there prints nobody's name.
func _log_shot() -> void:
	ChatManager.clear()
	NetworkManager.player_registered.emit(OTHER, NetworkManager.players[OTHER])
	await _wait(4)
	ChatManager._deliver({"kind": ChatManager.SAY, "name": "Rowan", "text": "sphere is mine", "peer_id": OTHER})
	await _wait(4)
	ChatManager.say("taking the far kerb")
	await _wait(4)
	NetworkManager.players.erase(OTHER)
	NetworkManager.player_left.emit(OTHER)
	await _wait(4)
	_report("join and leave", "%s" % [_lines()])
	_tap(&"chat")
	await _wait(4)
	await _type("back in a minute")
	await _shot("chat_open")
	_key(KEY_ESCAPE)
	await _wait(4)


## Leaving a session has to take the panel and everyone's voice with it, or the
## log is still hanging over the main menu with the last game's chat in it.
func _teardown() -> void:
	NetworkManager.leave_game()
	await _wait(6)
	_report("left", "hud visible:%s  history %d  voices %d" % [
		ChatHud.visible, ChatManager.history.size(), VoiceChat._voices.size(),
	])


func _capture_peak() -> float:
	var bus := AudioServer.get_bus_index(VoiceChat.MIC_BUS)
	var capture := AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
	if capture == null:
		return -1.0
	var peak := 0.0
	for frame: Vector2 in capture.get_buffer(capture.get_frames_available()):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return peak


func _lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for entry: Dictionary in ChatManager.history:
		lines.append("%s%s" % [
			"" if str(entry.get("name", "")).is_empty() else "%s: " % entry["name"],
			entry.get("text", ""),
		])
	return lines


func _place(at: Vector3) -> void:
	_player.global_position = at
	_player.velocity = Vector3.ZERO


## An action the way a key press delivers it, which is what `_unhandled_input`
## listens for; `Input.action_press` alone only moves the polled state.
func _tap(action: StringName) -> void:
	var press := InputEventAction.new()
	press.action = action
	press.pressed = true
	Input.parse_input_event(press)
	var release := press.duplicate() as InputEventAction
	release.pressed = false
	Input.parse_input_event(release)


func _key(code: Key) -> void:
	var press := InputEventKey.new()
	press.keycode = code
	press.physical_keycode = code
	press.pressed = true
	Input.parse_input_event(press)
	var release := press.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)


## Real keystrokes into whatever holds focus, so the field is tested and not just
## its text property.
func _type(text: String) -> void:
	for character in text:
		var press := InputEventKey.new()
		press.pressed = true
		press.unicode = character.unicode_at(0)
		press.keycode = KEY_NONE
		Input.parse_input_event(press)
		var release := press.duplicate() as InputEventKey
		release.pressed = false
		Input.parse_input_event(release)
	await get_tree().process_frame


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame


func _report(step: String, detail: String) -> void:
	print("comms_test: %-14s %s" % [step, detail])


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(SHOT_DIR + shot_name + ".png")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	if error != OK:
		push_error("could not write %s (%s)" % [path, error_string(error)])
