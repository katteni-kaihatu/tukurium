const mascot = document.querySelector("#mascot");
const inspector = document.querySelector("#inspector");
const mount = document.querySelector("#inspector-mount");
const scriptHost = document.querySelector("#script-editors");
const scriptWindows = new Map();
let latest = null;
let rectSig = "";
let placedSig = "";
const scriptPlaced = new Map();

mascot.src = window.ipc ? "brand/mascot.png" : "../client-godot/assets/branding/mascot.png";
window.tukuriumInspector.mount(mount);

function post(message) {
  if (window.ipc) window.ipc.postMessage(JSON.stringify(message));
}

function report(full) {
  const dpr = window.devicePixelRatio || 1;
  const rects = full ? [{
    x: 0, y: 0,
    w: Math.round(window.innerWidth * dpr),
    h: Math.round(window.innerHeight * dpr),
    r: 0,
  }] : [];
  if (!full) {
    for (const el of document.querySelectorAll("[data-hit]")) {
      if (el.hidden) continue;
      const box = el.getBoundingClientRect();
      if (box.width < 1 || box.height < 1) continue;
      rects.push({
        x: Math.round(box.x * dpr),
        y: Math.round(box.y * dpr),
        w: Math.max(1, Math.round(box.width * dpr)),
        h: Math.max(1, Math.round(box.height * dpr)),
        r: Math.round(Number(el.dataset.radius || 0) * dpr),
      });
    }
  }
  const next = JSON.stringify(rects);
  if (next === rectSig) return;
  rectSig = next;
  post({ type: "rects", rects });
}

function renderHeader(header) {
  if (!header) return;
  document.querySelector("#play").setAttribute("aria-pressed", header.edit ? "false" : "true");
  document.querySelector("#edit").setAttribute("aria-pressed", header.edit ? "true" : "false");
  document.querySelector("#room").textContent = header.room || "";
  const sync = document.querySelector("#sync");
  sync.textContent = header.sync || "";
  sync.dataset.status = header.status || "wait";
  const engine = document.querySelector("#engine");
  engine.textContent = header.engine || "";
  engine.hidden = !header.engine;
  document.querySelector("#fps").textContent = header.fps || "";
  document.querySelector("#view").textContent = header.view || "FPS";
  document.querySelector("#open-inspector").setAttribute("aria-pressed", header.inspector ? "true" : "false");
}

function placeWindow(view) {
  if (!view || !view.rect || !view.open) return;
  if (window.tukuriumInspector.state.view && window.tukuriumInspector.state.holdRect) return;
  const key = JSON.stringify(view.rect.map((value) => Math.round(Number(value) * 1000)));
  if (key === placedSig) return;
  placedSig = key;
  const [x, y, w, h] = view.rect;
  inspector.style.left = `${x * window.innerWidth}px`;
  inspector.style.top = `${y * window.innerHeight}px`;
  inspector.style.width = `${w * window.innerWidth}px`;
  inspector.style.height = `${h * window.innerHeight}px`;
}

function syncScriptEditors(list) {
  const wanted = new Set();
  (list || []).forEach((view) => {
    if (!view || !view.open || !view.panelId) return;
    wanted.add(view.panelId);
    let entry = scriptWindows.get(view.panelId);
    if (!entry) {
      entry = window.tukuriumScriptEditor.createWindow(scriptHost, Object.assign({ mode: "overlay" }, view));
      scriptWindows.set(view.panelId, entry);
    } else {
      entry.ui.apply(Object.assign({ mode: "overlay", open: true }, view));
    }
    if (view.rect && !(entry.ui.state && entry.ui.state.holdRect)) {
      const key = JSON.stringify(view.rect.map((value) => Math.round(Number(value) * 1000)));
      if (scriptPlaced.get(view.panelId) !== key) {
        scriptPlaced.set(view.panelId, key);
        entry.ui.place(view.rect);
      }
    }
  });
  for (const [id, entry] of [...scriptWindows.entries()]) {
    if (wanted.has(id)) continue;
    entry.wrap.remove();
    scriptWindows.delete(id);
    scriptPlaced.delete(id);
  }
}

