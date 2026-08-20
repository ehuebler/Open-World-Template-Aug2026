"""Authors the locomotion actions on the character rig and re-exports the .glb.

Run headless from the project root, with the Blender version that saved the file:

    & "C:\\Program Files\\Blender Foundation\\Blender 5.1\\blender.exe" --background --factory-startup assets/source/blender/player_character.blend --python assets/source/blender/build_animations.py

The script replaces every action in the file, so it is safe to re-run after
tweaking the tables below. It never touches the mesh, the rig or the skin
weights, and it clears the pose before saving, because glTF exports the skin from
the rest pose.

How the poses are described: each animation is a function of cycle phase (0..1)
returning `{bone_name: {"rot": [(axis, degrees), ...], "loc": (x, y, z)}}`, where
the axes and the offset are in **world** space, not bone space. Bone-local axes
depend on the roll the rig builder happened to calculate, so authoring against
world axes is the difference between a readable table and trial and error. In
this file's orientation (Z up, character faces +Y, character's right is +X):

    X  pitch: positive swings a limb forward and tips a torso bone **back**
    Y  roll:  moves an arm out from the body, leans the torso sideways
    Z  yaw:   twists (hips and shoulders counter-rotating in a walk)

The two halves of that pitch line run opposite ways and it is not a typo. One
rotation about +X carries a bone's tip toward -Y: an arm's tip is its hand,
hanging below the shoulder, so the hand goes forward; a spine's tip is the neck,
standing above the hips, so the shoulders go backward. Reading it as "positive
is forward" and authoring a sprint that way produces a run leaning *away* from
where it is going, which looks near enough to upright that it survives review.
Measure a torso, do not eyeball it: `atan2` of the neck minus the hips in y and
z. The chord comes out about 0.58 of the sum of the bones' angles, because the
lower bones carry the ones above them and the chord averages the lot.

Rotations apply in the order listed, so a bone that both drops and swings lists
the drop first: the swing then reads as a swing instead of a twist of an arm
still held out sideways. Arms go through `arm_hang` rather than being written
by hand, for the reason given there.
"""

import math
import os

import bpy
from mathutils import Matrix, Vector

TAU = math.tau
FPS = 30

SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))
BLEND_PATH = os.path.join(SOURCE_DIR, "player_character.blend")
PROJECT_DIR = os.path.abspath(os.path.join(
    SOURCE_DIR, os.pardir, os.pardir, os.pardir))
GLB_PATH = os.path.join(
    PROJECT_DIR, "assets", "runtime", "characters", "player_character.glb")

SIDES = (("Right", 1.0, 0.0), ("Left", -1.0, math.pi))

# Rest heights measured off the rig, used to keep the folded poses honest: a
# crouch has to fold the legs by exactly as much as it drops the hips, or the
# soles leave the floor. The leg root is the hip joint at 0.525, not the Hips
# bone at 0.542; using the latter over-folds by 17 mm and sinks the boots.
LEG_ROOT_HEIGHT = 0.525
ANKLE_HEIGHT = 0.103
THIGH_LENGTH = 0.236
SHIN_LENGTH = 0.186

# The rig rests in a wide A â€” 42 degrees out from vertical at the shoulder, 48 at
# the elbow â€” which is near enough to a T-pose that every clip has to bring the
# arms *down*, not nudge them. Measured off the rig by `_arm_check.py`; if the
# arms are ever rebuilt at a different angle these two numbers move with them.
ARM_REST_OUT = 41.8
FOREARM_REST_OUT = 47.8
# The forearm hangs a little wider than the upper arm, which is what keeps the
# hands off the hips: the body is 0.21 m wide there, and this puts wrists at 0.29.
FOREARM_FLARE = 4.0

# Everything above is measured off whichever rig is being baked;
# `build_character_3.py` overwrites the lot before calling `bake_into_open_file`.
# These last two exist because the pose tables also carry raw distances and a
# stride, neither of which survives a change of body on its own.
#
# BODY_SCALE multiplies every length written in metres - hip dips, crouch
# depths, the slide's reach - and is the ratio of heights. STRIDE_SCALE
# multiplies the walk and run swing instead, because a step is leg length times
# that angle: the settler is 47% leg against the astronaut's 36%, so the same
# angles would have it stepping a third further per stride than its own height
# allows, which reads as a body being dragged along by its feet.
BODY_SCALE = 1.0
STRIDE_SCALE = 1.0


def rot(*pairs):
    return {"rot": list(pairs)}


def arm_hang(pose, side, sign, out, swing=0.0, flex=0.0):
    """Write one arm's two bones from the angles the finished arm should read as.

    `out` is how far the upper arm hangs from vertical, `swing` swings the whole
    arm forward, and `flex` bends the elbow forward on top of that. Writing the
    angle a pose *wants* rather than a nudge from rest is the point: the rest
    pose is nowhere near a hanging arm, and the forearm inherits the shoulder's
    tuck, so hand-written pairs adduct it twice and it ends up across the hips.
    """
    tuck = ARM_REST_OUT - out
    elbow_tuck = FOREARM_REST_OUT - (out + FOREARM_FLARE) - tuck
    pose[side + "UpperArm"] = rot(("Y", sign * tuck), ("X", swing))
    pose[side + "LowerArm"] = rot(("Y", sign * elbow_tuck), ("X", flex))


def clench_hand(pose, side, sign, strength=1.0):
    """Close the optional settler finger chain; the astronaut ignores the keys."""
    for finger in ("Index", "Middle", "Ring", "Little"):
        for joint in range(1, 4):
            pose["{0}{1}{2}".format(side, finger, joint)] = rot(
                ("Y", sign * 52.0 * strength))
    pose[side + "Thumb1"] = rot(
        ("Z", -sign * 24.0 * strength),
        ("Y", sign * 34.0 * strength))
    pose[side + "Thumb2"] = rot(("Y", sign * 48.0 * strength))


def leg_fold(drop, ankle_forward=0.0):
    """Thigh, knee and foot angles that keep one sole on the floor.

    `drop` is how far the hips come down from rest and `ankle_forward` how far
    the foot is planted ahead of them. Solving the two-link chain instead of
    guessing angles is what stops a crouch from sinking the feet through the
    ground, and it means the depth of a pose is one number to tune.
    """
    drop *= BODY_SCALE
    ankle_forward *= BODY_SCALE
    rise = LEG_ROOT_HEIGHT + drop - ANKLE_HEIGHT
    reach = math.hypot(ankle_forward, rise)
    reach = min(reach, (THIGH_LENGTH + SHIN_LENGTH) * 0.999)
    a, b = THIGH_LENGTH, SHIN_LENGTH
    knee_interior = math.acos(max(-1.0, min(1.0, (a * a + b * b - reach * reach) / (2.0 * a * b))))
    hip_offset = math.acos(max(-1.0, min(1.0, (a * a + reach * reach - b * b) / (2.0 * a * reach))))
    lean = math.atan2(ankle_forward, rise)
    thigh = math.degrees(lean + hip_offset)
    knee = -math.degrees(math.pi - knee_interior)
    # The sole stays level by cancelling however far the shin ended up tilted.
    return thigh, knee, -(thigh + knee)


