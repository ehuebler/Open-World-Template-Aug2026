class_name LobbyPanel
extends HBoxContainer

## Create and join, side by side over the planet, because they are the whole of
## "Online" and putting them a click apart only hid one of them. The old menu had
## a hub screen in front of these two; there is nothing for it to say.
##
## The panel owns no session state. Every button ends in a NetworkManager call and
## the answer arrives back as a status line.

signal closed
signal notice(message: String, is_error: bool)

const TextModerationScript := preload("res://core/text_moderation.gd")
const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")
const DEFAULT_PORT := 7777

var _player_name := "Player"
var _lobby_list: VBoxContainer
var _name_fields: Array[LineEdit] = []


func _ready() -> void:
	add_theme_constant_override("separation", 28)
	alignment = BoxContainer.ALIGNMENT_CENTER
	_build_create_column()
	_build_join_column()
	NetworkManager.lobby_list_changed.connect(_on_lobby_list_changed)
	_refresh_lobbies()


func _exit_tree() -> void:
	if NetworkManager.lobby_list_changed.is_connected(_on_lobby_list_changed):
		NetworkManager.lobby_list_changed.disconnect(_on_lobby_list_changed)


func _build_create_column() -> void:
	var box := MenuWidgets.card(self, 26, true)
	box.custom_minimum_size = Vector2(MenuWidgets.panel_width(self, 0.4, 560.0), 0)
	box.add_child(MenuWidgets.heading("CREATE LOBBY"))
	box.add_child(PencilSurface.rule())

	var form := MenuWidgets.scroll_area(box)
	var player := MenuWidgets.field(form, "Player name", _player_name, "Your display name")
	_track_name(player)
	var lobby := MenuWidgets.field(form, "Lobby name", "%s's Lobby" % _player_name, "Lobby name")
	var max_players := MenuWidgets.number_field(form, "Max players", 2, 32, 8)

	var access := VBoxContainer.new()
	access.add_theme_constant_override("separation", 5)
	form.add_child(access)
	access.add_child(MenuWidgets.caption("Lobby access"))
	var visibility := OptionButton.new()
	visibility.add_item("Public")
	visibility.add_item("Private - code required")
	PencilSurface.add_to(visibility, PencilSurface.Style.BUTTON)
	access.add_child(visibility)

	var code := MenuWidgets.field(form, "Private lobby code", "", "4-12 letters or numbers")
	code.max_length = 12
	var code_group := code.get_parent() as Control
	code_group.visible = false
	visibility.item_selected.connect(func(index: int) -> void:
		code_group.visible = index == 1
	)

	var host := MenuWidgets.button("HOST LOBBY", PencilSurface.Style.PRIMARY)
	host.custom_minimum_size.y = 56
	host.pressed.connect(func() -> void:
		_player_name = player.text.strip_edges()
		var lobby_name := lobby.text.strip_edges()
		var is_private := visibility.selected == 1
		var lobby_code := code.text.strip_edges()
		if not _validate(_player_name, lobby_name):
			return
		if is_private and not _is_valid_code(lobby_code):
			notice.emit("Private codes must be 4-12 letters or numbers.", true)
			return
		NetworkManager.host_game({
			"player_name": _player_name,
			"name": lobby_name,
			"lobby_name": lobby_name,
			"max_players": int(max_players.value),
			"visibility": "private" if is_private else "public",
			"code": lobby_code if is_private else "",
		})
	)
	box.add_child(host)


func _build_join_column() -> void:
	var box := MenuWidgets.card(self, 26, true)
	box.custom_minimum_size = Vector2(MenuWidgets.panel_width(self, 0.4, 560.0), 0)
	box.add_child(MenuWidgets.heading("JOIN LOBBY"))
	box.add_child(PencilSurface.rule())

	var form := MenuWidgets.scroll_area(box)
	var player := MenuWidgets.field(form, "Player name", _player_name, "Your display name")
	_track_name(player)

	var refresh := MenuWidgets.button("REFRESH")
	refresh.pressed.connect(_refresh_lobbies)
	form.add_child(refresh)

	_lobby_list = VBoxContainer.new()
	_lobby_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lobby_list.add_theme_constant_override("separation", 8)
	form.add_child(_lobby_list)
	_show_empty_lobbies()

	form.add_child(PencilSurface.rule())
	form.add_child(MenuWidgets.caption("Or connect straight to a host."))
	var address := MenuWidgets.field(form, "Address", "127.0.0.1", "IP address or hostname")
	var code := MenuWidgets.field(form, "Lobby code", "", "Blank for public lobbies")
	code.max_length = 12

	var join := MenuWidgets.button("CONNECT", PencilSurface.Style.PRIMARY)
	join.custom_minimum_size.y = 56
	join.pressed.connect(func() -> void:
		_player_name = player.text.strip_edges()
		if not _validate(_player_name):
			return
		NetworkManager.join_game(
			address.text.strip_edges(), DEFAULT_PORT, _player_name, code.text.strip_edges())
	)
	box.add_child(join)


