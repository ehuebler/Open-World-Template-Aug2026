"""Build the runtime Aurora-Fleece Alpaca from the read-only MeshMaker sculpt.

Run from the project root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_alpaca.py

The source is a fluffy, -Y-facing quadruped sculpt on MeshMaker's two-bone rig,
which carries no usable skin. This recipe opens it read-only, turns it to Blender
+Y (Godot -Z), fits it to a herd-sized triangle budget, and builds a nineteen-bone
quadruped skeleton measured off the sculpt itself, so the legs, neck, and head
bend where the animal is actually jointed.

Two contracts are shared with the rest of the library. Animations are authored
here but baked and exported by build_animations.py, so every project character
uses one per-frame, world-axis pose format and one NLA export path. Colour comes
from the fauna population-art contract: semantic COLOR_0 regions, TEXCOORD_0
paint UVs into a palette atlas, and one deterministic external PNG whose alpha is
the night-emission mask.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_biome_assets as biome

NAME = "aurora_fleece_alpaca"
DISPLAY_NAME = "Aurora-Fleece Alpaca"
SRC_BLEND = os.path.join(
    ROOT, "assets", "source", "meshmaker", "alpaca.blend")
OUT_BLEND = os.path.join(ROOT, "assets", "work", "alpaca_rigged.blend")
OUT_GLB = os.path.join(
    ROOT, "assets", "runtime", "fauna", "models", NAME + ".glb")
PAINT_PNG = os.path.join(
    ROOT, "assets", "runtime", "biomes", "paint", NAME + "_paint.png")
MANIFEST = os.path.join(
    ROOT, "assets", "runtime", "fauna", "manifests", "fauna_assets.json")
PREVIEW_DIR = os.path.join(ROOT, "assets", "previews", "fauna")

TARGET_HEIGHT = 1.30
TARGET_TRIANGLES = 7000
TRIANGLE_BUDGET = (4200, 7200)
FPS = 30
SEED = 20268133
PAINT_SIZE = 512
EMISSION_STRENGTH = 1.55

# Authored bright, because the runtime multiplies this paint by the semantic
# COLOR_0 built from the same palette. Both together land on the intended shade.
PALETTE = tuple(map(biome._rgba, (
    "D6C2F4",  # 0 fleece: pale lilac wool
    "3FC2E6",  # 1 saddle: aurora blue over the topline
    "F6E8CF",  # 2 face: cream muzzle, brow, and throat
    "585CD2",  # 3 socks: indigo lower legs and hooves
    "7CF7D8",  # 4 glow: luminous flank rosettes and eye ring
    "FF7CC8",  # 5 plume: tail and rump sweep
)))
PAINT_STYLE = (
    "pale lilac fleece streaks, a broad aurora-blue saddle over the topline, "
    "cream face and throat, indigo socks, magenta tail plume, and mip-safe "
    "luminous flank rosettes carried in PNG alpha"
)
EMISSION_STYLE = "flank rosettes, eye ring, and tail plume glow after sunset"

REQUIRED_CLIPS = (
    "Idle", "Walk", "Run", "Graze", "Bound", "Strafe", "Spit", "HitReact",
    "Defeat",
)

# Measured off the normalized sculpt by _inspect_alpaca.py and expressed as
# shares of total height, so the skeleton follows the body if the target size
# ever changes. +Y is the head, +Z is up, and the feet sit on Z=0.
FRONT_FOOT_Y = 0.235
HIND_FOOT_Y = -0.410
FOOT_X = 0.131
LEG_TOP_Z = 0.245
KNEE_Z = 0.130
ANKLE_Z = 0.052

BONES = (
    # name, parent, head, tail, connected
    ("Root", None, (0.0, -0.05, 0.0), (0.0, -0.05, 0.12), False),
    ("Hips", "Root", (0.0, -0.30, 0.43), (0.0, -0.10, 0.45), False),
    ("Spine", "Hips", (0.0, -0.10, 0.45), (0.0, 0.08, 0.47), True),
    ("Chest", "Spine", (0.0, 0.08, 0.47), (0.0, 0.19, 0.55), True),
    ("Neck", "Chest", (0.0, 0.19, 0.57), (0.0, 0.37, 0.80), False),
    ("Head", "Neck", (0.0, 0.37, 0.80), (0.0, 0.72, 0.79), True),
    ("Tail", "Hips", (0.0, -0.56, 0.47), (0.0, -0.74, 0.45), False),
)
LEG_ENDS = (
    ("Front", FRONT_FOOT_Y, 0.045),
    ("Hind", HIND_FOOT_Y, 0.060),
)
SIDES = (("Left", -1.0), ("Right", 1.0))


def leg_bones() -> tuple:
    """Three bones per leg, planted under the measured foot cluster."""
    specs = []
    for end, foot_y, toe_reach in LEG_ENDS:
        for side, sign in SIDES:
            prefix = side + end
            hip_x = FOOT_X * sign * 0.92
            foot_x = FOOT_X * sign
            # Front legs stand slightly under the chest and hind legs slightly
            # behind the hip, which is where the sculpt's columns already are.
            hip_y = foot_y - 0.02 if end == "Front" else foot_y + 0.035
            specs.extend((
                (prefix + "UpperLeg", "Chest" if end == "Front" else "Hips",
                 (hip_x, hip_y, LEG_TOP_Z), (foot_x, foot_y, KNEE_Z), False),
                (prefix + "LowerLeg", prefix + "UpperLeg",
                 (foot_x, foot_y, KNEE_Z),
                 (foot_x, foot_y + 0.012, ANKLE_Z), True),
                (prefix + "Foot", prefix + "LowerLeg",
                 (foot_x, foot_y + 0.012, ANKLE_Z),
                 (foot_x, foot_y + toe_reach, 0.010), True),
            ))
    return tuple(specs)


ALL_BONES = BONES + leg_bones()
DEFORM_BONES = tuple(spec[0] for spec in ALL_BONES if spec[0] != "Root")
LEG_PREFIXES = tuple(
    side + end for end, _, _ in LEG_ENDS for side, _ in SIDES)


def metres(point) -> Vector:
    return Vector((point[0], point[1], point[2])) * TARGET_HEIGHT


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
    return sum(max(len(polygon.vertices) - 2, 0) for polygon in mesh.polygons)


def mesh_bounds(mesh_obj: bpy.types.Object) -> tuple[Vector, Vector]:
    points = [mesh_obj.matrix_world @ vertex.co
              for vertex in mesh_obj.data.vertices]
    low = Vector(tuple(min(point[axis] for point in points)
                       for axis in range(3)))
    high = Vector(tuple(max(point[axis] for point in points)
                        for axis in range(3)))
    return low, high


# --------------------------------------------------------------------------
# Source
# --------------------------------------------------------------------------

def normalize_source() -> tuple[bpy.types.Object, str]:
    """Open the sculpt read-only and return it turned, scaled, and grounded."""
    if not os.path.isfile(SRC_BLEND):
        raise SystemExit("alpaca source is missing: " + SRC_BLEND)
    source_hash = file_sha256(SRC_BLEND)
    bpy.ops.wm.open_mainfile(filepath=SRC_BLEND)

    mesh_obj = bpy.data.objects.get("geometry_0")
    if mesh_obj is None or mesh_obj.type != "MESH":
        raise SystemExit("geometry_0 mesh is missing from " + SRC_BLEND)
    if mesh_obj.data.color_attributes.get("Color") is None:
        raise SystemExit("the alpaca sculpt must carry a Color attribute")

    low, high = mesh_bounds(mesh_obj)
    source_height = high.z - low.z
    scale = TARGET_HEIGHT / source_height
    # The head projects toward source -Y. Blender +Y is Godot -Z, the direction
    # a creature actor faces, so bake that turn into the vertices.
    base = Matrix.Scale(scale, 4) @ Matrix.Rotation(math.pi, 4, "Z")
    turned = [base @ (mesh_obj.matrix_world @ vertex.co)
              for vertex in mesh_obj.data.vertices]
    turned_low = Vector(tuple(min(point[axis] for point in turned)
                              for axis in range(3)))
    turned_high = Vector(tuple(max(point[axis] for point in turned)
                               for axis in range(3)))
    offset = Vector((
        -(turned_low.x + turned_high.x) * 0.5,
        0.0,
        -turned_low.z,
    ))
    for vertex, point in zip(mesh_obj.data.vertices, turned):
        vertex.co = point + offset
    mesh_obj.data.update()
    mesh_obj.parent = None
    mesh_obj.matrix_parent_inverse = Matrix.Identity(4)
    mesh_obj.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh_obj.modifiers):
        mesh_obj.modifiers.remove(modifier)
    # MeshMaker's two-bone rig cannot pose a quadruped and its groups would be
    # mistaken for a skin, so the sculpt is taken on its own.
    mesh_obj.vertex_groups.clear()

    for obj in list(bpy.data.objects):
        if obj is not mesh_obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    mesh_obj.name = "Character"
    mesh_obj.data.name = "AlpacaMesh"
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    scene.render.fps = FPS

    print("source: {0} verts, {1} tris, {2:.3f} m; sha256={3}".format(
        len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
        source_height, source_hash))
    print("normalize: scale={0:.6f}, turn=180 deg, target={1:.3f} m".format(
        scale, TARGET_HEIGHT))
    return mesh_obj, source_hash


def optimize(mesh_obj: bpy.types.Object) -> None:
    before = triangle_count(mesh_obj.data)
    if before > TARGET_TRIANGLES:
        modifier = mesh_obj.modifiers.new("HerdBudget", "DECIMATE")
        modifier.decimate_type = "COLLAPSE"
        modifier.ratio = TARGET_TRIANGLES / float(before)
        modifier.use_collapse_triangulate = True
        activate(mesh_obj)
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    after = triangle_count(mesh_obj.data)
    minimum, maximum = TRIANGLE_BUDGET
    if not minimum <= after <= maximum:
        raise SystemExit("alpaca has {0} triangles, budget is {1}..{2}".format(
            after, minimum, maximum))
    for polygon in mesh_obj.data.polygons:
        polygon.use_smooth = True
    mesh_obj.data.update()
    print("optimize: {0} -> {1} tris, {2} verts".format(
        before, after, len(mesh_obj.data.vertices)))


# --------------------------------------------------------------------------
# Skeleton and skin
# --------------------------------------------------------------------------

def build_armature() -> bpy.types.Object:
    armature = bpy.data.armatures.new("CharacterSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, parent, head, tail, connected in ALL_BONES:
        bone = armature.edit_bones.new(name)
        bone.head = metres(head)
        bone.tail = metres(tail)
        if (bone.tail - bone.head).length < 1.0e-4:
            raise SystemExit(name + " has no length")
        if parent is not None:
            bone.parent = armature.edit_bones[parent]
            bone.use_connect = connected
    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")
    # Root only carries the body; posing it would slide the whole animal.
    armature.bones["Root"].use_deform = False
    print("rig: {0} bones, {1} deforming".format(
        len(armature.bones), len(DEFORM_BONES)))
    return rig


def side_and_end(group_name: str) -> tuple[float, str] | None:
    """Which quadrant a leg vertex group belongs to, or None for a body bone."""
    for end, _, _ in LEG_ENDS:
        for side, sign in SIDES:
            if group_name.startswith(side + end):
                return sign, end
    return None


def skin(mesh_obj: bpy.types.Object, rig: bpy.types.Object) -> None:
    """Heat-diffusion weights, then a deterministic clean-up of the legs.

    Automatic weights are the right tool for this sculpt: the source skin is two
    bones, and the fleece has no seams to guide an analytic falloff. What heat
    diffusion does get wrong on a barrel-bodied animal is reach — a foreleg bone
    catches belly and hind-leg wool across the gap between them — so every leg
    weight outside that leg's own quadrant is dropped and the vertex renormalized.
    """
    activate(mesh_obj)
    mesh_obj.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")

    groups = {group.name: group for group in mesh_obj.vertex_groups}
    missing = [name for name in DEFORM_BONES if name not in groups]
    if missing:
        raise SystemExit("automatic weights skipped: " + ", ".join(missing))

    # Halfway between the measured foot clusters: no foreleg owns wool behind it.
    split_y = (FRONT_FOOT_Y + HIND_FOOT_Y) * 0.5 * TARGET_HEIGHT
    band = TARGET_HEIGHT * 0.06
    rows: list[dict[str, float]] = []
    dropped = 0
    for vertex in mesh_obj.data.vertices:
        mapped: dict[str, float] = {}
        for assignment in vertex.groups:
            name = mesh_obj.vertex_groups[assignment.group].name
            amount = assignment.weight
            if amount <= 1.0e-6:
                continue
            limb = side_and_end(name)
            if limb is not None:
                sign, end = limb
                if vertex.co.x * sign < -band:
                    dropped += 1
                    continue
                if end == "Front" and vertex.co.y < split_y - band:
                    dropped += 1
                    continue
                if end == "Hind" and vertex.co.y > split_y + band:
                    dropped += 1
                    continue
            mapped[name] = mapped.get(name, 0.0) + amount
        kept = sorted(mapped.items(), key=lambda item: item[1],
                      reverse=True)[:4]
        total = sum(amount for _, amount in kept)
        if total < 1.0e-6:
            # Wool that lost every claim belongs to the body it hangs from.
            nearest = "Chest" if vertex.co.y > split_y else "Hips"
            kept = [(nearest, 1.0)]
            total = 1.0
        rows.append({name: amount / total for name, amount in kept})

    mesh_obj.vertex_groups.clear()
    rebuilt = {name: mesh_obj.vertex_groups.new(name=name)
               for name in DEFORM_BONES}
    counts = {name: 0 for name in DEFORM_BONES}
    for index, mapped in enumerate(rows):
        for name, amount in mapped.items():
            rebuilt[name].add([index], amount, "REPLACE")
            counts[name] += 1

    empty = [name for name, count in counts.items() if count == 0]
    if empty:
        raise SystemExit("unweighted bones: " + ", ".join(empty))
    print("skin: max 4 influences, {0} stray leg weights dropped".format(
        dropped))
    print("  " + ", ".join("{0}:{1}".format(name, counts[name])
                           for name in DEFORM_BONES))


# --------------------------------------------------------------------------
# Colour paint
# --------------------------------------------------------------------------

def recipe() -> biome.AssetRecipe:
    # "flyer" is chosen only for its paint projection: it is the archetype whose
    # polygons are projected on their dominant axis at a broad motif scale, which
    # is what a horizontal barrel body needs. A trunk-style cylindrical unwrap
    # would smear the atlas along the animal's length.
    return biome.AssetRecipe(
        NAME, "fauna", "flyer", "alpaca", SEED, TARGET_HEIGHT, PALETTE,
        TRIANGLE_BUDGET,
        {
            "shape": "capsule",
            "radius": 0.40,
            "height": 1.02,
            "centre": [0.0, 0.51, 0.0],
        },
        PAINT_STYLE, EMISSION_STYLE, EMISSION_STRENGTH,
        roughness=0.66, smooth=True,
    )


def region_of(centre: Vector) -> int:
    """Which semantic palette region one polygon belongs to."""
    x = centre.x / TARGET_HEIGHT
    y = centre.y / TARGET_HEIGHT
    z = centre.z / TARGET_HEIGHT

    if z < 0.17 and abs(x) > 0.055:
        return 3  # socks
    if y < -0.60:
        return 5  # tail plume
    if y > 0.30 and z > 0.66:
        # Cream over the muzzle, brow, and throat, with the luminous mark kept
        # to the crest between the ears instead of washing the whole face.
        if 0.40 < y < 0.62 and z > 0.88:
            return 4
        return 2
    if y > 0.12 and z > 0.50:
        return 2  # throat and chest front
    # A broad flank ring of rosettes, spaced along the body rather than dotted.
    if abs(x) > 0.21 and 0.24 < z < 0.50:
        wave = math.sin((y + 0.42) * math.tau * 1.35)
        if wave > 0.52:
            return 4
    if z > 0.43 and -0.56 < y < 0.30:
        return 1  # saddle blanket over the back and upper flanks
    return 0


def paint_regions(mesh_obj: bpy.types.Object,
                  asset: biome.AssetRecipe) -> dict[int, int]:
    mesh = mesh_obj.data
    existing = mesh.color_attributes.get(biome.COLOR_ATTRIBUTE)
    if existing is not None:
        mesh.color_attributes.remove(existing)
    for layer in list(mesh.uv_layers):
        mesh.uv_layers.remove(layer)
    colour = mesh.color_attributes.new(
        name=biome.COLOR_ATTRIBUTE, type="BYTE_COLOR", domain="CORNER")
    paint_uv = mesh.uv_layers.new(name=biome.PAINT_UV_NAME)

    tally: dict[int, int] = {index: 0 for index in range(len(PALETTE))}
    for polygon in mesh.polygons:
        palette_index = region_of(polygon.center)
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
    mesh.color_attributes.active_color_name = biome.COLOR_ATTRIBUTE
    mesh.color_attributes.render_color_index = 0
    mesh.uv_layers.active = paint_uv
    mesh.uv_layers.active_index = list(mesh.uv_layers).index(paint_uv)
    mesh.materials.clear()
    mesh.materials.append(biome._make_material(asset))
    mesh.update()
    print("paint regions: " + ", ".join(
        "{0}:{1}".format(index, tally[index]) for index in sorted(tally)))
    if min(tally.values()) <= 0:
        raise SystemExit("a palette region claimed no polygons")
    return tally


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


def paint_pixel(palette_index: int, u: float, v: float):
    """One motif of broad, mip-safe markings for one semantic region."""
    base = PALETTE[palette_index]
    pale = mix(base, (1.0, 1.0, 1.0, 1.0), 0.30)
    deep = (base[0] * 0.52, base[1] * 0.54, base[2] * 0.62, 1.0)
    tau = math.tau
    phase = SEED * 0.00041 + palette_index * 0.23
    result = base
    emission = 0.05

    if palette_index == 0:
        # Fleece: soft, wide fibre streaks that break up a flat body colour.
        fibre = 0.5 + 0.5 * math.sin(
            tau * (v * 2.0 + 0.18 * math.sin(tau * (u * 1.5 + phase)) + phase))
        clump = 0.5 + 0.5 * math.sin(tau * (u * 1.5 - v * 0.8 + phase * 1.4))
        result = mix(result, deep, (1.0 - fibre) * 0.22)
        result = mix(result, pale, fibre * clump * 0.30)
        emission = 0.04 + fibre * 0.06
    elif palette_index == 1:
        # Saddle: one broad band per motif, with a darker seam on its lower edge.
        band = math.sin(tau * (v * 0.75 + 0.10 * math.sin(tau * u) + phase))
        edge = 1.0 - smoothstep(0.10, 0.34, abs(band))
        result = mix(result, deep, clamp01(-band) * 0.42)
        result = mix(result, pale, clamp01(band) * 0.26)
        result = mix(result, PALETTE[4], edge * 0.34)
        emission = 0.08 + edge * 0.46
    elif palette_index == 2:
        # Face and throat: nearly plain cream with one soft blaze up the middle.
        blaze = 1.0 - smoothstep(0.16, 0.44, abs(u - 0.5))
        result = mix(result, pale, blaze * 0.42)
        result = mix(result, deep, smoothstep(0.62, 1.0, v) * 0.20)
        emission = 0.06 + blaze * 0.18
    elif palette_index == 3:
        # Socks: dark at the hoof, fading up, with two broad ankle rings.
        rise = smoothstep(0.0, 0.9, v)
        rings = 1.0 - smoothstep(
            0.06, 0.20, abs(math.sin(tau * (v * 1.5 + phase))))
        result = mix(result, deep, (1.0 - rise) * 0.55)
        result = mix(result, pale, rise * 0.22)
        result = mix(result, PALETTE[4], rings * 0.30)
        emission = 0.05 + rings * 0.40
    elif palette_index == 4:
        # Rosette: one soft disc per motif, well inside the band so minification
        # dims it evenly instead of breaking it into speckle.
        radius = math.hypot((u - 0.5) * 1.06, (v - 0.5) * 1.06)
        core = 1.0 - smoothstep(0.14, 0.34, radius)
        halo = 1.0 - smoothstep(0.30, 0.48, radius)
        result = mix(PALETTE[0], base, halo * 0.72)
        result = mix(result, pale, core * 0.70)
        emission = clamp01(0.10 + halo * 0.42 + core * 0.60)
    else:
        # Plume: sweeping chevrons down the tail and over the rump.
        sweep = abs(u - 0.5) * 1.7 + v * 1.5 + phase
        chevron = 1.0 - smoothstep(
            0.14, 0.34, abs((sweep - math.floor(sweep)) - 0.5))
        result = mix(result, deep, (1.0 - chevron) * 0.34)
        result = mix(result, pale, chevron * 0.34)
        emission = 0.08 + chevron * 0.52

    drift = 0.96 + 0.04 * math.sin(tau * (u * 0.8 + v * 0.6 + phase * 0.5))
    return (
        clamp01(result[0] * drift),
        clamp01(result[1] * drift),
        clamp01(result[2] * drift),
        clamp01(emission),
    )


def write_paint_texture() -> bpy.types.Image:
    """One deterministic PNG: an atlas band per semantic region, alpha is glow."""
    os.makedirs(os.path.dirname(PAINT_PNG), exist_ok=True)
    image = bpy.data.images.new(
        NAME + "_paint", width=PAINT_SIZE, height=PAINT_SIZE,
        alpha=True, float_buffer=False)
    try:
        image.colorspace_settings.name = "sRGB"
    except TypeError:
        pass
    count = len(PALETTE)
    # The same gutter share _polygon_paint_uvs reserves, so no motif is sampled
    # across a band seam once the texture is minified.
    gutter = biome.PAINT_GUTTER / (biome.PAINT_SIZE / count)
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
        raise SystemExit("colour paint did not produce " + PAINT_PNG)
    print("paint: {0} ({1:.1f} KB)".format(
        os.path.basename(PAINT_PNG), os.path.getsize(PAINT_PNG) / 1024.0))
    return image


# --------------------------------------------------------------------------
# Animation
# --------------------------------------------------------------------------

def alpaca_animations(anim):
    """Alpaca clips in build_animations.py's shared world-axis pose format."""
    rot = anim.rot
    tau = math.tau

    # Lateral four-beat walk, and diagonal pairs for the trot and the bound.
    walk_order = {
        "LeftHind": 0.0, "LeftFront": 0.25,
        "RightHind": 0.5, "RightFront": 0.75,
    }
    trot_order = {
        "LeftFront": 0.0, "RightHind": 0.0,
        "RightFront": 0.5, "LeftHind": 0.5,
    }
    bound_order = {
        "LeftFront": 0.0, "RightFront": 0.04,
        "LeftHind": 0.30, "RightHind": 0.34,
    }

    def ease(value):
        value = clamp01(value)
        return value * value * (3.0 - 2.0 * value)

    def pulse(t, start, peak, end):
        if t <= start or t >= end:
            return 0.0
        if t < peak:
            return ease((t - start) / max(peak - start, 1.0e-6))
        return 1.0 - ease((t - peak) / max(end - peak, 1.0e-6))

    def stride(pose, phase, order, swing, knee, foot, share=1.0):
        """Swing four legs from the hip, folding each as it leaves the ground."""
        for prefix, offset in order.items():
            leg = phase + offset * tau
            reach = math.sin(leg)
            # The fold peaks in the middle of the swing, when the foot is off
            # the ground, and returns to zero as the hoof is planted again.
            fold = max(0.0, -math.cos(leg)) ** 1.4
            # A carpus folds back under the animal, a hock folds forward.
            direction = -1.0 if prefix.endswith("Front") else 1.0
            pose[prefix + "UpperLeg"] = rot(("X", swing * reach * share))
            pose[prefix + "LowerLeg"] = rot(
                ("X", direction * knee * fold * share))
            pose[prefix + "Foot"] = rot(
                ("X", (foot * fold - swing * reach * 0.45) * share))

    def planted_legs(pose, drop, spread=0.0, fold=0.0):
        """All four legs taking a lowered body, for grazing and collapsing."""
        for prefix in LEG_PREFIXES:
            sign = -1.0 if prefix.startswith("Left") else 1.0
            direction = -1.0 if prefix.endswith("Front") else 1.0
            pose[prefix + "UpperLeg"] = rot(
                ("X", drop * (1.0 if prefix.endswith("Front") else -0.6)),
                ("Y", -sign * spread))
            pose[prefix + "LowerLeg"] = rot(("X", direction * fold))
            pose[prefix + "Foot"] = rot(("X", -direction * fold * 0.5))

    def idle_pose(t):
        breath = math.sin(t * tau)
        sway = math.sin(t * tau * 0.5)
        pose = {
            "Hips": {"rot": [("Z", 1.4 * sway)],
                     "loc": (0.0, 0.0, 0.004 * breath)},
            "Spine": rot(("X", 1.0 * breath), ("Z", -1.0 * sway)),
            "Chest": rot(("X", -1.2 + 1.4 * breath)),
            "Neck": rot(("X", 2.6 + 1.8 * breath), ("Z", 2.0 * sway)),
            "Head": rot(("X", -1.6 - 1.2 * breath), ("Z", 3.0 * sway)),
            "Tail": rot(("X", 4.0 * breath), ("Z", 9.0 * math.sin(t * tau * 1.5))),
        }
        stride(pose, 0.0, walk_order, 0.0, 0.0, 0.0)
        return pose

    def walk_pose(t):
        phase = t * tau
        pose = {}
        stride(pose, phase, walk_order, swing=17.0, knee=26.0, foot=12.0)
        # Two dips per cycle: one for each diagonal pair taking the weight.
        dip = -0.014 * (1.0 - math.cos(phase * 2.0)) * 0.5
        pose["Hips"] = {
            "rot": [("Z", 3.4 * math.sin(phase)), ("Y", 3.0 * math.sin(phase))],
            "loc": (0.004 * math.sin(phase), 0.0, dip),
        }
        pose["Spine"] = rot(("Z", -2.4 * math.sin(phase)))
        pose["Chest"] = rot(("X", -1.0), ("Z", -3.0 * math.sin(phase)))
        pose["Neck"] = rot(("X", 3.0 + 2.4 * math.sin(phase * 2.0)))
        pose["Head"] = rot(("X", -2.0 - 2.0 * math.sin(phase * 2.0)),
                           ("Z", 2.4 * math.sin(phase)))
        pose["Tail"] = rot(("Z", 12.0 * math.sin(phase)))
        return pose

    def run_pose(t):
        phase = t * tau
        pose = {}
        stride(pose, phase, trot_order, swing=31.0, knee=44.0, foot=20.0)
        dip = -0.030 * (1.0 - math.cos(phase * 2.0)) * 0.5
        pose["Hips"] = {
            "rot": [("X", -2.0), ("Z", 4.0 * math.sin(phase))],
            "loc": (0.0, 0.0, 0.016 + dip),
        }
        pose["Spine"] = rot(("X", 2.0), ("Z", -3.4 * math.sin(phase)))
        pose["Chest"] = rot(("X", -4.0))
        pose["Neck"] = rot(("X", -9.0 + 3.0 * math.sin(phase * 2.0)))
        pose["Head"] = rot(("X", 4.0 - 2.4 * math.sin(phase * 2.0)))
        pose["Tail"] = rot(("X", 16.0), ("Z", 16.0 * math.sin(phase * 2.0)))
        return pose

    def graze_pose(t):
        """Neck reached out and down, muzzle over the grass ahead of the hooves.

        The neck is one rigid bone from the withers, so folding it far enough to
        touch the ground swings the head back under the chest and the animal
        reads as collapsed rather than feeding. Extending it forward instead puts
        the muzzle a hand's width off the ground and well clear of the forelegs,
        which is the silhouette a grazing camelid actually makes. The animator
        blends into this from the walk, so the reach happens over the cross-fade.
        """
        nibble = math.sin(t * tau)
        sweep = math.sin(t * tau * 0.5)
        pose = {}
        planted_legs(pose, drop=-4.0, spread=4.0, fold=5.0)
        pose["Hips"] = {"rot": [("X", -2.0)],
                        "loc": (0.0, 0.0, -0.016)}
        pose["Spine"] = rot(("X", -4.0))
        pose["Chest"] = rot(("X", -8.0), ("Z", 2.0 * sweep))
        pose["Neck"] = rot(("X", -66.0 - 2.0 * nibble), ("Z", 5.0 * sweep))
        pose["Head"] = rot(("X", 10.0 - 6.0 * nibble), ("Z", 7.0 * sweep))
        pose["Tail"] = rot(("X", -6.0), ("Z", 7.0 * math.sin(t * tau * 1.5)))
        return pose

    def bound_pose(t):
        # One goat-like leap per cycle: gather, push off, tuck, land.
        push = pulse(t, 0.0, 0.22, 0.44)
        flight = pulse(t, 0.16, 0.50, 0.86)
        land = pulse(t, 0.78, 0.94, 1.0)
        pose = {}
        for prefix, offset in bound_order.items():
            # The front pair leads the hind pair through the arc, so the leap
            # reads as a rocking-horse bound rather than a hop on four springs.
            lead = pulse(t, offset, offset + 0.34, offset + 0.70)
            tuck = flight * (1.0 if prefix.endswith("Front") else 0.78)
            direction = -1.0 if prefix.endswith("Front") else 1.0
            pose[prefix + "UpperLeg"] = rot(
                ("X", 24.0 * push + 20.0 * lead * direction
                 - 30.0 * tuck * direction + 16.0 * land * direction))
            pose[prefix + "LowerLeg"] = rot(("X", direction * 62.0 * tuck))
            pose[prefix + "Foot"] = rot(("X", -direction * 24.0 * tuck))
        pose["Hips"] = {
            "rot": [("X", -9.0 * push + 7.0 * flight)],
            "loc": (0.0, 0.0,
                    -0.028 * push + 0.105 * flight - 0.034 * land),
        }
        pose["Spine"] = rot(("X", -6.0 * push + 5.0 * flight))
        pose["Chest"] = rot(("X", 8.0 * push - 4.0 * land))
        pose["Neck"] = rot(("X", 12.0 * push + 4.0 * flight - 10.0 * land))
        pose["Head"] = rot(("X", -6.0 * push + 2.0 * flight))
        pose["Tail"] = rot(("X", 22.0 * flight + 10.0 * push))
        return pose

    def strafe_pose(t):
        # Side-stepping trot, kept facing the threat: the body leans into the
        # circle and the head stays turned toward the middle of it.
        phase = t * tau
        pose = {}
        stride(pose, phase, trot_order, swing=15.0, knee=30.0, foot=13.0)
        for prefix in trot_order:
            sign = -1.0 if prefix.startswith("Left") else 1.0
            existing = pose[prefix + "UpperLeg"]["rot"]
            existing.append(("Y", -sign * (9.0 + 5.0 * math.sin(phase))))
        pose["Hips"] = {
            "rot": [("Y", -7.0), ("Z", 3.0 * math.sin(phase))],
            "loc": (0.0, 0.0, -0.012 * (1.0 - math.cos(phase * 2.0)) * 0.5),
        }
        pose["Spine"] = rot(("Y", -4.0))
        pose["Chest"] = rot(("Y", -3.0), ("X", -2.0))
        pose["Neck"] = rot(("X", 5.0), ("Z", -12.0))
        pose["Head"] = rot(("X", -3.0), ("Z", -16.0))
        pose["Tail"] = rot(("Z", 18.0 * math.sin(phase)))
        return pose

    def spit_pose(t):
        # Draws the head back over the withers, then throws it forward and lets
        # the neck recoil. Impact is at the top of the throw, near 0.45.
        draw = ease(t / 0.38)
        throw = ease((t - 0.38) / 0.20)
        settle = ease((t - 0.66) / 0.34)
        active = 1.0 - settle
        pose = {}
        planted_legs(pose, drop=-3.0 * active, spread=3.0 * active, fold=4.0)
        pose["Hips"] = {"rot": [("X", 3.0 * draw * active)],
                        "loc": (0.0, 0.012 * throw * active, 0.0)}
        pose["Spine"] = rot(("X", 5.0 * draw * active - 4.0 * throw * active))
        pose["Chest"] = rot(("X", 9.0 * draw * active - 12.0 * throw * active))
        pose["Neck"] = rot(
            ("X", 20.0 * draw * active - 34.0 * throw * active))
        pose["Head"] = rot(
            ("X", 14.0 * draw * active + 26.0 * throw * active))
        pose["Tail"] = rot(("X", 14.0 * draw * active))
        return pose

    def hit_react_pose(t):
        hit = math.sin(math.pi * clamp01(t))
        pose = {}
        planted_legs(pose, drop=-6.0 * hit, spread=6.0 * hit, fold=8.0 * hit)
        pose["Hips"] = {"rot": [("Z", -5.0 * hit), ("X", -7.0 * hit)],
                        "loc": (0.0, -0.012 * hit, -0.026 * hit)}
        pose["Spine"] = rot(("X", 9.0 * hit), ("Z", 6.0 * hit))
        pose["Chest"] = rot(("X", 7.0 * hit))
        pose["Neck"] = rot(("X", 16.0 * hit), ("Z", -8.0 * hit))
        pose["Head"] = rot(("X", -14.0 * hit), ("Z", -10.0 * hit))
        pose["Tail"] = rot(("X", -18.0 * hit))
        return pose

    def defeat_pose(t):
        buckle = ease(t / 0.42)
        limp = ease((t - 0.34) / 0.66)
        pose = {}
        planted_legs(pose, drop=-16.0 * buckle, spread=17.0 * buckle,
                     fold=48.0 * buckle)
        pose["Hips"] = {
            "rot": [("X", -12.0 * buckle), ("Z", -13.0 * limp)],
            "loc": (0.0, -0.012 * buckle, -0.135 * buckle),
        }
        pose["Spine"] = rot(("X", -9.0 * buckle), ("Z", 11.0 * limp))
        pose["Chest"] = rot(("X", -14.0 * buckle), ("Z", 8.0 * limp))
        pose["Neck"] = rot(("X", 10.0 * buckle - 44.0 * limp))
        pose["Head"] = rot(("X", 6.0 * buckle - 26.0 * limp))
        pose["Tail"] = rot(("X", -22.0 * limp))
        return pose

    return [
        ("Idle", 96, True, idle_pose),
        ("Walk", 34, True, walk_pose),
        ("Run", 22, True, run_pose),
        ("Graze", 120, True, graze_pose),
        ("Bound", 26, True, bound_pose),
        ("Strafe", 30, True, strafe_pose),
        ("Spit", 30, False, spit_pose),
        ("HitReact", 16, False, hit_react_pose),
        ("Defeat", 48, False, defeat_pose),
    ]


