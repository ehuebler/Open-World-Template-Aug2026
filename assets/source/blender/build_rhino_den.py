"""Build the deterministic runtime paint used by the Cinder-Plate Rhino den.

The den geometry is assembled from low-cost Godot primitives at runtime so it
can conform to whichever cliff the planet recipe places it on.  Its external
PNG still follows the fauna/geological paint contract: broad, mip-safe strata,
lichen blooms, and ember-coloured horn scrapes over usable primitive UVs.

Run from the project root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_rhino_den.py
"""

from __future__ import annotations

import json
import math
import os
import struct
import zlib

import bpy
from mathutils import Vector


ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    os.pardir, os.pardir, os.pardir))
NAME = "cinder_plate_rhino_den"
PAINT_SIZE = 256
PAINT_PNG = os.path.join(
    ROOT, "assets", "runtime", "biomes", "paint", NAME + "_paint.png")
MANIFEST = os.path.join(
    ROOT, "assets", "runtime", "fauna", "manifests", "fauna_assets.json")
PREVIEW_DIR = os.path.join(ROOT, "assets", "previews", "fauna")
CLOSE_PREVIEW = os.path.join(
    PREVIEW_DIR, "cinder_plate_rhino_den_close.png")
GAMEPLAY_PREVIEW = os.path.join(
    PREVIEW_DIR, "cinder_plate_rhino_den_gameplay.png")
PAINT_STYLE = (
    "broad blue-slate cliff strata, dusty violet mineral blooms, dark soot "
    "pockets, and wide amber horn scrapes; all marks are mip-safe"
)


def mix(a: tuple[float, float, float], b: tuple[float, float, float],
        share: float) -> tuple[float, float, float]:
    share = max(0.0, min(share, 1.0))
    return tuple(a[i] + (b[i] - a[i]) * share for i in range(3))


def smoothstep(start: float, end: float, value: float) -> float:
    if end <= start:
        return 0.0
    share = max(0.0, min((value - start) / (end - start), 1.0))
    return share * share * (3.0 - 2.0 * share)


def paint_pixel(x: int, y: int) -> tuple[float, float, float, float]:
    u = (x + 0.5) / PAINT_SIZE
    v = (y + 0.5) / PAINT_SIZE
    warped_v = v + math.sin(u * math.tau * 2.0) * 0.025 \
        + math.sin(u * math.tau * 5.0 + 0.7) * 0.009
    stratum = 0.5 + 0.5 * math.sin(warped_v * math.tau * 7.0)
    broad = smoothstep(0.18, 0.82, stratum)
    colour = mix((0.24, 0.25, 0.34), (0.48, 0.53, 0.67), broad)

    mineral = (0.5 + 0.5 * math.sin(
        u * math.tau * 2.0 + math.sin(v * math.tau * 3.0))) \
        * (0.5 + 0.5 * math.sin(v * math.tau * 2.0 + 1.2))
    mineral = smoothstep(0.58, 0.88, mineral)
    colour = mix(colour, (0.52, 0.34, 0.60), mineral * 0.38)

    soot = 0.5 + 0.5 * math.sin(
        u * math.tau * 3.0 - v * math.tau * 2.0 + 2.1)
    soot *= 0.5 + 0.5 * math.sin(v * math.tau * 4.0)
    colour = mix(colour, (0.08, 0.07, 0.10),
                 smoothstep(0.67, 0.94, soot) * 0.56)

    # Three broad diagonal scrape bands.  Their width is deliberately several
    # texels so they remain visible on a den seen from the settlement.
    scrape = 0.0
    for offset in (0.24, 0.74):
        line = (u * 0.72 + offset + math.sin(v * math.tau) * 0.018) % 1.0
        distance = abs(line - v)
        distance = min(distance, 1.0 - distance)
        scrape = max(scrape, 1.0 - smoothstep(0.012, 0.033, distance))
    colour = mix(colour, (0.62, 0.25, 0.12), scrape * 0.22)

    grain = math.sin((u * 17.0 + v * 11.0) * math.tau) * 0.018
    colour = tuple(max(0.0, min(component + grain, 1.0))
                   for component in colour)
    return (*colour, 1.0)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body \
        + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_paint() -> None:
    os.makedirs(os.path.dirname(PAINT_PNG), exist_ok=True)
    scanlines = bytearray()
    for y in range(PAINT_SIZE):
        scanlines.append(0)  # PNG filter: none
        for x in range(PAINT_SIZE):
            scanlines.extend(
                round(max(0.0, min(value, 1.0)) * 255.0)
                for value in paint_pixel(x, y))
    header = struct.pack(
        ">IIBBBBB", PAINT_SIZE, PAINT_SIZE, 8, 6, 0, 0, 0)
    payload = b"\x89PNG\r\n\x1a\n"
    payload += png_chunk(b"IHDR", header)
    payload += png_chunk(b"IDAT", zlib.compress(bytes(scanlines), level=9))
    payload += png_chunk(b"IEND", b"")
    with open(PAINT_PNG, "wb") as stream:
        stream.write(payload)


def godot_to_blender(value: tuple[float, float, float]) \
        -> tuple[float, float, float]:
    return (value[0], -value[2], value[1])


