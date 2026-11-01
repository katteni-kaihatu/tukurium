extends PanelContainer
## Shared CreationView content, hosted by the same world surface as inspectors.
const PRIMITIVES = preload("res://primitive_mesh.gd")
const DesignChrome = preload("res://design_chrome.gd")
var manager
var panel_id := ""
var app
var cards: Array[Button] = []
var selected := 0
var create_button: Button
var slot_button: Button
var text_button: Button
var camera_button: Button
var mirror_button: Button
var status: Label
var busy := false

func label(value: String, size: int = 20) -> Label:
	var result := Label.new()
	result.text=value
	result.add_theme_font_size_override("font_size",size)
	return result

func setup(controller, id: String) -> void:
	manager=controller
	app=manager.app
	panel_id=id
	theme=Theme.new()
	theme.default_font_size=20
	clip_contents = true
	var style := DesignChrome.panel(DesignChrome.PAPER, 18, 20, true)
	add_theme_stylebox_override("panel",style)
	build_ui()
	AppLanguage.language_changed.connect(refresh_language)

func build_ui() -> void:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",16)
	add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	var title := label("新規作成",28)
	title.add_theme_color_override("font_color", DesignChrome.INK)
	title.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := Button.new()
	close.text="×"
	close.focus_mode=Control.FOCUS_NONE
	close.custom_minimum_size=Vector2(48,44)
	DesignChrome.style_ghost(close)
	close.pressed.connect(func(): manager.close_panel(panel_id))
	header.add_child(close)
	column.add_child(HSeparator.new())
	var body := HBoxContainer.new()
	body.size_flags_vertical=Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation",22)
	column.add_child(body)
	var categories := VBoxContainer.new()
	categories.custom_minimum_size.x=155
	body.add_child(categories)
	var cat := label("3Dモデル",23)
	cat.add_theme_color_override("font_color", DesignChrome.INK)
	categories.add_child(cat)
	var proc := label("Procedural",15)
	proc.add_theme_color_override("font_color", DesignChrome.MUTED)
	categories.add_child(proc)
	var grid := GridContainer.new()
	grid.columns=4
	grid.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation",12)
	grid.add_theme_constant_override("v_separation",12)
	body.add_child(grid)
	var group := ButtonGroup.new()
	for index in PRIMITIVES.SHAPES.size():
		var card := Button.new()
		card.toggle_mode=true
		card.button_group=group
		card.focus_mode=Control.FOCUS_NONE
		card.custom_minimum_size=Vector2(188,220)
		DesignChrome.style_quiet(card)
		card.pressed.connect(select_shape.bind(index))
		card.gui_input.connect(func(event):
			if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.double_click and event.pressed:
				spawn_selected(index))
		grid.add_child(card)
		cards.append(card)
		var stack := VBoxContainer.new()
		card.add_child(stack)
		stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.offset_left=8; stack.offset_right=-8; stack.offset_top=8; stack.offset_bottom=-8
		stack.mouse_filter=Control.MOUSE_FILTER_IGNORE
		var preview := SubViewportContainer.new()
		preview.custom_minimum_size=Vector2(160,166)
		preview.size_flags_vertical=Control.SIZE_EXPAND_FILL
		preview.stretch=true
		preview.mouse_filter=Control.MOUSE_FILTER_IGNORE
		stack.add_child(preview)
		build_preview(preview,PRIMITIVES.SHAPES[index])
		var name_label := label(PRIMITIVES.NAMES[index],19)
		name_label.add_theme_color_override("font_color", DesignChrome.INK)
		name_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
		name_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
		stack.add_child(name_label)
	column.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	column.add_child(footer)
	status=label("",18)
	status.add_theme_color_override("font_color", DesignChrome.MUTED)
	status.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	footer.add_child(status)
	camera_button=Button.new()
	camera_button.text="◉ Camera を作成"
	camera_button.custom_minimum_size=Vector2(190,48)
	camera_button.focus_mode=Control.FOCUS_NONE
	DesignChrome.style_quiet(camera_button)
	camera_button.pressed.connect(spawn_camera)
	footer.add_child(camera_button)
	mirror_button=Button.new()
	mirror_button.text="▣ Mirror を作成"
	mirror_button.custom_minimum_size=Vector2(190,48)
	mirror_button.focus_mode=Control.FOCUS_NONE
	DesignChrome.style_quiet(mirror_button)
	mirror_button.pressed.connect(spawn_mirror)
	footer.add_child(mirror_button)
	var presets := VBoxContainer.new()
	presets.add_theme_constant_override("separation",4)
	footer.add_child(presets)
	text_button=Button.new()
	text_button.text="テキストを作成"
	text_button.custom_minimum_size=Vector2(190,48)
	text_button.focus_mode=Control.FOCUS_NONE
	DesignChrome.style_quiet(text_button)
	text_button.pressed.connect(spawn_slot.bind(true))
	presets.add_child(text_button)
	slot_button=Button.new()
	slot_button.text="空のSlotを作成"
	slot_button.custom_minimum_size=Vector2(190,48)
	slot_button.focus_mode=Control.FOCUS_NONE
	DesignChrome.style_quiet(slot_button)
	slot_button.pressed.connect(spawn_slot.bind(false))
	presets.add_child(slot_button)
	create_button=Button.new()
	create_button.custom_minimum_size=Vector2(210,48)
	create_button.focus_mode=Control.FOCUS_NONE
	DesignChrome.style_primary(create_button)
	create_button.pressed.connect(spawn_selected)
	footer.add_child(create_button)
	show_selection(0)

