extends Node
## Desktop stays alive while a fresh OpenXR display uses the same Engine.
const RIG = preload("res://vr_rig.gd")
var app
var state := "desktop"
var child := false
var token := ""
var control := false
var xr: OpenXRInterface
var rig
var view_yaw := 0.0
var child_pid := -1
var deadline := 0
var generation := 0
var attaching := false
var attached := false
var ready_sent := false
var audio_was_muted := false
var error_text := ""
var test_mode := ""
var test_script := ""
var test_arguments := PackedStringArray()
var overlay := CanvasLayer.new()
var box := PanelContainer.new()
var status_label := Label.new()
var cancel_button := Button.new()
var retry_button := Button.new()
var recenter_button := Button.new()

func setup(owner) -> void:
	app = owner
	audio_was_muted = AudioServer.is_bus_mute(0)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--vr-token="):
			token = argument.trim_prefix("--vr-token=")
			child = true
		if argument.begins_with("--vr-test="): test_mode = argument.trim_prefix("--vr-test=")
	build_overlay()
	if child:
		state = "starting"
		deadline = Time.get_ticks_msec() + 30000
		app.service_panel.auto_login = true
		app.avatar_restore_started = true
		if test_mode.is_empty(): xr = XRServer.find_interface("OpenXR")
		set_world_paused(true)
	refresh()

func build_overlay() -> void:
	overlay.layer = 60
	add_child(overlay)
	box.position = Vector2(20, 90)
	box.custom_minimum_size = Vector2(370, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("101b25")
	style.set_content_margin_all(20)
	style.set_corner_radius_all(12)
	box.add_theme_stylebox_override("panel", style)
	overlay.add_child(box)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	box.add_child(column)
	status_label.custom_minimum_size.x = 340
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status_label)
	cancel_button.text = "キャンセル"
	cancel_button.pressed.connect(stop)
	column.add_child(cancel_button)
	retry_button.text = "再試行"
	retry_button.pressed.connect(start)
	column.add_child(retry_button)
	recenter_button.text = "正面を合わせる"
	recenter_button.pressed.connect(func():
		if rig != null: rig.recenter())
	column.add_child(recenter_button)
	for button in [cancel_button, retry_button, recenter_button]:
		button.custom_minimum_size.y = 40
		button.focus_mode = Control.FOCUS_NONE

func request_switch(action: String, completed: Callable, extra: Dictionary = {}) -> void:
	var body := {"kind":"presentation", "action":action, "token":token}
	body.merge(extra, true)
	app.requests.request(body, completed, ["request_id"], "request_id", 8000, "presentation_result")

func start() -> void:
	if child or state != "desktop": return
	if not app.connected or not app.player_initialized or not app.editable:
		show_error("セッションへの接続を待ってから、VRに入ってください。")
		return
	if app.pending or not app.inspector_edits.is_empty() or app.camera_tool.active:
		show_error("編集中の操作を完了してから、VRに入ってください。")
		return
	for request in app.requests.requests.values():
		if request.kind in ["edit", "structure", "transform", "script", "playback", "edit_session"]:
			show_error("編集の反映を待ってから、VRに入ってください。")
			return
	for view in app.world_panels.views():
		if view.edits.values().any(func(edit): return edit.dirty or edit.inflight) or not view.script_view.flight.is_empty():
			show_error("パネルの編集を完了してから、VRに入ってください。")
			return
	app.release_cursor()
	app.world_panels.clear_focus()
	audio_was_muted = AudioServer.is_bus_mute(0)
	generation += 1
	var attempt := generation
	state = "starting"
	error_text = ""
	deadline = Time.get_ticks_msec() + 30000
	refresh()
	request_switch("begin", func(reply):
		if not reply.get("ok", false):
			if attempt == generation: show_error("VR切り替えを開始できませんでした。接続を確認して再試行してください。")
			return
		var issued: String = reply.data.token
		if attempt != generation:
			request_switch("stop", func(_r): pass, {"token":issued})
			return
		token = issued
		var args := PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), "--rendering-method", "gl_compatibility", "--xr-mode", "on" if test_mode.is_empty() else "off"])
		if not test_script.is_empty(): args.append_array(["--script", test_script])
		args.append_array(["--", "--port=" + str(app.port), "--session=" + app.session, "--close-with-engine", "--vr-token=" + token])
		if not test_mode.is_empty(): args.append("--vr-test=" + test_mode)
		args.append_array(test_arguments)
		child_pid = OS.create_instance(args)
		if child_pid < 0: stop_with_error("VR用の画面を起動できませんでした。"))

func stop() -> void:
	stop_with_error("")

