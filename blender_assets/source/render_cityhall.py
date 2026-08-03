"""Renders previews of the city hall, before and after `paint_cityhall.py`.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background generated/cityhall.blend --python blender_assets/source/render_cityhall.py

Images land in blender_assets/source/previews/. Every framing is shot twice: lit,
and again with the vertex colours pushed straight through an emission shader.
The flat pass is the one that matters when judging paint, because a lit render
cannot tell a bad paint job from a bad light rig - which is exactly how this
asset's original streaked, blue-banded vertex colours passed for "a bit dark".

Pass `-- --source` to shoot the generator's original paint instead, which
`paint_cityhall.py` keeps in the `ColorSource` attribute.
"""

import os
import sys

import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import previewkit  # noqa: E402

OUTPUT_DIR = os.path.join(SOURCE_DIR, "previews")
RESOLUTION = (900, 700)
SAMPLES = 64

VIEWS = {
    "front": Vector((0.0, -1.0, 0.45)),
    "corner": Vector((0.75, -0.75, 0.50)),
    "side": Vector((1.0, 0.0, 0.35)),
    "top": Vector((0.01, -0.01, 1.20)),
}


def find_mesh():
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh in " + bpy.data.filepath)
    return max(meshes, key=lambda o: len(o.data.vertices))


def set_surface(obj, emissive, layer):
    """Point the material at `layer`, lit or flat."""
    tree = obj.data.materials[0].node_tree
    output = tree.nodes["Material Output"]
    vertex_colour = next(n for n in tree.nodes if n.bl_idname == "ShaderNodeVertexColor")
    vertex_colour.layer_name = layer
    for link in list(output.inputs["Surface"].links):
        tree.links.remove(link)
    if emissive:
        emission = tree.nodes.get("PreviewEmission") or tree.nodes.new("ShaderNodeEmission")
        emission.name = "PreviewEmission"
        tree.links.new(vertex_colour.outputs["Color"], emission.inputs["Color"])
        tree.links.new(emission.outputs["Emission"], output.inputs["Surface"])
    else:
        bsdf = tree.nodes["Principled BSDF"]
        tree.links.new(vertex_colour.outputs["Color"], bsdf.inputs["Base Color"])
        tree.links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    layer = "ColorSource" if "--source" in argv else "Color"
    obj = find_mesh()
    if layer not in obj.data.color_attributes:
        raise SystemExit("no '{0}' attribute; run paint_cityhall.py first".format(layer))

    centre = Vector((0.0, 0.0, obj.dimensions.z * 0.5))
    reach = max(obj.dimensions) * 1.5
    preview = previewkit.Preview(OUTPUT_DIR, samples=SAMPLES)
    # The rig is scaled to a 180-unit building, not a prop: `spread` carries the
    # inverse-square correction, so the exposure holds at this size.
    preview.lights(centre, spread=reach * 0.45)

    suffix = "_source" if layer == "ColorSource" else ""
    for tag, emissive in (("lit", False), ("flat", True)):
        set_surface(obj, emissive, layer)
        for name, offset in VIEWS.items():
            preview.hero(centre + offset * reach, centre, lens=50.0)
            preview.shot("cityhall_{0}_{1}{2}".format(name, tag, suffix), RESOLUTION)
            print("rendered cityhall_{0}_{1}{2}".format(name, tag, suffix))


if __name__ == "__main__":
    main()
