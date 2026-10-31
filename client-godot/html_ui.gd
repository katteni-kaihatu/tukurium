extends Node
## Screen HTML for the header and inspector. Shared edits still go through the Engine.

var app
var server := TCPServer.new()
var peer: StreamPeerTCP
var pid := -1
var inbox := ""
var last_state := ""
var last_panel_state := ""
var next_push := 0
var started_msec := 0
var warned := false
var active := false
var notice := ""
var panel_textures: Dictionary = {}
var panel_queue: Array = []
var panel_cursor := 0
var script_cache: Dictionary = {}

func setup(owner) -> void:
	app = owner
	if not wanted(): return
	var exe := host_executable()
	if exe.is_empty():
		print("html-host が無いので、これまでのヘッダーを使います。探した場所: ", repo_root().path_join("target/debug/html-host.exe"))
		return
	var port := 47110
	while server.listen(port) != OK and port < 47140:
		port += 1
	if not server.is_listening():
		print("HTML UI の待受ポートを開けませんでした。")
		return
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE)
	var ui := repo_root().path_join("client-ui")
	pid = OS.create_process(exe, ["--parent", str(hwnd), "--connect", "127.0.0.1:%d" % server.get_local_port(), "--ui", ui])
	started_msec = Time.get_ticks_msec()
	if pid < 0:
		print("html-host を起動できませんでした。")

func wanted() -> bool:
	if OS.get_environment("TUKURIUM_HTML_UI") == "0": return false
	if DisplayServer.get_name() == "headless": return false
	for arg in OS.get_cmdline_args():
		if arg == "--script" or arg.begins_with("--script="): return false
	return true

func host_executable() -> String:
	var repo := repo_root()
	for name in ["target/debug/html-host.exe", "target/release/html-host.exe"]:
		var path := repo.path_join(name)
		if FileAccess.file_exists(path): return path
	return ""

func repo_root() -> String:
	return ProjectSettings.globalize_path("res://").trim_suffix("/").trim_suffix("\\").get_base_dir()

func _process(_delta: float) -> void:
	if pid < 0: return
	if peer == null:
		if server.is_connection_available():
			peer = server.take_connection()
			peer.set_no_delay(true)
			active = true
			app.hud.set_html_chrome(true)
			push(true)
		elif not warned and Time.get_ticks_msec() - started_msec > 8000:
			warned = true
			print("HTML UI に接続できませんでした。これまでのヘッダーを使います。")
		return
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		drop_host()
		return
	read_commands()
	if Time.get_ticks_msec() >= next_push:
		next_push = Time.get_ticks_msec() + 100
		push(false)
		push_panel(false)

func _exit_tree() -> void:
	if peer: peer.disconnect_from_host()
	server.stop()
	if pid >= 0: OS.kill(pid)

func drop_host() -> void:
	if peer: peer.disconnect_from_host()
	peer = null
	active = false
	panel_textures.clear()
	if app and app.hud: app.hud.set_html_chrome(false)

func write_line(text: String) -> void:
	if peer == null: return
	peer.put_data((text + "\n").to_utf8_buffer())

func push(force: bool) -> void:
	var text := JSON.stringify(snapshot())
	if not force and text == last_state: return
	last_state = text
	write_line(text)

func panel_ids() -> Array:
	var ids := []
	for id in app.world_panels.panels.keys():
		if not app.world_panels.panels[id].inspector_content: continue
		if app.world_panels.pinned_to_me(id): continue
		ids.append(id)
	return ids

func push_panel(force: bool) -> void:
	var ids: Array = panel_ids()
	if ids.is_empty():
		last_panel_state = ""
		return
	if panel_cursor >= ids.size(): panel_cursor = 0
	var id := str(ids[panel_cursor])
	panel_cursor = (panel_cursor + 1) % ids.size()
	var payload := {"type": "panel_state", "id": id, "inspector": inspector_model(id, "panel")}
	var text := JSON.stringify(payload)
	if not force and text == last_panel_state: return
	last_panel_state = text
	write_line(text)

