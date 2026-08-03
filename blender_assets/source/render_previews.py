"""Renders turntable, apparel and rig-check previews of player_character.blend.

Run headless from the project root, using the Blender version that saved the
.blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background blender_assets/source/player_character.blend --python blender_assets/source/render_previews.py

Images land in blender_assets/source/previews/. `body_*` shows the bare body,
`item_*` shows one garment at a time, `dressed_*` shows everything worn, and
`dressed_walk`/`dressed_crouch` drive the rig from the baked locomotion clips so
the shared skin weights can be judged under real deformation. `topology` shows
the wireframe of the body surface.
"""

import os

import bpy
from mathutils import Vector

OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "previews")
RESOLUTION = (620, 880)
SAMPLES = 96
APPAREL_COLLECTION = "Apparel"


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
    scene.render.film_transparent = False
    for transform in ("Khronos PBR Neutral", "AgX", "Filmic", "Standard"):
        try:
            scene.view_settings.view_transform = transform
            break
        except TypeError:
            continue


def clear_helpers():
    for obj in list(bpy.data.objects):
        if obj.type in {"LIGHT", "CAMERA"} or obj.name.startswith("Preview"):
            bpy.data.objects.remove(obj, do_unlink=True)


def set_world():
    world = bpy.data.worlds.get("PreviewWorld") or bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.055, 0.058, 0.066, 1.0)
    background.inputs["Strength"].default_value = 1.0
    bpy.context.scene.world = world


def add_area_light(name, location, target, energy, size):
    light_data = bpy.data.lights.new(name, type="AREA")
    light_data.energy = energy
    light_data.size = size
    light = bpy.data.objects.new(name, light_data)
    bpy.context.collection.objects.link(light)
    light.location = location
    direction = Vector(target) - Vector(location)
    light.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    return light


def set_lights(focus):
    add_area_light("PreviewKey", (2.6, 3.4, 3.0), focus, 360.0, 3.0)
    add_area_light("PreviewFill", (-3.4, 2.4, 1.3), focus, 110.0, 4.0)
    add_area_light("PreviewRim", (-0.8, -3.6, 2.6), focus, 220.0, 2.5)


def add_ground():
    mesh = bpy.data.meshes.new("PreviewGroundMesh")
    ground = bpy.data.objects.new("PreviewGround", mesh)
    bpy.context.collection.objects.link(ground)
    size = 12.0
    mesh.from_pydata(
        [(-size, -size, 0.0), (size, -size, 0.0), (size, size, 0.0), (-size, size, 0.0)],
        [],
        [(0, 1, 2, 3)],
    )
    mesh.update()
    material = bpy.data.materials.new("PreviewGroundMaterial")
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.10, 0.105, 0.115, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    mesh.materials.append(material)
    return ground


def add_camera():
    camera_data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def aim(camera, location, target):
    camera.location = location
    direction = Vector(target) - Vector(location)
    camera.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def render(name):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    bpy.context.scene.render.filepath = os.path.join(OUTPUT_DIR, name + ".png")
    bpy.ops.render.render(write_still=True)


def pose_from_clip(rig, name, frame):
    """Drive the rig from one of the baked locomotion clips.

    Posing bones directly does not survive a background render: the pose
    matrices and the evaluated mesh both update, yet the image still comes out
    at the rest pose. Driving real animation data and calling frame_set is what
    the render pipeline actually reads.
    """
    action = bpy.data.actions.get(name)
    if action is None:
        print("clip {0} is missing; rendering the rest pose instead".format(name))
        return False

    # A rig left on Rest Position (common while weight painting) ignores poses.
    rig.data.pose_position = "POSE"
    if rig.animation_data is None:
        rig.animation_data_create()
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    rig.animation_data.action = action
    bpy.context.scene.frame_set(frame)
    return True


def make_topology_copy(mesh_obj):
    copy = mesh_obj.copy()
    copy.data = mesh_obj.data.copy()
    copy.name = "PreviewTopology"
    copy.modifiers.clear()
    bpy.context.collection.objects.link(copy)
    wireframe = copy.modifiers.new("Wire", "WIREFRAME")
    wireframe.thickness = 0.004
    wireframe.use_replace = True
    return copy


def garments():
    collection = bpy.data.collections.get(APPAREL_COLLECTION)
    return sorted(collection.objects, key=lambda obj: obj.name) if collection else []


def set_worn(items, worn):
    for obj in items:
        obj.hide_render = not worn


def body_height(mesh_obj):
    return max((mesh_obj.matrix_world @ vert.co).z for vert in mesh_obj.data.vertices)


def main():
    mesh_obj = bpy.data.objects["Character"]
    rig = bpy.data.objects["CharacterRig"]
    wardrobe = garments()

    clear_helpers()
    ensure_engine()
    set_world()

    # Frame from the actual mesh so re-proportioning the body cannot crop it.
    height = body_height(mesh_obj)
    focus = (0.0, 0.0, height * 0.52)
    ortho = height * 1.18

    set_lights(focus)
    add_ground()
    camera = add_camera()

    def ortho_view(location):
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = ortho
        aim(camera, location, focus)

    def hero_view():
        camera.data.type = "PERSP"
        camera.data.lens = 62.0
        aim(camera, (height * 1.42, height * 1.90, height * 1.06), focus)

    far = height * 4.0

    set_worn(wardrobe, False)
    ortho_view((0.0, far, focus[2]))
    render("body_front")
    ortho_view((far, 0.0, focus[2]))
    render("body_side")
    hero_view()
    render("body_threequarter")

    topology = make_topology_copy(mesh_obj)
    mesh_obj.hide_render = True
    ortho_view((0.0, far, focus[2]))
    render("topology")
    mesh_obj.hide_render = False
    bpy.data.objects.remove(topology, do_unlink=True)

    for garment in wardrobe:
        set_worn(wardrobe, False)
        garment.hide_render = False
        hero_view()
        render("item_" + garment.name.replace("Apparel", "").lower())

    set_worn(wardrobe, True)
    ortho_view((0.0, far, focus[2]))
    render("dressed_front")
    ortho_view((far, 0.0, focus[2]))
    render("dressed_side")
    ortho_view((0.0, -far, focus[2]))
    render("dressed_back")
    hero_view()
    render("dressed_threequarter")

    if pose_from_clip(rig, "Walk", 8):
        hero_view()
        render("dressed_walk")
    if pose_from_clip(rig, "CrouchIdle", 1):
        hero_view()
        render("dressed_crouch")


if __name__ == "__main__":
    main()
