extends PanelContainer
const SHARED_SCRIPT_VIEW = preload("res://shared_script_view.gd")
const INSPECTOR_TREE = preload("res://inspector_tree.gd")
const REFERENCE_CHIP = preload("res://reference_chip.gd")
const PRIMITIVES = preload("res://primitive_mesh.gd")
## One inspector instance. Selection, drafts and requests never use the HUD's singleton state.
var manager
var script_view
var script_mount: MarginContainer
var tabs := TabBar.new()
var pending_shared_tab := -1
var panel_id := ""
var target_id := ""
var panel_state: Dictionary = {}
var controls: Dictionary = {}
var edits: Dictionary = {}
var filling := false
var title := Label.new()
var target_picker := OptionButton.new()
var scroll := ScrollContainer.new()
var fields_box := VBoxContainer.new()
var message := Label.new()
var picker_ids: Array[String] = []
var picker_signature: Array = []
var built := false
var scroll_pending := -1.0
var scroll_inflight := false
var scroll_due := 0
var remote_fields: Dictionary = {}
var drive_render_signature: Array = []
var sessions_signature: Array = []
var driven_values_signature: Dictionary = {}
var target_change_pending := false
var pending_target: Variant = null
var close_when_ready := false
var field_container: VBoxContainer
var drive_labels: Dictionary = {}
var drive_buttons: Dictionary = {}
var field_signature: Array = []
var requested_script := ""
var pending_driver_owner := ""
var pending_driver_script := ""
var hierarchy
var input_client_id := ""
var desktop := false
var building_field: Dictionary = {}
var reference_chips: Dictionary = {}
var pending_field := ""
var pending_reference_target := ""
var reference_values: Dictionary = {}
var component_shape_picker: OptionButton
var component_remove_buttons: Dictionary = {}
var component_actions := VBoxContainer.new()
var component_catalog := VBoxContainer.new()
var component_catalog_buttons: Dictionary = {}
var component_catalog_open := false
var component_catalog_toggle: Button
var component_search: LineEdit

func setup(controller, id: String, in_desktop: bool = false) -> void:
	manager = controller
	panel_id = id
	desktop = in_desktop
	input_client_id = manager.client_id + "/" + str(get_instance_id())
	theme = Theme.new()
	theme.default_font_size = 17 if desktop else 26
	var style := StyleBoxFlat.new()
	style.bg_color = Color("15212e")
	style.border_color = Color("5ac8c5")
	style.set_border_width_all(0 if desktop else 3)
	style.set_corner_radius_all(0 if desktop else 10)
	add_theme_stylebox_override("panel", style)
	build_layout()
	connect_view()
	AppLanguage.language_changed.connect(refresh_language)

func build_layout() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]: margin.add_theme_constant_override("margin_"+side, 16)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6 if desktop else 12)
	margin.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	title.text = "Inspector"
	title.add_theme_font_size_override("font_size", 27)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	if not desktop:
		add_button(header, "ピン", func(): manager.toggle_pin(panel_id)).tooltip_text = "画面の2D表示と、掴める3Dの板を切り替える。2Dも同じインスペクタです。板は物体一覧や階層には出ません"
	add_button(header, "+", func(): manager.duplicate_panel(panel_id))
	add_button(header, "↗", func(): manager.open_inspector(target_id, true)).tooltip_text = "Inspect this object in a separate local window"
	add_button(header, "×", func(): manager.close_panel(panel_id)).tooltip_text = "Delete this shared inspector for everyone"
	column.add_child(target_picker)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	build_actions(actions)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	build_body(body)
	column.add_child(message)

func connect_view() -> void:
	target_picker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	target_picker.item_selected.connect(func(index: int):
		if filling or index >= picker_ids.size(): return
		finish_all()
		var id_value: String = picker_ids[index]
		var target: Variant = manager.app.address_of(manager.app.objects[id_value]) if manager.app.objects.has(id_value) else null
		pending_target = target
		target_change_pending = true)
	scroll.get_v_scroll_bar().value_changed.connect(on_scroll)
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.add_theme_font_size_override("font_size", 16 if desktop else 18)
	message.text = ""

func build_actions(actions: Container) -> void:
	add_button(actions, "Select / Gizmo", func():
		if not target_id.is_empty(): manager.app.select_object(target_id))
	add_button(actions, "New 2D window" if desktop else "New 3D panel", func(): manager.open_inspector(target_id, desktop))
	var receiver = REFERENCE_CHIP.new()
	receiver.manager = manager
	receiver.text = "Drop reference"
	receiver.custom_minimum_size.x = 155
	receiver.accepts = func(data): return data is Dictionary and data.get("kind") == "kokoverse_reference"
	receiver.received = func(data):
		var reference: Dictionary = data.reference
		pending_field = reference.get("field_id", "")
		pending_reference_target = str(reference.target.instance_id)
		choose_target(str(reference.target.instance_id))
	receiver.tooltip_text = "Drop a Slot, component or field reference to inspect its object"
	actions.add_child(receiver)

