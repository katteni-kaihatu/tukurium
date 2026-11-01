extends PanelContainer
## Resources explorer (design): folders + materials / meshes / textures / scripts.
## Catalog is local project (or workspace) FS via Engine service; Script attach stays shared.
const SCRIPT_GRAPH = preload("res://script_graph.gd")
const PIN_BUTTON = preload("res://pin_icon_button.gd")
const PAPER := Color("fffdf9")
const GROUND := Color("eae5db")
const INK := Color("26262e")
const MUTED := Color("5e5c64")
const LINE := Color("dcd5c8")
const PLUM := Color("603d56")
const SEL := Color("fff1bf")
const SEL_LINE := Color("e9c24a")
const RK := {
	"folder": {"label": "Folder", "bg": Color("fff1bf"), "fg": Color("9a6b00")},
	"model": {"label": "Model", "bg": Color("e3e7f6"), "fg": Color("2f4a9c")},
	"material": {"label": "Material", "bg": Color("f4f1ea"), "fg": Color("9a4a16")},
	"image": {"label": "Texture", "bg": Color("e5f3ec"), "fg": Color("1f6b47")},
	"script": {"label": "Script", "bg": Color("e3e7f6"), "fg": Color("2f4a9c")},
}
var manager
var panel_id := ""
var app
var items: Array = []
var files_dir := ""
var cwd := "r0"
var selected_id := ""
var query := ""
var view_mode := "icon" # icon | list | detail
var folder_open: Dictionary = {}
var new_menu_open := false
var pending_id := ""
var loading := false
var root_name := "Workspace"
# UI refs
var crumb_row: HBoxContainer
var search_box: LineEdit
var tree_list: VBoxContainer
var grid: GridContainer
var list_col: VBoxContainer
var detail_col: VBoxContainer
var empty_label: Label
var count_label: Label
var sel_label: Label
var status: Label
var new_panel: PanelContainer
var new_btn: Button
var new_scrim: Control
var ui_host: Control
var action_row: HBoxContainer
var color_picker: ColorPickerButton
var rename_edit: LineEdit
var renaming := false
var rename_from := ""
var up_button: Button
var view_buttons: Dictionary = {}
var pin_button

func setup(controller, id: String) -> void:
	manager = controller
	app = manager.app
	panel_id = id
	clip_contents = true
	var style := StyleBoxFlat.new()
	# Single glass face (HTML Inspector `.window.glass`): pin overlay adds no second frame.
	style.bg_color = Color("fffdf9")
	style.border_color = Color(1, 1, 1, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.shadow_color = Color(15 / 255.0, 25 / 255.0, 40 / 255.0, 0.18)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 4)
	style.set_content_margin_all(0)
	add_theme_stylebox_override("panel", style)
	build_ui()
	reload_catalog()

func build_ui() -> void:
	# PanelContainer stretches every direct child to full rect. Keep one host Control
	# so the New menu can stay a small floating card above the body.
	ui_host = Control.new()
	ui_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_host.clip_contents = true
	add_child(ui_host)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	ui_host.add_child(root)
	root.add_child(_header())
	root.add_child(_toolbar())
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	root.add_child(body)
	body.add_child(_tree_pane())
	body.add_child(_content_pane())
	root.add_child(_footer())
	status = Label.new()
	status.add_theme_color_override("font_color", MUTED)
	status.add_theme_font_size_override("font_size", 12)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var status_wrap := MarginContainer.new()
	status_wrap.add_theme_constant_override("margin_left", 12)
	status_wrap.add_theme_constant_override("margin_right", 12)
	status_wrap.add_theme_constant_override("margin_bottom", 8)
	status_wrap.add_child(status)
	root.add_child(status_wrap)
	_build_new_menu_overlay()

func _header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 6)
	pad.add_child(header)
	var title := Label.new()
	title.text = "Resources"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(title)
	pin_button = PIN_BUTTON.new()
	pin_button.set_pinned_look(manager.pinned_to_me(panel_id))
	pin_button.pressed.connect(func(): manager.toggle_pin(panel_id))
	header.add_child(pin_button)
	var close := Button.new()
	close.text = "×"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(36, 30)
	_style_ghost(close)
	close.pressed.connect(func(): manager.close_panel(panel_id))
	header.add_child(close)
	# Pin overlay has no outer chrome; drag the content header like HTML Inspector.
	header.gui_input.connect(_on_header_input)
	return pad

func _on_header_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		return
	if not manager.pinned_to_me(panel_id):
		return
	manager.begin_pin_drag(panel_id)
	accept_event()

