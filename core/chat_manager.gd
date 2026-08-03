extends Node

## Session text chat. Add this script as the "ChatManager" autoload.
##
## The host is the authority on who said what: a client hands its line to the
## host, and the host stamps it with the name from its own roster before sending
## it on. That is what stops a peer putting words in someone else's mouth, and it
## is the same shape as player registration in network_manager.gd.
##
## Nothing here draws: `ui/chat/chat_hud.gd` listens to `message_posted` and
## reads `history`, so a project can replace the panel without touching the wire.

signal message_posted(entry: Dictionary)
## The log was replaced wholesale — a fresh session, or catch-up from the host.
signal history_reset

## What somebody typed, versus what the session is telling everyone.
const SAY := "say"
const SYSTEM := "system"

const TextModerationScript := preload("res://core/text_moderation.gd")

## Long enough to scroll back through, short enough to hand a joining peer.
const HISTORY_LIMIT := 60
const CATCH_UP := 12
const MAX_LENGTH := 240
## The shortest gap the host will accept between two lines from one peer. Chat is
## the one place a client writes text onto everybody's screen, so the pace is the
## host's to set rather than the sender's to promise.
const MIN_INTERVAL := 0.4

var history: Array[Dictionary] = []
## Peer id to the time it last got a line through, for the pacing above.
var _last_line: Dictionary = {}
## Peer id to name, kept because the roster drops a peer before it says the peer
## left, and "someone left" is not worth printing.
var _names: Dictionary = {}


func _ready() -> void:
	# Chat outlives the pause it might be read during.
	process_mode = Node.PROCESS_MODE_ALWAYS
	NetworkManager.session_started.connect(_on_session_started)
	NetworkManager.session_ended.connect(clear)
	NetworkManager.player_registered.connect(_on_player_registered)
	NetworkManager.player_left.connect(_on_player_left)


## Say something as the local player. Safe to call when offline, where it does
## nothing rather than erroring: the caller is UI and should not have to check.
func say(text: String) -> void:
	var line := text.strip_edges().substr(0, MAX_LENGTH)
	if line.is_empty() or not NetworkManager.in_multiplayer_session():
		return
	if multiplayer.is_server():
		_take_line(1, line)
	else:
		_offer_line.rpc_id(1, line)


## A line only this peer sees, for telling the player something about their own
## session rather than relaying anyone's words. Marked local so the host does not
## hand its own notices to the next peer that joins.
func notify(text: String) -> void:
	_post({"kind": SYSTEM, "name": "", "text": text, "peer_id": 0, "local": true})


func clear() -> void:
	history.clear()
	_last_line.clear()
	_names.clear()
	history_reset.emit()


func _on_session_started() -> void:
	clear()
	if not NetworkManager.in_multiplayer_session():
		return
	notify("%s — Enter to chat, hold V to talk" % NetworkManager.local_player_name)


func _on_player_registered(peer_id: int, metadata: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var who := str(metadata.get("name", "A player"))
	_names[peer_id] = who
	# Someone arriving mid-conversation gets the tail of it, so the panel is not
	# blank while everyone else is mid-sentence.
	var said: Array[Dictionary] = []
	for entry: Dictionary in history:
		if not bool(entry.get("local", false)):
			said.append(entry)
	if not said.is_empty():
		_catch_up.rpc_id(peer_id, said.slice(maxi(said.size() - CATCH_UP, 0)))
	_announce("%s joined" % who)


func _on_player_left(peer_id: int) -> void:
	# Only the host says so. Every peer sees the same disconnect locally, and all
	# of them announcing it would print the line once per player in the session.
	if not multiplayer.is_server():
		return
	_last_line.erase(peer_id)
	var who := str(_names.get(peer_id, ""))
	_names.erase(peer_id)
	_announce("%s left" % (who if not who.is_empty() else "A player"))


func _announce(text: String) -> void:
	_deliver.rpc({"kind": SYSTEM, "name": "", "text": text, "peer_id": 0})


## Host side of one line, whether it arrived over the wire or was typed here.
func _take_line(peer_id: int, text: String) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_line.get(peer_id, -MIN_INTERVAL)) < MIN_INTERVAL:
		return
	_last_line[peer_id] = now
	if not TextModerationScript.is_allowed(text):
		# Told only to whoever sent it: the point is to have them rephrase, not to
		# repeat the thing to the room.
		_deliver.rpc_id(peer_id, {
			"kind": SYSTEM, "name": "", "text": "Message blocked.", "peer_id": 0,
		})
		return
	_deliver.rpc({
		"kind": SAY,
		"name": str(NetworkManager.get_player_metadata(peer_id).get("name", "Player")),
		"text": text,
		"peer_id": peer_id,
	})


@rpc("any_peer", "reliable")
func _offer_line(text: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not NetworkManager.players.has(sender):
		return
	_take_line(sender, str(text).strip_edges().substr(0, MAX_LENGTH))


@rpc("authority", "call_local", "reliable")
func _deliver(entry: Dictionary) -> void:
	_post(entry)


## What was said before this peer arrived, which goes in front of the little it
## has of its own rather than over the top of it.
@rpc("authority", "reliable")
func _catch_up(entries: Array) -> void:
	var older: Array[Dictionary] = []
	for entry_variant: Variant in entries:
		if entry_variant is Dictionary:
			older.append((entry_variant as Dictionary).duplicate(true))
	older.append_array(history)
	history = older
	if history.size() > HISTORY_LIMIT:
		history = history.slice(history.size() - HISTORY_LIMIT)
	history_reset.emit()


func _post(entry: Dictionary) -> void:
	var stamped := entry.duplicate(true)
	stamped["at"] = Time.get_ticks_msec()
	history.append(stamped)
	if history.size() > HISTORY_LIMIT:
		history = history.slice(history.size() - HISTORY_LIMIT)
	message_posted.emit(stamped)
