"""Procedurally builds the suited player character mesh and its humanoid rig.

Run headless from the project root:

    & "C:\\Program Files\\Blender Foundation\\Blender 4.5\\blender.exe" --background --factory-startup --python blender_assets/source/build_character.py

The script wipes the scene and rebuilds everything from the proportion tables
below, so it is safe to re-run after tweaking numbers. It writes the .blend next
to itself and the .glb one level up, where Godot picks it up as an asset.

Modelling approach: every body part is generated as a closed lofted tube (a
stack of elliptical cross sections). The parts are joined and then converted
into one watertight quad surface with a voxel remesh followed by a relaxation
pass, which fuses the parts into a single continuous skin with filleted joints
instead of leaving visible intersections. The silhouette therefore comes from
the section tables while the surface stays seamless.

Orientation: Z up, character faces +Y. The glTF exporter maps Blender +Y to
glTF/Godot -Z, so the exported character faces Godot's forward direction.
"""

import math
import os
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

# --------------------------------------------------------------------------
# Tunables
# --------------------------------------------------------------------------

RING_SEGMENTS = 48
CAP_STEPS = 8
# Sections in the tables below are control points; they are resampled along a
# Catmull-Rom spline so the surface curves continuously instead of stepping
# between truncated cones.
SPLINE_SAMPLES = 7

# Voxel size for the fusing remesh. Smaller keeps more detail but costs polys.
VOXEL_SIZE = 0.014
# Relaxation applied after the remesh; this is what turns the hard boolean-like
# intersections at the shoulders and hips into rounded fillets.
RELAX_ITERATIONS = 6
RELAX_FACTOR = 0.5

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
# The .blend stays in this .gdignore'd folder; only the .glb is a Godot asset.
BLEND_PATH = os.path.join(SOURCE_DIR, "player_character.blend")
GLB_PATH = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir, "player_character.glb"))

SUIT_COLOR = (0.780, 0.792, 0.812, 1.0)
ACCENT_COLOR = (0.235, 0.267, 0.318, 1.0)


# --------------------------------------------------------------------------
# Section tables (metres, before the final "feet on the floor" shift)
# --------------------------------------------------------------------------
# Each entry is (centre, radius_across, radius_depth). "Across" and "depth" are
# resolved against the per-section frame built from the hint vector passed to
# add_tube, so for the torso they mean width/depth and for the boots they mean
# width/height.

TORSO = [
    ((0.000,  0.000, 0.505), 0.150, 0.128),  # pelvis floor, hidden between the legs
    ((0.000, -0.010, 0.560), 0.180, 0.158),  # hips and seat
    ((0.000, -0.012, 0.620), 0.176, 0.152),
    ((0.000, -0.004, 0.685), 0.164, 0.134),  # waist pinch
    ((0.000,  0.004, 0.780), 0.196, 0.150),
    ((0.000,  0.010, 0.890), 0.228, 0.170),  # chest
    ((0.000,  0.010, 0.995), 0.242, 0.166),  # shoulder line
    ((0.000,  0.010, 1.068), 0.190, 0.154),  # shoulder slope into the hood
    ((0.000,  0.010, 1.122), 0.148, 0.138),  # neck
    ((0.000,  0.014, 1.190), 0.178, 0.180),  # hood base
    ((0.000,  0.012, 1.285), 0.199, 0.203),  # lower head
    ((0.000,  0.006, 1.390), 0.206, 0.208),  # widest point of the head
    ((0.000,  0.000, 1.505), 0.197, 0.200),  # upper head stays full
    ((0.000, -0.008, 1.605), 0.162, 0.168),  # crown shoulder
]
TORSO_BOTTOM_CAP = 0.070
TORSO_TOP_CAP = 0.093

# Right side only; the left side is mirrored. Character's right is +X.
ARM = [
    ((0.150, 0.005, 1.012), 0.120, 0.116),  # buried in the torso so the join fuses
    ((0.232, 0.005, 0.952), 0.112, 0.108),  # deltoid
    ((0.298, 0.008, 0.862), 0.104, 0.101),
    ((0.354, 0.010, 0.772), 0.096, 0.094),
    ((0.400, 0.012, 0.698), 0.090, 0.089),  # elbow
    ((0.456, 0.015, 0.606), 0.084, 0.082),
    ((0.506, 0.018, 0.526), 0.076, 0.072),  # wrist
    ((0.532, 0.020, 0.484), 0.092, 0.064),  # mitten flares wide and flattens
    ((0.562, 0.022, 0.436), 0.096, 0.062),
    ((0.580, 0.022, 0.396), 0.084, 0.055),
]
ARM_START_CAP = 0.050
ARM_END_CAP = 0.058

