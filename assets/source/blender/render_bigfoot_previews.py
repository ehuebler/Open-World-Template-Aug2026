"""Render deformation and topology previews from the generated Bigfoot blend.

Run after build_bigfoot.py, from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background assets/work/bigfoot_rigged.blend `
        --python assets/source/blender/render_bigfoot_previews.py

Images are regenerable and land under assets/previews/authoring/.
"""

import os
import sys

import bpy
from mathutils import Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT_DIR = os.path.join(
    ROOT, "assets", "previews", "authoring")
RESOLUTION = (620, 780)

sys.path.insert(0, SOURCE_DIR)
from previewkit import Preview  # noqa: E402


def bounds(mesh_obj):
    points = [mesh_obj.matrix_world @ vertex.co
              for vertex in mesh_obj.data.vertices]
    low = Vector(tuple(min(point[axis] for point in points)
                       for axis in range(3)))
    high = Vector(tuple(max(point[axis] for point in points)
                        for axis in range(3)))
    return low, high


def clear_pose(rig):
    if rig.animation_data is not None:
        rig.animation_data.action = None
        for track in rig.animation_data.nla_tracks:
            track.mute = True
    for bone in rig.pose.bones:
        bone.rotation_mode = "QUATERNION"
        bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        bone.location = Vector()
        bone.scale = Vector((1.0, 1.0, 1.0))
    bpy.context.view_layer.update()


def pose(rig, name, frame):
    action = bpy.data.actions.get(name)
    if action is None:
        raise SystemExit("missing preview action " + name)
    rig.data.pose_position = "POSE"
    if rig.animation_data is None:
        rig.animation_data_create()
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    rig.animation_data.action = action
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()


def topology_copy(mesh_obj):
    copy = mesh_obj.copy()
    copy.data = mesh_obj.data.copy()
    copy.name = "BigfootTopologyPreview"
    copy.parent = None
    copy.matrix_world = mesh_obj.matrix_world.copy()
    copy.modifiers.clear()
    bpy.context.scene.collection.objects.link(copy)

    material = bpy.data.materials.new("BigfootTopologyMaterial")
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (0.12, 0.58, 0.78, 1.0)
    shader.inputs["Emission Color"].default_value = (0.03, 0.22, 0.35, 1.0)
    shader.inputs["Emission Strength"].default_value = 0.7
    shader.inputs["Roughness"].default_value = 0.7
    copy.data.materials.clear()
    copy.data.materials.append(material)

    wire = copy.modifiers.new("Topology", "WIREFRAME")
    wire.thickness = 0.003
    wire.use_replace = True
    return copy


def main():
    mesh_obj = bpy.data.objects.get("Character")
    rig = bpy.data.objects.get("CharacterRig")
    if mesh_obj is None or rig is None:
        raise SystemExit(
            "open assets/work/bigfoot_rigged.blend before rendering")

    for obj in list(bpy.data.objects):
        if obj.type in {"CAMERA", "LIGHT"} or obj.name.startswith("Preview"):
            bpy.data.objects.remove(obj, do_unlink=True)

    low, high = bounds(mesh_obj)
    height = high.z - low.z
    focus = Vector((0.0, 0.18, low.z + height * 0.50))
    preview = Preview(
        OUTPUT_DIR, samples=72,
        background=(0.045, 0.052, 0.064, 1.0))
    preview.lights(focus, spread=height * 0.90, gain=1.35)
    preview.ground(
        level=0.0, size=height * 3.5,
        colour=(0.085, 0.095, 0.110, 1.0))

    front = Vector((0.0, height * 4.0, focus.z))
    three_quarter = Vector((
        height * 1.55, height * 2.15, height * 1.08))
    side = Vector((height * 4.0, 0.0, focus.z))

    clear_pose(rig)
    preview.ortho(front, focus, height * 1.20)
    preview.shot("bigfoot_front", RESOLUTION)
    preview.hero(three_quarter, focus, lens=64.0)
    preview.shot("bigfoot_threequarter", RESOLUTION)

    topology = topology_copy(mesh_obj)
    mesh_obj.hide_render = True
    preview.ortho(front, focus, height * 1.20)
    preview.shot("bigfoot_topology", RESOLUTION)
    mesh_obj.hide_render = False
    bpy.data.objects.remove(topology, do_unlink=True)

    shots = (
        ("Walk", 10, "bigfoot_walk", three_quarter),
        ("Roar", 34, "bigfoot_roar", front),
        ("MeteorWindup", 47, "bigfoot_meteor_windup", three_quarter),
        ("MeteorFly", 8, "bigfoot_meteor_fly", side),
        ("Punch", 14, "bigfoot_punch", three_quarter),
        ("Defeat", 56, "bigfoot_defeat", three_quarter),
    )
    for action, frame, filename, camera in shots:
        pose(rig, action, frame)
        preview.hero(camera, focus, lens=64.0)
        preview.shot(filename, RESOLUTION)
        print("preview {0}: {1} frame {2}".format(
            filename, action, frame))


if __name__ == "__main__":
    main()
