"""Reusable position-delta vertex-animation-texture (VAT) baker.

The baker samples the *evaluated* mesh, so callers may put any fixed-topology
modifier stack in front of it (an Armature modifier is the usual case).  The
mesh at the first requested frame is exported as a static GLB.  Every EXR texel
stores the normalized object-local delta from that first-frame mesh::

    delta = delta_min + texel.rgb * (delta_max - delta_min)

Before encoding, deltas are rotated from Blender's Z-up object space into the
Y-up glTF/Godot mesh space (``x, z, -y``).  The glTF exporter performs that same
conversion on the static mesh; omitting it from the texture makes every bend
play on the wrong axes even though the still mesh looks correct.

The EXR is deliberately not power-of-two padded: its width is exactly the final
Blender vertex count and its height is exactly the number of stored frames.
RGBA is used because Blender's image writer requires a conventional image
layout; alpha is 1 and is not part of the VAT payload.

Stable vertex IDs live in the second UV layer (glTF ``TEXCOORD_1``).  UVs are a
corner/loop attribute in Blender, not a vertex attribute, so the same
``(vertex_id + 0.5) / texture_width`` value is explicitly copied to every loop
that references a vertex.  This survives glTF's vertex duplication at UV seams
and hard normals.  UV2.y is 0.5 and intentionally unused; animation time chooses
the EXR row.

Loop convention
---------------
For a seamless N-frame loop, sample frames ``0 .. N-1`` and author frame ``N``
as a duplicate of frame 0.  Pass ``loop_endpoint=N``: the baker verifies that
the endpoint matches but does not store the duplicate row.  Runtime playback
then interpolates from the last stored row to row zero exactly as the source
interpolates from frame N-1 to the duplicate endpoint.

This module has no project-specific asset knowledge.  See ``build_vat_assets``
for the fish, flower, and grass recipes.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import os
import struct
from typing import Iterable, Sequence

import bpy
from mathutils import Matrix, Vector


VAT_VERSION = 1
UV_ID_LAYER = "VAT_ID"
_JSON_CHUNK = 0x4E4F534A
_BIN_CHUNK = 0x004E4942
_COMPONENT_FORMATS = {
    5120: "b",   # BYTE
    5121: "B",   # UNSIGNED_BYTE
    5122: "h",   # SHORT
    5123: "H",   # UNSIGNED_SHORT
    5125: "I",   # UNSIGNED_INT
    5126: "f",   # FLOAT
}
_TYPE_COMPONENTS = {
    "SCALAR": 1,
    "VEC2": 2,
    "VEC3": 3,
    "VEC4": 4,
    "MAT2": 4,
    "MAT3": 9,
    "MAT4": 16,
}


@dataclass(frozen=True)
class VATBakeResult:
    """Paths and final-topology statistics returned by :func:`bake`."""

    glb_path: str
    exr_path: str
    json_path: str
    vertex_count: int
    triangle_count: int
    frame_count: int
    glb_vertex_count: int
    loop_endpoint_error: float


def triangle_count(mesh: bpy.types.Mesh) -> int:
    """Return the number of triangles represented by all mesh polygons."""

    return sum(max(0, len(polygon.vertices) - 2) for polygon in mesh.polygons)


def _topology(mesh: bpy.types.Mesh) -> tuple[int, tuple[tuple[int, ...], ...]]:
    """A strict topology signature; vertex order is part of the VAT contract."""

    return len(mesh.vertices), tuple(tuple(polygon.vertices) for polygon in mesh.polygons)


def _topology_hash(topology: tuple[int, tuple[tuple[int, ...], ...]]) -> str:
    digest = hashlib.sha256()
    digest.update(struct.pack("<I", topology[0]))
    for polygon in topology[1]:
        digest.update(struct.pack("<I", len(polygon)))
        digest.update(struct.pack("<{}I".format(len(polygon)), *polygon))
    return digest.hexdigest()


def blender_to_godot(vector: Vector) -> Vector:
    """Match Blender's glTF ``export_yup`` conversion for a mesh-space vector."""

    return Vector((vector.x, vector.z, -vector.y))


