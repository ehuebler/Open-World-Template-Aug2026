class_name CharacterDB
extends RefCounted

## The bodies a player can be. Each entry names the .glb, the collider/eye heights
## that fit it, and the apparel items that sit on its skeleton. Garments from one
## body are not offered on another: they share slot names so the equipment column
## stays the same shape, but the meshes only bind cleanly to the skeleton they
## were cut from.
##
## `playable` is what the home screen and the character editor offer. The
## astronaut is switched off rather than deleted: its body, its five garments and
## its `ItemDB` entries are all still good, `dev/_check_character.gd` and friends
## still measure it, and turning it back on is this one flag. What being off means
## is that [method sanitize_body] sends it to the default, so a `settings.cfg`
## saved when it was the default quietly becomes a settler rather than spawning a
## body nothing offers.

const DEFAULT_BODY := "settler"

const BODIES := {
	"astronaut": {
		"title": "Astronaut",
		"playable": false,
		"scene": "res://blender_assets/player_character.glb",
		"height": 1.45,
		"eye_height": 1.29,
		"lean_pivot": 0.72,
		"apparel": ["straw_hat", "flight_goggles", "rust_long_sleeve", "denim_trousers",
			"leather_shoes"],
	},
	"settler": {
		"title": "Settler",
		"playable": true,
		"scene": "res://blender_assets/player_character_3.glb",
		"height": 1.6,
		"eye_height": 1.45,
		"lean_pivot": 0.85,
		"apparel": ["c3_hair", "c3_goggles", "c3_tunic", "c3_boots"],
	},
}


static func body_ids() -> PackedStringArray:
	return PackedStringArray(BODIES.keys())


## The bodies anybody is allowed to choose, which is what the home screen and the
## editor list. Anything walking the bodies to *offer* one wants this; anything
## walking them to measure or check an asset wants [method body_ids].
static func playable_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in BODIES:
		if bool(_field(id, "playable", false)):
			out.append(id)
	return out


static func is_playable(id: String) -> bool:
	return bool(_field(id, "playable", false))


static func has_body(id: String) -> bool:
	return BODIES.has(id)


static func title(id: String) -> String:
	return String(_field(id, "title", id))


static func scene_path(id: String) -> String:
	return String(_field(id, "scene", BODIES[DEFAULT_BODY]["scene"]))


static func scene(id: String) -> PackedScene:
	return load(scene_path(id)) as PackedScene


static func height(id: String) -> float:
	return float(_field(id, "height", 1.45))


static func eye_height(id: String) -> float:
	return float(_field(id, "eye_height", 1.29))


static func lean_pivot(id: String) -> float:
	return float(_field(id, "lean_pivot", 0.72))


## Item ids that belong on this body, in the order the editor lists them.
static func apparel_ids(id: String) -> PackedStringArray:
	var raw: Variant = _field(id, "apparel", [])
	var out := PackedStringArray()
	for entry in raw:
		out.append(String(entry))
	return out


## True when this garment was authored for this body's skeleton.
static func apparel_fits(body_id: String, item_id: String) -> bool:
	return item_id in apparel_ids(body_id)


static func sanitize_body(id: String) -> String:
	return id if is_playable(id) else DEFAULT_BODY


## Look dictionary written by the home-screen editor and read when a body is
## previewed or spawned. `worn` is slot → item id; `tints` is "body" or a slot
## → HTML colour. Both are sparse.
static func default_look() -> Dictionary:
	return {
		"body": DEFAULT_BODY,
		"worn": {},
		"tints": {},
	}


static func load_look() -> Dictionary:
	var look := default_look()
	# Autoload global — do not path through /root; that fails outside a live tree
	# and was returning the astronaut default even when settings.cfg said settler.
	if SettingsManager == null:
		return look
	look["body"] = sanitize_body(str(SettingsManager.get_setting(
		&"appearance", &"body", DEFAULT_BODY)))
	var worn_raw: Variant = SettingsManager.get_setting(&"appearance", &"worn", {})
	if worn_raw is Dictionary:
		var worn: Dictionary = {}
		for slot: Variant in worn_raw:
			var item_id := str(worn_raw[slot])
			if ItemDB.has_item(item_id) and apparel_fits(str(look["body"]), item_id):
				worn[str(slot)] = item_id
		look["worn"] = worn
	var tint_raw: Variant = SettingsManager.get_setting(&"appearance", &"tints", {})
	if tint_raw is Dictionary:
		look["tints"] = (tint_raw as Dictionary).duplicate(true)
	return look


static func save_look(look: Dictionary) -> void:
	if SettingsManager == null:
		return
	var body_id := sanitize_body(str(look.get("body", DEFAULT_BODY)))
	SettingsManager.set_setting(&"appearance", &"body", body_id, false)
	SettingsManager.set_setting(&"appearance", &"worn", look.get("worn", {}), false)
	SettingsManager.set_setting(&"appearance", &"tints", look.get("tints", {}), false)
	SettingsManager.save_settings()


## Slot-ordered item ids for the wire / equipment container.
static func worn_items(look: Dictionary) -> PackedStringArray:
	var body_id := sanitize_body(str(look.get("body", DEFAULT_BODY)))
	var worn: Dictionary = look.get("worn", {})
	var out := PackedStringArray()
	out.resize(ItemDB.SLOT_ORDER.size())
	for index in ItemDB.SLOT_ORDER.size():
		var slot: String = ItemDB.SLOT_ORDER[index]
		var item_id := str(worn.get(slot, ""))
		out[index] = item_id if apparel_fits(body_id, item_id) else ""
	return out


## Reads a field off any body this file knows about, playable or not — which is
## deliberately a weaker test than [method sanitize_body]. Being switched off
## decides what may be *chosen*; it must not change what the astronaut's own
## measurements are, or `scene_path("astronaut")` starts returning the settler and
## every asset check quietly measures the wrong body.
static func _field(id: String, key: String, fallback: Variant) -> Variant:
	var body: Variant = BODIES.get(id if has_body(id) else DEFAULT_BODY, {})
	if body is Dictionary and (body as Dictionary).has(key):
		return (body as Dictionary)[key]
	return fallback
