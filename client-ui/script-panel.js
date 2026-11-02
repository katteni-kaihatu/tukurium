const mount = document.querySelector("#mount");
window.tukuriumScriptEditor.mount(mount, { mode: "panel" });
let captureDue = 0;

function requestCapture() {
  captureDue = Date.now() + 32;
}

function capture() {
  if (!window.ipc) return;
  window.ipc.postMessage(JSON.stringify({ type: "panel_capture_request", surface: "script_editor" }));
}

window.tukurium = {
  apply(message) {
    if (!message) return;
    if (message.type === "panel_state" && (message.surface === "script_editor" || message.scriptEditor)) {
      window.tukuriumScriptEditor.apply(Object.assign({ mode: "panel", open: true }, message.scriptEditor || message.model || {}));
      requestCapture();
      return;
    }
    if (message.type === "panel_pointer") {
      window.tukuriumScriptEditor.pointer(message);
      requestCapture();
      return;
    }
    if (message.type === "panel_key") {
      window.tukuriumScriptEditor.key(message);
      requestCapture();
      return;
    }
    if (message.type === "script_document_state" || message.type === "script_graph_state") {
      window.tukuriumScriptEditor.receive(message);
      requestCapture();
    }
  },
  requestCapture,
  report() {},
};

setInterval(() => {
  if (captureDue && Date.now() >= captureDue) {
    captureDue = 0;
    capture();
  }
}, 16);

if (!window.ipc) {
  window.tukurium.apply({
    type: "panel_state",
    surface: "script_editor",
    scriptEditor: {
      open: true,
      mode: "panel",
      title: "Script Editor",
      editable: true,
      target: "demo",
      targetName: "Demo",
      scriptId: "s1",
      scripts: [{ id: "s1", name: "Script1", enabled: true, status: "Running", source: "return {\n  name = \"Script1\",\n  fields = {},\n}\n", graph: false, parameters: {} }],
    },
  });
}
