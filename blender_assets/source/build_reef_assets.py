"""Build the reef: four corals and the small fish that swarm around them.

Run from the repository root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python blender_assets/source/build_reef_assets.py

The sources in ``generated/`` are MeshMaker output and are opened read-only.
Each is a 60,000-triangle shell carrying a ``Color`` vertex attribute, an
armature that drives nothing, and — in the small fish's case — a handful of
vertices pulled out into spikes.  All three of those have to go before any of it
can be instanced ten thousand times.

What comes out:

    coral_pink.glb  coral_blue.glb  coral_purple.glb  coral_green.glb
        Static, decimated, vertex-coloured.  No rig and no animation: coral
        bends in the current through `vivid_plant`'s own wind rotation, the same
        way the flowers do, so it needs nothing baked.
    small_fish_vat.glb / .exr / .json
        The swarm fish, with a swim cycle baked into a position texture the same
        way the big fish's is.  MeshMaker gave it no action, so the tail wave is
        authored here out of two shape keys.
"""

from __future__ import annotations

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir, os.pardir))
OUTPUT_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_vat

FPS = 24
SMALL_FISH_FRAMES = 24
SMALL_FISH_TRIANGLES = 150
# Corals are read at up to a few hundred instances inside the murk's own
# visibility, so they can afford more than a blade of grass and nothing like
# what MeshMaker handed over.
CORALS = (
    ("pink_coral.blend", "CoralPink", 900),
    ("blue_coral.blend", "CoralBlue", 800),
    ("purple_coral.blend", "CoralPurple", 800),
    ("green_coral.blend", "CoralGreen", 700),
)


def _open_source(filename: str) -> None:
    path = os.path.join(PROJECT_DIR, "generated", filename)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    bpy.ops.wm.open_mainfile(filepath=path)


def _biggest_mesh() -> bpy.types.Object:
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("source file has no mesh")
    return max(meshes, key=lambda obj: len(obj.data.vertices))


def _activate(obj: bpy.types.Object) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.hide_viewport = False
    obj.hide_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def _strip_rig(obj: bpy.types.Object) -> None:
    """Take the mesh off its armature and delete every other object.

    MeshMaker parents everything it exports to a rig it never animates.  Left
    in place that rig becomes a glTF skin, and a skin is the one thing a
    MultiMesh cannot draw: the whole point of both halves of this file is that
    nothing on screen has a skeleton.
    """

    for modifier in list(obj.modifiers):
        if modifier.type == "ARMATURE":
            obj.modifiers.remove(modifier)
    if obj.parent is not None:
        world = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = world
    obj.animation_data_clear()
    for other in list(bpy.data.objects):
        if other is not obj:
            bpy.data.objects.remove(other, do_unlink=True)


def _drop_loose(mesh: bpy.types.Mesh) -> int:
    """Delete vertices no face uses. Counts what went."""

    working = bmesh.new()
    working.from_mesh(mesh)
    loose = [vertex for vertex in working.verts if not vertex.link_faces]
    if loose:
        bmesh.ops.delete(working, geom=loose, context="VERTS")
    working.to_mesh(mesh)
    working.free()
    mesh.update()
    return len(loose)


