extends PanelContainer
## Shared Script Editor WorldPanel hosting the collaborative script draft view.
const SHARED_SCRIPT_VIEW = preload("res://shared_script_view.gd")
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

func setup(controller, id: String) -> void:
	manager = controller
	app = manager.app
	panel_id = id
	var style := StyleBoxFlat.new()
	style.bg_color = GROUND
	style.border_color = LINE
	style.set_border_width_all(1)
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
	header.add_child(title)
	var close := Button.new()
	close.text = "×"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(request_close)
	header.add_child(close)
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
	script_view.active = true
	script_view.refresh(target_id, script_id)
	if close_when_ready and not script_view.busy():
		close_when_ready = false
		manager.close_panel(panel_id)

func request_close() -> void:
	if script_view.busy():
		close_when_ready = true
		status.text = "下書きの同期を待っています…"
		return
	manager.close_panel(panel_id)

func finish_all() -> void:
	if not script_view.busy(): script_view.leave()

func has_active_edits() -> bool:
	return script_view.busy()

func refresh_sessions() -> void:
	pass

func disconnected() -> void:
	script_view.disconnected()