## Both columns ask for the player's name, and the player entered it once. Typing
## in either field updates the other so whichever button they press has it.
func _track_name(input: LineEdit) -> void:
	_name_fields.append(input)
	input.text_changed.connect(func(value: String) -> void:
		_player_name = value.strip_edges()
		for other: LineEdit in _name_fields:
			if other != input and is_instance_valid(other):
				other.text = value
	)


func _refresh_lobbies() -> void:
	notice.emit("Searching for games...", false)
	NetworkManager.refresh_lobbies()


func _on_lobby_list_changed(lobbies: Array) -> void:
	if _lobby_list == null or not is_instance_valid(_lobby_list):
		return
	for child: Node in _lobby_list.get_children():
		child.queue_free()
	if lobbies.is_empty():
		_show_empty_lobbies()
		return
	for lobby_data: Variant in lobbies:
		if lobby_data is Dictionary:
			var lobby_name := String(lobby_data.get("lobby_name", lobby_data.get("name", "Lobby")))
			if TextModerationScript.is_allowed(lobby_name):
				_lobby_list.add_child(_make_lobby_row(lobby_data))


func _make_lobby_row(data: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	PencilSurface.add_to(panel, PencilSurface.Style.ROW)
	var padding := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		padding.add_theme_constant_override("margin_%s" % side, 12)
	panel.add_child(padding)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	padding.add_child(row)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(details)
	var name_label := Label.new()
	name_label.text = String(data.get("lobby_name", data.get("name", "Lobby")))
	name_label.add_theme_color_override("font_color", PALETTE.text_primary)
	details.add_child(name_label)
	var passworded := bool(data.get("passworded", false))
	var meta := MenuWidgets.caption("%s  -  %s/%s players" % [
		"Private" if passworded else "Public",
		data.get("players", data.get("player_count", 0)),
		data.get("max_players", "?"),
	])
	details.add_child(meta)
	var join := MenuWidgets.button("JOIN")
	join.pressed.connect(func() -> void:
		if not _validate(_player_name):
			return
		if passworded:
			_ask_for_code(data)
			return
		NetworkManager.join_game(
			String(data.get("address", data.get("ip", ""))),
			int(data.get("port", DEFAULT_PORT)),
			_player_name,
			""
		)
	)
	row.add_child(join)
	return panel


## A private lobby needs one more thing than the row has room for, and the browser
## is worth keeping on screen while it is asked for.
func _ask_for_code(data: Dictionary) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = String(data.get("lobby_name", data.get("name", "Private Lobby")))
	dialog.ok_button_text = "JOIN"
	dialog.add_cancel_button("CANCEL")
	var code := LineEdit.new()
	code.placeholder_text = "Lobby code"
	code.max_length = 12
	code.secret = true
	code.custom_minimum_size.x = 260
	PencilSurface.add_to(code, PencilSurface.Style.INPUT)
	dialog.add_child(code)
	dialog.register_text_enter(code)
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		var entered := code.text.strip_edges()
		if entered.is_empty():
			notice.emit("Enter the private lobby code.", true)
			return
		NetworkManager.join_game(
			String(data.get("address", data.get("ip", ""))),
			int(data.get("port", DEFAULT_PORT)),
			_player_name,
			entered
		)
	)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free()
	)
	dialog.popup_centered()
	code.grab_focus()


func _show_empty_lobbies() -> void:
	var empty := MenuWidgets.caption("No lobbies found. Refresh, or connect directly below.")
	empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_list.add_child(empty)


func _validate(player_name: String, lobby_name := "") -> bool:
	if player_name.strip_edges().is_empty():
		notice.emit("Enter a player name.", true)
		return false
	if not TextModerationScript.is_allowed(player_name):
		notice.emit("Please choose an appropriate player name.", true)
		return false
	if not lobby_name.is_empty() and not TextModerationScript.is_allowed(lobby_name):
		notice.emit("Please choose an appropriate lobby name.", true)
		return false
	return true


func _is_valid_code(value: String) -> bool:
	if value.length() < 4 or value.length() > 12:
		return false
	for character in value:
		var codepoint := character.to_lower().to_ascii_buffer()[0]
		var is_number := codepoint >= 48 and codepoint <= 57
		var is_letter := codepoint >= 97 and codepoint <= 122
		if not is_number and not is_letter:
			return false
	return true
