class_name GameWorld
extends Node3D

## The world is also the home screen. It is loaded once, empty, and the menu is a
## camera and an overlay put over it (see ui/menu/home_screen.gd); players are
## spawned only once a session exists. Nothing between the title and playing is a
## scene change, which is what keeps the planet's quadtree built across it.

const PLAYER_SCENE := preload("res://game/player/player.tscn")

## The title view opens at the light the authored cycle reaches after three
## minutes: low over the Colony Ship and close to local sunset.
const HOME_SUN_ADVANCE_SECONDS := 180.0
## Phase zero is noon over the Colony Ship. Advancing three quarters of the
## orbit places that anchor on the morning terminator: 06:00 and sunrise.
const GAMEPLAY_SUNRISE_PHASE := 0.75
const DROP_FORWARD_DISTANCE := 1.55
const DROP_SURFACE_CLEARANCE := 0.08
## Slightly wider than the 2.4 m interaction ray to allow for the player's eye,
## the pickup's raised centre and a sloping surface, but still an arm's-length
## server check rather than trusting that a client ray hit.
const PICKUP_MAX_DISTANCE := 3.2
## Specialty panels can remain open for a step beyond the interaction ray, but
## every transaction is still tied to the completed building that opened it.
const SPECIALTY_HOUSE_MAX_DISTANCE := 5.0
## How often the host tells everyone what has actually broken. Slower than the
## damage itself, because this is a correction and not the mechanism: the peers
## have already worked it out for themselves.
const FLORA_CONFIRM_INTERVAL := 0.4
## A client owns its movement simulation, so a flora contact reaches the host
## after the corresponding movement packet. At the fastest authored run that
## can be about ten metres of travel; this margin accepts that lag while still
## rejecting claims made elsewhere on the planet.
const FLORA_BIOMASS_MAX_DISTANCE := 32.0
## Deliberately free city-menu grant. The client sends no amount, so every accepted
## press is exactly one hundred biomass regardless of the player's carried bank.
const CITY_BIOMASS_GRANT := 100.0
const SETTLEMENT_LAUNCHER_ABILITY := "settlement_launcher"
const BUILDING_ABILITY := "building"
## How far from the ship the host will still honour a RELEASE SETTLERS press.
## Generous next to the 2.4 m interaction ray, because the ship is 26 m tall and
## the panel stays open while the player moves, but still a check that they are
## at it rather than across the planet from it.
const SETTLER_RELEASE_MAX_DISTANCE := 40.0
const RESPAWN_CLEARANCE := 0.35
## Outside the ship's roughly twelve-metre footprint, but still visibly at it.
const RESPAWN_SPACING := 14.0
## Shoulder-to-shoulder separation at the orbital start used by an online
## sandbox. Wide enough that two flight capsules cannot begin intersecting, but
## close enough that the party enters the world as one visible group.
const ONLINE_SANDBOX_SPAWN_SPACING := 4.0
const SANDBOX_MODE := "sandbox"
const SANDBOX_SNAPSHOT_VERSION := 1
const SANDBOX_SAVE_STATE_GROUP := &"sandbox_save_state"

@onready var spawn_points: Node3D = $SpawnPoints
@onready var celestial_cycle: CelestialCycle = $CelestialCycle

var _spawned_players: Dictionary = {}
## On the server these are the authoritative finite world records. Clients keep
## the replicated subset in the same shape so duplicate join/live spawns and
## despawns are harmless.
var _pickups: Dictionary = {}
var _pickup_nodes: Dictionary = {}
var _next_pickup_id := 1
var _shop_request_sequence := 0
var _last_shop_request_by_peer: Dictionary = {}
var _settlement_request_sequence := 0
var _last_settlement_request_by_peer: Dictionary = {}
var _ability_constructs: Dictionary = {}
var _next_ability_construct_id := 1
var _locally_paused := false
var _simulation_frozen := false
var _time_scale_before_pause := 1.0
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
## Host-only respawn counter per player peer id, so a late or duplicated
## respawn packet cannot put an already-living body back at the colony.
var _respawn_sequence: Dictionary = {}
## Stable host-assigned formation slot per online sandbox player. Peer ids from
## Steam and ENet are identities, not roster indices; modulo-ing one by the
## number of authored markers can put two different peers on the same marker.
var _sandbox_spawn_slots: Dictionary = {}


func _ready() -> void:
	# The GameMenu opts into ALWAYS processing itself. The world must remain
	# pausable so its inherited gameplay, physics, audio, timers, and animations
	# all stop beneath that menu in a single-player session.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	NetworkManager.active_world = self
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_left.connect(_despawn_player)
	NetworkManager.session_started.connect(_begin_session)

	if NetworkManager.state == NetworkManager.SessionState.IN_GAME:
		_begin_session()
	else:
		_open_home_screen()


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
	_last_shop_request_by_peer.clear()
	_ability_constructs.clear()
	_respawn_sequence.clear()
	_sandbox_spawn_slots.clear()


func local_player() -> OnlinePlayer:
	return _spawned_players.get(multiplayer.get_unique_id()) as OnlinePlayer


func planet() -> Planet:
	return get_node_or_null("Planet") as Planet


## Stable ids are allocated only by the host and then carried by the caster's
## approved spawn event to every peer.
func allocate_ability_construct_id() -> int:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return 0
	var next_id := _next_ability_construct_id
	_next_ability_construct_id += 1
	return next_id


func spawn_ability_barrier_local(construct_id: int, owner_peer: int,
		at: Transform3D, size: Vector3, duration: float,
		fade_duration: float, tint: Color,
		initial_alpha := 0.52) -> AbilityBarrier:
	if construct_id <= 0:
		return null
	var existing := _ability_constructs.get(construct_id) as AbilityBarrier
	if is_instance_valid(existing):
		return existing
	var barrier := AbilityBarrier.create(
		self, construct_id, owner_peer, at, size,
		duration, fade_duration, tint, initial_alpha)
	if barrier == null:
		return null
	_ability_constructs[construct_id] = barrier
	barrier.expired.connect(_on_ability_construct_expired)
	barrier.tree_exited.connect(func() -> void:
		if _ability_constructs.get(construct_id) == barrier:
			_ability_constructs.erase(construct_id)
	)
	return barrier


func _on_ability_construct_expired(construct_id: int) -> void:
	if multiplayer.has_multiplayer_peer():
		if multiplayer.is_server():
			_apply_ability_construct_despawn.rpc(construct_id)
		return
	_apply_ability_construct_despawn(construct_id)


@rpc("authority", "call_local", "reliable")
func _apply_ability_construct_despawn(construct_id: int) -> void:
	if construct_id <= 0:
		return
	var barrier := _ability_constructs.get(construct_id) as AbilityBarrier
	_ability_constructs.erase(construct_id)
	if is_instance_valid(barrier):
		barrier.queue_free()


func ability_construct_snapshot() -> Array:
	var snapshot: Array = []
	for id_variant: Variant in _ability_constructs:
		var construct_id := int(id_variant)
		var barrier := _ability_constructs.get(construct_id) as AbilityBarrier
		if not is_instance_valid(barrier) or barrier.remaining() <= 0.0:
			continue
		snapshot.append({
			"construct_id": construct_id,
			"owner_peer": barrier.owner_peer,
			"transform": barrier.global_transform,
			"size": barrier.size(),
			"remaining": barrier.remaining(),
			"fade_duration": barrier.fade_duration(),
			"tint": barrier.tint(),
			"alpha": barrier.current_alpha(),
		})
	return snapshot


