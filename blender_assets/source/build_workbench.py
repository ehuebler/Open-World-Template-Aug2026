"""Builds the workbench prop and exports it to blender_assets/workbench.glb.

Run headless from the project root; it does not need an input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python blender_assets/source/build_workbench.py

The prop exports as two objects: the bench, and the vice's sliding jaw assembly.
The jaw's origin sits on the screw axis at its closed position, so Godot opens the
vice by moving it along `-Z` - Blender's `+Y` front becomes Godot's `-Z`.

Orientation matches the other props: Z up, working side facing `+Y`, so after the
Y-up export you stand at the bench facing Godot's forward.

The one dimension that matters here is the height of the top, and it is **measured
off the character** rather than scaled down from real furniture. See `bench_height()`.
"""

import os
import sys

import bmesh
import bpy

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref
from propkit import (add_box, add_cylinder, add_sphere, ensure_materials,
                     evaluated_polys, export_selected, new_object, reset_scene)

ASSET_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
BLEND_PATH = os.path.join(SOURCE_DIR, "workbench.blend")
GLB_PATH = os.path.join(ASSET_DIR, "workbench.glb")

# Used only when player_character.glb is missing; these are what it measures.
FALLBACK_ELBOW = 0.635
FALLBACK_HEIGHT = 1.446

# A general-purpose bench top sits a hand's width below the elbow: about 0.10 m for
# a 1.75 m adult, which is this fraction of standing height.
ELBOW_DROP = 0.057

LENGTH = 1.28
DEPTH = 0.56
TOP_THICKNESS = 0.058

LEG = 0.072            # square section
LEG_INSET_X = 0.100    # leg centre in from each end of the top
LEG_INSET_Y = 0.075

APRON_THICKNESS = 0.030
APRON_DROP = 0.130     # how far the aprons hang below the top

STRETCHER_BOTTOM = 0.105
STRETCHER_HEIGHT = 0.048
STRETCHER_THICKNESS = 0.026
SHELF_BOARDS = 4
SHELF_THICKNESS = 0.018
SHELF_GAP = 0.009

# Tool well: the trough along the back that stops chisels rolling off the bench. Its
# depth is not free - see add_top().
WELL_FRONT = -0.050
WELL_BACK = -0.235
WELL_FLOOR = 0.020
WELL_WALL = 0.020

BACKBOARD_HEIGHT = 0.220
BACKBOARD_THICKNESS = 0.022
PEG_COUNT = 4
PEG_LENGTH = 0.075
PEG_RADIUS = 0.010

# Face vice at one end of the bench. The jaws are kept wholly below the underside of
# the top: bringing them up level with the front edge puts the jaw plate's faces
# exactly on the top's front face, and two coincident coplanar faces z-fight.
#
# Both jaws get a wooden liner over the iron, as a woodworking vice does. Two iron
# plates nearly shut read as a black box bolted to the bench - it takes the colour
# change and an open gap with the screw crossing it to read as a vice at all.
VICE_X = -0.400
VICE_HALF = 0.115      # half the width of the jaws
VICE_TOP_GAP = 0.006   # jaw tops below the underside of the top
VICE_JAW_HEIGHT = 0.132
VICE_MOUNT = 0.010     # packing block between apron and fixed jaw
VICE_LINER = 0.022     # wooden facing on each jaw
VICE_BODY = 0.018      # iron casting behind the moving liner
VICE_OPEN = 0.030      # gap the jaws are modelled at
VICE_SCREW_RADIUS = 0.011
VICE_ROD_RADIUS = 0.007
VICE_ROD_SPREAD = 0.072
VICE_BAR_HALF = 0.100

BEVEL_WIDTH = 0.004
BEVEL_SEGMENTS = 2
SMOOTH_ANGLE = 32.0

HALF_L = LENGTH * 0.5
HALF_D = DEPTH * 0.5
LEG_X = HALF_L - LEG_INSET_X
LEG_Y = HALF_D - LEG_INSET_Y
FRAME_X = LEG_X + LEG * 0.5     # outer face of the legs
FRAME_Y = LEG_Y + LEG * 0.5

