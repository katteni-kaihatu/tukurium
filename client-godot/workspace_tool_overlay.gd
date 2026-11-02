extends CanvasLayer
## Personal 2D surface for Workspace History / Releases / Members / Debug / Commit.
## Project data comes from Engine service actions; panel placement is local (not a WorldPanel).
const DesignChrome = preload("res://design_chrome.gd")

var app
var tool := ""
var panel: PanelContainer
var title_label: Label
var body: VBoxContainer
var status: Label
var message_edit: LineEdit
var next_refresh := 0

func setup(controller) -> void:
	app = controller
	layer = 48
	visible = false
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.1, 0.12, 0.16, 0.35)
	dim.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.pressed:
			close())
	root.add_child(dim)
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", DesignChrome.panel(DesignChrome.PAPER, 16, 0, true))
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -360
	panel.offset_top = -280
	panel.offset_right = 360
	panel.offset_bottom = 280
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(panel)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(pad)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	pad.add_child(column)
	var header := HBoxContainer.new()
	column.add_child(header)
	title_label = Label.new()
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 20)
	title_label.add_theme_color_override("font_color", DesignChrome.INK)
	header.add_child(title_label)
	var close_btn := Button.new()
	close_btn.text = "×"
	close_btn.focus_mode = Control.FOCUS_NONE
	DesignChrome.style_quiet(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_color_override("font_color", DesignChrome.MUTED)
	status.add_theme_font_size_override("font_size", 13)
	column.add_child(status)

func open_tool(name: String) -> void:
	tool = name
	visible = true
	app.release_cursor()
	_rebuild()

func close() -> void:
	visible = false
	tool = ""

func _process(_delta: float) -> void:
	if not visible: return
	if Time.get_ticks_msec() < next_refresh: return
	next_refresh = Time.get_ticks_msec() + 800
	if tool in ["history", "releases", "members", "commit"]:
		_rebuild()

func _slug() -> String:
	var workspace = app.get("service_panel")
	if workspace == null: return ""
	var project: Dictionary = workspace.current_project if workspace.current_project is Dictionary else {}
	return str(project.get("slug", ""))

func _role() -> String:
	var workspace = app.get("service_panel")
	if workspace == null: return "view"
	var project: Dictionary = workspace.current_project if workspace.current_project is Dictionary else {}
	# Prefer explicit my_role from Engine service_state; never assume host.
	var role: String = str(project.get("my_role", ""))
	if role.is_empty():
		role = str(project.get("role", "view"))
	if role.is_empty():
		role = "view"
	return role

func _rebuild() -> void:
	for child in body.get_children():
		child.queue_free()
	message_edit = null
	match tool:
		"history":
			title_label.text = "History"
			_fill_history()
		"releases":
			title_label.text = "Releases"
			_fill_releases()
		"members":
			title_label.text = "Members"
			_fill_members()
		"debug":
			title_label.text = "Debug"
			_fill_debug()
		"commit":
			title_label.text = "Commit"
			_fill_commit()
		"branch":
			title_label.text = "Branch"
			_fill_branch()
		_:
			title_label.text = tool.capitalize()
			_unimplemented("この面は未実装です。")

func _unimplemented(detail: String) -> void:
	body.add_child(_note("未実装"))
	body.add_child(_note(detail))
	status.text = "Workspace tool · stub"

func _note(text: String, color: Color = DesignChrome.MUTED) -> Label:
	var node := Label.new()
	node.text = text
	node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	node.add_theme_color_override("font_color", color)
	node.add_theme_font_size_override("font_size", 14)
	return node

func _button(text: String, primary: bool = false) -> Button:
	var node := Button.new()
	node.text = text
	node.focus_mode = Control.FOCUS_NONE
	if primary:
		DesignChrome.style_primary(node)
	else:
		DesignChrome.style_quiet(node)
	return node

func _service(action: String, body: Dictionary, done: Callable) -> void:
	var workspace = app.get("service_panel")
	if workspace == null or not workspace.enabled:
		status.text = "サービス未接続"
		done.call({"ok": false, "message": "サービス未接続"})
		return
	workspace.call_service(action, body, func(data):
		var payload: Dictionary = data if data is Dictionary else {}
		payload["ok"] = true
		done.call(payload)
	, func(message):
		done.call({"ok": false, "message": str(message)})
	)

func _apply_project_meta(result: Dictionary) -> void:
	var workspace = app.get("service_panel")
	if workspace == null or not (workspace.current_project is Dictionary):
		return
	if result.has("my_role"):
		workspace.current_project["my_role"] = str(result.get("my_role", "view"))
	if result.has("branch"):
		workspace.current_project["branch"] = str(result.get("branch", "main"))

func _fill_history() -> void:
	var slug: String = _slug()
	if slug.is_empty():
		_unimplemented("Project を開くと履歴を表示します。")
		return
	var commit_open := _button("コミット…", true)
	commit_open.visible = _role() == "host"
	commit_open.pressed.connect(func(): open_tool("commit"))
	body.add_child(commit_open)
	_service("project_history", {"slug": slug}, func(result):
		if not visible or tool != "history": return
		_apply_project_meta(result)
		for child in body.get_children():
			if child is Button and child.text.begins_with("コミット"): continue
			child.queue_free()
		if not result.get("ok", false):
			body.add_child(_note("未実装" if str(result.get("message", "")).is_empty() else str(result.get("message", ""))))
			status.text = "History · unavailable"
			return
		var commits: Array = result.get("commits", [])
		if commits.is_empty():
			body.add_child(_note("コミットはまだありません。"))
		for entry in commits:
			var row := VBoxContainer.new()
			row.add_theme_constant_override("separation", 2)
			var head := Label.new()
			head.text = "%s · %s" % [str(entry.get("id", "")).substr(0, 8), str(entry.get("message", ""))]
			head.add_theme_color_override("font_color", DesignChrome.INK)
			head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row.add_child(head)
			var meta := Label.new()
			meta.text = str(entry.get("created_at", ""))
			meta.add_theme_color_override("font_color", DesignChrome.MUTED)
			meta.add_theme_font_size_override("font_size", 12)
			row.add_child(meta)
			var actions := HBoxContainer.new()
			actions.add_theme_constant_override("separation", 6)
			var diff_btn := _button("差分")
			var cid: String = str(entry.get("id", ""))
			diff_btn.pressed.connect(func(): _show_diff(slug, cid))
			actions.add_child(diff_btn)
			if _role() == "host":
				var revert_btn := _button("revert")
				revert_btn.pressed.connect(func(): _revert(slug, cid))
				actions.add_child(revert_btn)
			row.add_child(actions)
			body.add_child(row)
		status.text = "History · %d commits · branch %s" % [commits.size(), str(result.get("branch", "main"))]
	)

func _show_diff(slug: String, commit_id: String) -> void:
	_service("project_diff", {"slug": slug, "commit_id": commit_id}, func(result):
		if not result.get("ok", false):
			status.text = str(result.get("message", "差分を取得できません"))
			return
		var changes: Array = result.get("changes", [])
		status.text = "Diff · %d changes" % changes.size()
		for change in changes:
			body.add_child(_note("%s %s" % [str(change.get("kind", "")), str(change.get("path", change.get("address", "")))], DesignChrome.INK))
		var highlight: Array = result.get("highlight_ids", [])
		if app.has_method("highlight_diff_objects"):
			app.highlight_diff_objects(highlight)
	)

func _revert(slug: String, commit_id: String) -> void:
	_service("project_revert", {"slug": slug, "commit_id": commit_id}, func(result):
		status.text = str(result.get("message", "revert 完了" if result.get("ok", false) else "revert 失敗"))
		_rebuild()
	)

func _fill_commit() -> void:
	var slug: String = _slug()
	if slug.is_empty():
		_unimplemented("Project を開いてからコミットしてください。")
		return
	if _role() != "host":
		body.add_child(_note("コミットは Host のみ実行できます。"))
		status.text = "Commit · host only"
		return
	body.add_child(_note("コミットメッセージ"))
	message_edit = LineEdit.new()
	message_edit.placeholder_text = "何を変えましたか"
	DesignChrome.style_line_edit(message_edit)
	body.add_child(message_edit)
	var commit_btn := _button("すべてコミット", true)
	commit_btn.pressed.connect(func():
		var msg: String = message_edit.text.strip_edges()
		if msg.is_empty():
			status.text = "メッセージを入力してください"
			return
		_service("project_commit", {"slug": slug, "message": msg}, func(result):
			var note: String = str(result.get("ok_message", result.get("message", "コミットしました")))
			status.text = note
			if result.get("ok", false) or result.has("id"):
				# Refresh project role/branch on the service panel copy.
				var workspace = app.get("service_panel")
				if workspace != null and workspace.current_project is Dictionary:
					workspace.current_project["branch"] = str(result.get("branch", workspace.current_project.get("branch", "main")))
				open_tool("history")
		))
	body.add_child(commit_btn)
	_service("project_working_status", {"slug": slug}, func(result):
		_apply_project_meta(result)
		if result.get("ok", false) and result.get("clean", false):
			body.add_child(_note("すべてコミット済み", DesignChrome.OK))
		elif result.get("ok", false):
			body.add_child(_note("未コミットの変更があります", DesignChrome.WARN))
		status.text = "Commit · %s · %s" % [slug, _role()]
	)

func _fill_releases() -> void:
	var slug: String = _slug()
	if slug.is_empty():
		_unimplemented("Project を開くとリリース一覧を表示します。")
		return
	if _role() == "host":
		var create_btn := _button("新しいリリースを作成", true)
		create_btn.pressed.connect(func():
			_service("project_release_create", {"slug": slug}, func(result):
				status.text = str(result.get("message", ""))
				_rebuild()
			))
		body.add_child(create_btn)
	_service("project_releases", {"slug": slug}, func(result):
		if not visible or tool != "releases": return
		if not result.get("ok", false):
			body.add_child(_note(str(result.get("message", "未実装"))))
			status.text = "Releases · unavailable"
			return
		var releases: Array = result.get("releases", [])
		if releases.is_empty():
			body.add_child(_note("リリースはまだありません。コミットから作成します。"))
		for entry in releases:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var label := Label.new()
			var latest: String = " · Latest" if entry.get("latest", false) else ""
			label.text = "%s%s" % [str(entry.get("tag", entry.get("id", ""))), latest]
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.add_theme_color_override("font_color", DesignChrome.INK)
			row.add_child(label)
			if _role() == "host" and not entry.get("withdrawn", false):
				var withdraw := _button("取り下げる")
				var rid: String = str(entry.get("id", ""))
				withdraw.pressed.connect(func():
					_service("project_release_withdraw", {"slug": slug, "id": rid}, func(_r): _rebuild()))
				row.add_child(withdraw)
			elif entry.get("withdrawn", false):
				row.add_child(_note("取り下げ済み"))
			body.add_child(row)
		status.text = "Releases · private meta only · not on asset-server"
	)

func _fill_members() -> void:
	var slug: String = _slug()
	if slug.is_empty():
		_unimplemented("Project を開くとメンバーを表示します。")
		return
	body.add_child(_note("権限は Host / 編集 / 閲覧 の三段階です。Host はワークスペースを立てた人（1人）。"))
	_service("project_members", {"slug": slug}, func(result):
		if not visible or tool != "members": return
		if not result.get("ok", false):
			body.add_child(_note(str(result.get("message", "未実装"))))
			status.text = "Members · unavailable"
			return
		for entry in result.get("members", []):
			var row := Label.new()
			row.text = "%s · %s" % [str(entry.get("name", entry.get("user_id", ""))), str(entry.get("role", ""))]
			row.add_theme_color_override("font_color", DesignChrome.INK)
			body.add_child(row)
		if _role() == "host":
			var invite := LineEdit.new()
			invite.placeholder_text = "招待する user id"
			DesignChrome.style_line_edit(invite)
			body.add_child(invite)
			var add_btn := _button("＋ 招待する（編集）", true)
			add_btn.pressed.connect(func():
				var uid: String = invite.text.strip_edges()
				if uid.is_empty(): return
				_service("project_member_upsert", {"slug": slug, "user_id": uid, "role": "edit", "name": uid}, func(_r): _rebuild()))
			body.add_child(add_btn)
		status.text = "Members · host is fixed creator"
	)

func _fill_debug() -> void:
	body.add_child(_note("未実装"))
	body.add_child(_note("クエリ可視化とマッチ強調は KokoState / Systems の後で埋めます。"))
	var selected: String = str(app.selected_id)
	body.add_child(_note("選択中: %s" % (selected if not selected.is_empty() else "—"), DesignChrome.INK))
	status.text = "Debug · stub"

func _fill_branch() -> void:
	var slug: String = _slug()
	if slug.is_empty():
		_unimplemented("Project を開くとブランチを操作できます。")
		return
	if _role() != "host":
		body.add_child(_note("ブランチ操作は Host のみです。"))
		status.text = "Branch · host only"
		return
	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "新しいブランチ名"
	DesignChrome.style_line_edit(name_edit)
	body.add_child(name_edit)
	var create_btn := _button("＋ ブランチを作成", true)
	create_btn.pressed.connect(func():
		_service("project_branch_create", {"slug": slug, "name": name_edit.text.strip_edges()}, func(result):
			status.text = str(result.get("message", "作成しました" if result.get("ok", false) else "失敗"))
			_rebuild()
		))
	body.add_child(create_btn)
	var merge_btn := _button("main にマージ")
	merge_btn.pressed.connect(func():
		_service("project_branch_merge_main", {"slug": slug}, func(result):
			status.text = str(result.get("message", "マージしました" if result.get("ok", false) else "失敗"))
			_rebuild()
		))
	body.add_child(merge_btn)
	_service("project_history", {"slug": slug}, func(result):
		if result.get("ok", false):
			body.add_child(_note("現在: %s" % str(result.get("branch", "main")), DesignChrome.INK))
		status.text = "Branch · fast-forward merge only"
	)
