class_name MenuWidgets
extends RefCounted

## The rows the home screen's panels are assembled from. They live apart from any
## one screen because the settings tabs and the lobby forms want the same slider,
## the same labelled dropdown and the same card, and a second copy of a row is a
## second place for it to drift.
##
## Everything here is drawn on a lit pane by AuroraSurface, so it is only legible
## over the starfield once it is sitting on a card. Bare text over space is the
## home screen's own job (see home_screen.gd), not this file's.

const PALETTE: UIPalette = preload("res://ui/themes/ui_palette.tres")


static func button(label: String, style := AuroraSurface.Style.BUTTON) -> Button:
	var control := Button.new()
	control.text = label
	dress(control, style)
	return control


## Gives a button its fill. Split out from [method button] because the pause
## card's buttons come from a scene rather than from here, and the pairing has to
## hold for both.
##
## All three fills take the theme's void-dark type, and that is a property of the
## palette rather than a happy accident: cyan, periwinkle and rose are all light.
## The set before this had one fill — a burnt tangerine — dark enough to need pale
## type instead, and this function existed to remember it.
static func dress(control: Button, style: AuroraSurface.Style) -> void:
	AuroraSurface.add_to(control, style)


## Fills [param row] with one button per label, the open one carrying the gold
## fill. Colour is the only thing marking it: state is shading and meaning is
## hue in this UI, and which tab is open is meaning.
##
## Rebuilt on every switch rather than restyled in place, because that is the
## cheaper thing to get right — a strip that is redrawn from one integer cannot
## end up with two tabs both looking open.
static func fill_tab_row(row: HBoxContainer, labels: Array[String], current: int,
		on_pick: Callable, font_size := 15) -> void:
	for child in row.get_children():
		child.queue_free()
	for index in labels.size():
		var control := button(labels[index],
			AuroraSurface.Style.PRIMARY if index == current else AuroraSurface.Style.BUTTON)
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		control.add_theme_font_size_override("font_size", font_size)
		var chosen := index
		control.pressed.connect(func() -> void: on_pick.call(chosen))
		row.add_child(control)


## A drawn card, added to [param parent], with its padding on an inner margin
## rather than in a stylebox so the sheet reaches the panel's edge. Returns the
## box to fill: callers want the contents, never the card.
## [param fill] makes the card as tall as the space it is given rather than as
## tall as its contents, which is what a card holding a scrolling form wants: the
## scroll then takes up the slack and the card can never overrun the window.
## Cards that are shorter than the window should leave it off, or two side by side
## both grow to the taller one and the shorter grows a pool of blank paper under
## its last button.
static func card(parent: Control, padding := 26, fill := false) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.size_flags_vertical = \
		Control.SIZE_EXPAND_FILL if fill else Control.SIZE_SHRINK_BEGIN
	parent.add_child(panel)
	AuroraSurface.add_to(panel, AuroraSurface.Style.CARD)
	var margin := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, padding)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)
	return box


## Headings are cyan on the dark pane, over a thin ink outline. The outline is
## legibility and not weight: Bungee has plenty of its own, but a pane has a
## nebula drifting inside it and bright type on a moving field needs an edge.
static func heading(text: String, size := 26) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", PALETTE.accent)
	label.add_theme_color_override("font_outline_color", PALETTE.ink)
	label.add_theme_constant_override("outline_size", 4)
	return label


static func caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", PALETTE.text_secondary)
	label.add_theme_constant_override("outline_size", 2)
	return label


## A toggle drawn the way the rest of the menu is: a box that gets scribbled in
## when it is on, rather than the stock pill, which has its own colours baked in.
static func toggle_row(label_text: String, value: bool, callback: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var toggle := button("ON" if value else "OFF")
	toggle.toggle_mode = true
	toggle.button_pressed = value
	toggle.custom_minimum_size.x = 140
	toggle.toggled.connect(func(pressed: bool) -> void:
		toggle.text = "ON" if pressed else "OFF"
		callback.call(pressed)
	)
	row.add_child(toggle)
	return row


static func option_row(
	label_text: String, options: Array, selected: int, callback: Callable
) -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 5)
	group.add_child(caption(label_text))
	var option := OptionButton.new()
	for item: Variant in options:
		option.add_item(String(item))
	option.select(clampi(selected, 0, maxi(options.size() - 1, 0)))
	option.item_selected.connect(callback)
	AuroraSurface.add_to(option, AuroraSurface.Style.BUTTON)
	group.add_child(option)
	return group


static func slider_row(
	label_text: String,
	minimum: float,
	maximum: float,
	step: float,
	value: float,
	callback: Callable,
	suffix := ""
) -> VBoxContainer:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 4)
	var header := HBoxContainer.new()
	group.add_child(header)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)
	var value_label := Label.new()
	header.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	group.add_child(slider)
	var update_label := func(new_value: float) -> void:
		value_label.text = (
			"%d%s" % [roundi(new_value * 100.0), suffix]
			if suffix == "%"
			else "%.2f%s" % [new_value, suffix]
		)
	update_label.call(value)
	slider.value_changed.connect(update_label)
	slider.value_changed.connect(callback)
	return group


## The label sits above its field rather than beside it: a two-column form runs
## out of width before it runs out of fields.
static func field(parent: Control, label_text: String, value: String, placeholder: String) -> LineEdit:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 5)
	parent.add_child(group)
	group.add_child(caption(label_text))
	var input := LineEdit.new()
	input.text = value
	input.placeholder_text = placeholder
	input.max_length = 64
	AuroraSurface.add_to(input, AuroraSurface.Style.INPUT)
	group.add_child(input)
	return input


static func number_field(
	parent: Control, label_text: String, minimum: float, maximum: float, value: float
) -> SpinBox:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 5)
	parent.add_child(group)
	group.add_child(caption(label_text))
	var input := SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.value = value
	input.allow_greater = false
	input.allow_lesser = false
	AuroraSurface.add_to(input, AuroraSurface.Style.INPUT)
	group.add_child(input)
	return input


## A scrolling region inside a card. Forms are taller than the window once the
## type is set at a readable size, so the fields scroll and whatever button the
## caller adds after this stays pinned below them, where it can still be clicked.
## It takes whatever height is left over in a filling card, so the minimum here
## only has to be enough to be worth scrolling.
static func scroll_area(parent: Control, height := 140.0) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, height)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	# The scrollbar is drawn over the content rather than beside it, so the fields
	# are held clear of the right-hand edge to leave it somewhere to sit.
	var inset := MarginContainer.new()
	inset.add_theme_constant_override("margin_right", 20)
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inset)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 14)
	inset.add_child(box)
	return box


## How wide a card should be: a share of the window, capped so the forms do not
## stretch into unreadably long rows on an ultrawide. Panels ask for this instead
## of carrying a fixed pixel width, because a width that fills a 1280 window
## leaves two thirds of a 2560 one empty.
static func panel_width(inside: Control, share: float, cap: float) -> float:
	var window := inside.get_viewport_rect().size.x
	return minf(window * share, cap)


static func binding_text(action: StringName) -> String:
	var events := InputMap.action_get_events(action)
	return events[0].as_text() if not events.is_empty() else "UNBOUND"
