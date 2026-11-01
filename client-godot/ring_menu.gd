extends Control
## Pointer-operated local menu. It never creates replicated UI state.
signal chosen(index: int)
signal cancelled
const DesignChrome = preload("res://design_chrome.gd")
const INNER := 72.0
const OUTER := 178.0
const LABELS := ["Inspector 2D", "Inspector 3D", "新規作成…", "Resources"]
const ICONS := ["▣", "◇", "+", "▤"]
var center := Vector2.ZERO
var hovered := -1
var target_name := ""
var enabled := true
var font: Font

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	font = ThemeDB.fallback_font
	gui_input.connect(pointer_input)
	resized.connect(func(): center = center.clamp(Vector2.ONE * (OUTER+16), size-Vector2.ONE*(OUTER+16)); queue_redraw())

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED: queue_redraw()

func open(at: Vector2, name_text: String, can_edit: bool) -> void:
	center = at.clamp(Vector2.ONE*(OUTER+16), size-Vector2.ONE*(OUTER+16))
	target_name = name_text
	enabled = can_edit
	hovered = -1
	show()
	queue_redraw()

func sector(at: Vector2) -> int:
	var offset := at-center
	if offset.length() < INNER or offset.length() > OUTER: return -1
	return int(fposmod(offset.angle()+PI*0.75,TAU)/(PI*0.5))

func pointer_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hovered = sector(event.position)
		queue_redraw()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			cancelled.emit()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var selected := sector(event.position)
			if selected < 0: cancelled.emit()
			elif enabled: chosen.emit(selected)
	accept_event()

func centered_text(value: String, at: Vector2, font_size: int, color: Color) -> void:
	var width := font.get_string_size(value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
	draw_string(font,at-Vector2(width*0.5,0),value,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size,color)

func _draw() -> void:
	if font == null: return
	# Soft warm veil — paper workspace, not teal night.
	draw_rect(Rect2(Vector2.ZERO,size), Color(38 / 255.0, 38 / 255.0, 46 / 255.0, 0.18))
	for index in 4:
		var angle := -PI*0.5+index*PI*0.5
		var start := angle-PI*0.25+0.025
		var end := angle+PI*0.25-0.025
		var points := PackedVector2Array()
		for step in 33: points.append(center+Vector2.from_angle(lerpf(start,end,float(step)/32))*OUTER)
		for step in 33: points.append(center+Vector2.from_angle(lerpf(end,start,float(step)/32))*INNER)
		var active := index == hovered and enabled
		draw_colored_polygon(points, DesignChrome.PALE if active else Color("fffdf9f2"))
		draw_polyline(points+PackedVector2Array([points[0]]), DesignChrome.PLUM if active else DesignChrome.LINE, 1.8 if active else 1.4, true)
		var position := center+Vector2.from_angle(angle)*125
		centered_text(ICONS[index], position+Vector2(0,-4), 29, DesignChrome.PLUM if enabled else DesignChrome.MUTED)
		centered_text(tr(LABELS[index]), position+Vector2(0,23), 15, DesignChrome.INK if enabled else DesignChrome.MUTED)
	draw_circle(center, INNER-5, DesignChrome.PAPER)
	draw_arc(center, INNER-5, 0, TAU, 64, DesignChrome.LINE, 1.4, true)
	centered_text("tukurium", center+Vector2(0,-8), 17, DesignChrome.PLUM)
	centered_text(target_name.left(15), center+Vector2(0,15), 12, DesignChrome.MUTED)
