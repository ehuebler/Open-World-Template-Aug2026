"""Derives wearable apparel from the rigged player character.

Run headless from the project root, using the Blender version that saved the
.blend (opening a newer file in an older Blender drops data):

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background assets/source/blender/player_character.blend --python assets/source/blender/build_apparel.py

Each garment is cut out of a copy of the body mesh, pushed outward along its
normals and solidified into a shell. Because the vertices are copies of body
vertices they arrive with the body's skin weights already on them, so a garment
deforms exactly like the body underneath and needs no separate rigging or weight
transfer. Hems are placed from bone positions rather than fixed heights, so the
script keeps working after the body is reproportioned.

The script rewrites the .blend in place (Blender keeps the previous version as
player_character.blend1) and writes one .glb per garment beside the body asset.
It deliberately does not export player_character.glb: that file has to come from
build_animations.py, which is what puts the locomotion clips into it.

Garments carry no animation of their own. They export with the same 23 joints in
the same order as the body, so in Godot each garment's MeshInstance3D can be
reparented onto the body's Skeleton3D and is then driven by the body's clips.
"""

import math
import os

import bpy
import bmesh
from mathutils import Vector
from mathutils.bvhtree import BVHTree

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
ASSET_DIR = os.path.join(PROJECT_DIR, "assets", "runtime", "apparel")

BODY_NAME = "Character"
RIG_NAME = "CharacterRig"
APPAREL_COLLECTION = "Apparel"

# The body was authored with the right side as the good side, so symmetry work
# mirrors +X onto -X. Set either flag to False to leave that part of the body
# alone on a re-run.
SYMMETRISE_BODY = True
FLATTEN_BODY_MATERIAL = True

BODY_MATERIAL_NAME = "CharacterBody"
BODY_COLOR = (0.723, 0.700, 0.664, 1.0)

# Garments keep full derived density; the body's own Decimate is not inherited.
# Raise a slug's entry above 0 to thin one down, e.g. {"long_sleeve": 0.35}.
DECIMATE_RATIOS = {}

# How far a hem flange continues past the skin, so the fold closes against the
# body instead of leaving a gap at the opening. It has to clear the distance
# the shipped body stands outside the base mesh the flange was measured
# against, which the build reports and which is 2.1 mm — at the 2 mm this was,
# the fold closed exactly on that line and roughly half the rim lost, so every
# opening in the wardrobe wore a comb of bare skin one mesh edge deep. Deeper
# costs nothing: the flange is inside the body either way.
HEM_BURY = 0.010



# --------------------------------------------------------------------------
# Context helpers
# --------------------------------------------------------------------------

def ensure_object_mode():
    """The .blend can be saved in Weight Paint mode, which fails operator polls."""
    for obj in bpy.data.objects:
        if obj.mode != "OBJECT":
            bpy.context.view_layer.objects.active = obj
            try:
                bpy.ops.object.mode_set(mode="OBJECT")
            except RuntimeError as error:
                print("could not leave {0} mode on {1}: {2}".format(obj.mode, obj.name, error))


def activate(obj):
    view_layer = bpy.context.view_layer
    for other in view_layer.objects:
        other.select_set(False)
    obj.hide_viewport = False
    obj.select_set(True)
    view_layer.objects.active = obj


def flipped_name(name):
    if name.startswith("Left"):
        return "Right" + name[len("Left"):]
    if name.startswith("Right"):
        return "Left" + name[len("Right"):]
    return name


def mirror_x(vector):
    return Vector((-vector.x, vector.y, vector.z))


def ramp(value, low, high):
    if high <= low:
        return 0.0
    return max(0.0, min(1.0, (value - low) / (high - low)))


# --------------------------------------------------------------------------
# Body clean-up
# --------------------------------------------------------------------------

def symmetrise_bones(rig):
    """Mirror every Right* bone onto its Left* twin and centre the spine chain."""
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    edit_bones = rig.data.edit_bones

    centre_chain = [bone.name for bone in edit_bones
                    if not bone.name.startswith(("Left", "Right"))]
    for name in centre_chain:
        bone = edit_bones[name]
        bone.head.x = 0.0
        bone.tail.x = 0.0

    mirrored = 0
    for bone in edit_bones:
        if not bone.name.startswith("Right"):
            continue
        twin = edit_bones.get(flipped_name(bone.name))
        if twin is None:
            continue
        twin.head = mirror_x(bone.head)
        twin.tail = mirror_x(bone.tail)
        mirrored += 1

    # Consistent roll makes left and right respond identically to the same
    # rotation, which matters once the rig is animated.
    bpy.ops.armature.select_all(action="SELECT")
    bpy.ops.armature.calculate_roll(type="GLOBAL_POS_Y")
    bpy.ops.object.mode_set(mode="OBJECT")
    print("symmetrised {0} bone pairs, centred {1} spine bones".format(
        mirrored, len(centre_chain)))


