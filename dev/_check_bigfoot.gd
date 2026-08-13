extends SceneTree

## Structural validation for assets/runtime/characters/bigfoot.glb.
##
## Run from the project root:
##
##     godot --headless --path . --script dev/_check_bigfoot.gd

const PATH := "res://assets/runtime/characters/bigfoot.glb"
const REQUIRED_BONES := [
	"Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
]
const REQUIRED_CLIPS := [
	"Idle", "Walk", "Run", "Roar", "MeteorWindup", "MeteorFly",
	"MeteorImpact", "Punch", "Grab", "Throw", "HitReact", "Defeat",
]
const LOOP_CLIPS := ["Idle", "Walk", "Run", "MeteorFly"]

var _failures := 0


func _initialize() -> void:
	var packed := load(PATH) as PackedScene
	if packed == null:
		_fail("could not load " + PATH)
		quit(_failures)
		return
	var root := packed.instantiate()
	var skeleton := _first_skeleton(root)
	var player := _first_animation_player(root)
	var mesh_instance := _first_mesh(root)
	if skeleton == null:
		_fail("no Skeleton3D")
	else:
		_check_skeleton(skeleton)
	if player == null:
		_fail("no AnimationPlayer")
	else:
		_check_animations(player)
	if mesh_instance == null:
		_fail("no MeshInstance3D")
	else:
		_check_mesh(mesh_instance)
	root.free()
	if _failures == 0:
		print("BIGFOOT VALIDATION PASSED")
	else:
		printerr("BIGFOOT VALIDATION FAILED: %d issue(s)" % _failures)
	quit(_failures)


func _first_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _first_skeleton(child)
		if found != null:
			return found
	return null


func _first_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _first_animation_player(child)
		if found != null:
			return found
	return null


func _first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null


func _check_skeleton(skeleton: Skeleton3D) -> void:
	print("RESULT bones=", skeleton.get_bone_count())
	if skeleton.get_bone_count() != REQUIRED_BONES.size():
		_fail("expected %d bones, got %d" % [
			REQUIRED_BONES.size(), skeleton.get_bone_count(),
		])
	for bone_name in REQUIRED_BONES:
		if skeleton.find_bone(bone_name) < 0:
			_fail("missing bone " + bone_name)

	var left_hand := skeleton.find_bone("LeftHand")
	var right_hand := skeleton.find_bone("RightHand")
	var left_foot := skeleton.find_bone("LeftFoot")
	var left_toes := skeleton.find_bone("LeftToes")
	if left_hand < 0 or right_hand < 0 or left_foot < 0 or left_toes < 0:
		return
	var left_hand_position := skeleton.get_bone_global_rest(left_hand).origin
	var right_hand_position := skeleton.get_bone_global_rest(right_hand).origin
	var ankle := skeleton.get_bone_global_rest(left_foot).origin
	var toe := skeleton.get_bone_global_rest(left_toes).origin
	print("RESULT hands=", left_hand_position, " / ", right_hand_position)
	print("RESULT ankle=", ankle, " toe=", toe)
	# Blender +Y becomes Godot -Z without changing X: anatomical left is -X.
	if left_hand_position.x >= 0.0 or right_hand_position.x <= 0.0:
		_fail("hand bones are on the wrong Godot sides")
	if toe.z >= ankle.z:
		_fail("toes do not face Godot -Z")


func _check_animations(player: AnimationPlayer) -> void:
	var names := player.get_animation_list()
	print("RESULT clips=", names)
	for clip_name in REQUIRED_CLIPS:
		if not player.has_animation(clip_name):
			_fail("missing clip " + clip_name)
			continue
		var clip := player.get_animation(clip_name)
		if clip.length <= 0.0 or clip.get_track_count() == 0:
			_fail("empty clip " + clip_name)
		print("RESULT clip %-14s %.2fs tracks=%d loop=%d" % [
			clip_name, clip.length, clip.get_track_count(), clip.loop_mode,
		])
	for clip_name in LOOP_CLIPS:
		if player.has_animation(clip_name):
			var clip := player.get_animation(clip_name)
			if clip.loop_mode == Animation.LOOP_NONE:
				print("NOTE: ", clip_name,
					" is cyclically keyed but glTF carries no loop metadata")


func _check_mesh(mesh_instance: MeshInstance3D) -> void:
	var mesh := mesh_instance.mesh
	var aabb := mesh.get_aabb()
	var vertex_count := 0
	var triangle_count := 0
	var color_count := 0
	var bone_value_count := 0
	var weight_value_count := 0
	var uses_vertex_color := false
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		vertex_count += vertices.size()
		triangle_count += int(indices.size() / 3)
		color_count += colors.size()
		bone_value_count += bones.size()
		weight_value_count += weights.size()
		var material := mesh.surface_get_material(surface)
		if material is BaseMaterial3D:
			uses_vertex_color = uses_vertex_color or \
				(material as BaseMaterial3D).vertex_color_use_as_albedo
			print("RESULT vertex_color_as_albedo=",
				(material as BaseMaterial3D).vertex_color_use_as_albedo,
				" srgb=", (material as BaseMaterial3D).vertex_color_is_srgb)
	print("RESULT aabb=", aabb)
	print("RESULT mesh vertices=%d triangles=%d colors=%d bones=%d weights=%d" % [
		vertex_count, triangle_count, color_count,
		bone_value_count, weight_value_count,
	])
	if absf(aabb.size.y - 3.2) > 0.01 or absf(aabb.position.y) > 0.01:
		_fail("mesh is not 3.2 m tall and grounded")
	if triangle_count != 30000:
		_fail("expected 30000 triangles, got %d" % triangle_count)
	if color_count != vertex_count:
		_fail("COLOR_0 is missing or incomplete")
	if not uses_vertex_color:
		_fail("runtime material does not sample COLOR_0 as albedo")
	if bone_value_count == 0 or bone_value_count != weight_value_count:
		_fail("skin bone/weight arrays are missing or mismatched")


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: " + message)
