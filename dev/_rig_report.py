"""True rest-pose render and a bone dump for a rigged character .blend.

    blender --background <file.blend> --python dev/_rig_report.py -- --out=NAME

Mutes the NLA stack first: a track left unmuted keeps posing the rig even with no
active action, so "rest" renders come out as a blend of every clip in the file.
"""

import os
import sys

import bpy

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "blender_assets", "source"))
import previewkit  # noqa: E402

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dev", "captures")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = "rig"
    for entry in argv:
        if entry.startswith("--out="):
            out = entry.split("=", 1)[1]

    rig = bpy.data.objects.get("CharacterRig")
    mesh = bpy.data.objects.get("Character")
    if rig is not None:
        if rig.animation_data is not None:
            for track in rig.animation_data.nla_tracks:
                track.mute = True
            rig.animation_data.action = None
        for bone in rig.pose.bones:
            bone.location = (0.0, 0.0, 0.0)
            bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            bone.rotation_euler = (0.0, 0.0, 0.0)
            bone.scale = (1.0, 1.0, 1.0)
        print("--- bones ---")
        for bone in rig.data.bones:
            head = bone.head_local
            tail = bone.tail_local
            print("{0:<18} len={1:.3f} head=({2:+.3f},{3:+.3f},{4:+.3f}) tail=({5:+.3f},{6:+.3f},{7:+.3f})".format(
                bone.name, (tail - head).length, head.x, head.y, head.z, tail.x, tail.y, tail.z))
        print("bone count:", len(rig.data.bones))
    bpy.context.view_layer.update()

    for obj in bpy.data.objects:
        if obj.type == "MESH" and mesh is not None and obj is not mesh:
            obj.hide_render = True

    preview = previewkit.Preview(OUT_DIR, samples=32)
    preview.ground(0.0)
    preview.lights((0.0, 0.0, 0.85), spread=1.6)
    preview.ortho((0.0, -4.0, 0.85), (0.0, 0.0, 0.85), 2.1)
    preview.shot(out + "_true_front", (440, 660))
    preview.ortho((-4.0, 0.0, 0.85), (0.0, 0.0, 0.85), 2.1)
    preview.shot(out + "_true_side", (440, 660))


main()
