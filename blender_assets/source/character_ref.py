"""Measures the player character asset, for anything that has to fit the player.

`blender_assets/player_character.glb` is the source of truth. Props read their
fit from it rather than from proportion tables, so hand-editing
`player_character.blend` and re-exporting is enough to keep dependent props
correct - there is no second copy of the character's dimensions to update.

A hand is located from its **skin weights**, not from a bounding box: the mitten
flares wide around the wrist, so the box centre sits well above the part a grip
should actually pass through.
"""

import os

import bpy
from mathutils import Vector

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
ASSET_DIR = os.path.abspath(os.path.join(SOURCE_DIR, os.pardir))
CHARACTER_GLB = os.path.join(ASSET_DIR, "player_character.glb")

HANDS = ("RightHand", "LeftHand")
WEIGHT_THRESHOLD = 0.5

# Used when the character asset is missing, so a prop build still produces
# something rather than failing outright. Matches the asset as of writing.
FALLBACK = {
    "forward": Vector((0.0, 1.0, 0.0)),
    "height": 1.446,
    "hands": {
        hand: {
            "length": 0.1249,
            "grip_fraction": 0.66,
            "radius_mean": 0.063,
            "radius_max": 0.086,
        } for hand in HANDS
    },
}

_TRACKED = ("objects", "meshes", "armatures", "actions", "materials", "images")


def _snapshot():
    return {name: set(getattr(bpy.data, name)) for name in _TRACKED}


def discard_since(snapshot, keep=()):
    """Remove every datablock created since `snapshot`, sparing anything in `keep`.

    The character arrives with nine actions and its own materials; without this
    a prop's .blend would be saved carrying the whole character with it. `keep` is
    for props that had to be built while the character was still loaded, as
    anything measured off its surface must be.
    """
    for obj in set(bpy.data.objects) - snapshot["objects"] - set(keep):
        bpy.data.objects.remove(obj, do_unlink=True)
    for name in _TRACKED:
        if name == "objects":
            continue
        collection = getattr(bpy.data, name)
        for block in set(collection) - snapshot[name]:
            if block.users == 0:
                collection.remove(block)


def import_character(glb_path=CHARACTER_GLB):
    """Import the character and return (rig, body, snapshot).

    Pass the snapshot to `discard_since()` to take it back out again.
    """
    snapshot = _snapshot()
    bpy.ops.import_scene.gltf(filepath=glb_path)
    added = [obj for obj in bpy.data.objects if obj not in snapshot["objects"]]
    rig = next((obj for obj in added if obj.type == "ARMATURE"), None)
    if rig is None:
        raise RuntimeError("no armature in " + glb_path)
    # The body is the skinned mesh with vertex groups for the hands; the garments
    # are skinned too but do not reach the hands.
    candidates = [obj for obj in added if obj.type == "MESH" and obj.vertex_groups]
    body = max(candidates, key=lambda obj: len(obj.data.vertices))
    return rig, body, snapshot


def hand_fit(rig, body, hand, threshold=WEIGHT_THRESHOLD):
    """Where the fist is and how big it is, along and around the hand bone."""
    group = body.vertex_groups.get(hand)
    bone = rig.data.bones.get(hand)
    if group is None or bone is None:
        return None

    head = rig.matrix_world @ bone.head_local
    tail = rig.matrix_world @ bone.tail_local
    span = tail - head
    length = span.length
    axis = span.normalized()

    points = []
    for vert in body.data.vertices:
        for entry in vert.groups:
            if entry.group == group.index and entry.weight >= threshold:
                points.append(body.matrix_world @ vert.co)
                break
    if not points:
        return None

    centroid = sum(points, Vector()) / len(points)
    radials = [((point - head) - axis * (point - head).dot(axis)).length
               for point in points]
    return {
        "head": head,
        "tail": tail,
        "axis": axis,
        "length": length,
        "centroid": centroid,
        "grip_fraction": (centroid - head).dot(axis) / length,
        "radius_mean": sum(radials) / len(radials),
        "radius_max": max(radials),
        "verts": len(points),
    }


