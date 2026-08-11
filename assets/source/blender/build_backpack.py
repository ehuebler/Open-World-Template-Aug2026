"""Builds the backpack and exports assets/runtime/items/backpack.glb.

Run headless from the project root; it needs no input .blend:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup --python assets/source/blender/build_backpack.py

The pack is a rigid mesh, not a skinned garment: a real pack does not deform, so
it belongs on a bone rather than in the skin. It follows the same convention as
the weapons, so it mounts the same way:

    origin  the UpperChest bone, so a BoneAttachment3D there needs no offset
    +Y      the character's forward, i.e. the pack hangs off the -Y face
    +Z      up

After the Y-up export that puts forward on Godot's -Z and up on +Y.

Every dimension is **measured off assets/runtime/characters/player_character.glb** by
character_ref.py: the back surface sets where the pack's front face sits, the
torso's width and depth scale the pack, and the spine and shoulder bones set how
far up and down it reaches. Editing the character and re-exporting is enough to
keep the pack sitting flush against its back.
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
from propkit import (add_box, add_cylinder, add_loft, add_path_loft, catmull_rom,
                     ensure_materials, evaluated_polys, export_selected,
                     new_object, reset_scene, ring, squircle_profile)

PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
ASSET_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "items")
BLEND_PATH = os.path.join(SOURCE_DIR, "backpack.blend")
GLB_PATH = os.path.join(ASSET_DIR, "backpack.glb")

MATERIALS = {
    "BackpackCanvas": {"colour": (0.243, 0.255, 0.176, 1.0), "roughness": 0.78},
    "BackpackLeather": {"colour": (0.148, 0.096, 0.068, 1.0), "roughness": 0.62},
    "BackpackMetal": {"colour": (0.520, 0.470, 0.330, 1.0), "roughness": 0.36,
                      "metallic": 0.85},
}
SLOTS = list(MATERIALS)
CANVAS, LEATHER, METAL = range(3)

EMBED = 0.010          # how far the front face sinks into the back, to avoid a gap
WIDTH_OF_TORSO = 1.05  # pack width as a fraction of the torso's
DEPTH_OF_TORSO = 0.44  # how far it protrudes, as a fraction of torso depth
TOP_BELOW_SHOULDER = 0.030
BOTTOM_ABOVE_SPINE = 0.085
STRAP_STANDOFF = 0.009  # keeps the straps off the skin instead of z-fighting it
STRAP_CLEARS_HEAD = 0.020  # how far outboard of the head the straps cross

# (fraction of pack height, width scale, depth scale). Fullest around the middle
# so it reads as a stuffed soft pack rather than a crate.
BODY_SECTIONS = [
    (0.000, 0.84, 0.79),
    (0.175, 0.95, 0.95),
    (0.450, 1.00, 1.00),
    (0.720, 1.00, 0.98),
    (0.900, 0.95, 0.89),
    (1.000, 0.84, 0.74),
]

LID_SECTIONS = [
    (0.880, 1.05, 1.04),
    (0.960, 1.03, 1.00),
    (1.010, 0.92, 0.86),
    (1.038, 0.66, 0.60),
]

BEVEL_WIDTH = 0.0035
SMOOTH_ANGLE = 40.0
PROFILE_SEGMENTS = 20


def shoulder_crossing(body, start=0.10, stop=0.36, step=0.005, cliff=0.12):
    """The x where the top surface falls away from the head onto the shoulder.

    This character is a big head sitting almost straight on the body, with no
    trapezius to speak of, so a strap cannot cross where a real one would. Walking
    outward and taking the first sharp drop finds the saddle beside the head, which
    is the only place a strap can actually sit.
    """
    previous = None
    steps = int((stop - start) / step) + 1
    for i in range(steps):
        x = start + step * i
        hit = character_ref.ray_to_surface(body, (x, 0.0, 1.9), (0.0, 0.0, -1.0))
        if hit is None:
            continue
        if previous is not None and previous - hit.z > cliff:
            return x
        previous = hit.z
    raise RuntimeError("no shoulder found outboard of the head")


def measure_back(body, rig):
    """Where the pack has to sit, from the character's own geometry and bones."""
    bones = rig.data.bones
    spine_z = (rig.matrix_world @ bones["Spine"].head_local).z
    mount_z = (rig.matrix_world @ bones["UpperChest"].head_local).z

    cross_x = shoulder_crossing(body) + STRAP_CLEARS_HEAD
    crest = character_ref.ray_to_surface(body, (cross_x, 0.0, 1.9), (0.0, 0.0, -1.0))

    # Hang the pack off the shoulder surface rather than off the shoulder bone: on
    # a body this stylised the bone sits well below the shoulder you can see, and a
    # pack placed off it rides down by the whole difference.
    top = crest.z - TOP_BELOW_SHOULDER
    bottom = spine_z + BOTTOM_ABOVE_SPINE

    # Sample the torso across the span the pack covers, and use its deepest point
    # so no part of the pack floats away from the back.
    heights = [bottom + (top - bottom) * i / 8.0 for i in range(9)]
    profile = [entry for entry in character_ref.torso_profile(body, heights)
               if entry is not None]
    back = min(entry["back"] for entry in profile)
    depth = max(entry["front"] - entry["back"] for entry in profile)

    # Width is taken at the mount height, not across the span: this character is
    # much wider at the hips than at the chest, and a pack sized to the hips would
    # overhang the back it is supposed to rest on.
    half_width = character_ref.torso_profile(body, [mount_z])[0]["half_width"]

    return {
        "top": top,
        "bottom": bottom,
        "mount_z": mount_z,
        "front": back + EMBED,
        "half_width": half_width * WIDTH_OF_TORSO,
        "depth": depth * DEPTH_OF_TORSO,
        "cross_x": cross_x,
        "crest_z": crest.z,
    }


