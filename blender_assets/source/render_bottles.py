"""Renders previews of the water bottle and the chemical flask, alone and in hand.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background blender_assets/source/bottles.blend --python blender_assets/source/render_bottles.py

Images land in blender_assets/source/previews/. The in-hand shots import
player_character.glb and place each bottle by measuring that rig, so they check the
fit against the shipped character rather than against any written-down proportions.

Both bottles are authored with the cap along +Y, which is the axis that runs through
the fist. Standing one on the ground or putting one upright in a hand therefore
means turning +Y to world up, so `stand` and `hold` both build the basis rather than
setting a Euler by hand.
"""

import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref
from previewkit import Preview

OUTPUT_DIR = os.path.join(SOURCE_DIR, "previews")


def base_offset(obj):
    """How far below the origin the bottle's base sits, in its own +Y."""
    return -min(vert.co.y for vert in obj.data.vertices)


def stand(obj, x=0.0, y=0.0):
    """Stand a bottle on z=0 at (x, y), cap up, label facing -Y."""
    obj.matrix_world = (Matrix.Translation((x, y, base_offset(obj)))
                        @ Matrix.Rotation(math.radians(90.0), 4, "X"))


def hold(obj, grip, point, reference):
    """Place a bottle so its grip centre lands at `grip`, its +Y cap axis runs along
    `point` and its +Z label face along `reference`. Columns are (right, +Y, +Z)."""
    point = Vector(point).normalized()
    reference = Vector(reference).normalized()
    right = point.cross(reference).normalized()
    basis = Matrix(((right.x, point.x, reference.x),
                    (right.y, point.y, reference.y),
                    (right.z, point.z, reference.z)))
    obj.matrix_world = Matrix.Translation(grip) @ basis.to_4x4()


def main():
    preview = Preview(OUTPUT_DIR)
    water = bpy.data.objects["WaterBottle"]
    flask = bpy.data.objects["ChemicalFlask"]

    # --- each bottle on its own ------------------------------------------
    preview.ground()
    for bottle, name, height in ((water, "water_bottle", 0.190),
                                 (flask, "chemical_flask", 0.160)):
        other = flask if bottle is water else water
        other.hide_render = True
        stand(bottle)
        focus = (0.0, 0.0, height * 0.5)
        preview.lights(focus, spread=0.55)
        preview.ortho((0.0, -2.0, height * 0.5), focus, height * 1.35)
        preview.shot(name + "_profile", (560, 880))
        preview.hero((0.32, -0.40, height * 1.05), focus, lens=70.0)
        preview.shot(name + "_hero", (760, 860))
        other.hide_render = False

    # --- the pair, for relative size -------------------------------------
    stand(water, x=-0.062)
    stand(flask, x=0.070)
    focus = (0.006, 0.0, 0.095)
    preview.lights(focus, spread=0.62)
    preview.hero((0.30, -0.52, 0.20), focus, lens=64.0)
    preview.shot("bottles_pair", (940, 760))

    # --- in the character's hands ----------------------------------------
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; skipping the in-hand previews")
        return

    rig, body, _ = character_ref.import_character()
    forward = character_ref.facing(rig)
    right_grip = character_ref.grip_point(
        character_ref.hand_fit(rig, body, "RightHand"))
    left_grip = character_ref.grip_point(
        character_ref.hand_fit(rig, body, "LeftHand"))
    print("rig forward ({0:.3f}, {1:.3f}, {2:.3f})".format(*forward))
    print("right grip  ({0:.3f}, {1:.3f}, {2:.3f})".format(*right_grip))
    print("left grip   ({0:.3f}, {1:.3f}, {2:.3f})".format(*left_grip))

    # Cap up, label out towards the viewer: a carried bottle stays upright whatever
    # the wrist is doing, so world up is the axis to point the cap along.
    up = Vector((0.0, 0.0, 1.0))
    hold(water, right_grip, up, forward)
    hold(flask, left_grip, up, forward)

    right = Vector(forward).cross(up).normalized()
    focus = Vector(((right_grip.x + left_grip.x) / 2.0,
                    (right_grip.y + left_grip.y) / 2.0,
                    (right_grip.z + left_grip.z) / 2.0 + 0.10))
    preview.lights(focus, spread=1.15)
    preview.hero(focus - Vector(forward) * 1.20 + right * 0.42
                 + Vector((0.0, 0.0, 0.30)), focus, lens=58.0)
    preview.shot("bottles_held", (900, 820))

    # Close-up: does the waist actually sit inside the mitten?
    preview.lights(right_grip, spread=0.62)
    preview.hero(right_grip - Vector(forward) * 0.34 + right * 0.20
                 + Vector((0.0, 0.0, 0.12)), right_grip, lens=76.0)
    preview.shot("bottles_grip", (860, 760))


if __name__ == "__main__":
    main()