func build_body(body: Container) -> void:
	hierarchy = INSPECTOR_TREE.new()
	hierarchy.setup(self)
	body.add_child(hierarchy)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(details)
	tabs.add_tab("Object")
	tabs.add_tab("Scripts")
	tabs.tab_changed.connect(select_tab)
	details.add_child(tabs)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	details.add_child(scroll)
	fields_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fields_box.add_theme_constant_override("separation", 10)
	scroll.add_child(fields_box)
	script_mount = MarginContainer.new()
	script_mount.size_flags_vertical = Control.SIZE_EXPAND_FILL
	details.add_child(script_mount)
	script_mount.hide()
	script_view = SHARED_SCRIPT_VIEW.new()
	script_view.setup(manager,panel_id,script_mount)

func add_button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func heading(text: String) -> void:
	var label = REFERENCE_CHIP.new() if not building_field.is_empty() else Label.new()
	label.text = text
	if label is Label: label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		label.manager = manager
		label.flat = true
		label.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var field := str(building_field.id)
		label.payload = func(): return {"kind":"kokoverse_reference","reference":{"kind":"field","target":manager.app.field_address(target_id,field),"field_id":field}}
		label.value_payload = func():
			var data: Dictionary = manager.field_data(target_id,field)
			return {"kind":"kokoverse_value","value_type":data.value_type,"value":data.value}
		label.accepts = func(data): return data is Dictionary and data.get("kind") == "kokoverse_value" and data.get("value_type") in ["string","vec3","quat","color"] and data.get("value_type") == manager.field_data(target_id,field).get("value_type") and controls.has(field) and manager.field_driver(target_id,field).is_empty()
		label.received = func(data): apply_dropped_value(field,data.value)
		label.tooltip_text = "Drag / Ctrl+RMB: field reference · Add Shift: copy shared value"
		reference_chips[field] = label
	label.add_theme_color_override("font_color", Color("9cc6d4"))
	field_container.add_child(label)

func line_field(parent: Node, field: String, part: String) -> LineEdit:
	var line := LineEdit.new()
	line.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	line.custom_minimum_size = Vector2(0, 30 if desktop else 44)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.max_length = 80 if field in ["name", "world_text", "value_text"] else 32
	line.set_meta("field", field)
	line.set_meta("part", part)
	parent.add_child(line)
	if not controls.has(field): controls[field] = []
	controls[field].append(line)
	line.focus_entered.connect(func(): start_edit(field, line))
	line.focus_exited.connect(func():
		if edits.has(field): edits[field].release = true)
	line.text_changed.connect(func(_text): changed(field, line))
	line.text_submitted.connect(func(_text): line.release_focus())
	return line