func build_preview(parent: SubViewportContainer, shape: String) -> void:
	var preview := SubViewport.new()
	preview.size=Vector2i(160,166)
	preview.own_world_3d=true
	preview.render_target_update_mode=SubViewport.UPDATE_ONCE
	parent.add_child(preview)
	var camera := Camera3D.new()
	preview.add_child(camera)
	camera.position=Vector3(2,1.6,2.8)
	camera.look_at(Vector3.ZERO)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=2.2
	var environment := WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=DesignChrome.GROUND
	environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color=Color.WHITE
	environment.environment.ambient_light_energy=0.85
	preview.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees=Vector3(-45,-30,0)
	preview.add_child(light)
	var object := MeshInstance3D.new()
	object.mesh=PRIMITIVES.create(shape)
	var material := StandardMaterial3D.new()
	material.albedo_color=DesignChrome.PLUM
	material.roughness=0.55
	material.cull_mode=BaseMaterial3D.CULL_DISABLED
	object.material_override=material
	preview.add_child(object)

func show_selection(index: int) -> void:
	selected=index
	for i in cards.size():
		cards[i].button_pressed = i == index
		DesignChrome.style_quiet(cards[i], i == index)
	AppLanguage.format_text(create_button, "%s を作成", [tr(PRIMITIVES.NAMES[index])])

func select_shape(index: int) -> void:
	show_selection(index)
	manager.edit(panel_id,"creation_shape",PRIMITIVES.SHAPES[index],func(result):
		if not result.ok: status.text=result.get("message","選択を変更できませんでした"))

func refresh(object: Dictionary) -> void:
	var index: int=PRIMITIVES.SHAPES.find(object.creation.shape)
	if index>=0: show_selection(index)
	for card in cards: card.disabled=not app.editable
	slot_button.disabled=busy or not app.editable
	text_button.disabled=busy or not app.editable
	camera_button.disabled=busy or not app.editable
	mirror_button.disabled=busy or not app.editable
	create_button.disabled=busy or not app.editable

func refresh_language() -> void:
	# Re-resolve translated arguments after AppLanguage has refreshed its
	# stored templates, so the bound shape name uses the new language too.
	show_selection(selected)

func finish_all() -> void:
	pass

func spawn_slot(with_text: bool) -> void:
	if busy or not app.editable: return
	busy=true
	slot_button.disabled=true
	text_button.disabled=true
	camera_button.disabled=true
	mirror_button.disabled=true
	create_button.disabled=true
	status.text="作成中…"
	var position: Vector3=app.camera.global_position-app.camera.global_basis.z*4.0
	position.y=app.player_position.y+1.6
	var components: Array=[]
	if with_text: components.append({"type_id":"WorldText","values":{"world_text":"Text","world_text_color":[1.0,1.0,1.0,1.0]}})
	var command: Dictionary={"action":"create_slot","parent":null,"position":[position.x,position.y,position.z],"components":components}
	if with_text:
		var forward: Vector3=-app.camera.global_basis.z
		forward.y=0.0
		if forward.length_squared()<0.0001: forward=Vector3.FORWARD
		var rotation: Quaternion=Basis.looking_at(forward.normalized(),Vector3.UP).get_rotation_quaternion()
		command["rotation"]=[rotation.x,rotation.y,rotation.z,rotation.w]
	manager.command({"kind":"structure","command":command},func(result):
		busy=false
		slot_button.disabled=not app.editable
		text_button.disabled=not app.editable
		camera_button.disabled=not app.editable
		mirror_button.disabled=not app.editable
		create_button.disabled=not app.editable
		if result.ok:
			app.select_object(result.selected.instance_id)
			manager.close_panel(panel_id)
		else: status.text=result.get("message","作成できませんでした"))

func spawn_selected(index: int = -1) -> void:
	var chosen: int=selected if index<0 else index
	spawn_shape(PRIMITIVES.SHAPES[chosen],PRIMITIVES.NAMES[chosen])

func spawn_camera() -> void:
	spawn_shape("camera","Camera")

func spawn_mirror() -> void:
	spawn_shape("mirror","Mirror")

func spawn_shape(shape: String, name_text: String) -> void:
	if busy or not app.editable: return
	busy=true
	create_button.disabled=true
	slot_button.disabled=true
	text_button.disabled=true
	camera_button.disabled=true
	mirror_button.disabled=true
	status.text="作成中…"
	var position: Vector3=app.camera.global_position-app.camera.global_basis.z*4.0+app.camera.global_basis.x*2.2
	position.y=app.player_position.y+(0.03 if shape=="grid" else (1.6 if shape in ["camera","mirror"] else 0.75))
	var orientation := Quaternion.IDENTITY
	if shape=="camera": orientation=app.camera.global_basis.get_rotation_quaternion()
	elif shape=="mirror": orientation=Quaternion(Vector3.UP,app.camera.rotation.y)
	manager.command({"kind":"structure","command":{"action":"import_asset","name":name_text,"position":[position.x,position.y,position.z],"rotation":[orientation.x,orientation.y,orientation.z,orientation.w],"visual":{"kind":"primitive","shape":shape}}},func(result):
		busy=false
		create_button.disabled=not app.editable
		slot_button.disabled=not app.editable
		text_button.disabled=not app.editable
		camera_button.disabled=not app.editable
		mirror_button.disabled=not app.editable
		if result.ok:
			app.select_object(result.selected.instance_id)
			manager.close_panel(panel_id)
		else: status.text=result.get("message","作成できませんでした"))