# --------------------------------------------------------------------------
# Pose tables
# --------------------------------------------------------------------------

def _stride(pose, phase, thigh, knee_mid, knee_swing, foot, arm, elbow, hang, arm_bias=0.0):
    """One symmetric two-step gait, written once and used by walk and run.

    `arm_bias` is a constant added to both arms' swing, which is how the run
    gets its arms streaming behind it while the walk keeps them hanging.
    """
    thigh *= STRIDE_SCALE
    for side, sign, offset in SIDES:
        leg = phase + offset
        # A knee only folds backwards, hence the clamp: the swing leg reaches its
        # deepest fold shortly after the foot leaves the ground.
        fold = min(knee_mid + knee_swing * math.sin(leg - 1.1), -3.0)
        pose[side + "UpperLeg"] = rot(("X", thigh * math.sin(leg)))
        pose[side + "LowerLeg"] = rot(("X", fold))
        pose[side + "Foot"] = rot(("X", foot * math.sin(leg + 0.5)))
        # Arms swing against the leg on the same side, and the elbow bends more as
        # the hand comes forward, less as it trails behind.
        arm_hang(pose, side, sign, out=hang, swing=arm_bias - arm * math.sin(leg),
                 flex=elbow * (1.0 - 0.35 * math.sin(leg)))


def idle_pose(t):
    breath = math.sin(t * TAU)
    pose = {
        "Hips": {"rot": [("X", 0.6 * breath)], "loc": (0.0, 0.0, 0.006 * breath)},
        "Spine": rot(("X", -0.8 * breath)),
        "Chest": rot(("X", 1.4 * breath)),
        "Neck": rot(("X", -1.0 * breath)),
        "Head": rot(("X", 0.8 * breath), ("Z", 1.6 * math.sin(t * TAU * 0.5))),
    }
    for side, sign, offset in SIDES:
        # Hands at the hips with the elbows barely bent, riding the breath.
        arm_hang(pose, side, sign, out=9.0 + 0.7 * breath, swing=1.5 * breath,
                 flex=11.0 + 2.0 * breath)
    return pose


def walk_pose(t):
    """A brisk walk with a bounce in it.

    This clip covers everything from a stroll through the ordinary sprint - the
    game only changes gait above `arms_back_speed`, currently 18 m/s, and
    resamples this cycle for everything below - so it is written as the fast
    arms-swinging stride rather than as the slow walk, and the bobble is most of
    what says so.

    Most of the bobble is spent on the spine rather than on the hips, and that
    split is the whole trick. Dropping the hips drops the legs with them, and
    the legs are not re-solved for it, so every millimetre past what the stride
    has already lifted the ankles by goes straight through the floor - measured,
    a deeper hip dip costs the planted sole about one for one. The spine carries
    no weight of its own, so a bounce put there moves the chest and the head,
    which is all anyone reads a bobble off, and leaves the feet where they were.

    `dev/_player_test.gd --sheet` prints each clip's lowest sole, and that is
    the number to watch when retuning any of this: it has to stay near `Idle`'s
    and must not go below what `Run` already ships with.
    """
    phase = t * TAU
    pose = {}
    _stride(pose, phase, thigh=29.0, knee_mid=-33.0, knee_swing=28.0, foot=12.0,
            arm=24.0, elbow=18.0, hang=12.0)
    # Two dips per cycle, one per footfall, and never above the standing height.
    # A shade deeper than it was, which the longer stride pays for and no more.
    dip = -0.026 * (1.0 - math.cos(2.0 * phase)) * 0.5
    # The bounce proper, on the same beat, so the body compresses into a
    # footfall and comes back up between them.
    bounce = -0.022 * (1.0 - math.cos(2.0 * phase)) * 0.5
    # Weight going onto one leg and then the other, at half the dip's rate, so
    # the body rolls once per stride rather than twice. Small on purpose: the
    # legs hang off the hips and are not re-solved for this either, so swaying
    # any further walks the feet out sideways from under the body.
    sway = 0.011 * math.sin(phase)
    # Leaning is spent on the spine rather than the hips: the legs hang off the
    # hips, so pitching those would swing the whole stride backwards.
    pose["Hips"] = {"rot": [("Z", 7.0 * math.sin(phase))], "loc": (sway, 0.0, dip)}
    pose["Spine"] = {"rot": [("Z", -4.5 * math.sin(phase)), ("X", 4.0)],
                     "loc": (0.0, 0.0, bounce)}
    pose["Chest"] = rot(("Z", -5.5 * math.sin(phase)), ("X", 2.0))
    pose["Head"] = rot(("Z", 3.0 * math.sin(phase)), ("X", -4.0))
    return pose


def run_pose(t):
    """A flat-out sprint: chest driven forward, both arms streaming behind.

    The walk's arm carriage scaled up was what this used to be, and at speed it
    read as someone jogging with their palms held out in front of them: the
    elbow flex that makes a walk's arms swing is what puts the hands up there,
    and it grows with the swing. So the run drops the flex almost to nothing,
    biases the whole swing behind the body, and spends the difference on the
    lean instead. Nothing here should be copied back into `walk_pose` - it is a
    posture worth holding for a sprint and exhausting at any other pace.

    `hang` is wider than a walk's for a reason that only shows on the settler:
    leaned this far over, hands swept this far back pass either side of the
    head, and that head is a fifth of the body. Held at the walk's width they
    go through it.
    """
    phase = t * TAU
    pose = {}
    _stride(pose, phase, thigh=42.0, knee_mid=-52.0, knee_swing=44.0, foot=18.0,
            arm=12.0, elbow=9.0, hang=20.0, arm_bias=-78.0)
    dip = -0.042 * (1.0 - math.cos(2.0 * phase)) * 0.5
    pose["Hips"] = {"rot": [("Z", 9.0 * math.sin(phase)), ("X", -4.0)], "loc": (0.0, 0.0, dip)}
    # The lean is most of what says "powerful": negative, and about 32 degrees of
    # chord once the 0.58 in the header is taken off. It is spread over three
    # bones rather than loaded onto the spine, because the spine is one short
    # bone and that much of it folds the waist instead of tipping the body. The
    # game adds SPRINT_LEAN on top once a run winds past a sprint, so this is
    # deliberately short of flat.
    pose["Spine"] = rot(("Z", -7.0 * math.sin(phase)), ("X", -30.0))
    pose["Chest"] = rot(("Z", -8.0 * math.sin(phase)), ("X", -16.0))
    pose["UpperChest"] = rot(("X", -10.0))
    # Enough to cancel the whole lean, so the eyes stay on the horizon.
    pose["Neck"] = rot(("X", 26.0))
    pose["Head"] = rot(("Z", 4.0 * math.sin(phase)), ("X", 28.0))
    return pose


# How far the hips come down in a crouch; the leg angles follow from the solver.
CROUCH_DROP = -0.13


