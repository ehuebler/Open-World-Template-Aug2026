"""Build the runtime Bigfoot from the read-only MeshMaker source.

Run from the project root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_bigfoot.py

The source is an eight-unit, -Y-facing sculpt on MeshMaker's coarse 12-bone
rig. This recipe opens it read-only, turns it to Blender +Y (Godot -Z), scales
it to 3.2 m, reduces it to a boss-sized triangle budget, and rebuilds the
project's humanoid bone names. The useful MeshMaker skin is retained: its
distal arm and leg weights are deterministically split onto new hand, foot and
toe bones, while the original corner-domain Color attribute remains the
runtime COLOR_0 stream.

Animations are authored here but baked/exported by build_animations.py, so the
same per-frame, world-axis pose format and NLA export path is used by all
project characters.
"""

from __future__ import annotations

import hashlib
import importlib.util
import math
import os
from dataclasses import dataclass

import bpy
from mathutils import Matrix, Vector


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
SRC_BLEND = os.path.join(
    ROOT, "assets", "source", "meshmaker", "bigfoot.blend")
OUT_BLEND = os.path.join(
    ROOT, "assets", "work", "bigfoot_rigged.blend")
OUT_GLB = os.path.join(
    ROOT, "assets", "runtime", "characters", "bigfoot.glb")

TARGET_HEIGHT = 3.2
TARGET_TRIANGLES = 30_000
FPS = 30
RIM_COLOR = (0.20, 1.0, 0.58, 1.0)
RIM_STRENGTH = 1.25
RIM_RAMP_DARK = 0.68
RIM_RAMP_LIGHT = 0.84

REQUIRED_CLIPS = (
    "Idle", "Walk", "Run", "Roar", "MeteorWindup", "MeteorFly",
    "MeteorImpact", "Punch", "Grab", "Throw", "HitReact", "Defeat",
)
REQUIRED_BONES = (
    "Root", "Hips", "Spine", "Chest", "UpperChest", "Neck", "Head",
    "LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "LeftToes",
    "RightUpperLeg", "RightLowerLeg", "RightFoot", "RightToes",
)

# Turning a -Y-facing figure by 180 degrees swaps its world-space sides.
SOURCE_SIDES = {
    "Left": {
        "upper_arm": "arm_1_00",
        "lower_arm": "arm_1_01",
        "upper_leg": "leg_1_00",
        "lower_leg": "leg_1_01",
        "sign": -1.0,
    },
    "Right": {
        "upper_arm": "arm_0_00",
        "lower_arm": "arm_0_01",
        "upper_leg": "leg_0_00",
        "lower_leg": "leg_0_01",
        "sign": 1.0,
    },
}


@dataclass
class Segment:
    head: Vector
    tail: Vector


@dataclass
class Foot:
    ankle: Vector
    ball: Vector
    toe: Vector


@dataclass
class Arm:
    """The limb's real centreline, measured off the sculpt rather than assumed.

    MeshMaker's two arm bones are a clavicle spanning the shoulders and a single
    bone for everything below it, so reading them as an upper arm and a forearm
    puts the "upper arm" 100 degrees out from vertical. `arm_hang` then rotates
    that span down by 80 degrees in every clip, which drags the shoulder cap and
    the trapezius with it and buries the head in the chest.
    """

    shoulder: Vector
    elbow: Vector
    wrist: Vector
    tip: Vector

    def joints(self) -> tuple[Vector, Vector, Vector, Vector]:
        return (self.shoulder, self.elbow, self.wrist, self.tip)


@dataclass
class Chain:
    joints: tuple[Vector, Vector, Vector, Vector]
    lengths: tuple[float, float, float]
    total: float
    elbow_at: float
    wrist_at: float


# How wide, as a share of the whole limb, each joint's weights blend across.
JOINT_BAND = 0.085


def chain_of(arm: Arm) -> Chain:
    joints = arm.joints()
    lengths = tuple((joints[index + 1] - joints[index]).length
                    for index in range(3))
    total = sum(lengths)
    return Chain(
        joints, lengths, total,
        lengths[0] / total, (lengths[0] + lengths[1]) / total)


def arm_parameter(point: Vector, chain: Chain) -> float:
    """Where along the limb a point sits, 0 at the shoulder and 1 at the tip.

    Points inboard or above the shoulder come back negative, which is what lets
    the trapezius and the shoulder cap stay with the clavicle instead of
    swinging every time the arm does.
    """
    best_distance = None
    best_value = 0.0
    travelled = 0.0
    for index in range(3):
        start = chain.joints[index]
        segment = chain.joints[index + 1] - start
        length = chain.lengths[index]
        if length < 1.0e-6:
            continue
        share = (point - start).dot(segment) / (length * length)
        clamped = max(0.0, min(1.0, share))
        nearest = start + segment * clamped
        distance = (point - nearest).length
        value = travelled + clamped * length
        if index == 0 and share < 0.0:
            distance = (point - start).length
            value = share * length
        if best_distance is None or distance < best_distance:
            best_distance = distance
            best_value = value
        travelled += length
    return best_value / chain.total