func _toolbar() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 10)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_bottom", 8)
	pad.add_child(bar)
	up_button = _icon_btn("↑", "ひとつ上へ", func(): go_up())
	up_button.custom_minimum_size = Vector2(32, 32)
	_style_ghost(up_button)
	bar.add_child(up_button)
	var crumb_wrap := PanelContainer.new()
	crumb_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var crumb_style := StyleBoxFlat.new()
	crumb_style.bg_color = Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.05)
	crumb_style.set_corner_radius_all(9)
	crumb_style.set_content_margin_all(4)
	crumb_wrap.add_theme_stylebox_override("panel", crumb_style)
	bar.add_child(crumb_wrap)
	crumb_row = HBoxContainer.new()
	crumb_row.add_theme_constant_override("separation", 2)
	crumb_wrap.add_child(crumb_row)
	search_box = LineEdit.new()
	search_box.placeholder_text = "この中をさがす"
	search_box.custom_minimum_size = Vector2(150, 32)
	search_box.focus_mode = Control.FOCUS_CLICK
	search_box.text_changed.connect(func(t): query = t; rebuild_items())
	_style_line_edit(search_box)
	bar.add_child(search_box)
	var views := HBoxContainer.new()
	views.add_theme_constant_override("separation", 1)
	var views_bg := PanelContainer.new()
	var vs := StyleBoxFlat.new()
	vs.bg_color = Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.07)
	vs.set_corner_radius_all(9)
	vs.set_content_margin_all(2)
	views_bg.add_theme_stylebox_override("panel", vs)
	views_bg.add_child(views)
	bar.add_child(views_bg)
	for mode in [["icon", "Icons"], ["list", "List"], ["detail", "Details"]]:
		var b := Button.new()
		b.text = mode[1].substr(0, 1)
		b.tooltip_text = mode[1]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(30, 28)
		b.toggle_mode = true
		b.button_pressed = view_mode == mode[0]
		var m: String = mode[0]
		b.pressed.connect(func(): set_view(m))
		_style_toggle(b)
		views.add_child(b)
		view_buttons[mode[0]] = b
	new_btn = Button.new()
	new_btn.text = "+ New"
	new_btn.focus_mode = Control.FOCUS_NONE
	new_btn.custom_minimum_size = Vector2(88, 32)
	_style_primary(new_btn)
	new_btn.pressed.connect(toggle_new_menu)
	bar.add_child(new_btn)
	return pad

func _build_new_menu_overlay() -> void:
	new_scrim = Control.new()
	new_scrim.visible = false
	new_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	new_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	new_scrim.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			close_new_menu()
			accept_event()
	)
	ui_host.add_child(new_scrim)
	new_panel = PanelContainer.new()
	new_panel.visible = false
	new_panel.custom_minimum_size = Vector2(280, 0)
	new_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	new_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	new_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var ns := StyleBoxFlat.new()
	ns.bg_color = PAPER
	ns.border_color = Color("e7e1d6")
	ns.set_border_width_all(1)
	ns.set_corner_radius_all(14)
	ns.set_content_margin_all(8)
	ns.shadow_color = Color(0, 0, 0, 0.16)
	ns.shadow_size = 12
	ns.shadow_offset = Vector2(0, 4)
	new_panel.add_theme_stylebox_override("panel", ns)
	ui_host.add_child(new_panel)
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 2)
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_panel.add_child(menu)
	_menu_item(menu, "folder", "Folder", "いまのフォルダの中に作る", create_folder)
	_menu_item(menu, "material", "Material", "色付きマテリアルを追加", create_material)
	_menu_item(menu, "model", "Mesh / Model", "glTF / FBX を外部から取り込む", func(): import_external(["*.glb,*.fbx ; 3D models"]))
	_menu_item(menu, "image", "Texture", "画像を外部から取り込む", func(): import_external(["*.png,*.jpg,*.jpeg,*.webp ; Images"]))
	_menu_item(menu, "folder", "Import file…", "画像またはモデルを選ぶ", func(): import_external(["*.png,*.jpg,*.jpeg,*.webp ; Images", "*.glb,*.fbx ; 3D models"]))
	_menu_item(menu, "script", "Script (Lua)", "選択中 Slot へ空の Script を付ける", attach_blank)
	_menu_item(menu, "script", "Node graph", "選択中 Slot へノードグラフを付ける", attach_graph)

func _tree_pane() -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size.x = 172
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.08)
	style.border_width_right = 1
	style.set_content_margin_all(6)
	wrap.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(scroll)
	tree_list = VBoxContainer.new()
	tree_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree_list.add_theme_constant_override("separation", 1)
	scroll.add_child(tree_list)
	return wrap

func _content_pane() -> Control:
	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_theme_constant_override("separation", 8)
	var pad := MarginContainer.new()
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_left", 10)
	pad.add_theme_constant_override("margin_right", 10)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 6)
	wrap.add_child(pad)
	var stack := VBoxContainer.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_child(stack)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	stack.add_child(scroll)
	var host := VBoxContainer.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(host)
	grid = GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	host.add_child(grid)
	list_col = VBoxContainer.new()
	list_col.add_theme_constant_override("separation", 1)
	list_col.visible = false
	host.add_child(list_col)
	detail_col = VBoxContainer.new()
	detail_col.add_theme_constant_override("separation", 0)
	detail_col.visible = false
	host.add_child(detail_col)
	empty_label = Label.new()
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.add_theme_color_override("font_color", MUTED)
	empty_label.add_theme_font_size_override("font_size", 13)
	empty_label.visible = false
	host.add_child(empty_label)
	action_row = HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	stack.add_child(action_row)
	color_picker = ColorPickerButton.new()
	color_picker.custom_minimum_size = Vector2(120, 30)
	color_picker.edit_alpha = false
	color_picker.visible = false
	action_row.add_child(color_picker)
	rename_edit = LineEdit.new()
	rename_edit.visible = false
	rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rename_edit.custom_minimum_size = Vector2(160, 30)
	rename_edit.placeholder_text = "新しい名前"
	rename_edit.max_length = 80
	_style_line_edit(rename_edit)
	rename_edit.text_submitted.connect(func(_t): commit_rename())
	rename_edit.gui_input.connect(_on_rename_gui_input)
	action_row.add_child(rename_edit)
	return wrap

