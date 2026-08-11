"""Author the second-generation giant flower tree and its runtime paint.

The original asset was a decimated single-shell MeshMaker export.  Its silhouette
was difficult to read, the crown had no deliberate botanical construction, and
all of its surface detail lived in coarse vertex-colour blocks.  This generator
builds the replacement as authored botanical layers:

* a subtly curved, buttressed trunk with raised bark ribbons;
* an independently rotatable calyx and three overlapping petal whorls;
* a sculpted seed cup with individual curved stamens;
* one external, mip-safe PNG carrying bark, sepal, petal, vein and centre paint.

The runtime contract remains unchanged.  ``FlowerTreeField`` extracts exactly
two meshes from ``flower_tree.glb`` and draws the whole population as two
MultiMeshes.  The head remains below ``FlowerTreeHeadPivot`` so every generated
tree can receive its own flower angle without duplicating scene nodes.
"""

from __future__ import annotations

import json
import math
import os
import random
import sys
from typing import Sequence

import bmesh
import bpy
from mathutils import Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir, os.pardir))
OUTPUT_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
PAINT_DIR = os.path.join(OUTPUT_DIR, "biome_paint")
PREVIEW_DIR = os.path.join(OUTPUT_DIR, "biome_previews")
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_biome_assets as biome
import build_vat


SEED = 73051
HEAD_PIVOT_Z = 7.0
PAINT_SIZE = 512
PAINT_GUTTER = 8
PREVIEW_SIZE = 640
PREVIEW_SAMPLES = 48
PALETTE = tuple(map(biome._rgba, (
    "2B1719",  # 0: deep mahogany bark
    "9C5939",  # 1: warm raised bark ribbons
    "24483F",  # 2: blue-green calyx and sepals
    "681541",  # 3: wine outer petals
    "C93678",  # 4: rose middle petals
    "F47EAC",  # 5: luminous inner petals and veins
    "E7A637",  # 6: amber seed cup and filaments
    "FFE0A3",  # 7: cream-gold anthers
)))
RECIPE = biome.AssetRecipe(
    "flower_tree",
    "tree",
    "tree",
    "layered_flower",
    SEED,
    9.2,
    PALETTE,
    (3200, 9000),
    {
        "shape": "compound",
        "parts": [
            {
                "shape": "cylinder",
                "radius": 0.78,
                "height": 7.15,
                "centre": [0.0, 3.575, 0.0],
            },
            {
                "shape": "sphere",
                "radius": 4.65,
                "centre": [0.0, HEAD_PIVOT_Z + 0.48, 0.0],
            },
        ],
    },
    (
        "mahogany bark with amber ribbons; teal sepals; layered wine, rose and "
        "pink petals; amber seed cup and cream anthers"
    ),
    (
        "petal midribs, inner petals, seed cup and anthers carry a broad "
        "mip-safe night-emission mask in PNG alpha"
    ),
    3.8,
    roughness=0.72,
    smooth=True,
)


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def _smoothstep(low: float, high: float, value: float) -> float:
    if high <= low:
        return 1.0 if value >= high else 0.0
    amount = _clamp01((value - low) / (high - low))
    return amount * amount * (3.0 - 2.0 * amount)


def _mix(first: Sequence[float], second: Sequence[float],
         share: float) -> tuple[float, float, float, float]:
    amount = _clamp01(share)
    return tuple(
        first[index] * (1.0 - amount) + second[index] * amount
        for index in range(4)
    )


def _dark(colour: Sequence[float], amount: float = 0.48
          ) -> tuple[float, float, float, float]:
    return (
        colour[0] * amount,
        colour[1] * amount,
        colour[2] * amount,
        colour[3],
    )


def _pale(colour: Sequence[float], amount: float = 0.35
          ) -> tuple[float, float, float, float]:
    return _mix(colour, (1.0, 0.91, 0.74, 1.0), amount)


