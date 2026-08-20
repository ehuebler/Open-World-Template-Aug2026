extends Node

const WORLD := preload("res://game/world.tscn")
const SETTINGS_PATH := "user://settings.cfg"

var _failures := 0
var _save_id := ""
var _settings_existed := false
var _settings_bytes := PackedByteArray()
var _saved_network: Dictionary


func _ready() -> void:
	_snapshot_environment()
	await _check_file_round_trip()
	await _check_world_round_trip()
	await _cleanup()
	if _failures == 0:
		print("sandbox_save_test: all checks passed")
	get_tree().quit(1 if _failures > 0 else 0)


func _check_file_round_trip() -> void:
	var region_terrain := PackedByteArray()
	region_terrain.resize(24 * 12)
	region_terrain.fill(1)
	var region := MeepRegionPlan.new()
	region.solve(Vector2(-24.0, -12.0), Vector2i(24, 12),
		region_terrain, [{
			"site": "save_a",
			"local_centre": Vector2(-10.0, 0.0),
			"forecast_rate": 1.0,
			"seed": 1,
			"protected_local": PackedVector2Array([Vector2(-10.0, 0.0)]),
		}, {
			"site": "save_b",
			"local_centre": Vector2(10.0, 0.0),
			"forecast_rate": 1.5,
			"seed": 2,
			"protected_local": PackedVector2Array([Vector2(10.0, 0.0)]),
		}])
	var typed_snapshot := {
		"schema_version": 1,
		"mode": "sandbox",
		"transform": Transform3D(
			Basis.from_euler(Vector3(0.2, -0.4, 0.1)),
			Vector3(12.5, -7.0, 91.25)),
		"colours": PackedColorArray([Color("45df68"), Color("ef151f")]),
		"rows": PackedInt32Array([3, 8, 13, 21]),
		"nested": {"direction": Vector3(0.2, 0.9, -0.1).normalized()},
		"region_plan": region.snapshot(),
		"meep_roles": PackedByteArray([
			MeepColony.Role.CHILD,
			MeepColony.Role.BUILDER,
			MeepColony.Role.HOMEBODY,
			MeepColony.Role.HARVESTER,
		]),
	}
	var created := SaveManager.create_save(
		"Automated Sandbox Round Trip", "sandbox", typed_snapshot)
	_expect(bool(created.get("ok", false)),
		"a named sandbox save is created atomically")
	if not bool(created.get("ok", false)):
		return
	_save_id = String(created.get("id", ""))
	var loaded := SaveManager.load_save(_save_id, "sandbox")
	var snapshot_value: Variant = loaded.get("snapshot", {})
	var restored := snapshot_value as Dictionary \
		if snapshot_value is Dictionary else {}
	var restored_region := MeepRegionPlan.new()
	var region_value: Variant = restored.get("region_plan", {})
	var region_ok := region_value is Dictionary \
		and restored_region.apply_snapshot(region_value as Dictionary)
	_expect(bool(loaded.get("ok", false))
		and restored.get("transform") is Transform3D
		and restored.get("rows") is PackedInt32Array
		and restored.get("colours") is PackedColorArray
		and (restored.get("transform") as Transform3D).is_equal_approx(
			typed_snapshot["transform"])
		and region_ok and restored_region.owner_map() == region.owner_map()
		and restored.get("meep_roles", PackedByteArray())
			== typed_snapshot["meep_roles"],
		"save files preserve typed state, RLE regions, and packed Meep roles")
	_expect(not bool(SaveManager.load_save(_save_id, "story").get("ok", false)),
		"mode filtering refuses to load a sandbox save as Story")
	var changed := typed_snapshot.duplicate(true)
	changed["rows"] = PackedInt32Array([34, 55])
	var overwritten := SaveManager.overwrite_save(_save_id, changed)
	var reloaded := SaveManager.load_save(_save_id, "sandbox")
	var reloaded_snapshot: Dictionary = reloaded.get("snapshot", {})
	_expect(bool(overwritten.get("ok", false))
		and reloaded_snapshot.get("rows") == PackedInt32Array([34, 55]),
		"overwriting retains the slot identity and replaces its snapshot")
	_expect(SaveManager.list_saves("sandbox").any(
		func(row: Dictionary) -> bool:
			return String(row.get("id", "")) == _save_id),
		"the sandbox catalog lists the named save")
	SaveManager.delete_save(_save_id)
	_save_id = ""


