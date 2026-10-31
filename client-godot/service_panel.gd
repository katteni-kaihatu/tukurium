extends CanvasLayer
## HN home, saved items and workshop. The Engine keeps session credentials.
const Art = preload("res://service_art.gd")
const DesktopWindow = preload("res://desktop_window.gd")
const BRAND_ART = preload("res://brand_art.gd")
const PAPER = Color("fffdf9")
const GROUND = Color("eae5db")
const INK = Color("26262e")
const MUTED = Color("6b6872")
const LINE = Color("dcd5c8")
const BLUE = Color("2f5fc4")
const PALE = Color("eef3fc")
var app
var shade: ColorRect
var shell: PanelContainer
var floating_window
var windows := {}
var status_labels := {}
var detail_boxes := {}
var status: Label
var identity: Label
var name_input: LineEdit
var session_name: LineEdit
var sessions: VBoxContainer
var library: GridContainer
var workshop: GridContainer
var projects: VBoxContainer
var current_user: Dictionary = {}
var current_session: Dictionary = {}
var enabled := false
var auto_login := false
var open_button: Button
var library_offset := 0
var workshop_offset := 0
var projects_offset := 0
var load_world := ""
var world_choice: Label
var library_query: LineEdit
var workshop_query: LineEdit
var projects_query: LineEdit
var project_slug: LineEdit
var project_name: LineEdit
var project_description: TextEdit
var mine_only: CheckBox
var page := "sessions"
var heading: Label
var version_label: Label
var subtitle: Label
var selected := {}
var selection_kind := ""
var library_total := 0
var workshop_total := 0
var projects_total := 0
var library_page: Label
var workshop_page: Label
var projects_page: Label
var save_button: Button
var login_button: Button
var back_button: Button
var library_generation := 0
var workshop_generation := 0
var projects_generation := 0
var detail_generations := {"library":0,"workshop":0,"projects":0}
var body_font: SystemFont
var title_font: SystemFont
var publish_dialog: ConfirmationDialog
var publish_title: LineEdit
var publish_description: TextEdit
var publish_error: Label
var publishing_version := ""

func box(color: Color, radius: int = 12, border: Color = Color.TRANSPARENT, padding: int = 16) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color=color
	style.set_corner_radius_all(radius)
	style.border_color=border
	style.set_border_width_all(1 if border.a>0 else 0)
	style.content_margin_left=padding
	style.content_margin_right=padding
	style.content_margin_top=padding
	style.content_margin_bottom=padding
	return style

func text(value: String, size: int = 14, color: Color = INK, strong: bool = false) -> Label:
	var label := Label.new()
	label.text=value
	label.add_theme_font_override("font",title_font if strong else body_font)
	label.add_theme_font_size_override("font_size",size)
	label.add_theme_color_override("font_color",color)
	return label

func paragraph(value: String, size: int = 14, color: Color = MUTED) -> Label:
	var label := text(value,size,color)
	label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	return label

func row(parent: Node, gap: int = 10) -> HBoxContainer:
	var node := HBoxContainer.new()
	node.add_theme_constant_override("separation",gap)
	parent.add_child(node)
	return node

func column(parent: Node, gap: int = 10) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation",gap)
	parent.add_child(node)
	return node