def symmetrise_mesh(body):
    """Keep the +X half of the body and mirror it, flipping Left/Right weights."""
    group_flip = {}
    for group in body.vertex_groups:
        twin = body.vertex_groups.get(flipped_name(group.name))
        group_flip[group.index] = twin.index if twin else group.index

    bm = bmesh.new()
    bm.from_mesh(body.data)
    deform = bm.verts.layers.deform.verify()

    bmesh.ops.bisect_plane(
        bm,
        geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
        plane_co=(0.0, 0.0, 0.0),
        plane_no=(1.0, 0.0, 0.0),
        clear_inner=False,
        clear_outer=False,
    )
    doomed = [vert for vert in bm.verts if vert.co.x < -1.0e-6]
    if doomed:
        bmesh.ops.delete(bm, geom=doomed, context="VERTS")

    duplicate = bmesh.ops.duplicate(
        bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces))
    new_verts = [item for item in duplicate["geom"] if isinstance(item, bmesh.types.BMVert)]
    new_faces = [item for item in duplicate["geom"] if isinstance(item, bmesh.types.BMFace)]

    for vert in new_verts:
        vert.co.x = -vert.co.x
        weights = dict(vert[deform])
        vert[deform].clear()
        for index, weight in weights.items():
            vert[deform][group_flip.get(index, index)] = weight
    bmesh.ops.reverse_faces(bm, faces=new_faces)

    seam = [vert for vert in bm.verts if abs(vert.co.x) < 1.0e-4]
    bmesh.ops.remove_doubles(bm, verts=seam, dist=1.0e-4)

    bm.to_mesh(body.data)
    bm.free()
    body.data.update()
    print("mirrored body mesh: {0} polys".format(len(body.data.polygons)))


def flatten_body_material(body):
    """Collapse the suit/accent split into a single flat base colour."""
    material = bpy.data.materials.get(BODY_MATERIAL_NAME)
    if material is None:
        material = bpy.data.materials.new(BODY_MATERIAL_NAME)
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = BODY_COLOR
    bsdf.inputs["Roughness"].default_value = 0.68

    body.data.materials.clear()
    body.data.materials.append(material)
    for polygon in body.data.polygons:
        polygon.material_index = 0
    print("flattened body to a single material: {0}".format(BODY_MATERIAL_NAME))


# --------------------------------------------------------------------------
# Landmarks
# --------------------------------------------------------------------------

class Landmarks:
    """Body reference points read from the rig, so hems follow the anatomy."""

    def __init__(self, body, rig):
        bones = rig.data.bones
        self.ankle = bones["RightFoot"].head_local.copy()
        self.toe = bones["RightToes"].tail_local.copy()
        self.knee = bones["RightLowerLeg"].head_local.copy()
        self.hip = bones["Hips"].head_local.copy()
        self.waist = bones["Hips"].tail_local.copy()
        self.neck = bones["Neck"].head_local.copy()
        self.skull = bones["Head"].head_local.copy()
        self.shoulder = bones["RightUpperArm"].head_local.copy()
        self.elbow = bones["RightLowerArm"].head_local.copy()
        self.wrist = bones["RightHand"].head_local.copy()

        heights = [vert.co.z for vert in body.data.vertices]
        self.top = max(heights)
        self.floor = min(heights)
        # Widest the skull gets, which is what anything worn on the face is
        # spaced against: the two bodies' heads are within a centimetre in
        # height and five apart in width, so height is the wrong ruler for it.
        self.head_width = max((abs(vert.co.x) for vert in body.data.vertices
                               if vert.co.z > self.skull.z), default=0.1)

    @property
    def arm_chain(self):
        return [self.shoulder, self.elbow, self.wrist]

    @property
    def wrist_axis(self):
        return (self.wrist - self.elbow).normalized()


def near_z(height, band, half_width=None):
    def test(point):
        if abs(point.z - height) > band:
            return False
        return half_width is None or abs(point.x) < half_width
    return test


def near_point(centre, radius):
    def test(point):
        return (point - centre).length < radius
    return test


def distance_to_chain(point, nodes):
    best = float("inf")
    for start, end in zip(nodes, nodes[1:]):
        span = end - start
        length_squared = span.length_squared
        if length_squared < 1.0e-12:
            best = min(best, (point - start).length)
            continue
        along = max(0.0, min(1.0, (point - start).dot(span) / length_squared))
        best = min(best, (point - (start + span * along)).length)
    return best


