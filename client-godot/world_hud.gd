extends CanvasLayer
## Local application chrome. The world and edit operations stay in the Engine.
const RING = preload("res://ring_menu.gd")
const DesktopWindow = preload("res://desktop_window.gd")
const CURSOR_IMAGE = preload("res://assets/ui/selection-cursor.png")
const BRAND_ART = preload("res://brand_art.gd")
const INK := Color("101b25")
const LINE := Color("304550")
const TEXT := Color("e6f0f4")
const MUTED := Color("91a8b5")
const ACCENT := Color("77dbce")
var app
var root := Control.new()
var ring = RING.new()
var menu = DesktopWindow.new()
var workspace
var dock_holder: CenterContainer
var dock: HBoxContainer
var dock_buttons := {}
var edit_mode_buttons := {}
var dock_tween: Tween
var dock_open := false
var cursor_texture: ImageTexture
var room_label: Label
var sync_label: Label
var fps_label: Label
var engine_label: Label
var mode_button: Button
var language_selector: OptionButton
var language_status: Label
var top_bar: PanelContainer
var ring_target := ""
var next_status := 0

func style(color: Color, padding: int = 12) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = color
	result.border_color = LINE
	result.set_border_width_all(1)
	result.set_corner_radius_all(8)
	result.set_content_margin_all(padding)
	return result

func text(value: String, size: int = 15, color: Color = TEXT) -> Label:
	var result := Label.new()
	result.text = value
	result.add_theme_font_size_override("font_size",size)
	result.add_theme_color_override("font_color",color)
	return result

func button(parent: Node, value: String, action: Callable) -> Button:
	var result := Button.new()
	result.text = value
	result.focus_mode = Control.FOCUS_NONE
	result.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	result.add_theme_color_override("font_color",TEXT)
	result.add_theme_stylebox_override("normal",style(Color.TRANSPARENT,8))
	result.add_theme_stylebox_override("hover",style(Color("233b47"),8))
	result.add_theme_stylebox_override("pressed",style(Color("2b5057"),8))
	result.pressed.connect(action)
	parent.add_child(result)
	return result

func setup(owner) -> void:
	app = owner
	var cursor_image := CURSOR_IMAGE.get_image()
	cursor_image.resize(32,32,Image.INTERPOLATE_LANCZOS)
	cursor_texture = ImageTexture.create_from_image(cursor_image)
	Input.set_custom_mouse_cursor(cursor_texture,Input.CURSOR_ARROW,Vector2.ZERO)
	Input.set_custom_mouse_cursor(cursor_texture,Input.CURSOR_POINTING_HAND,Vector2.ZERO)
	workspace = app.get("service_panel")
	layer = 25
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font_size = 15
	root.theme = theme
	var bar := PanelContainer.new()
	top_bar = bar
	bar.name="TopBar"
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left=16; bar.offset_right=-16; bar.offset_top=14; bar.offset_bottom=66
	bar.add_theme_stylebox_override("panel",style(Color("101b25f5"),8))
	root.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation",12)
	bar.add_child(row)
	var brand_panel := PanelContainer.new()
	brand_panel.add_theme_stylebox_override("panel", style(Color("f5e9d5"), 3))
	brand_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(brand_panel)
	var brand := HBoxContainer.new()
	brand.name = "Brand"
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brand.add_theme_constant_override("separation", 4)
	brand_panel.add_child(brand)
	brand.add_child(BRAND_ART.picture(BRAND_ART.mascot(), Vector2(30, 30)))
	brand.add_child(BRAND_ART.picture(BRAND_ART.wordmark(), Vector2(125, 23)))
	row.add_child(VSeparator.new())
	var edit_switch := HBoxContainer.new()
	edit_switch.add_theme_constant_override("separation",2)
	row.add_child(edit_switch)
	edit_mode_buttons.play=button(edit_switch,"▶ Play",func(): set_edit_mode(false))
	edit_mode_buttons.edit=button(edit_switch,"✎ Edit",func(): set_edit_mode(true))
	row.add_child(VSeparator.new())
	room_label=text("Workshop",14,MUTED)
	room_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	room_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	room_label.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(room_label)
	sync_label=text("● 接続待ち",13,MUTED)
	row.add_child(sync_label)
	engine_label=text("",12,MUTED)
	row.add_child(engine_label)
	fps_label=text("-- FPS",13)
	fps_label.custom_minimum_size.x=62
	row.add_child(fps_label)
	mode_button=button(row,"FPS",cycle_view)
	mode_button.tooltip_text="視点切り替え · F5"
	build_menu()
	build_dock()
	refresh_edit_mode()
	root.add_child(ring)
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.hide()
	ring.chosen.connect(choose_action)
	ring.cancelled.connect(close_ring)
	# The old standalone service button is replaced by the dock.
	if workspace != null:
		workspace.open_button.hide()
		workspace.open_button.visibility_changed.connect(func():
			if workspace.open_button.visible: workspace.open_button.hide())