func stop_with_error(message: String) -> void:
	if state in ["desktop", "stopping"]: return
	generation += 1
	error_text = message
	if token.is_empty():
		state = "desktop"
		refresh()
		return
	state = "stopping"
	refresh()
	var stopping_token := token
	request_switch("stop", func(reply):
		if token != stopping_token or state != "stopping": return
		if not reply.get("ok", false):
			if child: app.get_tree().quit()
			else: restore_desktop(message), {"message":message})

func show_error(message: String) -> void:
	error_text = message
	state = "desktop"
	refresh()

func set_world_paused(value: bool) -> void:
	app.get_viewport().disable_3d = value
	# Both displays may decode the same video; only the active one emits sound.
	AudioServer.set_bus_mute(0, audio_was_muted or (value and not (child and control)))
	app.hud.visible = not value
	app.social_panels.visible = not value
	app.service_panel.visible = not value
	app.asset_status.get_child(0).visible = not value

func restore_desktop(message: String) -> void:
	if child_pid > 0 and OS.is_process_running(child_pid): OS.kill(child_pid)
	child_pid = -1
	state = "desktop"
	control = false
	token = ""
	deadline = 0
	app.orbit_yaw = app.player_yaw
	app.orbit_pitch = 0.0
	if not app.avatar_camera:
		app.camera.position = app.player_position + Vector3(0, 1.15, 0)
		app.camera.rotation = Vector3(0, app.player_yaw, 0)
	app.release_cursor()
	set_world_paused(false)
	app.get_window().grab_focus()
	if not message.is_empty(): error_text = friendly_error(message)
	refresh()

func friendly_error(message: String) -> String:
	if message in ["VR display disconnected", "VR startup timed out"]:
		return "VR用の画面が終了したか、起動がタイムアウトしました。SteamVRとIndexを確認して再試行してください。"
	return message

func receive(body: Dictionary) -> void:
	if body.get("token", "") != token: return
	if body.get("shutdown", false):
		app.get_tree().quit()
		return
	if body.state == "vr":
		state = "vr"
		control = body.get("control", false)
		deadline = 0
		if child:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			Engine.max_fps = 0
		set_world_paused(true)
		refresh()
	elif body.state == "desktop" and not child:
		restore_desktop(str(body.get("message", "")))

func tick() -> void:
	if child:
		if rig != null: rig.tick()
		if not attaching and app.connected and app.player_initialized:
			attaching = true
			request_switch("attach", func(reply):
				if not reply.get("ok", false): app.get_tree().quit(); return
				attached = true
				if test_mode == "fail" or (test_mode.is_empty() and (xr == null or not xr.is_initialized())):
					stop_with_error("VRを開始できませんでした。SteamVRを起動し、Indexの接続とOpenXRの設定を確認してください。")
					return
				if test_mode == "hang": return
				rig = RIG.new()
				add_child(rig)
				rig.setup(app, self, not test_mode.is_empty())
				if xr != null:
					for signal_name in ["session_stopping", "session_loss_pending", "instance_exiting"]:
						xr.connect(signal_name, func(): stop_with_error("SteamVRとの接続が終了しました。")))
		if attached and rig != null and not ready_sent and rig.tracked():
			rig.recenter()
			rig.tick()
			ready_sent = true
			request_switch("ready", func(reply):
				if not reply.get("ok", false): app.get_tree().quit())
	if deadline > 0 and Time.get_ticks_msec() > deadline and state == "starting":
		stop_with_error("VRの起動がタイムアウトしました。SteamVRとIndexを確認してください。")
	if not child and child_pid > 0 and state in ["starting", "vr"] and not OS.is_process_running(child_pid):
		stop_with_error("VR用の画面が終了しました。SteamVRとIndexを確認してください。")

func refresh() -> void:
	box.visible = child or state != "desktop" or not error_text.is_empty()
	status_label.text = error_text if state == "desktop" else ("VRを準備中…\nSteamVRとIndexを確認してください。" if state == "starting" else ("デスクトップに戻っています…" if state == "stopping" else "VRを使用中\nIndexの左BでVRメニューを開けます。"))
	cancel_button.text = "キャンセル" if state == "starting" else "デスクトップに戻る"
	cancel_button.visible = state in ["starting", "vr", "stopping"]
	cancel_button.disabled = state == "stopping"
	retry_button.visible = state == "desktop" and not error_text.is_empty()
	recenter_button.visible = child and state == "vr"
	if is_instance_valid(app.hud.vr_button):
		app.hud.vr_button.text = "VRを準備中…" if state == "starting" else "VRに入る"
		app.hud.vr_button.disabled = state != "desktop"

func blocks_desktop() -> bool:
	return child or state != "desktop"

func disconnected() -> void:
	if child:
		app.get_tree().quit()
	elif state != "desktop":
		generation += 1
		restore_desktop("接続が切れたため、デスクトップに戻りました。")

func _exit_tree() -> void:
	# This handle belongs to the child created by this exact display instance.
	if not child and child_pid > 0 and OS.is_process_running(child_pid): OS.kill(child_pid)
