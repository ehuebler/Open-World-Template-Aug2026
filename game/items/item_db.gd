class_name ItemDB
extends RefCounted

## Every item the game can put in a slot.
##
## `slot` is the body slot a garment occupies and matches the keys in
## Wardrobe.APPAREL, which is what lets an equipment slot decide on its own
## whether a dropped item belongs in it. Weapons use the slot WEAPON instead, so
## the weapon rack accepts them and the body slots do not. Items that cannot be
## held or worn leave it empty. `scene` is the .glb, worn on the body or put in the
## hands and also rendered into the item's icon; `tint` stands in for the icon
## until that render lands.
##
## A weapon carries three more fields: `hold`, one of the WeaponPose holds, which
## decides how the arms take it; `attack`, either ATTACK_SWING or ATTACK_SHOOT; and
## for a shooting weapon, `cell`, how many shots it stores.

const ITEMS := {
	"straw_hat": {
		"title": "Straw Hat",
		"description": "Woven brim gone soft at the edges. Sits low enough to keep the sun off the page.",
		"slot": "hat",
		"scene": "res://blender_assets/apparel_hat.glb",
		"tint": Color(0.9023, 0.7954, 0.4978),
	},
	"flight_goggles": {
		"title": "Flight Goggles",
		"description": "Brass rims on a webbing strap. Worn on the brow, and they tuck under a hat rather than fighting it.",
		"slot": "goggles",
		"scene": "res://blender_assets/apparel_goggles.glb",
		"tint": Color(0.5271, 0.4014, 0.2216),
	},
	"rust_long_sleeve": {
		"title": "Rust Long Sleeve",
		"description": "Heavy cotton, cuffs to the wrist. The dye has faded unevenly, which is most of its charm.",
		"slot": "long_sleeve",
		"scene": "res://blender_assets/apparel_long_sleeve.glb",
		"tint": Color(0.7906, 0.5459, 0.522),
	},
	"denim_trousers": {
		"title": "Denim Trousers",
		"description": "Stiff blue workwear, turned up at the ankle so the hem clears your shoes.",
		"slot": "pants",
		"scene": "res://blender_assets/apparel_pants.glb",
		"tint": Color(0.5021, 0.5639, 0.6682),
	},
	"leather_shoes": {
		"title": "Leather Shoes",
		"description": "Scuffed brown leather on a flat sole. Quiet on floorboards, loud on gravel.",
		"slot": "shoes",
		"scene": "res://blender_assets/apparel_shoes.glb",
		"tint": Color(0.4614, 0.41, 0.3811),
	},
	"c3_hair": {
		"title": "Settler Hair",
		"description": "Spiked and cut from the dressed settler. Sits on the scalp and takes a tint.",
		"slot": "hat",
		"scene": "res://blender_assets/apparel_c3_hair.glb",
		"tint": Color(0.10, 0.11, 0.20),
	},
	"c3_goggles": {
		"title": "Settler Goggles",
		"description": "Smoked slate lenses on a wide band. Cut for the settler's skull, which is a different shape entirely.",
		"slot": "goggles",
		"scene": "res://blender_assets/apparel_c3_goggles.glb",
		"tint": Color(0.2412, 0.3106, 0.4183),
	},
	"c3_tunic": {
		"title": "Settler Tunic",
		"description": "Capped at the shoulder and flared at the hem, over bare legs.",
		"slot": "long_sleeve",
		"scene": "res://blender_assets/apparel_c3_tunic.glb",
		"tint": Color(0.25, 0.26, 0.34),
	},
	"c3_boots": {
		"title": "Settler Boots",
		"description": "Heavy soles and a cuff at mid-shin. A pair, and they clear each other.",
		"slot": "shoes",
		"scene": "res://blender_assets/apparel_c3_boots.glb",
		"tint": Color(0.10, 0.11, 0.17),
	},
	"sword": {
		"title": "Drill Sword",
		"description": "Brass furniture on a leather-wrapped grip. Held two-handed, blade up, and cut across the body from right to left.",
		"slot": "weapon",
		"scene": "res://blender_assets/sword.glb",
		"hold": "blade",
		"attack": "swing",
		"tint": Color(0.72, 0.735, 0.76),
	},
	"laser_rifle": {
		"title": "Laser Carbine",
		"description": "Twelve shots in a cell that trickles back up on its own. Left hand under the barrel, right on the trigger; right click to sight down the optic.",
		"slot": "weapon",
		"scene": "res://blender_assets/laser_rifle.glb",
		"hold": "rifle",
		"attack": "shoot",
		"cell": 12,
		"tint": Color(0.44, 0.47, 0.5),
	},
}

## The body slots the equipment column shows, top to bottom.
const SLOT_ORDER := ["hat", "goggles", "long_sleeve", "pants", "shoes"]

## The slot anything carried in the hands occupies, whatever else it is.
const WEAPON := "weapon"

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
	return ITEMS.has(id)


static func title(id: String) -> String:
	return String(_field(id, "title", id))


static func description(id: String) -> String:
	return String(_field(id, "description", ""))


## The body slot this item is worn in, or "" if it cannot be worn.
static func slot_of(id: String) -> String:
	return String(_field(id, "slot", ""))


static func is_weapon(id: String) -> bool:
	return slot_of(id) == WEAPON


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
