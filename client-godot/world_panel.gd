extends MeshInstance3D
## A shared surface. Content views render InspectorView or CreationView data.
const INSPECTOR_VIEW = preload("res://inspector_view.gd")
const CREATION_VIEW = preload("res://creation_panel.gd")
var panel_id := ""
var viewport := SubViewport.new()
var content
var inspector_content := true
var manager
var last_pointer := Vector2(-1000, -1000)

func setup(controller, id: String) -> void:
	manager = controller
	panel_id = id
	inspector_content = manager.app.objects[id].get("creation") == null
	content = INSPECTOR_VIEW.new() if inspector_content else CREATION_VIEW.new()
	setup_local(content, Vector2i(720, 960), Vector2(1.2, 1.6), content.setup.bind(controller, id), id)

## Reuse the same surface and pointer mapping for a private XR menu.
func setup_local(view: Control, pixels: Vector2i, meters: Vector2, configure: Callable = Callable(), object_id: String = "") -> void:
	content = view
	var quad := QuadMesh.new()
	quad.size = meters
	mesh = quad
	viewport.name = "PanelViewport"
	viewport.size = pixels
	viewport.transparent_bg = false
	viewport.disable_3d = true
	viewport.gui_embed_subwindows = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)
	viewport.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if configure.is_valid(): configure.call()
	var surface := StandardMaterial3D.new()
	surface.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	surface.albedo_texture = viewport.get_texture()
	surface.cull_mode = BaseMaterial3D.CULL_DISABLED
	surface.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	material_override = surface
	var body := StaticBody3D.new()
	body.name = "PickBody"
	if not object_id.is_empty(): body.set_meta("object_id", object_id)
	var collision := CollisionShape3D.new()
	collision.name = "Collider"
	var shape := BoxShape3D.new()
	shape.size = Vector3(meters.x, meters.y, 0.05)
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func refresh(object: Dictionary) -> void:
	var size := Vector2i(int(object.panel.size[0]), int(object.panel.size[1]))
	# Assigning the same size still reallocates the render target, so only
	# resize when the shared panel size actually changed (as in mirror_renderer).
	if viewport.size != size:
		viewport.size = size
		# Preserve square pixels on the world surface; the desktop window has its own layout.
		mesh.size = Vector2(1.6 * float(size.x) / float(size.y), 1.6)
	content.refresh(object)

func canvas_point(global_point: Vector3) -> Vector2:
	var local := to_local(global_point)
	return Vector2((local.x / mesh.size.x + 0.5) * viewport.size.x, (0.5 - local.y / mesh.size.y) * viewport.size.y)

func forward_pointer(event: InputEventMouse, point: Vector2) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# A camera move can change the hit without a viewport mouse-motion event.
		# Refresh hover at the actual ray hit before deciding which editor keeps focus.
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
	if content.has_method("finish_all"): content.finish_all()

func has_text_focus() -> bool:
	var focus := viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit
