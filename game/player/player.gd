class_name OnlinePlayer
extends CharacterBody3D

## Networked first/third person character. The local player simulates itself and
## broadcasts state; everyone else is interpolated toward the state they receive.

enum Stance { STAND, CROUCH, SLIDE, FLY, CRASH, SWIM }
enum CameraMode { FIRST, THIRD_NEAR, THIRD_FAR }

const SYNC_INTERVAL := 1.0 / 20.0
## Floor under the teleport check, in metres between two packets. What a flying
## player can legitimately cover is far more than this, so the real limit is
## worked out from their stance; see `_speed_limit`.
const MAX_ACCEPTED_STEP := 4.0

## How far in front of the eyes something can be interacted with. Measured from
## the body, not the camera, so third person is not a longer arm.
const REACH := 2.4
## Slots of the player's own inventory, the last row of which the screen lays out
## as a hotbar.
const BACKPACK_SLOTS := 36

## Weapon slots, shown on the HUD bar and filled at the wardrobe's rack. Number
## keys reach all of them; the wheel only stops on the ones holding something.
const WEAPON_SLOTS := 5
## Weapons are two-handed here, so one hand carries them and the other supports.
const WEAPON_HAND := "right"
## Where a shot is aimed: far enough that the muzzle's offset from the eye does not
## bend the line noticeably.
const AIM_RANGE := 60.0
## Field of view while sighted down the optic, as a fraction of the usual one.
const AIM_FOV_SCALE := 0.55
## Seconds a cell takes to win back one shot, and the pause after firing before it
## starts. A carbine that never reloads still has to be paced.
const CELL_RECHARGE := 0.85
const CELL_PAUSE := 0.55

## Clips baked by blender_assets/source/build_animations.py. The looping set is
## marked here because glTF carries no loop flag.
const LOOPING_CLIPS := ["Idle", "Walk", "Run", "CrouchIdle", "CrouchWalk", "Fall", "Float",
	"Fly", "Tread", "Swim"]
const CLIP_BLEND := 0.14
## How long the landing clip owns the body before locomotion takes over again.
const LAND_TIME := 0.28

# Everything below is indexed by Stance, so the rows must stay in enum order.
# Sized to the bare body in player_character.glb, which stands 1.45 m tall and
# crouches to roughly 1.2 m in the CrouchIdle pose. Worn garments deliberately do
# not resize it: a hat is not a reason to stop fitting through a gap. Flight and
# swimming both borrow the standing capsule, which is why taking off, landing and
# wading out never have to ask whether there is room.
const COLLIDER_HEIGHTS := [1.45, 1.2, 0.9, 1.45, 0.9, 1.45]
const EYE_HEIGHTS := [1.29, 1.06, 0.78, 1.29, 0.6, 1.29]

## Fraction of `fly_speed` at which the body has finished going over from an
## upright hover to flat-out flight. A quarter, so almost the whole boost is
## spent in the flying silhouette rather than on the way into it.
const FLAT_OUT := 0.25
## Flight pitches the body about its hips, in metres off the floor: turning about
## the feet would swing the head most of a body length forward. A sprint leans
## from the ankles instead, which is what keeps the feet where the clip plants
## them, so its pivot is the floor.
const LEAN_PIVOT := 0.72
## How far a flat-out run leans, in radians, and the fraction of `run_top_speed`
## at which it has finished leaning. The clip only resamples so far before the
## legs stop reading, so past a point the lean is what carries the speed.
const SPRINT_LEAN := 0.35
const GROUND_FLAT_OUT := 0.35
## How far off the ground a face has to lean before running into it ends the run
## rather than being ridden over: 0.8 is about 53 degrees from vertical, so cliffs
## and buildings stop a run and hills do not.
const RUN_BREAK_FACE := 0.8
## Clear air needed under the feet before space takes off rather than buffering a
## jump. Both read the same press in the same state, and without this the buffer
## would never fire again: a press made just before landing is exactly the press
## it exists to catch. Under a metre, space is still asking to jump on landing.
const TAKEOFF_CLEARANCE := 0.9
## How fast the body rolls square to the ground under it, in e-foldings a second
## at full blend. Roughly a third of a second to settle, which is slow enough to
## read as the planet taking hold and fast enough that a walk never lags the
## curve it is walking over.
const ALIGN_RATE := 3.0
## How far under the body a chunk collider counts as the ground it is standing
## on, in metres. The chunk mesh is a triangulation of the same height field the
## guard reads, band-limited to whatever depth that chunk happens to be at, so it
## can sit a couple of decimetres below the value sampled here. Wherever that
## mesh exists it wins: it is the surface the player can see, and arguing with it
## over the decimetre between the two is what made a body standing still jitter.
const GROUND_MARGIN := 0.5
## How far under the field the body has to be before the mesh stops getting the
## benefit of the doubt, in metres. Past this it is not resting on a triangle
## that dips, it is inside the world, and no collider gets a vote.
const TUNNEL_DEPTH := 0.8
## How close to the field counts as having something under the feet, in metres.
## `is_on_floor` asks only about the move that just happened, and on the planet
## it says no far more often than the ground warrants — a run at speed spends
## most of its frames a centimetre or two clear of the mesh, and a body that is
## airborne on a technicality gets air control, no floor snapping and no stair
## step, which is most of what "caught on every bump" is made of.
const FOOT_REACH := 0.35
## The most pieces one tick's travel is cut into for the height field to be
## asked about along it rather than only at the end of it. The pieces are the
## field's own finest spacing — about 1.5 m at the planet's defaults, which is
## the narrowest ridge it can hold — so this cap is what actually binds: it is
## reached at around 1400 m/s, and past that the pieces get longer rather than
## more numerous. See [method _rewind_to_entry].
const SWEEP_PARTS := 16
## Halvings spent narrowing a crossing once a piece has found one. Four takes a
## metre and a half down to nine centimetres, which is well inside the
## `GROUND_MARGIN` the field and the mesh disagree by anyway.
const SWEEP_REFINE := 4
## How far the camera keeps off the ground, in metres. Its near plane is 0.1 m
## and the field is a smoothed copy of the mesh, so this is that plane plus the
## couple of decimetres the two can differ by.
const CAMERA_CLEARANCE := 0.45

## How hard a flight has to meet something solid before it becomes a crash, in
## metres a second into the surface. Well above `float_speed`, so nudging a wall
## while hovering just stops the body, and well under a boost, so any real flight
## into a hillside puts the player down.
const CRASH_SPEED := 26.0
## How hard a surface has to be met before the limb that met it is knocked loose,
## in metres a second into it. Above a sprint, so walking into a doorway does
## nothing, and well under `CRASH_SPEED`, so there is a band of impacts that are
## worth feeling without being worth falling over.
const KNOCK_SPEED := 9.0
## The impulse a knock is worth, in newton-seconds per metre a second of impact,
## and the speed past which more of it buys nothing. An arm is a couple of kilos,
## so a graze at the threshold moves it at walking pace and the hardest knock
## short of a crash throws it at a run. Anything more and a clipped shoulder
## looks like a dislocation.
const KNOCK_WEIGHT := 1.2
const KNOCK_SPEED_CAP := 20.0
## How much of the way to straight up a contact normal has to be before it counts
## as the floor rather than as something hit. The same line `floor_max_angle`
## draws, near enough, and drawn again here because a knock reads the raw normals
## rather than asking the body what it is standing on.
const FLOOR_FACE := 0.7
## Seconds spent on the ground before getting up, and how much of that is spent
## getting up rather than lying there.
const CRASH_TIME := 1.7
const CRASH_RISE := 0.55
## What the body keeps of the impact, in m/s along the ground. A crash is a
## tumble, not a redirection: 200 m/s carried into the slide would take the
## player most of a kilometre from where they hit.
const CRASH_SLIDE := 11.0
## How quickly the tumble sheds that, in m/s².
const CRASH_FRICTION := 9.0
## Seconds the capsule takes to close whatever gap has opened between it and the
## limp body, and the m/s it is allowed to spend doing it. The cap is what keeps
## a bone that has found its way somewhere the capsule cannot follow from firing
## the player across the ground after it.
const CRASH_CHASE_TIME := 0.22
const CRASH_CHASE_SPEED := 26.0
## How far away the body may be and still be worth chasing, metres. Past this it
## is not a tumble that got ahead of the capsule, it is a body somewhere the
## capsule was never going to reach — through a wall, down a shaft, or left
## behind by a teleport. Chasing it then tows the player across the world, which
## is a worse answer than losing sight of them for the second it takes to stand
## back up.
const CRASH_CHASE_REACH := 6.0
## Radians a second the body rolls at, per metre a second of impact, and the
## range that is allowed to reach. Taken from the whole impact rather than from
## the speed left along the ground: a dive straight down has almost no ground
## speed and would otherwise stand bolt upright through its own crash.
const TUMBLE_PER_SPEED := 0.16
const TUMBLE_RATE_RANGE := Vector2(4.0, 13.0)
## How fast the roll winds down, in e-foldings a second.
const TUMBLE_DECAY := 1.6
## How much of the body has to be under water before the feet stop being any use,
## and how little of it has to be left under before they are again. Two numbers
## rather than one, because a swimmer floats at `1 / buoyancy` submerged and a
## single threshold anywhere near that would flicker between stroke and stride.
## The gap reads as: swim once the water is chest deep, stand up again in knee
## deep water with something under the feet.
const SWIM_ENTER := 0.7
const SWIM_EXIT := 0.5
## Seconds a swimmer has to press jump a second time to launch into flight, and
## the reason the first press is not enough: jump is also the up-stroke, so a
## single press has to stay the way a swimmer reaches the surface or nobody can
## surface at all. Holding sprint was the old rule and did the same job, but it
## is a key combination nobody finds; two presses of the one key already in the
## swimmer's hand is the same idea written where it can be discovered.
const SWIM_LAUNCH_WINDOW := 0.4
## How hard the surface has to be crossed before it is worth a splash, in m/s
## along the radius. Wading in makes none.
const SPLASH_SPEED := 3.5

## How far the soles may be off the height field and still be in the snow, in
## metres. A stride is not level and the guard leaves a little slack under the
## feet, so this is a hand's width and not zero.
const PRINT_FOOTING := 0.6
## Ground a tick may cover and still count as walking, in metres. Above the
## 3.4 m a fully wound run covers in a frame, and far below any teleport: this
## is what stops a spawn or a ground-guard rewind stamping a print.
const PRINT_MAX_STEP := 4.5

## Degrees the view opens by, flat out on the ground or in the air. Speed reads as
## how much of the world is in shot, and at 200 m/s there is no scenery close
## enough to read it any other way. Absolute rather than a fraction of the
## player's own field of view, which the Settings screen lets them take to 110
## before this is added to it.
const SPEED_FOV_RUSH := 18.0

# Indexed by CameraMode.
const ARM_LENGTHS := [0.0, 1.9, 3.8]
const SHOULDER_OFFSETS := [0.0, 0.45, 0.62]

@export var peer_id := 1
@export var display_name := "Player"

@export_group("Movement")
@export var walk_speed := 4.6
## What shift gives immediately, and what a held shift then winds the run up to
## over `run_spool_time`. There is no stamina anywhere in here: the only things
## that end a run are letting go of forward and hitting something.
##
## The spool time is the whole cost of the wind-up, and it is deliberately long:
## the top speed crosses a chunk of ground per second, so reaching it in a few
## seconds means arriving somewhere unread. At 30 s the target climbs about
## 6.6 m/s², which is a shade under the planet's own pull and leaves plenty of
## time to see what is coming and turn off it.
@export var sprint_speed := 7.6
@export var run_top_speed := 205.0
@export var run_spool_time := 30.0
## Extra friction per m/s above a sprint, once forward is released. Zero below a
## sprint, so an ordinary walk still stops on `ground_friction` alone and only a
## real run skids.
@export var coast_drag := 0.8
## Metres of floor snapping per m/s of run, on top of the body's own. At 200 m/s
## the feet cross three and a half metres between frames, and ground that falls
## away faster than the scene's 0.3 m over that distance throws the body into the
## air: without this a run over rolling ground is a series of involuntary jumps.
## Nine centimetres per m/s reaches eighteen metres flat out, which is about what
## a crest on this terrain drops over one frame's worth of ground.
@export var run_snap := 0.09
@export var crouch_speed := 2.3
## Launch speed of a standing jump, m/s. Against the planet's 34 m/s² that is an
## apex of `v² / 68` and an airtime of `v / 17`, so twelve buys 2.1 m and seven
## tenths of a second in the air.
##
## The airtime is the point of the number and the height is a side effect. Space
## in mid-air takes off, and take-off needs `TAKEOFF_CLEARANCE` of clear ground
## underneath — so a jump whose whole arc is shorter than that cannot become a
## flight at all, however early the key is pressed. At 5.6 the apex was 0.46 m
## and it never could: the only ways into the air were a sprint jump and a
## ledge. Twelve leaves rather more than half a second above the line, which is
## a window rather than a frame to hit.
@export var jump_velocity := 12.0
## How much taller a jump gets at the top of a run, as a multiple of the standing
## one. Speed carried into a jump is already kept; this is the run also buying
## height, so a flat-out leap clears things a sprint could not.
##
## Cut when the standing jump was raised, because it multiplies it: a flat-out
## leap is 21.6 m/s and about seven metres, and the ceiling on it is `CRASH_SPEED`
## — land faster than 26 m/s and the jump puts the player down on their face.
@export var jump_speed_gain := 0.8
## Grace windows that make jumping forgiving: `coyote_time` still lets you jump
## just after walking off an edge, `jump_buffer` remembers a press made just
## before landing.
@export var coyote_time := 0.12
@export var jump_buffer := 0.12
@export var ground_accel := 60.0
@export var ground_friction := 48.0
## Deliberately weak, so speed carried into a jump survives the flight.
@export var air_accel := 14.0

@export_group("Steps")
## Ledges up to about shin height are climbed on the way past, so kerbs and prop
## edges do not stop a run dead.
@export var step_height := 0.3
## Seconds for the visuals to catch up after a step, so a climb eases instead of
## snapping the camera upwards.
@export var step_smooth_time := 0.08

