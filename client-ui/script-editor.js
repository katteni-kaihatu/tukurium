/* Shared Script Editor for overlay (2D pin) and off-screen panel (3D texture). */
(function () {
  const PIN_SVG = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 3.5h6l-1 6.5 3.5 3.5h-11L10 10z"></path><path d="M12 13.5V21"></path></svg>';

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function post(message) {
    if (window.ipc) window.ipc.postMessage(JSON.stringify(message));
  }

  function createUi(options) {
    const mode = options.mode || "overlay";
    // Do not put `.window` on the shell: that class is for overlay frames (fixed 640px).
    // Off-screen panel pages must fill the 1120×960 capture surface.
    const shell = el("div", mode === "panel" ? "script-shell panel-shell" : "script-shell");

    const head = el("div", "whead");
    const title = el("h2", "", "Script Editor");
    const pin = el("button", "tb pin");
    pin.type = "button";
    pin.setAttribute("aria-label", "ピン留め");
    pin.setAttribute("aria-pressed", "false");
    pin.innerHTML = PIN_SVG;
    const close = el("button", "tb");
    close.id = "close";
    close.type = "button";
    close.textContent = "×";
    close.setAttribute("aria-label", "閉じる");
    head.append(title, pin, close);

    const status = el("p", "script-status", "");
    const body = el("div", "script-body");
    const side = el("div", "script-side");
    const count = el("div", "muted tiny", "");
    const list = el("div", "script-list");
    const removeBtn = el("button", "ghost", "Remove selected");
    removeBtn.type = "button";
    const confirm = el("div", "script-confirm");
    confirm.hidden = true;
    const confirmMsg = el("p", "", "");
    const confirmCancel = el("button", "ghost", "Cancel");
    const confirmOk = el("button", "ghost", "Remove script");
    confirmCancel.type = "button";
    confirmOk.type = "button";
    confirm.append(confirmMsg, confirmCancel, confirmOk);
    const addBlank = el("button", "ghost", "+ Blank script");
    const addGraph = el("button", "ghost", "+ Node graph");
    addBlank.type = "button";
    addGraph.type = "button";
    const hint = el("p", "muted tiny", "");
    side.append(count, list, removeBtn, confirm, el("hr", "rule"), el("div", "tiny bold", "Add a script"), addBlank, addGraph, hint);

    const main = el("div", "script-main");
    const toolbar = el("div", "script-toolbar");
    const selectedTitle = el("div", "bold", "");
    const runBtn = el("button", "ghost tiny", "Run");
    const pauseBtn = el("button", "ghost tiny", "Pause");
    runBtn.type = "button";
    pauseBtn.type = "button";
    toolbar.append(selectedTitle, runBtn, pauseBtn);
    const runStatus = el("div", "muted tiny", "");
    const codeHead = el("div", "tiny bold", "Source code · Apply to save");
    const codeHost = el("div", "script-code");
    const graphHost = el("div", "script-graph-host");
    graphHost.hidden = true;
    const dropBar = el("div", "script-drop");
    dropBar.hidden = true;
    dropBar.append(el("span", "tiny", "Field reference:"));
    ["Read", "Write", "Drive"].forEach((op) => {
      const b = el("button", "ghost tiny", op);
      b.type = "button";
      b.dataset.op = op;
      dropBar.append(b);
    });
    const dropCancel = el("button", "ghost tiny", "Cancel");
    dropCancel.type = "button";
    dropBar.append(dropCancel);
    const paramsHead = el("div", "tiny bold", "Public parameters · changes save automatically");
    const params = el("div", "script-params");
    const feedback = el("p", "muted tiny", "");
    const actions = el("div", "script-actions");
    const applyBtn = el("button", "ghost", "Apply code");
    const reloadBtn = el("button", "ghost", "Reload draft");
    const clickBtn = el("button", "ghost", "Test click");
    applyBtn.type = "button";
    reloadBtn.type = "button";
    clickBtn.type = "button";
    actions.append(applyBtn, reloadBtn, clickBtn);
    main.append(toolbar, runStatus, codeHead, codeHost, graphHost, dropBar, paramsHead, params, feedback, actions);
    body.append(side, main);
    shell.append(head, status, body);

    const state = {
      view: null,
      mode,
      dirty: false,
      filling: false,
      cm: null,
      graph: null,
      dropped: null,
      document: null,
      graphDoc: null,
      paramTimer: 0,
    };

    function panelId() {
      return state.view && state.view.panelId ? state.view.panelId : "";
    }

    function selected() {
      const id = state.view && state.view.scriptId;
      return (state.view && state.view.scripts || []).find((s) => s.id === id) || null;
    }

    function graphPrefix() {
      return (window.tukuriumScriptGraph && window.tukuriumScriptGraph.PREFIX) || "@tukurium-graph-v1\n";
    }

    function isGraph() {
      const cur = selected();
      return !!(cur && (cur.graph || String(cur.source || "").startsWith(graphPrefix())));
    }

    function paintCarets(document, selfId) {
      if (!state.cm || !document) return;
      (state.caretMarks || []).forEach((mark) => mark.clear && mark.clear());
      state.caretMarks = [];
      const carets = document.cursors || document.carets || [];
      if (!Array.isArray(carets) || !document.text) return;
      const mine = selfId || state.clientId || "";
      carets.forEach((caret) => {
        const id = String(caret.client_id || "");
        if (mine && id === mine) return;
        const offset = Number(caret.head != null ? caret.head : caret.offset);
        if (!Number.isFinite(offset)) return;
        const pos = state.cm.posFromIndex(Math.max(0, Math.min(offset, document.text.length)));
        const widget = el("span", "script-caret");
        widget.textContent = caret.name || caret.client_id || "·";
        state.caretMarks.push(state.cm.setBookmark(pos, { widget, insertLeft: true }));
      });
    }

    function ensureEditors() {
      if (!state.cm && window.CodeMirror) {
        state.cm = window.CodeMirror(codeHost, {
          mode: "lua",
          lineNumbers: true,
          indentUnit: 4,
          lineWrapping: true,
          value: "",
        });
        state.cm.on("change", () => {
          if (state.filling) return;
          state.dirty = true;
          feedback.textContent = "Draft · Apply code to save; Run / Pause stays as shown above.";
          refreshButtons();
          post({ type: "command", name: "script_draft", panel: panelId(), script: state.view.scriptId, source: state.cm.getValue() });
        });
        state.cm.on("cursorActivity", () => {
          if (!state.document) return;
          const doc = state.cm.getDoc();
          const cur = doc.getCursor();
          const offset = doc.indexFromPos(cur);
          post({ type: "command", name: "script_cursor", panel: panelId(), script: state.view.scriptId, offset });
        });
      }
      if (!state.graph && window.tukuriumScriptGraph) {
        state.graph = window.tukuriumScriptGraph.create(graphHost, (ops) => {
          state.dirty = true;
          post({ type: "command", name: "graph_op", panel: panelId(), ops });
          refreshButtons();
        });
      }
    }

    function refreshButtons() {
      const view = state.view || {};
      const cur = selected();
      const editable = !!view.editable && !view.readonly;
      const busy = !!view.busy;
      const scripts = view.scripts || [];
      removeBtn.disabled = !editable || !cur || state.dirty || busy;
      addBlank.disabled = !editable || scripts.length >= 4 || state.dirty || busy;
      addGraph.disabled = addBlank.disabled;
      runBtn.disabled = !editable || !cur || state.dirty || busy;
      pauseBtn.disabled = runBtn.disabled;
      applyBtn.disabled = !editable || !cur || busy;
      reloadBtn.disabled = !cur || busy;
      clickBtn.disabled = !editable || !cur || !cur.hasInteract || state.dirty;
      if (state.cm) state.cm.setOption("readOnly", !editable || !!view.readonly || busy);
      if (state.graph) state.graph.setReadonly(!editable || !!view.readonly || busy);
    }

    function renderList() {
      list.innerHTML = "";
      const scripts = (state.view && state.view.scripts) || [];
      if (!scripts.length) {
        list.append(el("p", "empty", "No scripts attached yet"));
        return;
      }
      scripts.forEach((script) => {
        const row = el("button", "script-item" + (script.id === state.view.scriptId ? " selected" : ""));
        row.type = "button";
        const kind = script.kindLabel || (script.graph ? "Node graph" : "Luau");
        row.textContent = script.name + "  ·  " + kind + "  ·  " + (script.status || (script.enabled ? "Running" : "Paused"));
        if (script.error) row.title = script.error;
        row.addEventListener("click", () => {
          if (state.dirty) {
            feedback.textContent = "Apply or Reload before switching scripts.";
            return;
          }
          post({ type: "command", name: "script_select", panel: panelId(), script: script.id });
        });
        list.append(row);
      });
    }

    function renderParams() {
      params.innerHTML = "";
      const cur = selected();
      if (!cur) return;
      const fields = cur.schemaFields || [];
      fields.forEach((field) => {
        const row = el("div", "field");
        row.append(el("div", "fname", field.label || field.id));
        const values = cur.parameters || {};
        if (field.value_type === "bool") {
          const input = el("input");
          input.type = "checkbox";
          input.checked = !!values[field.id];
          input.disabled = state.dirty || !(state.view && state.view.editable);
          input.addEventListener("change", () => queueParam(field.id, input.checked));
          row.append(input);
        } else if (field.value_type === "number") {
          const input = el("input", "text");
          input.type = "number";
          input.step = "0.1";
          input.value = values[field.id] != null ? values[field.id] : 0;
          input.disabled = state.dirty || !(state.view && state.view.editable);
          input.addEventListener("change", () => queueParam(field.id, Number(input.value)));
          row.append(input);
        } else if (field.value_type === "string") {
          const input = el("input", "text");
          input.maxLength = 512;
          input.value = values[field.id] != null ? String(values[field.id]) : "";
          input.disabled = state.dirty || !(state.view && state.view.editable);
          input.addEventListener("change", () => queueParam(field.id, input.value));
          row.append(input);
        } else if (field.value_type === "color" || field.value_type === "vec3") {
          const wrap = el("div", "axis");
          const arr = Array.isArray(values[field.id]) ? values[field.id] : (field.value_type === "color" ? [1, 1, 1, 1] : [0, 0, 0]);
          const labels = field.value_type === "color" ? ["R", "G", "B", "A"] : ["X", "Y", "Z"];
          labels.forEach((label, i) => {
            const input = el("input", "text");
            input.type = "number";
            input.step = "0.01";
            input.value = arr[i] != null ? arr[i] : 0;
            input.disabled = state.dirty || !(state.view && state.view.editable);
            input.addEventListener("change", () => {
              const next = labels.map((_, j) => Number(wrap.children[j].value || 0));
              queueParam(field.id, next);
            });
            wrap.append(input);
          });
          row.append(wrap);
        } else if (field.value_type === "field_ref") {
          const chip = el("div", "ref-chip", values[field.id] ? JSON.stringify(values[field.id].field_id || values[field.id]) : "None");
          const clear = el("button", "ghost tiny", "Clear");
          clear.type = "button";
          clear.disabled = state.dirty || !(state.view && state.view.editable);
          clear.addEventListener("click", () => queueParam(field.id, null));
          row.append(chip, clear);
        } else {
          row.append(el("span", "muted", field.value_type || "?"));
        }
        params.append(row);
      });
    }

    function queueParam(id, value) {
      clearTimeout(state.paramTimer);
      state.paramTimer = setTimeout(() => {
        post({ type: "command", name: "script_param", panel: panelId(), script: state.view.scriptId, field: id, value });
      }, 180);
    }

    function showEditor() {
      ensureEditors();
      const graph = isGraph();
      codeHost.hidden = graph;
      graphHost.hidden = !graph;
      codeHead.textContent = graph ? "Node graph · wire nodes · Apply graph to save" : "Luau source · Apply code to save";
      applyBtn.textContent = graph ? "Apply graph" : "Apply code";
      const cur = selected();
      if (!cur) {
        if (!state.dirty && state.cm) { state.filling = true; state.cm.setValue(""); state.filling = false; }
        if (!state.dirty && state.graph) state.graph.load({ name: "Graph", nodes: [], links: [] });
        return;
      }
      if (graph) {
        if (!state.dirty && state.graph) {
          let data = cur.graphData;
          const prefix = graphPrefix();
          if ((!data || !data.nodes) && String(cur.source || "").startsWith(prefix)) {
            try { data = JSON.parse(cur.source.slice(prefix.length)); } catch (_) { data = { name: cur.name || "Graph", nodes: [], links: [] }; }
          }
          state.graph.load(data || { name: cur.name || "Graph", nodes: [], links: [] });
        }
      } else if (state.cm) {
        const text = cur.draft != null ? cur.draft : (cur.source || "");
        if (state.cm.getValue() === text) {
          state.dirty = !!cur.dirty;
        } else if (!state.dirty) {
          // While typing, keep the local buffer. Periodic panel_state must not snap text back.
          state.filling = true;
          const cursor = state.cm.getCursor();
          state.cm.setValue(text);
          state.cm.setCursor(cursor);
          state.filling = false;
          state.dirty = !!cur.dirty;
        }
      }
      if (graph && !state.dirty) state.dirty = !!cur.dirty;
    }

    function apply(view) {
      const previousId = state.view && state.view.scriptId;
      state.view = view || { open: false };
      if (!state.view.open) {
        shell.hidden = true;
        return;
      }
      // Switching scripts (or target) discards the in-memory buffer; server draft is authoritative.
      if (previousId !== state.view.scriptId || (view && view.target !== undefined && state._lastTarget !== view.target)) {
        state.dirty = false;
        state.document = null;
        state.graphDoc = null;
      }
      state._lastTarget = state.view.target;
      shell.hidden = false;
      title.textContent = "Script Editor";
      status.textContent = state.view.targetName ? ("対象: " + state.view.targetName) : (state.view.message || "Resources から Script を選ぶか、Slot を選んでください。");
      count.textContent = "Attached scripts · " + ((state.view.scripts || []).length) + " / 4";
      selectedTitle.textContent = (selected() && selected().name) || "";
      runStatus.textContent = selected() ? ((selected().status || "") + (selected().driveHint ? " · " + selected().driveHint : "")) : "";
      // Prefer live draft notice over server feedback while the caret is dirty.
      if (!state.dirty || !feedback.textContent) feedback.textContent = state.view.feedback || "";
      hint.textContent = state.view.hint || "";
      const pinned = !!state.view.open && state.view.mode === "overlay";
      pin.setAttribute("aria-pressed", pinned ? "true" : "false");
      const glyph = pin.querySelector("svg");
      if (glyph) glyph.setAttribute("fill", pinned ? "currentColor" : "none");
      pin.title = pinned ? "ピン留め: オン（画面に固定）" : "ピン留め: オフ（3D空間に置く）";
      reloadBtn.textContent = state.view.shared ? "Reload draft" : "Reload shared code";
      renderList();
      showEditor();
      renderParams();
      refreshButtons();
      if (state.cm) {
        requestAnimationFrame(() => {
          if (state.cm) state.cm.refresh();
        });
      }
      if (mode === "overlay") reportHits();
    }

    function reportHits() {
      if (mode !== "overlay" || !window.tukurium || !window.tukurium.report) return;
      window.tukurium.report(false);
    }

    function editingField() {
      if (state.cm && state.cm.hasFocus && state.cm.hasFocus()) return true;
      return !!shell.querySelector("input:focus, textarea:focus, select:focus");
    }

    pin.addEventListener("click", () => post({ type: "command", name: "pin_script_editor", panel: panelId() }));
    close.addEventListener("click", () => post({ type: "command", name: "close_script_editor", panel: panelId() }));
    removeBtn.addEventListener("click", () => {
      const cur = selected();
      if (!cur) return;
      confirmMsg.textContent = "Remove " + cur.name + "? Its code, parameters and saved state will be deleted.";
      confirm.hidden = false;
    });
    confirmCancel.addEventListener("click", () => { confirm.hidden = true; });
    confirmOk.addEventListener("click", () => {
      confirm.hidden = true;
      post({ type: "command", name: "script_remove", panel: panelId(), script: state.view.scriptId });
    });
    addBlank.addEventListener("click", () => post({ type: "command", name: "script_add", panel: panelId(), kind: "blank" }));
    addGraph.addEventListener("click", () => post({ type: "command", name: "script_add", panel: panelId(), kind: "graph" }));
    runBtn.addEventListener("click", () => post({ type: "command", name: "script_run", panel: panelId(), script: state.view.scriptId, enabled: true }));
    pauseBtn.addEventListener("click", () => post({ type: "command", name: "script_run", panel: panelId(), script: state.view.scriptId, enabled: false }));
    applyBtn.addEventListener("click", () => {
      const cur = selected();
      if (!cur) return;
      if (isGraph()) {
        post({ type: "command", name: "graph_apply", panel: panelId(), source: state.graph ? state.graph.source() : cur.source });
      } else {
        post({ type: "command", name: "script_apply", panel: panelId(), target: state.view.target, script: cur.id, source: state.cm ? state.cm.getValue() : cur.source, enabled: cur.enabled });
      }
    });
    reloadBtn.addEventListener("click", () => {
      state.dirty = false;
      post({ type: "command", name: "script_reload", panel: panelId(), script: state.view.scriptId });
    });
    clickBtn.addEventListener("click", () => post({ type: "command", name: "script_click", panel: panelId(), target: state.view.target, script: state.view.scriptId }));
    dropBar.querySelectorAll("button[data-op]").forEach((btn) => {
      btn.addEventListener("click", () => {
        post({ type: "command", name: "script_insert_ref", panel: panelId(), script: state.view.scriptId, operation: btn.dataset.op, reference: state.dropped });
        dropBar.hidden = true;
        state.dropped = null;
      });
    });
    dropCancel.addEventListener("click", () => { dropBar.hidden = true; state.dropped = null; });

    // Drag header for overlay placement.
    if (mode === "overlay") {
      let hold = null;
      head.addEventListener("pointerdown", (ev) => {
        if (ev.target.closest("button")) return;
        const target = state.frame || shell;
        hold = { x: ev.clientX, y: ev.clientY, left: target.offsetLeft, top: target.offsetTop };
        head.setPointerCapture(ev.pointerId);
      });
      head.addEventListener("pointermove", (ev) => {
        if (!hold) return;
        const target = state.frame || shell;
        target.style.left = hold.left + (ev.clientX - hold.x) + "px";
        target.style.top = hold.top + (ev.clientY - hold.y) + "px";
        state.holdRect = true;
        reportHits();
      });
      head.addEventListener("pointerup", () => {
        if (!hold) return;
        hold = null;
        state.holdRect = false;
        const target = state.frame || shell;
        const rect = target.getBoundingClientRect();
        post({
          type: "command",
          name: "place_script_editor",
          panel: panelId(),
          x: rect.left / window.innerWidth,
          y: rect.top / window.innerHeight,
          w: rect.width / window.innerWidth,
          h: rect.height / window.innerHeight,
          aspect: window.innerWidth / window.innerHeight,
        });
        reportHits();
      });
    }

    return {
      shell,
      state,
      apply,
      editingField,
      receive(message) {
        if (!state.view) return;
        if (message.type === "script_document_state" && message.document) {
          state.document = message.document;
          if (message.client_id) state.clientId = message.client_id;
          const text = message.document.text || "";
          const local = state.cm ? state.cm.getValue() : "";
          if (state.cm && local === text) {
            state.dirty = false;
          } else if (state.cm && !state.dirty) {
            state.filling = true;
            state.cm.setValue(text);
            state.filling = false;
            state.dirty = false;
          }
          // If dirty and local differs, keep typing; collaborative sync will catch up on flush/Apply.
          feedback.textContent = message.feedback || feedback.textContent;
          if (!state.dirty) paintCarets(message.document, state.clientId);
          refreshButtons();
        }
        if (message.type === "script_graph_state" && message.document) {
          state.graphDoc = message.document;
          if (state.graph && message.document.graph && !state.dirty) state.graph.load(message.document.graph);
          feedback.textContent = message.feedback || feedback.textContent;
          refreshButtons();
        }
        if (message.type === "script_offer_ref") {
          state.dropped = message.reference;
          dropBar.hidden = false;
          dropBar.querySelectorAll("button[data-op]").forEach((btn) => {
            if (btn.dataset.op === "Write") btn.disabled = !message.script_write;
            if (btn.dataset.op === "Drive") btn.disabled = !message.script_drive;
          });
        }
      },
      pointer(message) {
        if (!message) return;
        const target = document.elementFromPoint(message.x, message.y) || document.body;
        const type = message.kind === "button" ? (message.pressed ? "mousedown" : "mouseup") : message.kind === "wheel" ? "wheel" : "mousemove";
        const init = {
          bubbles: true,
          cancelable: true,
          clientX: message.x,
          clientY: message.y,
          button: message.button || 0,
          buttons: message.pressed ? 1 : 0,
          view: window,
        };
        target.dispatchEvent(new MouseEvent(type, init));
        if (message.kind === "button" && message.pressed) {
          target.dispatchEvent(new MouseEvent("click", init));
          const field = target.closest("input, textarea, select, .CodeMirror");
          if (field && field.classList && field.classList.contains("CodeMirror") && state.cm) {
            state.cm.focus();
            const pos = state.cm.coordsChar({ left: message.x, top: message.y }, "window");
            state.cm.setCursor(pos);
            post({ type: "panel_focus", focused: true, panel: panelId() });
          } else if (field && field.matches && field.matches("input, textarea, select")) {
            field.focus();
            post({ type: "panel_focus", focused: true, panel: panelId() });
          } else if (document.activeElement && document.activeElement.blur) {
            document.activeElement.blur();
            post({ type: "panel_focus", focused: false, panel: panelId() });
          }
        }
        if (message.kind === "wheel") {
          target.dispatchEvent(new WheelEvent("wheel", { ...init, deltaY: message.delta || 0 }));
          if (state.cm && target.closest && target.closest(".CodeMirror")) {
            state.cm.focus();
          }
        }
      },
      key(message) {
        if (!message) return;
        const elActive = document.activeElement;
        if (state.cm && (state.cm.hasFocus() || (elActive && elActive.closest && elActive.closest(".CodeMirror")))) {
          if (message.key === "Escape") {
            state.cm.getInputField().blur();
            post({ type: "panel_focus", focused: false, panel: panelId() });
            return;
          }
          if (message.key === "Backspace") {
            state.cm.execCommand("delCharBefore");
            return;
          }
          if (message.key === "Delete") {
            state.cm.execCommand("delCharAfter");
            return;
          }
          if (message.key === "Enter") {
            state.cm.replaceSelection("\n", "end");
            return;
          }
          if (typeof message.key === "string" && message.key.length === 1 && !message.ctrl && !message.alt && !message.meta) {
            state.cm.replaceSelection(message.key, "end");
          }
          return;
        }
        if (!elActive || (elActive.tagName !== "INPUT" && elActive.tagName !== "TEXTAREA")) return;
        if (message.key === "Escape") {
          elActive.blur();
          post({ type: "panel_focus", focused: false, panel: panelId() });
          return;
        }
        if (message.key === "Backspace") {
          const start = elActive.selectionStart ?? elActive.value.length;
          const end = elActive.selectionEnd ?? elActive.value.length;
          if (start === end && start > 0) {
            elActive.value = elActive.value.slice(0, start - 1) + elActive.value.slice(end);
            elActive.selectionStart = elActive.selectionEnd = start - 1;
          } else {
            elActive.value = elActive.value.slice(0, start) + elActive.value.slice(end);
            elActive.selectionStart = elActive.selectionEnd = start;
          }
          elActive.dispatchEvent(new Event("input", { bubbles: true }));
          elActive.dispatchEvent(new Event("change", { bubbles: true }));
          return;
        }
        if (typeof message.key === "string" && message.key.length === 1 && !message.ctrl && !message.alt && !message.meta) {
          const start = elActive.selectionStart ?? elActive.value.length;
          const end = elActive.selectionEnd ?? elActive.value.length;
          elActive.value = elActive.value.slice(0, start) + message.key + elActive.value.slice(end);
          elActive.selectionStart = elActive.selectionEnd = start + 1;
          elActive.dispatchEvent(new Event("input", { bubbles: true }));
          elActive.dispatchEvent(new Event("change", { bubbles: true }));
        }
      },
      place(rect) {
        if (!rect || rect.length < 4) return;
        const target = state.frame || shell;
        target.style.left = rect[0] * window.innerWidth + "px";
        target.style.top = rect[1] * window.innerHeight + "px";
        target.style.width = rect[2] * window.innerWidth + "px";
        target.style.height = rect[3] * window.innerHeight + "px";
      },
      setFrame(frame) {
        state.frame = frame;
      },
    };
  }

  const instances = new Map();

  window.tukuriumScriptEditor = {
    mount(host, options) {
      const ui = createUi(options || {});
      host.append(ui.shell);
      instances.set(host, ui);
      return ui;
    },
    apply(view) {
      // Single-mount pages (panel / first overlay helper).
      const first = instances.values().next().value;
      if (first) first.apply(view);
    },
    applyTo(host, view) {
      const ui = instances.get(host);
      if (ui) ui.apply(view);
    },
    receive(message) {
      instances.forEach((ui) => {
        if (message.panel && ui.state.view && ui.state.view.panelId && message.panel !== ui.state.view.panelId) return;
        ui.receive(message);
      });
    },
    pointer(message) {
      instances.forEach((ui) => ui.pointer(message));
    },
    key(message) {
      instances.forEach((ui) => ui.key(message));
    },
    editingField() {
      for (const ui of instances.values()) if (ui.editingField()) return true;
      return false;
    },
    createWindow(parent, view) {
      const wrap = el("section", "glass window script-window");
      wrap.dataset.hit = "1";
      wrap.dataset.radius = "18";
      wrap.dataset.panel = view.panelId || "";
      const mount = el("div", "");
      mount.style.height = "100%";
      wrap.append(mount);
      parent.append(wrap);
      const ui = createUi({ mode: "overlay" });
      ui.setFrame(wrap);
      ui.shell.style.height = "100%";
      ui.shell.style.borderRadius = "0";
      ui.shell.style.boxShadow = "none";
      mount.append(ui.shell);
      instances.set(mount, ui);
      ui.apply(Object.assign({ mode: "overlay", open: true }, view));
      if (view.rect) ui.place(view.rect);
      return { wrap, ui };
    },
  };
})();
