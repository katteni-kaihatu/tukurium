extends Node
const WORLD_PANEL = preload("res://world_panel.gd")
const DESKTOP_INSPECTOR = preload("res://desktop_inspector.gd")
const GIZMO = preload("res://translation_gizmo.gd")
var app
var panels: Dictionary = {}
var shared_gizmos: Dictionary = {}
var sessions: Array = []
var client_id := ""
var capture_id := ""
var keyboard_id := ""
var hover_id := ""
var component_schemas: Array = []
var drive_sources: Dictionary = {}
var evaluated_transforms: Dictionary = {}
var windows: Dictionary = {}
var dock_inspector_id := ""
var pin_when_created := ""
var pending_panel_close: Dictionary = {}
var carried_reference: Dictionary = {}
var graph_context_id := ""
var html_pinned_active := false
var html_text_focus := false

func setup(application) -> void:
	app = application
	client_id = "%s-%s" % [Time.get_ticks_usec(), randi()]

func command(body: Dictionary, callback: Callable = Callable()) -> String:
	var key: String = "edit" if body.kind == "edit" else ("request" if body.kind == "edit_session" else "command")
	return app.requests.request(body,callback,[key,"command_id"],"command_id",10000)

func edit(object_id: String, field: String, value: Variant, callback: Callable = Callable(), revision: String = "") -> void:
	var object: Dictionary = app.objects.get(object_id, {})
	if object.is_empty() or not app.editable:
		if callback.is_valid(): callback.call({"ok":false,"message":"Object unavailable or disconnected"})
		return
	var current_field := field_data(object_id, field)
	if current_field.is_empty():
		if callback.is_valid(): callback.call({"ok":false,"message":"Field unavailable"})
		return
	command({"kind":"edit","edit":{"target":app.field_address(object_id,field),"field_id":field,"expected_revision":str(current_field.revision) if revision.is_empty() else revision,"value":value}}, callback)

func field_data(object_id: String, field: String) -> Dictionary:
	for entry in app.objects.get(object_id, {}).get("fields", []):
		if entry.id == field: return entry
	return {}

func session_input(panel_id: String, target_id: String, field: String, action: String, draft: Dictionary, callback: Callable = Callable(), editor_id: String = "") -> void:
	if (not app.objects.has(panel_id) and not windows.has(panel_id)) or not app.objects.has(target_id):
		if callback.is_valid(): callback.call({"ok":false,"message":"Target unavailable"})
		return
	var context: Variant = null if windows.has(panel_id) else {"source":app.field_address(panel_id,"inspector_target"),"field_id":"inspector_target"}
	command({"kind":"edit_session","request":{"client_id":client_id if editor_id.is_empty() else editor_id,"context":context,"target":app.field_address(target_id,field),"field_id":field,"action":action,"draft":draft}}, callback)

func receive(body: Dictionary) -> bool:
	if body.get("kind") == "snapshot":
		# Schemas now arrive once per connection in the catalog
		# message; a snapshot only replaces them if it carries them.
		if body.has("component_schemas"): component_schemas = body["component_schemas"]
		update_drive_sources(body.get("drive_frame", {}))
	elif body.get("kind") == "drive_frame":
		update_drive_sources(body.frame)
	elif body.get("kind") == "status" and not body.get("editable", false):
		drive_sources.clear()
		evaluated_transforms.clear()
		carried_reference.clear()
	if body.get("kind") == "script_document_state":
		for view in views(): view.script_view.receive(body.document)
		return true
	if body.get("kind") == "script_graph_state":
		for view in views(): view.script_view.receive_graph(body.document)
		return true
	if body.get("kind") == "edit_sessions":
		sessions = body.get("sessions", [])
		for view in views(): view.refresh_sessions()
		return true
	return false

func update_drive_sources(frame: Dictionary) -> void:
	drive_sources.clear()
	evaluated_transforms.clear()
	for transform in frame.get("transforms", []): evaluated_transforms[transform.target.instance_id] = transform
	for object in frame.get("objects", []):
		drive_sources[object.target.instance_id] = object.get("sources", {})

var script_index: Dictionary = {}
var script_index_key: Array = []

