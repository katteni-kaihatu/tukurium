extends Node
## Local delivery/rendering state. Never saved in the shared world.
signal changed(key: String, state: Dictionary)
const DesignChrome = preload("res://design_chrome.gd")
var app: Node
var entries: Dictionary = {}
var badges: Dictionary = {}
var panel := PanelContainer.new()
var rows := VBoxContainer.new()
var heading := Label.new()
var row_nodes: Dictionary = {}
var expiry := Timer.new()
var refresh_queued := false
const TITLES := {
	"queued":"Queued", "converting":"Converting FBX / video", "preparing":"Preparing model",
	"uploading_local":"Sending to local engine", "uploading_host":"Uploading to host",
	"waiting_host":"Waiting for host", "placing":"Adding to world",
	"waiting":"Requesting asset", "waiting_upload":"Asset upload in progress", "downloading_network":"Downloading from host",
	"downloading_local":"Loading from local cache", "verifying":"Checking asset",
	"loading_model":"Building model", "loading_texture":"Preparing texture", "loading_video":"Opening video",
	"ready":"Ready", "error":"Failed"
}

func setup(application: Node) -> void:
	app = application
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	layer.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.offset_left = -225
	panel.offset_right = 225
	panel.offset_top = 112
	panel.offset_bottom = 180
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", DesignChrome.panel(DesignChrome.PAPER_GLASS, 12, 12, true))
	panel.add_child(rows)
	heading.add_theme_font_size_override("font_size",12)
	heading.add_theme_color_override("font_color", DesignChrome.INK)
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(heading)
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.visible = false
	expiry.one_shot = true
	expiry.timeout.connect(refresh)
	add_child(expiry)
	changed.connect(func(_key: String, _state: Dictionary): _queue_refresh())

func _queue_refresh() -> void:
	if refresh_queued: return
	refresh_queued = true
	call_deferred("_run_queued_refresh")

func _run_queued_refresh() -> void:
	refresh_queued = false
	refresh()

func _notification(what: int) -> void:
	if what==NOTIFICATION_TRANSLATION_CHANGED and app!=null:
		_queue_refresh()

func name_for(key: String) -> String:
	for object in app.objects.values():
		if object.visual.get("asset_id","") == key:
			for field in object.fields:
				if field.id == "name": return str(field.value)
	return tr("Asset %s") % key.left(8)

func update(key: String, phase: String, completed: int = 0, total: int = 0, message: String = "", title: String = "", message_args: Array = []) -> void:
	var entry: Dictionary = entries.get(key,{})
	entry.merge({"phase":phase,"completed":maxi(0,completed),"total":maxi(0,total),"message":message,"message_args":message_args.duplicate(),"updated":Time.get_ticks_msec()},true)
	if not title.is_empty(): entry.title = title
	entries[key] = entry
	changed.emit(key,entry.duplicate())

func description(entry: Dictionary) -> String:
	var text: String = tr(str(TITLES.get(entry.phase,entry.phase)))
	if int(entry.total) > 0:
		text += " · %d%% · %s / %s" % [mini(100,int(100.0*entry.completed/entry.total)),String.humanize_size(entry.completed),String.humanize_size(entry.total)]
	if not str(entry.message).is_empty():
		var message := tr(str(entry.message))
		if not entry.get("message_args",[]).is_empty(): message=message % entry.message_args
		text += " · " + message
	return text

