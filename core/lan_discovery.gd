extends Node

## UDP LAN discovery. Add this script as the "LanDiscovery" autoload before
## NetworkManager. Hosts advertise periodically and answer explicit probes.

signal lobby_list_changed(lobbies: Array)

const DISCOVERY_PORT := 45454
const PROTOCOL_VERSION := 1
const MAGIC := "3D_ONLINE_LOBBY"
const ADVERTISE_INTERVAL := 0.8
const LOBBY_TIMEOUT_MSEC := 3200

var _udp := PacketPeerUDP.new()
var _hosting := false
var _host_metadata: Dictionary = {}
var _lobbies: Dictionary = {}
var _advertise_elapsed := 0.0
var _prune_elapsed := 0.0
var _socket_ready := false


func _ready() -> void:
	_open_socket(0)
	set_process(true)


func _exit_tree() -> void:
	_udp.close()


func _process(delta: float) -> void:
	if not _socket_ready:
		return
	_read_packets()
	if _hosting:
		_advertise_elapsed += delta
		if _advertise_elapsed >= ADVERTISE_INTERVAL:
			_advertise_elapsed = 0.0
			_send_advertisement("255.255.255.255", DISCOVERY_PORT)
	else:
		_prune_elapsed += delta
		if _prune_elapsed >= 0.5:
			_prune_elapsed = 0.0
			_prune_expired()


func begin_host_advertising(metadata: Dictionary) -> void:
	# Browsers use an ephemeral port so multiple local test clients can coexist.
	# Only the active host owns the well-known discovery port.
	_open_socket(DISCOVERY_PORT)
	if not _socket_ready:
		push_warning("LAN host discovery could not bind UDP port %d." % DISCOVERY_PORT)
		return
	_host_metadata = metadata.duplicate(true)
	_hosting = true
	_advertise_elapsed = ADVERTISE_INTERVAL


func update_host_metadata(metadata: Dictionary) -> void:
	_host_metadata = metadata.duplicate(true)
	if _hosting:
		_advertise_elapsed = ADVERTISE_INTERVAL


func stop_host_advertising() -> void:
	_hosting = false
	_host_metadata.clear()
	_open_socket(0)


func refresh_lobbies() -> void:
	_lobbies.clear()
	_emit_lobbies()
	if not _socket_ready:
		return
	_send_packet({
		"magic": MAGIC,
		"version": PROTOCOL_VERSION,
		"type": "probe",
	}, "255.255.255.255", DISCOVERY_PORT)


func get_lobbies() -> Array:
	return _sorted_lobbies()


func _read_packets() -> void:
	while _udp.get_available_packet_count() > 0:
		var packet := _udp.get_packet()
		var sender_ip := _udp.get_packet_ip()
		var sender_port := _udp.get_packet_port()
		var text := packet.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if not parsed is Dictionary:
			continue
		var message: Dictionary = parsed
		if message.get("magic") != MAGIC or int(message.get("version", -1)) != PROTOCOL_VERSION:
			continue
		match str(message.get("type", "")):
			"probe":
				if _hosting:
					_send_advertisement(sender_ip, sender_port)
			"advertisement":
				if not _hosting:
					_record_lobby(message.get("lobby", {}), sender_ip)


func _send_advertisement(address: String, port: int) -> void:
	_send_packet({
		"magic": MAGIC,
		"version": PROTOCOL_VERSION,
		"type": "advertisement",
		"lobby": _host_metadata,
	}, address, port)


func _send_packet(message: Dictionary, address: String, port: int) -> void:
	if not _socket_ready:
		return
	var error := _udp.set_dest_address(address, port)
	if error != OK:
		return
	_udp.put_packet(JSON.stringify(message).to_utf8_buffer())


func _open_socket(port: int) -> void:
	_udp.close()
	_udp = PacketPeerUDP.new()
	_socket_ready = _udp.bind(port, "*") == OK
	if _socket_ready:
		_udp.set_broadcast_enabled(true)


func _record_lobby(raw_lobby: Variant, sender_ip: String) -> void:
	if not raw_lobby is Dictionary:
		return
	var lobby: Dictionary = raw_lobby.duplicate(true)
	var port := int(lobby.get("port", 0))
	if port < 1 or port > 65535:
		return
	lobby["address"] = sender_ip
	lobby["last_seen_msec"] = Time.get_ticks_msec()
	var key := "%s:%d" % [sender_ip, port]
	_lobbies[key] = lobby
	_emit_lobbies()


func _prune_expired() -> void:
	var now := Time.get_ticks_msec()
	var changed := false
	for key in _lobbies.keys():
		var lobby: Dictionary = _lobbies[key]
		if now - int(lobby.get("last_seen_msec", 0)) > LOBBY_TIMEOUT_MSEC:
			_lobbies.erase(key)
			changed = true
	if changed:
		_emit_lobbies()


func _emit_lobbies() -> void:
	lobby_list_changed.emit(_sorted_lobbies())


func _sorted_lobbies() -> Array:
	var result: Array = []
	for lobby in _lobbies.values():
		var public_lobby: Dictionary = lobby.duplicate(true)
		public_lobby.erase("last_seen_msec")
		result.append(public_lobby)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0
	)
	return result