func apply_ability_construct_snapshot(snapshot: Array) -> void:
	for entry_variant: Variant in snapshot:
		if not entry_variant is Dictionary:
			continue
		var entry := entry_variant as Dictionary
		spawn_ability_barrier_local(
			int(entry.get("construct_id", 0)),
			int(entry.get("owner_peer", 0)),
			entry.get("transform", Transform3D.IDENTITY),
			entry.get("size", Vector3(8.0, 4.0, 0.35)),
			float(entry.get("remaining", 0.0)),
			float(entry.get("fade_duration", 0.0)),
			entry.get("tint", Color(0.27, 0.69, 1.0)),
			float(entry.get("alpha", 0.52)))


## Which sites have been settled, for a peer that joined after somebody pressed
## the button. Only the founding facts travel: the ground a colony was measured
## against is the same height field on every peer, so the grid, the claim and the
## wall are rebuilt locally rather than sent.
func colony_snapshot() -> Array:
	var colonies := meep_colonies()
	return colonies.snapshot() if colonies != null else []


func apply_colony_snapshot(snapshot: Array,
		watchers := PackedVector3Array()) -> void:
	var colonies := meep_colonies()
	if colonies != null:
		colonies.apply_snapshot(snapshot, watchers)


## Planet-space directions of the players a save is about to put back, for
## [method MeepColonies.apply_snapshot] to judge residency by.
func _saved_watchers(saved_players: Variant) -> PackedVector3Array:
	var found := PackedVector3Array()
	var planet := get_node_or_null("Planet") as Planet
	if planet == null or not saved_players is Array:
		return found
	for entry_variant: Variant in saved_players as Array:
		if not entry_variant is Dictionary:
			continue
		var placed: Variant = (entry_variant as Dictionary).get("transform", null)
		if not placed is Transform3D or not (placed as Transform3D).is_finite():
			continue
		var direction := planet.to_local((placed as Transform3D).origin)
		if direction.length_squared() < 1.0:
			continue
		found.push_back(direction.normalized())
	return found


## One host-owned document containing every durable sandbox system. The same
## component snapshots used to catch up a late multiplayer joiner are reused
## here, with the cold-restore-only details (full player, Meeps, fauna, counters,
## and opt-in scene objects) included alongside them.
func sandbox_snapshot() -> Dictionary:
	var players: Array = []
	var peer_ids := _spawned_players.keys()
	peer_ids.sort()
	for peer_value: Variant in peer_ids:
		var player := _spawned_players.get(int(peer_value)) as OnlinePlayer
		if is_instance_valid(player):
			players.append(player.sandbox_snapshot())
	var fauna := get_node_or_null("Planet/FaunaPopulations") as FaunaSpawner
	return {
		"schema_version": SANDBOX_SNAPSHOT_VERSION,
		"mode": SANDBOX_MODE,
		"celestial": {
			"phase": celestial_cycle.phase(),
			"day_index": celestial_cycle.day_index(),
		},
		"counters": {
			"next_pickup_id": _next_pickup_id,
			"next_ability_construct_id": _next_ability_construct_id,
			"respawn_sequence": _respawn_sequence.duplicate(true),
		},
		"pickups": pickup_snapshots(),
		"scars": scar_snapshot(),
		"flora": flora_snapshot(),
		"bosses": boss_snapshots(),
		"ability_constructs": ability_construct_snapshot(),
		"colonies": colony_snapshot(),
		"fauna": fauna.sandbox_snapshot() \
			if fauna != null and fauna.snapshot_ready() else {},
		"players": players,
		"scene_objects": _sandbox_scene_object_snapshot(),
	}


func save_sandbox(save_id := "", display_name := "") -> Dictionary:
	if not _sandbox_save_allowed():
		return {
			"ok": false,
			"message": "Named saves are currently available in single-player Sandbox mode.",
		}
	# Traced because a save is one long synchronous frame — the whole planet's colonies,
	# flora ledger and scars serialized and written — and an exported capture that
	# happens to contain one should name it rather than leave a multi-second frame
	# looking like a mystery.
	var began := Time.get_ticks_usec()
	var snapshot := sandbox_snapshot()
	var gathered := Time.get_ticks_usec()
	RuntimeTelemetry.record_activity(&"save", &"gather_snapshot",
		gathered - began)
	var result := SaveManager.overwrite_save(save_id, snapshot) \
		if not save_id.is_empty() \
		else SaveManager.create_save(display_name, SANDBOX_MODE, snapshot)
	RuntimeTelemetry.record_activity(&"save", &"write_file",
		Time.get_ticks_usec() - gathered)
	RuntimeTelemetry.mark_event(&"sandbox_save", save_id if not save_id.is_empty()
		else display_name, {"gather_ms": float(gathered - began) / 1000.0})
	if bool(result.get("ok", false)):
		NetworkManager.session_options["save_id"] = String(result.get("id", ""))
		NetworkManager.session_options["save_name"] = String(
			result.get("name", display_name))
	return result


func load_sandbox_save(save_id: String) -> Dictionary:
	if not _sandbox_save_allowed():
		return {
			"ok": false,
			"message": "Named saves are currently available in single-player Sandbox mode.",
		}
	var result := SaveManager.load_save(save_id, SANDBOX_MODE)
	if not bool(result.get("ok", false)):
		return result
	set_local_pause(false)
	var error: Error = NetworkManager.reload_single_player_from_save(save_id)
	if error != OK:
		return {
			"ok": false,
			"message": "Could not reload the sandbox (%s)." % error_string(error),
		}
	return result


func active_save_id() -> String:
	return String(NetworkManager.session_options.get("save_id", "")) \
		if _sandbox_save_allowed() else ""


func _sandbox_save_allowed() -> bool:
	return NetworkManager.state == NetworkManager.SessionState.IN_GAME \
		and NetworkManager.is_single_player and NetworkManager.is_host \
		and String(NetworkManager.session_options.get("mode", "")) == SANDBOX_MODE


func _sandbox_scene_object_snapshot() -> Dictionary:
	var state: Dictionary = {}
	for value: Variant in get_tree().get_nodes_in_group(
			SANDBOX_SAVE_STATE_GROUP):
		var node := value as Node
		if node == null or not DamageHit.in_same_world(self, node) \
				or not node.has_method(&"sandbox_snapshot"):
			continue
		var snapshot_value: Variant = node.call(&"sandbox_snapshot")
		if snapshot_value is Dictionary:
			state[String(get_path_to(node))] = (
				snapshot_value as Dictionary).duplicate(true)
	return state


func _apply_sandbox_scene_object_snapshot(state: Dictionary) -> void:
	for path_text: String in state:
		var node := _relative_world_node(path_text)
		var snapshot_value: Variant = state[path_text]
		if node != null and node.has_method(&"apply_sandbox_snapshot") \
				and snapshot_value is Dictionary:
			node.call(&"apply_sandbox_snapshot", snapshot_value)


func active_ability_wall_count() -> int:
	var count := 0
	for barrier_variant: Variant in _ability_constructs.values():
		if is_instance_valid(barrier_variant):
			count += 1
	return count


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
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
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
			# Read back off a scar rather than out of the wire, so the widest
			# reach of a warped rim is the thing invalidated here too.
			var scar := TerrainScars.Scar.from_wire(entry)
			world_planet.mark_region_stale(
				scar.direction, scar.outer, scar.depth)