def _paint_pixel(palette_index: int, u: float, v: float
                 ) -> tuple[float, float, float, float]:
    """Paint one broad, tile-safe texel for the semantic atlas band."""

    tau = math.tau
    base = PALETTE[palette_index]
    shadow = _dark(base)
    highlight = _pale(base)
    phase = palette_index * 0.473 + SEED * 0.00019
    horizontal = 0.5 + 0.5 * math.sin(
        tau * (v * (3.0 + palette_index % 3)
               + 0.13 * math.sin(tau * u * 2.0) + phase))
    vertical = 0.5 + 0.5 * math.sin(
        tau * (u * (4.0 + palette_index % 2)
               + 0.10 * math.sin(tau * v * 2.0) + phase * 1.7))
    islands = (
        (0.5 + 0.5 * math.sin(tau * (u * 3.0 + v * 1.7 + phase)))
        * (0.5 + 0.5 * math.sin(tau * (v * 4.0 - u * 1.3 + phase * 2.1)))
    )
    spots = _smoothstep(0.60, 0.84, islands)
    result: Sequence[float] = base
    emission = 0.0

    if palette_index <= 1:
        # Broad longitudinal grooves and broken growth bands.  The knots are
        # intentionally sparse enough to survive on a four-metre runtime tree.
        grooves = _smoothstep(0.52, 0.80, vertical)
        growth = _smoothstep(0.48, 0.74, horizontal)
        knots = spots * _smoothstep(0.58, 0.82, vertical)
        result = _mix(result, shadow, grooves * (0.50 if palette_index == 0 else 0.27))
        result = _mix(result, highlight, (1.0 - grooves) * 0.24)
        result = _mix(result, _dark(base, 0.30), growth * 0.20 + knots * 0.52)
        if palette_index == 1:
            result = _mix(result, PALETTE[6], (1.0 - growth) * 0.12)
    elif palette_index == 2:
        # Sepal midribs and pale margins, with no emission.
        midrib = 1.0 - _smoothstep(
            0.030, 0.115,
            abs((u - 0.5) - 0.07 * math.sin(tau * (v * 2.0 + phase))))
        branching = _smoothstep(0.66, 0.91, vertical * horizontal)
        result = _mix(result, highlight, midrib * 0.42)
        result = _mix(result, shadow, branching * 0.22)
    elif 3 <= palette_index <= 5:
        # Petal markings are graphic rather than noisy: one winding midrib,
        # paired side veins, a dark scalloped wash, and restrained freckles.
        centre_line = abs(
            (u - 0.5) - 0.055 * math.sin(tau * (v * 1.5 + phase)))
        midrib = 1.0 - _smoothstep(0.025, 0.105, centre_line)
        side_distance = abs(
            ((u * 4.0 + v * 1.65
              + 0.12 * math.sin(tau * v * 2.0 + phase)) % 1.0) - 0.5)
        side_veins = 1.0 - _smoothstep(0.035, 0.120, side_distance)
        scallop = _smoothstep(0.54, 0.82, horizontal)
        inner = (palette_index - 3) / 2.0
        result = _mix(result, shadow, scallop * (0.28 - inner * 0.08))
        result = _mix(result, highlight, midrib * (0.48 + inner * 0.18))
        result = _mix(result, PALETTE[7], side_veins * (0.12 + inner * 0.10))
        result = _mix(result, highlight, spots * (0.13 + inner * 0.08))
        emission = _clamp01(
            midrib * (0.35 + inner * 0.34)
            + side_veins * (0.08 + inner * 0.18)
            + spots * inner * 0.13)
    elif palette_index == 6:
        # A honeycomb-like seed cup.  Nearly all of it emits, but broad darker
        # cells retain shape instead of turning the centre into a flat lamp.
        cells = _smoothstep(0.54, 0.82, vertical * horizontal)
        result = _mix(result, shadow, cells * 0.35)
        result = _mix(result, PALETTE[7], (1.0 - cells) * 0.35 + spots * 0.22)
        emission = 0.70 + (1.0 - cells) * 0.24
    else:
        # Cream anthers with rose freckles.
        result = _mix(result, PALETTE[5], spots * 0.28)
        result = _mix(result, shadow, horizontal * 0.08)
        emission = 0.88 + spots * 0.12

    drift = 0.95 + 0.05 * math.sin(
        tau * (u + v * 0.61 + phase * 0.37))
    return (
        _clamp01(result[0] * drift),
        _clamp01(result[1] * drift),
        _clamp01(result[2] * drift),
        _clamp01(emission),
    )


def _write_paint_texture(path: str) -> bpy.types.Image:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image = bpy.data.images.new(
        "flower_tree_color_paint",
        width=PAINT_SIZE,
        height=PAINT_SIZE,
        alpha=True,
        float_buffer=False,
    )
    try:
        image.colorspace_settings.name = "sRGB"
    except TypeError:
        pass
    # Alpha is semantic emission data, never transparency.
    if hasattr(image, "alpha_mode"):
        image.alpha_mode = "CHANNEL_PACKED"

    palette_count = len(PALETTE)
    band_pixels = PAINT_SIZE / palette_count
    gutter_share = PAINT_GUTTER / band_pixels
    pixels: list[float] = []
    for y in range(PAINT_SIZE):
        atlas_v = (y + 0.5) / PAINT_SIZE * palette_count
        palette_index = min(int(atlas_v), palette_count - 1)
        local_v = atlas_v - palette_index
        local_v = _clamp01(
            (local_v - gutter_share)
            / max(1.0 - gutter_share * 2.0, 1.0e-5))
        for x in range(PAINT_SIZE):
            u = (x + 0.5) / PAINT_SIZE
            pixels.extend(_paint_pixel(palette_index, u, local_v))
    image.pixels.foreach_set(pixels)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise ValueError("flower-tree paint did not produce {}".format(path))
    return image