func _footer() -> Control:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 12)
	pad.add_theme_constant_override("margin_right", 12)
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 4)
	pad.add_child(bar)
	var line := StyleBoxFlat.new()
	line.bg_color = Color(0, 0, 0, 0)
	line.border_color = Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.08)
	line.border_width_top = 1
	line.set_content_margin_all(0)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", line)
	panel.add_child(pad)
	count_label = Label.new()
	count_label.add_theme_font_size_override("font_size", 12)
	count_label.add_theme_color_override("font_color", MUTED)
	bar.add_child(count_label)
	sel_label = Label.new()
	sel_label.add_theme_font_size_override("font_size", 12)
	sel_label.add_theme_color_override("font_color", Color("3a3942"))
	sel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sel_label)
	var hint := Label.new()
	hint.text = "ダブルクリックで開く · F2 で名前変更 · 外部ファイルは New から"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", MUTED)
	bar.add_child(hint)
	return panel

func _icon_btn(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.flat = true
	b.pressed.connect(action)
	return b

func _paper_box(bg: Color = PAPER, radius: float = 8.0, margins: Vector4 = Vector4(8, 4, 8, 4)) -> StyleBoxFlat:
	# Godot has no set_content_margin_individual; a bad call left default dark Button chrome.
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(radius))
	s.content_margin_left = margins.x
	s.content_margin_top = margins.y
	s.content_margin_right = margins.z
	s.content_margin_bottom = margins.w
	return s

func _apply_button_boxes(b: Button, normal: StyleBox, hover: StyleBox, pressed: StyleBox) -> void:
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_stylebox_override("disabled", normal)

func _style_ghost(b: Button) -> void:
	var n := _paper_box(Color(0, 0, 0, 0), 8)
	var hover := _paper_box(Color("f3eaf0"), 8)
	_apply_button_boxes(b, n, hover, hover)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", PLUM)
	b.add_theme_color_override("font_pressed_color", PLUM)
	b.add_theme_color_override("font_disabled_color", MUTED)

func _style_quiet(b: Button, selected: bool = false) -> void:
	var n := _paper_box(SEL if selected else PAPER, 7)
	if selected:
		n.set_border_width_all(1)
		n.border_color = SEL_LINE
	var hover := _paper_box(SEL, 7)
	hover.set_border_width_all(1)
	hover.border_color = SEL_LINE
	_apply_button_boxes(b, n, hover, hover)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", INK)
	b.add_theme_color_override("font_disabled_color", MUTED)

func _style_toggle(b: Button) -> void:
	# Design: off = transparent on tinted rail; on = paper #FFFDF9 + light shadow + plum ink.
	var off := _paper_box(Color(0, 0, 0, 0), 7, Vector4(0, 0, 0, 0))
	var on := _paper_box(PAPER, 7, Vector4(0, 0, 0, 0))
	on.shadow_color = Color(60 / 255.0, 40 / 255.0, 10 / 255.0, 0.14)
	on.shadow_size = 3
	on.shadow_offset = Vector2(0, 1)
	var hover := on if b.button_pressed else _paper_box(Color("f3eaf0"), 7, Vector4(0, 0, 0, 0))
	_apply_button_boxes(b, on if b.button_pressed else off, hover, on)
	b.add_theme_color_override("font_color", PLUM if b.button_pressed else Color("3a3942"))
	b.add_theme_color_override("font_hover_color", PLUM)
	b.add_theme_color_override("font_pressed_color", PLUM)

func _style_line_edit(edit: LineEdit) -> void:
	# Design search field: white fill, #DCD5C8 border, 9px radius.
	var n := _paper_box(Color("ffffff"), 9, Vector4(10, 6, 10, 6))
	n.set_border_width_all(1)
	n.border_color = Color("dcd5c8")
	var focus := n.duplicate()
	focus.border_color = Color("d9c5d2")
	edit.add_theme_stylebox_override("normal", n)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_stylebox_override("read_only", n)
	edit.add_theme_color_override("font_color", INK)
	edit.add_theme_color_override("font_placeholder_color", MUTED)
	edit.add_theme_color_override("caret_color", PLUM)

func _style_primary(b: Button) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = PLUM
	s.set_corner_radius_all(9)
	s.set_content_margin_all(0)
	var h := s.duplicate()
	h.bg_color = Color("734a67")
	_apply_button_boxes(b, s, h, h)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 13)

func _style_menu_row(b: Button) -> void:
	var n := _paper_box(PAPER, 8, Vector4(8, 6, 8, 6))
	var hover := _paper_box(Color("f3eaf0"), 8, Vector4(8, 6, 8, 6))
	var pressed := _paper_box(Color("ebe0e8"), 8, Vector4(8, 6, 8, 6))
	_apply_button_boxes(b, n, hover, pressed)
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_hover_color", PLUM)
	b.add_theme_color_override("font_pressed_color", PLUM)
	b.add_theme_color_override("font_focus_color", INK)