# --------------------------------------------------------------------------
# Garment definitions
# --------------------------------------------------------------------------

def goggles_spec(landmarks, slug="goggles", name="ApparelGoggles",
                 colour=(0.290, 0.203, 0.098, 1.0), roughness=0.34):
    """A strap round the head swelling into a lens over each eye.

    A function taking a slug rather than another row in `garment_specs`, because
    both bodies want a pair and `build_character_3.py` asks for it by name.
    Every measurement is a fraction of the head's own height, which is what lets
    one call fit both: the two characters differ by 15 cm of body and 7 mm of
    skull, so anything written against the *figure* would come out a size wrong
    on one of them and anything written in metres a size wrong on both.

    The strap is deliberately thinner than the hat's shell and the lenses
    thicker. Both garments cover this band — the hat's brim is a quarter of the
    way up the skull and everything above it is inside the cap — so worn
    together the strap tucks under the hat and the lenses stand out through it,
    which is where a pair of goggles under a cap sits anyway. Worn without one
    the whole thing reads.
    """
    L = landmarks
    up = Vector((0.0, 0.0, 1.0))
    down = Vector((0.0, 0.0, -1.0))
    skull = L.top - L.skull.z
    low = L.skull.z + skull * 0.28
    high = L.skull.z + skull * 0.44
    mid = (low + high) * 0.5
    # An eye a little under halfway out, and a lens a little over a third of the
    # head wide. The lens is wider than the band is tall, so it comes out as an
    # oval cut off top and bottom by the strap, which is the shape of the thing.
    eye_x = L.head_width * 0.40
    lens = L.head_width * 0.34

    def region(point):
        # A band, and only across the head. At rest both bodies' hands hang far
        # below this, but a bare height test is one reproportioning away from
        # cutting somebody's knuckles out of the body and calling them eyewear.
        return low < point.z < high and abs(point.x) < skull

    def displace(point, normal):
        # A dome centred on each eye. Measuring the distance from |x| gets both
        # from one expression, and squaring the falloff makes it a dome rather
        # than the cone a linear one gives. Spreading the swell across the whole
        # front instead - a `face` term and a notch at the nose - is what the
        # first pass did, and it reads as a blindfold with a dent in it.
        offset = Vector((abs(point.x) - eye_x, 0.0, point.z - mid))
        # A plateau with a steep wall round it, not a dome. A dome has no
        # silhouette when it is pointing at the camera, which is the one view
        # that has to read, and a smooth shoulder gives the light nothing to
        # catch: both earlier passes came out as a flat strip across the eyes.
        # The wall is the outer quarter of the lens, which stands it at about
        # sixty degrees - past the EdgeSplit angle, so it creases.
        pod = min(1.0, max(0.0, (1.0 - offset.length / lens) * 4.0))
        # Front-facing by normal and not by y, because the two heads sit
        # differently against their own origins: the astronaut's reaches
        # furthest at +y and the settler's at -y, and a threshold in metres that
        # finds one body's face finds the other's cheekbone.
        facing = ramp(normal.y, 0.15, 0.60)
        # A lens has to clear the bridge of the nose as well as the strap, and
        # on a head this round the bridge is the front-most point of the whole
        # skull: at half the height below, the pods stood 29 mm off a face that
        # curved 32 mm away from them over the same span, and vanished. So the
        # standoff is read against the head's depth rather than chosen.
        return normal * skull * (0.024 + 0.150 * facing * pod)

    return {
        "slug": slug,
        "name": name,
        "colour": colour,
        "roughness": roughness,
        "region": region,
        "displace": displace,
        "post": None,
        "cuts": [
            (Vector((0.0, 0.0, high)), up, near_z(high, skull * 0.14)),
            (Vector((0.0, 0.0, low)), down, near_z(low, skull * 0.14)),
        ],
    }


