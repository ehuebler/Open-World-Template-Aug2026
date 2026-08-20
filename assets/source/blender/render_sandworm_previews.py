"""Render close and gameplay-distance checks for the generated Sandworm.

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background assets/work/sandworm_rigged.blend `
        --python assets/source/blender/render_sandworm_previews.py
"""

import os

import bpy
from mathutils import Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT = os.path.join(ROOT, "assets", "previews", "authoring")


def point_camera(camera, at):
    camera.rotation_euler = (
        Vector(at) - camera.location
    ).to_track_quat("-Z", "Y").to_euler()


def pose(rig, action_name, frame):
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    rig.animation_data.action = bpy.data.actions[action_name]
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()


def shot(scene, camera, name, size):
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.filepath = os.path.join(OUTPUT, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("wrote " + scene.render.filepath)


def main():
    os.makedirs(OUTPUT, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.studio_light = "paint.sl"
    scene.display.shading.color_type = "VERTEX"
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False

    camera_data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    rig = bpy.data.objects["CharacterRig"]

    pose(rig, "Bite", 12)
    camera.location = Vector((165.0, -8.0, 96.0))
    point_camera(camera, (0.0, -8.0, 67.0))
    camera_data.lens = 63.0
    shot(scene, camera, "sandworm_close", (960, 720))

    pose(rig, "Idle", 45)
    camera.location = Vector((700.0, -176.0, 70.0))
    point_camera(camera, (0.0, -176.0, 12.0))
    camera_data.lens = 54.0
    shot(scene, camera, "sandworm_rest", (1120, 700))

    pose(rig, "Leap", 18)
    shot(scene, camera, "sandworm_gameplay", (1120, 700))


if __name__ == "__main__":
    main()
