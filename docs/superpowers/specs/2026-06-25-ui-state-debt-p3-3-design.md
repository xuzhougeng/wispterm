# UI State Debt P3.3 - Input Mouse and Pointer Effect Boundary Design

Status: Draft for user review

## Context

P3.2 created an input-local effect boundary and removed direct AppWindow dirty-flag writes from the highest-risk keyboard and character paths:

- `dispatchChar`
- `dispatchKey`
- key-dispatched helper `openPreviewGalleryNeighbor`
- key-dispatched helper `deleteSelectedAgentHistoryRow`

The fast suite now imports `src/input/dirty_guard.zig`, which prevents those converted paths from regressing back to direct writes of:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

The remaining debt is in the non-key runtime input paths. Current measurements after P3.2:

- `src/input.zig`: 7065 lines.
- `src/input/effects.zig`: 70 lines.
- `src/input/dirty_guard.zig`: 47 lines.
- `src/input.zig` direct `AppWindow.` references: 819.
- `src/input.zig` still has 120 direct dirty assignment lines.

Remaining direct dirty assignments are concentrated in:

- `handleMouseButton`: 56 lines.
- `handleMouseWheel`: 22 lines.
- `handleMouseMove`: 8 lines.
- Width/resize helpers: `applySidebarWidthFromMouse`, `applyBrowserWidthFromMouse`, `applyAiCopilotWidthFromMouse`, `applyExplorerWidthFromMouse`.
- Selection and hover helpers: `markSelectionChanged`, `markUrlUnderlineDirty`, `updateAiTranscriptSelectionDrag`.
- Panel and preview helpers: `toggleBrowserDisplayMode`, `openUrl`, `openHtmlPanelForCell`, `openPreviewAsync`, `openPreviewNew`, `handleFileExplorerPress`, `handleAgentHistoryPress`, `toggleAiAgentPermission`.
- Scrollbar helpers: `applyAiInputScrollbarDrag`, `applyAiTranscriptScrollbarDrag`.
- Panel-swap helper: `updatePanelSwapDrag`.

P3.3 should close this invalidation debt before any larger mouse module split. If the dirtying semantics still live in scattered pointer branches, moving those branches into smaller files will only move the problem.

## Ghostty Reference

Ghostty keeps input-triggered redraw and pointer state changes behind runtime contracts instead of having every input branch know renderer dirty flags:

- `src/input.zig` is a small re-export over focused input modules such as `input/mouse.zig`, `input/key.zig`, `input/keyboard.zig`, and `input/mouse_encode.zig`.
- `src/apprt/action.zig` contains action variants such as `render`, `selection_changed`, `mouse_shape`, `mouse_visibility`, `mouse_over_link`, and `scrollbar`.
- `src/apprt/surface.zig` defines surface messages such as `set_mouse_shape`, `selection_scroll_tick`, `scrollbar`, and `present_surface`.
- `src/apprt/gtk/class/surface.zig` normalizes GTK pointer input and calls core surface callbacks such as `mouseButtonCallback`, `cursorPosCallback`, and `scrollCallback`.

P3.3 should not copy Ghostty's full app/surface mailbox system. The WispTerm-sized step is to finish using `UiEffect` as the local action/effect seam for pointer-driven UI invalidation. Once every input dirty request goes through that seam, a later P3.4 can split mouse/selection files with lower risk.

## Goal

Remove direct AppWindow dirty-flag writes from runtime input business logic by routing mouse, pointer, hover, drag, selection, preview, and wheel invalidation through the existing input effect boundary.

P3.3 is successful when:

- `src/input.zig` runtime paths no longer assign `AppWindow.g_force_rebuild` or `AppWindow.g_cells_valid` directly.
- Full repaint sites call `requestInputRepaint()`.
- Rebuild-only sites call `requestInputRebuild()`.
- Existing model-result sites that assign dirty flags use a narrow helper that maps the model's current dirty-request combinations into `UiEffect` without reintroducing direct writes.
- `src/input/dirty_guard.zig` is expanded so `zig build test` fails if runtime input business code reintroduces direct dirty-flag writes.
- Keyboard shortcuts and user-visible shortcut text remain unchanged.

## Non-Goals

- Do not split `src/input.zig` into new mouse modules in P3.3.
- Do not refactor terminal mouse reporting or PTY escape encoding.
- Do not change selection semantics, click count behavior, URL underline behavior, preview open behavior, AI chat interaction behavior, scrollbar drag behavior, or panel resize behavior.
- Do not change keyboard shortcuts or README shortcut docs.
- Do not change renderer overlay imports.
- Do not touch `remote/`, version files, release notes, packaging, PTY internals, or platform backends beyond what tests already compile.
- Do not attempt to reduce `AppWindow.` references broadly in this phase; P3.3 is about dirty-flag coupling only.

## Architecture

### 1. Keep One Input Effect Boundary

Continue using the P3.2 helpers in `src/input.zig`:

```zig
fn applyInputEffect(effect: ui_effect.UiEffect) void {
    AppWindow.applyUiEffect(effect);
}

fn requestInputRepaint() void {
    applyInputEffect(input_effects.repaint());
}

fn requestInputRebuild() void {
    applyInputEffect(input_effects.rebuildOnly());
}
```

Do not add a second invalidation abstraction in P3.3. Branches that currently set both dirty flags should call `requestInputRepaint()`. Branches that currently set only `g_force_rebuild = true` should call `requestInputRebuild()`.

### 2. Preserve Dirty Semantics

The conversion is mechanical but must preserve each existing dirtying shape:

- Old full repaint:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

becomes:

```zig
requestInputRepaint();
```

- Old rebuild-only:

```zig
AppWindow.g_force_rebuild = true;
```

becomes:

```zig
requestInputRebuild();
```

- Old model-returned flags:

```zig
AppWindow.g_force_rebuild = flags.force_rebuild;
AppWindow.g_cells_valid = flags.cells_valid;
```

must not be silently upgraded to unconditional repaint. Add a local helper that maps the current model output into `UiEffect` request semantics:

```zig
fn requestInputDirtyFlags(force_rebuild: bool, cells_valid: bool) void {
    applyInputEffect(.{
        .consumed = true,
        .needs_rebuild = force_rebuild,
        .cells_invalid = !cells_valid,
    });
}
```

`UiEffect` is a request/merge-style API: it can request rebuild and cell invalidation, but it is not the right API for resetting AppWindow flags to false. That is acceptable for the current `mouse_wheel_scroll.repaintFlagsForViewportScroll` contract, which only returns `.force_rebuild = true, .cells_valid = false` for non-zero viewport scrolling and `null` when no repaint is needed. If a future model needs absolute flag reset semantics, it should introduce a named AppWindow API rather than restoring direct assignments in `input.zig`.

### 3. Convert By Surface Area, Not By Visual Feature

Convert remaining direct writes in an order that keeps reviews small:

1. Small helpers and pointer helper functions.
2. `handleMouseWheel`.
3. `handleMouseMove`.
4. `handleMouseButton`.
5. Guard expansion and final results.

This ordering moves simple helpers first, then the mouse entrypoints. It also avoids mixing behavior extraction with dirty-boundary conversion.

### 4. Expand The Guard After Conversion

The final guard should assert that the runtime body of `src/input.zig` does not contain direct dirty writes, while allowing:

- test setup/restoration references near the top of `src/input.zig`;
- direct dirty writes in `src/AppWindow.zig`, where the flags are still owned;
- string literals inside guard tests and historical docs.

The guard can source-scan the runtime portion of `src/input.zig`, beginning at `fn applyInputEffect` and ending before `// --- Maximize toggle (native window) ---`. That range covers helpers, mouse paths, wheel paths, selection paths, and permission toggles while avoiding the top-of-file tests that intentionally set and assert AppWindow globals.

## Testing Strategy

Per implementation slice:

- Run `zig build test`.
- Run a focused source scan confirming the converted slice no longer contains direct dirty writes.
- Keep `test-full` for the final gate unless a failure needs the full app binary.

Final gate:

- `zig build test`
- `zig build test-full`
- `git diff --check`
- tracked-file Windows checkout-safety because guard/source files may change
- Optional macOS E2E after the user has time to run it, as in earlier P3 phases

## Acceptance Criteria

- `src/input.zig` has no runtime direct assignments to `AppWindow.g_force_rebuild` or `AppWindow.g_cells_valid` outside test setup/restoration.
- `src/input/dirty_guard.zig` fails in `zig build test` if a runtime direct dirty assignment is reintroduced.
- Rebuild-only paths remain rebuild-only.
- The current `mouse_wheel_scroll.repaintFlagsForViewportScroll` dirty-request behavior is preserved without direct AppWindow flag writes.
- No keyboard shortcut behavior or visible shortcut text changes.
- `zig build test` passes after each task.
- `zig build test-full` passes at the final gate.
- The final spec records updated line counts, `AppWindow.` reference count, and remaining dirty-write status.

## Risks

- `handleMouseButton` has many early returns and nested UI branches. A careless conversion can move repaint before or after a return and change behavior.
- Some rebuild-only sites intentionally leave cells valid. Upgrading them to full repaint would be safe visually but would weaken the semantics P3.2 introduced.
- Terminal mouse reporting must remain untouched; those paths may send bytes to PTY and should not be folded into local UI dirtying.
- `mouse_wheel_scroll.repaintFlagsForViewportScroll` currently returns one repaint-request combination. Treating model results as unconditional repaint would hide potential future model regressions.

## Recommended Next Step

Write a P3.3 implementation plan for the full input dirty-boundary sweep. Keep each task small and commit after each conversion slice. The first task should add exact-flag helper coverage, then convert small helpers before touching `handleMouseButton`.