func vector_field(field: String, label: String, parts: Array) -> void:
	heading(label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	field_container.add_child(row)
	for i in range(parts.size()):
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(column)
		var axis := Label.new()
		axis.text = parts[i]
		axis.add_theme_font_size_override("font_size", 18)
		column.add_child(axis)
		line_field(column, field, str(i))

func build_fields() -> void:
	if component_actions.get_parent() == fields_box: fields_box.remove_child(component_actions)
	for child in fields_box.get_children():
		fields_box.remove_child(child)
		child.queue_free()
	controls.clear()
	drive_labels.clear()
	drive_buttons.clear()
	drive_render_signature.clear()
	sessions_signature.clear()
	driven_values_signature.clear()
	reference_chips.clear()
	reference_values.clear()
	for child in component_actions.get_children():
		component_actions.remove_child(child)
		if child != component_catalog: child.queue_free()
	for child in component_catalog.get_children():
		component_catalog.remove_child(child)
		child.queue_free()
	component_shape_picker = null
	component_catalog_toggle = null
	component_search = null
	component_catalog_buttons.clear()
	component_remove_buttons.clear()
	building_field = {}
	field_container = fields_box
	if target_id.is_empty() or not manager.app.objects.has(target_id):
		heading("Choose an object above. Deleted targets are cleared.")
		return
	var object: Dictionary = manager.app.objects[target_id]
	fields_box.add_child(component_actions)
	build_component_actions(object)
	for schema in manager.component_schemas:
		var fields: Array = object.fields.filter(func(field): return int(field.component_id) == int(schema.local_id))
		if fields.is_empty(): continue
		if schema.type_id == "MediaPlayback" and object.get("playback") == null: continue
		component_section(str(schema.type_id),int(schema.local_id),schema.get("attach_defaults") != null)
		for field in fields: build_field(field)
	building_field = {}
	component_section("Scripts",8)
	if object.get("scripts", []).is_empty(): heading("No scripts attached")
	for script in object.get("scripts", []):
		var row := HBoxContainer.new()
		field_container.add_child(row)
		var label := Label.new()
		AppLanguage.format_text(label, "%s · Running" if script.enabled else "%s · Paused", [script.schema.name])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_size_override("font_size", 21)
		row.add_child(label)
		add_button(row, "Edit", open_script.bind(str(script.id)))
	add_button(field_container, "Manage scripts", open_script.bind(""))

func build_component_actions(object: Dictionary) -> void:
	component_actions.visible = object.get("panel") == null
	if object.get("panel") != null: return
	component_catalog_toggle = add_button(component_actions, "+ Add Component" if not component_catalog_open else "− Close Component List", func():
		component_catalog_open = not component_catalog_open
		build_fields())
	component_catalog_toggle.tooltip_text = "Add a registered component to this Slot"
	component_actions.add_child(component_catalog)
	component_catalog.visible = component_catalog_open
	if not component_catalog_open: return
	component_search = LineEdit.new()
	component_search.placeholder_text = "Find component…"
	component_catalog.add_child(component_search)
	component_search.text_changed.connect(filter_component_catalog)
	component_shape_picker = OptionButton.new()
	for index in PRIMITIVES.SHAPES.size(): component_shape_picker.add_item(PRIMITIVES.NAMES[index])
	component_shape_picker.select(PRIMITIVES.SHAPES.find("quad"))
	var shape_row := HBoxContainer.new()
	component_catalog.add_child(shape_row)
	var shape_label := Label.new()
	shape_label.text = "Mesh shape"
	shape_row.add_child(shape_label)
	shape_row.add_child(component_shape_picker)
	for schema in manager.component_schemas:
		if schema.get("attach_defaults") == null: continue
		var type_id := str(schema.type_id)
		var row := HBoxContainer.new()
		component_catalog.add_child(row)
		var button := add_button(row, "+ " + type_id, change_component.bind(type_id, true))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var present: bool = object.fields.any(func(field): return int(field.component_id) == int(schema.local_id))
		var motion_ready: bool = object.get("parent") == null and object.get("renderer") != null and object.get("collider") != null and object.collider.get("solid", false)
		button.disabled = not manager.app.editable or present or (type_id == "Mirror" and not mirror_surface(object)) or (type_id == "PlanarMotion" and not motion_ready)
		button.tooltip_text = "Already attached" if present else ("Needs a Quad or Mirror mesh" if type_id == "Mirror" and not mirror_surface(object) else ("Needs a root Slot with a renderer and solid Collider" if type_id == "PlanarMotion" and not motion_ready else ""))
		component_catalog_buttons[type_id] = button

func filter_component_catalog(query: String) -> void:
	for type_id in component_catalog_buttons:
		component_catalog_buttons[type_id].get_parent().visible = query.is_empty() or str(type_id).to_lower().contains(query.to_lower()) or tr(str(type_id)).to_lower().contains(query.to_lower())

func mirror_surface(object: Dictionary) -> bool:
	return object.get("visual",{}).get("kind","") == "primitive" and object.visual.get("shape","") in ["quad","mirror"]

func change_component(type_id: String, add: bool) -> void:
	if not manager.app.editable or not manager.app.objects.has(target_id): return
	var object: Dictionary = manager.app.objects[target_id]
	if object.get("panel") != null: return
	var schema: Dictionary = {}
	for candidate in manager.component_schemas:
		if candidate.type_id == type_id: schema = candidate; break
	if schema.is_empty() or schema.get("attach_defaults") == null: return
	var present: bool = object.fields.any(func(field): return int(field.component_id) == int(schema.local_id))
	if present == add or (add and type_id == "Mirror" and not mirror_surface(object)): return
	if add and type_id == "PlanarMotion" and (object.get("parent") != null or object.get("renderer") == null or object.get("collider") == null or not object.collider.get("solid", false)): return
	if not add and type_id == "MeshRenderer" and (object.get("panel") != null or object.get("playback") != null or object.get("mirror") != null or object.get("planar_motion") != null or not object.get("scripts",[]).is_empty()): return
	var command: Dictionary = {"action":"add_component" if add else "remove_component", "target":manager.app.address_of(object), "type_id":type_id, "expected_revision":object.object_revision}
	if add:
		command["values"] = schema.attach_defaults.duplicate(true)
		if type_id == "MeshRenderer": command["values"]["visual"]["shape"] = PRIMITIVES.SHAPES[component_shape_picker.selected]
	message.text = ""
	manager.command({"kind":"structure", "command":command}, func(result):
		if not result.ok: message.text = result.get("message", "Could not change component")
		elif add:
			component_catalog_open = false
			build_fields())

func component_section(name: String, component_id: int = 0, removable: bool = false) -> void:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 6)
	fields_box.add_child(section)
	var rule := HSeparator.new()
	section.add_child(rule)
	var label = REFERENCE_CHIP.new()
	label.manager = manager
	label.text = name
	label.flat = true
	label.alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.payload = func(): return {"kind":"kokoverse_reference","reference":{"kind":"component","target":{"instance_id":target_id,"local_id":component_id}}}
	label.tooltip_text = "Drag / Ctrl+RMB: component reference"
	label.add_theme_font_size_override("font_size", 19 if desktop else 23)
	label.add_theme_color_override("font_color", Color("5ac8c5"))
	var header := HBoxContainer.new()
	section.add_child(header)
	header.add_child(label)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if removable and manager.app.editable:
		var remove_button := add_button(header, "Remove", change_component.bind(name, false))
		remove_button.disabled = name == "MeshRenderer" and (manager.app.objects[target_id].get("panel") != null or manager.app.objects[target_id].get("playback") != null or manager.app.objects[target_id].get("mirror") != null or manager.app.objects[target_id].get("planar_motion") != null or not manager.app.objects[target_id].get("scripts",[]).is_empty())
		remove_button.tooltip_text = "Remove dependent components first" if remove_button.disabled else "Remove this component"
		component_remove_buttons[name] = remove_button
	field_container = section