@export_group("Flight")
## Hovering speed, and the speed a held boost winds up to. Deliberately an order
## of magnitude apart: the point of the boost is that the world changes character
## on the way up, not that the character gets a little brisker.
##
## The hover is faster on the level and on the way down than it is straight up.
## Climbing is the one direction that is worked for, so it is the one direction
## that is not free; everything else reads as gliding and wants the pace to match.
@export var float_speed := 20.0
@export var climb_speed := 11.0
@export var fly_speed := 1000.0
## Seconds to cross the whole speed range, on the boost and coasting back off it.
## There is no brake key: the only way down from a thousand metres a second is to
## stop asking for a direction, which is also the only thing a body at that speed
## could plausibly do.
@export var boost_time := 4.0
@export var ease_time := 2.4
## Acceleration onto a new heading, and how much of it is bought back per metre
## per second of cruise. The second term is what makes a turn at 200 m/s a wide
## arc and a turn at hovering speed a pivot.
@export var flight_accel := 34.0
@export var flight_turn := 2.0
## Drag with nothing held. The second term is per m/s carried, because a flat
## rate that stops a hover in a quarter of a second would take half a minute to
## shed a thousand.
@export var flight_drag := 42.0
@export var flight_coast := 0.9
## How close the feet may come to the ground while floating before the flight
## simply ends, in metres. Only while floating: at speed the ground arrives
## faster than any probe could warn about it, and `is_on_floor` catches that.
@export var land_clearance := 1.4

@export_group("Swim")
## Steady stroke, and how quickly the body gets onto it. Slow on purpose: an
## unhurried swim is the contrast the boost below is measured against.
@export var swim_speed := 3.4
@export var swim_accel := 16.0
## What a held sprint winds the stroke up to, and the seconds it takes to get
## there and to coast back off it. The same idea as the flight boost and a fifth
## of its pace: the sea is nine kilometres of open water on this planet and
## crossing it at walking speed is not a swim, it is a wait.
##
## Only ever wound up while a direction is being asked for, for the reason given
## in [method _fly_move] — otherwise a player holding sprint while treading water
## charges a launch they cannot see coming.
@export var swim_sprint_speed := 100.0
@export var swim_boost_time := 6.0
@export var swim_ease_time := 2.0
## Extra stroke acceleration per m/s of the wound-up target. **Must stay above
## [member water_drag]**, and that is a hard requirement rather than a taste: drag
## takes `water_drag * v` off the body every second, so a target the stroke cannot
## push that hard against is a target the body never arrives at. At 2.6 e-foldings
## and a hundred metres a second the stroke has to find 260 m/s² just to stand
## still, against the 16 an unhurried one uses.
@export var swim_surge := 4.0
## Lift as a multiple of the planet's own pull, at full submersion. Written as a
## ratio rather than in m/s² so that retuning gravity does not quietly sink
## everyone: the body settles at `1 / buoyancy` of itself under, which at 1.25 is
## floating with the head and shoulders out.
@export var buoyancy := 1.25
## Drag under the surface, in e-foldings a second. It is what makes an entry from
## a dive stop in tens of metres rather than hundreds, and it applies to a flight
## passing through as well as to a swimmer.
@export var water_drag := 2.6

@export_group("Slide")
@export var slide_speed := 10.5
## Horizontal speed needed before crouch turns into a slide instead of a crouch.
@export var slide_entry_speed := 4.6
@export var slide_exit_speed := 3.6
@export var slide_friction := 5.2
@export var slide_max_time := 1.3
## Seconds added to a slide at the top of a run. The slide is as long as the run
## that earned it; see `_start_slide` for why the duration is the dial and the
## friction is solved from it.
@export var slide_time_gain := 2.0
@export var slide_cooldown := 0.4
@export var slide_steer := 2.4

@export_group("Arctic")
## What pack ice does to the walk, as multipliers on the ordinary numbers.
##
## The friction is the whole effect and the acceleration only sells it: ice does
## not push you along, it stops taking anything back, so a stride that would
## have been spent against `ground_friction` is kept and the next one is added to
## it. That reads as accelerating faster even though the accel term barely moves,
## and it is also what makes stopping a problem, which is the point.
@export var ice_friction := 0.06
@export var ice_accel := 1.3
## And what a foot of snow does, which is the opposite of all three: slower to
## reach, slower once reached, and quicker to give up.
@export var snow_speed := 0.6
@export var snow_accel := 0.45
@export var snow_friction := 1.7

@export_group("Look")
@export var mouse_sensitivity := 0.0025
@export var invert_y := false

@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var ceiling_check: RayCast3D = $CeilingCheck
@onready var character: Node3D = $Character
## Absent when the .glb was exported without its clips, which the controller has
## to survive: the character is still fully playable, just stiff.
@onready var animator: AnimationPlayer = get_node_or_null("Character/AnimationPlayer")
@onready var head: Node3D = $Head
@onready var camera_arm: SpringArm3D = $Head/CameraArm
@onready var camera: Camera3D = $Head/CameraArm/Camera3D
@onready var aim_ray: RayCast3D = $Head/CameraArm/Camera3D/AimRay
@onready var hud: CanvasLayer = $HUD
@onready var reticle: Reticle = $HUD/Reticle
## Each HUD line is a label on a drawn plate, and the plate is what gets hidden:
## an empty one would read as a blank sticker over the world.
@onready var target_plate: Control = $HUD/Prompts/TargetPlate
@onready var prompt_plate: Control = $HUD/Prompts/PromptPlate
@onready var target_name: Label = $HUD/Prompts/TargetPlate/Panel/Padding/TargetName
@onready var interact_prompt: Label = $HUD/Prompts/PromptPlate/Panel/Padding/InteractPrompt
@onready var stance_label: Label = $HUD/Prompts/StancePlate/Panel/Padding/Stance
@onready var flight_plate: Control = $HUD/Prompts/FlightPlate
@onready var flight_speed_label: Label = $HUD/Prompts/FlightPlate/Panel/Padding/Lines/Speed

var controls_enabled := true

## Set before the node enters the tree to spawn the local player without giving it
## the viewport or the mouse. The home screen does this so it can keep its own
## camera and sweep it into place, which is what makes starting a game read as a
## camera move rather than a cut.
var defer_camera := false

## What the player is wearing, one slot per body slot in ItemDB.SLOT_ORDER, the
## weapons they have racked, and what they are carrying. All three are handed to
## menus to work on directly; the garments on the body and the weapon in the hands
## follow whatever the containers end up holding.
var equipment := ItemContainer.new(ItemDB.SLOT_ORDER.size())
var weapons := ItemContainer.new(WEAPON_SLOTS)
var backpack := ItemContainer.new(BACKPACK_SLOTS)

## What this player is made of, listed on the inventory tab and editable from the
## admin tab. Health is carried but nothing spends it yet; Speed is wired through
## to the three speed exports below.
var stats := PlayerStats.new()

## Quests and achievements. Local and never replicated — a session shares a world,
## not a diary — which is why this is built here rather than handed down from the
## host with the rest of the spawn metadata.
var journal := Journal.new()

var _stance: int = Stance.STAND
var _camera_mode: int = CameraMode.FIRST
var _shoulder := 1.0
## The speed the run has wound up to, which is what the legs are actually asked
## for. It survives letting go of shift — that is the whole point of winding it
## up — and only forward being released or something solid takes it away.
var _run_speed := 0.0
var _slide_time := 0.0
## This slide's own length and the friction solved to fit it, both fixed when it
## started, because both are proportional to the run that earned it.
var _slide_span := 0.0
var _slide_drag := 0.0
var _slide_ready_in := 0.0
var _coyote_left := 0.0
var _jump_buffered := 0.0
var _pitch := 0.0
var _eye_height := EYE_HEIGHTS[Stance.STAND]
## Distance the visuals still trail the collider by after a step, always <= 0.
var _step_offset := 0.0
## The speed flight is currently asking for, which the boost and the brake move
## and the velocity chases. Holding the target apart from the velocity is what
## lets the boost read as a long wind-up rather than as raw acceleration.
var _cruise := 0.0
## The same, for a swim. Separate from `_cruise` rather than shared, because a
## flight through water clamps that one to a hover on the way through and a
## swimmer surfacing into a launch would inherit whichever of the two ran last.
var _stroke := 0.0
## Seconds left face down after a crash, and how far the body has rolled getting
## there. The roll is an angle rather than a clip because there is no crash clip
## to play: the tumble is the body's own lean pivot driven round instead.
var _crash_left := 0.0
var _tumble := 0.0
var _tumble_rate := 0.0
## Crashes since the body spawned. Only the harness reads it.
var _crashes := 0
## What the flight was doing at the start of the last frame it flew. The speed at
## the moment of a collision is already gone by the time the collision can be
## noticed, so this is what says whether the ground was landed on or hit.
var _flight_velocity := Vector3.ZERO
## 0 hovering upright, 1 flat out, smoothed. It drives the body's lean, the
## camera's field of view and which of the two flight clips plays, and all three
## would pop on landing if they read the speed directly.
var _fly_blend := 0.0
## The same, for a swim: 0 treading water, 1 laid out along the stroke. Separate
## from `_fly_blend` because that one also opens the field of view, and a 3.4 m/s
## breaststroke has no business doing that.
var _swim_blend := 0.0
## How much of the swim boost is engaged, smoothed: 0 on the unhurried stroke, 1
## wound right up. This is the swim's half of the field of view, and it is a
## second number rather than `_swim_blend` for the reason written above that one —
## the lean is finished by the second stroke and the rush has barely started.
var _swim_rush := 0.0
## The same, for a run: 0 at a sprint, 1 flat out along the ground.
var _run_blend := 0.0
## Time left on the window a swimmer's second jump press has to land in to become
## a take-off. See [constant SWIM_LAUNCH_WINDOW].
var _swim_launch_left := 0.0
## The scene's own floor snapping, put back when the feet come down. Snapping is
## what would otherwise pull a low hover onto the ground.
var _floor_snap := 0.0
var _planet: Planet
## Whether there was ground under the feet at the end of the last physics frame,
## by the height field rather than by the collider. Set in [method _catch_ground],
## read through [method _grounded]. A frame stale, which at a walk is a couple of
## centimetres and at a run is ground the guard has already had its say about.
var _footed := false
## Radius the height field puts the ground at under the body, as of the last
## [method _catch_ground], or negative where there is no planet to measure from.
## Kept so the ragdoll can be handed the number the guard has just worked out
## rather than working it out again. A sample is 2 us — cheap enough that the
## sweep below spends twenty of them a tick without it showing — so this is
## tidiness, not thrift, and anything that wants its own may take one.
var _ground_radius := -1.0
## Where this physics tick's movement started, so the height field can be asked
## about the path the body took and not only about where it ended up. Written
## once at the top of [method _simulate_local_player], which is the one place
## every move in this file goes through.
var _swept_from := Vector3.ZERO
## How arctic the ground under the feet is, 0 to 1, and whether that ground is
## pack ice rather than snow over land. Read once a tick by
## [method _read_surface] because the walk needs them *before* it accelerates,
## and [method _catch_ground] — the only other place that talks to the height
## field — does not run until after.
var _frost := 0.0
var _on_ice := false
## Metres walked since the last footprint was put down, which foot is next, and
## where the body was when the count was last taken. The last of the three is
## kept here rather than reusing [member _swept_from] because prints are tracked
## for remote players too, and nothing writes that one for a body that is
## interpolated rather than simulated.
var _since_print := 0.0
var _left_foot := false
var _print_from := Vector3.INF
## The ragdoll on the character's skeleton, or null on a body whose .glb came
## without one — in which case a crash falls back to the tumble in [method _lay_out].
var _ragdoll: Ragdoll
## Whether the feet were under the surface last frame. Only the change matters —
## it is what a splash is drawn from — and it is tracked for remote players too,
## so everyone sees everyone else go in.
var _submerged := false
var _character_meshes: Array[MeshInstance3D] = []
## Body slot to the item worn in it, so only garments that changed are reloaded.
var _worn: Dictionary = {}
var _menu_open := false
## Which CharacterDB body this player is wearing. Drives the .glb under
## `character`, the collider heights, and which apparel is allowed on it.
var _body_id := CharacterDB.DEFAULT_BODY
var _body_height := 1.45
var _body_eye := 1.29
var _body_lean := LEAN_PIVOT
## Sparse slot/"body" → Color, applied after SurfaceSkin so a tint washes the
## authored albedo rather than replacing the material.
var _tints: Dictionary = {}
## Walk, sprint and crouch speeds as the exports were authored, captured before the
## Speed stat is allowed to scale them. Kept because the stat is a multiplier over
## all three: reading them back off themselves would compound every change, so a
## player set to 6 m/s and back to 4.6 would not end up where it started.
var _authored_speeds := Vector3.ZERO

## The weapon slot the bar is on, and the item id actually in the hands. They only
## differ while an empty slot is selected.
var _weapon_slot := 0
var _held := ""
var _held_mesh: MeshInstance3D
var _weapon_pose: WeaponPose
var _weapon_bar: WeaponBar
var _waypoints: WaypointLayer
## Where the player is, in terms that can be read out to somebody else. On by
## default and toggled with `coordinates`, because it exists to be quoted when
## something looks wrong and a readout nobody knows about would never be.
var _coordinates: CoordinatePlate
var _coordinates_wanted := true
## Charge left per weapon id, kept while a weapon is put away so switching is not
## a way to refill it. Fractional, because it trickles back up.
var _cells: Dictionary = {}
var _cell_pause := 0.0
var _base_fov := 75.0
var _clip := ""
var _land_left := 0.0
var _was_airborne := false

var _sync_elapsed := 0.0
var _target_transform := Transform3D.IDENTITY
var _target_velocity := Vector3.ZERO
var _target_pitch := 0.0
var _host_last_position := Vector3.ZERO
var _host_has_state := false
## Seconds the remote target has been carried forward on its own velocity since
## the last packet, so a peer that has gone quiet coasts to a stop rather than
## flying off on the last heading it was seen holding.
var _extrapolated := 0.0


