"""Builds the wardrobe prop and exports it to blender_assets/wardrobe.glb.

Run headless from the project root; it does not need an input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python blender_assets/source/build_wardrobe.py

The prop exports as three objects: the carcass, and one object per door. Each
door's origin sits on its hinge line at floor level, so Godot opens it by setting
rotation.y with no offset node in between - Blender's +Z becomes Godot's +Y.

Proportions are keyed off the player character rather than real furniture, since
the character is 1.446 m rather than adult height. WIDTH/DEPTH/HEIGHT below are
the outside of the carcass; the plinth and cornice overhang it.

Orientation matches the character rig: Z up, front facing +Y, so after the
Y-up export the doors face -Z, which is Godot's forward.
"""

import math
import os
import sys

import bpy
import bmesh
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

from propkit import (add_box, add_cylinder, ensure_materials, evaluated_polys,
                     export_selected, new_object, reset_scene)


ASSET_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
BLEND_PATH = os.path.join(SOURCE_DIR, "wardrobe.blend")
GLB_PATH = os.path.join(ASSET_DIR, "wardrobe.glb")
CHARACTER_GLB = os.path.join(ASSET_DIR, "player_character.glb")
PREVIEW_DIR = os.path.join(SOURCE_DIR, "previews")

CHARACTER_HEIGHT = 1.446

WIDTH = 1.00
DEPTH = 0.54
HEIGHT = 1.88

PANEL = 0.05          # side, top and bottom panel thickness
BACK = 0.03
PLINTH_HEIGHT = 0.09
CORNICE_HEIGHT = 0.13
DOOR_THICKNESS = 0.04
DOOR_GAP = 0.005      # half-gap where the two doors meet
DOOR_INSET = 0.01     # how far the doors sit in from the carcass sides

BEVEL_WIDTH = 0.006
BEVEL_SEGMENTS = 2
SMOOTH_ANGLE = 32.0

HALF_W = WIDTH * 0.5
HALF_D = DEPTH * 0.5
CARCASS_BOTTOM = PLINTH_HEIGHT
CARCASS_TOP = HEIGHT - CORNICE_HEIGHT
CAVITY_BOTTOM = CARCASS_BOTTOM + PANEL
CAVITY_TOP = CARCASS_TOP - PANEL
SHELF_Z = CAVITY_TOP - 0.26
RAIL_Z = SHELF_Z - 0.10

MATERIALS = {
    "WardrobeWood": {"colour": (0.420, 0.268, 0.168, 1.0), "roughness": 0.62},
    "WardrobeTrim": {"colour": (0.235, 0.145, 0.088, 1.0), "roughness": 0.58},
    "WardrobeInterior": {"colour": (0.624, 0.502, 0.376, 1.0), "roughness": 0.74},
    "WardrobeMetal": {"colour": (0.678, 0.549, 0.278, 1.0), "roughness": 0.34,
                      "metallic": 0.85},
}
SLOTS = list(MATERIALS)
WOOD, TRIM, INTERIOR, METAL = range(4)


# --------------------------------------------------------------------------
# Geometry helpers
# --------------------------------------------------------------------------

def recess_panel(bm, faces, steps):
    """Sink a framed panel into the +Y face of a door.

    `steps` is a list of (margin, depth) worked from the outside in. Two shallow
    steps read as a moulded frame, where one deep step just looks like a hole.
    """
    front = max(faces, key=lambda face: face.calc_center_median().y)
    for margin, depth in steps:
        bmesh.ops.inset_region(bm, faces=[front], thickness=margin, depth=0.0,
                               use_even_offset=True, use_boundary=True)
        for vert in front.verts:
            vert.co.y -= depth


def finish(name, bm, origin=None):
    return new_object(name, bm, SLOTS, bevel_width=BEVEL_WIDTH,
                      bevel_segments=BEVEL_SEGMENTS, smooth_angle=SMOOTH_ANGLE,
                      origin=origin)


# --------------------------------------------------------------------------
# Parts
# --------------------------------------------------------------------------

