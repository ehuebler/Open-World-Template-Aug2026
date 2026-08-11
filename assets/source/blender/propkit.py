"""Shared bmesh primitives for the procedural props.

Imported by build_wardrobe.py and build_weapons.py. Blender runs scripts with
`--python`, which does not put the script's folder on sys.path, so importers need:

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

Everything here builds into a caller-owned bmesh in **world coordinates** and
tags the new faces with a material slot index, so a prop is assembled by stacking
primitives and then handed to `new_object()` once. Shapes are expected to be
closed shells; `new_object()` recalculates normals across the whole mesh, which
is what lets `add_loft()` ignore ring winding.
"""

import math

import bmesh
import bpy
from mathutils import Matrix, Vector


# --------------------------------------------------------------------------
# Solids
# --------------------------------------------------------------------------

def add_box(bm, lo, hi, slot):
    """Axis-aligned box spanning lo..hi. Returns its faces."""
    lo, hi = Vector(lo), Vector(hi)
    matrix = Matrix.Translation((lo + hi) * 0.5) @ Matrix.Diagonal((hi - lo).to_4d())
    result = bmesh.ops.create_cube(bm, size=1.0, matrix=matrix, calc_uvs=True)
    faces = {face for vert in result["verts"] for face in vert.link_faces}
    for face in faces:
        face.material_index = slot
    return faces


def add_cone(bm, start, end, radius_start, radius_end, slot, segments=20):
    """Tapered cylinder from start to end. Equal radii give a plain cylinder."""
    start, end = Vector(start), Vector(end)
    axis = end - start
    matrix = (Matrix.Translation((start + end) * 0.5)
              @ axis.to_track_quat("Z", "Y").to_matrix().to_4x4())
    result = bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        cap_tris=False,
        segments=segments,
        radius1=radius_start,
        radius2=radius_end,
        depth=axis.length,
        matrix=matrix,
        calc_uvs=True,
    )
    faces = {face for vert in result["verts"] for face in vert.link_faces}
    for face in faces:
        face.material_index = slot
    return faces


def add_cylinder(bm, start, end, radius, slot, segments=20):
    return add_cone(bm, start, end, radius, radius, slot, segments)


