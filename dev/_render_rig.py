"""Diagnostic renders of a rigged character .blend: rest pose plus clip frames.

    blender --background <file.blend> --python dev/_render_rig.py -- --out=NAME [--clip=Walk]

Bones are drawn as capsule proxies parented to each bone, so a rig that does not
sit inside the mesh is visible rather than inferred from numbers.
"""

import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "source", "blender"))
import previewkit  # noqa: E402

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "previews", "authoring")


def args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = "rig"
    clip = "Walk"
    bones = False
    for entry in argv:
        if entry.startswith("--out="):
            out = entry.split("=", 1)[1]
        elif entry.startswith("--clip="):
            clip = entry.split("=", 1)[1]
        elif entry == "--bones":
            bones = True
    return out, clip, bones


def bone_proxies(rig):
    """A thin capsule per bone, parented so it follows the pose."""
    made = []
    material = bpy.data.materials.new("BoneProxy")
    material.use_nodes = True
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (1.0, 0.25, 0.05, 1.0)
        bsdf.inputs["Emission Color"].default_value = (1.0, 0.35, 0.05, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 3.0
    for bone in rig.data.bones:
        length = (bone.tail_local - bone.head_local).length
        if length < 1.0e-4:
            continue
        bpy.ops.mesh.primitive_cylinder_add(radius=max(0.006, length * 0.06), depth=length)
        proxy = bpy.context.active_object
        proxy.name = "proxy_" + bone.name
        proxy.data.materials.append(material)
        # Bone space is Y-along-bone; the cylinder is Z-along, hence the tilt.
        proxy.rotation_euler = (1.5707963, 0.0, 0.0)
        proxy.location = (0.0, length * 0.5, 0.0)
        bpy.ops.object.transform_apply(location=True, rotation=True)
        proxy.parent = rig
        proxy.parent_type = "BONE"
        proxy.parent_bone = bone.name
        # A bone parent puts the child at the bone's tail, so step back its length.
        proxy.matrix_parent_inverse = Vector((0.0, 0.0, 0.0)).to_track_quat().to_matrix().to_4x4()
        proxy.location = (0.0, -length, 0.0)
        made.append(proxy)
    return made


def main():
    out, clip, with_bones = args()
    rig = bpy.data.objects.get("CharacterRig")
    mesh = bpy.data.objects.get("Character")
    if rig is None or mesh is None:
        raise SystemExit("expected CharacterRig and Character in the file")

    for obj in bpy.data.objects:
        if obj.type == "MESH" and obj is not mesh:
            obj.hide_render = True

    if with_bones:
        bone_proxies(rig)

    preview = previewkit.Preview(OUT_DIR, samples=32)
    preview.ground(0.0)
    height = 1.7
    preview.lights((0.0, 0.0, height * 0.5), spread=1.6)

    def shoot(name):
        preview.ortho((0.0, -4.0, height * 0.5), (0.0, 0.0, height * 0.5), height * 1.25)
        preview.shot(name + "_front", (420, 640))
        preview.ortho((-4.0, 0.0, height * 0.5), (0.0, 0.0, height * 0.5), height * 1.25)
        preview.shot(name + "_side", (420, 640))

    shoot(out + "_rest")

    track = None
    for candidate in (rig.animation_data.nla_tracks if rig.animation_data else []):
        if candidate.name == clip:
            track = candidate
    if track is None:
        print("no clip named", clip)
        return

    # Push the strip's action onto the rig so the scene frame drives the pose.
    action = track.strips[0].action
    rig.animation_data.action = action
    for slot in action.slots:
        try:
            rig.animation_data.action_slot = slot
        except Exception:
            pass
    start = int(action.frame_range[0])
    end = int(action.frame_range[1])
    for index, frame in enumerate([start, start + (end - start) // 4,
                                   start + (end - start) // 2,
                                   start + 3 * (end - start) // 4]):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        preview.ortho((-4.0, 0.0, height * 0.5), (0.0, 0.0, height * 0.5), height * 1.25)
        preview.shot("{0}_{1}_f{2}".format(out, clip.lower(), index), (420, 640))
    print("wrote renders to", OUT_DIR)


main()