func _menu_item(parent: Node, kind: String, label: String, sub: String, action: Callable) -> void:
	var meta: Dictionary = RK.get(kind, RK.folder)
	var row := Button.new()
	row.focus_mode = Control.FOCUS_NONE
	row.flat = true
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.custom_minimum_size = Vector2(0, 48)
	_style_menu_row(row)
	row.pressed.connect(func():
		close_new_menu()
		action.call()
	)
	parent.add_child(row)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 8
	box.offset_right = -8
	box.offset_top = 6
	box.offset_bottom = -6
	var icon := PanelContainer.new()
	icon.custom_minimum_size = Vector2(30, 30)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var istyle := StyleBoxFlat.new()
	istyle.bg_color = meta.bg
	istyle.set_corner_radius_all(8)
	icon.add_theme_stylebox_override("panel", istyle)
	box.add_child(icon)
	var ic := Label.new()
	ic.text = label.substr(0, 1)
	ic.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ic.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ic.add_theme_color_override("font_color", meta.fg)
	ic.add_theme_font_size_override("font_size", 14)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(ic)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(col)
	var t := Label.new()
	t.text = label
	t.add_theme_font_size_override("font_size", 13)
	t.add_theme_color_override("font_color", INK)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(t)
	var s := Label.new()
	s.text = sub
	s.add_theme_font_size_override("font_size", 11)
	s.add_theme_color_override("font_color", MUTED)
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(s)

func place_new_menu() -> void:
	if new_btn == null or new_panel == null or ui_host == null: return
	new_panel.reset_size()
	var min_size: Vector2 = new_panel.get_combined_minimum_size()
	var width: float = maxf(min_size.x, 280.0)
	var height: float = maxf(min_size.y, 48.0)
	var btn_rect: Rect2 = new_btn.get_global_rect()
	var host_rect: Rect2 = ui_host.get_global_rect()
	var left: float = btn_rect.position.x + btn_rect.size.x - width - host_rect.position.x
	var top: float = btn_rect.position.y + btn_rect.size.y + 6.0 - host_rect.position.y
	left = clampf(left, 8.0, maxf(8.0, host_rect.size.x - width - 8.0))
	top = clampf(top, 8.0, maxf(8.0, host_rect.size.y - height - 8.0))
	new_panel.position = Vector2(left, top)
	new_panel.size = Vector2(width, height)

func close_new_menu() -> void:
	new_menu_open = false
	if new_panel: new_panel.visible = false
	if new_scrim: new_scrim.visible = false

func toggle_new_menu() -> void:
	new_menu_open = not new_menu_open
	if not new_menu_open:
		close_new_menu()
		return
	new_scrim.visible = true
	new_panel.visible = true
	ui_host.move_child(new_scrim, ui_host.get_child_count() - 1)
	ui_host.move_child(new_panel, ui_host.get_child_count() - 1)
	place_new_menu.call_deferred()

func set_view(mode: String) -> void:
	view_mode = mode
	for k in view_buttons:
		view_buttons[k].button_pressed = k == mode
		_style_toggle(view_buttons[k])
	rebuild_items()

func catalog_slug() -> String:
	var project: Dictionary = app.service_panel.current_project if app.service_panel else {}
	return str(project.get("slug", ""))

func service(action: String, body: Dictionary, done: Callable) -> void:
	var payload := body.duplicate(true)
	payload.kind = "service"
	payload.action = action
	var slug := catalog_slug()
	if not slug.is_empty(): payload.slug = slug
	app.requests.request(payload, func(result):
		if not result.get("ok", false):
			status.text = str(result.get("message", "処理できませんでした。"))
			if done.is_valid(): done.call({})
			return
		done.call(result.get("data", {}))
	, ["request_id"], "request_id", 120000, "service_result")

func reload_catalog() -> void:
	if loading: return
	loading = true
	status.text = "読み込み中…"
	service("project_resources", {}, func(data):
		loading = false
		if data.is_empty():
			status.text = "カタログを読めませんでした。"
			return
		items = data.get("items", [])
		files_dir = str(data.get("files_dir", ""))
		root_name = str(data.get("root_name", "Workspace"))
		if not by_id(cwd): cwd = "r0"
		status.text = ""
		rebuild_all()
	)

func by_id(id: String) -> Dictionary:
	for x in items:
		if str(x.get("id", "")) == id: return x
	return {}

func kids_of(pid: String) -> Array:
	var out: Array = []
	for x in items:
		var p = x.get("parent", null)
		if (p == null and pid == "") or str(p) == pid:
			out.append(x)
	out.sort_custom(func(a, b):
		var af := 0 if str(a.get("kind","")) == "folder" else 1
		var bf := 0 if str(b.get("kind","")) == "folder" else 1
		if af != bf: return af < bf
		return str(a.get("name","")) < str(b.get("name",""))
	)
	return out

func rebuild_all() -> void:
	rebuild_crumbs()
	rebuild_tree()
	rebuild_items()
	rebuild_actions()

func rebuild_crumbs() -> void:
	for c in crumb_row.get_children(): c.queue_free()
	var chain: Array = []
	var cur := by_id(cwd)
	while not cur.is_empty():
		chain.push_front(cur)
		var p = cur.get("parent", null)
		cur = by_id(str(p)) if p != null else {}
	up_button.disabled = cwd == "r0"
	for i in chain.size():
		if i > 0:
			var sep := Label.new()
			sep.text = "›"
			sep.add_theme_color_override("font_color", Color("8a8792"))
			crumb_row.add_child(sep)
		var b := Button.new()
		b.text = str(chain[i].get("name", "?"))
		b.focus_mode = Control.FOCUS_NONE
		b.flat = true
		_style_ghost(b)
		var id := str(chain[i].id)
		if i == chain.size() - 1:
			b.add_theme_color_override("font_color", INK)
			b.disabled = true
		else:
			b.add_theme_color_override("font_color", MUTED)
			b.pressed.connect(func(): go_folder(id))
		crumb_row.add_child(b)

