class_name MeepBlockProxy
extends StaticBody3D

## One member of the fixed local crowd-collision pool.
##
## Meeps remain rows in [MeepColony]. Only the nearest visible rows borrow these
## bodies, giving the local player something physical to slide around without
## turning the population into CharacterBody3D or Skeleton3D nodes.

## Dedicated crowd layer. Terrain, ground probes, and ability rays stay on layer 1.
const LAYER := 1 << 6

var colony: MeepColony
## Row in the colony arrays, or -1 while this body is parked.
var meep := -1

var _shape: CapsuleShape3D
var _base_radius := 0.32
var _base_height := 1.2


func _init() -> void:
	name = "MeepBlockProxy"
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	collision_mask = 0
	_shape = CapsuleShape3D.new()
	_shape.radius = 0.32
	_shape.height = 1.2
	var holder := CollisionShape3D.new()
	holder.shape = _shape
	add_child(holder)
	set_lent(-1)


func configure(host: MeepColony, radius: float, height: float) -> void:
	colony = host
	_base_height = maxf(height, 0.2)
	_base_radius = clampf(radius, 0.05, _base_height * 0.5)
	_apply_scale(1.0)


func _apply_scale(scale: float) -> void:
	var safe_height := maxf(_base_height * scale, 0.1)
	_shape.radius = clampf(_base_radius * scale, 0.025, safe_height * 0.5)
	_shape.height = maxf(safe_height, _shape.radius * 2.0)


## Lends this body to one row, or completely removes a spare from physics.
func set_lent(index: int) -> void:
	meep = index
	var lent := index >= 0
	_apply_scale(colony.meep_scale(index) if lent and colony != null else 1.0)
	collision_layer = LAYER if lent else 0
	visible = lent


## A block body can win the same ray hit as the overlapping pick proxy. Forwarding
## the interaction contract makes either deterministic result identify this Meep.
func interact_prompt() -> String:
	if colony == null or meep < 0:
		return "Meep"
	return colony.meep_summary(meep)


func interact(player: OnlinePlayer) -> void:
	if colony != null and meep >= 0:
		colony.inspect(meep, player)


## Test/reporting seam for the exact physical shape in the pool.
func capsule_shape() -> CapsuleShape3D:
	return _shape
