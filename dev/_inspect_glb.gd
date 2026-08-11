extends SceneTree


func _initialize() -> void:
	var scene: PackedScene = load("res://assets/runtime/characters/player_character.glb")
	var root := scene.instantiate()
	_walk(root, 0)
	quit()


func _walk(node: Node, depth: int) -> void:
	var line := "  ".repeat(depth) + "%s [%s]" % [node.name, node.get_class()]
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		line += " surfaces=%d aabb=%s skin=%s" % [
			mesh.get_surface_count(),
			mesh.get_aabb(),
			str((node as MeshInstance3D).skin != null),
		]
		for i in mesh.get_surface_count():
			var material := mesh.surface_get_material(i)
			var albedo := "?"
			if material is BaseMaterial3D:
				albedo = str((material as BaseMaterial3D).albedo_color)
			line += "\n" + "  ".repeat(depth + 1) + "surface %d: %s %s" % [i, material.resource_name, albedo]
	elif node is AnimationPlayer:
		var player := node as AnimationPlayer
		for anim_name in player.get_animation_list():
			var animation := player.get_animation(anim_name)
			line += "\n" + "  ".repeat(depth + 1) + "%s  %.2fs loop=%d tracks=%d" % [
				anim_name, animation.length, animation.loop_mode, animation.get_track_count(),
			]
	elif node is Skeleton3D:
		var skeleton := node as Skeleton3D
		line += " bones=%d" % skeleton.get_bone_count()
		for i in skeleton.get_bone_count():
			var rest := skeleton.get_bone_global_rest(i)
			line += "\n" + "  ".repeat(depth + 1) + "%-16s y=%.3f x=%.3f z=%.3f" % [
				skeleton.get_bone_name(i), rest.origin.y, rest.origin.x, rest.origin.z,
			]
	elif node is Node3D:
		line += " xform_origin=%s" % (node as Node3D).transform.origin
	print(line)
	for child in node.get_children():
		_walk(child, depth + 1)
