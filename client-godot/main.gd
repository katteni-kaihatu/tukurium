extends Node3D

const MAX_FRAME := 1048576
const AVATAR = preload("res://avatar.gd")
const TRANSLATION_GIZMO = preload("res://translation_gizmo.gd")
const ASSET_IMPORTER = preload("res://asset_importer.gd")
const ASSET_STATUS = preload("res://asset_status.gd")
var asset_status = ASSET_STATUS.new()
const SCRIPT_EDITOR = preload("res://script_editor.gd")
const WORLD_PANELS = preload("res://world_panels.gd")
const REQUEST_BROKER = preload("res://request_broker.gd")
const WORLD_HUD = preload("res://world_hud.gd")
const SOCIAL_PANELS = preload("res://social_panels.gd")
const PRIMITIVE_MESH = preload("res://primitive_mesh.gd")
const RENDER_HIERARCHY = preload("res://render_hierarchy.gd")
const CAMERA_TOOL = preload("res://camera_tool.gd")
const MIRROR_RENDERER = preload("res://mirror_renderer.gd")
var render_hierarchy = RENDER_HIERARCHY.new()
var camera_tool = CAMERA_TOOL.new()
var mirror_renderer = MIRROR_RENDERER.new()
var hud = WORLD_HUD.new()
var social_panels = SOCIAL_PANELS.new()
var requests = REQUEST_BROKER.new()
var world_panels = WORLD_PANELS.new()
var script_editor = SCRIPT_EDITOR.new()
var script_templates: Array = []
var script_statuses: Array = []
var world_tree_signature := ""
var asset_importer = ASSET_IMPORTER.new()
var video_controls: VBoxContainer
var avatar_button: Button
var reset_avatar: Button
var video_seek: HSlider
var video_time: Label
var video_loop: CheckBox
var seeking_video := false
var clock_ready := false
var clock_offset := 0.0
var clock_best_rtt := INF
var clock_next_ping := 0.0
var tcp := StreamPeerTCP.new()
var received := PackedByteArray()
var outgoing := PackedByteArray()
var port := 47000
var close_with_engine := false
var session := "demo"
var epoch := ""
var sequence := 0
var retry_at := 0.0
var initial_engine_deadline := 0
var connected := false
var editable := false
var invalid_frame_noticed := false
var current: Dictionary = {}
var fields: Dictionary = {}
var dirty: Dictionary = {}
var pending := false
var pending_action := ""
var pending_edit: Dictionary = {}
var inspector_edits: Dictionary = {}
var inspector_shell: Control
var inspector_toggle: Button
var filling := false
var objects: Dictionary = {}
var render_nodes: Dictionary = {}
var driven_objects: Dictionary = {}
var local_script_statuses: Array = []
var selected_id := ""
var tree_objects: VBoxContainer
var object_count: Label
var create_button: Button
var image_button: Button
var image_textures: Dictionary = {}
var duplicate_button: Button
var delete_button: Button
var selection_outline := MeshInstance3D.new()
var gizmo = TRANSLATION_GIZMO.new()
var gizmo_target := ""
var gizmo_revision := ""
var gizmo_preview := Vector3.ZERO
var gizmo_preview_active := false
var remote_previews: Dictionary = {}
var last_preview_at := 0
var camera := Camera3D.new()
var cube: MeshInstance3D
var material: StandardMaterial3D
var avatars: Dictionary = {}
var participant_names: Dictionary = {}
var self_id := "local"
var player_position := Vector3(0, 0, 3)
var player_target_position := Vector3(0, 0, 3)
var player_yaw := 0.0
var player_initialized := false
var avatar_camera := true
var first_person := false
var fps_active := false
var edit_mode := false
var hand_grab: Dictionary = {}
var grab_waiting := false
var grab_releasing := false
var right_down := false
var pressed_button_id := ""
var crosshair: Label
var interaction_rays: Array = []
var aiming_at_collider := false
var laser_mesh := ImmediateMesh.new()
var grounded := true
var jump_requested := false
var view_mode: OptionButton
var orbit_yaw := 0.45
var orbit_pitch := -0.25
var orbit_distance := 6.0
var last_input_at := 0
var people_label: Label
var nickname: LineEdit
var status_label: Label
var object_label: Label
var revision_label: Label
var feedback: Label
var name_input: LineEdit
var position_inputs: Array[SpinBox] = []
var rotation_inputs: Array[SpinBox] = []
var scale_inputs: Array[SpinBox] = []
var collider_inputs: Array[SpinBox] = []
var collider_enabled: CheckBox
var collider_solid: CheckBox
var color_input: ColorPickerButton
var apply_buttons: Array[Button] = []
var look := false
var capture_path := ""
var frames := 0
var avatar_restore_started := false
const SERVICE_PANEL = preload("res://service_panel.gd")
var service_panel = SERVICE_PANEL.new()
var app_version := "開発版"
var engine_role := ""

func _ready() -> void:
	if FileAccess.file_exists("res://version.txt"):
		var packaged_version := FileAccess.get_file_as_string("res://version.txt").strip_edges()
		if not packaged_version.is_empty(): app_version = packaged_version
	AppLanguage.language_changed.connect(refresh_localized_chrome)
	refresh_localized_chrome()
	# Space belongs to gameplay/text entry, not BaseButton's default UI accept.
	for event in InputMap.action_get_events("ui_accept"):
		if event is InputEventKey and (event.keycode == KEY_SPACE or event.physical_keycode == KEY_SPACE):
			InputMap.action_erase_event("ui_accept", event)
	var bindings := {"move_left":KEY_A, "move_right":KEY_D, "move_forward":KEY_W, "move_back":KEY_S, "jump":KEY_SPACE, "grab_rotate":KEY_E}
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var key := InputEventKey.new()
			key.physical_keycode = bindings[action]
			InputMap.action_add_event(action, key)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--port="): port = int(argument.trim_prefix("--port="))
		if argument == "--close-with-engine": close_with_engine = true
		if argument.begins_with("--session="): session = argument.trim_prefix("--session=")
		if argument.begins_with("--capture="): capture_path = argument.trim_prefix("--capture=")
	build_world()
	requests.send = queue_message
	add_child(world_panels)
	world_panels.setup(self)
	build_ui()
	add_child(service_panel)
	service_panel.setup(self)
	refresh_localized_chrome()
	add_child(asset_status)
	asset_status.setup(self)
	add_child(asset_importer)
	asset_importer.configure(self)
	add_child(social_panels)
	social_panels.setup(self)
	add_child(hud)
	hud.setup(self)
	add_child(camera_tool)
	camera_tool.setup(self)
	add_child(mirror_renderer)
	mirror_renderer.setup(self)
	set_view_mode(1, false)
	connect_engine()

func refresh_localized_chrome() -> void:
	var version := tr("開発版") if app_version == "開発版" else app_version
	var role := "" if engine_role.is_empty() else " — " + tr(engine_role.capitalize())
	DisplayServer.window_set_title("tukurium · " + version + role)
	if is_instance_valid(service_panel.version_label): service_panel.version_label.text=version
	if is_instance_valid(people_label):
		var names: PackedStringArray=[]
		for id in participant_names:
			names.append(str(participant_names[id])+(tr(" (you)") if id==self_id else ""))
		people_label.text="\n".join(names)

func build_world() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("243645")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b7d3e0")
	settings.ambient_light_energy = 0.3
	environment.environment = settings
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("344953")
	floor_material.roughness = 0.95
	floor_mesh.material_override = floor_material
	add_child(floor_mesh)
	var grid := ImmediateMesh.new()
	grid.surface_begin(Mesh.PRIMITIVE_LINES)
	for n in range(-20, 21):
		grid.surface_add_vertex(Vector3(n, 0.008, -20))
		grid.surface_add_vertex(Vector3(n, 0.008, 20))
		grid.surface_add_vertex(Vector3(-20, 0.008, n))
		grid.surface_add_vertex(Vector3(20, 0.008, n))
	grid.surface_end()
	var grid_node := MeshInstance3D.new()
	grid_node.mesh = grid
	var grid_material := StandardMaterial3D.new()
	grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid_material.albedo_color = Color("46616a")
	grid_node.material_override = grid_material
	add_child(grid_node)
	var outline := ImmediateMesh.new()
	outline.surface_begin(Mesh.PRIMITIVE_LINES)
	var corners: Array[Vector3] = []
	for x in [-0.78, 0.78]:
		for y in [-0.78, 0.78]:
			for z in [-0.78, 0.78]: corners.append(Vector3(x, y, z))
	for i in range(8):
		for bit in [1, 2, 4]:
			if (i ^ bit) > i:
				outline.surface_add_vertex(corners[i])
				outline.surface_add_vertex(corners[i ^ bit])
	outline.surface_end()
	selection_outline.mesh = outline
	var outline_material := StandardMaterial3D.new()
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.albedo_color = Color("a2ece7")
	selection_outline.material_override = outline_material
	selection_outline.visible = false
	add_child(selection_outline)
	camera.position = Vector3(5, 4, 8)
	add_child(camera)
	camera.look_at(Vector3(0, 0.6, 0))
	camera.current = true
	add_child(gizmo)
	var laser_display := MeshInstance3D.new()
	laser_display.mesh = laser_mesh
	var laser_material := StandardMaterial3D.new()
	laser_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	laser_material.vertex_color_use_as_albedo = true
	laser_display.material_override = laser_material
	add_child(laser_display)
	gizmo.camera = camera
	gizmo.drag_started.connect(start_gizmo_drag)
	gizmo.preview_changed.connect(preview_gizmo_drag)
	gizmo.drag_finished.connect(finish_gizmo_drag)
	gizmo.drag_cancelled.connect(cancel_gizmo_drag)

