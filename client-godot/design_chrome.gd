extends RefCounted
## Paper / plum chrome matching ツクリウム デザイン.html (workspace menus & docks).
## Preload as `const DesignChrome = preload("res://design_chrome.gd")` — do not rely on class_name.

const PAPER := Color("fffdf9")
const PAPER_GLASS := Color("fffdf9f0")
const GROUND := Color("f7f3eb")
const INK := Color("26262e")
const MUTED := Color("5e5c64")
const LINE := Color("dcd5c8")
const PLUM := Color("603d56")
const PLUM_HOVER := Color("734a67")
const PALE := Color("f3eaf0")
const SEL := Color("fff1bf")
const EDGE := Color(1, 1, 1, 0.72)
const SHADOW := Color(15 / 255.0, 25 / 255.0, 40 / 255.0, 0.18)
const OK := Color("1f6b47")
const WARN := Color("9a6b2f")
const DANGER := Color("9a3a2e")

static func panel(bg: Color = PAPER_GLASS, radius: float = 18.0, pad: float = 12.0, shadow: bool = true) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = EDGE
	s.set_border_width_all(1)
	s.set_corner_radius_all(int(radius))
	s.set_content_margin_all(pad)
	if shadow:
		s.shadow_color = SHADOW
		s.shadow_size = 10
		s.shadow_offset = Vector2(0, 3)
	return s

static func box(bg: Color, radius: float = 8.0, pad: float = 8.0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.set_content_margin_all(pad)
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1)
	return s

static func style_ghost(button: Button) -> void:
	var n := box(Color(0, 0, 0, 0), 9, 8)
	var hover := box(PALE, 9, 8)
	_apply_button(button, n, hover, hover)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", PLUM)
	button.add_theme_color_override("font_pressed_color", PLUM)
	button.add_theme_color_override("font_disabled_color", MUTED)

static func style_quiet(button: Button, selected: bool = false) -> void:
	var n := box(SEL if selected else PAPER, 9, 8, LINE if not selected else Color("e9c24a"))
	var hover := box(SEL, 9, 8, Color("e9c24a"))
	_apply_button(button, n, hover, hover)
	button.add_theme_color_override("font_color", INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)

static func style_primary(button: Button) -> void:
	var n := box(PLUM, 9, 10)
	var h := box(PLUM_HOVER, 9, 10)
	_apply_button(button, n, h, h)
	button.add_theme_color_override("font_color", Color.WHITE)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)

static func style_line_edit(edit: LineEdit) -> void:
	var n := box(Color.WHITE, 9, 8, LINE)
	n.content_margin_left = 10
	n.content_margin_right = 10
	n.content_margin_top = 6
	n.content_margin_bottom = 6
	var focus := n.duplicate()
	focus.border_color = Color("d9c5d2")
	edit.add_theme_stylebox_override("normal", n)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_stylebox_override("read_only", n)
	edit.add_theme_color_override("font_color", INK)
	edit.add_theme_color_override("font_placeholder_color", MUTED)
	edit.add_theme_color_override("caret_color", PLUM)

static func _apply_button(button: Button, normal: StyleBox, hover: StyleBox, pressed: StyleBox) -> void:
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_stylebox_override("disabled", normal)
