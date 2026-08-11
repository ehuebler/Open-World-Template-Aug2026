"""Build every Blender-authored VAT asset used by the project.

Run from the repository root with Blender 5.1:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" `
        --background --factory-startup `
        --python assets/source/blender/build_vat_assets.py

The source .blend files are opened read-only and are never saved. Runtime
outputs are written under ``assets/runtime/vat`` while all authoring inputs
remain hidden from Godot under ``assets/source``.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
DEFAULT_OUTPUT_DIR = os.path.join(
    PROJECT_DIR, "assets", "runtime", "vat")
if SOURCE_DIR not in sys.path:
    sys.path.insert(0, SOURCE_DIR)

import build_vat


FISH_TRIANGLES = 2500
FLOWER_NEAR_TRIANGLES = 520
FLOWER_FAR_TRIANGLES = 110
FISH_FRAME_COUNT = 50
FLOWER_FRAME_COUNT = 24
GRASS_FRAME_COUNT = 16
FPS = 24


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--fish-triangles", type=int, default=FISH_TRIANGLES)
    parser.add_argument("--flower-near-triangles", type=int, default=FLOWER_NEAR_TRIANGLES)
    parser.add_argument("--flower-far-triangles", type=int, default=FLOWER_FAR_TRIANGLES)
    blender_args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return parser.parse_args(blender_args)


def _open_source(filename: str) -> None:
    path = os.path.join(PROJECT_DIR, "assets", "source", "meshmaker", filename)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    bpy.ops.wm.open_mainfile(filepath=path)


def _biggest_mesh() -> bpy.types.Object:
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    if not meshes:
        raise RuntimeError("source file has no mesh")
    return max(meshes, key=lambda obj: len(obj.data.vertices))


def _source_rig(mesh: bpy.types.Object) -> bpy.types.Object:
    for modifier in mesh.modifiers:
        if modifier.type == "ARMATURE" and modifier.object is not None:
            return modifier.object
    if mesh.parent is not None and mesh.parent.type == "ARMATURE":
        return mesh.parent
    rigs = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(rigs) != 1:
        raise RuntimeError("expected one source armature, found {}".format(len(rigs)))
    return rigs[0]


def _activate(obj: bpy.types.Object) -> None:
    view_layer = bpy.context.view_layer
    for candidate in view_layer.objects:
        candidate.select_set(False)
    obj.hide_viewport = False
    obj.select_set(True)
    view_layer.objects.active = obj


def _weighted_vertex_count(obj: bpy.types.Object) -> int:
    return sum(1 for vertex in obj.data.vertices if any(group.weight > 0.0 for group in vertex.groups))


def _decimate_before_armature(
    obj: bpy.types.Object,
    target_triangles: int,
    *,
    minimum: int,
    maximum: int,
) -> int:
    """Apply a collapse decimate first in the stack and verify carried data."""

    before = build_vat.triangle_count(obj.data)
    if before <= target_triangles:
        raise ValueError(
            "{} already has {} triangles, below requested decimation target {}".format(
                obj.name, before, target_triangles
            )
        )
    color_names = {attribute.name for attribute in obj.data.color_attributes}
    group_names = {group.name for group in obj.vertex_groups}
    weighted_before = _weighted_vertex_count(obj)
    if not color_names:
        raise ValueError("{} has no MeshMaker vertex colors".format(obj.name))
    if not group_names or weighted_before == 0:
        raise ValueError("{} has no deformation weights to preserve".format(obj.name))

    modifier = obj.modifiers.new("VAT_FinalTopology", "DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.ratio = float(target_triangles) / float(before)
    modifier.use_collapse_triangulate = True
    _activate(obj)
    # This is load-bearing: applying after Armature would freeze one pose and
    # could generate a different collapse at different animation frames.
    bpy.ops.object.modifier_move_to_index(modifier=modifier.name, index=0)
    bpy.ops.object.modifier_apply(modifier=modifier.name)

    after = build_vat.triangle_count(obj.data)
    if not minimum <= after <= maximum:
        raise ValueError(
            "{} decimated to {} triangles, expected {}..{}".format(
                obj.name, after, minimum, maximum
            )
        )
    if not color_names.issubset({attribute.name for attribute in obj.data.color_attributes}):
        raise ValueError("decimation dropped a vertex-color attribute")
    if not group_names.issubset({group.name for group in obj.vertex_groups}):
        raise ValueError("decimation dropped a vertex group")
    if _weighted_vertex_count(obj) == 0:
        raise ValueError("decimation dropped all deformation weights")
    armature_modifiers = [item for item in obj.modifiers if item.type == "ARMATURE"]
    if not armature_modifiers:
        raise ValueError("decimation unexpectedly removed the Armature modifier")

    print(
        "decimated {}: {} -> {} triangles; {} colors; {} weighted vertices".format(
            obj.name,
            before,
            after,
            len(obj.data.color_attributes),
            _weighted_vertex_count(obj),
        )
    )
    return after


def _configure_timeline(frame_count: int) -> None:
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1.0
    scene.frame_start = 0
    scene.frame_end = frame_count - 1
    scene.frame_set(0)


def _output_base(output_dir: str, name: str) -> str:
    return os.path.join(os.path.abspath(output_dir), name)


def build_fish(output_dir: str, target_triangles: int) -> build_vat.VATBakeResult:
    print("\n=== fish VAT ===")
    _open_source("fish.blend")
    _configure_timeline(FISH_FRAME_COUNT)
    fish = _biggest_mesh()
    rig = _source_rig(fish)
    action = bpy.data.actions.get("fish_swim")
    if action is None:
        raise ValueError("fish.blend has no fish_swim action")
    rig.animation_data_create()
    if rig.animation_data.action != action:
        rig.animation_data.action = action
    _decimate_before_armature(
        fish,
        target_triangles,
        minimum=2000,
        maximum=3000,
    )
    return build_vat.bake(
        fish,
        range(FISH_FRAME_COUNT),
        fps=FPS,
        output_base=_output_base(output_dir, "fish_vat"),
        node_name="FishVAT",
        mesh_name="FishVATMesh",
        loop=True,
        # fish_swim contains the duplicate endpoint at frame 50; rows are 0..49.
        loop_endpoint=FISH_FRAME_COUNT,
        loop_tolerance=2.0e-4,
    )


def _reset_pose(rig: bpy.types.Object) -> None:
    for pose_bone in rig.pose.bones:
        pose_bone.matrix_basis = Matrix.Identity(4)
        pose_bone.rotation_mode = "XYZ"


def _flower_sway_bones(rig: bpy.types.Object) -> tuple[bpy.types.PoseBone, bpy.types.PoseBone]:
    preferred = [rig.pose.bones.get(name) for name in ("spine_01", "spine_02")]
    if all(preferred):
        return preferred[0], preferred[1]
    candidates = [
        pose_bone
        for pose_bone in rig.pose.bones
        if pose_bone.parent is not None and pose_bone.bone.use_deform
    ]
    if len(candidates) < 2:
        raise ValueError("flower rig needs two non-root deform bones")
    return candidates[0], candidates[1]


def _create_flower_sway(rig: bpy.types.Object) -> bpy.types.Action:
    """Author dense periodic keys on exactly the flower's two stem bones."""

    if rig.animation_data is not None:
        rig.animation_data_clear()
    _reset_pose(rig)
    lower, upper = _flower_sway_bones(rig)
    endpoint = FLOWER_FRAME_COUNT
    for frame in range(endpoint + 1):
        phase = math.tau * frame / endpoint
        # The upper stem travels farther than the lower stem, giving the bloom
        # a soft lag without moving the planted root.
        lower.rotation_euler = (
            math.radians(3.5) * math.sin(phase),
            math.radians(4.5) * math.cos(phase),
            math.radians(1.2) * math.sin(2.0 * phase),
        )
        upper.rotation_euler = (
            math.radians(6.0) * math.sin(phase + 0.22),
            math.radians(7.5) * math.cos(phase + 0.22),
            math.radians(1.8) * math.sin(2.0 * phase + 0.35),
        )
        lower.keyframe_insert(data_path="rotation_euler", frame=frame, group=lower.name)
        upper.keyframe_insert(data_path="rotation_euler", frame=frame, group=upper.name)

    if rig.animation_data is None or rig.animation_data.action is None:
        raise RuntimeError("Blender did not create the flower sway action")
    action = rig.animation_data.action
    action.name = "flower_sway"
    bpy.context.scene.frame_set(0)
    print(
        "authored {} on bones {} and {}, frames 0..{} ({} is duplicate endpoint)".format(
            action.name, lower.name, upper.name, endpoint, endpoint
        )
    )
    return action


