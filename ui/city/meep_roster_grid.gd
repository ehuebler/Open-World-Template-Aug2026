class_name MeepRosterGrid
extends Control

## Childless, custom-drawn City-menu roster.
##
## Report polling can touch hundreds of residents. Turning each resident into a
## small Control tree would make opening the City menu needlessly expensive, so
## this canvas stores only compact presentation dictionaries. Per-card signatures
## suppress unchanged redraws, and scrolling rebuilds draw commands for only the
## rows intersecting the viewport.

const COLUMNS := 3
const TILE_HEIGHT := 142.0
const COLUMN_GAP := 8.0
const ROW_GAP := 8.0
const TILE_PADDING := 8.0
const MAX_DETAIL_LINES := 3
const EMPTY_HEIGHT := 142.0

const ALIVE_TEXT := Color(1.0, 0.74, 0.76)
const DEAD_TEXT := Color(0.72, 0.58, 0.62)
const MUTED_TEXT := Color(0.78, 0.60, 0.64)
const DEAD_BORDER := Color(0.58, 0.31, 0.35, 0.72)

var _cards: Array[Dictionary] = []
var _row_signatures := PackedStringArray()
var _scroll: ScrollContainer
var _render_revision := 0


func _init() -> void:
	name = "MeepRosterGrid"
	custom_minimum_size = Vector2(0.0, EMPTY_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Gives the canvas its clipping viewport. The scrollbar signal is what makes
## culling safe: retained draw commands are rebuilt whenever another row enters.
func bind_scroll_container(scroll: ScrollContainer) -> void:
	if _scroll == scroll:
		return
	_scroll = scroll
	if _scroll == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	if not bar.value_changed.is_connected(_on_scroll_changed):
		bar.value_changed.connect(_on_scroll_changed)
	if not _scroll.resized.is_connected(_on_scroll_resized):
		_scroll.resized.connect(_on_scroll_resized)
	_request_redraw()


## Replaces the visible segment. Unchanged presentation signatures deliberately
## do nothing, even though CityMenu polls its report four times per second.
func set_rows(rows: Array) -> void:
	var next_cards: Array[Dictionary] = []
	var next_signatures := PackedStringArray()
	for row_variant: Variant in rows:
		if not row_variant is Dictionary:
			continue
		var card := _normalise_card(row_variant as Dictionary)
		next_cards.append(card)
		next_signatures.append(_card_signature(card))
	if next_signatures == _row_signatures:
		return
	_cards = next_cards
	_row_signatures = next_signatures
	var visual_rows := visual_row_count()
	var wanted_height := EMPTY_HEIGHT if visual_rows == 0 else (
		float(visual_rows) * TILE_HEIGHT
		+ float(maxi(visual_rows - 1, 0)) * ROW_GAP
	)
	custom_minimum_size = Vector2(0.0, wanted_height)
	_request_redraw()


func row_count() -> int:
	return _cards.size()


func visual_row_count() -> int:
	return ceili(float(_cards.size()) / float(COLUMNS))


## Useful to deterministic UI checks: the value changes only when this canvas
## actually requests a fresh set of draw commands.
func render_revision() -> int:
	return _render_revision


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED, NOTIFICATION_THEME_CHANGED:
			_request_redraw()
		NOTIFICATION_VISIBILITY_CHANGED:
			if is_visible_in_tree():
				_request_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	if _cards.is_empty():
		_draw_empty(font)
		return
	var shown_rows := _visible_grid_rows()
	var tile_width := (
		size.x - COLUMN_GAP * float(COLUMNS - 1)
	) / float(COLUMNS)
	for grid_row in range(shown_rows.x, shown_rows.y):
		for column in COLUMNS:
			var card_index := grid_row * COLUMNS + column
			if card_index >= _cards.size():
				break
			var tile := Rect2(
				Vector2(
					float(column) * (tile_width + COLUMN_GAP),
					float(grid_row) * (TILE_HEIGHT + ROW_GAP)
				),
				Vector2(tile_width, TILE_HEIGHT)
			)
			_draw_card(font, tile, _cards[card_index])


func _draw_card(font: Font, tile: Rect2, card: Dictionary) -> void:
	var dead := bool(card.get("dead", false))
	var text_color := DEAD_TEXT if dead else ALIVE_TEXT
	var border := DEAD_BORDER if dead else Color(RedHudTheme.RED_BRIGHT, 0.82)
	draw_rect(tile, Color(RedHudTheme.BLACK, 0.84), true)
	draw_rect(tile.grow(-0.75), border, false, 1.5, true)

	var icon_center := Vector2(tile.get_center().x, tile.position.y + 27.0)
	_draw_meep_icon(icon_center, dead)
	var text_rect := Rect2(
		Vector2(tile.position.x + TILE_PADDING, tile.position.y),
		Vector2(tile.size.x - TILE_PADDING * 2.0, tile.size.y)
	)
	_draw_fitted_string(
		font, text_rect, tile.position.y + 61.0,
		String(card.get("name", "Meep")), 14, text_color,
		HORIZONTAL_ALIGNMENT_CENTER
	)
	_draw_fitted_string(
		font, text_rect, tile.position.y + 79.0,
		"TYPE  %s" % String(card.get("type", "Meep")), 9, MUTED_TEXT
	)
	_draw_fitted_string(
		font, text_rect, tile.position.y + 92.0,
		"HEALTH  %s" % String(card.get("health", "0 / 0")), 9,
		RedHudTheme.GREEN if not dead else DEAD_TEXT
	)
	var details := PackedStringArray(
		card.get("details", PackedStringArray())
	)
	for line_index in mini(details.size(), MAX_DETAIL_LINES):
		_draw_fitted_string(
			font, text_rect,
			tile.position.y + 107.0 + float(line_index) * 12.0,
			details[line_index], 9, text_color
		)


## A deliberately simple, isolated vector placeholder. It is recognizable at
## roster scale without loading a model, texture, or one icon node per resident.
func _draw_meep_icon(center: Vector2, dead: bool) -> void:
	var body := Color(0.46, 0.30, 0.33) if dead else RedHudTheme.RED_PLATE
	var rim := DEAD_BORDER if dead else RedHudTheme.RED_BRIGHT
	draw_circle(center + Vector2(0.0, 5.0), 10.0, body)
	draw_circle(center + Vector2(0.0, -5.0), 7.5, body)
	draw_arc(center + Vector2(0.0, 5.0), 10.0, 0.0, TAU, 20, rim, 1.2, true)
	draw_arc(center + Vector2(0.0, -5.0), 7.5, 0.0, TAU, 18, rim, 1.2, true)
	draw_line(
		center + Vector2(-4.0, 14.0),
		center + Vector2(-6.0, 18.0), rim, 1.4, true
	)
	draw_line(
		center + Vector2(4.0, 14.0),
		center + Vector2(6.0, 18.0), rim, 1.4, true
	)
	if dead:
		for side in [-1.0, 1.0]:
			var eye := center + Vector2(side * 3.0, -6.0)
			draw_line(eye - Vector2(1.2, 1.2), eye + Vector2(1.2, 1.2),
				RedHudTheme.INK, 1.1, true)
			draw_line(eye + Vector2(-1.2, 1.2), eye + Vector2(1.2, -1.2),
				RedHudTheme.INK, 1.1, true)
	else:
		draw_circle(center + Vector2(-3.0, -6.0), 1.1, RedHudTheme.INK)
		draw_circle(center + Vector2(3.0, -6.0), 1.1, RedHudTheme.INK)


func _draw_empty(font: Font) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(RedHudTheme.BLACK, 0.42), true)
	if font == null:
		return
	var baseline := minf(size.y, EMPTY_HEIGHT) * 0.5 + 5.0
	draw_string(
		font, Vector2(0.0, baseline), "NO MEEPS IN THIS SEGMENT",
		HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, MUTED_TEXT
	)


