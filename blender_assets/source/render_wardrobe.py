"""Renders previews of the wardrobe prop.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background blender_assets/source/wardrobe.blend --python blender_assets/source/render_wardrobe.py

Images land in blender_assets/source/previews/. `wardrobe_open` swings the doors
to check that their origins really sit on the hinge lines, and `wardrobe_scale`
imports the player character alongside, which is the only reliable way to judge
the size of a prop for a 1.446 m character.
"""

import math
import os

import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
OUTPUT_DIR = os.path.join(SOURCE_DIR, "previews")
CHARACTER_GLB = os.path.join(ASSET_DIR, "player_character.glb")

RESOLUTION = (760, 860)
SAMPLES = 96
DOOR_SWING = 100.0


def ensure_engine():
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if hasattr(scene, "eevee"):
        scene.eevee.taa_render_samples = SAMPLES
    scene.render.resolution_x = RESOLUTION[0]
    scene.render.resolution_y = RESOLUTION[1]
    for transform in ("Khronos PBR Neutral", "AgX", "Filmic", "Standard"):
        try:
            scene.view_settings.view_transform = transform
            break
        except TypeError:
            continue


def set_world():
    world = bpy.data.worlds.get("PreviewWorld") or bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.055, 0.058, 0.066, 1.0)
    bpy.context.scene.world = world


def add_area_light(name, location, target, energy, size):
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.size = size
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    light.location = location
    light.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()


def add_ground():
    mesh = bpy.data.meshes.new("PreviewGroundMesh")
    ground = bpy.data.objects.new("PreviewGround", mesh)
    bpy.context.scene.collection.objects.link(ground)
    size = 14.0
    mesh.from_pydata([(-size, -size, 0.0), (size, -size, 0.0), (size, size, 0.0), (-size, size, 0.0)],
                     [], [(0, 1, 2, 3)])
    mesh.update()
    material = bpy.data.materials.new("PreviewGroundMaterial")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.105, 0.110, 0.120, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    mesh.materials.append(material)


def add_camera():
    data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", data)
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def aim(camera, location, target):
    camera.location = location
    camera.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()


def render(name):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    bpy.context.scene.render.filepath = os.path.join(OUTPUT_DIR, name + ".png")
    bpy.ops.render.render(write_still=True)


def swing(open_doors):
    for name, sign in (("WardrobeDoorL", 1.0), ("WardrobeDoorR", -1.0)):
        door = bpy.data.objects.get(name)
        if door is not None:
            door.rotation_euler = (0.0, 0.0, math.radians(DOOR_SWING) * sign if open_doors else 0.0)


def import_character(location):
    if not os.path.exists(CHARACTER_GLB):
        print("character glb missing; skipping the scale preview")
        return []
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=CHARACTER_GLB)
    added = [obj for obj in bpy.data.objects if obj not in before]
    for obj in added:
        if obj.parent is None:
            obj.location = location
    return added


def main():
    ensure_engine()
    set_world()
    focus = (0.0, 0.0, 0.94)
    # Kept dim on purpose: brighter than this and the view transform clips the
    # wood tones to the same pale tan, which makes the previews useless for
    # judging the palette.
    add_area_light("PreviewKey", (2.8, 3.6, 3.2), focus, 170.0, 3.2)
    add_area_light("PreviewFill", (-3.6, 2.6, 1.5), focus, 48.0, 4.0)
    add_area_light("PreviewRim", (-0.9, -3.8, 2.8), focus, 95.0, 2.5)
    add_ground()
    camera = add_camera()

    def ortho(location, scale, target=focus):
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = scale
        aim(camera, location, target)

    def hero(location):
        camera.data.type = "PERSP"
        camera.data.lens = 58.0
        aim(camera, location, focus)

    swing(False)
    ortho((0.0, 7.0, focus[2]), 2.20)
    render("wardrobe_front")
    hero((2.15, 2.75, 1.60))
    render("wardrobe_threequarter")

    swing(True)
    hero((2.15, 2.75, 1.60))
    render("wardrobe_open")

    swing(False)
    import_character((1.02, 0.60, 0.0))
    scale_target = (0.45, 0.0, 0.94)
    ortho((0.45, 7.0, scale_target[2]), 2.60, scale_target)
    render("wardrobe_scale")


if __name__ == "__main__":
    main()
