"""Author the two selectable robotic skins for ``player_character_3``.

The concept sheets are elevations of a differently proportioned figure, not UV
maps. Projecting either image onto this mesh would put its chest on the chin from
one angle and lose the back from every other one. The designs are therefore
restated against the settler's measured metres:

* ``clean_robotic`` keeps the warm skin, red/cream/gold armour, cyan chest and
  back cores, navy shorts and charcoal boots.
* ``integrated_robotic`` keeps the violet skin and markings under a
  graphite/silver/red exosuit with cyan chest and spine lights.

The mesh arrives without texture coordinates. ``build`` gives it one packed,
non-overlapping atlas and rasterises the designs from the original 3D position
of every texel, so the front and back meet on the sides and rebuilding the body
rebuilds its textures from the same measurements. The PNGs are game assets; the
code here is their source.
"""

from __future__ import annotations

import binascii
import math
import os
import struct
import zlib

import bpy


SIZE = 1024
UV_NAME = "C3SkinUV"
GUTTER = 7

SKINS = {
    "clean_robotic": "character_3_clean_robotic.png",
    "integrated_robotic": "character_3_integrated_robotic.png",
}

# sRGB authoring colours. The game's character shader supplies the lighting.
SKIN = (0.88, 0.72, 0.66)
HAIR = (0.88, 0.91, 0.94)
RED = (0.63, 0.10, 0.09)
RED_LIGHT = (0.82, 0.20, 0.16)
CREAM = (0.88, 0.79, 0.62)
GOLD = (0.78, 0.55, 0.17)
NAVY = (0.055, 0.085, 0.16)
BOOT = (0.075, 0.085, 0.105)
CYAN = (0.18, 0.82, 0.94)
CYAN_WHITE = (0.62, 0.96, 1.0)
INK = (0.045, 0.05, 0.075)

VIOLET = (0.55, 0.34, 0.68)
VIOLET_LIGHT = (0.70, 0.50, 0.80)
MARK = (0.21, 0.10, 0.31)
GRAPHITE = (0.085, 0.10, 0.14)
GRAPHITE_LIGHT = (0.16, 0.19, 0.24)
SILVER = (0.45, 0.50, 0.56)
SILVER_LIGHT = (0.67, 0.72, 0.76)
GREEN = (0.45, 0.85, 0.55)


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def smoothstep(low: float, high: float, value: float) -> float:
    if high == low:
        return 1.0 if value >= high else 0.0
    t = clamp((value - low) / (high - low))
    return t * t * (3.0 - 2.0 * t)


def band(value: float, low: float, high: float, feather: float = 0.006) -> float:
    return smoothstep(low - feather, low + feather, value) * (
        1.0 - smoothstep(high - feather, high + feather, value)
    )


def mix(a: tuple[float, float, float], b: tuple[float, float, float], amount: float):
    amount = clamp(amount)
    return tuple(a[index] + (b[index] - a[index]) * amount for index in range(3))


def ellipse(x: float, z: float, cx: float, cz: float, rx: float, rz: float,
            feather: float = 0.08) -> float:
    distance = ((x - cx) / rx) ** 2 + ((z - cz) / rz) ** 2
    return 1.0 - smoothstep(1.0 - feather, 1.0 + feather, distance)


def diamond(x: float, z: float, cx: float, cz: float, rx: float, rz: float,
            feather: float = 0.08) -> float:
    distance = abs(x - cx) / rx + abs(z - cz) / rz
    return 1.0 - smoothstep(1.0 - feather, 1.0 + feather, distance)


def line(x: float, z: float, ax: float, az: float, bx: float, bz: float,
         width: float, feather: float = 0.003) -> float:
    dx = bx - ax
    dz = bz - az
    length_squared = dx * dx + dz * dz
    along = clamp(((x - ax) * dx + (z - az) * dz) / max(length_squared, 1.0e-9))
    px = ax + dx * along
    pz = az + dz * along
    distance = math.hypot(x - px, z - pz)
    return 1.0 - smoothstep(width - feather, width + feather, distance)


def border(mask_outer: float, mask_inner: float) -> float:
    return clamp(mask_outer - mask_inner)