def _trunk_centre(z: float) -> Vector:
    """An upright base with a restrained asymmetric sweep higher up."""

    t = _clamp01(z / 7.15)
    bend = t * t * (3.0 - 2.0 * t)
    return Vector((
        0.15 * bend * math.sin(t * 2.35 + 0.18),
        -0.11 * bend * math.sin(t * 1.82 + 0.84),
        z,
    ))


def _trunk_radius(t: float) -> float:
    return 0.80 * (1.0 - t) ** 0.42 + 0.38 * t


def _build_trunk() -> bmesh.types.BMesh:
    bm = bmesh.new()
    bm.faces.layers.int.new(biome.PALETTE_ATTRIBUTE)
    rng = random.Random(SEED)

    # Nine spreading buttress roots grow out of the trunk's lower profile.  They
    # overlap the trunk shell deliberately; that removes daylight cracks while
    # keeping every part in the same exported mesh primitive.
    for index in range(9):
        angle = math.tau * index / 9.0 + rng.uniform(-0.12, 0.12)
        radial = Vector((math.cos(angle), math.sin(angle), 0.0))
        tangent = Vector((-math.sin(angle), math.cos(angle), 0.0))
        reach = rng.uniform(1.45, 1.95)
        points = (
            _trunk_centre(0.74) + radial * 0.18,
            _trunk_centre(0.43) + radial * 0.64 + tangent * rng.uniform(-0.08, 0.08),
            radial * (reach * 0.72) + tangent * rng.uniform(-0.12, 0.12)
            + Vector((0.0, 0.0, 0.13)),
            radial * reach + Vector((0.0, 0.0, 0.025)),
        )
        biome._add_tube(
            bm,
            points,
            (0.31, 0.25, 0.12, 0.025),
            0,
            segments=8,
            aspect=0.62,
            phase=angle,
        )

    trunk_points = []
    trunk_radii = []
    for index in range(10):
        t = index / 9.0
        z = 7.18 * t
        trunk_points.append(_trunk_centre(z))
        trunk_radii.append(_trunk_radius(t))
    biome._add_tube(
        bm,
        trunk_points,
        trunk_radii,
        0,
        segments=14,
        phase=0.37,
    )

    # Raised bark ribbons follow the trunk's sweep and slowly braid around it.
    # They give nearby trees a readable surface silhouette even before the PNG
    # contributes its darker painted grooves.
    for ridge in range(7):
        points = []
        radii = []
        for sample in range(9):
            t = 0.045 + sample / 8.0 * 0.91
            z = 7.18 * t
            angle = (
                math.tau * ridge / 7.0
                + t * math.tau * (0.34 + 0.035 * (ridge % 3))
                + 0.08 * math.sin(t * math.tau * 2.0 + ridge))
            outward = Vector((math.cos(angle), math.sin(angle), 0.0))
            points.append(
                _trunk_centre(z)
                + outward * (_trunk_radius(t) + 0.018))
            radii.append(0.050 * (1.0 - 0.45 * t))
        biome._add_tube(
            bm, points, radii, 1,
            segments=5, aspect=0.52, phase=ridge * 0.81)

    # Ground every root's narrow underside without flattening visible knees.
    for vertex in bm.verts:
        if vertex.co.z < 0.055:
            vertex.co.z = 0.0
    return bm


def _add_petal(
    bm: bmesh.types.BMesh,
    *,
    angle: float,
    length: float,
    half_width: float,
    elevation: float,
    arch: float,
    wave: float,
    palette_index: int,
    origin_radius: float,
    origin_height: float,
    raised_vein: bool,
) -> None:
    radial = Vector((math.cos(angle), math.sin(angle), 0.0))
    side = Vector((-math.sin(angle), math.cos(angle), 0.0))
    direction = biome._direction(angle, elevation).normalized()
    normal = direction.cross(side).normalized()
    start = radial * origin_radius + Vector((0.0, 0.0, origin_height))
    points = []
    widths = []
    sample_count = 7
    for sample in range(sample_count):
        t = sample / (sample_count - 1)
        envelope = math.sin(math.pi * t) ** 0.63
        centre = (
            start
            + direction * length * t
            + normal * length * arch * math.sin(math.pi * t)
            + side * length * wave
            * math.sin(math.tau * t + angle * 1.7)
        )
        # A small upward return at the very tip keeps the outer flower from
        # reading as a rigid plate when seen from the ground.
        centre += normal * length * 0.035 * t * t
        points.append(centre)
        width = half_width * (
            0.055 + 0.945 * envelope * (1.0 - 0.13 * t))
        width *= 1.0 + 0.045 * math.sin(math.pi * t * 3.0 + angle)
        widths.append(max(0.035, width))
    biome._add_ribbon(
        bm,
        points,
        widths,
        palette_index,
        thickness=max(0.027, half_width * 0.035),
        side_hint=side,
        leaf_profile=True,
    )

    if raised_vein:
        lifted = [
            point + normal * (0.032 + 0.018 * math.sin(
                math.pi * index / (sample_count - 1)))
            for index, point in enumerate(points[:-1])
        ]
        radii = [
            0.037 * (1.0 - 0.70 * index / max(1, len(lifted) - 1))
            for index in range(len(lifted))
        ]
        biome._add_tube(
            bm, lifted, radii, 5,
            segments=4, aspect=0.55, phase=angle)