def _evaluated_snapshot(
    source: bpy.types.Object,
    frame: int,
    *,
    copy_mesh_name: str | None = None,
) -> tuple[
    list[Vector],
    tuple[int, tuple[tuple[int, ...], ...]],
    bpy.types.Mesh | None,
    Matrix,
]:
    """Sample one frame and optionally retain a permanent copy of its mesh."""

    scene = bpy.context.scene
    scene.frame_set(frame)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    depsgraph.update()
    evaluated = source.evaluated_get(depsgraph)
    evaluated_mesh = evaluated.to_mesh(
        preserve_all_data_layers=True,
        depsgraph=depsgraph,
    )
    if evaluated_mesh is None:
        raise RuntimeError("could not evaluate mesh {!r} at frame {}".format(source.name, frame))

    positions = [vertex.co.copy() for vertex in evaluated_mesh.vertices]
    topology = _topology(evaluated_mesh)
    retained = evaluated_mesh.copy() if copy_mesh_name is not None else None
    if retained is not None:
        retained.name = copy_mesh_name
    matrix_world = evaluated.matrix_world.copy()
    evaluated.to_mesh_clear()
    return positions, topology, retained, matrix_world


def _fallback_uv0(mesh: bpy.types.Mesh) -> bpy.types.MeshUVLoopLayer:
    """Create a deterministic planar UV0 when a source mesh has no UVs."""

    layer = mesh.uv_layers.new(name="UVMap")
    if not mesh.vertices:
        return layer
    low_x = min(vertex.co.x for vertex in mesh.vertices)
    high_x = max(vertex.co.x for vertex in mesh.vertices)
    low_y = min(vertex.co.y for vertex in mesh.vertices)
    high_y = max(vertex.co.y for vertex in mesh.vertices)
    span_x = max(high_x - low_x, 1.0e-12)
    span_y = max(high_y - low_y, 1.0e-12)
    for loop in mesh.loops:
        co = mesh.vertices[loop.vertex_index].co
        layer.data[loop.index].uv = ((co.x - low_x) / span_x, (co.y - low_y) / span_y)
    return layer


def assign_vertex_ids_to_uv2(
    mesh: bpy.types.Mesh,
    *,
    layer_name: str = UV_ID_LAYER,
) -> bpy.types.MeshUVLoopLayer:
    """Put stable source-vertex IDs in the second UV layer's x component.

    Only UV0 is preserved because the VAT ID must be exactly the second glTF UV
    set, not merely another arbitrarily numbered UV attribute.
    """

    for layer in list(mesh.uv_layers):
        if layer.name == layer_name:
            mesh.uv_layers.remove(layer)
    while len(mesh.uv_layers) > 1:
        mesh.uv_layers.remove(mesh.uv_layers[-1])
    if not mesh.uv_layers:
        _fallback_uv0(mesh)

    vat_layer = mesh.uv_layers.new(name=layer_name)
    width = len(mesh.vertices)
    if width <= 0:
        raise ValueError("VAT meshes must contain at least one vertex")
    for loop in mesh.loops:
        vertex_id = loop.vertex_index
        vat_layer.data[loop.index].uv = ((vertex_id + 0.5) / width, 0.5)

    # Keep the authored/fallback map as UV0.  The list order, rather than which
    # layer happens to be active in Blender's UI, determines TEXCOORD_0/1.
    mesh.uv_layers.active_index = 0
    mesh.update()
    return vat_layer


def _set_active_vertex_color(mesh: bpy.types.Mesh, preferred: str | None) -> str:
    if not mesh.color_attributes:
        raise ValueError(
            "evaluated mesh {!r} has no vertex colors; VAT assets require COLOR_0".format(
                mesh.name
            )
        )
    attribute = mesh.color_attributes.get(preferred) if preferred else None
    if attribute is None:
        attribute = mesh.color_attributes[0]
    mesh.color_attributes.active_color_name = attribute.name
    for index, candidate in enumerate(mesh.color_attributes):
        if candidate.name == attribute.name:
            mesh.color_attributes.render_color_index = index
            break
    return attribute.name