class Design:
    """Measurements shared by both skins, in the source mesh's +Y-forward frame."""

    def __init__(self, body) -> None:
        self.floor = body.floor
        self.top = body.top
        self.height = body.height
        self.crotch = body.crotch_z
        self.hip = body.hip_z
        self.knee = body.knee_z
        self.ankle = body.ankle_z
        self.arm = body.arm_z
        self.shoulder = body.shoulder_x
        self.neck = body.neck_z
        self.skull = body.skull_z
        self.head_centre = (body.skull_z + body.top) * 0.5
        self.head_radius = (body.top - body.skull_z) * 0.5
        self.elbow = body.elbow_x(1.0, body.wrist_x(1.0))
        self.wrist = body.wrist_x(1.0)

    def facing(self, ny: float) -> tuple[float, float]:
        return (
            smoothstep(-0.05, 0.42, ny),
            smoothstep(-0.05, 0.42, -ny),
        )

    def torso(self, x: float, z: float) -> float:
        vertical = band(z, self.hip - 0.025, self.neck + 0.012, 0.012)
        # Narrower at the waist, broad enough at the shoulders to meet the caps.
        waist = smoothstep(self.hip, self.arm, z)
        half_width = 0.155 + waist * 0.055
        return vertical * (1.0 - smoothstep(half_width - 0.01, half_width + 0.01, abs(x)))

    def arms(self, x: float, z: float) -> float:
        along = band(abs(x), self.shoulder - 0.015, self.wrist + 0.055, 0.012)
        return along * band(z, self.arm - 0.12, self.arm + 0.13, 0.016)

    def hands(self, x: float, z: float) -> float:
        return smoothstep(self.wrist - 0.015, self.wrist + 0.018, abs(x)) * band(
            z, self.arm - 0.16, self.arm + 0.16, 0.02
        )

    def shorts(self, x: float, z: float) -> float:
        return band(z, self.crotch - 0.16, self.hip + 0.025, 0.012) * (
            1.0 - smoothstep(0.255, 0.29, abs(x))
        )

    def boots(self, z: float) -> float:
        return 1.0 - smoothstep(self.ankle + 0.12, self.ankle + 0.16, z)

    def head(self, z: float) -> float:
        return smoothstep(self.skull - 0.012, self.skull + 0.012, z)