func refresh() -> void:
	var now := Time.get_ticks_msec()
	var visible_entries: Array = []
	for key in entries.keys():
		var entry: Dictionary = entries[key]
		if entry.phase == "ready" and now-int(entry.updated)>5000:
			entries.erase(key)
			continue
		visible_entries.append(key)
	visible_entries.sort_custom(func(a,b):
		var a_ready: bool = entries[a].phase == "ready"
		var b_ready: bool = entries[b].phase == "ready"
		return int(entries[a].updated) > int(entries[b].updated) if a_ready==b_ready else not a_ready)
	var shown := visible_entries.slice(0,3)
	for key in row_nodes.keys():
		if not shown.has(key):
			row_nodes[key].row.queue_free()
			rows.remove_child(row_nodes[key].row)
			row_nodes.erase(key)
	panel.visible = not shown.is_empty()
	heading.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	heading.text = tr("ASSETS · THIS DEVICE") + (tr(" · %d tasks") % visible_entries.size() if visible_entries.size()>3 else "")
	for index in range(shown.size()):
		var key: String = shown[index]
		var entry: Dictionary = entries[key]
		if not row_nodes.has(key):
			var row := HBoxContainer.new()
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rows.add_child(row)
			var column := VBoxContainer.new()
			column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			column.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(column)
			var label := Label.new()
			label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			label.custom_minimum_size.x = 300
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.add_theme_font_size_override("font_size",13)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			column.add_child(label)
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size.y = 5
			bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			column.add_child(bar)
			var retry := Button.new()
			retry.text = "Retry"
			retry.focus_mode = Control.FOCUS_NONE
			retry.pressed.connect(func(): app.asset_importer.retry_asset(key))
			row.add_child(retry)
			row_nodes[key] = {"row":row,"label":label,"bar":bar,"retry":retry}
		var widgets: Dictionary = row_nodes[key]
		rows.move_child(widgets.row,index+1)
		widgets.label.text = str(entry.get("title",name_for(key))) + "\n" + description(entry)
		widgets.label.add_theme_color_override("font_color",Color("ffaaa0") if entry.phase == "error" else Color("a2ece7"))
		widgets.bar.visible = int(entry.total)>0
		widgets.bar.max_value = maxi(1,int(entry.total))
		widgets.bar.value = int(entry.completed)
		widgets.retry.visible = entry.phase == "error" and not key.begins_with("import:") and app.editable
	panel.offset_bottom = panel.offset_top+rows.get_combined_minimum_size().y+24
	_schedule_expiry(now)
	refresh_badges()

## Ready entries fade out 5s after their last update. Instead of polling,
## wake up once when the oldest ready entry reaches that deadline.
func _schedule_expiry(now: int) -> void:
	if expiry.get_parent() == null: return
	var oldest := -1
	for key in entries.keys():
		if entries[key].phase == "ready":
			var updated := int(entries[key].updated)
			if oldest < 0 or updated < oldest: oldest = updated
	if oldest < 0:
		expiry.stop()
	else:
		expiry.start(maxf(0.05, float(oldest + 5000 - now) / 1000.0))

func refresh_badges() -> void:
	var wanted := {}
	for object_id in app.objects:
		var object: Dictionary = app.objects[object_id]
		if object.visual.kind not in ["model","video"]: continue
		var node: Node3D = app.render_nodes.get(object_id)
		if node == null: continue
		var ready: bool = node.has_node("ImportedModel") if object.visual.kind == "model" else node.has_node("VideoPlayer")
		if ready: continue
		wanted[object_id] = true
		if not badges.has(object_id):
			var badge := Label3D.new()
			badge.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			badge.font_size = 40
			badge.pixel_size = 0.004
			badge.outline_size = 10
			app.add_child(badge)
			badges[object_id] = badge
		var id: String = object.visual.asset_id
		var state: Dictionary = entries.get(id,{"phase":"waiting","completed":0,"total":0,"message":""})
		var badge: Label3D = badges[object_id]
		var object_name: String = str(object_id)
		for field in object.fields:
			if field.id == "name": object_name = str(field.value)
		badge.text = object_name.left(32)+"\n"+tr(str(TITLES.get(state.phase,state.phase)))
		if int(state.total)>0:
			badge.text += "\n%d%% · %s / %s" % [mini(100,int(100.0*state.completed/state.total)),String.humanize_size(state.completed),String.humanize_size(state.total)]
		badge.modulate = DesignChrome.DANGER if state.phase == "error" else DesignChrome.PLUM
		var height := 1.0
		if object.get("collider") is Dictionary: height = float(object.collider.half_extents[1])*absf(float(object.world_scale[1]))
		badge.global_position = node.global_position+Vector3.UP*(height+0.2)
	for object_id in badges.keys():
		if not wanted.has(object_id):
			badges[object_id].queue_free()
			badges.erase(object_id)