func build_field(field: Dictionary) -> void:
		building_field = field
		match field.value_type:
			"address":
				heading(field.label)
				var reference = REFERENCE_CHIP.new()
				reference.manager = manager
				reference.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
				reference.text = tr("World") if field.value == null else str(manager.field_data(field.value.instance_id,"name").get("value",tr("Deleted Slot")))
				reference_values[field.id] = reference
				reference.payload = func():
					var value: Variant = manager.field_data(target_id,field.id).value
					return null if value == null else {"kind":"kokoverse_reference","reference":{"kind":"slot","target":value}}
				reference.pressed.connect(func():
					var value: Variant = manager.field_data(target_id,field.id).value
					if value != null: manager.open_inspector(value.instance_id, desktop))
				if field.id == "parent":
					reference.accepts = func(data): return data is Dictionary and data.get("kind") == "kokoverse_reference" and data.get("reference",{}).get("kind") == "slot"
					reference.received = func(data): hierarchy.move_object(target_id,data.reference.target.instance_id)
				field_container.add_child(reference)
			"inspector_tree":
				pass
			"string":
				heading(field.label)
				line_field(field_container, field.id, "0")
			"number":
				heading(field.label)
				line_field(field_container, field.id, "0")
			"bool":
				var check := CheckBox.new()
				check.text = field.label
				check.focus_mode = Control.FOCUS_NONE
				field_container.add_child(check)
				controls[field.id] = [check]
				check.toggled.connect(func(_enabled): changed(field.id, check, true))
			"vec3": vector_field(field.id, field.label, ["X", "Y", "Z"])
			"quat":
				vector_field(field.id, "", ["X", "Y", "Z"])
				AppLanguage.format_text(reference_chips[field.id], "%s · degrees", [tr(field.label)])
			"vec4": vector_field(field.id, field.label, ["min X", "max X", "min Z", "max Z"])
			"color": vector_field(field.id, field.label, ["R", "G", "B", "A"])
			"collider":
				heading("Collider")
				var row := HBoxContainer.new()
				field_container.add_child(row)
				controls[field.id] = []
				for label in ["Enabled / grabbable", "Solid"]:
					var check := CheckBox.new()
					check.text = label
					check.focus_mode = Control.FOCUS_NONE
					row.add_child(check)
					controls[field.id].append(check)
					check.toggled.connect(func(_enabled): changed(field.id, check, true))
				vector_field(field.id, "Collider half extents", ["X", "Y", "Z"])
			"playback":
				if field.value is Dictionary:
					heading("Video · shared playback")
					var row := HBoxContainer.new()
					field_container.add_child(row)
					add_button(row, "Play", func(): playback("play"))
					add_button(row, "Pause", func(): playback("pause"))
					add_button(row, "Restart", func(): playback("restart"))
			_:
				heading("")
				AppLanguage.format_text(reference_chips[field.id], "%s · %s", [tr(field.label), JSON.stringify(field.value)])
		if field.id in ["position", "rotation", "scale", "color", "world_text", "world_text_color", "value_number", "value_bool", "value_text"]:
			var info := Label.new()
			info.add_theme_font_size_override("font_size", 18)
			info.add_theme_color_override("font_color", Color("c5a5ed"))
			info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			field_container.add_child(info)
			drive_labels[field.id] = info
			var button := add_button(field_container, "", open_driver.bind(str(field.id)))
			button.add_theme_font_size_override("font_size", 20)
			drive_buttons[field.id] = button

