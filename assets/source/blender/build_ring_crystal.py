"""Build the reusable faceted crystal segment for planetary ring sites.

Run from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_ring_crystal.py

Godot bends no vertices at runtime: it places many straight, overlapping shards
along circular, oval and elongated curves. One compact convex segment therefore
serves every ring size while preserving MultiMesh batching and simple streamed
collision.
"""

from __future__ import annotations

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
OUTPUT = os.path.join(
    PROJECT_DIR, "assets", "runtime", "environment", "ring_crystal_segment.glb")
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

from propkit import ensure_materials, export_selected, new_object, reset_scene  # noqa: E402


SEED = 20261010
SIDES = 10
MATERIALS = {
    "RingCrystalPreview": {
        "colour": (0.08, 0.78, 0.34, 1.0),
        "roughness": 0.14,
        "metallic": 0.0,
        "emission": ((0.04, 0.72, 0.22, 1.0), 0.55),
    },
}


def _segment_mesh() -> bmesh.types.BMesh:
    rng = random.Random(SEED)
    bm = bmesh.new()

    # A fixed irregular decagon gives every long face a distinct reflection.
    # The axial profile cuts both ends and puts two subtle kinks through the
    # middle, so repeated pieces read as grown crystal rather than pipes.
    profile = [
        0.86 + rng.uniform(-0.09, 0.09)
        for _side in range(SIDES)
    ]
    levels = (
        (-0.50, 0.72, -0.035, 0.018),
        (-0.40, 1.00, 0.012, -0.020),
        (-0.08, 0.94, -0.018, 0.010),
        (0.22, 1.03, 0.025, 0.020),
        (0.42, 0.92, -0.010, -0.015),
        (0.50, 0.70, 0.030, 0.010),
    )
    rings: list[list[bmesh.types.BMVert]] = []
    for level_index, (x, radius, y_shift, z_shift) in enumerate(levels):
        ring = []
        for side in range(SIDES):
            angle = math.tau * side / SIDES + 0.11
            alternating = 1.0 + 0.045 * math.sin(
                angle * 3.0 + level_index * 0.83)
            value = 0.5 * radius * profile[side] * alternating
            ring.append(bm.verts.new(Vector((
                x,
                math.cos(angle) * value + y_shift,
                math.sin(angle) * value + z_shift,
            ))))
        rings.append(ring)

    for level in range(len(rings) - 1):
        for side in range(SIDES):
            # Alternating winding diagonals stop the long facets from resolving
            # into a uniform chevron under directional light.
            a = rings[level][side]
            b = rings[level][(side + 1) % SIDES]
            c = rings[level + 1][(side + 1) % SIDES]
            d = rings[level + 1][side]
            if (level + side) % 2:
                bm.faces.new((a, b, d))
                bm.faces.new((b, c, d))
            else:
                bm.faces.new((a, b, c))
                bm.faces.new((a, c, d))

    start = bm.verts.new(Vector((-0.505, 0.0, 0.0)))
    end = bm.verts.new(Vector((0.505, 0.0, 0.0)))
    for side in range(SIDES):
        next_side = (side + 1) % SIDES
        bm.faces.new((start, rings[0][next_side], rings[0][side]))
        bm.faces.new((end, rings[-1][side], rings[-1][next_side]))
    return bm


def main() -> None:
    reset_scene()
    slots = ensure_materials(MATERIALS)
    segment = new_object(
        "RingCrystalSegment",
        _segment_mesh(),
        slots,
        smooth_angle=1.0,
    )
    bpy.context.view_layer.update()
    triangles = sum(len(poly.vertices) - 2 for poly in segment.data.polygons)
    if not 100 <= triangles <= 180:
        raise ValueError("ring crystal generated {} triangles".format(triangles))
    export_selected([segment], OUTPUT)
    print("ring crystal: {} triangles".format(triangles))


if __name__ == "__main__":
    main()
