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
	"range", "radius", "cooldown", "delay", "launch_height", "launch_speed",
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

## The body slots the equipment column shows, top to bottom.
const SLOT_ORDER := ["hat", "goggles", "long_sleeve", "pants", "shoes"]

const ATTACK_SWING := "swing"
const ATTACK_SHOOT := "shoot"

## Shown on an equipment slot that has nothing in it yet.
const SLOT_LABELS := {
	"hat": "Head",
	"goggles": "Eyes",
	"long_sleeve": "Body",
	"pants": "Legs",
	"shoes": "Feet",
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
static func stats_of(id: String) -> Dictionary:
	var definition := ability_definition(id)
	return definition.stats if definition != null else {}


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
static func stat_lines(id: String) -> PackedStringArray:
	var stats := stats_of(id)
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
