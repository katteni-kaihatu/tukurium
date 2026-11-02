extends CanvasLayer
## Personal session UI. Shared participants and messages are supplied by the Engine.
const DesignChrome = preload("res://design_chrome.gd")
const INK := Color("26262e")
const LINE := Color("dcd5c8")
const TEXT := Color("26262e")
const MUTED := Color("5e5c64")
const ACCENT := Color("603d56")
var app
var root := Control.new()
var left: PanelContainer
var right: PanelContainer
var left_edge: Button
var right_edge: Button
var count_label: Label
var player_rows: VBoxContainer
var chat_rows: VBoxContainer
var chat_scroll: ScrollContainer
var chat_input: LineEdit
var send_button: Button
var chat_status: Label
var participants: Array = []
var self_id := "local"
var messages: Array = []
var stowed := false
var input_locked := false
var next_roster := 0
var roster_identity := ""
var roster_signature := ""
var slide: Tween

func panel_style() -> StyleBoxFlat:
	return DesignChrome.panel(DesignChrome.PAPER_GLASS, 16, 12, true)

func label(value: String, size: int = 14, color: Color = TEXT) -> Label:
	var node := Label.new()
	node.text=value
	node.add_theme_font_size_override("font_size",size)
	node.add_theme_color_override("font_color",color)
	return node

func small_button(value: String, action: Callable) -> Button:
	var node := Button.new()
	node.text=value
	node.focus_mode=Control.FOCUS_NONE
	node.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	DesignChrome.style_ghost(node)
	node.pressed.connect(action)
	return node

func setup(owner) -> void:
	app=owner
	layer=15
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter=Control.MOUSE_FILTER_IGNORE
	left=PanelContainer.new()
	left.name="ParticipantsPanel"
	left.add_theme_stylebox_override("panel",panel_style())
	left.anchor_bottom=1.0
	left.offset_left=16; left.offset_right=288; left.offset_top=80; left.offset_bottom=-98
	root.add_child(left)
	var players := VBoxContainer.new()
	players.add_theme_constant_override("separation",10)
	left.add_child(players)
	var player_head := HBoxContainer.new()
	players.add_child(player_head)
	var title := label("参加者",18)
	title.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	player_head.add_child(title)
	count_label=label("0人",13,MUTED)
	player_head.add_child(count_label)
	player_head.add_child(small_button("‹",func(): set_stowed(true)))
	players.add_child(HSeparator.new())
	var player_scroll := ScrollContainer.new()
	player_scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL
	player_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	players.add_child(player_scroll)
	player_rows=VBoxContainer.new()
	player_rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	player_rows.add_theme_constant_override("separation",7)
	player_scroll.add_child(player_rows)
	right=PanelContainer.new()
	right.name="ChatPanel"
	right.add_theme_stylebox_override("panel",panel_style())
	right.anchor_left=1.0; right.anchor_right=1.0; right.anchor_bottom=1.0
	right.offset_left=-326; right.offset_right=-16; right.offset_top=80; right.offset_bottom=-98
	root.add_child(right)
	var chat := VBoxContainer.new()
	chat.add_theme_constant_override("separation",9)
	right.add_child(chat)
	var chat_head := HBoxContainer.new()
	chat.add_child(chat_head)
	var chat_title := label("チャット",18)
	chat_title.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	chat_head.add_child(chat_title)
	chat_head.add_child(small_button("›",func(): set_stowed(true)))
	chat.add_child(HSeparator.new())
	chat_scroll=ScrollContainer.new()
	chat_scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL
	chat_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	chat.add_child(chat_scroll)
	chat_rows=VBoxContainer.new()
	chat_rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	chat_rows.add_theme_constant_override("separation",9)
	chat_scroll.add_child(chat_rows)
	chat_status=label("セッション全体",12,MUTED)
	chat.add_child(chat_status)
	var compose := HBoxContainer.new()
	compose.add_theme_constant_override("separation",6)
	chat.add_child(compose)
	chat_input=LineEdit.new()
	chat_input.placeholder_text="メッセージを入力"
	chat_input.max_length=1000
	chat_input.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	chat_input.text_submitted.connect(func(_value): send_chat())
	DesignChrome.style_line_edit(chat_input)
	compose.add_child(chat_input)
	send_button=small_button("送信",send_chat)
	DesignChrome.style_primary(send_button)
	compose.add_child(send_button)
	left_edge=small_button("›",func(): set_stowed(false))
	left_edge.position=Vector2(0,95)
	left_edge.custom_minimum_size=Vector2(24,58)
	left_edge.hide()
	root.add_child(left_edge)
	right_edge=small_button("‹",func(): set_stowed(false))
	right_edge.anchor_left=1.0; right_edge.anchor_right=1.0
	right_edge.offset_left=-24; right_edge.offset_right=0
	right_edge.offset_top=95; right_edge.offset_bottom=153
	right_edge.hide()
	root.add_child(right_edge)
	update_participants([],"local")
	set_messages([])