func button(parent: Node, value: String, callback: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.text=value
	b.custom_minimum_size.y=38
	b.mouse_default_cursor_shape=Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal",box(BLUE if primary else PAPER,9,BLUE if primary else LINE,12))
	b.add_theme_stylebox_override("hover",box(Color("274fa5") if primary else PALE,9,BLUE,12))
	b.add_theme_stylebox_override("pressed",box(Color("23478f") if primary else Color("e1e9f8"),9,BLUE,12))
	b.add_theme_stylebox_override("disabled",box(Color("f2eee7"),9,LINE,12))
	b.add_theme_color_override("font_color",Color.WHITE if primary else INK)
	b.add_theme_color_override("font_hover_color",Color.WHITE if primary else BLUE)
	b.add_theme_color_override("font_pressed_color",Color.WHITE if primary else BLUE)
	b.add_theme_color_override("font_disabled_color",Color("928c84"))
	b.pressed.connect(callback)
	parent.add_child(b)
	return b

func field(parent: Node, placeholder: String) -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text=placeholder
	input.custom_minimum_size.y=40
	input.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	parent.add_child(input)
	return input

func surface(parent: Node, color: Color = PAPER, padding: int = 16) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",box(color,14,Color.TRANSPARENT,padding))
	parent.add_child(panel)
	return panel

func rule(parent: Node) -> void:
	var separator := HSeparator.new()
	separator.add_theme_stylebox_override("separator",box(LINE,0,Color.TRANSPARENT,0))
	separator.custom_minimum_size.y=1
	parent.add_child(separator)

func setup(scene) -> void:
	app=scene
	layer=20
	body_font=SystemFont.new()
	body_font.font_names=PackedStringArray(["Yu Gothic UI","Meiryo","Malgun Gothic","Segoe UI"])
	title_font=SystemFont.new()
	title_font.font_names=PackedStringArray(["Yu Gothic","Meiryo","Malgun Gothic","Segoe UI"])
	title_font.font_weight=700
	open_button=button(self,"ホーム / ライブラリ",show_panel)
	open_button.position=Vector2(280,112)
	open_button.visible=false
	shade=ColorRect.new()
	shade.color=Color.TRANSPARENT
	shade.mouse_filter=Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.visible=false
	add_child(shade)
	var theme := Theme.new()
	theme.default_font=body_font
	theme.default_font_size=14
	for type in ["Label","LineEdit","TextEdit","CheckBox","Button"]:
		theme.set_color("font_color",type,INK)
		theme.set_color("font_hover_color",type,BLUE)
		theme.set_color("font_focus_color",type,BLUE)
		theme.set_color("font_pressed_color",type,INK)
		theme.set_color("font_disabled_color",type,MUTED)
	theme.set_color("font_uneditable_color","LineEdit",MUTED)
	theme.set_stylebox("normal","Button",box(PAPER,9,LINE,12))
	theme.set_stylebox("hover","Button",box(PALE,9,BLUE,12))
	theme.set_stylebox("pressed","Button",box(PALE,9,BLUE,12))
	theme.set_stylebox("disabled","Button",box(GROUND,9,LINE,12))
	theme.set_stylebox("normal","LineEdit",box(PAPER,10,LINE,10))
	theme.set_stylebox("focus","LineEdit",box(PAPER,10,BLUE,10))
	theme.set_color("font_placeholder_color","LineEdit",MUTED)
	theme.set_stylebox("normal","TextEdit",box(PAPER,10,LINE,10))
	theme.set_stylebox("focus","TextEdit",box(PAPER,10,BLUE,10))
	theme.set_stylebox("focus","Button",box(Color(0,0,0,0),9,BLUE,2))
	theme.set_stylebox("panel","AcceptDialog",box(PAPER,16,LINE,20))
	theme.set_color("title_color","Window",INK)
	theme.set_stylebox("embedded_border","Window",box(GROUND,14,LINE,12))
	var screen: Vector2=app.get_viewport().get_visible_rect().size
	var sizes := {"sessions":Vector2(790,585),"library":Vector2(1010,600),"workshop":Vector2(1010,600),"projects":Vector2(1010,600)}
	var positions := {"sessions":Vector2(104,88),"library":Vector2(145,96),"workshop":Vector2(185,106),"projects":Vector2(165,100)}
	var titles := {"sessions":"セッション","library":"インベントリ","workshop":"ワークショップ","projects":"Projects"}
	var descriptions := {"sessions":"一緒に作る場所を選ぶ。","library":"保存した作品を配置・共有する。","workshop":"公開された作品を探す。","projects":"ローカルのリポジトリ相当。この端末の Engine データにだけ保存します。"}
	for key in ["sessions","library","workshop","projects"]:
		var frame=DesktopWindow.new()
		shade.add_child(frame)
		frame.size=Vector2(minf(sizes[key].x,screen.x-40),minf(sizes[key].y,screen.y-170))
		frame.position=Vector2(minf(positions[key].x,screen.x-frame.size.x-20),positions[key].y)
		frame.minimum_window_size=Vector2(620 if key=="sessions" else 760,430)
		frame.panel.add_theme_stylebox_override("panel",box(GROUND,20,Color.TRANSPARENT,16))
		frame.panel.theme=theme
		frame.hide()
		windows[key]=frame
		frame.focused.connect(func(): activate_page(key))
		var main := column(frame.panel,14)
		main.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var top := row(main)
		frame.use_titlebar(top)
		if key=="sessions":
			var logo := BRAND_ART.picture(BRAND_ART.logo(), Vector2(136, 100))
			logo.name="BrandLogo"
			top.add_child(logo)
		var title_group := column(top,3)
		title_group.mouse_filter=Control.MOUSE_FILTER_IGNORE
		title_group.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		var title := text(titles[key],27,INK,true)
		title_group.add_child(title)
		var description := paragraph(descriptions[key],13)
		title_group.add_child(description)
		if key=="sessions":
			heading=title
			subtitle=description
			version_label=text(app.app_version,12,MUTED)
			version_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			version_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
			version_label.name="AppVersion"
			AppLanguage.format_text(version_label,"このアプリの配布バージョン",[],"tooltip_text")
			top.add_child(version_label)
		var close_button := button(top,"閉じる",func(): close_page(key))
		if key=="sessions":
			back_button=close_button
			var account := surface(main,PAPER,12)
			var account_layout := row(account,12)
			var account_body := column(account_layout,7)
			account_body.size_flags_horizontal=Control.SIZE_EXPAND_FILL
			identity=paragraph("HNを入力してはじめる",13)
			account_body.add_child(identity)
			var account_row := row(account_body)
			name_input=field(account_row,"HN")
			name_input.max_length=40
			login_button=button(account_row,"Start",login,true)
			name_input.text_submitted.connect(func(_value): login())
			button(account_row,"ユーザーコードをコピー",func():
				if not current_user.is_empty():
					DisplayServer.clipboard_set(str(current_user.id))
					status_labels.sessions.text="ユーザーコードをコピーしました。"
			).tooltip_text="ワークショップを使わず直接渡すときに使います。"
			var mascot := BRAND_ART.picture(BRAND_ART.mascot(), Vector2(90, 82))
			mascot.name="BrandMascot"
			account_layout.add_child(mascot)
		var workspace := row(main,16)
		workspace.size_flags_vertical=Control.SIZE_EXPAND_FILL
		var pane := column(workspace,12)
		pane.size_flags_horizontal=Control.SIZE_EXPAND_FILL
		pane.size_flags_vertical=Control.SIZE_EXPAND_FILL
		if key=="sessions": build_sessions(pane)
		elif key=="library":
			build_library(pane)
			empty_state(library,"まだ作品を表示できません","セッション画面でHNを入力すると、保存した作品を開けます。")
		elif key=="workshop":
			build_workshop(pane)
			empty_state(workshop,"まだ作品を表示できません","セッション画面でHNを入力すると、公開作品を探せます。")
		else:
			build_projects(pane)
			empty_state(projects,"まだ Project がありません","slug と表示名を入れて作成してください。保存はこの端末のみです。")
		if key!="sessions":
			var panel := surface(workspace)
			panel.custom_minimum_size.x=292
			var detail_scroll := ScrollContainer.new()
			detail_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
			panel.add_child(detail_scroll)
			var details := column(detail_scroll,12)
			details.size_flags_horizontal=Control.SIZE_EXPAND_FILL
			details.custom_minimum_size.x=252
			detail_boxes[key]=details
		var feedback := paragraph("HNを入力してStartを押してください。" if key=="sessions" else ("ローカルのみ · asset-server には載せません。" if key=="projects" else ""),12)
		main.add_child(feedback)
		status_labels[key]=feedback
		pane.resized.connect(update_columns)
	floating_window=windows.sessions
	shell=floating_window.panel
	status=status_labels.sessions
	show_detail_empty("library")
	show_detail_empty("workshop")
	show_detail_empty("projects")

func build_sessions(parent: VBoxContainer) -> void:
	var panel := surface(parent)
	var form := column(panel)
	form.add_child(text("新しいセッション",17,INK,true))
	var controls := row(form)
	session_name=field(controls,"セッション名")
	session_name.max_length=80
	button(controls,"作成",create_session,true)
	var choices := row(form)
	button(choices,"保存ワールドから…",choose_world)
	button(choices,"新しいワールド",func(): load_world=""; world_choice.text="新しいワールドで開始")
	world_choice=paragraph("新しいワールドで開始",12)
	form.add_child(world_choice)
	var heading_row := row(parent)
	var title := text("参加できるセッション",16,INK,true)
	title.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	heading_row.add_child(title)
	button(heading_row,"更新",refresh_sessions)
	button(heading_row,"退出",func(): call_service("leave_session",{},func(_v): refresh_sessions()))
	sessions=scrolling_column(parent)

func build_library(parent: VBoxContainer) -> void:
	var tools := row(parent)
	save_button=button(tools,"選択中のアイテムを保存",save_selected,true)
	button(tools,"更新",refresh_library)
	library_query=field(parent,"ライブラリを検索")
	library_query.text_submitted.connect(func(_value): library_offset=0; refresh_library())
	library=scrolling_grid(parent)
	var pager := row(parent)
	button(pager,"前へ",func(): library_offset=maxi(0,library_offset-10); refresh_library())
	library_page=text("0 件",12,MUTED)
	library_page.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	library_page.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	pager.add_child(library_page)
	button(pager,"次へ",func():
		if library_offset+10<library_total: library_offset+=10; refresh_library()
	)

func build_workshop(parent: VBoxContainer) -> void:
	var tools := row(parent)
	workshop_query=field(tools,"作品名・作者・説明を検索")
	workshop_query.text_submitted.connect(func(_value): workshop_offset=0; refresh_workshop())
	button(tools,"検索",func(): workshop_offset=0; refresh_workshop())
	button(tools,"更新",refresh_workshop)
	mine_only=CheckBox.new()
	mine_only.text="自分の公開作品"
	mine_only.toggled.connect(func(_on): workshop_offset=0; refresh_workshop())
	parent.add_child(mine_only)
	workshop=scrolling_grid(parent)
	var pager := row(parent)
	button(pager,"前へ",func(): workshop_offset=maxi(0,workshop_offset-12); refresh_workshop())
	workshop_page=text("0 件",12,MUTED)
	workshop_page.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	workshop_page.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	pager.add_child(workshop_page)
	button(pager,"次へ",func():
		if workshop_offset+12<workshop_total: workshop_offset+=12; refresh_workshop()
	)

func build_projects(parent: VBoxContainer) -> void:
	var create := surface(parent,PAPER,12)
	var form := column(create,8)
	form.add_child(text("新しい Project",17,INK,true))
	form.add_child(paragraph("slug は小文字・数字・ハイフン。ワールド快照はこの端末の data_root に保存されます。",12))
	var slug_row := row(form)
	project_slug=field(slug_row,"slug")
	project_slug.max_length=40
	project_name=field(slug_row,"表示名")
	project_name.max_length=80
	project_description=TextEdit.new()
	project_description.custom_minimum_size=Vector2(0,72)
	project_description.placeholder_text="説明（任意）"
	project_description.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	form.add_child(project_description)
	button(form,"作成",create_project,true)
	var tools := row(parent)
	projects_query=field(tools,"Projects を検索")
	projects_query.text_submitted.connect(func(_value): projects_offset=0; refresh_projects())
	button(tools,"検索",func(): projects_offset=0; refresh_projects())
	button(tools,"更新",refresh_projects)
	projects=scrolling_column(parent)
	var pager := row(parent)
	button(pager,"前へ",func(): projects_offset=maxi(0,projects_offset-10); refresh_projects())
	projects_page=text("0 件",12,MUTED)
	projects_page.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	projects_page.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	pager.add_child(projects_page)
	button(pager,"次へ",func():
		if projects_offset+10<projects_total: projects_offset+=10; refresh_projects()
	)

func scrolling_column(parent: Node) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	var list := column(scroll,10)
	list.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	return list

func scrolling_grid(parent: Node) -> GridContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns=2
	grid.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation",12)
	grid.add_theme_constant_override("v_separation",12)
	scroll.add_child(grid)
	return grid

func update_columns() -> void:
	for grid in [library,workshop]:
		if is_instance_valid(grid): grid.columns=clampi(int(grid.get_parent().size.x/195.0),1,3)

func activate_page(value: String) -> void:
	page=value
	floating_window=windows[value]
	shell=floating_window.panel
	status=status_labels[value]

func switch_page(value: String, refresh_data: bool = true) -> void:
	if not windows.has(value): return
	activate_page(value)
	app.release_cursor()
	shade.show()
	floating_window.show()
	floating_window.move_to_front()
	if value=="library":
		save_button.disabled=app.current.is_empty() or current_session.is_empty()
		save_button.tooltip_text="ワールドでアイテムを選択してから保存します。" if save_button.disabled else "見た目・設定・ロジックを保存します。"
	update_columns.call_deferred()
	if refresh_data and (value=="projects" or not current_user.is_empty()): refresh()

func close_page(value: String) -> void:
	if windows.has(value): windows[value].hide()
	if not any_page_open():
		shade.hide()
		return
	for index in range(shade.get_child_count()-1,-1,-1):
		var frame=shade.get_child(index)
		if not frame.visible: continue
		for key in windows:
			if windows[key]==frame:
				activate_page(key)
				return

func any_page_open() -> bool:
	for frame in windows.values():
		if frame.visible: return true
	return false

func close_active_page() -> void:
	for index in range(shade.get_child_count()-1,-1,-1):
		var frame=shade.get_child(index)
		if not frame.visible: continue
		for key in windows:
			if windows[key]==frame:
				close_page(key)
				return

func close_all() -> void:
	for frame in windows.values(): frame.hide()
	shade.hide()

func login() -> void:
	if not current_session.is_empty(): status_labels.sessions.text="HNを切り替えるには、セッションから退出してください。"; return
	if name_input.text.strip_edges().is_empty(): status_labels.sessions.text="HNを入力してください。"; name_input.grab_focus(); return
	auto_login=true
	call_service("login",{"name":name_input.text},func(_v):
		selected={}
		for kind in detail_generations:
			detail_generations[kind]+=1
			show_detail_empty(kind)
		refresh()
	)

func receive_state(body: Dictionary) -> void:
	enabled=body.get("enabled",false)
	open_button.visible=enabled
	if not enabled: return
	var previous_user_id: String=str(current_user.get("id",""))
	current_user=body.user if body.get("user") is Dictionary else {}
	current_session=body.session if body.get("session") is Dictionary else {}
	if previous_user_id!=str(current_user.get("id","")):
		library_generation+=1
		workshop_generation+=1
		for kind in detail_generations:
			detail_generations[kind]+=1
			show_detail_empty(kind)
		clear_list(library)
		clear_list(workshop)
		library_total=0
		workshop_total=0
		library_page.text="0 件"
		workshop_page.text="0 件"
		selected={}
		if current_user.is_empty():
			empty_state(library,"まだ作品を表示できません","セッション画面でHNを入力すると、保存した作品を開けます。")
			empty_state(workshop,"まだ作品を表示できません","セッション画面でHNを入力すると、公開作品を探せます。")
		else:
			if windows.library.visible: refresh_library()
			if windows.workshop.visible: refresh_workshop()
		if windows.projects.visible: refresh_projects()
	name_input.editable=current_session.is_empty()
	login_button.disabled=not current_session.is_empty()
	save_button.disabled=app.current.is_empty() or current_session.is_empty()
	if not current_user.is_empty():
		AppLanguage.format_text(identity,"HN  %s",[str(current_user.name)])
		name_input.text=current_user.name
		login_button.text="HNを切り替える"
		if not auto_login:
			auto_login=true
			call_service("login",{"name":current_user.name},func(_v): refresh())
	if current_session.is_empty():
		if not any_page_open(): show_panel()
	else: close_page("sessions")

func show_panel() -> void:
	switch_page("sessions")

func open_page(value: String) -> void:
	if not enabled: return
	if windows.has(value) and shade.visible and windows[value].visible:
		close_page(value)
		return
	switch_page(value)

func call_service(action: String, values: Dictionary, completed: Callable, failed: Callable = Callable(), feedback_page: String = "") -> void:
	var feedback: Label=status_labels.get(page if feedback_page.is_empty() else feedback_page,status)
	if not app.connected: feedback.text="接続を待っています…"; return
	feedback.text="読み込み中…" if action in ["library","workshop","workshop_detail","version","sessions","projects","project"] else "処理しています…"
	var body := values.duplicate(true)
	body.kind="service"
	body.action=action
	if action=="create_session" and not load_world.is_empty(): body.load_world=load_world
	app.requests.request(body,func(result):
		if not result.get("ok",false):
			feedback.text=result.get("message","処理できませんでした。もう一度お試しください。")
			if failed.is_valid(): failed.call(feedback.text)
			return
		feedback.text=""
		completed.call(result.get("data",{}))
	,["request_id"],"request_id",120000,"service_result")

func refresh() -> void:
	if page=="sessions": refresh_sessions()
	elif page=="library": refresh_library()
	elif page=="projects": refresh_projects()
	else: refresh_workshop()

func create_project() -> void:
	var slug: String=project_slug.text.strip_edges().to_lower()
	if slug.is_empty():
		status_labels.projects.text="slug を入力してください。"
		project_slug.grab_focus()
		return
	call_service("create_project",{
		"slug":slug,
		"display_name":project_name.text.strip_edges(),
		"description":project_description.text.strip_edges(),
	},func(record):
		project_slug.text=""
		project_name.text=""
		project_description.text=""
		projects_offset=0
		refresh_projects()
		select_project(record)
		status_labels.projects.text="Project を作成しました（ローカル）。"
	,Callable(),"projects")

func refresh_projects() -> void:
	call_service("projects",{"offset":projects_offset,"query":projects_query.text if projects_query else ""},func(data):
		projects_generation+=1
		clear_list(projects)
		var entries: Array=data.get("entries",[]) if data is Dictionary else []
		projects_total=int(data.get("total",entries.size()) if data is Dictionary else entries.size())
		projects_page.text="%d 件" % projects_total
		if entries.is_empty():
			empty_state(projects,"まだ Project がありません","slug と表示名を入れて作成してください。保存はこの端末のみです。")
			return
		for record in entries:
			var card := surface(projects)
			var contents := row(card)
			var labels := column(contents,3)
			labels.size_flags_horizontal=Control.SIZE_EXPAND_FILL
			var title := text(str(record.get("display_name",record.get("slug",""))),17,INK,true)
			title.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			labels.add_child(title)
			var meta := text("%s · scripts %s · ローカル" % [str(record.get("slug","")), str(record.get("script_count",0))],12,MUTED)
			meta.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			labels.add_child(meta)
			button(contents,"詳細",func(): select_project(record))
	,Callable(),"projects")

func select_project(record: Dictionary) -> void:
	selected=record
	selection_kind="projects"
	detail_generations.projects+=1
	var generation: int=detail_generations.projects
	call_service("project",{"slug":str(record.get("slug",""))},func(data):
		if generation!=detail_generations.projects: return
		show_project_detail(data)
	,Callable(),"projects")

func show_project_detail(data: Dictionary) -> void:
	var box_node: VBoxContainer=detail_boxes.projects
	clear_list(box_node)
	box_node.add_child(text(str(data.get("display_name",data.get("slug",""))),20,INK,true))
	box_node.add_child(paragraph("slug  %s" % str(data.get("slug","")),13,MUTED))
	box_node.add_child(paragraph(str(data.get("description","")) if not str(data.get("description","")).is_empty() else "説明なし",13))
	box_node.add_child(paragraph("Resources（Script）  %s" % str(data.get("script_count",0)),13,MUTED))
	box_node.add_child(paragraph("この端末の Engine data_root にだけ保存されます。asset-server には載せません。",12,MUTED))
	button(box_node,"ワークスペースで開く",func(): open_project_workspace(str(data.get("slug",""))),true)
	button(box_node,"更新",func(): select_project(data))

func open_project_workspace(slug: String) -> void:
	if slug.is_empty(): return
	call_service("open_project_workspace",{"slug":slug},func(_v):
		close_all()
		status_labels.projects.text="ワークスペースを開きました。"
	,Callable(),"projects")

func create_session() -> void:
	if session_name.text.strip_edges().is_empty(): status_labels.sessions.text="セッション名を入力してください。"; session_name.grab_focus(); return
	call_service("create_session",{"name":session_name.text},func(_v): pass)

func refresh_sessions() -> void:
	if current_user.is_empty(): return
	call_service("sessions",{},func(rows):
		clear_list(sessions)
		for record in rows:
			var card := surface(sessions)
			var contents := row(card)
			var labels := column(contents,3)
			labels.size_flags_horizontal=Control.SIZE_EXPAND_FILL
			var session_title := text(record.name,17,INK,true)
			session_title.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
			labels.add_child(session_title)
			var host_label := text("",12,MUTED)
			AppLanguage.format_text(host_label,"ホスト  %s",[str(record.owner_name)])
			labels.add_child(host_label)
			var here: bool=current_session.get("id","")==record.id
			button(contents,"ワールドへ" if here else "参加",func():
				if here: close_page("sessions")
				elif not current_session.is_empty(): status_labels.sessions.text="今のセッションから退出してから参加してください。"
				else: call_service("join_session",{"session_id":record.id},func(_v): pass)
			,true)
		if rows.is_empty(): empty_state(sessions,"まだセッションがありません","上のフォームから、新しいセッションを作成できます。")
	,Callable(),"sessions")

func clear_list(parent: Node) -> void:
	for child in parent.get_children(): parent.remove_child(child); child.queue_free()

func empty_state(parent: Node, title: String, hint: String) -> void:
	var panel := surface(parent)
	panel.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	var content := column(panel,8)
	content.add_child(paragraph(title,16,INK))
	content.add_child(paragraph(hint,13))

func refresh_library() -> void:
	if current_user.is_empty(): return
	library_generation+=1
	var generation := library_generation
	call_service("library",{"offset":library_offset,"query":library_query.text},func(data):
		if generation!=library_generation: return
		clear_list(library)
		library_total=int(data.get("total",0))
		set_page_label(library_page,library_offset,10,library_total)
		for record in data.get("entries",[]): item_card(library,record,"library")
		if data.get("entries",[]).is_empty(): empty_state(library,"保存した作品がありません","ワールドのアイテムを保存するか、ワークショップから取得してください。")
		update_columns.call_deferred()
	,Callable(),"library")

func refresh_workshop() -> void:
	if current_user.is_empty(): return
	workshop_generation+=1
	var generation := workshop_generation
	call_service("workshop",{"offset":workshop_offset,"query":workshop_query.text,"mine":mine_only.button_pressed},func(data):
		if generation!=workshop_generation: return
		clear_list(workshop)
		workshop_total=int(data.get("total",0))
		set_page_label(workshop_page,workshop_offset,12,workshop_total)
		for record in data.get("entries",[]): item_card(workshop,record,"workshop")
		if data.get("entries",[]).is_empty(): empty_state(workshop,"作品が見つかりません","マイライブラリから作品を公開できます。検索中なら、検索語を変えてください。")
		update_columns.call_deferred()
	,Callable(),"workshop")

func page_label(offset: int, count: int, total: int) -> String:
	return tr("0 件") if total==0 else tr("%d–%d / %d 件") % [offset+1,mini(offset+count,total),total]

func set_page_label(target: Label, offset: int, count: int, total: int) -> void:
	if total==0: target.text="0 件"
	else: AppLanguage.format_text(target,"%d–%d / %d 件",[offset+1,mini(offset+count,total),total])

func preview_node(parent: Node, data, kind: String, height: int) -> void:
	var area := PanelContainer.new()
	area.custom_minimum_size.y=height
	area.add_theme_stylebox_override("panel",box(Color("eaeef5"),10,Color.TRANSPARENT,0))
	area.clip_contents=true
	parent.add_child(area)
	if data is String and data.begins_with("data:image/png;base64,"):
		var image := Image.new()
		if image.load_png_from_buffer(Marshalls.base64_to_raw(data.get_slice(",",1)))==OK:
			var picture := TextureRect.new()
			picture.texture=ImageTexture.create_from_image(image)
			picture.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
			picture.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_COVERED
			area.add_child(picture)
			return
	var art := Art.new()
	art.kind=kind
	area.add_child(art)

func item_card(parent: GridContainer, record: Dictionary, kind: String) -> void:
	var card := surface(parent,PAPER,10)
	card.custom_minimum_size.x=174
	card.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	var contents := column(card,7)
	preview_node(contents,record.get("thumbnail"),str(record.get("kind","cube")),110)
	var title := text(str(record.get("title",record.get("name",tr("Untitled")))),15,INK,true)
	title.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	title.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	title.tooltip_text=title.text
	contents.add_child(title)
	var by := text("",12,MUTED)
	AppLanguage.format_text(by,"by %s",[str(record.get("publisher_name",record.get("creator_name","")))])
	by.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS
	contents.add_child(by)
	var note := ""
	if kind=="workshop": note="取得済み" if record.get("in_library",false) else "公開中"
	else: note="公開中" if record.get("publication")!=null else "保存済み"
	contents.add_child(text(note,11,BLUE))
	button(contents,"詳細を見る",func(): select_item(record,kind))

func show_detail_empty(kind: String = "") -> void:
	if kind.is_empty(): kind=page
	if not detail_boxes.has(kind): return
	var target_box: VBoxContainer=detail_boxes[kind]
	clear_list(target_box)
	if kind=="projects":
		target_box.add_child(text("Project の詳細",18,INK,true))
		target_box.add_child(paragraph("一覧から選ぶと、説明と「ワークスペースで開く」が出ます。",13))
	else:
		target_box.add_child(text("作品の詳細",18,INK,true))
		target_box.add_child(paragraph("作品を選ぶと、内容を確認できます。",13))

func select_item(record: Dictionary, kind: String) -> void:
	switch_page(kind,false)
	selected=record
	selection_kind=kind
	detail_generations[kind]+=1
	var generation: int=detail_generations[kind]
	var target_box: VBoxContainer=detail_boxes[kind]
	clear_list(target_box)
	target_box.add_child(text("読み込み中…",14,MUTED))
	call_service("version" if kind=="library" else "workshop_detail",{"version_id":record.get("version_id",""),"publication_id":record.get("id","")},func(data):
		if generation==detail_generations[kind]: render_detail(data,record,kind)
	,func(message):
		if generation==detail_generations[kind]: clear_list(target_box); target_box.add_child(paragraph(message,13))
	,kind)

func render_detail(data: Dictionary, record: Dictionary, kind: String) -> void:
	var target_box: VBoxContainer=detail_boxes[kind]
	clear_list(target_box)
	preview_node(target_box,data.get("thumbnail"),str(data.get("kind",record.get("kind","cube"))),158)
	var title: String=str(record.get("name",data.get("title",data.get("name",tr("作品")))))
	var title_label := paragraph(title,21,INK)
	title_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	target_box.add_child(title_label)
	var creator: String=str(data.get("creator_name",record.get("creator_name","")))
	var creator_label := paragraph("",13)
	AppLanguage.format_text(creator_label,"作者  %s",[creator])
	target_box.add_child(creator_label)
	if kind=="workshop" and data.get("publisher_name",creator)!=creator:
		var publisher_label := paragraph("",12)
		AppLanguage.format_text(publisher_label,"公開者  %s",[str(data.publisher_name)])
		target_box.add_child(publisher_label)
	var type_name := kind_label(str(record.get("kind",data.get("kind","cube"))))
	var scripts := int(data.get("script_count",data.get("object",{}).get("scripts",[]).size()))
	var type_label := text("",12,MUTED)
	AppLanguage.format_text(type_label,type_name+"  ·  ロジック %d 件",[scripts])
	target_box.add_child(type_label)
	if kind=="workshop" and not str(data.get("description","")).is_empty():
		var description_label := paragraph(data.description,13,INK)
		description_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
		target_box.add_child(description_label)
	rule(target_box)
	if kind=="workshop":
		var in_library: bool=data.get("in_library",false)
		var action: String="ライブラリに追加済み" if in_library else "ライブラリに保存"
		var acquire_button := button(target_box,action,func():
			call_service("acquire_item",{"publication_id":data.id},func(result):
				status_labels.workshop.text="ライブラリに保存しました。"
				select_item(result.publication,"workshop")
				refresh_workshop()
			)
		,true)
		acquire_button.disabled=in_library
		if in_library:
			button(target_box,"マイライブラリを開く",func(): switch_page("library"))
		if data.get("can_manage",false): button(target_box,"公開を停止…",func(): confirm_unpublish(data))
	else:
		var saved_label := text("",11,MUTED)
		AppLanguage.format_text(saved_label,"保存  %s",[Time.get_datetime_string_from_unix_time(int(data.saved_at)).replace("T"," ")])
		target_box.add_child(saved_label)
		var place := button(target_box,"ワールドに配置",func():
			var p: Vector3=app.player_position+Vector3(0,1,-2)
			call_service("place_item",{"version_id":record.version_id,"position":[p.x,p.y,p.z]},func(_v): close_all())
		,true)
		place.disabled=current_session.is_empty()
		place.tooltip_text="セッションに参加すると配置できます。" if place.disabled else ""
		if data.get("publication") is Dictionary:
			button(target_box,"公開中の作品を見る",func(): switch_page("workshop"); select_item(data.publication,"workshop"))
		else:
			button(target_box,"ワークショップに公開…",func(): show_publish(record))
		button(target_box,"名前を変更…",func(): rename_entry(record))
		button(target_box,"ユーザーに直接渡す…",func(): share_entry(record))
		button(target_box,"ライブラリから外す…",func(): confirm_remove(record))

func kind_label(kind: String) -> String:
	return {"cube":"オブジェクト","model":"3Dモデル","image":"画像","video":"動画"}.get(kind,"アイテム")

func modal(title: String, ok: String, width: int = 470) -> ConfirmationDialog:
	var dialog := ConfirmationDialog.new()
	dialog.title=title
	dialog.dialog_text=""
	dialog.ok_button_text=ok
	dialog.cancel_button_text="キャンセル"
	dialog.theme=shell.theme
	dialog.min_size=Vector2i(width,0)
	dialog.unresizable=true
	app.add_child(dialog)
	dialog.canceled.connect(dialog.queue_free)
	return dialog

func show_publish(record: Dictionary) -> void:
	publish_dialog=modal("ワークショップに公開","公開する",490)
	publish_dialog.dialog_hide_on_ok=false
	publishing_version=record.version_id
	var dialog := publish_dialog
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size=Vector2(450,mini(300,int(app.get_viewport().get_visible_rect().size.y)-200))
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	publish_dialog.add_child(scroll)
	var form := column(scroll,12)
	form.custom_minimum_size.x=430
	form.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	form.add_child(paragraph("公開するのは、この保存版です。ワールドで後から編集しても、公開中の内容は変わりません。",13))
	form.add_child(text("作品名",13,INK,true))
	publish_title=field(form,"作品名")
	publish_title.text=record.name
	publish_title.max_length=80
	form.add_child(text("説明",13,INK,true))
	publish_description=TextEdit.new()
	publish_description.placeholder_text="どんな作品か、使い方などを紹介してください。"
	publish_description.custom_minimum_size=Vector2(430,110)
	publish_description.wrap_mode=TextEdit.LINE_WRAPPING_BOUNDARY
	form.add_child(publish_description)
	publish_error=paragraph("",12,Color("a8321f")); form.add_child(publish_error)
	publish_dialog.confirmed.connect(func():
		if publish_title.text.strip_edges().is_empty(): publish_error.text="作品名を入力してください。"; return
		if publish_description.text.length()>2000: publish_error.text="説明は2000文字以内にしてください。"; return
		publish_dialog.get_ok_button().disabled=true
		call_service("publish_item",{"version_id":publishing_version,"title":publish_title.text,"description":publish_description.text},func(data):
			if is_instance_valid(dialog): dialog.queue_free()
			switch_page("workshop",false)
			mine_only.button_pressed=true
			refresh_workshop()
			select_item(data,"workshop")
			status_labels.workshop.text="ワークショップに公開しました。"
		,func(message):
			if is_instance_valid(dialog): publish_error.text=message; dialog.get_ok_button().disabled=false
		)
	)
	publish_dialog.popup_centered(Vector2i(510,420))

func confirm_unpublish(record: Dictionary) -> void:
	var dialog := modal("公開を停止しますか？","公開を停止")
	dialog.dialog_text="ワークショップでの公開を停止します。保存済みのライブラリや配置物は残ります。"
	dialog.confirmed.connect(func(): call_service("unpublish_item",{"publication_id":record.id},func(_v): selected={}; show_detail_empty("workshop"); refresh_workshop(); status_labels.workshop.text="公開を停止しました。"); dialog.queue_free())
	dialog.popup_centered()

func confirm_remove(record: Dictionary) -> void:
	var dialog := modal("ライブラリから外しますか？","ライブラリから外す")
	dialog.dialog_text="この一覧から外します。ワールドに配置したものや公開中の作品は残ります。"
	dialog.confirmed.connect(func(): call_service("remove_entry",{"entry_id":record.id},func(_v): selected={}; show_detail_empty("library"); refresh_library()); dialog.queue_free())
	dialog.popup_centered()

func rename_entry(record: Dictionary) -> void:
	var dialog := modal("ライブラリの名前を変更","変更する")
	var form := column(dialog)
	var input := field(form,"名前")
	input.text=record.name
	input.max_length=80
	dialog.confirmed.connect(func(): call_service("rename_entry",{"entry_id":record.id,"name":input.text},func(_v): show_detail_empty("library"); refresh_library()); dialog.queue_free())
	dialog.popup_centered()

func share_entry(record: Dictionary) -> void:
	var dialog := modal("ユーザーに直接渡す","渡す")
	var form := column(dialog)
	var recipient := field(form,"相手のユーザーコード")
	dialog.confirmed.connect(func(): call_service("share_item",{"version_id":record.version_id,"user_id":recipient.text.strip_edges()},func(_v): status_labels.library.text="作品を渡しました。"); dialog.queue_free())
	dialog.popup_centered()

func save_selected() -> void:
	if app.current.is_empty(): status_labels.library.text="ワールドでアイテムを選択してください。"; return
	var object: Dictionary=app.current.duplicate(true)
	var values := {"target":app.address_of(object),"name":str(app.fields.name.value)}
	save_button.disabled=true
	var thumbnail: PackedByteArray=await capture_item(object)
	if not thumbnail.is_empty(): values.thumbnail="data:image/png;base64,"+Marshalls.raw_to_base64(thumbnail)
	call_service("save_item",values,func(_v): library_offset=0; refresh_library(); save_button.disabled=false; status_labels.library.text="アイテムを保存しました。",func(_message): save_button.disabled=false)

func capture_item(object: Dictionary) -> PackedByteArray:
	if DisplayServer.get_name()=="headless": return PackedByteArray()
	var id: String=object.address.instance_id
	if not app.render_nodes.has(id): return PackedByteArray()
	var viewport := SubViewport.new()
	viewport.size=Vector2i(240,150)
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	app.add_child(viewport)
	var clone: Node3D=app.render_nodes[id].duplicate()
	viewport.add_child(clone)
	clone.position=Vector3.ZERO
	var bounds := mesh_bounds(clone)
	var center := bounds.get_center()
	var distance := maxf(bounds.size.length()*1.9,1.0)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.fov=32
	camera.far=maxf(1000,distance*4)
	camera.position=center+Vector3(1.1,0.7,1.5).normalized()*distance
	camera.look_at(center)
	var light := DirectionalLight3D.new()
	light.rotation_degrees=Vector3(-40,-30,0)
	viewport.add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color("eaeef5")
	environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color=Color.WHITE
	environment.environment.ambient_light_energy=0.8
	viewport.add_child(environment)
	await app.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image: Image=viewport.get_texture().get_image()
	viewport.queue_free()
	if image==null or image.is_empty(): return PackedByteArray()
	var bytes := image.save_png_to_buffer()
	if bytes.size()>48000: image.resize(160,100,Image.INTERPOLATE_LANCZOS); bytes=image.save_png_to_buffer()
	return bytes if bytes.size()<=48000 else PackedByteArray()

func mesh_bounds(node: Node3D) -> AABB:
	var result := AABB()
	if node is MeshInstance3D and node.mesh!=null and node.is_visible_in_tree(): result=node.global_transform*node.get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var child_bounds := mesh_bounds(child)
			if child_bounds.size.length()>0: result=child_bounds if result.size.length()==0 else result.merge(child_bounds)
	return result

func choose_world() -> void:
	var dialog := FileDialog.new()
	dialog.use_native_dialog=true
	dialog.access=FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters=PackedStringArray([tr("*.json ; Saved tukurium world")])
	app.add_child(dialog)
	dialog.file_selected.connect(func(path): load_world=path; AppLanguage.format_text(world_choice,"開始ワールド: %s",[path.get_file()]); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered_ratio(0.7)
