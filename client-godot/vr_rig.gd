extends Node3D
## Tracked display and private menu. Locomotion remains PlayerInput to Rust.
const WORLD_PANEL = preload("res://world_panel.gd")
var app
var session
var simulated := false
var viewport := SubViewport.new()
var origin := XROrigin3D.new()
var eye := XRCamera3D.new()
var left := XRController3D.new()
var right := XRController3D.new()
var menu = WORLD_PANEL.new()
var menu_status: Label
var recenter_button: Button
var return_button: Button
var yaw := 0.0
var center := Vector3.ZERO
var neutral := false
var turn_neutral := true
var pointer_down := false
var pointer_point := Vector2.ZERO
var laser := MeshInstance3D.new()
var laser_mesh := ImmediateMesh.new()
var test_left := Vector2.ZERO
var test_right := Vector2.ZERO
var test_focused := true
var test_tracked := true
var guard := MeshInstance3D.new()
var guard_label := Label3D.new()
var head_clear := true
var guard_request := false
var next_guard := 0
var trigger_neutral := false

func setup(owner, controller, fake: bool) -> void:
	app = owner
	session = controller
	simulated = fake
	yaw = app.player_yaw
	viewport.world_3d = app.get_world_3d()
	viewport.size = Vector2i(1024, 1024)
	viewport.use_xr = not simulated
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	viewport.add_child(origin)
	origin.add_child(eye)
	eye.current = true
	eye.near = 0.05
	eye.cull_mask = 0xfffff ^ app.AVATAR.SELF_AVATAR_LAYER ^ app.MIRROR_RENDERER.MIRROR_LAYER
	left.tracker = "left_hand"
	left.pose = "aim"
	right.tracker = "right_hand"
	right.pose = "aim"
	origin.add_child(left)
	origin.add_child(right)
	left.button_pressed.connect(func(action):
		if action == "by_button" and focused(): set_menu_open(not menu.visible))
	if simulated:
		eye.position = Vector3(0, 1.65, 0)
		right.position = Vector3(0.2, 1.35, -0.2)
	build_menu()
	build_laser()
	var shade := QuadMesh.new()
	shade.size = Vector2(4, 4)
	guard.mesh = shade
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.025, 0.035, 0.045)
	material.no_depth_test = true
	guard.material_override = material
	material.render_priority = 100
	guard.position.z = -0.1
	eye.add_child(guard)
	guard.hide()
	guard_label.text = "操作位置へ戻るか\n左Bでメニューを開いて\n正面を合わせてください"
	guard_label.font_size = 40
	guard_label.pixel_size = 0.0004
	guard_label.no_depth_test = true
	guard_label.position.z = -0.15
	eye.add_child(guard_label)
	menu.hide()
	recenter()

func build_menu() -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("101b25")
	style.set_corner_radius_all(22)
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	var theme := Theme.new()
	theme.default_font_size = 28
	panel.theme = theme
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	panel.add_child(column)
	var title := Label.new()
	title.text = "VRメニュー"
	title.add_theme_font_size_override("font_size", 40)
	column.add_child(title)
	menu_status = Label.new()
	menu_status.text = "右手のレーザーとトリガーで選択\n左Bで閉じる"
	menu_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(menu_status)
	recenter_button = Button.new()
	recenter_button.text = "正面を合わせる"
	recenter_button.add_theme_font_size_override("font_size", 32)
	recenter_button.custom_minimum_size.y = 86
	recenter_button.pressed.connect(recenter)
	column.add_child(recenter_button)
	return_button = Button.new()
	return_button.text = "デスクトップに戻る"
	return_button.add_theme_font_size_override("font_size", 32)
	return_button.custom_minimum_size.y = 86
	return_button.pressed.connect(session.stop)
	column.add_child(return_button)
	origin.add_child(menu)
	menu.setup_local(panel, Vector2i(720, 490), Vector2(0.8, 0.545))
	menu.material_override.no_depth_test = true
	menu.material_override.render_priority = 127
	menu.get_node("PickBody").collision_layer = 0

func build_laser() -> void:
	laser.mesh = laser_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("77dbce")
	material.no_depth_test = true
	laser.material_override = material
	add_child(laser)

func tracked() -> bool:
	if simulated: return test_tracked
	var head = XRServer.get_tracker("head")
	if head == null: return false
	var pose = head.get_pose("default")
	return pose != null and pose.has_tracking_data

func focused() -> bool:
	if simulated: return test_focused
	return session.xr != null and session.xr.get_session_state() == OpenXRInterface.SESSION_STATE_FOCUSED and (not session.xr.is_user_presence_supported() or session.xr.is_user_present())

