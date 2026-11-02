extends RefCounted
## Collaborative script_document / script_graph adapter for the HTML Script Editor surface.
## Keeps drafts in Godot and pushes text/graph state to client-ui; Apply still goes through script commands.

var bridge
var panel_id := ""
var client_id := ""
var target_id := ""
var script_id := ""
var draft_text := ""
var document: Dictionary = {}
var latest: Dictionary = {}
var flight: Dictionary = {}
var opening := false
var generation := 0
var due := 0
var heartbeat := 0
var caret_offset := 0
var feedback := ""
var busy_close := false
var graph_document: Dictionary = {}
var graph_latest: Dictionary = {}
var graph_queue: Array = []
var graph_flight := false
var graph_failed := false
var graph_due := 0
var graph_heartbeat := 0
var pending_apply: Dictionary = {}

func setup(owner, id: String) -> void:
	bridge = owner
	panel_id = id
	client_id = bridge.app.world_panels.client_id + "/html/" + id

func is_graph_script(script: Dictionary) -> bool:
	return str(script.get("source", "")).begins_with("@tukurium-graph-v1\n")

func current_script() -> Dictionary:
	if not bridge.app.objects.has(target_id): return {}
	for script in bridge.app.objects[target_id].get("scripts", []):
		if str(script.id) == script_id: return script
	return {}

func busy() -> bool:
	return opening or not flight.is_empty() or graph_flight or not graph_queue.is_empty() or busy_close

func refresh(next_target: String, next_script: Variant) -> void:
	var sid := str(next_script) if next_script != null else ""
	if (next_target != target_id or sid != script_id) and busy():
		busy_close = true
		feedback = "Synchronizing the draft before switching…"
		return
	if next_target != target_id:
		leave()
		target_id = next_target
		script_id = ""
		draft_text = ""
	if not sid.is_empty() and sid != script_id:
		leave()
		script_id = sid
		draft_text = ""
		open_document()
	elif not script_id.is_empty() and document.is_empty() and graph_document.is_empty() and not opening:
		open_document()

func open_document() -> void:
	var current: Dictionary = current_script()
	if current.is_empty() or opening or not bridge.app.objects.has(target_id): return
	if is_graph_script(current):
		open_graph()
		return
	generation += 1
	var token := generation
	opening = true
	feedback = "Opening shared draft…"
	request("open", {}, func(result):
		if token != generation: return
		opening = false
		if not result.get("ok", false):
			feedback = str(result.get("message", "Cannot open shared draft"))
			bridge.push_script_state(panel_id, true)
			return
		document = result.document
		latest = document
		draft_text = str(document.get("text", ""))
		feedback = "Shared draft · everyone can type · Apply code to run"
		heartbeat = 0
		bridge.push_document_state(panel_id)
		bridge.push_script_state(panel_id, true))

func open_graph() -> void:
	generation += 1
	var token := generation
	opening = true
	feedback = "Opening shared graph…"
	graph_request("open", {}, func(result):
		if token != generation: return
		opening = false
		if not result.get("ok", false):
			feedback = str(result.get("message", "Cannot open shared graph"))
			bridge.push_script_state(panel_id, true)
			return
		graph_document = result.document
		graph_latest = result.document
		graph_failed = false
		graph_heartbeat = Time.get_ticks_msec()
		feedback = "Shared graph · synchronized with applied code"
		bridge.push_graph_state(panel_id)
		bridge.push_script_state(panel_id, true))

func request(action: String, extra: Dictionary, callback: Callable) -> void:
	if not bridge.app.objects.has(target_id) or script_id.is_empty(): return
	var input := {
		"target": bridge.app.address_of(bridge.app.objects[target_id]),
		"script_id": script_id,
		"client_id": client_id,
		"action": action,
		"generation": document.get("generation", ""),
		"name": bridge.app.nickname.text,
	}
	input.merge(extra)
	bridge.app.requests.request({"kind": "script_document", "request": input}, callback, ["request", "request_id"], "request_id", 10000, "script_document_result")

func graph_request(action: String, extra: Dictionary, callback: Callable) -> String:
	if not bridge.app.objects.has(target_id) or script_id.is_empty(): return ""
	var input := {
		"target": bridge.app.address_of(bridge.app.objects[target_id]),
		"script_id": script_id,
		"client_id": client_id,
		"action": action,
		"generation": graph_document.get("generation", ""),
	}
	input.merge(extra)
	return bridge.app.requests.request({"kind": "script_graph", "request": input}, callback,
		["request", "request_id"], "command_id" if action == "apply" else "request_id", 10000,
		"result" if action == "apply" else "script_graph_result")

func set_draft(text: String) -> void:
	draft_text = text
	due = Time.get_ticks_msec() + 80