def _despike(mesh: bpy.types.Mesh, tolerance: float = 4.0, rounds: int = 4) -> int:
    """Pull stray vertices back onto the surface their neighbours describe.

    The fault this fixes is a vertex sitting a long way off the shell with its
    edges stretched out to reach it — a spike.  Decimating first would not help:
    a collapse keeps the silhouette, and a spike *is* the silhouette as far as
    the modifier is concerned, so it survives into the low-poly mesh as a long
    thin triangle that catches the light from every angle.

    A vertex is judged against the average of the vertices it is joined to, and
    the scale it is judged at is the median edge length of the mesh as a whole:
    on a shell this dense a vertex four median edges away from its own
    neighbourhood did not get there by being modelled.  Moving it onto that
    average rather than deleting it keeps the surface closed, which is what
    lets this run before decimation instead of leaving holes for it to chew on.
    """

    if not mesh.edges:
        return 0
    lengths = sorted(
        (mesh.vertices[edge.vertices[0]].co - mesh.vertices[edge.vertices[1]].co).length
        for edge in mesh.edges
    )
    limit = lengths[len(lengths) // 2] * tolerance
    neighbours: list[list[int]] = [[] for _ in mesh.vertices]
    for edge in mesh.edges:
        first, second = edge.vertices
        neighbours[first].append(second)
        neighbours[second].append(first)

    moved = 0
    for _round in range(rounds):
        changes = []
        for index, vertex in enumerate(mesh.vertices):
            near = neighbours[index]
            if not near:
                continue
            centre = Vector((0.0, 0.0, 0.0))
            for other in near:
                centre += mesh.vertices[other].co
            centre /= len(near)
            if (vertex.co - centre).length > limit:
                changes.append((index, centre))
        if not changes:
            break
        for index, centre in changes:
            mesh.vertices[index].co = centre
        moved += len(changes)
    mesh.update()
    return moved


def _decimate(obj: bpy.types.Object, target_triangles: int,
              *, minimum: int, maximum: int) -> int:
    before = build_vat.triangle_count(obj.data)
    if before <= target_triangles:
        raise ValueError("{} already has only {} triangles".format(obj.name, before))
    colors = {attribute.name for attribute in obj.data.color_attributes}
    if not colors:
        raise ValueError("{} has no MeshMaker vertex colors".format(obj.name))
    modifier = obj.modifiers.new("ReefTopology", "DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = float(target_triangles) / float(before)
    modifier.use_collapse_triangulate = True
    _activate(obj)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    after = build_vat.triangle_count(obj.data)
    if not minimum <= after <= maximum:
        raise ValueError("{} decimated to {} triangles, expected {}..{}".format(
            obj.name, after, minimum, maximum))
    if not colors.issubset({attribute.name for attribute in obj.data.color_attributes}):
        raise ValueError("decimation dropped a vertex-color attribute")
    print("  decimated {} -> {} triangles, {} vertices".format(
        before, after, len(obj.data.vertices)))
    return after


def _sit_on_the_origin(obj: bpy.types.Object) -> None:
    """Move the mesh so its base is at z=0 and its footprint is centred.

    Everything `GroundCover` plants is placed by its own origin and grown up
    local +Y after the glTF axis swap, so a model whose origin is anywhere else
    is a model that floats or sinks by however far it is out.
    """

    low = Vector((1e9, 1e9, 1e9))
    high = Vector((-1e9, -1e9, -1e9))
    for vertex in obj.data.vertices:
        for axis in range(3):
            low[axis] = min(low[axis], vertex.co[axis])
            high[axis] = max(high[axis], vertex.co[axis])
    shift = Vector(((low.x + high.x) * 0.5, (low.y + high.y) * 0.5, low.z))
    for vertex in obj.data.vertices:
        vertex.co -= shift
    obj.data.update()


def _export_static(obj: bpy.types.Object, node_name: str, path: str) -> None:
    obj.name = node_name
    obj.data.name = node_name + "Mesh"
    _activate(obj)
    settings = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_normals=True,
        export_skins=False,
        export_animations=False,
        export_materials="EXPORT",
    )
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **settings)
    except TypeError:
        # The vertex-color switch has been renamed more than once across
        # releases. The COLOR_0 check below is what actually holds the line.
        bpy.ops.export_scene.gltf(**settings)
    document, _binary = build_vat._read_glb(path)
    if document.get("skins") or document.get("animations"):
        raise ValueError("{} exported with a rig or an action".format(node_name))
    for mesh in document.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            if "COLOR_0" not in primitive.get("attributes", {}):
                raise ValueError("{} lost its vertex colors".format(node_name))
    print("  wrote {} ({:.0f} KB)".format(
        os.path.basename(path), os.path.getsize(path) / 1024.0))


def build_coral(filename: str, node_name: str, target_triangles: int) -> dict:
    print("\n=== {} ===".format(node_name))
    _open_source(filename)
    coral = _biggest_mesh()
    _strip_rig(coral)
    loose = _drop_loose(coral.data)
    moved = _despike(coral.data)
    print("  cleaned: {} loose vertices dropped, {} spikes pulled in".format(
        loose, moved))
    triangles = _decimate(
        coral,
        target_triangles,
        minimum=int(target_triangles * 0.7),
        maximum=int(target_triangles * 1.35),
    )
    _sit_on_the_origin(coral)
    height = max(vertex.co.z for vertex in coral.data.vertices)
    path = os.path.join(OUTPUT_DIR, node_name.lower().replace("coral", "coral_") + ".glb")
    _export_static(coral, node_name, path)
    return {
        "node": node_name,
        "triangles": triangles,
        "vertices": len(coral.data.vertices),
        "authored_height": round(height, 4),
        "glb": os.path.basename(path),
    }


# --- The swarm fish ----------------------------------------------------------

