"""Build the rigged and VAT Meep assets from the immutable MeshMaker sculpt.

Run from the repository root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_meep.py

The source blend is geometry input only.  This recipe hashes it before opening,
never saves over it, and verifies the hash again after every output has been
written.  The editable work blend carries the measured humanoid rig and four NLA
clips.  Runtime output includes that skeletal reference plus one validated
position VAT set per clip for the settlement's MultiMesh presentation.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
import sys
from typing import Iterable

import bpy
from mathutils import Matrix, Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_biome_assets as biome
import build_vat


NAME = "meep"
DISPLAY_NAME = "Meep Settler"
SRC_BLEND = os.path.join(
    ROOT, "assets", "source", "meshmaker", "meep.blend")
OUT_BLEND = os.path.join(ROOT, "assets", "work", "meep_rigged.blend")
OUT_GLB = os.path.join(
    ROOT, "assets", "runtime", "meeps", "models", "meep.glb")
PAINT_PNG = os.path.join(
    ROOT, "assets", "runtime", "biomes", "paint", "meep_paint.png")
VAT_DIR = os.path.join(ROOT, "assets", "runtime", "vat")
MANIFEST = os.path.join(
    ROOT, "assets", "runtime", "meeps", "manifests", "meep_assets.json")
PREVIEW_DIR = os.path.join(ROOT, "assets", "previews", "meeps")

TARGET_HEIGHT = 1.20
TARGET_TRIANGLES = 2800
TRIANGLE_BUDGET = (2400, 3200)
FPS = 30
SEED = 20268135
PAINT_SIZE = 256
EMISSION_STRENGTH = 1.45
EXPECTED_SOURCE_SHA256 = (
    "0370bf52f9f7d2b54ad8b4a587f255dd38411f1082c96198d0187fe5f286044c")

# Bright source colours are intentional: the runtime multiplies the paint PNG
# by COLOR_0.  Each stream therefore contributes a restrained part of the final
# shade rather than either one being a complete flat material.
PALETTE = tuple(map(biome._rgba, (
    "C6D5A5",  # 0 sage body
    "FFF1C5",  # 1 cream face, bib, palms and soles
    "86D3BE",  # 2 teal cuffs and ankle rings
    "9AF2EE",  # 3 cyan facial marks and night glyphs
    "839872",  # 4 deep sage lower limbs and dorsal bands
)))
PAINT_STYLE = (
    "broad sage body bands, a cream face and belly bib, teal wrist and ankle "
    "rings, deep-sage lower limbs, and large cyan cheek glyphs whose mip-safe "
    "centres provide the PNG-alpha night-emission mask"
)
EMISSION_STYLE = (
    "paired cyan cheek glyphs and the centre of each teal cuff glow softly "
    "after local sunset"
)
REQUIRED_BONES = (
    "Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
    "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
    "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
)
REQUIRED_CLIPS = ("Idle", "Walk", "Run", "Build")
CLIP_FRAMES = {"Idle": 90, "Walk": 30, "Run": 20, "Build": 30}

# Measured from the 1.2 m source.  The sculpt has a T rest, +Y-facing toes, a
# broad head and short legs.  Bilateral landmarks are averaged and mirrored so
# scan noise does not make the two halves animate differently.
BONE_SPECS = (
    # name, parent, head, tail, connected
    ("Root", None, (0.0, 0.0, 0.000), (0.0, 0.0, 0.100), False),
    ("Hips", "Root", (0.0, -0.030, 0.420), (0.0, -0.055, 0.500), False),
    ("Spine", "Hips", (0.0, -0.055, 0.500), (0.0, -0.049, 0.580), True),
    ("Chest", "Spine", (0.0, -0.049, 0.580), (0.0, -0.007, 0.660), True),
    ("UpperChest", "Chest", (0.0, -0.007, 0.660),
     (0.0, -0.048, 0.880), True),
    ("Neck", "UpperChest", (0.0, -0.048, 0.880),
     (0.0, -0.045, 0.960), True),
    ("Head", "Neck", (0.0, -0.045, 0.960),
     (0.0, 0.011, 1.180), True),
    ("LeftShoulder", "UpperChest", (-0.040, -0.010, 0.680),
     (-0.155, 0.003, 0.650), False),
    ("LeftUpperArm", "LeftShoulder", (-0.155, 0.003, 0.650),
     (-0.300, 0.016, 0.615), True),
    ("LeftLowerArm", "LeftUpperArm", (-0.300, 0.016, 0.615),
     (-0.430, 0.030, 0.624), True),
    ("LeftHand", "LeftLowerArm", (-0.430, 0.030, 0.624),
     (-0.495, 0.024, 0.632), True),
    ("RightShoulder", "UpperChest", (0.040, -0.010, 0.680),
     (0.155, 0.003, 0.650), False),
    ("RightUpperArm", "RightShoulder", (0.155, 0.003, 0.650),
     (0.300, 0.016, 0.615), True),
    ("RightLowerArm", "RightUpperArm", (0.300, 0.016, 0.615),
     (0.430, 0.030, 0.624), True),
    ("RightHand", "RightLowerArm", (0.430, 0.030, 0.624),
     (0.495, 0.024, 0.632), True),
    ("LeftUpperLeg", "Hips", (-0.100, -0.034, 0.430),
     (-0.095, 0.010, 0.250), False),
    ("LeftLowerLeg", "LeftUpperLeg", (-0.095, 0.010, 0.250),
     (-0.100, 0.018, 0.115), True),
    ("LeftFoot", "LeftLowerLeg", (-0.100, 0.018, 0.115),
     (-0.105, 0.050, 0.055), True),
    ("LeftToes", "LeftFoot", (-0.105, 0.050, 0.055),
     (-0.105, 0.086, 0.025), True),
    ("RightUpperLeg", "Hips", (0.100, -0.034, 0.430),
     (0.095, 0.010, 0.250), False),
    ("RightLowerLeg", "RightUpperLeg", (0.095, 0.010, 0.250),
     (0.100, 0.018, 0.115), True),
    ("RightFoot", "RightLowerLeg", (0.100, 0.018, 0.115),
     (0.105, 0.050, 0.055), True),
    ("RightToes", "RightFoot", (0.105, 0.050, 0.055),
     (0.105, 0.086, 0.025), True),
)


def load_sibling(filename: str, suffix: str):
    path = os.path.join(SOURCE_DIR, filename)
    spec = importlib.util.spec_from_file_location(
        os.path.splitext(filename)[0] + suffix, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def activate(obj: bpy.types.Object) -> None:
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for other in bpy.context.view_layer.objects:
        if other is not None:
            other.select_set(False)
    obj.hide_viewport = False
    obj.hide_render = False
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def file_sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def triangle_count(mesh: bpy.types.Mesh) -> int:
    return sum(max(len(polygon.vertices) - 2, 0)
               for polygon in mesh.polygons)


def mesh_bounds(mesh_obj: bpy.types.Object) -> tuple[Vector, Vector]:
    points = [mesh_obj.matrix_world @ vertex.co
              for vertex in mesh_obj.data.vertices]
    low = Vector(tuple(min(point[axis] for point in points)
                       for axis in range(3)))
    high = Vector(tuple(max(point[axis] for point in points)
                        for axis in range(3)))
    return low, high


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def smoothstep(low: float, high: float, value: float) -> float:
    if high <= low:
        return 1.0 if value >= high else 0.0
    share = clamp01((value - low) / (high - low))
    return share * share * (3.0 - 2.0 * share)


def mix(first, second, share: float):
    amount = clamp01(share)
    return tuple(first[index] * (1.0 - amount) + second[index] * amount
                 for index in range(4))


def source_mesh() -> bpy.types.Object:
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh in " + SRC_BLEND)
    return max(meshes, key=lambda obj: len(obj.data.vertices))


def normalize_source() -> tuple[bpy.types.Object, str]:
    if not os.path.isfile(SRC_BLEND):
        raise SystemExit("Meep source is missing: " + SRC_BLEND)
    source_hash = file_sha256(SRC_BLEND)
    if source_hash.lower() != EXPECTED_SOURCE_SHA256:
        raise SystemExit(
            "Meep source hash changed; inspect and intentionally update the recipe: "
            + source_hash)
    bpy.ops.wm.open_mainfile(filepath=SRC_BLEND)
    mesh_obj = source_mesh()
    if mesh_obj.data.color_attributes.get("Color") is None:
        raise SystemExit("Meep source must carry its MeshMaker Color attribute")

    low, high = mesh_bounds(mesh_obj)
    source_height = high.z - low.z
    scale = TARGET_HEIGHT / source_height
    transformed = [
        Matrix.Scale(scale, 4) @ (mesh_obj.matrix_world @ vertex.co)
        for vertex in mesh_obj.data.vertices
    ]
    transformed_low = Vector(tuple(min(point[axis] for point in transformed)
                                   for axis in range(3)))
    transformed_high = Vector(tuple(max(point[axis] for point in transformed)
                                    for axis in range(3)))
    offset = Vector((
        -(transformed_low.x + transformed_high.x) * 0.5,
        0.0,
        -transformed_low.z,
    ))
    for vertex, point in zip(mesh_obj.data.vertices, transformed):
        vertex.co = point + offset
    mesh_obj.data.update()
    mesh_obj.parent = None
    mesh_obj.matrix_parent_inverse = Matrix.Identity(4)
    mesh_obj.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh_obj.modifiers):
        mesh_obj.modifiers.remove(modifier)
    mesh_obj.vertex_groups.clear()
    for obj in list(bpy.data.objects):
        if obj is not mesh_obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    mesh_obj.name = "Character"
    mesh_obj.data.name = "MeepMesh"
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    scene.render.fps = FPS
    print("source: {} verts, {} tris, {:.3f} m; sha256={}".format(
        len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
        source_height, source_hash))
    return mesh_obj, source_hash


def optimize(mesh_obj: bpy.types.Object) -> None:
    before = triangle_count(mesh_obj.data)
    modifier = mesh_obj.modifiers.new("MeepNearBudget", "DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = TARGET_TRIANGLES / float(before)
    modifier.use_collapse_triangulate = True
    activate(mesh_obj)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    after = triangle_count(mesh_obj.data)
    minimum, maximum = TRIANGLE_BUDGET
    if not minimum <= after <= maximum:
        raise SystemExit(
            "Meep has {} triangles, budget is {}..{}".format(
                after, minimum, maximum))
    for polygon in mesh_obj.data.polygons:
        polygon.use_smooth = True
    mesh_obj.data.update()
    print("optimize: {} -> {} tris, {} verts".format(
        before, after, len(mesh_obj.data.vertices)))


def build_armature() -> bpy.types.Object:
    armature = bpy.data.armatures.new("CharacterSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, parent, head, tail, connected in BONE_SPECS:
        bone = armature.edit_bones.new(name)
        bone.head = Vector(head)
        bone.tail = Vector(tail)
        if parent is not None:
            bone.parent = armature.edit_bones[parent]
            bone.use_connect = connected
    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.bones["Root"].use_deform = False
    names = tuple(bone.name for bone in armature.bones)
    if names != REQUIRED_BONES:
        raise SystemExit("unexpected Meep bone order: " + repr(names))
    print("rig: {} bones, {} deforming".format(
        len(armature.bones),
        sum(1 for bone in armature.bones if bone.use_deform)))
    return rig


def point_segment_distance(point: Vector, head: Vector, tail: Vector) -> float:
    span = tail - head
    if span.length_squared < 1.0e-12:
        return (point - head).length
    share = clamp01((point - head).dot(span) / span.length_squared)
    return (point - head.lerp(tail, share)).length


def geometric_candidates(point: Vector) -> tuple[str, ...]:
    """Restrict a vertex to the anatomical chain occupying its region."""
    x, z = point.x, point.z
    side = "Left" if x < 0.0 else "Right"
    if abs(x) > 0.145 and 0.475 < z < 0.765:
        return (
            side + "Shoulder", side + "UpperArm",
            side + "LowerArm", side + "Hand", "UpperChest",
        )
    if z < 0.445 and abs(x) > 0.012:
        return (
            side + "UpperLeg", side + "LowerLeg",
            side + "Foot", side + "Toes", "Hips",
        )
    if z > 0.900:
        return ("UpperChest", "Neck", "Head")
    return ("Hips", "Spine", "Chest", "UpperChest")


def geometric_weights(mesh_obj: bpy.types.Object,
                      rig: bpy.types.Object) -> None:
    """Bind deterministically by distance inside anatomy-specific chains.

    Heat weights are deliberately avoided.  The source is one smooth connected
    shell with arms only a few centimetres from the torso and legs meeting at a
    narrow crotch, exactly where heat diffusion can cross-couple opposite limbs.
    Region-gated segment distances cannot claim a vertex from the wrong side.
    """
    bone_segments = {
        bone.name: (bone.head_local.copy(), bone.tail_local.copy())
        for bone in rig.data.bones if bone.use_deform
    }
    rows: list[dict[str, float]] = []
    soft = TARGET_HEIGHT * 0.022
    for vertex in mesh_obj.data.vertices:
        point = vertex.co
        weighted: list[tuple[str, float]] = []
        for name in geometric_candidates(point):
            head, tail = bone_segments[name]
            distance = point_segment_distance(point, head, tail)
            weight = 1.0 / ((distance * distance + soft * soft) ** 1.35)

            # Parent body bones blend only across the actual limb attachment.
            if name == "UpperChest":
                if abs(point.x) > 0.20:
                    weight *= 0.02
                elif abs(point.x) > 0.145:
                    weight *= 1.0 - smoothstep(0.145, 0.20, abs(point.x))
            elif name == "Hips" and point.z < 0.31:
                weight *= 0.02
            weighted.append((name, weight))
        kept = sorted(weighted, key=lambda item: item[1], reverse=True)[:4]
        total = sum(weight for _, weight in kept)
        if total <= 1.0e-12:
            raise SystemExit("geometric skin left vertex {} unweighted".format(
                vertex.index))
        rows.append({name: weight / total for name, weight in kept})

    mesh_obj.vertex_groups.clear()
    groups = {
        name: mesh_obj.vertex_groups.new(name=name)
        for name in REQUIRED_BONES if name != "Root"
    }
    counts = {name: 0 for name in groups}
    maximum_influences = 0
    worst_sum_error = 0.0
    for index, mapped in enumerate(rows):
        maximum_influences = max(maximum_influences, len(mapped))
        worst_sum_error = max(
            worst_sum_error, abs(sum(mapped.values()) - 1.0))
        for name, amount in mapped.items():
            groups[name].add([index], amount, "REPLACE")
            counts[name] += 1
    empty = [name for name, count in counts.items() if count == 0]
    if empty:
        raise SystemExit("geometric skin produced empty groups: "
                         + ", ".join(empty))
    if maximum_influences > 4 or worst_sum_error > 1.0e-6:
        raise SystemExit("invalid influence normalization")

    mesh_obj.parent = rig
    mesh_obj.matrix_parent_inverse = rig.matrix_world.inverted()
    modifier = mesh_obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    modifier.use_deform_preserve_volume = True
    print("skin: geometric, max influences={}, worst sum error={:.2e}".format(
        maximum_influences, worst_sum_error))
    print("  " + ", ".join("{}:{}".format(name, counts[name])
                           for name in groups))


def recipe() -> biome.AssetRecipe:
    return biome.AssetRecipe(
        NAME, "fauna", "glimmer", "meep", SEED, TARGET_HEIGHT, PALETTE,
        TRIANGLE_BUDGET,
        {
            "shape": "capsule",
            "radius": 0.35,
            "height": 0.70,
            "centre": [0.0, 0.39, 0.0],
        },
        PAINT_STYLE, EMISSION_STYLE, EMISSION_STRENGTH,
        roughness=0.58, smooth=True,
    )


def source_polygon_colour(mesh: bpy.types.Mesh,
                          polygon: bpy.types.MeshPolygon) -> tuple[float, ...]:
    attribute = mesh.color_attributes.get("Color")
    if attribute is None:
        return (0.5, 0.5, 0.5, 1.0)
    values = [attribute.data[index].color_srgb
              for index in polygon.loop_indices]
    return tuple(sum(value[axis] for value in values) / len(values)
                 for axis in range(4))


def region_of(centre: Vector, source_colour: tuple[float, ...]) -> int:
    x, y, z = centre
    red, green, blue = source_colour[:3]
    # Preserve the sculpt's paired cyan facial marks as a semantic region.
    if z > 0.98 and green > red * 1.18 and blue > red * 1.12:
        return 3
    # The bright source patches become the cream face/bib rather than being
    # flattened back into the body.
    if z > 0.93 and red + green + blue > 2.55:
        return 1
    if abs(x) > 0.425:
        return 1  # palms
    if 0.285 < abs(x) <= 0.425 and 0.49 < z < 0.72:
        return 2  # broad forearm cuffs
    if z < 0.105:
        return 1  # soles
    if 0.105 <= z < 0.235:
        return 2  # ankle rings
    if z < 0.40:
        return 4  # legs
    if y > 0.075 and 0.43 < z < 0.94 and abs(x) < 0.15:
        return 1  # cream front bib
    # One broad dorsal band remains readable from behind at gameplay distance.
    if y < -0.115 and 0.48 < z < 0.92:
        return 4
    return 0


def paint_regions(mesh_obj: bpy.types.Object,
                  asset: biome.AssetRecipe) -> dict[int, int]:
    mesh = mesh_obj.data
    regions = [
        region_of(polygon.center, source_polygon_colour(mesh, polygon))
        for polygon in mesh.polygons
    ]
    existing = mesh.color_attributes.get(biome.COLOR_ATTRIBUTE)
    if existing is not None:
        mesh.color_attributes.remove(existing)
    for layer in list(mesh.uv_layers):
        mesh.uv_layers.remove(layer)
    colour = mesh.color_attributes.new(
        name=biome.COLOR_ATTRIBUTE, type="BYTE_COLOR", domain="CORNER")
    paint_uv = mesh.uv_layers.new(name=biome.PAINT_UV_NAME)
    tally = {index: 0 for index in range(len(PALETTE))}
    for polygon, palette_index in zip(mesh.polygons, regions):
        tally[palette_index] += 1
        polygon.material_index = 0
        coordinates = [
            mesh.vertices[mesh.loops[loop].vertex_index].co
            for loop in polygon.loop_indices
        ]
        uvs = biome._polygon_paint_uvs(
            asset, polygon, coordinates, palette_index)
        for loop, uv in zip(polygon.loop_indices, uvs):
            coordinate = mesh.vertices[mesh.loops[loop].vertex_index].co
            colour.data[loop].color = biome._colour_value(
                PALETTE[palette_index], coordinate, TARGET_HEIGHT, SEED,
                palette_index)
            paint_uv.data[loop].uv = uv
    if min(tally.values()) <= 0:
        raise SystemExit("a Meep paint region claimed no polygons: "
                         + repr(tally))
    mesh.color_attributes.active_color_name = biome.COLOR_ATTRIBUTE
    mesh.color_attributes.render_color_index = 0
    mesh.uv_layers.active = paint_uv
    mesh.uv_layers.active_index = 0
    mesh.materials.clear()
    mesh.materials.append(biome._make_material(asset))
    mesh.update()
    print("paint regions: " + ", ".join(
        "{}:{}".format(index, tally[index]) for index in sorted(tally)))
    return tally


def paint_pixel(palette_index: int, u: float, v: float):
    base = PALETTE[palette_index]
    pale = mix(base, (1.0, 1.0, 1.0, 1.0), 0.28)
    deep = (base[0] * 0.58, base[1] * 0.62, base[2] * 0.58, 1.0)
    tau = math.tau
    phase = SEED * 0.00031 + palette_index * 0.17
    result = base
    emission = 0.0
    if palette_index == 0:
        # Two body-length waves make broad sage bands, not pixel-scale fur.
        bands = 0.5 + 0.5 * math.sin(
            tau * (v * 1.6 + 0.16 * math.sin(tau * (u + phase)) + phase))
        result = mix(result, deep, (1.0 - bands) * 0.28)
        result = mix(result, pale, bands * 0.18)
    elif palette_index == 1:
        # Cream regions get one soft central highlight and warm edges.
        centre = 1.0 - smoothstep(0.16, 0.48, abs(u - 0.5))
        edge = smoothstep(0.58, 0.96, abs(v * 2.0 - 1.0))
        result = mix(result, pale, centre * 0.30)
        result = mix(result, deep, edge * 0.14)
    elif palette_index == 2:
        # A thick cuff ring with a softly luminous centre survives every mip.
        ring = 1.0 - smoothstep(
            0.10, 0.30, abs(math.sin(tau * (v * 1.1 + phase))))
        result = mix(result, deep, (1.0 - ring) * 0.24)
        result = mix(result, pale, ring * 0.34)
        emission = 0.08 + ring * 0.34
    elif palette_index == 3:
        # Paired cheek-glyph islands, deliberately large and low-frequency.
        first = 1.0 - smoothstep(
            0.18, 0.36, math.hypot((u - 0.32) * 1.25, v - 0.52))
        second = 1.0 - smoothstep(
            0.18, 0.36, math.hypot((u - 0.68) * 1.25, v - 0.48))
        glyph = max(first, second)
        result = mix(deep, pale, 0.36 + glyph * 0.54)
        emission = 0.12 + glyph * 0.78
    else:
        # Lower limbs and dorsal band: wide diagonal sage chevrons.
        chevron = 0.5 + 0.5 * math.sin(
            tau * (u * 1.25 + v * 1.55 + phase))
        result = mix(result, deep, (1.0 - chevron) * 0.34)
        result = mix(result, PALETTE[0], chevron * 0.26)
    drift = 0.97 + 0.03 * math.sin(
        tau * (u * 0.7 + v * 0.45 + phase))
    return (
        clamp01(result[0] * drift),
        clamp01(result[1] * drift),
        clamp01(result[2] * drift),
        clamp01(emission),
    )


def write_paint_texture() -> bpy.types.Image:
    os.makedirs(os.path.dirname(PAINT_PNG), exist_ok=True)
    image = bpy.data.images.new(
        "meep_paint", width=PAINT_SIZE, height=PAINT_SIZE,
        alpha=True, float_buffer=False)
    try:
        image.colorspace_settings.name = "sRGB"
    except TypeError:
        pass
    count = len(PALETTE)
    gutter = biome.PAINT_GUTTER / (PAINT_SIZE / count)
    usable = max(1.0 - gutter * 2.0, 1.0e-5)
    pixels: list[float] = []
    for row in range(PAINT_SIZE):
        atlas_v = (row + 0.5) / PAINT_SIZE * count
        palette_index = min(int(atlas_v), count - 1)
        local_v = clamp01((atlas_v - palette_index - gutter) / usable)
        for column in range(PAINT_SIZE):
            pixels.extend(paint_pixel(
                palette_index, (column + 0.5) / PAINT_SIZE, local_v))
    image.pixels.foreach_set(pixels)
    image.filepath_raw = PAINT_PNG
    image.file_format = "PNG"
    image.save()
    if not os.path.isfile(PAINT_PNG) or os.path.getsize(PAINT_PNG) <= 0:
        raise SystemExit("Meep paint PNG was not written")
    print("paint: {} ({:.1f} KB)".format(
        os.path.basename(PAINT_PNG), os.path.getsize(PAINT_PNG) / 1024.0))
    return image


def wire_paint_material(material: bpy.types.Material,
                        image: bpy.types.Image) -> None:
    """Make the exported PBR material sample UV paint and semantic COLOR_0."""
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    colour = nodes.get("BiomeVertexColor")
    if principled is None or colour is None:
        raise SystemExit("Meep material lacks its paint inputs")
    for socket_name in ("Base Color", "Emission Color", "Emission",
                        "Emission Strength"):
        socket = principled.inputs.get(socket_name)
        if socket is not None:
            for link in list(socket.links):
                links.remove(link)
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "MeepColorPaint"
    texture.image = image
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"
    multiply = nodes.new("ShaderNodeMixRGB")
    multiply.name = "PaintTimesSemanticColor"
    multiply.blend_type = "MULTIPLY"
    multiply.inputs[0].default_value = 1.0
    links.new(texture.outputs["Color"], multiply.inputs[1])
    links.new(colour.outputs["Color"], multiply.inputs[2])
    links.new(multiply.outputs["Color"], principled.inputs["Base Color"])
    emission_socket = principled.inputs.get("Emission Color") \
        or principled.inputs.get("Emission")
    if emission_socket is not None:
        links.new(texture.outputs["Color"], emission_socket)
    strength = principled.inputs.get("Emission Strength")
    if strength is not None:
        scale = nodes.new("ShaderNodeMath")
        scale.name = "NightEmissionMask"
        scale.operation = "MULTIPLY"
        scale.inputs[1].default_value = EMISSION_STRENGTH
        links.new(texture.outputs["Alpha"], scale.inputs[0])
        links.new(scale.outputs[0], strength)
    material.diffuse_color = PALETTE[0]


def neutral_export_material() -> bpy.types.Material:
    """GLB-side material; the external .tres is the runtime paint authority.

    Embedding the same PNG in every VAT GLB makes Godot extract five redundant
    copies beside the models.  COLOR_0 and both UV sets remain in every GLB,
    while meep_surface.tres samples the single canonical PNG at runtime.
    """
    material = bpy.data.materials.get("MeepRuntimeOverride")
    if material is not None:
        return material
    material = bpy.data.materials.new("MeepRuntimeOverride")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    principled.inputs["Roughness"].default_value = 0.58
    colour = nodes.new("ShaderNodeVertexColor")
    colour.layer_name = biome.COLOR_ATTRIBUTE
    links.new(colour.outputs["Color"], principled.inputs["Base Color"])
    return material


def set_only_material(mesh: bpy.types.Mesh,
                      material: bpy.types.Material) -> list:
    original = list(mesh.materials)
    mesh.materials.clear()
    mesh.materials.append(material)
    return original


def restore_materials(mesh: bpy.types.Mesh, original: Iterable) -> None:
    mesh.materials.clear()
    for material in original:
        mesh.materials.append(material)


def meep_animations(anim):
    rot = anim.rot
    arm_hang = anim.arm_hang
    tau = math.tau

    def stride(pose: dict, phase: float, swing: float,
               knee: float, foot: float) -> None:
        for side, sign, offset in anim.SIDES:
            cycle = phase + offset
            reach = math.sin(cycle)
            lift = max(0.0, -math.cos(cycle)) ** 1.35
            pose[side + "UpperLeg"] = rot(("X", swing * reach))
            pose[side + "LowerLeg"] = rot(("X", -knee * lift))
            pose[side + "Foot"] = rot(
                ("X", foot * lift - swing * reach * 0.45))
            pose[side + "Toes"] = rot(("X", -foot * lift * 0.22))

    def idle_pose(t):
        breath = math.sin(t * tau)
        look = math.sin(t * tau * 0.5)
        pose = {
            "Hips": {"rot": [("Z", 0.8 * look)],
                     "loc": (0.0, 0.0, 0.006 * breath)},
            "Spine": rot(("X", 0.8 * breath), ("Z", -0.5 * look)),
            "Chest": rot(("X", -1.4 + 1.5 * breath)),
            "UpperChest": rot(("X", -0.8 + 1.0 * breath)),
            "Neck": rot(("X", -0.8 * breath), ("Z", 1.6 * look)),
            "Head": rot(("X", 0.7 * breath), ("Z", 3.0 * look)),
        }
        for side, sign, _ in anim.SIDES:
            arm_hang(pose, side, sign, out=18.0,
                     swing=1.5 * breath, flex=10.0 + 1.5 * breath)
            pose[side + "Hand"] = rot(("X", -4.0))
        stride(pose, 0.0, 0.0, 0.0, 0.0)
        return pose

    def walk_pose(t):
        phase = t * tau
        step = math.sin(phase)
        pose = {
            "Hips": {
                "rot": [("Z", 5.0 * step), ("Y", 2.2 * step)],
                "loc": (0.0, 0.0, -0.015 * (1.0 - math.cos(phase * 2.0)) * 0.5),
            },
            "Spine": rot(("Z", -3.2 * step)),
            "Chest": rot(("X", -2.0), ("Z", -2.2 * step)),
            "UpperChest": rot(("Z", -1.5 * step)),
            "Neck": rot(("X", 2.0), ("Z", 1.4 * step)),
            "Head": rot(("X", 2.0), ("Z", 2.0 * step)),
        }
        stride(pose, phase, 28.0, 38.0, 18.0)
        for side, sign, offset in anim.SIDES:
            arm_hang(pose, side, sign, out=17.0,
                     swing=-sign * 24.0 * step, flex=15.0)
        return pose

    def run_pose(t):
        phase = t * tau
        step = math.sin(phase)
        pose = {
            "Hips": {
                "rot": [("X", -5.0), ("Z", 3.5 * step)],
                "loc": (0.0, 0.0,
                        0.012 - 0.025 * (1.0 - math.cos(phase * 2.0)) * 0.5),
            },
            "Spine": rot(("X", -4.0), ("Z", -2.2 * step)),
            "Chest": rot(("X", -7.0), ("Z", -2.0 * step)),
            "UpperChest": rot(("X", -4.0)),
            "Neck": rot(("X", 8.0), ("Z", 1.4 * step)),
            "Head": rot(("X", 9.0), ("Z", 2.0 * step)),
        }
        stride(pose, phase, 42.0, 64.0, 26.0)
        for side, sign, offset in anim.SIDES:
            arm_hang(pose, side, sign, out=14.0,
                     swing=-sign * 38.0 * step, flex=34.0)
        return pose

    def build_pose(t):
        phase = t * tau
        # Raised at phase zero, fastest through the strike around 0.55, then a
        # slower recovery.  Smooth harmonics keep the duplicate endpoint exact.
        strike = 0.5 - 0.5 * math.cos(phase)
        impact = max(0.0, math.sin(phase)) ** 6
        recover = 0.5 + 0.5 * math.cos(phase)
        pose = {
            "Hips": {
                "rot": [("X", -5.0), ("Z", 1.5 * math.sin(phase))],
                "loc": (0.0, 0.0, -0.028 * impact),
            },
            "Spine": rot(("X", -8.0 - 3.0 * impact)),
            "Chest": rot(("X", -12.0 - 4.0 * impact)),
            "UpperChest": rot(("X", -8.0 - 3.0 * impact)),
            "Neck": rot(("X", 10.0 + 2.0 * impact)),
            "Head": rot(("X", 12.0 + 2.0 * impact)),
            "LeftUpperLeg": rot(("X", -4.0 * impact), ("Y", -4.0)),
            "RightUpperLeg": rot(("X", -4.0 * impact), ("Y", 4.0)),
            "LeftLowerLeg": rot(("X", -12.0 * impact)),
            "RightLowerLeg": rot(("X", -12.0 * impact)),
            "LeftFoot": rot(("X", 6.0 * impact)),
            "RightFoot": rot(("X", 6.0 * impact)),
        }
        lift = 42.0 * recover - 24.0 * strike
        for side, sign, _ in anim.SIDES:
            arm_hang(pose, side, sign, out=18.0,
                     swing=42.0 + lift, flex=38.0 + 28.0 * strike)
            # Yaw both arms toward Blender +Y so the hands meet around one
            # implied tool handle instead of reading as another locomotion pose.
            pose[side + "UpperArm"]["rot"].append(("Z", sign * 18.0))
            pose[side + "LowerArm"]["rot"].append(("Z", sign * 32.0))
            pose[side + "Hand"] = rot(
                ("X", -28.0 + 18.0 * strike),
                ("Z", -sign * (12.0 - 8.0 * strike)))
        return pose

    return [
        ("Idle", CLIP_FRAMES["Idle"], True, idle_pose),
        ("Walk", CLIP_FRAMES["Walk"], True, walk_pose),
        ("Run", CLIP_FRAMES["Run"], True, run_pose),
        ("Build", CLIP_FRAMES["Build"], True, build_pose),
    ]


def configure_animation_metrics(anim, rig: bpy.types.Object) -> None:
    bones = rig.data.bones
    anim.LEG_ROOT_HEIGHT = bones["LeftUpperLeg"].head_local.z
    anim.ANKLE_HEIGHT = bones["LeftFoot"].head_local.z
    anim.THIGH_LENGTH = bones["LeftUpperLeg"].length
    anim.SHIN_LENGTH = bones["LeftLowerLeg"].length

    def from_down(name: str) -> float:
        direction = (bones[name].tail_local
                     - bones[name].head_local).normalized()
        return math.degrees(math.acos(clamp01(
            (direction.dot(Vector((0.0, 0.0, -1.0))) + 1.0) * 0.5) * 2.0 - 1.0))

    anim.ARM_REST_OUT = from_down("LeftUpperArm")
    anim.FOREARM_REST_OUT = from_down("LeftLowerArm")
    anim.FOREARM_FLARE = max(
        0.0, anim.FOREARM_REST_OUT - anim.ARM_REST_OUT)
    anim.BODY_SCALE = TARGET_HEIGHT
    anim.STRIDE_SCALE = 1.0


def export_skeletal(rig: bpy.types.Object,
                    mesh_obj: bpy.types.Object) -> None:
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    original_materials = set_only_material(
        mesh_obj.data, neutral_export_material())
    activate(rig)
    mesh_obj.hide_viewport = False
    mesh_obj.hide_render = False
    mesh_obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    try:
        bpy.ops.export_scene.gltf(
            filepath=OUT_GLB,
            export_format="GLB",
            use_selection=True,
            export_apply=True,
            export_skins=True,
            export_animations=True,
            export_animation_mode="NLA_TRACKS",
            export_frame_range=False,
            export_force_sampling=True,
            export_yup=True,
            export_normals=True,
            export_texcoords=True,
            export_vertex_color="ACTIVE",
            export_all_vertex_colors=False,
            export_all_influences=False,
            export_cameras=False,
            export_lights=False,
        )
    finally:
        restore_materials(mesh_obj.data, original_materials)
    print("skeletal GLB: {} ({:.1f} KB)".format(
        OUT_GLB, os.path.getsize(OUT_GLB) / 1024.0))


def validate_skeletal_glb(expected_triangles: int) -> dict[str, int]:
    document, _binary = build_vat._read_glb(OUT_GLB)
    if len(document.get("skins", [])) != 1:
        raise SystemExit("Meep GLB must contain exactly one skin")
    animations = tuple(animation.get("name")
                       for animation in document.get("animations", []))
    if animations != REQUIRED_CLIPS:
        raise SystemExit("unexpected GLB animations: " + repr(animations))
    node_names = {node.get("name") for node in document.get("nodes", [])}
    missing_bones = set(REQUIRED_BONES) - node_names
    if missing_bones:
        raise SystemExit("GLB lost bones: " + repr(sorted(missing_bones)))
    triangles = 0
    vertices = 0
    primitives = 0
    for gltf_mesh in document.get("meshes", []):
        for primitive in gltf_mesh.get("primitives", []):
            primitives += 1
            attributes = primitive.get("attributes", {})
            missing = {
                "POSITION", "NORMAL", "COLOR_0", "TEXCOORD_0", "TEXCOORD_1",
                "JOINTS_0", "WEIGHTS_0",
            } - set(attributes)
            if missing:
                raise SystemExit(
                    "skeletal primitive missing " + repr(sorted(missing)))
            position = document["accessors"][attributes["POSITION"]]
            vertices += int(position["count"])
            if "indices" in primitive:
                triangles += int(
                    document["accessors"][primitive["indices"]]["count"]) // 3
    if triangles != expected_triangles:
        raise SystemExit(
            "skeletal GLB triangle count {} != {}".format(
                triangles, expected_triangles))
    if document.get("images") or document.get("textures"):
        raise SystemExit(
            "skeletal GLB embedded a duplicate of the canonical paint PNG")
    return {
        "primitive_count": primitives,
        "glb_vertex_count": vertices,
        "triangle_count": triangles,
    }


def validate_work(mesh_obj: bpy.types.Object,
                  rig: bpy.types.Object) -> None:
    low, high = mesh_bounds(mesh_obj)
    size = high - low
    mesh = mesh_obj.data
    if abs(low.z) > 0.002 or abs(size.z - TARGET_HEIGHT) > 0.004:
        raise SystemExit("Meep is not grounded and 1.2 m tall")
    if tuple(bone.name for bone in rig.data.bones) != REQUIRED_BONES:
        raise SystemExit("work blend bone order changed")
    if tuple(track.name for track in rig.animation_data.nla_tracks) \
            != REQUIRED_CLIPS:
        raise SystemExit("work blend NLA tracks changed")
    if [layer.name for layer in mesh.uv_layers] != [
            biome.PAINT_UV_NAME, build_vat.UV_ID_LAYER]:
        raise SystemExit("work mesh UV order must be PaintUV, VAT_ID")
    colour = mesh.color_attributes.get(biome.COLOR_ATTRIBUTE)
    if colour is None or colour.domain != "CORNER" \
            or colour.data_type != "BYTE_COLOR":
        raise SystemExit("work mesh lost semantic corner colors")
    worst_influences = 0
    worst_sum = 0.0
    for vertex in mesh.vertices:
        positive = [
            assignment.weight for assignment in vertex.groups
            if assignment.weight > 1.0e-7
        ]
        worst_influences = max(worst_influences, len(positive))
        worst_sum = max(worst_sum, abs(sum(positive) - 1.0))
    if worst_influences > 4 or worst_sum > 1.0e-4:
        raise SystemExit("work mesh weights are not normalized <=4")
    for name, frame_count in CLIP_FRAMES.items():
        action = bpy.data.actions.get(name)
        if action is None:
            raise SystemExit("missing action " + name)
        if tuple(round(value) for value in action.frame_range) \
                != (1, frame_count + 1):
            raise SystemExit("{} has unexpected frame range {}".format(
                name, tuple(action.frame_range)))
    print("work validation: {:.3f} x {:.3f} x {:.3f} m, floor={:+.5f}, "
          "{} verts/{} tris, UV0+UV1, COLOR_0, <=4 weights".format(
              size.x, size.y, size.z, low.z, len(mesh.vertices),
              triangle_count(mesh)))


def solo_clip(rig: bpy.types.Object, clip: str) -> None:
    rig.animation_data.action = None
    found = False
    for track in rig.animation_data.nla_tracks:
        track.mute = track.name != clip
        found = found or track.name == clip
    if not found:
        raise SystemExit("cannot solo missing NLA clip " + clip)


def bake_vat_clips(mesh_obj: bpy.types.Object,
                   rig: bpy.types.Object) -> dict[str, dict]:
    os.makedirs(VAT_DIR, exist_ok=True)
    records: dict[str, dict] = {}
    original_materials = set_only_material(
        mesh_obj.data, neutral_export_material())
    try:
        for clip in REQUIRED_CLIPS:
            solo_clip(rig, clip)
            frames = CLIP_FRAMES[clip]
            slug = clip.lower()
            node_name = "Meep{}VAT".format(clip)
            result = build_vat.bake(
                mesh_obj,
                range(1, frames + 1),
                fps=FPS,
                output_base=os.path.join(VAT_DIR, "meep_{}_vat".format(slug)),
                node_name=node_name,
                mesh_name=node_name + "Mesh",
                vertex_color_name=biome.COLOR_ATTRIBUTE,
                loop=True,
                loop_endpoint=frames + 1,
                loop_tolerance=2.5e-4,
            )
            document, _binary = build_vat._read_glb(result.glb_path)
            if document.get("images") or document.get("textures"):
                raise SystemExit(
                    "{} VAT embedded duplicate paint".format(clip))
            for gltf_mesh in document.get("meshes", []):
                for primitive in gltf_mesh.get("primitives", []):
                    missing = {"TEXCOORD_0", "TEXCOORD_1", "COLOR_0"} \
                        - set(primitive.get("attributes", {}))
                    if missing:
                        raise SystemExit(
                            "{} VAT lost {}".format(clip, sorted(missing)))
            records[clip] = {
                "glb": os.path.relpath(result.glb_path, ROOT).replace("\\", "/"),
                "positions": os.path.relpath(
                    result.exr_path, ROOT).replace("\\", "/"),
                "metadata": os.path.relpath(
                    result.json_path, ROOT).replace("\\", "/"),
                "source_vertices": result.vertex_count,
                "glb_vertices_after_corner_splits": result.glb_vertex_count,
                "triangles": result.triangle_count,
                "frames": result.frame_count,
                "texture_dimensions": [result.vertex_count, result.frame_count],
                "loop_endpoint_error": result.loop_endpoint_error,
            }
            static = bpy.data.objects.get(node_name)
            if static is not None:
                bpy.data.objects.remove(static, do_unlink=True)
    finally:
        restore_materials(mesh_obj.data, original_materials)
    return records


def render_pose(rig: bpy.types.Object, clip: str,
                share: float, path: str) -> None:
    solo_clip(rig, clip)
    track = rig.animation_data.nla_tracks.get(clip)
    strip = track.strips[0]
    frame = int(round(
        strip.frame_start + (strip.frame_end - strip.frame_start) * share))
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    bpy.context.scene.render.filepath = path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise SystemExit("preview did not produce " + path)


def render_previews(rig: bpy.types.Object,
                    mesh_obj: bpy.types.Object,
                    asset: biome.AssetRecipe) -> dict[str, str]:
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    solo_clip(rig, "Idle")
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    # The shared preview camera looks toward +Y from the rear.
    rig.rotation_euler.z += math.pi
    close = os.path.join(PREVIEW_DIR, "meep_close.png")
    biome._render_preview(mesh_obj, asset, close)
    build = os.path.join(PREVIEW_DIR, "meep_build.png")
    # Show the raised-tool anticipation; the opposite half of the same loop is
    # the down-strike, but reads too similarly to Idle in a still image.
    render_pose(rig, "Build", 0.15, build)
    camera = bpy.data.objects.get("BiomePreviewCamera")
    ground = bpy.data.objects.get("BiomePreviewGround")
    if camera is None:
        raise SystemExit("preview camera was not created")
    camera.data.ortho_scale *= 3.2
    if ground is not None:
        ground.scale.x = 3.5
        ground.scale.y = 3.5
    gameplay = os.path.join(PREVIEW_DIR, "meep_gameplay.png")
    render_pose(rig, "Idle", 0.0, gameplay)
    return {"close": close, "build": build, "gameplay": gameplay}


def write_manifest(source_hash: str,
                   mesh_obj: bpy.types.Object,
                   rig: bpy.types.Object,
                   glb_validation: dict[str, int],
                   vat_records: dict[str, dict],
                   previews: dict[str, str]) -> None:
    low, high = mesh_bounds(mesh_obj)
    manifest = {
        "schema": "meep_asset_manifest",
        "version": 1,
        "generator": "assets/source/blender/build_meep.py",
        "source": {
            "blend": "assets/source/meshmaker/meep.blend",
            "sha256": source_hash,
            "immutable": True,
        },
        "work_blend": "assets/work/meep_rigged.blend",
        "skeletal_reference": {
            "glb": "assets/runtime/meeps/models/meep.glb",
            "mesh_node": "Character",
            "vertices_after_corner_splits": glb_validation["glb_vertex_count"],
            "triangles": glb_validation["triangle_count"],
            "skins": 1,
            "bones": list(REQUIRED_BONES),
            "actions": [
                {
                    "name": name,
                    "fps": FPS,
                    "stored_cycle_frames": CLIP_FRAMES[name],
                    "duplicate_loop_endpoint_frame": CLIP_FRAMES[name] + 1,
                    "in_place": True,
                }
                for name in REQUIRED_CLIPS
            ],
        },
        "appearance": {
            "color_paint": "assets/runtime/biomes/paint/meep_paint.png",
            "paint_size": [PAINT_SIZE, PAINT_SIZE],
            "color_paint_style": PAINT_STYLE,
            "emission_style": EMISSION_STYLE,
            "emission_strength": EMISSION_STRENGTH,
            "runtime_material": "game/meeps/meep_surface.tres",
            "material_policy": (
                "GLBs retain COLOR_0, TEXCOORD_0 and TEXCOORD_1 but do not "
                "embed duplicate paint; apply the runtime material override"),
            "vertex_colour": "COLOR_0 semantic region colors",
            "color_paint_uv": "TEXCOORD_0 / PaintUV",
            "vat_vertex_id": "TEXCOORD_1 / VAT_ID",
            "emission_mask": "paint PNG alpha; never transparency",
        },
        "geometry": {
            "authored_height": round(high.z - low.z, 6),
            "bounds_blender": {
                "minimum": [round(float(value), 6) for value in low],
                "maximum": [round(float(value), 6) for value in high],
            },
            "source_vertices": len(mesh_obj.data.vertices),
            "triangles": triangle_count(mesh_obj.data),
            "triangle_budget": {
                "minimum": TRIANGLE_BUDGET[0],
                "maximum": TRIANGLE_BUDGET[1],
            },
            "maximum_skin_influences": 4,
            "ground_axis": "Godot/glTF +Y",
            "forward_axis": "Godot local -Z",
        },
        "vat": {
            "representation": "one independently validated VAT set per clip",
            "clips": vat_records,
            "normal_animation": (
                "static base-frame normals; production VAT is intended for "
                "population-distance MultiMeshes, while the skeletal reference "
                "retains evaluated normals for close inspection"
            ),
        },
        "previews": {
            key: os.path.relpath(path, ROOT).replace("\\", "/")
            for key, path in previews.items()
        },
        "runtime_resources": {
            "idle": "game/meeps/meep_idle_vat.tres",
            "walk": "game/meeps/meep_walk_vat.tres",
            "run": "game/meeps/meep_run_vat.tres",
            "build": "game/meeps/meep_build_vat.tres",
        },
    }
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print("manifest: " + MANIFEST)


def main() -> None:
    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    mesh_obj, source_hash = normalize_source()
    optimize(mesh_obj)
    rig = build_armature()
    geometric_weights(mesh_obj, rig)
    asset = recipe()
    paint_regions(mesh_obj, asset)
    # UV order is contract-significant: PaintUV first, VAT_ID second.
    build_vat.assign_vertex_ids_to_uv2(mesh_obj.data)
    image = write_paint_texture()
    wire_paint_material(mesh_obj.data.materials[0], image)

    anim = load_sibling("build_animations.py", "_meep")
    configure_animation_metrics(anim, rig)
    animations = meep_animations(anim)
    if tuple(spec[0] for spec in animations) != REQUIRED_CLIPS:
        raise SystemExit("Meep animation table is incomplete")
    anim.ANIMATIONS = animations
    anim.export = export_skeletal
    anim.bake_into_open_file(OUT_BLEND, OUT_GLB)

    validate_work(mesh_obj, rig)
    glb_validation = validate_skeletal_glb(triangle_count(mesh_obj.data))
    vat_records = bake_vat_clips(mesh_obj, rig)
    previews = render_previews(rig, mesh_obj, asset)
    write_manifest(
        source_hash, mesh_obj, rig, glb_validation, vat_records, previews)
    for key in sorted(previews):
        print("preview {}: {}".format(key, previews[key]))
    after_hash = file_sha256(SRC_BLEND)
    if after_hash != source_hash:
        raise SystemExit("immutable Meep source changed during build")
    print("source preserved: sha256=" + source_hash)


if __name__ == "__main__":
    main()