## What every flora field has lost so far, keyed by the field's path under this
## world. Paths rather than names because the fields are scattered through the
## planet's children, and every peer loads the same scene so the same path
## resolves to the same field.
func flora_snapshot() -> Dictionary:
	var state := {}
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		if not (field is Node) or not DamageHit.in_same_world(self, field) \
				or not field.has_method(&"broken_keys"):
			continue
		var keys: PackedInt32Array = field.call(&"broken_keys")
		if not keys.is_empty():
			state[String(get_path_to(field))] = keys
	return state


func apply_flora_snapshot(state: Dictionary) -> void:
	for path: String in state:
		_apply_flora_breaks(path, state[path])


# --- Colony respawn ---------------------------------------------------------

## Asked for by the death screen, rather than run down by a clock: being dead is
## the one moment a player is reading the screen instead of the world, and a
## timer that takes the body back mid-sentence loses them the only account they
## get of what killed them.
@rpc("any_peer", "call_local", "reliable")
func request_colony_respawn() -> void:
	if not _is_host_authority():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		sender = multiplayer.get_unique_id()
	var player := _spawned_players.get(sender) as OnlinePlayer
	if not is_instance_valid(player) or not player.is_dead():
		return
	respawn_player_at_colony(sender)


func respawn_player_at_colony(peer_id: int) -> bool:
	if not _is_host_authority():
		return false
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if not is_instance_valid(player):
		return false
	var sequence := int(_respawn_sequence.get(peer_id, 0)) + 1
	_respawn_sequence[peer_id] = sequence
	var at_transform := safe_colony_respawn_transform(peer_id)
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_apply_colony_respawn.rpc(peer_id, at_transform, sequence)
	else:
		_apply_colony_respawn(peer_id, at_transform, sequence)
	return true


## Terrain-sampled, deterministic positions beside the colony ship (or the
## landing site fallback). The host computes and broadcasts the exact transform,
## so peers need not agree on their local terrain streaming state that frame.
func safe_colony_respawn_transform(peer_id: int) -> Transform3D:
	var anchor := get_node_or_null("Planet/ColonyShip") as Node3D
	if anchor == null:
		anchor = get_node_or_null("Planet/LandingSite") as Node3D
	if anchor == null:
		return _spawn_transform(peer_id)
	var world_planet := planet()
	var up := anchor.global_basis.y.normalized()
	var forward := -anchor.global_basis.z
	forward -= up * forward.dot(up)
	if forward.length_squared() < 0.0001:
		forward = anchor.global_basis.x
	forward = forward.normalized()
	var right := forward.cross(up).normalized()
	var slot := posmod(peer_id - 1, 8)
	var angle := TAU * float(slot) / 8.0
	var offset := (right * cos(angle) + forward * sin(angle)) \
		* RESPAWN_SPACING
	if world_planet == null or world_planet.shape == null:
		return Transform3D(_upright_basis(forward, up),
			anchor.global_position + offset + up * RESPAWN_CLEARANCE)

	var local := world_planet.to_local(anchor.global_position + offset)
	if local.length_squared() < 1.0:
		return Transform3D(_upright_basis(forward, up),
			anchor.global_position + offset + up * RESPAWN_CLEARANCE)
	var direction := local.normalized()
	var spacing := world_planet.finest_spacing()
	var normal_local := world_planet.shape.normal_at(direction, spacing).normalized()
	var surface_local := world_planet.shape.surface_point(direction, spacing)
	var normal := (world_planet.global_basis * normal_local).normalized()
	var facing := forward - normal * forward.dot(normal)
	if facing.length_squared() < 0.0001:
		facing = right.cross(normal)
	return Transform3D(_upright_basis(facing.normalized(), normal),
		world_planet.to_global(surface_local) + normal * RESPAWN_CLEARANCE)


@rpc("authority", "call_local", "reliable")
func _apply_colony_respawn(peer_id: int, at_transform: Transform3D,
		sequence: int) -> void:
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if is_instance_valid(player):
		player.respawn_at(at_transform, sequence)


func _is_host_authority() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


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
		if not (field is Node) or not DamageHit.in_same_world(self, field) \
				or not field.has_method(&"drain_new_breaks"):
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


## Called by the body that actually simulated an impact. A remote owner sends
## only the deterministic field identity; the host derives the sender, confirms
## and records the break, computes the authored yield, then mutates the player's
## canonical carried bank.
func request_flora_biomass(peer_id: int, field: Node,
		key: PackedInt32Array, visual_height: float, at: Vector3) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id or not is_instance_valid(field) \
			or not DamageHit.in_same_world(self, field) or key.is_empty() \
			or not is_finite(visual_height) or not at.is_finite():
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	var path := String(get_path_to(field))
	if _is_host_authority():
		_server_flora_biomass(
			local_id, field, key, visual_height, at, true)
		return
	_request_flora_biomass_from_client.rpc_id(
		1, path, key, visual_height, at)


@rpc("any_peer", "call_remote", "reliable")
func _request_flora_biomass_from_client(path: String,
		key: PackedInt32Array, visual_height: float, at: Vector3) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	var field := _relative_world_node(path)
	_server_flora_biomass(
		sender, field, key, visual_height, at, false)


func _server_flora_biomass(peer_id: int, field: Node,
		key: PackedInt32Array, visual_height: float, at: Vector3,
		already_resolved: bool) -> void:
	if not _is_host_authority() or not is_instance_valid(field) \
			or not field.is_in_group(DamageHit.FIELD_GROUP) \
			or not DamageHit.in_same_world(self, field) \
			or not at.is_finite() or not is_finite(visual_height):
		return
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if not is_instance_valid(player) or player.is_dead() \
			or player.global_position.distance_to(at) \
				> FLORA_BIOMASS_MAX_DISTANCE:
		return
	var amount := 0.0
	if already_resolved:
		var value_method := &"impact_biomass_value" \
			if field.has_method(&"impact_biomass_value") else &"harvest_value"
		if field.has_method(value_method):
			var raw := float(field.call(value_method, visual_height))
			amount = maxf(roundf(raw), 1.0) if raw > 0.0 else 0.0
	elif field.has_method(&"claim_impact_biomass"):
		amount = float(field.call(
			&"claim_impact_biomass", key, visual_height, at))
	if is_finite(amount) and amount > 0.0:
		player.credit_biomass(amount, at)


## Resolves an untrusted client path without allowing an absolute path or `..`
## traversal to reach nodes outside this GameWorld.
func _relative_world_node(path_text: String) -> Node:
	var path := NodePath(path_text)
	if path.is_empty() or path.is_absolute():
		return null
	for index in path.get_name_count():
		if path.get_name(index) == &"..":
			return null
	return get_node_or_null(path)


## Undoes every break inside a sphere and reports how many plants stood back up.
##
## The sphere goes over the wire rather than the plants in it: flora is placed
## deterministically, so every peer can work out for itself which of its own
## instances the volume covers, exactly as it already does for the damage that
## broke them. Called by an encounter that resets the ground it was fought over.
func regrow_flora(centre: Vector3, radius: float) -> int:
	if not _is_host_authority():
		return 0
	if multiplayer.has_multiplayer_peer() and not multiplayer.get_peers().is_empty():
		_apply_flora_regrow.rpc(centre, radius)
	return _regrow_flora_here(centre, radius)


@rpc("authority", "call_remote", "reliable")
func _apply_flora_regrow(centre: Vector3, radius: float) -> void:
	_regrow_flora_here(centre, radius)


