const mount = document.querySelector("#mount");
window.tukuriumInspector.mount(mount);
let captureDue = 0;
let lastFrame = "";

function requestCapture() {
  captureDue = Date.now() + 32;
}

function capture() {
  if (!window.ipc) return;
  // Panel pages are fixed 1120×960. Ask the host to CapturePreview; JS only marks dirty.
  window.ipc.postMessage(JSON.stringify({ type: "panel_capture_request" }));
}

window.tukurium = {
  apply(message) {
    if (!message) return;
    if (message.type === "panel_state") {
      window.tukuriumInspector.apply(Object.assign({ mode: "panel", open: true }, message.inspector || message));
      requestCapture();
      return;
    }
    if (message.type === "panel_pointer") {
      window.tukuriumInspector.pointer(message);
      requestCapture();
      return;
    }
    if (message.type === "panel_key") {
      window.tukuriumInspector.key(message);
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
    inspector: {
      open: true, mode: "panel", title: "Cube", editable: true, target: "cube",
      objects: [{ id: "cube", name: "Cube", parent: "" }],
      sections: [{ name: "Slot", fields: [{ id: "name", label: "Name", type: "string", text: "Cube" }] }],
      scripts: [],
    },
  });
}
