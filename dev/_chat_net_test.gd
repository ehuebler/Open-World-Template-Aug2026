extends Node

## Chat over a real connection, as a client of a host in another process. The
## single-process harness cannot see the host stamping names or the relay working,
## because with an offline peer it is both ends at once.
##
## Start a host first, then run this:
##
##     godot --headless --path . -- --server --port=7777 --lobby-name="Chat Test"
##     godot --path . dev/_chat_net_test.tscn
##
## What it proves is that the line goes out unstamped and comes back attributed:
## the name on it is the one the host holds in its roster, not one this process
## chose, and the joining announcement arrives the same way.

const NAME := "Rowan"


func _ready() -> void:
	# NetworkManager opens the world with change_scene_to_file, which frees
	# whatever the current scene is. A stand-in takes that job so this harness
	# survives the session it starts. It has to wait a frame: root is still
	# setting up its children while this runs.
	await get_tree().process_frame
	var stand_in := Node.new()
	stand_in.name = "StandIn"
	get_tree().root.add_child(stand_in)
	get_tree().current_scene = stand_in

	NetworkManager.join_game("127.0.0.1", 7777, NAME)
	var waited := 0
	while not NetworkManager.in_multiplayer_session() and waited < 300:
		waited += 1
		await get_tree().process_frame
	if not NetworkManager.in_multiplayer_session():
		_report("connect", "no host answered on 127.0.0.1:7777 — start one first")
		get_tree().quit(1)
		return
	_report("connect", "in as peer %d after %d frames" % [multiplayer.get_unique_id(), waited])

	# Long enough for registration to land and the host to announce it.
	await _wait(90)
	_report("on joining", "%s" % [_lines()])

	ChatManager.say("hello from the client")
	await _wait(90)
	_report("said", "%s" % [_lines()])

	# The host is the one that stamps a name, so what comes back should be the
	# roster's idea of this peer rather than anything sent from here.
	var mine := ""
	for entry: Dictionary in ChatManager.history:
		if str(entry.get("kind", "")) == ChatManager.SAY:
			mine = str(entry.get("name", ""))
	_report("attributed", "%s (expected %s)" % [mine, NAME])

	# Pacing is the host's: a burst should not all come through.
	for index in 5:
		ChatManager.say("spam %d" % index)
	await _wait(90)
	_report("paced", "%d of 5 lines got through" % _count("spam"))

	ChatManager.say("shit")
	await _wait(90)
	_report("moderated", "%s" % [_lines().slice(maxi(_lines().size() - 2, 0))])

	NetworkManager.leave_game()
	await _wait(10)
	get_tree().quit()


func _count(fragment: String) -> int:
	var found := 0
	for entry: Dictionary in ChatManager.history:
		if str(entry.get("text", "")).begins_with(fragment):
			found += 1
	return found


func _lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for entry: Dictionary in ChatManager.history:
		lines.append("%s%s" % [
			"" if str(entry.get("name", "")).is_empty() else "%s: " % entry["name"],
			entry.get("text", ""),
		])
	return lines


func _wait(frames: int) -> void:
	for _frame in frames:
		await get_tree().process_frame


func _report(step: String, detail: String) -> void:
	print("chat_net_test: %-12s %s" % [step, detail])