def _write_exr(
    path: str,
    deltas: Sequence[Sequence[Vector]],
    delta_min: Sequence[float],
    delta_max: Sequence[float],
) -> None:
    height = len(deltas)
    width = len(deltas[0])
    axis_ranges = [delta_max[axis] - delta_min[axis] for axis in range(3)]
    pixels = [0.0] * (width * height * 4)
    for row, frame_deltas in enumerate(deltas):
        if len(frame_deltas) != width:
            raise ValueError("inconsistent VAT row width")
        for column, delta in enumerate(frame_deltas):
            offset = (row * width + column) * 4
            for axis in range(3):
                span = axis_ranges[axis]
                value = 0.0 if abs(span) < 1.0e-20 else (
                    (delta[axis] - delta_min[axis]) / span
                )
                pixels[offset + axis] = min(1.0, max(0.0, value))
            pixels[offset + 3] = 1.0

    image = bpy.data.images.new(
        name="VAT_{}".format(os.path.basename(path)),
        width=width,
        height=height,
        alpha=True,
        float_buffer=True,
        is_data=True,
    )
    try:
        image.colorspace_settings.name = "Non-Color"
    except TypeError:
        # Some Blender builds call the same data color space "Non-Colour Data".
        image.colorspace_settings.name = "Non-Colour Data"
    image.pixels.foreach_set(pixels)
    image.update()
    image.filepath_raw = path
    image.file_format = "OPEN_EXR"

    settings = bpy.context.scene.render.image_settings
    old_settings = (
        settings.file_format,
        settings.color_mode,
        settings.color_depth,
        settings.exr_codec,
    )
    try:
        settings.file_format = "OPEN_EXR"
        settings.color_mode = "RGBA"
        settings.color_depth = "32"
        settings.exr_codec = "ZIP"
        image.save()
    finally:
        (
            settings.file_format,
            settings.color_mode,
            settings.color_depth,
            settings.exr_codec,
        ) = old_settings
        bpy.data.images.remove(image)


def _select_only(obj: bpy.types.Object) -> None:
    view_layer = bpy.context.view_layer
    for candidate in view_layer.objects:
        candidate.select_set(False)
    obj.hide_viewport = False
    obj.hide_render = False
    obj.select_set(True)
    view_layer.objects.active = obj


def _export_static_glb(obj: bpy.types.Object, path: str) -> None:
    """Export one plain mesh: no source rig, skin, shape keys, or animation."""

    _select_only(obj)
    settings = dict(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=False,
        export_skins=False,
        export_animations=False,
        export_texcoords=True,
        export_normals=True,
        export_yup=True,
    )
    try:
        # ACTIVE exports MeshMaker's color attribute even if its material graph
        # does not happen to reference the attribute.
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **settings)
    except TypeError:
        # Kept for reuse with older compatible Blender releases.  Validation
        # below still fails loudly if such an exporter omits COLOR_0.
        bpy.ops.export_scene.gltf(**settings)


def _write_json(path: str, metadata: dict) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        json.dump(metadata, stream, indent=2, sort_keys=False)
        stream.write("\n")


def _read_glb(path: str) -> tuple[dict, bytes]:
    with open(path, "rb") as stream:
        payload = stream.read()
    if len(payload) < 12:
        raise ValueError("{} is too short to be a GLB".format(path))
    magic, version, declared_length = struct.unpack_from("<4sII", payload, 0)
    if magic != b"glTF" or version != 2 or declared_length != len(payload):
        raise ValueError("{} has an invalid GLB header".format(path))

    document = None
    binary = b""
    offset = 12
    while offset < len(payload):
        chunk_length, chunk_type = struct.unpack_from("<II", payload, offset)
        offset += 8
        chunk = payload[offset:offset + chunk_length]
        offset += chunk_length
        if chunk_type == _JSON_CHUNK:
            document = json.loads(chunk.decode("utf-8").rstrip(" \t\r\n\0"))
        elif chunk_type == _BIN_CHUNK:
            binary = chunk
    if document is None:
        raise ValueError("{} has no JSON chunk".format(path))
    return document, binary


def _accessor_values(document: dict, binary: bytes, accessor_index: int) -> list[tuple]:
    accessor = document["accessors"][accessor_index]
    if "sparse" in accessor:
        raise ValueError("sparse glTF accessors are not supported by VAT validation")
    view = document["bufferViews"][accessor["bufferView"]]
    component_type = accessor["componentType"]
    component_format = _COMPONENT_FORMATS[component_type]
    components = _TYPE_COMPONENTS[accessor["type"]]
    element_size = struct.calcsize("<" + component_format * components)
    stride = view.get("byteStride", element_size)
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    unpack_format = "<" + component_format * components
    return [
        struct.unpack_from(unpack_format, binary, base + index * stride)
        for index in range(accessor["count"])
    ]


