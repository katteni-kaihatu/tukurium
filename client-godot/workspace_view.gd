extends PanelContainer
## Shared WorkspaceView content on a WorldPanel. Edit/Play stay local to this client.
const DesignChrome = preload("res://design_chrome.gd")
const PIN_BUTTON = preload("res://pin_icon_button.gd")

var manager
var panel_id := ""
var app
var owner_label: Label
var slug_label: Label
var project_button: Button
var world_button: Button
var edit_button: Button
var play_button: Button
var inspector_button: Button
var resources_button: Button
var status_dot: Label
var status_label: Label
var pin_button
var next_refresh := 0
var last_edit_mode := false

func setup(controller, id: String) -> void:
	manager = controller
	app = manager.app
	panel_id = id
	clip_contents = true
	var style: StyleBoxFlat = DesignChrome.panel(DesignChrome.PAPER, 18, 0, true)
	style.set_content_margin_all(0)
	add_theme_stylebox_override("panel", style)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 8)
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 12)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	pad.add_child(column)
	add_child(pad)
	column.add_child(_header())
	column.add_child(_rule())
	column.add_child(_build_top_row())
	column.add_child(_build_bottom_row())
	last_edit_mode = app.edit_mode
	refresh()

func refresh(_object: Dictionary = {}) -> void:
	if app == null: return
	if pin_button != null:
		pin_button.set_pinned_look(manager.pinned_to_me(panel_id))
	var workspace = app.get("service_panel")
	var project: Dictionary = {}
	var session: Dictionary = {}
	var user: Dictionary = {}
	if workspace != null:
		if workspace.current_project is Dictionary:
			project = workspace.current_project
		if workspace.current_session is Dictionary:
			session = workspace.current_session
		if workspace.current_user is Dictionary:
			user = workspace.current_user
	var owner_name: String = str(user.get("name", ""))
	var slug: String = str(project.get("slug", ""))
	if owner_name.is_empty():
		owner_name = "—"
	if slug.is_empty():
		slug = "workspace"
		slug_label.add_theme_color_override("font_color", DesignChrome.MUTED)
	else:
		slug_label.add_theme_color_override("font_color", DesignChrome.PLUM)
	owner_label.text = owner_name
	slug_label.text = slug
	var session_name: String = str(session.get("name", ""))
	if session_name.is_empty():
		session_name = str(app.session)
	world_button.text = "🌐  Output · World · %s" % session_name
	var services_ok: bool = workspace != null and workspace.enabled
	project_button.disabled = not services_ok
	world_button.disabled = not services_ok
	if last_edit_mode != app.edit_mode:
		last_edit_mode = app.edit_mode
		DesignChrome.style_quiet(edit_button, app.edit_mode)
		DesignChrome.style_quiet(play_button, not app.edit_mode)
	edit_button.add_theme_color_override("font_color", DesignChrome.PLUM if app.edit_mode else DesignChrome.MUTED)
	play_button.add_theme_color_override("font_color", DesignChrome.PLUM if not app.edit_mode else DesignChrome.MUTED)
	inspector_button.disabled = not app.edit_mode
	resources_button.disabled = not app.edit_mode
	var inspectors: int = 0
	var resources: int = 0
	for id in app.world_panels.panels.keys():
		var kind: String = app.world_panels.panel_kind(str(id))
		if kind == "inspector":
			inspectors += 1
		elif kind == "resources":
			resources += 1
	inspectors += app.world_panels.windows.size()
	inspector_button.text = "▣ %d" % inspectors
	resources_button.text = "▤ %d" % resources
	var people := 1
	if app.social_panels != null and app.social_panels.participants is Array:
		people = maxi(1, app.social_panels.participants.size())
	status_label.text = "%s · %d" % [session_name, people]
	var ready: bool = app.connected and app.editable
	status_dot.add_theme_color_override("font_color", DesignChrome.OK if ready else DesignChrome.WARN)

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() < next_refresh: return
	next_refresh = Time.get_ticks_msec() + 250
	refresh()

