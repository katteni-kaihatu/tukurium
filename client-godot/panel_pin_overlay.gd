extends PanelContainer
## Local 2D face for a pinned WorldPanel (Resources / Script Editor / non-HTML Inspector).
## Chrome follows the tukurium design artifact: paper glass window + pushpin header.
const PIN_BUTTON = preload("res://pin_icon_button.gd")
const PAPER := Color("fffdf9e6")
const EDGE := Color(1, 1, 1, 0.7)
const INK := Color("3a3942")
const RULE := Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.08)
var manager
var panel_id := ""
var host: SubViewportContainer
var title: Label
var header: Control
var drag_grab := Vector2.ZERO
var dragging := false
var place_due := 0

func setup(controller, id: String, viewport: SubViewport, heading: String) -> void:
	manager = controller
	panel_id = id
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = PAPER
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.shadow_color = Color(15 / 255.0, 25 / 255.0, 40 / 255.0, 0.22)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 4)
	style.set_content_margin_all(0)
	add_theme_stylebox_override("panel", style)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	header = HBoxContainer.new()
	header.custom_minimum_size.y = 46
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)
	var rule := ColorRect.new()
	rule.color = RULE
	rule.custom_minimum_size = Vector2(0, 1)
	root.add_child(rule)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 14)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_top", 0)
	pad.add_theme_constant_override("margin_bottom", 0)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	header.add_child(pad)
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 8)
	head_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_child(head_row)
	title = Label.new()
	title.text = heading
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	head_row.add_child(title)
	var pin = PIN_BUTTON.new()
	pin.set_pinned_look(true)
	pin.pressed.connect(func(): manager.toggle_pin(panel_id))
	head_row.add_child(pin)
	var close := Button.new()
	close.focus_mode = Control.FOCUS_NONE
	close.flat = true
	close.text = "×"
	close.tooltip_text = "閉じる"
	close.custom_minimum_size = Vector2(30, 30)
	close.add_theme_font_size_override("font_size", 16)
	close.add_theme_color_override("font_color", INK)
	var close_style := StyleBoxFlat.new()
	close_style.bg_color = Color(0, 0, 0, 0)
	close_style.set_corner_radius_all(8)
	close.add_theme_stylebox_override("normal", close_style)
	var close_hover := close_style.duplicate()
	close_hover.bg_color = Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.09)
	close.add_theme_stylebox_override("hover", close_hover)
	close.add_theme_stylebox_override("pressed", close_hover)
	close.pressed.connect(func(): manager.close_panel(panel_id))
	head_row.add_child(close)
	header.gui_input.connect(_on_header_input)
	host = SubViewportContainer.new()
	host.stretch = true
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(host)
	if viewport.get_parent() != null:
		viewport.get_parent().remove_child(viewport)
	host.add_child(viewport)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			drag_grab = event.global_position - global_position
			manager.app.release_cursor()
		else:
			dragging = false
			_commit_place()
		accept_event()
	elif event is InputEventMouseMotion and dragging:
		var viewport_size: Vector2 = manager.app.get_viewport().get_visible_rect().size
		var next: Vector2 = event.global_position - drag_grab
		next.x = clampf(next.x, 8.0, maxf(8.0, viewport_size.x - size.x - 8.0))
		next.y = clampf(next.y, 48.0, maxf(48.0, viewport_size.y - size.y - 8.0))
		global_position = next
		place_due = Time.get_ticks_msec() + 80
		accept_event()

func _process(_delta: float) -> void:
	if place_due > 0 and Time.get_ticks_msec() >= place_due and not dragging:
		place_due = 0
		_commit_place()

func _commit_place() -> void:
	var viewport_size: Vector2 = manager.app.get_viewport().get_visible_rect().size
	if viewport_size.x < 8.0 or viewport_size.y < 8.0: return
	manager.pin_panel_rect(panel_id, [
		global_position.x / viewport_size.x,
		global_position.y / viewport_size.y,
		size.x / viewport_size.x,
		size.y / viewport_size.y,
	], viewport_size.x / viewport_size.y)

func apply_screen(screen: Dictionary) -> void:
	if dragging or place_due > 0: return
	var viewport_size: Vector2 = manager.app.get_viewport().get_visible_rect().size
	var rect: Array = screen.get("rect", [])
	if rect.size() < 4: return
	position = Vector2(float(rect[0]) * viewport_size.x, float(rect[1]) * viewport_size.y)
	size = Vector2(float(rect[2]) * viewport_size.x, float(rect[3]) * viewport_size.y)

func take_viewport() -> SubViewport:
	if host.get_child_count() == 0: return null
	var viewport: SubViewport = host.get_child(0)
	host.remove_child(viewport)
	return viewport
