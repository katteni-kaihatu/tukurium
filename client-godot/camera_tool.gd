extends Node
## A local viewfinder for a shared Camera component. Rust owns the parked pose and photo objects.
const DESKTOP_WINDOW = preload("res://desktop_window.gd")
const DesignChrome = preload("res://design_chrome.gd")
const MAX_SHARED_IMAGE_BYTES := 192 * 1024

var app
var overlay := CanvasLayer.new()
var frame = DESKTOP_WINDOW.new()
var viewport := SubViewport.new()
var eye := Camera3D.new()
var view := TextureRect.new()
var thumbnail := TextureRect.new()
var status := Label.new()
var shutter_button := Button.new()
var save_button := Button.new()
var share_button := Button.new()
var active := false
var looking := false
var busy := false
var target_id := ""
var position := Vector3.ZERO
var rotation := Quaternion.IDENTITY
var scale := Vector3.ONE
var yaw := 0.0
var pitch := 0.0
var revisions := {}
var changed := false
var held_keys := {}
var last_preview_at := 0
var captured_image: Image
var photo_directory := ""
var script_capture_pending := false
var script_capture_generation := 0

func setup(owner) -> void:
	app = owner
	add_child(overlay)
	overlay.layer = 30
	photo_directory = ProjectSettings.globalize_path("user://photos")
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.world_3d = app.get_world_3d()
	add_child(viewport)
	eye.near = 0.05
	eye.fov = 65.0
	viewport.add_child(eye)
	overlay.add_child(frame)
	frame.name = "CameraWindow"
	frame.position = Vector2(90, 90)
	frame.size = Vector2(720, 540)
	frame.minimum_window_size = Vector2(520, 420)
	frame.panel.add_theme_stylebox_override("panel", DesignChrome.panel(DesignChrome.PAPER, 18, 14, true))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	frame.panel.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	frame.use_titlebar(header)
	var title := Label.new()
	title.text = "◉  Camera"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", DesignChrome.INK)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "配置して閉じる"
	close_button.focus_mode = Control.FOCUS_NONE
	DesignChrome.style_ghost(close_button)
	close_button.pressed.connect(park)
	header.add_child(close_button)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.custom_minimum_size = Vector2(480, 270)
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	column.add_child(view)
	var hint := Label.new()
	hint.text = "WASD 移動  ·  Q/E 上下  ·  右ドラッグ 視点  ·  Shift 加速  ·  Esc 配置"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", DesignChrome.MUTED)
	column.add_child(hint)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	shutter_button.text = "● 撮影"
	DesignChrome.style_primary(shutter_button)
	shutter_button.pressed.connect(shoot)
	actions.add_child(shutter_button)
	save_button.text = "ローカル保存"
	save_button.disabled = true
	DesignChrome.style_quiet(save_button)
	save_button.pressed.connect(save_local)
	actions.add_child(save_button)
	share_button.text = "写真をワールドに置く"
	share_button.disabled = true
	DesignChrome.style_quiet(share_button)
	share_button.pressed.connect(share_photo)
	actions.add_child(share_button)
	var discard := Button.new()
	discard.text = "移動を戻す"
	DesignChrome.style_ghost(discard)
	discard.pressed.connect(reset_pose)
	actions.add_child(discard)
	var lower := HBoxContainer.new()
	column.add_child(lower)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.add_theme_font_size_override("font_size", 13)
	status.add_theme_color_override("font_color", DesignChrome.MUTED)
	lower.add_child(status)
	thumbnail.custom_minimum_size = Vector2(96, 54)
	thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	lower.add_child(thumbnail)
	frame.hide()

func is_camera(id: String) -> bool:
	return app.objects.has(id) and app.objects[id].get("camera") == true

func field_revisions(object: Dictionary) -> Dictionary:
	var result := {}
	for field in object.fields:
		if field.id in ["position", "rotation", "scale"]: result[field.id] = field.revision
	return result

func read_pose() -> void:
	var object: Dictionary = app.objects[target_id]
	var p: Array = object.world_position
	var q: Array = object.world_rotation
	var s: Array = object.world_scale
	position = Vector3(p[0], p[1], p[2])
	rotation = Quaternion(q[0], q[1], q[2], q[3])
	scale = Vector3(s[0], s[1], s[2])
	var angles := rotation.get_euler()
	yaw = angles.y
	pitch = angles.x
	revisions = field_revisions(object)
	changed = false
	update_eye()

