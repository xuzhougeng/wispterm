# File-preview enhancements: `.r`/`.R` preview + ctrl+right-click open-in-editor

Date: 2026-06-05
Branch: `worktree-feat-file-preview-enhance`

## Summary

Two small, composable improvements to the terminal-text file interactions:

1. **ctrl+left-click previews `.r`/`.R` scripts** — R scripts render in the
   existing in-app preview panel as plain text, the same way `.py`/`.zig` do.
2. **ctrl+right-click opens the file under the cursor in the OS default app** —
   local terminals only; falls through to the configured right-click action
   when it does not apply.

Both reuse existing machinery. No new config keys.

## Background

Today, clicking terminal text uses the "primary open" modifier
(`primaryOpenMod` = Cmd on macOS, Ctrl elsewhere):

- **ctrl+left-click** runs `open_url_or_preview`: try open URL → open HTML in the
  webview panel → open the in-app preview panel (`openPreviewPanelForCell`). The
  preview kind comes from `markdown_preview.detectKind`, whose text-file suffix
  list is `.txt .text .rs .c .h .cpp .zig .py .js .ts .json .yaml .toml .sh`.
  **`.r`/`.R` is absent**, so R scripts are not recognized as previewable text
  and a bare `model.R` token does not even hover-underline.
- **right-click** (`handleConfiguredRightClick`) runs the configured
  `right-click-action` (`ignore`/`copy`/`paste`/`copy-or-paste`). There is no
  modifier-aware branch.

Relevant existing pieces we reuse:

- `markdown_preview.detectKind` + `text_file_suffixes` (`src/markdown_preview.zig`).
- `preview_path.looksLikePreviewPath` (drives hover-underline + token extraction).
- `terminal_link_action.terminalPathClickAction` / `primaryOpenMod` (pure click
  rules, `src/input/terminal_link_action.zig`).
- `extractPreviewPathAtCell` + `resolveTerminalPreviewPath` (`src/input.zig` /
  `src/input/preview_source.zig`) — extract the path token under the cursor and
  resolve it to an absolute path relative to the shell cwd.
- `platform_open_url.open(allocator, .{ .url = path })` — default
  `.kind = .unknown` opens a path with the **OS default app** per platform:
  Linux `xdg-open <path>`, macOS `open <path>`, Windows
  `ShellExecuteW("open", <path>)`. Already imported in `input.zig`.

## Part 1 — ctrl+left-click previews `.r`/`.R`

### Change

Add `".r"` to `text_file_suffixes` in `src/markdown_preview.zig`. Detection is
case-insensitive (`endsWithIgnoreCase`), so a single `".r"` entry covers both
`.r` and `.R`.

### Resulting behavior (all automatic from `detectKind`)

- `detectKind("model.R") == .text` → ctrl+left-click opens the in-app preview
  panel and renders the file as plain text (identical path to `.py`/`.zig`).
- `looksLikePreviewPath("model.R")` becomes true (via `detectKind != null`), so:
  - ctrl-hover underlines a bare `model.R` token (no `/` required), and
  - the token is extractable by `extractPreviewPathAtCell`, which also enables
    Part 2 for `.R` files.

### Scope

Only `.r`/`.R`. Not `.Rmd`, `.Rds`, or other R-ecosystem extensions.

## Part 2 — ctrl+right-click opens file under cursor in OS default app (local only)

### Modifier

Use the existing `primaryOpenMod(ctrl, super)` convention:
**Ctrl+right-click** on Windows/Linux, **Cmd+right-click** on macOS. This matches
the left-click preview modifier and avoids the macOS Ctrl-click = secondary-click
conflict.

### Pure decision (`src/input/terminal_link_action.zig`)

New predicate, unit-tested in the fast suite:

```zig
pub fn rightClickOpensInEditor(
    launch_kind: platform_pty_command.LaunchKind,
    mod: bool,   // primaryOpenMod result
    shift: bool,
    alt: bool,
) bool {
    return launch_kind == .local and mod and !shift and !alt;
}
```

`.ssh` and `.wsl` return false — a local default app cannot open remote paths,
which is the "only local" rule. (WSL `\\wsl$\...` translation is explicitly out
of scope.)

### Wiring (`src/input.zig`)

In the right-click-release branch (currently
`if (ev.button == .right and ev.action == .release) { handleConfiguredRightClick(); return; }`):

```zig
if (ev.button == .right and ev.action == .release) {
    if (openInEditorAtRightClick(ev)) return;
    handleConfiguredRightClick();
    return;
}
```

`openInEditorAtRightClick(ev)` returns `true` only when it actually launched an
open; otherwise `false` so plain right-click (and non-qualifying ctrl+right-click)
keeps the configured copy/paste behavior. Steps:

1. Resolve the surface at `(ev.x, ev.y)`; if none → `false`.
2. If `!rightClickOpensInEditor(surface.launch_kind, primaryOpenMod(ev.ctrl, ev.super), ev.shift, ev.alt)` → `false`.
3. Compute the cell at the click; extract the path token with
   `extractPreviewPathAtCell` (requires `looksLikePreviewPath`). If none → `false`.
4. Resolve to an absolute local path with `resolveTerminalPreviewPath` (local
   branch joins the token with the shell's current cwd). On error → `false`.
5. `platform_open_url.open(allocator, .{ .url = resolved })`. Best-effort, like
   `openUrl` — no existence pre-check. Return `true`.

### Composition

Because Part 1 makes `.R` a recognized path token, ctrl+right-click on a `.R`
file works without any extra change.

## Out of scope / no change

- No new config key or toggle — ctrl+right-click is always available on local
  terminals; plain right-click is unchanged.
- No right-click hover-underline. Right-click has no hover state; the existing
  ctrl-hover underline already signals that a token is interactive.

## Testing

Fast-suite unit tests:

- `src/markdown_preview.zig`: `detectKind("plot.r") == .text`,
  `detectKind("model.R") == .text`.
- `src/input/preview_path.zig`: `looksLikePreviewPath("model.R")` is true.
- `src/input/terminal_link_action.zig`: truth table for
  `rightClickOpensInEditor` —
  - `.local` + mod + no shift/alt → true
  - `.ssh` + mod → false
  - `.wsl` + mod → false
  - `.local` + no mod → false
  - `.local` + mod + shift → false
  - `.local` + mod + alt → false

Integration glue (the `input.zig` right-click branch + `platform_open_url` call)
follows the existing untested click-handler pattern and is GUI-verified.

## Files touched

- `src/markdown_preview.zig` — add `".r"` to `text_file_suffixes` (+ test).
- `src/input/preview_path.zig` — add `.R` assertion (no code change; covered by
  `detectKind`).
- `src/input/terminal_link_action.zig` — add `rightClickOpensInEditor` + tests.
- `src/input.zig` — right-click branch wiring + `openInEditorAtRightClick` helper.