def add_sphere(bm, centre, radius, slot, segments=20, scale=(1.0, 1.0, 1.0)):
    matrix = Matrix.Translation(Vector(centre)) @ Matrix.Diagonal(Vector(scale).to_4d())
    result = bmesh.ops.create_uvsphere(
        bm,
        u_segments=segments,
        v_segments=max(4, segments // 2),
        radius=radius,
        matrix=matrix,
        calc_uvs=True,
    )
    faces = {face for vert in result["verts"] for face in vert.link_faces}
    for face in faces:
        face.material_index = slot
    return faces


# --------------------------------------------------------------------------
# Lofting, for the shapes a box or cylinder cannot describe: tapered sword
# blades, waisted grips, swept crossguards.
# --------------------------------------------------------------------------

def circle_profile(segments):
    """Unit circle as (u, v) pairs, to be scaled by a ring's right/up vectors."""
    step = math.tau / segments
    return [(math.cos(i * step), math.sin(i * step)) for i in range(segments)]


def squircle_profile(segments, power=3.2):
    """Superellipse as (u, v) pairs. power=2 is a circle, higher is squarer.

    Soft-sided things like a pack read better as a rounded rectangle than as
    either a box or a cylinder.
    """
    exponent = 2.0 / power
    step = math.tau / segments
    points = []
    for i in range(segments):
        angle = i * step
        cosine, sine = math.cos(angle), math.sin(angle)
        points.append((math.copysign(abs(cosine) ** exponent, cosine),
                       math.copysign(abs(sine) ** exponent, sine)))
    return points


def catmull_rom(points, count):
    """Resample a polyline to `count` points through a Catmull-Rom spline, so a
    strap laid out with a handful of control points comes out smooth."""
    points = [Vector(point) for point in points]
    padded = ([points[0] + (points[0] - points[1])] + points
              + [points[-1] + (points[-1] - points[-2])])
    spans = len(points) - 1
    sampled = []
    for i in range(count):
        position = i / (count - 1) * spans
        span = min(int(position), spans - 1)
        f = position - span
        p0, p1, p2, p3 = padded[span:span + 4]
        sampled.append(0.5 * ((2.0 * p1)
                              + (-p0 + p2) * f
                              + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
                              + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f * f * f))
    return sampled


def ring(centre, right, up, profile):
    """Place a 2D profile in 3D. `right`/`up` carry both direction and radius."""
    centre, right, up = Vector(centre), Vector(right), Vector(up)
    return [centre + right * u + up * v for u, v in profile]


def add_loft(bm, rings, slot, cap_start=True, cap_end=True):
    """Bridge a sequence of equal-length rings into a tube.

    Winding does not matter; new_object() recalculates normals. A ring may be
    collapsed to a single repeated point to bring the tube to a tip.
    """
    vert_rings = [[bm.verts.new(point) for point in points] for points in rings]
    faces = []
    for lower, upper in zip(vert_rings, vert_rings[1:]):
        count = len(lower)
        for i in range(count):
            j = (i + 1) % count
            corners = [lower[i], lower[j], upper[j], upper[i]]
            unique = []
            for vert in corners:
                if vert not in unique:
                    unique.append(vert)
            if len(unique) >= 3:
                faces.append(bm.faces.new(unique))
    if cap_start:
        faces.append(bm.faces.new(vert_rings[0]))
    if cap_end:
        faces.append(bm.faces.new(vert_rings[-1]))
    for face in faces:
        face.material_index = slot
    return faces


def add_path_loft(bm, centres, sections, slot, wide_hint=(1.0, 0.0, 0.0),
                  segments=12, profile=None, cap_start=True, cap_end=True):
    """Loft a tube along an arbitrary path.

    `sections` gives (half_wide, half_thick) per centre. `wide_hint` only seeds the
    first cross-section; each one after is carried along the path by projecting the
    previous frame onto the new normal plane. Re-deriving the frame from a fixed
    hint at every sample instead makes a flat strap twist wherever the path turns
    towards that hint, because the projection collapses as the two align.
    """
    centres = [Vector(centre) for centre in centres]
    shape = profile if profile is not None else circle_profile(segments)
    rings = []
    carried = Vector(wide_hint)
    for i, centre in enumerate(centres):
        if i == 0:
            tangent = centres[1] - centres[0]
        elif i == len(centres) - 1:
            tangent = centres[-1] - centres[-2]
        else:
            tangent = centres[i + 1] - centres[i - 1]
        tangent.normalize()
        wide = carried - tangent * carried.dot(tangent)
        if wide.length < 1e-5:
            fallback = Vector((0.0, 0.0, 1.0)) if abs(tangent.z) < 0.9 else Vector((1.0, 0.0, 0.0))
            wide = fallback - tangent * fallback.dot(tangent)
        wide.normalize()
        carried = wide
        thin = tangent.cross(wide).normalized()
        half_wide, half_thick = sections[i]
        rings.append(ring(centre, wide * half_wide, thin * half_thick, shape))
    return add_loft(bm, rings, slot, cap_start=cap_start, cap_end=cap_end)


def taper_loft(bm, sections, axis, right, up, slot, centre=(0.0, 0.0, 0.0),
               segments=20, cap_start=True, cap_end=True, profile=None):
    """Loft a tube along `axis` from (distance, right_radius, up_radius) sections.

    `right` and `up` are unit vectors spanning the cross-section, `axis` is the
    unit direction the sections measure along, and `centre` is the point distance
    zero sits at.
    """
    axis, right, up = Vector(axis), Vector(right), Vector(up)
    shape = profile if profile is not None else circle_profile(segments)
    rings = [ring(Vector(centre) + axis * distance,
                  right * r_radius, up * u_radius, shape)
             for distance, r_radius, u_radius in sections]
    return add_loft(bm, rings, slot, cap_start=cap_start, cap_end=cap_end)


# --------------------------------------------------------------------------
# Shading and object creation
# --------------------------------------------------------------------------

def shade_by_angle(bm, threshold):
    """Smooth everything, then mark creases sharp, so turned parts stay round
    while flat joinery keeps its edges."""
    limit = math.radians(threshold)
    for face in bm.faces:
        face.smooth = True
    for edge in bm.edges:
        edge.smooth = len(edge.link_faces) == 2 and edge.calc_face_angle() <= limit


def ensure_materials(spec):
    """spec maps name -> dict with colour, roughness, metallic, and optional
    emission (colour, strength) and alpha. Returns the names in declaration order,
    which is also the material slot order."""
    for name, values in spec.items():
        material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
        material.use_nodes = True
        bsdf = material.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = values["colour"]
        bsdf.inputs["Roughness"].default_value = values.get("roughness", 0.5)
        bsdf.inputs["Metallic"].default_value = values.get("metallic", 0.0)
        alpha = values.get("alpha", 1.0)
        bsdf.inputs["Alpha"].default_value = alpha
        if alpha < 1.0:
            # The glTF exporter reads the Alpha socket for the value but takes the
            # alphaMode from the render method, so both have to be set or the
            # material exports as fully opaque. Renamed in Blender 4.2, when EEVEE
            # Next replaced blend_method.
            if hasattr(material, "surface_render_method"):
                material.surface_render_method = "BLENDED"
            elif hasattr(material, "blend_method"):
                material.blend_method = "BLEND"
        emission = values.get("emission")
        if emission is not None:
            colour, strength = emission
            # Renamed in Blender 4.0; accept either.
            for key in ("Emission Color", "Emission"):
                if key in bsdf.inputs:
                    bsdf.inputs[key].default_value = colour
                    break
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = strength
    return list(spec)


def new_object(name, bm, slots, bevel_width=0.0, bevel_segments=2,
               bevel_angle=30.0, smooth_angle=32.0, origin=None,
               flip_normals=False):
    """Turn a finished bmesh into a scene object.

    `origin` moves the object origin to that world point while leaving the
    geometry where it is, which is how grips and hinges become pivots.

    `flip_normals` turns the shell inside out after normals have been recalculated,
    which is what a room needs: the geometry is authored as a solid volume, but it
    is seen from within, and backface culling would otherwise hide all of it.
    """
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    if flip_normals:
        bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    shade_by_angle(bm, smooth_angle)
    bm.normal_update()

    mesh = bpy.data.meshes.new(name + "Mesh")
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    for slot in slots:
        mesh.materials.append(bpy.data.materials[slot])

    if bevel_width > 0.0:
        bevel = obj.modifiers.new("Bevel", "BEVEL")
        bevel.width = bevel_width
        bevel.segments = bevel_segments
        bevel.limit_method = "ANGLE"
        bevel.angle_limit = math.radians(bevel_angle)
        bevel.harden_normals = False

    if origin is not None:
        origin = Vector(origin)
        mesh.transform(Matrix.Translation(-origin))
        obj.location = origin
    return obj


# --------------------------------------------------------------------------
# Scene plumbing
# --------------------------------------------------------------------------

def reset_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for mesh in list(bpy.data.meshes):
        bpy.data.meshes.remove(mesh)


def evaluated_polys(obj):
    """Face count after modifiers, which is what actually ships."""
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    count = len(mesh.polygons)
    evaluated.to_mesh_clear()
    return count


def export_selected(objects, filepath, include_lights=False):
    """Export just `objects`, bypassing bpy.ops.object.select_all, whose poll
    fails in background mode.

    `include_lights` writes any selected lights out through KHR_lights_punctual,
    which Godot imports as real light nodes. Emission alone cannot carry a scene
    whose light sources are part of the set dressing.
    """
    view_layer = bpy.context.view_layer
    for obj in view_layer.objects:
        obj.select_set(False)
    for obj in objects:
        obj.hide_viewport = False
        obj.select_set(True)
    view_layer.objects.active = objects[0]
    bpy.ops.export_scene.gltf(
        filepath=filepath,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_animations=False,
        export_yup=True,
        export_lights=include_lights,
    )
    import os
    print("wrote {0} ({1:.1f} KB)".format(filepath, os.path.getsize(filepath) / 1024.0))