func focus_godot() -> void:
	if active: write_line(JSON.stringify({"type": "focus_parent"}))

func panel_pointer(id: String, point: Vector2, event: InputEventMouse) -> void:
	if not active: return
	var message := {
		"type": "panel_pointer",
		"id": id,
		"x": point.x,
		"y": point.y,
		"button": 0,
		"pressed": false,
		"kind": "motion",
		"delta": 0,
	}
	if event is InputEventMouseButton:
		message.kind = "button"
		message.button = event.button_index - 1
		message.pressed = event.pressed
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			message.kind = "wheel"
			message.delta = -120.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 120.0
	write_line(JSON.stringify(message))

func panel_key(id: String, event: InputEventKey) -> void:
	if not active or not event.pressed or event.echo: return
	var key := ""
	match event.keycode:
		KEY_BACKSPACE: key = "Backspace"
		KEY_DELETE: key = "Delete"
		KEY_ENTER, KEY_KP_ENTER: key = "Enter"
		KEY_ESCAPE: key = "Escape"
		_:
			if event.unicode > 0: key = String.chr(event.unicode)
			else: key = OS.get_keycode_string(event.keycode)
	if key.is_empty(): return
	write_line(JSON.stringify({
		"type": "panel_key",
		"id": id,
		"key": key,
		"ctrl": event.ctrl_pressed,
		"alt": event.alt_pressed,
		"meta": event.meta_pressed,
		"shift": event.shift_pressed,
	}))

func texture_for(id: String):
	return panel_textures.get(id, null)

func read_commands() -> void:
	var available := peer.get_available_bytes()
	if available <= 0: return
	inbox += peer.get_utf8_string(available)
	while true:
		var break_at := inbox.find("\n")
		if break_at < 0: return
		var line := inbox.substr(0, break_at).strip_edges()
		inbox = inbox.substr(break_at + 1)
		var message = JSON.parse_string(line)
		if message is Dictionary: handle(message)

func handle(message: Dictionary) -> void:
	match str(message.get("type", "")):
		"panel_frame":
			apply_frame(message)
		"panel_focus":
			app.world_panels.html_text_focus = bool(message.get("focused", false))
			var panel := str(message.get("panel", ""))
			if app.world_panels.html_text_focus and not panel.is_empty():
				app.world_panels.keyboard_id = panel
			elif not app.world_panels.html_text_focus:
				focus_godot()
		"focus_parent":
			focus_godot()
		"command":
			match str(message.get("name", "")):
				"edit_mode": app.hud.set_edit_mode(bool(message.get("value", false)))
				"view": app.hud.cycle_view()
				"escape":
					app.hud.release_to_cursor()
					app.world_panels.html_text_focus = false
					focus_godot()
				"release":
					app.release_cursor()
					app.world_panels.html_text_focus = false
					focus_godot()
				"inspector":
					notice = ""
					app.world_panels.html_text_focus = false
					if app.world_panels.pinned_ids().is_empty(): app.world_panels.pin_target(str(app.selected_id))
					else: app.world_panels.release_pins()
					push(true)
					focus_godot()
				"place":
					var pinned: Array = app.world_panels.pinned_ids()
					if pinned.is_empty(): return
					app.world_panels.pin_panel_rect(pinned[0], [message.get("x", 0), message.get("y", 0), message.get("w", 0), message.get("h", 0)], float(message.get("aspect", 1.6)))
					push(true)
				"set_target":
					var panel := str(message.get("panel", ""))
					var target := str(message.get("target", ""))
					if panel.is_empty() or not app.objects.has(panel): return
					var address: Variant = app.address_of(app.objects[target]) if app.objects.has(target) else null
					app.world_panels.edit(panel, "inspector_target", address, func(_r): push(true); push_panel(true))
				"component":
					change_component(message)
				"playback":
					var target := str(message.get("target", ""))
					if target.is_empty() or not app.objects.has(target): return
					var field: Dictionary = app.world_panels.field_data(target, "playback")
					if field.is_empty(): return
					app.world_panels.command({"kind":"playback","command":{"target":app.address_of(app.objects[target]),"expected_revision":field.revision,"action":str(message.get("action","play"))}})
				"scripts_tab":
					var panel := str(message.get("panel", ""))
					if panel.is_empty() or not app.objects.has(panel): return
					app.world_panels.edit(panel, "inspector_scripts_open", bool(message.get("open", false)), func(_r): push_panel(true))
				"open_script":
					open_script(message)
				"script_apply":
					apply_script(message)
				"graph_op":
					graph_op(message)
				"graph_apply":
					graph_apply(message)
				"open_driver":
					open_driver(message)
		"edit":
			apply_edit(message)

