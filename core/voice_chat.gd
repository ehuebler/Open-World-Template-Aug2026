extends Node

## Push-to-talk voice. Add this script as the "VoiceChat" autoload.
##
## Hold the `push_to_talk` action and the microphone is opened, cut down to
## 12 kHz mono bytes and sent to everyone as unreliable packets. Unreliable is
## the point: a packet that arrives late is worth less than nothing, since
## waiting for it would delay every packet behind it, so a lost one is left as a
## gap and the talker keeps up with real time.
##
## Godot ships no voice codec, so the "codec" here is a resample and a companded
## byte per sample: 12 KB/s per talker, no dependencies, and speech-quality
## rather than music-quality. `encode` and `decode` are static and pure, which is
## how dev/_comms_test.gd measures what the compression costs.
##
## Capture happens on its own audio bus, where the order of the effects is what
## keeps the microphone out of the speakers: the capture tap comes first and an
## amplifier at -80 dB comes after it. Muting the bus or pulling its volume down
## instead would silence the tap along with the output.

signal speaking_changed(peer_id: int, speaking: bool)

const MIC_BUS := &"Mic"
const VOICE_BUS := &"Voice"

## Speech survives 12 kHz comfortably — it is the top octave that goes, and the
## alternative is sending the mixer's 44.1 kHz at four times the bandwidth.
const RATE := 12000.0
## A packet goes out once this many samples are ready: 30 ms, short enough not to
## be heard as delay and long enough to keep the packet rate down near 33/s.
const PACKET_SAMPLES := 360
## A packet this size could only be a peer trying it on: 4 seconds of audio.
const MAX_PACKET := 48000
## Samples held back before a speaker starts playing, which is what network
## jitter is absorbed by. 100 ms of slack, spent once per turn of speech.
const PREBUFFER := 1200
## Once a listener is this far behind there is no catching up by playing faster,
## so the oldest audio is dropped instead: 400 ms.
const MAX_QUEUE := 4800
## Silence for this long ends a turn, and clears the talking indicator.
const SILENCE_TIMEOUT := 0.35

## Set by the chat panel while the keyboard belongs to it, so that typing the
## letter v into a message does not also open the microphone.
var suspended := false
var transmitting := false
## Counted for diagnostics: it is the one number that says the capture, resample
## and packetise chain is actually producing something.
var packets_sent := 0

var _capture: AudioEffectCapture
var _microphone: AudioStreamPlayer
## Captured frames, downmixed but not yet resampled, and the fractional read
## position carried between chunks so resampling does not click at the seams.
var _mono := PackedFloat32Array()
var _phase := 0.0
## Resampled samples waiting to fill a packet.
var _outgoing := PackedFloat32Array()
## Peer id to {player, playback, queue, primed, silence}.
var _voices: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var bus := AudioServer.get_bus_index(MIC_BUS)
	if bus >= 0 and AudioServer.get_bus_effect_count(bus) > 0:
		_capture = AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
	if _capture == null:
		push_warning("VoiceChat: no capture effect on the %s bus; talking is disabled." % MIC_BUS)
	_microphone = AudioStreamPlayer.new()
	_microphone.name = "Microphone"
	_microphone.stream = AudioStreamMicrophone.new()
	_microphone.bus = MIC_BUS
	add_child(_microphone)
	NetworkManager.session_ended.connect(_end_session)
	NetworkManager.player_left.connect(_drop_voice)


func _exit_tree() -> void:
	# A generator that is still playing keeps its playback alive, and a playback
	# outliving the shutdown audit is reported as a leaked instance.
	for peer_id: int in _voices:
		var player: AudioStreamPlayer = _voices[peer_id]["player"]
		if is_instance_valid(player):
			player.stop()
	_voices.clear()


func _process(delta: float) -> void:
	_read_input()
	if transmitting:
		_gather()
		_send_ready_packets(false)
	_play_queues(delta)


## Names of everyone currently coming through, the local player included, for the
## indicator on the chat panel.
func talkers() -> PackedStringArray:
	var names := PackedStringArray()
	if transmitting:
		names.append(NetworkManager.local_player_name)
	for peer_id: int in _voices:
		var voice: Dictionary = _voices[peer_id]
		if bool(voice.get("speaking", false)):
			names.append(str(NetworkManager.get_player_metadata(peer_id).get("name", "Player")))
	return names


## One packet from a peer, split out of the RPC so a test can feed the playback
## path without a second machine.
func receive(peer_id: int, payload: PackedByteArray) -> void:
	if payload.is_empty() or payload.size() > MAX_PACKET:
		return
	var voice := _voice_for(peer_id)
	var queue: PackedFloat32Array = voice["queue"]
	queue.append_array(decode(payload))
	if queue.size() > MAX_QUEUE:
		queue = queue.slice(queue.size() - MAX_QUEUE)
	voice["queue"] = queue
	voice["silence"] = 0.0
	if not bool(voice["speaking"]):
		voice["speaking"] = true
		speaking_changed.emit(peer_id, true)


