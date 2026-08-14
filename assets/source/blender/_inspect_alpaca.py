"""Profile alpaca.blend after normalization, to place bones from measurements.

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background "assets/source/meshmaker/alpaca.blend" `
        --python assets/source/blender/_inspect_alpaca.py
"""

import math

import bpy
from mathutils import Matrix, Vector

TARGET_HEIGHT = 1.45
BANDS = 16


def normalized_points():
    obj = bpy.data.objects["geometry_0"]
    points = [obj.matrix_world @ vertex.co for vertex in obj.data.vertices]
    low = [min(p[i] for p in points) for i in range(3)]
    high = [max(p[i] for p in points) for i in range(3)]
    scale = TARGET_HEIGHT / (high[2] - low[2])
    base = Matrix.Scale(scale, 4) @ Matrix.Rotation(math.pi, 4, "Z")
    turned = [base @ p for p in points]
    tl = [min(p[i] for p in turned) for i in range(3)]
    th = [max(p[i] for p in turned) for i in range(3)]
    offset = Vector((-(tl[0] + th[0]) * 0.5, 0.0, -tl[2]))
    return [p + offset for p in turned]


def span(values):
    return (min(values), max(values)) if values else (float("nan"),) * 2


def inventory():
    """What the source actually contains, before assuming anything about it."""
    print("--- objects ---")
    for obj in bpy.data.objects:
        print("%-20s %-10s verts=%s" % (
            obj.name, obj.type,
            len(obj.data.vertices) if obj.type == "MESH" else "-"))
        if obj.type == "ARMATURE":
            print("  bones: %s" % ", ".join(
                bone.name for bone in obj.data.bones))
    mesh = bpy.data.objects["geometry_0"].data
    print("--- geometry_0 ---")
    print("verts=%d polys=%d tris=%d" % (
        len(mesh.vertices), len(mesh.polygons),
        sum(max(len(p.vertices) - 2, 0) for p in mesh.polygons)))
    print("uv layers: %s" % ([layer.name for layer in mesh.uv_layers] or "none"))
    print("color attributes: %s" % ([
        "%s(%s/%s)" % (c.name, c.domain, c.data_type)
        for c in mesh.color_attributes] or "none"))
    print("materials: %s" % ([m.name if m else None
                              for m in mesh.materials] or "none"))
    print("vertex groups: %s" % ([
        g.name for g in bpy.data.objects["geometry_0"].vertex_groups] or "none"))


def report():
    inventory()
    points = normalized_points()
    low = [min(p[i] for p in points) for i in range(3)]
    high = [max(p[i] for p in points) for i in range(3)]
    height = high[2] - low[2]
    print("bounds low=%s high=%s" % (
        tuple(round(v, 3) for v in low), tuple(round(v, 3) for v in high)))

    print("--- z bands (x span, y span, count) ---")
    for band in range(BANDS):
        z0 = low[2] + height * band / BANDS
        z1 = low[2] + height * (band + 1) / BANDS
        inside = [p for p in points if z0 <= p.z < z1]
        xs = span([p.x for p in inside])
        ys = span([p.y for p in inside])
        print("z %.3f..%.3f  n=%4d  x %.3f..%.3f  y %.3f..%.3f" % (
            z0, z1, len(inside), xs[0], xs[1], ys[0], ys[1]))

    print("--- y bands (front +Y is the head) ---")
    y_low, y_high = low[1], high[1]
    for band in range(BANDS):
        y0 = y_low + (y_high - y_low) * band / BANDS
        y1 = y_low + (y_high - y_low) * (band + 1) / BANDS
        inside = [p for p in points if y0 <= p.y < y1]
        xs = span([p.x for p in inside])
        zs = span([p.z for p in inside])
        print("y %.3f..%.3f  n=%4d  x %.3f..%.3f  z %.3f..%.3f" % (
            y0, y1, len(inside), xs[0], xs[1], zs[0], zs[1]))

    print("--- foot clusters: verts below 12%% height, by side and end ---")
    ankle_band = [p for p in points if p.z < low[2] + height * 0.12]
    for side_name, keep_x in (("Left(x<0)", lambda x: x < 0.0),
                              ("Right(x>0)", lambda x: x >= 0.0)):
        for end_name, keep_y in (("Front(+Y)", lambda y: y > 0.0),
                                 ("Back(-Y)", lambda y: y <= 0.0)):
            inside = [p for p in ankle_band
                      if keep_x(p.x) and keep_y(p.y)]
            if not inside:
                print("%s %s: empty" % (side_name, end_name))
                continue
            centre = sum(inside, Vector()) / len(inside)
            xs = span([p.x for p in inside])
            ys = span([p.y for p in inside])
            print("%s %s n=%4d centre=%s x %.3f..%.3f y %.3f..%.3f" % (
                side_name, end_name, len(inside),
                tuple(round(v, 3) for v in centre), xs[0], xs[1],
                ys[0], ys[1]))

    print("--- leg columns: x span per (y band, low z) to find leg tops ---")
    for band in range(8):
        z0 = low[2] + height * band / 8.0
        z1 = low[2] + height * (band + 1) / 8.0
        inside = [p for p in points if z0 <= p.z < z1]
        front = [p for p in inside if p.y > 0.0]
        back = [p for p in inside if p.y <= 0.0]
        print("z %.3f..%.3f  front n=%4d x %s | back n=%4d x %s" % (
            z0, z1, len(front), tuple(round(v, 3) for v in span(
                [p.x for p in front])),
            len(back), tuple(round(v, 3) for v in span(
                [p.x for p in back]))))


report()
