extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func until(test: Callable, message: String) -> bool:
	for _i in 600:
		await create_timer(0.025).timeout
		if test.call(): return true
	push_error(message)
	return false

func mouse(button: int, pressed: bool, point: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = button
	event.pressed = pressed
	root.push_input(event,true)

func fps_click(scene, panel, control: Control) -> void:
	await process_frame
	var point := control.get_global_rect().get_center()
	var local := Vector3((point.x/panel.viewport.size.x-0.5)*panel.mesh.size.x,(0.5-point.y/panel.viewport.size.y)*panel.mesh.size.y,0.025)
	var direction: Vector3 = (panel.to_global(local)-scene.camera.global_position).normalized()
	var motion := InputEventMouseMotion.new()
	motion.position = root.size*0.5
	motion.relative = Vector2(wrapf(scene.orbit_yaw-atan2(-direction.x,-direction.z),-PI,PI),scene.orbit_pitch-asin(direction.y))/0.003
	root.push_input(motion,true)
	await process_frame
	await process_frame
	var hit: Dictionary = scene.world_panels.pick(root.size*0.5)
	if hit.get("id","") != panel.panel_id:
		push_error("Panel control is occluded: expected="+panel.panel_id+" hit="+str(hit.get("id","none"))); quit(1); return
	mouse(MOUSE_BUTTON_LEFT,true,root.size*0.5)
	mouse(MOUSE_BUTTON_LEFT,false,root.size*0.5)

func run() -> void:
	var scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	if not await until(func(): return scene.editable and not scene.current.is_empty(),"Scene not ready"): quit(1); return
	scene.hud.set_edit_mode(true)
	var target: String = scene.selected_id
	for _i in 2: scene.world_panels.open_script_editor(target)
	if not await until(func(): return scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null).size() == 2,"Shared Script Editors missing"): quit(1); return
	var panels: Array = scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null)
	if not await until(func(): return panels[0].content.script_mount.visible and panels[1].content.script_mount.visible,"Script Editor mounts did not open"): quit(1); return
	var a = panels[0].content.script_view
	var b = panels[1].content.script_view
	if not await until(func(): return not a.document.is_empty() and not b.document.is_empty(),"Documents did not open"): quit(1); return
	var original: String = a.editor.code.text
	a.editor.code.text = "-- Alice\n" + original
	a.editor.code.text_changed.emit()
	b.editor.code.text = "-- Bob\n" + original
	b.editor.code.text_changed.emit()
	a.flush()
	b.flush()
	# Type again while the first request is still awaiting acknowledgement.
	a.editor.code.text += "\n-- more from Alice\n"
	a.editor.code.text_changed.emit()
	if not await until(func(): return a.flight.is_empty() and b.flight.is_empty() and a.editor.code.text == b.editor.code.text and a.editor.code.text.contains("-- Alice") and a.editor.code.text.contains("-- Bob") and a.editor.code.text.contains("-- more from Alice"),"Concurrent edits did not converge"): quit(1); return
	if scene.objects[target].scripts[0].source == a.editor.code.text:
		push_error("Draft was executed before Apply"); quit(1); return
	a.editor.code.text += "\n-- Apply while synchronizing\n"
	a.editor.code.text_changed.emit()
	a.flush()
	a.editor.apply_button.pressed.emit()
	if not await until(func(): return a.editor.pending_id.is_empty() and a.pending_action.is_empty() and scene.objects[target].scripts[0].source == a.editor.code.text,"Apply did not compile the shared draft"): quit(1); return
	if not await until(func(): return a.document.get("cursors",[]).size() >= 2,"Multiple cursors not visible"): quit(1); return
	var id: String = a.editor.selected
	a.editor.code.text += "\n-- syntax stays in the shared draft: (\n"
	a.editor.code.text_changed.emit()
	if not await until(func(): return a.flight.is_empty() and a.editor.code.text == b.editor.code.text,"Draft tail did not replicate"): quit(1); return
	# A comment containing an unmatched parenthesis remains valid; now test invalid source.
	var valid: String = scene.objects[target].scripts[0].source
	a.editor.code.text += "return ("
	a.editor.code.text_changed.emit()
	if not await until(func(): return a.flight.is_empty() and a.editor.code.text == b.editor.code.text,"Invalid draft not shared"): quit(1); return
	a.editor.apply_button.pressed.emit()
	if not await until(func(): return a.editor.pending_id.is_empty(),"Apply error response missing"): quit(1); return
	if scene.objects[target].scripts[0].source != valid:
		push_error("Invalid draft replaced running code"); quit(1); return
	# Restore the shared draft, then capture the real world-panel viewport.
	a.editor.code.text = valid
	a.editor.code.text_changed.emit()
	if not await until(func(): return a.flight.is_empty() and a.editor.code.text == b.editor.code.text,"Draft restore did not converge"): quit(1); return
	b.request("cursor",{"anchor":b.document.ids[mini(12,b.document.ids.size()-1)],"head":b.document.ids[mini(12,b.document.ids.size()-1)],"name":"Bob"},func(_r): pass)
	await create_timer(0.2).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			panels[0].viewport.get_texture().get_image().save_png(arg.trim_prefix("--screenshot="))
	# Use the actual FPS ray/input path for removal and creation, not signal-only tests.
	scene.world_panels.close_panel(panels[1].panel_id)
	if not await until(func(): return scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null).size()==1,"Extra Script Editor did not close"): quit(1); return
	var panel = panels[0]
	scene.set_view_mode(1)
	scene.orbit_yaw = 0
	scene.orbit_pitch = 0
	var position: Vector3 = scene.player_position + Vector3(0,1.15,-2)
	scene.world_panels.edit(panel.panel_id,"position",[position.x,position.y,position.z])
	scene.world_panels.edit(panel.panel_id,"rotation",[0,0,0,1])
	if not await until(func(): return panel.position.distance_to(position)<0.01 and not a.editor.remove_button.disabled,"Removal controls not ready"): quit(1); return
	await fps_click(scene,panel,a.editor.remove_button)
	if root.find_children("*","Window",true,false).any(func(w): return w.visible and w.exclusive):
		push_error("Script removal opened an exclusive subwindow that blocks world input"); quit(1); return
	if not await until(func(): return a.editor.remove_confirmation.visible,"Inline removal confirmation did not open"): quit(1); return
	if not scene.fps_active or scene.gameplay_keyboard_blocked(): push_error("Removal confirmation blocks FPS movement"); quit(1); return
	var before: Vector3 = scene.player_target_position
	Input.action_press("move_right")
	var moved: bool = await until(func(): return scene.player_target_position.distance_to(before)>0.15,"Removal confirmation froze movement")
	Input.action_release("move_right")
	if not moved: quit(1); return
	await fps_click(scene,panel,a.editor.remove_cancel_button)
	if a.editor.remove_confirmation.visible or scene.objects[target].scripts.is_empty(): push_error("Cancel removed the script or left confirmation open"); quit(1); return
	await fps_click(scene,panel,a.editor.remove_button)
	await fps_click(scene,panel,a.editor.remove_confirm_button)
	if not await until(func(): return scene.objects[target].get("scripts",[]).is_empty() and a.editor.pending_id.is_empty(),"FPS script removal failed"): quit(1); return
	await fps_click(scene,panel,a.editor.graph_button)
	if not await until(func(): return scene.objects[target].get("scripts",[]).size() == 1 and a.editor.pending_id.is_empty() and a.editor.is_graph(),"FPS node graph creation failed"): quit(1); return
	if not a.document.is_empty() or not a.editor.graph.visible:
		push_error("Graph editor incorrectly uses the Lua text draft"); quit(1); return
	scene.world_panels.open_script_editor(target)
	if not await until(func(): return scene.world_panels.panels.values().filter(func(p): return p.content.get("script_view") != null).size() == 2,"Second Script Editor missing"): quit(1); return
	var other = scene.world_panels.panels.values().filter(func(p): return p.panel_id != panel.panel_id and p.content.get("script_view") != null)[0]
	var graph_peer = other.content.script_view
	if not await until(func(): return not a.graph_document.is_empty() and not graph_peer.graph_document.is_empty(),"Graph drafts did not open on both panels"): quit(1); return
	var original_graph: String = scene.objects[target].scripts[0].source
	a.editor.graph.component_name.text = "SharedGraph"
	a.editor.graph.component_name.text_changed.emit("SharedGraph")
	graph_peer.editor.graph.canvas.get_node("n1").position_offset += Vector2(30,0)
	graph_peer.editor.graph.canvas.end_node_move.emit()
	if not await until(func(): return a.graph_queue.is_empty() and graph_peer.graph_queue.is_empty() and a.editor.graph.data == graph_peer.editor.graph.data and a.editor.graph.data.name == "SharedGraph" and float(a.editor.graph.data.nodes[0].x) == 70.0,"Concurrent graph edits did not converge"): quit(1); return
	if scene.objects[target].scripts[0].source != original_graph: push_error("Graph draft executed before Apply"); quit(1); return
	a.editor.apply_button.pressed.emit()
	if not await until(func(): return a.editor.pending_id.is_empty() and scene.objects[target].scripts[0].source.contains("SharedGraph"),"Shared graph draft Apply failed"): quit(1); return
	scene.world_panels.close_panel(other.panel_id)
	if not await until(func(): return scene.world_panels.panels.size() == 1,"Second graph inspector did not close"): quit(1); return
	a.editor.graph.add_node("on_interact")
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and scene.objects[target].scripts[0].source.contains("on_interact"),"Shared graph Apply failed"): quit(1); return
	# Editing a graph with an existing Field binding must preserve the reference.
	a.editor.graph.add_node("write_field")
	a.editor.graph.data.nodes[2].id = "paint"
	a.editor.graph.redraw()
	a.editor.graph.touch()
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and scene.objects[target].scripts[0].parameters.has("ref_paint"),"Shared graph Field parameter missing"): quit(1); return
	var reference := {"kind":"field","target":scene.field_address(target,"color"),"field_id":"color"}
	var destination = a.editor.parameter_controls.ref_paint
	await process_frame
	if destination.get_global_rect().size.x < 80 or destination.get_global_rect().end.x > a.editor.parameters.get_global_rect().end.x + 2:
		push_error("Field binding control is clipped in the shared inspector"); quit(1); return
	var malformed := {"kind":"kokoverse_reference","reference":{"kind":"field","target":{"instance_id":target,"local_id":"2"},"field_id":"color"}}
	if destination._can_drop_data(Vector2.ZERO,malformed): push_error("Malformed Field reference was accepted"); quit(1); return
	var dragged := {"kind":"kokoverse_reference","reference":reference}
	if not destination._can_drop_data(Vector2.ZERO,dragged): push_error("Valid Field reference was rejected"); quit(1); return
	scene.world_panels.carried_reference = dragged
	var drop := InputEventMouseButton.new()
	drop.button_index = MOUSE_BUTTON_LEFT
	drop.pressed = true
	destination._gui_input(drop)
	if not scene.world_panels.carried_reference.is_empty(): push_error("Dropped Field reference remained carried"); quit(1); return
	if not await until(func(): return a.editor.pending_id.is_empty() and scene.objects[target].scripts[0].parameters.get("ref_paint") is Dictionary,"Shared graph Field binding not saved"): quit(1); return
	a.editor.graph.canvas.get_node("paint").position_offset += Vector2(20,0)
	a.editor.graph.canvas.end_node_move.emit()
	a.editor.queued_parameters.ref_paint = malformed.reference
	await fps_click(scene,panel,a.editor.apply_button)
	if not a.editor.pending_id.is_empty() or not a.editor.feedback.text.contains("Invalid field reference for ref_paint") or a.editor.queued_parameters.has("ref_paint"):
		push_error("Malformed queued Field reference was sent or not explained"); quit(1); return
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and not a.editor.source_dirty,"Bound shared graph did not reapply: " + a.editor.feedback.text): quit(1); return
	if scene.objects[target].scripts[0].parameters.ref_paint.get("field_id") != "color": push_error("Shared graph Apply lost Field binding"); quit(1); return
	a.editor.graph.add_node("number")
	var number_id: String = str(a.editor.graph.data.nodes[3].id)
	var number_input: LineEdit = a.editor.graph.canvas.get_node(number_id).find_children("*","LineEdit",true,false)[0]
	number_input.text = "2"
	number_input.text_changed.emit("2")
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and not a.editor.source_dirty,"Graph with number and Field binding did not apply"): quit(1); return
	number_input = a.editor.graph.canvas.get_node(number_id).find_children("*","LineEdit",true,false)[0]
	number_input.text = "3"
	number_input.text_changed.emit("3")
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and not a.editor.source_dirty,"Changing an existing graph number to 3 failed: " + a.editor.feedback.text): quit(1); return
	if scene.objects[target].scripts[0].parameters.ref_paint.get("field_id") != "color": push_error("Changing a graph number lost ref_paint"); quit(1); return
	# Repeat the actual workshop graph: change its period node from 2 to 3.
	var fixture_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--graph-fixture="): fixture_path = arg.trim_prefix("--graph-fixture=")
	var examples = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	if not examples is Array or examples.size() < 4: push_error("Workshop graph fixture missing"); quit(1); return
	var blink_source: String = a.editor.graph.PREFIX + JSON.stringify(examples[3])
	var attached := {}
	scene.world_panels.command({"kind":"script","command":{"target":scene.address_of(scene.objects[target]),"action":"attach","source":blink_source}},func(result): attached.merge(result))
	if not await until(func(): return attached.has("ok") and scene.objects[target].scripts.size() == 2,"Workshop graph was not attached"): quit(1); return
	if not attached.ok: push_error("Workshop graph attach failed: " + str(attached.get("message",""))); quit(1); return
	a.editor.select_script(1)
	if not await until(func(): return a.editor.is_graph() and a.editor.current_script().get("schema",{}).get("name") == "BlinkBeacon" and a.editor.parameter_controls.has("ref_paint"),"Workshop graph did not open"): quit(1); return
	a.editor.parameter_controls.ref_paint.received.call({"reference":reference})
	if not await until(func(): return a.editor.pending_id.is_empty() and a.editor.current_script().parameters.get("ref_paint") is Dictionary,"Workshop graph reference was not bound"): quit(1); return
	var select_node: GraphNode = a.editor.graph.canvas.get_node("choice")
	if not select_node.find_children("*","Label",true,false).any(func(label): return label.text == "COLOR"):
		push_error("Select did not show the connected Color type"); quit(1); return
	if not a.editor.graph.canvas.get_node("paint").find_children("*","Label",true,false).any(func(label): return label.text == "COLOR"):
		push_error("Drive Field did not show its bound Color type"); quit(1); return
	var period: LineEdit = a.editor.graph.canvas.get_node("two").find_children("*","LineEdit",true,false)[0]
	period.text = "3"
	period.text_changed.emit("3")
	await fps_click(scene,panel,a.editor.apply_button)
	if not await until(func(): return a.editor.pending_id.is_empty() and not a.editor.source_dirty,"Workshop period change failed: " + a.editor.feedback.text): quit(1); return
	var saved_graph = JSON.parse_string(a.editor.current_script().source.substr(a.editor.graph.PREFIX.length()))
	var saved_period: Array = saved_graph.nodes.filter(func(item): return item.id == "two")
	if a.editor.current_script().parameters.ref_paint.get("field_id") != "color" or saved_period.size() != 1 or float(saved_period[0].value) != 3.0:
		push_error("Workshop period or Field reference changed unexpectedly"); quit(1); return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			var graph_canvas: GraphEdit = a.editor.graph.canvas
			graph_canvas.zoom = 0.8
			graph_canvas.scroll_offset = Vector2(200,220)
			await process_frame
			panel.viewport.get_texture().get_image().save_png(arg.trim_prefix("--screenshot=").get_base_dir().path_join("graph-types.png"))
	scene.release_cursor()
	await process_frame
	var graph_point: Vector2 = a.editor.graph.canvas.get_global_rect().position + Vector2(120,55)
	var graph_local := Vector3((graph_point.x/panel.viewport.size.x-0.5)*panel.mesh.size.x,(0.5-graph_point.y/panel.viewport.size.y)*panel.mesh.size.y,0.025)
	var graph_screen: Vector2 = scene.camera.unproject_position(panel.to_global(graph_local))
	mouse(MOUSE_BUTTON_RIGHT,true,graph_screen)
	mouse(MOUSE_BUTTON_RIGHT,false,graph_screen)
	if not await until(func(): return a.editor.graph.context_panel.visible,"Right-click did not reach the shared graph canvas"): quit(1); return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			panel.viewport.get_texture().get_image().save_png(arg.trim_prefix("--screenshot=").get_base_dir().path_join("graph-context.png"))
	a.editor.graph.context_panel.hide()
	scene.set_view_mode(1)
	# The New entry must open an operable world panel even immediately after removal.
	mouse(MOUSE_BUTTON_MIDDLE,true,root.size*0.5)
	mouse(MOUSE_BUTTON_MIDDLE,false,root.size*0.5)
	if not scene.hud.ring.visible: push_error("Ring blocked after script removal"); quit(1); return
	var new_point: Vector2 = scene.hud.ring.center + Vector2(0,125)
	mouse(MOUSE_BUTTON_LEFT,true,new_point)
	mouse(MOUSE_BUTTON_LEFT,false,new_point)
	if not await until(func(): return scene.world_panels.panels.values().any(func(p): return not p.inspector_content),"New object dialog did not appear after script removal"): quit(1); return
	var creation = scene.world_panels.panels.values().filter(func(p): return not p.inspector_content)[0]
	var creation_id: String = creation.panel_id
	if not await until(func(): return not scene.gameplay_keyboard_blocked() and scene.fps_active,"New object panel blocks FPS"): quit(1); return
	var count: int = scene.objects.size()
	await fps_click(scene,creation,creation.content.create_button)
	if not await until(func(): return not scene.objects.has(creation_id) and scene.objects.size()==count,"Creating an object after script removal failed"): quit(1); return
	print("SCRIPT DIALOGS PASS: inline cancel/remove, FPS movement, New panel and creation")
	print("SHARED SCRIPT SMOKE PASS: concurrent drafts, multiple cursors, Apply and syntax errors")
	quit(0)