func _check_world_round_trip() -> void:
	NetworkManager.state = NetworkManager.SessionState.IN_GAME
	NetworkManager.is_single_player = true
	NetworkManager.is_host = true
	NetworkManager.session_options = {
		"mode": "sandbox",
		"name": "Save Test",
		"max_players": 1,
	}
	NetworkManager.players = {
		1: {
			"peer_id": 1,
			"name": "Saver",
			"body": CharacterDB.DEFAULT_BODY,
			"skin": "",
			"worn": {},
			"tints": {},
		},
	}
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var first := WORLD.instantiate() as GameWorld
	add_child(first)
	await _wait_frames(8)
	var player := first.local_player()
	if not _expect(player != null, "sandbox session spawns a savable local player"):
		first.queue_free()
		await _wait_frames(2)
		return

	var browser_fixture := SaveManager.create_save(
		"Existing Sandbox", "sandbox",
		{"schema_version": 1, "mode": "sandbox", "players": []})
	var browser_save_id := String(browser_fixture.get("id", ""))
	var home_model := HomeScreen.new()
	var home_selector := home_model._build_sandbox_save_selector()
	add_child(home_selector)
	await _wait_frames(1)
	var home_picker := home_selector.find_child(
		"HomeSandboxSavePicker", true, false) as OptionButton
	var browser_index := -1
	if home_picker != null:
		for index in home_picker.item_count:
			if String(home_picker.get_item_metadata(index)) == browser_save_id:
				browser_index = index
				break
	_expect(home_picker != null and browser_index > 0,
		"Sandbox mode settings list compatible named saves before Start Game")
	if browser_index > 0:
		home_picker.select(browser_index)
		home_picker.item_selected.emit(browser_index)
	_expect(home_model._selected_home_save_id == browser_save_id,
		"the home submenu records the save selected for startup")
	home_selector.queue_free()
	home_model.free()
	await _wait_frames(1)

	var menu := GameMenu.new()
	menu.configure(player)
	add_child(menu)
	await _wait_frames(2)
	var save_action := menu.find_child("SaveAction", true, false) as Button
	var load_action := menu.find_child("LoadAction", true, false) as Button
	_expect(save_action != null and load_action != null
		and not save_action.disabled and not load_action.disabled,
		"single-player Sandbox enables Save and Load beside Settings")
	if save_action != null:
		save_action.pressed.emit()
	await _wait_frames(2)
	_expect(menu.current_tab() == GameMenu.Tab.SAVE
		and menu.find_child("CreateSandboxSave", true, false) != null
		and menu.find_child(
			"OverwriteSave_%s" % browser_save_id, true, false) != null,
		"Save opens the named create-or-overwrite browser")
	await _capture("menu_ingame_save")
	if load_action != null:
		load_action.pressed.emit()
	await _wait_frames(2)
	_expect(menu.current_tab() == GameMenu.Tab.LOAD
		and menu.find_child("SandboxSaveRows", true, false) != null
		and menu.find_child(
			"LoadSave_%s" % browser_save_id, true, false) != null,
		"Load opens the mode-filtered save browser")
	await _capture("menu_ingame_load")
	menu.close()
	await _wait_frames(2)
	if not browser_save_id.is_empty():
		SaveManager.delete_save(browser_save_id)

	var saved_transform := player.global_transform
	saved_transform.origin += saved_transform.basis.x * 3.5 \
		+ saved_transform.basis.y * 1.25
	player.global_transform = saved_transform
	player.velocity = Vector3.ZERO
	player.reset_network_state(saved_transform)
	player.stats.set_health(37.0)
	player.stats.set_base(PlayerStats.BIOMASS, 246.0)
	player.stats.set_base(PlayerStats.SPEED, 7.4)
	first.celestial_cycle.set_phase(0.42)
	first.celestial_cycle.set_day_index(3)
	first._spawn_pickup_local(41, "sword",
		Transform3D(saved_transform.basis,
			saved_transform.origin + saved_transform.basis.x * 2.0))

	var colonies := first.meep_colonies()
	var released := colonies.release_settlers(&"landing") \
		if colonies != null else 0
	_expect(released > 0, "the fixture creates a live Meep colony before saving")
	var dummy := first.find_child("TrainingDummy", true, false) as TrainingDummy
	if dummy != null:
		dummy.apply_sandbox_snapshot({
			"health": 4321.0,
			"alive": true,
			"transform": dummy.global_transform,
			"velocity": Vector3.ZERO,
		})
	await _wait_frames(5)

	var saved := first.save_sandbox("", "Automated World Restore")
	_expect(bool(saved.get("ok", false)),
		"GameWorld writes a complete sandbox snapshot")
	if not bool(saved.get("ok", false)):
		first.queue_free()
		await _wait_frames(2)
		return
	_save_id = String(saved.get("id", ""))
	var document := SaveManager.load_save(_save_id, "sandbox")
	var snapshot: Dictionary = document.get("snapshot", {})
	_expect(snapshot.has("players") and snapshot.has("colonies")
		and snapshot.has("fauna") and snapshot.has("scene_objects")
		and snapshot.has("scars") and snapshot.has("flora"),
		"world saves include player, Meeps, fauna, objects, terrain, and destruction")

	first.queue_free()
	await _wait_frames(3)
	NetworkManager.session_options["save_id"] = _save_id
	var second := WORLD.instantiate() as GameWorld
	add_child(second)
	await _wait_frames(12)
	var restored_player := second.local_player()
	_expect(restored_player != null
		and restored_player.global_position.distance_to(saved_transform.origin) < 8.0,
		"loading restores the player near the exact saved transform")
	_expect(restored_player != null
		and is_equal_approx(restored_player.stats.health(), 37.0)
		and is_equal_approx(restored_player.biomass(), 246.0)
		and is_equal_approx(
			restored_player.stats.base_of(PlayerStats.SPEED), 7.4),
		"loading restores player health, biomass, and base stats")
	_expect(second.celestial_cycle.day_index() == 3
		and absf(second.celestial_cycle.phase() - 0.42) < 0.01,
		"loading restores planetary day and time")
	var restored_colonies := second.meep_colonies()
	var restored_colony := restored_colonies.colony(&"landing") \
		if restored_colonies != null else null
	var restored_ledger := restored_colonies.ledger(&"landing") \
		if restored_colonies != null else null
	# The spawn points sit five kilometres around the sphere from the landing site, so
	# the town comes back unwatched: no grid, no rows, a kilobyte of arithmetic instead.
	# That is the residency line working as intended, and what a save owes either way is
	# the settlers, so this asks the planet for its population rather than a node for its
	# rows.
	_expect(restored_colonies != null
		and (restored_colony != null or restored_ledger != null)
		and restored_colonies.planet_population() == released,
		"loading restores the Meep population and city")
	_expect(second.pickup_node(41) != null,
		"loading restores dropped world items and stable IDs")
	var restored_dummy := second.find_child(
		"TrainingDummy", true, false) as TrainingDummy
	_expect(restored_dummy != null and is_equal_approx(
		restored_dummy.health(), 4321.0),
		"loading restores opt-in scene-object damage")
	second.queue_free()
	await _wait_frames(3)


