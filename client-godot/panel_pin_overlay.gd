extends PanelContainer
## Local 2D host for a pinned WorldPanel (Resources / non-HTML Inspector / Script fallback).
## No second chrome here — the content view paints the single glass face (like HTML .window).
## Drag starts from the content header via begin_drag().
var manager
var panel_id := ""
var host: SubViewportContainer
var drag_grab := Vector2.ZERO
var dragging := false
var place_due := 0

func setup(controller, id: String, viewport: SubViewport, _heading: String = "") -> void:
	manager = controller
	panel_id = id
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = false
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	host = SubViewportContainer.new()
	host.stretch = true
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(host)
	if viewport.get_parent() != null:
		viewport.get_parent().remove_child(viewport)
	host.add_child(viewport)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func begin_drag() -> void:
	dragging = true
	drag_grab = get_global_mouse_position() - global_position
	if manager and manager.app:
		manager.app.release_cursor()

func _process(_delta: float) -> void:
	if dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			dragging = false
			_commit_place()
			return
		var viewport_size: Vector2 = manager.app.get_viewport().get_visible_rect().size
		var next: Vector2 = get_global_mouse_position() - drag_grab
		next.x = clampf(next.x, 8.0, maxf(8.0, viewport_size.x - size.x - 8.0))
		next.y = clampf(next.y, 48.0, maxf(48.0, viewport_size.y - size.y - 8.0))
		global_position = next
		place_due = Time.get_ticks_msec() + 80
		return
	if place_due > 0 and Time.get_ticks_msec() >= place_due:
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