def _pale(mesh: bpy.types.Mesh) -> None:
    """Repaint the fish from black to a light neutral.

    The swarm is tinted per instance out of the MultiMesh colour, and an
    instance colour is a multiply: any hue at all times black is black. What is
    kept is the shading the bake put there — the relative light and dark across
    the body — stretched into a range that has something left to multiply.
    """

    colors = mesh.color_attributes.active_color
    if colors is None:
        raise ValueError("small fish has no vertex colors to repaint")
    values = []
    for item in colors.data:
        pixel = item.color
        values.append(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
    darkest = min(values)
    brightest = max(values)
    span = brightest - darkest
    for index, item in enumerate(colors.data):
        level = 0.75 if span < 1.0e-4 else 0.45 + 0.55 * (values[index] - darkest) / span
        item.color = (level, level, level, 1.0)
    print("  repainted: luma {:.3f}..{:.3f} -> grey 0.45..1.00".format(darkest, brightest))


def _create_swim(fish: bpy.types.Object) -> bpy.types.Action:
    """A tail wave out of two shape keys, driven round a periodic action.

    MeshMaker exported no action, and a bone rig for something this small would
    be four bones to describe a sine. Two signed keys — one the whole body, one
    the tail alone and a quarter cycle behind it — is the same wave with nothing
    to pose: the lag between them is what makes it travel down the fish instead
    of the whole animal wagging.
    """

    low = min(vertex.co.x for vertex in fish.data.vertices)
    high = max(vertex.co.x for vertex in fish.data.vertices)
    length = max(high - low, 1.0e-5)
    width = max(max(abs(vertex.co.y) for vertex in fish.data.vertices), 1.0e-5)

    basis = fish.shape_key_add(name="Basis")
    body = fish.shape_key_add(name="SwimBody")
    tail = fish.shape_key_add(name="SwimTail")
    for key in (body, tail):
        key.slider_min = -1.0
        key.slider_max = 1.0
    for index, vertex in enumerate(fish.data.vertices):
        # 0 at the nose (+X is forward on every MeshMaker fish), 1 at the tail.
        back = (high - vertex.co.x) / length
        body.data[index].co = basis.data[index].co + Vector((
            0.0, width * 2.6 * back * back, 0.0))
        tail.data[index].co = basis.data[index].co + Vector((
            0.0, width * 3.4 * back * back * back * back, 0.0))

    endpoint = SMALL_FISH_FRAMES
    for frame in range(endpoint + 1):
        phase = math.tau * frame / endpoint
        body.value = 0.7 * math.sin(phase)
        tail.value = 0.85 * math.sin(phase - math.pi * 0.5)
        body.keyframe_insert(data_path="value", frame=frame, group="SmallFishSwim")
        tail.keyframe_insert(data_path="value", frame=frame, group="SmallFishSwim")
    shape_keys = fish.data.shape_keys
    if shape_keys.animation_data is None or shape_keys.animation_data.action is None:
        raise RuntimeError("Blender did not create the small fish swim action")
    action = shape_keys.animation_data.action
    action.name = "small_fish_swim"
    bpy.context.scene.frame_set(0)
    return action


def build_small_fish() -> dict:
    print("\n=== SmallFishVAT ===")
    _open_source("small_fish.blend")
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1.0
    scene.frame_start = 0
    scene.frame_end = SMALL_FISH_FRAMES - 1
    scene.frame_set(0)

    fish = _biggest_mesh()
    _strip_rig(fish)
    loose = _drop_loose(fish.data)
    moved = _despike(fish.data)
    print("  cleaned: {} loose vertices dropped, {} spikes pulled in".format(
        loose, moved))
    _decimate(fish, SMALL_FISH_TRIANGLES, minimum=100, maximum=220)
    # Again after the collapse: decimating a cleaned shell can still leave a
    # single vertex standing proud where three faces met at a point.
    _despike(fish.data, tolerance=2.5, rounds=3)
    _pale(fish.data)
    _sit_on_the_origin(fish)
    if len(fish.data.vertices) > 200:
        raise ValueError("small fish VAT would need a {}-wide texture".format(
            len(fish.data.vertices)))
    _create_swim(fish)

    result = build_vat.bake(
        fish,
        range(SMALL_FISH_FRAMES),
        fps=FPS,
        output_base=os.path.join(OUTPUT_DIR, "small_fish_vat"),
        node_name="SmallFishVAT",
        mesh_name="SmallFishVATMesh",
        loop=True,
        loop_endpoint=SMALL_FISH_FRAMES,
        loop_tolerance=2.0e-4,
    )
    return {
        "vertices": result.vertex_count,
        "triangles": result.triangle_count,
        "frames": result.frame_count,
        "loop_endpoint_error": result.loop_endpoint_error,
        "glb": os.path.basename(result.glb_path),
    }


def main() -> None:
    summary = {}
    for filename, node_name, triangles in CORALS:
        summary[node_name] = build_coral(filename, node_name, triangles)
    summary["SmallFishVAT"] = build_small_fish()
    print("\nREEF_BUILD_SUMMARY")
    print(json.dumps(summary, indent=2, sort_keys=True))
    print("reef build complete")


if __name__ == "__main__":
    main()
