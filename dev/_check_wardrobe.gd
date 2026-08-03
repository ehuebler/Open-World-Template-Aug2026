@tool
extends SceneTree

# Verifies blender_assets/wardrobe.glb imports the way the prop is meant to be
# used: three mesh nodes, and door origins sitting on their hinge lines so that
# setting rotation.y swings them without any offset node in between.

const WARDROBE := "res://blender_assets/wardrobe.glb"


func _init() -> void:
	var scene := load(WARDROBE) as PackedScene
	if scene == null:
		push_error("could not load %s" % WARDROBE)
		quit(1)
		return

	var root := scene.instantiate()
	print("root: %s (%s)" % [root.name, root.get_class()])

	var meshes: Dictionary = {}
	for child in root.get_children():
		print("  %s (%s)" % [child.name, child.get_class()])
		if child is MeshInstance3D:
			meshes[String(child.name)] = child

	var whole := AABB()
	var first := true
	for name in meshes:
		var node: MeshInstance3D = meshes[name]
		var box: AABB = node.get_aabb()
		var world := node.transform * box
		whole = world if first else whole.merge(world)
		first = false
		var surfaces: Array[String] = []
		for i in node.mesh.get_surface_count():
			var material := node.mesh.surface_get_material(i)
			surfaces.append(material.resource_name if material != null else "<none>")
		print("  %-14s origin=%v surfaces=%s" % [name, node.position, ", ".join(surfaces)])

	print("bounds: size=%v at %v" % [whole.size, whole.position])
	print("front faces -Z: %s" % str(absf(whole.position.z) > absf(whole.end.z)))

	# The hinge check: swing each door and confirm the pivot edge stays put while
	# the leading edge travels forward, which is only true if the origin is on the
	# hinge line.
	for door_name in ["WardrobeDoorL", "WardrobeDoorR"]:
		if not meshes.has(door_name):
			push_error("missing %s" % door_name)
			continue
		var door: MeshInstance3D = meshes[door_name]
		var sign := 1.0 if door_name.ends_with("L") else -1.0
		var rest := door.transform * door.get_aabb()
		door.rotation.y = deg_to_rad(100.0) * sign
		var swung := door.transform * door.get_aabb()
		print("%s closed=%v..%v swung=%v..%v travel=%.3f" % [
			door_name, rest.position, rest.end, swung.position, swung.end,
			(swung.get_center() - rest.get_center()).length()])
		door.rotation.y = 0.0

	root.free()
	quit(0)