def validate_outputs(
    glb_path: str,
    exr_path: str,
    json_path: str,
    *,
    expected_node_name: str,
) -> dict:
    """Validate dimensions and the runtime-facing GLB attribute contract."""

    with open(json_path, "r", encoding="utf-8") as stream:
        metadata = json.load(stream)
    width = int(metadata["width"])
    height = int(metadata["height"])
    if width != int(metadata["vertex_count"]):
        raise ValueError("VAT width must equal the final Blender vertex count")
    if height != int(metadata["frame_count"]):
        raise ValueError("VAT height must equal the stored frame count")

    image = bpy.data.images.load(exr_path, check_existing=False)
    try:
        if tuple(image.size) != (width, height):
            raise ValueError(
                "EXR is {}x{}, metadata says {}x{}".format(
                    image.size[0], image.size[1], width, height
                )
            )
        pixels = list(image.pixels)
        payload = [
            pixels[offset + axis]
            for offset in range(0, len(pixels), 4)
            for axis in range(3)
        ]
        if not all(math.isfinite(value) and -1.0e-6 <= value <= 1.000001
                   for value in payload):
            raise ValueError("EXR contains a non-finite or unnormalized RGB value")
        expected_zero = [
            0.0 if abs(metadata["delta_max"][axis] - metadata["delta_min"][axis]) < 1.0e-20
            else -metadata["delta_min"][axis] / (
                metadata["delta_max"][axis] - metadata["delta_min"][axis]
            )
            for axis in range(3)
        ]
        first_texel = pixels[0:3]
        if any(abs(first_texel[axis] - expected_zero[axis]) > 2.0e-6
               for axis in range(3)):
            raise ValueError("EXR row zero does not decode to the static base frame")
    finally:
        bpy.data.images.remove(image)

    document, binary = _read_glb(glb_path)
    if document.get("skins"):
        raise ValueError("static VAT GLB unexpectedly contains a skin")
    if document.get("animations"):
        raise ValueError("static VAT GLB unexpectedly contains animation")
    if any("skin" in node for node in document.get("nodes", [])):
        raise ValueError("static VAT GLB contains a skinned node")

    mesh_nodes = [
        node for node in document.get("nodes", [])
        if "mesh" in node
    ]
    if len(mesh_nodes) != 1 or mesh_nodes[0].get("name") != expected_node_name:
        raise ValueError(
            "expected one deterministic mesh node {!r}, got {}".format(
                expected_node_name,
                [node.get("name") for node in mesh_nodes],
            )
        )

    primitives = [
        primitive
        for mesh in document.get("meshes", [])
        for primitive in mesh.get("primitives", [])
    ]
    if not primitives:
        raise ValueError("VAT GLB has no mesh primitives")

    glb_vertices = 0
    glb_triangles = 0
    seen_ids: set[int] = set()
    for primitive in primitives:
        if primitive.get("mode", 4) != 4:
            raise ValueError("VAT GLB contains a non-triangle primitive")
        attributes = primitive.get("attributes", {})
        missing = {"POSITION", "TEXCOORD_1", "COLOR_0"} - set(attributes)
        if missing:
            raise ValueError("VAT GLB primitive is missing {}".format(sorted(missing)))

        position_accessor = document["accessors"][attributes["POSITION"]]
        glb_vertices += int(position_accessor["count"])
        if "indices" in primitive:
            glb_triangles += int(document["accessors"][primitive["indices"]]["count"]) // 3
        else:
            glb_triangles += int(position_accessor["count"]) // 3

        for uv in _accessor_values(document, binary, attributes["TEXCOORD_1"]):
            raw_id = uv[0] * width - 0.5
            vertex_id = int(round(raw_id))
            if vertex_id < 0 or vertex_id >= width or abs(raw_id - vertex_id) > 2.0e-4:
                raise ValueError("UV2.x contains an invalid VAT vertex ID: {}".format(uv[0]))
            seen_ids.add(vertex_id)

    expected_ids = set(range(width))
    if seen_ids != expected_ids:
        missing_count = len(expected_ids - seen_ids)
        raise ValueError("VAT GLB lost {} source vertex IDs during export".format(missing_count))
    if glb_triangles != int(metadata["triangle_count"]):
        raise ValueError(
            "GLB has {} triangles, metadata says {}".format(
                glb_triangles, metadata["triangle_count"]
            )
        )
    return {
        "glb_vertex_count": glb_vertices,
        "glb_triangle_count": glb_triangles,
        "mesh_primitive_count": len(primitives),
    }


