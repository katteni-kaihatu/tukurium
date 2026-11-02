extends SceneTree
## Simulated XR input used only by the rendered integration test.
var app
var report := ""
func _initialize() -> void: call_deferred("run")
func until(test: Callable) -> bool:
	for i in 600:
		await create_timer(0.025).timeout
		if test.call(): return true
	return false
func check(test: bool, reason: String) -> bool:
	if not test:
		FileAccess.open(report + ".error", FileAccess.WRITE).store_string(reason)
		push_error(reason)
		quit(1)
	return test
func press(button: Button) -> void:
	await process_frame
	var rig = app.vr.rig
	var point := button.get_global_rect().get_center()
	var menu = rig.menu
	var local := Vector3((point.x / menu.viewport.size.x - 0.5) * menu.mesh.size.x, (0.5 - point.y / menu.viewport.size.y) * menu.mesh.size.y, 0)
	var target: Vector3 = menu.to_global(local)
	rig.right.global_position = target + menu.global_basis.z * 0.4
	rig.right.look_at(target)
	rig.tick()
	rig.pointer(true)
	rig.pointer(false)
	await process_frame
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--vr-smoke-report="): report = arg.trim_prefix("--vr-smoke-report=")
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	if not check(await until(func(): return app.vr.state == "vr"), "VR child did not become active"): return
	var rig = app.vr.rig
	if not check(rig != null and root.disable_3d, "VR viewport did not replace desktop rendering"): return
	await create_timer(0.2).timeout
	rig.test_focused = false
	rig.test_left = Vector2(0, 1)
	if not check(not rig.player_input().active, "Unfocused VR accepted movement"): return
	rig.test_focused = true
	if not check(not rig.player_input().active, "Held stick resumed without neutral"): return
	rig.test_left = Vector2.ZERO
	rig.player_input()
	var start: Vector3 = app.player_target_position
	rig.test_left = Vector2(0, 1)
	await create_timer(0.25).timeout
	if not check(app.player_target_position.distance_to(start) > 0.3, "VR movement did not reach Rust"): return
	rig.test_left = Vector2.ZERO
	await create_timer(0.3).timeout
	rig.eye.position.x = 0.25
	rig.tick()
	var head_before: Vector3 = rig.eye.global_position
	rig.test_right = Vector2(1, 0)
	rig.player_input()
	rig.tick()
	if not check(rig.eye.global_position.distance_to(head_before) < 0.0001, "Snap turn moved the offset head"): return
	rig.test_right = Vector2.ZERO
	rig.left.button_pressed.emit("by_button")
	if not check(rig.menu.visible, "Left B did not open the private menu"): return
	if not check(not rig.player_input().active, "Private menu accepted movement"): return
	await press(rig.recenter_button)
	if not check(not rig.menu.visible, "Ray/trigger did not activate recenter"): return
	rig.left.button_pressed.emit("by_button")
	await process_frame
	if not check(rig.menu.content.get_combined_minimum_size().y <= rig.menu.viewport.size.y, "VR menu exceeds its viewport"): return
	await RenderingServer.frame_post_draw
	rig.viewport.get_texture().get_image().save_png(report + ".png")
	FileAccess.open(report, FileAccess.WRITE).store_string("VR movement, focus, snap turn and private menu passed")
	await press(rig.return_button)
	await create_timer(1.0).timeout
	check(false, "Ray/trigger did not exit VR")