def build(fit, body):
    bm = bmesh.new()
    profile = squircle_profile(PROFILE_SEGMENTS)
    height = fit["top"] - fit["bottom"]

    def at(fraction):
        return fit["bottom"] + height * fraction

    def fraction_of(z):
        return (z - fit["bottom"]) / height

    def face_at(fraction):
        """Where the pack's back panel sits, following the spine's own contour.

        A flat panel set at the deepest point of the back stands off everywhere the
        back is shallower, which on this character leaves a visible gap under the
        shoulder blades. Tracking the surface per section keeps it in contact.
        """
        hit = character_ref.ray_to_surface(
            body, (0.0, -0.9, at(fraction)), (0.0, 1.0, 0.0))
        return (fit["front"] - EMBED if hit is None else hit.y) + EMBED

    def section(fraction, width_scale, depth_scale):
        """A ring whose front face lies on the back and whose bulk grows backward."""
        depth = fit["depth"] * depth_scale
        centre = Vector((0.0, face_at(fraction) - depth * 0.5, at(fraction)))
        return ring(centre,
                    Vector((fit["half_width"] * width_scale, 0.0, 0.0)),
                    Vector((0.0, depth * 0.5, 0.0)),
                    profile)

    add_loft(bm, [section(*entry) for entry in BODY_SECTIONS], CANVAS)
    add_loft(bm, [section(*entry) for entry in LID_SECTIONS], LEATHER)

    def rear_at(fraction):
        """Follow the rear surface, interpolating the body's depth scale."""
        scale = BODY_SECTIONS[-1][2]
        for (low, _, low_depth), (high, _, high_depth) in zip(BODY_SECTIONS, BODY_SECTIONS[1:]):
            if low <= fraction <= high:
                blend = (fraction - low) / (high - low)
                scale = low_depth + (high_depth - low_depth) * blend
                break
        return face_at(fraction) - fit["depth"] * scale

    # Closing flap tongue, tracking the rear surface so it neither sinks in nor
    # stands off as the pack tapers.
    tongue = [(0.0, rear_at(f) + 0.004, at(f)) for f in
              (0.905, 0.840, 0.760, 0.680, 0.615)]
    add_path_loft(bm, catmull_rom(tongue, 9),
                  [(0.034, 0.008)] * 9, LEATHER, wide_hint=(1.0, 0.0, 0.0),
                  segments=10)
    buckle_z = at(0.628)
    add_box(bm, (-0.021, rear_at(0.628) - 0.012, buckle_z - 0.017),
            (0.021, rear_at(0.628) + 0.010, buckle_z + 0.017), METAL)

    # Shoulder straps: out of the pack's top, over the shoulder beside the head,
    # then down the chest. Every waypoint past the anchor is a ray hit on the
    # character, so the strap lies on the body instead of through it.
    cross = fit["cross_x"]
    for side in (-1.0, 1.0):
        def over(x, y):
            return character_ref.ray_to_surface(
                body, (side * x, y, 1.9), (0.0, 0.0, -1.0), STRAP_STANDOFF)

        def onto_chest(x, z):
            return character_ref.ray_to_surface(
                body, (side * x, 0.8, z), (0.0, -1.0, 0.0), STRAP_STANDOFF)

        def onto_back(x, z):
            return character_ref.ray_to_surface(
                body, (side * x, -0.8, z), (0.0, 1.0, 0.0), STRAP_STANDOFF)

        crest = fit["crest_z"]
        # The rear of the shoulder is lower than the top of the pack, so the run up
        # the back is pinned just under it. Leaving the strap to climb to the pack's
        # top first makes it rise, dip and rise again in a visible kink.
        rear = over(cross, -0.090)

        # Enough waypoints that the spline through them stays on the skin; too few
        # and it cuts the corner over the shoulder and stands off in a loop.
        anchor_z = rear.z - 0.008
        route = [
            # Anchored inside the pack, low enough that the lid hides the join.
            Vector((side * fit["half_width"] * 0.80,
                    face_at(fraction_of(anchor_z)) - 0.030, anchor_z)),
            onto_back(0.115, rear.z - 0.014),
            onto_back(0.170, rear.z - 0.008),
            rear,
            over(cross, -0.030),
            over(cross, 0.030),
            over(cross * 0.96, 0.085),
            onto_chest(cross * 0.80, crest - 0.055),
            onto_chest(cross * 0.56, crest - 0.110),
            onto_chest(0.100, crest - 0.180),
        ]
        count = 30
        centres = catmull_rom(route, count)
        # Widest and thickest across the shoulder, where a strap is padded, tapering
        # to plain webbing at the anchor and the chest.
        sections = []
        for i in range(count):
            swell = math.sin(math.pi * i / (count - 1.0))
            sections.append((0.030 + 0.014 * swell, 0.006 + 0.004 * swell))
        add_path_loft(bm, centres, sections, LEATHER, wide_hint=(1.0, 0.0, 0.0),
                      segments=10)
        # Sternum buckle, a plate clasped around the strap above its tail.
        index = int(count * 0.85)
        buckle, half_wide = centres[index], sections[index][0]
        add_box(bm, (buckle.x - half_wide - 0.005, buckle.y - 0.012, buckle.z - 0.016),
                (buckle.x + half_wide + 0.005, buckle.y + 0.012, buckle.z + 0.016),
                METAL)

    # Grab handle across the top of the lid.
    # Ends sunk into the lid, crest standing clear of it - keep the arc shallower
    # and it reads as a slot pressed into the leather rather than a handle.
    handle = [(-0.042, rear_at(0.985) + 0.030, at(1.012)),
              (-0.022, rear_at(0.985) + 0.036, at(1.112)),
              (0.022, rear_at(0.985) + 0.036, at(1.112)),
              (0.042, rear_at(0.985) + 0.030, at(1.012))]
    add_path_loft(bm, catmull_rom(handle, 14), [(0.012, 0.008)] * 14, LEATHER,
                  wide_hint=(0.0, 1.0, 0.0), segments=10)

    # Side compression rivets, purely to break up the canvas.
    for side in (-1.0, 1.0):
        for fraction in (0.34, 0.60):
            x = side * fit["half_width"] * 0.99
            y = face_at(fraction) - fit["depth"] * 0.5
            add_cylinder(bm, (x, y, at(fraction)), (x + side * 0.008, y, at(fraction)),
                         0.012, METAL, 12)

    return new_object("Backpack", bm, SLOTS, bevel_width=BEVEL_WIDTH,
                      smooth_angle=SMOOTH_ANGLE,
                      origin=(0.0, 0.0, fit["mount_z"]))


def main():
    reset_scene()
    rig, body, snapshot = character_ref.import_character()
    fit = measure_back(body, rig)

    print("fitted to the character's back:")
    print("  spans z {0:.3f}..{1:.3f} ({2:.3f} m tall)".format(
        fit["bottom"], fit["top"], fit["top"] - fit["bottom"]))
    print("  front face y={0:.3f} (back surface + {1:.3f} embed)".format(
        fit["front"], EMBED))
    print("  {0:.3f} m wide, protrudes {1:.3f} m".format(
        fit["half_width"] * 2.0, fit["depth"]))
    print("  straps cross the shoulder at x={0:.3f}, z={1:.3f}".format(
        fit["cross_x"], fit["crest_z"]))
    print("  origin on UpperChest at z={0:.3f}".format(fit["mount_z"]))

    ensure_materials(MATERIALS)
    pack = build(fit, body)
    character_ref.discard_since(snapshot, keep=[pack])
    print("Backpack polys={0} exported={1}".format(
        len(pack.data.polygons), evaluated_polys(pack)))

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export_selected([pack], GLB_PATH)


if __name__ == "__main__":
    main()