def _clean(x: float, y: float, z: float, nx: float, ny: float, nz: float,
           design: Design) -> tuple[float, float, float]:
    del y, nx, nz
    front, back = design.facing(ny)
    colour = SKIN

    # A painted cap supplies the clean design's white hair even when the separate
    # sculpted hair garment is off. Its low, pointed sides echo the concept sheet.
    if design.head(z) > 0.0:
        head_x = abs(x) / max(design.head_radius * 1.1, 0.01)
        hairline = design.head_centre + 0.025 - 0.055 * head_x
        colour = mix(colour, HAIR, smoothstep(hairline - 0.008, hairline + 0.008, z))

    torso = design.torso(x, z)
    colour = mix(colour, RED, torso)
    side = torso * smoothstep(0.115, 0.175, abs(x))
    colour = mix(colour, CREAM, side * 0.86)

    # Cream abdominal channels and red centre plates, read square-on and remain
    # quiet around the sides where a projected front elevation would smear.
    abdomen = front * band(z, design.hip + 0.015, design.arm - 0.12, 0.012)
    centre = abdomen * (1.0 - smoothstep(0.075, 0.10, abs(x)))
    colour = mix(colour, CREAM, abdomen * smoothstep(0.095, 0.135, abs(x)))
    for level in (design.hip + 0.08, design.hip + 0.16, design.hip + 0.24):
        plate = diamond(x, z, 0.0, level, 0.071, 0.056)
        colour = mix(colour, RED_LIGHT, centre * plate)
        colour = mix(colour, GOLD, centre * border(
            diamond(x, z, 0.0, level, 0.076, 0.061),
            diamond(x, z, 0.0, level, 0.068, 0.053),
        ))

    chest_z = design.arm - 0.035
    outer = diamond(x, z, 0.0, chest_z, 0.17, 0.145)
    inner = diamond(x, z, 0.0, chest_z, 0.155, 0.13)
    colour = mix(colour, GOLD, front * torso * border(outer, inner))
    colour = mix(colour, RED_LIGHT, front * torso * inner * 0.45)

    core_outer = ellipse(x, z, 0.0, chest_z + 0.005, 0.042, 0.050)
    core_inner = ellipse(x, z, 0.0, chest_z + 0.005, 0.028, 0.035)
    colour = mix(colour, INK, front * core_outer)
    colour = mix(colour, CYAN, front * core_inner)
    colour = mix(colour, CYAN_WHITE, front * ellipse(
        x, z, -0.007, chest_z + 0.017, 0.012, 0.015
    ))

    # The back is one broad red yoke with the smaller cyan power spine from the
    # reference, not a mirrored front chest.
    back_yoke = back * torso * band(z, design.arm - 0.15, design.neck, 0.012)
    colour = mix(colour, RED_LIGHT, back_yoke * (1.0 - smoothstep(0.15, 0.20, abs(x))))
    back_core = ellipse(x, z, 0.0, design.arm - 0.055, 0.030, 0.043)
    colour = mix(colour, INK, back * back_core)
    colour = mix(colour, CYAN, back * ellipse(
        x, z, 0.0, design.arm - 0.055, 0.020, 0.030
    ))
    colour = mix(colour, CYAN, back * line(
        x, z, 0.0, design.arm - 0.09, 0.0, design.arm - 0.20, 0.012
    ))

    arm = design.arms(x, z)
    shoulder = arm * band(abs(x), design.shoulder, design.elbow - 0.035, 0.012)
    colour = mix(colour, RED, shoulder)
    colour = mix(colour, GOLD, shoulder * band(
        abs(x), design.shoulder + 0.015, design.shoulder + 0.035, 0.005
    ))
    forearm = arm * band(abs(x), design.elbow + 0.01, design.wrist - 0.015, 0.012)
    stripe = line(abs(x), z, design.elbow + 0.01, design.arm - 0.045,
                  design.wrist - 0.02, design.arm + 0.035, 0.022)
    colour = mix(colour, RED_LIGHT, forearm * stripe)
    colour = mix(colour, GOLD, forearm * border(
        line(abs(x), z, design.elbow + 0.01, design.arm - 0.045,
             design.wrist - 0.02, design.arm + 0.035, 0.028),
        stripe,
    ))
    colour = mix(colour, SKIN, design.hands(x, z))

    colour = mix(colour, NAVY, design.shorts(x, z))
    colour = mix(colour, BOOT, design.boots(z))

    # Face features and cyan circuits are paint, not geometry. Front gating keeps
    # them off the spherical head's sides and from bleeding through to the back.
    face = front * design.head(z)
    eye_z = design.head_centre + 0.012
    for side_sign in (-1.0, 1.0):
        eye_x = side_sign * design.head_radius * 0.34
        eye = ellipse(x, z, eye_x, eye_z, 0.026, 0.037)
        pupil = ellipse(x, z, eye_x, eye_z - 0.002, 0.013, 0.024)
        colour = mix(colour, HAIR, face * eye)
        colour = mix(colour, INK, face * pupil)
        colour = mix(colour, CYAN_WHITE, face * ellipse(
            x, z, eye_x - 0.004, eye_z + 0.009, 0.005, 0.008
        ))
        cheek_x = side_sign * design.head_radius * 0.52
        colour = mix(colour, CYAN, face * line(
            x, z, eye_x + side_sign * 0.012, eye_z - 0.025,
            cheek_x, eye_z - 0.070, 0.004, 0.002
        ))
        colour = mix(colour, CYAN, face * line(
            x, z, cheek_x, eye_z - 0.070,
            cheek_x - side_sign * 0.020, eye_z - 0.087, 0.004, 0.002
        ))
    colour = mix(colour, INK, face * line(
        x, z, -0.028, design.head_centre - 0.072,
        0.028, design.head_centre - 0.072, 0.003, 0.0015
    ))
    return colour


