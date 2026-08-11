extends Node

## Focused, rendering-free checks for the Red Tab loadout backend.
##
##     godot --headless --path . dev/_loadout_model_test.tscn

const SETTINGS_PATH := "user://settings.cfg"

var _failures := 0
var _settings_existed := false
var _settings_bytes := PackedByteArray()


func _ready() -> void:
	_snapshot_settings()
	_check_item_kinds()
	_check_container_filters()
	_check_character_schema()
	_check_starter_inventory()
	_check_rack_migration()
	_restore_settings()
	print("loadout_model_test: %s" % (
		"all checks passed" if _failures == 0 else "%d check(s) failed" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_item_kinds() -> void:
	_expect(ItemDB.kind_of("sword") == ItemDB.KIND_WEAPON,
		"sword has explicit weapon kind")
	_expect(ItemDB.kind_of("c3_hair") == ItemDB.KIND_APPAREL,
		"apparel has explicit apparel kind")
	_expect(ItemDB.accepts_hotbar("sword"), "hotbar accepts weapons")
	_expect(not ItemDB.accepts_ability("sword"), "ability slot rejects weapons")
	# Two abilities ship now. The container still has to keep a weapon out of an
	# ability slot, which is what the check above and the filters below are for;
	# what changed is only that the catalogue is no longer allowed to be empty.
	_expect(ItemDB.accepts_ability("laser_eyes"),
		"ability slot accepts a real ability")


func _check_container_filters() -> void:
	var hotbar := ItemContainer.new(CharacterDB.HOTBAR_SLOTS)
	var abilities := ItemContainer.new(CharacterDB.ABILITY_SLOTS)
	var backpack := ItemContainer.new(2)
	for index in hotbar.size():
		hotbar.set_filter(index, ItemDB.HOTBAR)
	for index in abilities.size():
		abilities.set_filter(index, ItemDB.ABILITY)
	for index in backpack.size():
		backpack.set_filter(index, ItemDB.BACKPACK)
	hotbar.set_item(0, "sword")
	abilities.set_item(0, "sword")
	backpack.set_item(0, "c3_hair")
	_expect(hotbar.get_item(0) == "sword", "filtered hotbar stores a weapon")
	_expect(abilities.get_item(0).is_empty(), "filtered ability slot refuses a weapon")
	_expect(backpack.get_item(0) == "c3_hair", "backpack stores apparel")
	_expect(ItemContainer.transfer(backpack, 0, hotbar, 1) == false,
		"hotbar refuses apparel transfers")


func _check_character_schema() -> void:
	var defaults := CharacterDB.default_look()
	_expect((defaults["hotbar"] as Array).size() == CharacterDB.HOTBAR_SLOTS,
		"default hotbar has three slots")
	_expect((defaults["abilities"] as Array).size() == CharacterDB.ABILITY_SLOTS,
		"default abilities have two slots")
	_expect(defaults.has("backpack"), "default look carries backpack data")
	var old_look := {"rack": ["sword", "", "laser_rifle", "sword"]}
	_expect(CharacterDB.hotbar_items(old_look, 3) \
		== PackedStringArray(["sword", "", "laser_rifle"]),
		"old rack is a positional hotbar fallback")
	_expect(CharacterDB.racked_items(old_look, 3) \
		== CharacterDB.hotbar_items(old_look, 3),
		"racked_items remains a compatibility alias")


func _check_starter_inventory() -> void:
	# CharacterDB addresses the autoload directly. Swap in an isolated ConfigFile
	# while exercising the one-time seed, then restore both memory and disk.
	var saved_config: ConfigFile = SettingsManager._config
	SettingsManager._config = ConfigFile.new()
	SettingsManager._config.set_value(
		"appearance", "starter_inventory_revision", 0)

	var look := CharacterDB.default_look()
	look["worn"] = {"hat": "c3_hair"}
	look["backpack"] = ["c3_goggles"]
	CharacterDB._seed_starter_inventory(look)
	var backpack: Array = look.get("backpack", [])
	var worn: Dictionary = look.get("worn", {})
	var hotbar: Array = look.get("hotbar", [])
	for item_id: String in CharacterDB.apparel_ids(CharacterDB.DEFAULT_BODY):
		var count := backpack.count(item_id)
		if worn.values().has(item_id):
			count += 1
		_expect(count == 1, "starter owns exactly one %s" % item_id)
	_expect(backpack.size() + worn.size()
		== CharacterDB.apparel_ids(CharacterDB.DEFAULT_BODY).size(),
		"starter ownership is finite across worn and backpack")
	for item_id: String in ItemDB.weapon_ids():
		_expect(hotbar.count(item_id) + backpack.count(item_id) == 1,
			"starter owns exactly one %s" % item_id)
	_expect(hotbar[0] == "sword" and hotbar[1] == "laser_rifle",
		"starter weapons fill open numbered slots")
	_expect(int(SettingsManager._config.get_value(
		"appearance", "starter_inventory_revision", 0))
		== CharacterDB.STARTER_INVENTORY_REVISION,
		"starter seed records its revision")

	# Once revised, removing an item is permanent: another load cannot manufacture
	# a dropped garment back into the backpack.
	backpack.erase("c3_boots")
	look["backpack"] = backpack
	CharacterDB._seed_starter_inventory(look)
	_expect(not (look["backpack"] as Array).has("c3_boots"),
		"completed starter seed does not resurrect removed ownership")

	# The first finite-inventory rollouts could leave an empty save marked as
	# complete. The current revision repairs that all-missing state from every
	# old marker and adds the weapons those revisions never granted.
	for old_revision: int in [1, 2, 3, 4]:
		SettingsManager._config = ConfigFile.new()
		SettingsManager._config.set_value(
			"appearance", "starter_inventory_revision", old_revision)
		var broken_look := CharacterDB.default_look()
		CharacterDB._seed_starter_inventory(broken_look)
		var repaired: Array = broken_look.get("backpack", [])
		var repaired_hotbar: Array = broken_look.get("hotbar", [])
		for item_id: String in CharacterDB.apparel_ids(CharacterDB.DEFAULT_BODY):
			_expect(repaired.count(item_id) == 1,
				"empty revision-%d save recovers %s" % [old_revision, item_id])
		for item_id: String in ItemDB.weapon_ids():
			_expect(repaired_hotbar.count(item_id) == 1,
				"revision-%d save receives %s" % [old_revision, item_id])

	# A partial older wardrobe is real finite ownership. Advancing its marker
	# must not manufacture an individually removed garment.
	SettingsManager._config = ConfigFile.new()
	SettingsManager._config.set_value(
		"appearance", "starter_inventory_revision", 3)
	var partial_look := CharacterDB.default_look()
	partial_look["backpack"] = ["c3_hair"]
	CharacterDB._seed_starter_inventory(partial_look)
	_expect(partial_look["backpack"] == ["c3_hair"],
		"partial older wardrobe preserves removed apparel")
	_expect((partial_look["hotbar"] as Array).has("sword")
		and (partial_look["hotbar"] as Array).has("laser_rifle"),
		"revision-three wardrobe receives both missing weapons")
	_expect(int(SettingsManager._config.get_value(
		"appearance", "starter_inventory_revision", 0))
		== CharacterDB.STARTER_INVENTORY_REVISION,
		"partial wardrobe advances the repair revision")

	# Revision four could preserve a wardrobe containing every settler garment
	# except the hair. Repair that known rollout omission without restoring other
	# apparel the player may genuinely have removed.
	SettingsManager._config = ConfigFile.new()
	SettingsManager._config.set_value(
		"appearance", "starter_inventory_revision", 4)
	var hairless_look := CharacterDB.default_look()
	hairless_look["hotbar"] = ["sword", "laser_rifle", ""]
	hairless_look["backpack"] = ["c3_goggles"]
	CharacterDB._seed_starter_inventory(hairless_look)
	_expect(hairless_look["backpack"] == ["c3_goggles", "c3_hair"],
		"revision-four partial wardrobe receives missing Settler Hair only")
	_expect(not (hairless_look["backpack"] as Array).has("c3_tunic")
		and not (hairless_look["backpack"] as Array).has("c3_boots"),
		"hair repair does not resurrect unrelated removed apparel")
	SettingsManager._config = saved_config


func _check_rack_migration() -> void:
	var manager := GameSettingsManager.new()
	manager._config = ConfigFile.new()
	manager._config.set_value("appearance", "body", "settler")
	manager._config.set_value("appearance", "skin", "clean_robotic")
	manager._config.set_value("appearance", "worn", {"hat": "c3_hair"})
	manager._config.set_value("appearance", "tints", {"body": "abcdef"})
	manager._config.set_value("appearance", "rack",
		["sword", "", "laser_rifle", "sword", "laser_rifle"])
	_expect(manager._migrate_loadout(), "old settings trigger loadout migration")
	_expect(manager._config.get_value("appearance", "hotbar", []) \
		== ["sword", "", "laser_rifle"], "rack slots one through three stay numbered")
	_expect(manager._config.get_value("appearance", "rack", []) \
		== ["sword", "", "laser_rifle"], "legacy rack mirrors the migrated hotbar")
	_expect(manager._config.get_value("appearance", "backpack", []) \
		== ["sword", "laser_rifle"], "rack overflow moves to the backpack")
	_expect(manager._config.get_value("appearance", "abilities", []).size() == 2,
		"migration creates both ability slots")
	_expect(manager._config.get_value("appearance", "skin", "") == "clean_robotic" \
		and manager._config.get_value("appearance", "worn", {}) == {"hat": "c3_hair"} \
		and manager._config.get_value("appearance", "tints", {}) == {"body": "abcdef"},
		"migration preserves existing appearance data")
	_expect(not manager._migrate_loadout(), "loadout migration is idempotent")
	manager.free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("loadout_model_test: PASS  %s" % message)
		return
	_failures += 1
	push_error("loadout_model_test: FAIL  %s" % message)


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
		push_error("loadout_model_test: could not restore %s" % path)
		return
	file.store_buffer(_settings_bytes)
	file.close()