def _crouch_base(pose, drop=CROUCH_DROP, stride_phase=None, stride=0.0):
    thigh, knee, foot = leg_fold(drop)
    for side, sign, offset in SIDES:
        swing = 0.0 if stride_phase is None else math.sin(stride_phase + offset)
        pose[side + "UpperLeg"] = rot(("X", thigh + stride * swing), ("Y", -sign * 7.0))
        pose[side + "LowerLeg"] = rot(("X", knee - stride * 0.35 * swing))
        pose[side + "Foot"] = rot(("X", foot))
        # Elbows in and bent, hands hanging in front of the thighs.
        arm_hang(pose, side, sign, out=15.0, swing=-8.0 - 0.4 * stride * swing, flex=40.0)
    pose["Hips"] = {"rot": [], "loc": (0.0, 0.0, drop)}
    pose["Spine"] = rot(("X", 14.0))
    pose["Chest"] = rot(("X", 8.0))
    # The head lifts back up to look ahead rather than down at the floor.
    pose["Neck"] = rot(("X", -12.0))
    pose["Head"] = rot(("X", -14.0))


def crouch_idle_pose(t):
    sway = math.sin(t * TAU)
    pose = {}
    # The fold is re-solved for the swayed depth, not scaled towards it, so the
    # soles stay put through the whole breath.
    _crouch_base(pose, drop=CROUCH_DROP + 0.008 * sway)
    pose["Chest"] = rot(("X", 8.0 + 1.2 * sway))
    return pose


def crouch_walk_pose(t):
    phase = t * TAU
    pose = {}
    dip = -0.012 * (1.0 - math.cos(2.0 * phase)) * 0.5
    _crouch_base(pose, drop=CROUCH_DROP + dip, stride_phase=phase, stride=12.0)
    pose["Hips"]["rot"].append(("Z", 4.0 * math.sin(phase)))
    return pose


def jump_rise_pose(t):
    """A crouched launch snapping into a split leap, so it reads even at 0.3 s.

    Both arms swung forward was the first version, and it is what a standing
    jump really does - the arm swing is where a third of the height comes from.
    It also reads as somebody feeling their way along a dark corridor, because
    at the top of the swing the palms are up and the elbows are bent and nothing
    else in the pose is doing anything. The arms go back instead and the legs
    take the whole silhouette: lead knee driven up past horizontal, trailing leg
    stretched out behind it with the toes off the end.
    """
    launch = min(t * 2.2, 1.0)
    pose = {}
    for side, sign, offset in SIDES:
        crouch = -14.0 * (1.0 - launch)
        if sign > 0.0:
            pose[side + "UpperLeg"] = rot(("X", 82.0 * launch + crouch), ("Y", -7.0 * launch))
            pose[side + "LowerLeg"] = rot(("X", -92.0 * launch - 6.0))
            pose[side + "Foot"] = rot(("X", 16.0 * launch))
        else:
            pose[side + "UpperLeg"] = rot(("X", -28.0 * launch + crouch), ("Y", 5.0 * launch))
            pose[side + "LowerLeg"] = rot(("X", -14.0 * launch - 6.0))
            pose[side + "Foot"] = rot(("X", -34.0 * launch))
        # Elbows nearly straight, so the pair reads as one line carried on from
        # the shoulders rather than as two props held out at the sides.
        arm_hang(pose, side, sign, out=16.0 + 8.0 * launch, swing=-74.0 * launch,
                 flex=10.0 + 8.0 * launch)
    pose["Hips"] = {"rot": [], "loc": (0.0, 0.0, 0.03 * launch)}
    pose["Spine"] = rot(("X", -16.0 * launch))
    pose["Chest"] = rot(("X", -8.0 * launch))
    pose["UpperChest"] = rot(("X", -5.0 * launch))
    pose["Neck"] = rot(("X", 12.0 * launch))
    pose["Head"] = rot(("X", 16.0 * launch))
    return pose


def fall_pose(t):
    """Where a jump ends up, so it has to start where the jump left off.

    `JumpRise` finishes with the arms swept 74 degrees behind and the elbows
    nearly straight, and this is what plays the moment the apex is passed, so the
    arms are held there and the wave only drifts them. The crossfade between the
    two clips then has almost nothing to move, which is the whole point and is
    what `_check_character` measures at the seam.

    They used to swing forward into a bent-elbow hang, and every jump ended with
    the character reaching out in front of itself halfway up - the same "feeling
    along a dark corridor" read `jump_rise_pose` was authored to get away from,
    arrived at from the other direction. Wide arms for balance was the stated
    intent and is not what it rendered as: at 40 degrees of flex the hands come to
    rest in front of the thighs and the whole pose is a stand.
    """
    float_wave = math.sin(t * TAU)
    pose = {}
    for side, sign, offset in SIDES:
        trail = 1.0 if sign > 0.0 else 0.4
        pose[side + "UpperLeg"] = rot(("X", 16.0 * trail + 4.0 * float_wave), ("Y", -sign * 8.0))
        pose[side + "LowerLeg"] = rot(("X", -30.0 * trail - 8.0))
        pose[side + "Foot"] = rot(("X", 14.0))
        # This is the first second aloft, not the destination of a long fall. Hold
        # the launch's arm line exactly: even five degrees of looping drift moves a
        # hand several centimetres and reads as the leap running out of resolve.
        # `AirRun` is the deliberate change of silhouette if the body stays aloft.
        arm_hang(pose, side, sign, out=28.0, swing=-72.0, flex=18.0)
    pose["Hips"] = rot(("X", -6.0))
    pose["Spine"] = rot(("X", -4.0))
    pose["Head"] = rot(("X", -6.0))
    return pose


def air_run_pose(_t):
    """The held landing stride reached only after a full second in the air.

    The right foot is offered to the ground while the left leg trails folded
    behind it. The arms deliberately stop matching: the left fist is driven up
    and the right elbow folds back, making the silhouette read as the last frame
    before a running footfall rather than as a relaxed fall. Runtime spends more
    than half a second blending here, then enters `Run` at its matching
    right-leg-forward quarter-cycle when the foot finds ground.
    """
    pose = {
        "RightUpperLeg": rot(("X", 58.0), ("Y", -5.0)),
        "RightLowerLeg": rot(("X", -28.0)),
        "RightFoot": rot(("X", 18.0)),
        "LeftUpperLeg": rot(("X", -38.0), ("Y", 7.0)),
        "LeftLowerLeg": rot(("X", -72.0)),
        "LeftFoot": rot(("X", -24.0)),
        "Hips": {"rot": [("Z", -5.0), ("X", -6.0)], "loc": (0.0, 0.0, 0.025)},
        "Spine": rot(("Z", 5.0), ("X", -18.0)),
        "Chest": rot(("Z", 7.0), ("X", -10.0)),
        "UpperChest": rot(("X", -6.0)),
        "Neck": rot(("X", 15.0)),
        "Head": rot(("Z", -4.0), ("X", 17.0)),
    }
    # The right upper arm trails while its elbow brings the hand forward; the
    # left upper arm supplies the high fist from the reference. Both stay clear
    # of the settler's larger head and of either body's shoulder garments.
    arm_hang(pose, "Right", 1.0, out=27.0, swing=-24.0, flex=155.0)
    arm_hang(pose, "Left", -1.0, out=25.0, swing=178.0, flex=36.0)
    clench_hand(pose, "Right", 1.0)
    clench_hand(pose, "Left", -1.0)
    return pose