func _ready() -> void:
	add_to_group("network_players")
	var settings := get_node_or_null("/root/SettingsManager")
	if settings != null and settings.has_method("get_setting"):
		mouse_sensitivity = float(settings.call("get_setting", &"gameplay", &"mouse_sensitivity", 0.35)) / 140.0
		invert_y = bool(settings.call("get_setting", &"gameplay", &"invert_y", false))
		camera.fov = float(settings.call("get_setting", &"gameplay", &"fov", 75.0))

	_base_fov = camera.fov
	_floor_snap = floor_snap_length
	_cruise = float_speed
	_run_speed = walk_speed

	# The exports are where feel is tuned, so the stat starts from them rather than
	# from its own table default, and the table's figure is only a fallback for
	# anything holding stats without a body.
	_authored_speeds = Vector3(walk_speed, sprint_speed, crouch_speed)
	stats.set_base(PlayerStats.SPEED, walk_speed)
	stats.changed.connect(_on_stat_changed)

	for index in ItemDB.SLOT_ORDER.size():
		equipment.set_filter(index, ItemDB.SLOT_ORDER[index])
	equipment.changed.connect(_on_equipment_changed)
	for index in WEAPON_SLOTS:
		weapons.set_filter(index, ItemDB.WEAPON)
	weapons.changed.connect(_on_weapons_changed)
	# Local players take the saved look; remote peers get apply_look from the
	# spawn metadata a moment later, which swaps the body before the first frame
	# of gameplay if it differs from the scene default.
	if peer_id == multiplayer.get_unique_id():
		apply_look(CharacterDB.load_look())
	else:
		_bind_character_nodes()
		_character_meshes = SurfaceSkin.apply(character)
		_prepare_animations()
		_add_weapon_pose()
		_add_ragdoll()
	# The arm would otherwise pull the camera in on our own capsule, and the aim
	# ray would report us as the thing under the crosshair in third person.
	camera_arm.add_excluded_object(get_rid())
	aim_ray.add_exception(self)
	_apply_stance(_stance)

	# The plate is drawn behind the padding rather than behind the wrapper, so it
	# hugs the text instead of spanning the screen.
	for panel: PanelContainer in [
		$HUD/Prompts/TargetPlate/Panel,
		$HUD/Prompts/PromptPlate/Panel,
		$HUD/Prompts/StancePlate/Panel,
		$HUD/Prompts/FlightPlate/Panel,
	]:
		PencilSurface.add_to(panel, PencilSurface.Style.HUD)
	flight_plate.visible = false

	var is_local := peer_id == multiplayer.get_unique_id()
	camera.current = is_local and not defer_camera
	hud.visible = is_local and not defer_camera
	_target_transform = global_transform
	_host_last_position = global_position
	if is_local:
		# Only the local player needs a bar: each one carries a viewport for its
		# icons, and nobody sees anyone else's HUD.
		_weapon_bar = WeaponBar.new()
		hud.add_child(_weapon_bar)
		_weapon_bar.bind(weapons)
		_weapon_bar.select(_weapon_slot)
		# Behind the bar, so a waypoint pinned to the bottom of the screen does
		# not sit over the weapon icons.
		_waypoints = WaypointLayer.new()
		hud.add_child(_waypoints)
		hud.move_child(_waypoints, 0)
		_waypoints.bind(camera)
		_coordinates = CoordinatePlate.new()
		_coordinates.body = self
		hud.add_child(_coordinates)
		if not defer_camera:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Takes the viewport, the mouse and the HUD, for a player spawned with
## [member defer_camera] set. Idempotent: a player that already has them keeps
## them.
func take_camera() -> void:
	defer_camera = false
	if peer_id != multiplayer.get_unique_id():
		return
	camera.current = true
	hud.visible = true
	controls_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_camera_mode(mode: CameraMode) -> void:
	_camera_mode = mode


func reset_network_state(at_transform: Transform3D) -> void:
	_target_transform = at_transform
	_host_last_position = at_transform.origin
	_host_has_state = true
	_extrapolated = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if peer_id != multiplayer.get_unique_id() or not controls_enabled:
		return
	# Clicking back into a window that has let the cursor go is only ever about
	# taking it again, so it happens before the click can also be an attack.
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Sighted down the optic, the same hand movement should cover less ground.
		var sensitivity := mouse_sensitivity * (1.0 - 0.5 * _aim_amount())
		# About the body's own up rather than the parent's. `rotate_y` takes its
		# axis in parent space, which on a sphere is the way up at exactly one
		# point on it; anywhere else it tips the body off the ground instead of
		# turning it on the spot, and the radial alignment then hauls it back.
		# What is left of the turn is the part of the mouse that happened to lie
		# along the local up, which near the equator of the parent's Y is none of
		# it — a view that will not turn.
		rotate_object_local(Vector3.UP, -event.relative.x * sensitivity)
		var vertical_sign := -1.0 if not invert_y else 1.0
		_pitch = clampf(_pitch + event.relative.y * sensitivity * vertical_sign, -1.48, 1.48)
		head.rotation.x = _pitch
	elif event.is_action_pressed("cycle_camera"):
		_camera_mode = wrapi(_camera_mode + 1, 0, CameraMode.size())
	elif event.is_action_pressed("swap_shoulder"):
		_shoulder = -_shoulder
	elif event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("coordinates"):
		_coordinates_wanted = not _coordinates_wanted
		if _coordinates != null:
			_coordinates.visible = _coordinates_wanted
	elif event.is_action_pressed("inventory"):
		_open_game_menu(GameMenu.Tab.INVENTORY)
	elif event.is_action_pressed("pause"):
		_open_game_menu(GameMenu.Tab.SETTINGS)
	elif event.is_action_pressed("attack"):
		_attack()
	elif event.is_action_pressed("weapon_next"):
		_cycle_weapon(1)
	elif event.is_action_pressed("weapon_prev"):
		_cycle_weapon(-1)
	else:
		for index in WEAPON_SLOTS:
			if event.is_action_pressed("weapon_%d" % (index + 1)):
				select_weapon(index)
				return


func _process(delta: float) -> void:
	_update_step_offset(delta)
	_update_body_lean(delta)
	_update_camera(delta)
	_update_animation(delta)
	if _weapon_pose != null:
		# Everyone's, not just our own: a remote player's pitch is synced, and their
		# barrel should point where they are looking.
		_weapon_pose.set_pitch(_pitch)
	if peer_id == multiplayer.get_unique_id():
		_update_weapon(delta)
		_update_hud(delta)


func _physics_process(delta: float) -> void:
	var is_local := peer_id == multiplayer.get_unique_id()
	if is_local and controls_enabled:
		_simulate_local_player(delta)
		_update_target_label()
		journal.track(global_position, get_tree(), delta)
		_sync_elapsed += delta
		if _sync_elapsed >= SYNC_INTERVAL:
			_sync_elapsed = 0.0
			if multiplayer.is_server():
				_host_last_position = global_position
				_host_has_state = true
				_apply_state.rpc(global_transform, velocity, _pitch, _stance)
			else:
				_submit_state.rpc_id(1, global_transform, velocity, _pitch, _stance)
	elif not is_local:
		# A packet is 50 ms of travel, which at flight speed is ten metres: sitting
		# on the last one until the next arrives would leave a flying peer a whole
		# building behind where they are. The target is carried forward on its own
		# velocity instead, for a couple of packets' worth and no further.
		if _extrapolated < SYNC_INTERVAL * 2.0:
			_target_transform.origin += _target_velocity * delta
			_extrapolated += delta
		global_transform = global_transform.interpolate_with(_target_transform, minf(delta * 14.0, 1.0))
		velocity = _target_velocity
		_pitch = lerpf(_pitch, _target_pitch, minf(delta * 14.0, 1.0))
		head.rotation.x = _pitch
	# For everyone, and outside both branches: a remote player's position and
	# velocity are both known here, so their entry throws up its own splash
	# without a packet having to be spent saying so.
	_track_water_crossing()
	_track_footprints()


# --- Interaction and clothes ------------------------------------------------

## Whatever is under the crosshair within arm's reach, if it is something that
## can be used. Cast from the camera so it agrees with what the player is looking
## at, and lengthened by the spring arm so third person does not shorten the
## reach measured from the body.
func _interact_target() -> Node:
	var from := camera.global_position
	var query := PhysicsRayQueryParameters3D.create(
		from, from - camera.global_basis.z * (REACH + camera_arm.spring_length))
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var node := hit.get("collider") as Node
	if node != null and node.has_method("interact") and node.has_method("interact_prompt"):
		return node
	return null


func _interact() -> void:
	var target := _interact_target()
	if target != null:
		target.call("interact", self)


## Tab and Escape are the same menu opened at a different tab. Both are handled
## here rather than in the world, because everything on the menu's first page — the
## containers, the stats, the body — belongs to this player, and the pause overlay
## they replaced had nothing on it that did not.
func _open_game_menu(tab: GameMenu.Tab) -> void:
	if _menu_open:
		return
	var menu := GameMenu.new()
	menu.configure(self)
	menu.closed.connect(_on_game_menu_closed)
	menu.leave_requested.connect(_on_leave_requested)
	open_menu()
	hud.add_child(menu)
	menu.show_tab(tab)
	# The world decides what being in a menu costs: a real stop in single player, a
	# local one in company. Asked after open_menu, which is what took the mouse.
	var world := NetworkManager.active_world as GameWorld
	if world != null:
		world.set_local_pause(true)


func _on_game_menu_closed() -> void:
	close_menu()
	var world := NetworkManager.active_world as GameWorld
	if world != null:
		world.set_local_pause(false)


func _on_leave_requested() -> void:
	var world := NetworkManager.active_world as GameWorld
	if world != null:
		world.leave_session()


## Sparse slot/"body" → HTML colour, as CharacterDB stores them, for a menu that
## wants to show what is already applied.
func tints() -> Dictionary:
	var out: Dictionary = {}
	for target: String in _tints:
		out[target] = Color(_tints[target]).to_html()
	return out


## Recolours one garment or the skin, on the body and in the saved look. Called by
## the colour strip on the inventory tab; the tint is not replicated, for the same
## reason the rest of the look is broadcast by whoever changed it rather than by the
## host — see [method broadcast_look].
func set_tint(target: String, colour: Color) -> void:
	_tints[target] = colour
	_apply_tints()
	if peer_id != multiplayer.get_unique_id():
		return
	var look := CharacterDB.load_look()
	var saved: Dictionary = look.get("tints", {})
	saved[target] = colour.to_html()
	look["tints"] = saved
	CharacterDB.save_look(look)


## The Speed stat is one multiplier over all three speed exports, taken against
## what they were authored as. Scaling them together is what keeps a sprint faster
## than a walk however far the stat is moved.
func _on_stat_changed(id: StringName, value: float) -> void:
	if id != PlayerStats.SPEED:
		return
	var scale := value / maxf(_authored_speeds.x, 0.01)
	walk_speed = _authored_speeds.x * scale
	sprint_speed = _authored_speeds.y * scale
	crouch_speed = _authored_speeds.z * scale


## A menu has the mouse. The body keeps being simulated so it still falls and is
## still synced, but it stops taking input and the crosshair gets out of the way.
func open_menu() -> void:
	_menu_open = true
	controls_enabled = false
	if _weapon_pose != null:
		_weapon_pose.set_aimed(false)
	reticle.visible = false
	prompt_plate.visible = false
	target_name.text = ""
	target_plate.visible = false
	# The menu carries a rack of its own showing the same slots, and the bar would
	# otherwise sit half behind the card.
	if _weapon_bar != null:
		_weapon_bar.visible = false
	if _waypoints != null:
		_waypoints.visible = false
	if _coordinates != null:
		_coordinates.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_menu() -> void:
	_menu_open = false
	controls_enabled = true
	reticle.visible = true
	if _weapon_bar != null:
		_weapon_bar.visible = true
	if _waypoints != null:
		_waypoints.visible = true
	# Back to what it was, not to on: the menu is not a reason to undo a toggle.
	if _coordinates != null:
		_coordinates.visible = _coordinates_wanted
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The look other peers should draw this player in, for someone who has just
## joined and missed the change.
func worn_items() -> PackedStringArray:
	return equipment.items()


func body_id() -> String:
	return _body_id


## Body, clothes and tints in one shot. Used by the spawn path (metadata) and by
## the local player's own _ready. Swapping the .glb rewires animation, weapon
## pose and ragdoll, because all three hang off the skeleton that just changed.
func apply_look(look: Dictionary) -> void:
	var next_body := CharacterDB.sanitize_body(str(look.get("body", CharacterDB.DEFAULT_BODY)))
	_tints = {}
	var tint_raw: Variant = look.get("tints", {})
	if tint_raw is Dictionary:
		for key: Variant in tint_raw:
			var parsed := Color.html(str(tint_raw[key]))
			_tints[str(key)] = parsed
	_set_body(next_body)
	var worn := CharacterDB.worn_items(look)
	if worn.is_empty() and look.get("worn", null) == null:
		worn = equipment.items()
	apply_worn(worn)
	_apply_tints()


func _set_body(next_body: String) -> void:
	next_body = CharacterDB.sanitize_body(next_body)
	_body_height = CharacterDB.height(next_body)
	_body_eye = CharacterDB.eye_height(next_body)
	_body_lean = CharacterDB.lean_pivot(next_body)
	_bind_character_nodes()
	# player.tscn ships the astronaut. Meta records which .glb is actually under
	# `character`, so a second apply_look with the same id is a no-op and a first
	# apply from the scene default still swaps when the id is settler.
	var mounted := ""
	if character != null and is_instance_valid(character):
		mounted = String(character.get_meta("character_body_id", ""))
	if mounted == next_body and _body_id == next_body:
		return
	_body_id = next_body
	var packed := CharacterDB.scene(next_body)
	if packed == null:
		push_error("OnlinePlayer: missing body scene for '%s'" % next_body)
		return
	var fresh := packed.instantiate() as Node3D
	fresh.set_meta("character_body_id", next_body)
	# The old body has to leave before the new one arrives: two siblings cannot
	# both be called "Character", and Godot resolves that by renaming the one
	# being added. Everything downstream looks the body up by that name, so the
	# swap used to leave the player with no character at all.
	var parent: Node = self
	var index := -1
	var old := character
	if old != null and is_instance_valid(old):
		parent = old.get_parent()
		index = old.get_index()
		parent.remove_child(old)
		old.free()
	fresh.name = "Character"
	parent.add_child(fresh)
	if index >= 0:
		parent.move_child(fresh, index)
	_worn.clear()
	_bind_character_nodes()
	_character_meshes = SurfaceSkin.apply(character)
	_prepare_animations()
	_add_weapon_pose()
	_add_ragdoll()
	_apply_stance(_stance)