def bake(
    source: bpy.types.Object,
    frames: Iterable[int],
    *,
    fps: float,
    output_base: str,
    node_name: str,
    mesh_name: str | None = None,
    vertex_color_name: str | None = "Color",
    loop: bool = True,
    loop_endpoint: int | None = None,
    loop_tolerance: float = 1.0e-4,
) -> VATBakeResult:
    """Bake ``source`` into ``output_base`` plus .glb/.exr/.json.

    ``source`` must already have its final topology.  Deformation-only
    modifiers may remain.  Frames must be contiguous integers because each one
    maps directly to an EXR row.
    """

    if source.type != "MESH":
        raise TypeError("VAT source must be a mesh object")
    frame_list = [int(frame) for frame in frames]
    if not frame_list:
        raise ValueError("at least one VAT frame is required")
    if frame_list != list(range(frame_list[0], frame_list[0] + len(frame_list))):
        raise ValueError("VAT frames must be contiguous ascending integers")
    if loop_endpoint is not None and loop_endpoint in frame_list:
        raise ValueError("the duplicate loop endpoint must not be stored in the VAT")

    output_base = os.path.abspath(output_base)
    os.makedirs(os.path.dirname(output_base), exist_ok=True)
    glb_path = output_base + ".glb"
    exr_path = output_base + ".exr"
    json_path = output_base + ".json"
    static_mesh_name = mesh_name or node_name + "Mesh"

    sampled_positions: list[list[Vector]] = []
    stable_topology = None
    static_mesh = None
    static_matrix = Matrix.Identity(4)
    for row, frame in enumerate(frame_list):
        positions, topology, retained, matrix_world = _evaluated_snapshot(
            source,
            frame,
            copy_mesh_name=static_mesh_name if row == 0 else None,
        )
        if stable_topology is None:
            stable_topology = topology
            static_mesh = retained
            static_matrix = matrix_world
        elif topology != stable_topology:
            raise ValueError(
                "topology changed at frame {}; VAT requires stable vertex and polygon order".format(
                    frame
                )
            )
        sampled_positions.append(positions)

    assert stable_topology is not None
    assert static_mesh is not None
    base_positions = sampled_positions[0]
    endpoint_error = 0.0
    if loop_endpoint is not None:
        endpoint_positions, endpoint_topology, _unused_mesh, _unused_matrix = (
            _evaluated_snapshot(source, int(loop_endpoint))
        )
        if endpoint_topology != stable_topology:
            raise ValueError("topology changed at duplicate loop endpoint")
        endpoint_error = max(
            ((endpoint - first).length for endpoint, first in zip(
                endpoint_positions, base_positions
            )),
            default=0.0,
        )
        if endpoint_error > loop_tolerance:
            raise ValueError(
                "loop endpoint differs from the first frame by {:.8f} m (limit {:.8f})".format(
                    endpoint_error, loop_tolerance
                )
            )

    deltas: list[list[Vector]] = []
    delta_min = [math.inf, math.inf, math.inf]
    delta_max = [-math.inf, -math.inf, -math.inf]
    for positions in sampled_positions:
        frame_deltas = []
        for position, base in zip(positions, base_positions):
            delta = blender_to_godot(position - base)
            frame_deltas.append(delta)
            for axis in range(3):
                delta_min[axis] = min(delta_min[axis], delta[axis])
                delta_max[axis] = max(delta_max[axis], delta[axis])
        deltas.append(frame_deltas)

    color_name = _set_active_vertex_color(static_mesh, vertex_color_name)
    assign_vertex_ids_to_uv2(static_mesh)
    static_object = bpy.data.objects.new(node_name, static_mesh)
    bpy.context.scene.collection.objects.link(static_object)
    static_object.matrix_world = static_matrix

    # A newly constructed object around an evaluated mesh has no parent,
    # modifiers, vertex groups, shape keys, or animation data.  Exporting only
    # this object is what strips the authoring rig from the runtime asset.
    _write_exr(exr_path, deltas, delta_min, delta_max)
    _export_static_glb(static_object, glb_path)

    vertex_count = len(static_mesh.vertices)
    triangles = triangle_count(static_mesh)
    frame_count = len(frame_list)
    runtime_base_positions = [blender_to_godot(position) for position in base_positions]
    bounds_min = [
        min(position[axis] for position in runtime_base_positions)
        for axis in range(3)
    ]
    bounds_max = [
        max(position[axis] for position in runtime_base_positions)
        for axis in range(3)
    ]
    metadata = {
        "format": "normalized_position_delta_vat",
        "version": VAT_VERSION,
        "mesh_node": node_name,
        "mesh_data": static_mesh_name,
        "vertex_color": color_name,
        "coordinate_space": "godot_y_up_object_local",
        "axis_conversion": "Blender (x, y, z) -> Godot/glTF (x, z, -y)",
        "vertex_count": vertex_count,
        "triangle_count": triangles,
        "frame_count": frame_count,
        "frame_start": frame_list[0],
        "frame_end": frame_list[-1],
        "fps": float(fps),
        "width": vertex_count,
        "height": frame_count,
        "delta_min": [float(value) for value in delta_min],
        "delta_max": [float(value) for value in delta_max],
        "delta_range": [
            float(delta_max[axis] - delta_min[axis])
            for axis in range(3)
        ],
        "bounds_min": [float(value) for value in bounds_min],
        "bounds_max": [float(value) for value in bounds_max],
        "topology_sha256": _topology_hash(stable_topology),
        "texture": {
            "file": os.path.basename(exr_path),
            "format": "OpenEXR",
            "channels": "RGBA32F",
            "payload_channels": "RGB",
            "normalization": "delta = delta_min + texel.rgb * (delta_max - delta_min)",
            "row_zero": "frame_start at V=(0.5/height)",
            "padding_vertices": 0,
            "padding_frames": 0,
        },
        "uv2": {
            "layer": UV_ID_LAYER,
            "gltf_attribute": "TEXCOORD_1",
            "x": "(vertex_id + 0.5) / width",
            "y": 0.5,
            "domain": "CORNER (same x copied to every loop of each vertex)",
        },
        "animation": {
            "frames": frame_list,
            "loop": bool(loop),
            "loop_endpoint": int(loop_endpoint) if loop_endpoint is not None else None,
            "loop_endpoint_stored": False if loop_endpoint is not None else None,
            "loop_endpoint_max_error": float(endpoint_error),
            "loop_note": (
                "The duplicate endpoint matches frame_start and is omitted; "
                "after frame_end, interpolate/wrap to texture row zero."
                if loop and loop_endpoint is not None
                else "After frame_end, wrap to texture row zero." if loop else "Play once."
            ),
        },
        "files": {
            "mesh": os.path.basename(glb_path),
            "texture": os.path.basename(exr_path),
            "metadata": os.path.basename(json_path),
        },
    }
    _write_json(json_path, metadata)

    validation = validate_outputs(
        glb_path,
        exr_path,
        json_path,
        expected_node_name=node_name,
    )
    metadata["glb_vertex_count"] = validation["glb_vertex_count"]
    metadata["glb_triangle_count"] = validation["glb_triangle_count"]
    _write_json(json_path, metadata)

    print(
        "VAT wrote {}: {} source vertices, {} GLB vertices, {} triangles, {} frames".format(
            os.path.basename(output_base),
            vertex_count,
            validation["glb_vertex_count"],
            triangles,
            frame_count,
        )
    )
    return VATBakeResult(
        glb_path=glb_path,
        exr_path=exr_path,
        json_path=json_path,
        vertex_count=vertex_count,
        triangle_count=triangles,
        frame_count=frame_count,
        glb_vertex_count=validation["glb_vertex_count"],
        loop_endpoint_error=endpoint_error,
    )
