extends PanelContainer
## Shared Resources WorldPanel: Slot scripts as unified ScriptComponents.
const SCRIPT_GRAPH = preload("res://script_graph.gd")
const PAPER := Color("fffdf9")
const GROUND := Color("eae5db")
const INK := Color("26262e")
const MUTED := Color("6b6872")
const LINE := Color("dcd5c8")
const BLUE := Color("2f5fc4")
var manager
var panel_id := ""
var app
var target_id := ""
var slot_list: VBoxContainer
var script_list: VBoxContainer
var status: Label
var blank_button: Button
var graph_button: Button
var open_button: Button
var pending_id := ""
var selected_script := ""

func setup(controller, id: String) -> void:
	manager = controller
	app = manager.app
	panel_id = id
	var style := StyleBoxFlat.new()
	style.bg_color = GROUND
	style.border_color = LINE
	style.set_border_width_all(1)
	style.set_content_margin_all(18)
	add_theme_stylebox_override("panel", style)
	build_ui()

func build_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	add_child(root)
	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Resources"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text = "×"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): manager.close_panel(panel_id))
	header.add_child(close)
	var note := Label.new()
	note.text = "選択中の Slot へ Script（状態一体）を付けます。作成はここから。編集は Script Editor。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", MUTED)
	note.add_theme_font_size_override("font_size", 13)
	root.add_child(note)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	root.add_child(body)
	var left := _pane(body, "Slots")
	slot_list = left
	var right_wrap := VBoxContainer.new()
	right_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_wrap.add_theme_constant_override("separation", 10)
	body.add_child(right_wrap)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	right_wrap.add_child(actions)
	blank_button = _action(actions, "+ Blank", attach_blank)
	graph_button = _action(actions, "+ Node graph", attach_graph)
	open_button = _action(actions, "Script Editor で開く", open_editor)
	var right := _pane(right_wrap, "Scripts on Slot")
	script_list = right
	status = Label.new()
	status.add_theme_color_override("font_color", MUTED)
	status.add_theme_font_size_override("font_size", 13)
	root.add_child(status)

func _pane(parent: Node, heading: String) -> VBoxContainer:
	var wrap := PanelContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var paper := StyleBoxFlat.new()
	paper.bg_color = PAPER
	paper.border_color = LINE
	paper.set_border_width_all(1)
	paper.set_content_margin_all(12)
	wrap.add_theme_stylebox_override("panel", paper)
	parent.add_child(wrap)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	wrap.add_child(col)
	var label := Label.new()
	label.text = heading
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", INK)
	col.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	return list