MATERIALS = {
    "BenchTop": {"colour": (0.516, 0.372, 0.216, 1.0), "roughness": 0.54},
    "BenchFrame": {"colour": (0.296, 0.190, 0.116, 1.0), "roughness": 0.66},
    "BenchIron": {"colour": (0.132, 0.136, 0.146, 1.0), "roughness": 0.44,
                  "metallic": 0.80},
    "BenchSteel": {"colour": (0.560, 0.572, 0.596, 1.0), "roughness": 0.28,
                   "metallic": 0.90},
}
SLOTS = list(MATERIALS)
TOP, FRAME, IRON, STEEL = range(4)


def bench_height():
    """Height of the work surface, derived from where the character's elbow lands.

    Bench height is ergonomic, not architectural: it is set by the arms, so scaling
    a real 0.90 m bench by this character's height gets it wrong. The character is
    1.446 m tall but its head is a fifth of that, which puts the shoulders at 0.68 of
    standing height where an adult's are at 0.82. Working from stature would stand
    the top near mid-chest; working from the elbow puts it between wrist and elbow,
    which is where you can actually lean on a piece of work.
    """
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; using fallback arm measurements")
        return FALLBACK_ELBOW - FALLBACK_HEIGHT * ELBOW_DROP, FALLBACK_HEIGHT, None

    rig, body, snapshot = character_ref.import_character()
    arm = character_ref.arm_drop(rig)
    height = max((body.matrix_world @ vert.co).z for vert in body.data.vertices)
    character_ref.discard_since(snapshot)
    return arm["elbow"] - height * ELBOW_DROP, height, arm


TOP_Z, CHARACTER_HEIGHT, ARM = bench_height()
UNDER_TOP = TOP_Z - TOP_THICKNESS
APRON_BOTTOM = UNDER_TOP - APRON_DROP
STRETCHER_TOP = STRETCHER_BOTTOM + STRETCHER_HEIGHT
JAW_TOP = UNDER_TOP - VICE_TOP_GAP
JAW_BOTTOM = JAW_TOP - VICE_JAW_HEIGHT
SCREW_Z = (JAW_TOP + JAW_BOTTOM) * 0.5
# Front faces, working outward from the apron: packing block, fixed liner, the gap,
# moving liner, iron casting.
MOUNT_FACE = FRAME_Y + VICE_MOUNT
FIXED_FACE = MOUNT_FACE + VICE_LINER
MOVING_BACK = FIXED_FACE + VICE_OPEN
MOVING_MID = MOVING_BACK + VICE_LINER
MOVING_FACE = MOVING_MID + VICE_BODY


def finish(name, bm, origin=None):
    return new_object(name, bm, SLOTS, bevel_width=BEVEL_WIDTH,
                      bevel_segments=BEVEL_SEGMENTS, smooth_angle=SMOOTH_ANGLE,
                      origin=origin)


def add_top(bm):
    """Work slab at the front, trough at the back, rear board behind it.

    The trough floor sits flush with the underside of the slabs either side of it,
    which fixes the well's depth at the thickness of the top. Dropping the floor
    lower to deepen the well opens a slot running the length of the bench along both
    sides of the trough, because between the floor and the slabs above it there is
    nothing left to bound the well with.

    The ends need closing too: three slabs and a floor leave the trough open at both
    ends, which reads as a slot sawn through the bench.
    """
    add_box(bm, (-HALF_L, WELL_FRONT, UNDER_TOP), (HALF_L, HALF_D, TOP_Z), TOP)
    add_box(bm, (-HALF_L, -HALF_D, UNDER_TOP), (HALF_L, WELL_BACK, TOP_Z), TOP)
    add_box(bm, (-HALF_L, WELL_BACK, UNDER_TOP - WELL_FLOOR),
            (HALF_L, WELL_FRONT, UNDER_TOP), FRAME)
    for side in (-1, 1):
        outer = side * HALF_L
        inner = side * (HALF_L - WELL_WALL)
        add_box(bm, (min(outer, inner), WELL_BACK, UNDER_TOP),
                (max(outer, inner), WELL_FRONT, TOP_Z), TOP)


