"""Build the rigged, animated runtime Sandworm from its read-only source.

Run from the project root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_sandworm.py

MeshMaker supplied a fully coloured, coiled mesh and a useful longitudinal
``spine_01`` weight gradient, but no armature.  This recipe turns that gradient
into a multi-bone spline skin, adds a separately weighted lower jaw, authors the
encounter clips, and exports the active corner-domain Color attribute as
``COLOR_0``.  The source blend is opened read-only and hash-checked afterwards.
"""

from __future__ import annotations

import hashlib
import heapq
import importlib.util
import math
import os

import bpy
from mathutils import Matrix, Vector
from mathutils.kdtree import KDTree


SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
SRC_BLEND = os.path.join(
    ROOT, "assets", "source", "meshmaker", "sandworm.blend")
OUT_BLEND = os.path.join(
    ROOT, "assets", "work", "sandworm_rigged.blend")
OUT_GLB = os.path.join(
    ROOT, "assets", "runtime", "characters", "sandworm.glb")

# A 120 m coil stands roughly 85 m high in the source pose: a twenty-plus-storey
# creature whose leap can be read from across its expanded desert arena.
TARGET_SPAN = 120.0
TARGET_TRIANGLES = 32_000
FPS = 30

CHAIN_BONES = (
    "Tail", "Body01", "Body02", "Body03", "Body04",
    "Body05", "Body06", "Neck", "Head",
)
REQUIRED_BONES = ("Root",) + CHAIN_BONES + ("LowerJaw",)