func _bind_character_nodes() -> void:
	character = get_node_or_null("Character") as Node3D
	animator = get_node_or_null("Character/AnimationPlayer") as AnimationPlayer


func _apply_tints() -> void:
	# Re-paint from the mesh albedo first so a second dress cannot compound a
	# previous tint into a darker and darker wash.
	var body_tint: Color = _tints.get("body", Color.WHITE)
	for mesh_instance in _character_meshes:
		if mesh_instance == null or not is_instance_valid(mesh_instance):
			continue
		if String(mesh_instance.name).begins_with(Wardrobe.NODE_PREFIX):
			continue
		SurfaceSkin.paint(mesh_instance)
		if body_tint != Color.WHITE:
			SurfaceSkin.tint(mesh_instance, body_tint)
	for slot: String in ItemDB.SLOT_ORDER:
		var garment: MeshInstance3D = null
		for node in character.find_children(Wardrobe.NODE_PREFIX + slot, "MeshInstance3D", true, false):
			garment = node as MeshInstance3D
			break
		if garment == null:
			continue
		SurfaceSkin.paint(garment)
		if _tints.has(slot):
			SurfaceSkin.tint(garment, _tints[slot])


func apply_worn(worn: PackedStringArray) -> void:
	# Routed through the container rather than straight onto the skeleton, so a
	# remote player's look is held in the same place as the local player's and
	# only one function ever adds or removes a garment.
	for index in mini(worn.size(), equipment.size()):
		equipment.set_item(index, worn[index])


func _on_equipment_changed() -> void:
	_dress()
	if peer_id == multiplayer.get_unique_id() and multiplayer.has_multiplayer_peer():
		_wear.rpc(equipment.items())


## Puts the body in step with the equipment container, garment by garment.
func _dress() -> void:
	for index in ItemDB.SLOT_ORDER.size():
		var body_slot: String = ItemDB.SLOT_ORDER[index]
		var id := equipment.get_item(index)
		# Refuse garments cut for a different skeleton — they would bind, but the
		# weights would be nonsense and the silhouette would clip through itself.
		if not id.is_empty() and not CharacterDB.apparel_fits(_body_id, id):
			id = ""
		if String(_worn.get(body_slot, "")) == id:
			continue
		_worn[body_slot] = id
		if id.is_empty():
			Wardrobe.unequip(character, body_slot)
			continue
		var garment := Wardrobe.equip(character, body_slot, ItemDB.scene_path(id))
		if garment != null:
			SurfaceSkin.paint(garment)
	_refresh_mesh_list()
	_apply_tints()


## The shadow-casting list drives every frame, so a garment that has just come off,
## or a weapon that has just been put away, has to leave it with the same breath.
func _refresh_mesh_list() -> void:
	_character_meshes.assign(character.find_children("*", "MeshInstance3D", true, false))
	for mesh_instance in _character_meshes:
		# A skinned mesh keeps the bounds it was imported with, and a ragdoll puts
		# the bones a couple of metres from where the pose says they are. Without
		# the margin the whole body disappears the moment the camera turns.
		mesh_instance.extra_cull_margin = 3.0


# --- Weapons ----------------------------------------------------------------

## The arms are posed by a modifier on the skeleton rather than by clips, so one
## hold works over every gait the body can be in. See weapon_pose.gd.
func _add_weapon_pose() -> void:
	if _weapon_pose != null and is_instance_valid(_weapon_pose):
		_weapon_pose.queue_free()
		_weapon_pose = null
	var skeleton := Weapons.skeleton_of(character)
	if skeleton == null:
		return
	_weapon_pose = WeaponPose.new()
	_weapon_pose.name = "WeaponPose"
	skeleton.add_child(_weapon_pose)


## Rigid bodies built onto the same skeleton, idle until a crash. Added after the
## weapon pose so it runs after it: modifiers on a skeleton apply in tree order,
## and while the body is limp the ragdoll is the one that should win.
func _add_ragdoll() -> void:
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
		_ragdoll = null
	var skeleton := Weapons.skeleton_of(character)
	if skeleton == null:
		return
	_ragdoll = Ragdoll.new()
	_ragdoll.name = "Ragdoll"
	skeleton.add_child(_ragdoll)
	if not _ragdoll.built():
		_ragdoll.queue_free()
		_ragdoll = null
		return
	_ragdoll.ignore(self)


## The weapon this player has in hand, for a peer that has just joined.
func held_item() -> String:
	return _held


func apply_held(id: String) -> void:
	_take_up(id if ItemDB.is_weapon(id) else "")


## Switches to a weapon slot, whether or not it holds anything: an empty slot is
## how the weapon is put away again.
func select_weapon(index: int) -> void:
	if index < 0 or index >= weapons.size():
		return
	_weapon_slot = index
	if _weapon_bar != null:
		_weapon_bar.select(index)
	_take_up(weapons.get_item(index))


## The wheel only stops on slots holding something, which is the point of having
## five of them and two weapons.
func _cycle_weapon(step: int) -> void:
	var filled: Array[int] = []
	for index in weapons.size():
		if not weapons.get_item(index).is_empty():
			filled.append(index)
	if filled.is_empty():
		return
	var at := filled.find(_weapon_slot)
	if at >= 0:
		select_weapon(filled[wrapi(at + step, 0, filled.size())])
		return
	# Coming off an empty slot: carry on in the direction asked for rather than
	# jumping back to the first weapon.
	var next := filled[0] if step > 0 else filled[filled.size() - 1]
	for index in filled:
		if step > 0 and index > _weapon_slot:
			next = index
			break
		if step < 0 and index < _weapon_slot:
			next = index
	select_weapon(next)


## Puts `id` in the hands, or empties them for "". Everything that depends on what
## is held hangs off here, including what other peers are told.
func _take_up(id: String) -> void:
	if id == _held:
		return
	_held = id
	Weapons.unequip(character, WEAPON_HAND)
	_held_mesh = null
	if _weapon_pose != null:
		_weapon_pose.set_aimed(false)
		_weapon_pose.hold(ItemDB.hold_of(id))
	if not id.is_empty():
		_held_mesh = Weapons.equip(character, WEAPON_HAND, id, ItemDB.scene_path(id))
		if _held_mesh != null:
			SurfaceSkin.paint(_held_mesh)
		var cell := ItemDB.cell_size(id)
		if cell > 0 and not _cells.has(id):
			_cells[id] = float(cell)
	_refresh_mesh_list()
	if peer_id == multiplayer.get_unique_id() and multiplayer.has_multiplayer_peer():
		_hold.rpc(_held)


func _on_weapons_changed() -> void:
	# The rack can be rearranged while a weapon is in hand, so what the selected
	# slot now holds is the authority on what should be held.
	_take_up(weapons.get_item(_weapon_slot))
	if _weapon_bar != null:
		_weapon_bar.refresh()


func _attack() -> void:
	if _held.is_empty() or _weapon_pose == null:
		return
	match ItemDB.attack_of(_held):
		ItemDB.ATTACK_SWING:
			if not _weapon_pose.swinging():
				_swing_weapon.rpc()
		ItemDB.ATTACK_SHOOT:
			_shoot()


func _shoot() -> void:
	if _charge() < 1:
		return
	_cells[_held] = float(_cells.get(_held, 0.0)) - 1.0
	_cell_pause = CELL_PAUSE
	_weapon_pose.kick()
	var from := _muzzle_point()
	_fire_bolt.rpc(from, _shot_direction(from))


## The tip of whatever is in hand. A weapon's own -Z is the way it points, so the
## muzzle is the far face of its bounding box along that axis.
func _muzzle_point() -> Vector3:
	if _held_mesh == null:
		return camera.global_position - camera.global_basis.z * 0.4
	var box := _held_mesh.get_aabb()
	var centre := box.get_center()
	return _held_mesh.global_transform * Vector3(centre.x, centre.y, box.position.z)


## Bolts leave the muzzle but go where the crosshair is, so a shot lands where the
## player aimed rather than parallel to it.
func _shot_direction(from: Vector3) -> Vector3:
	var target := camera.global_position - camera.global_basis.z * AIM_RANGE
	var along := target - from
	if along.length_squared() < 0.0001:
		return -camera.global_basis.z
	return along.normalized()


## Shots left in the held weapon, rounded down: a cell part way to its next shot
## cannot fire it yet.
func _charge() -> int:
	if ItemDB.cell_size(_held) <= 0:
		return 0
	return floori(float(_cells.get(_held, 0.0)))


func _aim_amount() -> float:
	return _weapon_pose.aim_amount() if _weapon_pose != null else 0.0


func _update_weapon(delta: float) -> void:
	if _weapon_pose == null:
		return
	# Only something that shoots can be sighted, and only while the body is under
	# the player's control.
	var can_aim := controls_enabled and ItemDB.attack_of(_held) == ItemDB.ATTACK_SHOOT
	_weapon_pose.set_aimed(can_aim and Input.is_action_pressed("aim"))

	var cell := ItemDB.cell_size(_held)
	if cell > 0:
		_cell_pause = maxf(_cell_pause - delta, 0.0)
		if _cell_pause <= 0.0:
			_cells[_held] = minf(float(_cells.get(_held, 0.0)) + delta / CELL_RECHARGE, float(cell))


# --- Movement ---------------------------------------------------------------

func _simulate_local_player(delta: float) -> void:
	# Before anything moves. Every branch below finishes in `_catch_ground`, and
	# what it needs to know is where the body set off from.
	_swept_from = global_position
	_align_to_planet(delta)
	_read_surface()
	var grounded := _grounded()
	if _stance == Stance.CRASH:
		_crash_move(delta)
		return
	_update_flight_state(delta, grounded)
	if _stance == Stance.FLY:
		_fly_move(delta)
		# No stair step: there is no floor under a flight, and the probe only ever
		# runs against one.
		var carried := velocity
		_flight_velocity = carried
		move_and_slide()
		# Before the ground guard, which teleports the body: the slide collisions
		# describe the move that just happened and reading them after moving it
		# out from under them is not safe.
		var struck := _hit_something_solid(carried)
		var through := _catch_ground()
		if struck or (through and carried.length() >= CRASH_SPEED):
			_begin_crash(carried)
		else:
			_knock_limb(carried)
		return

	var fill := _submersion()
	_update_water_state(fill, grounded)
	if _stance == Stance.SWIM:
		_swim_move(delta, fill)
		# No stair step and no run to break: there is nothing under a swimmer to
		# climb, and the height field still backs up the sea bed.
		move_and_slide()
		_catch_ground()
		return

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	# Already tangential: the body's own X and Z lie in the ground plane once the
	# body is aligned, so there is nothing to flatten out of it.
	var wish := global_basis * Vector3(input.x, 0.0, input.y)
	if wish.length_squared() > 0.0001:
		wish = wish.normalized()
	else:
		wish = Vector3.ZERO

	_update_stance(delta, grounded)
	_update_run_speed(delta, wish != Vector3.ZERO)
	# Only while the feet are already down. A jump sets an upward velocity, which
	# `move_and_slide` will not snap against, but leaving the long reach on while
	# airborne would still have the body groping for ground it has left.
	floor_snap_length = maxf(_floor_snap, _horizontal_speed() * run_snap) if grounded \
		else _floor_snap
	if not grounded:
		velocity -= _up() * (_gravity() * delta)
	_try_jump(delta, grounded)

	if _stance == Stance.SLIDE:
		_slide_move(delta, wish)
	else:
		_walk_move(delta, wish, grounded)
	# Kept from before the move, because the collision spends it: this is the
	# speed that says whether the ground was landed on or hit.
	var carried := velocity
	_move_and_step(delta, grounded)
	# A crash is not a flying-only event. Dropping off a mountain, or running
	# into a cliff with a sprint fully wound up, arrives at a face just as hard
	# as a flight does and puts the player down the same way.
	if _hit_something_solid(carried):
		_begin_crash(carried)
	else:
		_knock_limb(carried)
	_catch_ground()


## What is underfoot, as far as the walk cares: how arctic it is, and whether it
## is pack ice or snow over ground.
##
## Read at the top of the tick and not in [method _catch_ground], which is the
## other place this file talks to the height field, because the guard runs
## *after* the move and the accel and friction terms are wanted before it. It
## costs one dot product and a smoothstep — [method PlanetShape.frost] takes no
## noise samples — so a tick is no more expensive for asking.
##
## Ice is told from snow by the radius, which works because [method
## PlanetShape._freeze] put the floe at exactly [constant PlanetShape.ICE_TOP]
## and left everything higher alone. [member _ground_radius] is last tick's
## sample, which at a sprint is under a decimetre away and always the same
## surface — and the alternative, sampling here as well, is a second call for a
## number the guard is about to produce anyway.
func _read_surface() -> void:
	_frost = 0.0
	_on_ice = false
	var planet := _planet_below()
	if planet == null or planet.shape == null:
		return
	var local := planet.to_local(global_position)
	var span := local.length()
	if span < 1.0:
		return
	_frost = planet.shape.frost(local / span)
	_on_ice = _frost > 0.5 and _ground_radius > 0.0 \
		and _ground_radius - planet.shape.radius <= PlanetShape.ICE_TOP + 0.05


## Which way is out of the ground here. The world is a sphere, so this is not a
## constant and nothing below may say `Vector3.UP` or read `velocity.y`. Taken
## from the body rather than from the planet because `_align_to_planet` has
## already put the two in agreement, and the body's own frame is what `wish`, the
## stair probe and the camera are all expressed in.
func _up() -> Vector3:
	return global_basis.y


## The part of a vector that lies along the ground, and the part that leaves it.
func _flat(vector: Vector3) -> Vector3:
	var up := _up()
	return vector - up * vector.dot(up)


func _rise() -> float:
	return velocity.dot(_up())


## How hard the planet pulls, in m/s². It lives in `project.godot` rather than
## among the exports here because it belongs to the world and not to the body
## falling through it — a second planet would want its own, and that is the day to
## move it onto `Planet`. The fallback only ever applies to a scene opened without
## the project's settings, so it is written to match what is set there.
func _gravity() -> float:
	return float(ProjectSettings.get_setting("physics/3d/default_gravity", 24.0))