func label(text: String, size: int = 15, color: Color = Color("d8e6ec")) -> Label:
	var item := Label.new()
	item.text = text
	item.add_theme_font_size_override("font_size", size)
	item.add_theme_color_override("font_color", color)
	return item

func panel(parent: Node, left: float, top: float, right: float, bottom: float) -> VBoxContainer:
	var shell := PanelContainer.new()
	shell.offset_left = left
	shell.offset_top = top
	shell.offset_right = right
	shell.offset_bottom = bottom
	var style := StyleBoxFlat.new()
	style.bg_color = Color("172630")
	style.border_color = Color("3a505c")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 20
	style.content_margin_right = 20
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	shell.add_theme_stylebox_override("panel", style)
	parent.add_child(shell)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 14)
	shell.add_child(stack)
	return stack

func build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var theme := Theme.new()
	theme.default_font_size = 15
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme
	layer.add_child(root)
	crosshair = label("+", 24, Color("a2ece7"))
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-8,-16)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.visible = false
	root.add_child(crosshair)
	var header := panel(root, 24, 22, 1256, 92)
	header.get_parent().hide()
	header.get_parent().set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.get_parent().offset_right = -24
	var row := HBoxContainer.new()
	header.add_child(row)
	row.add_child(label("tukurium", 25))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	view_mode = OptionButton.new()
	view_mode.add_item("Third person")
	view_mode.add_item("First person / FPS")
	view_mode.add_item("Fly camera")
	view_mode.item_selected.connect(set_view_mode)
	row.add_child(view_mode)
	inspector_toggle = Button.new()
	inspector_toggle.text = "Inspector [I]"
	inspector_toggle.toggle_mode = true
	inspector_toggle.button_pressed = false
	inspector_toggle.toggled.connect(func(visible):
		inspector_shell.visible = visible
		inspector_toggle.release_focus())
	row.add_child(inspector_toggle)
	var window_inspector := Button.new()
	window_inspector.text = "Inspector ↗"
	window_inspector.focus_mode = Control.FOCUS_NONE
	window_inspector.tooltip_text = "Open a local 2D inspector · Ctrl+Shift+I"
	window_inspector.pressed.connect(func(): world_panels.open_inspector(selected_id, true))
	row.add_child(window_inspector)
	status_label = label("Connecting…", 14, Color("6ed3dc"))
	row.add_child(status_label)
	var tree := panel(root, 24, 112, 264, 510)
	tree.get_parent().name = "LegacyWorldSidebar"
	tree.get_parent().hide()
	tree.add_child(label("WORLD", 12, Color("8ca7b6")))
	var session_label := label("Workshop / " + session, 16)
	session_label.clip_text = true
	tree.add_child(session_label)
	tree.add_child(label("Drop images, models or videos here", 12, Color("8ca7b6")))
	create_button = Button.new()
	create_button.text = "+ Cube"
	create_button.custom_minimum_size.y = 36
	create_button.pressed.connect(func(): submit_structure("create"))
	var creation := HBoxContainer.new()
	tree.add_child(creation)
	create_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	creation.add_child(create_button)
	image_button = Button.new()
	image_button.text = "Import…"
	image_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	image_button.pressed.connect(choose_image)
	creation.add_child(image_button)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 180
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.add_child(scroll)
	tree_objects = VBoxContainer.new()
	tree_objects.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(tree_objects)
	var tools := HBoxContainer.new()
	tree.add_child(tools)
	duplicate_button = Button.new()
	duplicate_button.text = "Duplicate"
	duplicate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duplicate_button.pressed.connect(func(): submit_structure("duplicate"))
	tools.add_child(duplicate_button)
	delete_button = Button.new()
	delete_button.text = "Delete…"
	delete_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	delete_button.pressed.connect(confirm_delete)
	tools.add_child(delete_button)
	object_count = label("Waiting for world…", 12, Color("8ca7b6"))
	tree.add_child(object_count)
	var people := panel(root, 24, 530, 264, 700)
	people.get_parent().hide()
	people.add_child(label("PEOPLE", 12, Color("8ca7b6")))
	nickname = LineEdit.new()
	nickname.placeholder_text = "Your display name"
	nickname.max_length = 40
	nickname.text_submitted.connect(func(text): queue_message({"kind":"profile", "name":text}); nickname.release_focus())
	people.add_child(nickname)
	var avatar_actions := HBoxContainer.new()
	people.add_child(avatar_actions)
	avatar_button = Button.new()
	avatar_button.text = "Avatar texture…"
	avatar_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	avatar_button.tooltip_text = "Choose a PNG, JPEG or WebP texture for your Oekaki avatar"
	avatar_button.pressed.connect(func(): asset_importer.choose_avatar_texture())
	avatar_actions.add_child(avatar_button)
	reset_avatar = Button.new()
	reset_avatar.text = "Reset"
	reset_avatar.pressed.connect(func(): asset_importer.reset_avatar_texture())
	avatar_actions.add_child(reset_avatar)
	people_label = label("Connecting…", 13, Color("9cb5c2"))
	people_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	AppLanguage.format_text(people_label,"Connecting…")
	people_label.max_lines_visible = 4
	people.add_child(people_label)
	var inspector_panel := panel(root, -340, 112, -24, 708)
	inspector_shell = inspector_panel.get_parent()
	inspector_shell.hide()
	inspector_panel.get_parent().anchor_left = 1.0
	inspector_panel.get_parent().anchor_right = 1.0
	var inspector_scroll := ScrollContainer.new()
	inspector_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_panel.add_child(inspector_scroll)
	var inspector := VBoxContainer.new()
	inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_scroll.add_child(inspector)
	inspector.add_child(label("INSPECTOR", 12, Color("8ca7b6")))
	object_label = label("Shared cube", 22)
	object_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	inspector.add_child(object_label)
	revision_label = label("Waiting for world…", 12, Color("8ca7b6"))
	inspector.add_child(revision_label)
	var scripts_button := Button.new()
	scripts_button.text = "Script Systems…"
	scripts_button.pressed.connect(func():
		if current.is_empty(): return
		release_cursor()
		script_editor.open(selected_id))
	inspector.add_child(scripts_button)
	var world_inspector_button := Button.new()
	world_inspector_button.text = "Open shared world inspector · Ctrl+I"
	world_inspector_button.pressed.connect(func(): world_panels.open_inspector(selected_id))
	inspector.add_child(world_inspector_button)
	inspector.add_child(HSeparator.new())
	inspector.add_child(label("Slot · Name", 14))
	name_input = LineEdit.new()
	name_input.max_length = 80
	name_input.custom_minimum_size.y = 36
	inspector.add_child(name_input)
	name_input.text_changed.connect(func(_v): queue_inspector_edit("name"))
	name_input.text_submitted.connect(func(_v): submit("name", name_input.text))
	add_apply(inspector, "Rename", func(): submit("name", name_input.text))
	inspector.add_child(label("Transform · Position", 14))
	var axes := HBoxContainer.new()
	inspector.add_child(axes)
	for axis in ["X", "Y", "Z"]:
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		axes.add_child(column)
		column.add_child(label(axis, 12, Color("8ca7b6")))
		var spin := SpinBox.new()
		spin.min_value = -1000
		spin.max_value = 1000
		spin.step = 0.01
		spin.custom_minimum_size.x = 80
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(spin)
		position_inputs.append(spin)
		spin.get_line_edit().text_changed.connect(func(_v): queue_inspector_edit("position"))
		spin.value_changed.connect(func(value): queue_inspector_edit("position",spin,value))
	add_apply(inspector, "Move", func():
		for spin in position_inputs: spin.apply()
		submit("position", [position_inputs[0].value, position_inputs[1].value, position_inputs[2].value]))
	inspector.add_child(label("MeshRenderer · Color", 14))
	color_input = ColorPickerButton.new()
	color_input.custom_minimum_size.y = 40
	color_input.edit_alpha = false
	inspector.add_child(color_input)
	color_input.color_changed.connect(func(_v): queue_inspector_edit("color"))
	add_apply(inspector, "Apply color", func():
		var c := color_input.color
		submit("color", [c.r, c.g, c.b, c.a]))
	rotation_inputs = add_vector_editor(inspector, "Rotation · degrees", "rotation", -36000, 36000, 1)
	add_apply(inspector, "Apply rotation", func():
		for spin in rotation_inputs: spin.apply()
		var q := Quaternion.from_euler(Vector3(deg_to_rad(rotation_inputs[0].value),deg_to_rad(rotation_inputs[1].value),deg_to_rad(rotation_inputs[2].value)))
		submit("rotation",[q.x,q.y,q.z,q.w]))
	scale_inputs = add_vector_editor(inspector, "Scale", "scale", 0.05, 20, 0.05)
	add_apply(inspector, "Apply scale", func():
		for spin in scale_inputs: spin.apply()
		submit("scale",[scale_inputs[0].value,scale_inputs[1].value,scale_inputs[2].value]))
	collider_enabled = CheckBox.new()
	collider_enabled.text = "Collider · enabled / grabbable"
	inspector.add_child(collider_enabled)
	collider_enabled.toggled.connect(func(_v): queue_inspector_edit("collider"))
	collider_solid = CheckBox.new()
	collider_solid.text = "Solid · blocks the character"
	inspector.add_child(collider_solid)
	collider_solid.toggled.connect(func(_v): queue_inspector_edit("collider"))
	collider_inputs = add_vector_editor(inspector, "Collider · half extents", "collider", 0.001, 50, 0.01)
	add_apply(inspector, "Apply collider", func():
		for spin in collider_inputs: spin.apply()
		var shape: Variant = {"half_extents":[collider_inputs[0].value,collider_inputs[1].value,collider_inputs[2].value],"solid":collider_solid.button_pressed} if collider_enabled.button_pressed else null
		submit("collider",shape))
	feedback = label("", 13, Color("9cb5c2"))
	feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector.add_child(feedback)
	video_controls = VBoxContainer.new()
	video_controls.add_child(label("Video playback · shared",12))
	var play_button := Button.new()
	play_button.text = "Play / Pause"
	play_button.pressed.connect(func(): asset_importer.toggle_video())
	video_controls.add_child(play_button)
	var restart_button := Button.new()
	restart_button.text = "Restart"
	restart_button.pressed.connect(func(): asset_importer.restart_video())
	video_controls.add_child(restart_button)
	apply_buttons.append(play_button)
	apply_buttons.append(restart_button)
	video_time = label("Waiting for host clock…",12)
	video_controls.add_child(video_time)
	video_seek = HSlider.new()
	video_seek.step = 0.1
	video_seek.drag_started.connect(func(): seeking_video = true)
	video_seek.drag_ended.connect(func(changed: bool):
		seeking_video = false
		if changed: send_playback("seek",{"position_seconds":video_seek.value})
	)
	video_controls.add_child(video_seek)
	video_loop = CheckBox.new()
	video_loop.text = "Loop"
	video_loop.toggled.connect(func(enabled: bool):
		if not filling: send_playback("loop",{"looping":enabled})
	)
	video_controls.add_child(video_loop)
	inspector.add_child(video_controls)
	inspector.move_child(video_controls,4)
	video_controls.visible = false
	script_editor.setup(self)

