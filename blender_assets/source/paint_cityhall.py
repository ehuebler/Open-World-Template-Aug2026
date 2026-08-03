"""Repaint `generated/cityhall.blend` from its own geometry.

    blender --background generated/cityhall.blend --python blender_assets/source/paint_cityhall.py

The mesh arrives from a generator that stores its guess at the surface colour in
a per-corner attribute and no UVs at all, so "texture" here means vertex paint
and nothing else. The shape is good; the paint is not. It streaks vertically
down the walls, bands the cornices in saturated blue, drops green patches on a
wing roof, and bakes its own shadows in so hard that 44% of the surface area
sits within a hair of black. None of that survives a lighting rig.

So the paint is rebuilt from the part that is trustworthy - the geometry - and
tinted with the colours the generator did agree on, measured per region with the
saturated noise thrown out. Height and face normal name the architecture:

    plaza -> podium -> main storey -> roof deck -> drum -> dome -> lantern -> finial

Occlusion is then computed honestly, by raycasting the mesh, instead of being
inherited from the baked-in mess. That is what makes the colonnades and the
dome ribs read: a single flat albedo over this shape looks like a soap carving.

The original attribute is kept as `ColorSource` and is the input on every run,
so this can be re-run without stacking corrections on corrections.
"""

import math
import os
import random

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BLEND = os.path.join(ROOT, "generated", "cityhall.blend")

SOURCE_LAYER = "ColorSource"
PAINT_LAYER = "Color"

# Linear albedo. Hues are the generator's own, measured per region with the
# saturated faces discarded; the values are lifted to real stone albedo, because
# every one of those samples came back darkened by baked-in shadow.
PAVING = Vector((0.345, 0.350, 0.362))     # cool grey, the plaza's own cast
PODIUM = Vector((0.395, 0.380, 0.360))     # rusticated base, a shade off white
WALL = Vector((0.560, 0.515, 0.445))       # warm limestone, the body of it
DOME = Vector((0.635, 0.590, 0.510))       # painted, so lighter than the walls
ROOF = Vector((0.200, 0.215, 0.235))       # lead, and the only real contrast
BRONZE = Vector((0.340, 0.200, 0.110))     # finial

# Stone colour as a function of height, lerped between stops so a threshold
# never cuts a ragged ring around the dome. Metres from the plaza deck.
STOPS = (
    (0.0, PAVING),
    (2.6, PAVING),
    (5.2, PODIUM),
    (23.0, PODIUM),
    (27.0, WALL),
    (43.0, WALL),
    (48.0, DOME),
    (67.0, DOME),
    (72.5, BRONZE),
    (80.0, BRONZE),
)

DOME_RADIUS = 34.0      # nothing but the dome assembly lives inside this above DOME_BASE
DOME_BASE = 36.0
DECK_MIN_Z = 4.5        # below this an up-facing face is plaza, not roof
DECK_NORMAL = 0.55      # cos of the steepest face still counted as a deck
ROOF_LINE = (24.0, 28.0)  # the main cornice: flat tops are terraces below, lead above

AO_RAYS = 24
AO_DISTANCE = 11.0      # column gaps and cornice recesses, not whole wings
AO_FLOOR = 0.30         # crevices go dim, never black: black reads as a hole
AO_GAMMA = 1.25
AO_SMOOTH_PASSES = 2

GRAIN = 0.035           # per-vertex speckle
MOTTLE = 0.055          # slow patchiness, so the stone is not one flat sheet


def find_mesh() -> bpy.types.Object:
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if len(meshes) != 1:
        raise SystemExit("expected one mesh in {0}, found {1}".format(
            BLEND, [o.name for o in meshes]))
    return meshes[0]


def preserve_source(mesh: bpy.types.Mesh) -> None:
    """Stash the generator's paint once, so later runs read the original."""
    if SOURCE_LAYER in mesh.color_attributes:
        return
    original = [tuple(d.color) for d in mesh.color_attributes[PAINT_LAYER].data]
    layer = mesh.color_attributes.new(SOURCE_LAYER, "BYTE_COLOR", "CORNER")
    for i, value in enumerate(original):
        layer.data[i].color = value
    print("  kept the generator's paint as '{0}'".format(SOURCE_LAYER))