func rebuild_tree() -> void:
	for c in tree_list.get_children(): c.queue_free()
	_walk_tree("r0", 0)

func _walk_tree(id: String, depth: int) -> void:
	var f := by_id(id)
	if f.is_empty(): return
	var subs: Array = kids_of(id).filter(func(x): return str(x.get("kind","")) == "folder")
	var open := bool(folder_open.get(id, depth == 0 or _is_ancestor(id, cwd)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var pad := Control.new()
	pad.custom_minimum_size.x = depth * 12
	row.add_child(pad)
	if subs.size() > 0:
		var chev := Button.new()
		chev.text = "▾" if open else "▸"
		chev.focus_mode = Control.FOCUS_NONE
		chev.flat = true
		chev.custom_minimum_size = Vector2(18, 18)
		_style_ghost(chev)
		chev.pressed.connect(func():
			folder_open[id] = not open
			rebuild_tree()
		)
		row.add_child(chev)
	else:
		var sp := Control.new()
		sp.custom_minimum_size.x = 18
		row.add_child(sp)
	var btn := Button.new()
	btn.text = "📁 " + str(f.get("name", "?"))
	btn.focus_mode = Control.FOCUS_NONE
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.y = 28
	_style_quiet(btn, id == cwd)
	btn.pressed.connect(func(): go_folder(id))
	row.add_child(btn)
	tree_list.add_child(row)
	if open:
		for sub in subs: _walk_tree(str(sub.id), depth + 1)

func _is_ancestor(id: String, child: String) -> bool:
	var cur := by_id(child)
	while not cur.is_empty():
		if str(cur.get("id","")) == id: return true
		var p = cur.get("parent", null)
		if p == null: return false
		cur = by_id(str(p))
	return false

func current_list() -> Array:
	var q := query.strip_edges()
	if q.is_empty(): return kids_of(cwd)
	var out: Array = []
	_collect_search(cwd, q, out)
	return out

func _collect_search(pid: String, q: String, out: Array) -> void:
	for x in kids_of(pid):
		if str(x.get("name","")).findn(q) >= 0: out.append(x)
		if str(x.get("kind","")) == "folder":
			_collect_search(str(x.id), q, out)

func rebuild_items() -> void:
	for c in grid.get_children(): c.queue_free()
	for c in list_col.get_children(): c.queue_free()
	for c in detail_col.get_children(): c.queue_free()
	var list := current_list()
	grid.visible = view_mode == "icon"
	list_col.visible = view_mode == "list"
	detail_col.visible = view_mode == "detail"
	empty_label.visible = list.is_empty()
	empty_label.text = ("「%s」は見つかりませんでした" % query) if not query.strip_edges().is_empty() else "このフォルダは空です"
	count_label.text = "%d 項目" % list.size() + (("（「%s」で検索）" % query) if not query.strip_edges().is_empty() else "")
	var sel := by_id(selected_id)
	sel_label.text = ("選択: " + str(sel.get("name",""))) if not sel.is_empty() else ""
	if view_mode == "detail":
		var head := HBoxContainer.new()
		for t in ["Name", "Type", "Usage"]:
			var l := Label.new()
			l.text = t
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL if t == "Name" else Control.SIZE_SHRINK_END
			l.custom_minimum_size.x = 84 if t == "Type" else (120 if t == "Usage" else 0)
			l.add_theme_font_size_override("font_size", 11)
			l.add_theme_color_override("font_color", MUTED)
			head.add_child(l)
		detail_col.add_child(head)
	for x in list:
		match view_mode:
			"icon": grid.add_child(_tile(x))
			"list": list_col.add_child(_row(x, false))
			"detail": detail_col.add_child(_row(x, true))

func _tile(x: Dictionary) -> Control:
	var kind := str(x.get("kind", "folder"))
	var meta: Dictionary = RK.get(kind, RK.folder)
	var on := str(x.get("id","")) == selected_id
	var id := str(x.id)
	# PanelContainer + VBox avoids Button+FULL_RECT children collapsing Grid cells.
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(118, 128)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = SEL if on else PAPER
	style.border_color = SEL_LINE if on else Color("e7e1d6")
	style.set_border_width_all(2 if on else 1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", style)
	card.gui_input.connect(func(ev):
		if not ev is InputEventMouseButton or not ev.pressed or ev.button_index != MOUSE_BUTTON_LEFT:
			return
		if ev.double_click:
			open_item(id)
		else:
			select_item(id)
	)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)
	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(0, 68)
	thumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thumb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ts := StyleBoxFlat.new()
	ts.bg_color = meta.bg
	ts.set_corner_radius_all(10)
	thumb.add_theme_stylebox_override("panel", ts)
	col.add_child(thumb)
	if kind == "material":
		var ball := PanelContainer.new()
		ball.custom_minimum_size = Vector2(36, 36)
		ball.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(str(x.get("hex", "#cccccc")))
		bs.set_corner_radius_all(18)
		bs.border_color = Color(0, 0, 0, 0.2)
		bs.set_border_width_all(1)
		ball.add_theme_stylebox_override("panel", bs)
		var center := CenterContainer.new()
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		center.add_child(ball)
		thumb.add_child(center)
	else:
		var mark := Label.new()
		mark.text = meta.label.substr(0, 1)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		mark.add_theme_color_override("font_color", meta.fg)
		mark.add_theme_font_size_override("font_size", 22)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		thumb.add_child(mark)
	var name_l := Label.new()
	name_l.text = str(x.get("name",""))
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override("font_size", 12)
	name_l.add_theme_color_override("font_color", INK)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_l)
	var kind_l := Label.new()
	kind_l.text = meta.label
	kind_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kind_l.add_theme_font_size_override("font_size", 10)
	kind_l.add_theme_color_override("font_color", MUTED)
	kind_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(kind_l)
	return card

func _row(x: Dictionary, detail: bool) -> Control:
	var kind := str(x.get("kind", "folder"))
	var meta: Dictionary = RK.get(kind, RK.folder)
	var on := str(x.get("id","")) == selected_id
	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_pressed = on
	btn.focus_mode = Control.FOCUS_NONE
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size.y = 34 if detail else 32
	_style_quiet(btn, on)
	var id := str(x.id)
	btn.pressed.connect(func(): select_item(id))
	btn.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.double_click and ev.button_index == MOUSE_BUTTON_LEFT:
			open_item(id)
	)
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 8)
	btn.add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 8
	box.offset_right = -8
	var icon := PanelContainer.new()
	icon.custom_minimum_size = Vector2(22, 22)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var istyle := StyleBoxFlat.new()
	istyle.bg_color = meta.bg if kind != "material" else Color(str(x.get("hex", "#ccc")))
	istyle.set_corner_radius_all(6)
	icon.add_theme_stylebox_override("panel", istyle)
	box.add_child(icon)
	var name_l := Label.new()
	name_l.text = str(x.get("name",""))
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.add_theme_font_size_override("font_size", 13)
	name_l.add_theme_color_override("font_color", INK)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_l)
	var kind_l := Label.new()
	kind_l.text = meta.label
	kind_l.add_theme_font_size_override("font_size", 11)
	kind_l.add_theme_color_override("font_color", MUTED)
	kind_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(kind_l)
	if detail:
		var usage := Label.new()
		usage.text = usage_text(x)
		usage.custom_minimum_size.x = 120
		usage.add_theme_font_size_override("font_size", 11)
		usage.add_theme_color_override("font_color", MUTED)
		usage.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(usage)
	return btn

