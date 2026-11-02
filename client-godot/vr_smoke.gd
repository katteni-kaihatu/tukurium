extends SceneTree
var app
var report := ""
func _initialize() -> void: call_deferred("run")
func until(test: Callable, reason: String) -> bool:
	for i in 900:
		await create_timer(0.025).timeout
		if FileAccess.file_exists(report + ".error"):
			push_error(FileAccess.get_file_as_string(report + ".error")); return false
		if test.call(): return true
	push_error(reason)
	return false
func click(button: Button) -> void:
	await process_frame
	var at := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at; motion.global_position = at
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = at; event.global_position = at; event.button_index = MOUSE_BUTTON_LEFT; event.pressed = true
	root.push_input(event, true)
	event = event.duplicate(); event.pressed = false
	root.push_input(event, true)
func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--vr-smoke-report="): report = arg.trim_prefix("--vr-smoke-report=")
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	if not await until(func(): return app.editable and app.player_initialized, "Desktop not ready"): quit(1); return
	var id: String = app.self_id
	var original_session: String = app.session
	app.vr.test_mode = "fail"
	await click(app.hud.vr_button)
	if not await until(func(): return app.vr.state == "desktop" and not app.vr.error_text.is_empty(), "Failure did not restore desktop"): quit(1); return
	if root.disable_3d or not app.hud.visible: push_error("Failure left desktop hidden"); quit(1); return
	app.vr.test_mode = "success"
	app.vr.test_script = "res://vr_child_smoke.gd"
	app.vr.test_arguments = PackedStringArray(["--vr-smoke-report=" + report])
	await click(app.vr.retry_button)
	if not await until(func(): return app.vr.state == "vr", "VR never became active"): quit(1); return
	if not AudioServer.is_bus_mute(0): push_error("Waiting desktop duplicated VR audio"); quit(1); return
	if not await until(func(): return app.vr.state == "desktop", "Private VR exit did not restore desktop"): quit(1); return
	if not FileAccess.file_exists(report): push_error("VR input checks missing"); quit(1); return
	if app.self_id != id or app.session != original_session: push_error("Handoff changed participant/session"); quit(1); return
	if app.fps_active or Input.mouse_mode != Input.MOUSE_MODE_VISIBLE: push_error("Return captured the mouse"); quit(1); return
	if AudioServer.is_bus_mute(0): push_error("Desktop audio was not restored"); quit(1); return
	app.vr.test_script = ""
	app.vr.test_arguments = PackedStringArray()
	app.vr.test_mode = "hang"
	await click(app.hud.vr_button)
	if not await until(func(): return app.vr.child_pid > 0, "Pending child not started"): quit(1); return
	await click(app.vr.cancel_button)
	if not await until(func(): return app.vr.state == "desktop", "Cancel did not restore desktop"): quit(1); return
	await click(app.hud.vr_button)
	if not await until(func(): return app.vr.child_pid > 0, "Timeout child not started"): quit(1); return
	app.vr.deadline = Time.get_ticks_msec() - 1
	if not await until(func(): return app.vr.state == "desktop", "Timeout did not restore desktop"): quit(1); return
	app.vr.test_mode = "success"
	for i in 10:
		await click(app.hud.vr_button)
		if not await until(func(): return app.vr.state == "vr", "Repeated VR entry failed"): quit(1); return
		await click(app.vr.cancel_button)
		if not await until(func(): return app.vr.state == "desktop", "PC return button failed"): quit(1); return
	await click(app.hud.vr_button)
	if not await until(func(): return app.vr.state == "vr", "Reentry failed"): quit(1); return
	OS.kill(app.vr.child_pid)
	if not await until(func(): return app.vr.state == "desktop", "Child crash did not restore desktop"): quit(1); return
	if root.disable_3d or not app.hud.visible: push_error("Crash left desktop hidden"); quit(1); return
	print("VR SWITCH SMOKE PASS")
	quit()