def add_frame(bm):
    for x in (-LEG_X, LEG_X):
        for y in (-LEG_Y, LEG_Y):
            add_box(bm, (x - LEG * 0.5, y - LEG * 0.5, 0.0),
                    (x + LEG * 0.5, y + LEG * 0.5, UNDER_TOP), FRAME)

    # Aprons run flush with the outer faces of the legs; the side pair butts into
    # the long pair rather than crossing it.
    for side in (-1, 1):
        add_box(bm, (-FRAME_X, side * (FRAME_Y - APRON_THICKNESS), APRON_BOTTOM),
                (FRAME_X, side * FRAME_Y, UNDER_TOP), FRAME)
        add_box(bm, (side * (FRAME_X - APRON_THICKNESS),
                     -FRAME_Y + APRON_THICKNESS, APRON_BOTTOM),
                (side * FRAME_X, FRAME_Y - APRON_THICKNESS, UNDER_TOP), FRAME)

    for side in (-1, 1):
        add_box(bm, (-FRAME_X, side * (LEG_Y - STRETCHER_THICKNESS * 0.5),
                     STRETCHER_BOTTOM),
                (FRAME_X, side * (LEG_Y + STRETCHER_THICKNESS * 0.5),
                 STRETCHER_TOP), FRAME)
        add_box(bm, (side * (LEG_X - STRETCHER_THICKNESS * 0.5), -LEG_Y,
                     STRETCHER_BOTTOM),
                (side * (LEG_X + STRETCHER_THICKNESS * 0.5), LEG_Y,
                 STRETCHER_TOP), FRAME)


def add_shelf(bm):
    """Slatted boards resting on the lower stretchers."""
    span = (LEG_Y - STRETCHER_THICKNESS * 0.5) * 2.0
    board = (span - SHELF_GAP * (SHELF_BOARDS - 1)) / SHELF_BOARDS
    start = -span * 0.5
    for i in range(SHELF_BOARDS):
        near = start + i * (board + SHELF_GAP)
        add_box(bm, (-LEG_X, near, STRETCHER_TOP),
                (LEG_X, near + board, STRETCHER_TOP + SHELF_THICKNESS), FRAME)


def add_backboard(bm):
    add_box(bm, (-HALF_L, -HALF_D, TOP_Z),
            (HALF_L, -HALF_D + BACKBOARD_THICKNESS, TOP_Z + BACKBOARD_HEIGHT), FRAME)
    face = -HALF_D + BACKBOARD_THICKNESS
    peg_z = TOP_Z + BACKBOARD_HEIGHT * 0.62
    for i in range(PEG_COUNT):
        x = -HALF_L * 0.62 + (HALF_L * 1.24) * i / (PEG_COUNT - 1)
        add_cylinder(bm, (x, face, peg_z), (x, face + PEG_LENGTH, peg_z),
                     PEG_RADIUS, FRAME, segments=12)


def add_vice_mount(bm):
    """The half of the vice that never moves: packing block, iron cheek, fixed liner."""
    add_box(bm, (VICE_X - VICE_HALF - 0.018, FRAME_Y, JAW_BOTTOM - 0.014),
            (VICE_X + VICE_HALF + 0.018, MOUNT_FACE, UNDER_TOP), FRAME)
    add_box(bm, (VICE_X - VICE_HALF - 0.006, MOUNT_FACE, JAW_BOTTOM - 0.014),
            (VICE_X + VICE_HALF + 0.006, MOUNT_FACE + 0.008, UNDER_TOP), IRON)
    add_box(bm, (VICE_X - VICE_HALF, MOUNT_FACE, JAW_BOTTOM),
            (VICE_X + VICE_HALF, FIXED_FACE, JAW_TOP), FRAME)