def _build_head() -> bmesh.types.BMesh:
    bm = bmesh.new()
    bm.faces.layers.int.new(biome.PALETTE_ATTRIBUTE)
    rng = random.Random(SEED ^ 0x65A4E12B)

    # The calyx seals the head/trunk overlap and remains visible between the
    # outer petals when a bloom is strongly tilted.
    biome._add_profiled_hull(
        bm,
        Vector((0.0, 0.0, -0.46)),
        Vector((0.0, 0.0, 1.0)),
        (
            (0.0, 0.38, 0.38),
            (0.24, 0.68, 0.68),
            (0.52, 1.02, 1.02),
            (0.76, 1.24, 1.24),
            (0.93, 0.86, 0.86),
        ),
        2,
        segments=14,
        lobes=7,
        lobe_amount=0.07,
        phase=0.42,
    )

    for index in range(10):
        angle = math.tau * index / 10.0 + 0.18
        _add_petal(
            bm,
            angle=angle,
            length=2.85 + rng.uniform(-0.10, 0.15),
            half_width=0.42 + rng.uniform(-0.03, 0.035),
            elevation=-0.13 + rng.uniform(-0.025, 0.025),
            arch=-0.035,
            wave=0.018,
            palette_index=2,
            origin_radius=0.48,
            origin_height=0.20,
            raised_vein=False,
        )

    whorls = (
        # count, phase, length, width, elevation, arch, wave, palette
        (13, 0.00, 4.42, 1.20, 0.035, -0.045, 0.020, 3),
        (11, 0.31, 3.58, 1.07, 0.205, 0.040, 0.016, 4),
        (9, 0.66, 2.62, 0.82, 0.405, 0.085, 0.012, 5),
    )
    for whorl_index, values in enumerate(whorls):
        count, phase, length, width, elevation, arch, wave, palette = values
        for index in range(count):
            angle = phase + math.tau * index / count
            _add_petal(
                bm,
                angle=angle,
                length=length * rng.uniform(0.94, 1.055),
                half_width=width * rng.uniform(0.93, 1.06),
                elevation=elevation + rng.uniform(-0.022, 0.024),
                arch=arch + rng.uniform(-0.012, 0.012),
                wave=wave * (-1.0 if (index + whorl_index) % 2 else 1.0),
                palette_index=palette,
                origin_radius=0.28 + whorl_index * 0.04,
                origin_height=0.32 + whorl_index * 0.10,
                raised_vein=(whorl_index > 0 or index % 2 == 0),
            )

    # A lobed, domed seed cup hides every petal root and gives the flower a
    # strong focal form instead of a flat coin in the middle.
    biome._add_profiled_hull(
        bm,
        Vector((0.0, 0.0, 0.23)),
        Vector((0.0, 0.0, 1.0)),
        (
            (0.0, 1.28, 1.28),
            (0.23, 1.48, 1.48),
            (0.50, 1.35, 1.35),
            (0.75, 1.03, 1.03),
            (0.96, 0.46, 0.46),
            (1.05, 0.12, 0.12),
        ),
        6,
        segments=18,
        lobes=11,
        lobe_amount=0.045,
        phase=0.29,
    )

    # Curved filaments in two offset rings create a dense but still readable
    # centre.  Their anthers are profiled botanical pods, not primitive spheres.
    rings = ((10, 0.56, 0.83, 0.34), (16, 0.96, 0.69, 0.25))
    for ring_index, (count, radius, start_z, height) in enumerate(rings):
        for index in range(count):
            angle = (
                math.tau * index / count
                + ring_index * 0.23
                + rng.uniform(-0.035, 0.035))
            radial = Vector((math.cos(angle), math.sin(angle), 0.0))
            side = Vector((-math.sin(angle), math.cos(angle), 0.0))
            start = radial * radius + Vector((0.0, 0.0, start_z))
            end = (
                radial * (radius + 0.13 + 0.04 * ring_index)
                + side * rng.uniform(-0.055, 0.055)
                + Vector((0.0, 0.0, start_z + height)))
            middle = start.lerp(end, 0.52) + radial * 0.055
            biome._add_tube(
                bm,
                (start, middle, end),
                (0.033, 0.025, 0.015),
                6,
                segments=5,
                aspect=0.82,
                phase=angle,
            )
            axis = (
                radial * 0.28
                + Vector((0.0, 0.0, 0.96))
                + side * rng.uniform(-0.08, 0.08)).normalized()
            biome._add_profiled_hull(
                bm,
                end - axis * 0.075,
                axis,
                (
                    (0.0, 0.070, 0.058),
                    (0.07, 0.115, 0.085),
                    (0.18, 0.096, 0.070),
                    (0.25, 0.018, 0.018),
                ),
                7,
                segments=7,
                lobes=3,
                lobe_amount=0.05,
                phase=angle,
            )
    return bm