def garment_specs(landmarks):
    L = landmarks
    # Hem normals point out of the garment, which is the direction the shell is
    # not allowed to cross.
    up = Vector((0.0, 0.0, 1.0))
    down = Vector((0.0, 0.0, -1.0))
    right_chain = L.arm_chain
    left_chain = [mirror_x(node) for node in right_chain]
    wrists = ((L.wrist, L.wrist_axis), (mirror_x(L.wrist), mirror_x(L.wrist_axis)))

    def past_wrist(point):
        for wrist, axis in wrists:
            offset = point - wrist
            if offset.length < 0.30 and offset.dot(axis) > 0.0:
                return True
        return False

    def arm_distance(point):
        return min(distance_to_chain(point, right_chain),
                   distance_to_chain(point, left_chain))

    def wrist_distance(point):
        return min((point - wrist).length for wrist, _ in wrists)

    # The shoe collar sits above the trouser cuff so the cuff hides its rim.
    shoe_top = L.ankle.z + 0.075

    def shoe_region(point):
        return point.z < shoe_top

    def shoe_displace(point, normal):
        # Thicker toward the sole, which reads as a heel. The extra over the
        # old 20 mm is for the ankle: a crouch folds the foot up against the
        # shin and the shoe's own instep has further to travel than the skin
        # inside it, so the two crossed by 17 mm at the toe box.
        return normal * (0.024 + 0.010 * (1.0 - ramp(point.z, 0.0, 0.05)))

    def shoe_post(point):
        # Anything pushed under the floor becomes a flat sole resting on it.
        return Vector((point.x, point.y, max(point.z, 0.0)))

    pants_hem = L.ankle.z + 0.055
    pants_waist = L.waist.z + 0.022

    def pants_region(point):
        return abs(point.x) < 0.32 and pants_hem < point.z < pants_waist

    def pants_displace(point, normal):
        # 23 mm base, and all of the rise over the old 17 mm is the knee: a
        # shell and the body under it carry the same skin weights but sit a
        # couple of centimetres apart, so a joint that folds shortens the
        # outside of the garment more than the skin it covers and the two
        # cross once the gap runs out — 19 mm behind the knee in a crouch. The
        # cuff sits proud of the shoe so the trouser leg covers the shoe top.
        cuff = 1.0 - ramp(point.z, pants_hem, pants_hem + 0.12)
        band = ramp(point.z, pants_waist - 0.05, pants_waist)
        return normal * (0.023 + 0.012 * cuff + 0.005 * band)

    sleeve_hem = L.waist.z - 0.075
    # Seven tenths of the way up the neck, and the fraction is the whole point:
    # a hem is cut by a plane, and a horizontal plane laid across a surface that
    # is itself nearly horizontal does not cut a circle in it — it wanders over
    # the quad grid a face at a time and comes out as a sawtooth. At the old
    # 50 mm above the neck the collar sat on the shelf where the shoulders run
    # into the throat, which `dev/_probe_neck.py` measures as the most up-facing
    # band on the body, and the neckline was visibly torn in every pose. Up here
    # the neck is a wall and the same cut is a clean ring.
    sleeve_collar = L.neck.z + (L.skull.z - L.neck.z) * 0.70

    def sleeve_region(point):
        if past_wrist(point):
            return False
        if point.z > sleeve_collar:
            return False
        torso = abs(point.x) < 0.34 and point.z > sleeve_hem
        return torso or arm_distance(point) < 0.17

    def sleeve_displace(point, normal):
        # The thinnest of these at 14 mm, and the one that showed: the run
        # pose twists the chest under a collar cut across the widest part of
        # it, and the skin came through the neckline as a torn grey bib. The
        # shoulder gets more again, because it is the joint with the largest
        # swing and the shell there has the least room to give. The hem has to
        # clear the trouser waistband it hangs over, which is 28 mm.
        #
        # `Fall` joining the measured clips put one vertex at 22.7 mm, beside the
        # hip, where the swept-back arms now hold - which is this number sitting on
        # its own limit rather than ahead of it. One vertex at seven tenths of a
        # millimetre is under anything anybody can see, so it is left at 22 and
        # written down instead: the next thing that widens a held pose around the
        # hips should expect to pay for it here, at 24.
        hem = 1.0 - ramp(point.z, sleeve_hem, sleeve_hem + 0.09)
        cuff = 1.0 - ramp(wrist_distance(point), 0.06, 0.17)
        collar = ramp(point.z, sleeve_collar - 0.20, sleeve_collar)
        return normal * (0.022 + 0.012 * hem + 0.006 * cuff + 0.008 * collar)

    brim = L.skull.z + (L.top - L.skull.z) * 0.26

    def hat_region(point):
        return point.z > brim

    def hat_displace(point, normal):
        lift = ramp(point.z, brim, L.top)
        rolled_brim = 1.0 - ramp(point.z, brim, brim + 0.035)
        amount = 0.021 + 0.005 * lift + 0.009 * rolled_brim
        # Raising the crown keeps it a hat instead of a painted-on scalp.
        return normal * amount + Vector((0.0, 0.0, 0.030 * lift ** 1.5))

    return [
        {
            "slug": "shoes",
            "name": "ApparelShoes",
            "colour": (0.180, 0.140, 0.120, 1.0),
            "roughness": 0.52,
            "region": shoe_region,
            "displace": shoe_displace,
            "post": shoe_post,
            "cuts": [(Vector((0.0, 0.0, shoe_top)), up, near_z(shoe_top, 0.07))],
        },
        {
            "slug": "pants",
            "name": "ApparelPants",
            "colour": (0.216, 0.278, 0.404, 1.0),
            "roughness": 0.74,
            "region": pants_region,
            "displace": pants_displace,
            "post": None,
            "cuts": [
                (Vector((0.0, 0.0, pants_waist)), up, near_z(pants_waist, 0.07, 0.36)),
                (Vector((0.0, 0.0, pants_hem)), down, near_z(pants_hem, 0.07, 0.36)),
            ],
        },
        {
            "slug": "long_sleeve",
            "name": "ApparelLongSleeve",
            "colour": (0.588, 0.259, 0.235, 1.0),
            "roughness": 0.78,
            "region": sleeve_region,
            "displace": sleeve_displace,
            "post": None,
            "cuts": [
                (Vector((0.0, 0.0, sleeve_collar)), up, near_z(sleeve_collar, 0.06, 0.36)),
                (Vector((0.0, 0.0, sleeve_hem)), down, near_z(sleeve_hem, 0.06, 0.36)),
            ] + [(wrist, axis, near_point(wrist, 0.20)) for wrist, axis in wrists],
        },
        {
            "slug": "hat",
            "name": "ApparelHat",
            "colour": (0.792, 0.596, 0.212, 1.0),
            "roughness": 0.72,
            "region": hat_region,
            "displace": hat_displace,
            "post": None,
            "cuts": [(Vector((0.0, 0.0, brim)), down, near_z(brim, 0.06))],
        },
        goggles_spec(landmarks),
    ]