func _draw_fitted_string(
		font: Font,
		rect: Rect2,
		baseline: float,
		text: String,
		font_size: int,
		color: Color,
		alignment := HORIZONTAL_ALIGNMENT_LEFT
	) -> void:
	if font == null or rect.size.x <= 0.0:
		return
	draw_string(
		font,
		Vector2(rect.position.x, baseline),
		_fit_text(font, text, rect.size.x, font_size),
		alignment,
		rect.size.x,
		font_size,
		color
	)


func _fit_text(font: Font, text: String, width: float, font_size: int) -> String:
	if font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size
		).x <= width:
		return text
	var shortened := text
	while shortened.length() > 1:
		shortened = shortened.left(shortened.length() - 1)
		var candidate := "%s…" % shortened
		if font.get_string_size(
				candidate, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size
				).x <= width:
			return candidate
	return "…"


func _normalise_card(row: Dictionary) -> Dictionary:
	var dead := String(row.get("status", "alive")).to_lower() == "dead"
	var meep_type := String(row.get(
		"type", row.get("meep_type", "Meep")
	)).strip_edges()
	if meep_type.is_empty():
		meep_type = "Meep"
	var health := roundi(maxf(float(row.get("health", 0.0)), 0.0))
	var maximum_health := roundi(maxf(
		float(row.get("maximum_health", 0.0)), 0.0
	))
	var details := PackedStringArray()
	if dead:
		details.append("DEATH AGE  %s" % _duration(
			float(row.get("age_seconds", 0.0))
		))
		details.append("DIED  %s" % _ago(
			float(row.get("death_seconds_ago", 0.0))
		))
		var cause := String(row.get("death_cause", "Killed in combat")).strip_edges()
		details.append("CAUSE  %s" % (
			cause if not cause.is_empty() else "Killed in combat"
		))
	else:
		details.append("AGE  %s" % _duration(
			float(row.get("age_seconds", 0.0))
		))
		_append_optional_stats(details, row)
	return {
		"index": int(row.get("index", -1)),
		"name": String(row.get("name", "Meep")),
		"type": meep_type,
		"health": "%d / %d" % [health, maximum_health],
		"dead": dead,
		"details": details,
	}


