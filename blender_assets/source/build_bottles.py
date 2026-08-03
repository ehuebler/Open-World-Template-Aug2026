"""Builds the two hand-held bottles and exports blender_assets/water_bottle.glb
and blender_assets/chemical_flask.glb.

Run headless from the project root; it needs no input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python blender_assets/source/build_bottles.py

Both bottles use the weapons' mount convention, because a bottle is gripped
exactly like a sword handle - the fist closes around a cylinder whose axis runs
straight through it:

    origin  the centre of the grip, i.e. the point that sits inside the fist
    +Y      towards the cap or stopper, so the bottle's own up
    +Z      the face the graduation marks read from

Sizing follows the weapons' split. The *gripped* radius is measured off
blender_assets/player_character.glb - character_ref.py reports the fist's radius
from the hand bones' skin weights - and every radius below is a multiple of that,
so re-exporting the character after editing its hands keeps both bottles in hand.
Heights are absolute metres, because this character's mitten hands are cartoonishly
large for its 1.45 m frame: scale a whole bottle off the fist and you get a 260 mm
flask. So the bottles are as slender or as squat as they should be for the body,
and only their thickness follows the hand. Profiles are (height in metres, radius
as a multiple of the gripped radius).

The flask is a real hollow vessel rather than a solid with a transparent skin: the
profile runs up the outside, over the lip and back down the inside to a floor.
Alpha-blended glass with no inner wall reads as tinted film, whereas the second
surface gives the double edge highlight that makes it look like glass.
"""

import os
import sys

import bmesh
import bpy

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SOURCE_DIR)

import character_ref
from propkit import (add_cone, add_cylinder, ensure_materials, evaluated_polys,
                     export_selected, new_object, reset_scene, taper_loft)

ASSET_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
BLEND_PATH = os.path.join(SOURCE_DIR, "bottles.blend")
WATER_GLB = os.path.join(ASSET_DIR, "water_bottle.glb")
FLASK_GLB = os.path.join(ASSET_DIR, "chemical_flask.glb")

# Fractions of the measured fist radius. The water bottle's waist is the fattest
# thing here and still leaves the fingertips past its far side; the flask is held
# by its neck, so it sits close to the sword's 0.37.
WAIST_TO_FIST = 0.54
NECK_TO_FIST = 0.43
FINGER_REACH = 0.60      # how far either side of the origin the fingers wrap

# Small, because the thinnest wall here is under 3 mm and the weapons' 1.8 mm
# bevel would eat straight through it.
BEVEL_WIDTH = 0.0007
SMOOTH_ANGLE = 34.0
SEGMENTS = 28


def fist_radius(measurement):
    """Mean radius of the closed fist, which the gripped radii scale from."""
    fits = [fit for fit in measurement["hands"].values() if fit is not None]
    return sum(fit["radius_mean"] for fit in fits) / len(fits)


def profile_radius(profile, height):
    """Linearly interpolated radius of a (height, radius) profile."""
    if height <= profile[0][0]:
        return profile[0][1]
    for (y0, r0), (y1, r1) in zip(profile, profile[1:]):
        if height <= y1:
            return r0 + (r1 - r0) * (height - y0) / (y1 - y0)
    return profile[-1][1]


def sections(profile, grip):
    """Scale a profile into the (distance, right, up) triples taper_loft wants."""
    return [(y, r * grip, r * grip) for y, r in profile]


def tube(bm, span, slot, grip, segments=SEGMENTS):
    """A cylinder along +Y from a (low, high, radius) span."""
    low, high, radius = span
    add_cylinder(bm, (0.0, low, 0.0), (0.0, high, 0.0), radius * grip, slot,
                 segments)


def gripped(profile, grip, reach, steps=24):
    """Widest radius the closed fingers have to reach around, in metres.

    Past `reach` the palm and wrist lie alongside the bottle rather than gripping
    it, so the shoulders and base are not what decides whether it can be held.
    """
    return grip * max(profile_radius(profile, -reach + 2.0 * reach * i / steps)
                      for i in range(steps + 1))


# --------------------------------------------------------------------------
# Water bottle
# --------------------------------------------------------------------------

