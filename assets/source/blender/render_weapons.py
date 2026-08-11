"""Renders previews of the sword and laser rifle, on their own and dual wielded.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/weapons.blend --python assets/source/blender/render_weapons.py

Images land in assets/previews/authoring/. The in-hand shots import
player_character.glb and place each weapon by measuring that rig, so they check
the fit against the shipped character rather than against any written-down
proportions. Nothing is hard-coded to the A-pose: the grip point comes from the
hand's skin weights and the aim direction from the foot-to-toe vector, so a
change to the character shows up as a bad preview rather than drifting silently.
"""

import os
import sys

import bpy
from mathutils import Matrix, Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "authoring")

SAMPLES = 96


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
    for transform in ("Khronos PBR Neutral", "AgX", "Filmic", "Standard"):
        try:
            scene.view_settings.view_transform = transform
            break
        except TypeError:
            continue


def set_world():
    world = bpy.data.worlds.get("PreviewWorld") or bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (
        0.055, 0.058, 0.066, 1.0)
    bpy.context.scene.world = world


def add_area_light(name, location, target, energy, size):
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.size = size
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    light.location = location
    light.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()


def add_camera():
    data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", data)
    bpy.context.scene.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def aim(camera, location, target):
    camera.location = location
    camera.rotation_euler = (Vector(target) - Vector(location)).to_track_quat("-Z", "Y").to_euler()


def render(name, resolution):
    scene = bpy.context.scene
    scene.render.resolution_x, scene.render.resolution_y = resolution
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    scene.render.filepath = os.path.join(OUTPUT_DIR, name + ".png")
    bpy.ops.render.render(write_still=True)


# --------------------------------------------------------------------------
# Mounting weapons on the imported character
# --------------------------------------------------------------------------

def hold(obj, grip, forward, up=Vector((0.0, 0.0, 1.0))):
    """Place a weapon so its grip centre lands at `grip` and its +Y aim axis runs
    along `forward`. Columns are (right, forward, up) because the weapons are
    authored +Y forward, +Z up."""
    forward = Vector(forward).normalized()
    up = Vector(up).normalized()
    right = forward.cross(up).normalized()
    basis = Matrix(((right.x, forward.x, up.x),
                    (right.y, forward.y, up.y),
                    (right.z, forward.z, up.z)))
    obj.matrix_world = Matrix.Translation(grip) @ basis.to_4x4()


def main():
    ensure_engine()
    set_world()
    camera = add_camera()

    sword = bpy.data.objects["Sword"]
    rifle = bpy.data.objects["LaserRifle"]

    def lights(focus, spread=1.0):
        """Three-point rig scaled around `focus`.

        Energy goes with spread squared. Without that, pulling the rig in for a
        prop-sized subject raises the irradiance by the inverse square and the
        view transform clips every albedo to white - which is exactly what made
        dark leather render as pale pink.
        """
        for light in [obj for obj in bpy.data.objects if obj.type == "LIGHT"]:
            bpy.data.objects.remove(light, do_unlink=True)
        focus = Vector(focus)
        falloff = spread ** 2
        add_area_light("Key", focus + Vector((1.6, -1.2, 1.9)) * spread, focus,
                       50.0 * falloff, 2.4 * spread)
        add_area_light("Fill", focus + Vector((-2.0, -1.0, 0.5)) * spread, focus,
                       14.0 * falloff, 3.0 * spread)
        add_area_light("Rim", focus + Vector((-0.4, 2.2, 1.4)) * spread, focus,
                       28.0 * falloff, 1.8 * spread)

    def ortho(location, target, scale):
        camera.data.type = "ORTHO"
        camera.data.ortho_scale = scale
        aim(camera, location, target)

    def hero(location, target, lens=62.0):
        camera.data.type = "PERSP"
        camera.data.lens = lens
        aim(camera, location, target)

    # --- weapons on their own -------------------------------------------
    rifle.hide_render = True
    lights((0.0, 0.30, 0.0), spread=0.55)
    ortho((0.0, 0.30, 2.0), (0.0, 0.30, 0.0), 0.95)   # looking down on the flat
    render("sword_flat", (620, 900))
    hero((0.62, -0.30, 0.46), (0.0, 0.26, 0.0))
    render("sword_hero", (960, 620))
    rifle.hide_render = False

    sword.hide_render = True
    lights((0.0, 0.13, 0.07), spread=0.5)
    ortho((2.0, 0.13, 0.07), (0.0, 0.13, 0.07), 0.72)  # classic gun profile
    render("rifle_profile", (960, 560))
    hero((0.60, -0.34, 0.34), (0.0, 0.12, 0.06))
    render("rifle_hero", (960, 620))
    sword.hide_render = False

    # --- dual wielded on the character ----------------------------------
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; skipping the in-hand previews")
        return

    rig, body, _ = character_ref.import_character()
    forward = character_ref.facing(rig)
    right_grip = character_ref.grip_point(character_ref.hand_fit(rig, body, "RightHand"))
    left_grip = character_ref.grip_point(character_ref.hand_fit(rig, body, "LeftHand"))
    print("rig forward ({0:.3f}, {1:.3f}, {2:.3f})".format(*forward))
    print("right grip  ({0:.3f}, {1:.3f}, {2:.3f})".format(*right_grip))
    print("left grip   ({0:.3f}, {1:.3f}, {2:.3f})".format(*left_grip))

    hold(sword, right_grip, forward)
    hold(rifle, left_grip, forward)

    focus = Vector((0.0, 0.0, 0.78))
    lights(focus, spread=1.9)

    # Both weapons aim along the character's forward, so a head-on view
    # foreshortens them to nothing. Shoot from the side and the front quarter.
    right = forward.cross(Vector((0.0, 0.0, 1.0))).normalized()
    ortho(focus + right * 5.0, focus, 2.05)
    render("weapons_dual_side", (960, 760))
    hero(focus + forward * 1.5 + right * 2.4 + Vector((0.0, 0.0, 0.85)), focus)
    render("weapons_dual_hero", (900, 800))

    # Close-up: does the grip actually sit inside the mitten?
    lights(right_grip, spread=0.7)
    hero(right_grip + Vector((0.30, -0.30, 0.20)), right_grip, lens=78.0)
    render("weapons_grip", (860, 700))


if __name__ == "__main__":
    main()
