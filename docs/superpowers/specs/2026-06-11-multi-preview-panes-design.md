# Multi Preview Panes (per-kind independent panels)

- **Date:** 2026-06-11
- **Status:** Approved (brainstormed with owner)
- **Branch:** `worktree-feat-multi-preview-panes`
- **Builds on:** `2026-06-09-preview-tiling-panel-design.md` (preview as a
  first-class split-tree pane, PR #185)

## Problem

`Ctrl+click` on a file reuses **the** preview pane (`firstPreviewForReuse`:
focused-preview-else-first-in-reading-order) and replaces its content. Opening
an image therefore evicts the markdown you were reading. The owner wants to
read a markdown file, an image, and an HTML page **simultaneously** alongside
the terminal.

## Decisions (made during brainstorming)

1. **Reuse is per content Kind.** Each `markdown_preview.Kind` (`markdown`,
   `text`, `csv`, `tsv`, `image`) gets its own pane. Same kind replaces
   content in its pane; a kind with no pane yet creates a new pane and leaves
   the other kinds' panes untouched.
2. **HTML stays on the browser panel.** `.html` continues through
   `html_server` + the native-webview browser panel (not a split-tree pane).
   It already coexists with preview panes, which satisfies the
   "markdown + image + html at once" goal. A tiled webview pane is a separate
   future project (shared prerequisite with the copilot pane, scope B).
3. **New panes stack in the right preview column.** The first preview keeps
   today's right-edge column (`split(.root, .right, 0.62)`). Every later
   preview pane splits the **bottom-most existing preview pane downward**
   (`.down`, ratio 0.5) instead of carving another full-height column, so
   previews stack vertically and stop squeezing the terminal:

   ```
   [terminal | md pane ]
   [         | img pane]
   [         | csv pane]
   ```

4. **`Ctrl+Shift+click` (always-new) adopts the same stacked placement.**
   Today it carves a new full-height column per pane; the original spec
   already called for stacking, so this is a fix, not a behavior change.
   It remains the escape hatch for two same-kind panes side by side.
5. **No cap on pane count.** `MAX_SPLITS_PER_TAB` and the "Preview failed"
   toast already bound the worst case; `Ctrl+Shift+W` closes previews one per
   press, and dividers resize the stack.

## Addendum (2026-06-12, owner feedback on the shipped #185 behavior)

Two changes shipped on this branch alongside the per-kind work, superseding
the "unchanged behavior" notes below:

1. **Close is focused-pane, not preview-first.** `Ctrl+Shift+W` closes the
   focused pane (terminal or preview alike); select a preview by clicking it
   or via `Ctrl+1-9`. The preview-first path (`closeActivePreviewPane` /
   `tab.closePreviewPane` / `tab.firstPreviewForReuse`) was removed — the
   owner reported the old behavior kept evicting previews instead of closing
   the selected pane. The browser side panel still closes first (it is an
   unfocusable dock, so the shortcut is its only keyboard close).
2. **Image drag-to-pan restored.** The right-dock image preview supported
   left-drag panning; the #185 pane migration dropped that wiring (keyboard
   arrows only). A press on a ready image pane now starts a pan drag again.

## Behavior

### Reuse algorithm (`Ctrl+click`, file-explorer click)

Given the detected `kind` of the clicked file:

1. If the focused leaf is a preview pane **of the same kind** → reuse it
   (replace content via `beginAsyncLoad`).
2. Else, the first preview pane **of the same kind** in reading order →
   reuse it.
3. Else → create a new pane (placement below) and load into it.

Reusing or creating a pane never moves focus: the terminal keeps focus, the
same philosophy as today's preview open.

### Placement algorithm (create)

1. No preview pane in the tab → `split(.root, .right, rightEdgeRatio())`
   (today's `splitIntoPreview`, unchanged).
2. At least one preview pane exists → split the **last preview pane in
   reading order** with `.down`, ratio 0.5. The new pane appears at the
   bottom of the preview stack.

### Unchanged behavior (verified, zero work)

- **Close:** ~~`Ctrl+Shift+W` closes one preview per press (focused preview,
  else first in reading order; `tab.closePreviewPane`), then falls through to
  splits/tab.~~ Superseded by the 2026-06-12 addendum: close targets the
  focused pane.
- **Persistence:** `session_persist.LeafSnap.preview` stores `kind` + `path`
  per leaf; multiple preview panes round-trip automatically.
- **Pane mechanics:** focus ring, `Ctrl+1-9`, Alt+drag swap, divider resize,
  zoom — all leaf-agnostic already.
- A pane's `kind` is set on every load; under per-kind reuse a pane only ever
  receives its own kind, so kinds stay stable. (A pane restored from an old
  mixed-use session simply hosts whatever kind it last had.)

## Implementation

### `src/appwindow/tab.zig`

- `previewForReuse(gpa, t, kind) ?Node.Handle` — kind-aware variant of
  `firstPreviewForReuse` (focused-same-kind first, then reading-order
  first-same-kind, else null). `firstPreviewForReuse` (kind-agnostic) stays
  for `closePreviewPane`.
- `splitIntoPreviewStacked(gpa) ?*PreviewPane` — finds the last preview in
  reading order; if none, delegates to `splitIntoPreview`; otherwise
  `tree.split(handle, .down, 0.5, insert)` with a new `PreviewPane`.

  ⚠️ **Renumbering trap:** `split(at, …)` moves the node at `at` to the last
  position and renumbers; the focused handle must be remapped the same way
  `splitIntoPreview` remaps for `.root` (focused == at → old_len + insert.len;
  focused stays put otherwise — verify against `split()`'s actual layout, and
  cover with a test asserting the terminal keeps focus).

### `src/input.zig`

- `openPreviewAsync(kind, …)`: replace the `firstPreviewForReuse` lookup with
  `previewForReuse(gpa, t, kind)`; on miss call `splitIntoPreviewStacked`.
- `openPreviewNew(kind, …)`: call `splitIntoPreviewStacked` instead of
  `splitIntoPreview`.

No renderer, persistence, or close-path changes.

## Edge cases

- **Split cap reached:** `tree.split` fails → existing "Preview failed" toast.
- **Focused preview of kind X, click kind Y:** the Y pane is reused/created;
  the focused X pane and focus itself are untouched.
- **User swapped/moved panes (Alt+drag):** reading order recomputes from the
  spatial layout, so "last preview" follows the visual bottom-most pane.
- **Old sessions with one mixed-use pane:** restored pane keeps its last
  kind; new kinds open new panes alongside it.

## Testing (TDD, tab.zig test infra from PR #185)

Fast/pure (tab.zig, stub Surface + real PreviewPane):

- `previewForReuse`: focused same-kind wins; reading-order first same-kind;
  null when no same-kind pane (other kinds present); null on terminal-only.
- `splitIntoPreviewStacked`: first pane → right column (delegates); second
  pane → splits the existing preview `.down`, tree grows by 2 nodes, both
  previews remain, terminal keeps focus; refcounts balance (testing
  allocator leak check).
- Two different kinds → two panes coexist; same kind twice → reuse, node
  count unchanged.

Both suites (`zig build test`, `zig build test-full`) stay green.