WATER_MATERIALS = {
    "BottleBody": {"colour": (0.055, 0.235, 0.290, 1.0), "roughness": 0.28,
                   "metallic": 0.60},
    "BottleTrim": {"colour": (0.062, 0.066, 0.076, 1.0), "roughness": 0.80},
    "BottleMetal": {"colour": (0.615, 0.635, 0.665, 1.0), "roughness": 0.24,
                    "metallic": 0.92},
}
BODY, TRIM, METAL = range(3)

# One shell from the base to the top of the neck. The waist at zero is both the
# narrowest point of the body and the origin, so the bottle is gripped where it is
# thinnest and the fist lands a third of the way up.
WATER_PROFILE = [
    (-0.0660, 0.570),
    (-0.0641, 0.870),
    (-0.0615, 1.000),
    (-0.0585, 1.045),
    (-0.0425, 1.065),
    (-0.0225, 1.070),
    (0.0000, 1.000),
    (0.0245, 1.023),
    (0.0510, 1.066),
    (0.0640, 1.053),
    (0.0740, 0.970),
    (0.0835, 0.772),
    (0.0908, 0.595),
    (0.0965, 0.512),
    (0.1030, 0.501),
]

WATER_BAND = (-0.0180, 0.0185, 1.105)    # rubber sleeve over the waist
WATER_COLLAR = (0.0945, 0.0985, 0.577)   # steel ring where the thread starts
WATER_CAP = (0.0985, 0.1205, 0.622)
WATER_CAP_RING = (0.1035, 0.1145, 0.665)  # proud band, so the cap looks grippable
WATER_CAP_TOP = (0.1205, 0.1240, 0.588)


def build_water_bottle(grip):
    bm = bmesh.new()
    taper_loft(bm, sections(WATER_PROFILE, grip), (0.0, 1.0, 0.0),
               (1.0, 0.0, 0.0), (0.0, 0.0, 1.0), BODY, segments=SEGMENTS)
    tube(bm, WATER_BAND, TRIM, grip)
    tube(bm, WATER_COLLAR, METAL, grip, 20)
    tube(bm, WATER_CAP, TRIM, grip, 20)
    tube(bm, WATER_CAP_RING, TRIM, grip, 20)
    tube(bm, WATER_CAP_TOP, METAL, grip, 20)
    return new_object("WaterBottle", bm, list(WATER_MATERIALS),
                      bevel_width=BEVEL_WIDTH, smooth_angle=SMOOTH_ANGLE)


# --------------------------------------------------------------------------
# Chemical flask
# --------------------------------------------------------------------------

FLASK_MATERIALS = {
    "FlaskGlass": {"colour": (0.760, 0.840, 0.820, 1.0), "roughness": 0.06,
                   "alpha": 0.30},
    "FlaskLiquid": {"colour": (0.130, 0.760, 0.260, 1.0), "roughness": 0.14,
                    "emission": ((0.180, 0.980, 0.360, 1.0), 1.6)},
    "FlaskCork": {"colour": (0.470, 0.325, 0.180, 1.0), "roughness": 0.86},
    "FlaskMark": {"colour": (0.880, 0.900, 0.880, 1.0), "roughness": 0.38},
}
GLASS, LIQUID, CORK, MARK = range(4)

# Erlenmeyer: flat foot, cone body, neck long enough that the closed fingers sit
# on it without swallowing the stopper. The cone runs straight into the neck, as a
# real one does - there is no shoulder to speak of.
FLASK_OUTER = [
    (-0.1000, 0.560),
    (-0.0980, 1.230),
    (-0.0958, 1.450),
    (-0.0942, 1.586),
    (-0.0905, 1.572),
    (-0.0868, 1.500),
    (-0.0700, 1.320),
    (-0.0540, 1.148),
    (-0.0420, 1.060),
    (-0.0330, 1.012),
    (-0.0240, 1.000),
    (0.0140, 0.998),
    (0.0330, 1.000),
    (0.0380, 1.020),
    (0.0410, 1.180),
    (0.0442, 1.174),
]

# The cavity, listed floor upwards, about 0.10 inside the outer wall. The base is
# left far thicker than the wall, the way blown glassware actually is.
FLASK_INNER = [
    (-0.0958, 0.560),
    (-0.0942, 1.360),
    (-0.0912, 1.452),
    (-0.0868, 1.400),
    (-0.0700, 1.220),
    (-0.0540, 1.048),
    (-0.0420, 0.960),
    (-0.0330, 0.912),
    (-0.0240, 0.900),
    (0.0140, 0.898),
    (0.0330, 0.900),
    (0.0380, 0.918),
    (0.0432, 0.960),
]

