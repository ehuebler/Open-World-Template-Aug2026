"""Build the instanced alien-tech fragment used by the planetary formation sites.

Run from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python blender_assets/source/build_tech_fragment.py

The metre cube is only the repeatable authored unit. Godot stretches, turns and
partly buries each instance independently, so one mesh reads as slabs, towers and
corner-first shards. Its hundreds of panels are real silhouette geometry; the
dedicated vivid shader adds only the sub-panel etching and iridescent film.

The same deterministic pass also exports ``tech_fragment_collision.glb``. It
retains the core, broad panels and bars without bevels or pin-sized studs, giving
runtime streaming an accurate surface without shipping the visual mesh's 24k
triangles into physics for every nearby fragment.
"""

from __future__ import annotations

import os
import random
import sys

import bmesh
import bpy

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir, os.pardir))
OUTPUT = os.path.join(PROJECT_DIR, "blender_assets", "tech_fragment.glb")
COLLISION_OUTPUT = os.path.join(
    PROJECT_DIR, "blender_assets", "tech_fragment_collision.glb")
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

from propkit import (  # noqa: E402
    add_box,
    ensure_materials,
    evaluated_polys,
    export_selected,
    new_object,
    reset_scene,
)

SEED = 20261003
GRID = 10
CORE_HALF = 0.5
OVERLAP = 0.006

MATERIALS = {
    "TechIris": {
        "colour": (0.48, 0.08, 0.62, 1.0),
        "roughness": 0.16,
        "metallic": 0.0,
        "emission": ((0.02, 0.55, 0.72, 1.0), 0.15),
    },
}

# (normal axis, sign, first face axis, second face axis).
FACES = (
    (0, -1.0, 1, 2),
    (0, 1.0, 1, 2),
    (1, -1.0, 0, 2),
    (1, 1.0, 0, 2),
    (2, -1.0, 0, 1),
    (2, 1.0, 0, 1),
)


def _face_box(bm: bmesh.types.BMesh, face: tuple[int, float, int, int],
              u0: float, u1: float, v0: float, v1: float,
              depth: float) -> None:
    axis, sign, u_axis, v_axis = face
    lo = [-CORE_HALF, -CORE_HALF, -CORE_HALF]
    hi = [CORE_HALF, CORE_HALF, CORE_HALF]
    lo[u_axis], hi[u_axis] = sorted((u0, u1))
    lo[v_axis], hi[v_axis] = sorted((v0, v1))
    inner = sign * (CORE_HALF - OVERLAP)
    outer = sign * (CORE_HALF + depth)
    lo[axis], hi[axis] = sorted((inner, outer))
    add_box(bm, lo, hi, 0)


def _span(rng: random.Random) -> int:
    roll = rng.random()
    if roll < 0.08:
        return 3
    if roll < 0.33:
        return 2
    return 1


def _panel_face(bm: bmesh.types.BMesh,
                collision_bm: bmesh.types.BMesh,
                face: tuple[int, float, int, int],
                rng: random.Random) -> int:
    occupied = [[False for _v in range(GRID)] for _u in range(GRID)]
    cells = [(u, v) for u in range(GRID) for v in range(GRID)]
    rng.shuffle(cells)
    made = 0
    cell = 0.94 / GRID

    for u, v in cells:
        if occupied[u][v] or rng.random() < 0.08:
            continue
        wide = min(_span(rng), GRID - u)
        tall = min(_span(rng), GRID - v)
        while wide > 1 and any(occupied[x][y]
                               for x in range(u, u + wide)
                               for y in range(v, v + tall)):
            wide -= 1
        while tall > 1 and any(occupied[x][y]
                               for x in range(u, u + wide)
                               for y in range(v, v + tall)):
            tall -= 1
        if any(occupied[x][y]
               for x in range(u, u + wide)
               for y in range(v, v + tall)):
            continue
        for x in range(u, u + wide):
            for y in range(v, v + tall):
                occupied[x][y] = True

        gap = rng.uniform(0.008, 0.018)
        u0 = -0.47 + u * cell + gap
        u1 = -0.47 + (u + wide) * cell - gap
        v0 = -0.47 + v * cell + gap
        v1 = -0.47 + (v + tall) * cell - gap
        depth = rng.uniform(0.018, 0.055)
        if rng.random() < 0.15:
            depth += rng.uniform(0.04, 0.1)
        _face_box(bm, face, u0, u1, v0, v1, depth)
        # The collision companion keeps the broad panels but has no bevel and
        # deliberately omits the tiny studs below. It therefore follows every
        # rectangle a player can read without turning thousands of decorative
        # pinheads into snag points.
        _face_box(collision_bm, face, u0, u1, v0, v1, depth)
        made += 1

    # Fine studs and long bus-like bars break the tiled grid into several scales.
    for _stud in range(18):
        u = rng.uniform(-0.43, 0.43)
        v = rng.uniform(-0.43, 0.43)
        wide = rng.uniform(0.018, 0.055)
        tall = rng.uniform(0.018, 0.055)
        _face_box(bm, face, u - wide, u + wide, v - tall, v + tall,
                  rng.uniform(0.07, 0.15))
        made += 1
    for _bar in range(5):
        horizontal = rng.random() < 0.5
        u = rng.uniform(-0.3, 0.3)
        v = rng.uniform(-0.3, 0.3)
        half_u = rng.uniform(0.15, 0.34) if horizontal else rng.uniform(0.025, 0.055)
        half_v = rng.uniform(0.025, 0.055) if horizontal else rng.uniform(0.15, 0.34)
        depth = rng.uniform(0.065, 0.13)
        _face_box(
            bm, face, u - half_u, u + half_u, v - half_v, v + half_v, depth)
        _face_box(
            collision_bm, face,
            u - half_u, u + half_u, v - half_v, v + half_v, depth)
        made += 1
    return made


def main() -> None:
    reset_scene()
    slots = ensure_materials(MATERIALS)
    rng = random.Random(SEED)
    bm = bmesh.new()
    collision_bm = bmesh.new()
    add_box(bm, (-CORE_HALF, -CORE_HALF, -CORE_HALF),
            (CORE_HALF, CORE_HALF, CORE_HALF), 0)
    add_box(collision_bm, (-CORE_HALF, -CORE_HALF, -CORE_HALF),
            (CORE_HALF, CORE_HALF, CORE_HALF), 0)

    panels = 0
    for face in FACES:
        panels += _panel_face(bm, collision_bm, face, rng)

    fragment = new_object(
        "TechFragment",
        bm,
        slots,
        bevel_width=0.004,
        bevel_segments=1,
        smooth_angle=24.0,
    )
    collision_fragment = new_object(
        "TechFragmentCollision",
        collision_bm,
        slots,
        smooth_angle=0.0,
    )
    bpy.context.view_layer.update()
    polygons = evaluated_polys(fragment)
    collision_polygons = evaluated_polys(collision_fragment)
    if panels < 250:
        raise ValueError("tech fragment has too few geometric panels: {}".format(panels))
    if polygons > 28000:
        raise ValueError("tech fragment bevel made {} polygons".format(polygons))
    if collision_polygons > 8000:
        raise ValueError(
            "tech fragment collision made {} polygons".format(collision_polygons))

    export_selected([fragment], OUTPUT)
    export_selected([collision_fragment], COLLISION_OUTPUT)
    print(
        "tech fragment: {} protrusions, {} visual polygons, "
        "{} collision polygons".format(
            panels, polygons, collision_polygons))


if __name__ == "__main__":
    main()
