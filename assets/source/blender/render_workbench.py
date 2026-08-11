"""Renders previews of the workbench prop.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/workbench.blend --python assets/source/blender/render_workbench.py

Images land in assets/previews/authoring/. `workbench_open` winds the vice out
to check the jaw really slides along its screw, and the two character shots are the
only reliable way to judge a work surface height: `workbench_scale` stands the
character beside the bench for a straight height comparison, `workbench_use` puts
them at it.
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

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "authoring")
VICE_TRAVEL = 0.085


def load_character():
    """Import the character and keep the matrices the import gave its roots."""
    _, _, snapshot = character_ref.import_character()
    added = [obj for obj in bpy.data.objects if obj not in snapshot["objects"]]
    roots = [(obj, obj.matrix_world.copy()) for obj in added if obj.parent is None]
    return added, roots


def stand(roots, location, turn=0.0):
    """Put the character down at `location`, turned `turn` radians about Z.

    Recomputed from the import matrices rather than applied on top of wherever it was
    last, and rotated about the world origin because that is where the character is
    authored. Assigning rotation_euler outright would throw away the axis correction
    the glTF import bakes into the root.
    """
    for obj, base in roots:
        obj.matrix_world = (Matrix.Translation(location)
                            @ Matrix.Rotation(turn, 4, "Z") @ base)


def main():
    preview = Preview(OUTPUT_DIR, samples=128)
    preview.ground()
    bench = bpy.data.objects["Workbench"]

    points = [bench.matrix_world @ vert.co for vert in bench.data.vertices]
    top = max(p.z for p in points if p.y > 0.0)
    print("bench spans x {0:.3f}..{1:.3f}  y {2:.3f}..{3:.3f}  z {4:.3f}..{5:.3f}, "
          "work surface {6:.3f}".format(
              min(p.x for p in points), max(p.x for p in points),
              min(p.y for p in points), max(p.y for p in points),
              min(p.z for p in points), max(p.z for p in points), top))

    jaw = bpy.data.objects.get("WorkbenchViceJaw")
    jaw_home = jaw.location.y if jaw is not None else 0.0

    def wind_vice(distance):
        """Open the vice by sliding the jaw along its screw, which is +Y here."""
        if jaw is not None:
            jaw.location.y = jaw_home + distance

    focus = Vector((0.0, 0.0, 0.46))
    preview.lights(focus, spread=1.7)

    preview.ortho((0.0, 6.0, focus.z), focus, 1.62)
    preview.shot("workbench_front", (960, 640))

    # From the vice end, so the vice reads as front-mounted rather than stuck on the
    # end of the bench, which is how it looks from the other corner.
    preview.hero((-1.52, 1.70, 1.02), (0.06, 0.0, 0.46), lens=46.0)
    preview.shot("workbench_hero", (1040, 780))

    # High and over the front edge, which is the only angle the tool well and the
    # slatted shelf both read from.
    preview.hero((0.86, 1.18, 1.44), (-0.05, -0.09, 0.52), lens=40.0)
    preview.shot("workbench_top", (1000, 760))

    # Close on the vice, wound out so the screw and guide rods are exposed.
    vice = Vector((-0.40, 0.34, top - 0.10))
    preview.lights(vice, spread=0.85, gain=1.25)
    wind_vice(VICE_TRAVEL)
    preview.hero(vice + Vector((0.52, 0.62, 0.30)), vice, lens=62.0)
    preview.shot("workbench_open", (960, 760))
    wind_vice(0.0)

    # --- against the character -------------------------------------------
    if not os.path.exists(character_ref.CHARACTER_GLB):
        print("character asset missing; skipping the scale previews")
        return

    added, roots = load_character()
    stand(roots, (-0.98, 0.06, 0.0))
    height = max((obj.matrix_world @ vert.co).z for obj in added
                 if obj.type == "MESH" for vert in obj.data.vertices)
    print("character crown {0:.3f} m, work surface {1:.3f} m ({2:.0f}% of height)"
          .format(height, top, top / height * 100.0))

    # Wide enough to clear the crown: the ortho scale is the frame's long side, so at
    # this aspect ratio 2.3 leaves only 1.66 m of height and decapitates the figure.
    preview.lights(Vector((-0.30, 0.0, 0.60)), spread=1.9)
    preview.ortho((-0.30, 6.0, 0.78), (-0.30, 0.0, 0.78), 2.64)
    preview.shot("workbench_scale", (1000, 720))

    # Stood at the vice, turned to face the bench. Shot from well along the bench
    # rather than square on to it: anywhere in front puts the figure between the
    # camera and the bench, and all you see is their back.
    stand(roots, (-0.36, 0.58, 0.0), turn=math.pi)
    preview.lights(Vector((-0.20, 0.10, 0.60)), spread=1.9)
    preview.hero((2.45, 1.45, 1.02), (-0.30, 0.24, 0.54), lens=38.0)
    preview.shot("workbench_use", (1040, 780))


if __name__ == "__main__":
    main()