func axes(controller: XRController3D, fake: Vector2) -> Vector2:
	return fake if simulated else (controller.get_vector2("primary") if controller.get_has_tracking_data() else Vector2.ZERO)

func recenter() -> void:
	# Keep physical height, rotate about the current head instead of the room origin.
	var local_forward := -eye.transform.basis.z
	if Vector2(local_forward.x, local_forward.z).length() > 0.01:
		yaw = app.player_yaw - atan2(-local_forward.x, -local_forward.z)
	center = eye.position * Vector3(1, 0, 1)
	neutral = false
	set_menu_open(false)

func set_menu_open(value: bool) -> void:
	if pointer_down: pointer(false)
	menu.visible = value
	trigger_neutral = false
	neutral = false
	if value:
		menu.global_position = eye.global_position - eye.global_basis.z * 1.05
		menu.look_at(eye.global_position, Vector3.UP, true)
	else: menu.leave_pointer()

func tick() -> void:
	origin.rotation.y = yaw
	origin.position = app.player_position - Basis(Vector3.UP, yaw) * center
	var physical_offset := (eye.position * Vector3(1, 0, 1) - center).length()
	guard.visible = not tracked() or physical_offset > 0.6 or not head_clear
	guard_label.visible = guard.visible and not menu.visible
	if session.control and not guard_request and Time.get_ticks_msec() >= next_guard:
		guard_request = true
		next_guard = Time.get_ticks_msec() + 100
		var p := eye.global_position
		app.requests.request({"kind":"presentation","action":"view","position":[p.x,p.y,p.z]}, func(reply):
			guard_request = false
			head_clear = reply.get("ok", false) and reply.get("data", {}).get("clear", false), ["request_id"], "request_id", 1000, "presentation_result")
	if guard.visible:
		neutral = false
		# Menu remains reachable even when the head left the seated/standing area.
		menu_status.text = "操作位置から離れています。\n元の位置へ戻るか、正面を合わせてください。"
	else: menu_status.text = "右手のレーザーとトリガーで選択\n左Bで閉じる"
	laser_mesh.clear_surfaces()
	if not focused() or not tracked():
		if pointer_down: pointer(false)
		neutral = false
		return
	if menu.visible and (simulated or right.get_has_tracking_data()):
		var start := right.global_position
		var direction := -right.global_basis.z
		var hit = Plane(menu.global_basis.z, menu.global_position).intersects_ray(start, direction)
		var point := Vector2(-1000, -1000)
		if hit != null:
			point = menu.canvas_point(hit)
			if not Rect2(Vector2.ZERO, Vector2(menu.viewport.size)).has_point(point): point = Vector2(-1000, -1000)
		pointer_point = point
		var motion := InputEventMouseMotion.new()
		menu.forward_pointer(motion, point)
		laser_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		laser_mesh.surface_add_vertex(to_local(start))
		laser_mesh.surface_add_vertex(to_local(hit if hit != null else start + direction * 2.0))
		laser_mesh.surface_end()
		if not simulated:
			var pressed := right.is_button_pressed("trigger_click")
			if not pressed: trigger_neutral = true
			if trigger_neutral and pressed != pointer_down: pointer(pressed)

func pointer(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	pointer_down = pressed
	menu.forward_pointer(event, pointer_point)

func player_input() -> Dictionary:
	var move := axes(left, test_left)
	var turn := axes(right, test_right)
	var allowed: bool = session.control and focused() and tracked() and not menu.visible and not guard.visible
	if not allowed: neutral = false
	if allowed and move.length() < 0.15 and turn.length() < 0.15: neutral = true
	if absf(turn.x) < 0.25: turn_neutral = true
	if allowed and neutral and turn_neutral and absf(turn.x) > 0.7:
		yaw -= signf(turn.x) * PI / 6.0
		# Keep the current head world position fixed during snap turn.
		var offset := eye.position * Vector3(1, 0, 1) - center
		center = eye.position * Vector3(1, 0, 1) - Basis(Vector3.UP, -signf(turn.x) * PI / 6.0).inverse() * offset
		turn_neutral = false
	var forward := -eye.global_basis.z
	if Vector2(forward.x, forward.z).length() > 0.01: session.view_yaw = atan2(-forward.x, -forward.z)
	var pitch := clampf(asin(clampf(forward.y, -1.0, 1.0)), -1.5, 1.5)
	move = move.limit_length(1.0) if allowed and neutral and move.length() > 0.15 else Vector2.ZERO
	return {"movement":[move.x, -move.y], "yaw":session.view_yaw,"pitch":pitch,"jump":false,"face_view":true,"active":allowed and neutral}
