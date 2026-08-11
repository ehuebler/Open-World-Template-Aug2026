"""Turns the two MeshMaker .blend files at Vacationer's Landing into game .glb files.

Run headless from the project root; it needs no input file of its own, because it
opens each source in turn:

    $blender = "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe"
    & $blender --background --factory-startup --python assets/source/blender/build_landing.py

It writes `assets/runtime/environment/colony_ship.glb` and `assets/runtime/biomes/models/purple_flower.glb`,
and never saves the sources in `assets/source/meshmaker/`, so re-exporting either of them from
MeshMaker and running this again is the whole of the update path.

What it is for is the triangle count. MeshMaker hands out about 60,000 triangles
whatever the subject is, which is generous for a 26 m ship and absurd for a
flower there are twenty thousand of. Both come down by a collapse decimate,
which keeps the vertex colours the whole look is carried in.

Three details are load-bearing:

- **The decimate is applied here, not at export.** glTF's `export_apply` runs the
  modifier stack, and doing it at export time gives up control over the order
  the modifiers are applied in, which is what decides whether the vertex colours
  survive the collapse.
- **The ship's collider is a second, much coarser object.** Godot's `-colonly`
  suffix turns it into a StaticBody3D with a trimesh shape and no mesh to draw,
  so the ship collides as its own silhouette — four legs you can walk between —
  without the 69 ms it costs to build a BVH over the full sixty thousand faces.
- **The flower's armature is thrown away and it goes out twice.** Its sway is a
  vertex shader now rather than a skeleton, and the field it grows in is a
  MultiMesh, which can draw a plain mesh by the thousand and cannot draw a
  skinned one at all. The second copy is the far LOD: past thirty metres a bloom
  is a few pixels of purple and the near mesh is spending five hundred triangles
  on them.
"""

import os
import sys

import bpy

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
ENVIRONMENT_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "environment")
BIOME_MODEL_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "biomes", "models")

# Triangles wanted out, per object. The ship is looked at from twenty metres and
# is one draw in the world, so it keeps enough to hold its greebles. The flower
# is charged per triangle by the ten thousand, so it keeps a silhouette and its
# petals and nothing else; see GroundCover for how the two levels are spent. The
# collider only has to be the shape you bump into.
SHIP_FACES = 20000
SHIP_COLLIDER_FACES = 3600
FLOWER_FACES = 520
FLOWER_FAR_FACES = 110


def biggest_mesh():
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh in " + (bpy.data.filepath or "<unsaved>"))
    return max(meshes, key=lambda obj: len(obj.data.vertices))


def armatures():
    return [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]


def activate(obj):
    view_layer = bpy.context.view_layer
    for other in view_layer.objects:
        other.select_set(False)
    obj.hide_viewport = False
    obj.select_set(True)
    view_layer.objects.active = obj


def decimate(obj, wanted_faces):
    """Collapse `obj` down to about `wanted_faces` triangles, in place."""
    before = len(obj.data.polygons)
    if before <= wanted_faces:
        print("  {0}: {1} faces, already under {2}".format(obj.name, before, wanted_faces))
        return
    modifier = obj.modifiers.new("Decimate", "DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = float(wanted_faces) / float(before)
    modifier.use_collapse_triangulate = True
    activate(obj)
    # Ahead of the armature, or Blender applies a modifier out of order and the
    # weights come through the collapse having already been deformed.
    bpy.ops.object.modifier_move_to_index(modifier=modifier.name, index=0)
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    print("  {0}: {1} faces -> {2}".format(obj.name, before, len(obj.data.polygons)))


def export(objects, filename):
    view_layer = bpy.context.view_layer
    for obj in view_layer.objects:
        obj.select_set(False)
    for obj in objects:
        obj.hide_viewport = False
        obj.select_set(True)
    view_layer.objects.active = objects[0]

    output_dir = ENVIRONMENT_DIR if filename == "colony_ship.glb" else BIOME_MODEL_DIR
    path = os.path.join(output_dir, filename)
    settings = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        # False, deliberately: see the note in the module docstring. Every
        # modifier that mattered has already been applied above.
        export_apply=False,
        export_skins=True,
        export_animations=False,
        export_yup=True,
    )
    try:
        # MeshMaker paints into a colour attribute and leaves the material
        # reading it, but "MATERIAL" only exports what the shader graph happens
        # to reference, and a decimate can drop that link. The whole look is in
        # these colours, so they go out whatever the material says.
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **settings)
    except TypeError:
        bpy.ops.export_scene.gltf(**settings)
    print("wrote {0} ({1:.0f} KB)".format(path, os.path.getsize(path) / 1024.0))


def open_source(name):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(
        PROJECT_DIR, "assets", "source", "meshmaker", name))


def build_ship():
    print("colony_ship.blend")
    open_source("colony_ship.blend")
    hull = biggest_mesh()
    hull.name = "ColonyShip"
    hull.data.name = "ColonyShipMesh"

    # The rig is MeshMaker's boilerplate and this prop never bends, so the skin
    # goes with it: a static 20k mesh should not be paying to be skinned every
    # frame against three bones that never move.
    for modifier in list(hull.modifiers):
        if modifier.type == "ARMATURE":
            hull.modifiers.remove(modifier)
    hull.vertex_groups.clear()
    for rig in armatures():
        bpy.data.objects.remove(rig, do_unlink=True)

    collider = hull.copy()
    collider.data = hull.data.copy()
    collider.name = "ColonyShipHull-colonly"
    collider.data.name = "ColonyShipColliderMesh"
    bpy.context.scene.collection.objects.link(collider)

    decimate(hull, SHIP_FACES)
    decimate(collider, SHIP_COLLIDER_FACES)
    print("  standing {0:.1f} m tall on a {1:.1f} m span".format(
        hull.dimensions.z, max(hull.dimensions.x, hull.dimensions.y)))
    export([hull, collider], "colony_ship.glb")


def build_flower():
    print("purple_closed_flower.blend")
    open_source("purple_closed_flower.blend")
    flower = biggest_mesh()
    flower.name = "PurpleFlower"
    flower.data.name = "PurpleFlowerMesh"

    # The rig goes. The bend is a rotation about the base with height as its
    # lever arm, which is what the two bones described and what the vertex
    # shader now computes from the vertex's own height — for nothing, on the
    # GPU, for every bloom in the field at once.
    for modifier in list(flower.modifiers):
        if modifier.type == "ARMATURE":
            flower.modifiers.remove(modifier)
    flower.vertex_groups.clear()
    for rig in armatures():
        bpy.data.objects.remove(rig, do_unlink=True)

    distant = flower.copy()
    distant.data = flower.data.copy()
    distant.name = "PurpleFlowerFar"
    distant.data.name = "PurpleFlowerFarMesh"
    bpy.context.scene.collection.objects.link(distant)

    decimate(flower, FLOWER_FACES)
    decimate(distant, FLOWER_FAR_FACES)
    print("  standing {0:.2f} m tall on a {1:.2f} m spread".format(
        flower.dimensions.z, max(flower.dimensions.x, flower.dimensions.y)))
    export([flower, distant], "purple_flower.glb")


def main():
    build_ship()
    build_flower()


if __name__ == "__main__":
    main()
