class_name ItemDB
extends RefCounted

## Every item the game can put in a slot.
##
## `kind` explicitly separates apparel, ordinary items, weapons and abilities.
## `slot` remains the body slot an apparel item occupies and matches the keys in
## Wardrobe.APPAREL. Container filters call [method accepts], so body equipment,
## the numbered hotbar, ability buttons and the backpack all share these rules.
## `scene` is the .glb, worn on the body or put in the hands and also rendered
## into the item's icon; `tint` stands in for the icon until that render lands.
##
## A weapon carries three more fields: `hold`, one of the WeaponPose holds, which
## decides how the arms take it; `attack`, either ATTACK_SWING or ATTACK_SHOOT; and
## for a shooting weapon, `cell`, how many shots it stores.

const KIND_APPAREL := "apparel"
const KIND_ITEM := "item"
const KIND_WEAPON := "weapon"
const KIND_ABILITY := "ability"

## Container filter ids. WEAPON is retained for old rack containers; HOTBAR is
## the broader numbered-slot rule and accepts both weapons and ordinary items.
const WEAPON := KIND_WEAPON
const HOTBAR := "hotbar"
const ABILITY := KIND_ABILITY
const BACKPACK := "backpack"

const ITEMS := {
	"straw_hat": {
		"title": "Straw Hat",
		"description": "Woven brim gone soft at the edges. Sits low enough to keep the sun off the page.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/apparel_hat.glb",
		"tint": Color(0.9023, 0.7954, 0.4978),
	},
	"flight_goggles": {
		"title": "Flight Goggles",
		"description": "Brass rims on a webbing strap. Worn on the brow, and they tuck under a hat rather than fighting it.",
		"kind": KIND_APPAREL,
		"slot": "goggles",
		"scene": "res://assets/runtime/apparel/apparel_goggles.glb",
		"tint": Color(0.5271, 0.4014, 0.2216),
	},
	"rust_long_sleeve": {
		"title": "Rust Long Sleeve",
		"description": "Heavy cotton, cuffs to the wrist. The dye has faded unevenly, which is most of its charm.",
		"kind": KIND_APPAREL,
		"slot": "long_sleeve",
		"scene": "res://assets/runtime/apparel/apparel_long_sleeve.glb",
		"tint": Color(0.7906, 0.5459, 0.522),
	},
	"denim_trousers": {
		"title": "Denim Trousers",
		"description": "Stiff blue workwear, turned up at the ankle so the hem clears your shoes.",
		"kind": KIND_APPAREL,
		"slot": "pants",
		"scene": "res://assets/runtime/apparel/apparel_pants.glb",
		"tint": Color(0.5021, 0.5639, 0.6682),
	},
	"leather_shoes": {
		"title": "Leather Shoes",
		"description": "Scuffed brown leather on a flat sole. Quiet on floorboards, loud on gravel.",
		"kind": KIND_APPAREL,
		"slot": "shoes",
		"scene": "res://assets/runtime/apparel/apparel_shoes.glb",
		"tint": Color(0.4614, 0.41, 0.3811),
	},
	"c3_hair": {
		"title": "Settler Hair",
		"description": "Spiked and cut from the dressed settler. Sits on the scalp and takes a tint.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/apparel_c3_hair.glb",
		"tint": Color(0.10, 0.11, 0.20),
	},
	"c3_sun_hat": {
		"title": "Wide Sun Hat",
		"description": "A broad, low brim for long walks between settlements.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/placeholder_c3_sun_hat.tscn",
		"tint": Color(0.93, 0.70, 0.31),
		"price": 0,
		"shop": true,
	},
	"c3_wizard_hat": {
		"title": "Wayfinder Hat",
		"description": "A tall crooked cone made for dramatic directions.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/placeholder_c3_wizard_hat.tscn",
		"tint": Color(0.34, 0.23, 0.62),
		"price": 0,
		"shop": true,
	},
	"c3_crown": {
		"title": "Settlement Crown",
		"description": "A broad gold circlet with deliberately oversized points.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/placeholder_c3_crown.tscn",
		"tint": Color(1.0, 0.74, 0.18),
		"price": 0,
		"shop": true,
	},
	"c3_beanie": {
		"title": "Harbor Beanie",
		"description": "A soft round cap and rolled band for windy coasts.",
		"kind": KIND_APPAREL,
		"slot": "hat",
		"scene": "res://assets/runtime/apparel/placeholder_c3_beanie.tscn",
		"tint": Color(0.18, 0.58, 0.68),
		"price": 0,
		"shop": true,
	},
	"c3_goggles": {
		"title": "Settler Goggles",
		"description": "Smoked slate lenses on a wide band. Cut for the settler's skull, which is a different shape entirely.",
		"kind": KIND_APPAREL,
		"slot": "goggles",
		"scene": "res://assets/runtime/apparel/apparel_c3_goggles.glb",
		"tint": Color(0.2412, 0.3106, 0.4183),
	},
	"c3_tunic": {
		"title": "Settler Tunic",
		"description": "Capped at the shoulder and flared at the hem, over bare legs.",
		"kind": KIND_APPAREL,
		"slot": "long_sleeve",
		"scene": "res://assets/runtime/apparel/apparel_c3_tunic.glb",
		"tint": Color(0.25, 0.26, 0.34),
	},
	"c3_boots": {
		"title": "Settler Boots",
		"description": "Heavy soles and a cuff at mid-shin. A pair, and they clear each other.",
		"kind": KIND_APPAREL,
		"slot": "shoes",
		"scene": "res://assets/runtime/apparel/apparel_c3_boots.glb",
		"tint": Color(0.10, 0.11, 0.17),
	},
	"sword": {
		"title": "Drill Sword",
		"description": "Brass furniture on a leather-wrapped grip. Held two-handed, blade up, and cut across the body from right to left.",
		"kind": KIND_WEAPON,
		"slot": "weapon",
		"scene": "res://assets/runtime/items/sword.glb",
		"hold": "blade",
		"attack": "swing",
		"tint": Color(0.72, 0.735, 0.76),
	},
	"laser_rifle": {
		"title": "Laser Carbine",
		"description": "Twelve shots in a cell that trickles back up on its own. Left hand under the barrel, right on the trigger; right click to sight down the optic.",
		"kind": KIND_WEAPON,
		"slot": "weapon",
		"scene": "res://assets/runtime/items/laser_rifle.glb",
		"hold": "rifle",
		"attack": "shoot",
		"cell": 12,
		"tint": Color(0.44, 0.47, 0.5),
	},
}