def land_pose(t):
    # Absorb on impact, then push back up: one dip, no overshoot.
    dip = math.sin(math.pi * min(t * 1.15, 1.0))
    thigh, knee, foot = leg_fold(-0.17 * dip)
    pose = {}
    for side, sign, offset in SIDES:
        pose[side + "UpperLeg"] = rot(("X", thigh), ("Y", -sign * 6.0 * dip))
        pose[side + "LowerLeg"] = rot(("X", knee))
        pose[side + "Foot"] = rot(("X", foot))
        arm_hang(pose, side, sign, out=11.0 + 15.0 * dip, swing=24.0 * dip,
                 flex=14.0 + 30.0 * dip)
    pose["Hips"] = {"rot": [], "loc": (0.0, 0.0, -0.17 * dip)}
    pose["Spine"] = rot(("X", 20.0 * dip))
    pose["Chest"] = rot(("X", 8.0 * dip))
    pose["Head"] = rot(("X", -18.0 * dip))
    return pose


def hero_land_pose(t):
    """A planted three-point landing: forward foot, rear knee, and one hand.

    The pose arrives quickly, holds long enough to read at speed, then releases
    over its last quarter so the game's crossfade can finish standing it up.
    It is deliberately asymmetric like the reference silhouette; mirroring both
    sides into the same crouch would just duplicate `Land`.
    """
    arrive = min(t * 4.5, 1.0)
    arrive = arrive * arrive * (3.0 - 2.0 * arrive)
    release = max((t - 0.72) / 0.28, 0.0)
    release = min(release, 1.0)
    release = release * release * (3.0 - 2.0 * release)
    planted = arrive * (1.0 - release)
    thigh, knee, foot = leg_fold(-0.31 * planted, ankle_forward=0.18 * planted)
    pose = {
        # Right foot forward under a high knee.
        "RightUpperLeg": rot(("X", thigh), ("Y", -18.0 * planted)),
        "RightLowerLeg": rot(("X", knee)),
        "RightFoot": rot(("X", foot)),
        # Left knee folded under and behind the hips.
        "LeftUpperLeg": rot(("X", -12.0 * planted), ("Y", 30.0 * planted)),
        "LeftLowerLeg": rot(("X", -112.0 * planted)),
        "LeftFoot": rot(("X", 48.0 * planted)),
        "Hips": {
            "rot": [("Z", 8.0 * planted)],
            "loc": (0.0, -0.025 * planted, -0.31 * planted),
        },
        # Chest pitched over the planted knee and rolled hard toward the bracing
        # hand. The opposite shoulder stays high, giving the pose its diagonal
        # line instead of reading as a symmetric crouch.
        "Spine": rot(("X", -30.0 * planted), ("Y", -30.0 * planted),
                     ("Z", -7.0 * planted)),
        "Chest": rot(("X", -15.0 * planted), ("Y", -20.0 * planted),
                     ("Z", -5.0 * planted)),
        # Counter-rotate the head so the body can fold without burying the face
        # in the raised knee.
        "Neck": rot(("X", 20.0 * planted), ("Y", 25.0 * planted)),
        "Head": rot(("X", 15.0 * planted), ("Y", 20.0 * planted),
                    ("Z", -4.0 * planted)),
        # Lay the bracing hand across the ground instead of continuing the
        # forearm's downward line below it.
        "LeftHand": rot(("X", -80.0 * planted)),
    }
    # Left hand braces on the ground; right arm reaches wide for balance.
    arm_hang(pose, "Left", -1.0, out=40.0,
             swing=35.0 * planted, flex=-50.0 * planted)
    arm_hang(pose, "Right", 1.0, out=10.0 + 30.0 * planted,
             swing=-10.0 * planted, flex=8.0)
    return pose


SLIDE_DROP = -0.16


def slide_pose(t):
    # Eases into the pose and holds it, since the clip plays once per slide.
    ease = min(t * 2.5, 1.0)
    ease = ease * ease * (3.0 - 2.0 * ease)
    # Right leg thrown out in front with the heel down, left knee tucked under
    # the hips and riding just above the floor: a knee slide.
    thigh, knee, foot = leg_fold(SLIDE_DROP * ease, ankle_forward=0.34 * ease)
    pose = {
        "RightUpperLeg": rot(("X", thigh), ("Y", -8.0 * ease)),
        "RightLowerLeg": rot(("X", knee - 3.0)),
        "RightFoot": rot(("X", foot)),
        "LeftUpperLeg": rot(("X", 14.0 * ease), ("Y", 26.0 * ease)),
        "LeftLowerLeg": rot(("X", -100.0 * ease - 3.0)),
        "LeftFoot": rot(("X", 40.0 * ease)),
        "Hips": {"rot": [("Z", 10.0 * ease)], "loc": (0.0, 0.0, SLIDE_DROP * ease)},
        # The lean back lives on the spine so it cannot lift the planted heel.
        "Spine": rot(("X", -20.0 * ease), ("Z", -8.0 * ease)),
        "Chest": rot(("X", -10.0 * ease)),
        "Neck": rot(("X", 16.0 * ease)),
        "Head": rot(("X", 18.0 * ease), ("Z", -6.0 * ease)),
    }
    # Trailing arm tucked in behind, leading arm out to the side for balance.
    arm_hang(pose, "Right", 1.0, out=10.0 + 16.0 * ease, swing=-26.0 * ease, flex=32.0 * ease)
    arm_hang(pose, "Left", -1.0, out=10.0 + 34.0 * ease, swing=-10.0 * ease, flex=24.0 * ease)
    return pose


# Both flight clips are authored **upright**, and the game pitches the whole body
# forward as speed builds (`_update_body_lean` in game/player/player.gd). So in
# this file "up" is the direction of travel: Fly's arms swept down behind the hips
# become a pair streaming off the shoulders, and its legs a straight line behind,
# the moment the body leans over. Authoring them lying down instead would fight
# the rig's rest pose and leave the clips unusable at the hover end of the same
# continuum.

# How far the hips ride above rest while hovering. Small: the toes only have to
# leave the ground plane enough to read, and the collider does not move.
FLOAT_LIFT = 0.04


def float_pose(t):
    bob = math.sin(t * TAU)
    drift = math.sin(t * TAU * 0.5)
    pose = {
        # Trailing leg straight and swept a little back, the other knee drawn up
        # across it. This is the whole silhouette: it is what says hovering
        # rather than falling, which Fall already covers with wide arms.
        "RightUpperLeg": rot(("X", -16.0 - 2.0 * bob), ("Y", -5.0)),
        "RightLowerLeg": rot(("X", -6.0 - 3.0 * bob)),
        "RightFoot": rot(("X", -26.0)),
        "LeftUpperLeg": rot(("X", 72.0 + 4.0 * bob), ("Y", 15.0)),
        "LeftLowerLeg": rot(("X", -104.0 - 5.0 * bob)),
        "LeftFoot": rot(("X", -4.0)),
        "Hips": {
            "rot": [("X", -7.0), ("Z", 3.0 * drift)],
            "loc": (0.0, 0.0, FLOAT_LIFT + 0.012 * bob),
        },
        "Spine": rot(("X", -5.0)),
        "Chest": rot(("X", 7.0 + 1.2 * bob)),
        "Neck": rot(("X", -5.0)),
        "Head": rot(("X", -7.0), ("Z", 2.5 * drift)),
    }
    # Fists down by the hips with the elbows bent out, riding the bob. Held any
    # wider this reads as a scarecrow from above, which is the view a hovering
    # figure is most often seen from.
    for side, sign, offset in SIDES:
        arm_hang(pose, side, sign, out=21.0 + 3.0 * bob,
                 swing=-20.0 - 4.0 * bob, flex=32.0 + 5.0 * bob)
    return pose


