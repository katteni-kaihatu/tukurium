/* Shared inspector for the overlay (2D pin) and the off-screen panel page (3D texture). */
(function (global) {
  const AXIS = { X: "#a24b55", Y: "#2f7d55", Z: "#3e6294", R: "#a24b55", G: "#2f7d55", B: "#3e6294", A: "#6a6875", W: "#6a6875" };
  const state = {
    view: null,
    fieldSig: "",
    tab: "object",
    catalogOpen: false,
    shapeIndex: 0,
    scriptId: "",
    scriptText: "",
    graph: null,
    dirtyScript: false,
    focused: false,
    holdRect: null,
  };

  function post(message) {
    if (global.ipc) global.ipc.postMessage(JSON.stringify(message));
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text != null) node.textContent = text;
    return node;
  }

  function axisBox(name, value, disabled) {
    const label = el("label", "axis");
    const tag = el("b", null, name);
    tag.style.color = AXIS[name] || "#6a6875";
    const input = el("input");
    input.value = value;
    input.spellcheck = false;
    input.disabled = !!disabled;
    input.setAttribute("aria-label", name);
    label.append(tag, input);
    return label;
  }

  function mount(root) {
    root.replaceChildren();
    const shell = el("div", "inspector-shell");
    shell.id = "inspector-root";
    const head = el("div", "whead");
    head.id = "drag";
    const title = el("h2", null, "Inspector");
    title.id = "title";
    const pin = el("button", "ghost", "ピン");
    pin.id = "pin";
    pin.type = "button";
    pin.setAttribute("aria-pressed", "false");
    const close = el("button", "icon", "×");
    close.id = "close";
    close.type = "button";
    close.setAttribute("aria-label", "閉じる");
    head.append(title, pin, close);
    const tabs = el("div", "tabs");
    const objectTab = el("button", "tab", "Object");
    objectTab.dataset.tab = "object";
    const scriptsTab = el("button", "tab", "Scripts");
    scriptsTab.dataset.tab = "scripts";
    tabs.append(objectTab, scriptsTab);
    const body = el("div", "inspector-body");
    const tree = el("aside", "tree");
    tree.id = "tree";
    const main = el("div", "main");
    main.id = "main";
    body.append(tree, main);
    const message = el("p");
    message.id = "message";
    shell.append(head, tabs, body, message);
    root.append(shell);
    pin.addEventListener("click", () => post({ type: "command", name: "inspector" }));
    close.addEventListener("click", () => post({ type: "command", name: "inspector" }));
    tabs.addEventListener("click", (event) => {
      const button = event.target.closest("[data-tab]");
      if (!button) return;
      state.tab = button.dataset.tab;
      if (state.view) render(state.view);
      if (state.tab === "scripts") post({ type: "command", name: "scripts_tab", open: true, panel: state.view && state.view.panelId });
      else post({ type: "command", name: "scripts_tab", open: false, panel: state.view && state.view.panelId });
    });
    main.addEventListener("change", onChange);
    main.addEventListener("click", onClick);
    tree.addEventListener("click", onTreeClick);
    head.addEventListener("pointerdown", onDragStart);
  }

  function onDragStart(event) {
    if (event.button !== 0 || event.target.closest("button") || !state.view || state.view.mode === "panel") return;
    const inspector = document.querySelector("#inspector");
    if (!inspector) return;
    const offset = { x: event.clientX - inspector.offsetLeft, y: event.clientY - inspector.offsetTop };
    const move = (ev) => {
      inspector.style.left = Math.max(8, ev.clientX - offset.x) + "px";
      inspector.style.top = Math.max(80, ev.clientY - offset.y) + "px";
      if (global.tukurium && global.tukurium.report) global.tukurium.report(true);
    };
    const up = () => {
      document.removeEventListener("pointermove", move);
      document.removeEventListener("pointerup", up);
      const box = inspector.getBoundingClientRect();
      post({
        type: "command",
        name: "place",
        x: box.x / window.innerWidth,
        y: box.y / window.innerHeight,
        w: box.width / window.innerWidth,
        h: box.height / window.innerHeight,
        aspect: window.innerWidth / window.innerHeight,
      });
      if (global.tukurium && global.tukurium.report) global.tukurium.report(false);
    };
    document.addEventListener("pointermove", move);
    document.addEventListener("pointerup", up);
    if (global.tukurium && global.tukurium.report) global.tukurium.report(true);
  }

  function onTreeClick(event) {
    const item = event.target.closest("[data-object]");
    if (!item || !state.view) return;
    post({ type: "command", name: "set_target", panel: state.view.panelId, target: item.dataset.object });
  }

  function onClick(event) {
    const button = event.target.closest("[data-action]");
    if (!button || !state.view) return;
    const action = button.dataset.action;
    const panel = state.view.panelId;
    if (action === "catalog") {
      state.catalogOpen = !state.catalogOpen;
      render(state.view);
      return;
    }
    if (action === "add_component") {
      post({ type: "command", name: "component", panel, add: true, typeId: button.dataset.type, shape: state.shapeIndex });
      state.catalogOpen = false;
      return;
    }
    if (action === "remove_component") {
      post({ type: "command", name: "component", panel, add: false, typeId: button.dataset.type });
      return;
    }
    if (action === "playback") {
      post({ type: "command", name: "playback", panel, target: state.view.target, action: button.dataset.play });
      return;
    }
    if (action === "open_script") {
      state.tab = "scripts";
      state.scriptId = button.dataset.script || "";
      post({ type: "command", name: "open_script", panel, script: state.scriptId });
      render(state.view);
      return;
    }
    if (action === "apply_script") {
      post({ type: "command", name: "script_apply", panel, target: state.view.target, script: state.scriptId, source: state.scriptText });
      state.dirtyScript = false;
      return;
    }
    if (action === "reload_script") {
      state.dirtyScript = false;
      post({ type: "command", name: "open_script", panel, script: state.scriptId });
      return;
    }
    if (action === "graph_add") {
      post({ type: "command", name: "graph_op", panel, ops: [{ kind: "add_node", node_kind: button.dataset.kind, x: 40, y: 40 }] });
      return;
    }
    if (action === "apply_graph") {
      post({ type: "command", name: "graph_apply", panel });
      return;
    }
    if (action === "driver") {
      post({ type: "command", name: "open_driver", panel, field: button.dataset.field });
    }
  }

  function onChange(event) {
    const row = event.target.closest("[data-field]");
    if (!row || !state.view) return;
    if (row.dataset.type === "script_source") {
      state.scriptText = event.target.value;
      state.dirtyScript = true;
      return;
    }
    if (row.dataset.type === "shape") {
      state.shapeIndex = Number(event.target.value) || 0;
      return;
    }
    if (row.dataset.type === "text") return;
    let value;
    if (row.dataset.type === "bool") value = row.querySelector("input").checked;
    else if (row.dataset.type === "string" || row.dataset.type === "number") value = row.querySelector("input").value;
    else if (row.dataset.type === "collider") {
      const checks = [...row.querySelectorAll('input[type="checkbox"]')];
      const extents = [...row.querySelectorAll(".axis input")].map((input) => input.value);
      value = { enabled: checks[0].checked, solid: checks[1].checked, half_extents: extents.map(Number) };
    } else value = [...row.querySelectorAll(".axis input, input.text")].filter((input) => input.type !== "checkbox").map((input) => input.value);
    post({
      type: "edit",
      field: row.dataset.field,
      valueType: row.dataset.type,
      value,
      target: state.view.target,
      panel: state.view.panelId,
    });
  }

  function renderTree(view) {
    const tree = document.querySelector("#tree");
    if (!tree) return;
    tree.replaceChildren();
    const heading = el("div", "tree-head", "Hierarchy");
    tree.append(heading);
    const objects = view.objects || [];
    const byParent = {};
    for (const object of objects) {
      const parent = object.parent || "";
      (byParent[parent] || (byParent[parent] = [])).push(object);
    }
    function add(parentId, depth) {
      for (const object of byParent[parentId] || []) {
        const row = el("button", "tree-item" + (object.id === view.target ? " selected" : ""));
        row.type = "button";
        row.dataset.object = object.id;
        row.style.paddingLeft = `${8 + depth * 12}px`;
        row.textContent = object.name || object.id;
        tree.append(row);
        add(object.id, depth + 1);
      }
    }
    add("", 0);
    if (objects.length === 0) tree.append(el("p", "empty", "物体がありません。"));
  }

  function fieldRow(field, editable) {
    const row = el("div", "field");
    row.dataset.field = field.id;
    row.dataset.type = field.type;
    const name = el("span", "fname", field.label);
    row.append(name);
    if (field.drive) {
      const drive = el("div", "drive", field.drive.label);
      row.append(drive);
      if (field.drive.button) {
        const open = el("button", "ghost tiny", field.drive.button);
        open.type = "button";
        open.dataset.action = "driver";
        open.dataset.field = field.id;
        row.append(open);
      }
    }
    if (field.remote) {
      row.append(el("span", "lease", field.remote));
    }
    if (field.type === "string" || field.type === "number") {
      const input = el("input", "text");
      input.value = field.text || "";
      input.disabled = !editable || !!field.driven;
      input.spellcheck = false;
      row.append(input);
    } else if (field.type === "bool") {
      const label = el("label", "check");
      const input = el("input");
      input.type = "checkbox";
      input.checked = !!field.checked;
      input.disabled = !editable || !!field.driven;
      label.append(input, document.createTextNode(field.label));
      name.remove();
      row.append(label);
    } else if (field.type === "text") {
      row.append(el("span", "static", field.text || ""));
    } else if (field.type === "playback") {
      ["play", "pause", "restart"].forEach((play) => {
        const button = el("button", "ghost tiny", play);
        button.type = "button";
        button.dataset.action = "playback";
        button.dataset.play = play;
        row.append(button);
      });
    } else if (field.type === "collider") {
      const box = el("div", "collider");
      ["Enabled / grabbable", "Solid"].forEach((label, index) => {
        const wrap = el("label", "check");
        const input = el("input");
        input.type = "checkbox";
        input.checked = !!(field.flags && field.flags[index]);
        input.disabled = !editable;
        wrap.append(input, document.createTextNode(label));
        box.append(wrap);
      });
      (field.axes || ["X", "Y", "Z"]).forEach((axis, index) => {
        box.append(axisBox(axis, (field.values && field.values[index]) || "0", !editable));
      });
      row.append(box);
    } else {
      (field.axes || []).forEach((axis, index) => {
        row.append(axisBox(axis, (field.values && field.values[index]) || "0", !editable || !!field.driven));
      });
    }
    return row;
  }

  function renderObject(view) {
    const main = document.querySelector("#main");
    main.replaceChildren();
    const actions = el("div", "actions");
    const catalog = el("button", "ghost", state.catalogOpen ? "− Close Component List" : "+ Add Component");
    catalog.type = "button";
    catalog.dataset.action = "catalog";
    catalog.disabled = !view.editable || !!view.isPanelTarget;
    actions.append(catalog);
    main.append(actions);
    if (state.catalogOpen && view.catalog) {
      const list = el("div", "catalog");
      const shape = el("select");
      shape.dataset.field = "shape";
      shape.dataset.type = "shape";
      (view.shapes || []).forEach((name, index) => {
        const option = el("option", null, name);
        option.value = String(index);
        if (index === (view.shapeIndex || 0)) option.selected = true;
        shape.append(option);
      });
      list.append(el("label", "fname", "Mesh shape"), shape);
      for (const entry of view.catalog) {
        const button = el("button", "catalog-item", "+ " + entry.typeId);
        button.type = "button";
        button.dataset.action = "add_component";
        button.dataset.type = entry.typeId;
        button.disabled = !!entry.disabled || !view.editable;
        button.title = entry.tooltip || "";
        list.append(button);
      }
      main.append(list);
    }
    for (const section of view.sections || []) {
      const card = el("section", "section");
      const heading = el("div", "section-head");
      heading.append(el("h3", null, section.name));
      if (section.removable) {
        const remove = el("button", "ghost tiny", "Remove");
        remove.type = "button";
        remove.dataset.action = "remove_component";
        remove.dataset.type = section.name;
        remove.disabled = !!section.removeDisabled || !view.editable;
        heading.append(remove);
      }
      card.append(heading);
      for (const field of section.fields || []) card.append(fieldRow(field, view.editable));
      main.append(card);
    }
    if (!view.sections || view.sections.length === 0) {
      main.append(el("p", "empty", "ワールドで対象を選んでください。"));
    }
  }

  function renderScripts(view) {
    const main = document.querySelector("#main");
    main.replaceChildren();
    const list = el("div", "script-list");
    for (const script of view.scripts || []) {
      const row = el("div", "script-row");
      row.append(el("span", null, `${script.name} · ${script.enabled ? "Running" : "Paused"}`));
      const edit = el("button", "ghost tiny", "Edit");
      edit.type = "button";
      edit.dataset.action = "open_script";
      edit.dataset.script = script.id;
      row.append(edit);
      list.append(row);
    }
    if (!view.scripts || view.scripts.length === 0) list.append(el("p", "empty", "No scripts attached"));
    const manage = el("button", "ghost", "Manage scripts");
    manage.type = "button";
    manage.dataset.action = "open_script";
    manage.dataset.script = "";
    list.append(manage);
    main.append(list);
    if (view.graph) {
      const graphBox = el("div", "graph");
      graphBox.append(el("h3", null, "Node graph"));
      const tools = el("div", "actions");
      ["number", "add", "write_field", "on_update"].forEach((kind) => {
        const add = el("button", "ghost tiny", "+ " + kind);
        add.type = "button";
        add.dataset.action = "graph_add";
        add.dataset.kind = kind;
        tools.append(add);
      });
      const apply = el("button", "ghost tiny", "Apply graph");
      apply.type = "button";
      apply.dataset.action = "apply_graph";
      tools.append(apply);
      graphBox.append(tools);
      const canvas = el("div", "graph-canvas");
      for (const node of view.graph.nodes || []) {
        const card = el("div", "graph-node");
        card.style.left = `${node.x || 0}px`;
        card.style.top = `${node.y || 0}px`;
        card.textContent = `${node.kind || node.id}`;
        canvas.append(card);
      }
      if ((view.graph.nodes || []).length === 0) canvas.append(el("p", "empty", "ノードを追加してください。"));
      graphBox.append(canvas);
      main.append(graphBox);
      return;
    }
    const editor = el("div", "script-editor");
    const area = el("textarea", "code");
    area.dataset.field = "script_source";
    area.dataset.type = "script_source";
    area.value = view.scriptText || state.scriptText || "";
    area.disabled = !view.editable;
    state.scriptText = area.value;
    area.addEventListener("input", () => {
      state.scriptText = area.value;
      state.dirtyScript = true;
      state.focused = true;
    });
    area.addEventListener("focus", () => { state.focused = true; });
    area.addEventListener("blur", () => { state.focused = false; });
    editor.append(area);
    const actions = el("div", "actions");
    const apply = el("button", "ghost", "Apply code");
    apply.type = "button";
    apply.dataset.action = "apply_script";
    const reload = el("button", "ghost", "Reload draft");
    reload.type = "button";
    reload.dataset.action = "reload_script";
    actions.append(apply, reload);
    editor.append(actions);
    main.append(editor);
  }

  function render(view) {
    state.view = view;
    const shell = document.querySelector("#inspector-root");
    if (!shell) return;
    document.querySelector("#title").textContent = view.title || "Inspector";
    document.querySelector("#message").textContent = view.message || "";
    document.querySelector("#pin").setAttribute("aria-pressed", view.open ? "true" : "false");
    document.querySelectorAll(".tab").forEach((tab) => {
      tab.setAttribute("aria-pressed", tab.dataset.tab === state.tab ? "true" : "false");
    });
    renderTree(view);
    if (state.tab === "scripts") renderScripts(view);
    else renderObject(view);
    if (global.tukurium && global.tukurium.report) global.tukurium.report(false);
    if (view.mode === "panel" && global.tukurium && global.tukurium.requestCapture) {
      global.tukurium.requestCapture();
    }
  }

  function editingField() {
    const active = document.activeElement;
    return active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable);
  }

  function apply(view) {
    if (!view || !view.open) {
      state.view = view;
      return;
    }
    // Keep caret and draft while typing; FPS labels must not rebuild the form.
    if (editingField() || (state.focused && state.tab === "scripts" && state.dirtyScript)) {
      state.view = view;
      const title = document.querySelector("#title");
      const message = document.querySelector("#message");
      if (title) title.textContent = view.title || "Inspector";
      if (message) message.textContent = view.message || "";
      return;
    }
    if (view.scriptId) state.scriptId = view.scriptId;
    if (view.scriptText != null && !state.dirtyScript) state.scriptText = view.scriptText;
    if (view.tab) state.tab = view.tab;
    render(view);
  }

  function notifyFocus(on) {
    state.focused = !!on;
    post({ type: "panel_focus", focused: !!on, panel: state.view && state.view.panelId ? state.view.panelId : "" });
    if (!on) post({ type: "focus_parent" });
  }

  function commitField(node) {
    if (!node || (node.tagName !== "INPUT" && node.tagName !== "TEXTAREA")) return;
    node.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function pointer(event) {
    const target = document.elementFromPoint(event.x, event.y) || document.body;
    const type = event.kind === "button" ? (event.pressed ? "mousedown" : "mouseup") : event.kind === "wheel" ? "wheel" : "mousemove";
    const init = {
      bubbles: true,
      cancelable: true,
      clientX: event.x,
      clientY: event.y,
      button: event.button || 0,
      buttons: event.pressed ? 1 : 0,
      view: window,
    };
    target.dispatchEvent(new MouseEvent(type, init));
    if (event.kind === "button" && event.pressed) {
      target.dispatchEvent(new MouseEvent("click", init));
      const field = target.closest("input, textarea, select") || (target.matches && target.matches("input, textarea, select") ? target : null);
      const prev = document.activeElement;
      if (prev && prev !== field && (prev.tagName === "INPUT" || prev.tagName === "TEXTAREA")) {
        commitField(prev);
      }
      if (field) {
        field.focus();
        notifyFocus(true);
      } else {
        if (prev && prev.blur) prev.blur();
        notifyFocus(false);
      }
    }
    if (event.kind === "wheel") {
      target.dispatchEvent(new WheelEvent("wheel", { ...init, deltaY: event.delta || 0 }));
    }
  }

  function key(event) {
    const el = document.activeElement;
    if (!el || (el.tagName !== "INPUT" && el.tagName !== "TEXTAREA")) return false;
    if (event.key === "Escape") {
      el.blur();
      notifyFocus(false);
      return true;
    }
    if (event.key === "Enter" && el.tagName === "INPUT") {
      commitField(el);
      el.blur();
      notifyFocus(false);
      return true;
    }
    if (event.key === "Backspace") {
      const start = el.selectionStart ?? el.value.length;
      const end = el.selectionEnd ?? el.value.length;
      if (start === end && start > 0) {
        el.value = el.value.slice(0, start - 1) + el.value.slice(end);
        el.selectionStart = el.selectionEnd = start - 1;
      } else {
        el.value = el.value.slice(0, start) + el.value.slice(end);
        el.selectionStart = el.selectionEnd = start;
      }
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    }
    if (event.key === "Delete") {
      const start = el.selectionStart ?? el.value.length;
      const end = el.selectionEnd ?? el.value.length;
      if (start === end) {
        el.value = el.value.slice(0, start) + el.value.slice(end + 1);
      } else {
        el.value = el.value.slice(0, start) + el.value.slice(end);
      }
      el.selectionStart = el.selectionEnd = start;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    }
    if (typeof event.key === "string" && event.key.length === 1 && !event.ctrl && !event.alt && !event.meta) {
      const start = el.selectionStart ?? el.value.length;
      const end = el.selectionEnd ?? el.value.length;
      el.value = el.value.slice(0, start) + event.key + el.value.slice(end);
      el.selectionStart = el.selectionEnd = start + 1;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return true;
    }
    return false;
  }

  global.tukuriumInspector = { mount, apply, pointer, key, state, editingField, notifyFocus };
})(window);