func _regrow_flora_here(centre: Vector3, radius: float) -> int:
	var restored := 0
	for field in get_tree().get_nodes_in_group(DamageHit.FIELD_GROUP):
		if not (field is Node) or not DamageHit.in_same_world(self, field) \
				or not field.has_method(&"restore_within"):
			continue
		restored += int(field.call(&"restore_within", centre, radius))
	return restored


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
	if celestial_cycle != null and celestial_cycle.period_seconds > 0.0:
		celestial_cycle.set_phase(
			HOME_SUN_ADVANCE_SECONDS / celestial_cycle.period_seconds)
	_home_screen = HomeScreen.new()
	_home_screen.name = "HomeScreen"
	_home_screen.frame = _spawn_transform(1)
	add_child(_home_screen)


func _begin_session() -> void:
	if _session_open:
		return
	_session_open = true
	if multiplayer.is_server():
		var saved := _selected_sandbox_snapshot()
		if not saved.is_empty():
			_begin_saved_sandbox(saved)
			return
		# The world is already rendering behind the title screen, but a new game
		# begins at sunrise over the colony rather than inheriting however long
		# the player spent in the menu. Joining clients receive this phase below.
		celestial_cycle.set_phase(GAMEPLAY_SUNRISE_PHASE)
		celestial_cycle.set_day_index(0)
		for peer_id in NetworkManager.players:
			_spawn_player(int(peer_id), NetworkManager.get_player_metadata(int(peer_id)), _spawn_transform(int(peer_id)), true)
	else:
		_request_world_state.rpc_id(1)


func _selected_sandbox_snapshot() -> Dictionary:
	if not NetworkManager.is_single_player \
			or String(NetworkManager.session_options.get("mode", "")) \
				!= SANDBOX_MODE:
		return {}
	var save_id := String(NetworkManager.session_options.get("save_id", ""))
	if save_id.is_empty():
		return {}
	var result := SaveManager.load_save(save_id, SANDBOX_MODE)
	if not bool(result.get("ok", false)):
		push_error("Could not load sandbox save '%s': %s" % [
			save_id, String(result.get("message", "invalid save"))])
		NetworkManager.session_options.erase("save_id")
		NetworkManager.session_options.erase("save_name")
		return {}
	var snapshot_value: Variant = result.get("snapshot", {})
	return (snapshot_value as Dictionary).duplicate(true) \
		if snapshot_value is Dictionary else {}


func _begin_saved_sandbox(snapshot: Dictionary) -> void:
	var celestial_value: Variant = snapshot.get("celestial", {})
	var celestial_state := celestial_value as Dictionary \
		if celestial_value is Dictionary else {}
	var phase := float(celestial_state.get("phase", GAMEPLAY_SUNRISE_PHASE))
	celestial_cycle.set_phase(
		clampf(phase, 0.0, 1.0) if is_finite(phase)
			else GAMEPLAY_SUNRISE_PHASE)
	celestial_cycle.set_day_index(maxi(
		int(celestial_state.get("day_index", 0)), 0))

	var counters_value: Variant = snapshot.get("counters", {})
	var counters := counters_value as Dictionary \
		if counters_value is Dictionary else {}
	_next_pickup_id = maxi(int(counters.get("next_pickup_id", 1)), 1)
	_next_ability_construct_id = maxi(
		int(counters.get("next_ability_construct_id", 1)), 1)
	var respawn_value: Variant = counters.get("respawn_sequence", {})
	_respawn_sequence = (respawn_value as Dictionary).duplicate(true) \
		if respawn_value is Dictionary else {}

	var scars: Variant = snapshot.get("scars", [])
	if scars is Array:
		apply_scar_snapshot(scars as Array)
	var flora: Variant = snapshot.get("flora", {})
	if flora is Dictionary:
		apply_flora_snapshot(flora as Dictionary)
	var colonies: Variant = snapshot.get("colonies", [])
	if colonies is Array:
		# Told where the players will be standing, because the registry decides
		# which cities to simulate in full from that and the bodies are not
		# spawned until further down. Without the hint every city on the planet
		# would be built here and all but the nearest freed a moment later.
		apply_colony_snapshot(colonies as Array,
			_saved_watchers(snapshot.get("players", [])))
	apply_boss_snapshots(snapshot.get("bosses", []))
	var constructs: Variant = snapshot.get("ability_constructs", [])
	if constructs is Array:
		apply_ability_construct_snapshot(constructs as Array)
	var scene_objects: Variant = snapshot.get("scene_objects", {})
	if scene_objects is Dictionary:
		_apply_sandbox_scene_object_snapshot(scene_objects as Dictionary)

	var saved_players: Variant = snapshot.get("players", [])
	for peer_value: Variant in NetworkManager.players.keys():
		var peer_id := int(peer_value)
		var player_state := _saved_player_snapshot(saved_players, peer_id)
		var metadata := NetworkManager.get_player_metadata(peer_id)
		var transform := _spawn_transform(peer_id)
		if not player_state.is_empty():
			var metadata_value: Variant = player_state.get("metadata", {})
			if metadata_value is Dictionary:
				metadata = (metadata_value as Dictionary).duplicate(true)
			var transform_value: Variant = player_state.get(
				"transform", transform)
			if transform_value is Transform3D \
					and (transform_value as Transform3D).is_finite():
				transform = transform_value as Transform3D
			NetworkManager.players[peer_id] = metadata.duplicate(true)
		_spawn_player(peer_id, metadata, transform, false)
		var player := _spawned_players.get(peer_id) as OnlinePlayer
		if player != null and not player_state.is_empty():
			player.apply_sandbox_snapshot(player_state)

	var pickups: Variant = snapshot.get("pickups", [])
	if pickups is Array:
		for pickup_value: Variant in pickups:
			if not pickup_value is Dictionary:
				continue
			var pickup := pickup_value as Dictionary
			var pickup_id := int(pickup.get("pickup_id", 0))
			_spawn_pickup_local(
				pickup_id,
				String(pickup.get("item_id", "")),
				pickup.get("transform", Transform3D.IDENTITY))
			_next_pickup_id = maxi(_next_pickup_id, pickup_id + 1)
	for construct_value: Variant in _ability_constructs.keys():
		_next_ability_construct_id = maxi(
			_next_ability_construct_id, int(construct_value) + 1)
	call_deferred(&"_finish_saved_sandbox_restore", snapshot.duplicate(true))


func _saved_player_snapshot(value: Variant, peer_id: int) -> Dictionary:
	if not value is Array:
		return {}
	var fallback: Dictionary = {}
	for row_value: Variant in value:
		if not row_value is Dictionary:
			continue
		var row := row_value as Dictionary
		if fallback.is_empty():
			fallback = row
		if int(row.get("peer_id", 0)) == peer_id:
			return row
	return fallback


func _finish_saved_sandbox_restore(snapshot: Dictionary) -> void:
	var fauna := get_node_or_null("Planet/FaunaPopulations") as FaunaSpawner
	for _attempt in 8:
		if fauna == null or fauna.snapshot_ready():
			break
		await get_tree().process_frame
	var fauna_value: Variant = snapshot.get("fauna", {})
	if fauna != null and fauna.snapshot_ready() and fauna_value is Dictionary:
		fauna.apply_sandbox_snapshot(fauna_value as Dictionary)


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
	var freeze_simulation := paused and NetworkManager.is_single_player
	if freeze_simulation == _simulation_frozen:
		get_tree().paused = freeze_simulation
		return
	_simulation_frozen = freeze_simulation
	if freeze_simulation:
		_time_scale_before_pause = Engine.time_scale
		if celestial_cycle != null:
			celestial_cycle.set_time_paused(true)
		# SceneTree pause stops nodes; zero time scale also freezes shader TIME,
		# so wind, water, clouds, lava, and other material animation do not keep
		# moving behind the translucent menu.
		Engine.time_scale = 0.0
		get_tree().paused = true
		return

	get_tree().paused = false
	Engine.time_scale = _time_scale_before_pause
	if celestial_cycle != null:
		celestial_cycle.set_time_paused(false)