LEG = [
    ((0.112, 0.000, 0.580), 0.116, 0.120),  # buried in the pelvis
    ((0.122, 0.000, 0.478), 0.111, 0.116),
    ((0.126, -0.002, 0.392), 0.106, 0.112),  # thigh
    ((0.127,  0.004, 0.292), 0.096, 0.102),  # knee
    ((0.126, -0.004, 0.216), 0.094, 0.101),  # calf
    ((0.125,  0.000, 0.151), 0.083, 0.088),
    ((0.124,  0.010, 0.106), 0.076, 0.080),  # ankle
]
LEG_START_CAP = 0.060
LEG_END_CAP = 0.050

BOOT = [
    ((0.124, -0.072, 0.078), 0.078, 0.070),  # heel
    ((0.126, -0.010, 0.071), 0.087, 0.068),
    ((0.131,  0.055, 0.065), 0.087, 0.062),
    ((0.138,  0.120, 0.058), 0.076, 0.054),  # toe box
]
BOOT_START_CAP = 0.038
BOOT_END_CAP = 0.050
BOOT_TOE_OUT = math.radians(7.0)  # splay the boots outward around the ankle

# (name, parent, head, tail, connected)
BONES = [
    ("Root",       None,         (0.000, 0.000, 0.000), (0.000, 0.000, 0.120), False),
    ("Hips",       "Root",       (0.000, 0.000, 0.545), (0.000, 0.000, 0.665), False),
    ("Spine",      "Hips",       (0.000, 0.000, 0.665), (0.000, 0.000, 0.800), True),
    ("Chest",      "Spine",      (0.000, 0.000, 0.800), (0.000, 0.000, 0.905), True),
    ("UpperChest", "Chest",      (0.000, 0.000, 0.905), (0.000, 0.000, 1.030), True),
    ("Neck",       "UpperChest", (0.000, 0.000, 1.030), (0.000, 0.005, 1.150), True),
    ("Head",       "Neck",       (0.000, 0.005, 1.150), (0.000, 0.005, 1.560), True),
]

ARM_BONES = [
    ("{0}Shoulder", "UpperChest",     (0.055, 0.005, 1.005), (0.200, 0.005, 0.985), False),
    ("{0}UpperArm", "{0}Shoulder",    (0.200, 0.005, 0.985), (0.400, 0.012, 0.698), True),
    ("{0}LowerArm", "{0}UpperArm",    (0.400, 0.012, 0.698), (0.506, 0.018, 0.526), True),
    ("{0}Hand",     "{0}LowerArm",    (0.506, 0.018, 0.526), (0.572, 0.022, 0.420), True),
]

LEG_BONES = [
    ("{0}UpperLeg", "Hips",           (0.120, 0.000, 0.528), (0.127, 0.004, 0.292), False),
    ("{0}LowerLeg", "{0}UpperLeg",    (0.127, 0.004, 0.292), (0.124, 0.010, 0.106), True),
    ("{0}Foot",     "{0}LowerLeg",    (0.124, 0.010, 0.106), (0.131, 0.085, 0.048), True),
    ("{0}Toes",     "{0}Foot",        (0.131, 0.085, 0.048), (0.136, 0.150, 0.042), True),
]


# --------------------------------------------------------------------------
# Scene helpers
# --------------------------------------------------------------------------

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for collection in (bpy.data.objects, bpy.data.meshes, bpy.data.armatures,
                       bpy.data.materials, bpy.data.actions):
        for block in list(collection):
            if block.users == 0:
                collection.remove(block)