# The driver lookup used to scan every object x every script on each
# call (several times per inspector frame). The index maps script id
# to (owner, script) and is rebuilt only when the (owner, id,
# revision) set changes — a script's revision changes on every write
# to it, so a cached entry can never outlive the script it describes.
func field_driver(object_id: String, field: String) -> Dictionary:
	var script_id: String = drive_sources.get(object_id, {}).get(field, "")
	if script_id.is_empty(): return {}
	var key: Array = []
	for owner_id in app.objects:
		for script in app.objects[owner_id].get("scripts", []):
			key.append([owner_id, script.id, str(script.get("revision", ""))])
	if key != script_index_key:
		script_index_key = key
		script_index.clear()
		for owner_id in app.objects:
			for script in app.objects[owner_id].get("scripts", []):
				script_index[script.id] = [owner_id, script]
	if not script_index.has(script_id): return {}
	var entry: Array = script_index[script_id]
	var driver: Dictionary = entry[1].duplicate(false)
	driver["owner_id"] = entry[0]
	return driver

func panel_spawn_position(distance: float) -> Vector3:
	var origin: Vector3 = app.camera.global_position
	var forward: Vector3 = -app.camera.global_basis.z
	var hit: Dictionary = app.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin,origin+forward*distance))
	if not hit.is_empty() and hit.collider.has_meta("object_id") and panels.has(str(hit.collider.get_meta("object_id"))):
		# Opening a tool while looking at another must not put it behind that surface.
		distance = maxf(0.6,origin.distance_to(hit.position)-0.4)
	return origin + forward*distance

func target_of(id: String) -> String:
	var object: Dictionary = app.objects.get(id, {})
	for key in ["inspector", "resources", "script_editor"]:
		var view = object.get(key, null)
		if view is Dictionary and view.get("target") != null:
			return str(view.target.instance_id)
	return ""

func pinned_to_me(id: String) -> bool:
	var attachment = app.objects.get(id, {}).get("panel", {}).get("attachment", null)
	return attachment is Dictionary and str(attachment.get("user_id", "")) == app.self_id and attachment.get("screen") is Dictionary

func pinned_ids() -> Array:
	var ids := []
	for id in panels.keys():
		if pinned_to_me(id): ids.append(id)
	return ids

func pin_panel(id: String) -> void:
	if not app.objects.has(id): return
	var viewport: Vector2 = app.get_viewport().get_visible_rect().size
	if viewport.x < 100.0 or viewport.y < 100.0: return
	var panel_size: Array = app.objects[id].panel.size
	var panel_aspect := float(panel_size[0]) / maxf(float(panel_size[1]), 1.0)
	var height := minf(640.0, viewport.y - 110.0)
	var width := height * panel_aspect
	if width > viewport.x - 90.0:
		width = viewport.x - 90.0
		height = width / panel_aspect
	pin_panel_rect(id, [72.0 / viewport.x, 88.0 / viewport.y, width / viewport.x, height / viewport.y], viewport.x / viewport.y)

func pin_panel_rect(id: String, rect: Array, aspect: float) -> void:
	if not app.objects.has(id): return
	for other in pinned_ids():
		if other != id: edit(other, "panel_pin", null)
	var x := clampf(float(rect[0]), 0.0, 0.95)
	var y := clampf(float(rect[1]), 0.0, 0.95)
	var w := clampf(float(rect[2]), 0.05, 1.0)
	var h := clampf(float(rect[3]), 0.05, 1.0)
	if x + w > 1.0: w = 1.0 - x
	if y + h > 1.0: h = 1.0 - y
	if w < 0.05 or h < 0.05: return
	edit(id, "panel_pin", {
		"user_id": "$self",
		"offset": [0.0, 1.15, -1.2],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"screen": {"rect": [x, y, w, h], "aspect": clampf(aspect, 0.4, 4.0)},
	})

func toggle_pin(id: String) -> void:
	if pinned_to_me(id): edit(id, "panel_pin", null)
	else: pin_panel(id)

func pin_target(target_id: String) -> void:
	if not app.edit_mode or not app.editable: return
	for id in panels.keys():
		if panels[id].inspector_content and target_of(id) == target_id:
			toggle_pin(id)
			return
	pin_when_created = target_id
	open_inspector(target_id)

func release_pins() -> void:
	for id in pinned_ids(): edit(id, "panel_pin", null)