## Whether a menu is holding this player out of the world. Not the same question as
## `get_tree().paused`, which is only true in single player, and the reason this is
## worth asking separately: in company the world keeps turning and this is still the
## honest answer to "am I in a menu".
func locally_paused() -> bool:
	return _locally_paused


## Drop the session and go back to the home screen. Reached from GameMenu's
## HOLD LEAVE action; the menu raises it rather than doing it, because what a
## world is is this node's business.
func leave_session() -> void:
	set_local_pause(false)
	NetworkManager.leave_game()
	if NetworkManager.menu_scene_path.is_empty():
		queue_free()


func meep_colonies() -> MeepColonies:
	return get_node_or_null("Planet/MeepColonies") as MeepColonies


## What [CityMenu] reads while it is open, for the colony a given ship controls.
## Empty rather than null for a site that has not been settled, so the panel has
## rows to draw before there is anything in them.
func colony_report(site: StringName) -> Dictionary:
	var colonies := meep_colonies()
	return colonies.report(site) if colonies != null else {}


## RELEASE SETTLERS. Same shape as [method request_pickup]: a client sends the
## claim and nothing else, the host derives who asked from the RPC sender, and a
## local call is accepted only for the caller's own body so this cannot be used
## to spend another player's ship.
func request_release_settlers(peer_id: int, site: StringName) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id:
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if _is_host_authority():
		_server_release_settlers(local_id, site)
		return
	_request_release_settlers_from_client.rpc_id(1, site)


@rpc("any_peer", "call_remote", "reliable")
func _request_release_settlers_from_client(site: StringName) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	_server_release_settlers(sender, site)


## The host's answer, and the only place a colony is founded. Checked against the
## ship's own position rather than trusting that the client's interaction ray hit
## something: the panel can be left open and walked away from.
func _server_release_settlers(peer_id: int, site: StringName) -> void:
	if not _is_host_authority():
		return
	var colonies := meep_colonies()
	if colonies == null:
		return
	var ship := colonies.ship(site)
	if ship == null:
		return
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if not is_instance_valid(player) or player.is_dead():
		return
	if player.global_position.distance_to(ship.global_position) \
			> SETTLER_RELEASE_MAX_DISTANCE:
		return
	colonies.release_settlers(site)


## Transfers carried biomass to the city controlled by the open panel. Clients
## state only the desired amount; the server derives who asked, verifies that
## they are still at the ship, and debits its canonical player copy first.
func request_deposit_biomass(peer_id: int, site: StringName,
		amount: float) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id or not is_finite(amount) or amount <= 0.0:
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if _is_host_authority():
		_server_deposit_biomass(local_id, site, amount)
		return
	_request_deposit_biomass_from_client.rpc_id(1, site, amount)


@rpc("any_peer", "call_remote", "reliable")
func _request_deposit_biomass_from_client(site: StringName,
		amount: float) -> void:
	if not multiplayer.is_server() or not is_finite(amount) or amount <= 0.0:
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	_server_deposit_biomass(sender, site, amount)


func _server_deposit_biomass(peer_id: int, site: StringName,
		amount: float) -> void:
	if not _is_host_authority() or not is_finite(amount) or amount <= 0.0:
		return
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if colonies == null or not is_instance_valid(player) or player.is_dead():
		return
	var ship := colonies.ship(site)
	var colony := colonies.colony(site)
	if ship == null or colony == null or colony.count() <= 0 \
			or player.global_position.distance_to(ship.global_position) \
				> SETTLER_RELEASE_MAX_DISTANCE:
		return
	var transferred := player.take_biomass(amount)
	if transferred > 0.0:
		colonies.deposit_biomass(site, transferred)


## Free fixed-size city grant. The client cannot choose an amount and the host still
## requires a living local player beside this colony's ship.
func request_add_city_biomass(peer_id: int, site: StringName) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id:
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if _is_host_authority():
		_server_add_city_biomass(local_id, site)
		return
	_request_add_city_biomass_from_client.rpc_id(1, site)


@rpc("any_peer", "call_remote", "reliable")
func _request_add_city_biomass_from_client(site: StringName) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	_server_add_city_biomass(sender, site)


func _server_add_city_biomass(peer_id: int, site: StringName) -> void:
	if not _is_host_authority():
		return
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if colonies == null or not is_instance_valid(player) or player.is_dead():
		return
	var ship := colonies.ship(site)
	var colony := colonies.colony(site)
	if ship == null or colony == null or colony.count() <= 0 \
			or player.global_position.distance_to(ship.global_position) \
				> SETTLER_RELEASE_MAX_DISTANCE:
		return
	colonies.deposit_biomass(site, CITY_BIOMASS_GRANT)


