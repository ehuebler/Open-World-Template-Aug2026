"""Build the rigged, animated runtime Volcanoronomous from its source sculpt.

Run from the project root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_volcanoronomous.py

MeshMaker supplied a coloured dragon sculpt with only its provisional root/spine
groups and no armature.  This deterministic recipe keeps the source blend
read-only, normalises and budgets the sculpt, fits a full quadruped/wing/tail
skeleton, creates heat weights with side/limb clean-up, bakes the encounter
clips, and exports the active corner colour as glTF COLOR_0.
"""

from __future__ import annotations

import hashlib
import importlib.util
import math
import os

import bpy
from mathutils import Matrix, Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
SRC_BLEND = os.path.join(
    ROOT, "assets", "source", "meshmaker", "volcanoronomous.blend")
OUT_BLEND = os.path.join(
    ROOT, "assets", "work", "volcanoronomous_rigged.blend")
OUT_GLB = os.path.join(
    ROOT, "assets", "runtime", "characters", "volcanoronomous.glb")

TARGET_WINGSPAN = 15.0
TARGET_TRIANGLES = 36_000
FPS = 30

REQUIRED_BONES = (
    "Root", "Hips", "Spine", "Chest", "Neck", "Head", "LowerJaw",
    "LeftWingBase", "LeftWingMid", "LeftWingTip",
    "RightWingBase", "RightWingMid", "RightWingTip",
    "LeftFrontUpperArm", "LeftFrontLowerArm", "LeftFrontClaw",
    "RightFrontUpperArm", "RightFrontLowerArm", "RightFrontClaw",
    "Tail01", "Tail02", "Tail03", "Tail04",
    "LeftHindUpperLeg", "LeftHindLowerLeg", "LeftHindClaw",
    "RightHindUpperLeg", "RightHindLowerLeg", "RightHindClaw",
)
DEFORM_BONES = REQUIRED_BONES[1:]


