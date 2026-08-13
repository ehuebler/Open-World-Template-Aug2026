class_name CombatantFlash
extends RefCounted

## Local-only red overlay flash for a rigged mob mesh hierarchy.
##
## Adds transient unshaded overlays on every [MeshInstance3D] under [param root]
## without replacing imported materials or mutating shared state.

const DURATION := 0.38
const PEAK_ALPHA := 0.62


static func flash(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		return
	for mesh: MeshInstance3D in _collect_meshes(root):
		_flash_mesh(mesh)


static func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child: Node in node.get_children():
		if child is CombatantFlashOverlay:
			continue
		out.append_array(_collect_meshes(child))
	return out


static func _flash_mesh(source: MeshInstance3D) -> void:
	if source.mesh == null:
		return
	for child: Node in source.get_children():
		if child is CombatantFlashOverlay:
			(child as CombatantFlashOverlay).retrigger()
			return
	var overlay := CombatantFlashOverlay.new()
	overlay.name = "DamageFlashOverlay"
	source.add_child(overlay)
	overlay.setup(source, DURATION, PEAK_ALPHA)
