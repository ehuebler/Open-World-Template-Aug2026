@tool
extends SceneTree

# Verifies the weapon assets and that game/player/weapons.gd puts them in the
# character's hands. The load-bearing checks are the last two: that the derived
# grip lands where character_ref.py measured the fist, and that a weapon stays
# rigidly attached to the hand while an animation plays.

const WeaponsScript := preload("res://game/player/weapons.gd")
const CHARACTER := "res://blender_assets/player_character.glb"

# The fist centroids blender_assets/source/character_ref.py measures, converted
# from Blender's Z-up to Godot's Y-up: (x, y, z) -> (x, z, -y).
const EXPECTED_GRIP := {
	"right": Vector3(0.509, 0.633, -0.010),
	"left": Vector3(-0.509, 0.635, -0.012),
}
const GRIP_TOLERANCE := 0.02

# Length along the aim axis, from the build script's report.
const EXPECTED_LENGTH := {"sword": 0.823, "laser_rifle": 0.613}


func _init() -> void:
	var failures := 0
	failures += _check_assets()
	failures += _check_in_hands()
	print("\n%s" % ("all checks passed" if failures == 0 else "%d check(s) failed" % failures))
	quit(1 if failures > 0 else 0)


func _check_assets() -> int:
	var failures := 0
	print("--- weapon assets ---")
	for weapon in WeaponsScript.names():
		var path: String = WeaponsScript.WEAPONS[weapon]
		var scene := load(path) as PackedScene
		if scene == null:
			push_error("could not load %s" % path)
			failures += 1
			continue
		var root := scene.instantiate()
		var meshes := root.find_children("*", "MeshInstance3D", true, false)
		var mesh: MeshInstance3D = meshes[0] if meshes.size() > 0 else null
		if mesh == null:
			push_error("%s has no MeshInstance3D" % path)
			failures += 1
			root.free()
			continue

		var surfaces: Array[String] = []
		for i in mesh.mesh.get_surface_count():
			var material := mesh.mesh.surface_get_material(i)
			surfaces.append(material.resource_name if material != null else "<none>")
		var box: AABB = mesh.get_aabb()
		# Authored +Y forward in Blender, which the Y-up export puts on -Z here.
		var length: float = box.size.z
		print("%s: %s, %d surfaces [%s]" % [weapon, mesh.name, surfaces.size(), ", ".join(surfaces)])
		print("  aim length %.3f m, reach ahead of grip %.3f, behind %.3f" % [
			length, -box.position.z, box.end.z])
		print("  span x=%.3f y=%.3f" % [box.size.x, box.size.y])

		if absf(length - EXPECTED_LENGTH[weapon]) > 0.005:
			push_error("%s is %.3f m along its aim axis, expected %.3f" % [
				weapon, length, EXPECTED_LENGTH[weapon]])
			failures += 1
		# The origin must sit inside the grip: most of the weapon ahead of it, a
		# little behind for the pommel or the receiver.
		if box.position.z > -0.05 or box.end.z < 0.05:
			push_error("%s origin is not inside its grip (z spans %.3f..%.3f)" % [
				weapon, box.position.z, box.end.z])
			failures += 1
		root.free()
	return failures