def fly_pose(t):
    wave = math.sin(t * TAU)
    roll = math.sin(t * TAU * 0.5)
    pose = {
        # Legs together with the toes pointed, which leaned over is the long
        # trailing line that carries the speed.
        "RightUpperLeg": rot(("X", -5.0 + 1.5 * wave), ("Y", 3.0)),
        "RightLowerLeg": rot(("X", -5.0 - 2.0 * wave)),
        "RightFoot": rot(("X", -34.0)),
        "LeftUpperLeg": rot(("X", -5.0 - 1.5 * wave), ("Y", -3.0)),
        "LeftLowerLeg": rot(("X", -5.0 + 2.0 * wave)),
        "LeftFoot": rot(("X", -34.0)),
        "Hips": {"rot": [("Z", 2.0 * roll)], "loc": (0.0, 0.0, 0.0)},
        # Arched back, which once the body is pitched over is the head lifting to
        # look along the flight path instead of at the floor rushing past. These
        # four were all negative until the header's pitch line was measured, and
        # negative is the fold that puts the chin on the chest: a flight spent
        # looking straight down at the ground going past.
        "Spine": rot(("X", 5.0)),
        "Chest": rot(("X", 6.0 + 1.0 * wave)),
        "Neck": rot(("X", 13.0)),
        "Head": rot(("X", 15.0), ("Z", 3.0 * roll)),
    }
    # Both arms swept back along the body, which leaned over is the pair
    # streaming behind the shoulders. Two earlier versions are worth not
    # repeating: both arms *forward* disappears, because an arm is barely longer
    # than the head is high and a matched pair only just clears the crown, so
    # the silhouette stays a torso; and one arm up with the other back reads as
    # a punch and dates the whole thing, besides being the one pose a held
    # weapon cannot survive. Back is the same length of line, and it points
    # where the body has been rather than where it is going, which is what
    # carries the speed.
    #
    # It is spent on `swing` rather than `out` for the same reason it always
    # was: swing takes the arm round in the sagittal plane, and `out` would put
    # it round the side, which leaned over is a swan dive.
    for side, sign, offset in SIDES:
        arm_hang(pose, side, sign, out=12.0, swing=-54.0 - 4.0 * math.sin(t * TAU + offset),
                 flex=7.0)
    return pose


def meteor_fly_pose(t):
    """The punch: right fist thrown out along the flight path, left leg folded.

    Authored upright like the other two flight clips, so "along the flight path"
    is straight overhead here and the game's forward pitch is what turns it into
    a punch. That is why the leading arm goes to nearly 180 degrees of swing:
    from a hanging arm, half a turn about X is an arm pointing at the sky, which
    once the body is over is an arm pointing where it is going. `out` stays tiny
    so the arm runs up the body's centre line rather than out to the side, which
    pitched over would be a wing rather than a punch.

    The asymmetry is the whole silhouette and it is deliberate: trailing arm
    tucked in, right leg straight behind, left knee folded so the heel comes up.
    A matched pair of arms and legs is `Fly`, which is what this must not be
    mistaken for at fifty metres.
    """
    wave = math.sin(t * TAU)
    roll = math.sin(t * TAU * 0.5)
    pose = {
        # Trailing leg straight and pointed, carrying the long line.
        "RightUpperLeg": rot(("X", -6.0 + 1.2 * wave), ("Y", 4.0)),
        "RightLowerLeg": rot(("X", -4.0 - 1.5 * wave)),
        "RightFoot": rot(("X", -36.0)),
        # Left knee folded, heel drawn up behind. Held in the shin rather than
        # the thigh so the fold reads without the knee swinging out of line.
        "LeftUpperLeg": rot(("X", -10.0 - 1.2 * wave), ("Y", -9.0)),
        "LeftLowerLeg": rot(("X", -96.0 - 4.0 * wave)),
        "LeftFoot": rot(("X", -18.0)),
        "Hips": {"rot": [("Y", -4.0), ("Z", 4.0 * roll)], "loc": (0.0, 0.0, 0.0)},
        # Arched harder than Fly and rolled toward the leading shoulder, which
        # is what stops the punching arm looking bolted on.
        "Spine": rot(("X", 7.0), ("Y", 6.0)),
        "Chest": rot(("X", 8.0 + 1.0 * wave), ("Y", 9.0), ("Z", -4.0)),
        "Neck": rot(("X", 13.0)),
        "Head": rot(("X", 16.0), ("Y", 4.0), ("Z", 3.0 * roll)),
    }
    # Right arm punched out ahead, all but straight.
    arm_hang(pose, "Right", 1.0, out=5.0,
             swing=172.0 + 2.0 * wave, flex=-6.0)
    # Left arm swept back along the body, tighter than Fly's so the two arms do
    # not read as a matched pair.
    arm_hang(pose, "Left", -1.0, out=9.0,
             swing=-62.0 - 3.0 * wave, flex=14.0)
    clench_hand(pose, "Right", 1.0)
    clench_hand(pose, "Left", -1.0)
    return pose


# --------------------------------------------------------------------------
# Abilities
# --------------------------------------------------------------------------

def _starfire_pose(t, active_side):
    """Quick open-palm cast, authored once and mirrored by active side."""
    if t < 0.30:
        share = t / 0.30
        swing = 8.0 + (-48.0 - 8.0) * share
        flex = 18.0 + (76.0 - 18.0) * share
    elif t < 0.66:
        share = (t - 0.30) / 0.36
        share = share * share * (3.0 - 2.0 * share)
        swing = -48.0 + (102.0 + 48.0) * share
        flex = 76.0 + (8.0 - 76.0) * share
    else:
        share = (t - 0.66) / 0.34
        share = share * share * (3.0 - 2.0 * share)
        swing = 102.0 + (8.0 - 102.0) * share
        flex = 8.0 + (18.0 - 8.0) * share

    active_sign = 1.0 if active_side == "Right" else -1.0
    pulse = math.sin(math.pi * t)
    pose = {
        "Spine": rot(("Y", active_sign * 8.0 * pulse)),
        "Chest": rot(("Y", active_sign * 16.0 * pulse),
                     ("Z", -active_sign * 5.0 * pulse)),
        "Head": rot(("Y", -active_sign * 5.0 * pulse)),
    }
    for side, sign, _offset in SIDES:
        if side == active_side:
            arm_hang(pose, side, sign, out=26.0 + 8.0 * pulse,
                     swing=swing, flex=flex)
            pose[side + "Hand"] = rot(("X", -18.0 * pulse))
        else:
            arm_hang(pose, side, sign, out=20.0,
                     swing=20.0 * pulse, flex=48.0 * pulse)
    return pose


def starfire_right_pose(t):
    return _starfire_pose(t, "Right")