def build_flower_variant(
    output_dir: str,
    *,
    target_triangles: int,
    output_name: str,
    node_name: str,
    minimum: int,
    maximum: int,
) -> build_vat.VATBakeResult:
    print("\n=== {} ===".format(output_name))
    # Reopen for each LOD so near and far are independently collapsed from the
    # original 60k-triangle weighted mesh.
    _open_source("purple_closed_flower.blend")
    _configure_timeline(FLOWER_FRAME_COUNT)
    flower = _biggest_mesh()
    rig = _source_rig(flower)
    _decimate_before_armature(
        flower,
        target_triangles,
        minimum=minimum,
        maximum=maximum,
    )
    _create_flower_sway(rig)
    return build_vat.bake(
        flower,
        range(FLOWER_FRAME_COUNT),
        fps=FPS,
        output_base=_output_base(output_dir, output_name),
        node_name=node_name,
        mesh_name=node_name + "Mesh",
        loop=True,
        loop_endpoint=FLOWER_FRAME_COUNT,
        loop_tolerance=2.0e-4,
    )


def _grass_material() -> bpy.types.Material:
    material = bpy.data.materials.new("GrassVATMaterial")
    material.use_nodes = True
    material.use_backface_culling = False
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    shader = nodes.get("Principled BSDF")
    shader.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
    shader.inputs["Roughness"].default_value = 0.9
    vertex_color = nodes.new("ShaderNodeVertexColor")
    vertex_color.layer_name = "Color"
    links.new(vertex_color.outputs["Color"], shader.inputs["Base Color"])
    return material


