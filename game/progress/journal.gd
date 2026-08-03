class_name Journal
extends RefCounted

## What one player has done, against the goals in [JournalDB].
##
## Held by [OnlinePlayer] and driven from its physics step, because the only
## condition there is measures a distance from the player to a place. Checked on an
## interval rather than every frame: the entries are a handful, but each one is a
## group walk and a square root against a target that cannot be reached in the
## seven metres a flight covers between checks.
##
## Completion is **local and persistent**. Nothing about a quest is replicated: a
## co-op session shares a world, not a diary, and the host has no business being
## told which achievements a guest has. It saves to `settings.cfg` under
## `progress/done` for the same reason the look does — it is a fact about this
## player on this machine.

## Seconds between condition checks.
const INTERVAL := 0.5

signal completed(id: String)

var _done: Dictionary = {}
var _elapsed := 0.0


func _init() -> void:
	load_progress()


func is_done(id: String) -> bool:
	return bool(_done.get(id, false))


func done_count(kind: StringName) -> int:
	var count := 0
	for id in JournalDB.ids_of_kind(kind):
		if is_done(id):
			count += 1
	return count


## Marks an entry done and saves. Returns false if it was already done, so a
## caller can tell a fresh completion from a repeat and only announce the former.
func complete(id: String) -> bool:
	if not JournalDB.has_entry(id) or is_done(id):
		return false
	_done[id] = true
	save_progress()
	completed.emit(id)
	return true


## Clears one entry or, with no id, all of them. The admin tab's undo.
func reset(id := "") -> void:
	if id.is_empty():
		_done.clear()
	else:
		_done.erase(id)
	save_progress()


## Walks the unfinished entries and completes any whose condition now holds.
## `where` is the player's global position; `tree` is how landmarks are found.
func track(where: Vector3, tree: SceneTree, delta: float) -> void:
	_elapsed += delta
	if _elapsed < INTERVAL or tree == null:
		return
	_elapsed = 0.0
	var places := _landmarks(tree)
	for id: String in JournalDB.ENTRIES:
		if is_done(id):
			continue
		var wanted := JournalDB.landmark_of(id)
		if wanted.is_empty() or not places.has(wanted):
			continue
		var at: Vector3 = places[wanted]
		if where.distance_to(at) <= JournalDB.within_of(id):
			complete(id)


## Landmark node name → where it is. By node name rather than title, because the
## title is player-facing text and free to be reworded without breaking a goal.
func _landmarks(tree: SceneTree) -> Dictionary:
	var out: Dictionary = {}
	for node in tree.get_nodes_in_group(Landmark.GROUP):
		var landmark := node as Landmark
		if landmark != null:
			out[landmark.name] = landmark.global_position
	return out


func load_progress() -> void:
	_done.clear()
	if SettingsManager == null:
		return
	var raw: Variant = SettingsManager.get_setting(&"progress", &"done", [])
	if raw is Array:
		for entry: Variant in raw:
			var id := str(entry)
			if JournalDB.has_entry(id):
				_done[id] = true


func save_progress() -> void:
	if SettingsManager == null:
		return
	SettingsManager.set_setting(&"progress", &"done", _done.keys(), false)
	SettingsManager.save_settings()