func sync_pinned_presentation() -> void:
	var html: bool = app.html_ui != null and app.html_ui.active
	var any_pinned := false
	for id in panels.keys():
		var pinned: bool = panels[id].inspector_content and pinned_to_me(id)
		# Owner with HTML sees the same inspector as a 2D overlay; hide the board locally.
		panels[id].visible = not (html and pinned)
		if html and pinned: any_pinned = true
	if any_pinned != html_pinned_active:
		# Pin toggles must not leave HTML text focus armed, or WASD stays swallowed.
		html_text_focus = false
		if any_pinned: app.release_cursor()
		if app.html_ui: app.html_ui.focus_godot()
	html_pinned_active = any_pinned
	if pin_when_created.is_empty(): return
	for id in panels.keys():
		if panels[id].inspector_content and target_of(id) == pin_when_created and not pinned_to_me(id):
			pin_when_created = ""
			pin_panel(id)
			return

func open_inspector(target_id: String = "", desktop: bool = false) -> void:
	if not app.edit_mode or not app.editable: return
	if desktop:
		open_window(target_id)
		return
	var position := panel_spawn_position(2.1)
	var q: Quaternion = app.camera.global_basis.get_rotation_quaternion()
	var target: Variant = app.address_of(app.objects[target_id]) if app.objects.has(target_id) else null
	command({"kind":"structure","command":{"action":"create_inspector","target":target,"position":[position.x,position.y,position.z],"rotation":[q.x,q.y,q.z,q.w]}}, func(result):
		if not result.ok: app.feedback.text = str(result.get("message", "Cannot open inspector")))

func close_panel(id: String) -> void:
	if not app.objects.has(id): return
	panels[id].clear_focus()
	for view in views():
		if view.panel_id == id: view.finish_all()
	if views().any(func(view): return view.panel_id == id and view.has_active_edits()):
		pending_panel_close[id] = true
		return
	pending_panel_close.erase(id)
	command({"kind":"structure","command":{"action":"delete","target":app.address_of(app.objects[id]),"expected_revision":app.objects[id].object_revision}})

func open_creation() -> void:
	if not app.edit_mode or not app.editable: return
	var position := panel_spawn_position(2.6)
	var q: Quaternion = app.camera.global_basis.get_rotation_quaternion()
	command({"kind":"structure","command":{"action":"create_creation_panel","position":[position.x,position.y,position.z],"rotation":[q.x,q.y,q.z,q.w]}}, func(result):
		if not result.ok: app.feedback.text = result.get("message","Cannot open creation panel"))

func open_resources(target_id: String = "") -> void:
	if not app.edit_mode or not app.editable: return
	var position := panel_spawn_position(2.3)
	var q: Quaternion = app.camera.global_basis.get_rotation_quaternion()
	var resolved := target_id if not target_id.is_empty() else app.selected_id
	var target: Variant = app.address_of(app.objects[resolved]) if app.objects.has(resolved) else null
	command({"kind":"structure","command":{"action":"create_resources_panel","target":target,"position":[position.x,position.y,position.z],"rotation":[q.x,q.y,q.z,q.w]}}, func(result):
		if not result.ok: app.feedback.text = str(result.get("message", "Cannot open Resources")))

func open_script_editor(target_id: String = "", script_id: String = "") -> void:
	if not app.edit_mode or not app.editable: return
	var position := panel_spawn_position(2.4)
	var q: Quaternion = app.camera.global_basis.get_rotation_quaternion()
	var resolved := target_id if not target_id.is_empty() else app.selected_id
	var target: Variant = app.address_of(app.objects[resolved]) if app.objects.has(resolved) else null
	var sid: Variant = script_id if not script_id.is_empty() else null
	command({"kind":"structure","command":{"action":"create_script_editor_panel","target":target,"script_id":sid,"position":[position.x,position.y,position.z],"rotation":[q.x,q.y,q.z,q.w]}}, func(result):
		if not result.ok: app.feedback.text = str(result.get("message", "Cannot open Script Editor")))

func duplicate_panel(id: String) -> void:
	if not app.objects.has(id): return
	command({"kind":"structure","command":{"action":"duplicate","target":app.address_of(app.objects[id]),"expected_revision":app.objects[id].object_revision}})

func sync() -> void:
	for id in panels.keys():
		if not app.objects.has(id):
			panels[id].content.finish_all()
			panels.erase(id)
			if capture_id == id: capture_id = ""
			if keyboard_id == id: keyboard_id = ""
	for id in app.objects:
		if app.objects[id].get("panel") != null and panels.has(id):
			panels[id].refresh(app.objects[id])
	for window in windows.values(): window.get_meta("inspector").refresh_local()
	refresh_gizmos()