def _face_phase(values: Sequence[float]) -> list[float]:
    centre = sum(values) / len(values)
    phase = 0.20 + (centre - math.floor(centre)) * 0.60
    return [
        max(0.04, min(0.96, phase + (value - centre) * 0.72))
        for value in values
    ]


def _polygon_uvs(
    polygon: bpy.types.MeshPolygon,
    coordinates: Sequence[Vector],
    palette_index: int,
) -> list[tuple[float, float]]:
    if palette_index <= 1:
        raw_u = [
            math.atan2(coordinate.y, coordinate.x) / math.tau
            for coordinate in coordinates
        ]
        anchor = raw_u[0]
        local_u = [
            anchor + ((value - anchor + 0.5) % 1.0) - 0.5
            for value in raw_u
        ]
        local_v = [
            _clamp01(coordinate.z / RECIPE.height)
            for coordinate in coordinates
        ]
    else:
        scale = 1.35 if palette_index <= 5 else 0.82
        normal = polygon.normal
        dominant = max(range(3), key=lambda axis: abs(normal[axis]))
        axes = ((1, 2), (0, 2), (0, 1))[dominant]
        local_u = _face_phase([
            coordinate[axes[0]] / scale for coordinate in coordinates
        ])
        local_v = _face_phase([
            coordinate[axes[1]] / scale for coordinate in coordinates
        ])

    palette_count = len(PALETTE)
    band_pixels = PAINT_SIZE / palette_count
    gutter = PAINT_GUTTER / band_pixels
    usable = 1.0 - gutter * 2.0
    return [
        (
            u,
            (palette_index + gutter + _clamp01(v) * usable) / palette_count,
        )
        for u, v in zip(local_u, local_v)
    ]


def _vertex_colour(palette_index: int, coordinate: Vector
                   ) -> tuple[float, float, float, float]:
    base = PALETTE[palette_index]
    value = 0.92 + 0.08 * _clamp01(
        (coordinate.z + 0.5) / max(RECIPE.height, 0.01))
    value += 0.025 * math.sin(
        coordinate.x * 3.1 + coordinate.y * 4.7
        + coordinate.z * 2.2 + palette_index)
    return (
        _clamp01(base[0] * value),
        _clamp01(base[1] * value),
        _clamp01(base[2] * value),
        1.0,
    )


def _finish_mesh(
    name: str,
    bm: bmesh.types.BMesh,
    material: bpy.types.Material,
) -> bpy.types.Object:
    if not bm.faces:
        raise ValueError("{} produced no faces".format(name))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    mesh = bpy.data.meshes.new(name + "Mesh")
    bm.to_mesh(mesh)
    bm.free()
    mesh.validate(clean_customdata=False)
    mesh.update(calc_edges=True)

    palette_attribute = mesh.attributes.get(biome.PALETTE_ATTRIBUTE)
    if palette_attribute is None:
        raise ValueError("{} lost its semantic palette".format(name))
    colour = mesh.color_attributes.new(
        name=biome.COLOR_ATTRIBUTE,
        type="BYTE_COLOR",
        domain="CORNER",
    )
    paint_uv = mesh.uv_layers.new(name=biome.PAINT_UV_NAME)
    for polygon in mesh.polygons:
        palette_index = int(
            palette_attribute.data[polygon.index].value) % len(PALETTE)
        polygon.material_index = 0
        polygon.use_smooth = True
        coordinates = [
            mesh.vertices[mesh.loops[loop_index].vertex_index].co
            for loop_index in polygon.loop_indices
        ]
        uvs = _polygon_uvs(polygon, coordinates, palette_index)
        for loop_index, uv in zip(polygon.loop_indices, uvs):
            coordinate = mesh.vertices[
                mesh.loops[loop_index].vertex_index].co
            colour.data[loop_index].color = _vertex_colour(
                palette_index, coordinate)
            paint_uv.data[loop_index].uv = uv
    mesh.attributes.remove(palette_attribute)
    mesh.color_attributes.active_color_name = biome.COLOR_ATTRIBUTE
    mesh.color_attributes.render_color_index = 0
    mesh.uv_layers.active = paint_uv
    mesh.uv_layers.active_index = list(mesh.uv_layers).index(paint_uv)
    mesh.materials.append(material)
    mesh.update()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _export_material() -> bpy.types.Material:
    material = bpy.data.materials.new("FlowerTreeExportMaterial")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    principled.inputs["Roughness"].default_value = RECIPE.roughness
    colour = nodes.new("ShaderNodeVertexColor")
    colour.name = "FlowerTreeVertexColor"
    colour.layer_name = biome.COLOR_ATTRIBUTE
    links.new(colour.outputs["Color"], principled.inputs["Base Color"])
    return material