## Requests one exact city purchase ID. The request carries neither a price nor a
## desired resulting level: both are canonical colony state on the host.
func request_city_purchase(peer_id: int, site: StringName,
		purchase_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id or not MeepColony.city_purchase_valid(purchase_id) \
			or MeepColony.is_harvester_rate_purchase(purchase_id):
		return
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if not is_instance_valid(player):
		return
	if _is_host_authority():
		_server_city_purchase(local_id, site, purchase_id)
		return
	_request_city_purchase_from_client.rpc_id(1, site, purchase_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_city_purchase_from_client(site: StringName,
		purchase_id: int) -> void:
	if not multiplayer.is_server() \
			or not MeepColony.city_purchase_valid(purchase_id) \
			or MeepColony.is_harvester_rate_purchase(purchase_id):
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	_server_city_purchase(sender, site, purchase_id)


func _server_city_purchase(peer_id: int, site: StringName,
		purchase_id: int) -> void:
	if not _is_host_authority() \
			or not MeepColony.city_purchase_valid(purchase_id) \
			or MeepColony.is_harvester_rate_purchase(purchase_id):
		return
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if colonies == null or not is_instance_valid(player) or player.is_dead():
		return
	var ship := colonies.ship(site)
	var colony := colonies.colony(site)
	if ship == null or colony == null or colony.count() <= 0 \
			or player.global_position.distance_to(ship.global_position) \
				> SETTLER_RELEASE_MAX_DISTANCE:
		return
	var launcher_record: Dictionary = {}
	if purchase_id == MeepColony.CityPurchase.SEND_SETTLEMENT:
		if not player.authoritative_progression_ready():
			return
		launcher_record = colonies.settlement_launcher_record(site)
		if launcher_record.is_empty():
			return
	var bought := colonies.purchase(site, purchase_id, peer_id)
	if bought and purchase_id == MeepColony.CityPurchase.SEND_SETTLEMENT:
		player.authoritative_grant_one_time_ability(
			SETTLEMENT_LAUNCHER_ABILITY, launcher_record)


## Building enters placement only when the host confirms that it is equipped and
## the owner still has a launch authorization from the selected parent city.
func request_settlement_ability(peer_id: int, parent: StringName) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id or parent == &"":
		return
	if _is_host_authority():
		_server_settlement_ability(local_id, parent)
		return
	_request_settlement_ability_from_client.rpc_id(1, parent)


@rpc("any_peer", "call_remote", "reliable")
func _request_settlement_ability_from_client(parent: StringName) -> void:
	if not multiplayer.is_server() or parent == &"":
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
	_server_settlement_ability(sender, parent)


func _server_settlement_ability(peer_id: int, parent: StringName) -> void:
	if not _is_host_authority():
		return
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if not is_instance_valid(player) \
			or not player._host_can_cast_ability(BUILDING_ABILITY):
		return
	var record := player.one_time_ability_record_matching(
		SETTLEMENT_LAUNCHER_ABILITY, "parent_site", String(parent))
	var colonies := meep_colonies()
	var ship := colonies.ship(parent) if colonies != null else null
	var colony := colonies.colony(parent) if colonies != null else null
	if record.is_empty() or ship == null or colony == null:
		return
	_notify_settlement_targeting(peer_id, parent)


func _notify_settlement_targeting(peer_id: int, site: StringName) -> void:
	if multiplayer.has_multiplayer_peer():
		_apply_settlement_targeting.rpc(peer_id, site)
	else:
		_apply_settlement_targeting(peer_id, site)


@rpc("authority", "call_local", "reliable")
func _apply_settlement_targeting(peer_id: int, site: StringName) -> void:
	if multiplayer.get_unique_id() != peer_id:
		return
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if is_instance_valid(player):
		player.begin_settlement_targeting(site)


func request_settlement_launch(peer_id: int, parent: StringName,
		target_direction: Vector3) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id or not target_direction.is_finite():
		return
	_settlement_request_sequence += 1
	if _is_host_authority():
		_server_settlement_launch(
			local_id, _settlement_request_sequence, parent, target_direction)
	else:
		_request_settlement_launch_from_client.rpc_id(
			1, _settlement_request_sequence, parent, target_direction)


@rpc("any_peer", "call_remote", "reliable")
func _request_settlement_launch_from_client(sequence: int,
		parent: StringName, target_direction: Vector3) -> void:
	if not multiplayer.is_server() or not target_direction.is_finite():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_settlement_request(sender, sequence):
		return
	_server_settlement_launch(sender, sequence, parent, target_direction)


func _server_settlement_launch(peer_id: int, sequence: int,
		parent: StringName, target_direction: Vector3) -> void:
	if not _is_host_authority() \
			or not _accept_settlement_request(peer_id, sequence, true) \
			or not target_direction.is_finite() \
			or absf(target_direction.length() - 1.0) > 0.01:
		return
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	var parent_ship := colonies.ship(parent) if colonies != null else null
	var parent_colony := colonies.colony(parent) if colonies != null else null
	var launcher_record := player.one_time_ability_record_matching(
		SETTLEMENT_LAUNCHER_ABILITY, "parent_site", String(parent)) \
			if is_instance_valid(player) else {}
	if colonies == null or not is_instance_valid(player) or player.is_dead() \
			or parent_ship == null or parent_colony == null \
			or not player._host_can_cast_ability(BUILDING_ABILITY) \
			or launcher_record.is_empty():
		return
	var child := colonies.launch_settlement(
		parent, target_direction, peer_id)
	if child != &"":
		player.authoritative_consume_one_time_ability(
			SETTLEMENT_LAUNCHER_ABILITY, "parent_site", String(parent))
		if multiplayer.has_multiplayer_peer():
			_apply_settlement_launch_accepted.rpc(peer_id, child)
		else:
			_apply_settlement_launch_accepted(peer_id, child)


@rpc("authority", "call_local", "reliable")
func _apply_settlement_launch_accepted(peer_id: int,
		_child: StringName) -> void:
	if multiplayer.get_unique_id() != peer_id:
		return
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	if is_instance_valid(player):
		player.cancel_settlement_targeting()


func settlement_preview_valid(parent: StringName,
		target_direction: Vector3) -> bool:
	var colonies := meep_colonies()
	return colonies != null \
		and colonies.valid_settlement_landing(parent, target_direction)


func request_settlement_rename(peer_id: int, site: StringName,
		wanted: String) -> void:
	var local_id := multiplayer.get_unique_id()
	if peer_id != local_id:
		return
	_settlement_request_sequence += 1
	if _is_host_authority():
		_server_settlement_rename(
			local_id, _settlement_request_sequence, site, wanted)
	else:
		_request_settlement_rename_from_client.rpc_id(
			1, _settlement_request_sequence, site, wanted)


@rpc("any_peer", "call_remote", "reliable")
func _request_settlement_rename_from_client(sequence: int,
		site: StringName, wanted: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_settlement_request(sender, sequence):
		return
	_server_settlement_rename(sender, sequence, site, wanted)


func _server_settlement_rename(peer_id: int, sequence: int,
		site: StringName, wanted: String) -> void:
	if not _is_host_authority() \
			or not _accept_settlement_request(peer_id, sequence, true):
		return
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	var lander := colonies.ship(site) if colonies != null else null
	var here := colonies.colony(site) if colonies != null else null
	if colonies == null or not is_instance_valid(player) or player.is_dead() \
			or lander == null or here == null or here.parent_site_id == &"" \
			or player.global_position.distance_to(lander.global_position) \
				> SETTLER_RELEASE_MAX_DISTANCE:
		return
	colonies.rename_settlement(site, wanted)


func _accept_settlement_request(peer_id: int, sequence: int,
		already_checked := false) -> bool:
	var last := int(_last_settlement_request_by_peer.get(peer_id, 0))
	if sequence <= last:
		return already_checked and sequence == last
	_last_settlement_request_by_peer[peer_id] = sequence
	return true


## Harvester levels deliberately have a separate building-local route. Allowing
## their append-only IDs through the ship menu would bypass the physical machine
## and proximity checks that make this interaction authoritative.
func request_harvester_upgrade(peer_id: int, site: StringName,
		structure_index: int, purchase_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if peer_id != local_id \
			or not MeepColony.is_harvester_rate_purchase(purchase_id) \
			or not is_instance_valid(player):
		return
	_shop_request_sequence += 1
	if _is_host_authority():
		_server_harvester_upgrade(
			local_id, site, structure_index, purchase_id)
	else:
		_request_harvester_upgrade_from_client.rpc_id(
			1, _shop_request_sequence, site, structure_index, purchase_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_harvester_upgrade_from_client(sequence: int,
		site: StringName, structure_index: int, purchase_id: int) -> void:
	if not multiplayer.is_server() \
			or not MeepColony.is_harvester_rate_purchase(purchase_id):
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_shop_request(sender, sequence):
		return
	_server_harvester_upgrade(
		sender, site, structure_index, purchase_id)


func _server_harvester_upgrade(peer_id: int, site: StringName,
		structure_index: int, purchase_id: int) -> bool:
	if not MeepColony.is_harvester_rate_purchase(purchase_id):
		return false
	var context := _specialty_context(peer_id, site, structure_index,
		MeepStructures.Kind.BIOMASS_HARVESTER, false)
	var colony := context.get("colony") as MeepColony
	return colony.try_city_purchase(purchase_id) if colony != null else false


func request_hat_purchase(peer_id: int, site: StringName,
		structure_index: int, item_id: String) -> void:
	var local_id := multiplayer.get_unique_id()
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if peer_id != local_id or not item_id in ItemDB.hat_shop_ids() \
			or not is_instance_valid(player):
		return
	player.sync_progression_to_server()
	player.sync_loadout_to_server()
	_shop_request_sequence += 1
	if _is_host_authority():
		_server_hat_purchase(
			local_id, site, structure_index, item_id)
	else:
		_request_hat_purchase_from_client.rpc_id(
			1, _shop_request_sequence, site, structure_index, item_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_hat_purchase_from_client(sequence: int, site: StringName,
		structure_index: int, item_id: String) -> void:
	if not multiplayer.is_server() or not item_id in ItemDB.hat_shop_ids():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_shop_request(sender, sequence):
		return
	_server_hat_purchase(sender, site, structure_index, item_id)


func _server_hat_purchase(peer_id: int, site: StringName,
		structure_index: int, item_id: String) -> bool:
	var context := _specialty_context(
		peer_id, site, structure_index, MeepStructures.Kind.HAT_HOUSE)
	var player := context.get("player") as OnlinePlayer
	var price := ItemDB.hat_price(item_id)
	if player == null or price < 0:
		return false
	# The host ledger is the transaction key. An owned carried hat routes through
	# the same validated request to equip/stow; an owned dropped hat is never reminted.
	if player.owns_hat(item_id):
		return player.authoritative_toggle_hat(item_id) \
			if player.owns_physical_item(item_id) else true
	if player.backpack_slot_for(item_id) < 0 or not player.can_spend_gold(price):
		return false
	var backpack_index := player.authoritative_grant_backpack(item_id)
	if backpack_index < 0:
		return false
	if not player.authoritative_spend_gold(price):
		player.authoritative_remove_item("backpack", backpack_index, item_id)
		return false
	if not player.authoritative_record_hat_purchase(item_id):
		player.authoritative_remove_item("backpack", backpack_index, item_id)
		return false
	var generation := player.advance_inventory_generation()
	var transaction_id := _next_pickup_id
	_next_pickup_id += 1
	if peer_id != multiplayer.get_unique_id():
		_grant_pickup.rpc_id(peer_id, transaction_id, item_id,
			backpack_index, generation)
	player.publish_authoritative_loadout()
	player.publish_authoritative_progression()
	return true


func request_ability_house_action(peer_id: int, site: StringName,
		structure_index: int, ability_id: String, action: int) -> void:
	var local_id := multiplayer.get_unique_id()
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if peer_id != local_id or not ItemDB.is_ability(ability_id) \
			or action < 0 or action >= OnlinePlayer.AbilityProgressAction.size() \
			or not is_instance_valid(player):
		return
	player.sync_loadout_to_server()
	player.sync_progression_to_server()
	_shop_request_sequence += 1
	if _is_host_authority():
		_server_ability_house_action(
			local_id, site, structure_index, ability_id, action)
	else:
		_request_ability_house_action_from_client.rpc_id(
			1, _shop_request_sequence, site, structure_index,
			ability_id, action)


@rpc("any_peer", "call_remote", "reliable")
func _request_ability_house_action_from_client(sequence: int,
		site: StringName, structure_index: int,
		ability_id: String, action: int) -> void:
	if not multiplayer.is_server() or not ItemDB.is_ability(ability_id) \
			or action < 0 or action >= OnlinePlayer.AbilityProgressAction.size():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_shop_request(sender, sequence):
		return
	_server_ability_house_action(
		sender, site, structure_index, ability_id, action)


func _server_ability_house_action(peer_id: int, site: StringName,
		structure_index: int, ability_id: String, action: int) -> bool:
	var context := _specialty_context(
		peer_id, site, structure_index, MeepStructures.Kind.ABILITIES_HOUSE)
	var player := context.get("player") as OnlinePlayer
	return player.authoritative_ability_action(ability_id, action) \
		if player != null else false


func request_ability_stat_upgrade(peer_id: int, site: StringName,
		structure_index: int, ability_id: String, stat_id: String) -> void:
	var local_id := multiplayer.get_unique_id()
	var player := _spawned_players.get(local_id) as OnlinePlayer
	if peer_id != local_id \
			or not ItemDB.ability_stat_valid(ability_id, stat_id) \
			or not is_instance_valid(player):
		return
	player.sync_loadout_to_server()
	player.sync_progression_to_server()
	_shop_request_sequence += 1
	if _is_host_authority():
		_server_ability_stat_upgrade(
			local_id, site, structure_index, ability_id, stat_id)
	else:
		_request_ability_stat_upgrade_from_client.rpc_id(
			1, _shop_request_sequence, site, structure_index,
			ability_id, stat_id)


@rpc("any_peer", "call_remote", "reliable")
func _request_ability_stat_upgrade_from_client(sequence: int,
		site: StringName, structure_index: int,
		ability_id: String, stat_id: String) -> void:
	if not multiplayer.is_server() \
			or not ItemDB.ability_stat_valid(ability_id, stat_id):
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _accept_shop_request(sender, sequence):
		return
	_server_ability_stat_upgrade(
		sender, site, structure_index, ability_id, stat_id)


func _server_ability_stat_upgrade(peer_id: int, site: StringName,
		structure_index: int, ability_id: String, stat_id: String) -> bool:
	var context := _specialty_context(
		peer_id, site, structure_index, MeepStructures.Kind.ABILITIES_HOUSE)
	var colony := context.get("colony") as MeepColony
	var player := context.get("player") as OnlinePlayer
	if colony == null or player == null \
			or not colony.abilities_house_stats_unlocked():
		return false
	return player.authoritative_ability_stat_upgrade(ability_id, stat_id)


func _accept_shop_request(peer_id: int, sequence: int) -> bool:
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(peer_id) \
			or sequence <= int(_last_shop_request_by_peer.get(peer_id, 0)):
		return false
	_last_shop_request_by_peer[peer_id] = sequence
	return true


func _specialty_context(peer_id: int, site: StringName,
		structure_index: int, expected_kind: int,
		requires_player_state := true) -> Dictionary:
	if not _is_host_authority():
		return {}
	var colonies := meep_colonies()
	var player := _spawned_players.get(peer_id) as OnlinePlayer
	var colony := colonies.colony(site) if colonies != null else null
	if player == null or colony == null or player.is_dead() \
			or (requires_player_state \
				and (not player.authoritative_inventory_ready() \
					or not player.authoritative_progression_ready())) \
			or not colony.specialty_interaction_valid(
				structure_index, expected_kind, player.global_position,
				SPECIALTY_HOUSE_MAX_DISTANCE):
		return {}
	return {
		"player": player,
		"colony": colony,
	}


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
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
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
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
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
	if not multiplayer.is_server() \
			or NetworkManager.state != NetworkManager.SessionState.IN_GAME:
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
	_respawn_sequence.erase(peer_id)
	_sandbox_spawn_slots.erase(peer_id)
	if is_instance_valid(player):
		if _is_host_authority():
			player.release_poke_ball_on_departure()
		player.queue_free()


@rpc("any_peer", "reliable")
func _request_world_state() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.state != NetworkManager.SessionState.IN_GAME \
			or not NetworkManager.is_peer_registered(sender):
		return
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
			"combat": player.combat_snapshot() if is_instance_valid(player) else {},
			"resources": player.resource_snapshot() if is_instance_valid(player) else {},
		})
	# A joining peer loaded this scene later than the host. Send the host's sky
	# phase with the same snapshot so both see the same day rather than each
	# beginning their own sixteen-minute clock at noon. The ground they arrive on
	# has to match too: the craters cut before they joined and the plants already
	# cleared away are as much world state as the sky is.
	_receive_world_state.rpc_id(
		sender, snapshots, celestial_cycle.phase(), pickup_snapshots(),
		scar_snapshot(), flora_snapshot(), boss_snapshots(),
		celestial_cycle.day_index(), ability_construct_snapshot(),
		colony_snapshot())


@rpc("authority", "reliable")
func _receive_world_state(
		snapshots: Array,
		day_phase := -1.0,
		pickup_state: Array = [],
		scar_state: Array = [],
		flora_state: Dictionary = {},
		boss_state: Variant = {},
		day_number := 0,
		ability_construct_state: Array = [],
		colony_state: Array = []
	) -> void:
	if float(day_phase) >= 0.0:
		celestial_cycle.set_phase(float(day_phase))
	celestial_cycle.set_day_index(int(day_number))
	apply_scar_snapshot(scar_state)
	apply_flora_snapshot(flora_state)
	apply_boss_snapshots(boss_state)
	apply_ability_construct_snapshot(ability_construct_state)
	apply_colony_snapshot(colony_state)
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
			var combat_state: Variant = snapshot.get("combat", null)
			if combat_state is Dictionary:
				player.apply_combat_snapshot(combat_state)
			var resource_state: Variant = snapshot.get("resources", null)
			if resource_state is Dictionary:
				player.apply_resource_snapshot(resource_state)
	for pickup_variant in pickup_state:
		if not pickup_variant is Dictionary:
			continue
		var pickup: Dictionary = pickup_variant
		_spawn_pickup_local(
			int(pickup.get("pickup_id", 0)),
			str(pickup.get("item_id", "")),
			pickup.get("transform", Transform3D.IDENTITY))


func _spawn_transform(peer_id: int) -> Transform3D:
	if _is_online_sandbox():
		return _online_sandbox_spawn_transform(peer_id)
	if _has_spawn_override and peer_id == multiplayer.get_unique_id():
		return _spawn_override
	var points := spawn_points.get_children()
	if points.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0))
	var index := posmod(peer_id - 1, points.size())
	return (points[index] as Node3D).global_transform


func _is_online_sandbox() -> bool:
	return NetworkManager.state == NetworkManager.SessionState.IN_GAME \
		and not NetworkManager.is_single_player \
		and str(NetworkManager.session_options.get("mode", "")) == "sandbox"


## A compact line across the first orbital marker's view plane. Slots alternate
## right and left of the host (0, +1, -1, +2, -2...) so adding somebody never
## moves a player who has already spawned.
func _online_sandbox_spawn_transform(peer_id: int) -> Transform3D:
	var anchor := _sandbox_spawn_anchor()
	var centre_node := get_node_or_null("Planet") as Node3D
	var centre := centre_node.global_position if centre_node != null \
		else anchor.origin - anchor.basis.z
	var anchor_basis := _planet_facing_basis(
		anchor.origin, centre, anchor.basis.y, -anchor.basis.z)
	var slot := _sandbox_spawn_slot(peer_id)
	var lane := ceili(float(slot) * 0.5)
	var side := 1.0 if slot % 2 == 1 else -1.0
	var origin := anchor.origin + anchor_basis.x \
		* (float(lane) * side * ONLINE_SANDBOX_SPAWN_SPACING)
	var basis := _planet_facing_basis(
		origin, centre, anchor_basis.y, -anchor_basis.z)
	return Transform3D(basis, origin)


func _sandbox_spawn_anchor() -> Transform3D:
	if _has_spawn_override:
		return _spawn_override
	var points := spawn_points.get_children()
	if not points.is_empty() and points[0] is Node3D:
		return (points[0] as Node3D).global_transform
	return Transform3D(Basis.IDENTITY, Vector3(0.0, 2.0, 0.0))


func _sandbox_spawn_slot(peer_id: int) -> int:
	if _sandbox_spawn_slots.has(peer_id):
		return int(_sandbox_spawn_slots[peer_id])
	var slot := 0
	var occupied := _sandbox_spawn_slots.values()
	while occupied.has(slot):
		slot += 1
	_sandbox_spawn_slots[peer_id] = slot
	return slot


## Keeps the body's -Z aimed at the planet while retaining a stable visual up
## across the formation. The fallbacks also keep a stripped test world useful
## when its anchor happens to sit at the nominal centre.
func _planet_facing_basis(origin: Vector3, centre: Vector3, up_hint: Vector3,
		forward_fallback: Vector3) -> Basis:
	var forward := centre - origin
	if forward.length_squared() < 0.0001:
		forward = forward_fallback
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	up_hint -= forward * up_hint.dot(forward)
	if up_hint.length_squared() < 0.0001:
		var hint := Vector3.UP if absf(forward.y) < 0.9 else Vector3.RIGHT
		up_hint = hint - forward * hint.dot(forward)
	return _upright_basis(forward, up_hint.normalized())


## Every arena boss is deterministic scene content, so a late join needs state
## rather than a spawn packet. Paths distinguish multiple bosses of the same
## script and remain stable across peers loading the same world scene.
func boss_snapshots() -> Array:
	var rows: Array = []
	for boss_variant: Variant in get_tree().get_nodes_in_group(&"bosses"):
		var boss := boss_variant as Node
		if boss == null or not DamageHit.in_same_world(self, boss) \
				or not boss.has_method(&"boss_snapshot"):
			continue
		var wire := (boss.call(&"boss_snapshot") as Dictionary).duplicate(true)
		wire["node_path"] = String(get_path_to(boss))
		rows.append(wire)
	return rows


func apply_boss_snapshots(state: Variant) -> void:
	# Compatibility with hosts from the single-boss protocol and focused tests
	# that still pass Bigfoot's dictionary directly.
	if state is Dictionary:
		apply_bigfoot_snapshot(state)
		return
	if not state is Array:
		return
	for wire_variant: Variant in state:
		if not wire_variant is Dictionary:
			continue
		var wire := wire_variant as Dictionary
		var boss: Node
		var path := NodePath(String(wire.get("node_path", "")))
		if not path.is_empty():
			boss = get_node_or_null(path)
		if boss == null:
			var wanted := String(wire.get("boss_id", ""))
			for candidate_variant: Variant in get_tree().get_nodes_in_group(&"bosses"):
				var candidate := candidate_variant as Node
				if candidate == null or not DamageHit.in_same_world(self, candidate) \
						or not candidate.has_method(&"boss_id"):
					continue
				if String(candidate.call(&"boss_id")) == wanted:
					boss = candidate
					break
		if boss != null and boss.has_method(&"apply_boss_snapshot"):
			boss.call(&"apply_boss_snapshot", wire)


func bigfoot_snapshot() -> Dictionary:
	for boss_variant: Variant in get_tree().get_nodes_in_group(&"bigfoot_boss"):
		var boss := boss_variant as Node
		if boss != null and DamageHit.in_same_world(self, boss) \
				and boss.has_method(&"boss_snapshot"):
			return boss.call(&"boss_snapshot") as Dictionary
	return {}


func apply_bigfoot_snapshot(wire: Dictionary) -> void:
	if wire.is_empty():
		return
	for boss_variant: Variant in get_tree().get_nodes_in_group(&"bigfoot_boss"):
		var boss := boss_variant as Node
		if boss != null and DamageHit.in_same_world(self, boss) \
				and boss.has_method(&"apply_boss_snapshot"):
			boss.call(&"apply_boss_snapshot", wire)
			return
