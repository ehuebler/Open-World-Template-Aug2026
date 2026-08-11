class_name GameWorld
extends Node3D

## The world is also the home screen. It is loaded once, empty, and the menu is a
## camera and an overlay put over it (see ui/menu/home_screen.gd); players are
## spawned only once a session exists. Nothing between the title and playing is a
## scene change, which is what keeps the planet's quadtree built across it.

const PLAYER_SCENE := preload("res://game/player/player.tscn")

const DROP_FORWARD_DISTANCE := 1.55
const DROP_SURFACE_CLEARANCE := 0.08
## Slightly wider than the 2.4 m interaction ray to allow for the player's eye,
## the pickup's raised centre and a sloping surface, but still an arm's-length
## server check rather than trusting that a client ray hit.
const PICKUP_MAX_DISTANCE := 3.2
## How often the host tells everyone what has actually broken. Slower than the
## damage itself, because this is a correction and not the mechanism: the peers
## have already worked it out for themselves.
const FLORA_CONFIRM_INTERVAL := 0.4

@onready var spawn_points: Node3D = $SpawnPoints
@onready var celestial_cycle: CelestialCycle = $CelestialCycle

var _spawned_players: Dictionary = {}
## On the server these are the authoritative finite world records. Clients keep
## the replicated subset in the same shape so duplicate join/live spawns and
## despawns are harmless.
var _pickups: Dictionary = {}
var _pickup_nodes: Dictionary = {}
var _next_pickup_id := 1
var _locally_paused := false
var _home_screen: HomeScreen
## Set once a session has been opened here, so a second `session_started` — the
## one a client gets on connecting, after the host's — cannot spawn twice.
var _session_open := false
var _spawn_override := Transform3D.IDENTITY
var _has_spawn_override := false
## Look the home screen was showing when New Game was pressed. Wins over the
## roster metadata for the local peer so the body that starts is the one that
## was on screen, not a stale settings read.
var _look_override: Dictionary = {}
var _has_look_override := false
## Seconds until the next flora reconciliation pass. See
## [method confirm_flora_breaks].
var _flora_confirm_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	NetworkManager.active_world = self
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_left.connect(_despawn_player)
	NetworkManager.session_started.connect(_begin_session)

	if NetworkManager.state == NetworkManager.SessionState.IDLE:
		_open_home_screen()
	else:
		_begin_session()


func _physics_process(delta: float) -> void:
	_flora_confirm_left -= delta
	if _flora_confirm_left > 0.0:
		return
	_flora_confirm_left = FLORA_CONFIRM_INTERVAL
	confirm_flora_breaks()


func _exit_tree() -> void:
	if NetworkManager.active_world == self:
		NetworkManager.active_world = null
	if NetworkManager.player_registered.is_connected(_on_player_registered):
		NetworkManager.player_registered.disconnect(_on_player_registered)
	if NetworkManager.player_left.is_connected(_despawn_player):
		NetworkManager.player_left.disconnect(_despawn_player)
	if NetworkManager.session_started.is_connected(_begin_session):
		NetworkManager.session_started.disconnect(_begin_session)
	_pickups.clear()
	_pickup_nodes.clear()


func local_player() -> OnlinePlayer:
	return _spawned_players.get(multiplayer.get_unique_id()) as OnlinePlayer


func planet() -> Planet:
	return get_node_or_null("Planet") as Planet


## Asks for a mark to be cut into the ground.
##
## Host-authoritative, like every other change to shared world state here: a
## client sends the request and waits to be told, so two peers cannot end up
## with craters the other does not have. The host applies it to itself through
## the same broadcast, so there is one code path and no chance of the two
## drifting.
func request_scar(scar: TerrainScars.Scar) -> void:
	if scar == null:
		return
	if not multiplayer.has_multiplayer_peer():
		_apply_scar(scar.to_wire())
		return
	if multiplayer.is_server():
		_apply_scar.rpc(scar.to_wire())
	else:
		_request_scar_from_client.rpc_id(1, scar.to_wire())


