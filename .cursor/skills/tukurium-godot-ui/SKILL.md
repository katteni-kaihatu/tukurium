---
name: tukurium-godot-ui
description: >-
  Implements and diagnoses tukurium Godot / WorldPanel / overlay UI without
  repeating known pitfalls (indigo blank screen, pin chrome, shared vs local
  state). Use when adding or changing client-godot UI, Resources, Inspector,
  Creation, Script Editor, pins, 3D panels, HTML overlay, or when the user
  reports a solid indigo/blue empty window or GDScript Parse Error.
---

# tukurium Godot UI

Short gate for UI work. Detailed rules live in `guidelines/`; do not copy them here.

## Before editing

Read in order (skim, then deep-dive only what the change touches):

1. [guidelines/ui-surfaces.md](../../../guidelines/ui-surfaces.md) — 3D shared vs 2D personal
2. [guidelines/world-space-panels.md](../../../guidelines/world-space-panels.md) — if WorldPanel / pin / input
3. [guidelines/lessons-learned.md](../../../guidelines/lessons-learned.md) — search 藍色 / `:=` / pin / HTML

Reuse existing `WorldPanel` + content script. Do not invent a second mesh/collider/input path.

## Hard rules while writing GDScript

- Never use `:=` on untyped values: `app.*`, `Dictionary.get(...)`, or expressions with `and` / `or` / `==` that include them.
  - Bad: `var catalog := job.get("purpose","") == "catalog"`
  - Good: `var catalog: bool = str(job.get("purpose","")) == "catalog"`
- Shared world meaning stays in Rust Components. Godot keeps display copies, focus, drag, GPU only.
- FPS: do not free the mouse just to use a panel; do not stop movement / switch to TPS when opening a panel.
- Pin chrome matches design (`pin_icon_button.gd`, PLUM `#603D56`). Multiple 2D pins allowed.
- Personal overlays (dock, ring, social, creation, camera, home/library, asset status) use `design_chrome.gd` via `preload` — not `class_name`. Workspace chrome is a shared WorldPanel (`workspace_view.gd`), also pinnable.
## After GDScript edits

1. Grep the diff for `var \w+ :=` next to `.get(` / untyped props; fix before handing off.
2. Confirm parse with headless Godot when available:

```powershell
& .tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path client-godot --quit-after 1 2>&1 |
  Select-String -Pattern 'Parse Error|Cannot infer|Compilation failed|Failed to load script'
```

No matches expected. If Godot binary is missing, read the newest `godot.log` under `%APPDATA%\Godot\app_userdata\tukurium\logs\` (or `.run/**/godot-error.log`) — **first** `SCRIPT ERROR: Parse Error` lines, not the flood of `poll` nulls.

## Indigo / blue empty window

Symptom: full window is environment indigo, no floor/grid/camera UI.

Cause (typical): a depended `.gd` failed to parse → `main.gd` did not load → `_ready` never builds the world.

Do this:

1. Open the newest godot error log; read from the **top**.
2. Fix the named file/line (almost always `:=` type inference).
3. Re-run the headless check above.
4. Append or tighten the lesson in `guidelines/lessons-learned.md` if the failure mode is new.

## New panel checklist

- [ ] Surface choice recorded (shared 3D vs personal 2D) per ui-surfaces
- [ ] Rust Component + registry if shared state is new
- [ ] Godot content hosted by existing WorldPanel
- [ ] No new `:=` on Variant-ish expressions
- [ ] Parse check clean; related `tests/*-integration.mjs --rendered` if input path changed
