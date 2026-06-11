# Preview Panel as a First-Class Tiling Pane (Heterogeneous Split-Tree Leaves)

Date: 2026-06-09
Status: Approved (design)

## Problem

The Markdown/text/image preview panel (`markdown_preview_panel.zig`) is a
right-docked **singleton**: all of its state is threadlocal globals (`g_kind`,
`g_title_buf`, `g_path_buf`, `g_source`, `g_scroll_offset`, `g_image_*`,
`g_load_status`, `g_width`, `g_owner_tab`), with a matching threadlocal GL
image-texture cache in `markdown_preview_renderer.zig`. It lives entirely
**outside** the split tree — the leaf type is terminal-only
(`split_tree.zig`: `Node.leaf: *Surface`) — so it can only dock on the right
edge of one tab, at most one at a time, with a bespoke draggable width.

Goal: make the preview a **first-class tiling pane** — a real leaf in the split
tree that can be focused, navigated, **swapped with terminal panes**, resized via
the split divider, and zoomed, exactly like a terminal pane. This is the same
architectural move already approved for the copilot
(`2026-06-04-copilot-tiling-panel-design.md`), whose first non-terminal arm was
to be `copilot`; here the first non-terminal arm is `preview`.

## Scope (decided)

- **In scope:** the preview becomes a first-class split-tree leaf. Multiple
  preview panes per tab are allowed (split to compare two files side by side).
- **In scope:** convert the preview singleton into a per-instance `PreviewPane`
  object (the lift unique to this feature — the copilot already had a per-instance
  `ai_chat.Session`).
- **In scope:** land the **shared `Pane` infrastructure** (heterogeneous leaves,
  `surfaces()`/`panes()` iterators, per-leaf render/input dispatch, persistence
  codec) with arms `terminal` + `preview`. The copilot work rebases onto this
  later (see "Relationship to the copilot branch").
- **Out of scope (future arms):** `copilot`, `webview`. The data model is designed
  so each is a one-arm addition.
- **Out of scope:** moving panes across tabs; persisting preview *scroll/zoom*
  state (only kind + path persist).

## Goals / Non-Goals

**Goals**
- A preview is a normal pane: created by splitting, focusable, navigable
  (`Ctrl+1-9`, spatial), swappable (`Alt+drag`), resizable (divider), zoomable —
  reusing the existing split-tree machinery unchanged.
- `Surface` stays single-purpose (terminal only). No preview fields bolted on.
- The data model trivially extends to `copilot` / `webview` panes later.

**Non-Goals**
- Keeping the old right-dock as a parallel code path (it is removed).
- Persisting preview scroll position / image zoom across restart.
- Cross-tab pane moves.
- Full generic-ization of `SplitTree` over a `View` type (we use a concrete
  sum type, not Ghostty-style generics).

## Architecture

### Chosen approach: `Pane` sum-type leaf

The split-tree leaf changes from `*Surface` (terminal-only) to a small tagged
union:

```zig
// split_tree.zig
pub const Pane = union(enum) {
    terminal: *Surface,
    preview:  *PreviewPane,
    // copilot / webview: future arms (one each)

    pub fn ref(self: Pane) Pane;            // dispatch to the arm
    pub fn unref(self: Pane, gpa: Allocator) void;
};

pub const Node = union(enum) {
    leaf: Pane,        // was: *Surface
    split: Split,
};
```

Rejected alternatives: (2) a polymorphic `Surface` with a content union —
pollutes the terminal-centric `Surface` with unused preview/image fields and
fits a future webview pane even worse; (3) keep the right-dock and only allow it
to "swap" slots — a special-case hack that lives outside the tree model and never
delivers real focus/resize/zoom.

### Why most operations come for free

The geometry/topology functions (`swapLeaves`, `spatial`, `deepest`,
`previous`/`nextHandle`, `zoom`, reading-order / number-focus) switch on
`.leaf`/`.split` and operate on **handles** — they ignore the leaf payload. They
only need to compile against `Pane`. Concretely, `swapLeaves`
(`split_tree.zig:426`) swaps the two leaf payloads by value and asserts leaf-ness;
swapping `Pane`s is identical to swapping `*Surface`s. So **swap / `Ctrl+1-9` nav
/ spatial nav / divider-resize / zoom are reused unchanged.**