def _integrated(x: float, y: float, z: float, nx: float, ny: float, nz: float,
                design: Design) -> tuple[float, float, float]:
    del y, nx, nz
    front, back = design.facing(ny)
    colour = VIOLET

    torso = design.torso(x, z)
    arms = design.arms(x, z)
    colour = mix(colour, GRAPHITE, max(torso, arms))
    colour = mix(colour, GRAPHITE_LIGHT, design.hands(x, z))
    colour = mix(colour, GRAPHITE, design.shorts(x, z))
    colour = mix(colour, BOOT, design.boots(z))

    chest_z = design.arm - 0.03
    chest_band = front * torso * band(z, design.arm - 0.16, design.neck, 0.012)
    left_plate = band(abs(x), 0.045, 0.17, 0.010) * diamond(
        abs(x), z, 0.095, chest_z, 0.082, 0.13
    )
    colour = mix(colour, SILVER, chest_band * left_plate)
    colour = mix(colour, SILVER_LIGHT, chest_band * line(
        abs(x), z, 0.045, chest_z + 0.07, 0.16, chest_z + 0.025, 0.012
    ))
    colour = mix(colour, RED_LIGHT, front * torso * line(
        abs(x), z, 0.17, design.neck - 0.015, 0.195, design.arm - 0.10, 0.009
    ))

    # Three cyan diamonds make the chest read at game distance; the concept's
    # smaller facets survive as the two flanking lights.
    for cx, cz, rx, rz in (
        (0.0, chest_z - 0.005, 0.043, 0.048),
        (-0.060, chest_z + 0.025, 0.031, 0.030),
        (0.060, chest_z + 0.025, 0.031, 0.030),
        (0.0, chest_z - 0.075, 0.025, 0.032),
    ):
        shape = diamond(x, z, cx, cz, rx, rz)
        colour = mix(colour, INK, front * diamond(x, z, cx, cz, rx * 1.18, rz * 1.18))
        colour = mix(colour, CYAN, front * shape)

    # Segment the abdomen without turning the whole torso silver.
    for level in (design.hip + 0.075, design.hip + 0.155, design.hip + 0.235):
        colour = mix(colour, SILVER, front * torso * band(
            z, level - 0.022, level + 0.022, 0.006
        ) * band(abs(x), 0.035, 0.115, 0.008))
        colour = mix(colour, RED, front * torso * line(
            abs(x), z, 0.12, level - 0.025, 0.145, level + 0.025, 0.006, 0.002
        ))

    # A mechanical back plate and a five-light spine rather than a copy of the
    # front. The broad value steps are what remain legible from third person.
    back_plate = back * torso * band(z, design.hip + 0.13, design.neck, 0.014)
    colour = mix(colour, SILVER, back_plate * diamond(
        x, z, 0.0, design.arm - 0.07, 0.16, 0.20
    ))
    colour = mix(colour, GRAPHITE, back_plate * diamond(
        x, z, 0.0, design.arm - 0.07, 0.105, 0.15
    ))
    for index in range(5):
        light_z = design.arm + 0.035 - index * 0.047
        radius = 0.019 if index in (1, 2) else 0.014
        colour = mix(colour, INK, back * ellipse(
            x, z, 0.0, light_z, radius * 1.45, radius * 1.45
        ))
        colour = mix(colour, CYAN, back * ellipse(
            x, z, 0.0, light_z, radius, radius
        ))

    # Silver armour plates and red rails run down both arms. Hands stay gloved.
    upper = arms * band(abs(x), design.shoulder, design.elbow - 0.015, 0.010)
    lower = arms * band(abs(x), design.elbow, design.wrist, 0.010)
    colour = mix(colour, SILVER, upper * band(z, design.arm - 0.085, design.arm + 0.065))
    colour = mix(colour, SILVER, lower * line(
        abs(x), z, design.elbow, design.arm - 0.055,
        design.wrist, design.arm + 0.045, 0.045, 0.008
    ))
    colour = mix(colour, RED_LIGHT, arms * line(
        abs(x), z, design.shoulder, design.arm + 0.085,
        design.wrist - 0.01, design.arm + 0.065, 0.008, 0.003
    ))

    # Violet circuitry on the exposed head and legs. It is symmetric in front and
    # back but not mirrored across them, matching the reference's full-head marks.
    head = design.head(z)
    crown = design.head_centre + design.head_radius * 0.58
    for side_sign in (-1.0, 1.0):
        sx = side_sign
        colour = mix(colour, MARK, head * line(
            x, z, sx * 0.025, design.top - 0.01,
            sx * design.head_radius * 0.58, crown, 0.012, 0.004
        ))
        colour = mix(colour, MARK, head * line(
            x, z, sx * design.head_radius * 0.58, crown,
            sx * design.head_radius * 0.36, design.head_centre - 0.06, 0.010, 0.004
        ))
        colour = mix(colour, MARK, head * line(
            x, z, sx * 0.04, design.head_centre + 0.03,
            sx * 0.11, design.head_centre - 0.09, 0.008, 0.003
        ))

    leg = band(z, design.ankle + 0.15, design.crotch - 0.14, 0.012)
    local_leg = abs(x) - 0.105
    colour = mix(colour, MARK, leg * line(
        local_leg, z, -0.045, design.crotch - 0.19,
        0.035, design.knee + 0.02, 0.010, 0.004
    ))
    colour = mix(colour, MARK, leg * line(
        local_leg, z, 0.040, design.crotch - 0.23,
        -0.025, design.knee - 0.06, 0.008, 0.003
    ))

    face = front * head
    eye_z = design.head_centre + 0.005
    for side_sign in (-1.0, 1.0):
        eye_x = side_sign * design.head_radius * 0.33
        colour = mix(colour, INK, face * ellipse(x, z, eye_x, eye_z, 0.027, 0.033))
        colour = mix(colour, GREEN, face * ellipse(x, z, eye_x, eye_z, 0.014, 0.020))
    colour = mix(colour, MARK, face * line(
        x, z, -0.025, design.head_centre - 0.072,
        0.025, design.head_centre - 0.072, 0.003, 0.0015
    ))
    return colour


