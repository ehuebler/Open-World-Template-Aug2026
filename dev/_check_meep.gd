extends SceneTree

## Structural validation for the generated Meep source-asset package.
##
## Run from the project root:
##
##     Godot_v4.7-stable_win64_console.exe --headless --path . \
##         --script dev/_check_meep.gd

const MODEL_PATH := "res://assets/runtime/meeps/models/meep.glb"
const MANIFEST_PATH := "res://assets/runtime/meeps/manifests/meep_assets.json"
const PAINT_PATH := "res://assets/runtime/biomes/paint/meep_paint.png"
const MATERIAL_PATH := "res://game/meeps/meep_surface.tres"
const SHADER_PATH := "res://shaders/vivid/vivid_meep.gdshader"
const SOURCE_PATH := "res://assets/source/meshmaker/meep.blend"
const SOURCE_SHA256 := \
	"0370bf52f9f7d2b54ad8b4a587f255dd38411f1082c96198d0187fe5f286044c"
const EXPECTED_TRIANGLES := 2800
const REQUIRED_BONES := [
	"Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
	"LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
	"RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
]
const REQUIRED_CLIPS := ["Idle", "Walk", "Run", "Build"]
const VAT_RESOURCES := {
	"Idle": "res://game/meeps/meep_idle_vat.tres",
	"Walk": "res://game/meeps/meep_walk_vat.tres",
	"Run": "res://game/meeps/meep_run_vat.tres",
	"Build": "res://game/meeps/meep_build_vat.tres",
}
const VAT_MODELS := {
	"Idle": "res://assets/runtime/vat/meep_idle_vat.glb",
	"Walk": "res://assets/runtime/vat/meep_walk_vat.glb",
	"Run": "res://assets/runtime/vat/meep_run_vat.glb",
	"Build": "res://assets/runtime/vat/meep_build_vat.glb",
}
const VAT_FRAMES := {"Idle": 90, "Walk": 30, "Run": 20, "Build": 30}

var _failures := 0


func _initialize() -> void:
	var manifest := _read_json(MANIFEST_PATH)
	_check_source_and_manifest(manifest)
	_check_material()
	_check_skeletal_model()
	_check_vat(manifest)
	if _failures == 0:
		print("MEEP VALIDATION PASSED")
	else:
		printerr("MEEP VALIDATION FAILED: %d issue(s)" % _failures)
	quit(_failures)


func _check_source_and_manifest(manifest: Dictionary) -> void:
	var source_hash := FileAccess.get_sha256(SOURCE_PATH).to_lower()
	print("RESULT source_sha256=", source_hash)
	if source_hash != SOURCE_SHA256:
		_fail("immutable source hash changed")
	if manifest.is_empty():
		return
	if str(manifest.get("schema", "")) != "meep_asset_manifest":
		_fail("unexpected manifest schema")
	var source := manifest.get("source", {}) as Dictionary
	if str(source.get("sha256", "")).to_lower() != SOURCE_SHA256:
		_fail("manifest source hash is stale")
	var geometry := manifest.get("geometry", {}) as Dictionary
	if int(geometry.get("triangles", -1)) != EXPECTED_TRIANGLES:
		_fail("manifest triangle count is stale")
	var appearance := manifest.get("appearance", {}) as Dictionary
	if str(appearance.get("color_paint", "")) != PAINT_PATH.trim_prefix("res://"):
		_fail("manifest does not wire the runtime paint PNG")
	if str(appearance.get("runtime_material", "")) != \
			MATERIAL_PATH.trim_prefix("res://"):
		_fail("manifest does not wire the runtime material")
	if str(appearance.get("color_paint_uv", "")).find("TEXCOORD_0") < 0:
		_fail("manifest does not declare TEXCOORD_0 paint")
	if str(appearance.get("vat_vertex_id", "")).find("TEXCOORD_1") < 0:
		_fail("manifest does not declare TEXCOORD_1 VAT IDs")
	var normal_choice := str(
		(manifest.get("vat", {}) as Dictionary).get("normal_animation", ""))
	if normal_choice.find("static base-frame normals") < 0:
		_fail("VAT normal policy is undocumented")