def export_runtime(rig: bpy.types.Object,
                   mesh_obj: bpy.types.Object) -> None:
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for obj in bpy.context.view_layer.objects:
        if obj is not None:
            obj.select_set(False)
    for obj in (rig, mesh_obj):
        obj.hide_viewport = False
        obj.hide_render = False
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
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
        # The runtime samples the paint PNG through TEXCOORD_0 and reads COLOR_0
        # as the semantic region mask, so both streams must survive the export.
        export_texcoords=True,
        export_vertex_color="ACTIVE",
        export_all_vertex_colors=False,
    )
    print("wrote {0} ({1:.1f} KB)".format(
        OUT_GLB, os.path.getsize(OUT_GLB) / 1024.0))


# --------------------------------------------------------------------------
# Previews, manifest, validation
# --------------------------------------------------------------------------

def preview_with_paint(material: bpy.types.Material,
                       image: bpy.types.Image) -> None:
    """Show the same PNG the game samples, with its alpha driving the glow."""
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    principled = nodes.get("Principled BSDF")
    if principled is None:
        raise SystemExit("preview material has no Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "BiomeColorPaint"
    texture.image = image
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"
    for socket_name in ("Base Color", "Emission Color", "Emission"):
        socket = principled.inputs.get(socket_name)
        if socket is None:
            continue
        for link in list(socket.links):
            links.remove(link)
        links.new(texture.outputs["Color"], socket)
    strength = principled.inputs.get("Emission Strength")
    if strength is not None:
        multiplier = nodes.new("ShaderNodeMath")
        multiplier.operation = "MULTIPLY"
        multiplier.inputs[1].default_value = EMISSION_STRENGTH
        links.new(texture.outputs["Alpha"], multiplier.inputs[0])
        links.new(multiplier.outputs[0], strength)


def render_pose(rig: bpy.types.Object, clip: str, share: float,
                path: str) -> None:
    """Render one frame of one clip, so a bake can be judged without the game.

    The clip is chosen by soloing its NLA track rather than by assigning its
    action, because the exported tracks are the authority on what the game will
    play, and because reading one back through the action slot API would be
    testing a different path from the one that shipped.
    """
    strip = None
    for track in rig.animation_data.nla_tracks:
        track.mute = track.name != clip
        if track.name == clip and track.strips:
            strip = track.strips[0]
    if strip is None:
        raise SystemExit("no baked NLA track named " + clip)
    rig.animation_data.action = None
    bpy.context.scene.frame_set(int(round(
        strip.frame_start
        + (strip.frame_end - strip.frame_start) * clamp01(share))))
    bpy.context.view_layer.update()
    bpy.context.scene.render.filepath = path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(path):
        raise SystemExit("pose preview did not produce " + path)


def render_previews(rig: bpy.types.Object, mesh_obj: bpy.types.Object,
                    asset: biome.AssetRecipe,
                    image: bpy.types.Image) -> dict[str, str]:
    preview_with_paint(mesh_obj.data.materials[0], image)
    # The shared preview camera looks toward Blender +Y from the rear, and the
    # alpaca faces +Y, so turn the animal to meet it.
    rig.rotation_euler.z += math.pi
    close_path = os.path.join(PREVIEW_DIR, NAME + "_close.png")
    biome._render_preview(mesh_obj, asset, close_path)
    written = {"close": close_path}

    camera = bpy.data.objects.get("BiomePreviewCamera")
    ground = bpy.data.objects.get("BiomePreviewGround")
    for clip, share, key in (
            ("Graze", 0.5, "graze"),
            ("Bound", 0.45, "bound"),
            ("Run", 0.25, "run"),
            ("Spit", 0.5, "spit"),
    ):
        path = os.path.join(PREVIEW_DIR, "{0}_{1}.png".format(NAME, key))
        render_pose(rig, clip, share, path)
        written[key] = path

    if camera is not None:
        camera.data.ortho_scale *= 3.2
    if ground is not None:
        ground.scale.x = 3.5
        ground.scale.y = 3.5
    # Standing at rest, from the distance the herd is normally seen at, which is
    # the view the paint has to hold together in. Soloing Idle rather than
    # unmuting everything: nine tracks at once blend into a heap.
    gameplay_path = os.path.join(PREVIEW_DIR, NAME + "_gameplay.png")
    render_pose(rig, "Idle", 0.0, gameplay_path)
    written["gameplay"] = gameplay_path
    return written


def merge_manifest(mesh_obj: bpy.types.Object,
                   rig: bpy.types.Object) -> None:
    """Record this asset beside the procedurally generated fauna entries."""
    manifest: dict = {}
    if os.path.isfile(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as handle:
            manifest = json.load(handle)
    assets = manifest.setdefault("assets", {})
    low, high = mesh_bounds(mesh_obj)
    assets[NAME] = {
        "name": NAME,
        "display_name": DISPLAY_NAME,
        "category": "land_fauna",
        "form": "alpaca",
        "seed": SEED,
        "generator": "assets/source/blender/build_alpaca.py",
        "source_sculpt": "assets/source/meshmaker/alpaca.blend",
        "work_blend": "assets/work/alpaca_rigged.blend",
        "glb": "assets/runtime/fauna/models/{0}.glb".format(NAME),
        "color_paint": (
            "assets/runtime/biomes/paint/{0}_paint.png".format(NAME)),
        "close_preview": "assets/previews/fauna/{0}_close.png".format(NAME),
        "gameplay_distance_preview": (
            "assets/previews/fauna/{0}_gameplay.png".format(NAME)),
        "authored_height": round(high.z - low.z, 6),
        "triangle_count": triangle_count(mesh_obj.data),
        "collision_hint": recipe().collision_hint,
        "color_paint_style": PAINT_STYLE,
        "emission_style": EMISSION_STYLE,
        "emission_strength": EMISSION_STRENGTH,
        "runtime_contract": {
            "mesh_node": "Character",
            "vertex_colour": "COLOR_0 semantic region colors",
            "color_paint_uv": "TEXCOORD_0",
            "emission_mask": (
                "assets/runtime/biomes/paint/{0}_paint.png alpha; "
                "never transparency".format(NAME)),
            "ground_axis": "Godot/glTF +Y",
            "forward_axis": "Godot local -Z",
            "skins": 1,
            "bones": len(rig.data.bones),
            "animations": list(REQUIRED_CLIPS),
        },
        "file_size_bytes": os.path.getsize(OUT_GLB),
        "paint_size_bytes": os.path.getsize(PAINT_PNG),
    }
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print("recorded {0} in {1}".format(NAME, MANIFEST))


def validate(mesh_obj: bpy.types.Object, rig: bpy.types.Object) -> None:
    low, high = mesh_bounds(mesh_obj)
    size = high - low
    mesh = mesh_obj.data
    clips = tuple(track.name for track in rig.animation_data.nla_tracks)
    if clips != REQUIRED_CLIPS:
        raise SystemExit("unexpected NLA clips: " + repr(clips))
    if mesh.color_attributes.get(biome.COLOR_ATTRIBUTE) is None:
        raise SystemExit("the runtime mesh lost its COLOR_0 regions")
    if mesh.uv_layers.get(biome.PAINT_UV_NAME) is None:
        raise SystemExit("the runtime mesh lost its paint UVs")
    if abs(size.z - TARGET_HEIGHT) > 0.005 or abs(low.z) > 0.006:
        raise SystemExit("runtime bounds are not normalized and grounded")
    left = rig.data.bones["LeftFrontFoot"]
    if left.head_local.x >= 0.0:
        raise SystemExit("LeftFrontFoot is on the wrong Blender side")
    if rig.data.bones["Head"].tail_local.y \
            <= rig.data.bones["Neck"].head_local.y:
        raise SystemExit("the alpaca's head does not point Blender +Y")
    print("final: bounds={0:.3f} x {1:.3f} x {2:.3f} m, floor={3:+.4f}, "
          "mesh={4} verts/{5} tris, bones={6}, clips={7}".format(
              size.x, size.y, size.z, low.z, len(mesh.vertices),
              triangle_count(mesh), len(rig.data.bones), len(clips)))


def main() -> None:
    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    mesh_obj, source_hash = normalize_source()
    optimize(mesh_obj)
    rig = build_armature()
    skin(mesh_obj, rig)
    asset = recipe()
    paint_regions(mesh_obj, asset)

    anim = load_sibling("build_animations.py", "_alpaca")
    # Pose offsets are authored as shares of body height, the way the shared
    # tables are authored as shares of the player's.
    anim.BODY_SCALE = TARGET_HEIGHT
    animations = alpaca_animations(anim)
    if tuple(spec[0] for spec in animations) != REQUIRED_CLIPS:
        raise SystemExit("the alpaca animation table is incomplete")
    anim.ANIMATIONS = animations
    anim.export = export_runtime
    anim.bake_into_open_file(OUT_BLEND, OUT_GLB)

    validate(mesh_obj, rig)
    image = write_paint_texture()
    merge_manifest(mesh_obj, rig)
    written = render_previews(rig, mesh_obj, asset, image)
    for key in sorted(written):
        print("  preview {0}: {1}".format(key, os.path.basename(written[key])))
    if file_sha256(SRC_BLEND) != source_hash:
        raise SystemExit("the source sculpt changed during the build")
    print("source preserved: sha256=" + source_hash)


if __name__ == "__main__":
    main()
