"""Reports where the arms sit: the rest angles the pose tables are relative to,
and how close each clip brings an arm to the body.

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup blender_assets/source/player_character.blend --python blender_assets/source/_arm_check.py

The clearance is measured on the deformed mesh rather than the bones, since an arm
sinking into a hip is a mesh question. It reads the pose tables out of
`build_animations.py`, so it reports what the next bake would produce, and it
leaves the file alone.
"""

import importlib
import math
import os
import sys

import bpy
import mathutils.kdtree

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)
build_animations = importlib.import_module("build_animations")

ARM_GROUPS = ("Shoulder", "UpperArm", "LowerArm", "Hand")


def rest_report(rig):
    print("--- rest pose, right arm ---")
    for name in ("RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"):
        bone = rig.data.bones[name]
        head, tail = bone.head_local, bone.tail_local
        delta = tail - head
        out = math.degrees(math.atan2(delta.x, -delta.z)) if delta.z else 90.0
        print("  {0:<14} head ({1:.3f}, {2:.3f}, {3:.3f}) tail ({4:.3f}, {5:.3f}, {6:.3f})"
              "  len {7:.3f}  {8:.1f} deg out from straight down".format(
                  name, head.x, head.y, head.z, tail.x, tail.y, tail.z, delta.length, out))


def torso_width(mesh_obj):
    """Half-width of the body without the arms, in 0.1 m bands."""
    arm_indices = {group.index for group in mesh_obj.vertex_groups
                   if any(part in group.name for part in ARM_GROUPS)}
    bands = {}
    for vertex in mesh_obj.data.vertices:
        if any(g.group in arm_indices and g.weight > 0.2 for g in vertex.groups):
            continue
        band = round(vertex.co.z * 10.0) / 10.0
        bands[band] = max(bands.get(band, 0.0), abs(vertex.co.x))
    print("--- body half-width without arms (m) ---")
    for band in sorted(bands, reverse=True):
        if band < 0.4:
            continue
        print("  z {0:.1f}  {1:.3f}".format(band, bands[band]))


def arm_gap(mesh_obj):
    """Closest approach between an arm and the rest of the body, as posed."""
    arm_indices = {group.index for group in mesh_obj.vertex_groups
                   if any(part in group.name for part in ARM_GROUPS)}
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = mesh_obj.evaluated_get(depsgraph).to_mesh()
    arm_points, body_points = [], []
    for vertex, source in zip(evaluated.vertices, mesh_obj.data.vertices):
        on_arm = any(g.group in arm_indices and g.weight > 0.5 for g in source.groups)
        # Shoulders always touch the chest; only the free part of the arm matters.
        if on_arm and vertex.co.z < 0.93:
            arm_points.append(vertex.co.copy())
        elif not on_arm:
            body_points.append(vertex.co.copy())
    tree = mathutils.kdtree.KDTree(len(body_points))
    for index, point in enumerate(body_points):
        tree.insert(point, index)
    tree.balance()
    closest = min((tree.find(point)[2] for point in arm_points), default=0.0)
    mesh_obj.evaluated_get(depsgraph).to_mesh_clear()
    return closest


def pose_report(rig, name, pose_function, phases, mesh_obj=None):
    for phase in phases:
        pose = pose_function(phase)
        for pose_bone in rig.pose.bones:
            build_animations.set_bone_pose(pose_bone, pose.get(pose_bone.name, {}))
        bpy.context.view_layer.update()
        gap = "" if mesh_obj is None else "  gap to body {0:.3f}".format(arm_gap(mesh_obj))
        shoulder = rig.pose.bones["RightUpperArm"].head
        elbow = rig.pose.bones["RightLowerArm"].head
        wrist = rig.pose.bones["RightHand"].head
        hand = rig.pose.bones["RightHand"].tail
        upper = elbow - shoulder
        out = math.degrees(math.atan2(upper.x, -upper.z))
        print("  {0:<10} phase {1:.2f}  elbow x {2:.3f} z {3:.3f}  wrist x {4:.3f} z {5:.3f}"
              "  hand x {6:.3f} z {7:.3f}  {8:.1f} deg out{9}".format(
                  name, phase, elbow.x, elbow.z, wrist.x, wrist.z, hand.x, hand.z, out, gap))


def main():
    rig = bpy.data.objects["CharacterRig"]
    mesh_obj = bpy.data.objects["Character"]
    rest_report(rig)
    torso_width(mesh_obj)
    print("--- posed ---")
    for name, _frames, _looping, pose_function in build_animations.ANIMATIONS:
        pose_report(rig, name, pose_function, (0.0, 0.25, 0.5, 0.75), mesh_obj)
    build_animations.clear_pose(rig)


if __name__ == "__main__":
    main()