func open(id: String) -> void:
	if not is_camera(id):
		app.feedback.text = "Camera コンポーネントが有効なSlotを選んでください。Edit → 新規作成 → Camera でも作れます。"
		return
	if active and target_id != id and changed:
		status.text = "先に現在のカメラを配置するか、移動を戻してください。"
		return
	if active: close_without_commit()
	target_id = id
	read_pose()
	app.release_cursor()
	app.release_player_input()
	app.hud.set_dock_open(false)
	captured_image = null
	thumbnail.texture = null
	save_button.disabled = true
	share_button.disabled = true
	status.text = "カメラを操作できます。右ドラッグで向きを変えます。"
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.texture = viewport.get_texture()
	active = true
	frame.show()
	frame.move_to_front()

func close_without_commit() -> void:
	if not active: return
	stop_looking()
	if app.connected: app.queue_message({"kind":"drag_preview", "preview":null})
	active = false
	script_capture_pending = false
	script_capture_generation += 1
	busy = false
	changed = false
	target_id = ""
	held_keys.clear()
	frame.hide()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	view.texture = null

func stop_looking() -> void:
	looking = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func reset_pose() -> void:
	if not active or busy or not is_camera(target_id): return
	if app.connected: app.queue_message({"kind":"drag_preview", "preview":null})
	read_pose()
	status.text = "共有ワールド上の位置に戻しました。"

func world_updated() -> void:
	if not active: return
	if not is_camera(target_id) or not app.editable:
		close_without_commit()
		return
	if busy: return
	if field_revisions(app.objects[target_id]) != revisions:
		if changed:
			status.text = "別の編集で位置が変わりました。ドローン操作を戻しました。"
			if app.connected: app.queue_message({"kind":"drag_preview", "preview":null})
		read_pose()
	elif not changed:
		read_pose()

func update_eye() -> void:
	var basis := Basis(rotation)
	eye.transform = Transform3D(basis, position - basis.z * 0.8)

func send_preview() -> void:
	if not active or not changed or not app.connected or not is_camera(target_id): return
	var now := Time.get_ticks_msec()
	if now - last_preview_at < 50: return
	last_preview_at = now
	app.queue_message({"kind":"drag_preview", "preview":{
		"target":app.address_of(app.objects[target_id]),
		"expected_revision":revisions.position,
		"expected_rotation_revision":revisions.rotation,
		"expected_scale_revision":revisions.scale,
		"position":[position.x,position.y,position.z],
		"rotation":[rotation.x,rotation.y,rotation.z,rotation.w],
		"scale":[scale.x,scale.y,scale.z]}})

func _process(delta: float) -> void:
	if not active or busy: return
	if not app.get_window().has_focus():
		held_keys.clear()
		stop_looking()
		return
	if not app.editable or not is_camera(target_id):
		close_without_commit()
		return
	var direction := Vector3.ZERO
	if held_keys.has(KEY_W): direction.z -= 1
	if held_keys.has(KEY_S): direction.z += 1
	if held_keys.has(KEY_A): direction.x -= 1
	if held_keys.has(KEY_D): direction.x += 1
	if held_keys.has(KEY_Q): direction.y -= 1
	if held_keys.has(KEY_E): direction.y += 1
	if direction != Vector3.ZERO:
		var speed := 9.0 if held_keys.has(KEY_SHIFT) else 3.0
		position += Basis(rotation) * direction.normalized() * speed * delta
		position = position.clamp(Vector3.ONE * -999.0, Vector3.ONE * 999.0)
		changed = true
		update_eye()
	send_preview()

func handle_input(event: InputEvent) -> bool:
	if not active: return false
	if event is InputEventKey:
		var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_ESCAPE and event.pressed and not event.echo:
			if looking: stop_looking()
			else: park()
			return true
		if key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_SHIFT]:
			if event.pressed: held_keys[key] = true
			else: held_keys.erase(key)
			return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed and view.get_global_rect().has_point(event.position):
			looking = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return true
		if not event.pressed and looking:
			stop_looking()
			return true
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and view.get_global_rect().has_point(event.position):
		eye.fov = clampf(eye.fov + (-5.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 5.0), 25.0, 90.0)
		AppLanguage.format_text(status,"画角 %d°",[int(eye.fov)])
		return true
	if event is InputEventMouseMotion and looking:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.45, 1.45)
		rotation = Quaternion.from_euler(Vector3(pitch, yaw, 0.0))
		changed = true
		update_eye()
		return true
	return false