func open_driver(field: String) -> void:
	var driver: Dictionary = manager.field_driver(target_id, field)
	if driver.is_empty(): return
	var owner: String = str(driver.get("owner_id", target_id))
	if owner == target_id: open_script(str(driver.id))
	else:
		pending_driver_owner = owner
		pending_driver_script = str(driver.id)
		choose_target(owner)

func open_script(id: String) -> void:
	finish_all()
	requested_script = id if not id.is_empty() else "*"

func choose_target(id: String) -> void:
	finish_all()
	pending_target = manager.app.address_of(manager.app.objects[id]) if manager.app.objects.has(id) else null
	target_change_pending = true

func value_text(value: Variant, kind: String) -> String:
	if kind == "quat" and value is Array:
		var angles := Quaternion(value[0],value[1],value[2],value[3]).get_euler()
		return "%.1f°, %.1f°, %.1f°" % [rad_to_deg(angles.x),rad_to_deg(angles.y),rad_to_deg(angles.z)]
	if value is Array:
		return ", ".join(value.map(func(v): return String.num(float(v), 3)))
	return str(value)

func apply_dropped_value(field: String, value: Variant) -> void:
	if not controls.has(field) or not manager.field_driver(target_id,field).is_empty(): return
	var data: Dictionary = manager.field_data(target_id,field)
	filling = true
	var values: Variant = value
	if data.value_type == "quat":
		var angles := Quaternion(value[0],value[1],value[2],value[3]).get_euler()
		values = [rad_to_deg(angles.x),rad_to_deg(angles.y),rad_to_deg(angles.z)]
	for i in controls[field].size():
		if controls[field][i] is LineEdit:
			controls[field][i].text = str(values[i]) if values is Array else str(values)
	filling = false
	changed(field,controls[field][0],true)

func refresh_drives(stop_driven_edits: bool = true) -> void:
	# Compose what each field's drive UI should show and write only
	# the controls whose rendered state actually changed. The label
	# depends on the driver's enabled flag and the field's shared
	# base value, both of which change on edits — not per frame — so
	# steady-state ticks now do no control writes at all. The
	# signature holds the format_text inputs (source + values); a
	# locale change re-renders through AppLanguage's bindings and
	# needs no signature change.
	var previous: Dictionary = {}
	for entry in drive_render_signature: previous[entry[0]] = entry
	var rendered: Array = []
	for field in drive_labels:
		var driver: Dictionary = manager.field_driver(target_id, field)
		if driver.is_empty():
			rendered.append([field, false, "", [], "", []])
			continue
		var data: Dictionary = manager.field_data(target_id, field)
		rendered.append([field, true,
			"Local Drive · running\nShared base: %s" if driver.enabled else "Local Drive · paused\nShared base: %s", [value_text(data.value, data.value_type)],
			"Open %s →", [driver.schema.name]])
		# A driven field's shared draft is meaningless; release it.
		# These are cheap flag writes, kept unconditional as before —
		# only the control writes below are signature-gated.
		if stop_driven_edits and edits.has(field):
			edits[field].dirty = false
			edits[field].release = true
	for entry in rendered:
		var field: String = entry[0]
		var prev: Array = previous.get(field, [])
		if entry == prev: continue
		drive_labels[field].visible = entry[1]
		drive_buttons[field].visible = entry[1]
		if not entry[1]: continue
		AppLanguage.format_text(drive_labels[field], entry[2], entry[3])
		AppLanguage.format_text(drive_buttons[field], entry[4], entry[5])
	drive_render_signature = rendered

func playback(action: String) -> void:
	var field: Dictionary = manager.field_data(target_id, "playback")
	if field.is_empty(): return
	manager.command({"kind":"playback","command":{"target":manager.app.address_of(manager.app.objects[target_id]),"expected_revision":field.revision,"action":action}})