func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null,Input.CURSOR_ARROW)
	Input.set_custom_mouse_cursor(null,Input.CURSOR_POINTING_HAND)

func build_menu() -> void:
	root.add_child(menu)
	menu.size=Vector2(530,470)
	menu.position=Vector2(128,118)
	menu.minimum_window_size=Vector2(420,320)
	menu.panel.add_theme_stylebox_override("panel",style(INK,22))
	menu.hide()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",12)
	menu.panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	menu.use_titlebar(header)
	var title := text("ユーザー設定",22)
	title.mouse_filter=Control.MOUSE_FILTER_IGNORE
	title.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	header.add_child(title)
	button(header,"閉じる",close_menu)
	column.add_child(HSeparator.new())
	var settings := VBoxContainer.new()
	settings.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	settings.add_theme_constant_override("separation",9)
	column.add_child(settings)
	settings.add_child(text("言語",13,MUTED))
	language_selector=OptionButton.new()
	language_selector.name="LanguageSelector"
	language_selector.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	language_selector.add_item("日本語")
	language_selector.add_item("한국어")
	language_selector.custom_minimum_size.y=38
	language_selector.select(AppLanguage.LOCALES.find(AppLanguage.locale))
	language_selector.item_selected.connect(func(index):
		var saved: bool=AppLanguage.set_locale(AppLanguage.LOCALES[index])
		language_status.text="" if saved else tr("言語設定を保存できませんでした。"))
	settings.add_child(language_selector)
	language_status=text("",12,MUTED)
	settings.add_child(language_status)
	AppLanguage.language_changed.connect(func(): language_selector.select(AppLanguage.LOCALES.find(AppLanguage.locale)))
	settings.add_child(text("表示名",13,MUTED))
	app.nickname.reparent(settings)
	app.nickname.custom_minimum_size.y=38
	settings.add_child(text("アバター",13,MUTED))
	var avatar_row := HBoxContainer.new()
	settings.add_child(avatar_row)
	app.avatar_button.reparent(avatar_row)
	app.avatar_button.text="テクスチャを選択"
	app.reset_avatar.reparent(avatar_row)
	app.reset_avatar.text="リセット"
	settings.add_child(HSeparator.new())
	settings.add_child(text("参加者",13,MUTED))
	app.people_label.reparent(settings)
	app.people_label.max_lines_visible=6

func build_dock() -> void:
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	holder.offset_top=18
	holder.offset_bottom=94
	holder.mouse_filter=Control.MOUSE_FILTER_PASS
	holder.modulate.a=0.0
	root.add_child(holder)
	dock_holder=holder
	dock=HBoxContainer.new()
	dock.add_theme_constant_override("separation",10)
	holder.add_child(dock)
	for item in [["sessions","⌂","セッション"],["projects","◇","Projects"],["library","▦","インベントリ"],["workshop","✦","ワークショップ"],["camera","◉","カメラ"],["inspector","▣","インスペクタ"],["resources","▤","Resources"],["scripts","⌘","Scripts"],["settings","⚙","設定"]]:
		var key: String=item[0]
		var tile := Button.new()
		tile.text=item[1]+"\n"+item[2]
		tile.custom_minimum_size=Vector2(108,64)
		tile.focus_mode=Control.FOCUS_NONE
		tile.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
		tile.add_theme_font_size_override("font_size",14)
		tile.add_theme_color_override("font_color",TEXT)
		tile.add_theme_color_override("font_hover_color",ACCENT)
		tile.add_theme_stylebox_override("normal",style(INK,5))
		tile.add_theme_stylebox_override("hover",style(Color("233b47"),5))
		tile.add_theme_stylebox_override("pressed",style(Color("2b5057"),5))
		tile.pressed.connect(func(): open_dock(key))
		dock.add_child(tile)
		dock_buttons[key]=tile
	dock_buttons.inspector.hide()
	dock_buttons.resources.hide()
	dock_buttons.scripts.hide()
	holder.hide()