func usage_text(x: Dictionary) -> String:
	var kind := str(x.get("kind",""))
	if kind == "folder": return "%d 項目" % kids_of(str(x.id)).size()
	if kind == "material": return "色 " + str(x.get("hex", ""))
	if kind == "model": return "メッシュ" if str(x.get("asset_id","")) != "" or str(x.get("file","")) != "" else "—"
	if kind == "image": return "%sx%s" % [x.get("width", "?"), x.get("height", "?")]
	if kind == "script": return "Slot へ付与済み" if x.get("attached", false) else "定義"
	return "—"

func select_item(id: String) -> void:
	if renaming and id != selected_id:
		cancel_rename()
	selected_id = id
	rebuild_items()
	rebuild_actions()

func rebuild_actions() -> void:
	for c in action_row.get_children():
		if c != color_picker and c != rename_edit: c.queue_free()
	color_picker.visible = false
	if rename_edit: rename_edit.visible = false
	var x := by_id(selected_id)
	if x.is_empty():
		renaming = false
		return
	if renaming:
		rename_edit.visible = true
		if rename_edit.text.is_empty() or rename_from != selected_id:
			rename_edit.text = str(x.get("name", ""))
			rename_from = selected_id
		_action_btn("保存", commit_rename)
		_action_btn("キャンセル", cancel_rename)
		rename_edit.call_deferred("grab_focus")
		rename_edit.call_deferred("select_all")
		return
	var kind := str(x.get("kind",""))
	if kind == "material":
		color_picker.visible = true
		color_picker.color = Color(str(x.get("hex", "#cccccc")))
		if not color_picker.color_changed.is_connected(_on_material_color):
			color_picker.color_changed.connect(_on_material_color)
		_action_btn("選択に適用", apply_material)
	elif kind == "model" or kind == "image":
		_action_btn("ワールドに置く", func(): place_item(selected_id))
	elif kind == "script":
		_action_btn("Script Editor で開く", open_editor_for_selection)
	elif kind == "folder":
		_action_btn("開く", func(): go_folder(selected_id))
	_action_btn("名前を変更", start_rename)
	if selected_id != "r0":
		_action_btn("削除", func(): remove_item(selected_id))

func start_rename() -> void:
	if by_id(selected_id).is_empty(): return
	renaming = true
	rename_from = selected_id
	if rename_edit: rename_edit.text = str(by_id(selected_id).get("name", ""))
	rebuild_actions()

func cancel_rename() -> void:
	renaming = false
	rename_from = ""
	if rename_edit:
		rename_edit.text = ""
		rename_edit.release_focus()
	rebuild_actions()

func commit_rename(text: Variant = null) -> void:
	var x := by_id(selected_id)
	if x.is_empty():
		cancel_rename()
		return
	var next: String = str(text) if text != null else (rename_edit.text if rename_edit else "")
	next = next.strip_edges()
	if next.is_empty() or next.length() > 80:
		status.text = "名前は 1〜80 文字にしてください。"
		if rename_edit: rename_edit.grab_focus()
		return
	if next == str(x.get("name", "")):
		cancel_rename()
		return
	var item: Dictionary = x.duplicate(true)
	item["name"] = next
	item.erase("is_new")
	renaming = false
	rename_from = ""
	if rename_edit:
		rename_edit.release_focus()
		rename_edit.visible = false
	upsert_item(item)
	status.text = "「%s」に改名しました。" % next

