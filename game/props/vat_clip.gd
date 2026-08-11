@tool
class_name VatClip
extends Resource

## One baked vertex animation and the numbers needed to decode it.
##
## The JSON is deliberately kept beside the EXR instead of transcribed into a
## .tres: the Blender bake is authoritative, and re-baking a mesh must not leave
## an old vertex/frame count silently attached to the new texture.

@export var positions: Texture2D
@export_file("*.json") var metadata_path := ""
@export_range(0.0, 4.0) var playback_speed := 1.0

var frame_count := 1.0
var vertex_count := 1
var texture_width := 1
var frames_per_second := 24.0
var delta_minimum := Vector3.ZERO
var delta_maximum := Vector3.ZERO
var _prepared := false


func prepare() -> bool:
	if _prepared:
		return positions != null and frame_count > 0.0
	_prepared = true
	if positions == null:
		push_error("VatClip '%s' has no position texture" % resource_path)
		return false
	if metadata_path.is_empty():
		push_error("VatClip '%s' has no metadata path" % resource_path)
		return false
	var file := FileAccess.open(metadata_path, FileAccess.READ)
	if file == null:
		push_error("VatClip cannot open '%s'" % metadata_path)
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("VatClip metadata '%s' is not a JSON object" % metadata_path)
		return false
	var data := parsed as Dictionary
	frame_count = float(data.get("frame_count", 0))
	vertex_count = int(data.get("vertex_count", 0))
	texture_width = int(data.get("texture_width", data.get("width", vertex_count)))
	frames_per_second = float(data.get("fps", 24.0))
	delta_minimum = _vector(data.get("delta_min", [0.0, 0.0, 0.0]))
	delta_maximum = _vector(data.get("delta_max", [0.0, 0.0, 0.0]))
	if frame_count < 1.0 or vertex_count < 1:
		push_error("VatClip metadata '%s' has invalid dimensions" % metadata_path)
		return false
	var image_size := positions.get_size()
	if image_size.x != texture_width or texture_width < vertex_count \
			or image_size.y != int(frame_count):
		push_error("VatClip '%s' texture is %dx%d but metadata asks for %dx%d" % [
			resource_path, image_size.x, image_size.y, texture_width, int(frame_count)])
		return false
	var image := positions.get_image()
	if image == null or image.has_mipmaps():
		push_error("VatClip '%s' must import as a readable texture without mipmaps"
			% resource_path)
		return false
	if image.get_format() not in [
			Image.FORMAT_RGBF, Image.FORMAT_RGBAF,
			Image.FORMAT_RGBH, Image.FORMAT_RGBAH,
	]:
		push_error("VatClip '%s' lost its HDR precision during import (format %d)"
			% [resource_path, image.get_format()])
		return false
	return true


func apply(material: ShaderMaterial) -> bool:
	if material == null or not prepare():
		return false
	material.set_shader_parameter(&"vat_enabled", true)
	material.set_shader_parameter(&"vat_positions", positions)
	material.set_shader_parameter(&"vat_frame_count", frame_count)
	material.set_shader_parameter(&"vat_fps", frames_per_second)
	material.set_shader_parameter(&"vat_delta_min", delta_minimum)
	material.set_shader_parameter(&"vat_delta_max", delta_maximum)
	material.set_shader_parameter(&"vat_playback_speed", playback_speed)
	return true


func validate_mesh(mesh: Mesh) -> bool:
	if mesh == null or not prepare():
		return false
	var seen := {}
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var uv2 := arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array
		if uv2.is_empty() or uv2.size() != mesh.surface_get_array_len(surface):
			push_error("VatClip '%s' mesh surface %d has no stable UV2 vertex IDs"
				% [resource_path, surface])
			return false
		for encoded in uv2:
			var vertex_id := floori(encoded.x * float(texture_width))
			if vertex_id < 0 or vertex_id >= vertex_count:
				push_error("VatClip '%s' mesh has UV2 ID %d outside 0..%d"
					% [resource_path, vertex_id, vertex_count - 1])
				return false
			seen[vertex_id] = true
	if seen.size() != vertex_count:
		push_error("VatClip '%s' mesh exposes %d of %d baked vertex IDs"
			% [resource_path, seen.size(), vertex_count])
		return false
	return true


func _vector(value: Variant) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if value is Dictionary:
		return Vector3(float(value.get("x", 0.0)), float(value.get("y", 0.0)),
			float(value.get("z", 0.0)))
	return Vector3.ZERO