# Shank narrow enough to clear the bore, head wider than the lip.
CORK_PROFILE = [
    (0.0300, 0.680),
    (0.0345, 0.760),
    (0.0430, 0.800),
    (0.0470, 1.185),
    (0.0540, 1.160),
    (0.0575, 1.050),
    (0.0600, 0.700),
]

LIQUID_FILL = -0.0500
LIQUID_FLOOR = -0.0930
LIQUID_INSET = 0.075      # never touch the glass, or the blend order shows

MARK_HEIGHTS = (-0.0800, -0.0660, -0.0520)
MARK_THICKNESS = 0.0022
MARK_PROUD = 0.045


def build_flask(grip):
    bm = bmesh.new()
    forward, right, up = (0.0, 1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0)

    shell = FLASK_OUTER + list(reversed(FLASK_INNER))
    taper_loft(bm, sections(shell, grip), forward, right, up, GLASS,
               segments=SEGMENTS)

    add_cone(bm, (0.0, LIQUID_FLOOR, 0.0), (0.0, LIQUID_FILL, 0.0),
             (profile_radius(FLASK_INNER, LIQUID_FLOOR) - LIQUID_INSET) * grip,
             (profile_radius(FLASK_INNER, LIQUID_FILL) - LIQUID_INSET) * grip,
             LIQUID, SEGMENTS)

    taper_loft(bm, sections(CORK_PROFILE, grip), forward, right, up, CORK,
               segments=20)

    for height in MARK_HEIGHTS:
        low, high = height - MARK_THICKNESS / 2.0, height + MARK_THICKNESS / 2.0
        add_cone(bm, (0.0, low, 0.0), (0.0, high, 0.0),
                 (profile_radius(FLASK_OUTER, low) + MARK_PROUD) * grip,
                 (profile_radius(FLASK_OUTER, high) + MARK_PROUD) * grip,
                 MARK, SEGMENTS)

    return new_object("ChemicalFlask", bm, list(FLASK_MATERIALS),
                      bevel_width=BEVEL_WIDTH, smooth_angle=SMOOTH_ANGLE)


# --------------------------------------------------------------------------

def report(obj, profile, grip, fist, height):
    lo = [min(vert.co[i] for vert in obj.data.vertices) for i in range(3)]
    hi = [max(vert.co[i] for vert in obj.data.vertices) for i in range(3)]
    reach = gripped(profile, grip, FINGER_REACH * fist)
    print("  {0:14s} polys={1:5d} exported={2:5d}".format(
        obj.name, len(obj.data.polygons), evaluated_polys(obj)))
    print("    height(+Y)={0:.3f} m ({1:.1f}% of character height)".format(
        hi[1] - lo[1], 100.0 * (hi[1] - lo[1]) / height))
    print("    above grip={0:.3f}  below={1:.3f}  widest diameter={2:.3f}".format(
        hi[1], -lo[1], max(hi[0] - lo[0], hi[2] - lo[2])))
    print("    gripped radius={0:.4f} m = {1:.2f} of the fist radius".format(
        reach, reach / fist))


def main():
    reset_scene()
    measurement = character_ref.measure()
    fist = fist_radius(measurement)
    waist, neck = fist * WAIST_TO_FIST, fist * NECK_TO_FIST
    print("fist radius measured from the character: {0:.4f} m".format(fist))
    print("gripped radii: waist {0:.4f} m, flask neck {1:.4f} m".format(waist, neck))

    ensure_materials(WATER_MATERIALS)
    ensure_materials(FLASK_MATERIALS)
    water = build_water_bottle(waist)
    flask = build_flask(neck)

    print("bottles, origin at the grip centre, cap along +Y:")
    report(water, WATER_PROFILE, waist, fist, measurement["height"])
    report(flask, FLASK_OUTER, neck, fist, measurement["height"])

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected([water], WATER_GLB)
    export_selected([flask], FLASK_GLB)


if __name__ == "__main__":
    main()