def stone_at(z: float) -> Vector:
    if z <= STOPS[0][0]:
        return STOPS[0][1].copy()
    for (z0, c0), (z1, c1) in zip(STOPS, STOPS[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            return c0.lerp(c1, t)
    return STOPS[-1][1].copy()


def region_colour(point: Vector, normal_z: float) -> Vector:
    """Base albedo for one corner, from where it sits and which way it faces."""
    z = point.z
    base = stone_at(z)
    if math.hypot(point.x, point.y) < DOME_RADIUS and z >= DOME_BASE:
        return base
    if normal_z > DECK_NORMAL and z >= DECK_MIN_Z:
        # Flat-topped and outside the dome. Above the cornice that means a roof,
        # a cornice cap or a parapet, and all of those are lead here. Below it,
        # it is a terrace or a stair landing: lead down there reads as a hole
        # punched in the building.
        low, high = ROOF_LINE
        deck = PAVING.lerp(ROOF, min(1.0, max(0.0, (z - low) / (high - low))))
        flat = min(1.0, (normal_z - DECK_NORMAL) / (0.85 - DECK_NORMAL))
        return base.lerp(deck, flat)
    return base


def occlusion(mesh: bpy.types.Mesh) -> list:
    """Per-vertex openness in 0..1, by cosine-weighted raycast against the mesh."""
    verts = [v.co.copy() for v in mesh.vertices]
    polys = [tuple(p.vertices) for p in mesh.polygons]
    bvh = BVHTree.FromPolygons(verts, polys)

    # Cosine-weighted hemisphere on a golden-angle spiral: deterministic, and
    # far smoother than the same count of random directions.
    golden = math.pi * (3.0 - math.sqrt(5.0))
    pattern = []
    for i in range(AO_RAYS):
        u = (i + 0.5) / AO_RAYS
        radius = math.sqrt(u)
        theta = i * golden
        pattern.append(Vector((radius * math.cos(theta),
                               radius * math.sin(theta),
                               math.sqrt(max(0.0, 1.0 - u)))))

    open_amount = [1.0] * len(verts)
    for index, vertex in enumerate(mesh.vertices):
        normal = vertex.normal
        if normal.length_squared < 1e-8:
            continue
        normal = normal.normalized()
        helper = Vector((0.0, 0.0, 1.0)) if abs(normal.z) < 0.9 else Vector((1.0, 0.0, 0.0))
        tangent = normal.cross(helper).normalized()
        bitangent = normal.cross(tangent)
        origin = vertex.co + normal * 0.02
        hits = 0
        for d in pattern:
            direction = tangent * d.x + bitangent * d.y + normal * d.z
            location, _n, _i, _dist = bvh.ray_cast(origin, direction, AO_DISTANCE)
            if location is not None:
                hits += 1
        open_amount[index] = 1.0 - hits / float(AO_RAYS)

    for _ in range(AO_SMOOTH_PASSES):
        acc = [[0.0, 0] for _ in verts]
        for edge in mesh.edges:
            a, b = edge.vertices
            acc[a][0] += open_amount[b]
            acc[a][1] += 1
            acc[b][0] += open_amount[a]
            acc[b][1] += 1
        for i, (total, count) in enumerate(acc):
            if count:
                open_amount[i] = (open_amount[i] + total / count) * 0.5
    return open_amount


def mottle(point: Vector) -> float:
    """Slow, smooth patchiness. Cheap trig beats a noise texture here: the
    building is 180 units wide and the eye only needs a hint of unevenness."""
    return (math.sin(point.x * 0.071) * math.sin(point.y * 0.063) * math.sin(point.z * 0.089)
            + 0.5 * math.sin(point.x * 0.131 + 1.7) * math.sin(point.z * 0.113 + 0.9))


def repaint(obj: bpy.types.Object) -> None:
    mesh = obj.data
    preserve_source(mesh)

    print("  raycasting occlusion ({0} verts x {1} rays)...".format(
        len(mesh.vertices), AO_RAYS))
    open_amount = occlusion(mesh)

    rng = random.Random(20260802)
    speckle = [rng.uniform(-GRAIN, GRAIN) for _ in mesh.vertices]

    paint = mesh.color_attributes[PAINT_LAYER].data
    normals = [p.normal.z for p in mesh.polygons]
    for poly_index, poly in enumerate(mesh.polygons):
        normal_z = normals[poly_index]
        for loop_index in poly.loop_indices:
            vertex_index = mesh.loops[loop_index].vertex_index
            point = mesh.vertices[vertex_index].co
            colour = region_colour(point, normal_z)
            shade = AO_FLOOR + (1.0 - AO_FLOOR) * open_amount[vertex_index] ** AO_GAMMA
            shade *= 1.0 + speckle[vertex_index] + MOTTLE * mottle(point)
            paint[loop_index].color = (
                min(1.0, max(0.0, colour.x * shade)),
                min(1.0, max(0.0, colour.y * shade)),
                min(1.0, max(0.0, colour.z * shade)),
                1.0,
            )
    mesh.update()


def dress_material(obj: bpy.types.Object) -> None:
    """Stone, not the default half-gloss plastic the generator left behind."""
    material = obj.data.materials[0]
    tree = material.node_tree
    bsdf = tree.nodes.get("Principled BSDF")
    if bsdf is None:
        return
    vertex_colour = next(
        (n for n in tree.nodes if n.bl_idname == "ShaderNodeVertexColor"), None)
    if vertex_colour is not None:
        vertex_colour.layer_name = PAINT_LAYER
        tree.links.new(vertex_colour.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.82
    for name, value in (("Metallic", 0.0), ("Specular IOR Level", 0.35)):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = value


def report(obj: bpy.types.Object) -> None:
    mesh = obj.data
    paint = mesh.color_attributes[PAINT_LAYER].data
    total = 0.0
    acc = Vector((0.0, 0.0, 0.0))
    for poly in mesh.polygons:
        mean = Vector((0.0, 0.0, 0.0))
        for loop_index in poly.loop_indices:
            c = paint[loop_index].color
            mean += Vector((c[0], c[1], c[2]))
        acc += mean / len(poly.loop_indices) * poly.area
        total += poly.area
    mean = acc / total
    print("  mean albedo ({0:.3f}, {1:.3f}, {2:.3f}), luma {3:.3f}".format(
        mean.x, mean.y, mean.z,
        0.2126 * mean.x + 0.7152 * mean.y + 0.0722 * mean.z))


def main() -> None:
    obj = find_mesh()
    print("repainting {0} ({1} verts, {2} faces)".format(
        obj.name, len(obj.data.vertices), len(obj.data.polygons)))
    repaint(obj)
    dress_material(obj)
    report(obj)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
    print("  wrote {0} ({1:.0f} KB)".format(
        os.path.basename(BLEND), os.path.getsize(BLEND) / 1024.0))


main()
