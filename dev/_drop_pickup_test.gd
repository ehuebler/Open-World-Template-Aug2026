extends Node

## Focused, headless finite-world inventory checks.
##
##     godot --headless --path . dev/_drop_pickup_test.tscn

const SETTINGS_PATH := "user://settings.cfg"

var _failures := 0
var _saved_look: Dictionary
var _settings_existed := false
var _settings_bytes := PackedByteArray()
var _world: GameWorld
var _planet: Planet
var _player: OnlinePlayer


func _ready() -> void:
	_snapshot_settings()
	_saved_look = CharacterDB.load_look()
	for item_id: String in ItemDB.ITEMS:
		ItemIcons._cache[item_id] = ImageTexture.new()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.players.clear()
	NetworkManager.players[1] = {"name": "Drop Test", "peer_id": 1}
	NetworkManager.state = NetworkManager.SessionState.IN_GAME

	_world = _make_world()
	add_child(_world)
	for _frame in 3:
		await get_tree().process_frame
	_player = _world.local_player()
	if _player == null:
		_expect(false, "world spawned the local player")
		await _finish()
		return
	_player.set_process(false)
	_player.set_physics_process(false)
	_clear_loadout()
	_place_player(Vector3.UP)
	await get_tree().process_frame

	_check_snapshot_filters()
	await _check_drop_and_pickup()
	await _check_full_backpack()
	await _finish()


func _make_world() -> GameWorld:
	var world := GameWorld.new()
	world.name = "World"

	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var spawn := Marker3D.new()
	spawn.name = "Spawn1"
	spawn_points.add_child(spawn)
	world.add_child(spawn_points)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	world.add_child(sun)

	_planet = Planet.new()
	_planet.name = "Planet"
	_planet.shape = PlanetShape.new()
	_planet.shape.volcano_enabled = false
	_planet.shape.prepare()
	_planet.has_water = false
	_planet.has_clouds = false
	_planet.atmosphere_height = 0.0
	_planet.max_depth = 0
	_planet.sun = sun
	_planet.set_process(false)
	world.add_child(_planet)

	var ground := _planet.shape.surface_point(Vector3.UP, _planet.finest_spacing())
	spawn.position = ground

	var cycle := CelestialCycle.new()
	cycle.name = "CelestialCycle"
	cycle.planet = _planet
	cycle.sun = sun
	cycle.period_seconds = 0.0
	world.add_child(cycle)
	return world


func _place_player(direction: Vector3) -> void:
	direction = direction.normalized()
	var spacing := _planet.finest_spacing()
	var ground := _planet.to_global(
		_planet.shape.surface_point(direction, spacing))
	var up := (
		_planet.global_basis * _planet.shape.normal_at(direction, spacing)
	).normalized()
	_player.global_transform = Transform3D(
		_world._upright_basis(Vector3.FORWARD, up), ground)
	_player.reset_network_state(_player.global_transform)


func _clear_loadout() -> void:
	_player.holster()
	_player.equipment.clear()
	_player.hotbar.clear()
	_player.abilities.clear()
	_player.backpack.clear()


func _check_snapshot_filters() -> void:
	var equipment_state := PackedStringArray()
	equipment_state.resize(_player.equipment.size())
	equipment_state[0] = "sword"
	var hotbar_state := PackedStringArray()
	hotbar_state.resize(_player.hotbar.size())
	hotbar_state[0] = "c3_hair"
	var ability_state := PackedStringArray()
	ability_state.resize(_player.abilities.size())
	ability_state[0] = "sword"
	var backpack_state := PackedStringArray()
	backpack_state.resize(_player.backpack.size())
	backpack_state[0] = "sword"
	var clean := _player._sanitize_loadout_snapshot({
		"equipment": equipment_state,
		"hotbar": hotbar_state,
		"abilities": ability_state,
		"backpack": backpack_state,
	})
	var clean_equipment: PackedStringArray = clean.get(
		"equipment", PackedStringArray())
	var clean_hotbar: PackedStringArray = clean.get(
		"hotbar", PackedStringArray())
	var clean_abilities: PackedStringArray = clean.get(
		"abilities", PackedStringArray())
	var clean_backpack: PackedStringArray = clean.get(
		"backpack", PackedStringArray())
	_expect(not clean.is_empty()
		and clean_equipment[0].is_empty()
		and clean_hotbar[0].is_empty()
		and clean_abilities[0].is_empty()
		and clean_backpack[0] == "sword",
		"snapshot sanitizer applies every container filter")