func _header() -> Control:
	var header := HBoxContainer.new()
	header.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_theme_constant_override("separation", 8)
	var title := _label("Workspace", 20, DesignChrome.INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(title)
	pin_button = PIN_BUTTON.new()
	pin_button.set_pinned_look(manager.pinned_to_me(panel_id))
	pin_button.pressed.connect(func(): manager.toggle_pin(panel_id))
	header.add_child(pin_button)
	var close := _quiet_button("×")
	close.custom_minimum_size = Vector2(36, 30)
	close.pressed.connect(func(): manager.close_panel(panel_id))
	header.add_child(close)
	header.gui_input.connect(_on_header_input)
	return header

func _on_header_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		return
	if not manager.pinned_to_me(panel_id):
		return
	manager.begin_pin_drag(panel_id)
	accept_event()

func _build_top_row() -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	var left := HBoxContainer.new()
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	row.add_child(left)
	var cube := _label("▣", 15, DesignChrome.PLUM)
	left.add_child(cube)
	owner_label = _label("", 14, DesignChrome.MUTED)
	owner_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	left.add_child(owner_label)
	left.add_child(_label("/", 14, DesignChrome.MUTED))
	slug_label = _label("", 14, DesignChrome.PLUM)
	slug_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	left.add_child(slug_label)
	var branch := _quiet_button("⎇ main", true)
	branch.disabled = true
	branch.tooltip_text = "ブランチは未実装"
	left.add_child(branch)
	var right := HBoxContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.add_theme_constant_override("separation", 6)
	row.add_child(right)
	project_button = _quiet_button("<> Project")
	project_button.pressed.connect(_open_projects)
	right.add_child(project_button)
	for item in [["History", "履歴は未実装"], ["Releases", "Releases は未実装"], ["Members", "Members は未実装"]]:
		var stub := _quiet_button(str(item[0]), true)
		stub.disabled = true
		stub.tooltip_text = str(item[1])
		right.add_child(stub)
	return row

func _build_bottom_row() -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	world_button = _quiet_button("🌐  Output · World")
	world_button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	world_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	world_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	world_button.pressed.connect(_open_sessions)
	row.add_child(world_button)
	var modes := PanelContainer.new()
	modes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modes.add_theme_stylebox_override("panel", DesignChrome.box(DesignChrome.GROUND, 10, 4, DesignChrome.LINE))
	row.add_child(modes)
	var mode_row := HBoxContainer.new()
	mode_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_row.add_theme_constant_override("separation", 2)
	modes.add_child(mode_row)
	edit_button = _quiet_button("✎")
	edit_button.tooltip_text = "Edit"
	edit_button.pressed.connect(func(): app.hud.set_edit_mode(true))
	mode_row.add_child(edit_button)
	play_button = _quiet_button("▶")
	play_button.tooltip_text = "Play"
	play_button.pressed.connect(func(): app.hud.set_edit_mode(false))
	mode_row.add_child(play_button)
	var debug_button := _quiet_button("🐞", true)
	debug_button.disabled = true
	debug_button.tooltip_text = "Debug は未実装"
	mode_row.add_child(debug_button)
	inspector_button = _quiet_button("▣ 0")
	inspector_button.tooltip_text = "インスペクタ"
	inspector_button.pressed.connect(func(): app.hud.open_dock("inspector"))
	row.add_child(inspector_button)
	resources_button = _quiet_button("▤ 0")
	resources_button.tooltip_text = "Resources"
	resources_button.pressed.connect(func(): app.hud.open_dock("resources"))
	row.add_child(resources_button)
	var status := HBoxContainer.new()
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_constant_override("separation", 6)
	row.add_child(status)
	status_dot = _label("●", 13, DesignChrome.OK)
	status.add_child(status_dot)
	status_label = _label("", 13, DesignChrome.MUTED)
	status_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	status.add_child(status_label)
	return row

func _rule() -> Control:
	var line := HSeparator.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = DesignChrome.LINE
	style.set_content_margin_all(0)
	line.add_theme_stylebox_override("separator", style)
	line.custom_minimum_size.y = 1
	return line

func _label(value: String, size: int, color: Color) -> Label:
	var node := Label.new()
	node.text = value
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node

func _quiet_button(value: String, muted: bool = false) -> Button:
	var node := Button.new()
	node.text = value
	node.focus_mode = Control.FOCUS_NONE
	node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	node.mouse_filter = Control.MOUSE_FILTER_STOP
	DesignChrome.style_quiet(node)
	if muted:
		node.add_theme_color_override("font_color", DesignChrome.MUTED)
		node.add_theme_color_override("font_disabled_color", DesignChrome.MUTED)
	return node

func _open_projects() -> void:
	var workspace = app.get("service_panel")
	if workspace == null or not workspace.enabled: return
	app.release_cursor()
	workspace.open_page("projects")

func _open_sessions() -> void:
	var workspace = app.get("service_panel")
	if workspace == null or not workspace.enabled: return
	app.release_cursor()
	workspace.open_page("sessions")