func _on_rename_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		cancel_rename()
		accept_event()

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree(): return
	if not (event is InputEventKey and event.pressed and not event.echo): return
	if event.keycode == KEY_F2 and not selected_id.is_empty() and not renaming:
		start_rename()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and renaming:
		cancel_rename()
		get_viewport().set_input_as_handled()

func _action_btn(text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	_style_quiet(b, false)
	b.pressed.connect(action)
	action_row.add_child(b)

func _on_material_color(c: Color) -> void:
	var x := by_id(selected_id)
	if x.is_empty() or str(x.get("kind","")) != "material": return
	var hex := "#%02x%02x%02x" % [int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0)]
	upsert_item({"id": selected_id, "kind": "material", "name": x.get("name",""), "parent": x.get("parent"), "hex": hex})

func go_folder(id: String) -> void:
	if by_id(id).is_empty(): return
	if renaming: cancel_rename()
	cwd = id
	selected_id = ""
	query = ""
	search_box.text = ""
	folder_open[id] = true
	rebuild_all()

func go_up() -> void:
	var cur := by_id(cwd)
	var p = cur.get("parent", null)
	if p != null: go_folder(str(p))

func open_item(id: String) -> void:
	var x := by_id(id)
	if x.is_empty(): return
	match str(x.get("kind","")):
		"folder": go_folder(id)
		"model", "image": place_item(id)
		"material":
			select_item(id)
			apply_material()
		"script":
			select_item(id)
			open_editor_for_selection()
		_: select_item(id)

func stamp() -> String:
	return "r%s" % Time.get_ticks_usec()

func upsert_item(item: Dictionary, then_reload: bool = true) -> void:
	service("project_resource_upsert", {"item": item}, func(data):
		if data.has("items"):
			items = data.items
			if then_reload: rebuild_all()
			status.text = "保存しました。"
		else:
			reload_catalog()
	)

func create_folder() -> void:
	var id := stamp()
	upsert_item({"id": id, "kind": "folder", "name": "New Folder", "parent": cwd, "is_new": true})
	selected_id = id

func create_material() -> void:
	var id := stamp()
	upsert_item({"id": id, "kind": "material", "name": "New Material", "parent": cwd, "hex": "#F7C7D9", "is_new": true})
	selected_id = id

func remove_item(id: String) -> void:
	if id == "r0": return
	service("project_resource_remove", {"id": id}, func(data):
		if data.has("items"):
			items = data.items
			if selected_id == id: selected_id = ""
			rebuild_all()
			status.text = "削除しました。"
		else:
			reload_catalog()
	)

func import_external(filters: Array) -> void:
	if not app.editable:
		status.text = "編集できません。"
		return
	var packed := PackedStringArray()
	for f in filters: packed.append(str(f))
	app.asset_importer.choose_catalog_files(packed, func(paths):
		for path in paths:
			app.asset_importer.import_to_catalog(str(path), _on_catalog_prepared)
		status.text = "取り込み中…"
	)

func _on_catalog_prepared(ok: bool, payload: Dictionary, message: String) -> void:
	if not ok:
		status.text = message if not message.is_empty() else "取り込みに失敗しました。"
		return
	var id := stamp()
	var kind := str(payload.get("kind",""))
	var name := str(payload.get("name", "Imported"))
	var item := {"id": id, "kind": kind, "name": name, "parent": cwd, "is_new": true}
	if kind == "image":
		item.width = payload.get("width", 0)
		item.height = payload.get("height", 0)
		item.data_url = payload.get("data_url", "")
		var file_name := _write_bytes(id, str(payload.get("ext","png")), payload.get("bytes", PackedByteArray()))
		if not file_name.is_empty(): item.file = file_name
	elif kind == "model":
		item.asset_id = payload.get("asset_id", "")
		item.half_extents = payload.get("half_extents", [0.75, 0.75, 0.75])
		var file_name := _write_bytes(id, "glb", payload.get("bytes", PackedByteArray()))
		if not file_name.is_empty(): item.file = file_name
	else:
		status.text = "未対応の種類です。"
		return
	selected_id = id
	upsert_item(item)
	status.text = "%s をカタログに追加しました。" % name

func _write_bytes(id: String, ext: String, bytes: PackedByteArray) -> String:
	if bytes.is_empty() or files_dir.is_empty(): return ""
	DirAccess.make_dir_recursive_absolute(files_dir)
	var name := "%s.%s" % [id, ext]
	var path := files_dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: return ""
	f.store_buffer(bytes)
	return name

