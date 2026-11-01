extends Control
## Local floating frame. Position and size never become shared world state.
signal focused
const DesignChrome = preload("res://design_chrome.gd")

var panel := PanelContainer.new()
var grip := Button.new()
var dragging := false
var resizing := false
var origin := Vector2.ZERO
var start_position := Vector2.ZERO
var start_size := Vector2.ZERO
var minimum_window_size := Vector2(480, 360)

func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grip.text="◢"
	grip.tooltip_text="ドラッグしてサイズ変更"
	grip.focus_mode=Control.FOCUS_NONE
	grip.mouse_default_cursor_shape=Control.CURSOR_FDIAGSIZE
	grip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	grip.offset_left=-30
	grip.offset_top=-30
	grip.offset_right=0
	grip.offset_bottom=0
	grip.add_theme_stylebox_override("normal",StyleBoxEmpty.new())
	grip.add_theme_stylebox_override("hover",StyleBoxEmpty.new())
	grip.add_theme_color_override("font_color", DesignChrome.MUTED)
	add_child(grip)
	grip.gui_input.connect(_grip_input)

func use_titlebar(handle: Control) -> void:
	handle.mouse_filter=Control.MOUSE_FILTER_PASS
	handle.mouse_default_cursor_shape=Control.CURSOR_MOVE
	handle.gui_input.connect(_title_input)

func _title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
		dragging=true
		resizing=false
		origin=event.global_position
		start_position=position
		get_viewport().set_input_as_handled()

func _grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
		resizing=true
		dragging=false
		origin=event.global_position
		start_size=size
		get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed and is_visible_in_tree():
		var hovered: Control=get_viewport().gui_get_hovered_control()
		if hovered!=null and is_ancestor_of(hovered):
			move_to_front()
			focused.emit()
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and not event.pressed:
		dragging=false
		resizing=false
	elif event is InputEventMouseMotion and (dragging or resizing):
		var delta: Vector2=event.global_position-origin
		var screen: Vector2=get_viewport_rect().size
		if dragging:
			position=Vector2(clampf(start_position.x+delta.x,0,maxf(0,screen.x-size.x)),clampf(start_position.y+delta.y,72,maxf(72,screen.y-size.y-60)))
		else:
			size=Vector2(clampf(start_size.x+delta.x,minimum_window_size.x,screen.x-position.x),clampf(start_size.y+delta.y,minimum_window_size.y,screen.y-position.y-60))
		get_viewport().set_input_as_handled()
