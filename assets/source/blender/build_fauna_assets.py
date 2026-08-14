"""Build deterministic GLB/PNG fauna variants and two-scale previews.

Run from the repository root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_fauna_assets.py

The interactive fauna runtime instances these meshes as CharacterBody3D actors.
Each asset still follows the population-art contract used by flora and small
creatures: one grounded mesh, COLOR_0 semantic colors, TEXCOORD_0 paint UVs,
one external deterministic PNG, broad mip-safe markings, and a manifest entry.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
import sys
from typing import Callable, Iterable, Sequence

import bmesh
import bpy
from mathutils import Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
MODEL_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "fauna", "models")
# Small-creature paint stays beside the established biome paint library.
PAINT_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "biomes", "paint")
MANIFEST_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "fauna", "manifests")
PREVIEW_DIR = os.path.join(PROJECT_DIR, "assets", "previews", "fauna")
PAINT_SIZE = 256
PAINT_GUTTER = 6
MANIFEST_VERSION = 1

if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_biome_assets as biome
import build_vat
import propkit


RGBA = tuple[float, float, float, float]


def rgba(value: str) -> RGBA:
    value = value.removeprefix("#")
    if len(value) != 6:
        raise ValueError("palette colours must use six hex digits")
    return tuple(int(value[index:index + 2], 16) / 255.0
                 for index in (0, 2, 4)) + (1.0,)


@dataclass(frozen=True)
class FaunaRecipe:
    name: str
    display_name: str
    form: str
    seed: int
    height: float
    palette: tuple[RGBA, ...]
    triangle_budget: tuple[int, int]
    collision_hint: dict[str, object]
    paint_style: str
    emission_style: str
    emission_strength: float
    builder: Callable[["FaunaRecipe", bmesh.types.BMesh], None]

    def biome_recipe(self) -> biome.AssetRecipe:
        # "glimmer" supplies robust palette-atlas UV projection and broad
        # creature-like vertex color variation. The runtime PNG below replaces
        # its generic paint with markings authored for each fauna silhouette.
        return biome.AssetRecipe(
            self.name,
            "fauna",
            "glimmer",
            self.form,
            self.seed,
            self.height,
            self.palette,
            self.triangle_budget,
            self.collision_hint,
            self.paint_style,
            self.emission_style,
            self.emission_strength,
            roughness=0.56 if self.form == "porcupine" else 0.42,
            smooth=True,
        )


def tag(bm: bmesh.types.BMesh, faces: Iterable[bmesh.types.BMFace],
        palette_index: int) -> list[bmesh.types.BMFace]:
    return biome._tag_faces(bm, faces, palette_index)


def add_sphere(
    bm: bmesh.types.BMesh,
    centre: Sequence[float],
    radius: float,
    scale: Sequence[float],
    palette_index: int,
    segments: int = 16,
) -> None:
    tag(bm, propkit.add_sphere(
        bm, centre, radius, 0, segments=segments, scale=scale), palette_index)


def add_cone(
    bm: bmesh.types.BMesh,
    start: Sequence[float],
    end: Sequence[float],
    radius_start: float,
    radius_end: float,
    palette_index: int,
    segments: int = 8,
) -> None:
    tag(bm, propkit.add_cone(
        bm, start, end, radius_start, radius_end, 0, segments=segments),
        palette_index)


def add_torus_x(
    bm: bmesh.types.BMesh,
    centre: Sequence[float],
    major_radius: float,
    tube_radius: float,
    palette_index: int,
    major_segments: int = 20,
    minor_segments: int = 6,
) -> None:
    """A torus whose hole axis is local X (a wheel/slinky coil)."""

    centre = Vector(centre)
    rings: list[list[bmesh.types.BMVert]] = []
    for major_index in range(major_segments):
        major_angle = math.tau * major_index / major_segments
        radial = Vector((
            0.0, math.cos(major_angle), math.sin(major_angle)))
        ring_centre = centre + radial * major_radius
        ring: list[bmesh.types.BMVert] = []
        for minor_index in range(minor_segments):
            minor_angle = math.tau * minor_index / minor_segments
            point = (
                ring_centre
                + radial * (math.cos(minor_angle) * tube_radius)
                + Vector((1.0, 0.0, 0.0))
                * (math.sin(minor_angle) * tube_radius)
            )
            ring.append(bm.verts.new(point))
        rings.append(ring)
    faces: list[bmesh.types.BMFace] = []
    for major_index, ring in enumerate(rings):
        following = rings[(major_index + 1) % major_segments]
        for minor_index in range(minor_segments):
            next_minor = (minor_index + 1) % minor_segments
            faces.append(bm.faces.new((
                ring[minor_index],
                following[minor_index],
                following[next_minor],
                ring[next_minor],
            )))
    tag(bm, faces, palette_index)


def build_porcupine(_recipe: FaunaRecipe, bm: bmesh.types.BMesh) -> None:
    # Low, broad body and oversized sensory head make this an alien animal
    # rather than a terrestrial porcupine recolored neon.
    add_sphere(bm, (0.0, -0.02, 0.39), 0.39,
               (0.90, 1.42, 0.74), 1, 20)
    add_sphere(bm, (0.0, 0.48, 0.38), 0.29,
               (0.88, 1.00, 0.86), 2, 16)
    add_sphere(bm, (0.0, 0.69, 0.34), 0.16,
               (0.72, 1.16, 0.62), 3, 14)

    # Four short, splayed legs keep the body at knee height and readable while
    # running. Legs and hoof bulbs share palette slot zero as the runtime's
    # semantic COLOR_0 gait mask.
    for x in (-0.24, 0.24):
        for y in (-0.31, 0.29):
            add_cone(
                bm, (x, y, 0.06), (x * 0.88, y, 0.27),
                0.075, 0.055, 0, 8)
            add_sphere(bm, (x, y + 0.025, 0.055), 0.075,
                       (1.0, 1.28, 0.62), 0, 12)

    # Petal-like ears and four luminous eyes.
    for x in (-0.18, 0.18):
        add_cone(
            bm, (x * 0.72, 0.51, 0.53), (x * 1.35, 0.55, 0.72),
            0.105, 0.018, 3, 8)
        for z in (0.39, 0.49):
            add_sphere(bm, (x * 0.72, 0.705, z), 0.047,
                       (1.0, 0.58, 1.0), 4, 10)

    # Quills fan backward from a magenta/cyan mantle instead of forming a
    # uniform brush. Alternating lengths make a recognizable defensive crest.
    rows = (
        (-0.31, 0.20, 7),
        (-0.10, 0.25, 8),
        (0.11, 0.22, 7),
    )
    for row_index, (y, reach, count) in enumerate(rows):
        for index in range(count):
            share = index / max(count - 1, 1)
            x = (share - 0.5) * (0.57 - row_index * 0.05)
            start = Vector((x, y, 0.57 - abs(x) * 0.14))
            side = (share - 0.5) * 0.21
            end = start + Vector((
                side, -0.15 - reach * 0.18,
                reach + 0.12 * (1.0 - abs(share - 0.5) * 2.0)))
            add_cone(
                bm, start, end, 0.042, 0.006,
                2 + (index + row_index) % 3, 7)


def build_slinky(_recipe: FaunaRecipe, bm: bmesh.types.BMesh) -> None:
    major_radius = 0.68
    centre_z = major_radius + 0.055
    coil_count = 13
    for index in range(coil_count):
        share = index / (coil_count - 1)
        x = (share - 0.5) * 0.94
        # A shallow wave breaks the manufactured-perfect silhouette while all
        # coils still share one wheel axis for the runtime roll.
        y = math.sin(share * math.tau * 1.5) * 0.018
        add_torus_x(
            bm, (x, y, centre_z), major_radius,
            0.047 + 0.006 * math.sin(share * math.pi),
            1 + index % 3, 20, 6)

    # Flexible end pads read as hands during the body-slap animation.
    for side in (-1.0, 1.0):
        add_sphere(
            bm, (side * 0.59, 0.0, centre_z), 0.18,
            (0.56, 0.80, 1.34), 3 if side < 0.0 else 4, 14)

    # Raised eye stalks sit on the forward (+Y in Blender, -Z in Godot) rim.
    for x in (-0.22, 0.22):
        start = (x, major_radius * 0.84, centre_z + major_radius * 0.36)
        end = (x, major_radius * 0.98, centre_z + major_radius * 0.68)
        add_cone(bm, start, end, 0.055, 0.035, 0, 8)
        add_sphere(bm, end, 0.115, (1.0, 0.74, 1.0), 4, 14)
        add_sphere(
            bm, (x, end[1] + 0.08, end[2]), 0.052,
            (1.0, 0.46, 1.0), 0, 10)
    add_sphere(
        bm, (0.0, major_radius + 0.03, centre_z - 0.06), 0.17,
        (1.42, 0.42, 0.56), 3, 14)


RECIPES: tuple[FaunaRecipe, ...] = (
    FaunaRecipe(
        "lumaquill_porcupine",
        "Lumaquill Porcupine",
        "porcupine",
        20268131,
        0.72,
        tuple(map(rgba, (
            "17243B", "1C8E99", "F24E9D", "FFD85A", "B9FFF5"))),
        (1800, 5200),
        {
            "shape": "capsule",
            "radius": 0.31,
            "height": 0.62,
            "centre": [0.0, 0.31, 0.0],
        },
        (
            "broad turquoise flank bands, magenta quill chevrons, large yellow "
            "eyespots, and mip-safe cyan/magenta night marks in PNG alpha"
        ),
        "quill bands and eyes glow cyan-magenta after local sunset",
        1.65,
        build_porcupine,
    ),
    FaunaRecipe(
        "prism_coil_slinky",
        "Prism-Coil Slinky",
        "slinky",
        20268132,
        1.70,
        tuple(map(rgba, (
            "24133F", "5F2DA8", "00BEB5", "FF65CF", "B9F54A"))),
        (2800, 6200),
        {
            "shape": "capsule",
            "radius": 0.72,
            "height": 1.62,
            "centre": [0.0, 0.81, 0.0],
        },
        (
            "wide alternating violet/teal coil bands, looping lime helix marks, "
            "pink slap pads, and a mip-safe luminous stripe mask in PNG alpha"
        ),
        "teal helix bands, eyes, and slap pads pulse after local sunset",
        1.8,
        build_slinky,
    ),
)
RECIPE_BY_NAME = {recipe.name: recipe for recipe in RECIPES}


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def smoothstep(low: float, high: float, value: float) -> float:
    if high <= low:
        return 1.0 if value >= high else 0.0
    share = clamp01((value - low) / (high - low))
    return share * share * (3.0 - 2.0 * share)


def mix(first: RGBA, second: RGBA, share: float) -> RGBA:
    amount = clamp01(share)
    return tuple(
        first[index] * (1.0 - amount) + second[index] * amount
        for index in range(4)
    )


def paint_pixel(recipe: FaunaRecipe, palette_index: int,
                u: float, v: float) -> RGBA:
    palette = recipe.palette
    base = palette[palette_index]
    pale = mix(base, palette[-1], 0.34)
    dark = (base[0] * 0.46, base[1] * 0.46, base[2] * 0.52, 1.0)
    phase = recipe.seed * 0.00037 + palette_index * 0.19
    tau = math.tau
    result = base

    if recipe.form == "porcupine":
        bands = 0.5 + 0.5 * math.sin(
            tau * (u * 3.0 + v * 1.15
                   + 0.14 * math.sin(tau * v * 2.0) + phase))
        chevron_coordinate = abs(u - 0.5) * 2.0 + v * 2.4 + phase
        chevrons = 1.0 - smoothstep(
            0.12, 0.28,
            abs((chevron_coordinate - math.floor(chevron_coordinate)) - 0.5))
        islands = (
            (0.5 + 0.5 * math.sin(tau * (u * 2.0 + v * 1.2 + phase)))
            * (0.5 + 0.5 * math.sin(
                tau * (v * 3.0 - u * 0.8 + phase * 1.7)))
        )
        eyespots = smoothstep(0.66, 0.84, islands)
        result = mix(result, dark, (1.0 - bands) * 0.28)
        result = mix(result, pale, bands * 0.34)
        result = mix(result, palette[3], eyespots * 0.68)
        result = mix(result, palette[2], chevrons * 0.42)
        emission = clamp01(
            0.05 + bands * 0.24 + chevrons * 0.55 + eyespots * 0.72)
    else:
        helix = 0.5 + 0.5 * math.sin(
            tau * (u * 2.0 - v * 3.0
                   + 0.16 * math.sin(tau * u * 2.0) + phase))
        coil_band = 0.5 + 0.5 * math.sin(
            tau * (v * 5.0 + phase * 1.6))
        loops = 1.0 - smoothstep(
            0.05, 0.16,
            abs(math.hypot((u - 0.5) * 1.05, (v - 0.5) * 0.84) - 0.27))
        result = mix(result, dark, (1.0 - coil_band) * 0.30)
        result = mix(result, palette[2], helix * 0.44)
        result = mix(result, palette[3], (1.0 - helix) * coil_band * 0.34)
        result = mix(result, palette[4], loops * 0.66)
        emission = clamp01(
            0.06 + helix * 0.58 + loops * 0.76 + coil_band * 0.12)

    drift = 0.95 + 0.05 * math.sin(
        tau * (u + v * 0.62 + phase * 0.3))
    return (
        clamp01(result[0] * drift),
        clamp01(result[1] * drift),
        clamp01(result[2] * drift),
        emission,
    )


def write_paint_texture(recipe: FaunaRecipe, path: str) -> bpy.types.Image:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image = bpy.data.images.new(
        recipe.name + "_paint",
        width=PAINT_SIZE,
        height=PAINT_SIZE,
        alpha=True,
        float_buffer=False,
    )
    try:
        image.colorspace_settings.name = "sRGB"
    except TypeError:
        pass
    palette_count = len(recipe.palette)
    band_pixels = PAINT_SIZE / palette_count
    gutter_share = PAINT_GUTTER / band_pixels
    pixels: list[float] = []
    for y in range(PAINT_SIZE):
        atlas_v = (y + 0.5) / PAINT_SIZE * palette_count
        palette_index = min(int(atlas_v), palette_count - 1)
        local_v = atlas_v - palette_index
        local_v = clamp01(
            (local_v - gutter_share)
            / max(1.0 - gutter_share * 2.0, 1.0e-5))
        for x in range(PAINT_SIZE):
            u = (x + 0.5) / PAINT_SIZE
            pixels.extend(paint_pixel(recipe, palette_index, u, local_v))
    image.pixels.foreach_set(pixels)
    image.filepath_raw = path
    image.file_format = "PNG"
    image.save()
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise ValueError("color paint did not produce {}".format(path))
    return image


def use_paint_for_preview(
    material: bpy.types.Material,
    image: bpy.types.Image,
    emission_strength: float,
) -> None:
    biome._preview_with_paint(material, image)
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    texture = nodes.get("BiomeColorPaint")
    principled = nodes.get("Principled BSDF")
    if texture is None or principled is None:
        return
    if "Emission Strength" in principled.inputs:
        multiplier = nodes.new("ShaderNodeMath")
        multiplier.operation = "MULTIPLY"
        multiplier.inputs[1].default_value = emission_strength
        links.new(texture.outputs["Alpha"], multiplier.inputs[0])
        links.new(multiplier.outputs[0], principled.inputs["Emission Strength"])


def render_previews(
    obj: bpy.types.Object,
    asset_recipe: biome.AssetRecipe,
    close_path: str,
    gameplay_path: str,
) -> None:
    # The shared biome preview camera looks toward Blender +Y from the rear.
    # Fauna faces +Y so turn only the already-exported preview copy toward it.
    obj.rotation_euler.z += math.pi
    biome._render_preview(obj, asset_recipe, close_path)
    camera = bpy.data.objects.get("BiomePreviewCamera")
    ground = bpy.data.objects.get("BiomePreviewGround")
    if camera is None or camera.type != "CAMERA":
        raise RuntimeError("close preview did not create its camera")
    camera.data.ortho_scale *= 3.2
    if ground is not None:
        ground.scale.x = 3.5
        ground.scale.y = 3.5
    scene = bpy.context.scene
    scene.render.filepath = gameplay_path
    os.makedirs(os.path.dirname(gameplay_path), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(gameplay_path) \
            or os.path.getsize(gameplay_path) <= 0:
        raise ValueError(
            "gameplay-distance preview did not produce {}".format(gameplay_path))


def build_one(recipe: FaunaRecipe) -> dict[str, object]:
    print("\n=== {} ===".format(recipe.name))
    biome._reset_scene()
    bm = bmesh.new()
    # Blender 5.x may invalidate face handles if this layer is added after
    # geometry, so create it before a builder returns any faces.
    bm.faces.layers.int.new(biome.PALETTE_ATTRIBUTE)
    recipe.builder(recipe, bm)
    asset_recipe = recipe.biome_recipe()
    obj = biome._finish_object(asset_recipe, bm)

    source_triangles = build_vat.triangle_count(obj.data)
    low, high = biome._bounds(obj.data.vertices)
    measured_height = high.z - low.z
    if abs(low.z) > 1.0e-7:
        raise ValueError("{} base is {}, expected zero".format(
            recipe.name, low.z))
    if abs(measured_height - recipe.height) > 1.0e-5:
        raise ValueError("{} height {} differs from authored {}".format(
            recipe.name, measured_height, recipe.height))
    minimum, maximum = recipe.triangle_budget
    if not minimum <= source_triangles <= maximum:
        raise ValueError("{} has {} triangles, budget is {}..{}".format(
            recipe.name, source_triangles, minimum, maximum))

    os.makedirs(MODEL_DIR, exist_ok=True)
    glb_path = os.path.join(MODEL_DIR, recipe.name + ".glb")
    biome._export_glb(obj, glb_path)
    validation = biome._validate_glb(
        glb_path, asset_recipe, source_triangles)

    paint_path = os.path.join(PAINT_DIR, recipe.name + "_paint.png")
    image = write_paint_texture(recipe, paint_path)
    use_paint_for_preview(obj.data.materials[0], image, recipe.emission_strength)
    close_path = os.path.join(PREVIEW_DIR, recipe.name + "_close.png")
    gameplay_path = os.path.join(
        PREVIEW_DIR, recipe.name + "_gameplay.png")
    render_previews(obj, asset_recipe, close_path, gameplay_path)

    entry = {
        "name": recipe.name,
        "display_name": recipe.display_name,
        "category": "land_fauna",
        "form": recipe.form,
        "seed": recipe.seed,
        "glb": "assets/runtime/fauna/models/{}.glb".format(recipe.name),
        "color_paint": (
            "assets/runtime/biomes/paint/{}_paint.png".format(recipe.name)),
        "close_preview": (
            "assets/previews/fauna/{}_close.png".format(recipe.name)),
        "gameplay_distance_preview": (
            "assets/previews/fauna/{}_gameplay.png".format(recipe.name)),
        "authored_height": round(measured_height, 6),
        "triangle_count": validation["triangle_count"],
        "glb_vertex_count": validation["glb_vertex_count"],
        "triangle_budget": {
            "minimum": minimum,
            "maximum": maximum,
        },
        "collision_hint": recipe.collision_hint,
        "color_paint_style": recipe.paint_style,
        "emission_style": recipe.emission_style,
        "emission_strength": recipe.emission_strength,
        "runtime_contract": {
            "mesh_node": recipe.name,
            "mesh_count": 1,
            "primitive_count": validation["primitive_count"],
            "vertex_colour": "COLOR_0 semantic part colors",
            "color_paint_uv": "TEXCOORD_0",
            "paint_texture": (
                "assets/runtime/biomes/paint/{}_paint.png".format(recipe.name)),
            "emission_mask": (
                "assets/runtime/biomes/paint/{}_paint.png alpha; "
                "never transparency".format(recipe.name)),
            "ground_axis": "Godot/glTF +Y",
            "forward_axis": "Godot local -Z",
            "skins": 0,
            "animations": (
                "procedural runtime walk/run/roll/body-slap presentation"),
        },
        "file_size_bytes": os.path.getsize(glb_path),
        "paint_size_bytes": os.path.getsize(paint_path),
        "close_preview_size_bytes": os.path.getsize(close_path),
        "gameplay_preview_size_bytes": os.path.getsize(gameplay_path),
    }
    print(
        "  wrote {}: {} triangles, {:.1f} KB; paint {:.1f} KB".format(
            os.path.basename(glb_path),
            validation["triangle_count"],
            entry["file_size_bytes"] / 1024.0,
            entry["paint_size_bytes"] / 1024.0,
        )
    )
    return entry


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", nargs="+", metavar="NAME",
        help="build only named recipes; comma-separated names are accepted")
    blender_arguments = (
        sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    return parser.parse_args(blender_arguments)


def selected_recipes(only: Sequence[str] | None) -> list[FaunaRecipe]:
    if not only:
        return list(RECIPES)
    requested: list[str] = []
    for value in only:
        requested.extend(
            name.strip() for name in value.split(",") if name.strip())
    unknown = sorted(set(requested) - set(RECIPE_BY_NAME))
    if unknown:
        raise ValueError("unknown fauna recipe(s): {}".format(
            ", ".join(unknown)))
    requested_set = set(requested)
    return [
        recipe for recipe in RECIPES if recipe.name in requested_set]


def foreign_entries(manifest_path: str) -> dict:
    """Entries in the manifest that some other recipe file owns.

    One creature is a sculpt with its own build script rather than a recipe in
    the table below, and it records itself in the same manifest. Rewriting this
    file wholesale would delete it, so anything stamped with another generator is
    carried through untouched.
    """
    if not os.path.isfile(manifest_path):
        return {}
    with open(manifest_path, encoding="utf-8") as handle:
        existing = json.load(handle)
    mine = "assets/source/blender/build_fauna_assets.py"
    return {
        name: entry
        for name, entry in (existing.get("assets") or {}).items()
        if isinstance(entry, dict) and entry.get("generator", mine) != mine
    }


def main() -> None:
    recipes = selected_recipes(arguments().only)
    entries = [build_one(recipe) for recipe in recipes]
    os.makedirs(MANIFEST_DIR, exist_ok=True)
    manifest_path = os.path.join(MANIFEST_DIR, "fauna_assets.json")
    kept = foreign_entries(manifest_path)
    manifest = {
        "schema": "procedural_fauna_asset_manifest",
        "version": MANIFEST_VERSION,
        "generator": "assets/source/blender/build_fauna_assets.py",
        "coordinate_system": {
            "authoring": "Blender Z-up, metres",
            "runtime": "glTF/Godot Y-up, metres",
            "axis_conversion": (
                "Blender (x, y, z) -> glTF/Godot (x, z, -y)"),
            "ground_plane": "runtime Y=0",
        },
        "library_contract": {
            "deterministic_recipes": True,
            "one_mesh_per_glb": True,
            "one_primitive_per_mesh": True,
            "vertex_colour": "COLOR_0",
            "color_paint_uv": "TEXCOORD_0",
            "external_color_paint": (
                "one PNG per variant under assets/runtime/biomes/paint"),
            "emission_mask": "PNG alpha, never transparency",
            "close_and_gameplay_previews_validated": True,
        },
        "assets": dict(kept, **{entry["name"]: entry for entry in entries}),
    }
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print("wrote {} fauna assets ({} kept from other recipes) and {}".format(
        len(entries), len(kept), manifest_path))


if __name__ == "__main__":
    main()