GRASS_NEAR_BLADES = 20
GRASS_FAR_BLADES = 8
GRASS_CLUMP_RADIUS = 0.30
# Three levels a blade rather than four. A 30 cm blade bent over one kink reads
# the same as one bent over two from any distance a person stands at, and the
# saving is a third of every grass triangle on the planet.
GRASS_LEVELS = 3


def _grass_blade_layout(count: int, widen: float
		) -> tuple[tuple[float, float, float, float, float, float], ...]:
    """One splayed clump of turf: angle, radius, height, width, out-curve, side.

    The unit of grass in the world is this clump, not a blade, and it has to
    cover ground: a lawn made of narrow upright tufts is a lawn with soil
    between every one of them however many are scattered.  So the blades are
    spread evenly over a disc by the golden angle, and the ones further out
    lean further out, which gives the clump a skirt that overlaps its
    neighbours' at a density the CPU can still place.

    [param widen] is how much thicker each blade is drawn, and it is what makes
    a level of detail possible at all.  Coverage is blades times blade width;
    the distant clump spends a third of the triangles on blades half again as
    wide, so it covers the same ground and only stops looking like separate
    blades at a range where they were never separable anyway.
    """

    golden = math.pi * (3.0 - math.sqrt(5.0))
    blades = []
    for index in range(count):
        # Square-rooted so the blades are spread over the disc's area rather
        # than crowded into its middle.
        share = math.sqrt((index + 0.5) / count)
        radial = GRASS_CLUMP_RADIUS * share
        wobble = math.sin(index * 2.399)
        blades.append((
            index * golden,
            radial,
            # Tallest in the middle, shortest at the skirt, so the clump reads
            # as a mound of grass rather than a brush.
            0.40 - 0.15 * share + 0.03 * wobble,
            (0.050 - 0.014 * share) * widen,
            0.055 + 0.55 * radial,
            0.014 * wobble,
        ))
    return tuple(blades)