def load_sibling(filename: str, suffix: str):
    path = os.path.join(SOURCE_DIR, filename)
    spec = importlib.util.spec_from_file_location(
        os.path.splitext(filename)[0] + suffix, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REQUIRED_CLIPS = load_sibling(
    "boss_manifest.py", "_sandworm_manifest").required_clips(
        "sandworm",
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


def group_weight(vertex: bpy.types.MeshVertex,
                 group: bpy.types.VertexGroup) -> float:
    for assignment in vertex.groups:
        if assignment.group == group.index:
            return assignment.weight
    return 0.0


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    if abs(edge1 - edge0) < 1.0e-8:
        return float(value >= edge1)
    amount = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return amount * amount * (3.0 - 2.0 * amount)


def normalize_source() -> tuple[bpy.types.Object, str]:
    if not os.path.isfile(SRC_BLEND):
        raise SystemExit("Sandworm source is missing: " + SRC_BLEND)
    source_hash = file_sha256(SRC_BLEND)
    bpy.ops.wm.open_mainfile(filepath=SRC_BLEND)

    mesh_obj = bpy.data.objects.get("geometry_0")
    if mesh_obj is None or mesh_obj.type != "MESH":
        raise SystemExit("geometry_0 mesh is missing from " + SRC_BLEND)
    color = mesh_obj.data.color_attributes.get("Color")
    if color is None or color.domain != "CORNER":
        raise SystemExit("Sandworm source must contain corner-domain Color")
    if mesh_obj.vertex_groups.get("spine_01") is None:
        raise SystemExit("Sandworm source lost its longitudinal spine_01 weights")

    low, high = mesh_bounds(mesh_obj)
    horizontal = max(high.x - low.x, high.y - low.y)
    scale = TARGET_SPAN / horizontal
    # The sculpt's open jaws point source -X.  Blender +Y becomes Godot -Z,
    # making the visible bite agree with CharacterBody3D's forward direction.
    base = Matrix.Scale(scale, 4) @ Matrix.Rotation(-math.pi * 0.5, 4, "Z")
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

    for obj in list(bpy.data.objects):
        if obj is not mesh_obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)

    mesh_obj.name = "Character"
    mesh_obj.data.name = "SandwormMesh"
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.length_unit = "METERS"
    bpy.context.scene.render.fps = FPS
    print("source: {0} verts, {1} tris, {2:.3f} m span; sha256={3}".format(
        len(mesh_obj.data.vertices), triangle_count(mesh_obj.data),
        horizontal, source_hash))
    print("normalize: scale={0:.6f}, turn=-90 deg, target={1:.3f} m".format(
        scale, TARGET_SPAN))
    return mesh_obj, source_hash


def optimize(mesh_obj: bpy.types.Object) -> None:
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
        raise SystemExit("Sandworm still exceeds its triangle budget")
    for polygon in mesh_obj.data.polygons:
        polygon.use_smooth = True
    mesh_obj.data.update()
    print("optimize: {0} -> {1} tris, {2} verts".format(
        before, after, len(mesh_obj.data.vertices)))


def vertex_color_material(mesh_obj: bpy.types.Object) -> None:
    material = bpy.data.materials.new("SandwormVertexColor")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    for node in list(nodes):
        nodes.remove(node)
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    color = nodes.new("ShaderNodeVertexColor")
    color.name = "SandwormColor"
    color.layer_name = "Color"
    shader.inputs["Roughness"].default_value = 0.92
    shader.inputs["Specular IOR Level"].default_value = 0.22
    links.new(color.outputs["Color"], shader.inputs["Base Color"])
    links.new(color.outputs["Alpha"], shader.inputs["Alpha"])
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    mesh_obj.data.materials.clear()
    mesh_obj.data.materials.append(material)


def longitudinal_rows(mesh_obj: bpy.types.Object) -> list[float]:
    """Measure tail-to-head distance along the continuous sculpt topology.

    MeshMaker supplied only root/spine_01 skin influences. Treating the latter
    as a longitudinal gradient left most of the coiled mesh bound to unrelated
    chain sections: the bones straightened but the visible animal did not.
    Geodesic distance cannot jump between neighbouring turns of the coil, so it
    recovers a stable body coordinate without modifying the source file.
    """
    vertices = mesh_obj.data.vertices
    adjacency: list[list[tuple[int, float]]] = [
        [] for _ in range(len(vertices))]
    for edge in mesh_obj.data.edges:
        first, second = edge.vertices
        distance = (vertices[first].co - vertices[second].co).length
        adjacency[first].append((second, distance))
        adjacency[second].append((first, distance))

    unseen = set(range(len(vertices)))
    components: list[list[int]] = []
    while unseen:
        seed = next(iter(unseen))
        stack = [seed]
        unseen.remove(seed)
        component = []
        while stack:
            current = stack.pop()
            component.append(current)
            for neighbour, _distance in adjacency[current]:
                if neighbour in unseen:
                    unseen.remove(neighbour)
                    stack.append(neighbour)
        components.append(component)
    main = max(components, key=len)
    allowed = set(main)

    def distances(start: int) -> list[float]:
        result = [math.inf] * len(vertices)
        result[start] = 0.0
        queue = [(0.0, start)]
        while queue:
            distance, current = heapq.heappop(queue)
            if distance != result[current]:
                continue
            for neighbour, edge_length in adjacency[current]:
                if neighbour not in allowed:
                    continue
                candidate = distance + edge_length
                if candidate < result[neighbour]:
                    result[neighbour] = candidate
                    heapq.heappush(queue, (candidate, neighbour))
        return result

    first_pass = distances(main[0])
    tail_or_head = max(main, key=lambda index: first_pass[index])
    from_first = distances(tail_or_head)
    opposite = max(main, key=lambda index: from_first[index])
    from_opposite = distances(opposite)

    rows = [0.0] * len(vertices)
    for index in main:
        total = from_first[index] + from_opposite[index]
        rows[index] = from_first[index] / total if total > 1.0e-6 else 0.0

    # The head endpoint is the higher of the two on the grounded source sculpt.
    # Keep t=1 at the head because the last chain segment and jaw mask rely on it.
    if vertices[tail_or_head].co.z > vertices[opposite].co.z:
        rows = [1.0 - amount for amount in rows]
        tail_or_head, opposite = opposite, tail_or_head

    if len(main) < len(vertices):
        nearest = KDTree(len(main))
        for index in main:
            nearest.insert(vertices[index].co, index)
        nearest.balance()
        for component in components:
            if component is main:
                continue
            for index in component:
                _point, closest, _distance = nearest.find(vertices[index].co)
                rows[index] = rows[closest]

    print("topology: {0} components, {1}/{2} verts in body, "
          "{3:.1f} m tail-head geodesic".format(
              len(components), len(main), len(vertices),
              from_first[opposite]))
    return rows


def measured_chain(mesh_obj: bpy.types.Object,
                   rows: list[float]) -> list[Vector]:
    """Fit one centre knot per deform segment to the source weight gradient."""
    knot_count = len(CHAIN_BONES) + 1
    knots = []
    for index in range(knot_count):
        target = index / float(knot_count - 1)
        half = 0.065 if 0 < index < knot_count - 1 else 0.045
        samples = [
            (vertex.co.copy(), max(half - abs(amount - target), 0.0))
            for vertex, amount in zip(mesh_obj.data.vertices, rows)
            if abs(amount - target) <= half
        ]
        if len(samples) < 24:
            nearest = sorted(
                zip(mesh_obj.data.vertices, rows),
                key=lambda item: abs(item[1] - target),
            )[:128]
            samples = [(vertex.co.copy(), 1.0) for vertex, _ in nearest]
        total = sum(weight for _, weight in samples)
        knots.append(sum(
            (point * weight for point, weight in samples), Vector()) / total)

    # Endpoint means sit inside the thick tail and muzzle.  Extending each by a
    # fraction of its first chord lets the rest skeleton cover those caps without
    # changing the measured curve through the body.
    knots[0] += (knots[0] - knots[1]).normalized() * TARGET_SPAN * 0.035
    knots[-1] += (knots[-1] - knots[-2]).normalized() * TARGET_SPAN * 0.035
    print("chain:")
    for index, point in enumerate(knots):
        print("  {0:>2}: ({1:+.3f}, {2:+.3f}, {3:+.3f})".format(
            index, point.x, point.y, point.z))
    return knots


def build_armature(mesh_obj: bpy.types.Object,
                   knots: list[Vector]) -> bpy.types.Object:
    armature = bpy.data.armatures.new("SandwormSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")

    root = armature.edit_bones.new("Root")
    root.head = Vector((0.0, 0.0, 0.0))
    root.tail = Vector((0.0, 0.0, TARGET_SPAN * 0.045))

    previous = root
    for index, name in enumerate(CHAIN_BONES):
        bone = armature.edit_bones.new(name)
        bone.head = knots[index]
        bone.tail = knots[index + 1]
        if (bone.tail - bone.head).length < 0.05:
            bone.tail = bone.head + Vector((0.0, 0.05, 0.0))
        bone.parent = previous
        bone.use_connect = previous is not root
        previous = bone

    jaw = armature.edit_bones.new("LowerJaw")
    # The hinge is in the penultimate head cross-section; +Y is the exported
    # forward direction and the already-open lower jaw projects from it.
    jaw.head = knots[-2].lerp(knots[-1], 0.35)
    jaw.tail = jaw.head + Vector((0.0, TARGET_SPAN * 0.18, -0.03))
    jaw.parent = armature.edit_bones["Head"]
    jaw.use_connect = False

    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_X")
    bpy.ops.object.mode_set(mode="OBJECT")
    armature.bones["Root"].use_deform = False
    if tuple(bone.name for bone in armature.bones) != REQUIRED_BONES:
        raise SystemExit("Sandworm skeleton is incomplete")
    print("rig: {0} bones".format(len(armature.bones)))
    return rig


def remap_weights(mesh_obj: bpy.types.Object, rig: bpy.types.Object,
                  rows: list[float]) -> None:
    _, high = mesh_bounds(mesh_obj)
    height = high.z
    assignments: list[dict[str, float]] = []
    for vertex, amount in zip(mesh_obj.data.vertices, rows):
        along = amount * (len(CHAIN_BONES) - 1)
        first = min(int(math.floor(along)), len(CHAIN_BONES) - 1)
        second = min(first + 1, len(CHAIN_BONES) - 1)
        blend = along - first
        # At t == 1 both indices are Head. A dict literal with duplicate keys
        # would keep only the zero-valued blend entry, leaving the muzzle-tip
        # vertices unweighted and making glTF add a synthetic ``neutral_bone``.
        mapped = {CHAIN_BONES[first]: 1.0} if first == second else {
            CHAIN_BONES[first]: 1.0 - blend,
            CHAIN_BONES[second]: blend,
        }

        # Separate the forward, lower half of the muzzle.  The smooth bands leave
        # cheek and throat vertices shared with Head instead of making a hard
        # rubber seam at the hinge.
        jaw = smoothstep(0.73, 0.94, amount)
        jaw *= smoothstep(TARGET_SPAN * 0.13, TARGET_SPAN * 0.33, vertex.co.y)
        jaw *= 1.0 - smoothstep(height * 0.69, height * 0.78, vertex.co.z)
        jaw = max(0.0, min(0.92, jaw))
        if jaw > 1.0e-5:
            for name in list(mapped):
                mapped[name] *= 1.0 - jaw
            mapped["LowerJaw"] = jaw
        mapped = {name: weight for name, weight in mapped.items()
                  if weight > 1.0e-6}
        total = sum(mapped.values())
        assignments.append({
            name: weight / total for name, weight in mapped.items()
        })

    mesh_obj.vertex_groups.clear()
    groups = {
        name: mesh_obj.vertex_groups.new(name=name)
        for name in REQUIRED_BONES if name != "Root"
    }
    counts = {name: 0 for name in groups}
    for index, mapped in enumerate(assignments):
        for name, amount in mapped.items():
            groups[name].add([index], amount, "REPLACE")
            counts[name] += 1
    if counts["LowerJaw"] < 40:
        raise SystemExit("lower-jaw mask did not capture enough vertices")
    unweighted = [
        vertex.index for vertex in mesh_obj.data.vertices
        if not vertex.groups
    ]
    if unweighted:
        raise SystemExit(
            "Sandworm skin left {0} vertices unweighted".format(
                len(unweighted)))

    mesh_obj.parent = rig
    mesh_obj.matrix_parent_inverse = rig.matrix_world.inverted()
    modifier = mesh_obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = rig
    modifier.use_deform_preserve_volume = True
    print("skin: " + ", ".join(
        "{0}:{1}".format(name, counts[name]) for name in groups))


def sandworm_animations(anim, rig: bpy.types.Object):
    rot = anim.rot
    tau = math.tau
    chain_rest = []
    for name in CHAIN_BONES:
        bone = rig.data.bones[name]
        direction = (bone.tail_local - bone.head_local).normalized()
        chain_rest.append({
            "name": name,
            "head": bone.head_local.copy(),
            "length": (bone.tail_local - bone.head_local).length,
            "direction": direction,
            "basis": bone.matrix_local.to_3x3().copy(),
        })
    uncoiled_forward = Vector((0.0, 0.955, 0.297)).normalized()
    uncoiled_side = Vector((1.0, 0.0, 0.0))
    uncoiled_bend = Vector(
        (0.0, -uncoiled_forward.z, uncoiled_forward.y)).normalized()
    chain_length = sum(row["length"] for row in chain_rest)
    # Keep the attacking mouth near the runtime's 67 m bite anchor and send the
    # newly straightened body behind it, rather than moving the mouth hundreds
    # of metres ahead of the CharacterBody path.
    uncoiled_head = Vector((0.0, 0.0, 67.0))
    uncoiled_start = uncoiled_head - uncoiled_forward * chain_length

    def clamp(value):
        return max(0.0, min(1.0, value))

    def ease(value):
        value = clamp(value)
        return value * value * (3.0 - 2.0 * value)

    def uncoiled_pose(amount, phase):
        """Aim the connected skeleton down a long, shallow airborne S curve.

        The supplied sculpture is intentionally coiled in its bind pose. Small
        additive rotations cannot undo that rest curvature, so these clips key
        absolute armature-space matrices while preserving every segment length.
        """
        amount = ease(amount)
        head = chain_rest[0]["head"].lerp(uncoiled_start, amount)
        pose = {}
        for index, row in enumerate(chain_rest):
            wave = math.sin(index * 0.82 + phase * tau)
            rise = math.cos(index * 0.57 + phase * tau * 0.72)
            target = (
                uncoiled_forward
                + uncoiled_side * (0.075 * wave)
                + uncoiled_bend * (0.035 * rise)
            ).normalized()
            direction = row["direction"].lerp(target, amount).normalized()
            align = row["direction"].rotation_difference(direction)
            basis = align.to_matrix() @ row["basis"]
            matrix = basis.to_4x4()
            matrix.translation = head
            pose[row["name"]] = {"matrix": matrix}
            head = head + direction * row["length"]
        return pose

    def idle_pose(t):
        pose = uncoiled_pose(1.0, t * 0.08)
        pose["LowerJaw"] = rot(("X", 2.0 + 1.4 * math.sin(t * tau)))
        return pose

    def burrow_pose(t):
        pose = uncoiled_pose(1.0, 0.12 + t * 0.16)
        pose["LowerJaw"] = rot(("X", 5.0))
        return pose

    def emerge_pose(t):
        rise = ease(t / 0.72)
        pose = uncoiled_pose(1.0, 0.24 + t * 0.12)
        pose["LowerJaw"] = rot(("X", -12.0 * rise))
        return pose

    def leap_pose(t):
        pose = uncoiled_pose(1.0, 0.36 + t * 0.28)
        pose["LowerJaw"] = rot(("X", -18.0))
        return pose

    def bite_pose(t):
        wind = ease(t / 0.24)
        snap = ease((t - 0.24) / 0.20)
        release = ease((t - 0.62) / 0.38)
        active = 1.0 - release
        pose = uncoiled_pose(1.0, 0.08 + t * 0.16)
        # The rest mouth is open. The strike closes the separately weighted jaw;
        # the body remains extended through recovery instead of snapping back
        # into its authored resting coil in mid-air.
        pose["LowerJaw"] = rot(
            ("X", (-19.0 * wind + 43.0 * snap) * active))
        return pose

    def dive_pose(t):
        pose = uncoiled_pose(1.0, 0.52 + t * 0.20)
        pose["LowerJaw"] = rot(("X", 8.0 * ease(t / 0.68)))
        return pose

    def hit_react_pose(t):
        hit = math.sin(math.pi * clamp(t))
        pose = uncoiled_pose(1.0, 0.64 + hit * 0.10)
        pose["LowerJaw"] = rot(("X", -12.0 * hit))
        return pose

    def defeat_pose(t):
        limp = ease((t - 0.58) / 0.42)
        pose = uncoiled_pose(1.0, 0.76 + ease(t) * 0.12)
        pose["LowerJaw"] = rot(("X", -22.0 * limp))
        return pose

    return [
        ("Idle", 90, True, idle_pose),
        ("Burrow", 30, True, burrow_pose),
        ("Emerge", 32, False, emerge_pose),
        ("Leap", 36, False, leap_pose),
        ("Bite", 24, False, bite_pose),
        ("Dive", 30, False, dive_pose),
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


def validate_extended_poses(rig: bpy.types.Object) -> None:
    if rig.animation_data is None:
        raise SystemExit("cannot validate the Sandworm poses")
    previous_frame = bpy.context.scene.frame_current
    muted = [track.mute for track in rig.animation_data.nla_tracks]
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    results = {}
    for name in REQUIRED_CLIPS:
        action = bpy.data.actions.get(name)
        if action is None:
            raise SystemExit("cannot validate Sandworm pose " + name)
        rig.animation_data.action = action
        start, end = action.frame_range
        bpy.context.scene.frame_set(round((start + end) * 0.5))
        bpy.context.view_layer.update()
        tail = rig.pose.bones["Tail"].head.copy()
        mouth = rig.pose.bones["Head"].tail.copy()
        chord = (mouth - tail).length
        length = sum(
            (rig.pose.bones[bone].tail - rig.pose.bones[bone].head).length
            for bone in CHAIN_BONES
        )
        results[name] = chord / max(length, 1.0e-6)
    rig.animation_data.action = None
    for track, was_muted in zip(rig.animation_data.nla_tracks, muted):
        track.mute = was_muted
    bpy.context.scene.frame_set(previous_frame)
    lowest = min(results.values())
    if lowest < 0.86:
        raise SystemExit(
            "Sandworm pose remained coiled: "
            + ", ".join("{0}={1:.1%}".format(name, amount)
                        for name, amount in results.items()))
    print("extended poses: " + ", ".join(
        "{0}={1:.1%}".format(name, amount)
        for name, amount in results.items()))


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
    validate_extended_poses(rig)
    # Decimation may remove a lone lowest tooth/scale tip. At this scale three
    # centimetres is far below the runtime sand clearance and keeps the stance
    # plane effectively exact.
    if abs(max(size.x, size.y) - TARGET_SPAN) > 0.03 \
            or abs(low.z) > 0.03:
        raise SystemExit("runtime bounds are not normalized and grounded")
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
    rows = longitudinal_rows(mesh_obj)
    knots = measured_chain(mesh_obj, rows)
    rig = build_armature(mesh_obj, knots)
    remap_weights(mesh_obj, rig, rows)

    anim = load_sibling("build_animations.py", "_sandworm")
    anim.BODY_SCALE = 1.0
    default_set_bone_pose = anim.set_bone_pose

    def set_sandworm_bone_pose(pose_bone, channels):
        absolute = channels.get("matrix")
        if absolute is None:
            default_set_bone_pose(pose_bone, channels)
            return
        pose_bone.rotation_mode = "QUATERNION"
        pose_bone.matrix = absolute
        # Connected children derive their matrix_basis from the evaluated parent
        # pose. Flush each absolute segment before the next one is solved, or
        # every child computes against the parent's previous-frame transform and
        # the baked chain folds back into a coil.
        bpy.context.view_layer.update()

    anim.set_bone_pose = set_sandworm_bone_pose
    animations = sandworm_animations(anim, rig)
    if tuple(spec[0] for spec in animations) != REQUIRED_CLIPS:
        raise SystemExit("Sandworm animation table is incomplete")
    anim.ANIMATIONS = animations
    anim.export = export_runtime
    anim.bake_into_open_file(OUT_BLEND, OUT_GLB)
    validate(mesh_obj, rig)

    after_hash = file_sha256(SRC_BLEND)
    if after_hash != source_hash:
        raise SystemExit("source Sandworm blend changed during the build")
    print("source preserved: sha256=" + after_hash)


if __name__ == "__main__":
    main()