func refresh(object: Dictionary) -> void:
	panel_state = object
	filling = true
	var entries: Array = []
	# Rebuild key: each object's name-field revision. Rust bumps a field's
	# revision on every write, so the key changes exactly when the listed
	# (id, name) pairs do — without stringifying every object's name.
	var picker_key: Array = []
	for id in manager.app.objects:
		if manager.app.objects[id].get("inspector") != null: continue
		var name_field: Dictionary = manager.field_data(id, "name")
		entries.append([id, name_field.get("value", id)])
		picker_key.append([id, str(name_field.get("revision", ""))])
	if picker_key != picker_signature:
		picker_signature = picker_key
		target_picker.clear()
		picker_ids.clear()
		target_picker.add_item(tr("Choose object…"))
		picker_ids.append("")
		for entry in entries:
			target_picker.add_item(entry[1])
			picker_ids.append(entry[0])
	var new_target: String = object.inspector.target.instance_id if object.inspector.get("target") != null else ""
	var inspected: Dictionary = manager.app.objects.get(new_target, {})
	# Structure key compared as data (deep equality) instead of a JSON
	# string; every leaf is a scalar, so this matches comparing the
	# stringified form while skipping the serialization.
	# The schema set is part of the build key: schemas arrive separately
	# (the catalog message) and can land after the first snapshot, so a
	# view built while they were still empty must rebuild once they
	# arrive even though the inspected object itself did not change.
	var next_signature: Array = [inspected.get("fields", []).map(func(f): return [f.component_id,f.id,f.value_type]),inspected.get("scripts", []).map(func(s): return [s.id,s.schema.name,s.enabled]),manager.component_schemas.map(func(s): return [int(s.local_id),str(s.type_id),s.get("attach_defaults") != null])]
	if new_target != target_id or not built or (next_signature != field_signature and edits.is_empty()):
		for field in edits:
			# A target switch ends the old lease; never redirect a draft to the new target.
			manager.session_input(panel_id, target_id, field, "end", {}, Callable(), input_client_id)
		edits.clear()
		scroll_pending = -1.0
		target_id = new_target
		field_signature = next_signature
		build_fields()
		built = true
	target_picker.select(maxi(0, picker_ids.find(target_id)))
	if hierarchy != null: hierarchy.refresh()
	fill_values()
	refresh_drives()
	restore_scroll(object)
	filling = false
	refresh_sessions()
	if not pending_field.is_empty() and target_id == pending_reference_target and not target_change_pending and reference_chips.has(pending_field):
		scroll.ensure_control_visible(reference_chips[pending_field])
		pending_field = ""
	refresh_pages(object)

func refresh_pages(object: Dictionary) -> void:
	var show_scripts: bool = object.inspector.get("scripts_open",false)
	tabs.set_block_signals(true)
	tabs.current_tab = 1 if show_scripts else 0
	tabs.set_block_signals(false)
	script_mount.visible = show_scripts
	component_actions.visible = manager.app.objects.get(target_id, {}).get("panel") == null
	scroll.visible = not show_scripts
	script_view.active = show_scripts
	if show_scripts: script_view.refresh(target_id, object.inspector.get("script_id"))

func select_tab(index: int) -> void:
	finish_all()
	pending_shared_tab = index

func restore_scroll(object: Dictionary) -> void:
	var bar := scroll.get_v_scroll_bar()
	if scroll_pending < 0 and not scroll_inflight:
		scroll.scroll_vertical = int(float(object.inspector.scroll[1]) * maxf(0.0, bar.max_value - bar.page))

func fill_reference_values() -> void:
	for field in reference_values:
		var value: Variant = manager.field_data(target_id,field).get("value")
		reference_values[field].text = tr("World") if value == null else str(manager.field_data(value.instance_id,"name").get("value",tr("Deleted Slot")))

## The edit session another participant holds on this field, if any.
## Derived from the current session list on every call, so callers
## never act on a stale copy.
func remote_session(field: String) -> Dictionary:
	var remote: Dictionary = {}
	for session in manager.sessions:
		var context: Variant = session.get("context")
		var same_context: bool = context == null if desktop else context != null and context.source.instance_id == panel_id
		if session.target.instance_id == target_id and session.field_id == field and (session.client_id != input_client_id or not same_context):
			remote = session
	return remote

func fill_values() -> void:
	fill_reference_values()
	for field in controls:
		if edits.has(field): continue
		# A field under a remote edit session displays that editor's
		# draft, not the shared value. refresh() fills before
		# refresh_sessions() runs, and the session render is gated on
		# its signature — if filling stomped the draft here, nothing
		# would reapply it while the session state stays unchanged.
		if not remote_session(field).is_empty(): continue
		var data: Dictionary = manager.field_data(target_id, field)
		if data.is_empty(): continue
		var value: Variant = manager.app.driven_objects.get(target_id, {}).get(field, data.value)
		var parts: Array = controls[field]
		if field == "collider":
			parts[0].button_pressed = value != null
			parts[1].button_pressed = value != null and value.solid
			for i in range(3): parts[i+2].text = String.num(float(value.half_extents[i]) if value != null else 0.5, 4)
		elif data.value_type == "string": parts[0].text = str(value)
		elif data.value_type == "number": parts[0].text = String.num(float(value), 4)
		elif data.value_type == "bool": parts[0].button_pressed = value == true
		elif data.value_type == "quat":
			var angles := Quaternion(value[0],value[1],value[2],value[3]).get_euler()
			for i in range(3): parts[i].text = String.num(rad_to_deg(angles[i]), 3)
		elif value is Array:
			for i in range(parts.size()): parts[i].text = String.num(float(value[i]), 4)