func _check_material() -> void:
	var paint := load(PAINT_PATH) as Texture2D
	if paint == null:
		_fail("could not load deterministic paint PNG")
	elif paint.get_size() != Vector2(256, 256):
		_fail("paint PNG must be 256x256")
	var material := load(MATERIAL_PATH) as ShaderMaterial
	if material == null:
		_fail("could not load Meep runtime material")
		return
	if material.shader == null or material.shader.resource_path != SHADER_PATH:
		_fail("runtime material does not use the dedicated Meep VAT shader")
		return
	if material.get_shader_parameter(&"base_texture") != paint:
		_fail("runtime material does not sample meep_paint.png")
	if not bool(material.get_shader_parameter(&"use_vertex_color")):
		_fail("runtime material does not multiply COLOR_0")
	if not bool(material.get_shader_parameter(
			&"night_emission_from_texture_alpha")):
		_fail("runtime material does not use paint alpha as emission")
	var code := material.shader.code
	for uniform_name in [
			"idle_vat_positions", "walk_vat_positions",
			"run_vat_positions", "build_vat_positions",
	]:
		if code.find(uniform_name) < 0:
			_fail("Meep shader is missing " + uniform_name)
	if code.find("INSTANCE_CUSTOM") < 0 or code.find("UV2.x") < 0:
		_fail("Meep shader does not select clips per instance from TEXCOORD_1")


func _check_skeletal_model() -> void:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		_fail("could not load " + MODEL_PATH)
		return
	var root := packed.instantiate()
	var skeleton := _first_skeleton(root)
	var player := _first_animation_player(root)
	var mesh_instance := _first_mesh(root)
	if skeleton == null:
		_fail("skeletal GLB has no Skeleton3D")
	else:
		print("RESULT bones=", skeleton.get_bone_count())
		if skeleton.get_bone_count() != REQUIRED_BONES.size():
			_fail("expected %d bones, got %d" % [
				REQUIRED_BONES.size(), skeleton.get_bone_count()])
		for bone_name in REQUIRED_BONES:
			if skeleton.find_bone(bone_name) < 0:
				_fail("missing bone " + bone_name)
		var ankle := skeleton.find_bone("LeftFoot")
		var toes := skeleton.find_bone("LeftToes")
		if ankle >= 0 and toes >= 0:
			if skeleton.get_bone_global_rest(toes).origin.z >= \
					skeleton.get_bone_global_rest(ankle).origin.z:
				_fail("Meep toes do not face Godot local -Z")
	if player == null:
		_fail("skeletal GLB has no AnimationPlayer")
	else:
		var names := player.get_animation_list()
		print("RESULT clips=", names)
		for clip_name in REQUIRED_CLIPS:
			if not player.has_animation(clip_name):
				_fail("missing clip " + clip_name)
				continue
			var clip := player.get_animation(clip_name)
			if clip.length <= 0.0 or clip.get_track_count() == 0:
				_fail("empty clip " + clip_name)
			print("RESULT clip %-5s length=%.3f tracks=%d" % [
				clip_name, clip.length, clip.get_track_count()])
	if mesh_instance == null:
		_fail("skeletal GLB has no MeshInstance3D")
	else:
		_check_mesh_streams(mesh_instance.mesh, true, "skeletal")
		var aabb := mesh_instance.mesh.get_aabb()
		print("RESULT skeletal_aabb=", aabb)
		if absf(aabb.position.y) > 0.003 or absf(aabb.size.y - 1.2) > 0.004:
			_fail("skeletal mesh is not 1.2 m tall and grounded")
	root.free()