## Turns the body's up to point out of the planet's centre. This one call is what
## lets the rest of the file treat a sphere as a floor: `up_direction` is what
## `move_and_slide` calls a floor, and the body's basis is what every direction
## here is built from.
##
## Reapplied every frame rather than only on landing, because walking is what
## changes it: a run across 500 m of an 8 km planet turns the local up by three
## and a half degrees, and nothing else would ever put it right.
##
## `up_direction` is set whatever the altitude, because it costs nothing and the
## floor checks want it. The *body* is only turned by [method _alignment_blend],
## which is zero out in space — see there for why that matters.
func _align_to_planet(delta: float) -> void:
	var planet := _planet_below()
	var up := planet.up_at(global_position) if planet != null else Vector3.UP
	up_direction = up
	var blend := _alignment_blend(planet)
	if blend <= 0.0:
		return
	var axis := global_basis.y.cross(up)
	# Already square to the ground, or exactly upside down over the far side —
	# which has no shortest way round and is not reachable by flying there.
	if axis.length_squared() < 0.000000001:
		return
	# Eased rather than snapped, so descending into the air rolls the body upright
	# over a few seconds instead of flicking it. Written as an exponential
	# approach so the turn takes the same time whatever the frame rate.
	var angle := global_basis.y.angle_to(up)
	var taken := angle * (1.0 - exp(-blend * ALIGN_RATE * delta))
	global_basis = (Basis(axis.normalized(), taken) * global_basis).orthonormalized()


## How hard the body is pulled square to the ground: 0 out in space, 1 once there
## is ground to speak of underneath.
##
## The gate exists because at the orbital spawn the planet is dead ahead and the
## way out of its centre is straight behind, so there is no heading left to keep
## once up is forced radial — the view whips sideways and the spawn is ruined.
## Out there nothing needs a floor anyway. Flying down through the air is what
## earns the orientation, and by the ground it is complete.
func _alignment_blend(planet: Planet) -> float:
	if planet == null:
		return 0.0
	# Anything not flying is on its way to the floor and needs the floor to be a
	# floor: gravity, the stair probe and `is_on_floor` all measure off this.
	if _stance != Stance.FLY:
		return 1.0
	var ceiling := planet.atmosphere_height
	if ceiling <= 0.0:
		return 1.0
	var altitude := global_position.distance_to(planet.global_position) - planet.shape.radius
	var depth := 1.0 - clampf(altitude / ceiling, 0.0, 1.0)
	# Slowing down is the other half of it: at a float there is nothing to do but
	# settle, while hauling the body upright in the middle of a 200 m/s dive
	# fights the steering. Never to zero, or a fast descent would arrive sideways.
	return depth * (1.0 - 0.6 * clampf(_cruise / maxf(fly_speed, 1.0), 0.0, 1.0))


## The planet's collider is not the planet. A chunk only gets a
## [ConcavePolygonShape3D] once it is near enough, deep enough *and* finished
## building on the thread pool, so there is always a window in which the ground
## is drawn but not solid — and a flight arriving at 200 m/s can be inside that
## window when it reaches a hillside. The height field answers the same question
## in constant time and without a mesh, which is why it, and not the collider, is
## what finally stops anything going through the world.
##
## It also answers the smaller question the collider is bad at: is there ground
## under the feet at all. Where there is no chunk body, [method is_on_floor] can
## only ever say no, and a body that believes it is falling gets air control, no
## floor snapping and no stair step — which is the whole of walking. So this sets
## [member _footed] as well as pushing out, and the two together are what the
## rest of the file means by grounded.
func _catch_ground() -> bool:
	_footed = is_on_floor()
	_ground_radius = -1.0
	var planet := _planet_below()
	if planet == null or planet.shape == null:
		return false
	# The ground that is drawn, not the ground the field could describe. A chunk
	# that has not refined yet has no canyon in it, and a body must be held up by
	# the surface it can see rather than by the one under it.
	var spacing := planet.spacing_underfoot()
	# First, because at speed the place the move finished is not the place it
	# met the ground, and everything below measures wherever the body is.
	var crossed := _rewind_to_entry(planet, spacing)
	var local := planet.to_local(global_position)
	if local.length_squared() < 1.0:
		return false
	var out := local.normalized()
	var floor_radius := planet.shape.radius + planet.shape.elevation(out, spacing)
	_ground_radius = floor_radius
	var under := floor_radius - local.length()
	# A crossing has already been narrowed down to the surface it crossed, so
	# every test below would measure it as a graze and wave it through. It is
	# not a graze: the body was on the far side of that ground a moment ago.
	if not crossed:
		if under < -FOOT_REACH:
			return false
		# Within a boot's depth of the surface and not on the way up: the ground
		# is there whether or not the last move happened to touch it. Not for a
		# flight or a swim, both of which pass close to ground they are not
		# standing on and have their own tests for arriving.
		if _stance != Stance.FLY and _stance != Stance.SWIM:
			_footed = _footed or _rise() <= 0.1
		if under <= 0.0:
			return false
		# The mesh gets the benefit of the doubt while it is shallow enough to be
		# a triangle that dips rather than a body inside the world.
		if under < TUNNEL_DEPTH and _footing_within(GROUND_MARGIN):
			return false
	global_position = planet.to_global(out * floor_radius)
	# Whatever was driving the body into the ground is spent; what it had along
	# the surface is not, so a graze keeps its heading.
	velocity = _flat(velocity)
	_footed = true
	if _stance == Stance.FLY:
		_end_flight()
	return true


## Puts the body back where its path first went under the height field, and says
## whether it found such a place.
##
## The guard above is a point test, and a point test only stands in for a swept
## one while the point moves less than the smallest thing it must not miss. A
## boost covers seventeen metres in a tick. A ridge that thick is crossed
## *between* two samples: the body is above the ground where the tick started,
## above the ground on the far side where it ended, and nothing in the frame
## ever saw the mountain in between. That is the whole of what flying through
## the planet is, and pushing harder on the guard cannot fix it — there is
## nothing wrong with the answer it gives, only with where it was asked.
##
## `move_and_slide` does not have the problem, because it sweeps its capsule.
## But at that speed almost none of the ground ahead has a collider yet, so
## there is nothing for the sweep to find and the field is all there is.
##
## The chord therefore gets walked in pieces the width of the field's own finest
## feature, and the first piece that ends underground is halved a few times for
## the crossing. It is arithmetic and no physics query: a handful of noise
## lookups at a boost, and one length and a comparison at every other speed,
## which is every tick the player spends walking.
func _rewind_to_entry(planet: Planet, spacing: float) -> bool:
	var travelled := global_position - _swept_from
	var reach := travelled.length()
	if reach <= spacing:
		return false
	var parts := mini(ceili(reach / spacing), SWEEP_PARTS)
	# The start counts. A body that was already inside — because a chunk
	# coarsened under it, or because the last tick left it there — has its whole
	# path underground, and the loop below would otherwise find no crossing on it
	# and hand back the far end.
	if _clearance(planet, _swept_from, spacing) <= 0.0:
		global_position = _swept_from
		return true
	var clear := 0.0
	for part in range(1, parts + 1):
		var at := float(part) / float(parts)
		if _clearance(planet, _swept_from + travelled * at, spacing) > 0.0:
			clear = at
			continue
		var inside := at
		for _refine in SWEEP_REFINE:
			var middle := (clear + inside) * 0.5
			if _clearance(planet, _swept_from + travelled * middle, spacing) > 0.0:
				clear = middle
			else:
				inside = middle
		global_position = _swept_from + travelled * clear
		return true
	return false


## How far a point is above the height field, in metres, negative inside it.
func _clearance(planet: Planet, at: Vector3, spacing: float) -> float:
	var local := planet.to_local(at)
	var span := local.length()
	if span < 1.0:
		return -span
	return span - (planet.shape.radius + planet.shape.elevation(local / span, spacing))


## Ground under the feet, from either of the two things that can provide it. Every
## floor question in the movement code goes through here rather than through
## [method is_on_floor], which knows only about chunk colliders.
func _grounded() -> bool:
	return is_on_floor() or _footed


## Cached: the search is by type rather than by name, so it costs a walk of the
## world's children and the planet never moves between them.
func _planet_below() -> Planet:
	if is_instance_valid(_planet):
		return _planet
	var parent := get_parent()
	if parent == null:
		return null
	for sibling in parent.get_children():
		if sibling is Planet:
			_planet = sibling as Planet
			return _planet
	return null


## move_and_slide plus a stair step. Without it a capsule stops dead against any
## lip it cannot slide over, which is most prop edges and kerbs.
func _move_and_step(delta: float, grounded: bool) -> void:
	var intended := _flat(velocity) * delta
	var before := global_position
	move_and_slide()
	if not is_on_wall() or intended.length() < 0.001:
		return
	var achieved := _flat(global_position - before)
	# Slopes and glancing walls legitimately eat some motion; only a real
	# obstruction, which eats most of it, is worth lifting the body for.
	if achieved.dot(intended) >= intended.length_squared() * 0.8:
		return
	if (grounded or _footing_within(step_height)) and _climb_step(intended):
		return
	# Only something close to vertical ends a run. `is_on_wall` means no more
	# than "steeper than `floor_max_angle`", which on a procedural planet is
	# most hillsides, and a run that died on every slope would never get out of
	# the valley it started in.
	if _steepest_contact() >= RUN_BREAK_FACE:
		_break_run()


## Is there anything to stand on within `reach` under the body? `is_on_floor` asks
## the same question of the move that just happened, and on the planet it says no
## far more often than the ground under the feet warrants: the terrain is a
## triangulation that dips between its vertices, the height-field guard works to a
## margin of half a metre, and a run at speed spends most of its frames a
## centimetre or two clear of the mesh. A body that is airborne on a technicality
## will not climb a kerb, and every small bump becomes a wall.
func _footing_within(reach: float) -> bool:
	return test_move(global_transform, -_up() * reach)


## How far the steepest thing just hit leans off the ground: 1 is a vertical face,
## 0 is ground you could stand on.
func _steepest_contact() -> float:
	var up := _up()
	var worst := 0.0
	for index in get_slide_collision_count():
		worst = maxf(worst, 1.0 - absf(get_slide_collision(index).get_normal().dot(up)))
	return worst


func _climb_step(intended: Vector3) -> bool:
	var direction := intended.normalized()
	# The probe starts a few millimetres back off the obstruction and reaches a
	# little past it: the slide leaves the capsule flush against the wall, and a
	# shape that starts in contact reports a collision even for motion running
	# parallel to the surface it is touching.
	var clearance := 0.03
	var start := global_transform.translated(-direction * clearance)
	# Far enough past the lip that the body comes down on the step's top face
	# rather than balancing on its edge.
	var forward := direction * (maxf(intended.length(), 0.12) + clearance)
	# Raised higher than the tallest allowed step, so a step right at the limit
	# still has room to pass over it. How far the body may actually rise is
	# judged from the landing below, not from this probe.
	var lift := up_direction * (step_height + 0.05)
	if test_move(start, lift):
		return false
	var lifted := start.translated(lift)
	if test_move(lifted, forward):
		return false

	var over := lifted.translated(forward)
	var landing := KinematicCollision3D.new()
	# No ground under the raised body means this is a gap or a cliff, not a step.
	if not test_move(over, -lift * 1.2, landing):
		return false
	# Anything that is not a wall will do: coming down on the edge of a step
	# reports a slanted normal, and the rise is bounded either way.
	if landing.get_normal().dot(up_direction) < 0.3:
		return false
	var target := over.origin + landing.get_travel()
	var rise := (target - global_position).dot(_up())
	if rise > step_height + 0.01 or rise < -0.01:
		return false

	_step_offset -= rise
	global_position = target
	return true


func _try_jump(delta: float, grounded: bool) -> void:
	_coyote_left = coyote_time if grounded else maxf(_coyote_left - delta, 0.0)
	_jump_buffered = jump_buffer if Input.is_action_just_pressed("jump") else maxf(_jump_buffered - delta, 0.0)
	if _jump_buffered <= 0.0 or _coyote_left <= 0.0:
		return
	_jump_buffered = 0.0
	_coyote_left = 0.0
	velocity = _flat(velocity) + _up() * (jump_velocity * (1.0 + jump_speed_gain * _run_amount()))
	# Jumping out of a slide keeps the boosted speed, which is the payoff for
	# chaining a slide into a hop, and the slide's speed is what sizes the jump.
	if _stance != Stance.STAND:
		_try_stand()


## Shift winds the run up and letting go of shift leaves it where it got to. Only
## releasing forward gives the speed back, which is what makes a run something
## held rather than something spent — there is no stamina here to spend.
func _update_run_speed(delta: float, steering: bool) -> void:
	# A slide is not a run, and the slide's own friction owns the speed while it
	# lasts; `_update_stance` hands the run back whatever the slide leaves.
	if _stance == Stance.SLIDE:
		return
	if not steering:
		_run_speed = walk_speed
		return
	if Input.is_action_pressed("sprint"):
		_run_speed = maxf(_run_speed, sprint_speed)
		_run_speed = move_toward(_run_speed, run_top_speed,
			(run_top_speed - sprint_speed) / maxf(run_spool_time, 0.01) * delta)
	# The target can never run far ahead of the legs. Without this, anything that
	# bleeds the real speed — a crouch, a slide, a hill — would leave the wind-up
	# intact and hand it all back for free the moment the body stood up again.
	_run_speed = clampf(_run_speed, walk_speed,
		maxf(sprint_speed, _horizontal_speed() * 1.25 + walk_speed))


## How far into a run the player is: 0 at a sprint, 1 flat out. The lean, the
## field of view and the height of a jump all read it, so they agree.
func _run_amount() -> float:
	return clampf(
		inverse_lerp(sprint_speed, run_top_speed * GROUND_FLAT_OUT, _horizontal_speed()), 0.0, 1.0)


## A run ends against anything it cannot climb or slide past. Momentum built over
## several seconds is not something to carry on through a pillar, and nothing else
## in the movement code notices the collision: `move_and_slide` would happily
## redirect the whole 200 m/s along the wall.
func _break_run() -> void:
	if _run_speed <= sprint_speed:
		return
	_run_speed = walk_speed
	velocity = _flat(velocity).limit_length(walk_speed) + _up() * _rise()
	if _stance == Stance.SLIDE:
		_slide_ready_in = slide_cooldown
		_try_stand()