@rpc("any_peer", "call_remote", "reliable")
func _request_scar_from_client(wire: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() <= 1:
		return
	_apply_scar.rpc(wire)


@rpc("authority", "call_local", "reliable")
func _apply_scar(wire: Dictionary) -> void:
	var world_planet := planet()
	if world_planet == null:
		return
	world_planet.add_scar(TerrainScars.Scar.from_wire(wire))


## Every mark on the ground, for a peer joining a session that has already been
## fought over.
func scar_snapshot() -> Array:
	var world_planet := planet()
	if world_planet == null or world_planet.shape == null:
		return []
	return world_planet.shape.scars.to_wire()


func apply_scar_snapshot(wire: Array) -> void:
	if wire.is_empty():
		return
	var world_planet := planet()
	if world_planet == null or world_planet.shape == null:
		return
	world_planet.shape.scars.from_wire(wire)
	# One sweep rather than one per scar: the registry is already populated, and
	# a joining peer has every chunk to build anyway.
	for entry in wire:
		if entry is Dictionary:
			world_planet.mark_region_stale(
				(entry.get("direction", Vector3.UP) as Vector3).normalized(),
				float(entry.get("radius", 1.0)),
				float(entry.get("depth", 0.0)))


## What every flora field has lost so far, keyed by the field's path under this
## world. Paths rather than names because the fields are scattered through the
## planet's children, and every peer loads the same scene so the same path
## resolves to the same field.
func flora_snapshot() -> Dictionary:
	var state := {}
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		if not field.has_method(&"broken_keys"):
			continue
		var keys: PackedInt32Array = field.call(&"broken_keys")
		if not keys.is_empty():
			state[String(get_path_to(field))] = keys
	return state


func apply_flora_snapshot(state: Dictionary) -> void:
	for path: String in state:
		_apply_flora_breaks(path, state[path])


## Runs on the host only, a few times a second. Anything that has broken since
## the last pass is told to everyone.
##
## Every peer has already applied the same damage volumes to the same
## deterministic flora and should already agree; this is the correction for when
## they do not, and it is cheap precisely because agreement is the normal case
## and the list is nearly always empty.
func confirm_flora_breaks() -> void:
	var broadcasting := multiplayer.has_multiplayer_peer() \
		and multiplayer.is_server() and multiplayer.get_peers().size() > 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		if not field.has_method(&"drain_new_breaks"):
			continue
		# Drained whether or not it is going anywhere. On a client nothing reads
		# the list, and left alone it would grow all session.
		var keys: PackedInt32Array = field.call(&"drain_new_breaks")
		if broadcasting and not keys.is_empty():
			_apply_flora_breaks.rpc(String(get_path_to(field)), keys)


@rpc("authority", "call_remote", "reliable")
func _apply_flora_breaks(path: String, keys: PackedInt32Array) -> void:
	var field := get_node_or_null(NodePath(path))
	if field != null and field.has_method(&"apply_broken_keys"):
		field.call(&"apply_broken_keys", keys)


func pickup_node(pickup_id: int) -> DroppedItem:
	return _pickup_nodes.get(pickup_id) as DroppedItem


## Stable join-in-progress representation of every live, unclaimed pickup.
func pickup_snapshots() -> Array:
	var snapshots: Array = []
	var ids := _pickups.keys()
	ids.sort()
	for id_variant in ids:
		var pickup_id := int(id_variant)
		var record: Dictionary = _pickups.get(pickup_id, {})
		if record.is_empty() or bool(record.get("claimed", false)):
			continue
		snapshots.append({
			"pickup_id": pickup_id,
			"item_id": str(record.get("item_id", "")),
			"transform": record.get("transform", Transform3D.IDENTITY),
		})
	return snapshots


## Where the local player will be put when a session opens, overriding the spawn
## markers. The home screen uses it to start the player exactly where the
## character it has been showing was standing.
func override_local_spawn(at_transform: Transform3D) -> void:
	_spawn_override = at_transform
	_has_spawn_override = true


func override_local_look(look: Dictionary) -> void:
	_look_override = look.duplicate(true)
	_has_look_override = true


func _open_home_screen() -> void:
	_home_screen = HomeScreen.new()
	_home_screen.name = "HomeScreen"
	_home_screen.frame = _spawn_transform(1)
	add_child(_home_screen)


func _begin_session() -> void:
	if _session_open:
		return
	_session_open = true
	if multiplayer.is_server():
		# The world is already rendering behind the title screen, but a new game
		# should begin at the authored noon rather than inherit however long the
		# player spent in the menu. Joining clients receive this phase below.
		celestial_cycle.set_phase(0.0)
		for peer_id in NetworkManager.players:
			_spawn_player(int(peer_id), NetworkManager.get_player_metadata(int(peer_id)), _spawn_transform(int(peer_id)), true)
	else:
		_request_world_state.rpc_id(1)


## What being in a menu costs. Escape used to raise a pause card of the world's
## own; now [GameMenu] is that card and calls this instead, but the policy stays
## here because it is about the session and not about the menu:
##
## - **Single player** really stops. There is nobody else in the world to keep it
##   turning for, and stopping means you can read a settings page without falling
##   out of the sky while you do.
## - **In company** nothing stops. The other players are still playing, so all this
##   can honestly do is take the mouse and stop taking this player's input — which
##   [method OnlinePlayer.open_menu] has already done by the time this is called.
func set_local_pause(paused: bool) -> void:
	_locally_paused = paused
	get_tree().paused = paused and NetworkManager.is_single_player


## Whether a menu is holding this player out of the world. Not the same question as
## `get_tree().paused`, which is only true in single player, and the reason this is
## worth asking separately: in company the world keeps turning and this is still the
## honest answer to "am I in a menu".
func locally_paused() -> bool:
	return _locally_paused


## Drop the session and go back to the home screen. Reached from the Settings tab's
## LEAVE GAME; the menu raises it rather than doing it, because what a world is is
## this node's business.
func leave_session() -> void:
	get_tree().paused = false
	NetworkManager.leave_game()
	if NetworkManager.menu_scene_path.is_empty():
		queue_free()


## Public red-menu entry point. A client sends only the source claim; the server
## derives the owner from the RPC sender. A host/single-player call is accepted
## only for its own local peer, so this API cannot be used to name another body.
func request_drop(
		peer_id: int,
		source: String,
		index: int,
		expected_item_id: String
	) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id:
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if multiplayer.is_server():
		_server_drop(local_id, source, index, expected_item_id,
			player.inventory_generation())
		return
	player.sync_loadout_to_server()
	_request_drop_from_client.rpc_id(
		1, source, index, expected_item_id, player.inventory_generation())


@rpc("any_peer", "call_remote", "reliable")
func _request_drop_from_client(
		source: String,
		index: int,
		expected_item_id: String,
		generation: int
	) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		return
	_server_drop(sender, source, index, expected_item_id, generation)


## Public DroppedItem entry point, with the same sender derivation as drop.
func request_pickup(pickup_id: int, peer_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id:
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if multiplayer.is_server():
		_server_pickup(local_id, pickup_id, player.inventory_generation())
		return
	player.sync_loadout_to_server()
	_request_pickup_from_client.rpc_id(
		1, pickup_id, player.inventory_generation())


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup_from_client(pickup_id: int, generation: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1:
		return
	_server_pickup(sender, pickup_id, generation)


## Returns the spawned id for focused tests; public callers intentionally ignore
## it and learn the result through the reliable spawn/confirmation messages.
func _server_drop(
		peer_id: int,
		source: String,
		index: int,
		expected_item_id: String,
		generation: int
	) -> int:
	if not multiplayer.is_server() or not _is_physical_item(expected_item_id):
		return 0
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if not is_instance_valid(player) or not player.authoritative_inventory_ready() \
			or generation != player.inventory_generation() \
			or not _source_accepts_item(source, expected_item_id) \
			or player.physical_item_at(source, index) != expected_item_id:
		return 0

	# The finite item leaves canonical inventory before an id is allocated or a
	# world node exists. A failed claim therefore cannot create anything.
	if not player.authoritative_remove_item(source, index, expected_item_id):
		return 0
	var next_generation := player.advance_inventory_generation()
	var pickup_id := _next_pickup_id
	_next_pickup_id += 1
	var at_transform := _drop_transform(player)
	_pickups[pickup_id] = {
		"item_id": expected_item_id,
		"transform": at_transform,
		"claimed": false,
	}
	_spawn_pickup_local(pickup_id, expected_item_id, at_transform)
	if multiplayer.has_multiplayer_peer():
		_spawn_pickup.rpc(pickup_id, expected_item_id, at_transform)

	# The host already mutated its owning container above. A remote owner takes
	# the same normal container callback path on confirmation, preserving dress,
	# held-item replication and local persistence.
	if peer_id != multiplayer.get_unique_id():
		_confirm_drop.rpc_id(peer_id, pickup_id, source, index,
			expected_item_id, next_generation)
	return pickup_id


func _server_pickup(peer_id: int, pickup_id: int, generation: int) -> bool:
	if not multiplayer.is_server():
		return false
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	var record: Dictionary = _pickups.get(pickup_id, {})
	if not is_instance_valid(player) or not player.authoritative_inventory_ready() \
			or generation != player.inventory_generation() or record.is_empty() \
			or bool(record.get("claimed", false)):
		return false
	var item_id := str(record.get("item_id", ""))
	var at_transform: Transform3D = record.get(
		"transform", Transform3D.IDENTITY)
	if not _is_physical_item(item_id) \
			or player.global_position.distance_to(at_transform.origin) \
				> PICKUP_MAX_DISTANCE \
			or player.backpack_slot_for(item_id) < 0:
		return false

	# Claim first. A second request arriving anywhere below this line sees the
	# flag (or, after despawn, no record) and cannot grant the same finite item.
	record["claimed"] = true
	_pickups[pickup_id] = record
	var backpack_index := player.authoritative_grant_backpack(item_id)
	if backpack_index < 0:
		record["claimed"] = false
		_pickups[pickup_id] = record
		return false
	var next_generation := player.advance_inventory_generation()
	if peer_id != multiplayer.get_unique_id():
		_grant_pickup.rpc_id(peer_id, pickup_id, item_id,
			backpack_index, next_generation)
	_despawn_pickup_local(pickup_id)
	if multiplayer.has_multiplayer_peer():
		_despawn_pickup.rpc(pickup_id)
	return true


@rpc("authority", "call_remote", "reliable")
func _confirm_drop(
		pickup_id: int,
		source: String,
		index: int,
		item_id: String,
		generation: int
	) -> void:
	var player := local_player()
	if is_instance_valid(player):
		player.confirm_authoritative_drop(
			pickup_id, source, index, item_id, generation)


@rpc("authority", "call_remote", "reliable")
func _grant_pickup(
		pickup_id: int,
		item_id: String,
		backpack_index: int,
		generation: int
	) -> void:
	var player := local_player()
	if is_instance_valid(player):
		player.grant_authoritative_pickup(
			pickup_id, item_id, backpack_index, generation)


@rpc("authority", "call_remote", "reliable")
func _spawn_pickup(
		pickup_id: int,
		item_id: String,
		at_transform: Transform3D
	) -> void:
	_spawn_pickup_local(pickup_id, item_id, at_transform)


func _spawn_pickup_local(
		pickup_id: int,
		item_id: String,
		at_transform: Transform3D
	) -> void:
	if pickup_id <= 0 or not _is_physical_item(item_id):
		return
	var existing := _pickup_nodes.get(pickup_id) as DroppedItem
	if is_instance_valid(existing):
		return
	_pickups[pickup_id] = {
		"item_id": item_id,
		"transform": at_transform,
		"claimed": false,
	}
	var dropped := DroppedItem.new()
	dropped.configure(pickup_id, item_id)
	add_child(dropped, true)
	dropped.global_transform = at_transform
	dropped.reset_physics_interpolation()
	_pickup_nodes[pickup_id] = dropped


@rpc("authority", "call_remote", "reliable")
func _despawn_pickup(pickup_id: int) -> void:
	_despawn_pickup_local(pickup_id)


func _despawn_pickup_local(pickup_id: int) -> void:
	_pickups.erase(pickup_id)
	var dropped := _pickup_nodes.get(pickup_id) as DroppedItem
	_pickup_nodes.erase(pickup_id)
	if is_instance_valid(dropped):
		dropped.queue_free()


func _is_physical_item(item_id: String) -> bool:
	return not item_id.is_empty() and ItemDB.has_item(item_id) \
		and not ItemDB.is_ability(item_id)


func _source_accepts_item(source: String, item_id: String) -> bool:
	match source:
		"equipment":
			return ItemDB.is_apparel(item_id)
		"hotbar":
			return ItemDB.accepts_hotbar(item_id)
		"backpack":
			return ItemDB.accepts_backpack(item_id)
	return false


## Stands the pickup on the finest terrain query, one player-width ahead along
## the globe. Basis +Y follows the sampled terrain normal and -Z keeps facing in
## the player's projected forward direction.
func _drop_transform(player: OnlinePlayer) -> Transform3D:
	var up := player.global_basis.y.normalized()
	if up.length_squared() < 0.5:
		up = Vector3.UP
	var forward := -player.global_basis.z
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.0001:
		forward = player.global_basis.x
	forward = forward.normalized()

	var planet := get_node_or_null("Planet") as Planet
	if planet == null or planet.shape == null:
		return Transform3D(_upright_basis(forward, up),
			player.global_position + forward * DROP_FORWARD_DISTANCE
				+ up * DROP_SURFACE_CLEARANCE)

	var player_local := planet.to_local(player.global_position)
	if player_local.length_squared() < 1.0:
		return Transform3D(_upright_basis(forward, up),
			player.global_position + forward * DROP_FORWARD_DISTANCE
				+ up * DROP_SURFACE_CLEARANCE)
	var radial := player_local.normalized()
	var forward_local := planet.global_basis.inverse() * forward
	forward_local -= radial * forward_local.dot(radial)
	if forward_local.length_squared() < 0.0001:
		var hint := Vector3.FORWARD if absf(radial.z) < 0.9 else Vector3.RIGHT
		forward_local = (hint - radial * hint.dot(radial)).normalized()
	else:
		forward_local = forward_local.normalized()
	var angle := DROP_FORWARD_DISTANCE / maxf(planet.shape.radius, 1.0)
	var direction := (
		radial * cos(angle) + forward_local * sin(angle)).normalized()
	var spacing := planet.finest_spacing()
	var normal := planet.shape.normal_at(direction, spacing).normalized()
	var surface := planet.shape.surface_point(direction, spacing)
	var facing := forward_local - normal * forward_local.dot(normal)
	if facing.length_squared() < 0.0001:
		facing = direction.cross(normal)
	return planet.global_transform * Transform3D(
		_upright_basis(facing.normalized(), normal),
		surface + normal * DROP_SURFACE_CLEARANCE)


func _upright_basis(forward: Vector3, up: Vector3) -> Basis:
	up = up.normalized()
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.0001:
		var hint := Vector3.FORWARD if absf(up.z) < 0.9 else Vector3.RIGHT
		forward = hint - up * hint.dot(up)
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	return Basis(right, up, right.cross(up).normalized()).orthonormalized()


func _on_player_registered(peer_id: int, metadata: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_spawn_player.rpc(peer_id, metadata, _spawn_transform(peer_id), true)


## [param in_flight] is for the spawn markers, which hang in orbit with nothing
## under them. A player rebuilt from a late joiner's snapshot is placed wherever
## they already were, and their real stance arrives on the next sync packet.
@rpc("authority", "call_local", "reliable")
func _spawn_player(peer_id: int, metadata: Dictionary, at_transform: Transform3D, in_flight: bool) -> void:
	if _spawned_players.has(peer_id):
		return
	var player := PLAYER_SCENE.instantiate() as OnlinePlayer
	player.name = str(peer_id)
	player.peer_id = peer_id
	player.display_name = str(metadata.get("name", "Player"))
	# The home screen still owns the viewport and the mouse; it hands both to the
	# body at the end of its sweep rather than losing them the moment it spawns.
	# Keep that body hidden too: it occupies the preview's exact transform, and
	# rendering both for even one handover frame makes their surfaces z-fight in
	# black patches that look like the old character-shadow flicker.
	player.defer_camera = is_instance_valid(_home_screen) \
		and peer_id == multiplayer.get_unique_id()
	if player.defer_camera:
		player.visible = false
		player.controls_enabled = false
	add_child(player, true)
	# Look arrives with the roster metadata so every peer builds the same body
	# before the first sync packet. The home screen can override the local peer
	# with the preview that was just on screen.
	var look := {
		"body": metadata.get("body", CharacterDB.DEFAULT_BODY),
		"skin": metadata.get("skin", ""),
		"worn": metadata.get("worn", {}),
		"tints": metadata.get("tints", {}),
	}
	if _has_look_override and peer_id == multiplayer.get_unique_id():
		look = _look_override.duplicate(true)
		_has_look_override = false
	player.apply_look(look)
	player.global_transform = at_transform
	# This is a spawn/teleport, not movement between two physics ticks. Without
	# resetting, interpolation draws one frame between the scene origin and the
	# orbital or home-screen handover position.
	player.reset_physics_interpolation()
	player.reset_network_state(at_transform)
	if in_flight:
		player.start_flying()
	_spawned_players[peer_id] = player


@rpc("authority", "call_local", "reliable")
func _despawn_player(peer_id: int) -> void:
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	_spawned_players.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()


@rpc("any_peer", "reliable")
func _request_world_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var snapshots: Array = []
	for peer_id in NetworkManager.players:
		var id := int(peer_id)
		var player := _spawned_players.get(id) as OnlinePlayer
		var player_transform := player.global_transform if is_instance_valid(player) else _spawn_transform(id)
		var meta: Dictionary = NetworkManager.get_player_metadata(id)
		snapshots.append({
			"peer_id": id,
			"metadata": meta,
			"transform": player_transform,
			# Clothes and weapons are broadcast when they change, so a peer joining
			# later has to be told what everyone already has on and in hand.
			"worn": player.worn_items() if is_instance_valid(player) else PackedStringArray(),
			"held": player.held_item() if is_instance_valid(player) else "",
			"body": player.body_id() if is_instance_valid(player) else str(meta.get("body", CharacterDB.DEFAULT_BODY)),
		})
	# A joining peer loaded this scene later than the host. Send the host's sky
	# phase with the same snapshot so both see the same day rather than each
	# beginning their own sixteen-minute clock at noon. The ground they arrive on
	# has to match too: the craters cut before they joined and the plants already
	# cleared away are as much world state as the sky is.
	_receive_world_state.rpc_id(
		sender, snapshots, celestial_cycle.phase(), pickup_snapshots(),
		scar_snapshot(), flora_snapshot())


@rpc("authority", "reliable")
func _receive_world_state(
		snapshots: Array,
		day_phase := -1.0,
		pickup_state: Array = [],
		scar_state: Array = [],
		flora_state: Dictionary = {}
	) -> void:
	if float(day_phase) >= 0.0:
		celestial_cycle.set_phase(float(day_phase))
	apply_scar_snapshot(scar_state)
	apply_flora_snapshot(flora_state)
	for snapshot_variant in snapshots:
		if not snapshot_variant is Dictionary:
			continue
		var snapshot: Dictionary = snapshot_variant
		var peer_id := int(snapshot.get("peer_id", 0))
		var meta: Dictionary = snapshot.get("metadata", {})
		if snapshot.has("body"):
			meta = meta.duplicate(true)
			meta["body"] = snapshot.get("body")
		_spawn_player(
			peer_id,
			meta,
			snapshot.get("transform", Transform3D.IDENTITY),
			false
		)
		var player := _spawned_players.get(peer_id) as OnlinePlayer
		if is_instance_valid(player):
			player.apply_worn(snapshot.get("worn", PackedStringArray()))
			player.apply_held(String(snapshot.get("held", "")))
	for pickup_variant in pickup_state:
		if not pickup_variant is Dictionary:
			continue
		var pickup: Dictionary = pickup_variant
		_spawn_pickup_local(
			int(pickup.get("pickup_id", 0)),
			str(pickup.get("item_id", "")),
			pickup.get("transform", Transform3D.IDENTITY))


func _spawn_transform(peer_id: int) -> Transform3D:
	if _has_spawn_override and peer_id == multiplayer.get_unique_id():
		return _spawn_override
	var points := spawn_points.get_children()
	if points.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0))
	var index := posmod(peer_id - 1, points.size())
	return (points[index] as Node3D).global_transform