func _check_vat(manifest: Dictionary) -> void:
	var vat_manifest := manifest.get("vat", {}) as Dictionary
	var clip_manifest := vat_manifest.get("clips", {}) as Dictionary
	for clip_name in REQUIRED_CLIPS:
		var clip := load(str(VAT_RESOURCES[clip_name])) as VatClip
		if clip == null:
			_fail("could not load VAT resource for " + clip_name)
			continue
		if not clip.prepare():
			_fail("VAT metadata/texture failed for " + clip_name)
			continue
		if int(clip.frame_count) != int(VAT_FRAMES[clip_name]):
			_fail("%s VAT has %d frames, expected %d" % [
				clip_name, int(clip.frame_count), int(VAT_FRAMES[clip_name])])
		if clip.vertex_count != 1356 or clip.texture_width != 1356:
			_fail("%s VAT dimensions are not fixed at 1356 vertices" % clip_name)
		var packed := load(str(VAT_MODELS[clip_name])) as PackedScene
		if packed == null:
			_fail("could not load VAT GLB for " + clip_name)
			continue
		var root := packed.instantiate()
		var mesh_instance := _first_mesh(root)
		if mesh_instance == null:
			_fail(clip_name + " VAT GLB has no mesh")
		else:
			_check_mesh_streams(mesh_instance.mesh, false, clip_name + " VAT")
			if not clip.validate_mesh(mesh_instance.mesh):
				_fail(clip_name + " VAT UV2 IDs do not match the EXR")
		root.free()
		var entry := clip_manifest.get(clip_name, {}) as Dictionary
		if int(entry.get("frames", -1)) != int(VAT_FRAMES[clip_name]):
			_fail(clip_name + " manifest frame count is stale")
		if float(entry.get("loop_endpoint_error", 1.0)) > 0.00025:
			_fail(clip_name + " duplicate loop endpoint does not close")
		print("RESULT VAT %-5s texture=%dx%d endpoint_error=%.8f" % [
			clip_name, clip.texture_width, int(clip.frame_count),
			float(entry.get("loop_endpoint_error", -1.0))])


func _check_mesh_streams(mesh: Mesh, skinned: bool, label: String) -> void:
	var vertices := 0
	var triangles := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var surface_vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
		var indices := arrays[Mesh.ARRAY_INDEX] as PackedInt32Array
		var uv := arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array
		var uv2 := arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array
		var colors := arrays[Mesh.ARRAY_COLOR] as PackedColorArray
		vertices += surface_vertices.size()
		triangles += int(indices.size() / 3)
		if uv.size() != surface_vertices.size():
			_fail(label + " lost TEXCOORD_0")
		if uv2.size() != surface_vertices.size():
			_fail(label + " lost TEXCOORD_1")
		if colors.size() != surface_vertices.size():
			_fail(label + " lost COLOR_0")
		elif not colors.is_empty():
			var darkest := 1.0
			var brightest := 0.0
			var average := 0.0
			for color in colors:
				var light := color.get_luminance()
				darkest = minf(darkest, light)
				brightest = maxf(brightest, light)
				average += light
			average /= float(colors.size())
			print("RESULT %s COLOR_0 luminance min=%.3f avg=%.3f max=%.3f"
				% [label, darkest, average, brightest])
			if average < 0.15 or brightest < 0.35:
				_fail(label + " COLOR_0 is too dark for multiplicative paint")
		if skinned:
			var bones := arrays[Mesh.ARRAY_BONES] as PackedInt32Array
			var weights := arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array
			if bones.is_empty() or bones.size() != weights.size() \
					or bones.size() != surface_vertices.size() * 4:
				_fail(label + " does not have normalized four-lane skin arrays")
		var material := mesh.surface_get_material(surface)
		if skinned and material is BaseMaterial3D:
			var base := material as BaseMaterial3D
			print("RESULT imported_vertex_color_as_albedo=",
				base.vertex_color_use_as_albedo,
				" embedded_texture=", base.albedo_texture != null,
				" (external runtime override samples canonical paint)")
	print("RESULT %s vertices=%d triangles=%d" % [
		label, vertices, triangles])
	if triangles != EXPECTED_TRIANGLES:
		_fail("%s has %d triangles, expected %d" % [
			label, triangles, EXPECTED_TRIANGLES])


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("could not open " + path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_fail(path + " is not a JSON object")
		return {}
	return parsed as Dictionary


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


func _fail(message: String) -> void:
	_failures += 1
	printerr("FAIL: " + message)