func update_participants(people: Array, own_id: String) -> void:
	participants=people.duplicate(true)
	self_id=own_id
	var identities := PackedStringArray()
	for person in participants:
		if person is Dictionary: identities.append("%s:%s" % [person.get("id",""),person.get("name","")])
	identities.sort()
	var identity := own_id + "|" + "|".join(identities)
	if identity!=roster_identity:
		roster_identity=identity
		refresh_roster()
		next_roster=Time.get_ticks_msec()+500

func horizontal_distance(person: Dictionary, origin: Vector3) -> float:
	var pose: Dictionary=person.get("pose",{})
	var position: Array=pose.get("position",[])
	if position.size()!=3: return INF
	return Vector2(float(position[0])-origin.x,float(position[2])-origin.z).length()

func refresh_roster() -> void:
	if player_rows==null: return
	var others: Array=[]
	var own: Dictionary={}
	for value in participants:
		if not value is Dictionary: continue
		if str(value.get("id",""))==self_id: own=value
		else: others.append(value)
	var origin: Vector3=app.player_target_position
	others.sort_custom(func(a,b): return horizontal_distance(a,origin)<horizontal_distance(b,origin))
	# The rows render exactly: the count, the own name, then per other person a
	# band heading on band changes plus (name, formatted distance). Skip the
	# rebuild while that rendered content is unchanged.
	var rows: Array=[]
	var signature_parts: Array=[str(participants.size()),str(own.get("name",""))]
	var last_band := -1
	for person in others:
		var distance := horizontal_distance(person,origin)
		var band := 0 if distance<=3.0 else (1 if distance<=15.0 else 2)
		rows.append([person,distance,band,band!=last_band])
		if band!=last_band: last_band=band
		signature_parts.append("%d|%s|%s" % [band,person.get("name",""),("%.1fm" % distance) if is_finite(distance) else "—"])
	var signature := "\n".join(signature_parts)
	if signature==roster_signature: return
	roster_signature=signature
	for child in player_rows.get_children(): child.queue_free()
	AppLanguage.format_text(count_label,"%d人",[participants.size()])
	if participants.is_empty():
		player_rows.add_child(label("まだ誰もいません",13,MUTED))
		return
	if not own.is_empty(): add_player(own,0.0,true)
	for row in rows:
		if row[3]:
			var heading := label(["●  すぐそば · 3m以内","●  近く · 15m以内","●  とおく"][row[2]],12,[ACCENT,DesignChrome.WARN,MUTED][row[2]])
			heading.mouse_filter=Control.MOUSE_FILTER_IGNORE
			player_rows.add_child(heading)
		add_player(row[0],row[1],false)

func add_player(person: Dictionary, distance: float, own: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation",8)
	player_rows.add_child(row)
	var initial := str(person.get("name","?"))
	var avatar := label(initial.substr(0,1).to_upper(),15,ACCENT if own else TEXT)
	avatar.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	avatar.custom_minimum_size.x=24
	row.add_child(avatar)
	var name := label(initial,13)
	name.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	if own: AppLanguage.format_text(name,"%s  あなた",[initial])
	name.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	name.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name)
	if not own:
		row.add_child(label("%.1fm" % distance if is_finite(distance) else "—",11,MUTED))