def _preview_with_paint(
    material: bpy.types.Material,
    image: bpy.types.Image,
) -> None:
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "FlowerTreeColorPaint"
    texture.image = image
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"
    for link in list(principled.inputs["Base Color"].links):
        links.remove(link)
    links.new(texture.outputs["Color"], principled.inputs["Base Color"])
    for socket_name in ("Emission Color", "Emission"):
        if socket_name in principled.inputs:
            links.new(texture.outputs["Color"], principled.inputs[socket_name])
            break
    if "Emission Strength" in principled.inputs:
        strength = nodes.new("ShaderNodeMath")
        strength.operation = "MULTIPLY"
        strength.inputs[1].default_value = 0.42
        links.new(texture.outputs["Alpha"], strength.inputs[0])
        links.new(strength.outputs[0], principled.inputs["Emission Strength"])


def _parent(
    child: bpy.types.Object,
    parent: bpy.types.Object,
    location: Vector = Vector((0.0, 0.0, 0.0)),
) -> None:
    child.parent = parent
    child.location = location
    child.rotation_euler = (0.0, 0.0, 0.0)
    child.scale = (1.0, 1.0, 1.0)


def _export(root: bpy.types.Object, path: str) -> None:
    for candidate in bpy.context.view_layer.objects:
        if candidate is not None:
            candidate.select_set(False)
    root.select_set(True)
    for child in root.children_recursive:
        child.select_set(True)
    bpy.context.view_layer.objects.active = root
    settings = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_normals=True,
        export_tangents=False,
        export_texcoords=True,
        export_skins=False,
        export_animations=False,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
    )
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **settings)
    except TypeError:
        bpy.ops.export_scene.gltf(**settings)


def _validate_glb(path: str) -> dict[str, int]:
    document, _binary = build_vat._read_glb(path)
    if document.get("skins") or document.get("animations"):
        raise ValueError("flower tree exported with rigging or animation")
    required = {
        "FlowerTree",
        "FlowerTreeTrunk",
        "FlowerTreeHeadPivot",
        "FlowerTreeHead",
    }
    names = {node.get("name") for node in document.get("nodes", [])}
    if not required.issubset(names):
        raise ValueError("flower tree GLB is missing nodes: {}".format(
            sorted(required - names)))
    if len(document.get("meshes", [])) != 2:
        raise ValueError("flower tree must export exactly two visual meshes")
    if document.get("images") or document.get("textures"):
        raise ValueError(
            "flower tree embedded its runtime PNG instead of keeping it external")

    triangles = 0
    vertices = 0
    primitives = 0
    for mesh in document["meshes"]:
        for primitive in mesh.get("primitives", []):
            primitives += 1
            attributes = primitive.get("attributes", {})
            missing = {"POSITION", "NORMAL", "COLOR_0", "TEXCOORD_0"} - set(
                attributes)
            if missing:
                raise ValueError("{} lost {}".format(
                    mesh.get("name", "flower tree mesh"), sorted(missing)))
            vertices += int(
                document["accessors"][attributes["POSITION"]]["count"])
            if "indices" in primitive:
                triangles += int(
                    document["accessors"][primitive["indices"]]["count"]) // 3
            else:
                triangles += int(
                    document["accessors"][attributes["POSITION"]]["count"]) // 3
    if primitives != 2:
        raise ValueError(
            "flower tree exported {} primitives; expected two".format(primitives))
    if not RECIPE.triangle_budget[0] <= triangles <= RECIPE.triangle_budget[1]:
        raise ValueError("flower tree has {} triangles, budget is {}..{}".format(
            triangles, *RECIPE.triangle_budget))
    return {
        "triangle_count": triangles,
        "glb_vertex_count": vertices,
        "primitive_count": primitives,
    }


