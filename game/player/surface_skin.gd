class_name SurfaceSkin
extends RefCounted

## Reskins imported meshes with the game's own surface material.
##
## A .glb arrives wearing plain StandardMaterial3Ds, which look nothing like the
## rest of the world. Every surface gets its own copy of [constant TEMPLATE] with
## that surface's albedo colour and texture copied across, so the look survives
## whatever the .blend is renamed or reorganised into and a new garment needs no
## script change to be shaded like the body.
##
## Only albedo comes across. Roughness, normal maps and UV scale authored in
## Blender do not exist as far as this project is concerned — everything else the
## surface needs is either in the template or manufactured by the shader.

const TEMPLATE := preload("res://game/player/player_suit.tres")


## Paints every mesh under `root`, returning them so callers can keep hold of
## them for shadow and visibility work.
static func apply(root: Node) -> Array[MeshInstance3D]:
	var painted: Array[MeshInstance3D] = []
	# Shared across the whole tree, so surfaces that came from one Blender
	# material still share one material here.
	var derived := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		painted.append(paint(node as MeshInstance3D, derived))
	return painted


static func paint(mesh_instance: MeshInstance3D, derived: Dictionary = {}) -> MeshInstance3D:
	# Characters cast no shadow, and it is decided here because this is the one
	# call every body's meshes already pass through — the player, the home
	# screen's preview, the editor's, and each garment as it is put on. Left to
	# whoever owns the body, it is four places to remember and the previews are
	# the two nobody thinks of.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := mesh_instance.mesh
	if mesh == null:
		return mesh_instance
	for surface in mesh.get_surface_count():
		var source := mesh.surface_get_material(surface)
		if not derived.has(source):
			derived[source] = material_for(source)
		mesh_instance.set_surface_override_material(surface, derived[source])
	return mesh_instance


static func material_for(source: Material) -> ShaderMaterial:
	var material := TEMPLATE.duplicate() as ShaderMaterial
	var standard := source as BaseMaterial3D
	if standard != null:
		material.set_shader_parameter(&"base_color", standard.albedo_color)
		material.set_shader_parameter(&"base_texture", standard.albedo_texture)
	return material


## Multiplies the albedo already painted onto every surface of `mesh_instance`.
## Used by the character editor so a tint is a wash over the authored colour
## rather than a replacement that throws the shading away.
##
## It multiplies what it finds, so it cannot be applied twice to the same
## material: two picks in a row leave the surface the product of both, and two
## meshes sharing one material tint it twice over. Callers that repaint first —
## which is the only way to change a tint rather than deepen it — should tint the
## materials [method paint] handed back instead, one apply each.
static func tint(mesh_instance: MeshInstance3D, colour: Color) -> void:
	var mesh := mesh_instance.mesh
	if mesh == null:
		return
	for surface in mesh.get_surface_count():
		tint_material(mesh_instance.get_surface_override_material(surface) as ShaderMaterial,
			colour)


static func tint_material(material: ShaderMaterial, colour: Color) -> void:
	if material == null:
		return
	var base: Variant = material.get_shader_parameter(&"base_color")
	var current := base as Color if base is Color else Color.WHITE
	material.set_shader_parameter(&"base_color", current * colour)
