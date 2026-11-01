/* HTML node-graph editor compatible with @tukurium-graph-v1 ops (kind/link.out/input). */
(function () {
  const PREFIX = "@tukurium-graph-v1\n";
  const TYPES = {
    on_update: [[], [["flow", "flow"]]], on_interact: [[], [["flow", "flow"]]],
    on_button_press: [[], [["flow", "flow"]]], on_button_release: [[], [["flow", "flow"]]],
    on_contact_start: [[], [["flow", "flow"]]], on_contact_end: [[], [["flow", "flow"]]], on_drive: [[], [["flow", "flow"]]],
    branch: [[["flow", "flow"], ["test", "bool"]], [["yes", "flow"], ["no", "flow"]]],
    sequence: [[["flow", "flow"]], [["first", "flow"], ["second", "flow"]]],
    write_field: [[["flow", "flow"], ["value", "any"]], [["next", "flow"]]],
    drive_field: [[["flow", "flow"], ["value", "any"]], [["next", "flow"]]],
    set_state: [[["flow", "flow"], ["value", "any"]], [["next", "flow"]]],
    capture_camera: [[["flow", "flow"]], [["next", "flow"]]],
    for_range: [[["flow", "flow"], ["start", "number"], ["end", "number"], ["step", "number"]], [["body", "flow"], ["done", "flow"], ["index", "number"]]],
    while_loop: [[["flow", "flow"], ["test", "bool"]], [["body", "flow"], ["done", "flow"]]],
    break_loop: [[["flow", "flow"]], []], continue_loop: [[["flow", "flow"]], []],
    number: [[], [["value", "number"]]], public_number: [[], [["value", "number"]]],
    bool: [[], [["value", "bool"]]], string: [[], [["value", "string"]]],
    vec3: [[], [["value", "vec3"]]], color: [[], [["value", "color"]]],
    delta: [[], [["value", "number"]]], time: [[], [["value", "number"]]], world_time: [[], [["value", "number"]]],
    contact_other_id: [[], [["value", "string"]]],
    read_field: [[], [["value", "any"]]], get_state: [[], [["value", "any"]]],
    display: [[["value", "any"]], [["value", "any"]]],
    add: [[["a", "number"], ["b", "number"]], [["value", "number"]]],
    subtract: [[["a", "number"], ["b", "number"]], [["value", "number"]]],
    multiply: [[["a", "number"], ["b", "number"]], [["value", "number"]]],
    divide: [[["a", "number"], ["b", "number"]], [["value", "number"]]],
    less: [[["a", "number"], ["b", "number"]], [["value", "bool"]]],
    equal: [[["a", "any"], ["b", "any"]], [["value", "bool"]]],
    and: [[["a", "bool"], ["b", "bool"]], [["value", "bool"]]],
    or: [[["a", "bool"], ["b", "bool"]], [["value", "bool"]]],
    not: [[["a", "bool"]], [["value", "bool"]]],
    to_string: [[["value", "any"]], [["value", "string"]]],
    vec3_make: [[["x", "number"], ["y", "number"], ["z", "number"]], [["value", "vec3"]]],
    color_make: [[["r", "number"], ["g", "number"], ["b", "number"], ["a", "number"]], [["value", "color"]]],
  };
  const COLORS = { flow: "#f0b86b", number: "#7bd8cb", bool: "#b5a6ff", string: "#e7aeb6", vec3: "#9cc7fa", color: "#f0d891", any: "#cbd5dc" };
  const EVENT = new Set(["on_update", "on_interact", "on_button_press", "on_button_release", "on_contact_start", "on_contact_end", "on_drive"]);

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function stamp() {
    return "n" + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);
  }

  function create(host, onOps) {
    const root = el("div", "sg-root");
    const tools = el("div", "sg-tools");
    const nameInput = el("input", "text");
    nameInput.placeholder = "Component name";
    nameInput.maxLength = 40;
    const select = el("select", "text");
    Object.keys(TYPES).forEach((kind) => {
      const opt = el("option", "", kind);
      opt.value = kind;
      select.append(opt);
    });
    const addBtn = el("button", "ghost tiny", "+ Node");
    addBtn.type = "button";
    tools.append(nameInput, select, addBtn);
    const canvas = el("div", "sg-canvas");
    canvas.tabIndex = 0;
    root.append(tools, canvas);
    host.append(root);

    let data = { name: "Graph", nodes: [], links: [] };
    let selected = new Set();
    let drag = null;
    let wire = null;
    let readonly = false;

    function emit(ops) {
      if (readonly || !ops.length) return;
      onOps(ops);
    }

    function nodeById(id) {
      return data.nodes.find((n) => n.id === id);
    }

    function redraw() {
      canvas.innerHTML = "";
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("class", "sg-wires");
      svg.setAttribute("width", "100%");
      svg.setAttribute("height", "100%");
      canvas.append(svg);
      data.links.forEach((link) => {
        const from = nodeById(link.from);
        const to = nodeById(link.to);
        if (!from || !to) return;
        const a = portPos(from, link.out, false);
        const b = portPos(to, link.input, true);
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        const mid = (a.x + b.x) / 2;
        path.setAttribute("d", `M${a.x},${a.y} C${mid},${a.y} ${mid},${b.y} ${b.x},${b.y}`);
        path.setAttribute("stroke", "#8a8792");
        path.setAttribute("fill", "none");
        path.setAttribute("stroke-width", "2");
        path.addEventListener("contextmenu", (ev) => {
          ev.preventDefault();
          if (readonly) return;
          data.links = data.links.filter((l) => l !== link);
          emit([{ kind: "disconnect", link: { from: link.from, out: link.out, to: link.to, input: link.input } }]);
          redraw();
        });
        svg.append(path);
      });
      data.nodes.forEach((node) => {
        const card = el("div", "sg-node" + (selected.has(node.id) ? " selected" : ""));
        card.style.left = node.x + "px";
        card.style.top = node.y + "px";
        card.dataset.id = node.id;
        const title = el("div", "sg-title", node.kind);
        card.append(title);
        const ports = el("div", "sg-ports");
        const spec = TYPES[node.kind] || [[], []];
        const left = el("div", "sg-col");
        const right = el("div", "sg-col");
        spec[0].forEach(([pid, type]) => left.append(portEl(node, pid, type, true)));
        spec[1].forEach(([pid, type]) => right.append(portEl(node, pid, type, false)));
        ports.append(left, right);
        card.append(ports);
        if ("value" in node || ["number", "public_number", "bool", "string"].includes(node.kind)) {
          const input = el("input", "text tiny");
          input.value = node.value != null ? String(node.value) : (node.kind === "bool" ? "false" : "0");
          input.disabled = readonly;
          input.addEventListener("change", () => {
            node.value = coerce(node.kind, input.value);
            emit([{ kind: "value", id: node.id, value: node.value }]);
          });
          card.append(input);
        }
        card.addEventListener("pointerdown", (ev) => {
          if (readonly || ev.target.closest(".sg-port")) return;
          selected = new Set([node.id]);
          drag = { id: node.id, ox: ev.clientX - node.x, oy: ev.clientY - node.y };
          card.setPointerCapture(ev.pointerId);
          redraw();
        });
        card.addEventListener("pointermove", (ev) => {
          if (!drag || drag.id !== node.id) return;
          node.x = Math.round(ev.clientX - drag.ox);
          node.y = Math.round(ev.clientY - drag.oy);
          emit([{ kind: "position", id: node.id, x: node.x, y: node.y }]);
          redraw();
        });
        card.addEventListener("pointerup", () => { drag = null; });
        canvas.append(card);
      });
      nameInput.value = data.name || "Graph";
      nameInput.disabled = readonly;
    }

    function coerce(kind, text) {
      if (kind === "bool") return text === "true" || text === "1";
      if (kind === "string") return text;
      const n = Number(text);
      return Number.isFinite(n) ? n : 0;
    }

    function portEl(node, pid, type, input) {
      const row = el("div", "sg-port-row");
      const dot = el("button", "sg-port");
      dot.type = "button";
      dot.style.background = COLORS[type] || COLORS.any;
      dot.title = pid + " · " + type;
      dot.addEventListener("pointerdown", (ev) => {
        ev.stopPropagation();
        if (readonly) return;
        if (input) return;
        wire = { from: node.id, out: pid };
      });
      dot.addEventListener("pointerup", (ev) => {
        ev.stopPropagation();
        if (readonly || !wire || !input) return;
        const link = { from: wire.from, out: wire.out, to: node.id, input: pid };
        data.links = data.links.filter((l) => !(l.to === link.to && l.input === link.input));
        data.links.push(link);
        emit([{ kind: "connect", link }]);
        wire = null;
        redraw();
      });
      if (input) row.append(dot, el("span", "sg-port-label", pid));
      else row.append(el("span", "sg-port-label", pid), dot);
      return row;
    }

    function portPos(node, port, input) {
      const spec = TYPES[node.kind] || [[], []];
      const list = input ? spec[0] : spec[1];
      const index = Math.max(0, list.findIndex((p) => p[0] === port));
      return {
        x: node.x + (input ? 8 : 172),
        y: node.y + 36 + index * 18,
      };
    }

    addBtn.addEventListener("click", () => {
      if (readonly) return;
      const kind = select.value;
      if (EVENT.has(kind) && data.nodes.some((n) => n.kind === kind)) return;
      if (data.nodes.length >= 64) return;
      const node = { id: stamp(), kind, x: 40 + data.nodes.length * 12, y: 40 + data.nodes.length * 12 };
      if (["number", "public_number"].includes(kind)) node.value = 0;
      if (kind === "bool") node.value = false;
      if (kind === "string") node.value = "";
      data.nodes.push(node);
      emit([{ kind: "add_node", node: JSON.parse(JSON.stringify(node)) }]);
      redraw();
    });
    nameInput.addEventListener("change", () => {
      data.name = nameInput.value.slice(0, 40) || "Graph";
      emit([{ kind: "name", value: data.name }]);
    });
    canvas.addEventListener("keydown", (ev) => {
      if (readonly) return;
      if (ev.key === "Delete" || ev.key === "Backspace") {
        const ids = [...selected];
        if (!ids.length) return;
        data.nodes = data.nodes.filter((n) => !selected.has(n.id));
        data.links = data.links.filter((l) => !selected.has(l.from) && !selected.has(l.to));
        emit(ids.map((id) => ({ kind: "remove_node", id })));
        selected.clear();
        redraw();
      }
    });

    return {
      root,
      load(next) {
        data = JSON.parse(JSON.stringify(next || { name: "Graph", nodes: [], links: [] }));
        if (!data.nodes) data.nodes = [];
        if (!data.links) data.links = [];
        redraw();
      },
      source() {
        return PREFIX + JSON.stringify(data);
      },
      data() {
        return JSON.parse(JSON.stringify(data));
      },
      setReadonly(value) {
        readonly = !!value;
        redraw();
      },
      project(base, ops) {
        const next = JSON.parse(JSON.stringify(base));
        (ops || []).forEach((op) => {
          const kind = op.kind || op.op;
          if (kind === "name") next.name = op.value != null ? op.value : op.name;
          if (kind === "add_node" && op.node) next.nodes.push(op.node);
          if (kind === "remove_node") {
            next.nodes = next.nodes.filter((n) => n.id !== op.id);
            next.links = next.links.filter((l) => l.from !== op.id && l.to !== op.id);
          }
          if (kind === "position") {
            const n = next.nodes.find((x) => x.id === op.id);
            if (n) { n.x = op.x; n.y = op.y; }
          }
          if (kind === "value") {
            const n = next.nodes.find((x) => x.id === op.id);
            if (n) n.value = op.value;
          }
          if (kind === "connect" && op.link) {
            next.links = next.links.filter((l) => !(l.to === op.link.to && l.input === op.link.input));
            next.links.push(op.link);
          }
          if (kind === "disconnect" && op.link) {
            next.links = next.links.filter((l) => !(l.from === op.link.from && l.out === op.link.out && l.to === op.link.to && l.input === op.link.input));
          }
        });
        return next;
      },
      PREFIX,
      TYPES,
    };
  }

  window.tukuriumScriptGraph = { create, PREFIX, TYPES };
})();
