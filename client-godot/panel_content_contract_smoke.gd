extends SceneTree
## Headless contract check: every WorldPanel content script exposes the methods
## world_panels / world_panel call at close, focus clear, and tick.
## Run: Godot --headless --path client-godot --script res://panel_content_contract_smoke.gd

const CONTENTS := [
	{"path": "res://inspector_view.gd", "script_host": true},
	{"path": "res://creation_panel.gd", "script_host": false},
	{"path": "res://resources_view.gd", "script_host": false},
	{"path": "res://script_editor_view.gd", "script_host": true},
	{"path": "res://workspace_view.gd", "script_host": false},
]

const REQUIRED_ALL := ["finish_all", "has_active_edits", "disconnected"]
const REQUIRED_SCRIPT_HOST := ["tick"]

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var failed := 0
	for entry in CONTENTS:
		var path: String = entry.path
		var script: GDScript = load(path)
		if script == null:
			push_error("Missing content script: %s" % path)
			failed += 1
			continue
		var node: Object = script.new()
		if node == null:
			push_error("Could not instantiate: %s" % path)
			failed += 1
			continue
		for method_name in REQUIRED_ALL:
			if not node.has_method(method_name):
				push_error("%s missing %s()" % [path, method_name])
				failed += 1
		if entry.script_host:
			for method_name in REQUIRED_SCRIPT_HOST:
				if not node.has_method(method_name):
					push_error("%s (script host) missing %s()" % [path, method_name])
					failed += 1
			if node.get("edits") == null:
				push_error("%s (script host) missing edits Dictionary" % path)
				failed += 1
		if node is Node:
			(node as Node).free()
		elif node.has_method("free"):
			node.free()
	if failed > 0:
		push_error("panel content contract failed (%d)" % failed)
		quit(1)
		return
	print("panel content contract ok")
	quit(0)