# --------------------------------------------------------------------------
# Garment construction
# --------------------------------------------------------------------------

def apparel_collection():
    collection = bpy.data.collections.get(APPAREL_COLLECTION)
    if collection is None:
        collection = bpy.data.collections.new(APPAREL_COLLECTION)
        bpy.context.scene.collection.children.link(collection)
    return collection


def fold_hems(bm, planes, anchors):
    """Extrude every open hem back toward the skin, staying in the hem plane.

    This gives the garment a visible edge thickness without a full lining, and
    keeping the flange in the hem plane is what makes the hem read as a straight
    fold rather than a torn edge.

    Each flange retraces the path its own vertex took when the shell was offset
    outward, landing HEM_BURY past the skin so the fold closes against the body:
    stopping short leaves a gap at the opening that you can see into. Retracing
    the recorded offset rather than the vertex normal matters, because the body
    has a few inverted faces whose normals would fling the flange outward into a
    visible flap.
    """
    boundary = [edge for edge in bm.edges if edge.is_boundary]
    if not boundary:
        return
    rim = {vert for edge in boundary for vert in edge.verts}

    result = bmesh.ops.extrude_edge_only(bm, edges=boundary)
    for vert in [item for item in result["geom"] if isinstance(item, bmesh.types.BMVert)]:
        partners = [edge.other_vert(vert) for edge in vert.link_edges
                    if edge.other_vert(vert) in rim]
        if not partners:
            continue
        partner = partners[0]
        skin = anchors.get(partner)
        if skin is None:
            continue
        inward = skin - partner.co
        vert.co = skin + inward.normalized() * HEM_BURY if inward.length > 1.0e-9 else skin

        nearest = None
        for origin, axis in planes:
            distance = abs((partner.co - origin).dot(axis))
            if nearest is None or distance < nearest[0]:
                nearest = (distance, origin, axis)
        if nearest is not None and nearest[0] < 0.006:
            _, origin, axis = nearest
            vert.co -= axis * (vert.co - origin).dot(axis)


