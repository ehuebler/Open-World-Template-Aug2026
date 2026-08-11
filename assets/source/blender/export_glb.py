"""Exports the character in the currently open .blend to the Godot .glb.

Run headless from the project root, with the same Blender version that saved the
file (opening a newer .blend in an older Blender silently drops data):

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/player_character.blend --python assets/source/blender/export_glb.py

Use this after editing the .blend by hand. Unlike build_character.py it never
touches the mesh or the rig, and it never saves the .blend, so hand edits
survive. It prints a summary of what it found first, which is the quickest way
to spot a rig or transform change that would break the Godot import.
"""

import os

import bpy
from mathutils import Matrix, Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
GLB_PATH = os.path.join(
    PROJECT_DIR, "assets", "runtime", "characters", "player_character.glb")

EXPORTABLE = {"MESH", "ARMATURE"}

# Garments ship as their own .glb files, written by build_apparel.py, so that the
# wardrobe can put them on and take them off at runtime. Exporting them into the
# body would weld them to the character permanently.
SKIP_COLLECTIONS = {"Apparel"}


def exportable_objects():
    return [obj for obj in bpy.data.objects
            if obj.type in EXPORTABLE and not skipped(obj)]


def skipped(obj):
    return any(collection.name in SKIP_COLLECTIONS for collection in obj.users_collection)


def describe_mesh(obj):
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    print("  {0} [MESH] polys={1} exported={2} materials={3}".format(
        obj.name,
        len(obj.data.polygons),
        len(evaluated.data.polygons),
        [slot.material.name if slot.material else "<none>" for slot in obj.material_slots]))
    if not obj.data.uv_layers:
        print("    WARNING no UV map")
    if obj.mode != "OBJECT":
        print("    WARNING saved in {0} mode".format(obj.mode))


def describe_armature(obj):
    deforming = [bone.name for bone in obj.data.bones if bone.use_deform]
    print("  {0} [ARMATURE] bones={1} deforming={2}".format(
        obj.name, len(obj.data.bones), len(deforming)))

    posed = [bone.name for bone in obj.pose.bones
             if bone.matrix_basis != Matrix.Identity(4)]
    if posed:
        print("    NOTE posed away from rest: {0}".format(posed))
        print("         glTF skins export from the rest pose, so this is a preview"
              " state rather than part of the asset.")


def describe_modifiers(obj):
    for modifier in obj.modifiers:
        line = "    modifier {0} [{1}] viewport={2} render={3}".format(
            modifier.name, modifier.type, modifier.show_viewport, modifier.show_render)
        if modifier.type == "DECIMATE":
            line += " mode={0} ratio={1:.4f} faces_out={2}".format(
                modifier.decimate_type, modifier.ratio, modifier.face_count)
        print(line)


def describe_transform(obj):
    if obj.matrix_world == Matrix.Identity(4):
        return
    print("    transform scale={0} rotation={1} location={2}".format(
        tuple(round(value, 4) for value in obj.matrix_world.to_scale()),
        tuple(round(value, 4) for value in obj.matrix_world.to_euler()),
        tuple(round(value, 4) for value in obj.matrix_world.translation)))


def report_bounds(objects):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    low = Vector((1.0e9, 1.0e9, 1.0e9))
    high = Vector((-1.0e9, -1.0e9, -1.0e9))
    for obj in objects:
        if obj.type != "MESH":
            continue
        evaluated = obj.evaluated_get(depsgraph)
        for corner in evaluated.bound_box:
            world = evaluated.matrix_world @ Vector(corner)
            for axis in range(3):
                low[axis] = min(low[axis], world[axis])
                high[axis] = max(high[axis], world[axis])
    if low.x > high.x:
        return
    print("bounds: width={0:.3f} depth={1:.3f} height={2:.3f}".format(
        high.x - low.x, high.y - low.y, high.z - low.z))
    print("floor:  {0:+.4f} m  (0 keeps the feet on the ground in Godot)".format(low.z))


def describe(objects):
    print("---- source file ----")
    print("blend: {0}".format(bpy.data.filepath or "<unsaved>"))
    for obj in objects:
        if obj.type == "MESH":
            describe_mesh(obj)
        else:
            describe_armature(obj)
        describe_transform(obj)
        describe_modifiers(obj)
    skipped_names = [obj.name for obj in bpy.data.objects if obj.type in EXPORTABLE and skipped(obj)]
    if skipped_names:
        print("skipped (exported separately): {0}".format(skipped_names))
    print("actions: {0}".format([action.name for action in bpy.data.actions] or "none"))
    report_bounds(objects)
    print("---------------------")


def export(objects):
    # Selection is set through the data API rather than bpy.ops, because the
    # operator poll fails against the UI context restored from a saved .blend.
    # Unhide before selecting, in two passes: writing hide_viewport resyncs the
    # view layer and clears the selection made so far, so interleaving the two
    # leaves only the last object selected and exports a partial character.
    view_layer = bpy.context.view_layer
    for obj in objects:
        obj.hide_viewport = False
    for obj in view_layer.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    view_layer.objects.active = objects[0]
    selected = [obj.name for obj in bpy.context.selected_objects]
    print("exporting: {0}".format(selected))
    missing = [obj.name for obj in objects if obj.name not in selected]
    if missing:
        raise SystemExit("selection failed for {0}: the export would be partial".format(missing))

    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_skins=True,
        export_animations=bool(bpy.data.actions),
        # One glTF animation per NLA track, which is how the clips are stored.
        # The exporter's default "Actions" mode silently writes nothing for the
        # slotted actions Blender 4.4+ produces, which drops every clip.
        export_animation_mode="NLA_TRACKS",
        export_frame_range=False,
        export_force_sampling=True,
        export_yup=True,
    )
    print("wrote {0} ({1:.1f} KB)".format(GLB_PATH, os.path.getsize(GLB_PATH) / 1024.0))


def main():
    objects = exportable_objects()
    if not objects:
        raise SystemExit("nothing to export: no mesh or armature objects in the file")
    describe(objects)
    export(objects)


if __name__ == "__main__":
    main()