func _check_drop_and_pickup() -> void:
	_player.backpack.set_item(0, "sword")
	_player.backpack.set_item(1, "sword")
	var before := _count_item("sword")

	# Public peer spoofing, a missing server player and a stale expected id all
	# fail before either canonical inventory or world state changes.
	_world.request_drop(99, "backpack", 0, "sword")
	_expect(_world._server_drop(
		99, "backpack", 0, "sword", _player.inventory_generation()) == 0,
		"server rejects a missing RPC-derived peer")
	_world.request_drop(1, "backpack", 0, "laser_rifle")
	_expect(_player.backpack.get_item(0) == "sword"
		and _world.pickup_snapshots().is_empty(),
		"invalid drop claims change nothing")

	_world.request_drop(1, "backpack", 0, "sword")
	await get_tree().process_frame
	var snapshots := _world.pickup_snapshots()
	_expect(_count_item("sword") == before - 1
		and _player.backpack.get_item(0).is_empty()
		and snapshots.size() == 1,
		"one drop removes exactly one source item")
	if snapshots.is_empty():
		return
	var pickup_id := int((snapshots[0] as Dictionary).get("pickup_id", 0))
	var dropped := _world.pickup_node(pickup_id)
	_expect(is_instance_valid(dropped)
		and dropped is StaticBody3D
		and dropped.interact_prompt() == "Pick up %s" % ItemDB.title("sword")
		and dropped.find_child("*", true, false) != null,
		"world pickup body and titled prompt exist")
	if not is_instance_valid(dropped):
		return

	var local := _planet.to_local(dropped.global_position)
	var surface_normal := _planet.shape.normal_at(
		local.normalized(), _planet.finest_spacing())
	_expect(dropped.global_basis.y.normalized().dot(surface_normal) > 0.995
		and dropped.global_position.distance_to(_player.global_position) > 0.75,
		"pickup is clear of the player and upright on terrain")

	_player.global_position = dropped.global_position \
		+ dropped.global_basis.x * (GameWorld.PICKUP_MAX_DISTANCE + 2.0)
	dropped.interact(_player)
	_expect(_world.pickup_node(pickup_id) == dropped
		and _count_item("sword") == before - 1,
		"too-far pickup is refused")

	_player.global_position = dropped.global_position + dropped.global_basis.z
	dropped.interact(_player)
	var after_valid := _count_item("sword")
	_expect(_world.pickup_node(pickup_id) == null
		and after_valid == before,
		"valid pickup returns exactly one item")
	_world.request_pickup(pickup_id, 1)
	_expect(_count_item("sword") == after_valid,
		"duplicate pickup request cannot grant twice")
	await get_tree().process_frame


func _check_full_backpack() -> void:
	_player.backpack.clear()
	for index in _player.backpack.size():
		_player.backpack.set_item(index, "c3_hair")
	_player.hotbar.set_item(0, "laser_rifle")
	_player.select_hotbar(0)
	_expect(_player.held_item() == "laser_rifle",
		"hotbar test begins with its item drawn")

	_world.request_drop(1, "hotbar", 0, "laser_rifle")
	await get_tree().process_frame
	var snapshots := _world.pickup_snapshots()
	_expect(_player.hotbar.get_item(0).is_empty()
		and _player.is_holstered() and snapshots.size() == 1,
		"dropping the drawn hotbar slot holsters normally")
	if snapshots.is_empty():
		return
	var snapshot: Dictionary = snapshots[0]
	var pickup_id := int(snapshot.get("pickup_id", 0))
	var dropped := _world.pickup_node(pickup_id)
	if is_instance_valid(dropped):
		_player.global_position = dropped.global_position + dropped.global_basis.z
	_world.request_pickup(pickup_id, 1)
	_expect(_world.pickup_node(pickup_id) == dropped
		and _player.backpack.first_accepting("laser_rifle") < 0
		and _count_item("laser_rifle") == 0,
		"backpack-full pickup is refused")

	var live := _world.pickup_snapshots()
	var same_node := _world.pickup_node(pickup_id)
	_world._receive_world_state([], -1.0, live)
	_expect(live.size() == 1
		and int((live[0] as Dictionary).get("pickup_id", 0)) == pickup_id
		and str((live[0] as Dictionary).get("item_id", "")) == "laser_rifle"
		and (live[0] as Dictionary).get("transform") is Transform3D
		and _world.pickup_node(pickup_id) == same_node,
		"join snapshot includes live pickups without duplicate nodes")


func _count_item(item_id: String) -> int:
	var count := 0
	for container in [_player.equipment, _player.hotbar, _player.backpack]:
		for held: String in (container as ItemContainer).items():
			if held == item_id:
				count += 1
	return count


func _finish() -> void:
	if is_instance_valid(_world):
		_world.queue_free()
	await get_tree().process_frame
	CharacterDB.save_look(_saved_look)
	_restore_settings()
	NetworkManager.players.clear()
	NetworkManager.state = NetworkManager.SessionState.IDLE
	NetworkManager.is_single_player = false
	NetworkManager.is_host = false
	print("drop_pickup_test: %s" % (
		"all checks passed" if _failures == 0
		else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("drop_pickup_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("drop_pickup_test: FAIL  %s" % message)


func _snapshot_settings() -> void:
	var path := ProjectSettings.globalize_path(SETTINGS_PATH)
	_settings_existed = FileAccess.file_exists(path)
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes(path)


func _restore_settings() -> void:
	var path := ProjectSettings.globalize_path(SETTINGS_PATH)
	if not _settings_existed:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("drop_pickup_test: could not restore %s" % path)
		return
	file.store_buffer(_settings_bytes)
	file.close()