## How each stat is spelled out for the abilities menu, in the order it is shown.
##
## A table rather than a formatter per screen, because the menu is not the only
## thing that will ever want to say how much damage something does, and two
## places writing "60 m" their own way is how one of them ends up saying "60.0".
## Anything an ability declares that is not listed here is still shown, using
## its own key and a plain number, so a new stat is never silently swallowed.
const STAT_ORDER := ["damage", "player_damage", "impact", "speed", "duration",
	"range", "radius", "cooldown", "punch_reach", "wind_length",
	"capture_full_health",
	"capture_low_health", "release_distance", "delay",
	"launch_height", "launch_speed",
	"slam_speed", "rope_length", "swing_acceleration", "max_speed",
	"impact_speed", "knockback", "lift", "self_launch_speed",
	"crater_radius", "crater_depth", "crater_warp",
	"projectile_radius", "beam_radius", "paint_radius", "paint_spacing",
	"chain_interval",
	"wall_width", "wall_height", "wall_thickness", "fade_duration",
	"explosion_duration", "animation_duration", "apex_time"]
const STAT_LABELS := {
	"damage": "Damage",
	"player_damage": "Player Damage",
	"impact": "Impact",
	"speed": "Speed",
	"duration": "Duration",
	"range": "Range",
	"radius": "Radius",
	"cooldown": "Cooldown",
	"punch_reach": "Punch Reach",
	"wind_length": "Wind Tunnel",
	"capture_full_health": "Full-Health Capture",
	"capture_low_health": "Low-Health Capture",
	"release_distance": "Unequip Release",
	"delay": "Delay",
	"launch_height": "Launch Height",
	"launch_speed": "Launch Speed",
	"slam_speed": "Slam Speed",
	"rope_length": "Rope Length",
	"swing_acceleration": "Swing Acceleration",
	"max_speed": "Maximum Speed",
	"impact_speed": "Impact Threshold",
	"knockback": "Knockback",
	"lift": "Lift",
	"self_launch_speed": "Self Launch",
	"crater_radius": "Crater Radius",
	"crater_depth": "Crater Depth",
	"crater_warp": "Crater Irregularity",
	"projectile_radius": "Projectile Radius",
	"beam_radius": "Beam Radius",
	"paint_radius": "Paint Radius",
	"paint_spacing": "Paint Spacing",
	"chain_interval": "Blast Step",
	"wall_width": "Wall Width",
	"wall_height": "Wall Height",
	"wall_thickness": "Wall Thickness",
	"fade_duration": "Fade",
	"explosion_duration": "Explosion",
	"animation_duration": "Animation",
	"apex_time": "Apex Hold",
}
const STAT_UNITS := {
	"damage": "",
	"player_damage": "",
	"impact": "",
	"speed": " m/s",
	"duration": " s",
	"range": " m",
	"radius": " m",
	"cooldown": " s",
	"punch_reach": " m",
	"wind_length": " m",
	"capture_full_health": "%",
	"capture_low_health": "%",
	"release_distance": " m",
	"delay": " s",
	"launch_height": " m",
	"launch_speed": " m/s",
	"slam_speed": " m/s",
	"rope_length": " m",
	"swing_acceleration": " m/s²",
	"max_speed": " m/s",
	"impact_speed": " m/s",
	"knockback": " m/s",
	"lift": " m/s",
	"self_launch_speed": " m/s",
	"crater_radius": " m",
	"crater_depth": " m",
	"projectile_radius": " m",
	"beam_radius": " m",
	"paint_radius": " m",
	"paint_spacing": " m",
	"chain_interval": " s",
	"wall_width": " m",
	"wall_height": " m",
	"wall_thickness": " m",
	"fade_duration": " s",
	"explosion_duration": " s",
	"animation_duration": " s",
	"apex_time": " s",
}

