extends Button
## Pushpin control matching the tukurium design artifact (15×15 glyph in a 30×30 hit).
const MUTED := Color("6a6875")
const PLUM := Color("603d56")
const PALE := Color("f3eaf0")
var pinned_look := false

func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(30, 30)
	flat = true
	text = ""
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "ピン留め: オフ（3D空間に置く）"
	_apply_look()
	toggled.connect(func(_on): queue_redraw())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)

func set_pinned_look(on: bool) -> void:
	pinned_look = on
	tooltip_text = "ピン留め: オン（画面に固定）" if on else "ピン留め: オフ（3D空間に置く）"
	_apply_look()
	queue_redraw()

func _apply_look() -> void:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(8)
	style.set_content_margin_all(0)
	style.bg_color = PALE if pinned_look else Color(0, 0, 0, 0)
	add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = PALE if pinned_look else Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.09)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", hover)
	add_theme_stylebox_override("focus", style)
	modulate = PLUM if pinned_look else MUTED

func _draw() -> void:
	# Paths from the design SVG viewBox 0 0 24 24, centered in the 30×30 button.
	var scale := 15.0 / 24.0
	var origin := Vector2((size.x - 15.0) * 0.5, (size.y - 15.0) * 0.5)
	var ink: Color = PLUM if pinned_look else MUTED
	var head := PackedVector2Array([
		_pt(9, 3.5, origin, scale),
		_pt(15, 3.5, origin, scale),
		_pt(14, 10, origin, scale),
		_pt(17.5, 13.5, origin, scale),
		_pt(6.5, 13.5, origin, scale),
		_pt(10, 10, origin, scale),
	])
	if pinned_look:
		draw_colored_polygon(head, ink)
	draw_polyline(head + PackedVector2Array([head[0]]), ink, 1.6, true)
	draw_line(_pt(12, 13.5, origin, scale), _pt(12, 21, origin, scale), ink, 1.6, true)

func _pt(x: float, y: float, origin: Vector2, scale: float) -> Vector2:
	return origin + Vector2(x, y) * scale