def boulder_mesh() -> bpy.types.Mesh:
    segments = 8
    godot_vertices: list[tuple[float, float, float]] = [(0.0, 1.0, 0.0)]
    for ring in range(2):
        y = 0.46 if ring == 0 else -0.48
        base_radius = 0.76 if ring == 0 else 0.92
        for segment in range(segments):
            angle = math.tau * segment / segments
            radius = base_radius * (
                1.0 + 0.09 * math.sin(segment * 2.31 + ring * 1.77))
            godot_vertices.append((
                math.cos(angle) * radius,
                y + 0.06 * math.sin(segment * 1.61 + ring),
                math.sin(angle) * radius * (
                    0.82 + 0.07 * math.cos(segment * 1.37)),
            ))
    bottom = len(godot_vertices)
    godot_vertices.append((0.0, -0.94, 0.0))
    faces: list[tuple[int, ...]] = []
    for segment in range(segments):
        next_segment = (segment + 1) % segments
        upper = 1 + segment
        next_upper = 1 + next_segment
        lower = 1 + segments + segment
        next_lower = 1 + segments + next_segment
        faces.append((0, next_upper, upper))
        faces.append((upper, next_upper, next_lower, lower))
        faces.append((bottom, lower, next_lower))
    mesh = bpy.data.meshes.new("RhinoDenFacetedRock")
    mesh.from_pydata(
        [godot_to_blender(vertex) for vertex in godot_vertices], [], faces)
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for polygon in mesh.polygons:
        for loop_index in polygon.loop_indices:
            source = godot_vertices[mesh.loops[loop_index].vertex_index]
            uv_layer.data[loop_index].uv = (
                math.atan2(source[2], source[0]) / math.tau + 0.5,
                source[1] * 0.44 + 0.5,
            )
    return mesh


def painted_material() -> bpy.types.Material:
    material = bpy.data.materials.new("Rhino Den Painted Strata")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    shader = nodes.get("Principled BSDF")
    image = bpy.data.images.load(PAINT_PNG, check_existing=False)
    texture = nodes.new("ShaderNodeTexImage")
    texture.image = image
    material.node_tree.links.new(
        texture.outputs["Color"], shader.inputs["Base Color"])
    shader.inputs["Roughness"].default_value = 0.88
    shader.inputs["Metallic"].default_value = 0.04
    return material


def flat_material(name: str, colour: tuple[float, float, float, float],
        roughness: float = 1.0) -> bpy.types.Material:
    material = bpy.data.materials.new(name)
    material.diffuse_color = colour
    material.use_nodes = True
    shader = material.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = colour
    shader.inputs["Roughness"].default_value = roughness
    return material