## Samples to bytes: one byte each, on a square-law curve so the quiet half of
## the range keeps most of the resolution, which is where speech lives.
static func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(samples.size())
	for index in samples.size():
		var sample := clampf(samples[index], -1.0, 1.0)
		var companded := sqrt(absf(sample)) * signf(sample)
		payload[index] = int(roundf(companded * 127.0)) + 128
	return payload


static func decode(payload: PackedByteArray) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(payload.size())
	for index in payload.size():
		var companded := (float(payload[index]) - 128.0) / 127.0
		samples[index] = companded * absf(companded)
	return samples


func _read_input() -> void:
	var wanted := (
		not suspended
		and NetworkManager.in_multiplayer_session()
		and _capture != null
		and Input.is_action_pressed(&"push_to_talk")
	)
	if wanted == transmitting:
		return
	if wanted:
		_start_transmitting()
	else:
		_stop_transmitting()


func _start_transmitting() -> void:
	transmitting = true
	_mono.clear()
	_outgoing.clear()
	_phase = 0.0
	_capture.clear_buffer()
	if not _microphone.playing:
		_microphone.play()
	speaking_changed.emit(NetworkManager.get_local_peer_id(), true)


func _stop_transmitting() -> void:
	if not transmitting:
		return
	transmitting = false
	# Whatever is left is a fragment of a word, so it goes out short rather than
	# being dropped.
	_send_ready_packets(true)
	_microphone.stop()
	speaking_changed.emit(NetworkManager.get_local_peer_id(), false)


## Capture, downmix and resample into `_outgoing`.
func _gather() -> void:
	var available := _capture.get_frames_available()
	if available > 0:
		for frame: Vector2 in _capture.get_buffer(available):
			_mono.append((frame.x + frame.y) * 0.5)
	if _mono.size() < 2:
		return
	var step := AudioServer.get_mix_rate() / RATE
	var read := _phase
	var last := float(_mono.size() - 1)
	while read < last:
		var whole := int(read)
		_outgoing.append(lerpf(_mono[whole], _mono[whole + 1], read - float(whole)))
		read += step
	# The sample the next chunk interpolates from has to survive the trim.
	var consumed := int(read)
	_mono = _mono.slice(consumed)
	_phase = read - float(consumed)


func _send_ready_packets(flush: bool) -> void:
	while _outgoing.size() >= PACKET_SAMPLES:
		_voice_packet.rpc(encode(_outgoing.slice(0, PACKET_SAMPLES)))
		_outgoing = _outgoing.slice(PACKET_SAMPLES)
		packets_sent += 1
	if flush and not _outgoing.is_empty():
		_voice_packet.rpc(encode(_outgoing))
		_outgoing.clear()
		packets_sent += 1


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _voice_packet(payload: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state == NetworkManager.SessionState.IN_GAME \
			and NetworkManager.is_peer_registered(sender):
		receive(sender, payload)


func _play_queues(delta: float) -> void:
	for peer_id: int in _voices:
		var voice: Dictionary = _voices[peer_id]
		var playback: AudioStreamGeneratorPlayback = voice["playback"]
		var queue: PackedFloat32Array = voice["queue"]
		if not bool(voice["primed"]) and queue.size() >= PREBUFFER:
			voice["primed"] = true
		if bool(voice["primed"]) and playback != null:
			var pushable := mini(playback.get_frames_available(), queue.size())
			for index in pushable:
				playback.push_frame(Vector2(queue[index], queue[index]))
			queue = queue.slice(pushable)
			# Run dry and the next burst waits for its prebuffer again, rather
			# than being fed a sample at a time into a stuttering stream.
			if queue.is_empty():
				voice["primed"] = false
		voice["queue"] = queue
		if queue.is_empty():
			voice["silence"] = float(voice["silence"]) + delta
			if bool(voice["speaking"]) and float(voice["silence"]) > SILENCE_TIMEOUT:
				voice["speaking"] = false
				speaking_changed.emit(peer_id, false)


func _voice_for(peer_id: int) -> Dictionary:
	if _voices.has(peer_id):
		return _voices[peer_id]
	var player := AudioStreamPlayer.new()
	player.name = "Voice%d" % peer_id
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = RATE
	generator.buffer_length = 0.3
	player.stream = generator
	player.bus = VOICE_BUS
	add_child(player)
	player.play()
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		# No audio device, which is the headless case. Packets are still accepted
		# and counted; there is simply nowhere to put them.
		player.queue_free()
		player = null
	_voices[peer_id] = {
		"player": player,
		"playback": playback,
		"queue": PackedFloat32Array(),
		"primed": false,
		"speaking": false,
		"silence": 0.0,
	}
	return _voices[peer_id]


func _drop_voice(peer_id: int) -> void:
	var voice: Dictionary = _voices.get(peer_id, {})
	if voice.is_empty():
		return
	_voices.erase(peer_id)
	var player: AudioStreamPlayer = voice["player"]
	if is_instance_valid(player):
		player.stop()
		player.queue_free()
	if bool(voice["speaking"]):
		speaking_changed.emit(peer_id, false)


func _end_session() -> void:
	_stop_transmitting()
	for peer_id: int in _voices.keys():
		_drop_voice(peer_id)
