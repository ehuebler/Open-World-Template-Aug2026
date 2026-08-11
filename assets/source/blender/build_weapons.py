"""Builds the dual-wieldable weapons and exports assets/runtime/items/sword.glb and
assets/runtime/items/laser_rifle.glb.

Run headless from the project root; it needs no input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python assets/source/blender/build_weapons.py

Both weapons share one mount convention so either can go in either hand:

    origin  the centre of the grip, i.e. the point that sits inside the fist
    +Y      the direction the weapon points - blade tip, muzzle
    +Z      the weapon's up - sword flat, rifle sight rail

After the Y-up export that puts the aim on Godot's -Z and up on +Y, so a weapon
parented to a hand with an identity basis points where the character faces.

Grips are **measured off assets/runtime/characters/player_character.glb** rather than
written down here: character_ref.py finds the vertices weighted to each Hand bone
and reports the fist's radius and where its centroid sits along the bone. Grip
thickness and length come from that radius, so re-exporting the character after
editing its hands is enough to keep the weapons fitting. Everything else -
blade taper, barrel calibre, receiver layout - is a design choice and is spelled
out as constants below.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref
from propkit import (add_box, add_cone, add_cylinder, add_sphere,
                     ensure_materials, evaluated_polys, export_selected,
                     new_object, reset_scene, taper_loft)

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
ASSET_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "items")
BLEND_PATH = os.path.join(SOURCE_DIR, "weapons.blend")
SWORD_GLB = os.path.join(ASSET_DIR, "sword.glb")
RIFLE_GLB = os.path.join(ASSET_DIR, "laser_rifle.glb")

# A real hand closes on a handle about a third of the fist's own thickness, and
# leaves a little grip proud at each end. Both are ratios of the measured fist
# radius, which is what makes the weapons follow the character.
GRIP_TO_FIST = 0.37
GRIP_LENGTH_TO_FIST = 1.10

BEVEL_WIDTH = 0.0018
SMOOTH_ANGLE = 35.0


def grip_fit(measurement):
    """Turn the measured fist into the grip dimensions both weapons build from."""
    fits = [fit for fit in measurement["hands"].values() if fit is not None]
    radius = sum(fit["radius_mean"] for fit in fits) / len(fits)
    fraction = sum(fit["grip_fraction"] for fit in fits) / len(fits)
    return {
        "radius": radius * GRIP_TO_FIST,
        "half_length": radius * GRIP_LENGTH_TO_FIST,
        "fist_radius": radius,
        "along_hand": fraction,
    }


# --------------------------------------------------------------------------
# Sword
# --------------------------------------------------------------------------

SWORD_MATERIALS = {
    "SwordBlade": {"colour": (0.720, 0.745, 0.780, 1.0), "roughness": 0.22,
                   "metallic": 0.95},
    "SwordFitting": {"colour": (0.480, 0.360, 0.140, 1.0), "roughness": 0.32,
                     "metallic": 0.85},
    "SwordGrip": {"colour": (0.130, 0.085, 0.070, 1.0), "roughness": 0.72},
}
BLADE, FITTING, GRIP = range(3)

BLADE_LENGTH = 0.614
GUARD_CLEARANCE = 0.018   # grip end to guard centre
BLADE_SEAT = 0.010        # guard centre to where the blade starts

# Flattened hexagon: a central ridge either side of the flat, so the blade catches
# a highlight down its length instead of reading as a flat plank.
BLADE_PROFILE = [(-1.0, 0.0), (-0.52, 1.0), (0.52, 1.0),
                 (1.0, 0.0), (0.52, -1.0), (-0.52, -1.0)]

# (fraction along the blade, half-width across X, half-thickness in Z). The point
# is drawn out over the last fifth: converging it any faster leaves a rounded
# nose once the bevel runs over it.
BLADE_TAPER = [
    (0.000, 0.0335, 0.0080),
    (0.150, 0.0330, 0.0078),
    (0.360, 0.0318, 0.0073),
    (0.560, 0.0298, 0.0067),
    (0.720, 0.0268, 0.0060),
    (0.840, 0.0225, 0.0053),
    (0.930, 0.0158, 0.0043),
    (0.980, 0.0080, 0.0030),
    (1.000, 0.0018, 0.0014),
]

# Crossguard, lofted along X. It lies in the blade's plane, so its cross-section
# is taller along the blade axis than it is thick.
GUARD_SECTIONS = [
    (-0.100, 0.0090, 0.0062),
    (-0.061, 0.0118, 0.0084),
    (-0.022, 0.0155, 0.0110),
    (0.000, 0.0170, 0.0120),
    (0.022, 0.0155, 0.0110),
    (0.061, 0.0118, 0.0084),
    (0.100, 0.0090, 0.0062),
]


def sword_grip_sections(grip, count=25):
    """Waisted grip with four raised wrap ridges."""
    half = grip["half_length"]
    sections = []
    for i in range(count):
        t = i / (count - 1)
        swell = grip["radius"] * 0.12 * (2.0 * t - 1.0) ** 2
        wrap = grip["radius"] * 0.07 * (0.5 + 0.5 * math.cos(t * 8.0 * math.pi))
        radius = grip["radius"] * 0.89 + swell + wrap
        sections.append((-half + t * 2.0 * half, radius, radius))
    return sections


def build_sword(grip):
    bm = bmesh.new()
    forward, right, up = (0.0, 1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0)

    guard_y = grip["half_length"] + GUARD_CLEARANCE
    blade_root = guard_y + BLADE_SEAT
    blade = [(blade_root + fraction * BLADE_LENGTH, half_w, half_t)
             for fraction, half_w, half_t in BLADE_TAPER]

    taper_loft(bm, blade, forward, right, up, BLADE, profile=BLADE_PROFILE)
    taper_loft(bm, GUARD_SECTIONS, right, forward, up, FITTING,
               centre=(0.0, guard_y, 0.0), segments=16)
    taper_loft(bm, sword_grip_sections(grip), forward, right, up, GRIP, segments=14)

    pommel_seat = -grip["half_length"] - 0.004
    add_cylinder(bm, (0.0, pommel_seat - 0.012, 0.0), (0.0, pommel_seat, 0.0),
                 grip["radius"] * 1.12, FITTING, 16)
    add_sphere(bm, (0.0, pommel_seat - 0.016, 0.0), grip["radius"] * 1.16,
               FITTING, segments=18, scale=(1.0, 0.88, 1.0))

    return new_object("Sword", bm, list(SWORD_MATERIALS), bevel_width=BEVEL_WIDTH,
                      smooth_angle=SMOOTH_ANGLE)


# --------------------------------------------------------------------------
# Laser rifle
# --------------------------------------------------------------------------

RIFLE_MATERIALS = {
    "RifleBody": {"colour": (0.115, 0.125, 0.140, 1.0), "roughness": 0.55},
    "RifleMetal": {"colour": (0.330, 0.350, 0.375, 1.0), "roughness": 0.34,
                   "metallic": 0.90},
    "RifleGrip": {"colour": (0.070, 0.075, 0.085, 1.0), "roughness": 0.78},
    "RifleGlow": {"colour": (0.180, 0.780, 0.920, 1.0), "roughness": 0.30,
                  "emission": ((0.220, 0.860, 1.000, 1.0), 5.0)},
}
BODY, METAL, RGRIP, GLOW = range(4)

BARREL_RADIUS = 0.050          # a 0.10 m bore, deliberately oversized
BARREL_Y0 = 0.100
BARREL_Y1 = 0.395
RING_RADIUS = 0.059
GRIP_RAKE = math.radians(19.0)  # top of the grip sits forward of the bottom

# (fraction of the grip's half length, width scale, front-to-back scale), both
# scales relative to the grip radius. Pistol grips are deeper than they are wide.
RIFLE_GRIP_TAPER = [
    (-1.000, 0.75, 0.88),
    (-0.657, 0.84, 1.01),
    (-0.263, 0.86, 1.07),
    (0.157, 0.82, 1.05),
    (0.551, 0.77, 0.99),
    (1.000, 0.71, 0.88),
]


def build_rifle(grip):
    bm = bmesh.new()

    # The grip is raked back, and everything else hangs off the receiver's
    # underside, which sits just above where the grip enters it.
    half = grip["half_length"] * 1.08
    axis = Vector((0.0, math.sin(GRIP_RAKE), math.cos(GRIP_RAKE)))
    right = Vector((1.0, 0.0, 0.0))
    up = right.cross(axis).normalized()
    sections = [(fraction * half, grip["radius"] * wide, grip["radius"] * deep)
                for fraction, wide, deep in RIFLE_GRIP_TAPER]
    taper_loft(bm, sections, axis, right, up, RGRIP, segments=16)

    floor = (axis * half).z - 0.002        # receiver underside
    barrel_z = floor + 0.050
    top = floor + 0.100

    add_box(bm, (-0.046, -0.130, floor), (0.046, 0.115, top), BODY)
    add_box(bm, (-0.036, -0.175, floor + 0.016), (0.036, -0.130, top - 0.016), METAL)

    add_cylinder(bm, (0.0, BARREL_Y0, barrel_z), (0.0, BARREL_Y1, barrel_z),
                 BARREL_RADIUS, METAL, 24)
    for y in (0.155, 0.235, 0.315):
        add_cylinder(bm, (0.0, y - 0.011, barrel_z), (0.0, y + 0.011, barrel_z),
                     RING_RADIUS, METAL, 24)
    for y in (0.195, 0.275):
        add_cylinder(bm, (0.0, y - 0.009, barrel_z), (0.0, y + 0.009, barrel_z),
                     0.053, GLOW, 24)

    add_cone(bm, (0.0, BARREL_Y1, barrel_z), (0.0, 0.428, barrel_z),
             BARREL_RADIUS, 0.061, METAL, 24)
    add_cylinder(bm, (0.0, 0.424, barrel_z), (0.0, 0.438, barrel_z), 0.043, GLOW, 24)

    # Power cell slung under the barrel.
    cell_z = floor - 0.024
    add_cylinder(bm, (0.0, 0.085, cell_z), (0.0, 0.178, cell_z), 0.027, GLOW, 18)
    add_cylinder(bm, (0.0, 0.085, cell_z), (0.0, 0.100, cell_z), 0.031, METAL, 18)
    add_cylinder(bm, (0.0, 0.163, cell_z), (0.0, 0.178, cell_z), 0.031, METAL, 18)

    # Sight rail and optic.
    add_box(bm, (-0.020, -0.105, top), (0.020, 0.050, top + 0.012), METAL)
    scope_z = top + 0.036
    add_cylinder(bm, (0.0, -0.080, scope_z), (0.0, 0.015, scope_z), 0.025, BODY, 18)
    add_box(bm, (-0.013, -0.068, top + 0.010), (0.013, -0.050, top + 0.026), METAL)
    add_box(bm, (-0.013, -0.006, top + 0.010), (0.013, 0.012, top + 0.026), METAL)
    add_cylinder(bm, (0.0, 0.012, scope_z), (0.0, 0.020, scope_z), 0.021, GLOW, 18)

    # Trigger group, bridging the grip to the receiver.
    add_box(bm, (-0.013, 0.022, floor - 0.034), (0.013, 0.074, floor - 0.021), BODY)
    add_box(bm, (-0.013, 0.062, floor - 0.021), (0.013, 0.074, floor), BODY)
    add_box(bm, (-0.008, 0.030, floor - 0.021), (0.008, 0.044, floor - 0.002), METAL)

    return new_object("LaserRifle", bm, list(RIFLE_MATERIALS),
                      bevel_width=BEVEL_WIDTH, smooth_angle=SMOOTH_ANGLE)


# --------------------------------------------------------------------------

def report(obj, height):
    lo = [min(vert.co[i] for vert in obj.data.vertices) for i in range(3)]
    hi = [max(vert.co[i] for vert in obj.data.vertices) for i in range(3)]
    print("  {0:11s} polys={1:5d} exported={2:5d}".format(
        obj.name, len(obj.data.polygons), evaluated_polys(obj)))
    print("    length(+Y)={0:.3f} m ({1:.0f}% of character height)".format(
        hi[1] - lo[1], 100.0 * (hi[1] - lo[1]) / height))
    print("    reach ahead of grip={0:.3f}  behind={1:.3f}".format(hi[1], -lo[1]))
    print("    span X={0:.3f} Z={1:.3f}".format(hi[0] - lo[0], hi[2] - lo[2]))


def main():
    reset_scene()
    measurement = character_ref.measure()
    grip = grip_fit(measurement)
    print("grip from the measured fist: radius {0:.4f} m, half length {1:.4f} m, "
          "{2:.3f} along the hand bone".format(
              grip["radius"], grip["half_length"], grip["along_hand"]))

    ensure_materials(SWORD_MATERIALS)
    ensure_materials(RIFLE_MATERIALS)
    sword = build_sword(grip)
    rifle = build_rifle(grip)

    print("weapons, origin at the grip centre, aim along +Y:")
    report(sword, measurement["height"])
    report(rifle, measurement["height"])

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected([sword], SWORD_GLB)
    export_selected([rifle], RIFLE_GLB)


if __name__ == "__main__":
    main()
