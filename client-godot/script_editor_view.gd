extends PanelContainer
## Shared Script Editor WorldPanel hosting the collaborative script draft view.
const SHARED_SCRIPT_VIEW = preload("res://shared_script_view.gd")
const PIN_BUTTON = preload("res://pin_icon_button.gd")
const PAPER := Color("fffdf9")
const GROUND := Color("eae5db")
const INK := Color("26262e")
const MUTED := Color("6b6872")
const LINE := Color("dcd5c8")
var manager
var panel_id := ""
var app
var target_id := ""
var script_mount: MarginContainer
var script_view
var status: Label
var close_when_ready := false
## world_hud / world_panels.views() expect inspector-like edit bookkeeping.
var edits: Dictionary = {}

func setup(controller, id: String) -> void:
	manager = controller
	app = manager.app
	panel_id = id
	clip_contents = true
	var style := StyleBoxFlat.new()
	# Single glass face; pin overlay stays chromeless so corners are not doubled.
	style.bg_color = PAPER
	style.border_color = Color(1, 1, 1, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.shadow_color = Color(15 / 255.0, 25 / 255.0, 40 / 255.0, 0.18)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 4)
	style.set_content_margin_all(14)
	add_theme_stylebox_override("panel", style)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	add_child(root)
	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Script Editor"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(title)
	var pin = PIN_BUTTON.new()
	pin.set_pinned_look(manager.pinned_to_me(panel_id))
	pin.pressed.connect(func(): manager.toggle_pin(panel_id))
	header.add_child(pin)
	var close := Button.new()
	close.text = "×"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(request_close)
	header.add_child(close)
	header.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and manager.pinned_to_me(panel_id):
			manager.begin_pin_drag(panel_id)
			header.accept_event())
	status = Label.new()
	status.add_theme_color_override("font_color", MUTED)
	status.add_theme_font_size_override("font_size", 13)
	root.add_child(status)
	script_mount = MarginContainer.new()
	script_mount.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(script_mount)
	script_view = SHARED_SCRIPT_VIEW.new()
	script_view.setup(manager, panel_id, script_mount)

func refresh(object: Dictionary) -> void:
	var view = object.get("script_editor", {})
	var next := ""
	var script_id = null
	if view is Dictionary:
		if view.get("target") != null:
			next = str(view.target.instance_id)
		script_id = view.get("script_id")
	if next.is_empty():
		status.text = "Resources から Script を選ぶか、Slot を選んでください。"
		script_view.active = false
		return
	target_id = next
	var name_text := str(manager.field_data(target_id, "name").get("value", target_id))
	status.text = "対象: %s" % name_text
	# html-host owns collaborative drafts for this panel; keep the SubViewport dormant.
	var html_active: bool = app.html_ui != null and app.html_ui.active
	if html_active:
		script_view.active = false
		if close_when_ready and app.html_ui.script_sessions.has(panel_id) and not app.html_ui.script_sessions[panel_id].busy():
			close_when_ready = false
			manager.close_panel(panel_id)
		return
	script_view.active = true
	script_view.refresh(target_id, script_id)
	if close_when_ready and not script_view.busy():
		close_when_ready = false
		manager.close_panel(panel_id)

func request_close() -> void:
	var html_active: bool = app.html_ui != null and app.html_ui.active
	if html_active and app.html_ui.script_sessions.has(panel_id) and app.html_ui.script_sessions[panel_id].busy():
		close_when_ready = true
		status.text = "下書きの同期を待っています…"
		return
	if not html_active and script_view.busy():
		close_when_ready = true
		status.text = "下書きの同期を待っています…"
		return
	if html_active: app.html_ui.drop_script_session(panel_id)
	manager.close_panel(panel_id)

func tick() -> void:
	if script_view != null:
		script_view.tick()
	if close_when_ready and not has_active_edits():
		close_when_ready = false
		manager.close_panel(panel_id)

func finish_all() -> void:
	var html_active: bool = app.html_ui != null and app.html_ui.active
	if html_active:
		if app.html_ui.script_sessions.has(panel_id) and not app.html_ui.script_sessions[panel_id].busy():
			app.html_ui.drop_script_session(panel_id)
		return
	if script_view != null and not script_view.busy():
		script_view.leave()

func has_active_edits() -> bool:
	var html_active: bool = app.html_ui != null and app.html_ui.active
	if html_active and app.html_ui.script_sessions.has(panel_id):
		return app.html_ui.script_sessions[panel_id].busy()
	return script_view != null and script_view.busy()

func refresh_sessions() -> void:
	pass

func disconnected() -> void:
	if script_view != null:
		script_view.disconnected()
	edits.clear()
	close_when_ready = false