def starfire_left_pose(t):
    return _starfire_pose(t, "Left")


def _starfire_float_pose(t, active_side):
    """The same throw while preserving Float's raised-knee silhouette."""
    # Float is a two-second loop while this throw is one third of a second. Move
    # through the matching fraction of its bob so the legs remain alive without
    # racing through a full hover cycle during one cast.
    pose = float_pose(t / 6.0)
    pose.update(_starfire_pose(t, active_side))
    return pose


def starfire_float_right_pose(t):
    return _starfire_float_pose(t, "Right")


def starfire_float_left_pose(t):
    return _starfire_float_pose(t, "Left")


def _hero_punch_pose(t, active_side):
    """Fast centre-line fist strike, authored once and mirrored."""
    if t < 0.28:
        share = t / 0.28
        swing = 10.0 + (-38.0 - 10.0) * share
        flex = 14.0 + (62.0 - 14.0) * share
    elif t < 0.58:
        share = (t - 0.28) / 0.30
        share = share * share * (3.0 - 2.0 * share)
        swing = -38.0 + (108.0 + 38.0) * share
        flex = 62.0 + (4.0 - 62.0) * share
    else:
        share = (t - 0.58) / 0.42
        share = share * share * (3.0 - 2.0 * share)
        swing = 108.0 + (12.0 - 108.0) * share
        flex = 4.0 + (16.0 - 4.0) * share

    active_sign = 1.0 if active_side == "Right" else -1.0
    pulse = math.sin(math.pi * t)
    pose = {
        "Spine": rot(("X", -6.0 * pulse),
                     ("Y", active_sign * 5.0 * pulse)),
        "Chest": rot(("X", -4.0 * pulse),
                     ("Y", active_sign * 10.0 * pulse)),
        "Head": rot(("X", 3.0 * pulse),
                    ("Y", -active_sign * 4.0 * pulse)),
    }
    for side, sign, _offset in SIDES:
        if side == active_side:
            # Nearly on the body's centre line, unlike Starfire's open side cast.
            arm_hang(pose, side, sign, out=8.0 + 4.0 * pulse,
                     swing=swing, flex=flex)
            clench_hand(pose, side, sign, 1.55)
        else:
            arm_hang(pose, side, sign, out=18.0,
                     swing=-14.0 * pulse, flex=32.0 + 8.0 * pulse)
            clench_hand(pose, side, sign)
    return pose


def hero_punch_right_pose(t):
    return _hero_punch_pose(t, "Right")


def hero_punch_left_pose(t):
    return _hero_punch_pose(t, "Left")


def _hero_punch_float_pose(t, active_side):
    """Keep Float's bent knee under the same mirrored upper-body strike."""
    pose = float_pose(t / 6.0)
    pose.update(_hero_punch_pose(t, active_side))
    return pose


def hero_punch_float_right_pose(t):
    return _hero_punch_float_pose(t, "Right")


def hero_punch_float_left_pose(t):
    return _hero_punch_float_pose(t, "Left")


def nuke_throw_pose(t):
    """Heavy right-hand wind-up and committed palm launch."""
    if t < 0.42:
        wind = t / 0.42
        wind = wind * wind * (3.0 - 2.0 * wind)
        swing = 12.0 - 80.0 * wind
        flex = 18.0 + 72.0 * wind
    elif t < 0.76:
        fire = (t - 0.42) / 0.34
        fire = fire * fire * (3.0 - 2.0 * fire)
        swing = -68.0 + 184.0 * fire
        flex = 90.0 - 84.0 * fire
    else:
        recover = (t - 0.76) / 0.24
        recover = recover * recover * (3.0 - 2.0 * recover)
        swing = 116.0 - 104.0 * recover
        flex = 6.0 + 12.0 * recover
    pulse = math.sin(math.pi * t)
    pose = {
        "Spine": rot(("Y", 12.0 * pulse), ("X", -5.0 * pulse)),
        "Chest": rot(("Y", 24.0 * pulse), ("X", -8.0 * pulse)),
        "Head": rot(("Y", -9.0 * pulse), ("X", 4.0 * pulse)),
        "RightHand": rot(("X", -24.0 * pulse)),
    }
    arm_hang(pose, "Right", 1.0, out=24.0 + 12.0 * pulse,
             swing=swing, flex=flex)
    arm_hang(pose, "Left", -1.0, out=24.0,
             swing=28.0 * pulse, flex=58.0 * pulse)
    return pose


def nuke_float_throw_pose(t):
    pose = float_pose(t / 6.0)
    pose.update(nuke_throw_pose(t))
    return pose


def lasso_throw_pose(t):
    """Snap the right hand forward as if casting a web line."""
    cast = min(t / 0.56, 1.0)
    cast = cast * cast * (3.0 - 2.0 * cast)
    recover = max((t - 0.72) / 0.28, 0.0)
    recover = recover * recover * (3.0 - 2.0 * recover)
    held = cast * (1.0 - 0.35 * recover)
    pose = {
        "Spine": rot(("Y", 9.0 * held)),
        "Chest": rot(("Y", 17.0 * held), ("X", -4.0 * held)),
        "Head": rot(("Y", -6.0 * held)),
        "RightHand": rot(("X", -34.0 * held), ("Z", 12.0 * held)),
    }
    arm_hang(pose, "Right", 1.0, out=20.0 + 14.0 * held,
             swing=112.0 * held, flex=20.0 - 12.0 * held)
    arm_hang(pose, "Left", -1.0, out=16.0 + 8.0 * held,
             swing=-18.0 * held, flex=24.0 + 18.0 * held)
    return pose


def lasso_float_throw_pose(t):
    pose = float_pose(t / 6.0)
    pose.update(lasso_throw_pose(t))
    return pose


def lasso_hold_pose(t):
    sway = math.sin(t * TAU)
    pose = {
        "Spine": rot(("Y", 8.0 + 3.0 * sway), ("X", -4.0)),
        "Chest": rot(("Y", 14.0 + 4.0 * sway), ("X", -6.0)),
        "Head": rot(("Y", -6.0 - 2.0 * sway), ("X", 3.0)),
        "RightHand": rot(("X", -32.0), ("Z", 10.0)),
    }
    arm_hang(pose, "Right", 1.0, out=33.0 + 2.0 * sway,
             swing=108.0 + 5.0 * sway, flex=12.0)
    arm_hang(pose, "Left", -1.0, out=25.0 - 2.0 * sway,
             swing=-20.0, flex=40.0 + 3.0 * sway)
    return pose


def lasso_float_hold_pose(t):
    pose = float_pose(t)
    pose.update(lasso_hold_pose(t))
    return pose


def wall_place_pose(t):
    """Raise both palms and push the barrier into place."""
    push = math.sin(math.pi * min(t, 1.0))
    pose = {
        "Spine": rot(("X", -7.0 * push)),
        "Chest": rot(("X", -12.0 * push)),
        "Head": rot(("X", 8.0 * push)),
        "RightHand": rot(("X", -28.0 * push)),
        "LeftHand": rot(("X", -28.0 * push)),
    }
    for side, sign, _offset in SIDES:
        arm_hang(pose, side, sign, out=34.0 * push,
                 swing=96.0 * push, flex=10.0 + 18.0 * push)
    return pose


