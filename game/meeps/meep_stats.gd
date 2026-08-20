class_name MeepStats
extends Resource

## What a Meep is, as numbers. One of these is shared by every Meep in a colony;
## only the values that differ per individual — health, where it is, what it is
## doing — live in the colony's own arrays.
##
## A resource rather than constants so the numbers can be tuned in the inspector
## and so a later colony can run a different kind of settler off the same
## simulation without a second code path.

## Health a fresh settler is released with. Small: a Meep is not a fighter, and the
## point of the number is that losing them to an uncleared nest has to hurt.
@export var maximum_health := 24.0
## Metres per second on open ground. Meeps cover a hundred-metre town all day; at the
## old 2.4 m/s, most of what a player saw was the walk to work rather than the work.
## Still well under the player's 9 m/s walk, so one is easy to catch and inspect.
@export var walk_speed := 5.0
## How fast the same Meep moves when it is frightened.
@export var flee_speed := 7.2
## Radius of the body, for hit tests and for the size it is drawn at.
@export var body_radius := 0.35
## Ground-to-head height of the authored creature and its physical proxy capsule.
@export var body_height := 1.2
## Radius of the upright proxy capsule. Kept separate from combat's historical
## body radius so adding crowd collision does not change damage policy.
@export var collision_radius := 0.32
## Work done per second on a job, in job seconds. Reserved for the construction
## passes; the board already divides progress by it.
@export var work_rate := 1.25
## How far a Meep notices things on its own, in metres. Reserved for the mobs pass.
@export var sight_range := 16.0
## Metres from a target that count as arrived. A little over one grid cell, so a
## Meep does not oscillate across the boundary of the cell it is aiming at.
@export var arrive_within := 2.4
## How far a Meep will wander from the colony centre when it has nothing to do, as
## a share of the claim's radius. Wandering Meeps that leave town read as lost
## rather than idle.
@export_range(0.1, 1.0) var wander_share := 0.75
## Seconds a wander lasts before a new spot is picked, even if the old one was
## never reached.
@export var wander_seconds := 9.0