### `PreviewPane` (new file `src/preview_pane.zig`)

The singleton state moves into a per-instance struct:

```zig
kind: markdown_preview.Kind,
load_status: LoadStatus,
title_buf: [256]u8, title_len: usize,
path_buf:  [512]u8, path_len: usize,
source: ?[]u8,
scroll_offset: f32,
image_zoom: f32, image_pan_x: f32, image_pan_y: f32,
content_generation: u64,
request_id: u64,
jobs: std.ArrayListUnmanaged(*PreviewJob),   // each pane owns its async loads
// image-texture cache, migrated from markdown_preview_renderer.zig:
image_texture: gpu.GLuint, image_w: c_int, image_h: c_int,
image_generation: u64, image_failed: bool,
refcount: usize,                             // see below
```

The existing pure logic in `markdown_preview_panel.zig` (`open`, `beginAsyncLoad`,
`tickAsync`, `scrollBy`, `zoomImageBySteps`, `panImageBy`, `clampImagePan`,
async job machinery) moves onto `PreviewPane` as methods. The existing unit tests
in that file become `PreviewPane` *instance* tests (they already exercise exactly
this state machine).

`Surface` is **unchanged**.

### Reference counting (the one subtlety)

`SplitTree` is immutable: every edit `clone()`s the tree and ref-counts each leaf
so versions share leaves (`clone` → `surface.ref()`). `PreviewPane` must be
ref-counted the same way. `Pane.ref` / `Pane.unref` dispatch per arm; `deinit`
unrefs each leaf via `Pane.unref`. On the final unref a `PreviewPane` frees its
source buffer and pending jobs, and **defers GL texture deletion to the render
thread** (see render section).

### Containing churn: two iterators

`.leaf` is referenced in 5 files: `split_tree.zig`, `appwindow/tab.zig`,
`appwindow/split_layout.zig`, `session_persist.zig`, `renderer/overlays.zig`. The
existing `iterator()` yields `SurfaceEntry { handle, surface: *Surface }` and is
used at ~38 sites, nearly all of which want **terminals only** (PTY resize,
snapshot, bell, focus-of-terminal). To avoid sprinkling `if (.terminal)`
everywhere:

- `tree.surfaces()` — yields only terminal leaves (skips preview), preserving the
  current `SurfaceEntry` shape. Existing terminal-only walks switch to this with a
  method rename, no per-site branching.
- `tree.panes()` — yields all leaves (`{ handle, pane: Pane }`); used by new code
  that must see every pane: render, focus resolution, persistence, swap.

### Render dispatch (one site)

Leaf rects are computed in `appwindow/split_layout.zig` and drawn via the
renderer. When drawing a leaf, dispatch on `Pane` kind: `terminal` → the cell
renderer (unchanged); `preview` → `markdown_preview_renderer` called with
`(rect, *PreviewPane)` instead of reading globals + the single dock rect. The
renderer's image-texture cache (currently threadlocal `g_image_texture` keyed by a
generation counter) moves into the pane; the GL handle lifecycle stays
**render-thread-owned** — the renderer lazily creates/uploads the texture for a
pane on the render thread, and texture deletion for freed panes is deferred to the
render thread (a small deferred-delete list), avoiding GL-on-wrong-thread hazards.

### Input dispatch (one site)

The **focused leaf** decides routing (generalizing today's "is the mouse over the
one dock rect" logic):
- Focused leaf is a `terminal` → PTY (unchanged).
- Focused leaf is a `preview` → scroll / image zoom / image pan on **that pane**:
  - Keyboard: `PageUp`/`PageDown`/`Home`/`End`/arrows scroll; for image kind,
    `+`/`-`/`=` (and `Ctrl+wheel`) zoom, drag pans.
  - Mouse: a click within a preview leaf's rect focuses it; wheel/drag route to
    that leaf's rect (the hit-test moves from the single dock rect to the leaf rect
    supplied by `split_layout`).

## UX & Behavior

### Open / create (decision: "reuse, else create")

On `Ctrl+click` of a file path in terminal *T* (active tab):

1. A preview pane **already exists** in the tab → load the clicked file **into
   it**: the focused pane if it is a preview, else the first preview in reading
   order (top-left → bottom-right). The pane is **not moved**; it updates in place
   wherever it currently sits. (Deterministic and stateless — no MRU tracking.)