def wall_float_place_pose(t):
    pose = float_pose(t / 6.0)
    pose.update(wall_place_pose(t))
    return pose


def nausica_mark_pose(t):
    """A short, precise right-hand beam rather than a weapon recoil."""
    point = math.sin(math.pi * min(t, 1.0))
    pose = {
        "Spine": rot(("Y", 6.0 * point)),
        "Chest": rot(("Y", 11.0 * point), ("X", -3.0 * point)),
        "Head": rot(("Y", -4.0 * point)),
        "RightHand": rot(("X", -12.0 * point)),
    }
    arm_hang(pose, "Right", 1.0, out=15.0 + 12.0 * point,
             swing=122.0 * point, flex=8.0)
    arm_hang(pose, "Left", -1.0, out=15.0,
             swing=-12.0 * point, flex=20.0)
    return pose


def nausica_float_mark_pose(t):
    pose = float_pose(t / 6.0)
    pose.update(nausica_mark_pose(t))
    return pose


def grapple_grab_pose(t):
    reach = min(t / 0.58, 1.0)
    reach = reach * reach * (3.0 - 2.0 * reach)
    pose = {
        "Hips": {"rot": [("X", -5.0 * reach)],
                 "loc": (0.0, 0.0, -0.035 * reach)},
        "Spine": rot(("X", -12.0 * reach)),
        "Chest": rot(("X", -9.0 * reach)),
        "Neck": rot(("X", 8.0 * reach)),
        "Head": rot(("X", 10.0 * reach)),
    }
    for side, sign, _offset in SIDES:
        arm_hang(pose, side, sign, out=22.0 + 9.0 * reach,
                 swing=96.0 * reach, flex=12.0 + 12.0 * reach)
    return pose


def grapple_carry_pose(t):
    bob = math.sin(t * TAU)
    pose = {
        "Hips": {"rot": [("Z", 2.5 * bob)],
                 "loc": (0.0, 0.0, 0.018 * bob)},
        "Spine": rot(("X", -8.0)),
        "Chest": rot(("X", -6.0)),
        "Neck": rot(("X", 7.0)),
        "Head": rot(("X", 9.0), ("Z", -2.5 * bob)),
        "RightUpperLeg": rot(("X", 20.0 + 3.0 * bob), ("Y", -5.0)),
        "RightLowerLeg": rot(("X", -38.0)),
        "LeftUpperLeg": rot(("X", -8.0 - 3.0 * bob), ("Y", 5.0)),
        "LeftLowerLeg": rot(("X", -18.0)),
    }
    for side, sign, offset in SIDES:
        arm_hang(pose, side, sign, out=30.0,
                 swing=78.0 + 3.0 * math.sin(t * TAU + offset),
                 flex=72.0 + 4.0 * bob)
    return pose


# --------------------------------------------------------------------------
# Water
# --------------------------------------------------------------------------
#
# The third upright-authored pair, and it works exactly as the flight pair does:
# `Tread` is the standing-still end and `Swim` the flat-out one, and `_swim_blend`
# in game/player/player.gd pitches the body between them. So "up" is again the
# direction of travel, and `Swim` is a front crawl written vertically - which is
# also why the arms sweep nearly the whole way round the shoulder rather than
# reaching forward. Authored lying down instead there would be nothing usable at
# the treading end of the same continuum.

def tread_pose(t):
    bob = math.sin(t * TAU)
    scull = math.sin(t * TAU * 2.0)
    pose = {
        "Hips": {"rot": [("Z", 3.0 * bob)], "loc": (0.0, 0.0, 0.018 * bob)},
        # Reclined a little with the chin well up: the one thing a treading
        # swimmer is certainly doing is keeping their face out of the water.
        "Spine": rot(("X", 3.0)),
        "Chest": rot(("X", 2.0 + 1.5 * bob)),
        "Neck": rot(("X", 10.0)),
        "Head": rot(("X", 14.0), ("Z", 3.0 * bob)),
    }
    for side, sign, offset in SIDES:
        leg = t * TAU + offset
        # An eggbeater: each thigh circles up and out half a cycle behind the
        # other, so the body is never being kicked the same way twice at once
        # and the bob has something under it that looks like it caused it.
        pose[side + "UpperLeg"] = rot(("X", 46.0 + 20.0 * math.sin(leg)),
                                      ("Y", -sign * (18.0 + 8.0 * math.cos(leg))))
        pose[side + "LowerLeg"] = rot(("X", -74.0 + 26.0 * math.cos(leg)))
        pose[side + "Foot"] = rot(("X", 12.0))
        # Hands sculling out at chest height. This is the whole read: a treading
        # swimmer is doing something with their arms and a floating one is not,
        # which is the only thing separating this clip from `Float`.
        arm_hang(pose, side, sign, out=62.0 + 6.0 * math.sin(leg),
                 swing=14.0 * scull, flex=44.0 + 10.0 * math.cos(leg))
    return pose


def swim_pose(t):
    phase = t * TAU
    pose = {}
    for side, sign, offset in SIDES:
        stroke = phase + offset
        # The pull runs the arm from out past the head down to the hip and the
        # recovery brings it back over. The elbow is only allowed to bend on the
        # recovery half, because a bent arm on the pull is a swimmer dragging
        # themselves backwards through their own hand.
        recovery = max(0.0, math.cos(stroke))
        arm_hang(pose, side, sign, out=10.0 + 12.0 * recovery,
                 swing=68.0 + 96.0 * math.sin(stroke), flex=8.0 + 34.0 * recovery)
        # Flutter kick at twice the arm rate, off small knees and pointed toes.
        kick = 2.0 * phase + offset
        pose[side + "UpperLeg"] = rot(("X", -4.0 + 15.0 * math.sin(kick)), ("Y", -sign * 3.0))
        pose[side + "LowerLeg"] = rot(("X", -14.0 - 10.0 * math.sin(kick - 0.9)))
        pose[side + "Foot"] = rot(("X", -32.0))
    # Body roll, one turn per stroke pair, which is what stops a crawl reading
    # as a plank with windmills on it.
    roll = math.sin(phase)
    pose["Hips"] = {"rot": [("Z", 7.0 * roll)], "loc": (0.0, 0.0, 0.0)}
    # Barely arched, because a crawl is a straight line, but the head is well up:
    # leaned over, that is a swimmer looking where they are going rather than at
    # the sea bed, and the camera rides on that bone.
    pose["Spine"] = rot(("Z", -5.0 * roll), ("X", 3.0))
    pose["Chest"] = rot(("Z", -6.0 * roll), ("X", 4.0))
    pose["Neck"] = rot(("X", 14.0))
    pose["Head"] = rot(("X", 16.0), ("Z", 4.0 * roll))
    return pose


