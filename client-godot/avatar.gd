extends Node3D

const SELF_AVATAR_LAYER := 1 << 18
var target_position := Vector3.ZERO
var target_yaw := 0.0
var local := false
var name_label := Label3D.new()
var paint_material: StandardMaterial3D
var texture_id := ""

func _ready() -> void:
	if ResourceLoader.exists("res://assets/oekaki/avatar.glb") and ResourceLoader.exists("res://assets/oekaki/sample.png"):
		build_oekaki_avatar()
	else:
		build_simple_avatar()
	name_label.position.y = 1.9
	name_label.auto_translate_mode=Node.AUTO_TRANSLATE_MODE_DISABLED
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.font_size = 48
	name_label.pixel_size = 0.004
	name_label.outline_size = 10
	name_label.no_depth_test = true
	add_child(name_label)

func build_simple_avatar() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("6edbd0")
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.24
	capsule.height = 1.1
	body.mesh = capsule
	body.position.y = 0.65
	body.material_override = material
	add_child(body)
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	head.mesh = sphere
	head.position.y = 1.45
	head.material_override = material
	add_child(head)
	var face := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = Vector3(0.2,0.07,0.05)
	face.mesh = shape
	face.position = Vector3(0,1.48,-0.22)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color("19313e")
	face.material_override = dark
	add_child(face)

func build_oekaki_avatar() -> void:
	var model: Node3D = load("res://assets/oekaki/avatar.glb").instantiate()
	model.scale = Vector3.ONE * 0.012
	model.rotation.y = PI
	add_child(model)
	var material := StandardMaterial3D.new()
	material.albedo_texture = load("res://assets/oekaki/sample.png")
	paint_material = material
	material.albedo_color = Color.WHITE
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	# The GLB already has coincident Front/Back sheets with opposite winding.
	# Rendering both sides of each sheet makes the two faces fight for depth.
	material.cull_mode = BaseMaterial3D.CULL_BACK
	for node in model.find_children("*", "MeshInstance3D", true, false):
		node.material_override = material
	# Tonarium's GLB has one clip per animated part; play those independent tracks together.
	for original in model.find_children("*", "AnimationPlayer", true, false):
		for clip in original.get_animation_list():
			if clip == "RESET": continue
			var animation: Animation = original.get_animation(clip).duplicate()
			animation.loop_mode = Animation.LOOP_LINEAR
			var library := AnimationLibrary.new()
			library.add_animation("idle", animation)
			var player := AnimationPlayer.new()
			player.root_node = original.root_node
			original.get_parent().add_child(player)
			player.add_animation_library("", library)
			player.play("idle")

func apply_texture(texture: Texture2D) -> void:
	if paint_material != null:
		paint_material.albedo_texture = texture if texture != null else load("res://assets/oekaki/sample.png")

func set_state(view: Dictionary, is_local: bool, immediate: bool = false) -> void:
	if local != is_local:
		var layer := SELF_AVATAR_LAYER if is_local else 1
		for visual in find_children("*", "VisualInstance3D", true, false):
			visual.layers = layer
		name_label.visible = not is_local
	local = is_local
	var p: Array = view.pose.position
	target_position = Vector3(p[0], p[1], p[2])
	target_yaw = view.pose.yaw
	name_label.text = view.name + (" (you)" if is_local else "")
	name_label.modulate = Color("a2ece7") if is_local else Color.WHITE
	if immediate:
		position = target_position
		rotation.y = target_yaw

func _process(delta: float) -> void:
	var alpha := 1.0 - exp(-delta * 14.0)
	position = position.lerp(target_position, alpha)
	rotation.y = lerp_angle(rotation.y, target_yaw, alpha)