func set_cursor(offset: int) -> void:
	# Remember the live caret even while an edit is in flight; the presence
	# heartbeat must re-send this offset, not the end of the draft.
	caret_offset = maxi(0, offset)
	if document.is_empty() or not flight.is_empty(): return
	var ids: Array = document.get("ids", [])
	var clamped: int = mini(caret_offset, ids.size())
	var head: String = ids[clamped - 1] if clamped > 0 and not ids.is_empty() else "0"
	request("cursor", {"anchor": head, "head": head}, func(result):
		if result.get("ok", false): receive(result.document))

func queue_graph_ops(ops: Array) -> void:
	if graph_document.is_empty() or graph_failed or opening: return
	graph_queue.append(ops.duplicate(true))
	graph_due = Time.get_ticks_msec() + 60

func receive(value: Dictionary) -> void:
	if str(value.get("target", {}).get("instance_id", "")) != target_id: return
	if str(value.get("script_id", "")) != script_id: return
	if document.is_empty(): return
	if value.get("generation", "") != document.get("generation", ""):
		feedback = "The document was reset. Reload draft to continue."
		bridge.push_script_state(panel_id, true)
		return
	if int(value.get("revision", 0)) < int(latest.get("revision", 0)): return
	latest = value
	if not flight.is_empty(): return
	if draft_text != str(document.get("text", "")):
		flush()
		return
	document = value
	draft_text = str(document.get("text", ""))
	bridge.push_document_state(panel_id)

func receive_graph(value: Dictionary) -> void:
	if str(value.get("target", {}).get("instance_id", "")) != target_id: return
	if str(value.get("script_id", "")) != script_id or graph_document.is_empty(): return
	if value.get("generation", "") != graph_document.get("generation", ""):
		graph_failed = true
		feedback = "Graph draft was reset. Reload draft to continue."
		bridge.push_script_state(panel_id, true)
		return
	if int(value.get("revision", 0)) < int(graph_latest.get("revision", 0)): return
	graph_latest = value
	bridge.push_graph_state(panel_id)

func delta(before: String, after: String, ids: Array) -> Dictionary:
	var prefix := 0
	while prefix < mini(before.length(), after.length()) and before[prefix] == after[prefix]: prefix += 1
	var suffix := 0
	while suffix < mini(before.length() - prefix, after.length() - prefix) and before[before.length() - suffix - 1] == after[after.length() - suffix - 1]: suffix += 1
	return {"after": "0" if prefix == 0 else ids[prefix - 1], "delete": ids.slice(prefix, before.length() - suffix), "insert": after.substr(prefix, after.length() - prefix - suffix)}

func project(base: Dictionary, change: Dictionary, previous_ids: Array) -> Dictionary:
	var ids: Array = []
	var chars: Array = []
	for i in base.ids.size():
		if not change.delete.has(base.ids[i]):
			ids.append(base.ids[i])
			chars.append(base.text[i])
	var at := ids.find(change.after) + 1
	if change.after != "0" and at == 0:
		var old := previous_ids.find(change.after)
		while old >= 0:
			at = ids.find(previous_ids[old]) + 1
			if at > 0: break
			old -= 1
	for i in change.insert.length():
		ids.insert(at + i, "")
		chars.insert(at + i, change.insert[i])
	return {"text": "".join(chars), "ids": ids, "caret": at + change.insert.length()}

func flush() -> void:
	if opening or document.is_empty() or not flight.is_empty() or draft_text == str(document.get("text", "")): return
	var change := delta(str(document.text), draft_text, document.ids)
	var proposed := project(document, change, document.ids)
	send_edit(change, proposed)

func send_edit(change: Dictionary, proposed: Dictionary) -> void:
	var token := generation
	flight = proposed
	request("edit", change, func(result):
		if token != generation: return
		if not result.get("ok", false):
			flight.clear()
			feedback = str(result.get("message", "Draft synchronization failed; copy your text before reloading"))
			bridge.push_script_state(panel_id, true)
			return
		var sent: Dictionary = flight.duplicate(true)
		var inserted: Array = result.get("inserted_ids", [])
		var next := 0
		for i in sent.ids.size():
			if sent.ids[i] == "":
				sent.ids[i] = inserted[next]
				next += 1
		var local_text: String = draft_text
		flight.clear()
		if latest.is_empty() or int(result.document.revision) >= int(latest.revision): latest = result.document
		document = latest
		if sent.text == local_text:
			draft_text = str(document.get("text", ""))
			bridge.push_document_state(panel_id)
		else:
			var queued := delta(sent.text, local_text, sent.ids)
			var rebased := project(document, queued, sent.ids)
			draft_text = str(rebased.text)
			bridge.push_document_state(panel_id)
			send_edit(queued, rebased))