2. **No** preview pane exists → **create one at the right edge of the tab**
   (see placement rule) with a fresh `PreviewPane`. **Opening does not steal
   keyboard focus** — *T* keeps focus, matching today's right-dock feel.
3. **Additional** previews on demand (when one already exists and you want a
   second): a command-center **"Split → Preview"** entry, plus a modifier-click
   (e.g. `Ctrl+Shift+click`) that forces a **new** preview pane regardless of
   existing ones. New panes from these paths also follow the right-edge placement
   rule.

### Placement rule (decision: prefer the right side)

Even though the right-dock is gone, a **newly created** preview pane defaults to
the **right edge of the active tab's layout** — implemented by splitting at the
**root** handle with direction `right`, which wraps the entire existing layout on
the left and places the new preview as the rightmost column. Initial split ratio
is derived from today's `DEFAULT_WIDTH` (~440px) relative to the window width,
clamped, so it opens at roughly the familiar size. A second/third preview created
while one exists splits the existing right-edge preview region (previews stay
grouped on the right). Because it is a first-class pane, the user can afterward
`Alt+drag`-swap, spatially move, or resize it anywhere. (The right-edge default is
about *creation*, not a constraint — reuse never relocates an existing preview.)

### As a real pane (free from the tree)
Focus, `Ctrl+1-9` number-focus, spatial nav, **`Alt+drag` swap with a terminal**,
divider-resize, zoom-to-tab. A focused preview pane shows the focus ring like any
pane.

### Close
The standard close-split keybind closes a preview pane like any pane. A
preview-only tab is allowed; the tab closes only when **all** panes are gone
(existing behavior).

## Removing the right-dock

The bespoke docking machinery is **deleted**, since the tree now owns geometry:

- `markdown_preview_panel.zig`: `g_width` / `setWidth` / `width()` / `MIN_WIDTH` /
  `MAX_WIDTH` / `DEFAULT_WIDTH` / `RESIZE_HIT_WIDTH` and the
  `g_owner_tab` / `isVisibleForActiveTab` / `onTabClosed` / `onTabReordered`
  ownership tracking (tab ownership is now implicit — the pane lives in that tab's
  tree).
- `input.zig`: the resize hit-test, `g_markdown_preview_resize_dragging`, and the
  "over the dock rect" mouse routing (replaced by focused-leaf routing).
- `AppWindow.zig`: `width()`'s contribution to `reservedRightWidth` (the right-dock
  width reservation).
- `renderer/markdown_preview_renderer.zig`: the dock-rect geometry, resize-edge
  draw, and `isVisibleForActiveTab()` gate (replaced by per-leaf rect rendering).

Net simplification — geometry, visibility, and tab lifecycle all collapse into
"it's a leaf in the tree."

## Persistence (decision: persist slot + reload path)

`session_persist.zig` already saves/restores the split tree. `LeafSnap` gains a
kind:

```zig
pub const LeafSnap = union(enum) {
    terminal: SurfaceSnap,   // was the only (implicit) case
    preview:  PreviewSnap,   // { kind: markdown_preview.Kind, path: []const u8 }
};
```

Codec **version bump**. On restore: `terminal` → build the `Surface` as today;
`preview` → recreate the `PreviewPane` in place and kick `beginAsyncLoad(path)`
best-effort (shows "failed" if the file is gone or moved). `countLeaves`,
`focused_leaf`, and `zoomed_leaf` are leaf-index based and therefore unaffected
(a restored focused/zoomed preview is valid). Scroll/zoom state is not persisted.

## Relationship to the `feat/copilot-tiling-panel` branch

Both features introduce the same heterogeneous-leaf infrastructure. That branch
is **unmerged and unimplemented** (spec `de90e28` + plan `fab1c06`). Decision:
**this preview work lands the shared `Pane` infra** (the `Pane` type,
`surfaces()`/`panes()`, per-leaf render/input dispatch, the `LeafSnap` codec) with
arms `terminal` + `preview`. Preview is the simpler pane — no agent target, no
terminal binding, no live session — so it is the cleaner first mover. The copilot
branch then **rebases** to add a `copilot` arm: its Phase 1 ("`Pane` type + leaf
change + iterators") becomes already-done, and it keeps Phases 2–7 (CopilotPane,
binding, agent-target resolution, dock removal, persistence, webview-overlay fix).
`Pane` is designed so adding `copilot` / `webview` is a one-arm change.