def carve_shell(obj, spec):
    """Reduce the body copy to the garment region, then offset and shape it."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)

    # Slice edge loops along every hem first. Deleting whole faces against a
    # plane would leave the hem zig-zagging across the isotropic body mesh.
    for point, normal, limit in spec.get("cuts", ()):
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

    bm.normal_update()
    unwanted = [face for face in bm.faces if not spec["region"](face.calc_center_median())]
    if len(unwanted) == len(bm.faces):
        bm.free()
        raise SystemExit("{0}: region selected no faces".format(spec["slug"]))
    if unwanted:
        bmesh.ops.delete(bm, geom=unwanted, context="FACES")

    loose = [vert for vert in bm.verts if not vert.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")

    # Remember which boundary vertices sit on each hem plane. Offsetting along
    # per-vertex normals would otherwise bend a flat hem wherever the body
    # curves, which is very visible at the trouser cuffs above the feet.
    planes = [(Vector(point), Vector(normal).normalized())
              for point, normal, _ in spec.get("cuts", ())]
    hems = []
    for vert in bm.verts:
        if not any(edge.is_boundary for edge in vert.link_edges):
            continue
        nearest = None
        for origin, axis in planes:
            distance = abs((vert.co - origin).dot(axis))
            # Generous tolerance: bisect leaves vertices a hair off the plane,
            # and a tight test would skip some and leave a fringed hem.
            if distance < 0.006 and (nearest is None or distance < nearest[0]):
                nearest = (distance, origin, axis)
        if nearest is not None:
            hems.append((vert, nearest[1], nearest[2]))

    bm.normal_update()
    displace = spec["displace"]
    post = spec["post"]
    anchors = {}
    moved = []
    for vert in bm.verts:
        anchors[vert] = vert.co.copy()
        moved.append((vert, vert.co + displace(vert.co.copy(), vert.normal.copy())))
    for vert, position in moved:
        vert.co = position

    for vert, origin, axis in hems:
        vert.co -= axis * (vert.co - origin).dot(axis)

    # Turn each hem into a flange folded back toward the skin. Solidifying the
    # whole garment instead pushes the lining along boundary vertex normals,
    # which at an open hem tilt away from the garment and leave it hanging past
    # the hem as a ragged fringe of teeth.
    bm.normal_update()
    fold_hems(bm, planes, anchors)

    if post:
        for vert in bm.verts:
            vert.co = post(vert.co.copy())

    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.normal_update()
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def build_garment(body, rig, spec, collection):
    existing = bpy.data.objects.get(spec["name"])
    if existing is not None:
        bpy.data.objects.remove(existing, do_unlink=True)

    obj = body.copy()
    obj.data = body.data.copy()
    obj.name = spec["name"]
    obj.data.name = spec["name"] + "Mesh"
    obj.modifiers.clear()
    collection.objects.link(obj)

    carve_shell(obj, spec)

    material = bpy.data.materials.get(spec["name"]) or bpy.data.materials.new(spec["name"])
    material.use_nodes = True
    bsdf = material.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = spec["colour"]
    bsdf.inputs["Roughness"].default_value = spec["roughness"]
    obj.data.materials.clear()
    obj.data.materials.append(material)
    for polygon in obj.data.polygons:
        polygon.material_index = 0

    ratio = DECIMATE_RATIOS.get(spec["slug"], 0.0)
    if ratio > 0.0:
        decimate = obj.modifiers.new("Decimate", "DECIMATE")
        decimate.decimate_type = "COLLAPSE"
        decimate.ratio = ratio

    # Keeps the hems crisp while the garment body stays smooth.
    split = obj.modifiers.new("EdgeSplit", "EDGE_SPLIT")
    split.use_edge_angle = True
    split.split_angle = math.radians(40.0)
    split.use_edge_sharp = True

    armature = obj.modifiers.new("Armature", "ARMATURE")
    armature.object = rig
    obj.parent = rig

    activate(obj)
    bpy.ops.object.shade_smooth()
    return obj


# --------------------------------------------------------------------------
# Export
# --------------------------------------------------------------------------

def export(objects, path):
    # Unhide before selecting, in two passes: writing hide_viewport resyncs the
    # view layer and can clear the selection made so far, which silently exports
    # a garment .glb holding nothing but the armature.
    view_layer = bpy.context.view_layer
    for obj in objects:
        obj.hide_viewport = False
    for obj in view_layer.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    view_layer.objects.active = objects[0]

    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_skins=True,
        export_animations=False,
        export_yup=True,
    )
    print("wrote {0} ({1:.1f} KB)".format(path, os.path.getsize(path) / 1024.0))


def evaluated_polys(obj):
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh = evaluated.to_mesh()
    count = len(mesh.polygons)
    evaluated.to_mesh_clear()
    return count


def base_tree(body):
    """A BVH of the body as the shells are cut from it, before its modifiers."""
    bm = bmesh.new()
    bm.from_mesh(body.data)
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    return tree


def set_pose_position(rig, position):
    """Stand the rig in its rest pose, or put it back on its animation.

    The depsgraph does not hand back a body in its rest shape unless it is
    asked: it hands back whatever pose the .blend was saved holding, which
    after a bake is the last frame of the last clip, and measured through that
    the astronaut's sleeve reported 373 mm of bare skin — all of it an arm that
    had swung out from under it.

    It has to be done here rather than by switching the body's Armature
    modifier off, even though that is the obvious way: the Decimate sits after
    it, and a collapse fed different geometry returns a different *topology*,
    so a per-vertex mask taken with the modifier off indexes a mesh that no
    longer exists once it is on.
    """
    previous = rig.data.pose_position
    rig.data.pose_position = position
    bpy.context.view_layer.update()
    return previous


def hide_decimate(objects):
    """Take the body's Decimate out of the stack, and say what to put back.

    A per-vertex mask is the only cheap way to ask the same question of the
    same vertex in twenty different poses, and Decimate makes one impossible:
    it is a collapse, so posing the body before it changes which edges it
    chooses and the mesh that comes out has a different *topology* per frame.
    Index 400 is a shoulder at rest and a shin two frames later, and the
    measurement reads over a metre of poke-through on a garment that has none.

    Nothing is lost by dropping it here. What the collapse costs is measured
    against the rest pose by `poke_through`, and what this measures — a shell
    and the skin under it skinned apart at a fold — is a property of the
    weights, which the collapse does not touch.
    """
    hidden = [modifier for obj in objects for modifier in obj.modifiers
              if modifier.type == "DECIMATE" and modifier.show_viewport]
    for modifier in hidden:
        modifier.show_viewport = False
    bpy.context.view_layer.update()
    return hidden


def decimation_bulge(body, tree):
    """How far the shipped body stands outside the base mesh, at worst, in mm.

    This is the number every offset in the file has to clear. The shells are
    cut from the base mesh and the body ships decimated, and a collapse does
    not shrink a surface evenly — it cuts the corner off convexities and puts
    the error back on the outside.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    worst = 0.0
    for vertex in mesh.vertices:
        location, normal, _index, _distance = tree.find_nearest(vertex.co)
        if location is not None:
            worst = max(worst, (vertex.co - location).dot(normal))
    evaluated.to_mesh_clear()
    return worst * 1000.0


