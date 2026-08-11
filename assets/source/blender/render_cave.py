"""Renders previews of the cave entry room from inside it.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/cave_room.blend --python assets/source/blender/render_cave.py

Images land in assets/previews/authoring/. Unlike the prop previews this
deliberately does **not** set up a light rig: the room's own purple and green
crystal lights are the subject, and a three-point rig would flood out the only
thing worth looking at. The world is left nearly black for the same reason.
"""

import math
import os
import sys

import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref
from previewkit import Preview

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "authoring")
# Not quite black. At zero, every surface the crystals do not reach renders as a
# flat silhouette, and the dripstone in front of a glow turns into a paper cut-out.
CAVE_DARK = (0.010, 0.011, 0.016, 1.0)


def floor_under(cave, x, y, from_z=7.0):
    """Height of the rock below a point, for standing things on an uneven floor."""
    inverse = cave.matrix_world.inverted()
    found, location, _, _ = cave.ray_cast(
        inverse @ Vector((x, y, from_z)),
        (inverse.to_3x3() @ Vector((0.0, 0.0, -1.0))).normalized())
    return None if not found else (cave.matrix_world @ location).z


def main():
    preview = Preview(OUTPUT_DIR, samples=192, background=CAVE_DARK)
    scene = bpy.context.scene
    # Without ray tracing nothing bounces, and every surface the crystals do not
    # face directly renders pure black instead of dim rock.
    if hasattr(scene, "eevee") and hasattr(scene.eevee, "use_raytracing"):
        scene.eevee.use_raytracing = True

    cave = bpy.data.objects["CaveRoom"]

    # Looking at the tunnel mouth from across the chamber. Far enough back to keep
    # lit wall on all sides of it: a black shape filling the frame is not a hole,
    # it is just a black frame.
    preview.hero((-2.50, -2.20, 2.70), (10.2, 0.5, 2.95), lens=30.0)
    preview.shot("cave_tunnel", (1150, 740))

    # Wide sweep of the chamber. Shot from the tunnel side, which is the one
    # direction that has both crystal clusters in front of it.
    preview.hero((8.2, 1.0, 2.60), (-7.0, -0.8, 3.40), lens=20.0)
    preview.shot("cave_room", (1280, 780))

    # Standing in the middle looking up, for the ceiling and the sense of volume.
    preview.hero((1.0, 1.2, 1.60), (-2.0, 3.0, 8.00), lens=24.0)
    preview.shot("cave_ceiling", (900, 900))

    # From inside the tunnel looking back in, which is the way a player arrives. Far
    # enough down the passage that its walls frame the shot - closer than about 4 m
    # and the mouth is wider than the frame, so there is nothing to frame with.
    preview.hero((14.9, 1.30, 2.95), (2.0, -1.20, 2.70), lens=24.0)
    preview.shot("cave_entry", (1280, 780))

    # Close on the big purple cluster.
    preview.hero((-3.30, 5.10, 2.40), (-6.10, 7.80, 1.40), lens=55.0)
    preview.shot("cave_crystals", (900, 740))

    # --- the character in the room, for scale ---------------------------
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; skipping the scale preview")
        return

    stand = Vector((3.60, -2.20, 0.0))
    stand.z = floor_under(cave, stand.x, stand.y) or 0.0
    print("standing the character at ({0:.2f}, {1:.2f}, {2:.2f})".format(*stand))

    _, _, snapshot = character_ref.import_character()
    for obj in bpy.data.objects:
        if obj not in snapshot["objects"] and obj.parent is None:
            obj.location = obj.location + stand

    # Well back on a wide lens, aimed at the character's chest: the room's size has
    # to read off a figure whose height you already know, so both have to be in shot.
    preview.hero((9.20, 2.60, 1.60), stand + Vector((0.0, 0.0, 0.90)), lens=20.0)
    preview.shot("cave_scale", (1280, 780))

    print("character height {0:.3f} m against a {1:.1f} m ceiling".format(
        1.447, max((cave.matrix_world @ v.co).z for v in cave.data.vertices)))


if __name__ == "__main__":
    main()