PAINTERS = {
    "clean_robotic": _clean,
    "integrated_robotic": _integrated,
}


def _activate(obj: bpy.types.Object) -> None:
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for other in bpy.context.view_layer.objects:
        other.select_set(False)
    obj.hide_viewport = False
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def _unwrap(obj: bpy.types.Object) -> None:
    """Replace any source UVs with the one atlas every generated skin shares."""
    _activate(obj)
    while obj.data.uv_layers:
        obj.data.uv_layers.remove(obj.data.uv_layers[0])
    obj.data.uv_layers.new(name=UV_NAME)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    # Twenty pixels of separation at 1024 before the seven-pixel dilation. A
    # smaller margin lets mipmaps pull a neighbouring limb into a seam.
    bpy.ops.uv.smart_project(
        angle_limit=math.radians(66.0),
        island_margin=0.020,
        area_weight=0.0,
        correct_aspect=True,
        scale_to_bounds=True,
    )
    bpy.ops.object.mode_set(mode="OBJECT")
    obj.data.update()


def _rasterise(mesh: bpy.types.Mesh, painter, design: Design) -> bytearray:
    """Rasterise one analytic 3D design through the mesh's packed UV triangles."""
    pixels = bytearray(SIZE * SIZE * 3)
    filled = bytearray(SIZE * SIZE)
    uv_data = mesh.uv_layers.active.data
    mesh.calc_loop_triangles()

    for triangle in mesh.loop_triangles:
        loop_indices = triangle.loops
        uv = []
        points = []
        normals = []
        for loop_index in loop_indices:
            loop = mesh.loops[loop_index]
            coordinate = uv_data[loop_index].uv
            uv.append((
                coordinate.x * (SIZE - 1),
                (1.0 - coordinate.y) * (SIZE - 1),
            ))
            vertex = mesh.vertices[loop.vertex_index]
            points.append(vertex.co)
            normals.append(vertex.normal)

        ax, ay = uv[0]
        bx, by = uv[1]
        cx, cy = uv[2]
        denominator = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(denominator) < 1.0e-8:
            continue
        least_x = max(0, int(math.floor(min(ax, bx, cx))))
        most_x = min(SIZE - 1, int(math.ceil(max(ax, bx, cx))))
        least_y = max(0, int(math.floor(min(ay, by, cy))))
        most_y = min(SIZE - 1, int(math.ceil(max(ay, by, cy))))

        for py in range(least_y, most_y + 1):
            sample_y = py + 0.5
            for px in range(least_x, most_x + 1):
                sample_x = px + 0.5
                wa = ((by - cy) * (sample_x - cx)
                      + (cx - bx) * (sample_y - cy)) / denominator
                wb = ((cy - ay) * (sample_x - cx)
                      + (ax - cx) * (sample_y - cy)) / denominator
                wc = 1.0 - wa - wb
                if wa < -1.0e-5 or wb < -1.0e-5 or wc < -1.0e-5:
                    continue
                x = points[0].x * wa + points[1].x * wb + points[2].x * wc
                y = points[0].y * wa + points[1].y * wb + points[2].y * wc
                z = points[0].z * wa + points[1].z * wb + points[2].z * wc
                nx = normals[0].x * wa + normals[1].x * wb + normals[2].x * wc
                ny = normals[0].y * wa + normals[1].y * wb + normals[2].y * wc
                nz = normals[0].z * wa + normals[1].z * wb + normals[2].z * wc
                normal_length = math.sqrt(nx * nx + ny * ny + nz * nz)
                if normal_length > 1.0e-8:
                    nx /= normal_length
                    ny /= normal_length
                    nz /= normal_length
                colour = painter(x, y, z, nx, ny, nz, design)
                pixel_index = py * SIZE + px
                byte_index = pixel_index * 3
                pixels[byte_index] = round(clamp(colour[0]) * 255.0)
                pixels[byte_index + 1] = round(clamp(colour[1]) * 255.0)
                pixels[byte_index + 2] = round(clamp(colour[2]) * 255.0)
                filled[pixel_index] = 1

    _dilate(pixels, filled)
    return pixels