# (name, frames, looping, pose function). Frames are at FPS; a looping clip gets
# one extra frame holding the cycle's first pose so the wrap is seamless.
ANIMATIONS = [
    ("Idle", 90, True, idle_pose),
    ("Walk", 30, True, walk_pose),
    ("Run", 20, True, run_pose),
    ("CrouchIdle", 72, True, crouch_idle_pose),
    ("CrouchWalk", 36, True, crouch_walk_pose),
    ("JumpRise", 11, False, jump_rise_pose),
    ("Fall", 36, True, fall_pose),
    ("AirRun", 24, False, air_run_pose),
    ("Land", 13, False, land_pose),
    ("HeroLand", 24, False, hero_land_pose),
    ("Slide", 12, False, slide_pose),
    ("Float", 60, True, float_pose),
    ("Fly", 48, True, fly_pose),
    ("MeteorFly", 30, True, meteor_fly_pose),
    ("StarfireRight", 10, False, starfire_right_pose),
    ("StarfireLeft", 10, False, starfire_left_pose),
    ("StarfireFloatRight", 10, False, starfire_float_right_pose),
    ("StarfireFloatLeft", 10, False, starfire_float_left_pose),
    ("HeroPunchRight", 10, False, hero_punch_right_pose),
    ("HeroPunchLeft", 10, False, hero_punch_left_pose),
    ("HeroPunchFloatRight", 10, False, hero_punch_float_right_pose),
    ("HeroPunchFloatLeft", 10, False, hero_punch_float_left_pose),
    ("NukeThrow", 16, False, nuke_throw_pose),
    ("NukeFloatThrow", 16, False, nuke_float_throw_pose),
    ("LassoThrow", 9, False, lasso_throw_pose),
    ("LassoFloatThrow", 9, False, lasso_float_throw_pose),
    ("LassoHold", 30, True, lasso_hold_pose),
    ("LassoFloatHold", 30, True, lasso_float_hold_pose),
    ("WallPlace", 14, False, wall_place_pose),
    ("WallFloatPlace", 14, False, wall_float_place_pose),
    ("NausicaMark", 12, False, nausica_mark_pose),
    ("NausicaFloatMark", 12, False, nausica_float_mark_pose),
    ("GrappleGrab", 10, False, grapple_grab_pose),
    ("GrappleCarry", 30, True, grapple_carry_pose),
    ("Tread", 72, True, tread_pose),
    ("Swim", 36, True, swim_pose),
]


# --------------------------------------------------------------------------
# Baking
# --------------------------------------------------------------------------

def set_bone_pose(pose_bone, channels):
    """Apply world-space rotations and an offset to one bone, from rest."""
    rest = pose_bone.bone.matrix_local.to_3x3()
    world = Matrix.Identity(3)
    for axis, degrees in channels.get("rot", []):
        world = Matrix.Rotation(math.radians(degrees), 3, axis) @ world
    pose_bone.rotation_mode = "QUATERNION"
    pose_bone.rotation_quaternion = (rest.inverted() @ world @ rest).to_quaternion()
    offset = channels.get("loc")
    pose_bone.location = (rest.inverted() @ (Vector(offset) * BODY_SCALE)
                          if offset else Vector((0.0, 0.0, 0.0)))


def bake_action(rig, name, frames, looping, pose_function):
    rig.animation_data.action = None
    key_count = frames + 1 if looping else frames
    for index in range(key_count):
        # A looping clip's last key repeats phase 0, which is what makes the wrap
        # seamless; a one-shot runs to the end of its own curve.
        phase = (index % frames) / float(frames) if looping else index / float(max(frames - 1, 1))
        pose = pose_function(phase)
        frame = index + 1
        for pose_bone in rig.pose.bones:
            # Every bone is keyed on every frame, so a clip fully defines the pose
            # and cannot inherit a leftover from whichever clip ran before it.
            set_bone_pose(pose_bone, pose.get(pose_bone.name, {}))
            pose_bone.keyframe_insert(data_path="rotation_quaternion", frame=frame)
            pose_bone.keyframe_insert(data_path="location", frame=frame)

    action = rig.animation_data.action
    action.name = name
    action.use_fake_user = True

    # One track per clip, which is how the glTF exporter is asked for several
    # animations from one rig: it emits one animation per NLA track, named after
    # the track. Actions left loose in the file are not exported at all.
    rig.animation_data.action = None
    track = rig.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, 1, action)
    strip.name = name
    strip.blend_type = "REPLACE"

    print("  {0:<12} {1:>3} keys  {2:.2f}s  {3}".format(
        name, key_count, (key_count - 1) / float(FPS), "loop" if looping else "one-shot"))
    return action


def clear_pose(rig):
    for pose_bone in rig.pose.bones:
        pose_bone.rotation_mode = "QUATERNION"
        pose_bone.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pose_bone.location = Vector((0.0, 0.0, 0.0))
        pose_bone.scale = Vector((1.0, 1.0, 1.0))


def export(rig, mesh_obj):
    view_layer = bpy.context.view_layer
    for obj in view_layer.objects:
        obj.select_set(False)
    for obj in (rig, mesh_obj):
        obj.hide_viewport = False
        obj.select_set(True)
    view_layer.objects.active = rig

    bpy.ops.export_scene.gltf(
        filepath=GLB_PATH,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_skins=True,
        export_animations=True,
        export_animation_mode="NLA_TRACKS",
        # Each action carries its own length; the scene range would clip them.
        export_frame_range=False,
        export_force_sampling=True,
        export_yup=True,
    )
    print("wrote {0} ({1:.1f} KB)".format(GLB_PATH, os.path.getsize(GLB_PATH) / 1024.0))


def bake_into_open_file(blend_path: str, glb_path: str) -> None:
    """Bake every clip onto the CharacterRig already loaded in this blend.

    `build_character_3.py` calls this after measuring that body's proportions into
    the module-level constants above, so the same pose tables drive both the
    astronaut and the settler without copying actions across mismatched rests.
    """
    global BLEND_PATH, GLB_PATH
    BLEND_PATH = blend_path
    GLB_PATH = glb_path

    rig = bpy.data.objects["CharacterRig"]
    mesh_obj = bpy.data.objects["Character"]
    print("rig: {0} bones, mesh: {1} polys".format(len(rig.data.bones), len(mesh_obj.data.polygons)))
    print("proportions: leg_root={0:.3f} ankle={1:.3f} thigh={2:.3f} shin={3:.3f} arm_out={4:.1f}".format(
        LEG_ROOT_HEIGHT, ANKLE_HEIGHT, THIGH_LENGTH, SHIN_LENGTH, ARM_REST_OUT))

    bpy.context.scene.render.fps = FPS
    # New keys land on linear handles: the pose tables are already sampled per
    # frame, and bezier handles would only add overshoot between them.
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"

    if rig.animation_data is None:
        rig.animation_data_create()
    for track in list(rig.animation_data.nla_tracks):
        rig.animation_data.nla_tracks.remove(track)
    for action in list(bpy.data.actions):
        action.use_fake_user = False
        bpy.data.actions.remove(action)

    print("baking actions:")
    for name, frames, looping, pose_function in ANIMATIONS:
        bake_action(rig, name, frames, looping, pose_function)

    # glTF takes the skin from the rest pose, so the file must not be left posed.
    rig.animation_data.action = None
    clear_pose(rig)

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("wrote {0}".format(BLEND_PATH))
    export(rig, mesh_obj)


def main():
    bake_into_open_file(BLEND_PATH, GLB_PATH)


if __name__ == "__main__":
    main()