## Edge Cases
- **Zoom** a preview pane → full-tab; works via leaf-agnostic tree zoom.
- **`Alt+drag` swap** preview↔terminal → `swapLeaves` now swaps `Pane`s.
- **Background-tab async load:** `tickAsync` is per-pane; AppWindow's frame tick
  walks every preview pane (all tabs) so loads finish even off the active tab.
- **Stale async result:** preserved — each pane keeps its own `request_id`; a
  completed job whose `request_id` no longer matches is dropped (today's guard,
  now per-pane).
- **Last terminal closed, preview remains:** a preview-only tab is allowed; it
  closes when all panes are gone.
- **Image pane focus + keyboard:** `+`/`-` zoom and arrows pan only for
  `kind == .image`; ignored otherwise (today's image-only guards, per-pane).

## Testing Strategy
Follow project TDD; both `zig build test` and `zig build test-full` stay green.

- **Fast suite (pure):** `split_tree` ref/unref/clone with mixed terminal+preview
  leaves; `surfaces()` skips preview, `panes()` yields all; swap / number-focus /
  spatial unaffected by a mixed tree; `PreviewPane` state lifecycle (the ported
  panel tests — open/load/scroll/zoom/pan/free); right-edge placement helper (pure
  fn over a tree); reuse-target selection (pure fn:
  focused-preview-or-first-in-reading-order).
- **Full suite:** `Ctrl+click` reuse-else-create flow; input routed to a focused
  preview (scroll/zoom); render-dispatch smoke (terminal vs preview leaf);
  `session_persist` round-trip with a preview pane (save → load → same layout,
  path reloaded).
- **GUI verify (macOS/Windows; no Linux GUI backend, and WSLg cannot screenshot
  GL):** deferred to the user, as usual.

## Suggested Staging (details deferred to the implementation plan)
1. `Pane` type + `Node.leaf: Pane` + `ref`/`unref`/`clone` + `surfaces()` /
   `panes()` — compiler-driven worklist; terminals keep working, existing tests
   green.
2. `PreviewPane` instance type — migrate singleton state + async machinery; port
   its unit tests to instance tests.
3. Render dispatch per leaf + migrate the image-texture cache into the pane
   (render-thread-owned, deferred delete).
4. Input routing via focused leaf (preview scroll/zoom/pan; per-leaf mouse
   hit-test) + remove the right-dock width/resize machinery.
5. Open flow — `Ctrl+click` reuse-else-create with right-edge placement;
   "Split → Preview" command; `Ctrl+Shift+click` for a new pane.
6. Persistence — `LeafSnap` kind + `PreviewSnap` (kind, path), codec bump, restore
   + async reload.

## Files Touched (anticipated)
- `src/split_tree.zig` — `Pane` / `Node`, `ref`/`unref`/`clone`, `surfaces()` /
  `panes()`, `swapLeaves` payload.
- `src/preview_pane.zig` — **new** per-instance pane (state + async migrated from
  `markdown_preview_panel.zig`).
- `src/markdown_preview_panel.zig` — reduced to the `PreviewPane` instance type (or
  removed once its contents move); singleton globals + dock width machinery deleted.
- `src/renderer/markdown_preview_renderer.zig` — takes `(rect, *PreviewPane)`;
  image-texture cache per pane; dock geometry removed.
- `src/appwindow/split_layout.zig` — per-leaf render/rect dispatch.
- `src/renderer/overlays.zig` — leaf iteration/dispatch site.
- `src/appwindow/tab.zig` — pane-aware tab ops; drop owner-tab tracking.
- `src/AppWindow.zig` — open/create flow + right-edge placement, focus/input
  routing, remove `reservedRightWidth` contribution, per-pane async tick,
  command-center "Split → Preview".
- `src/input.zig` — focused-leaf routing for preview (scroll/zoom/pan), remove
  width-drag hit-test + `g_markdown_preview_resize_dragging`, `Ctrl+click`
  create/reuse + `Ctrl+Shift+click` new.
- `src/session_persist.zig` — `LeafSnap` kind + `PreviewSnap`, codec bump, restore
  reload.
- command-center registry — "Split → Preview" entry.