func apply_frame(message: Dictionary) -> void:
	var id := str(message.get("id", ""))
	var png := str(message.get("png", ""))
	if id.is_empty() or png.is_empty(): return
	var bytes := Marshalls.base64_to_raw(png)
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK: return
	if panel_textures.has(id):
		panel_textures[id].update(image)
	else:
		panel_textures[id] = ImageTexture.create_from_image(image)
	if app.world_panels.panels.has(id):
		app.world_panels.panels[id].apply_html_texture(panel_textures[id])

func snapshot() -> Dictionary:
	var ready: bool = app.connected and app.editable
	var status := "wait"
	if app.hud.sync_label.text.begins_with("● 同期中"): status = "busy"
	elif ready: status = "ready"
	return {
		"type": "state",
		"header": {
			"edit": app.edit_mode,
			"room": app.hud.room_label.text,
			"sync": app.hud.sync_label.text,
			"status": status,
			"engine": app.hud.engine_label.text,
			"fps": app.hud.fps_label.text,
			"view": app.hud.mode_button.text,
			"inspector": not app.world_panels.pinned_ids().is_empty(),
		},
		"inspector": pinned_view(),
	}

func pinned_view() -> Dictionary:
	var pinned: Array = app.world_panels.pinned_ids()
	if pinned.is_empty(): return {"open": false}
	return inspector_model(str(pinned[0]), "overlay")

func inspector_model(panel_id: String, mode: String) -> Dictionary:
	if not app.objects.has(panel_id): return {"open": false}
	var screen: Dictionary = {}
	var attachment = app.objects[panel_id].panel.get("attachment", null)
	if attachment is Dictionary and attachment.get("screen") is Dictionary:
		screen = attachment.screen
	var target: String = app.world_panels.target_of(panel_id)
	var model := {
		"open": true,
		"mode": mode,
		"panelId": panel_id,
		"rect": screen.get("rect", []),
		"title": "Inspector",
		"editable": app.editable,
		"target": target,
		"message": notice,
		"objects": object_list(),
		"sections": [],
		"catalog": [],
		"shapes": ["box", "sphere", "capsule", "cylinder", "cone", "torus", "grid", "quad"],
		"shapeIndex": 6,
		"scripts": [],
		"isPanelTarget": false,
		"tab": "scripts" if app.objects[panel_id].inspector.get("scripts_open", false) else "object",
	}
	if target.is_empty() or not app.objects.has(target):
		return model
	model.title = object_name(target)
	model.isPanelTarget = app.objects[target].get("panel") != null
	model.sections = sections_for(target)
	model.catalog = catalog_for(target)
	model.scripts = scripts_for(target)
	var script_id: Variant = app.objects[panel_id].inspector.get("script_id")
	if script_id != null:
		model.scriptId = str(script_id)
		if script_cache.has(str(script_id)):
			model.scriptText = script_cache[str(script_id)]
	if app.objects[panel_id].inspector.get("scripts_open", false) and script_id != null:
		var graph = graph_for(target, str(script_id))
		if not graph.is_empty(): model.graph = graph
	return model