## The active loadout is intentionally hat-only. Legacy item definitions keep
## their explicit apparel kind so old saves remain parseable in the backpack.
const SLOT_ORDER := ["hat"]
const MAX_ABILITY_LEVEL := 5
const MAX_ABILITY_STAT_LEVEL := 5
const ABILITY_STAT_ORDER := [
	"power", "cooldown", "size", "speed", "range", "duration",
]
const ABILITY_STAT_LABELS := {
	"power": "POWER",
	"cooldown": "COOLDOWN",
	"size": "SIZE",
	"speed": "SPEED",
	"range": "RANGE",
	"duration": "DURATION",
}
const ABILITY_STAT_KEYS := {
	"power": ["damage", "impact", "knockback", "lift"],
	"cooldown": ["cooldown"],
	"size": [
		"radius", "projectile_radius", "crater_radius", "beam_radius",
		"paint_radius", "wall_width", "wall_height", "punch_reach",
		"wind_length", "rope_length",
	],
	"speed": [
		"speed", "launch_speed", "slam_speed", "swing_acceleration",
		"max_speed", "self_launch_speed",
	],
	"range": ["range"],
	"duration": ["duration", "fade_duration", "explosion_duration"],
}
const ABILITY_STAT_GAIN := 0.10
const ABILITY_COOLDOWN_REDUCTION := 0.08

const ATTACK_SWING := "swing"
const ATTACK_SHOOT := "shoot"

## Shown on an equipment slot that has nothing in it yet.
const SLOT_LABELS := {
	"hat": "Hat",
}


static func has_item(id: String) -> bool:
	return ITEMS.has(id) or AbilityCatalog.has(id)


static func title(id: String) -> String:
	var definition := ability_definition(id)
	if definition != null:
		return definition.title
	return String(_field(id, "title", id))