def _look_at(obj: bpy.types.Object, location: Vector, target: Vector) -> None:
    obj.location = location
    obj.rotation_euler = (target - location).to_track_quat(
        "-Z", "Y").to_euler()


def _add_area_light(
    name: str,
    location: Vector,
    target: Vector,
    energy: float,
    size: float,
    colour: tuple[float, float, float],
) -> None:
    data = bpy.data.lights.new(name, type="AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    data.color = colour
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    _look_at(light, location, target)


def _preview_ground() -> None:
    mesh = bpy.data.meshes.new("FlowerTreePreviewGroundMesh")
    extent = 15.0
    mesh.from_pydata(
        [(-extent, -extent, 0.0), (extent, -extent, 0.0),
         (extent, extent, 0.0), (-extent, extent, 0.0)],
        [],
        [(0, 1, 2, 3)],
    )
    material = bpy.data.materials.new("FlowerTreePreviewGroundMaterial")
    material.use_nodes = True
    principled = material.node_tree.nodes["Principled BSDF"]
    principled.inputs["Base Color"].default_value = (0.055, 0.073, 0.065, 1.0)
    principled.inputs["Roughness"].default_value = 0.92
    mesh.materials.append(material)
    ground = bpy.data.objects.new("FlowerTreePreviewGround", mesh)
    bpy.context.scene.collection.objects.link(ground)


def _render_preview(
    name: str,
    camera_location: Vector,
    focus: Vector,
    ortho_scale: float,
) -> str:
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    if hasattr(scene, "eevee"):
        scene.eevee.taa_render_samples = PREVIEW_SAMPLES
    scene.render.resolution_x = PREVIEW_SIZE
    scene.render.resolution_y = PREVIEW_SIZE
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    for look in ("AgX - Medium High Contrast", "Medium High Contrast", "None"):
        try:
            scene.view_settings.look = look
            break
        except TypeError:
            continue

    if scene.world is None:
        scene.world = bpy.data.worlds.new("FlowerTreePreviewWorld")
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.018, 0.025, 0.032, 1.0)
    background.inputs["Strength"].default_value = 0.52

    camera_data = bpy.data.cameras.new("FlowerTreePreviewCamera_" + name)
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = ortho_scale
    camera = bpy.data.objects.new("FlowerTreePreviewCamera_" + name, camera_data)
    bpy.context.scene.collection.objects.link(camera)
    scene.camera = camera
    _look_at(camera, camera_location, focus)

    distance = 10.0
    _add_area_light(
        "FlowerTreeKey_" + name,
        focus + Vector((1.55, -1.75, 2.15)) * distance,
        focus,
        23000.0,
        11.0,
        (1.0, 0.82, 0.71),
    )
    _add_area_light(
        "FlowerTreeFill_" + name,
        focus + Vector((-1.8, -0.1, 0.9)) * distance,
        focus,
        7600.0,
        13.0,
        (0.54, 0.69, 1.0),
    )
    _add_area_light(
        "FlowerTreeRim_" + name,
        focus + Vector((-0.7, 1.7, 1.7)) * distance,
        focus,
        14000.0,
        9.0,
        (1.0, 0.27, 0.53),
    )

    os.makedirs(PREVIEW_DIR, exist_ok=True)
    path = os.path.join(PREVIEW_DIR, name + ".png")
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise ValueError("flower-tree preview did not produce {}".format(path))

    bpy.data.objects.remove(camera, do_unlink=True)
    for light_name in (
        "FlowerTreeKey_" + name,
        "FlowerTreeFill_" + name,
        "FlowerTreeRim_" + name,
    ):
        light = bpy.data.objects.get(light_name)
        if light is not None:
            bpy.data.objects.remove(light, do_unlink=True)
    return path


def _reset_scene() -> None:
    biome._reset_scene()