func start_edit(field: String, control: Control, one_shot: bool = false) -> void:
	if filling or not manager.app.editable or target_id.is_empty(): return
	if not manager.field_driver(target_id, field).is_empty(): return
	if edits.has(field):
		edits[field].release = one_shot
		return
	var data: Dictionary = manager.field_data(target_id, field)
	if data.is_empty(): return
	edits[field] = {"granted":false,"dirty":false,"inflight":false,"release":one_shot,"revision":str(data.revision),"due":0,"heartbeat":0,"control":control,"value":null}
	manager.session_input(panel_id, target_id, field, "begin", draft_for(control), on_lease.bind(field), input_client_id)

func draft_for(control: Control) -> Dictionary:
	if control is LineEdit:
		var selection: Array = [control.get_selection_from_column(),control.get_selection_to_column()] if control.has_selection() else [control.caret_column,control.caret_column]
		return {"part":str(control.get_meta("part")),"text":control.text,"caret":control.caret_column,"selection":selection}
	return {"part":"check","text":"","caret":0,"selection":[0,0]}

func on_lease(result: Dictionary, field: String) -> void:
	if not edits.has(field): return
	if result.ok:
		edits[field].granted = true
		edits[field].heartbeat = Time.get_ticks_msec()
	else:
		edits.erase(field)
		message.text = str(result.get("message", "Another editor is using this field"))
	refresh_sessions()

func changed(field: String, control: Control, one_shot: bool = false) -> void:
	if filling: return
	start_edit(field, control, one_shot)
	if not edits.has(field): return
	edits[field].control = control
	edits[field].due = Time.get_ticks_msec() + 180
	var parsed := read_value(field)
	edits[field].dirty = parsed.ok
	edits[field].value = parsed.value

func read_value(field: String) -> Dictionary:
	var parts: Array = controls[field]
	var type: String = manager.field_data(target_id, field).get("value_type", "")
	if type == "string": return {"ok":field != "name" or not parts[0].text.strip_edges().is_empty(),"value":parts[0].text}
	if type == "bool": return {"ok":true,"value":parts[0].button_pressed}
	if type == "collider" and not parts[0].button_pressed: return {"ok":true,"value":null}
	var values := []
	for control in parts:
		if not control is LineEdit: continue
		if not control.text.is_valid_float(): return {"ok":false,"value":null}
		values.append(control.text.to_float())
	if type == "quat":
		var q := Quaternion.from_euler(Vector3(deg_to_rad(values[0]),deg_to_rad(values[1]),deg_to_rad(values[2])))
		return {"ok":true,"value":[q.x,q.y,q.z,q.w]}
	if type == "collider": return {"ok":true,"value":{"solid":parts[1].button_pressed,"half_extents":values}}
	if type == "number": return {"ok":true,"value":values[0]}
	return {"ok":true,"value":values}

func edit_result(result: Dictionary, field: String) -> void:
	if not edits.has(field): return
	edits[field].inflight = false
	if result.ok:
		edits[field].revision = str(manager.field_data(target_id, field).get("revision", edits[field].revision))
		message.text = "Shared change applied"
	else:
		edits[field].dirty = false
		edits[field].release = true
		message.text = str(result.get("message", "Edit rejected"))

func tick() -> void:
	script_view.tick()
	refresh_drives()
	# Driven values reach the input fields only when the target's
	# driven values actually changed; a running Drive changes them
	# per frame (fill as before), a paused or absent one leaves the
	# fields — and the user's caret — alone.
	if not drive_labels.is_empty():
		var driven: Dictionary = manager.app.driven_objects.get(target_id, {})
		if driven != driven_values_signature:
			driven_values_signature = driven.duplicate(true)
			filling = true
			fill_values()
			filling = false
	if not manager.app.editable: return
	var now := Time.get_ticks_msec()
	if scroll_pending >= 0 and not scroll_inflight and now >= scroll_due:
		var value := scroll_pending
		scroll_pending = -1.0
		scroll_inflight = true
		write_view_field("panel_scroll", [0.0,value], func(result):
			scroll_inflight = false
			if not result.ok: message.text = "Scroll changed elsewhere; scroll again")
	for field in edits.keys():
		var state: Dictionary = edits[field]
		if not state.granted: continue
		if state.dirty and not state.inflight and now >= state.due:
			state.dirty = false
			state.inflight = true
			manager.edit(target_id, field, state.value, edit_result.bind(field), state.revision)
		if state.release and not state.dirty and not state.inflight:
			manager.session_input(panel_id, target_id, field, "end", {}, Callable(), input_client_id)
			edits.erase(field)
			continue
		if now - state.heartbeat >= 120:
			state.heartbeat = now
			manager.session_input(panel_id, target_id, field, "update", draft_for(state.control), func(result):
				if not result.ok and edits.has(field):
					edits.erase(field)
					message.text = str(result.get("message", "Editing expired")), input_client_id)
	if edits.is_empty() and not script_view.busy() and close_when_ready:
		close_when_ready = false
		manager.close_panel(panel_id)
		return
	if edits.is_empty() and not script_view.busy() and target_change_pending:
		target_change_pending = false
		write_view_field("inspector_target", pending_target)
	if not pending_driver_script.is_empty() and target_id == pending_driver_owner and not target_change_pending:
		open_script(pending_driver_script)
		pending_driver_owner = ""
		pending_driver_script = ""
	if edits.is_empty() and not script_view.busy() and pending_shared_tab >= 0:
		var selected := pending_shared_tab
		pending_shared_tab = -1
		write_view_field("inspector_scripts_open", selected == 1)
	if edits.is_empty() and not script_view.busy() and not requested_script.is_empty():
		var id := requested_script
		requested_script = ""
		show_requested_script(id)
	refresh_sessions()

