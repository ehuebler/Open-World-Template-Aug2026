class_name SettlementLauncher
extends Ability

## Inventory definition retained for catalogue presentation and ownership.
## Settlement launchers are deliberately not direct-cast powers anymore;
## BuildingAbility chooses one of their parent-city records and opens targeting.


func _press() -> bool:
	return false