func add_vector_editor(parent: Node, title: String, field_id: String, minimum: float, maximum: float, step: float) -> Array[SpinBox]:
	parent.add_child(label(title,14))
	var row := HBoxContainer.new()
	parent.add_child(row)
	var inputs: Array[SpinBox] = []
	for axis in ["X","Y","Z"]:
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(column)
		column.add_child(label(axis,12,Color("8ca7b6")))
		var spin := SpinBox.new()
		spin.min_value = minimum
		spin.max_value = maximum
		spin.step = step
		spin.custom_minimum_size.x = 75
		column.add_child(spin)
		spin.value_changed.connect(func(value): queue_inspector_edit(field_id,spin,value))
		spin.get_line_edit().text_changed.connect(func(_v): queue_inspector_edit(field_id))
		inputs.append(spin)
	return inputs

func add_apply(parent: Node, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 32
	button.pressed.connect(action)
	parent.add_child(button)
	button.visible = false
	apply_buttons.append(button)

func mark_dirty(id: String) -> void:
	if filling or not fields.has(id): return
	if not dirty.has(id): dirty[id] = fields[id].revision

func inspector_key(target: Dictionary, field_id: String) -> String:
	return target.instance_id + ":" + field_id

func inspector_value(id: String, override_spin: SpinBox = null, override_value: float = 0.0) -> Variant:
	if id == "name": return name_input.text
	if id == "color":
		var c := color_input.color
		return [c.r,c.g,c.b,c.a]
	if id == "collider" and not collider_enabled.button_pressed: return null
	var inputs: Array[SpinBox] = position_inputs
	if id == "rotation": inputs = rotation_inputs
	if id == "scale": inputs = scale_inputs
	if id == "collider": inputs = collider_inputs
	var values := []
	for spin in inputs:
		if spin == override_spin:
			values.append(override_value)
			continue
		var raw := spin.get_line_edit().text.strip_edges()
		if not raw.is_valid_float(): return null
		values.append(clampf(raw.to_float(),spin.min_value,spin.max_value))
	if id == "rotation":
		var q := Quaternion.from_euler(Vector3(deg_to_rad(values[0]),deg_to_rad(values[1]),deg_to_rad(values[2])))
		return [q.x,q.y,q.z,q.w]
	if id == "collider": return {"half_extents":values,"solid":collider_solid.button_pressed}
	return values

func queue_inspector_edit(id: String, override_spin: SpinBox = null, override_value: float = 0.0) -> void:
	if filling or current.is_empty() or not editable: return
	mark_dirty(id)
	var key := inspector_key(current.address,id)
	var value: Variant = inspector_value(id,override_spin,override_value)
	if (value == null and not (id == "collider" and not collider_enabled.button_pressed)) or (id == "name" and str(value).strip_edges().is_empty()):
		inspector_edits.erase(key)
		return
	var due: int = inspector_edits.get(key,{}).get("due",Time.get_ticks_msec()+160)
	inspector_edits[key] = {"target":current.address.duplicate(),"field_id":id,"expected_revision":dirty[id],"value":value,"due":due}

func flush_inspector_edits() -> void:
	if not editable or pending or grab_waiting or not hand_grab.is_empty() or gizmo_preview_active: return
	for key in inspector_edits.keys():
		var edit: Dictionary = inspector_edits[key]
		if Time.get_ticks_msec() < edit.due: continue
		inspector_edits.erase(key)
		send_field_edit(edit)
		return

func send_field_edit(edit: Dictionary) -> void:
	pending = true
	pending_action = "edit"
	pending_edit = edit.duplicate(true)
	feedback.text = "Syncing…"
	var command := edit.duplicate(true)
	command.erase("due")
	command.target = field_address(edit.target.instance_id, edit.field_id)
	requests.request({"kind":"edit","edit":command}, complete_action, ["edit","command_id"])

func submit(id: String, value: Variant) -> void:
	if not editable or pending or current.is_empty(): return
	inspector_edits.erase(inspector_key(current.address,id))
	send_field_edit({"target":current.address.duplicate(),"field_id":id,"expected_revision":dirty.get(id,fields[id].revision),"value":value})

func start_gizmo_drag() -> void:
	gizmo_target = selected_id
	gizmo_revision = fields.position.revision
	dirty["position"] = gizmo_revision
	gizmo_preview = cube.position
	gizmo_preview_active = true
	send_gizmo_preview()
	feedback.text = "Drag to move · Shift: 0.25 snap · Esc: cancel"

func gizmo_local_position(world_position: Vector3) -> Variant:
	if not objects.has(gizmo_target): return null
	var parent: Variant=objects[gizmo_target].get("parent")
	if not parent is Dictionary: return world_position
	var parent_id: String=str(parent.get("instance_id",""))
	if not render_nodes.has(parent_id): return null
	var parent_node: Node3D=render_nodes[parent_id]
	var parent_scale: Vector3=parent_node.scale
	if absf(parent_scale.x)<0.000001 or absf(parent_scale.y)<0.000001 or absf(parent_scale.z)<0.000001: return null
	return parent_node.quaternion.inverse()*(world_position-parent_node.position)/parent_scale

func preview_gizmo_drag(position: Vector3) -> void:
	gizmo_preview = position
	if not render_nodes.has(gizmo_target): return
	render_nodes[gizmo_target].position = position
	draw_render_hierarchy()
	selection_outline.position = position
	var local_position: Variant=gizmo_local_position(position)
	if local_position is Vector3:
		filling = true
		for i in range(3): position_inputs[i].value = local_position[i]
		filling = false

func restore_gizmo_visual() -> void:
	if gizmo_preview_active and connected: queue_message({"kind":"drag_preview", "preview":null})
	if objects.has(gizmo_target) and render_nodes.has(gizmo_target):
		var p: Array = objects[gizmo_target].world_position
		render_nodes[gizmo_target].position = Vector3(p[0], p[1], p[2])
	gizmo_preview_active = false
	gizmo_target = ""
	draw_render_hierarchy()
	update_selected()

func send_gizmo_preview() -> void:
	if not connected or not gizmo_preview_active or not objects.has(gizmo_target): return
	queue_message({"kind":"drag_preview", "preview":{
		"target":address_of(objects[gizmo_target]), "expected_revision":gizmo_revision,
		"position":[gizmo_preview.x, gizmo_preview.y, gizmo_preview.z]}})

func valid_remote_preview(preview: Dictionary) -> bool:
	var id: String = preview.target.instance_id
	if not objects.has(id) or objects[id].address != preview.target: return false
	var revisions := {}
	for field in objects[id].fields: revisions[field.id] = field.revision
	return revisions.get("position") == preview.expected_revision and (preview.get("expected_rotation_revision") == null or revisions.get("rotation") == preview.expected_rotation_revision) and (preview.get("expected_scale_revision") == null or revisions.get("scale") == preview.expected_scale_revision)

func draw_render_hierarchy(delta: float = 0.0) -> void:
	render_hierarchy.draw(render_nodes, remote_previews, gizmo_target if gizmo_preview_active else "", gizmo_preview, delta)

func sync_render_hierarchy() -> void:
	render_hierarchy.sync(objects, world_panels.evaluated_transforms)
	draw_render_hierarchy()

func apply_drive_frame(frame: Dictionary) -> void:
	var previous := driven_objects.keys()
	driven_objects.clear()
	for object in frame.get("objects", []):
		if objects.has(object.target.instance_id) and objects[object.target.instance_id].address == object.target:
			driven_objects[object.target.instance_id] = object["values"]
	for id in driven_objects.keys():
		if not previous.has(id): previous.append(id)
	for id in world_panels.evaluated_transforms:
		if not previous.has(id): previous.append(id)
	for id in previous:
		if not objects.has(id) or not render_nodes.has(id): continue
		var c: Array = driven_objects.get(id, {}).get("color", [])
		if c.is_empty():
			for field in objects[id].fields:
				if field.id == "color": c = field.value
		if c.size() == 4:
			render_nodes[id].material_override.albedo_color = Color(c[0], c[1], c[2], c[3])
			if render_nodes[id].has_node("ImportedModel"): asset_importer.tint_model(render_nodes[id].get_node("ImportedModel"), render_nodes[id].material_override.albedo_color)
		if render_nodes[id].has_node("WorldText") and objects[id].get("world_text") is Dictionary:
			var label: Label3D = render_nodes[id].get_node("WorldText")
			label.text = str(driven_objects.get(id, {}).get("world_text", objects[id].world_text.text))
			var text_color: Array = driven_objects.get(id, {}).get("world_text_color", objects[id].world_text.color)
			if text_color.size() == 4: label.modulate = Color(text_color[0], text_color[1], text_color[2], text_color[3])
	sync_render_hierarchy()
	var statuses: Array = frame.get("statuses", [])
	if statuses != local_script_statuses:
		local_script_statuses = statuses
		script_editor.refresh()

func update_selection_outline() -> void:
	if current.is_empty(): return
	selection_outline.transform = cube.transform
	if cube.mesh is QuadMesh: selection_outline.scale *= Vector3(cube.mesh.size.x / 1.5, cube.mesh.size.y / 1.5, 0.06)
	if current.get("visual",{}).get("kind","")=="model":
		var half: Array = current.visual.half_extents
		selection_outline.scale *= Vector3(half[0],half[1],half[2])/0.75

func set_remote_previews(entries: Array) -> void:
	var next := {}
	# Engine orders owners consistently when multiple people preview the same object.
	for entry in entries:
		var preview: Dictionary = entry.preview
		if valid_remote_preview(preview) and not next.has(preview.target.instance_id):
			next[preview.target.instance_id] = preview
	remote_previews = next
	draw_render_hierarchy()

func cancel_gizmo_drag() -> void:
	dirty.erase("position")
	restore_gizmo_visual()
	feedback.text = "Move cancelled."

func finish_gizmo_drag(position: Vector3) -> void:
	if position.distance_squared_to(gizmo.drag_origin) < 0.000001:
		cancel_gizmo_drag()
		return
	var local_position: Variant=gizmo_local_position(position)
	if not local_position is Vector3:
		cancel_gizmo_drag()
		return
	submit("position", [local_position.x, local_position.y, local_position.z])
	if pending: pending_action = "gizmo"
	else: cancel_gizmo_drag()

func address_of(object: Dictionary) -> Dictionary:
	return {"instance_id":object.address.instance_id, "local_id":int(object.address.local_id)}

func submit_structure(action: String, target: Dictionary = {}) -> void:
	if not editable or pending: return
	if action != "create" and current.is_empty() and target.is_empty(): return
	var command := {"command_id":str(Time.get_ticks_usec()), "action":action}
	if action != "create":
		var object := current if target.is_empty() else target
		command.target = address_of(object)
		command.expected_revision = object.object_revision
	pending = true
	pending_action = action
	feedback.text = "Applying…"
	requests.request({"kind":"structure", "command":command}, complete_action)

func confirm_delete() -> void:
	if current.is_empty(): return
	var target: Dictionary = current.duplicate(true)
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete object"
	AppLanguage.format_text(dialog,"Delete “%s” for everyone in this world?",[fields.name.value],"dialog_text")
	dialog.ok_button_text = "Delete"
	dialog.confirmed.connect(func(): submit_structure("delete", target); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered(Vector2i(420, 140))

func choose_image() -> void:
	asset_importer.choose_files()

func import_image(path: String) -> void:
	if not editable or pending: return
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		feedback.text = "Could not read that image. Choose PNG or JPEG."
		return
	var largest := maxi(image.get_width(), image.get_height())
	if largest > 1024:
		var factor := 1024.0 / largest
		image.resize(maxi(1, int(image.get_width() * factor)), maxi(1, int(image.get_height() * factor)), Image.INTERPOLATE_LANCZOS)
	var data := image.save_png_to_buffer() if image.detect_alpha() else image.save_jpg_to_buffer(0.85)
	var prefix := "data:image/png;base64," if image.detect_alpha() else "data:image/jpeg;base64,"
	while data.size() > 192 * 1024 and maxi(image.get_width(), image.get_height()) > 64:
		image.resize(maxi(1, int(image.get_width() * 0.75)), maxi(1, int(image.get_height() * 0.75)), Image.INTERPOLATE_LANCZOS)
		data = image.save_png_to_buffer() if image.detect_alpha() else image.save_jpg_to_buffer(0.85)
	if data.size() > 192 * 1024:
		feedback.text = "Image is too large. Try a smaller image."
		return
	pending = true
	pending_action = "create_image"
	feedback.text = "Sharing image…"
	requests.request({"kind":"structure", "command":{"action":"create_image", "data_url":prefix + Marshalls.raw_to_base64(data)}}, complete_action)

func queue_message(body: Dictionary) -> void:
	sequence += 1
	var data := JSON.stringify({"protocol_version":3, "session_id":session,
		"authority_epoch":epoch, "sequence":str(sequence), "body":body}).to_utf8_buffer()
	var frame := PackedByteArray()
	frame.resize(4)
	frame[0] = (data.size() >> 24) & 255
	frame[1] = (data.size() >> 16) & 255
	frame[2] = (data.size() >> 8) & 255
	frame[3] = data.size() & 255
	frame.append_array(data)
	if outgoing.size() + frame.size() <= MAX_FRAME: outgoing.append_array(frame)
	else: disconnect_engine("Send queue full. Reconnecting…")

func connect_engine() -> void:
	if close_with_engine and initial_engine_deadline==0:
		initial_engine_deadline=Time.get_ticks_msec()+5000
	received.clear()
	outgoing.clear()
	invalid_frame_noticed = false
	tcp = StreamPeerTCP.new()
	var error := tcp.connect_to_host("127.0.0.1", port)
	if close_with_engine and error != OK:
		get_tree().quit()
	retry_at = Time.get_ticks_msec() + 2000

func disconnect_engine(message: String) -> void:
	if close_with_engine and connected:
		get_tree().quit()
	requests.disconnected()
	script_editor.disconnected()
	avatar_restore_started = false
	reset_media_clock()
	asset_importer.disconnected()
	cancel_hand_grab()
	set_remote_previews([])
	camera_tool.close_without_commit()
	if gizmo.dragging: gizmo.cancel_drag()
	if gizmo_preview_active: restore_gizmo_visual()
	tcp.disconnect_from_host()
	connected = false
	editable = false
	pending = false
	pending_edit.clear()
	inspector_edits.clear()
	dirty.clear()
	status_label.text = message
	retry_at = Time.get_ticks_msec() + 2000
	jump_requested = false

func send_player_input() -> void:
	if not connected: return
	var movement := Vector2.ZERO
	var keyboard_blocked := gameplay_keyboard_blocked()
	var jump_held: bool = Input.is_action_pressed("jump") and not keyboard_blocked
	var active: bool = not keyboard_blocked and player_initialized and avatar_camera and not gizmo.dragging and (fps_active or look or jump_requested or jump_held)
	if active and (look or fps_active):
		movement = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	queue_message({"kind":"player_input", "input":{
		"movement":[movement.x, movement.y], "yaw":orbit_yaw, "pitch":-orbit_pitch,
		"jump":active and (jump_requested or jump_held),
		"face_view":first_person, "active":active}})
	jump_requested = false

func release_player_input() -> void:
	jump_requested = false
	if connected: queue_message({"kind":"player_input", "input":{
		"movement":[0, 0], "yaw":0, "pitch":0, "jump":false, "face_view":false, "active":false}})

func begin_hand_grab() -> void:
	if not editable or pending or grab_waiting or not hand_grab.is_empty(): return
	grab_waiting = true
	world_panels.clear_focus()
	var hit: Dictionary = world_panels.pick(get_viewport().get_visible_rect().size * 0.5)
	if not hit.is_empty() and objects[hit.id].panel.get("attachment") != null:
		world_panels.edit(hit.id, "panel_pin", null, func(result):
			if result.ok and right_down: queue_message({"kind":"grab","action":"begin"})
			else: grab_waiting = false)
		return
	send_player_input()
	queue_message({"kind":"grab","action":"begin"})

func finish_hand_grab() -> void:
	if hand_grab.is_empty() or grab_releasing: return
	grab_releasing = true
	pending = true
	pending_action = "grab"
	requests.request({"kind":"grab","action":"release"}, complete_action, ["command_id"])

func cancel_hand_grab() -> void:
	if connected and (grab_waiting or not hand_grab.is_empty()) and not grab_releasing:
		queue_message({"kind":"grab","action":"cancel"})
	grab_waiting = false
	hand_grab.clear()
	right_down = false

func release_cursor() -> void:
	cancel_hand_grab()
	fps_active = false
	look = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	release_player_input()

func draw_interaction_rays() -> void:
	laser_mesh.clear_surfaces()
	var points: Array[Vector3] = []
	var colors: Array[Color] = []
	for entry in interaction_rays:
		var ray: Dictionary = entry.ray
		var local: bool = entry.owner == "local"
		if local and (not fps_active or ray.target == null): continue
		if not local and not ray.holding: continue
		var o: Array = ray.origin
		var p: Array = ray.point
		var start := Vector3(o[0],o[1],o[2])
		var end := Vector3(p[0],p[1],p[2])
		if ray.holding and ray.target is Dictionary:
			var target: String = ray.target.instance_id
			if remote_previews.has(target) and render_nodes.has(target):
				var preview: Dictionary = remote_previews[target]
				var pos: Array = preview.position
				var rot: Array = preview.get("rotation", objects[target].world_rotation)
				var size: Array = preview.get("scale", objects[target].world_scale)
				var frame := Transform3D(Basis(Quaternion(rot[0],rot[1],rot[2],rot[3])) * Basis.from_scale(Vector3(size[0],size[1],size[2])), Vector3(pos[0],pos[1],pos[2]))
				end = render_nodes[target].transform * (frame.affine_inverse() * end)
		if local: start = camera.position + camera.global_basis.x * 0.12 - camera.global_basis.y * 0.09
		var tint := Color("ffd087") if ray.holding else Color("a2ece7")
		points.append_array([start,end])
		colors.append_array([tint,tint])
		for axis in [Vector3.RIGHT,Vector3.UP,Vector3.BACK]:
			points.append_array([end-axis*0.025,end+axis*0.025])
			colors.append_array([tint,tint])
	if points.is_empty(): return
	laser_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(points.size()):
		laser_mesh.surface_set_color(colors[i])
		laser_mesh.surface_add_vertex(points[i])
	laser_mesh.surface_end()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		release_cursor()
		world_panels.capture_id = ""
		world_panels.clear_focus()

func reset_media_clock() -> void:
	clock_ready = false
	clock_best_rtt = INF
	clock_next_ping = 0.0

func update_media_clock() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not connected or not editable or now < clock_next_ping: return
	clock_next_ping = now + 2.0
	requests.request({"kind":"clock_ping","client_time":now}, accept_clock.bind(now), ["request_id"], "request_id", 5000, "clock_pong")

func accept_clock(body: Dictionary, sent: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var rtt := now - sent
	var server := float(body.get("server_time",-1.0))
	if not is_finite(server) or server < 0.0 or rtt < 0.0 or rtt > 5.0: return
	if not clock_ready or rtt <= clock_best_rtt * 1.5 + 0.01:
		clock_offset = server - (sent + now) * 0.5
		clock_best_rtt = minf(clock_best_rtt,rtt)
		clock_ready = true

func media_time() -> float:
	return Time.get_ticks_msec() / 1000.0 + clock_offset

func send_playback(action: String, values: Dictionary = {}) -> void:
	if not editable or pending or not hand_grab.is_empty() or current.is_empty() or current.get("playback") == null: return
	var command := {"command_id":str(Time.get_ticks_usec()),"target":current.address,"expected_revision":fields.playback.revision,"action":action}
	command.merge(values)
	pending = true
	pending_action = "playback"
	requests.request({"kind":"playback","command":command}, complete_action)

func update_video_controls() -> void:
	if not video_controls.visible or current.get("playback") == null: return
	var duration: float = asset_importer.video_duration(current)
	var position: float = asset_importer.video_position(current,duration) if clock_ready else 0.0
	video_time.text = "Loading video…" if duration <= 0.0 else (("%.1f / %.1f s" % [position,duration]) if clock_ready else "Waiting for host clock…")
	video_seek.editable = editable and clock_ready and not pending and duration > 0.0
	if not seeking_video:
		video_seek.max_value = maxf(0.1,duration)
		video_seek.set_value_no_signal(position)
	filling = true
	video_loop.button_pressed = current.playback.looping
	video_loop.disabled = not editable or pending
	filling = false

func _process(delta: float) -> void:
	requests.tick()
	script_editor.tick()
	tcp.poll()
	var state := tcp.get_status()
	if close_with_engine and not connected and initial_engine_deadline>0 and Time.get_ticks_msec()>=initial_engine_deadline:
		get_tree().quit()
		return
	if close_with_engine and state == StreamPeerTCP.STATUS_ERROR:
		get_tree().quit()
		return
	if state == StreamPeerTCP.STATUS_CONNECTED:
		if not connected:
			connected = true
			tcp.set_no_delay(true)
			queue_message({"kind":"hello"})
		if not outgoing.is_empty():
			var sent := tcp.put_partial_data(outgoing.slice(0, 524288))
			if sent[0] != OK: disconnect_engine("Connection lost")
			else: outgoing = outgoing.slice(sent[1])
		var available := mini(tcp.get_available_bytes(), 524288)
		if available > 0:
			var part := tcp.get_partial_data(available)
			if part[0] == OK: received.append_array(part[1])
			else: disconnect_engine("Connection lost")
		for _i in range(8):
			if received.size() < 4: break
			var size := (received[0] << 24) | (received[1] << 16) | (received[2] << 8) | received[3]
			if size <= 0 or size > MAX_FRAME:
				disconnect_engine("Invalid engine frame")
				break
			if received.size() < size + 4: break
			var decoded: Variant = JSON.parse_string(received.slice(4, size + 4).get_string_from_utf8())
			received = received.slice(size + 4)
			if decoded is Dictionary: accept_message(decoded)
			else: note_invalid_frame()
	else:
		if connected: disconnect_engine("Engine disconnected. Reconnecting…")
		if Time.get_ticks_msec() >= retry_at: connect_engine()
	flush_inspector_edits()
	if editable and not avatar_restore_started:
		avatar_restore_started = true
		if FileAccess.file_exists(asset_importer.avatar_file()): asset_importer.queue_avatar_texture(asset_importer.avatar_file())
	update_media_clock()
	var busy := pending or grab_waiting or not hand_grab.is_empty()
	avatar_button.disabled = not editable or busy
	reset_avatar.disabled = not editable or busy
	for button in apply_buttons: button.disabled = not editable or busy or current.is_empty()
	create_button.disabled = not editable or busy or objects.size() >= 128
	image_button.disabled = create_button.disabled
	duplicate_button.disabled = not editable or busy or current.is_empty() or objects.size() >= 128
	delete_button.disabled = not editable or busy or current.is_empty()
	crosshair.visible = first_person and fps_active
	crosshair.modulate = Color("ffd087") if not hand_grab.is_empty() else (Color("a2ece7") if aiming_at_collider else Color.WHITE)
	if connected and gizmo_preview_active and Time.get_ticks_msec() - last_preview_at >= 50:
		last_preview_at = Time.get_ticks_msec()
		send_gizmo_preview()
	for id in remote_previews.keys():
		var preview: Dictionary = remote_previews[id]
		if not valid_remote_preview(preview):
			remote_previews.erase(id)
			continue
	draw_render_hierarchy(delta)
	update_selection_outline()
	world_panels.tick()
	if edit_mode and not current.is_empty() and not hud.blocking(): gizmo.set_target(cube.position, editable and not busy and not look and not fps_active)
	else: gizmo.clear_target()
	if look and not gizmo.dragging and not avatar_camera:
		var movement := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W): movement.z -= 1
		if Input.is_physical_key_pressed(KEY_S): movement.z += 1
		if Input.is_physical_key_pressed(KEY_A): movement.x -= 1
		if Input.is_physical_key_pressed(KEY_D): movement.x += 1
		if Input.is_physical_key_pressed(KEY_Q): movement.y -= 1
		if Input.is_physical_key_pressed(KEY_E): movement.y += 1
		camera.position += camera.global_basis * movement.normalized() * delta * 5
	if player_initialized:
		player_position = player_position.lerp(player_target_position, 1.0 - exp(-35.0 * delta))
	if avatar_camera and player_initialized and not gizmo.dragging:
		if first_person:
			camera.position = player_position + Vector3(0, 1.15, 0)
			camera.rotation = Vector3(orbit_pitch, orbit_yaw, 0)
		else:
			var target := player_position + Vector3(0, 1.0, 0)
			camera.position = target + Vector3(sin(orbit_yaw) * cos(orbit_pitch), -sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * orbit_distance
			camera.look_at(target)
	if avatars.has(self_id):
		avatars[self_id].visible = true
		avatars[self_id].target_position = player_position
		avatars[self_id].target_yaw = player_yaw
	camera.cull_mask = 0xfffff ^ AVATAR.SELF_AVATAR_LAYER if first_person and avatar_camera else 0xfffff
	mirror_renderer.tick()
	if connected and Time.get_ticks_msec() - last_input_at >= 16:
		last_input_at = Time.get_ticks_msec()
		send_player_input()
	draw_interaction_rays()
	asset_importer.update_videos()
	update_video_controls()
	frames += 1
	if not capture_path.is_empty() and frames == 90:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(capture_path)
		get_tree().quit()

## A frame that is not a JSON object cannot be routed. Surface it once per
## connection instead of dropping it silently, then keep going.
func note_invalid_frame() -> void:
	if invalid_frame_noticed: return
	invalid_frame_noticed = true
	feedback.text = "Received an unreadable message from the engine."

func accept_message(message: Dictionary) -> void:
	if message.get("protocol_version") != 3:
		var got: Variant = message.get("protocol_version")
		received.clear()
		disconnect_engine(tr("Engine protocol mismatch (expected 3, got %s). Please update tukurium.") % str(got))
		return
	var service_body: Dictionary = message.get("body",{})
	if service_body.get("kind") == "engine_shutdown":
		get_tree().quit()
		return
	if service_body.get("kind") == "service_state":
		if session != message.get("session_id"):
			requests.disconnected()
			asset_importer.disconnected()
			world_panels.disconnected()
			script_editor.disconnected()
			session = message.session_id
			epoch = ""
			selected_id = ""
			current.clear()
			fields.clear()
			pending = false
			pending_edit.clear()
			inspector_edits.clear()
			dirty.clear()
			player_initialized = false
			reset_media_clock()
			for avatar in avatars.values(): avatar.queue_free()
			avatars.clear()
			social_panels.update_participants([],"local")
			social_panels.set_messages([])
			apply_snapshot({"world_revision":"0","objects":[]})
			queue_message({"kind":"hello"})
		service_panel.receive_state(service_body)
		return
	if service_body.get("kind") == "service_result":
		requests.receive(service_body)
		return
	if message.get("session_id") != session: return
	if epoch != message.authority_epoch:
		reset_media_clock()
		avatar_restore_started = false
	epoch = message.authority_epoch
	var body: Dictionary = message.body
	if body.get("kind") == "result" and body.has("snapshot"): apply_snapshot(body.snapshot)
	if requests.receive(body): return
	if world_panels.receive(body): return
	if str(body.get("kind","")).begins_with("asset_"):
		asset_importer.receive(body)
		return
	match body.get("kind"):
		"camera_capture":
			if body.get("target") is Dictionary:
				camera_tool.capture_from_script(str(body.target.get("instance_id", "")))
		"drive_frame":
			apply_drive_frame(body.frame)
		"script_statuses":
			script_statuses = body.statuses
			script_editor.refresh()
		"chat_state":
			social_panels.set_messages(body.messages)
		"chat_error":
			social_panels.show_error(str(body.get("message","チャットを送信できませんでした")))
		"interaction_rays":
			interaction_rays = body.rays
			aiming_at_collider = false
			for entry in interaction_rays:
				if entry.owner == "local": aiming_at_collider = entry.ray.target != null
		"grab_state":
			grab_waiting = false
			hand_grab = body.grab if body.get("grab") is Dictionary else {}
			if hand_grab.is_empty():
				grab_releasing = false
			else:
				if not pending: select_object(hand_grab.preview.target.instance_id)
				feedback.text = "Holding · E: rotate · Shift+Wheel: scale · LMB: straighten · Release RMB: place"
				if not right_down and not hand_grab.released: finish_hand_grab()
		"grab_error":
			grab_waiting = false
			feedback.text = body.message
		"object_previews":
			set_remote_previews(body.previews)
		"presence":
			self_id = body.self_id
			participant_names.clear()
			if body.get("local_motion") is Dictionary: grounded = body.local_motion.grounded
			var visible := {}
			var names: PackedStringArray = []
			for person in body.participants:
				var id: String = person.id
				participant_names[id] = person.name
				visible[id] = true
				var fresh := not avatars.has(id)
				if fresh:
					var avatar = AVATAR.new()
					add_child(avatar)
					avatars[id] = avatar
				avatars[id].set_state(person, id == self_id, fresh)
				var texture_id: String = person.avatar_texture if person.get("avatar_texture") is String else ""
				asset_importer.attach_avatar(id,texture_id)
				if id == self_id:
					var p: Array = person.pose.position
					player_target_position = Vector3(p[0], p[1], p[2])
					player_yaw = person.pose.yaw
					if not player_initialized:
						player_position = player_target_position
						player_initialized = true
					if not nickname.has_focus(): nickname.text = person.name
				names.append(person.name + (tr(" (you)") if id == self_id else ""))
			for id in avatars.keys():
				if not visible.has(id):
					avatars[id].queue_free()
					avatars.erase(id)
			people_label.text = "\n".join(names)
			social_panels.update_participants(body.participants,self_id)
		"catalog":
			# Static session data, sent once at hello: component
			# schemas for the panels and the script templates. The
			# catalog can land after the first snapshot; refresh the
			# panels so views built without schemas rebuild now
			# instead of waiting for the next snapshot.
			script_templates = body.get("script_templates", [])
			world_panels.component_schemas = body.get("component_schemas", [])
			world_panels.sync()
		"snapshot":
			editable = body.editable
			social_panels.set_messages(body.get("chat",[]))
			if body.has("script_templates"): script_templates = body["script_templates"]
			script_statuses = body.get("script_statuses", [])
			engine_role=str(body.role)
			refresh_localized_chrome()
			AppLanguage.format_text(status_label,("Host" if body.role == "host" else "Guest")+(" · Connected" if editable else " · Waiting for host"))
			apply_snapshot(body.snapshot)
			apply_drive_frame(body.get("drive_frame", {}))
			script_editor.refresh()
		"status":
			status_label.text = body.message
			editable = body.editable
			if not editable:
				apply_drive_frame({})
				requests.disconnected()
				asset_importer.disconnected()
				world_panels.disconnected()
				script_editor.disconnected()
				avatar_restore_started = false
				reset_media_clock()
				set_remote_previews([])
				if gizmo.dragging: gizmo.cancel_drag()
				if gizmo_preview_active: restore_gizmo_visual()
				if pending: feedback.text = "Connection interrupted. Check the shared value before retrying."
				pending = false
				pending_edit.clear()
				inspector_edits.clear()
				dirty.clear()

func complete_action(body: Dictionary) -> void:
	if pending_action == "gizmo": restore_gizmo_visual()
	pending = false
	if pending_action == "edit" and not pending_edit.is_empty():
		var key := inspector_key(pending_edit.target,pending_edit.field_id)
		if not body.ok: inspector_edits.erase(key)
		if not current.is_empty() and current.address == pending_edit.target and not inspector_edits.has(key):
			dirty.erase(pending_edit.field_id)
	else: dirty.clear()
	feedback.text = "Applied to the shared world." if body.ok else body.get("message", "Edit rejected")
	refresh_fields()
	if pending_action == "edit" and body.ok and not pending_edit.is_empty():
		var key := inspector_key(pending_edit.target,pending_edit.field_id)
		if inspector_edits.has(key) and objects.has(pending_edit.target.instance_id):
			for field in objects[pending_edit.target.instance_id].fields:
				if field.id == pending_edit.field_id:
					inspector_edits[key].expected_revision = field.revision
					if not current.is_empty() and current.address == pending_edit.target: dirty[field.id] = field.revision
	pending_edit.clear()
	if body.ok and pending_action in ["create", "create_image", "duplicate"] and body.get("selected") is Dictionary:
		select_object(body.selected.instance_id)
		focus_selected()
	pending_action = ""

func apply_snapshot(snapshot: Dictionary) -> void:
	if gizmo.dragging:
		var valid_target := false
		for object in snapshot.objects:
			if object.address.instance_id == gizmo_target:
				for field in object.fields:
					if field.id == "position" and field.revision == gizmo_revision: valid_target = true
		if not valid_target:
			gizmo.cancel_drag()
			feedback.text = "Object changed elsewhere. Move cancelled."
	var previous_objects: Dictionary=objects.duplicate()
	objects.clear()
	var used_images := {}
	for object in snapshot.objects:
		var id: String = object.address.instance_id
		objects[id] = object
		if render_nodes.has(id) and previous_objects.has(id) and previous_objects[id].get("visual") != object.get("visual"):
			render_nodes[id].queue_free()
			render_nodes.erase(id)
		if not render_nodes.has(id):
			render_nodes[id] = world_panels.create_surface(id) if object.get("panel") != null else create_render_node(object)
		var node: MeshInstance3D = render_nodes[id]
		var collision: CollisionShape3D = node.get_node("PickBody/Collider")
		collision.disabled = object.get("collider") == null
		if object.get("collider") is Dictionary:
			var half: Array = object.collider.half_extents
			collision.shape.size = Vector3(half[0],half[1],half[2])*2.0
		if object.get("visual", {}).get("kind", "cube") == "image":
			var source: String = object.visual.data_url
			used_images[source] = true
			if not image_textures.has(source):
				var image := Image.new()
				var bytes := Marshalls.base64_to_raw(source.get_slice(",", 1))
				var error := image.load_png_from_buffer(bytes) if source.begins_with("data:image/png") else image.load_jpg_from_buffer(bytes)
				if error == OK: image_textures[source] = ImageTexture.create_from_image(image)
			node.material_override.albedo_texture = image_textures.get(source)
		for field in object.fields:
			if field.id == "color":
				var c: Array = field.value
				node.material_override.albedo_color = Color(c[0], c[1], c[2], c[3])
		if object.get("world_text") is Dictionary:
			var label: Label3D
			if node.has_node("WorldText"):
				label=node.get_node("WorldText")
			else:
				label=Label3D.new()
				label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
				label.name="WorldText"
				label.font_size=64
				label.pixel_size=0.005
				label.outline_size=6
				label.double_sided=true
				node.add_child(label)
			label.text=object.world_text.text
			var text_color: Array=object.world_text.color
			label.modulate=Color(text_color[0],text_color[1],text_color[2],text_color[3])
			label.position=Vector3(0,0,0.8) if object.get("renderer")!=null else Vector3.ZERO
		elif node.has_node("WorldText"):
			node.get_node("WorldText").queue_free()
		if object.visual.kind == "model":
			asset_importer.attach_model(id)
			if node.has_node("ImportedModel"): asset_importer.tint_model(node.get_node("ImportedModel"),node.material_override.albedo_color)
		if object.visual.kind == "video": asset_importer.attach_video(id)
	for id in render_nodes.keys():
		if not objects.has(id):
			render_nodes[id].queue_free()
			render_nodes.erase(id)
	mirror_renderer.sync(objects, render_nodes)
	for source in image_textures.keys():
		if not used_images.has(source): image_textures.erase(source)
	asset_importer.evict_unused_assets()
	camera_tool.world_updated()
	if not objects.has(selected_id):
		selected_id = "" if objects.is_empty() else str(objects.keys()[0])
		dirty.clear()
	AppLanguage.format_text(revision_label,"World revision %s · ObjectRoot",[snapshot.world_revision])
	asset_status.refresh_badges()
	update_selected()
	rebuild_tree()
	world_panels.sync()
	apply_drive_frame({"objects":driven_objects.keys().filter(func(id): return objects.has(id)).map(func(id): return {"target":objects[id].address,"values":driven_objects[id]}), "statuses":local_script_statuses})

func create_render_node(object: Dictionary) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var image_panel: bool = object.get("visual", {}).get("kind", "cube") in ["image","video"]
	if image_panel:
		var quad := QuadMesh.new()
		var ratio: float = float(object.visual.width) / float(object.visual.height)
		quad.size = Vector2(2.0, 2.0 / ratio) if ratio >= 1 else Vector2(2.0 * ratio, 2.0)
		node.mesh = quad
	elif object.visual.get("kind") == "primitive":
		node.mesh = PRIMITIVE_MESH.create(object.visual.shape)
	elif object.visual.get("kind") != "none":
		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.5, 1.5, 1.5)
		node.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.45
	if object.visual.get("kind") == "primitive" and object.visual.shape in ["grid","quad"]:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if image_panel:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	if object.visual.get("kind") == "primitive" and object.visual.shape == "camera":
		var lens := MeshInstance3D.new()
		lens.name = "Lens"
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.22
		cylinder.bottom_radius = 0.22
		cylinder.height = 0.18
		lens.mesh = cylinder
		lens.rotation.x = PI * 0.5
		lens.position.z = -0.51
		var lens_material := StandardMaterial3D.new()
		lens_material.albedo_color = Color("14222f")
		lens_material.metallic = 0.35
		lens.material_override = lens_material
		node.add_child(lens)
	if object.visual.get("kind") == "primitive" and object.visual.shape == "mirror":
		var border_material := StandardMaterial3D.new()
		border_material.albedo_color = Color("1d2731")
		border_material.metallic = 0.5
		for piece in [
			["Top",Vector3(2.12,0.08,0.14),Vector3(0,1.04,0)],
			["Bottom",Vector3(2.12,0.08,0.14),Vector3(0,-1.04,0)],
			["Left",Vector3(0.08,2.0,0.14),Vector3(-1.04,0,0)],
			["Right",Vector3(0.08,2.0,0.14),Vector3(1.04,0,0)]]:
			var edge := MeshInstance3D.new()
			edge.name = piece[0]
			var box := BoxMesh.new()
			box.size = piece[1]
			edge.mesh = box
			edge.position = piece[2]
			edge.material_override = border_material
			node.add_child(edge)
	var body := StaticBody3D.new()
	body.set_meta("object_id", object.address.instance_id)
	var collision := CollisionShape3D.new()
	collision.name = "Collider"
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE
	collision.shape = shape
	body.add_child(collision)
	node.add_child(body)
	body.name = "PickBody"
	add_child(node)
	return node

func select_object(id: String) -> void:
	if pending: return
	if not objects.has(id): return
	if id != selected_id and gizmo.dragging: gizmo.cancel_drag()
	if id != selected_id: dirty.clear()
	selected_id = id
	update_selected()
	rebuild_tree()

func update_selected() -> void:
	current = objects.get(selected_id, {})
	video_controls.visible = not current.is_empty() and current.visual.kind == "video"
	fields.clear()
	selection_outline.visible = not current.is_empty() and current.get("visual", {}).get("kind") != "none"
	if current.is_empty():
		AppLanguage.format_text(object_label,"No object selected")
		name_input.text = ""
		return
	for field in current.fields: fields[field.id] = field
	cube = render_nodes[selected_id]
	material = cube.material_override
	update_selection_outline()
	AppLanguage.format_text(object_label,"%s",[fields.name.value])
	refresh_fields()

func rebuild_tree() -> void:
	var entries: Array = []
	for id in objects:
		var name := "Cube"
		for field in objects[id].fields:
			if field.id == "name": name = field.value
		entries.append([id, name])
	var signature := JSON.stringify([selected_id, entries])
	if signature == world_tree_signature: return
	world_tree_signature = signature
	for node in tree_objects.get_children():
		tree_objects.remove_child(node)
		node.queue_free()
	for id in objects:
		var object: Dictionary = objects[id]
		var button := Button.new()
		var name := "Cube"
		for field in object.fields:
			if field.id == "name": name = field.value
		button.text = "◇  " + name
		button.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(180, 36)
		button.toggle_mode = true
		button.button_pressed = id == selected_id
		button.pressed.connect(select_object.bind(id))
		tree_objects.add_child(button)
	AppLanguage.format_text(object_count,"%d / 128 objects",[objects.size()])

func focus_selected() -> void:
	if current.is_empty(): return
	release_cursor()
	avatar_camera = false
	release_player_input()
	first_person = false
	view_mode.select(2)
	camera.position = cube.position + Vector3(5, 3.25, 8)
	camera.look_at(cube.position)

func set_view_mode(mode: int, capture: bool = true) -> void:
	if gizmo.dragging: gizmo.cancel_drag()
	cancel_hand_grab()
	look = false
	avatar_camera = mode != 2
	release_player_input()
	first_person = mode == 1
	fps_active = first_person and capture
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if fps_active else Input.MOUSE_MODE_VISIBLE
	if fps_active: hud.set_dock_open(false)
	view_mode.select(mode)
	view_mode.release_focus()

func gameplay_keyboard_blocked() -> bool:
	if camera_tool.active: return true
	if hud.blocking(): return true
	if world_panels.has_window_focus(): return true
	if service_panel.enabled and service_panel.shade.visible: return true
	if world_panels.text_focused(): return true
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return true
	for window in get_tree().root.find_children("*", "Window", true, false):
		if window.visible and window.has_focus(): return true
	return false

func try_jump() -> void:
	if not gameplay_keyboard_blocked() and player_initialized and avatar_camera and not gizmo.dragging:
		jump_requested = true
		send_player_input()

func refresh_fields() -> void:
	if fields.is_empty(): return
	filling = true
	if not dirty.has("name"): name_input.text = fields.name.value
	if not dirty.has("position"):
		for i in range(3): position_inputs[i].value = fields.position.value[i]
	color_input.disabled = not fields.has("color")
	if fields.has("color") and not dirty.has("color"):
		var c: Array = fields.color.value
		color_input.color = Color(c[0], c[1], c[2], c[3])
	if fields.has("rotation") and not dirty.has("rotation"):
		var q: Array = fields.rotation.value
		var angles := Quaternion(q[0],q[1],q[2],q[3]).get_euler()
		for i in range(3): rotation_inputs[i].value = rad_to_deg(angles[i])
	if fields.has("scale") and not dirty.has("scale"):
		for i in range(3): scale_inputs[i].value = fields.scale.value[i]
	if fields.has("collider") and not dirty.has("collider"):
		var shape: Variant = fields.collider.value
		collider_enabled.button_pressed = shape != null
		collider_solid.button_pressed = shape != null and shape.solid
		for i in range(3): collider_inputs[i].value = shape.half_extents[i] if shape != null else 0.5
	filling = false

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and not pressed_button_id.is_empty():
		script_editor.button_event(pressed_button_id, "release")
		pressed_button_id = ""
	if camera_tool.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if hud.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if hud.blocking(): return
	if service_panel.enabled and service_panel.shade.visible: return
	if world_panels.route_input(event):
		get_viewport().set_input_as_handled()
		return
	if edit_mode and event is InputEventKey and event.pressed and not event.echo and event.ctrl_pressed and event.physical_keycode == KEY_I and not gameplay_keyboard_blocked():
		world_panels.open_inspector(selected_id, event.shift_pressed)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event.keycode == KEY_SPACE or event.physical_keycode == KEY_SPACE) and not gameplay_keyboard_blocked():
		if event.pressed and not event.echo: try_jump()
		get_viewport().set_input_as_handled()
		return
	if edit_mode and event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_I:
		var focus := get_viewport().gui_get_focus_owner()
		if fps_active or not (focus is LineEdit or focus is TextEdit):
			world_panels.open_inspector(selected_id, true)
			get_viewport().set_input_as_handled()
			return
	# Captured FPS mouse input belongs to the viewport, even over an inspector panel.
	if fps_active and (event is InputEventMouse or (event is InputEventKey and event.keycode == KEY_ESCAPE)):
		_unhandled_input(event)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if hud.blocking(): return
	if service_panel.enabled and service_panel.shade.visible: return
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		release_cursor()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and first_person and avatar_camera:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			right_down = event.pressed
			if event.pressed:
				fps_active = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				hud.set_dock_open(false)
				begin_hand_grab()
			else: finish_hand_grab()
			get_viewport().set_input_as_handled()
			return
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN] and not hand_grab.is_empty():
			if event.shift_pressed:
				queue_message({"kind":"grab","action":"scale","factor":1.1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0/1.1})
			else:
				queue_message({"kind":"grab","action":"distance","delta":0.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.25})
			get_viewport().set_input_as_handled()
			return
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_LEFT,MOUSE_BUTTON_WHEEL_RIGHT] and not hand_grab.is_empty():
			queue_message({"kind":"grab","action":"rotate","delta":[0.15 if event.button_index == MOUSE_BUTTON_WHEEL_RIGHT else -0.15,0.0],"vertical":true})
			get_viewport().set_input_as_handled()
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not hand_grab.is_empty():
			queue_message({"kind":"grab","action":"align"})
			get_viewport().set_input_as_handled()
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not fps_active:
			fps_active = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			hud.set_dock_open(false)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not fps_active and gizmo.begin_drag(event.position):
			get_viewport().set_input_as_handled()
			return
		var origin := camera.project_ray_origin(event.position)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + camera.project_ray_normal(event.position) * 5000)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.collider.has_meta("object_id"):
			var hit_id := str(hit.collider.get_meta("object_id"))
			select_object(hit_id)
			if event.double_click and camera_tool.is_camera(hit_id):
				camera_tool.open(hit_id)
				get_viewport().set_input_as_handled()
				return
			var button: Variant = objects.get(hit_id, {}).get("button")
			if button == true:
				if script_editor.button_event(hit_id, "press"): pressed_button_id = hit_id
			elif button == null: script_editor.interact(hit_id)
	if event is InputEventKey and event.keycode == KEY_F and event.pressed: focus_selected()
	if event is InputEventKey and event.keycode == KEY_SPACE and event.pressed and not event.echo: try_jump()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		look = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if look else Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseMotion and (look or fps_active):
		if not hand_grab.is_empty() and Input.is_action_pressed("grab_rotate"):
			queue_message({"kind":"grab","action":"rotate","delta":[clampf(event.relative.x*0.006,-1.0,1.0),clampf(event.relative.y*0.006,-1.0,1.0)],"vertical":event.shift_pressed})
			return
		if avatar_camera:
			orbit_yaw -= event.relative.x * 0.003
			orbit_pitch = clampf(orbit_pitch - event.relative.y * 0.003, -1.4 if first_person else -1.2, 1.4 if first_person else 0.2)
		else:
			camera.rotation.y -= event.relative.x * 0.003
			camera.rotation.x = clampf(camera.rotation.x - event.relative.y * 0.003, -1.4, 1.4)
	if event is InputEventKey and event.keycode == KEY_ESCAPE:
		look = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		release_player_input()

func field_address(object_id: String, field_id: String) -> Dictionary:
	for field in objects.get(object_id, {}).get("fields", []):
		if field.id == field_id: return {"instance_id":object_id,"local_id":int(field.component_id)}
	return {}
