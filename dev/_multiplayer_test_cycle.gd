extends CelestialCycle

## Multiplayer pickup tests need a phase value, not a rendered sun/planet.
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