func _action(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func refresh(object: Dictionary) -> void:
	var resources = object.get("resources", {})
	var next := ""
	if resources is Dictionary and resources.get("target") != null:
		next = str(resources.target.instance_id)
	elif not app.selected_id.is_empty() and app.objects.has(app.selected_id):
		next = app.selected_id
	if next != target_id and not next.is_empty() and resources is Dictionary:
		# Keep shared target in sync with selection when empty.
		if resources.get("target") == null and app.objects.has(next):
			manager.edit(panel_id, "resources_target", app.address_of(app.objects[next]))
	target_id = next
	rebuild_slots()
	rebuild_scripts()
	var can := app.editable and not target_id.is_empty() and app.objects.has(target_id) and pending_id.is_empty()
	blank_button.disabled = not can or script_count() >= 4
	graph_button.disabled = blank_button.disabled
	open_button.disabled = target_id.is_empty()
	if target_id.is_empty():
		status.text = "ワールドで Slot を選んでから Script を追加してください。"
	elif not app.editable:
		status.text = "編集できません。"
	else:
		status.text = ""

func script_count() -> int:
	return app.objects.get(target_id, {}).get("scripts", []).size()

func rebuild_slots() -> void:
	for child in slot_list.get_children(): child.queue_free()
	add_slot_children("", 0)

func add_slot_children(parent_id: String, depth: int) -> void:
	var ids: Array = app.objects.keys()
	ids.sort()
	for id in ids:
		var object: Dictionary = app.objects[id]
		if object.get("panel") != null: continue
		var address: Variant = object.get("parent")
		if (address == null and parent_id != "") or (address != null and str(address.instance_id) != parent_id):
			continue
		add_slot_row(id, depth)
		add_slot_children(id, depth + 1)

func add_slot_row(id: String, depth: int) -> void:
	if not app.objects.has(id): return
	var object: Dictionary = app.objects[id]
	var row := Button.new()
	row.focus_mode = Control.FOCUS_NONE
	row.toggle_mode = true
	row.button_pressed = id == target_id
	var name_text := str(manager.field_data(id, "name").get("value", id))
	var count: int = object.get("scripts", []).size()
	var indent := ""
	for _i in depth: indent += "  "
	row.text = "%s%s  (%d)" % [indent, name_text.left(28), count]
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.pressed.connect(func():
		if not app.objects.has(id): return
		manager.edit(panel_id, "resources_target", app.address_of(app.objects[id]))
		app.select_object(id)
	)
	slot_list.add_child(row)

func rebuild_scripts() -> void:
	for child in script_list.get_children(): child.queue_free()
	if target_id.is_empty() or not app.objects.has(target_id):
		var empty := Label.new()
		empty.text = "Slot 未選択"
		empty.add_theme_color_override("font_color", MUTED)
		script_list.add_child(empty)
		return
	var scripts: Array = app.objects[target_id].get("scripts", [])
	if scripts.is_empty():
		var empty := Label.new()
		empty.text = "まだ Script がありません"
		empty.add_theme_color_override("font_color", MUTED)
		script_list.add_child(empty)
		return
	for script in scripts:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		script_list.add_child(row)
		var label := Label.new()
		label.text = "%s · %s" % [str(script.schema.name), "Running" if script.get("enabled", false) else "Paused"]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_color_override("font_color", INK)
		row.add_child(label)
		var edit := Button.new()
		edit.text = "開く"
		edit.focus_mode = Control.FOCUS_NONE
		var script_id := str(script.id)
		edit.pressed.connect(func():
			selected_script = script_id
			manager.open_script_editor(target_id, script_id)
		)
		row.add_child(edit)

func attach_blank() -> void:
	if target_id.is_empty() or not app.editable: return
	var names: Array = app.objects.get(target_id, {}).get("scripts", []).map(func(c): return c.schema.name)
	var number := 1
	while names.has("Script%d" % number): number += 1
	var source := "return {\n    name = \"Script%d\",\n    fields = {},\n    drive = function(ctx)\n        -- Derive values with ctx:drive. Use ctx.time or ctx.world_time.\n    end\n}\n" % number
	send_attach(source)

func attach_graph() -> void:
	if target_id.is_empty() or not app.editable: return
	var names: Array = app.objects.get(target_id, {}).get("scripts", []).map(func(c): return c.schema.name)
	var number := 1
	while names.has("Graph%d" % number): number += 1
	var graph = SCRIPT_GRAPH.new()
	graph.fresh("Graph%d" % number)
	send_attach(graph.source())

func send_attach(source: String) -> void:
	if not pending_id.is_empty(): return
	status.text = "追加しています…"
	pending_id = app.requests.request({"kind":"script","command":{"action":"attach","target":app.address_of(app.objects[target_id]),"source":source}}, func(body):
		pending_id = ""
		if body.get("ok", false):
			status.text = "Script を追加しました。"
		else:
			status.text = body.get("message", "追加できませんでした。")
	)

func open_editor() -> void:
	if target_id.is_empty(): return
	manager.open_script_editor(target_id, selected_script)

func finish_all() -> void:
	pass

func has_active_edits() -> bool:
	return not pending_id.is_empty()

func disconnected() -> void:
	pending_id = ""