static func description(id: String) -> String:
	var definition := ability_definition(id)
	if definition != null:
		return definition.description
	return String(_field(id, "description", ""))


## The body slot this item is worn in, or "" if it cannot be worn.
static func slot_of(id: String) -> String:
	return String(_field(id, "slot", ""))


## Explicit catalogue classification. The fallback keeps an older external item
## table parseable, but every item shipped in [constant ITEMS] declares a kind.
static func kind_of(id: String) -> String:
	if AbilityCatalog.has(id):
		return KIND_ABILITY
	var explicit := String(_field(id, "kind", ""))
	if not explicit.is_empty():
		return explicit
	var slot := slot_of(id)
	if slot == WEAPON:
		return KIND_WEAPON
	if slot in SLOT_ORDER:
		return KIND_APPAREL
	return KIND_ITEM if has_item(id) else ""


static func is_apparel(id: String) -> bool:
	return kind_of(id) == KIND_APPAREL


static func is_weapon(id: String) -> bool:
	return kind_of(id) == KIND_WEAPON


static func is_item(id: String) -> bool:
	return kind_of(id) == KIND_ITEM


static func is_ability(id: String) -> bool:
	return kind_of(id) == KIND_ABILITY


## Numbered slots accept things that can be drawn and activated with the mouse.
static func accepts_hotbar(id: String) -> bool:
	return has_item(id) and (is_weapon(id) or is_item(id))


static func accepts_ability(id: String) -> bool:
	return has_item(id) and is_ability(id)


## Abilities are selected powers rather than carried objects.
static func accepts_backpack(id: String) -> bool:
	return has_item(id) and not is_ability(id)


## Shared rule used by [ItemContainer]. Empty ids always clear a slot.
static func accepts(filter: String, id: String) -> bool:
	if id.is_empty():
		return true
	match filter:
		"":
			return has_item(id)
		HOTBAR:
			return accepts_hotbar(id)
		ABILITY:
			return accepts_ability(id)
		BACKPACK:
			return accepts_backpack(id)
		WEAPON:
			return is_weapon(id)
		_:
			return is_apparel(id) and slot_of(id) == filter


## Every weapon in the catalogue, in table order. Derived rather than listed, so a
## weapon added to [constant ITEMS] is offered by the character editor with no
## second table to remember. The wardrobe's equivalent is
## [method CharacterDB.apparel_ids], which cannot be derived the same way: a
## garment belongs to one skeleton and a weapon is held by anybody.
static func weapon_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: String in ITEMS:
		if is_weapon(id):
			ids.append(id)
	return ids


static func hotbar_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: String in ITEMS:
		if accepts_hotbar(id):
			ids.append(id)
	return ids


static func ability_ids() -> PackedStringArray:
	return AbilityCatalog.ids()


static func ability_use_type(id: String) -> int:
	var definition := ability_definition(id)
	return definition.use_type if definition != null \
		else AbilityDefinition.UseType.REUSABLE


static func is_one_time_ability(id: String) -> bool:
	return is_ability(id) \
		and ability_use_type(id) == AbilityDefinition.UseType.ONE_TIME


## Whether this definition may occupy LMB or RMB directly. A false entry still
## remains an owned/catalogued ability record; another utility can consume it.
static func ability_directly_equippable(id: String) -> bool:
	var definition := ability_definition(id)
	return definition != null and definition.direct_equip


static func reusable_ability_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: String in ability_ids():
		if not is_one_time_ability(id):
			ids.append(id)
	return ids


static func one_time_ability_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: String in ability_ids():
		if is_one_time_ability(id):
			ids.append(id)
	return ids


static func hat_shop_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for id: String in ITEMS:
		if bool(_field(id, "shop", false)) and slot_of(id) == "hat":
			ids.append(id)
	return ids


## Prices are data-backed even while this phase intentionally makes every
## transaction free. Keeping the authoritative debit path now avoids replacing
## the protocol when economy balancing begins.
static func hat_price(id: String) -> int:
	return maxi(int(_field(id, "price", 0)), 0) if id in hat_shop_ids() else -1


