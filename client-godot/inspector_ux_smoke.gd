extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func until(test: Callable, message: String) -> bool:
	for _i in 600:
		await create_timer(0.025).timeout
		if test.call(): return true
	push_error(message)
	return false

func run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	if not await until(func(): return scene.editable and not scene.current.is_empty(), "Scene not ready"): quit(1); return
	scene.hud.set_edit_mode(true)
	if scene.inspector_shell.visible: push_error("Legacy inspector should start closed"); quit(1); return
	var initial_count: int = scene.objects.size()
	var initial_target: String = scene.selected_id
	scene.world_panels.open_inspector(scene.selected_id, true)
	if not await until(func(): return scene.world_panels.windows.size() == 1, "Native inspector did not open"): quit(1); return
	await create_timer(0.2).timeout
	if not scene.world_panels.panels.is_empty() or scene.objects.size() != initial_count:
		push_error("Opening a desktop inspector created a world object"); quit(1); return
	var window: Window = scene.world_panels.windows.values()[0]
	var view = window.get_meta("inspector")
	# Shared panels are created only by their own action.
	scene.world_panels.open_inspector(initial_target)
	if not await until(func(): return scene.world_panels.panels.size() == 1, "World panel did not open"): quit(1); return
	var panel = scene.world_panels.panels.values()[0]
	if scene.world_panels.windows.size() != 1: push_error("World panel created another native window"); quit(1); return
	var world_view = panel.content
	if window.get_window_id() == root.get_window_id() or view == world_view:
		push_error("Inspector is not an independent native view"); quit(1); return
	if view.get_script().resource_path != "res://desktop_inspector.gd" or window.is_embedded():
		push_error("Desktop inspector is not using its native layout"); quit(1); return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--window-probe="):
			print("NATIVE_WINDOW=", DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id()))
			if not await until(func(): return FileAccess.file_exists(argument.trim_prefix("--window-probe=") + ".done"), "Windows frame probe timed out"): quit(1); return
	var original_world_size: Vector2i = panel.viewport.size
	var original_panel_revision: String = scene.objects[panel.panel_id].object_revision
	window.size = Vector2i(950, 650)
	await process_frame
	await process_frame
	if not view.size.is_equal_approx(Vector2(window.size)) or panel.viewport.size != original_world_size:
		push_error("Desktop resize stretched the UI or changed world resolution"); quit(1); return
	view.scroll.scroll_vertical = 100
	await create_timer(0.25).timeout
	if scene.objects[panel.panel_id].object_revision != original_panel_revision:
		push_error("Desktop resize or scroll wrote shared panel data"); quit(1); return
	scene.world_panels.edit(panel.panel_id, "panel_size", [1024, 768])
	if not await until(func(): return panel.viewport.size == Vector2i(1024,768), "World resolution froze while desktop was open"): quit(1); return
	if not is_equal_approx(panel.mesh.size.x / panel.mesh.size.y, 1024.0 / 768.0):
		push_error("World panel pixels are stretched"); quit(1); return
	window.size = Vector2i(1100,800)
	if not await until(func(): return view.drive_labels.has("rotation") and view.drive_labels.rotation.visible, "Drive provenance is missing"): quit(1); return
	if view.controls.rotation[0].editable: push_error("Driven output should not appear writable"); quit(1); return
	if not view.controls.position[0].editable: push_error("Un-driven field should stay editable"); quit(1); return
	var sections: Array = []
	for section in view.fields_box.get_children():
		if section.get_child_count() < 2: continue
		var header: Node = section.get_child(1)
		if header is HBoxContainer and header.get_child_count() > 0:
			sections.append(header.get_child(0).text)
	for expected in ["Slot", "Transform", "MeshRenderer", "Scripts"]:
		if not sections.has(expected): push_error("Missing component section " + expected); quit(1); return
	if sections.has("MediaPlayback"): push_error("Non-video object showed MediaPlayback"); quit(1); return
	if not view.component_remove_buttons.has("MeshRenderer") or not view.component_remove_buttons.MeshRenderer.disabled:
		push_error("MeshRenderer with an attached script was removable"); quit(1); return
	if not scene.world_panels.has_window_focus() or not scene.gameplay_keyboard_blocked(): push_error("Native focus did not block gameplay"); quit(1); return
	var line: LineEdit = view.controls.name[0]
	line.grab_focus()
	if not await until(func(): return view.edits.has("name") and view.edits.name.granted, "Native field lease not granted"): quit(1); return
	if not await until(func(): return not world_view.controls.name[0].editable,"Spatial view did not respect native editor lease"): quit(1); return
	if not line.editable: push_error("Context-free desktop lease locked its own editor"); quit(1); return
	line.select_all()
	for character in "Native shared inspector":
		var event := InputEventKey.new()
		event.keycode = character.unicode_at(0)
		event.unicode = character.unicode_at(0)
		event.pressed = true
		window.push_input(event, true)
	if not await until(func(): return scene.world_panels.field_data(view.target_id, "name").value == "Native shared inspector", "Native typing not committed"): quit(1); return
	line.release_focus()
	var before_editors: int = scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null).size()
	view.open_script("")
	if not await until(func(): return scene.world_panels.panels.values().filter(func(p): return scene.objects.get(p.panel_id, {}).get("resources") != null).size() > 0, "Resources panel did not open from desktop inspector"): quit(1); return
	if world_view.script_mount.visible:
		push_error("Inspector still shows Scripts mount"); quit(1); return
	view.drive_buttons.rotation.pressed.emit()
	if not await until(func(): return scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null).size() > before_editors, "Driver did not open Script Editor"): quit(1); return
	var driver: Dictionary = scene.world_panels.field_driver(view.target_id, "rotation")
	var editor_panels: Array = scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null)
	var editor_panel = editor_panels[editor_panels.size() - 1]
	if not await until(func(): return editor_panel.content.script_view.editor.selected == driver.id, "Wrong driver selected in Script Editor"): quit(1); return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot="):
			await RenderingServer.frame_post_draw
			window.get_texture().get_image().save_png(argument.trim_prefix("--screenshot=").replace(".png", "-scripts.png"))
	if not view.scroll.visible:
		push_error("Object view should remain visible"); quit(1); return
	view.scroll.scroll_vertical = 0
	await process_frame
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot="):
			await RenderingServer.frame_post_draw
			window.get_texture().get_image().save_png(argument.trim_prefix("--screenshot="))
	view.controls.name[0].grab_focus()
	if not await until(func(): return view.edits.has("name") and view.edits.name.granted,"Final lease missing"): quit(1); return
	view.controls.name[0].text = "Native closed safely"
	view.controls.name[0].text_changed.emit("Native closed safely")
	var inspected_target: String = view.target_id
	window.close_requested.emit()
	if not await until(func(): return scene.world_panels.windows.is_empty(), "Native window did not close"): quit(1); return
	if scene.world_panels.field_data(inspected_target,"name").value != "Native closed safely":
		push_error("Closing the window lost the last edit"); quit(1); return
	if panel.content != world_view or panel.viewport.get_parent() != panel: push_error("Close replaced the shared view"); quit(1); return
	scene.world_panels.open_window(inspected_target)
	await process_frame
	# Removing a world panel must not close an independent local inspector.
	scene.world_panels.close_panel(panel.panel_id)
	if not await until(func(): return scene.world_panels.panels.is_empty(), "World panel did not close"): quit(1); return
	if scene.world_panels.windows.size() != 1: push_error("Deleting world panel closed local inspector"); quit(1); return
	var local_view = scene.world_panels.windows.values()[0].get_meta("inspector")
	local_view.choose_target("")
	if not await until(func(): return local_view.target_id.is_empty(), "Local target did not clear"): quit(1); return
	local_view.choose_target(inspected_target)
	if not await until(func(): return local_view.target_id == inspected_target, "Local target did not restore"): quit(1); return
	# Multiple local windows have independent selections and create no world objects.
	scene.world_panels.open_window("")
	var extra_id: String = scene.world_panels.windows.keys()[1]
	if scene.world_panels.windows[extra_id].get_meta("inspector").target_id != "" or local_view.target_id != inspected_target or scene.objects.size() != initial_count:
		push_error("Local windows share their selection or create world objects"); quit(1); return
	var created := {}
	scene.world_panels.command({"kind":"structure","command":{"action":"create"}}, func(result): created.merge(result))
	if not await until(func(): return created.has("selected") and scene.objects.has(created.selected.instance_id), "Temporary target not created"): quit(1); return
	var extra_view = scene.world_panels.windows[extra_id].get_meta("inspector")
	extra_view.choose_target(created.selected.instance_id)
	if not await until(func(): return extra_view.target_id == created.selected.instance_id, "Second local target not selected"): quit(1); return
	if local_view.target_id != inspected_target: push_error("Second local selection changed first window"); quit(1); return
	var removed: Dictionary = scene.objects[extra_view.target_id]
	var deletion := {}
	scene.world_panels.command({"kind":"structure","command":{"action":"delete","target":scene.address_of(removed),"expected_revision":removed.object_revision}},func(result): deletion.merge(result))
	if not await until(func(): return deletion.has("ok"), "Delete response missing"): quit(1); return
	if not deletion.ok: push_error("Delete failed: " + str(deletion.get("message", ""))); quit(1); return
	if not await until(func(): return extra_view.target_id.is_empty(), "Deleted target did not clear in local view"): quit(1); return
	if scene.world_panels.windows.size() != 2: push_error("Deleting inspected target closed its local window"); quit(1); return
	scene.world_panels.close_window(extra_id)
	scene.world_panels.close_window(local_view.panel_id)
	if not scene.world_panels.windows.is_empty(): push_error("Local windows did not close"); quit(1); return
	print("INSPECTOR UX SMOKE PASS: desktop-only creation, independent selections, native resize, shared edits, world tabs and separate lifetimes")
	scene.queue_free()
	await process_frame
	await process_frame
	quit(0)