func toggle_dock_inspector(target_id: String = "") -> void:
	if windows.has(dock_inspector_id):
		close_window(dock_inspector_id)
	else:
		dock_inspector_id = open_window(target_id)

func open_window(target_id: String = "") -> String:
	if not app.edit_mode: return ""
	app.release_cursor()
	var id := "desktop-%s-%s" % [Time.get_ticks_usec(), randi()]
	var window := Window.new()
	window.hide()
	window.title = "tukurium · Inspector"
	window.force_native = true
	window.borderless = false
	window.unresizable = false
	window.extend_to_title = false
	window.popup_window = false
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_size = Vector2i.ZERO
	window.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	window.size = Vector2i(1100, 800)
	window.min_size = Vector2i(900, 560)
	window.transient = false
	window.close_requested.connect(close_window.bind(id))
	window.focus_entered.connect(func(): app.release_cursor())
	app.add_child(window)
	var view = DESKTOP_INSPECTOR.new()
	window.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view.setup(self, id, true)
	window.set_meta("inspector", view)
	window.set_meta("closing", false)
	windows[id] = window
	view.set_initial_target(target_id)
	window.show()
	window.grab_focus()
	return id

func close_window(id: String, force: bool = false) -> void:
	if not windows.has(id): return
	if id == dock_inspector_id: dock_inspector_id = ""
	var window: Window = windows[id]
	var view = window.get_meta("inspector")
	window.gui_release_focus()
	view.finish_all()
	window.hide()
	if not force and view.has_active_edits():
		window.set_meta("closing", true)
		return
	windows.erase(id)
	window.queue_free()

func views() -> Array:
	var result: Array = []
	for panel in panels.values():
		if panel.content.get("script_view") != null:
			result.append(panel.content)
	for window in windows.values(): result.append(window.get_meta("inspector"))
	return result

func has_window_focus() -> bool:
	for window in windows.values():
		if window.has_focus(): return true
	return false

func create_surface(id: String):
	var panel = WORLD_PANEL.new()
	app.add_child(panel)
	panel.setup(self, id)
	panels[id] = panel
	return panel

func refresh_gizmos() -> void:
	var wanted := {}
	for object in app.objects.values():
		if object.get("inspector") == null or object.inspector.get("target") == null: continue
		var target_id: String = object.inspector.target.instance_id
		if not app.render_nodes.has(target_id): continue
		wanted[target_id] = true
		if not shared_gizmos.has(target_id):
			var gizmo = GIZMO.new()
			app.add_child(gizmo)
			gizmo.camera = app.camera
			gizmo.shared_display = true
			shared_gizmos[target_id] = gizmo
		shared_gizmos[target_id].set_target(app.render_nodes[target_id].position, false)
		shared_gizmos[target_id].shared_active = app.remote_previews.has(target_id)
		shared_gizmos[target_id].visible = app.edit_mode and target_id != app.selected_id
	for id in shared_gizmos.keys():
		if not wanted.has(id):
			shared_gizmos[id].queue_free()
			shared_gizmos.erase(id)

func text_focused() -> bool:
	if html_text_focus: return true
	for panel in panels.values():
		if panel.has_text_focus(): return true
	return false

func clear_focus() -> void:
	for panel in panels.values(): panel.clear_focus()
	keyboard_id = ""
	capture_id = ""
	graph_context_id = ""
	html_text_focus = false
	if app.html_ui: app.html_ui.focus_godot()

func pick(screen: Vector2) -> Dictionary:
	var origin: Vector3 = app.camera.project_ray_origin(screen)
	var direction: Vector3 = app.camera.project_ray_normal(screen)
	var hit: Dictionary = app.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + direction * 4000.0))
	if hit.is_empty() or not hit.collider.has_meta("object_id"): return {}
	var id := str(hit.collider.get_meta("object_id"))
	if not panels.has(id) or direction.dot(panels[id].global_basis.z) >= 0.0: return {}
	return {"id":id,"position":panels[id].canvas_point(hit.position)}