def main() -> None:
    print("\n=== flower tree v2 ===")
    _reset_scene()
    paint_path = os.path.join(PAINT_DIR, "flower_tree_paint.png")
    paint_image = _write_paint_texture(paint_path)
    material = _export_material()

    trunk = _finish_mesh("FlowerTreeTrunk", _build_trunk(), material)
    head = _finish_mesh("FlowerTreeHead", _build_head(), material)
    root = bpy.data.objects.new("FlowerTree", None)
    pivot = bpy.data.objects.new("FlowerTreeHeadPivot", None)
    bpy.context.scene.collection.objects.link(root)
    bpy.context.scene.collection.objects.link(pivot)
    _parent(trunk, root)
    _parent(pivot, root, Vector((0.0, 0.0, HEAD_PIVOT_Z)))
    _parent(head, pivot)
    bpy.context.view_layer.update()

    trunk_triangles = build_vat.triangle_count(trunk.data)
    head_triangles = build_vat.triangle_count(head.data)
    source_triangles = trunk_triangles + head_triangles
    if not RECIPE.triangle_budget[0] <= source_triangles <= RECIPE.triangle_budget[1]:
        raise ValueError(
            "flower tree generated {} triangles, budget is {}..{}".format(
                source_triangles, *RECIPE.triangle_budget))

    glb_path = os.path.join(OUTPUT_DIR, "flower_tree.glb")
    _export(root, glb_path)
    glb_stats = _validate_glb(glb_path)
    if glb_stats["triangle_count"] != source_triangles:
        raise ValueError(
            "flower tree source has {} triangles but GLB has {}".format(
                source_triangles, glb_stats["triangle_count"]))

    # Include the pivot in the actual authored height while preserving the
    # head's local radial footprint.
    head_low = Vector((
        min(vertex.co.x for vertex in head.data.vertices),
        min(vertex.co.y for vertex in head.data.vertices),
        min(vertex.co.z for vertex in head.data.vertices),
    ))
    head_high = Vector((
        max(vertex.co.x for vertex in head.data.vertices),
        max(vertex.co.y for vertex in head.data.vertices),
        max(vertex.co.z for vertex in head.data.vertices),
    ))
    authored_height = max(
        max(vertex.co.z for vertex in trunk.data.vertices),
        HEAD_PIVOT_Z + head_high.z,
    )
    crown_radius = max(
        abs(head_low.x), abs(head_low.y),
        abs(head_high.x), abs(head_high.y))
    crown_collision_radius = max(4.65, crown_radius * 0.98)

    metadata = {
        "source": "blender_assets/source/flower_tree_asset.py",
        "generator_version": 2,
        "authored_height": round(authored_height, 6),
        "head_pivot": [0.0, HEAD_PIVOT_Z, 0.0],
        "head_normal": [0.0, 1.0, 0.0],
        "trunk_triangles": trunk_triangles,
        "head_triangles": head_triangles,
        "glb_vertex_count": glb_stats["glb_vertex_count"],
        "color_paint": "biome_paint/flower_tree_paint.png",
        "color_paint_size": [PAINT_SIZE, PAINT_SIZE],
        "color_paint_alpha": (
            "broad mip-safe night-emission mask; never used as transparency"),
        "paint_style": (
            "wavy bark grooves and knots; sepal midribs; layered petal veins, "
            "freckles and scallops; honeycomb seed cup and bright anthers"),
        "trunk_collision": {
            "radius": 0.78,
            "height": 7.15,
            "centre": [0.0, 3.575, 0.0],
        },
        "crown_collision": {
            "radius": round(crown_collision_radius, 4),
            "centre_from_pivot": [0.0, 0.48, 0.0],
        },
        "runtime_contract": {
            "mesh_nodes": ["FlowerTreeTrunk", "FlowerTreeHead"],
            "head_pivot": "FlowerTreeHeadPivot",
            "mesh_count": 2,
            "primitive_count": 2,
            "paint_texture": "biome_paint/flower_tree_paint.png",
            "emission_mask": "biome_paint/flower_tree_paint.png alpha",
            "skins": 0,
            "animations": 0,
            "ground_axis": "Godot/glTF +Y",
        },
    }
    json_path = os.path.join(OUTPUT_DIR, "flower_tree.json")
    with open(json_path, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(metadata, stream, indent=2)
        stream.write("\n")

    _preview_with_paint(material, paint_image)
    _preview_ground()
    full_preview = _render_preview(
        "flower_tree",
        Vector((12.5, -16.0, 9.6)),
        Vector((0.0, 0.0, 4.45)),
        12.4,
    )
    crown_preview = _render_preview(
        "flower_tree_crown",
        Vector((8.2, -11.5, 10.8)),
        Vector((0.0, 0.0, HEAD_PIVOT_Z + 0.45)),
        9.6,
    )

    print("  trunk: {} triangles, head: {} triangles".format(
        trunk_triangles, head_triangles))
    print("  authored height: {:.3f} m, crown radius: {:.3f} m".format(
        authored_height, crown_radius))
    print("  GLB: {:.1f} KB, paint: {:.1f} KB".format(
        os.path.getsize(glb_path) / 1024.0,
        os.path.getsize(paint_path) / 1024.0))
    print("  previews: {}, {}".format(
        os.path.basename(full_preview), os.path.basename(crown_preview)))
    print("flower tree v2 build complete")


if __name__ == "__main__":
    main()