func _walk_move(delta: float, wish: Vector3, grounded: bool) -> void:
	var flat := _flat(velocity)
	var target_speed := _target_speed()
	if wish == Vector3.ZERO:
		if grounded:
			flat = flat.move_toward(Vector3.ZERO, _coast_drag(flat.length()) * delta)
	elif grounded:
		flat = flat.move_toward(wish * target_speed, _ground_accel() * delta)
	elif flat.length() > target_speed:
		# Airborne and already faster than we could run: steer without braking.
		flat = flat.move_toward(wish * flat.length(), air_accel * delta)
	else:
		flat = flat.move_toward(wish * target_speed, air_accel * delta)
	velocity = flat + _up() * _rise()


## Friction once forward is released. `ground_friction` alone would take four
## seconds to shed a run, so it grows with whatever the run is carrying above a
## sprint; below a sprint the extra term is zero and a walk stops as it always did.
##
## The surface scales the whole thing, the speed term included. Letting the run
## skid keep its full bite on ice would give the odd result that a sprint stops
## dead on a floe while a walk slithers about on it.
func _coast_drag(speed: float) -> float:
	return (ground_friction + maxf(speed - sprint_speed, 0.0) * coast_drag) * _grip()


## Acceleration underfoot. Ice gives a little more and snow a lot less; see the
## Arctic exports for why the two are not symmetrical.
func _ground_accel() -> float:
	if _on_ice:
		return ground_accel * ice_accel
	return ground_accel * lerpf(1.0, snow_accel, _frost)


## How much of the ordinary friction this surface is willing to apply.
func _grip() -> float:
	if _on_ice:
		return ice_friction
	return lerpf(1.0, snow_friction, _frost)


func _slide_move(delta: float, wish: Vector3) -> void:
	var flat := _flat(velocity)
	var speed := maxf(flat.length() - _slide_drag * delta, 0.0)
	var direction := flat.normalized() if flat.length_squared() > 0.0001 else -global_basis.z
	if wish != Vector3.ZERO:
		direction = (direction + wish * slide_steer * delta).normalized()
	velocity = direction * speed + _up() * _rise()


## Top speed the walk is steering toward. Deep snow holds it down; ice does not
## raise it, because what ice does is let the body keep speed rather than help it
## reach any — and a target above the run would have a player on a floe outrunning
## one on grass, which is not what slipping feels like.
func _target_speed() -> float:
	var top := crouch_speed if _stance == Stance.CROUCH else _run_speed
	if _on_ice:
		return top
	return top * lerpf(1.0, snow_speed, _frost)


func _horizontal_speed() -> float:
	return _flat(velocity).length()


# --- Flight -----------------------------------------------------------------

## Puts the player in the air without a take-off, for spawning somewhere that has
## no ground under it. Take-off proper wants clearance below and a jump press,
## and both are answers to questions that do not arise in orbit.
func start_flying() -> void:
	if _stance == Stance.FLY:
		return
	velocity = Vector3.ZERO
	_cruise = float_speed
	_jump_buffered = 0.0
	_flight_velocity = Vector3.ZERO
	floor_snap_length = 0.0
	_apply_stance(Stance.FLY)


## Space in mid-air takes off, and space twice does it out of the water. Three
## things end a flight: the floor, drifting down near it while floating, and the
## land key, which is the only way out of a hover held over a hole with nothing
## underneath to touch.
func _update_flight_state(delta: float, grounded: bool) -> void:
	_swim_launch_left = maxf(_swim_launch_left - delta, 0.0)
	if _stance == Stance.FLY:
		if grounded or Input.is_action_just_pressed("land"):
			_end_flight()
		elif velocity.length() <= float_speed * 1.6 \
				and test_move(global_transform, -_up() * land_clearance):
			_end_flight()
		return
	if _stance == Stance.SWIM:
		# Out of the water takes two presses; see SWIM_LAUNCH_WINDOW. The coyote
		# window is skipped rather than checked, because a swim is entered from a
		# fall as often as from a wade and the window is still open on the way in.
		if not _swim_launch_pressed():
			return
	# The coyote window belongs to the jump, so walking off a ledge and pressing
	# space is still a jump and not a take-off.
	elif grounded or _coyote_left > 0.0 or not Input.is_action_just_pressed("jump"):
		return
	# Only on the land path. The clearance is there to keep a take-off apart from
	# a buffered jump, and a swimmer has no jump to buffer; asking for it in the
	# water as well would refuse a launch out of anything shallower than a metre.
	elif test_move(global_transform, -_up() * TAKEOFF_CLEARANCE):
		return
	# Whatever the jump or the fall had built up is kept, trimmed to hovering
	# speed: a take-off out of a sprint carries its heading instead of stopping
	# dead in the air.
	velocity = velocity.limit_length(float_speed)
	_cruise = float_speed
	_jump_buffered = 0.0
	_swim_launch_left = 0.0
	floor_snap_length = 0.0
	_apply_stance(Stance.FLY)


## Second press of jump inside [constant SWIM_LAUNCH_WINDOW]. The first press
## arms the window and is otherwise left alone, so it still does what it always
## did in [method _swim_move]: pull the body toward the surface.
func _swim_launch_pressed() -> bool:
	if not Input.is_action_just_pressed("jump"):
		return false
	if _swim_launch_left > 0.0:
		return true
	_swim_launch_left = SWIM_LAUNCH_WINDOW
	return false


# --- Crashing ---------------------------------------------------------------

## Did that move put the body into something that does not move, hard? Measured
## against the velocity the frame *started* with, because the slide has already
## redirected whatever survived along the surface and the number that says how
## hard it hit is gone by the time anything can ask.
func _hit_something_solid(carried: Vector3) -> bool:
	for index in get_slide_collision_count():
		var hit := get_slide_collision(index)
		# Only things that cannot be pushed. Flying into another player is their
		# problem as much as yours and should floor neither of you.
		if not (hit.get_collider() is StaticBody3D):
			continue
		if -hit.get_normal().dot(carried) >= CRASH_SPEED:
			return true
	return false


## The tier below a crash: a hit hard enough to be felt but not to put the player
## down, which knocks the part of the body that met the wall and leaves the rest
## walking. Catching a shoulder on a rock at a sprint should cost a flinch, and
## before this it cost either nothing at all or the whole second and a half of
## lying on the floor.
##
## Floors are skipped. Every landing arrives at some speed into a surface, and a
## jump is not an accident — the `Land` clip already has that job.
func _knock_limb(carried: Vector3) -> void:
	if _ragdoll == null or not _ragdoll.built() or _ragdoll.limp():
		return
	var hardest := 0.0
	var at := Vector3.ZERO
	var away := Vector3.ZERO
	for index in get_slide_collision_count():
		var hit := get_slide_collision(index)
		if not (hit.get_collider() is StaticBody3D):
			continue
		var normal := hit.get_normal()
		if normal.dot(_up()) > FLOOR_FACE:
			continue
		var speed := -normal.dot(carried)
		if speed > hardest:
			hardest = speed
			at = hit.get_position()
			away = normal
	if hardest < KNOCK_SPEED:
		return
	var planet := _planet_below()
	if planet != null and _ground_radius > 0.0:
		_ragdoll.set_floor(planet.global_position, _ground_radius)
	# Out of the surface, not along the travel: what the body does is rebound off
	# the thing it hit. Capped because a flight clipping a spire at 300 m/s would
	# otherwise fire one arm over the horizon while the player walked on.
	_ragdoll.take_hit(at, away * minf(hardest, KNOCK_SPEED_CAP) * KNOCK_WEIGHT,
		-_up() * _gravity())


func _begin_crash(carried: Vector3) -> void:
	# One crash per crash. A flight into a hillside reaches here twice — once
	# through `_end_flight`, which the ground guard calls, and once from the
	# guard's own answer back in the move — and a second pass would restart the
	# timer and count the fall twice while the ragdoll, already limp, ignored it.
	if _stance == Stance.CRASH:
		return
	_crash_left = CRASH_TIME
	_tumble = 0.0
	_tumble_rate = clampf(carried.length() * TUMBLE_PER_SPEED,
		TUMBLE_RATE_RANGE.x, TUMBLE_RATE_RANGE.y)
	_crashes += 1
	floor_snap_length = _floor_snap
	velocity = _flat(carried).limit_length(CRASH_SLIDE)
	# Spent. Left standing it would have the next landing judged by this crash.
	_flight_velocity = Vector3.ZERO
	_run_speed = 0.0
	_cruise = float_speed
	_apply_stance(Stance.CRASH)
	if _ragdoll != null and _ragdoll.built():
		# The hold is arms placed by IK, and a limp body has no use for either.
		if _weapon_pose != null:
			_weapon_pose.active = false
		# Guarded from the tick it goes limp, not from the next one. The frame a
		# crash starts is the fastest the bones will ever be moving.
		var planet := _planet_below()
		if planet != null and _ground_radius > 0.0:
			_ragdoll.set_floor(planet.global_position, _ground_radius)
		_ragdoll.go_limp(velocity, -_up() * _gravity())


## No steering and no jumping: the whole point is that the player is not driving
## for a moment. Gravity and friction are all that act, and the body gets up the
## instant it is allowed to — which is not while something is over it.
##
## The capsule chases the limp body rather than coasting on its own friction.
## Everything that is attached to the player and not to the bones hangs off the
## capsule — the camera above all, but also the eye line, the interaction ray and
## the position other peers are told about — so a capsule that stops where the
## crash started while the body tumbles on leaves the view pointed at the ground
## the player used to be lying on, and stands them up a few metres from their own
## corpse.
##
## Chasing is not the same as being dragged. The capsule is still swept by
## `move_and_slide`, so a wall stops it whatever the bones did, and the speed it
## may spend closing the gap is capped: a limb that finds its way somewhere the
## capsule cannot follow pulls the view for a moment and then gives up, rather
## than firing the player across the world after it.
func _crash_move(delta: float) -> void:
	_crash_left = maxf(_crash_left - delta, 0.0)
	if not _grounded():
		velocity -= _up() * (_gravity() * delta)
	var limp := _ragdoll != null and _ragdoll.limp()
	var along := _flat(velocity)
	var gap := _flat(_ragdoll.centre() - global_position) if limp else Vector3.ZERO
	if limp and gap.length() <= CRASH_CHASE_REACH:
		# Straight at the body rather than a force toward it. A spring would
		# overshoot a tumble that is still turning, and the capsule has no
		# momentum worth conserving here: nobody is driving it, and the motion
		# the crash is made of belongs to the bones.
		along = (gap / CRASH_CHASE_TIME).limit_length(CRASH_CHASE_SPEED)
	else:
		along = along.move_toward(Vector3.ZERO, CRASH_FRICTION * delta)
	velocity = along + _up() * _rise()
	move_and_slide()
	_catch_ground()
	if limp:
		_ragdoll.set_pull(-_up() * _gravity())
		# Half the crashes worth having happen where the collider budget has not
		# reached yet, and bones with nothing to land on go through the planet
		# while the capsule stops on top of it. The guard the capsule already has
		# is handed to them, at the radius it has just measured.
		var planet := _planet_below()
		if planet != null and _ground_radius > 0.0:
			_ragdoll.set_floor(planet.global_position, _ground_radius)
		# The last of the crash is the pose easing out of where the body actually
		# landed and into the clip that stands it up, which is what makes getting
		# up a movement rather than a cut.
		if _crash_left < CRASH_RISE:
			_ragdoll.settle(_crash_left / CRASH_RISE)
	if _crash_left <= 0.0 and _grounded():
		# The chase is a means of keeping up, not momentum the player earned, so
		# it does not survive into the stance that can be steered.
		velocity = _up() * _rise()
		if _ragdoll != null:
			_ragdoll.stand_up()
		if _weapon_pose != null:
			_weapon_pose.active = true
		_try_stand()


func _end_flight() -> void:
	# Every way out of a flight comes through here — the floor, the drift-down,
	# the height field, the land key — so this is the one place that can tell a
	# landing from a crash without having to know which of them got here.
	#
	# Judged on the speed the flight was carrying rather than on what is left in
	# `velocity`: whatever grounded the body has already spent it, and the
	# evidence of how hard it hit is a frame old by the time anything can ask.
	# The ground test is what keeps the land key honest — pressed up in the air
	# there is nothing under the feet to have hit. It asks `_grounded` and not
	# `is_on_floor`, because the collider is the one thing that is reliably
	# absent here: a flight fast enough to be worth crashing outruns the chunk
	# builder, so the arrival that most deserves to put the player down was the
	# one arrival with nothing under it to prove it had happened.
	if _flight_velocity.length() >= CRASH_SPEED \
			and (_grounded() or test_move(global_transform, -_up() * land_clearance)):
		_begin_crash(_flight_velocity)
		return
	_flight_velocity = Vector3.ZERO
	floor_snap_length = _floor_snap
	# A thousand metres a second does not survive contact with the floor, and it
	# should not survive the cancel key either. Without this the run that follows
	# would inherit the flight's speed, and the walk clip would strobe while the
	# player slid across the world at a sprint's hundred times over.
	velocity = _flat(velocity).limit_length(sprint_speed)
	_cruise = float_speed
	_apply_stance(Stance.STAND)