func route_input(event: InputEvent) -> bool:
	if event is InputEventKey and text_focused() and panels.has(keyboard_id):
		if event.keycode == KEY_ESCAPE and event.pressed:
			clear_focus()
			return true
		if panels[keyboard_id].using_html and app.html_ui != null and app.html_ui.active:
			app.html_ui.panel_key(keyboard_id, event)
			return true
		panels[keyboard_id].viewport.push_input(event.duplicate(), true)
		return true
	if not event is InputEventMouse: return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if not event.pressed and not graph_context_id.is_empty():
			if panels.has(graph_context_id):
				var release_hit := pick(event.position)
				panels[graph_context_id].forward_pointer(event, release_hit.position if release_hit.get("id", "") == graph_context_id else Vector2(-1000,-1000))
			graph_context_id = ""
			return true
		# In cursor mode the graph canvas owns its context menu. FPS right-click
		# still belongs to grabbing, and Ctrl+right-click still extracts references.
		if event.pressed and not app.fps_active and not event.ctrl_pressed and app.hand_grab.is_empty() and not app.grab_waiting:
			var graph_hit := pick(event.position)
			if not graph_hit.is_empty():
				var panel = panels[graph_hit.id]
				if panel.content.get("script_view") != null and panel.content.get("script_mount") != null and panel.content.script_mount.visible:
					var graph = panel.content.script_view.editor.graph
					if graph.visible and graph.canvas.get_global_rect().has_point(graph_hit.position):
						panel.forward_pointer(InputEventMouseMotion.new(),graph_hit.position)
						panel.forward_pointer(event,graph_hit.position)
						graph_context_id = graph_hit.id
						return true
		# Plain RMB and every in-progress grab release belong to world manipulation.
		if not event.pressed or not event.ctrl_pressed or not app.hand_grab.is_empty() or app.grab_waiting: return false
		var reference_hit := pick(app.get_viewport().get_visible_rect().size * 0.5 if app.fps_active else event.position)
		if not reference_hit.is_empty():
			panels[reference_hit.id].forward_pointer(InputEventMouseMotion.new(),reference_hit.position)
			var control: Control = panels[reference_hit.id].viewport.gui_get_hovered_control()
			if control != null and control.has_method("is_reference_chip"):
				panels[reference_hit.id].forward_pointer(event,reference_hit.position)
				return true
		return false
	if not app.hand_grab.is_empty() or app.gizmo.dragging: return false
	var screen: Vector2 = app.get_viewport().get_visible_rect().size * 0.5 if app.fps_active else event.position
	var hit := pick(screen)
	if capture_id.is_empty() and not app.fps_active and app.get_viewport().gui_get_hovered_control() != null: hit = {}
	if not capture_id.is_empty() and panels.has(capture_id):
		var panel = panels[capture_id]
		var origin: Vector3 = app.camera.project_ray_origin(screen)
		var direction: Vector3 = app.camera.project_ray_normal(screen)
		var point: Variant = Plane(panel.global_basis.z.normalized(), panel.global_position).intersects_ray(origin, direction)
		if point != null: hit = {"id":capture_id,"position":panel.canvas_point(point)}
	if hit.is_empty():
		if not hover_id.is_empty() and panels.has(hover_id): panels[hover_id].leave_pointer()
		hover_id = ""
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT: clear_focus()
		return false
	if hover_id != hit.id and panels.has(hover_id): panels[hover_id].leave_pointer()
	hover_id = hit.id
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if keyboard_id != hit.id: clear_focus()
			keyboard_id = hit.id
			capture_id = hit.id
			# Do not arm html_text_focus here: a non-field click would swallow WASD until
			# panel_focus arrives. Field focus is confirmed by the HTML page instead.
		else: capture_id = ""
	panels[hit.id].forward_pointer(event, hit.position)
	# FPS aims the pointer with the view, including while dragging a UI control.
	# Forward the same motion to mouse-look; only cursor-mode UI owns mouse motion.
	return not event is InputEventMouseMotion or not app.fps_active

func tick() -> void:
	sync_pinned_presentation()
	for view in views(): view.tick()
	for id in windows.keys():
		if windows[id].get_meta("closing") and not windows[id].get_meta("inspector").has_active_edits(): close_window(id)
	for id in pending_panel_close.keys():
		if not app.objects.has(id): pending_panel_close.erase(id)
		elif not views().any(func(view): return view.panel_id == id and view.has_active_edits()): close_panel(id)
	refresh_gizmos()

func disconnected() -> void:
	sessions.clear()
	clear_focus()
	for view in views(): view.disconnected()
