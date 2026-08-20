class_name MeepStructureProxy
extends StaticBody3D

## A physical building collider with a live look-at report.
##
## [MeepStructures] already lends a small collider pool to the nearest buildings.
## Giving those same bodies the interaction contract avoids a second node pool:
## whichever hut can currently stop the player can also say who owns it and who is
## home. A distant city still has no body per building.

var colony: MeepColony
## Structure index currently represented, or -1 while this body is parked.
var structure := -1


func configure(host: MeepColony) -> void:
	colony = host


func set_lent(index: int) -> void:
	structure = index


func interact_prompt() -> String:
	if colony == null or structure < 0:
		return "Building"
	return colony.structure_summary(structure)


## Ordinary structures retain the inspection seam. Completed specialty houses
## route through the colony so the interacting player's local overlay opens.
func interact(player: OnlinePlayer) -> void:
	if colony != null and structure >= 0:
		colony.interact_structure(structure, player)