func set_messages(items: Array) -> void:
	messages=items.duplicate(true)
	if chat_rows==null: return
	var bar := chat_scroll.get_v_scroll_bar()
	var follow := bar.value>=bar.max_value-bar.page-20.0
	var old_scroll := chat_scroll.scroll_vertical
	for child in chat_rows.get_children(): child.queue_free()
	if messages.is_empty(): chat_rows.add_child(label("ここから会話をはじめよう",13,MUTED))
	for item in messages:
		if not item is Dictionary: continue
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation",2)
		chat_rows.add_child(body)
		var heading := HBoxContainer.new()
		body.add_child(heading)
		var sender := label(str(item.get("sender_name","")),13,ACCENT)
		sender.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
		sender.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		heading.add_child(sender)
		var time := Time.get_datetime_dict_from_unix_time(int(item.get("at_millis",0))/1000)
		heading.add_child(label("%02d:%02d" % [time.hour,time.minute],11,MUTED))
		var content := label(str(item.get("text","")),13)
		content.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
		content.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		body.add_child(content)
	_restore_scroll.call_deferred(follow,old_scroll)

func _restore_scroll(follow: bool, old_scroll: int) -> void:
	if follow: chat_scroll.scroll_vertical=int(chat_scroll.get_v_scroll_bar().max_value)
	else: chat_scroll.scroll_vertical=old_scroll

func send_chat() -> void:
	var value := chat_input.text.strip_edges()
	if value.is_empty() or not app.connected or not app.editable: return
	app.queue_message({"kind":"chat_send","text":value})
	chat_input.clear()
	chat_status.text="セッション全体"

func show_error(message: String) -> void:
	chat_status.text=message

func set_stowed(value: bool, animate: bool = true) -> void:
	if stowed==value: return
	stowed=value
	if value and chat_input.has_focus(): chat_input.release_focus()
	if slide and slide.is_running(): slide.kill()
	left.show(); right.show()
	left_edge.visible=value; right_edge.visible=value
	var left_x := -288.0 if value else 16.0
	var left_right := -16.0 if value else 288.0
	var right_x := 16.0 if value else -326.0
	var right_right := 326.0 if value else -16.0
	var alpha := 0.0 if value else (0.38 if input_locked else 1.0)
	if not animate:
		left.offset_left=left_x; left.offset_right=left_right
		right.offset_left=right_x; right.offset_right=right_right
		left.modulate.a=alpha; right.modulate.a=alpha
		if value: left.hide(); right.hide()
		return
	slide=create_tween().set_parallel(true)
	slide.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for panel in [left,right]: slide.tween_property(panel,"modulate:a",alpha,0.2)
	slide.tween_property(left,"offset_left",left_x,0.22)
	slide.tween_property(left,"offset_right",left_right,0.22)
	slide.tween_property(right,"offset_left",right_x,0.22)
	slide.tween_property(right,"offset_right",right_right,0.22)
	slide.finished.connect(func(): if stowed: left.hide(); right.hide())

func _process(_delta: float) -> void:
	if app==null: return
	var locked: bool=app.fps_active or Input.mouse_mode==Input.MOUSE_MODE_CAPTURED
	if locked!=input_locked:
		if locked and chat_input.has_focus(): chat_input.release_focus()
		input_locked=locked
		for panel in [left,right,left_edge,right_edge]:
			panel.mouse_behavior_recursive=Control.MOUSE_BEHAVIOR_DISABLED if locked else Control.MOUSE_BEHAVIOR_INHERITED
		if not stowed:
			left.modulate.a=0.38 if locked else 1.0
			right.modulate.a=0.38 if locked else 1.0
		left_edge.modulate.a=0.38 if locked else 1.0
		right_edge.modulate.a=0.38 if locked else 1.0
	chat_input.editable=not locked and app.editable
	send_button.disabled=locked or not app.editable
	if Time.get_ticks_msec()>=next_roster:
		next_roster=Time.get_ticks_msec()+500
		if not stowed: refresh_roster()
