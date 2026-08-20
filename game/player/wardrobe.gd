class_name Wardrobe
extends RefCounted

## Puts apparel built by assets/source/blender/build_apparel.py onto a character
## instanced from player_character.glb.
##
## Each garment is exported with the same 23 joints, in the same order, as the
## body. That means a garment needs neither its own skeleton nor its own copy of
## the locomotion clips: reparenting its MeshInstance3D onto the body's
## Skeleton3D leaves it driven by whatever the body is already playing.
##
## OnlinePlayer derives its pencil materials by walking every MeshInstance3D
## under the character, so equip before that runs and garments are shaded like
## the rest of the body, picking up the colour baked into their .glb.

const APPAREL := {
	"shoes": "res://assets/runtime/apparel/apparel_shoes.glb",
	"pants": "res://assets/runtime/apparel/apparel_pants.glb",
	"long_sleeve": "res://assets/runtime/apparel/apparel_long_sleeve.glb",
	"hat": "res://assets/runtime/apparel/apparel_hat.glb",
	"goggles": "res://assets/runtime/apparel/apparel_goggles.glb",
}

const NODE_PREFIX := "Apparel_"


static func slots() -> Array:
	return APPAREL.keys()


static func skeleton_of(character: Node) -> Skeleton3D:
	for node in character.find_children("*", "Skeleton3D", true, false):
		return node as Skeleton3D
	return null


## Wears `slot`, replacing whatever occupies it. `source` names the garment .glb
## to wear, so two items sharing a slot can be different garments; it defaults to
## the one garment APPAREL lists for the slot. Returns the garment, or null if the
## slot is unknown or the character has no skeleton.
static func equip(character: Node, slot: String, source := "") -> MeshInstance3D:
	var skeleton := skeleton_of(character)
	if skeleton == null:
		push_error("Wardrobe: %s has no Skeleton3D" % character.name)
		return null
	if source.is_empty():
		if not APPAREL.has(slot):
			push_error("Wardrobe: unknown apparel slot '%s'" % slot)
			return null
		source = APPAREL[slot]

	var scene := load(source) as PackedScene
	if scene == null:
		push_error("Wardrobe: could not load %s" % source)
		return null

	var instance := scene.instantiate()
	var garment: MeshInstance3D = null
	for node in instance.find_children("*", "MeshInstance3D", true, false):
		garment = node as MeshInstance3D
		break
	if garment == null:
		push_error("Wardrobe: %s contains no MeshInstance3D" % source)
		instance.free()
		return null
	var authored_transform := garment.transform
	var preserve_transform := bool(garment.get_meta(
		&"wardrobe_preserve_transform", false))

	# Lift the garment out of its own imported scene, then discard the rest of
	# that scene including its duplicate skeleton.
	garment.get_parent().remove_child(garment)
	instance.free()

	unequip(character, slot)
	garment.name = NODE_PREFIX + slot
	skeleton.add_child(garment)
	garment.transform = authored_transform if preserve_transform \
		else Transform3D.IDENTITY
	# Relative to the garment, so it resolves to the Skeleton3D it now sits under.
	garment.skeleton = NodePath("..")
	return garment


static func unequip(character: Node, slot: String) -> void:
	var skeleton := skeleton_of(character)
	if skeleton == null:
		return
	var worn := skeleton.get_node_or_null(NODE_PREFIX + slot)
	if worn != null:
		skeleton.remove_child(worn)
		worn.queue_free()


static func equip_all(character: Node) -> Array:
	var worn := []
	for slot in APPAREL:
		var garment := equip(character, slot)
		if garment != null:
			worn.append(garment)
	return worn
