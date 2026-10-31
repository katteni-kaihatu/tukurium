extends MeshInstance3D
## A shared surface. Content views render Inspector / Creation / Resources / Script Editor data.
## Inspector boards prefer the HTML panel texture when the host is connected.
const INSPECTOR_VIEW = preload("res://inspector_view.gd")
const CREATION_VIEW = preload("res://creation_panel.gd")
const RESOURCES_VIEW = preload("res://resources_view.gd")
const SCRIPT_EDITOR_VIEW = preload("res://script_editor_view.gd")
var panel_id := ""
var viewport := SubViewport.new()
var content
var inspector_content := true
var manager
var last_pointer := Vector2(-1000, -1000)
var html_texture: Texture2D
var using_html := false

func setup(controller, id: String) -> void:
	manager = controller
	panel_id = id
	var object: Dictionary = manager.app.objects[id]
	inspector_content = object.get("inspector") != null
	if object.get("resources") != null:
		content = RESOURCES_VIEW.new()
	elif object.get("script_editor") != null:
		content = SCRIPT_EDITOR_VIEW.new()
	elif object.get("creation") != null:
		content = CREATION_VIEW.new()
	else:
		content = INSPECTOR_VIEW.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.2, 1.6)
	mesh = quad
	viewport.name = "PanelViewport"
	viewport.size = Vector2i(720, 960)
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)
	viewport.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.setup(controller, id)
	var surface := StandardMaterial3D.new()
	surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.albedo_texture = viewport.get_texture()
	surface.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	material_override = surface
	var body := StaticBody3D.new()
	body.name = "PickBody"
	body.set_meta("object_id", id)
	var collision := CollisionShape3D.new()
	collision.name = "Collider"
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.2, 1.6, 0.05)
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func refresh(object: Dictionary) -> void:
	var size := Vector2i(int(object.panel.size[0]), int(object.panel.size[1]))
	if viewport.size != size:
		viewport.size = size
		mesh.size = Vector2(1.6 * float(size.x) / float(size.y), 1.6)
	content.refresh(object)
	if inspector_content and manager.app.html_ui != null and manager.app.html_ui.active:
		# Prefer the HTML paper board immediately so the old dark Control theme never flashes.
		using_html = true
		content.visible = false
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var texture = manager.app.html_ui.texture_for(panel_id)
		if texture != null: apply_html_texture(texture)
		else:
			material_override.albedo_texture = null
			material_override.albedo_color = Color("fffdf9")

func apply_html_texture(texture: Texture2D) -> void:
	if not inspector_content or texture == null: return
	html_texture = texture
	using_html = true
	material_override.albedo_color = Color(1, 1, 1, 1)
	material_override.albedo_texture = texture
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	content.visible = false

func canvas_size() -> Vector2:
	if using_html: return Vector2(1120, 960)
	return Vector2(viewport.size)

func canvas_point(global_point: Vector3) -> Vector2:
	var local := to_local(global_point)
	var size := canvas_size()
	return Vector2((local.x / mesh.size.x + 0.5) * size.x, (0.5 - local.y / mesh.size.y) * size.y)

func forward_pointer(event: InputEventMouse, point: Vector2) -> void:
	if using_html and manager.app.html_ui != null and manager.app.html_ui.active:
		manager.app.html_ui.panel_pointer(panel_id, point, event)
		last_pointer = point
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var motion := InputEventMouseMotion.new()
		motion.position = point
		motion.global_position = point
		motion.relative = point - last_pointer
		viewport.push_input(motion, true)
		var focus := viewport.gui_get_focus_owner()
		var hovered := viewport.gui_get_hovered_control()
		if focus != null and hovered != focus and (hovered == null or not focus.is_ancestor_of(hovered)):
			viewport.gui_release_focus()
	var copy: InputEventMouse = event.duplicate()
	copy.position = point
	copy.global_position = point
	if copy is InputEventMouseMotion:
		copy.relative = point - last_pointer
	last_pointer = point
	viewport.push_input(copy, true)

func leave_pointer() -> void:
	var event := InputEventMouseMotion.new()
	forward_pointer(event, Vector2(-1000, -1000))

func clear_focus() -> void:
	viewport.gui_release_focus()
	content.finish_all()

func has_text_focus() -> bool:
	if using_html: return false
	var focus := viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit
