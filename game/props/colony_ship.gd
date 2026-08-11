@tool
class_name ColonyShip
extends Landmark

## The lander standing on the coast at Vacationer's Landing.
##
## A [Landmark] rather than a bare [SurfaceAnchor], and that is the whole of how
## it gets its waypoint: the anchor stands it on the ground and puts it in the
## [constant Landmark.GROUP] group, and [WaypointLayer] names anything in that
## group without being told about ships. So the title, the tint and the three
## ranges below are inherited exports, set in `game/world.tscn` beside the rest
## of the planet's named places.
##
## The model is raised here rather than instanced in the scene file, because the
## one thing that has to happen to it — every surface repainted with the game's
## own material — would otherwise be a property override on a node inside an
## imported .glb, keyed by a name MeshMaker chose. Walking the tree survives a
## re-export; a path called `tmp28mf7g7u_ply` does not.
##
## Collision comes with the asset. `build_landing.py` exports a second, much
## coarser copy of the hull named with Godot's `-colonly` suffix, so the import
## turns it into a [StaticBody3D] with a trimesh shape and nothing to draw. At
## walking height the only geometry there is the four legs, which is what makes
## the ship something to stand under rather than a cylinder to bump into.

const MODEL: PackedScene = preload("res://assets/runtime/environment/colony_ship.glb")
const SURFACE: ShaderMaterial = preload("res://game/props/colony_ship.tres")


func _ready() -> void:
	# Landmark's own ready joins the group and stands the anchor up. The model
	# has to follow that, not race it: it is parented here and inherits whatever
	# transform the placement worked out.
	super()
	_raise()


## Hangs the ship off the anchor. Internal, so the hundreds of nodes a .glb can
## unpack into stay out of the Scene dock and out of `world.tscn` when this runs
## in the editor.
func _raise() -> void:
	var model := MODEL.instantiate()
	model.name = "Hull"
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		mesh_instance.material_override = SURFACE
		# A 26 m ship on an otherwise empty shore is mostly read by its shadow,
		# which is also the only thing that says where its legs meet the ground.
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(model, false, Node.INTERNAL_MODE_BACK)
