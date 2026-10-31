extends "res://inspector_view.gd"
## Desktop layout of the same inspector model and editing operations.
## No SubViewport texture or world-panel dimensions are used here.
var active_tab := 0
var pending_tab := -1
var local_script := ""
var local_state := {"inspector":{"target":null,"tree":{"root":null,"collapsed":[]}}}

func set_initial_target(id: String) -> void:
	local_state.inspector.target = manager.app.address_of(manager.app.objects[id]) if manager.app.objects.has(id) else null
	refresh_local()

func refresh_local() -> void:
	var target: Variant = local_state.inspector.target
	if target != null and not manager.app.objects.has(target.instance_id):
		local_state.inspector.target = null
	refresh(local_state)

func write_view_field(field: String, value: Variant, callback: Callable = Callable()) -> void:
	match field:
		"inspector_target":
			local_state.inspector.target = value
			local_script = ""
			scroll.scroll_vertical = 0
		"inspector_tree": local_state.inspector.tree = value
	refresh_local()
	if callback.is_valid(): callback.call({"ok":true})

func build_layout() -> void:
	var margin := MarginContainer.new()
	for edge in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 12)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	title.text = "Inspector"
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	target_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(target_picker)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)
	build_actions(actions)
	column.add_child(HSeparator.new())
	var body := HSplitContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.split_offset = 245
	column.add_child(body)
	build_body(body)
	script_view.local_selection = true
	hierarchy.custom_minimum_size.x = 200
	hierarchy.tree.add_theme_font_size_override("font_size", 17)
	column.add_child(HSeparator.new())
	column.add_child(message)

func select_tab(_index: int) -> void:
	pass

func tick() -> void:
	super.tick()

func show_requested_script(id: String) -> void:
	open_script("" if id == "*" else id)

func refresh_pages(_object: Dictionary) -> void:
	tabs.set_block_signals(true)
	tabs.current_tab = 0
	tabs.set_block_signals(false)
	scroll.visible = true
	script_mount.visible = false
	script_view.active = false

func restore_scroll(_object: Dictionary) -> void:
	pass # Desktop scrolling is local and independent of the world surface.

func on_scroll(_value: float) -> void:
	pass # Resizing or scrolling this view must never write panel_scroll.