def ray_to_surface(body, origin, direction, standoff=0.0):
    """First surface hit from `origin` along `direction`, held `standoff` clear of it.

    Prefer this to nearest-point projection, which is ambiguous exactly where gear
    has to be fitted. Beside this character's head the top of the shoulder and the
    side of the head are nearly equidistant, so nearest point is a coin toss over
    which one a strap lands on, but a ray cast straight down can only hit the
    shoulder.
    """
    inverse = body.matrix_world.inverted()
    direction = Vector(direction).normalized()
    found, location, _, _ = body.ray_cast(
        inverse @ Vector(origin), (inverse.to_3x3() @ direction).normalized())
    if not found:
        return None
    return (body.matrix_world @ location) - direction * standoff


def torso_profile(body, heights, band=0.03, arm_cutoff=0.16):
    """The torso's front, back and half width at each height, in metres.

    Read from raw geometry rather than from skin weights: the body is decimated
    hard enough that only a dozen torso vertices carry a dominant weight from any
    one spine bone, and none at all above the chest, which is far too sparse to
    describe a surface. `arm_cutoff` drops vertices out past the shoulders so the
    arms do not widen the profile.
    """
    points = [body.matrix_world @ vert.co for vert in body.data.vertices]
    profile = []
    for height in heights:
        band_points = [p for p in points
                       if abs(p.z - height) <= band and abs(p.x) <= arm_cutoff]
        if not band_points:
            profile.append(None)
            continue
        profile.append({
            "height": height,
            "back": min(p.y for p in band_points),
            "front": max(p.y for p in band_points),
            "half_width": max(abs(p.x) for p in band_points),
            "verts": len(band_points),
        })
    return profile


def arm_drop(rig, side="Right"):
    """Shoulder, elbow, wrist and fingertip heights with the arm hanging straight down.

    The rest pose holds the arms out in an A-pose - this character's upper arm leaves
    the shoulder at about 55 degrees below horizontal - so no arm joint's rest
    position is where it sits on a standing figure. Work surface heights are set from
    elbow height, so it has to be derived by dropping the bone lengths from the
    shoulder rather than read off the pose.
    """
    names = [side + part for part in ("UpperArm", "LowerArm", "Hand")]
    bones = [rig.data.bones.get(name) for name in names]
    missing = [name for name, bone in zip(names, bones) if bone is None]
    if missing:
        raise RuntimeError("rig has no " + ", ".join(missing))

    def length(bone):
        return ((rig.matrix_world @ bone.tail_local)
                - (rig.matrix_world @ bone.head_local)).length

    upper, lower, hand = bones
    shoulder = (rig.matrix_world @ upper.head_local).z
    elbow = shoulder - length(upper)
    wrist = elbow - length(lower)
    return {"shoulder": shoulder, "elbow": elbow, "wrist": wrist,
            "fingertip": wrist - length(hand)}


def facing(rig):
    """The character's forward, read off the rig rather than assumed, so a
    changed export orientation shows up instead of silently inverting props."""
    heel = rig.matrix_world @ rig.data.bones["RightFoot"].head_local
    toe = rig.matrix_world @ rig.data.bones["RightToes"].tail_local
    forward = toe - heel
    forward.z = 0.0
    return forward.normalized()


def grip_point(fit, fraction=None):
    """The point inside the fist that a grip's centre should sit at."""
    fraction = fit["grip_fraction"] if fraction is None else fraction
    return fit["head"] + (fit["tail"] - fit["head"]) * fraction


def measure(glb_path=CHARACTER_GLB, verbose=True):
    """Import the character, measure it, and take it back out of the scene."""
    if not os.path.exists(glb_path):
        print("character asset missing at {0}; using fallback measurements".format(glb_path))
        return dict(FALLBACK)

    rig, body, snapshot = import_character(glb_path)
    height = max((body.matrix_world @ vert.co).z for vert in body.data.vertices)
    result = {
        "forward": facing(rig),
        "height": height,
        "hands": {hand: hand_fit(rig, body, hand) for hand in HANDS},
    }
    if verbose:
        print("measured {0}".format(os.path.basename(glb_path)))
        print("  body {0} verts, {1:.3f} m to the crown, forward ({2:.3f}, {3:.3f}, {4:.3f})".format(
            len(body.data.vertices), height, *result["forward"]))
        for hand, fit in result["hands"].items():
            if fit is None:
                print("  {0}: not weighted".format(hand))
                continue
            print("  {0}: bone {1:.4f} m, fist {2} verts at {3:.3f} along it, "
                  "radius mean {4:.4f} max {5:.4f}".format(
                      hand, fit["length"], fit["verts"], fit["grip_fraction"],
                      fit["radius_mean"], fit["radius_max"]))
    discard_since(snapshot)
    return result