def _dilate(pixels: bytearray, filled: bytearray) -> None:
    """Carry island-edge colours through the empty mip gutter without crossing it."""
    frontier = []
    for index, value in enumerate(filled):
        if not value:
            continue
        x = index % SIZE
        y = index // SIZE
        if (x > 0 and not filled[index - 1]) or (x + 1 < SIZE and not filled[index + 1]) \
                or (y > 0 and not filled[index - SIZE]) \
                or (y + 1 < SIZE and not filled[index + SIZE]):
            frontier.append(index)

    for _step in range(GUTTER):
        next_pixels: dict[int, int] = {}
        for source in frontier:
            x = source % SIZE
            y = source // SIZE
            neighbours = []
            if x > 0:
                neighbours.append(source - 1)
            if x + 1 < SIZE:
                neighbours.append(source + 1)
            if y > 0:
                neighbours.append(source - SIZE)
            if y + 1 < SIZE:
                neighbours.append(source + SIZE)
            for target in neighbours:
                if not filled[target] and target not in next_pixels:
                    next_pixels[target] = source
        frontier = list(next_pixels)
        for target, source in next_pixels.items():
            source_byte = source * 3
            target_byte = target * 3
            pixels[target_byte:target_byte + 3] = pixels[source_byte:source_byte + 3]
            filled[target] = 1


def _chunk(name: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + name
        + payload
        + struct.pack(">I", binascii.crc32(name + payload) & 0xFFFFFFFF)
    )


def _write_png(path: str, pixels: bytearray) -> None:
    rows = bytearray()
    stride = SIZE * 3
    for y in range(SIZE):
        rows.append(0)  # PNG filter: none; zlib handles these flat colour fields.
        start = y * stride
        rows.extend(pixels[start:start + stride])
    encoded = (
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
        + _chunk(b"sRGB", b"\x00")
        + _chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + _chunk(b"IEND", b"")
    )
    with open(path, "wb") as output:
        output.write(encoded)


def build(mesh_obj: bpy.types.Object, body, asset_dir: str) -> dict[str, str]:
    """Give ``mesh_obj`` its atlas and write both selectable texture PNGs."""
    _unwrap(mesh_obj)
    design = Design(body)
    paths = {}
    for skin_id, filename in SKINS.items():
        path = os.path.join(asset_dir, filename)
        pixels = _rasterise(mesh_obj.data, PAINTERS[skin_id], design)
        _write_png(path, pixels)
        paths[skin_id] = path
        print("  skin {0:21s} {1:.1f} KB".format(
            skin_id, os.path.getsize(path) / 1024.0
        ))
    return paths