func show_requested_script(id: String) -> void:
	if id == "*": write_view_field("inspector_scripts_open",true)
	else:
		write_view_field("inspector_script_id",id,func(result):
			if result.ok: write_view_field("inspector_scripts_open",true))

func write_view_field(field: String, value: Variant, callback: Callable = Callable()) -> void:
	manager.edit(panel_id, field, value, callback)

func has_active_edits() -> bool:
	return not edits.is_empty() or script_view.busy()

func finish_all() -> void:
	if not script_view.busy(): script_view.leave()
	for field in edits: edits[field].release = true

func disconnected() -> void:
	script_view.disconnected()
	edits.clear()
	scroll_pending = -1.0
	scroll_inflight = false
	target_change_pending = false
	pending_shared_tab = -1
	close_when_ready = false
	message.text = "Disconnected · shared editing paused"
	refresh_sessions()

func refresh_sessions() -> void:
	# Gate on the session-derived state this function renders: for
	# each field, whether it is read-only and the remote draft (if
	# any) down to its text/caret/selection. When none of that
	# changed since the last run, every control write below would
	# repeat the current state — including re-setting the remote
	# draft's text and caret every frame — so skip the run.
	var signature: Array = []
	for field in controls:
		var remote: Dictionary = remote_session(field)
		var readonly: bool = not manager.app.editable or not remote.is_empty() or not manager.field_driver(target_id, field).is_empty()
		var display_name := ""
		if not remote.is_empty():
			var owner: String = str(remote.owner)
			display_name = str(manager.app.participant_names.get("local" if owner.begins_with("local-") else owner, "Another user"))
		var draft: Dictionary = remote.get("draft", {})
		signature.append([field, readonly, str(remote.get("owner", "")), display_name,
			str(draft.get("text", "")), int(draft.get("caret", 0)), draft.get("selection", []), str(draft.get("part", ""))])
	if signature == sessions_signature: return
	sessions_signature = signature
	var previously_remote := not remote_fields.is_empty()
	remote_fields.clear()
	for field in controls:
		var remote: Dictionary = remote_session(field)
		var readonly: bool = not manager.app.editable or not remote.is_empty() or not manager.field_driver(target_id, field).is_empty()
		for control in controls[field]:
			if control is LineEdit: control.editable = not readonly
			elif control is BaseButton: control.disabled = readonly
		if not remote.is_empty():
			remote_fields[field] = true
			var owner: String = str(remote.owner)
			var display_name: String = str(manager.app.participant_names.get("local" if owner.begins_with("local-") else owner, "Another user"))
			AppLanguage.format_text(message, "Editing: %s · %s", [display_name, field])
			for control in controls[field]:
				if control is LineEdit and str(control.get_meta("part")) == str(remote.draft.part):
					filling = true
					control.text = remote.draft.text
					control.caret_column = int(remote.draft.caret)
					control.select(int(remote.draft.selection[0]),int(remote.draft.selection[1]))
					filling = false
	if previously_remote and remote_fields.is_empty():
		filling = true
		fill_values()
		filling = false
		if message.text.begins_with("Editing:") or message.text.begins_with(tr("Editing: ")): message.text = ""

func on_scroll(_value: float) -> void:
	if filling or panel_state.is_empty() or not manager.app.editable: return
	var bar := scroll.get_v_scroll_bar()
	var ratio: float = float(scroll.scroll_vertical) / maxf(1.0, bar.max_value - bar.page)
	scroll_pending = clampf(ratio,0.0,1.0)
	scroll_due = Time.get_ticks_msec() + 80

func refresh_language() -> void:
	if target_picker.item_count > 0: target_picker.set_item_text(0, tr("Choose object…"))
	if built:
		for field in reference_chips:
			var data: Dictionary = manager.field_data(target_id, field)
			if data.get("value_type") == "quat":
				AppLanguage.format_text(reference_chips[field], "%s · degrees", [tr(data.label)])
		# Locale changes only affect reference placeholders, never field
		# drafts, caret positions or controls that emit editing signals.
		fill_reference_values()
		refresh_drives(false)
		if component_search != null: filter_component_catalog(component_search.text)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and script_view != null:
		script_view.dispose()