def _create_grass_mesh(count: int, widen: float
		) -> tuple[bpy.types.Object, list[float]]:
    """Create the clump's curved strips, six vertices and four triangles a blade."""

    # angle, radial offset, height, width, forward curve, side curve
    blades = _grass_blade_layout(count, widen)
    levels = GRASS_LEVELS
    vertices: list[tuple[float, float, float]] = []
    faces: list[tuple[int, int, int, int]] = []
    colors: list[tuple[float, float, float, float]] = []
    height_fractions: list[float] = []

    for angle, radial, height, width, forward_curve, side_curve in blades:
        forward = Vector((math.cos(angle), math.sin(angle), 0.0))
        side = Vector((-math.sin(angle), math.cos(angle), 0.0))
        base = forward * radial
        first_vertex = len(vertices)
        for level in range(levels):
            fraction = level / (levels - 1)
            bend = fraction * fraction
            centre = (
                base
                + forward * (forward_curve * bend)
                + side * (side_curve * math.sin(fraction * math.pi))
                + Vector((0.0, 0.0, height * fraction))
            )
            half_width = width * 0.5 * (1.0 - 0.88 * fraction)
            for sign in (-1.0, 1.0):
                vertices.append(tuple(centre + side * (half_width * sign)))
                # MeshMaker-style baked color, dark at the root and yellow-green
                # at the tip.  Alpha remains opaque.
                colors.append((
                    0.055 + 0.10 * fraction,
                    0.20 + 0.30 * fraction,
                    0.035 + 0.07 * fraction,
                    1.0,
                ))
                height_fractions.append(fraction)
        for level in range(levels - 1):
            lower = first_vertex + level * 2
            upper = lower + 2
            faces.append((lower, lower + 1, upper + 1, upper))

    mesh = bpy.data.meshes.new("GrassSourceMesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    color_attribute = mesh.color_attributes.new(
        name="Color",
        type="BYTE_COLOR",
        domain="CORNER",
    )
    for loop in mesh.loops:
        color_attribute.data[loop.index].color = colors[loop.vertex_index]
    mesh.color_attributes.active_color_name = color_attribute.name
    mesh.color_attributes.render_color_index = 0
    mesh.materials.append(_grass_material())

    grass = bpy.data.objects.new("GrassSource", mesh)
    bpy.context.scene.collection.objects.link(grass)
    return grass, height_fractions


def _create_grass_sway(
    grass: bpy.types.Object,
    height_fractions: list[float],
) -> bpy.types.Action:
    """Add two signed bend shape keys and a 16-frame periodic action."""

    basis = grass.shape_key_add(name="Basis")
    bend_x = grass.shape_key_add(name="BendX")
    bend_y = grass.shape_key_add(name="BendY")
    for key in (bend_x, bend_y):
        key.slider_min = -1.0
        key.slider_max = 1.0
    for index, fraction in enumerate(height_fractions):
        influence = fraction * fraction
        bend_x.data[index].co = basis.data[index].co + Vector((
            0.075 * influence,
            0.0,
            -0.016 * influence,
        ))
        bend_y.data[index].co = basis.data[index].co + Vector((
            0.0,
            0.058 * influence,
            -0.011 * influence,
        ))

    endpoint = GRASS_FRAME_COUNT
    for frame in range(endpoint + 1):
        phase = math.tau * frame / endpoint
        bend_x.value = 0.82 * math.sin(phase)
        bend_y.value = 0.62 * math.sin(phase + math.pi * 0.5)
        bend_x.keyframe_insert(data_path="value", frame=frame, group="GrassBend")
        bend_y.keyframe_insert(data_path="value", frame=frame, group="GrassBend")
    shape_keys = grass.data.shape_keys
    if shape_keys.animation_data is None or shape_keys.animation_data.action is None:
        raise RuntimeError("Blender did not create the grass sway action")
    action = shape_keys.animation_data.action
    action.name = "grass_sway"
    bpy.context.scene.frame_set(0)
    return action