func park() -> void:
	if not active or busy: return
	stop_looking()
	if not changed:
		close_without_commit()
		return
	if not app.editable or not is_camera(target_id):
		status.text = "共有ワールドに接続してから配置してください。"
		return
	busy = true
	status.text = "カメラの位置を共有ワールドに保存中…"
	var command := {
		"target":app.address_of(app.objects[target_id]),
		"space":"world",
		"expected_position_revision":revisions.position,
		"expected_rotation_revision":revisions.rotation,
		"expected_scale_revision":revisions.scale,
		"position":[position.x,position.y,position.z],
		"rotation":[rotation.x,rotation.y,rotation.z,rotation.w],
		"scale":[scale.x,scale.y,scale.z]}
	app.requests.request({"kind":"transform", "command":command}, func(result):
		busy = false
		if result.ok:
			app.feedback.text = "カメラを配置しました。"
			close_without_commit()
		else:
			status.text = result.get("message", "配置できませんでした")
			if is_camera(target_id): read_pose()
			if app.connected: app.queue_message({"kind":"drag_preview", "preview":null}))

func shoot() -> void:
	if not active or busy: return
	busy = true
	status.text = "撮影中…"
	await RenderingServer.frame_post_draw
	if not active:
		busy = false
		return
	captured_image = viewport.get_texture().get_image()
	busy = false
	if captured_image == null or captured_image.is_empty():
		status.text = "画像を取得できませんでした。"
		return
	thumbnail.texture = ImageTexture.create_from_image(captured_image)
	save_button.disabled = false
	share_button.disabled = not app.editable
	status.text = "撮影しました。ローカル保存かワールドへの配置を選べます。"

func capture_from_script(id: String) -> void:
	if script_capture_pending or not is_camera(id):
		return
	if active and target_id != id and changed:
		return
	if not active or target_id != id: open(id)
	if not active or target_id != id: return
	script_capture_pending = true
	script_capture_generation += 1
	var generation := script_capture_generation
	if generation == script_capture_generation and active and target_id == id and is_camera(id):
		await shoot()
		if generation == script_capture_generation and active and target_id == id and captured_image != null and not captured_image.is_empty():
			save_local()
	if generation == script_capture_generation: script_capture_pending = false

func save_local() -> void:
	if captured_image == null or captured_image.is_empty(): return
	var error := DirAccess.make_dir_recursive_absolute(photo_directory)
	if error != OK:
		status.text = "写真フォルダーを作成できませんでした。"
		return
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "-")
	var path := photo_directory.path_join("tukurium-" + stamp + "-" + str(Time.get_ticks_usec()) + ".png")
	error = captured_image.save_png(path)
	if error == OK: AppLanguage.format_text(status,"保存: %s",[path])
	else: status.text = "写真を保存できませんでした。"

func share_photo() -> void:
	if captured_image == null or captured_image.is_empty() or busy or not app.editable: return
	var image: Image = captured_image.duplicate()
	var largest := maxi(image.get_width(), image.get_height())
	if largest > 1024:
		image.resize(maxi(1, int(image.get_width() * 1024.0 / largest)), maxi(1, int(image.get_height() * 1024.0 / largest)), Image.INTERPOLATE_LANCZOS)
	var data: PackedByteArray = image.save_jpg_to_buffer(0.82)
	while data.size() > MAX_SHARED_IMAGE_BYTES and maxi(image.get_width(), image.get_height()) > 64:
		image.resize(maxi(1, int(image.get_width() * 0.75)), maxi(1, int(image.get_height() * 0.75)), Image.INTERPOLATE_LANCZOS)
		data = image.save_jpg_to_buffer(0.78)
	if data.size() > MAX_SHARED_IMAGE_BYTES:
		status.text = "写真が大きすぎます。"
		return
	var point := position - Basis(rotation).z * 2.2
	var facing := Quaternion(Vector3.UP, yaw)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "-")
	var command := {"action":"import_asset", "name":"Photo " + stamp,
		"position":[point.x,point.y,point.z],
		"rotation":[facing.x,facing.y,facing.z,facing.w],
		"visual":{"kind":"image", "data_url":"data:image/jpeg;base64," + Marshalls.raw_to_base64(data),
			"width":image.get_width(), "height":image.get_height()}}
	busy = true
	status.text = "写真をワールドに共有中…"
	app.requests.request({"kind":"structure", "command":command}, func(result):
		busy = false
		if result.ok:
			status.text = "写真をワールドに配置しました。"
			if result.get("selected") is Dictionary: app.select_object(result.selected.instance_id)
		else: status.text = result.get("message", "写真を共有できませんでした"))