function apply(message) {
  if (!message) return;
  if (message.type === "script_document_state" || message.type === "script_graph_state" || message.type === "script_offer_ref") {
    window.tukuriumScriptEditor.receive(message);
    report(false);
    return;
  }
  if (message.type !== "state") return;
  latest = message;
  renderHeader(message.header);
  const view = message.inspector || { open: false };
  inspector.hidden = !view.open;
  if (view.open) {
    placeWindow(view);
    window.tukuriumInspector.apply(Object.assign({ mode: "overlay" }, view));
  }
  syncScriptEditors(message.scriptEditors || []);
  report(false);
}

window.tukurium = { apply, report };

document.querySelector(".modes").addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (!button) return;
  post({ type: "command", name: "edit_mode", value: button.dataset.command === "edit" });
});
document.querySelector("#view").addEventListener("click", () => post({ type: "command", name: "view" }));
document.querySelector("#open-inspector").addEventListener("click", () => post({ type: "command", name: "inspector" }));
document.addEventListener("pointerdown", (event) => {
  if (event.target.closest("#inspector input, #inspector textarea, #inspector select, #script-editors input, #script-editors textarea, #script-editors select, .CodeMirror")) return;
  if (event.target.closest("#inspector, #script-editors .script-window")) {
    setTimeout(() => {
      if (!window.tukuriumInspector.editingField() && !window.tukuriumScriptEditor.editingField()) post({ type: "focus_parent" });
    }, 0);
    return;
  }
  post({ type: "command", name: "release" });
  post({ type: "focus_parent" });
});
document.addEventListener("focusin", (event) => {
  if (event.target.closest("#inspector input, #inspector textarea, #inspector select")) {
    window.tukuriumInspector.notifyFocus(true);
  }
  if (event.target.closest("#script-editors input, #script-editors textarea, #script-editors select, .CodeMirror")) {
    post({ type: "panel_focus", focused: true, panel: event.target.closest("[data-panel]")?.dataset.panel || "" });
  }
});
document.addEventListener("focusout", () => {
  setTimeout(() => {
    if (!window.tukuriumInspector.editingField() && !window.tukuriumScriptEditor.editingField()) {
      window.tukuriumInspector.notifyFocus(false);
      post({ type: "focus_parent" });
    }
  }, 0);
});
window.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  event.preventDefault();
  if (document.activeElement) document.activeElement.blur();
  post({ type: "command", name: "escape" });
  post({ type: "focus_parent" });
});
window.addEventListener("resize", () => report(false));

if (!window.ipc) {
  apply({
    type: "state",
    header: {
      edit: true, room: "Workshop", sync: "● 同期済み", status: "ready",
      engine: "Engine 4 ms", fps: "60 FPS", view: "FPS", inspector: true,
    },
    inspector: {
      open: true, mode: "overlay", title: "Cube", editable: true, message: "", target: "cube", panelId: "panel",
      rect: [0.06, 0.11, 0.5, 0.7],
      objects: [{ id: "cube", name: "Cube", parent: "" }],
      sections: [
        { name: "Slot", fields: [{ id: "name", label: "Name", type: "string", text: "Cube" }] },
      ],
      catalog: [{ typeId: "WorldText", disabled: false }],
      shapes: ["box", "sphere", "quad"],
      scripts: [],
    },
    scriptEditors: [{
      open: true, mode: "overlay", panelId: "script-panel", target: "cube", targetName: "Cube", editable: true,
      scriptId: "s1", rect: [0.55, 0.12, 0.4, 0.7],
      scripts: [{ id: "s1", name: "Script1", enabled: true, status: "Running", source: "return {\n  name = \"Script1\",\n  fields = {},\n}\n", graph: false, parameters: {}, schemaFields: [] }],
    }],
  });
} else {
  report(false);
}