def covered_mask(body, spec, margin=0.018):
    """Which of the body's base vertices this garment is supposed to hide.

    Read off the base mesh, which is where the region tests are written and
    where the shell was cut. Vertices within `margin` of a hem are left out,
    because an opening is bare skin on purpose and the flange folded back
    through it is a face the nearest-point test would find.
    """
    planes = [(Vector(point), Vector(normal).normalized())
              for point, normal, _ in spec.get("cuts", ())]
    return [spec["region"](vertex.co)
            and not any(abs((vertex.co - origin).dot(axis)) < margin
                        for origin, axis in planes)
            for vertex in body.data.vertices]


def posed_poke(body, garment, mask):
    """How far the body stands outside the garment in whatever pose is set.

    A garment and the body under it carry the same skin weights but sit a
    couple of centimetres apart, and linear blend skinning does not preserve
    that gap: on the inside of a fold the outer surface has further to travel
    and arrives short, so the two cross. It is the only way these shells can
    clip at all — at rest they are the body pushed along its own normals and
    cannot — which is why a rest-pose render proves nothing.

    Faces whose normal disagrees with the skin's are skipped, so the hem
    flange folded back inside the body is not mistaken for the outside of the
    garment; without that filter a sleeve with no fault at all reported 147 mm.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    tree = BVHTree.FromObject(garment, depsgraph)
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    worst = 0.0
    culprit = -1
    showing = 0
    for index, vertex in enumerate(mesh.vertices):
        if not mask[index]:
            continue
        location, normal, _face, _distance = tree.find_nearest(vertex.co)
        if location is None or normal.dot(vertex.normal) < 0.3:
            continue
        depth = (vertex.co - location).dot(normal)
        if depth > 0.0:
            showing += 1
            if depth > worst:
                worst, culprit = depth, index
    evaluated.to_mesh_clear()
    return showing, worst * 1000.0, culprit


def pose_frame(rig, action, frame):
    rig.animation_data.action = action
    if hasattr(rig.animation_data, "action_slot") and action.slots:
        rig.animation_data.action_slot = action.slots[0]
    bpy.context.scene.frame_set(frame)


def fit_report(body, rig, specs, garments,
               clips=("Walk", "Run", "CrouchIdle", "JumpRise", "Fall", "HeroLand"),
               samples=5):
    """Worst interpenetration per garment over a few frames of the bendiest clips.

    `Fall` is here because it holds a pose rather than passing through one. It is
    the loosest clip on the list by joint angle, but it is also the only one a body
    can be in for ten seconds, so a sleeve that crosses a chest for two frames of a
    run and a sleeve that crosses it for the whole descent are not the same fault.
    """
    if rig.animation_data is None:
        return {}
    masks = [covered_mask(body, spec) for spec in specs]
    hidden = hide_decimate([body] + list(garments))
    held = rig.animation_data.action
    worst = {garment.name: (0, 0.0, "rest", "") for garment in garments}
    for name in clips:
        action = bpy.data.actions.get(name)
        if action is None:
            continue
        start, end = (int(value) for value in action.frame_range)
        for step in range(samples):
            frame = start + (end - start) * step // max(samples - 1, 1)
            pose_frame(rig, action, frame)
            for mask, garment in zip(masks, garments):
                showing, depth, culprit = posed_poke(body, garment, mask)
                if depth > worst[garment.name][1]:
                    at = body.data.vertices[culprit].co
                    worst[garment.name] = (
                        showing, depth, "%s@%d" % (name, frame),
                        "x%+.2f y%+.2f z%.2f" % (at.x, at.y, at.z))
    for modifier in hidden:
        modifier.show_viewport = True
    rig.animation_data.action = held
    bpy.context.scene.frame_set(int(bpy.context.scene.frame_start))
    bpy.context.view_layer.update()
    return worst


def poke_through(body, tree, spec):
    """How much of the body the garment fails to cover, in mm of clearance.

    Measured against the *base* mesh rather than against the finished garment,
    which is the only version of this that gives a number worth acting on. The
    shells are carved from the base body and offset along its normals, so a
    garment covers a vertex exactly when the offset there exceeds how far the
    shipped body has wandered outward from the mesh it was cut from — and it
    wanders because the body carries a Decimate, and a collapsed mesh cuts the
    corner off every convex bulge and puts it back somewhere else. Comparing
    the two meshes directly also sidesteps the hems: the flange folded back
    inside the body is a face like any other, so a nearest-point test against
    the finished garment reads every vertex around an opening as bare skin and
    reported 147 mm of poke-through on a sleeve that has none.

    Returns how many region vertices the body wins, how many were tested, and
    the worst shortfall.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    displace = spec["displace"]
    worst = 0.0
    showing = 0
    tested = 0
    for vertex in mesh.vertices:
        point = vertex.co.copy()
        if not spec["region"](point):
            continue
        location, normal, _index, _distance = tree.find_nearest(point)
        if location is None:
            continue
        tested += 1
        # What the shell was pushed out to here, against where the body ended up.
        offset = displace(location, normal.copy()).dot(normal)
        shortfall = (point - location).dot(normal) - offset
        if shortfall > 0.0:
            showing += 1
            worst = max(worst, shortfall)
    evaluated.to_mesh_clear()
    return showing, tested, worst * 1000.0