def activate(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


# --------------------------------------------------------------------------
# Lofting
# --------------------------------------------------------------------------

def catmull_rom(a, b, c, d, t):
    """Uniform Catmull-Rom; works for floats and Vectors alike."""
    t2 = t * t
    t3 = t2 * t
    return 0.5 * ((2.0 * b)
                  + (c - a) * t
                  + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
                  + (-a + 3.0 * b - 3.0 * c + d) * t3)


def resample(sections, samples=SPLINE_SAMPLES):
    """Densify a control-point table into a smoothly varying section list."""
    points = [Vector(entry[0]) for entry in sections]
    across = [entry[1] for entry in sections]
    depth = [entry[2] for entry in sections]

    # Clamped ends: duplicating the terminal control points keeps the curve
    # inside the silhouette the table describes.
    points = [points[0]] + points + [points[-1]]
    across = [across[0]] + across + [across[-1]]
    depth = [depth[0]] + depth + [depth[-1]]

    dense = []
    for i in range(1, len(points) - 2):
        for step in range(samples):
            t = step / samples
            dense.append((
                catmull_rom(points[i - 1], points[i], points[i + 1], points[i + 2], t),
                max(1.0e-4, catmull_rom(across[i - 1], across[i], across[i + 1], across[i + 2], t)),
                max(1.0e-4, catmull_rom(depth[i - 1], depth[i], depth[i + 1], depth[i + 2], t)),
            ))
    dense.append((points[-2], across[-2], depth[-2]))
    return dense


def section_frames(points, hint):
    """Return a (tangent, across, depth) orthonormal frame per section."""
    hint = Vector(hint).normalized()
    count = len(points)
    frames = []
    for index in range(count):
        if index == 0:
            tangent = points[1] - points[0]
        elif index == count - 1:
            tangent = points[-1] - points[-2]
        else:
            tangent = points[index + 1] - points[index - 1]
        tangent.normalize()

        depth = hint - tangent * tangent.dot(hint)
        if depth.length < 1.0e-5:
            fallback = Vector((1.0, 0.0, 0.0)) if abs(tangent.x) < 0.9 else Vector((0.0, 0.0, 1.0))
            depth = fallback - tangent * tangent.dot(fallback)
        depth.normalize()
        across = tangent.cross(depth)
        frames.append((tangent, across, depth))
    return frames


def ring_positions(centre, across, depth, radius_across, radius_depth, segments):
    step = 2.0 * math.pi / segments
    return [centre + across * (radius_across * math.cos(i * step))
                   + depth * (radius_depth * math.sin(i * step))
            for i in range(segments)]


def dome_rings(centre, tangent, across, depth, radius_across, radius_depth,
               length, steps, segments):
    """Rings between a base section and its pole, ordered base -> pole."""
    rings = []
    for step in range(1, steps):
        angle = (math.pi / 2.0) * (step / steps)
        scale = math.cos(angle)
        offset = length * math.sin(angle)
        rings.append(ring_positions(centre + tangent * offset, across, depth,
                                    radius_across * scale, radius_depth * scale,
                                    segments))
    return rings


def add_tube(bm, sections, hint, start_cap, end_cap, segments=RING_SEGMENTS):
    """Add one closed lofted volume to `bm`."""
    sections = resample(sections)
    points = [Vector(entry[0]) for entry in sections]
    frames = section_frames(points, hint)

    rings = []
    poles = []

    first_tangent, first_across, first_depth = frames[0]
    start_dome = dome_rings(points[0], -first_tangent, first_across, first_depth,
                            sections[0][1], sections[0][2], start_cap, CAP_STEPS,
                            segments)
    poles.append(points[0] - first_tangent * start_cap)
    rings.extend(reversed(start_dome))

    for index, (centre, radius_across, radius_depth) in enumerate(sections):
        _, across, depth = frames[index]
        rings.append(ring_positions(Vector(centre), across, depth,
                                    radius_across, radius_depth, segments))

    last_tangent, last_across, last_depth = frames[-1]
    rings.extend(dome_rings(points[-1], last_tangent, last_across, last_depth,
                            sections[-1][1], sections[-1][2], end_cap, CAP_STEPS,
                            segments))
    poles.append(points[-1] + last_tangent * end_cap)

    vert_rings = [[bm.verts.new(position) for position in ring] for ring in rings]
    start_pole = bm.verts.new(poles[0])
    end_pole = bm.verts.new(poles[1])

    for lower, upper in zip(vert_rings, vert_rings[1:]):
        for i in range(segments):
            j = (i + 1) % segments
            bm.faces.new((lower[i], lower[j], upper[j], upper[i]))

    for i in range(segments):
        j = (i + 1) % segments
        bm.faces.new((start_pole, vert_rings[0][j], vert_rings[0][i]))
        bm.faces.new((end_pole, vert_rings[-1][i], vert_rings[-1][j]))


def mirrored(sections):
    return [((-centre[0], centre[1], centre[2]), across, depth)
            for centre, across, depth in sections]


def rotated(sections, pivot, axis, angle):
    rotation = Matrix.Rotation(angle, 3, axis)
    pivot = Vector(pivot)
    return [(tuple(rotation @ (Vector(centre) - pivot) + pivot), across, depth)
            for centre, across, depth in sections]


# --------------------------------------------------------------------------
# Mesh build
# --------------------------------------------------------------------------

def build_raw_mesh():
    bm = bmesh.new()

    up = (0.0, 0.0, 1.0)
    forward = (0.0, 1.0, 0.0)

    add_tube(bm, TORSO, forward, TORSO_BOTTOM_CAP, TORSO_TOP_CAP)

    for side in (1.0, -1.0):
        arm = ARM if side > 0 else mirrored(ARM)
        leg = LEG if side > 0 else mirrored(LEG)
        boot = BOOT if side > 0 else mirrored(BOOT)

        ankle = (0.124 * side, 0.010, 0.106)
        boot = rotated(boot, ankle, "Z", -BOOT_TOE_OUT * side)

        add_tube(bm, arm, forward, ARM_START_CAP, ARM_END_CAP)
        add_tube(bm, leg, forward, LEG_START_CAP, LEG_END_CAP)
        add_tube(bm, boot, up, BOOT_START_CAP, BOOT_END_CAP)

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

    mesh = bpy.data.meshes.new("CharacterMesh")
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new("Character", mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def fuse_and_smooth(obj):
    """Turn the overlapping lofts into one continuous, evenly tessellated skin."""
    activate(obj)

    obj.data.remesh_voxel_size = VOXEL_SIZE
    obj.data.remesh_voxel_adaptivity = 0.0
    obj.data.use_remesh_fix_poles = True
    bpy.ops.object.voxel_remesh()

    relax = obj.modifiers.new("Relax", "SMOOTH")
    relax.factor = RELAX_FACTOR
    relax.iterations = RELAX_ITERATIONS
    bpy.ops.object.modifier_apply(modifier=relax.name)

    bpy.ops.object.shade_smooth()


def drop_to_floor(obj):
    """Move the mesh so the soles sit exactly on z=0; return the applied shift."""
    lowest = min((obj.matrix_world @ vert.co).z for vert in obj.data.vertices)
    shift = -lowest
    for vert in obj.data.vertices:
        vert.co.z += shift
    obj.data.update()
    return shift


def unwrap(obj):
    activate(obj)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")


def make_material(name, color, roughness):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    return material


WRIST = Vector((0.506, 0.018, 0.526))
ELBOW = Vector((0.400, 0.012, 0.698))

BOOT_CUFF_Z = 0.150
BELT_Z = (0.640, 0.702)
BELT_HALF_WIDTH = 0.25
MITTEN_REACH = 0.26


def _slab(low, high, half_width):
    def test(point):
        return abs(point.x) < half_width and low < point.z < high
    return test


def _below(height):
    def test(point):
        return point.z < height
    return test


def _sphere(centre, radius):
    def test(point):
        return (point - centre).length < radius
    return test


def _cap(centre, radius, axis):
    def test(point):
        offset = point - centre
        return offset.length < radius and offset.dot(axis) > 0.0
    return test


def accent_regions(shift):
    """Accent panels, each as the planes to cut plus the faces they cover.

    `limit` restricts which faces a plane is allowed to slice, which is what
    keeps the belt from carving a stripe straight through the forearms.
    """
    up = Vector((0.0, 0.0, 1.0))
    regions = [
        {   # boot cuffs
            "planes": [(Vector((0.0, 0.0, BOOT_CUFF_Z + shift)), up)],
            "limit": _below(0.34 + shift),
            "inside": _below(BOOT_CUFF_Z + shift),
        },
        {   # waist belt; the half width sits between the torso and the A-posed arms
            "planes": [(Vector((0.0, 0.0, BELT_Z[0] + shift)), up),
                       (Vector((0.0, 0.0, BELT_Z[1] + shift)), up)],
            "limit": _slab(0.55 + shift, 0.80 + shift, BELT_HALF_WIDTH),
            "inside": _slab(BELT_Z[0] + shift, BELT_Z[1] + shift, BELT_HALF_WIDTH),
        },
    ]
    for side in (1.0, -1.0):
        wrist = Vector((WRIST.x * side, WRIST.y, WRIST.z + shift))
        elbow = Vector((ELBOW.x * side, ELBOW.y, ELBOW.z + shift))
        axis = (wrist - elbow).normalized()
        regions.append({
            "planes": [(wrist, axis)],
            "limit": _sphere(wrist, MITTEN_REACH),
            "inside": _cap(wrist, MITTEN_REACH, axis),
        })
    return regions


def cut_accent_loops(obj, shift):
    """Slice real edge loops where the accent panels start.

    Without this the panel borders would zig-zag across the isotropic remesh
    grid; cutting first gives dead-straight seams.
    """
    bm = bmesh.new()
    bm.from_mesh(obj.data)

    for region in accent_regions(shift):
        limit = region["limit"]
        for point, normal in region["planes"]:
            faces = [face for face in bm.faces if limit(face.calc_center_median())]
            if not faces:
                continue
            verts = set()
            edges = set()
            for face in faces:
                verts.update(face.verts)
                edges.update(face.edges)
            bmesh.ops.bisect_plane(
                bm,
                geom=list(verts) + list(edges) + faces,
                plane_co=point,
                plane_no=normal,
                clear_inner=False,
                clear_outer=False,
            )

    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def assign_materials(obj, shift):
    suit = make_material("CharacterSuit", SUIT_COLOR, 0.62)
    accent = make_material("CharacterAccent", ACCENT_COLOR, 0.45)
    obj.data.materials.append(suit)
    obj.data.materials.append(accent)

    tests = [region["inside"] for region in accent_regions(shift)]
    for polygon in obj.data.polygons:
        centre = polygon.center
        polygon.material_index = 1 if any(test(centre) for test in tests) else 0


# --------------------------------------------------------------------------
# Rig
# --------------------------------------------------------------------------

def bone_table(shift):
    table = list(BONES)
    for prefix, side in (("Left", -1.0), ("Right", 1.0)):
        for name, parent, head, tail, connected in ARM_BONES + LEG_BONES:
            table.append((
                name.format(prefix),
                parent.format(prefix),
                (head[0] * side, head[1], head[2]),
                (tail[0] * side, tail[1], tail[2]),
                connected,
            ))
    return [(name, parent,
             Vector((head[0], head[1], head[2] + shift)),
             Vector((tail[0], tail[1], tail[2] + shift)),
             connected)
            for name, parent, head, tail, connected in table]


def build_armature(shift):
    armature_data = bpy.data.armatures.new("CharacterSkeleton")
    rig = bpy.data.objects.new("CharacterRig", armature_data)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")

    edit_bones = armature_data.edit_bones
    for name, parent, head, tail, connected in bone_table(shift):
        bone = edit_bones.new(name)
        bone.head = head
        bone.tail = tail
        if parent is not None:
            bone.parent = edit_bones[parent]
            bone.use_connect = connected

    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")

    # The root is a transport handle only, so it must not pull on the skin.
    armature_data.bones["Root"].use_deform = False
    return rig


def bind(mesh_obj, rig):
    bpy.ops.object.select_all(action="DESELECT")
    mesh_obj.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")

    activate(mesh_obj)
    # Relaxing the heat-map weights removes the hard falloff bands the solver
    # leaves around the shoulders and hips.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    try:
        bpy.ops.object.vertex_group_smooth(group_select_mode="ALL", factor=0.5, repeat=4)
    except RuntimeError as error:
        print("Weight smoothing skipped: {0}".format(error))
    bpy.ops.object.mode_set(mode="OBJECT")

    bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=4)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode="ALL", lock_active=False)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def report(obj):
    xs = [vert.co.x for vert in obj.data.vertices]
    ys = [vert.co.y for vert in obj.data.vertices]
    zs = [vert.co.z for vert in obj.data.vertices]
    print("---- character report ----")
    print("faces: {0}  verts: {1}".format(len(obj.data.polygons), len(obj.data.vertices)))
    print("height: {0:.3f} m".format(max(zs) - min(zs)))
    print("width:  {0:.3f} m".format(max(xs) - min(xs)))
    print("depth:  {0:.3f} m".format(max(ys) - min(ys)))
    print("floor:  {0:.4f} m".format(min(zs)))
    print("--------------------------")


def save_and_export(rig, mesh_obj):
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)

    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    mesh_obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_skins=True,
        export_animations=False,
        export_yup=True,
    )
    print("wrote {0}".format(BLEND_PATH))
    print("wrote {0}".format(GLB_PATH))


def main():
    clear_scene()
    bpy.context.scene.unit_settings.system = "METRIC"

    mesh_obj = build_raw_mesh()
    fuse_and_smooth(mesh_obj)
    shift = drop_to_floor(mesh_obj)
    cut_accent_loops(mesh_obj, shift)
    unwrap(mesh_obj)
    assign_materials(mesh_obj, shift)
    activate(mesh_obj)
    bpy.ops.object.shade_smooth()

    rig = build_armature(shift)
    bind(mesh_obj, rig)

    report(mesh_obj)
    save_and_export(rig, mesh_obj)


if __name__ == "__main__":
    main()
