"""Front/side ortho renders of every mesh in a .blend, and which way it faces.

    blender --background <file.blend> --python dev/_render_mesh.py -- --out=NAME

The facing line is the reason this exists as well as the pictures. Everything in
`build_character_3.py` is measured off the mesh on the assumption that it faces
+Y the way the astronaut does, and a sculpt that arrives facing the other way
does not fail loudly — it builds a rig whose toes are its heels.
"""

import os
import sys

import bpy

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "source", "blender"))
import previewkit  # noqa: E402

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "previews", "authoring")


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = "mesh"
    for entry in argv:
        if entry.startswith("--out="):
            out = entry.split("=", 1)[1]

    meshes = [o for o in bpy.data.objects
              if o.type == "MESH" and "Icosphere" not in o.name]
    biggest = max(meshes, key=lambda o: len(o.data.vertices))
    for obj in meshes:
        obj.hide_render = obj is not biggest

    top = max((biggest.matrix_world @ v.co).z for v in biggest.data.vertices)
    mid = top * 0.5
    preview = previewkit.Preview(OUT_DIR, samples=32)
    preview.ground(0.0)
    preview.lights((0.0, 0.0, mid), spread=1.7)
    preview.ortho((0.0, -4.0, mid), (0.0, 0.0, mid), top * 1.3)
    preview.shot(out + "_front", (440, 660))
    preview.ortho((-4.0, 0.0, mid), (0.0, 0.0, mid), top * 1.3)
    preview.shot(out + "_side", (440, 660))
    preview.hero((2.4, -3.0, mid + 0.9), (0.0, 0.0, mid), lens=70.0)
    preview.shot(out + "_hero", (440, 660))
    print("top", top, "verts", len(biggest.data.vertices))
    report_facing(biggest)


def report_facing(obj):
    """Which way the sculpt's toes point, and by how much.

    A foot is the one part of a body that is decisively longer in front than
    behind, so the sole's own centre of area sits forward of the ankle it hangs
    off. Faces, chests and hair are all far weaker signals on a stylised sculpt,
    and hair in particular reads backwards.
    """
    coords = [obj.matrix_world @ v.co for v in obj.data.vertices]
    floor = min(p.z for p in coords)
    top = max(p.z for p in coords)
    height = top - floor
    sole = [p for p in coords if p.z < floor + height * 0.04]
    shin = [p for p in coords if floor + height * 0.14 < p.z < floor + height * 0.2]
    if not sole or not shin:
        print("facing: no feet found")
        return
    ankle_y = sum(p.y for p in shin) / len(shin)
    toe_y = max(p.y for p in sole)
    heel_y = min(p.y for p in sole)
    forward = "+Y" if (toe_y - ankle_y) > (ankle_y - heel_y) else "-Y"
    print("facing: {0}  (ankle y={1:.3f}, sole spans {2:.3f}..{3:.3f})".format(
        forward, ankle_y, heel_y, toe_y))


main()