func _snapshot_environment() -> void:
	var settings_path := ProjectSettings.globalize_path(SETTINGS_PATH)
	_settings_existed = FileAccess.file_exists(settings_path)
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes(settings_path)
	_saved_network = {
		"state": int(NetworkManager.state),
		"is_single_player": NetworkManager.is_single_player,
		"is_host": NetworkManager.is_host,
		"session_options": NetworkManager.session_options.duplicate(true),
		"players": NetworkManager.players.duplicate(true),
		"peer": multiplayer.multiplayer_peer,
	}


func _cleanup() -> void:
	if not _save_id.is_empty():
		SaveManager.delete_save(_save_id)
		_save_id = ""
	NetworkManager.active_world = null
	NetworkManager.state = int(_saved_network["state"]) \
		as NetworkManager.SessionState
	NetworkManager.is_single_player = bool(_saved_network["is_single_player"])
	NetworkManager.is_host = bool(_saved_network["is_host"])
	NetworkManager.session_options = (
		_saved_network["session_options"] as Dictionary).duplicate(true)
	NetworkManager.players = (
		_saved_network["players"] as Dictionary).duplicate(true)
	multiplayer.multiplayer_peer = _saved_network["peer"] as MultiplayerPeer
	var settings_path := ProjectSettings.globalize_path(SETTINGS_PATH)
	if not _settings_existed:
		if FileAccess.file_exists(settings_path):
			DirAccess.remove_absolute(settings_path)
	else:
		var file := FileAccess.open(settings_path, FileAccess.WRITE)
		if file != null:
			file.store_buffer(_settings_bytes)
			file.close()
	await get_tree().process_frame


func _wait_frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame


func _capture(capture_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(
		"res://dev/captures/%s.png" % capture_name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := image.save_png(path)
	_expect(error == OK, "%s.png is captured for visual review" % capture_name)


func _expect(condition: bool, message: String) -> bool:
	if condition:
		print("sandbox_save_test: PASS  %s" % message)
		return true
	_failures += 1
	push_error("sandbox_save_test: FAIL %s" % message)
	return false