func object_list() -> Array:
	var list := []
	for id in app.objects:
		if app.objects[id].get("inspector") != null: continue
		var parent = app.objects[id].get("parent")
		list.append({
			"id": id,
			"name": object_name(id),
			"parent": parent.instance_id if parent is Dictionary else "",
		})
	return list

func catalog_for(id: String) -> Array:
	var object: Dictionary = app.objects[id]
	var list := []
	for schema in app.world_panels.component_schemas:
		if schema.get("attach_defaults") == null: continue
		var type_id := str(schema.type_id)
		var present: bool = object.fields.any(func(field): return int(field.component_id) == int(schema.local_id))
		var mirror_ok: bool = object.get("visual", {}).get("kind", "") == "primitive" and object.visual.get("shape", "") in ["quad", "mirror"]
		var motion_ok: bool = object.get("parent") == null and object.get("renderer") != null and object.get("collider") != null and object.collider.get("solid", false)
		var disabled: bool = present or (type_id == "Mirror" and not mirror_ok) or (type_id == "PlanarMotion" and not motion_ok)
		var tooltip := ""
		if present: tooltip = "Already attached"
		elif type_id == "Mirror" and not mirror_ok: tooltip = "Needs a Quad or Mirror mesh"
		elif type_id == "PlanarMotion" and not motion_ok: tooltip = "Needs a root Slot with a renderer and solid Collider"
		list.append({"typeId": type_id, "disabled": disabled, "tooltip": tooltip})
	return list

func scripts_for(id: String) -> Array:
	var list := []
	for script in app.objects[id].get("scripts", []):
		list.append({
			"id": str(script.id),
			"name": str(script.get("schema", {}).get("name", "Script")),
			"enabled": script.get("enabled", false),
		})
	return list

func graph_for(target: String, script_id: String) -> Dictionary:
	if not app.objects.has(target): return {}
	for script in app.objects[target].get("scripts", []):
		if str(script.id) != script_id: continue
		var source := str(script.get("source", ""))
		if not source.begins_with("@tukurium-graph-v1\n"): return {}
		var parsed = JSON.parse_string(source.substr("@tukurium-graph-v1\n".length()))
		if parsed is Dictionary: return parsed
	return {}

func sections_for(id: String) -> Array:
	var object: Dictionary = app.objects[id]
	var grouped := {}
	var order: Array[int] = []
	var names := {}
	for schema in app.world_panels.component_schemas:
		names[int(schema.local_id)] = str(schema.type_id)
	for field in object.get("fields", []):
		if str(field.get("value_type", "")) == "inspector_tree": continue
		var component := int(field.get("component_id", 0))
		if not grouped.has(component):
			grouped[component] = []
			order.append(component)
		var view := field_view(id, field)
		if not view.is_empty():
			var bucket: Array = grouped[component]
			bucket.append(view)
			grouped[component] = bucket
	var sections: Array = []
	for component in order:
		if grouped[component].is_empty(): continue
		var type_id := str(names.get(component, "Object"))
		var removable: bool = false
		for schema in app.world_panels.component_schemas:
			if int(schema.local_id) == component and schema.get("attach_defaults") != null:
				removable = true
		sections.append({
			"name": type_id,
			"fields": grouped[component],
			"removable": removable,
			"removeDisabled": type_id == "MeshRenderer" and (object.get("panel") != null or object.get("playback") != null or object.get("mirror") != null or object.get("planar_motion") != null or not object.get("scripts", []).is_empty()),
		})
	return sections