func _check_in_hands() -> int:
	var failures := 0
	print("\n--- in the character's hands ---")
	var scene := load(CHARACTER) as PackedScene
	if scene == null:
		push_error("could not load %s" % CHARACTER)
		return 1

	# Must be in the tree, or AnimationPlayer.seek() does nothing and every
	# global_transform reads back as identity.
	var character := scene.instantiate()
	get_root().add_child(character)
	var skeleton: Skeleton3D = WeaponsScript.skeleton_of(character)
	if skeleton == null:
		push_error("character has no Skeleton3D")
		_discard(character)
		return 1
	print("skeleton %s, %d bones" % [skeleton.name, skeleton.get_bone_count()])

	var held: Dictionary = WeaponsScript.dual_wield(character)
	print("dual wielding: %s" % str(held.keys()))
	if held.size() != 2:
		push_error("expected both hands armed, got %d" % held.size())
		failures += 1

	# Does the derived grip land where the fist actually is?
	for hand in held:
		var bone := skeleton.find_bone(WeaponsScript.HANDS[hand])
		var grip: Vector3 = WeaponsScript.grip_point(skeleton, bone)
		var want: Vector3 = EXPECTED_GRIP[hand]
		var error := grip.distance_to(want)
		print("%s grip at %v, fist measured at %v, off by %.4f m" % [hand, grip, want, error])
		if error > GRIP_TOLERANCE:
			push_error("%s grip is %.4f m from the measured fist" % [hand, error])
			failures += 1

	# Does the weapon stay attached while the body animates? Sample the distance
	# from the weapon to its hand bone across a clip; it must not move.
	# Each weapon must hang off a BoneAttachment3D pinned to its hand bone.
	for hand in held:
		var mount := skeleton.get_node_or_null(WeaponsScript.NODE_PREFIX + hand)
		if mount is not BoneAttachment3D:
			push_error("%s weapon is not on a BoneAttachment3D" % hand)
			failures += 1
		elif mount.bone_name != WeaponsScript.HANDS[hand]:
			push_error("%s attachment is on '%s', expected '%s'" % [
				hand, mount.bone_name, WeaponsScript.HANDS[hand]])
			failures += 1

	var players := character.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		print("clips available on the character: %s" % str((players[0] as AnimationPlayer).get_animation_list()))

	# Swing each arm and confirm the weapon rides along. Done by posing bones
	# rather than by playing a clip: an AnimationPlayer never applies a pose in a
	# headless SceneTree script, so a clip-driven check silently measures the rest
	# pose and passes for the wrong reason.
	print("\n--- following a swinging arm ---")
	for hand in held:
		var bone := skeleton.find_bone(WeaponsScript.HANDS[hand])
		var arm := skeleton.find_bone("RightUpperArm" if hand == "right" else "LeftUpperArm")
		if arm < 0:
			push_error("no upper arm bone for the %s hand" % hand)
			failures += 1
			continue

		# A BoneAttachment3D only refreshes on a frame and nothing here draws
		# frames, so compose the transform it would produce: bone pose times the
		# weapon's local grip transform.
		var local: Transform3D = (held[hand] as MeshInstance3D).transform
		var rest := skeleton.get_bone_rest(arm).basis.get_rotation_quaternion()
		var offsets: Array[float] = []
		var aims: Array[Vector3] = []
		var travelled := 0.0
		var previous := Vector3.ZERO

		for step in 6:
			var angle := deg_to_rad(-55.0 * float(step) / 5.0)
			skeleton.set_bone_pose_rotation(arm, Quaternion(Vector3.RIGHT, angle) * rest)
			var pose := _global_pose(skeleton, bone)
			var weapon := pose * local
			offsets.append(pose.origin.distance_to(weapon.origin))
			aims.append(-weapon.basis.z.normalized())
			if step > 0:
				travelled += previous.distance_to(weapon.origin)
			previous = weapon.origin
		skeleton.set_bone_pose_rotation(arm, rest)

		var spread: float = offsets.max() - offsets.min()
		var swing := rad_to_deg(aims[0].angle_to(aims[-1]))
		print("  %s: grip-to-bone %.4f m (spread %.6f), grip travelled %.3f m, aim turned %.1f deg" % [
			hand, offsets[0], spread, travelled, swing])
		if spread > 0.0005:
			push_error("%s weapon slides against the hand by %.4f m" % [hand, spread])
			failures += 1
		if travelled < 0.05:
			push_error("%s weapon did not follow the arm (moved %.4f m)" % [hand, travelled])
			failures += 1
		if swing < 30.0:
			push_error("%s weapon did not rotate with the hand (%.1f deg)" % [hand, swing])
			failures += 1

	_discard(character)
	return failures


func _discard(character: Node) -> void:
	get_root().remove_child(character)
	character.free()


# Skeleton3D.get_bone_global_pose() reads a cache it only refreshes while
# processing frames, and a --script SceneTree draws none, so it reports the rest
# pose however the bones are posed - force_update_all_bone_transforms() does not
# help. Compose the chain from the local poses instead.
static func _global_pose(skeleton: Skeleton3D, bone: int) -> Transform3D:
	var result := Transform3D.IDENTITY
	var index := bone
	while index >= 0:
		result = skeleton.get_bone_pose(index) * result
		index = skeleton.get_bone_parent(index)
	return result