func flush_graph() -> void:
	if opening or graph_flight or graph_failed or graph_document.is_empty() or graph_queue.is_empty(): return
	graph_flight = true
	var token := generation
	graph_request("edit", {"ops": graph_queue[0]}, func(result):
		if token != generation: return
		graph_flight = false
		if not result.get("ok", false):
			graph_failed = true
			feedback = str(result.get("message", "Graph synchronization failed. Reload draft to retry."))
			bridge.push_script_state(panel_id, true)
			return
		graph_queue.pop_front()
		if graph_latest.is_empty() or int(result.document.revision) >= int(graph_latest.revision): graph_latest = result.document
		graph_document = graph_latest
		bridge.push_graph_state(panel_id)
		if not graph_queue.is_empty(): flush_graph()
		elif not pending_apply.is_empty(): apply_graph())

func apply_code(enabled: bool, parameters: Dictionary) -> void:
	if document.is_empty(): return
	if not flight.is_empty() or draft_text != str(document.get("text", "")):
		pending_apply = {"enabled": enabled, "parameters": parameters, "kind": "code"}
		flush()
		feedback = "Synchronizing the shared draft before applying…"
		bridge.push_script_state(panel_id, true)
		return
	var current: Dictionary = current_script()
	if current.is_empty(): return
	bridge.app.world_panels.command({
		"kind": "script",
		"command": {
			"target": bridge.app.address_of(bridge.app.objects[target_id]),
			"action": "update",
			"script_id": script_id,
			"expected_revision": current.revision,
			"source": draft_text,
			"enabled": enabled,
			"parameters": parameters,
		}
	}, func(result):
		feedback = "" if result.get("ok", false) else str(result.get("message", "Script rejected"))
		open_document()
		bridge.push_script_state(panel_id, true))

func apply_graph() -> void:
	if pending_apply.is_empty(): return
	if graph_document.is_empty() or graph_failed or graph_flight or not graph_queue.is_empty():
		feedback = "Synchronizing shared graph before Apply…"
		bridge.push_script_state(panel_id, true)
		return
	var action: Dictionary = pending_apply
	pending_apply = {}
	var current: Dictionary = current_script()
	if current.is_empty(): return
	graph_request("apply", {
		"revision": int(graph_latest.revision),
		"expected_revision": current.revision,
		"enabled": bool(action.get("enabled", current.enabled)),
		"parameters": action.get("parameters", current.get("parameters", {})),
	}, func(result):
		feedback = "" if result.get("ok", false) else str(result.get("message", "Graph apply rejected"))
		open_graph()
		bridge.push(true)
		bridge.push_script_state(panel_id, true))

func request_apply_graph(enabled: bool, parameters: Dictionary) -> void:
	pending_apply = {"enabled": enabled, "parameters": parameters, "kind": "graph"}
	flush_graph()
	if graph_queue.is_empty() and not graph_flight: apply_graph()

func reload() -> void:
	if not flight.is_empty() or graph_flight:
		feedback = "Wait for the draft to finish synchronizing."
		bridge.push_script_state(panel_id, true)
		return
	leave()
	open_document()

func leave() -> void:
	if not graph_document.is_empty() and not graph_flight:
		bridge.app.requests.request({"kind": "script_graph", "request": {
			"target": graph_document.target, "script_id": graph_document.script_id,
			"client_id": client_id, "action": "leave", "generation": graph_document.generation}},
			func(_r): pass, ["request", "request_id"], "request_id", 10000, "script_graph_result")
	graph_document = {}
	graph_latest = {}
	graph_queue.clear()
	graph_flight = false
	graph_failed = false
	if not document.is_empty() and flight.is_empty():
		bridge.app.requests.request({"kind": "script_document", "request": {
			"target": document.target, "script_id": document.script_id, "client_id": client_id,
			"action": "leave", "generation": document.generation}}, func(_r): pass,
			["request", "request_id"], "request_id", 10000, "script_document_result")
	generation += 1
	document = {}
	latest = {}
	flight = {}
	opening = false
	pending_apply = {}
	draft_text = ""
	caret_offset = 0

func tick() -> void:
	if not graph_queue.is_empty() and Time.get_ticks_msec() >= graph_due: flush_graph()
	if not graph_flight and graph_queue.is_empty() and not pending_apply.is_empty() and pending_apply.get("kind", "") == "graph":
		apply_graph()
	if document.is_empty() or opening or not bridge.app.editable: return
	var now := Time.get_ticks_msec()
	if now >= due: flush()
	if flight.is_empty() and not pending_apply.is_empty() and pending_apply.get("kind", "") == "code" and draft_text == str(document.get("text", "")):
		var action: Dictionary = pending_apply
		pending_apply = {}
		apply_code(bool(action.get("enabled", true)), action.get("parameters", {}))
	if flight.is_empty() and draft_text == str(document.get("text", "")) and now - heartbeat > 1500:
		heartbeat = now
		set_cursor(mini(caret_offset, draft_text.length()))

func disconnected() -> void:
	leave()
	feedback = "Connection interrupted."
