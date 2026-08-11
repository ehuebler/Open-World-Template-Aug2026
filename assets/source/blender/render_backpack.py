"""Renders previews of the backpack, on its own and worn by the character.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/backpack.blend --python assets/source/blender/render_backpack.py

Images land in assets/previews/authoring/. The pack is authored in the
character's own space with its origin on the UpperChest bone, so importing
player_character.glb into this scene lines the two up with no transform at all -
which makes the worn shots a real check of the fit rather than a posed mock-up.
"""

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


def main():
    preview = Preview(OUTPUT_DIR)
    pack = bpy.data.objects["Backpack"]

    lo = Vector((min((pack.matrix_world @ v.co).x for v in pack.data.vertices),
                 min((pack.matrix_world @ v.co).y for v in pack.data.vertices),
                 min((pack.matrix_world @ v.co).z for v in pack.data.vertices)))
    hi = Vector((max((pack.matrix_world @ v.co).x for v in pack.data.vertices),
                 max((pack.matrix_world @ v.co).y for v in pack.data.vertices),
                 max((pack.matrix_world @ v.co).z for v in pack.data.vertices)))
    print("pack bounds x {0:.3f}..{1:.3f}  y {2:.3f}..{3:.3f}  z {4:.3f}..{5:.3f}".format(
        lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))

    # --- the pack on its own --------------------------------------------
    # Aim at the canvas body: the straps reach out to where the shoulders and chest
    # would be, so the bounding box centre sits in the empty space between them.
    canvas = [pack.matrix_world @ pack.data.vertices[index].co
              for poly in pack.data.polygons if poly.material_index == 0
              for index in poly.vertices]
    focus = sum(canvas, Vector()) / len(canvas)
    # Frame off the whole span, though, or the straps fall outside the shot.
    reach = (hi - lo).length
    preview.lights(focus, spread=0.9, gain=1.9)

    def orbit(name, direction, resolution, lens=58.0):
        offset = Vector(direction).normalized() * reach * 2.2
        preview.hero(focus + offset, focus, lens=lens)
        preview.shot(name, resolution)

    orbit("backpack_hero", (0.62, -0.90, 0.42), (900, 760))     # lid and buckles
    orbit("backpack_front", (-0.45, 0.95, 0.28), (820, 780))    # the harness
    # Straight side, so the strap arc reads as a silhouette.
    preview.ortho(focus + Vector((1.8, 0.0, 0.0)), focus, reach * 0.98)
    preview.shot("backpack_side", (720, 820))

    # --- worn by the character ------------------------------------------
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; skipping the worn previews")
        return

    rig, _, _ = character_ref.import_character()
    forward = character_ref.facing(rig)
    right = forward.cross(Vector((0.0, 0.0, 1.0))).normalized()
    print("rig forward ({0:.3f}, {1:.3f}, {2:.3f})".format(*forward))

    body_focus = Vector((0.0, 0.0, 0.82))
    preview.lights(body_focus, spread=1.9)
    preview.hero(body_focus - forward * 2.1 + right * 1.5 + Vector((0.0, 0.0, 0.7)),
                 body_focus)
    preview.shot("backpack_worn_back", (900, 820))
    preview.ortho(body_focus + right * 5.0, body_focus, 1.75)
    preview.shot("backpack_worn_side", (760, 900))
    preview.hero(body_focus + forward * 2.3 + right * 1.2 + Vector((0.0, 0.0, 0.5)),
                 body_focus)
    preview.shot("backpack_worn_front", (860, 860))

    # Close-up on one shoulder: does the strap sit on the body or through it?
    shoulder = Vector((0.20, 0.0, 1.06))
    preview.lights(shoulder, spread=0.8, gain=1.5)
    preview.hero(shoulder + Vector((0.42, 0.34, 0.34)), shoulder, lens=80.0)
    preview.shot("backpack_strap", (860, 720))


if __name__ == "__main__":
    main()