def add_vice_jaw(bm):
    """The sliding half: liner, iron casting, screw, guide rods and the tommy bar.

    The rods and screw travel with the jaw, as they do on a real face vice, which is
    why they belong to this object and not to the bench.
    """
    add_box(bm, (VICE_X - VICE_HALF, MOVING_BACK, JAW_BOTTOM),
            (VICE_X + VICE_HALF, MOVING_MID, JAW_TOP), FRAME)
    add_box(bm, (VICE_X - VICE_HALF - 0.008, MOVING_MID, JAW_BOTTOM - 0.014),
            (VICE_X + VICE_HALF + 0.008, MOVING_FACE, JAW_TOP + 0.006), IRON)

    # The screw starts back behind the fixed jaw so no gap opens up as it winds out.
    add_cylinder(bm, (VICE_X, FRAME_Y - 0.030, SCREW_Z),
                 (VICE_X, MOVING_FACE + 0.030, SCREW_Z),
                 VICE_SCREW_RADIUS, STEEL, segments=14)
    for side in (-1, 1):
        x = VICE_X + side * VICE_ROD_SPREAD
        add_cylinder(bm, (x, FRAME_Y - 0.010, SCREW_Z),
                     (x, MOVING_FACE + 0.008, SCREW_Z),
                     VICE_ROD_RADIUS, STEEL, segments=12)

    # Tommy bar hung vertically, where it falls when you let go of it. Across the
    # bench it lies over the jaw and the two merge into one dark shape.
    bar_y = MOVING_FACE + 0.034
    add_cylinder(bm, (VICE_X, bar_y, SCREW_Z - VICE_BAR_HALF),
                 (VICE_X, bar_y, SCREW_Z + VICE_BAR_HALF), 0.008, STEEL, segments=12)
    for side in (-1, 1):
        add_sphere(bm, (VICE_X, bar_y, SCREW_Z + side * VICE_BAR_HALF), 0.013,
                   STEEL, segments=12)


def build_bench():
    bm = bmesh.new()
    add_top(bm)
    add_frame(bm)
    add_shelf(bm)
    add_backboard(bm)
    add_vice_mount(bm)
    return finish("Workbench", bm)


def build_vice_jaw():
    bm = bmesh.new()
    add_vice_jaw(bm)
    return finish("WorkbenchViceJaw", bm, origin=(VICE_X, MOVING_BACK, SCREW_Z))


def main():
    reset_scene()
    ensure_materials(MATERIALS)

    bench = build_bench()
    jaw = build_vice_jaw()
    parts = [bench, jaw]

    print("workbench {0:.2f} x {1:.2f} m, top at {2:.3f} m, {3:.3f} m overall".format(
        LENGTH, DEPTH, TOP_Z, TOP_Z + BACKBOARD_HEIGHT))
    if ARM is None:
        print("  top from fallback elbow {0:.3f} m".format(FALLBACK_ELBOW))
    else:
        print("  character {0:.3f} m: shoulder {1:.3f}, elbow {2:.3f}, wrist {3:.3f}, "
              "fingertip {4:.3f}".format(
                  CHARACTER_HEIGHT, ARM["shoulder"], ARM["elbow"], ARM["wrist"],
                  ARM["fingertip"]))
        print("  top is {0:.3f} m below the elbow, {1:.3f} m above the wrist, "
              "{2:.2f}x character height".format(
                  ARM["elbow"] - TOP_Z, TOP_Z - ARM["wrist"],
                  TOP_Z / CHARACTER_HEIGHT))
    print("  tool well {0:.3f} m wide, {1:.3f} m deep; vice jaws {2:.3f} m tall, "
          "modelled {3:.3f} m open".format(
              WELL_FRONT - WELL_BACK, TOP_THICKNESS, VICE_JAW_HEIGHT, VICE_OPEN))
    for obj in parts:
        print("  {0:18s} polys={1:5d} exported={2:5d} origin=({3:.3f}, {4:.3f}, {5:.3f})".format(
            obj.name, len(obj.data.polygons), evaluated_polys(obj), *obj.location))

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected(parts, GLB_PATH)


if __name__ == "__main__":
    main()