def load_sibling(filename: str, suffix: str):
    path = os.path.join(SOURCE_DIR, filename)
    spec = importlib.util.spec_from_file_location(
        os.path.splitext(filename)[0] + suffix, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REQUIRED_CLIPS = load_sibling(
    "boss_manifest.py", "_volcanoronomous_manifest").required_clips(
        "volcanoronomous",
        recipe_path=__file__,
        source_path=SRC_BLEND,
        runtime_path=OUT_GLB,
    )


def activate(obj: bpy.types.Object) -> None:
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for other in bpy.context.view_layer.objects:
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


def mesh_bounds(mesh_obj: bpy.types.Object) -> tuple[Vector, Vector]:
    points = [mesh_obj.matrix_world @ vertex.co
              for vertex in mesh_obj.data.vertices]
    low = Vector(tuple(min(point[axis] for point in points)
                       for axis in range(3)))
    high = Vector(tuple(max(point[axis] for point in points)
                        for axis in range(3)))
    return low, high


def triangle_count(mesh: bpy.types.Mesh) -> int:
    return sum(max(len(polygon.vertices) - 2, 0)
               for polygon in mesh.polygons)


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    if abs(edge1 - edge0) < 1.0e-8:
        return float(value >= edge1)
    share = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return share * share * (3.0 - 2.0 * share)


def normalize_source() -> tuple[bpy.types.Object, str]:
    if not os.path.isfile(SRC_BLEND):
        raise SystemExit("Volcanoronomous source is missing: " + SRC_BLEND)
    source_hash = file_sha256(SRC_BLEND)
    bpy.ops.wm.open_mainfile(filepath=SRC_BLEND)

    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise SystemExit("Volcanoronomous source contains no mesh")
    # The second source object is a plain two-metre Icosphere left by the
    # MeshMaker session.  The 57k-triangle coloured sculpt is unambiguous.
    mesh_obj = max(meshes, key=lambda obj: triangle_count(obj.data))
    color = mesh_obj.data.color_attributes.get("Color")
    if color is None or color.domain != "CORNER":
        raise SystemExit(
            "Volcanoronomous source must contain corner-domain Color")

    low, high = mesh_bounds(mesh_obj)
    source_wingspan = high.x - low.x
    scale = TARGET_WINGSPAN / source_wingspan
    # The sculpt looks source -Y. Blender +Y becomes Godot -Z, so this baked
    # half-turn makes its muzzle agree with CharacterBody3D forward.
    base = Matrix.Scale(scale, 4) @ Matrix.Rotation(math.pi, 4, "Z")
    turned = [base @ (mesh_obj.matrix_world @ vertex.co)
              for vertex in mesh_obj.data.vertices]
    turned_low = Vector(tuple(min(point[axis] for point in turned)
                              for axis in range(3)))
    turned_high = Vector(tuple(max(point[axis] for point in turned)
                               for axis in range(3)))
    offset = Vector((
        -(turned_low.x + turned_high.x) * 0.5,
        -(turned_low.y + turned_high.y) * 0.5,
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
    mesh_obj.vertex_groups.clear()

    for obj in list(bpy.data.objects):
        if obj is not mesh_obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    mesh_obj.name = "Character"
    mesh_obj.data.name = "VolcanoronomousMesh"
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    scene.render.fps = FPS
    print("source: {0} verts, {1} tris, {2:.3f} m wingspan; sha256={3}".format(
        len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
        source_wingspan, source_hash))
    print("normalize: scale={0:.6f}, turn=180 deg, target={1:.3f} m".format(
        scale, TARGET_WINGSPAN))
    return mesh_obj, source_hash


def optimize(mesh_obj: bpy.types.Object) -> None:
    before = triangle_count(mesh_obj.data)
    if before > TARGET_TRIANGLES:
        modifier = mesh_obj.modifiers.new("FlyingBossBudget", "DECIMATE")
        modifier.decimate_type = "COLLAPSE"
        modifier.ratio = TARGET_TRIANGLES / float(before)
        modifier.use_collapse_triangulate = True
        activate(mesh_obj)
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    after = triangle_count(mesh_obj.data)
    color = mesh_obj.data.color_attributes.get("Color")
    if color is None or color.domain != "CORNER":
        raise SystemExit("decimation dropped the Color corner attribute")
    if after > int(TARGET_TRIANGLES * 1.02):
        raise SystemExit("Volcanoronomous still exceeds its triangle budget")
    for polygon in mesh_obj.data.polygons:
        polygon.use_smooth = True
    mesh_obj.data.update()
    print("optimize: {0} -> {1} tris, {2} verts".format(
        before, after, len(mesh_obj.data.vertices)))


def vertex_color_material(mesh_obj: bpy.types.Object) -> None:
    material = bpy.data.materials.new("VolcanoronomousVertexColor")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    for node in list(nodes):
        nodes.remove(node)
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    color = nodes.new("ShaderNodeVertexColor")
    color.name = "VolcanoronomousColor"
    color.layer_name = "Color"
    shader.inputs["Roughness"].default_value = 0.72
    shader.inputs["Metallic"].default_value = 0.02
    shader.inputs["Specular IOR Level"].default_value = 0.34
    links.new(color.outputs["Color"], shader.inputs["Base Color"])
    links.new(color.outputs["Alpha"], shader.inputs["Alpha"])
    mesh_obj.data.materials.clear()
    mesh_obj.data.materials.append(material)


def bone_table():
    """Measured rest skeleton for the normalised 15 m sculpt."""
    return (
        ("Root", None, (0.0, 0.0, 0.0), (0.0, 0.0, 0.8), False),
        ("Hips", "Root", (0.0, -0.65, 4.05), (0.0, -0.10, 5.05), False),
        ("Spine", "Hips", (0.0, -0.10, 5.05), (0.0, 0.38, 6.25), True),
        ("Chest", "Spine", (0.0, 0.38, 6.25), (0.0, 1.05, 7.30), True),
        ("Neck", "Chest", (0.0, 1.05, 7.30), (0.0, 2.45, 8.45), True),
        ("Head", "Neck", (0.0, 2.45, 8.45), (0.0, 4.65, 8.20), True),
        ("LowerJaw", "Head", (0.0, 3.35, 7.88), (0.0, 5.25, 7.54), False),
        ("Tail01", "Hips", (0.0, -0.62, 4.55), (0.0, -2.15, 4.45), False),
        ("Tail02", "Tail01", (0.0, -2.15, 4.45), (0.0, -3.78, 4.55), True),
        ("Tail03", "Tail02", (0.0, -3.78, 4.55), (0.0, -5.20, 5.25), True),
        ("Tail04", "Tail03", (0.0, -5.20, 5.25), (0.0, -6.02, 6.35), True),
        ("LeftWingBase", "Chest", (-1.00, 0.28, 7.15), (-2.75, 0.18, 9.72), False),
        ("LeftWingMid", "LeftWingBase", (-2.75, 0.18, 9.72), (-5.15, 0.05, 10.60), True),
        ("LeftWingTip", "LeftWingMid", (-5.15, 0.05, 10.60), (-7.38, 0.10, 9.55), True),
        ("RightWingBase", "Chest", (1.00, 0.28, 7.15), (2.75, 0.18, 9.72), False),
        ("RightWingMid", "RightWingBase", (2.75, 0.18, 9.72), (5.15, 0.05, 10.60), True),
        ("RightWingTip", "RightWingMid", (5.15, 0.05, 10.60), (7.38, 0.10, 9.55), True),
        ("LeftFrontUpperArm", "Chest", (-1.12, 1.08, 5.90), (-1.42, 1.85, 3.75), False),
        ("LeftFrontLowerArm", "LeftFrontUpperArm", (-1.42, 1.85, 3.75), (-1.66, 2.78, 1.20), True),
        ("LeftFrontClaw", "LeftFrontLowerArm", (-1.66, 2.78, 1.20), (-1.72, 3.67, 0.32), True),
        ("RightFrontUpperArm", "Chest", (1.12, 1.08, 5.90), (1.42, 1.85, 3.75), False),
        ("RightFrontLowerArm", "RightFrontUpperArm", (1.42, 1.85, 3.75), (1.66, 2.78, 1.20), True),
        ("RightFrontClaw", "RightFrontLowerArm", (1.66, 2.78, 1.20), (1.72, 3.67, 0.32), True),
        ("LeftHindUpperLeg", "Hips", (-1.18, -0.70, 4.15), (-1.67, -1.22, 2.48), False),
        ("LeftHindLowerLeg", "LeftHindUpperLeg", (-1.67, -1.22, 2.48), (-1.48, -2.08, 0.82), True),
        ("LeftHindClaw", "LeftHindLowerLeg", (-1.48, -2.08, 0.82), (-1.58, -2.82, 0.24), True),
        ("RightHindUpperLeg", "Hips", (1.18, -0.70, 4.15), (1.67, -1.22, 2.48), False),
        ("RightHindLowerLeg", "RightHindUpperLeg", (1.67, -1.22, 2.48), (1.48, -2.08, 0.82), True),
        ("RightHindClaw", "RightHindLowerLeg", (1.48, -2.08, 0.82), (1.58, -2.82, 0.24), True),
    )


def build_armature() -> bpy.types.Object:
    armature = bpy.data.armatures.new("VolcanoronomousSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, parent, head, tail, connected in bone_table():
        bone = armature.edit_bones.new(name)
        bone.head = Vector(head)
        bone.tail = Vector(tail)
        if parent is not None:
            bone.parent = armature.edit_bones[parent]
            bone.use_connect = connected
    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.bones["Root"].use_deform = False
    bones = tuple(bone.name for bone in armature.bones)
    if bones != REQUIRED_BONES:
        raise SystemExit("Volcanoronomous skeleton is incomplete: " + repr(bones))
    print("rig: {0} bones, {1} deforming".format(
        len(armature.bones), len(DEFORM_BONES)))
    return rig


def group_region(name: str, point: Vector) -> bool:
    """Reject heat claims that crossed the folded sculpt to another appendage."""
    side_band = 0.22
    if name.startswith("Left") and point.x > side_band:
        return False
    if name.startswith("Right") and point.x < -side_band:
        return False
    if "Wing" in name:
        return point.z >= 6.15 and abs(point.x) >= 0.55
    if "Front" in name:
        return point.y >= 0.15 and point.z <= 6.45 and abs(point.x) >= 0.48
    if "Hind" in name:
        return point.y <= 0.25 and point.z <= 5.35 and abs(point.x) >= 0.48
    if name.startswith("Tail"):
        return point.y <= -0.35
    if name == "LowerJaw":
        # The jaw bone passes close enough to the chest and both forelimbs for
        # heat diffusion to claim most of the animal unless it is fenced to the
        # underside of the muzzle.
        return point.y >= 3.0 and 6.55 <= point.z <= 8.35 \
            and abs(point.x) <= 1.55
    if name in ("Neck", "Head"):
        return point.y >= 0.75 and point.z >= 6.35
    return True


def fallback_bone(point: Vector) -> str:
    if point.y < -1.35:
        if point.y < -5.1:
            return "Tail04"
        if point.y < -3.7:
            return "Tail03"
        if point.y < -2.1:
            return "Tail02"
        return "Tail01"
    if point.y > 3.1 and point.z > 6.5:
        return "Head"
    if point.y > 1.1 and point.z > 6.4:
        return "Neck"
    if point.z > 6.0:
        return "Chest"
    if point.z > 4.8:
        return "Spine"
    return "Hips"


def skin(mesh_obj: bpy.types.Object, rig: bpy.types.Object) -> None:
    """Heat-diffusion weights, constrained to each measured appendage."""
    activate(mesh_obj)
    mesh_obj.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")

    groups = {group.name: group for group in mesh_obj.vertex_groups}
    missing = [name for name in DEFORM_BONES if name not in groups]
    if missing:
        raise SystemExit("automatic weights skipped: " + ", ".join(missing))

    rows: list[dict[str, float]] = []
    dropped = 0
    for vertex in mesh_obj.data.vertices:
        mapped: dict[str, float] = {}
        for assignment in vertex.groups:
            name = mesh_obj.vertex_groups[assignment.group].name
            if name not in DEFORM_BONES or assignment.weight <= 1.0e-6:
                continue
            if not group_region(name, vertex.co):
                dropped += 1
                continue
            mapped[name] = mapped.get(name, 0.0) + assignment.weight
        kept = sorted(mapped.items(), key=lambda item: item[1],
                      reverse=True)[:4]
        total = sum(amount for _, amount in kept)
        if total < 1.0e-6:
            kept = [(fallback_bone(vertex.co), 1.0)]
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
    modifier = next(
        (mod for mod in mesh_obj.modifiers if mod.type == "ARMATURE"), None)
    if modifier is None:
        modifier = mesh_obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    modifier.use_deform_preserve_volume = True
    print("skin: max 4 influences, {0} cross-appendage claims dropped".format(
        dropped))
    print("  " + ", ".join(
        "{0}:{1}".format(name, counts[name]) for name in DEFORM_BONES))


def volcanoronomous_animations(anim):
    rot = anim.rot
    tau = math.tau

    def ease(value):
        value = max(0.0, min(1.0, value))
        return value * value * (3.0 - 2.0 * value)

    def wings(pose, lift, sweep=0.0, fold=0.0):
        for side, sign in (("Left", 1.0), ("Right", -1.0)):
            pose[side + "WingBase"] = rot(
                ("Y", sign * lift), ("Z", sign * sweep))
            pose[side + "WingMid"] = rot(
                ("Y", sign * lift * 0.45), ("Z", sign * fold))
            pose[side + "WingTip"] = rot(
                ("Y", -sign * lift * 0.18), ("Z", sign * fold * 0.5))

    def tail_wave(pose, phase, amount=8.0):
        for index, name in enumerate(("Tail01", "Tail02", "Tail03", "Tail04")):
            pose[name] = rot(
                ("Z", amount * math.sin(phase - index * 0.58)),
                ("X", amount * 0.18 * math.cos(phase - index * 0.44)))

    def legs_tucked(pose, share=1.0):
        for side, sign in (("Left", -1.0), ("Right", 1.0)):
            pose[side + "FrontUpperArm"] = rot(
                ("X", -28.0 * share), ("Y", sign * 8.0 * share))
            pose[side + "FrontLowerArm"] = rot(("X", 42.0 * share))
            pose[side + "FrontClaw"] = rot(("X", -20.0 * share))
            pose[side + "HindUpperLeg"] = rot(
                ("X", 24.0 * share), ("Y", sign * 7.0 * share))
            pose[side + "HindLowerLeg"] = rot(("X", -48.0 * share))
            pose[side + "HindClaw"] = rot(("X", 20.0 * share))

    def idle_pose(t):
        phase = t * tau
        breath = math.sin(phase)
        pose = {
            "Hips": {"rot": [("Z", 1.3 * math.sin(phase * 0.5))],
                     "loc": (0.0, 0.0, 0.035 * breath)},
            "Spine": rot(("X", -1.5 * breath)),
            "Chest": rot(("X", 2.2 * breath)),
            "Neck": rot(("X", -2.0 * breath),
                        ("Z", 2.0 * math.sin(phase * 0.5))),
            "Head": rot(("X", 1.6 * breath),
                        ("Z", -2.8 * math.sin(phase * 0.5))),
            "LowerJaw": rot(("X", 2.0 + 1.5 * breath)),
        }
        wings(pose, 4.0 + 2.5 * breath)
        tail_wave(pose, phase * 0.65, 6.0)
        return pose

    def fly_pose(t):
        phase = t * tau
        flap = math.sin(phase)
        pose = {
            "Hips": {"rot": [("X", -4.0), ("Z", 2.0 * math.sin(phase * 0.5))],
                     "loc": (0.0, 0.0, 0.04 * math.cos(phase))},
            "Spine": rot(("X", 5.0)),
            "Chest": rot(("X", 7.0)),
            "Neck": rot(("X", -5.0)),
            "Head": rot(("X", -7.0),
                        ("Z", 2.0 * math.sin(phase * 0.5))),
            "LowerJaw": rot(("X", 3.0)),
        }
        wings(pose, 28.0 * flap, sweep=5.0 - 4.0 * math.cos(phase),
              fold=8.0 * max(0.0, -flap))
        tail_wave(pose, phase, 11.0)
        legs_tucked(pose)
        return pose

    def swoop_pose(t):
        drive = math.sin(math.pi * max(0.0, min(1.0, t)))
        pose = {
            "Hips": rot(("X", -10.0 * drive)),
            "Spine": rot(("X", -12.0 * drive)),
            "Chest": rot(("X", -9.0 * drive)),
            "Neck": rot(("X", 14.0 * drive)),
            "Head": rot(("X", 18.0 * drive)),
            "LowerJaw": rot(("X", -12.0 * drive)),
        }
        wings(pose, 12.0 * drive, sweep=42.0 * drive, fold=28.0 * drive)
        tail_wave(pose, t * tau * 1.4, 15.0 * drive)
        legs_tucked(pose, 1.0 - 0.25 * drive)
        return pose

    def laser_pose(t):
        charge = ease(t / 0.28)
        release = ease((t - 0.82) / 0.18)
        held = charge * (1.0 - release)
        pose = {
            "Spine": rot(("X", 4.0 * held)),
            "Chest": rot(("X", 7.0 * held)),
            "Neck": rot(("X", -10.0 * held)),
            "Head": rot(("X", -14.0 * held)),
            "LowerJaw": rot(("X", 11.0 * held)),
        }
        wings(pose, 6.0, sweep=-10.0 * held, fold=-5.0 * held)
        legs_tucked(pose)
        tail_wave(pose, t * tau * 0.5, 5.0)
        return pose

    def claw_pose(t):
        wind = ease(t / 0.30)
        strike = ease((t - 0.28) / 0.24)
        recover = ease((t - 0.68) / 0.32)
        active = (wind - strike * 0.72) * (1.0 - recover)
        slash = strike * (1.0 - recover)
        pose = {
            "Chest": rot(("Y", -14.0 * active), ("Z", -8.0 * active)),
            "Neck": rot(("Y", 8.0 * active)),
            "Head": rot(("Y", 10.0 * active)),
            "RightFrontUpperArm": rot(
                ("X", (-40.0 * wind + 78.0 * slash)), ("Y", -18.0 * wind)),
            "RightFrontLowerArm": rot(("X", 54.0 * wind - 68.0 * slash)),
            "RightFrontClaw": rot(("X", -26.0 * wind + 42.0 * slash)),
        }
        wings(pose, 8.0, sweep=22.0 * wind, fold=12.0 * wind)
        tail_wave(pose, t * tau, 8.0)
        legs_tucked(pose)
        return pose

    def dodge_pose(t):
        bank = math.sin(math.pi * max(0.0, min(1.0, t)))
        pose = {
            "Hips": rot(("Y", -20.0 * bank), ("Z", 16.0 * bank)),
            "Spine": rot(("Y", -12.0 * bank)),
            "Chest": rot(("Y", -10.0 * bank)),
            "Neck": rot(("Y", 16.0 * bank)),
            "Head": rot(("Y", 20.0 * bank)),
        }
        pose["LeftWingBase"] = rot(("Y", 34.0 * bank), ("Z", 10.0 * bank))
        pose["RightWingBase"] = rot(("Y", 8.0 * bank), ("Z", -28.0 * bank))
        pose["LeftWingMid"] = rot(("Y", 16.0 * bank))
        pose["RightWingMid"] = rot(("Y", 4.0 * bank), ("Z", -16.0 * bank))
        tail_wave(pose, t * tau + 1.2, 18.0 * bank)
        legs_tucked(pose)
        return pose

    def emerge_pose(t):
        rise = ease(t / 0.68)
        settle = ease((t - 0.72) / 0.28)
        power = rise * (1.0 - settle)
        pose = {
            "Hips": {"rot": [("X", -8.0 * power)],
                     "loc": (0.0, 0.0, 0.75 * power)},
            "Spine": rot(("X", -12.0 * power)),
            "Chest": rot(("X", -8.0 * power)),
            "Neck": rot(("X", 18.0 * power)),
            "Head": rot(("X", 23.0 * power)),
            "LowerJaw": rot(("X", -18.0 * power)),
        }
        wings(pose, -42.0 * power, sweep=-12.0 * power)
        tail_wave(pose, t * tau * 1.5, 16.0 * power)
        legs_tucked(pose, rise)
        return pose

    def hit_react_pose(t):
        hit = math.sin(math.pi * max(0.0, min(1.0, t)))
        pose = {
            "Hips": rot(("Y", 9.0 * hit), ("Z", -7.0 * hit)),
            "Spine": rot(("Y", 13.0 * hit)),
            "Chest": rot(("Y", 17.0 * hit)),
            "Neck": rot(("Y", -22.0 * hit), ("X", 8.0 * hit)),
            "Head": rot(("Y", -27.0 * hit), ("X", 12.0 * hit)),
            "LowerJaw": rot(("X", -10.0 * hit)),
        }
        wings(pose, 14.0 * hit, sweep=10.0 * hit)
        tail_wave(pose, t * tau + 0.8, 12.0 * hit)
        legs_tucked(pose)
        return pose

    def defeat_pose(t):
        fall = ease(t / 0.78)
        limp = ease((t - 0.55) / 0.45)
        pose = {
            "Hips": {"rot": [("Y", 42.0 * fall), ("Z", -24.0 * fall)],
                     "loc": (0.0, 0.0, -0.55 * fall)},
            "Spine": rot(("Y", 28.0 * fall), ("X", -18.0 * fall)),
            "Chest": rot(("Y", 24.0 * fall), ("X", -22.0 * fall)),
            "Neck": rot(("Y", -35.0 * fall), ("X", 32.0 * limp)),
            "Head": rot(("Y", -44.0 * fall), ("X", 38.0 * limp)),
            "LowerJaw": rot(("X", -24.0 * limp)),
        }
        wings(pose, -28.0 * fall, sweep=48.0 * limp, fold=34.0 * limp)
        tail_wave(pose, t * tau * 0.7, 20.0 * (1.0 - limp * 0.6))
        legs_tucked(pose, 1.0 - fall * 0.3)
        return pose

    return [
        ("Idle", 90, True, idle_pose),
        ("Fly", 36, True, fly_pose),
        ("Swoop", 30, False, swoop_pose),
        ("Laser", 54, False, laser_pose),
        ("Claw", 27, False, claw_pose),
        ("Dodge", 20, False, dodge_pose),
        ("Emerge", 54, False, emerge_pose),
        ("HitReact", 18, False, hit_react_pose),
        ("Defeat", 72, False, defeat_pose),
    ]


def export_runtime(rig: bpy.types.Object,
                   mesh_obj: bpy.types.Object) -> None:
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for obj in bpy.context.view_layer.objects:
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
        export_vertex_color="ACTIVE",
        export_all_vertex_colors=False,
    )
    print("wrote {0} ({1:.1f} MB)".format(
        OUT_GLB, os.path.getsize(OUT_GLB) / (1024.0 * 1024.0)))


def validate(mesh_obj: bpy.types.Object, rig: bpy.types.Object) -> None:
    low, high = mesh_bounds(mesh_obj)
    size = high - low
    color = mesh_obj.data.color_attributes.get("Color")
    bones = tuple(bone.name for bone in rig.data.bones)
    clips = tuple(track.name for track in rig.animation_data.nla_tracks)
    if bones != REQUIRED_BONES:
        raise SystemExit("unexpected runtime bones: " + repr(bones))
    if clips != REQUIRED_CLIPS:
        raise SystemExit("unexpected runtime clips: " + repr(clips))
    if color is None or color.domain != "CORNER":
        raise SystemExit("runtime mesh lost Color")
    # Decimation may remove the single lowest claw-tip vertex while preserving
    # the actual stance plane; a centimetre is well below runtime clearance.
    if abs(size.x - TARGET_WINGSPAN) > 0.01 or abs(low.z) > 0.01:
        raise SystemExit("runtime bounds are not normalised and grounded")
    unweighted = [vertex.index for vertex in mesh_obj.data.vertices
                  if not vertex.groups]
    if unweighted:
        raise SystemExit(
            "runtime skin has {0} unweighted vertices".format(len(unweighted)))
    print("final: bounds={0:.3f} x {1:.3f} x {2:.3f} m, "
          "mesh={3} verts/{4} tris, bones={5}, clips={6}, Color={7}/{8}".format(
              size.x, size.y, size.z, len(mesh_obj.data.vertices),
              triangle_count(mesh_obj.data), len(bones), len(clips),
              color.domain, color.data_type))


def main() -> None:
    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    mesh_obj, source_hash = normalize_source()
    optimize(mesh_obj)
    vertex_color_material(mesh_obj)
    rig = build_armature()
    skin(mesh_obj, rig)

    anim = load_sibling("build_animations.py", "_volcanoronomous")
    anim.BODY_SCALE = 1.0
    animations = volcanoronomous_animations(anim)
    if tuple(spec[0] for spec in animations) != REQUIRED_CLIPS:
        raise SystemExit("Volcanoronomous animation table is incomplete")
    anim.ANIMATIONS = animations
    anim.export = export_runtime
    anim.bake_into_open_file(OUT_BLEND, OUT_GLB)
    validate(mesh_obj, rig)

    after_hash = file_sha256(SRC_BLEND)
    if after_hash != source_hash:
        raise SystemExit(
            "source Volcanoronomous blend changed during the build")
    print("source preserved: sha256=" + after_hash)


if __name__ == "__main__":
    main()