func field_view(id: String, field: Dictionary) -> Dictionary:
	var type := str(field.get("value_type", ""))
	var label := tr(str(field.get("label", field.id)))
	var value: Variant = app.driven_objects.get(id, {}).get(field.id, field.get("value"))
	var view := {"id": str(field.id), "label": label, "type": type}
	var driver: Dictionary = app.world_panels.field_driver(id, str(field.id))
	if not driver.is_empty():
		view.driven = true
		view.drive = {
			"label": ("Local Drive · running\nShared base: %s" if driver.enabled else "Local Drive · paused\nShared base: %s") % value_text(field.get("value"), type),
			"button": "Open %s →" % str(driver.get("schema", {}).get("name", "script")),
		}
	for session in app.world_panels.sessions:
		if session.target.instance_id == id and session.field_id == field.id:
			view.remote = "Editing · " + str(session.get("client_id", ""))
	match type:
		"string": view["text"] = str(value)
		"number": view["text"] = String.num(float(value), 3)
		"bool": view["checked"] = value == true
		"vec3":
			view["axes"] = ["X", "Y", "Z"]
			view["values"] = numbers(value, 3)
		"quat":
			view["axes"] = ["X", "Y", "Z"]
			view["values"] = euler_degrees(value)
		"vec4":
			view["axes"] = ["min X", "max X", "min Z", "max Z"]
			view["values"] = numbers(value, 4)
		"color":
			view["axes"] = ["R", "G", "B", "A"]
			view["values"] = numbers(value, 4)
		"address":
			view["type"] = "text"
			view["text"] = address_text(value)
		"collider":
			if value is Dictionary:
				view["flags"] = [value.get("enabled", true), value.get("solid", false)]
				view["axes"] = ["X", "Y", "Z"]
				view["values"] = numbers(value.get("half_extents", [0.5, 0.5, 0.5]), 3)
			else:
				view["type"] = "text"
				view["text"] = str(value)
		"playback":
			view["type"] = "playback"
			view["text"] = str(value)
		_:
			return {}
	return view

func numbers(value: Variant, count: int) -> Array:
	var result: Array = []
	for index in count:
		var part := 0.0
		if value is Array and index < value.size(): part = float(value[index])
		result.append(String.num(part, 3))
	return result

func euler_degrees(value: Variant) -> Array:
	if not value is Array or value.size() < 4: return ["0.000", "0.000", "0.000"]
	var angles := Quaternion(float(value[0]), float(value[1]), float(value[2]), float(value[3])).get_euler()
	return [String.num(rad_to_deg(angles.x), 3), String.num(rad_to_deg(angles.y), 3), String.num(rad_to_deg(angles.z), 3)]

func value_text(value: Variant, kind: String) -> String:
	if kind == "quat" and value is Array:
		var angles := Quaternion(value[0], value[1], value[2], value[3]).get_euler()
		return "%.1f°, %.1f°, %.1f°" % [rad_to_deg(angles.x), rad_to_deg(angles.y), rad_to_deg(angles.z)]
	if value is Array:
		return ", ".join(value.map(func(v): return String.num(float(v), 3)))
	return str(value)

func address_text(value: Variant) -> String:
	if value == null: return tr("World")
	if value is Dictionary and app.objects.has(value.instance_id): return object_name(str(value.instance_id))
	return tr("Deleted Slot")

func object_name(id: String) -> String:
	return str(app.world_panels.field_data(id, "name").get("value", id))