def render_previews() -> None:
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    rock_mesh = boulder_mesh()
    rock = painted_material()
    rock_mesh.materials.append(rock)
    dark = flat_material("Sealed Cave Depth", (0.006, 0.004, 0.01, 1.0))
    sand = flat_material("Cliff Ground", (0.33, 0.15, 0.075, 1.0), 0.92)

    def add_rock(name: str, position: tuple[float, float, float],
            scale: tuple[float, float, float],
            material: bpy.types.Material = rock) -> bpy.types.Object:
        obj = bpy.data.objects.new(name, rock_mesh)
        bpy.context.collection.objects.link(obj)
        obj.location = godot_to_blender(position)
        obj.scale = (scale[0], scale[2], scale[1])
        obj.material_slots[0].link = "OBJECT"
        obj.material_slots[0].material = material
        return obj

    def add_box(name: str, position: tuple[float, float, float],
            size: tuple[float, float, float],
            material: bpy.types.Material) -> bpy.types.Object:
        bpy.ops.mesh.primitive_cube_add(
            size=1.0, location=godot_to_blender(position))
        obj = bpy.context.object
        obj.name = name
        obj.scale = (size[0], size[2], size[1])
        obj.data.materials.append(material)
        return obj

    shoulder_positions = (
        (-4.25, 1.45, 1.12), (-3.52, 3.40, 1.42),
        (4.08, 1.62, 1.04), (3.68, 3.52, 1.55),
    )
    shoulder_scales = (
        (2.12, 1.72, 1.42), (1.82, 1.44, 1.54),
        (2.02, 1.86, 1.34), (1.72, 1.38, 1.50),
    )
    for index, (position, scale) in enumerate(
            zip(shoulder_positions, shoulder_scales)):
        obj = add_rock("CliffShoulder" + str(index), position, scale)
        obj.rotation_euler[1] = -0.10 + 0.07 * index
    for index in range(4):
        obj = add_rock(
            "CliffCap" + str(index),
            (-3.05 + index * 2.05,
             4.38 + 0.24 * ((index + 1) % 2), 1.32),
            (1.52, 1.08 + 0.10 * (index % 2), 1.48))
        obj.rotation_euler[1] = 0.07 * (index - 1)

    add_rock("CaveShadow", (0.0, 1.75, 0.36),
             (2.05, 1.55, 0.18), dark)
    add_box("LowerShadow", (0.0, 0.82, 0.38),
            (4.08, 0.34, 1.70), dark)
    for index in range(11):
        share = index / 10.0
        angle = math.pi + (0.0 - math.pi) * share
        position = (
            math.cos(angle) * 2.32,
            1.58 + math.sin(angle) * 1.77,
            0.02 - 0.11 * math.sin(angle),
        )
        scale = (
            0.72 + 0.13 * math.sin(index * 2.17),
            0.62 + 0.15 * math.cos(index * 1.43),
            0.58 + 0.10 * math.sin(index * 0.91),
        )
        add_rock("ArchRock" + str(index), position, scale)
    for side in (-1.0, 1.0):
        for row in range(2):
            add_rock(
                "Pillar_{0}_{1}".format("L" if side < 0 else "R", row),
                (side * (2.30 + row * 0.08), 0.48 + row * 0.78, 0.0),
                tuple(component * (1.0 - row * 0.07)
                      for component in (0.78, 0.70, 0.68)))
    for index in range(7):
        add_rock(
            "ThresholdRock" + str(index),
            (-2.55 + index * 0.85, 0.02 + 0.04 * (index % 2),
             -0.70 - 0.08 * abs(3 - index)),
            (0.62, 0.18, 0.70))

    add_box("Ground", (0.0, -0.55, -0.6), (38.0, 1.0, 38.0), sand)
    # A broad tilted backing bank makes clear that the arch is cut into a cliff,
    # without hiding the painted facade in either validation view.
    add_rock("CliffBankLeft", (-4.7, 3.0, 3.0), (3.5, 3.5, 2.8), sand)
    add_rock("CliffBankMiddle", (0.0, 4.0, 3.4), (4.2, 4.0, 3.2), sand)
    add_rock("CliffBankRight", (4.8, 3.2, 2.8), (3.6, 3.4, 2.9), sand)

    world = bpy.context.scene.world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (
        0.12, 0.20, 0.34, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.45
    bpy.ops.object.light_add(type="SUN", location=(4.0, -7.0, 11.0))
    sun = bpy.context.object
    sun.rotation_euler = (math.radians(34.0), 0.0, math.radians(-28.0))
    sun.data.energy = 3.0
    bpy.ops.object.light_add(type="AREA", location=(-5.0, -8.0, 8.0))
    area = bpy.context.object
    area.data.energy = 1100.0
    area.data.shape = "DISK"
    area.data.size = 7.0

    bpy.ops.object.camera_add(location=(0.0, -15.0, 5.0))
    camera = bpy.context.object
    camera.data.lens = 48.0
    bpy.context.scene.camera = camera

    def aim(location: tuple[float, float, float],
            target: tuple[float, float, float]) -> None:
        camera.location = location
        camera.rotation_euler = (
            Vector(target) - camera.location).to_track_quat("-Z", "Y").to_euler()

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.view_settings.look = "AgX - Medium High Contrast"

    aim((9.0, 18.5, 6.5), (0.0, 0.0, 2.0))
    scene.render.filepath = CLOSE_PREVIEW
    bpy.ops.render.render(write_still=True)
    aim((24.0, 45.0, 12.0), (0.0, 0.0, 2.2))
    scene.render.filepath = GAMEPLAY_PREVIEW
    bpy.ops.render.render(write_still=True)


def update_manifest() -> None:
    with open(MANIFEST, "r", encoding="utf-8") as stream:
        manifest = json.load(stream)
    entry = {
        "name": NAME,
        "display_name": "Cinder-Plate Rhino Den",
        "category": "fauna_den",
        "form": "non-enterable cliff cave facade",
        "seed": 20268135,
        "generator": "assets/source/blender/build_rhino_den.py",
        "runtime_geometry": "game/fauna/rhino_den.gd primitive arch",
        "color_paint": (
            "assets/runtime/biomes/paint/cinder_plate_rhino_den_paint.png"),
        "close_preview": (
            "assets/previews/fauna/cinder_plate_rhino_den_close.png"),
        "gameplay_distance_preview": (
            "assets/previews/fauna/cinder_plate_rhino_den_gameplay.png"),
        "color_paint_style": PAINT_STYLE,
        "runtime_contract": {
            "geometry": "Godot primitive meshes with TEXCOORD_0 UVs",
            "paint_texture": (
                "assets/runtime/biomes/paint/"
                "cinder_plate_rhino_den_paint.png"),
            "collision": "solid backing slab; entrance is never traversable",
            "placement": "host-authored steep terrain near frontier rhinos",
        },
        "paint_size_bytes": os.path.getsize(PAINT_PNG),
    }
    if os.path.isfile(CLOSE_PREVIEW):
        entry["close_preview_size_bytes"] = os.path.getsize(CLOSE_PREVIEW)
    if os.path.isfile(GAMEPLAY_PREVIEW):
        entry["gameplay_preview_size_bytes"] = os.path.getsize(
            GAMEPLAY_PREVIEW)
    manifest.setdefault("assets", {})[NAME] = entry
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")


def main() -> None:
    write_paint()
    render_previews()
    update_manifest()
    print("Wrote", PAINT_PNG)


if __name__ == "__main__":
    main()
