class_name MeepPickProxy
extends StaticBody3D

## A collider lent to whichever Meep is nearest the player, so that a creature the
## game does not give a node to can still be looked at and used.
##
## Meeps are rows in an array — that is what lets a planet hold thousands of them —
## and the interaction ray needs something physical under the crosshair. So a small
## pool of these follows the nearest few, exactly the way [FaunaSpawner] lends its
## handful of real lights to whichever creatures are close enough to be worth
## lighting. Eight bodies covers everything within arm's reach of one player; the
## other thousand need nothing, because nobody can point at them.
##
## On its own layer rather than the world's. Physical crowd blocking is supplied by
## [MeepBlockProxy]; keeping this pick shape separate means interaction can remain
## broad without making ground checks or ability sweeps mistake a Meep for terrain.

## Layer these sit on. Nothing in the game masks it, so a proxy is invisible to
## movement and to everything that names a layer; the queries that ask for every
## layer, which is what the interaction ray does, are exactly the ones that should
## see it.
const LAYER := 1 << 5

var colony: MeepColony
## Row in the colony's arrays, or -1 while this proxy is spare.
var meep := -1

var _shape: CapsuleShape3D
var _base_radius := 0.32
var _base_height := 1.2


func _init() -> void:
	name = "MeepPickProxy"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	collision_layer = LAYER
	collision_mask = 0
	_shape = CapsuleShape3D.new()
	_shape.radius = 0.32
	_shape.height = 1.2
	var holder := CollisionShape3D.new()
	holder.shape = _shape
	add_child(holder)
	# Spare proxies are parked rather than freed, so being off has to be cheap and
	# complete.
	set_lent(-1)


func configure(host: MeepColony, radius: float, height := 1.2) -> void:
	colony = host
	_base_height = maxf(height, 0.2)
	_base_radius = clampf(radius, 0.05, _base_height * 0.5)
	_apply_scale(1.0)


func _apply_scale(scale: float) -> void:
	var safe_height := maxf(_base_height * scale, 0.1)
	_shape.radius = clampf(_base_radius * scale, 0.025, safe_height * 0.5)
	_shape.height = maxf(safe_height, _shape.radius * 2.0)


## Test/reporting seam for the exact shape lent by this fixed pool.
func capsule_shape() -> CapsuleShape3D:
	return _shape


## Points this proxy at a Meep, or parks it when [param index] is negative.
func set_lent(index: int) -> void:
	meep = index
	var lent := index >= 0
	_apply_scale(colony.meep_scale(index) if lent and colony != null else 1.0)
	collision_layer = LAYER if lent else 0
	visible = lent


func interact_prompt() -> String:
	if colony == null or meep < 0:
		return "Meep"
	return colony.meep_summary(meep)


## Inspecting a Meep does not change it. The prompt over it is the report — which
## is why that is a live one — and this is the seam a future panel hangs off.
func interact(player: OnlinePlayer) -> void:
	if colony != null and meep >= 0:
		colony.inspect(meep, player)
