extends Node

const MAX_SOURCE := 100 * 1024 * 1024
const MAX_ASSET := 128 * 1024 * 1024
const CHUNK := 128 * 1024
var editor: Node
var jobs: Array[Dictionary] = []
var active: Dictionary = {}
var templates: Dictionary = {}
var downloads: Dictionary = {}
var requested: Dictionary = {}
var transfer_age := 0.0
var prepare_thread: Thread
var videos: Dictionary = {}
var avatar_textures: Dictionary = {}

func avatar_file() -> String:
	return ProjectSettings.globalize_path("res://../.run/avatars/custom.png")

func choose_avatar_texture() -> void:
	var dialog := FileDialog.new()
	dialog.title = tr("Choose an Oekaki avatar texture")
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = PackedStringArray([tr("*.png,*.jpg,*.jpeg,*.webp ; Avatar textures")])
	dialog.use_native_dialog = true
	dialog.file_selected.connect(func(path): queue_avatar_texture(path); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

func queue_avatar_texture(path: String) -> void:
	enqueue_job({"path":path,"purpose":"avatar"})

func reset_avatar_texture() -> void:
	if not editor.editable: return
	editor.queue_message({"kind":"profile","name":editor.nickname.text.strip_edges(),"avatar_texture":null})
	if FileAccess.file_exists(avatar_file()): DirAccess.remove_absolute(avatar_file())

func start_avatar_texture(path: String) -> void:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length()>MAX_SOURCE: fail("Avatar texture must be an image under 100 MiB."); return
	var img := Image.load_from_file(path)
	if img == null or img.is_empty(): fail("Could not read avatar texture."); return
	var size := maxi(img.get_width(),img.get_height())
	if size>2048: img.resize(maxi(1,img.get_width()*2048/size),maxi(1,img.get_height()*2048/size),Image.INTERPOLATE_LANCZOS)
	var data := img.save_png_to_buffer()
	while data.size()>1024*1024 and maxi(img.get_width(),img.get_height())>128:
		img.resize(maxi(1,int(img.get_width()*0.75)),maxi(1,int(img.get_height()*0.75)),Image.INTERPOLATE_LANCZOS)
		data = img.save_png_to_buffer()
	if data.size()>1024*1024: fail("Avatar texture could not fit the sharing limit."); return
	var id := hash_bytes(data)
	cache_avatar_texture(id,data)
	start_upload(id,data,"png")

func cache_avatar_texture(id: String, data: PackedByteArray) -> bool:
	var img := Image.new()
	if img.load_png_from_buffer(data)!=OK: return false
	avatar_textures[id] = ImageTexture.create_from_image(img)
	for avatar in editor.avatars.values():
		if avatar.texture_id==id: avatar.apply_texture(avatar_textures[id])
	return true

func attach_avatar(id: String, texture_id: String) -> void:
	var avatar: Node3D = editor.avatars[id]
	if avatar.texture_id!=texture_id:
		avatar.texture_id = texture_id
		if texture_id.is_empty(): avatar.apply_texture(null)
	if texture_id.is_empty(): return
	if avatar_textures.has(texture_id):
		if avatar.paint_material != null and avatar.paint_material.albedo_texture!=avatar_textures[texture_id]: avatar.apply_texture(avatar_textures[texture_id])
	elif editor.editable and not requested.has(texture_id):
		request_asset(texture_id)

func tool_path(name: String) -> String:
	return ProjectSettings.globalize_path("res://../.tools/ffmpeg/"+name+".exe")

func media_directory() -> String:
	var path := ProjectSettings.globalize_path("res://../.run/media")
	DirAccess.make_dir_recursive_absolute(path)
	return path

func configure(value: Node) -> void:
	editor = value
	editor.get_window().files_dropped.connect(drop_files)

func choose_files() -> void:
	var dialog := FileDialog.new()
	dialog.title = tr("Import images, models or videos")
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.filters = PackedStringArray([tr("*.png,*.jpg,*.jpeg,*.webp ; Images"), tr("*.glb,*.fbx ; 3D models (up to 100 MiB)"), tr("*.mp4,*.mov,*.webm,*.mkv,*.avi,*.ogv ; Videos (up to 100 MiB)")])
	dialog.use_native_dialog = true
	dialog.files_selected.connect(func(paths): drop_files(paths); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

## Prepare images / GLB / FBX for the Resources catalog without placing a Slot.
## on_done receives (ok: bool, payload: Dictionary, message: String).
## payload for images: {kind,data_url,width,height,bytes,ext,name}
## payload for models: {kind,asset_id,half_extents,bytes,ext,name}
func import_to_catalog(path: String, on_done: Callable) -> void:
	enqueue_job({"path":path,"purpose":"catalog","on_catalog":on_done,"point":Vector3.ZERO})

func choose_catalog_files(kinds: PackedStringArray, on_paths: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.title = tr("Import into Resources")
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.filters = kinds
	dialog.use_native_dialog = true
	dialog.files_selected.connect(func(paths): on_paths.call(paths); dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.7)

func place_visual(visual: Dictionary, name: String, half_height: float = 0.75) -> void:
	if not editor.editable: return
	var point: Vector3 = editor.player_target_position - editor.camera.global_basis.z * 3.0
	point.y = maxf(point.y, half_height + 0.02)
	var rotation := Quaternion.IDENTITY
	if visual.get("kind","") in ["image","video"]:
		rotation = Quaternion(Vector3.UP, editor.camera.rotation.y)
	editor.requests.request({"kind":"structure","command":{"action":"import_asset","name":name.substr(0,80),"position":[point.x,point.y,point.z],"rotation":[rotation.x,rotation.y,rotation.z,rotation.w],"visual":visual}}, func(body):
		if body.get("ok", false):
			var selected: Dictionary = body.get("selected", {})
			if not selected.is_empty(): editor.select_object(selected.instance_id)
			AppLanguage.format_text(editor.feedback,"Placed %s",[name])
		else:
			editor.feedback.text = str(body.get("message", "Could not place resource"))
	)

func drop_files(paths: PackedStringArray) -> void:
	if not editor.editable:
		editor.feedback.text = "Connect to the world before importing."
		return
	var mouse: Vector2 = editor.get_viewport().get_mouse_position()
	var origin: Vector3 = editor.camera.project_ray_origin(mouse)
	var direction: Vector3 = editor.camera.project_ray_normal(mouse)
	var point: Variant = Plane(Vector3.UP,0).intersects_ray(origin,direction)
	if point == null or origin.distance_to(point) > 12.0:
		point = editor.player_target_position - editor.camera.global_basis.z * 3.0
		point.y = 0.0
	var hit: Dictionary = editor.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(origin,origin+direction*12.0))
	if not hit.is_empty(): point = hit.position
	for i in range(paths.size()):
		enqueue_job({"path":paths[i],"point":point+editor.camera.global_basis.x*float(i)*2.2})
	if not jobs.is_empty(): AppLanguage.format_text(editor.feedback,"%d file(s) queued for import",[jobs.size()])

func _process(delta: float) -> void:
	expire_downloads()
	if prepare_thread != null:
		if not prepare_thread.is_alive():
			var result: Dictionary = prepare_thread.wait_to_finish()
			prepare_thread = null
			if not active.is_empty():
				if result.has("error"): fail(result.error)
				else: upload_model(result.data)
		return
	if active.has("video_pid"):
		if not OS.is_process_running(active.video_pid): finish_video_conversion()
		return
	if not active.is_empty():
		transfer_age += delta
		if transfer_age > 35.0: fail("Import timed out. Drop the file again to retry.")
	if active.is_empty() and not jobs.is_empty() and editor.editable and not editor.pending and editor.hand_grab.is_empty() and not editor.gizmo_preview_active:
		start_import(jobs.pop_front())

func fail(message: String, values: Array = []) -> void:
	printerr("Asset import: "+(message % values if not values.is_empty() else message))
	var done: Callable = Callable()
	if not active.is_empty():
		done = active.get("on_catalog", Callable())
		if active.has("video_pid") and OS.is_process_running(active.video_pid): OS.kill(active.video_pid)
		editor.asset_status.update(str(active.task),"error",0,0,message,"",values)
		active.clear()
		editor.pending = false
		editor.pending_action = ""
	var text := message % values if not values.is_empty() else message
	AppLanguage.format_text(editor.feedback,message,values)
	if done.is_valid(): done.call(false, {}, text)

func start_import(job: Dictionary) -> void:
	active = job
	active.placed = false
	active.upload_complete = true
	import_status("preparing")
	transfer_age = 0.0
	editor.pending = true
	editor.pending_action = "import_asset"
	if job.get("purpose","")=="avatar": start_avatar_texture(str(job.path)); return
	var catalog: bool = str(job.get("purpose", "")) == "catalog"
	var extension: String = str(job.path).get_extension().to_lower()
	if extension in ["png","jpg","jpeg","webp"]:
		var img := Image.load_from_file(job.path)
		if img == null or img.is_empty(): fail("Could not load image: %s",[str(job.path).get_file()]); return
		var size := maxi(img.get_width(),img.get_height())
		if size > 1024: img.resize(maxi(1,img.get_width()*1024/size),maxi(1,img.get_height()*1024/size),Image.INTERPOLATE_LANCZOS)
		var png := img.detect_alpha()
		var data := img.save_png_to_buffer() if png else img.save_jpg_to_buffer(0.85)
		while data.size() > 192*1024 and maxi(img.get_width(),img.get_height()) > 64:
			img.resize(maxi(1,int(img.get_width()*0.75)),maxi(1,int(img.get_height()*0.75)),Image.INTERPOLATE_LANCZOS)
			data = img.save_png_to_buffer() if png else img.save_jpg_to_buffer(0.85)
		if data.size() > 192*1024: fail("Image could not fit the import limit."); return
		var ratio := float(img.get_width()) / img.get_height()
		var half := Vector3(1.0,1.0/ratio,0.03) if ratio >= 1.0 else Vector3(ratio,1.0,0.03)
		var prefix := "data:image/png;base64," if png else "data:image/jpeg;base64,"
		var visual := {"kind":"image","data_url":prefix+Marshalls.raw_to_base64(data),"width":img.get_width(),"height":img.get_height()}
		if catalog:
			finish_catalog({"kind":"image","data_url":visual.data_url,"width":img.get_width(),"height":img.get_height(),"bytes":data,"ext":("png" if png else "jpg"),"name":str(job.path).get_file().get_basename(),"half_height":half.y})
		else:
			commit_import(visual,half.y)
	elif extension in ["glb","fbx"]:
		if catalog and extension == "fbx":
			# Catalog keeps a GLB on disk; convert first.
			pass
		var file := FileAccess.open(job.path,FileAccess.READ)
		if file == null: fail("Could not open model file."); return
		if file.get_length() > MAX_SOURCE: fail("Model import limit is 100 MiB per file."); return
		AppLanguage.format_text(editor.feedback,"Importing %s…",[extension.to_upper()])
		import_status("converting" if extension == "fbx" else "preparing")
		prepare_thread = Thread.new()
		prepare_thread.start(prepare_model.bind(str(job.path),extension))
	elif extension in ["mp4","mov","webm","mkv","avi","ogv"]:
		if catalog: fail("Video catalog entries are not supported yet."); return
		start_video_conversion(str(job.path))
	else: fail("Supported files: images, GLB, FBX and videos.")

func prepare_model(path: String, extension: String) -> Dictionary:
	var data := FileAccess.get_file_as_bytes(path)
	if extension == "fbx":
		var fbx := FBXDocument.new()
		var state := FBXState.new()
		if fbx.append_from_buffer(data,path.get_base_dir(),state) != OK: return {"error":"Could not read this FBX model."}
		var model := fbx.generate_scene(state)
		if model == null: return {"error":"FBX has no importable scene."}
		var gltf := GLTFDocument.new()
		var output_state := GLTFState.new()
		var error := gltf.append_from_scene(model,output_state)
		if error == OK: data = gltf.generate_buffer(output_state)
		model.free()
		if error != OK or data.is_empty(): return {"error":"Could not convert FBX for sharing."}
	if data.size()>MAX_ASSET: return {"error":"Converted model exceeds 128 MiB."}
	if not self_contained_glb(data): return {"error":"Use a model with embedded textures, or keep its textures beside the FBX."}
	return {"data":data}

func upload_model(data: PackedByteArray) -> void:
	var task: String = active.task
	import_status("preparing")
	await get_tree().process_frame
	if active.get("task","") != task: return
	var id := hash_bytes(data)
	if not templates.has(id) and not build_template(id,data): fail("No renderable mesh found in this model."); return
	var half: Array = templates[id].half
	if active.get("purpose","") == "catalog":
		active.catalog_payload = {"kind":"model","asset_id":id,"half_extents":half,"bytes":data,"ext":"glb","name":str(active.path).get_file().get_basename(),"half_height":float(half[1])}
		start_upload(id,data,"glb")
		return
	start_upload(id,data,"glb")
	commit_import({"kind":"model","asset_id":id,"half_extents":half},half[1])

func finish_catalog(payload: Dictionary) -> void:
	var done: Callable = active.get("on_catalog", Callable())
	import_status("ready")
	active.clear()
	editor.pending = false
	editor.pending_action = ""
	if done.is_valid():
		done.call(true, payload, "")
	else:
		editor.feedback.text = "Resource prepared."

func hash_bytes(data: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(data)
	return hash.finish().hex_encode()

func start_upload(id: String, data: PackedByteArray, format: String) -> void:
	active.asset_id = id
	active.data = data
	active.format = format
	active.upload_complete = false
	transfer_age = 0.0
	import_status("uploading_local",0,data.size())
	editor.feedback.text = "Sharing asset…"
	editor.queue_message({"kind":"asset_offer","asset_id":id,"size":data.size(),"format":format})

func probe_video(path: String) -> Dictionary:
	var output := []
	var result := OS.execute(tool_path("ffprobe"),PackedStringArray(["-v","error","-select_streams","v:0","-show_entries","stream=width,height,codec_name","-show_entries","format=duration","-of","json","-i",path]),output,true,false)
	if result != 0 or output.is_empty(): return {}
	var info: Variant = JSON.parse_string(output[0])
	if not info is Dictionary or info.get("streams",[]).is_empty(): return {}
	var stream: Dictionary = info.streams[0]
	stream.duration = float(info.get("format",{}).get("duration",0))
	return stream

func start_video_conversion(path: String) -> void:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null: fail("Could not open video file."); return
	if file.get_length()>MAX_SOURCE: fail("Video import limit is 100 MiB per file."); return
	if not FileAccess.file_exists(tool_path("ffmpeg")): fail("Video tools are missing. Run scripts/setup-media.ps1."); return
	var info := probe_video(path)
	if info.is_empty() or info.duration<=0: fail("No readable video track found."); return
	if path.get_extension().to_lower()=="ogv" and info.get("codec_name","")=="theora":
		finish_video(path,info)
		return
	var destination := media_directory().path_join("import-"+str(Time.get_ticks_usec())+".ogv")
	var bitrate := mini(2500,maxi(64,int(100.0*1024*1024*8*0.82/info.duration/1000)-128))
	var args := PackedStringArray(["-y","-nostdin","-v","error","-protocol_whitelist","file,pipe,crypto,data","-i",path,"-map","0:v:0","-map","0:a:0?","-vf","scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,fps=30","-c:v","libtheora","-b:v",str(bitrate)+"k","-c:a","libvorbis","-q:a","3",destination])
	var pid := OS.create_process(tool_path("ffmpeg"),args,false)
	if pid<0: fail("Could not start video conversion."); return
	active.video_pid = pid
	active.video_output = destination
	import_status("converting")
	editor.feedback.text = "Preparing video…"

func finish_video_conversion() -> void:
	var path: String = active.video_output
	active.erase("video_pid")
	if not FileAccess.file_exists(path): fail("Video conversion failed."); return
	var info := probe_video(path)
	if info.is_empty() or info.get("codec_name","")!="theora": fail("Video conversion failed."); return
	finish_video(path,info)

func finish_video(path: String, info: Dictionary) -> void:
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null or file.get_length()>MAX_ASSET: fail("Converted video exceeds 128 MiB."); return
	var data := file.get_buffer(file.get_length())
	var id := hash_bytes(data)
	active.video_info = info
	if not cache_video(id,data): fail("Could not write video cache."); return
	start_upload(id,data,"ogv")
	var ratio := float(info.width)/float(info.height)
	commit_import({"kind":"video","asset_id":id,"width":int(info.width),"height":int(info.height),"duration_seconds":float(info.duration)},1.0/ratio if ratio>=1.0 else 1.0)

func cache_video(id: String, data: PackedByteArray) -> bool:
	var path := media_directory().path_join(id+".ogv")
	if not FileAccess.file_exists(path):
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file == null: return false
		file.store_buffer(data)
	videos[id] = path
	return true

func self_contained_glb(data: PackedByteArray) -> bool:
	if data.size()<20 or data.decode_u32(0)!=0x46546c67 or data.decode_u32(4)!=2 or data.decode_u32(8)!=data.size(): return false
	var length := data.decode_u32(12)
	if length > data.size()-20 or data.decode_u32(16)!=0x4e4f534a: return false
	var document: Variant = JSON.parse_string(data.slice(20,20+length).get_string_from_utf8())
	if not document is Dictionary: return false
	for buffer in document.get("buffers",[]):
		if buffer.has("uri"): return false
	for img in document.get("images",[]):
		if img.has("uri") and not (str(img.uri).begins_with("data:image/png;base64,") or str(img.uri).begins_with("data:image/jpeg;base64,")): return false
	return true

func mesh_bounds(node: Node, parent: Transform3D, result: Dictionary) -> void:
	var frame := parent
	if node is Node3D: frame = parent * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var box: AABB = frame * node.get_aabb()
		result.box = result.box.merge(box) if result.has("box") else box
	for child in node.get_children(): mesh_bounds(child,frame,result)

func build_template(id: String, data: PackedByteArray) -> bool:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(data,"",state) != OK: return false
	var model := document.generate_scene(state)
	if not model is Node3D:
		if model != null: model.free()
		return false
	var result := {}
	mesh_bounds(model,Transform3D.IDENTITY,result)
	if not result.has("box"): model.free(); return false
	var box: AABB = result.box
	var size := maxf(box.size.x,maxf(box.size.y,box.size.z))
	if not is_finite(size) or size < 0.000001: model.free(); return false
	var factor := 2.0/size
	var wrapper := Node3D.new()
	wrapper.add_child(model)
	wrapper.scale = Vector3.ONE * factor
	wrapper.position = -box.get_center()*factor
	var half := box.size*factor*0.5
	half = half.max(Vector3.ONE*0.001)
	templates[id] = {"node":wrapper,"half":[half.x,half.y,half.z]}
	return true

func commit_import(visual: Dictionary, half_height: float) -> void:
	var point: Vector3 = active.point + Vector3.UP*(half_height+0.02)
	var rotation := Quaternion.IDENTITY
	if visual.kind in ["image","video"]: rotation = Quaternion(Vector3.UP,editor.camera.rotation.y)
	import_status("placing")
	editor.requests.request({"kind":"structure","command":{"action":"import_asset","name":str(active.path).get_file().get_basename().substr(0,80),"position":[point.x,point.y,point.z],"rotation":[rotation.x,rotation.y,rotation.z,rotation.w],"visual":visual}}, on_import_result.bind(str(active.task)))
	AppLanguage.format_text(editor.feedback,"Placing %s…",[str(active.path).get_file()])
	transfer_age = 0.0

func receive(body: Dictionary) -> void:
	var id: String = body.get("asset_id","")
	if body.kind == "asset_transfer":
		var phase: String = str(body.phase)
		if active.get("asset_id","") == id:
			transfer_age = 0.0
			import_status(phase,int(body.get("completed",0)),int(body.get("total",0)))
		elif requested.has(id) and int(requested[id]) >= 0 and not templates.has(id) and not videos.has(id) and not avatar_textures.has(id):
			requested[id] = Time.get_ticks_msec()
			editor.asset_status.update(id,phase,int(body.get("completed",0)),int(body.get("total",0)))
		return
	if body.kind == "asset_chunk_request" and active.get("asset_id","") == id:
		var offset := int(body.offset)
		var data: PackedByteArray = active.data
		if offset < 0 or offset >= data.size(): fail("Invalid asset upload offset."); return
		editor.queue_message({"kind":"asset_chunk","asset_id":id,"offset":offset,"data":Marshalls.raw_to_base64(data.slice(offset,mini(offset+CHUNK,data.size())))})
		transfer_age = 0.0
		import_status("uploading_local",offset,data.size())
		AppLanguage.format_text(editor.feedback,"Sharing asset… %d%%",[int(100.0*offset/data.size())])
	elif body.kind == "asset_ready" and active.get("asset_id","") == id:
		if active.format == "png":
			DirAccess.make_dir_recursive_absolute(avatar_file().get_base_dir())
			var file := FileAccess.open(avatar_file(),FileAccess.WRITE)
			if file != null: file.store_buffer(active.data)
			editor.queue_message({"kind":"profile","name":editor.nickname.text.strip_edges(),"avatar_texture":id})
			import_status("ready")
			active.clear()
			editor.pending = false
			editor.pending_action = ""
			editor.feedback.text = "Avatar texture shared."
		elif active.get("purpose","") == "catalog" and active.has("catalog_payload"):
			active.upload_complete = true
			finish_catalog(active.catalog_payload)
		else:
			active.upload_complete = true
			finish_import()

	elif body.kind == "asset_offer":
		if not requested.has(id) or int(requested[id]) < 0: return
		var size := int(body.size)
		if size < 20 or size > MAX_ASSET:
			download_failed(id,"Invalid asset size")
			return
		downloads[id] = {"size":size,"data":PackedByteArray(),"format":body.get("format","glb")}
		requested[id] = Time.get_ticks_msec()
		editor.asset_status.update(id,"downloading_local",0,size)
		editor.queue_message({"kind":"asset_chunk_request","asset_id":id,"offset":0})
	elif body.kind == "asset_chunk" and downloads.has(id):
		var download: Dictionary = downloads[id]
		var bytes := Marshalls.base64_to_raw(body.data)
		if download.get("finishing",false) or int(body.offset)!=download.data.size() or bytes.is_empty() or bytes.size()>CHUNK or download.data.size()+bytes.size()>download.size:
			download_failed(id,"Invalid or out-of-order asset data")
			return
		download.data.append_array(bytes)
		requested[id] = Time.get_ticks_msec()
		editor.asset_status.update(id,"downloading_local",download.data.size(),download.size)
		if download.data.size() == download.size:
			download.finishing = true
			finish_download(id,download)
		else: editor.queue_message({"kind":"asset_chunk_request","asset_id":id,"offset":download.data.size()})
	elif body.kind == "asset_error":
		if active.get("asset_id","") == id: fail(body.get("message","Asset transfer failed."))
		else: download_failed(id,body.get("message","Asset download failed."))

func finish_download(id: String, download: Dictionary) -> void:
	editor.asset_status.update(id,"verifying")
	await get_tree().process_frame
	if downloads.get(id) != download: return
	if hash_bytes(download.data) != id:
		download_failed(id,"Asset checksum mismatch")
		return
	editor.asset_status.update(id,{"ogv":"loading_video","png":"loading_texture"}.get(download.format,"loading_model"))
	await get_tree().process_frame
	if downloads.get(id) != download: return
	var success := true
	if download.format == "png": success = cache_avatar_texture(id,download.data)
	elif download.format == "ogv": success = cache_video(id,download.data)
	else: success = self_contained_glb(download.data) and build_template(id,download.data)
	if not success:
		download_failed(id,"Could not load or cache this asset")
		return
	downloads.erase(id)
	requested.erase(id)
	for object_id in editor.objects:
		if editor.objects[object_id].visual.get("asset_id","") == id:
			if download.format == "ogv": attach_video(object_id)
			elif download.format == "glb": attach_model(object_id)
	editor.asset_status.update(id,"ready",int(download.size),int(download.size))

func download_failed(id: String, message: String) -> void:
	downloads.erase(id)
	requested[id] = -1
	editor.asset_status.update(id,"error",0,0,message)

func expire_downloads() -> void:
	for id in requested.keys():
		if int(requested[id]) >= 0 and Time.get_ticks_msec()-int(requested[id]) > 35000:
			download_failed(id,"Transfer timed out. Retry when connected.")

func request_asset(id: String) -> void:
	requested[id] = Time.get_ticks_msec()
	editor.asset_status.update(id,"waiting")
	editor.queue_message({"kind":"asset_get","asset_id":id})

func retry_asset(id: String) -> void:
	if not editor.editable: return
	downloads.erase(id)
	request_asset(id)

func enqueue_job(job: Dictionary) -> void:
	job.task = "import:%s:%s" % [Time.get_ticks_usec(),jobs.size()]
	jobs.append(job)
	editor.asset_status.update(job.task,"queued",0,0,"",str(job.path).get_file())

func import_status(phase: String, completed: int = 0, total: int = 0) -> void:
	if not active.is_empty(): editor.asset_status.update(str(active.task),phase,completed,total,"",str(active.path).get_file())

func on_import_result(body: Dictionary, task: String) -> void:
	if active.get("task","") != task: return
	if not body.ok:
		fail(str(body.get("message","Import failed")))
		return
	active.placed = true
	active.selected = body.get("selected",{})
	finish_import()

func finish_import() -> void:
	if not active.get("placed",false) or not active.get("upload_complete",false): return
	import_status("ready")
	AppLanguage.format_text(editor.feedback,"Imported %s",[str(active.path).get_file()])
	var selected: Dictionary = active.get("selected",{})
	active.clear()
	editor.pending = false
	editor.pending_action = ""
	if not selected.is_empty(): editor.select_object(selected.instance_id)

func attach_model(object_id: String) -> void:
	var object: Dictionary = editor.objects[object_id]
	var id: String = object.visual.asset_id
	var parent: MeshInstance3D = editor.render_nodes[object_id]
	if parent.has_node("ImportedModel"): return
	if templates.has(id):
		var model: Node3D = templates[id].node.duplicate()
		model.name = "ImportedModel"
		parent.add_child(model)
		parent.mesh = null
		tint_model(model,parent.material_override.albedo_color)
	elif not requested.has(id):
		request_asset(id)

## The material list is collected once per attached model instance and
## cached on its root. Repeat calls with the same color do nothing, and a
## color change only rewrites the cached materials instead of walking the
## whole subtree again (Drive frames and snapshots call this every time).
func tint_model(node: Node, color: Color) -> void:
	if node.has_meta("tint_materials"):
		if node.get_meta("tint_color") == color: return
		for material in node.get_meta("tint_materials"):
			if is_instance_valid(material):
				material.albedo_color = material.get_meta("source_color",Color.WHITE)*color
		node.set_meta("tint_color",color)
		return
	var materials: Array = []
	_collect_tint_materials(node,color,materials)
	node.set_meta("tint_materials",materials)
	node.set_meta("tint_color",color)

func _collect_tint_materials(node: Node, color: Color, materials: Array) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for i in range(node.mesh.get_surface_count()):
			var material: Material = node.get_surface_override_material(i)
			if material == null:
				material = node.mesh.surface_get_material(i)
				material = material.duplicate() if material is StandardMaterial3D else StandardMaterial3D.new()
				node.set_surface_override_material(i,material)
				material.set_meta("source_color",material.albedo_color)
			if material is StandardMaterial3D:
				material.albedo_color = material.get_meta("source_color",Color.WHITE)*color
				if not materials.has(material): materials.append(material)
	for child in node.get_children(): _collect_tint_materials(child,color,materials)

## Evict cached assets nothing references anymore, mirroring the image
## texture eviction in apply_snapshot. In-flight transfers (downloads and
## the active import) are never evicted from under their completion path.
func evict_unused_assets() -> void:
	var used := {}
	for object in editor.objects.values():
		var visual: Dictionary = object.get("visual",{})
		if visual.get("kind") in ["model","video"]:
			var id: String = str(visual.get("asset_id",""))
			if not id.is_empty(): used[id] = true
	for avatar in editor.avatars.values():
		if not avatar.texture_id.is_empty(): used[avatar.texture_id] = true
	var active_id: String = str(active.get("asset_id",""))
	if not active_id.is_empty(): used[active_id] = true
	for id in templates.keys():
		if not used.has(id) and not downloads.has(id):
			templates[id].node.free()
			templates.erase(id)
	for id in videos.keys():
		if not used.has(id) and not downloads.has(id):
			var path: String = videos[id]
			videos.erase(id)
			if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	for id in avatar_textures.keys():
		if not used.has(id): avatar_textures.erase(id)
	for id in requested.keys():
		if int(requested[id]) < 0 and not used.has(id): requested.erase(id)

func attach_video(object_id: String) -> void:
	var object: Dictionary = editor.objects[object_id]
	var id: String = object.visual.asset_id
	var parent: MeshInstance3D = editor.render_nodes[object_id]
	if parent.has_node("VideoPlayer"): return
	if videos.has(id):
		var player := VideoStreamPlayer.new()
		player.name = "VideoPlayer"
		var stream := VideoStreamTheora.new()
		stream.file = videos[id]
		player.stream = stream
		player.loop = true
		player.volume_db = -12.0
		player.visible = false
		parent.add_child(player)
		player.play()
		player.paused = true
	elif not requested.has(id):
		request_asset(id)

func update_videos() -> void:
	for id in editor.objects:
		if editor.objects[id].visual.kind != "video": continue
		var node: MeshInstance3D = editor.render_nodes[id]
		if node.has_node("VideoPlayer"):
			var player: VideoStreamPlayer = node.get_node("VideoPlayer")
			if not editor.clock_ready or object_playback_missing(id):
				player.paused = true
				continue
			var object: Dictionary = editor.objects[id]
			var state: Dictionary = object.playback
			var duration := video_duration(object)
			var position := video_position(object,duration)
			var revision := ""
			for field in object.fields:
				if field.id == "playback": revision = field.revision
			var fresh: bool = player.get_meta("playback_revision", "") != revision
			var should_play: bool = state.playing and (state.looping or duration <= 0.0 or position < duration)
			player.loop = state.looping
			if not player.is_playing():
				if should_play or fresh: player.play(); fresh = true
			player.paused = not should_play
			var drift := absf(player.stream_position - position)
			if state.looping and duration > 0.0: drift = minf(drift,absf(duration-drift))
			if fresh or drift > (0.25 if should_play else 0.025):
				player.stream_position = position
			player.set_meta("playback_revision",revision)
			var texture := player.get_video_texture()
			if texture != null: node.material_override.albedo_texture = texture

func object_playback_missing(id: String) -> bool:
	return editor.objects[id].get("playback") == null

func video_duration(object: Dictionary) -> float:
	var node: MeshInstance3D = editor.render_nodes[object.address.instance_id]
	if node.has_node("VideoPlayer"):
		var length: float = node.get_node("VideoPlayer").get_stream_length()
		if length > 0.0: return length
	return float(object.visual.get("duration_seconds",0.0))

func video_position(object: Dictionary, duration: float) -> float:
	var state: Dictionary = object.playback
	var position: float = state.position_seconds
	if state.playing: position += maxf(0.0,editor.media_time()-float(state.anchor_seconds))
	if duration > 0.0:
		position = fposmod(position,duration) if state.looping else minf(position,duration)
	return position

func toggle_video() -> void:
	if not editor.current.is_empty() and editor.current.get("playback") != null:
		editor.send_playback("pause" if editor.current.playback.playing else "play")

func restart_video() -> void:
	editor.send_playback("restart")

func _exit_tree() -> void:
	if active.has("video_pid") and OS.is_process_running(active.video_pid): OS.kill(active.video_pid)
	if prepare_thread != null: prepare_thread.wait_to_finish()
	for template in templates.values(): template.node.free()

func disconnected() -> void:
	for id in requested.keys(): download_failed(id,"Disconnected. Reconnect to resume.")
	downloads.clear()
	requested.clear()
	if not active.is_empty(): fail("Import interrupted. Drop the file again after reconnecting.")
