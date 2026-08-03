"""Render a body wearing every garment built into the .blend it is given.

    blender --background generated/character_3_rigged.blend --python dev/_render_dressed.py -- --out=NAME

Works on either body: it renders whatever meshes the file holds. `--head`
frames the skull instead of the figure, which is the only way to judge anything
worn on the face at 440 px, and `--clip=Run@8` poses the rig at one frame of one
baked clip instead of standing it in its rest pose. Garments are cut from the
body and offset along its normals, so at rest they cannot clip by construction
and a rest shot proves nothing about fit — every fault is at a joint under a
pose.
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


def pose_clip(rig, spec):
    """Put the rig on one frame of one baked action. `spec` is `Name` or `Name@8`."""
    name, _, frame = spec.partition("@")
    action = bpy.data.actions.get(name)
    if action is None:
        raise SystemExit("no action named {0}; have {1}".format(
            name, sorted(a.name for a in bpy.data.actions)))
    rig.animation_data.action = action
    # Blender 4.4+ puts an action's channels in slots, and an action assigned
    # without one plays nothing at all — silently, and the render comes out in
    # the rest pose looking exactly like a garment that fits.
    if hasattr(rig.animation_data, "action_slot") and action.slots:
        rig.animation_data.action_slot = action.slots[0]
    start, end = action.frame_range
    bpy.context.scene.frame_set(int(frame) if frame else int((start + end) * 0.5))
    print("posed {0} at frame {1} of [{2:.0f},{3:.0f}]".format(
        name, bpy.context.scene.frame_current, start, end))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = "dressed"
    head = "--head" in argv
    hidden = []
    clip = ""
    at = 0.0
    for entry in argv:
        if entry.startswith("--out="):
            out = entry.split("=", 1)[1]
        if entry.startswith("--hide="):
            hidden = [part.lower() for part in entry.split("=", 1)[1].split(",") if part]
        if entry.startswith("--clip="):
            clip = entry.split("=", 1)[1]
        if entry.startswith("--at="):
            head, at = True, float(entry.split("=", 1)[1])

    rig = bpy.data.objects.get("CharacterRig")
    if rig is not None:
        if rig.animation_data is not None:
            for track in rig.animation_data.nla_tracks:
                track.mute = True
            rig.animation_data.action = None
        # Muting the stack is not enough: the pose bones keep whatever the last
        # evaluated clip left in them, which renders as a T-pose with one arm up.
        for bone in rig.pose.bones:
            bone.location = (0.0, 0.0, 0.0)
            bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
            bone.rotation_euler = (0.0, 0.0, 0.0)
            bone.scale = (1.0, 1.0, 1.0)
        if clip:
            pose_clip(rig, clip)

    scene = bpy.context.scene.collection
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        obj.hide_render = any(part in obj.name.lower() for part in hidden)
        if obj.name not in scene.objects:
            scene.objects.link(obj)
    bpy.context.view_layer.update()

    top = max((obj.matrix_world @ v.co).z
              for obj in bpy.data.objects if obj.type == "MESH" and obj.name != "PreviewGround"
              for v in obj.data.vertices)
    # Both heads are a fifth of the figure, so a head shot is the top fifth of
    # it framed at a fifth of the width.
    mid = at if at else (top * 0.86 if head else top * 0.55)
    frame = top * 0.42 if head else top * 1.35
    size = (520, 520) if head else (440, 660)
    preview = previewkit.Preview(OUT_DIR, samples=32)
    preview.ground(0.0)
    preview.lights((0.0, 0.0, mid), spread=1.7)
    # Characters face +Y, so the front shot is taken from +Y. Naming the -Y shot
    # "front" is how a body that arrived facing backwards went unnoticed.
    preview.ortho((0.0, 4.0, mid), (0.0, 0.0, mid), frame)
    preview.shot(out + "_front", size)
    preview.ortho((0.0, -4.0, mid), (0.0, 0.0, mid), frame)
    preview.shot(out + "_back", size)
    preview.ortho((-4.0, 0.0, mid), (0.0, 0.0, mid), frame)
    preview.shot(out + "_side", size)
    preview.hero((-1.9, 2.6, top * 1.05), (0.0, 0.0, mid), lens=72.0)
    preview.shot(out + "_hero", size)
    print("rendered:", [o.name for o in bpy.data.objects if o.type == "MESH"])


main()