func place_item(id: String) -> void:
	var x := by_id(id)
	if x.is_empty() or not app.editable: return
	var kind := str(x.get("kind",""))
	if kind == "image":
		var data_url := str(x.get("data_url", ""))
		if data_url.is_empty() and str(x.get("file","")) != "" and not files_dir.is_empty():
			var path := files_dir.path_join(str(x.file))
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				var png := img.detect_alpha()
				var data := img.save_png_to_buffer() if png else img.save_jpg_to_buffer(0.85)
				var prefix := "data:image/png;base64," if png else "data:image/jpeg;base64,"
				data_url = prefix + Marshalls.raw_to_base64(data)
				x.width = img.get_width()
				x.height = img.get_height()
		if data_url.is_empty():
			status.text = "テクスチャデータがありません。"
			return
		app.asset_importer.place_visual({"kind":"image","data_url":data_url,"width":int(x.get("width",1)),"height":int(x.get("height",1))}, str(x.get("name","Texture")))
		status.text = "ワールドに置きました。"
	elif kind == "model":
		var asset_id := str(x.get("asset_id",""))
		var half = x.get("half_extents", [0.75, 0.75, 0.75])
		if asset_id.is_empty() and str(x.get("file","")) != "" and not files_dir.is_empty():
			# Re-import from disk into the live asset pipeline, then place.
			var path := files_dir.path_join(str(x.file))
			status.text = "モデルを読み込み中…"
			app.asset_importer.import_to_catalog(path, func(ok2, payload, msg):
				if not ok2:
					status.text = msg
					return
				upsert_item({"id": id, "kind": "model", "name": x.get("name",""), "parent": x.get("parent"), "asset_id": payload.asset_id, "half_extents": payload.half_extents, "file": x.get("file","")}, false)
				app.asset_importer.place_visual({"kind":"model","asset_id":payload.asset_id,"half_extents":payload.half_extents}, str(x.get("name","Model")), float(payload.get("half_height", 0.75)))
				status.text = "ワールドに置きました。"
			)
			return
		if asset_id.is_empty():
			status.text = "モデルデータがありません。"
			return
		app.asset_importer.place_visual({"kind":"model","asset_id":asset_id,"half_extents":half}, str(x.get("name","Model")), float(half[1]) if half is Array and half.size() > 1 else 0.75)
		status.text = "ワールドに置きました。"

func apply_material() -> void:
	var x := by_id(selected_id)
	if x.is_empty() or str(x.get("kind","")) != "material": return
	var target := str(app.selected_id)
	if target.is_empty() or not app.objects.has(target):
		status.text = "ワールドで物体を選んでから適用してください。"
		return
	if not app.editable:
		status.text = "編集できません。"
		return
	var c := Color(str(x.get("hex", "#cccccc")))
	manager.edit(target, "color", [c.r, c.g, c.b, c.a], func(result):
		if result.get("ok", false): status.text = "マテリアルを適用しました。"
		else: status.text = str(result.get("message", "適用できませんでした。"))
	)

func target_slot() -> String:
	var resources = app.objects.get(panel_id, {}).get("resources", {})
	if resources is Dictionary and resources.get("target") != null:
		return str(resources.target.instance_id)
	return str(app.selected_id)

func attach_blank() -> void:
	var target := target_slot()
	if target.is_empty() or not app.editable or not app.objects.has(target):
		status.text = "ワールドで Slot を選んでから Script を追加してください。"
		return
	var names: Array = app.objects.get(target, {}).get("scripts", []).map(func(c): return c.schema.name)
	var number := 1
	while names.has("Script%d" % number): number += 1
	var source := "return {\n    name = \"Script%d\",\n    fields = {},\n    drive = function(ctx)\n        -- Derive values with ctx:drive. Use ctx.time or ctx.world_time.\n    end\n}\n" % number
	send_attach(target, source, "Script%d" % number)

func attach_graph() -> void:
	var target := target_slot()
	if target.is_empty() or not app.editable or not app.objects.has(target):
		status.text = "ワールドで Slot を選んでから Script を追加してください。"
		return
	var names: Array = app.objects.get(target, {}).get("scripts", []).map(func(c): return c.schema.name)
	var number := 1
	while names.has("Graph%d" % number): number += 1
	var graph = SCRIPT_GRAPH.new()
	graph.fresh("Graph%d" % number)
	send_attach(target, graph.source(), "Graph%d" % number)

func send_attach(target: String, source: String, label: String) -> void:
	if not pending_id.is_empty(): return
	status.text = "追加しています…"
	pending_id = app.requests.request({"kind":"script","command":{"action":"attach","target":app.address_of(app.objects[target]),"source":source}}, func(body):
		pending_id = ""
		if body.get("ok", false):
			var id := stamp()
			upsert_item({"id": id, "kind": "script", "name": label, "parent": cwd, "is_new": true, "attached": true})
			status.text = "Script を追加しました。"
		else:
			status.text = body.get("message", "追加できませんでした。")
	)

func open_editor_for_selection() -> void:
	var target := target_slot()
	if target.is_empty():
		status.text = "Slot を選んでください。"
		return
	manager.open_script_editor(target, "")

func refresh(object: Dictionary) -> void:
	var resources = object.get("resources", {})
	var next := ""
	if resources is Dictionary and resources.get("target") != null:
		next = str(resources.target.instance_id)
	elif not app.selected_id.is_empty() and app.objects.has(app.selected_id):
		next = app.selected_id
	if next != "" and resources is Dictionary and resources.get("target") == null and app.objects.has(next):
		manager.edit(panel_id, "resources_target", app.address_of(app.objects[next]))
	if pin_button != null:
		pin_button.set_pinned_look(manager.pinned_to_me(panel_id))
	# Keep catalog in sync lightly when panel refreshes after reconnect.
	if items.is_empty() and not loading:
		reload_catalog()

func finish_all() -> void:
	pass

func has_active_edits() -> bool:
	return not pending_id.is_empty() or loading

func disconnected() -> void:
	pending_id = ""
	loading = false