def build_carcass():
    bm = bmesh.new()

    # Plinth and cornice both overhang and are stepped rather than single slabs,
    # which is what stops the box reading as a plain crate.
    front = HALF_D + DOOR_THICKNESS
    add_box(bm, (-HALF_W - 0.030, -HALF_D - 0.020, 0.0),
            (HALF_W + 0.030, front + 0.020, PLINTH_HEIGHT - 0.030), TRIM)
    add_box(bm, (-HALF_W - 0.014, -HALF_D - 0.008, PLINTH_HEIGHT - 0.030),
            (HALF_W + 0.014, front + 0.008, PLINTH_HEIGHT), TRIM)
    add_box(bm, (-HALF_W - 0.018, -HALF_D - 0.010, CARCASS_TOP),
            (HALF_W + 0.018, front + 0.010, CARCASS_TOP + 0.038), TRIM)
    add_box(bm, (-HALF_W - 0.042, -HALF_D - 0.024, CARCASS_TOP + 0.038),
            (HALF_W + 0.042, front + 0.024, HEIGHT), TRIM)

    # Sides, top and bottom.
    add_box(bm, (-HALF_W, -HALF_D, CARCASS_BOTTOM),
            (-HALF_W + PANEL, HALF_D, CARCASS_TOP), WOOD)
    add_box(bm, (HALF_W - PANEL, -HALF_D, CARCASS_BOTTOM),
            (HALF_W, HALF_D, CARCASS_TOP), WOOD)
    add_box(bm, (-HALF_W + PANEL, -HALF_D, CARCASS_BOTTOM),
            (HALF_W - PANEL, HALF_D, CAVITY_BOTTOM), WOOD)
    add_box(bm, (-HALF_W + PANEL, -HALF_D, CAVITY_TOP),
            (HALF_W - PANEL, HALF_D, CARCASS_TOP), WOOD)

    # Interior: back board, one shelf and a hanging rail on brackets.
    add_box(bm, (-HALF_W + PANEL, -HALF_D, CAVITY_BOTTOM),
            (HALF_W - PANEL, -HALF_D + BACK, CAVITY_TOP), INTERIOR)
    add_box(bm, (-HALF_W + PANEL, -HALF_D + BACK, SHELF_Z),
            (HALF_W - PANEL, HALF_D - 0.02, SHELF_Z + 0.03), INTERIOR)
    rail_x = HALF_W - PANEL - 0.015
    add_cylinder(bm, (-rail_x, 0.0, RAIL_Z), (rail_x, 0.0, RAIL_Z), 0.016, METAL)

    return finish("Wardrobe", bm)


def build_door(side):
    """side is -1 for the left leaf, +1 for the right; hinge on the outer edge."""
    bm = bmesh.new()
    outer = side * (HALF_W - DOOR_INSET)
    inner = side * DOOR_GAP
    lo_x, hi_x = min(outer, inner), max(outer, inner)

    faces = add_box(bm, (lo_x, HALF_D, CAVITY_BOTTOM),
                    (hi_x, HALF_D + DOOR_THICKNESS, CAVITY_TOP), WOOD)
    recess_panel(bm, faces, [(0.058, 0.007), (0.026, 0.013)])

    # Vertical bar handle, set in from the leading edge the door opens on.
    handle_x = inner + side * 0.070
    handle_y = HALF_D + DOOR_THICKNESS
    grip_z = (CAVITY_BOTTOM + CAVITY_TOP) * 0.5
    grip_half = 0.105
    for offset in (-grip_half, grip_half):
        add_cylinder(bm, (handle_x, handle_y, grip_z + offset),
                     (handle_x, handle_y + 0.035, grip_z + offset), 0.010, METAL)
    add_cylinder(bm, (handle_x, handle_y + 0.035, grip_z - grip_half),
                 (handle_x, handle_y + 0.035, grip_z + grip_half), 0.012, METAL)

    name = "WardrobeDoorL" if side < 0 else "WardrobeDoorR"
    return finish(name, bm, origin=(outer, HALF_D, 0.0))


# --------------------------------------------------------------------------
# Scene setup
# --------------------------------------------------------------------------

def main():
    reset_scene()
    ensure_materials(MATERIALS)

    carcass = build_carcass()
    left = build_door(-1)
    right = build_door(1)
    parts = [carcass, left, right]

    print("wardrobe {0:.2f} x {1:.2f} x {2:.2f} m ({3:.2f}x character height)".format(
        WIDTH, DEPTH, HEIGHT, HEIGHT / CHARACTER_HEIGHT))
    for obj in parts:
        print("  {0:16s} polys={1:5d} exported={2:5d} origin=({3:.3f}, {4:.3f}, {5:.3f})".format(
            obj.name, len(obj.data.polygons), evaluated_polys(obj), *obj.location))

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected(parts, GLB_PATH)


if __name__ == "__main__":
    main()