func refresh_edit_mode() -> void:
	for key in ["play","edit"]:
		var active: bool=app.edit_mode == (key=="edit")
		var tile: Button=edit_mode_buttons[key]
		tile.add_theme_stylebox_override("normal",style(Color("245750") if active else Color.TRANSPARENT,8))
		tile.add_theme_color_override("font_color",ACCENT if active else MUTED)
	dock_buttons.inspector.visible=app.edit_mode
	dock_buttons.resources.visible=app.edit_mode
	dock_buttons.scripts.visible=app.edit_mode

func set_edit_mode(enabled: bool) -> void:
	if app.edit_mode==enabled: return
	app.edit_mode=enabled
	if not enabled:
		ring.hide()
		app.world_panels.clear_focus()
		for id in app.world_panels.windows.keys(): app.world_panels.close_window(id)
		app.inspector_shell.hide()
		app.inspector_toggle.set_pressed_no_signal(false)
		if app.script_editor.window != null: app.script_editor.window.hide()
		if app.gizmo.dragging: app.gizmo.cancel_drag()
	app.world_panels.refresh_gizmos()
	refresh_edit_mode()

func set_html_chrome(active: bool) -> void:
	if top_bar: top_bar.visible = not active

func set_dock_open(open: bool, animate: bool = true) -> void:
	if dock_open==open: return
	dock_open=open
	if dock_tween and dock_tween.is_running(): dock_tween.kill()
	if open: dock_holder.show()
	var top: float=-86.0 if open else 18.0
	var bottom: float=-10.0 if open else 94.0
	var alpha: float=1.0 if open else 0.0
	if not animate:
		dock_holder.offset_top=top
		dock_holder.offset_bottom=bottom
		dock_holder.modulate.a=alpha
		if not open: dock_holder.hide()
		return
	dock_tween=create_tween().set_parallel(true)
	dock_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	dock_tween.tween_property(dock_holder,"offset_top",top,0.28)
	dock_tween.tween_property(dock_holder,"offset_bottom",bottom,0.28)
	dock_tween.tween_property(dock_holder,"modulate:a",alpha,0.22)
	dock_tween.finished.connect(func(): if not dock_open: dock_holder.hide())

func open_dock(key: String) -> void:
	if key=="inspector":
		if app.edit_mode: app.world_panels.pin_target(app.selected_id)
	elif key=="resources":
		if app.edit_mode: app.world_panels.open_resources(app.selected_id)
	elif key=="scripts":
		if app.edit_mode: app.world_panels.open_script_editor(app.selected_id)
	elif key=="camera":
		app.camera_tool.open(app.selected_id)
	elif key=="settings":
		toggle_menu()
	elif workspace != null and workspace.enabled:
		menu.hide()
		ring.hide()
		workspace.open_page(key)

func workspace_open() -> bool:
	return workspace != null and workspace.enabled and workspace.shade.visible

func blocking() -> bool:
	return menu.visible or ring.visible or workspace_open()

func open_creation() -> void:
	if app.edit_mode: app.world_panels.open_creation()

func release_to_cursor() -> void:
	var captured: bool=Input.mouse_mode==Input.MOUSE_MODE_CAPTURED or app.fps_active
	var closed_overlay := false
	if not captured:
		if ring.visible: ring.hide(); closed_overlay=true
		elif menu.visible: menu.hide(); closed_overlay=true
		elif workspace_open(): workspace.close_active_page(); closed_overlay=true
	app.get_viewport().gui_release_focus()
	app.world_panels.clear_focus()
	app.release_cursor()
	set_dock_open(true if captured or closed_overlay else not dock_open)

func resume_view() -> void:
	if blocking() or app.world_panels.has_window_focus() or not app.get_window().has_focus(): return
	if app.avatar_camera and app.first_person:
		app.fps_active=true
		Input.mouse_mode=Input.MOUSE_MODE_CAPTURED
		set_dock_open(false)

func close_menu() -> void:
	menu.hide()