func apply_edit(message: Dictionary) -> void:
	var id := str(message.get("target", ""))
	if id.is_empty(): id = str(app.selected_id)
	if id.is_empty() or not app.editable:
		notice = "編集できません。"
		push(true)
		return
	var type := str(message.get("valueType", ""))
	if type == "collider":
		var parsed_collider := coerce_collider(message.get("value"))
		if not parsed_collider.ok:
			notice = str(parsed_collider.get("message", "値を送れませんでした。"))
			push(true)
			return
		notice = ""
		app.world_panels.edit(id, str(message.field), parsed_collider.value, func(result: Dictionary):
			notice = "" if result.ok else str(result.get("message", "Edit rejected"))
			push(true); push_panel(true))
		return
	var parsed := coerce(type, message.get("value"), str(message.get("field", "")))
	if not parsed.ok:
		notice = str(parsed.get("message", "値を送れませんでした。"))
		push(true)
		return
	notice = ""
	var panel := str(message.get("panel", ""))
	var editor: String = app.world_panels.client_id + "/html"
	if not panel.is_empty():
		app.world_panels.session_input(panel, id, str(message.field), "begin", {}, Callable(), editor)
	app.world_panels.edit(id, str(message.field), parsed.value, func(result: Dictionary):
		notice = "" if result.ok else str(result.get("message", "Edit rejected"))
		if not panel.is_empty():
			app.world_panels.session_input(panel, id, str(message.field), "end", {}, Callable(), editor)
		push(true); push_panel(true))

func coerce_collider(value: Variant) -> Dictionary:
	if not value is Dictionary: return {"ok": false, "message": "Colliderではありません。"}
	var extents = value.get("half_extents", [])
	if not extents is Array or extents.size() < 3: return {"ok": false, "message": "Colliderではありません。"}
	return {"ok": true, "value": {
		"enabled": bool(value.get("enabled", true)),
		"solid": bool(value.get("solid", false)),
		"half_extents": [float(extents[0]), float(extents[1]), float(extents[2])],
	}}

func coerce(type: String, value: Variant, field: String) -> Dictionary:
	if type == "string":
		var text := str(value)
		if field == "name" and text.strip_edges().is_empty(): return {"ok": false, "message": "名前は空にできません。"}
		return {"ok": true, "value": text}
	if type == "bool": return {"ok": true, "value": bool(value)}
	if type == "number":
		if not str(value).is_valid_float(): return {"ok": false, "message": "数値ではありません。"}
		return {"ok": true, "value": float(value)}
	if type == "quat":
		if not value is Array or value.size() < 3: return {"ok": false, "message": "角度ではありません。"}
		for part in value:
			if not str(part).is_valid_float(): return {"ok": false, "message": "角度ではありません。"}
		var rotation := Quaternion.from_euler(Vector3(deg_to_rad(float(value[0])), deg_to_rad(float(value[1])), deg_to_rad(float(value[2]))))
		return {"ok": true, "value": [rotation.x, rotation.y, rotation.z, rotation.w]}
	if type in ["vec3", "vec4", "color"]:
		if not value is Array: return {"ok": false, "message": "数値ではありません。"}
		var numbers: Array = []
		for part in value:
			if not str(part).is_valid_float(): return {"ok": false, "message": "数値ではありません。"}
			numbers.append(float(part))
		return {"ok": true, "value": numbers}
	return {"ok": false, "message": "この項目はまだHTMLから編集できません。"}

func change_component(message: Dictionary) -> void:
	var target := ""
	var panel := str(message.get("panel", ""))
	if not panel.is_empty(): target = app.world_panels.target_of(panel)
	if target.is_empty() or not app.objects.has(target): return
	var object: Dictionary = app.objects[target]
	if object.get("panel") != null: return
	var type_id := str(message.get("typeId", ""))
	var add: bool = bool(message.get("add", true))
	var schema: Dictionary = {}
	for candidate in app.world_panels.component_schemas:
		if candidate.type_id == type_id: schema = candidate; break
	if schema.is_empty() or schema.get("attach_defaults") == null: return
	var command: Dictionary = {"action":"add_component" if add else "remove_component", "target":app.address_of(object), "type_id":type_id, "expected_revision":object.object_revision}
	if add:
		command["values"] = schema.attach_defaults.duplicate(true)
		if type_id == "MeshRenderer":
			var shapes = ["box", "sphere", "capsule", "cylinder", "cone", "torus", "grid", "quad"]
			var index := clampi(int(message.get("shape", 6)), 0, shapes.size() - 1)
			command["values"]["visual"]["shape"] = shapes[index]
	app.world_panels.command({"kind":"structure", "command":command}, func(result):
		notice = "" if result.ok else str(result.get("message", "Could not change component"))
		push(true); push_panel(true))