## Future reports can append compact card stats without changing the grid's node
## shape. Either `stat_lines: Array[String]` or `stats: Dictionary` is accepted.
func _append_optional_stats(lines: PackedStringArray, row: Dictionary) -> void:
	var stats: Variant = row.get("stat_lines", row.get("stats", []))
	if stats is Dictionary:
		var stat_map := stats as Dictionary
		var keys := stat_map.keys()
		keys.sort()
		for key_variant: Variant in keys:
			if lines.size() >= MAX_DETAIL_LINES:
				return
			var key := String(key_variant).replace("_", " ").to_upper()
			lines.append("%s  %s" % [key, str(stat_map[key_variant])])
		return
	if stats is Array:
		for line_variant: Variant in stats:
			if lines.size() >= MAX_DETAIL_LINES:
				return
			var line := String(line_variant).strip_edges()
			if not line.is_empty():
				lines.append(line)
		return
	if typeof(stats) == TYPE_PACKED_STRING_ARRAY:
		for line: String in stats:
			if lines.size() >= MAX_DETAIL_LINES:
				return
			if not line.strip_edges().is_empty():
				lines.append(line.strip_edges())


func _card_signature(card: Dictionary) -> String:
	var parts := PackedStringArray([
		str(card.get("index", -1)),
		String(card.get("name", "")),
		String(card.get("type", "")),
		String(card.get("health", "")),
		str(bool(card.get("dead", false))),
	])
	parts.append_array(PackedStringArray(
		card.get("details", PackedStringArray())
	))
	return "\u001f".join(parts)


func _visible_grid_rows() -> Vector2i:
	var total := visual_row_count()
	if total <= 0:
		return Vector2i.ZERO
	if _scroll == null or not is_instance_valid(_scroll):
		return Vector2i(0, total)
	var viewport := _scroll.get_global_rect()
	var own := get_global_rect()
	var top := clampf(viewport.position.y - own.position.y, 0.0, size.y)
	var bottom := clampf(viewport.end.y - own.position.y, 0.0, size.y)
	if bottom <= top:
		return Vector2i(0, total)
	var stride := TILE_HEIGHT + ROW_GAP
	# One overscan row keeps fast wheel scrolling from exposing an empty seam.
	var first := maxi(floori(top / stride) - 1, 0)
	var past_last := mini(ceili(bottom / stride) + 1, total)
	return Vector2i(first, past_last)


func _duration(seconds: float) -> String:
	var total := maxi(floori(maxf(seconds, 0.0)), 0)
	if total < 60:
		return "%ds" % total
	if total < 3600:
		return "%dm %ds" % [total / 60, total % 60]
	if total < 86400:
		return "%dh %dm" % [total / 3600, (total % 3600) / 60]
	return "%dd %dh" % [total / 86400, (total % 86400) / 3600]


func _ago(seconds: float) -> String:
	return "just now" if seconds < 1.0 else "%s ago" % _duration(seconds)


func _on_scroll_changed(_value: float) -> void:
	_request_redraw()


func _on_scroll_resized() -> void:
	_request_redraw()


func _request_redraw() -> void:
	_render_revision += 1
	queue_redraw()