def build_grass(output_dir: str, *, count: int, widen: float,
                output_name: str, node_name: str) -> build_vat.VATBakeResult:
    print("\n=== {} ===".format(output_name))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _configure_timeline(GRASS_FRAME_COUNT)
    grass, height_fractions = _create_grass_mesh(count, widen)
    _create_grass_sway(grass, height_fractions)
    expected = count * GRASS_LEVELS * 2
    if len(grass.data.vertices) != expected:
        raise ValueError("grass clump has {} vertices, expected {}".format(
            len(grass.data.vertices), expected))
    blade_heights = [specification[2]
                     for specification in _grass_blade_layout(count, widen)]
    if not all(0.22 <= height <= 0.42 for height in blade_heights):
        raise ValueError("a grass blade's authored height is outside 0.22..0.42 m")
    if min(vertex.co.z for vertex in grass.data.vertices) < -1.0e-6:
        raise ValueError("grass vertices extend below their authored ground plane")

    result = build_vat.bake(
        grass,
        range(GRASS_FRAME_COUNT),
        fps=FPS,
        output_base=_output_base(output_dir, output_name),
        node_name=node_name,
        mesh_name=node_name + "Mesh",
        loop=True,
        loop_endpoint=GRASS_FRAME_COUNT,
        loop_tolerance=2.0e-4,
    )
    document, _binary = build_vat._read_glb(result.glb_path)
    if not document.get("materials") or not all(
        material.get("doubleSided", False)
        for material in document["materials"]
    ):
        raise ValueError("grass GLB material is not two-sided")
    return result


def _summary_record(result: build_vat.VATBakeResult) -> dict:
    return {
        "vertices": result.vertex_count,
        "glb_vertices_after_corner_splits": result.glb_vertex_count,
        "triangles": result.triangle_count,
        "frames": result.frame_count,
        "loop_endpoint_error": result.loop_endpoint_error,
        "glb": os.path.basename(result.glb_path),
        "exr": os.path.basename(result.exr_path),
        "json": os.path.basename(result.json_path),
    }


def main() -> None:
    args = _arguments()
    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    results = {
        "fish": build_fish(output_dir, args.fish_triangles),
        "purple_flower_near": build_flower_variant(
            output_dir,
            target_triangles=args.flower_near_triangles,
            output_name="purple_flower_near_vat",
            node_name="PurpleFlowerNearVAT",
            minimum=420,
            maximum=650,
        ),
        "purple_flower_far": build_flower_variant(
            output_dir,
            target_triangles=args.flower_far_triangles,
            output_name="purple_flower_far_vat",
            node_name="PurpleFlowerFarVAT",
            minimum=80,
            maximum=150,
        ),
        "grass_near": build_grass(
            output_dir,
            count=GRASS_NEAR_BLADES,
            widen=1.0,
            output_name="grass_vat",
            node_name="GrassVAT",
        ),
        "grass_far": build_grass(
            output_dir,
            count=GRASS_FAR_BLADES,
            widen=1.65,
            output_name="grass_far_vat",
            node_name="GrassFarVAT",
        ),
    }

    print("\nVAT_BUILD_SUMMARY")
    print(json.dumps(
        {name: _summary_record(result) for name, result in results.items()},
        indent=2,
        sort_keys=True,
    ))
    print("VAT build and validation complete")


if __name__ == "__main__":
    main()