func _fly_move(delta: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	# The camera's basis rather than the body's, because looking is the steering:
	# hold forward while looking down and you dive. Only the head pitches, so the
	# camera's own X stays level and a strafe never rolls the flight path.
	var wish := camera.global_basis * Vector3(input.x, 0.0, input.y)
	if Input.is_action_pressed("jump"):
		wish += _up()
	var steering := wish.length_squared() > 0.0001

	# Level or on the way down the hover runs at its full pace; the more of the
	# heading is straight up, the more it gives back. Read off the wish rather
	# than off the velocity, so the cap changes with what is being asked for and
	# not with what the body has not finished doing yet.
	var climbing := clampf(wish.normalized().dot(_up()), 0.0, 1.0) if steering else 0.0
	var hover := lerpf(float_speed, climb_speed, climbing)

	# Only winds up while there is a direction to wind up in. Otherwise a player
	# holding the boost while stationary would be charging a target they cannot
	# see, and the next tap of forward would launch them at a thousand metres a
	# second out of nowhere.
	var wanted := fly_speed if steering and Input.is_action_pressed("sprint") else hover
	# One rate across the whole range whichever way it is travelling, so each of
	# the two times reads as the seconds it takes end to end.
	var seconds := boost_time if wanted > _cruise else ease_time
	_cruise = move_toward(_cruise, wanted, (fly_speed - float_speed) / maxf(seconds, 0.01) * delta)

	if steering:
		velocity = velocity.move_toward(
			wish.normalized() * _cruise, (flight_accel + _cruise * flight_turn) * delta)
	else:
		velocity = velocity.move_toward(
			Vector3.ZERO, (flight_drag + velocity.length() * flight_coast) * delta)

	# Water is not a wall, but it is not air either. A flight carries on under the
	# surface — that is the point of the sea having no collider — at a hover's
	# pace: the boost cannot wind up down there, and whatever a dive arrived with
	# is shed over tens of metres instead of carrying on to the sea bed.
	var fill := _submersion()
	if fill > 0.0:
		_cruise = minf(_cruise, float_speed)
		velocity *= exp(-water_drag * fill * delta)


# --- Water ------------------------------------------------------------------

## The sea, or null on a planet without one — which includes every scene that has
## no planet at all, so nothing here may assume it exists.
func _water() -> PlanetWater:
	var planet := _planet_below()
	return planet.water if planet != null else null


## How much of the body is under water: 0 clear of it, 1 with the head under.
##
## Read from the sea's own radius rather than from a collider or an area, so it is
## exact at any depth anywhere on the planet, and true whether or not any ground
## has been built nearby — the same reason the ground guard reads the height
## field instead of the chunk meshes.
func _submersion() -> float:
	var water := _water()
	if water == null:
		return 0.0
	return clampf(water.depth_at(global_position) / maxf(_stance_height(_stance), 0.1), 0.0, 1.0)


## Splashes on the way in and on the way out, at the speed the surface was crossed
## at. Runs for every player: a remote peer's position and velocity are both known
## locally, so their entry throws up its own splash with no packet spent saying so.
func _track_water_crossing() -> void:
	var water := _water()
	if water == null:
		return
	var under := water.depth_at(global_position) > 0.0
	if under == _submerged:
		return
	_submerged = under
	var speed := absf(velocity.dot(_up()))
	if speed >= SPLASH_SPEED:
		water.splash(water.surface_above(global_position), speed)


## Prints in the snow, one every [constant Snowfield.STRIDE] metres of ground
## covered. Runs for every player, for the same reason splashes do.
##
## Measured in distance and not off the walk cycle, which is the tempting way to
## do it and the wrong one: the clip is resampled by speed, so its cycle is a
## fixed number of *seconds* and prints taken from it would be a pace apart at a
## walk and a stride apart at a run — feet do the opposite.
##
## Everything it needs it asks the planet for rather than reading the walk's own
## [member _frost] and [member _on_ice], because those are written by the local
## simulation and a remote body never runs one. That costs one height-field
## sample a tick per player, behind a frost test that is a dot product and is
## false everywhere outside the cap.
func _track_footprints() -> void:
	var from := _print_from
	_print_from = global_position
	if _stance == Stance.FLY or _stance == Stance.SWIM or _stance == Stance.CRASH:
		return
	var step := from.distance_to(global_position)
	# Nothing covered, or a jump rather than a walk: the ground guard's rewind, a
	# spawn, a scene change. `_print_from` starts at INF so the first tick after
	# either is caught here and not drawn as a stride across the map.
	if step <= 0.0 or step > PRINT_MAX_STEP:
		return
	var planet := _planet_below()
	if planet == null or planet.shape == null or planet.snowfield == null:
		return
	var local := planet.to_local(global_position)
	var span := local.length()
	if span < 1.0:
		return
	var out := local / span
	if planet.shape.frost(out) <= 0.05:
		return
	var ground := planet.shape.radius \
		+ planet.shape.elevation(out, planet.finest_spacing())
	# Feet in the snow, and the snow not a floe: pack ice sits at exactly
	# PlanetShape.ICE_TOP and takes no prints.
	if absf(span - ground) > PRINT_FOOTING \
			or ground - planet.shape.radius <= PlanetShape.ICE_TOP + 0.05:
		return
	_since_print += step
	if _since_print < Snowfield.STRIDE:
		return
	_since_print = 0.0
	_left_foot = not _left_foot
	var travel := _flat(velocity)
	var facing := travel.normalized() if travel.length_squared() > 0.01 \
		else -global_basis.z
	planet.snowfield.stamp(global_position, _up(), facing, _left_foot)


## Chest deep is swimming; knee deep with something under the feet is not.
## Anything between is whichever it already was.
func _update_water_state(fill: float, grounded: bool) -> void:
	if _stance != Stance.SWIM:
		if fill >= SWIM_ENTER:
			_run_speed = walk_speed
			# Every swim starts on the unhurried stroke, boost held or not. Left
			# where the last one ended, a swimmer who surfaced flat out and went
			# straight back in would be handed the whole wind-up again for free.
			_stroke = swim_speed
			# Snapping would haul a swimmer down onto any ground that passed
			# within reach underneath them.
			floor_snap_length = 0.0
			_apply_stance(Stance.SWIM)
		return
	# Clear of the water entirely means thrown out of it rather than stood up in
	# it, and the body falls from there like anything else in the air.
	if fill <= 0.0 or (fill <= SWIM_EXIT and grounded):
		floor_snap_length = _floor_snap
		# Wading out of the shallows is not a launch. A boosted stroke is worth
		# more than a wound-up run and the ground has no way to have earned it, so
		# it is spent here — but only with something under the feet, because the
		# other way out of this branch is breaking the surface on the way up, and
		# that one is meant to throw the body clear.
		if grounded:
			velocity = velocity.limit_length(sprint_speed)
		_try_stand()


## Steered by the camera, like flight: under water forward is wherever you are
## looking, and the surface is above you as often as it is ahead.
##
## [param fill] is how much of the body the water has hold of, and it scales all
## three terms. A stroke taken half out of the water pushes half as hard, and the
## lift is the same fraction, which is what makes the surface somewhere the body
## settles rather than a line it has to be clamped to.
##
## Which is also why [member swim_surge] is written per m/s asked for rather than
## as a flat figure: the stroke and the drag are then both linear in `fill`, they
## cancel, and the boost reaches the same speed with the shoulders out as it does
## ten metres down. A flat acceleration large enough to beat the drag while
## submerged would be an enormous one at the surface.
func _swim_move(delta: float, fill: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var wish := camera.global_basis * Vector3(input.x, 0.0, input.y)
	if Input.is_action_pressed("jump"):
		wish += _up()
	elif Input.is_action_pressed("crouch"):
		wish -= _up()
	var steering := wish.length_squared() > 0.0001

	# The boost, wound the same way the flight's is: one rate across the whole
	# range whichever way it is going, so each of the two times reads as the
	# seconds it takes end to end.
	var wanted := swim_sprint_speed if steering and Input.is_action_pressed("sprint") \
		else swim_speed
	var seconds := swim_boost_time if wanted > _stroke else swim_ease_time
	_stroke = move_toward(_stroke, wanted,
		(swim_sprint_speed - swim_speed) / maxf(seconds, 0.01) * delta)

	if steering:
		# Both terms are scaled by `fill`, and so is the drag below, so the two
		# stay in the ratio that decides the top speed however much of the body
		# the water has hold of. A swimmer with their shoulders out is pushing
		# against half as much water and half as much of it is pushing back.
		velocity = velocity.move_toward(wish.normalized() * _stroke,
			(swim_accel + _stroke * swim_surge) * fill * delta)
	# Buoyancy against gravity, and nothing else pulls down in this branch: below
	# the float line the first term wins and the body rises, above it the second
	# does, and they cross with the head out.
	velocity += _up() * (_gravity() * (buoyancy * fill - 1.0) * delta)
	velocity *= exp(-water_drag * fill * delta)


# --- Stance -----------------------------------------------------------------

func _update_stance(delta: float, grounded: bool) -> void:
	_slide_ready_in = maxf(_slide_ready_in - delta, 0.0)
	var crouch_held := Input.is_action_pressed("crouch")

	if _stance == Stance.SLIDE:
		_slide_time += delta
		var spent := _slide_time >= _slide_span or _horizontal_speed() <= slide_exit_speed
		if not grounded or not crouch_held or spent:
			_slide_ready_in = slide_cooldown
			# The run resumes from what the slide left, not from what it started
			# with, or the friction would cost nothing and every run would be
			# worth sliding indefinitely.
			_run_speed = clampf(_horizontal_speed(), walk_speed, run_top_speed)
			if crouch_held and grounded:
				_apply_stance(Stance.CROUCH)
			else:
				_try_stand()
		return

	if Input.is_action_just_pressed("crouch"):
		if grounded and _slide_ready_in <= 0.0 and _horizontal_speed() >= slide_entry_speed:
			_start_slide()
		else:
			_apply_stance(Stance.CROUCH)
	elif not crouch_held and _stance == Stance.CROUCH:
		_try_stand()


func _start_slide() -> void:
	var flat := _flat(velocity)
	var direction := flat.normalized() if flat.length_squared() > 0.0001 else -global_basis.z
	var speed := maxf(flat.length() * 1.15, slide_speed)
	velocity = direction * speed + _up() * _rise()
	_slide_time = 0.0
	# A slide is as long as the run that earned it, so the duration is the dial
	# and the friction is solved to fit: bleed exactly this speed away over
	# exactly this time. Tuning the friction instead would leave the timer and
	# the speed floor cutting each other short at different speeds.
	_slide_span = slide_max_time + slide_time_gain * _run_amount()
	_slide_drag = maxf(slide_friction, (speed - slide_exit_speed) / _slide_span)
	_apply_stance(Stance.SLIDE)


## Stands up only when there is room, so crouching under something is not a way
## to clip through it.
func _try_stand() -> bool:
	ceiling_check.force_raycast_update()
	if ceiling_check.is_colliding():
		return false
	_apply_stance(Stance.STAND)
	return true


func _apply_stance(next: int) -> void:
	_stance = next
	var capsule := collider.shape as CapsuleShape3D
	var height := _stance_height(_stance)
	capsule.height = height
	collider.position.y = height * 0.5


## Stance heights scale with the body's authored height so a 1.6 m settler does
## not crouch inside a 1.45 m capsule.
func _stance_height(stance: int) -> float:
	return COLLIDER_HEIGHTS[stance] * (_body_height / COLLIDER_HEIGHTS[Stance.STAND])


func _stance_eye(stance: int) -> float:
	return EYE_HEIGHTS[stance] * (_body_eye / EYE_HEIGHTS[Stance.STAND])


# --- Camera and presentation ------------------------------------------------

## The collider is lifted onto a step in one physics frame; the mesh and the eye
## line are left behind by that much and slid back up over `step_smooth_time`.
func _update_step_offset(delta: float) -> void:
	if absf(_step_offset) < 0.001:
		_step_offset = 0.0
	else:
		_step_offset *= exp(-delta / maxf(step_smooth_time, 0.001))


## Where the visible body sits and how far over it has gone. The collider never
## tips — a flying player is still a standing capsule — so the whole difference
## between hovering and flying flat out is drawn here and in the two clips.
##
## Runs for everyone, not just the local player: stance and velocity are both
## synced, so a remote player leans from the same two numbers.
func _update_body_lean(delta: float) -> void:
	if _stance == Stance.CRASH:
		if _ragdoll != null and _ragdoll.limp():
			# The bones are lying where they fell, in world space. Leaning the
			# node they hang off would move the whole ragdoll out from under
			# itself.
			_fly_blend = lerpf(_fly_blend, 0.0, 1.0 - exp(-delta * 8.0))
			_swim_blend = lerpf(_swim_blend, 0.0, 1.0 - exp(-delta * 8.0))
			_swim_rush = lerpf(_swim_rush, 0.0, 1.0 - exp(-delta * 8.0))
			_run_blend = 0.0
			character.rotation.x = 0.0
			character.position = Vector3(0.0, _step_offset, 0.0)
			return
		_lay_out(delta)
		return
	var flying := _stance == Stance.FLY
	var flat_out := 0.0
	if flying:
		flat_out = clampf(
			inverse_lerp(float_speed * 1.4, fly_speed * FLAT_OUT, velocity.length()), 0.0, 1.0)
	_fly_blend = lerpf(_fly_blend, flat_out, 1.0 - exp(-delta * 5.0))
	# Water is the same continuum an order of magnitude slower: treading upright
	# at a standstill, laid out along the stroke once the body is going anywhere.
	# It finishes well short of `swim_speed`, because a swimmer is flat by the
	# second stroke rather than at the top speed of the fastest one.
	var stroking := 0.0
	var rushing := 0.0
	if _stance == Stance.SWIM:
		stroking = clampf(
			inverse_lerp(swim_speed * 0.2, swim_speed * 0.75, velocity.length()), 0.0, 1.0)
		# Off the target the boost is winding toward rather than off the speed
		# reached, which is the same choice `_cruise` exists for: the wind-up is
		# already seconds long and smooth, and reading the velocity instead would
		# have the view breathe with every turn taken at speed.
		rushing = clampf(inverse_lerp(swim_speed, swim_sprint_speed, _stroke), 0.0, 1.0)
	_swim_blend = lerpf(_swim_blend, stroking, 1.0 - exp(-delta * 4.0))
	_swim_rush = lerpf(_swim_rush, rushing, 1.0 - exp(-delta * 4.0))
	_run_blend = lerpf(_run_blend, 0.0 if flying else _run_amount(), 1.0 - exp(-delta * 4.0))

	# Flat out and level, the body lies horizontal; pointed straight up it stands
	# upright again, and straight down it goes head first. Hovering it does none
	# of this, which is what the blend scales. Flight and swimming never overlap,
	# so the larger of the two is whichever one is happening — and taking the
	# larger rather than the sum is what carries the lean through a launch out of
	# the water instead of standing the body up for the frames both are moving.
	var fly_lean := -(PI * 0.5 - atan2(_rise(), _horizontal_speed())) \
		* maxf(_fly_blend, _swim_blend)
	var lean := fly_lean - SPRINT_LEAN * _run_blend
	character.rotation.x = lean
	# One rotation, so the pivot is shared: weighted towards the hips by however
	# much of the lean is the flight's, and towards the floor by however much of
	# it is the run's. They only overlap for the moment after a landing.
	var pivot := Vector3.ZERO
	if absf(lean) > 0.0001:
		pivot.y = _body_lean * fly_lean / lean
	character.position = Vector3(0.0, _step_offset, 0.0) + pivot - Basis(Vector3.RIGHT, lean) * pivot


## The fallback crash, for a character whose .glb arrived without a skeleton the
## ragdoll could be built on. Everything with the stock character goes limp
## instead; see [Ragdoll].
##
## The tumble, and then the pick-up. While the body is still travelling it rolls
## with the ground going past it; once it stops it eases to the nearest whole
## half-turn, which is face down or face up rather than halfway onto its side.
## The last `CRASH_RISE` seconds unwind that back to upright, so standing up is
## the same motion played out instead of a snap.
##
## Turned about the hips like the flight lean, because a body rolling about its
## feet describes an arc a body length across and leaves the ground.
func _lay_out(delta: float) -> void:
	_fly_blend = lerpf(_fly_blend, 0.0, 1.0 - exp(-delta * 8.0))
	_swim_blend = lerpf(_swim_blend, 0.0, 1.0 - exp(-delta * 8.0))
	_swim_rush = lerpf(_swim_rush, 0.0, 1.0 - exp(-delta * 8.0))
	_run_blend = 0.0
	_tumble += _tumble_rate * delta
	_tumble_rate *= exp(-delta * TUMBLE_DECAY)
	# Once the roll has run out, settle onto the nearest whole half-turn, which is
	# face down or face up rather than stopped halfway onto one shoulder.
	if _tumble_rate < 1.0:
		_tumble = lerpf(_tumble, roundf(_tumble / PI) * PI, 1.0 - exp(-delta * 6.0))
	if _crash_left < CRASH_RISE:
		_tumble_rate = 0.0
		_tumble = lerpf(_tumble, 0.0, 1.0 - exp(-delta * 7.0))
	character.rotation.x = _tumble
	var pivot := Vector3(0.0, _body_lean, 0.0)
	character.position = Vector3(0.0, _step_offset, 0.0) \
		+ pivot - Basis(Vector3.RIGHT, _tumble) * pivot


func _update_camera(delta: float) -> void:
	var weight := 1.0 - exp(-delta * 12.0)
	camera_arm.spring_length = lerpf(camera_arm.spring_length, ARM_LENGTHS[_camera_mode], weight)
	camera_arm.position.x = lerpf(camera_arm.position.x, SHOULDER_OFFSETS[_camera_mode] * _shoulder, weight)
	_eye_height = lerpf(_eye_height, _stance_eye(_stance), weight)
	head.position.y = _eye_height + _step_offset
	_pull_camera_out_of_the_ground()
	camera.fov = lerpf(
		_base_fov + SPEED_FOV_RUSH * maxf(maxf(_fly_blend, _run_blend), _swim_rush),
		_base_fov * AIM_FOV_SCALE, _aim_amount())

	# Own body is hidden while the camera sits inside its head. Hiding is a
	# visibility switch and not SHADOWS_ONLY, because SurfaceSkin has already put
	# every character mesh's shadow out and that setting would light one back up
	# for the one case that used to want it.
	var inside_head := peer_id == multiplayer.get_unique_id() and camera_arm.spring_length < 0.35
	# What is in the hands keeps being drawn where the body is not: it is held out in
	# front of the eyes, so hiding it with the body would leave first person with no
	# weapon at all. The exception is a weapon brought right up to the eye, which
	# from inside is a wall of polygons rather than a weapon.
	var hide_weapon := false
	if _held_mesh != null and inside_head:
		hide_weapon = _held_mesh.global_position.distance_to(camera.global_position) < 0.3
	for mesh_instance in _character_meshes:
		mesh_instance.visible = not (hide_weapon if mesh_instance == _held_mesh else inside_head)


## The spring arm shortens against anything it can cast a sphere at, which covers
## props, players and any chunk of planet that has a collider. The planet is the
## one thing that regularly has none: a chunk is only given a body once it is near
## enough and finished building, and the third-person arm reaches four metres into
## ground that may be drawn and not yet solid. So the same height field that stops
## the body going through the world is asked about the camera as well, and the arm
## is halved until the eye is out in the air.
##
## Only ever shortens what the arm already worked out, so it cannot push the
## camera through something the cast did find.
func _pull_camera_out_of_the_ground() -> void:
	# First person has no arm to shorten, and the eye is inside a body that is
	# already kept out of the ground by the guard.
	if camera_arm.spring_length < 0.05:
		return
	var planet := _planet_below()
	if planet == null or planet.shape == null:
		return
	var origin := camera_arm.global_position
	var along := -camera_arm.global_basis.z
	var length := camera_arm.spring_length
	for step in 4:
		if length < 0.05:
			length = 0.0
			break
		var local := planet.to_local(origin + along * length)
		var out := local.normalized()
		var floor_radius := planet.shape.radius \
			+ planet.shape.elevation(out, planet.finest_spacing())
		if local.length() >= floor_radius + CAMERA_CLEARANCE:
			return
		length *= 0.5
	camera_arm.spring_length = length


func _prepare_animations() -> void:
	if animator == null:
		push_warning("player: %s has no AnimationPlayer; re-export the .glb with its clips"
			% character.name)
		return
	# glTF has no loop flag, so the cycles are marked here. The Animation
	# resources are shared by every player, which is fine: this is idempotent.
	for clip_name in LOOPING_CLIPS:
		if animator.has_animation(clip_name):
			animator.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	_play("Idle")


func _play(clip: String, speed := 1.0) -> void:
	if animator == null:
		return
	if clip != _clip and animator.has_animation(clip):
		animator.play(clip, CLIP_BLEND)
		_clip = clip
	animator.speed_scale = speed


func _update_animation(delta: float) -> void:
	var airborne := not _grounded_for_display()
	if _was_airborne and not airborne:
		_land_left = LAND_TIME
	_was_airborne = airborne
	_land_left = maxf(_land_left - delta, 0.0)

	var speed := _horizontal_speed()
	if _stance == Stance.CRASH:
		# There is no crash clip. `Fall` is the loosest pose the character has and
		# the tumble is what sells it; `Land` is a knee bend, which read the right
		# way round is someone pushing themselves back up.
		_play("Land" if _crash_left < CRASH_RISE else "Fall")
	elif _stance == Stance.FLY:
		# The two ends of one continuum, crossfaded at the point the body is about
		# halfway over: the lean is doing most of the work either side of it.
		_play("Fly" if _fly_blend > 0.45 else "Float")
	elif _stance == Stance.SWIM:
		# The same two ends as flight, at a tenth of the speed: sculling upright,
		# or laid out along a crawl. The stroke is resampled the way a stride is,
		# so a drift reads as a drift rather than as a sprint through treacle.
		if _swim_blend > 0.45:
			_play("Swim", clampf(velocity.length() / swim_speed, 0.6, 1.5))
		else:
			_play("Tread")
	elif _stance == Stance.SLIDE:
		_play("Slide")
	elif airborne:
		_play("JumpRise" if _rise() > 0.6 else "Fall")
	elif _land_left > 0.0 and speed < walk_speed * 0.6:
		# Skipped when you land already running, where a knee-bend would read as
		# a stumble rather than as absorbing the drop.
		_play("Land")
	elif _stance == Stance.CROUCH:
		if speed > 0.4:
			_play("CrouchWalk", clampf(speed / crouch_speed, 0.6, 1.6))
		else:
			_play("CrouchIdle")
	elif speed > 0.4:
		# Stride length is baked in, so the clip is resampled to the real speed
		# instead of letting the feet skate.
		if speed > (walk_speed + sprint_speed) * 0.5:
			# The clip stops reading as a stride somewhere past twice its own
			# speed, so the ceiling is low and the forward lean takes over from
			# there. Resampling all the way to 200 m/s would be a blur.
			_play("Run", clampf(speed / sprint_speed, 0.7, 1.9))
		else:
			_play("Walk", clampf(speed / walk_speed, 0.6, 1.5))
	else:
		_play("Idle")


## Remote players are interpolated rather than simulated, so is_on_floor() never
## fires for them and their contact has to be inferred from the synced velocity.
func _grounded_for_display() -> bool:
	if peer_id == multiplayer.get_unique_id():
		return _grounded()
	return absf(_rise()) < 1.5


func _update_hud(delta: float) -> void:
	# Sighted down the optic the crosshair draws in, which is most of what says the
	# shot has settled.
	reticle.set_spread(_horizontal_speed() / sprint_speed * (1.0 - 0.7 * _aim_amount()))
	if _coordinates != null and _coordinates.visible:
		_coordinates.refresh(global_position, _planet_below(), delta)
	if _weapon_bar != null:
		var cell := ItemDB.cell_size(_held)
		_weapon_bar.show_cell("cell  %d / %d" % [_charge(), cell] if cell > 0 else "")
	if not _menu_open:
		var target := _interact_target()
		prompt_plate.visible = target != null
		if target != null:
			interact_prompt.text = "E    %s" % target.call("interact_prompt")
	var parts: Array[String] = []
	match _camera_mode:
		CameraMode.FIRST:
			parts.append("first person")
		CameraMode.THIRD_NEAR:
			parts.append("third person, close")
		CameraMode.THIRD_FAR:
			parts.append("third person, far")
	if _camera_mode != CameraMode.FIRST:
		parts.append("left shoulder" if _shoulder < 0.0 else "right shoulder")
	if _stance == Stance.CROUCH:
		parts.append("crouched")
	elif _stance == Stance.SLIDE:
		parts.append("sliding")
	elif _stance == Stance.SWIM:
		parts.append("swimming")
	# Only once a run has actually wound up past a sprint: a readout that sat
	# there saying "5 m/s" through every walk would be noise.
	if _stance != Stance.FLY and _horizontal_speed() > sprint_speed:
		parts.append("%d m/s" % roundi(_horizontal_speed()))
	stance_label.text = "  ".join(parts)

	# The flight controls are nowhere else in the game, so they are on screen for
	# as long as they apply and gone the moment the feet are back down.
	flight_plate.visible = _stance == Stance.FLY and not _menu_open
	if _stance == Stance.FLY:
		flight_speed_label.text = "%s  %d m/s" % [
			"flying" if _fly_blend > 0.45 else "floating", roundi(velocity.length())]


func _update_target_label() -> void:
	aim_ray.force_raycast_update()
	target_name.text = ""
	if aim_ray.is_colliding():
		var collider_hit := aim_ray.get_collider()
		if collider_hit is OnlinePlayer and collider_hit != self:
			target_name.text = (collider_hit as OnlinePlayer).display_name
	target_plate.visible = not target_name.text.is_empty()


# --- Networking -------------------------------------------------------------

## The fastest a player in `stance` could honestly be travelling. Both flight and
## a wound-up run reach speeds an order of magnitude past a sprint, so this is
## most of what the check can still say: the ceiling is high because the game
## really does let a player go that fast.
func _speed_limit(stance: int) -> float:
	if stance == Stance.FLY:
		return fly_speed * 1.2
	# A slide leaves the ground run at 1.15 times what it entered on.
	return run_top_speed * 1.25


## Clients submit predicted movement. The server rejects wrong senders and
## implausible single-packet teleports, then relays accepted state to everyone.
@rpc("any_peer", "unreliable_ordered")
func _submit_state(next_transform: Transform3D, next_velocity: Vector3, look_pitch: float, stance: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != peer_id:
		return
	var next_stance := clampi(stance, 0, Stance.size() - 1)
	var limit := _speed_limit(next_stance)
	# What counts as a teleport depends on what the sender claims to be doing: a
	# flying player covers ten metres between packets, so a fixed few metres would
	# reject every honest one of them.
	var step := maxf(MAX_ACCEPTED_STEP, limit * SYNC_INTERVAL * 3.0)
	if _host_has_state and next_transform.origin.distance_to(_host_last_position) > step:
		_apply_state.rpc_id(sender, global_transform, velocity, _pitch, _stance)
		return
	_host_has_state = true
	_host_last_position = next_transform.origin
	global_transform = next_transform
	# Split against the sender's own up, which on a sphere is wherever they are
	# standing. Clamping the world's Y here would call a run across the equator a
	# vertical one.
	var up := next_transform.basis.y.normalized()
	var climb := next_velocity.dot(up)
	var flat := (next_velocity - up * climb).limit_length(limit)
	# The fastest anything can honestly leave the ground is a flat-out leap, so
	# the ceiling is written from the two numbers that decide one rather than as
	# a multiple of the standing jump — which a run already beats on its own, and
	# which therefore used to clamp every sprint jump anyone else made.
	var rise := maxf(jump_velocity * (1.0 + jump_speed_gain) * 1.2, limit)
	velocity = flat + up * clampf(climb, -maxf(80.0, limit), rise)
	_pitch = clampf(look_pitch, -1.48, 1.48)
	head.rotation.x = _pitch
	_apply_stance(next_stance)
	_target_transform = global_transform
	_apply_state.rpc(global_transform, velocity, _pitch, _stance)


## A player owns their own look: everyone else applies what they are told, and the
## host relays it on to peers that cannot hear the sender directly.
@rpc("any_peer", "call_remote", "reliable")
func _wear(worn: PackedStringArray) -> void:
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	apply_worn(worn)


## Only what is in the hands is broadcast, not the whole rack: the rack is private
## and nobody else can see it.
@rpc("any_peer", "call_remote", "reliable")
func _hold(id: String) -> void:
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	apply_held(id)


## Swings and shots are sent rather than derived from state, because both are
## instants: a peer that missed the packet should miss the swing, not play it late.
## `call_local` means the shooter takes the same path as everyone else.
@rpc("any_peer", "call_local", "reliable")
func _swing_weapon() -> void:
	if not _sender_owns_this_player():
		return
	if _weapon_pose != null:
		_weapon_pose.swing()


@rpc("any_peer", "call_local", "reliable")
func _fire_bolt(from: Vector3, along: Vector3) -> void:
	if not _sender_owns_this_player():
		return
	LaserBolt.fire(get_parent(), from, along, self)


## A local call reports no sender, so that stands for this player themselves.
func _sender_owns_this_player() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	return sender == 0 or sender == peer_id


@rpc("authority", "call_remote", "unreliable_ordered")
func _apply_state(next_transform: Transform3D, next_velocity: Vector3, look_pitch: float, stance: int) -> void:
	if peer_id == multiplayer.get_unique_id():
		return
	_target_transform = next_transform
	_target_velocity = next_velocity
	_target_pitch = clampf(look_pitch, -1.48, 1.48)
	_extrapolated = 0.0
	_apply_stance(clampi(stance, 0, Stance.size() - 1))