func open_script(message: Dictionary) -> void:
	var panel := str(message.get("panel", ""))
	var script := str(message.get("script", ""))
	if panel.is_empty() or not app.objects.has(panel): return
	app.world_panels.edit(panel, "inspector_scripts_open", true)
	app.world_panels.edit(panel, "inspector_script_id", null if script.is_empty() else script, func(_r):
		var target: String = app.world_panels.target_of(panel)
		if not script.is_empty() and app.objects.has(target):
			for entry in app.objects[target].get("scripts", []):
				if str(entry.id) == script:
					script_cache[script] = str(entry.get("source", ""))
		push_panel(true))

func apply_script(message: Dictionary) -> void:
	var target := str(message.get("target", ""))
	var script := str(message.get("script", ""))
	var source := str(message.get("source", ""))
	if target.is_empty() or script.is_empty() or not app.objects.has(target): return
	var current: Dictionary = {}
	for entry in app.objects[target].get("scripts", []):
		if str(entry.id) == script: current = entry
	if current.is_empty(): return
	script_cache[script] = source
	app.world_panels.command({"kind":"script","command":{"target":app.address_of(app.objects[target]),"action":"update","script_id":script,"expected_revision":current.revision,"source":source,"enabled":current.enabled,"parameters":current.get("parameters", {})}}, func(result):
		notice = "" if result.ok else str(result.get("message", "Script rejected"))
		push(true); push_panel(true))

func graph_op(message: Dictionary) -> void:
	var panel := str(message.get("panel", ""))
	if panel.is_empty() or not app.objects.has(panel): return
	var target: String = app.world_panels.target_of(panel)
	var script: Variant = app.objects[panel].inspector.get("script_id")
	if target.is_empty() or script == null: return
	var input := {
		"target": app.address_of(app.objects[target]),
		"script_id": str(script),
		"client_id": app.world_panels.client_id + "/html",
		"action": "edit",
		"ops": message.get("ops", []),
	}
	app.requests.request({"kind":"script_graph","request":input}, func(result):
		notice = "" if result.get("ok", false) else str(result.get("message", "Graph edit rejected"))
		push_panel(true), ["request","request_id"], "request_id", 10000, "script_graph_result")

func graph_apply(message: Dictionary) -> void:
	var panel := str(message.get("panel", ""))
	if panel.is_empty() or not app.objects.has(panel): return
	var target: String = app.world_panels.target_of(panel)
	var script: Variant = app.objects[panel].inspector.get("script_id")
	if target.is_empty() or script == null: return
	var input := {
		"target": app.address_of(app.objects[target]),
		"script_id": str(script),
		"client_id": app.world_panels.client_id + "/html",
		"action": "apply",
	}
	app.requests.request({"kind":"script_graph","request":input}, func(result):
		notice = "" if result.get("ok", false) else str(result.get("message", "Graph apply rejected"))
		push(true); push_panel(true), ["request","request_id"], "command_id", 10000, "result")

func open_driver(message: Dictionary) -> void:
	var panel := str(message.get("panel", ""))
	var field := str(message.get("field", ""))
	var target: String = app.world_panels.target_of(panel) if not panel.is_empty() else str(app.selected_id)
	if target.is_empty(): return
	var driver: Dictionary = app.world_panels.field_driver(target, field)
	if driver.is_empty(): return
	var owner := str(driver.get("owner_id", target))
	if owner != target and app.objects.has(panel):
		app.world_panels.edit(panel, "inspector_target", app.address_of(app.objects[owner]))
	app.world_panels.edit(panel, "inspector_scripts_open", true)
	app.world_panels.edit(panel, "inspector_script_id", str(driver.id), func(_r): push_panel(true))