static func ability_unlock_price(id: String) -> int:
	return 0 if is_ability(id) and not is_one_time_ability(id) else -1


static func ability_upgrade_price(id: String, current_level: int) -> int:
	if not is_ability(id) or is_one_time_ability(id) \
			or current_level < 1 or current_level >= MAX_ABILITY_LEVEL:
		return -1
	return 0


static func ability_stat_ids(id: String) -> PackedStringArray:
	var definition := ability_definition(id)
	var out := PackedStringArray()
	if definition == null or is_one_time_ability(id):
		return out
	for stat_id: String in ABILITY_STAT_ORDER:
		var keys: Array = ABILITY_STAT_KEYS.get(stat_id, [])
		for key: String in keys:
			if definition.stats.has(key) and float(definition.stats[key]) > 0.0:
				out.push_back(stat_id)
				break
	return out


static func ability_stat_valid(id: String, stat_id: String) -> bool:
	return stat_id in ability_stat_ids(id)


static func ability_stat_label(stat_id: String) -> String:
	return String(ABILITY_STAT_LABELS.get(stat_id, stat_id.to_upper()))


static func sanitize_ability_stat_levels(id: String, raw: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not raw is Dictionary or not is_ability(id) or is_one_time_ability(id):
		return out
	for stat_variant: Variant in raw:
		var stat_id := str(stat_variant)
		var level := int((raw as Dictionary)[stat_variant])
		if ability_stat_valid(id, stat_id) and level > 0:
			out[stat_id] = clampi(level, 1, MAX_ABILITY_STAT_LEVEL)
	return out


static func ability_stat_upgrade_price(
		id: String, stat_id: String, current_level: int) -> int:
	if not ability_stat_valid(id, stat_id) or current_level < 0 \
			or current_level >= MAX_ABILITY_STAT_LEVEL:
		return -1
	return 0


## Complete authored definition, shared by runtime, menu, and effect factories.
static func ability_definition(id: String) -> AbilityDefinition:
	return AbilityCatalog.definition(id)


## The script that implements an ability, or "" for anything that is not one.
static func ability_script(id: String) -> String:
	var definition := ability_definition(id)
	return definition.implementation.resource_path \
		if definition != null and definition.implementation != null else ""


## The raw numbers behind an ability: damage, range, cooldown and so on.
##
## Kept in the catalogue beside the title and the description because those
## three together are the whole of what a slot needs to describe itself, and
## splitting the numbers into the ability script would mean the menu had to load
## and instance an ability to find out what it does.
static func stats_of(id: String, level := 1,
		stat_levels: Dictionary = {}) -> Dictionary:
	var definition := ability_definition(id)
	if definition == null:
		return {}
	var stats := definition.stats.duplicate(true)
	var added_levels := clampi(level, 1, MAX_ABILITY_LEVEL) - 1
	if added_levels > 0:
		var effect_scale := 1.0 + 0.08 * float(added_levels)
		var cooldown_scale := 1.0 - 0.05 * float(added_levels)
		# These are PvE outputs. `player_damage` is deliberately never scaled;
		# Nuke's radius remains authored until the explicit Size track is trained.
		for key: String in ["damage", "impact"]:
			if stats.has(key) and float(stats[key]) > 0.0:
				stats[key] = float(stats[key]) * effect_scale
		if id == "wall" and stats.has("duration"):
			stats["duration"] = float(stats["duration"]) * effect_scale
		if stats.has("cooldown"):
			stats["cooldown"] = maxf(
				float(stats["cooldown"]) * cooldown_scale, 0.0)
	var clean_levels := sanitize_ability_stat_levels(id, stat_levels)
	for stat_id: String in clean_levels:
		var trained := int(clean_levels[stat_id])
		var scale := 1.0 - ABILITY_COOLDOWN_REDUCTION * float(trained) \
			if stat_id == "cooldown" \
			else 1.0 + ABILITY_STAT_GAIN * float(trained)
		for key: String in ABILITY_STAT_KEYS.get(stat_id, []):
			if stats.has(key) and float(stats[key]) > 0.0:
				stats[key] = maxf(float(stats[key]) * scale, 0.0)
	return stats


static func ability_stat_preview(id: String, ability_level: int,
		stat_levels: Dictionary, stat_id: String) -> String:
	if not ability_stat_valid(id, stat_id):
		return ""
	var current_level := clampi(int(stat_levels.get(stat_id, 0)),
		0, MAX_ABILITY_STAT_LEVEL)
	var next_levels := stat_levels.duplicate(true)
	next_levels[stat_id] = mini(current_level + 1, MAX_ABILITY_STAT_LEVEL)
	var current := stats_of(id, ability_level, stat_levels)
	var next := stats_of(id, ability_level, next_levels)
	var pieces := PackedStringArray()
	for key: String in ABILITY_STAT_KEYS.get(stat_id, []):
		if not current.has(key) or float(current[key]) <= 0.0:
			continue
		pieces.push_back("%s %s → %s" % [
			STAT_LABELS.get(key, key.capitalize()),
			_stat_value(current, key), _stat_value(next, key)])
	return "  •  ".join(pieces)


static func ability_profile(id: String) -> String:
	var definition := ability_definition(id)
	return definition.profile_line() if definition != null else ""


static func ability_icon(id: String) -> Texture2D:
	var definition := ability_definition(id)
	return definition.icon if definition != null else null


## The same numbers written out for a menu, one line each, in a fixed order.
##
## Label and value are separated by a tab so a caller can lay them out in two
## columns without parsing anything back out of the string.
static func stat_lines(id: String, level := 1,
		stat_levels: Dictionary = {}) -> PackedStringArray:
	var stats := stats_of(id, level, stat_levels)
	var lines := PackedStringArray()
	if stats.is_empty():
		return lines
	var written := {}
	for key: String in STAT_ORDER:
		if not stats.has(key):
			continue
		written[key] = true
		lines.append("%s\t%s" % [STAT_LABELS.get(key, key.capitalize()),
			_stat_value(stats, key)])
	# Anything the table above does not know about, so an ability declaring a
	# stat nobody has thought of yet still shows it rather than hiding it.
	for key: String in stats:
		if written.has(key) or key.ends_with("_unit"):
			continue
		lines.append("%s\t%s" % [key.capitalize(), _stat_value(stats, key)])
	return lines


## One stat as it reads on screen. Whole numbers lose their decimal point, since
## "1200 /s" is a damage figure and "1200.0 /s" is a debug print.
static func _stat_value(stats: Dictionary, key: String) -> String:
	var amount := float(stats[key])
	var written := "%d" % int(round(amount)) if is_equal_approx(
		amount, round(amount)) else "%.1f" % amount
	# A per-second or per-hit qualifier authored beside the number, so a
	# sustained beam and a single blow are told apart in the menu.
	return written + String(stats.get(key + "_unit",
		STAT_UNITS.get(key, "")))


## Which WeaponPose hold the arms take this in, or "" for something not held.
static func hold_of(id: String) -> String:
	return String(_field(id, "hold", ""))


## ATTACK_SWING or ATTACK_SHOOT, or "" for an item that does neither.
static func attack_of(id: String) -> String:
	return String(_field(id, "attack", ""))


## Shots the weapon's cell holds, or 0 for a weapon that needs none.
static func cell_size(id: String) -> int:
	return int(_field(id, "cell", 0))


static func tint(id: String) -> Color:
	var definition := ability_definition(id)
	if definition != null:
		return definition.tint
	return _field(id, "tint", Color(0.6, 0.6, 0.6))


## The .glb this item is worn as, or "" for an item with no model.
static func scene_path(id: String) -> String:
	return String(_field(id, "scene", ""))


## Every item that is worn in `slot`, which is how the wardrobe is stocked.
static func items_for_slot(slot: String) -> Array:
	var found := []
	for id in ITEMS:
		if slot_of(id) == slot:
			found.append(id)
	return found


static func _field(id: String, key: String, fallback: Variant) -> Variant:
	var entry: Dictionary = ITEMS.get(id, {})
	return entry.get(key, fallback)