def load_sibling(filename: str, suffix: str):
    path = os.path.join(SOURCE_DIR, filename)
    spec = importlib.util.spec_from_file_location(
        os.path.splitext(filename)[0] + suffix, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def weight(vertex: bpy.types.MeshVertex,
           group: bpy.types.VertexGroup) -> float:
    for assignment in vertex.groups:
        if assignment.group == group.index:
            return assignment.weight
    return 0.0


def projection(point: Vector, segment: Segment) -> float:
    direction = segment.tail - segment.head
    if direction.length_squared < 1.0e-8:
        return 0.0
    return (point - segment.head).dot(direction) / direction.length_squared


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    if abs(edge1 - edge0) < 1.0e-8:
        return float(value >= edge1)
    amount = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return amount * amount * (3.0 - 2.0 * amount)


def normalize_source() -> tuple[bpy.types.Object, dict[str, Segment], str]:
    """Open the source and return a normalized mesh plus transformed landmarks."""
    if not os.path.isfile(SRC_BLEND):
        raise SystemExit("Bigfoot source is missing: " + SRC_BLEND)
    source_hash = file_sha256(SRC_BLEND)
    bpy.ops.wm.open_mainfile(filepath=SRC_BLEND)

    mesh_obj = bpy.data.objects.get("geometry_0")
    source_rig = bpy.data.objects.get("MeshMakerRig")
    if mesh_obj is None or mesh_obj.type != "MESH":
        raise SystemExit("geometry_0 mesh is missing from " + SRC_BLEND)
    if source_rig is None or source_rig.type != "ARMATURE":
        raise SystemExit("MeshMakerRig armature is missing from " + SRC_BLEND)
    color = mesh_obj.data.color_attributes.get("Color")
    if color is None or color.domain != "CORNER":
        raise SystemExit("Bigfoot source must contain corner-domain Color")

    low, high = mesh_bounds(mesh_obj)
    source_height = high.z - low.z
    scale = TARGET_HEIGHT / source_height
    # The head and toes both project toward source -Y. Blender +Y maps to
    # Godot -Z, so bake this turn into vertices and all measured rig points.
    base = Matrix.Scale(scale, 4) @ Matrix.Rotation(math.pi, 4, "Z")
    turned = [base @ (mesh_obj.matrix_world @ vertex.co)
              for vertex in mesh_obj.data.vertices]
    turned_low = Vector(tuple(min(point[axis] for point in turned)
                              for axis in range(3)))
    turned_high = Vector(tuple(max(point[axis] for point in turned)
                               for axis in range(3)))
    offset = Vector((
        -(turned_low.x + turned_high.x) * 0.5,
        0.0,
        -turned_low.z,
    ))

    def convert(point: Vector) -> Vector:
        return base @ point + offset

    source_bones = {
        bone.name: Segment(
            convert(source_rig.matrix_world @ bone.head_local),
            convert(source_rig.matrix_world @ bone.tail_local),
        )
        for bone in source_rig.data.bones
    }

    for vertex, point in zip(mesh_obj.data.vertices, turned):
        vertex.co = point + offset
    mesh_obj.data.update()
    mesh_obj.parent = None
    mesh_obj.matrix_parent_inverse = Matrix.Identity(4)
    mesh_obj.matrix_world = Matrix.Identity(4)
    for modifier in list(mesh_obj.modifiers):
        mesh_obj.modifiers.remove(modifier)

    for obj in list(bpy.data.objects):
        if obj is not mesh_obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    mesh_obj.name = "Character"
    mesh_obj.data.name = "BigfootMesh"
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.length_unit = "METERS"
    bpy.context.scene.render.fps = FPS

    print("source: {0} verts, {1} tris, {2:.3f} m; sha256={3}".format(
        len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
        source_height, source_hash))
    print("normalize: scale={0:.6f}, turn=180 deg, target={1:.3f} m".format(
        scale, TARGET_HEIGHT))
    return mesh_obj, source_bones, source_hash


def optimize(mesh_obj: bpy.types.Object) -> tuple[int, int]:
    before = triangle_count(mesh_obj.data)
    if before > TARGET_TRIANGLES:
        modifier = mesh_obj.modifiers.new("BossBudget", "DECIMATE")
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
        raise SystemExit("Bigfoot still exceeds its triangle budget")
    for polygon in mesh_obj.data.polygons:
        polygon.use_smooth = True
    mesh_obj.data.update()
    print("optimize: {0} -> {1} tris, {2} verts, Color={3}/{4}".format(
        before, after, len(mesh_obj.data.vertices),
        color.domain, color.data_type))
    return before, after


def vertex_color_material(mesh_obj: bpy.types.Object) -> None:
    material = bpy.data.materials.new("BigfootVertexColor")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    for node in list(nodes):
        nodes.remove(node)
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    color = nodes.new("ShaderNodeVertexColor")
    color.name = "BigfootColor"
    color.layer_name = "Color"
    shader.inputs["Roughness"].default_value = 0.90
    shader.inputs["Specular IOR Level"].default_value = 0.28
    links.new(color.outputs["Color"], shader.inputs["Base Color"])
    links.new(color.outputs["Alpha"], shader.inputs["Alpha"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    mesh_obj.data.materials.clear()
    mesh_obj.data.materials.append(material)


def add_camera_rim(material: bpy.types.Material) -> None:
    """Build Character 3's editable Layer Weight camera-rim graph."""
    material.use_nodes = True
    tree = material.node_tree
    nodes = tree.nodes
    links = tree.links
    bsdf = nodes.get("Principled BSDF")
    output = nodes.get("Material Output")
    if bsdf is None or output is None:
        raise RuntimeError("camera rim needs Principled BSDF and Material Output")

    layer_weight = nodes.new("ShaderNodeLayerWeight")
    layer_weight.name = "Camera Rim Layer Weight"
    layer_weight.label = "Camera-facing rim mask"
    layer_weight.inputs["Blend"].default_value = 0.35
    layer_weight.location = (120.0, -160.0)

    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.name = "Camera Rim Color Ramp"
    ramp.label = "Rim thickness and sharpness"
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].position = RIM_RAMP_DARK
    ramp.color_ramp.elements[0].color = (0.0, 0.0, 0.0, 1.0)
    ramp.color_ramp.elements[-1].position = RIM_RAMP_LIGHT
    ramp.color_ramp.elements[-1].color = (1.0, 1.0, 1.0, 1.0)
    ramp.location = (340.0, -160.0)

    emission = nodes.new("ShaderNodeEmission")
    emission.name = "Camera Rim Emission"
    emission.label = "Neon green rim"
    emission.inputs["Color"].default_value = RIM_COLOR
    emission.inputs["Strength"].default_value = RIM_STRENGTH
    emission.location = (350.0, 80.0)

    mix = nodes.new("ShaderNodeMixShader")
    mix.name = "Camera Rim Mix Shader"
    mix.label = "Base surface + camera rim"
    mix.location = (590.0, 120.0)
    output.location = (820.0, 120.0)

    for socket in (ramp.inputs["Fac"], mix.inputs[0], mix.inputs[1],
                   mix.inputs[2], output.inputs["Surface"]):
        for link in list(socket.links):
            links.remove(link)
    links.new(layer_weight.outputs["Fresnel"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], mix.inputs[0])
    links.new(bsdf.outputs["BSDF"], mix.inputs[1])
    links.new(emission.outputs["Emission"], mix.inputs[2])
    links.new(mix.outputs["Shader"], output.inputs["Surface"])


def weighted_slab_center(mesh_obj: bpy.types.Object, group_name: str,
                         z: float, half: float) -> Vector | None:
    group = mesh_obj.vertex_groups.get(group_name)
    if group is None:
        return None
    samples = []
    for vertex in mesh_obj.data.vertices:
        amount = weight(vertex, group)
        if amount > 0.15 and abs(vertex.co.z - z) <= half:
            samples.append((vertex.co.copy(), amount))
    if not samples:
        return None
    total = sum(amount for _, amount in samples)
    result = Vector()
    for point, amount in samples:
        result += point * amount
    return result / total


def quantile(values: list[float], amount: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = int(round((len(ordered) - 1) * amount))
    return ordered[max(0, min(index, len(ordered) - 1))]


def measure_foot(mesh_obj: bpy.types.Object, group_name: str,
                 side: float, height: float) -> Foot:
    group = mesh_obj.vertex_groups[group_name]
    candidates = []
    for vertex in mesh_obj.data.vertices:
        amount = weight(vertex, group)
        point = vertex.co
        if (amount > 0.15 and point.x * side > height * 0.04
                and point.z < height * 0.13):
            candidates.append((point.copy(), amount))
    if len(candidates) < 20:
        raise SystemExit("could not measure " + group_name + " foot")

    total = sum(amount for _, amount in candidates)
    foot_x = sum(point.x * amount for point, amount in candidates) / total
    ys = [point.y for point, _ in candidates]
    heel_y = quantile(ys, 0.02)
    toe_y = quantile(ys, 0.98)
    ankle_z = height * 0.050
    ankle_samples = [
        (point, amount) for point, amount in candidates
        if abs(point.z - ankle_z) < height * 0.018
    ]
    ankle_y = (sum(point.y * amount for point, amount in ankle_samples)
                / sum(amount for _, amount in ankle_samples)
                if ankle_samples else (heel_y + toe_y) * 0.30)
    ball_y = heel_y + (toe_y - heel_y) * 0.66
    return Foot(
        Vector((foot_x, ankle_y, ankle_z)),
        Vector((foot_x, ball_y, height * 0.028)),
        Vector((foot_x, toe_y, height * 0.022)),
    )


def slab_centre(samples: list[tuple[Vector, float]], z: float,
                half: float) -> Vector | None:
    total = 0.0
    centre = Vector()
    for point, mass in samples:
        if abs(point.z - z) <= half:
            centre += point * mass
            total += mass
    if total < 1.0e-6:
        return None
    return centre / total


def measure_arm(mesh_obj: bpy.types.Object, names: dict,
                shoulder: Vector, height: float) -> Arm:
    """Fit an elbow, a wrist and a fingertip to the sculpted arm's centreline."""
    groups = [mesh_obj.vertex_groups[key]
              for key in (names["upper_arm"], names["lower_arm"])
              if mesh_obj.vertex_groups.get(key) is not None]
    samples = []
    for vertex in mesh_obj.data.vertices:
        mass = sum(weight(vertex, group) for group in groups)
        if mass > 0.05:
            samples.append((vertex.co.copy(), min(mass, 1.0)))
    if len(samples) < 200:
        raise SystemExit("could not measure the " + names["lower_arm"] + " arm")

    half = height * 0.028
    lowest = min(point.z for point, _ in samples)
    tip = slab_centre(samples, lowest + half, half)
    if tip is None:
        raise SystemExit("could not find the " + names["lower_arm"] + " hand")
    span = shoulder.z - tip.z
    if span < height * 0.20:
        raise SystemExit("measured arm span is implausibly short")
    elbow = slab_centre(samples, shoulder.z - span * 0.42, half)
    wrist = slab_centre(samples, shoulder.z - span * 0.78, half)
    if elbow is None or wrist is None:
        raise SystemExit("could not place the " + names["lower_arm"] + " joints")
    # The last full slab of mass is a knuckle, not the end of the fingers.
    reach = (tip - wrist)
    if reach.length > 1.0e-4:
        tip = tip + reach.normalized() * height * 0.022
    return Arm(shoulder.copy(), elbow, wrist, tip)


def axis_point(point: Vector) -> Vector:
    return Vector((0.0, point.y, point.z))


def build_armature(mesh_obj: bpy.types.Object,
                   source: dict[str, Segment]) -> tuple[bpy.types.Object, dict]:
    low, high = mesh_bounds(mesh_obj)
    height = high.z - low.z
    root = source["root"]
    spine_1 = source["spine_01"]
    spine_2 = source["spine_02"]
    source_head = source["head"]

    hips_head = axis_point(root.head)
    hips_tail = axis_point(root.tail)
    spine_mid = axis_point(spine_1.head.lerp(spine_1.tail, 0.52))
    upper_chest = Segment(axis_point(spine_2.head), axis_point(spine_2.tail))
    neck_tail = axis_point(source_head.head.lerp(source_head.tail, 0.24))
    crown_points = [
        vertex.co.copy() for vertex in mesh_obj.data.vertices
        if vertex.co.z > high.z - height * 0.025
    ]
    crown = (sum(crown_points, Vector()) / len(crown_points)
             if crown_points else axis_point(source_head.tail))
    crown.x = 0.0

    bone_specs = [
        ("Root", None,
         Vector((0.0, hips_head.y, 0.0)),
         Vector((0.0, hips_head.y, height * 0.10)), False),
        ("Hips", "Root", hips_head, hips_tail, False),
        ("Spine", "Hips", hips_tail, spine_mid, True),
        ("Chest", "Spine", spine_mid, axis_point(spine_1.tail), True),
        ("UpperChest", "Chest", upper_chest.head, upper_chest.tail, True),
        ("Neck", "UpperChest", axis_point(source_head.head), neck_tail, True),
        ("Head", "Neck", neck_tail, crown, True),
    ]

    measurements = {"feet": {}, "arms": {}, "source": source}
    for side_name, names in SOURCE_SIDES.items():
        sign = names["sign"]
        upper_arm = source[names["upper_arm"]]
        lower_arm = source[names["lower_arm"]]
        # The source's first arm bone is a clavicle from the sternum out to the
        # shoulder joint, and its second is the whole limb below that. Keep the
        # clavicle as the shoulder and fit a real three-bone arm to the sculpt.
        arm = measure_arm(mesh_obj, names, lower_arm.head, height)
        measurements["arms"][side_name] = arm
        bone_specs.extend([
            (side_name + "Shoulder", "UpperChest",
             axis_point(upper_arm.head), arm.shoulder, False),
            (side_name + "UpperArm", side_name + "Shoulder",
             arm.shoulder, arm.elbow, True),
            (side_name + "LowerArm", side_name + "UpperArm",
             arm.elbow, arm.wrist, True),
            (side_name + "Hand", side_name + "LowerArm",
             arm.wrist, arm.tip, True),
        ])

        upper_leg = source[names["upper_leg"]]
        lower_leg = source[names["lower_leg"]]
        hip_z = upper_leg.head.z - height * 0.047
        hip = weighted_slab_center(
            mesh_obj, names["upper_leg"], hip_z, height * 0.012)
        if hip is None:
            hip = upper_leg.head.lerp(upper_leg.tail, 0.16)
        foot = measure_foot(
            mesh_obj, names["lower_leg"], sign, height)
        measurements["feet"][side_name] = foot
        bone_specs.extend([
            (side_name + "UpperLeg", "Hips",
             hip, upper_leg.tail, False),
            (side_name + "LowerLeg", side_name + "UpperLeg",
             lower_leg.head, foot.ankle, True),
            (side_name + "Foot", side_name + "LowerLeg",
             foot.ankle, foot.ball, True),
            (side_name + "Toes", side_name + "Foot",
             foot.ball, foot.toe, True),
        ])

    armature = bpy.data.armatures.new("CharacterSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, parent, head, tail, connected in bone_specs:
        bone = armature.edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        if (bone.tail - bone.head).length < 1.0e-4:
            bone.tail = bone.head + Vector((0.0, 0.0, height * 0.02))
        if parent is not None:
            bone.parent = armature.edit_bones[parent]
            bone.use_connect = connected
    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.bones["Root"].use_deform = False
    # The shoulders deform here, unlike the player rigs: they are what holds the
    # trapezius and the shoulder cap still while the arm underneath swings.

    if (len(armature.bones) != len(REQUIRED_BONES)
            or {bone.name for bone in armature.bones} != set(REQUIRED_BONES)):
        raise SystemExit("Bigfoot skeleton is missing required bones")
    print("rig: {0} bones; hands Left={1}, Right={2}".format(
        len(armature.bones),
        tuple(round(value, 3)
              for value in armature.bones["LeftHand"].head_local),
        tuple(round(value, 3)
              for value in armature.bones["RightHand"].head_local)))
    for side_name in SOURCE_SIDES:
        arm = measurements["arms"][side_name]
        print("  {0} arm: shoulder={1} elbow={2} wrist={3} tip={4}".format(
            side_name,
            tuple(round(value, 3) for value in arm.shoulder),
            tuple(round(value, 3) for value in arm.elbow),
            tuple(round(value, 3) for value in arm.wrist),
            tuple(round(value, 3) for value in arm.tip)))
    return rig, measurements


def remap_weights(mesh_obj: bpy.types.Object, rig: bpy.types.Object,
                  measurements: dict) -> None:
    """Retain MeshMaker's skin and split it across the expanded skeleton."""
    source = measurements["source"]
    old_groups = {group.name: group for group in mesh_obj.vertex_groups}
    group_order = [name for name in REQUIRED_BONES if name != "Root"]
    chains = {side_name: chain_of(measurements["arms"][side_name])
              for side_name in SOURCE_SIDES}
    rows: list[dict[str, float]] = []

    for vertex in mesh_obj.data.vertices:
        point = vertex.co
        mapped: dict[str, float] = {}

        def add(name: str, amount: float) -> None:
            if amount > 1.0e-7:
                mapped[name] = mapped.get(name, 0.0) + amount

        def old(name: str) -> float:
            group = old_groups.get(name)
            return weight(vertex, group) if group is not None else 0.0

        add("Hips", old("root"))

        amount = old("spine_01")
        factor = smoothstep(
            0.42, 0.72, projection(point, source["spine_01"]))
        add("Spine", amount * (1.0 - factor))
        add("Chest", amount * factor)

        amount = old("spine_02")
        factor = smoothstep(
            0.76, 1.04, projection(point, source["spine_02"]))
        add("UpperChest", amount * (1.0 - factor))
        add("Neck", amount * factor)
        add("Head", old("head"))

        for side_name, names in SOURCE_SIDES.items():
            # Both source arm groups describe one limb, so they are pooled and
            # then split along the measured chain instead of being read as an
            # upper arm and a forearm that they never were.
            limb = old(names["upper_arm"]) + old(names["lower_arm"])
            if limb > 1.0e-7:
                chain = chains[side_name]
                along = arm_parameter(point, chain)
                held = smoothstep(-0.03, 0.11, along)
                add(side_name + "Shoulder", limb * (1.0 - held))
                swung = limb * held
                elbow = smoothstep(
                    chain.elbow_at - JOINT_BAND,
                    chain.elbow_at + JOINT_BAND, along)
                hand = smoothstep(
                    chain.wrist_at - JOINT_BAND,
                    chain.wrist_at + JOINT_BAND, along)
                add(side_name + "UpperArm", swung * (1.0 - elbow))
                add(side_name + "LowerArm", swung * elbow * (1.0 - hand))
                add(side_name + "Hand", swung * hand)

            add(side_name + "UpperLeg", old(names["upper_leg"]))

            amount = old(names["lower_leg"])
            foot = measurements["feet"][side_name]
            foot_amount = 1.0 - smoothstep(
                foot.ankle.z - TARGET_HEIGHT * 0.01,
                foot.ankle.z + TARGET_HEIGHT * 0.045,
                point.z)
            toe_amount = smoothstep(
                foot.ball.y - TARGET_HEIGHT * 0.025,
                foot.ball.y + TARGET_HEIGHT * 0.025,
                point.y)
            add(side_name + "LowerLeg", amount * (1.0 - foot_amount))
            add(side_name + "Foot",
                amount * foot_amount * (1.0 - toe_amount))
            add(side_name + "Toes",
                amount * foot_amount * toe_amount)

        kept = sorted(mapped.items(), key=lambda item: item[1], reverse=True)[:4]
        total = sum(amount for _, amount in kept)
        if total < 1.0e-7:
            # The source is fully weighted, but keep a deterministic safeguard.
            kept = [("Hips", 1.0)]
            total = 1.0
        rows.append({name: amount / total for name, amount in kept})

    mesh_obj.vertex_groups.clear()
    new_groups = {
        name: mesh_obj.vertex_groups.new(name=name)
        for name in group_order
    }
    counts = {name: 0 for name in group_order}
    for index, mapped in enumerate(rows):
        for name, amount in mapped.items():
            new_groups[name].add([index], amount, "REPLACE")
            counts[name] += 1

    mesh_obj.parent = rig
    mesh_obj.matrix_parent_inverse = rig.matrix_world.inverted()
    modifier = mesh_obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    modifier.use_deform_preserve_volume = True

    empty = [name for name, count in counts.items() if count == 0]
    if empty:
        raise SystemExit("unweighted target groups: " + ", ".join(empty))
    print("skin: max 4 influences; group vertices=" + ", ".join(
        "{0}:{1}".format(name, counts[name]) for name in group_order))


def configure_animation_metrics(anim, rig: bpy.types.Object,
                                height: float) -> None:
    bones = rig.data.bones

    def length(name: str) -> float:
        bone = bones[name]
        return (bone.tail_local - bone.head_local).length

    def from_down(name: str) -> float:
        bone = bones[name]
        direction = (bone.tail_local - bone.head_local).normalized()
        cosine = max(-1.0, min(1.0, direction.dot(Vector((0, 0, -1)))))
        return math.degrees(math.acos(cosine))

    anim.LEG_ROOT_HEIGHT = bones["LeftUpperLeg"].head_local.z
    anim.ANKLE_HEIGHT = bones["LeftFoot"].head_local.z
    anim.THIGH_LENGTH = length("LeftUpperLeg")
    anim.SHIN_LENGTH = length("LeftLowerLeg")
    anim.ARM_REST_OUT = from_down("LeftUpperArm")
    anim.FOREARM_REST_OUT = from_down("LeftLowerArm")
    anim.FOREARM_FLARE = max(
        0.0, anim.FOREARM_REST_OUT - anim.ARM_REST_OUT)
    anim.BODY_SCALE = height / 1.45
    leg_share = anim.LEG_ROOT_HEIGHT / height
    anim.STRIDE_SCALE = (0.525 / 1.45) / leg_share
    print("animation proportions: leg_root={0:.3f}, ankle={1:.3f}, "
          "thigh={2:.3f}, shin={3:.3f}, arm={4:.1f}/{5:.1f}, "
          "scale={6:.3f}, stride={7:.3f}".format(
              anim.LEG_ROOT_HEIGHT, anim.ANKLE_HEIGHT,
              anim.THIGH_LENGTH, anim.SHIN_LENGTH,
              anim.ARM_REST_OUT, anim.FOREARM_REST_OUT,
              anim.BODY_SCALE, anim.STRIDE_SCALE))


def bigfoot_animations(anim):
    """Boss-specific clips in build_animations.py's shared pose format."""
    rot = anim.rot
    arm_hang = anim.arm_hang
    leg_fold = anim.leg_fold
    tau = math.tau

    def clamp(value):
        return max(0.0, min(1.0, value))

    def ease(value):
        value = clamp(value)
        return value * value * (3.0 - 2.0 * value)

    def pulse(t, start, peak, end):
        if t <= start or t >= end:
            return 0.0
        if t < peak:
            return ease((t - start) / max(peak - start, 1.0e-6))
        return 1.0 - ease((t - peak) / max(end - peak, 1.0e-6))

    rest_thigh, rest_knee, rest_foot = leg_fold(0.0)

    def legs_from_drop(pose, drop, spread=0.0):
        thigh, knee, foot = leg_fold(drop)
        for side, sign, _ in anim.SIDES:
            pose[side + "UpperLeg"] = rot(
                ("X", thigh - rest_thigh), ("Y", -sign * spread))
            pose[side + "LowerLeg"] = rot(("X", knee - rest_knee))
            pose[side + "Foot"] = rot(("X", foot - rest_foot))

    def idle_pose(t):
        breath = math.sin(t * tau)
        sway = math.sin(t * tau * 0.5)
        pose = {
            "Hips": {
                "rot": [("Z", 1.8 * sway)],
                "loc": (0.0, 0.0, 0.005 * breath),
            },
            "Spine": rot(("X", -7.0 - 0.8 * breath), ("Z", -1.2 * sway)),
            "Chest": rot(("X", -3.0 + 1.7 * breath), ("Z", -1.0 * sway)),
            "UpperChest": rot(("X", 2.0 + 0.8 * breath)),
            "Neck": rot(("X", 4.0 - 0.8 * breath)),
            "Head": rot(("X", 3.0), ("Z", 2.0 * sway)),
        }
        for side, sign, offset in anim.SIDES:
            arm_hang(
                pose, side, sign, out=18.0 + 1.2 * breath,
                swing=-6.0 + 2.0 * math.sin(t * tau + offset),
                flex=20.0 + 2.0 * breath)
        return pose

    def walk_pose(t):
        phase = t * tau
        pose = {}
        anim._stride(
            pose, phase, thigh=26.0, knee_mid=-28.0, knee_swing=25.0,
            foot=12.0, arm=22.0, elbow=17.0, hang=19.0)
        dip = -0.020 * (1.0 - math.cos(phase * 2.0)) * 0.5
        pose["Hips"] = {
            "rot": [("Z", 6.0 * math.sin(phase))],
            "loc": (0.006 * math.sin(phase), 0.0, dip),
        }
        pose["Spine"] = rot(("X", -9.0), ("Z", -4.0 * math.sin(phase)))
        pose["Chest"] = rot(("X", -3.0), ("Z", -5.0 * math.sin(phase)))
        pose["Neck"] = rot(("X", 7.0))
        pose["Head"] = rot(("X", 5.0), ("Z", 3.0 * math.sin(phase)))
        return pose

    def run_pose(t):
        phase = t * tau
        pose = {}
        anim._stride(
            pose, phase, thigh=40.0, knee_mid=-48.0, knee_swing=40.0,
            foot=18.0, arm=30.0, elbow=24.0, hang=25.0, arm_bias=-18.0)
        dip = -0.034 * (1.0 - math.cos(phase * 2.0)) * 0.5
        pose["Hips"] = {
            "rot": [("Z", 8.0 * math.sin(phase)), ("X", -3.0)],
            "loc": (0.0, 0.0, dip),
        }
        pose["Spine"] = rot(("X", -22.0), ("Z", -6.0 * math.sin(phase)))
        pose["Chest"] = rot(("X", -10.0), ("Z", -7.0 * math.sin(phase)))
        pose["UpperChest"] = rot(("X", -5.0))
        pose["Neck"] = rot(("X", 18.0))
        pose["Head"] = rot(("X", 17.0), ("Z", 4.0 * math.sin(phase)))
        return pose

    def roar_pose(t):
        power = ease(t / 0.26) * (1.0 - ease((t - 0.82) / 0.18))
        tremor = math.sin(t * tau * 5.0) * power
        pose = {
            # Rears up onto straighter legs and throws the chest out.
            "Hips": {
                "rot": [("Z", 2.0 * tremor), ("X", 6.0 * power)],
                "loc": (0.0, 0.0, 0.018 * power),
            },
            "Spine": rot(("X", 15.0 * power), ("Z", 1.5 * tremor)),
            "Chest": rot(("X", 18.0 * power), ("Z", -2.0 * tremor)),
            "UpperChest": rot(("X", 11.0 * power)),
            # This head sits straight on the shoulders with no neck to speak of,
            # so the tilt back is small and the reach comes from a lift instead.
            # Rotating it as far as a human's puts the jaw through the sternum.
            "Neck": {
                "rot": [("X", 13.0 * power)],
                "loc": (0.0, 0.012 * power, 0.026 * power),
            },
            "Head": rot(("X", 15.0 * power), ("Z", 1.5 * tremor)),
        }
        for side, sign, _ in anim.SIDES:
            # Arms up and bent rather than spread flat: an ape roaring beats its
            # chest, and a straight-armed T on this silhouette reads as a stagger.
            arm_hang(
                pose, side, sign, out=16.0 + 26.0 * power,
                swing=-6.0 + 54.0 * power,
                flex=20.0 + 48.0 * power)
            pose[side + "Hand"] = rot(("X", -28.0 * power))
        return pose

    def meteor_windup_pose(t):
        power = ease(t)
        pose = {}
        legs_from_drop(pose, -0.13 * power, spread=8.0 * power)
        pose["Hips"] = {
            "rot": [("Z", -16.0 * power)],
            "loc": (0.0, 0.0, -0.13 * power),
        }
        pose["Spine"] = rot(("X", -20.0 * power), ("Z", 12.0 * power))
        pose["Chest"] = rot(("X", -10.0 * power), ("Z", 14.0 * power))
        pose["Neck"] = rot(("X", 18.0 * power), ("Z", -8.0 * power))
        pose["Head"] = rot(("X", 16.0 * power), ("Z", -10.0 * power))
        arm_hang(
            pose, "Right", 1.0, out=18.0 + 18.0 * power,
            swing=-6.0 - 82.0 * power, flex=20.0 + 72.0 * power)
        arm_hang(
            pose, "Left", -1.0, out=18.0 + 15.0 * power,
            swing=-6.0 + 34.0 * power, flex=20.0 + 28.0 * power)
        pose["RightHand"] = rot(("Y", 20.0 * power))
        return pose

    def meteor_fly_pose(t):
        return anim.meteor_fly_pose(t)

    def meteor_impact_pose(t):
        strike = ease(t / 0.24)
        recover = ease((t - 0.62) / 0.38)
        power = strike * (1.0 - recover)
        pose = {}
        legs_from_drop(pose, -0.19 * power, spread=10.0 * power)
        pose["Hips"] = {
            "rot": [("Z", -10.0 * power)],
            "loc": (0.0, 0.0, -0.19 * power),
        }
        pose["Spine"] = rot(("X", -34.0 * power), ("Z", 9.0 * power))
        pose["Chest"] = rot(("X", -19.0 * power), ("Z", 8.0 * power))
        pose["Neck"] = rot(("X", 25.0 * power))
        pose["Head"] = rot(("X", 24.0 * power))
        arm_hang(
            pose, "Right", 1.0, out=8.0 + 22.0 * power,
            swing=172.0 - 142.0 * strike + 6.0 * recover,
            flex=-6.0 + 38.0 * strike)
        arm_hang(
            pose, "Left", -1.0, out=12.0 + 30.0 * power,
            swing=-62.0 + 84.0 * strike, flex=14.0 + 24.0 * power)
        return pose

    def punch_pose(t):
        wind = ease(t / 0.25)
        strike = ease((t - 0.25) / 0.27)
        recover = ease((t - 0.72) / 0.28)
        active = 1.0 - recover
        pose = {
            "Hips": rot(("Z", -10.0 * strike * active)),
            "Spine": rot(("X", -9.0 * strike * active),
                         ("Z", 12.0 * strike * active)),
            "Chest": rot(("Z", 14.0 * strike * active)),
            "Head": rot(("Z", -7.0 * strike * active)),
        }
        swing = (-42.0 * wind * (1.0 - strike)
                 + 108.0 * strike) * active
        flex = (20.0 + 68.0 * wind * (1.0 - strike)
                - 16.0 * strike) * active + 20.0 * recover
        arm_hang(
            pose, "Right", 1.0, out=20.0, swing=swing, flex=flex)
        arm_hang(
            pose, "Left", -1.0, out=22.0,
            swing=-10.0 - 18.0 * strike * active,
            flex=24.0 + 24.0 * strike * active)
        pose["RightHand"] = rot(("Y", 26.0 * wind * active))
        return pose

    def grab_pose(t):
        reach = pulse(t, 0.05, 0.48, 0.96)
        close = ease((t - 0.34) / 0.30) * (1.0 - ease((t - 0.82) / 0.18))
        pose = {
            "Spine": rot(("X", -18.0 * reach)),
            "Chest": rot(("X", -8.0 * reach)),
            "Neck": rot(("X", 14.0 * reach)),
            "Head": rot(("X", 12.0 * reach)),
        }
        for side, sign, _ in anim.SIDES:
            arm_hang(
                pose, side, sign, out=18.0 + 20.0 * reach,
                swing=-6.0 + 72.0 * reach,
                flex=20.0 + 52.0 * reach - 32.0 * close)
            pose[side + "Hand"] = rot(
                ("Y", sign * 32.0 * close),
                ("Z", -sign * 12.0 * close))
        return pose

    def throw_pose(t):
        wind = ease(t / 0.38)
        release = ease((t - 0.38) / 0.28)
        settle = ease((t - 0.78) / 0.22)
        active = 1.0 - settle
        pose = {
            "Hips": rot(("Z", (-18.0 * wind + 30.0 * release) * active)),
            "Spine": rot(("X", -8.0 * active),
                         ("Z", (16.0 * wind - 24.0 * release) * active)),
            "Chest": rot(("Z", (18.0 * wind - 30.0 * release) * active)),
            "Head": rot(("Z", (-10.0 * wind + 14.0 * release) * active)),
        }
        arm_hang(
            pose, "Right", 1.0, out=24.0,
            swing=(-68.0 * wind + 186.0 * release) * active,
            flex=(88.0 * wind - 92.0 * release) * active + 20.0 * settle)
        arm_hang(
            pose, "Left", -1.0, out=24.0 + 18.0 * wind * active,
            swing=(42.0 * wind - 58.0 * release) * active,
            flex=48.0 * wind * active + 20.0 * settle)
        return pose

    def hit_react_pose(t):
        hit = math.sin(math.pi * clamp(t))
        pose = {
            "Hips": rot(("Z", -6.0 * hit)),
            "Spine": rot(("X", 22.0 * hit), ("Z", 12.0 * hit)),
            "Chest": rot(("X", 13.0 * hit), ("Z", 10.0 * hit)),
            "Neck": rot(("X", -18.0 * hit), ("Z", -8.0 * hit)),
            "Head": rot(("X", -22.0 * hit), ("Z", -12.0 * hit)),
        }
        arm_hang(
            pose, "Right", 1.0, out=18.0 + 38.0 * hit,
            swing=-6.0 + 36.0 * hit, flex=20.0 + 52.0 * hit)
        arm_hang(
            pose, "Left", -1.0, out=18.0 + 28.0 * hit,
            swing=-6.0 - 30.0 * hit, flex=20.0 + 44.0 * hit)
        return pose

    def defeat_pose(t):
        """The knees give way and the body goes limp, holding on the last key.

        Only the collapse is authored here. Toppling the carcass over onto the
        ground is `BigfootBoss._tick_defeat`, which can see the terrain the body
        has to come to rest against; a clip that laid him flat in place would
        stand him on his shoulder on any slope.
        """
        stagger = ease(t / 0.20)
        buckle = ease((t - 0.16) / 0.44)
        limp = ease((t - 0.46) / 0.54)
        pose = {}
        # As deep a fold as the leg solver allows without pulling the soles up.
        legs_from_drop(pose, -0.30 * buckle, spread=17.0 * buckle)
        pose["Hips"] = {
            "rot": [("X", -12.0 * buckle), ("Z", -14.0 * limp)],
            "loc": (0.0, -0.02 * buckle, -0.30 * buckle),
        }
        pose["Spine"] = rot(("X", -26.0 * buckle), ("Z", 15.0 * limp))
        pose["Chest"] = rot(("X", -19.0 * buckle), ("Z", 11.0 * limp))
        pose["UpperChest"] = rot(("X", -9.0 * buckle))
        # Snapped back by the killing blow, then hanging off a slack neck.
        pose["Neck"] = rot(("X", 15.0 * stagger - 24.0 * limp))
        pose["Head"] = rot(("X", 13.0 * stagger - 28.0 * limp),
                           ("Z", -12.0 * limp))
        for side, sign, _ in anim.SIDES:
            arm_hang(
                pose, side, sign, out=14.0 - 5.0 * limp,
                swing=-4.0 + 26.0 * buckle - 8.0 * limp,
                flex=18.0 - 12.0 * limp)
        return pose

    return [
        ("Idle", 90, True, idle_pose),
        ("Walk", 36, True, walk_pose),
        ("Run", 24, True, run_pose),
        ("Roar", 54, False, roar_pose),
        ("MeteorWindup", 48, False, meteor_windup_pose),
        ("MeteorFly", 30, True, meteor_fly_pose),
        ("MeteorImpact", 36, False, meteor_impact_pose),
        ("Punch", 24, False, punch_pose),
        ("Grab", 30, False, grab_pose),
        ("Throw", 36, False, throw_pose),
        ("HitReact", 18, False, hit_react_pose),
        ("Defeat", 60, False, defeat_pose),
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


def validate_open_file(mesh_obj: bpy.types.Object,
                       rig: bpy.types.Object) -> None:
    low, high = mesh_bounds(mesh_obj)
    size = high - low
    color = mesh_obj.data.color_attributes.get("Color")
    clips = tuple(track.name for track in rig.animation_data.nla_tracks)
    if clips != REQUIRED_CLIPS:
        raise SystemExit("unexpected NLA clips: " + repr(clips))
    if color is None or color.domain != "CORNER":
        raise SystemExit("runtime mesh lost Color")
    if abs(size.z - TARGET_HEIGHT) > 0.005 or abs(low.z) > 0.002:
        raise SystemExit("runtime bounds are not normalized and grounded")
    if rig.data.bones["LeftHand"].head_local.x >= 0.0:
        raise SystemExit("LeftHand is on the wrong Blender side")
    if rig.data.bones["LeftToes"].tail_local.y <= \
            rig.data.bones["LeftFoot"].head_local.y:
        raise SystemExit("Bigfoot toes do not point Blender +Y")
    material = mesh_obj.data.materials[0]
    required_rim_nodes = {
        "Camera Rim Layer Weight",
        "Camera Rim Color Ramp",
        "Camera Rim Emission",
        "Camera Rim Mix Shader",
    }
    missing_rim_nodes = required_rim_nodes.difference(
        node.name for node in material.node_tree.nodes)
    if missing_rim_nodes:
        raise SystemExit("Bigfoot camera rim is incomplete: "
                         + repr(sorted(missing_rim_nodes)))
    print("final: bounds={0:.3f} x {1:.3f} x {2:.3f} m, floor={3:+.4f}, "
          "mesh={4} verts/{5} tris, bones={6}, clips={7}, Color={8}/{9}".format(
              size.x, size.y, size.z, low.z,
              len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
              len(rig.data.bones), len(clips), color.domain, color.data_type))
    for name, frames, looping, _ in bigfoot_animations(
            load_sibling("build_animations.py", "_bigfoot_report")):
        keys = frames + 1 if looping else frames
        print("  {0:<14} {1:>3} keys  {2:.2f}s  {3}".format(
            name, keys, (keys - 1) / FPS,
            "loop" if looping else "one-shot"))


def main() -> None:
    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_GLB), exist_ok=True)
    mesh_obj, source_bones, source_hash = normalize_source()
    optimize(mesh_obj)
    vertex_color_material(mesh_obj)
    rig, measurements = build_armature(mesh_obj, source_bones)
    remap_weights(mesh_obj, rig, measurements)

    low, high = mesh_bounds(mesh_obj)
    anim = load_sibling("build_animations.py", "_bigfoot")
    configure_animation_metrics(anim, rig, high.z - low.z)
    animations = bigfoot_animations(anim)
    if tuple(spec[0] for spec in animations) != REQUIRED_CLIPS:
        raise SystemExit("Bigfoot animation table is incomplete")
    anim.ANIMATIONS = animations
    # Keep the shared baker and NLA authoring path, but make its final export
    # explicit about emitting exactly the active Color layer as COLOR_0.
    anim.export = export_runtime
    anim.bake_into_open_file(OUT_BLEND, OUT_GLB)

    # The arbitrary Mix Shader graph is for Blender authoring and preview. Keep
    # the runtime GLB export-safe, then save the equivalent graph into the work
    # blend after export; Godot supplies its counterpart through vivid_surface.
    add_camera_rim(mesh_obj.data.materials[0])
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    validate_open_file(mesh_obj, rig)
    after_hash = file_sha256(SRC_BLEND)
    if after_hash != source_hash:
        raise SystemExit("source Bigfoot blend changed during the build")
    print("source preserved: sha256=" + after_hash)
    print("wrote " + OUT_BLEND)


if __name__ == "__main__":
    main()