func toggle_menu() -> void:
	if menu.visible: close_menu()
	else:
		ring.hide()
		app.get_viewport().gui_release_focus()
		app.world_panels.clear_focus()
		app.release_cursor()
		menu.show()

func close_ring() -> void:
	ring.hide()
	resume_view()

func cycle_view() -> void:
	app.set_view_mode((app.view_mode.selected+1)%3)
	if blocking(): app.release_cursor()

func show_ring(position: Vector2) -> void:
	if not app.edit_mode: return
	var screen: Vector2 = app.get_viewport().get_visible_rect().size*0.5 if app.fps_active else position
	ring_target=app.selected_id
	var origin: Vector3=app.camera.project_ray_origin(screen)
	var query := PhysicsRayQueryParameters3D.create(origin,origin+app.camera.project_ray_normal(screen)*4000)
	var hit: Dictionary=app.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.collider.has_meta("object_id"):
		ring_target=str(hit.collider.get_meta("object_id"))
		app.select_object(ring_target)
	var name_text: String=str(app.world_panels.field_data(ring_target,"name").get("value","World"))
	app.world_panels.clear_focus()
	app.release_cursor()
	set_dock_open(false)
	ring.open(screen,name_text,app.editable)

func choose_action(index: int) -> void:
	ring.hide()
	if not app.edit_mode: return
	match index:
		0: app.world_panels.pin_target(ring_target)
		1: app.world_panels.open_inspector(ring_target)
		2: open_creation()
		3: app.world_panels.open_resources(ring_target)
	if index in [1,2,3]: resume_view()

func handle_input(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
			release_to_cursor()
			return true
		if (event.keycode == KEY_TAB or event.physical_keycode == KEY_TAB) and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed and not app.gameplay_keyboard_blocked():
			app.social_panels.set_stowed(not app.social_panels.stowed)
			return true
		if (event.keycode == KEY_F5 or event.physical_keycode == KEY_F5) and not app.gameplay_keyboard_blocked():
			cycle_view()
			return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if not app.edit_mode: return false
		# Opening the ring releases the cursor and cancels a right-click grab.
		if app.right_down or app.look or app.grab_waiting or not app.hand_grab.is_empty(): return true
		if event.pressed:
			if ring.visible: close_ring(); return true
			if not app.gameplay_keyboard_blocked(): show_ring(event.position); return true
	return false

func _process(_delta: float) -> void:
	if app.fps_active or Input.mouse_mode==Input.MOUSE_MODE_CAPTURED:
		if dock_open: set_dock_open(false)
	elif (menu.visible or workspace_open()) and not dock_open:
		set_dock_open(true)
	if Time.get_ticks_msec()<next_status: return
	next_status=Time.get_ticks_msec()+200
	fps_label.text="%d FPS" % Engine.get_frames_per_second()
	mode_button.text=["Third person","FPS","Fly camera"][app.view_mode.selected]
	var ready: bool=app.connected and app.editable
	var busy: bool=app.pending
	for request in app.requests.requests.values():
		busy=busy or request.kind in ["edit","structure","transform","script","playback"]
	for view in app.world_panels.views():
		busy=busy or view.edits.values().any(func(edit): return edit.dirty or edit.inflight) or not view.script_view.flight.is_empty()
	sync_label.text="● 同期中" if ready and busy else ("● 同期済み" if ready else "● 接続待ち")
	sync_label.add_theme_color_override("font_color",ACCENT if ready else Color("e9bc70"))
	sync_label.tooltip_text=app.status_label.text
	engine_label.text="Engine %d ms" % roundi(app.clock_best_rtt*1000) if app.clock_ready else ""
	engine_label.tooltip_text="ローカルEngineとの往復時間"
	room_label.text=str(workspace.current_session.get("name",app.session)) if workspace != null else app.session
	var services_available: bool=workspace != null and workspace.enabled
	for key in ["sessions","library","workshop"]:
		dock_buttons[key].disabled=not services_available
		var active: bool=workspace_open() and workspace.windows[key].visible
		dock_buttons[key].add_theme_color_override("font_color",ACCENT if active else TEXT)
	dock_buttons.settings.add_theme_color_override("font_color",ACCENT if menu.visible else TEXT)
	var inspector_open: bool=app.world_panels.windows.has(app.world_panels.dock_inspector_id)
	dock_buttons.inspector.add_theme_color_override("font_color",ACCENT if inspector_open else TEXT)