def main():
    ensure_object_mode()
    body = bpy.data.objects[BODY_NAME]
    rig = bpy.data.objects[RIG_NAME]

    if SYMMETRISE_BODY:
        symmetrise_bones(rig)
        symmetrise_mesh(body)
    if FLATTEN_BODY_MATERIAL:
        flatten_body_material(body)

    landmarks = Landmarks(body, rig)
    print("landmarks: floor={0:.3f} ankle={1:.3f} waist={2:.3f} neck={3:.3f} "
          "skull={4:.3f} top={5:.3f}".format(
              landmarks.floor, landmarks.ankle.z, landmarks.waist.z,
              landmarks.neck.z, landmarks.skull.z, landmarks.top))

    collection = apparel_collection()
    specs = garment_specs(landmarks)
    garments = [build_garment(body, rig, spec, collection) for spec in specs]

    print("---- apparel ----")
    tree = base_tree(body)
    previous = set_pose_position(rig, "REST")
    rest = [poke_through(body, tree, spec) for spec in specs]
    print("  decimation puts the body up to {0:.1f} mm outside the base mesh; "
          "hems bury {1:.1f} mm".format(decimation_bulge(body, tree), HEM_BURY * 1000.0))
    set_pose_position(rig, previous)
    posed = fit_report(body, rig, specs, garments)
    for spec, garment, (showing, tested, worst) in zip(specs, garments, rest):
        clipping, depth, where, at = posed.get(garment.name, (0, 0.0, "-", ""))
        print("  {0:22s} base={1:5d} exported={2:5d}  rest {3:3d}/{4:4d} verts "
              "{5:.1f} mm   posed {6:3d} verts {7:4.1f} mm at {8} {9}".format(
                  garment.name, len(garment.data.polygons), evaluated_polys(garment),
                  showing, tested, worst, clipping, depth, where, at))
    print("  {0:22s} base={1:5d} exported={2:5d}".format(
        body.name, len(body.data.polygons), evaluated_polys(body)))
    print("-----------------")

    bpy.ops.wm.save_mainfile()
    for spec, garment in zip(garment_specs(landmarks), garments):
        export([garment, rig], os.path.join(ASSET_DIR, "apparel_{0}.glb".format(spec["slug"])))

    if SYMMETRISE_BODY:
        print("\nThe rest pose changed, so the baked locomotion clips no longer\n"
              "match it. Re-run build_animations.py to rebake them and to write\n"
              "player_character.glb, which is the only script that should export\n"
              "the body: exporting it from here drops the animations.")


if __name__ == "__main__":
    main()
