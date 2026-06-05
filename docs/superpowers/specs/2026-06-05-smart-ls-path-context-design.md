# Smart `ls` Path Context for Ctrl+Click — Design

**Date:** 2026-06-05
**Status:** Approved (design), pending implementation plan
**Branch:** `feat-smarter-path`

## Problem

When the user runs `ls <dir>/` (e.g. `ls Ath/Ph_SE/`), the output is a flat list of
**bare filenames** — the directory prefix lives only on the command line above, not in
the listing. Ctrl+clicking `cluster_resolution_summary.tsv` to preview it currently
resolves the token relative to the shell's CWD (`$CWD/cluster_resolution_summary.tsv`),
which does not exist. The real file is `$CWD/Ath/Ph_SE/cluster_resolution_summary.tsv`.

Today's resolver (`resolveTerminalPreviewPath`, `src/input/preview_source.zig:164`) only
looks at the clicked token text plus CWD. It ignores all surrounding terminal context, so
bare-filename clicks from `ls <dir>/` output fail to open.

## Goal

Make ctrl+click "context-aware" for the **`ls` family only**: when the clicked token is a
bare filename, infer the directory prefix from the nearest preceding `ls <dir>/` command
line and prepend it before the existing CWD-relative resolution runs.

### Explicitly out of scope

- **`tree`** — its output is hierarchical/indented; a bare filename is not a complete
  path, and correct resolution would require parsing box-drawing indentation. Deliberately
  excluded (would be a separate, more fragile feature).
- **`find <dir>`** — its output is already a complete relative path
  (`Ath/Ph_SE/file.tsv`), which the existing CWD-join already resolves correctly. Nothing
  to build.

## Approach

A small pure parsing layer + an upward viewport scan + a single wiring point. No OSC 133
shell integration exists in this codebase, so command-line detection is heuristic; the
grid is readable row-by-row (`readViewportRowLocked` / `TerminalTokenGrid`), which is
sufficient.

### Component 1 — Pure parsing (unit-testable)

New pure module under `src/input/` (e.g. `ls_path_context.zig`), no terminal dependency.

**`parseLsDirArg(line: []const u8) ?[]const u8`**
Given one line of text, decide whether it is an `ls`-family command with exactly one
directory argument; if so, return that directory prefix (a slice into `line`).

Rules:
- The command name must be one of `ls` / `ll` / `la` / `l` / `dir`, matched as a standalone
  token (so `lsblk`, `false`, a path containing `ls` do not match). The command token may
  be preceded by an arbitrary prompt prefix (we scan for the token boundary rather than
  assuming column 0).
- Skip `-`-prefixed flags (e.g. `-l`, `-la`, `--color=auto`).
- Of the remaining non-flag arguments, require **exactly one**, and it must **end with `/`**
  (e.g. `Ath/Ph_SE/`). Return it.
- Return `null` for: zero args (`ls` of CWD), multiple non-flag args (`ls A/ B/` —
  ambiguous), or a sole argument not ending in `/`. We do not guess in ambiguous cases.

**`inferPrefixForClick(grid, click_row) ?[]const u8`**
Scan **upward** from `click_row` (bounded to the visible viewport), reading each row's text
and calling `parseLsDirArg`. Return the **nearest** matching directory; return `null` if the
top of the viewport is reached without a match. Accepts a row-reader interface (the same
shape as `TerminalTokenGrid`) so it can be unit-tested with a fake grid.

### Component 2 — Wiring

In `resolveTerminalPreviewPath` (`src/input/preview_source.zig:164`), before the existing
per-launch-kind resolution, insert a prefix **only when both** hold:
1. The clicked token is a **bare filename** — contains no `/`, is not absolute, is not
   `~`-rooted. (Already-pathed tokens are left untouched.)
2. `inferPrefixForClick` returns a prefix.

On a hit: `bare_name` → `prefix ++ bare_name`, then the existing logic joins with CWD per
`launch_kind`. This works uniformly for `local`, `wsl`, and `ssh` because it is plain
string prefixing applied before the unchanged per-kind join.

`resolveTerminalPreviewPath` will need access to the click row and a row-reader for the
scan; these come from the same `surface` + `render_state` grid the token extraction already
uses (under the existing `render_state.mutex`).

## Behavior & boundaries (accepted trade-offs)

- **No existence check.** Best-effort. A wrong guess fails gracefully exactly as today
  (`Preview failed`). Avoids `stat` / remote round-trips for WSL/SSH.
- **Viewport-only scan.** If the `ls` command has scrolled off the top, we fall back to the
  current CWD-relative behavior. The common "ran `ls dir/`, then clicked a result" case has
  the command on screen.
- **Heuristic command detection (no OSC 133).** If an intervening command's prompt line is
  not recognized, the upward scan could skip past it to an earlier `ls`. This is a known
  low-probability misfire accepted for v1; a future "stop at the first prompt-looking line"
  convergence can tighten it if needed.

## Affected call sites

Both ctrl+click preview (`openPreviewPanelForCell`) and SSH download
(`downloadTerminalFileAtCell`) route through `resolveTerminalPreviewPath`, so both benefit
automatically from the same change.

## Testing

- Unit tests for `parseLsDirArg`: ls/ll/la/l/dir hits with trailing-`/` arg; flag skipping;
  rejection of zero args, multiple args, non-`/` arg, and non-ls command names
  (`lsblk`, paths containing `ls`).
- Unit tests for `inferPrefixForClick` against a fake grid: nearest-match selection,
  no-match returns null, bounded scan to viewport top.
- A resolver-level test confirming bare-name + inferred prefix joins correctly, and that
  absolute/`~`/slash-containing tokens are left untouched.

## Files

- New: `src/input/ls_path_context.zig` (pure: `parseLsDirArg`, `inferPrefixForClick`).
- Edit: `src/input/preview_source.zig` (wire into `resolveTerminalPreviewPath`).
- Test registration in the appropriate test aggregator so the new tests actually run.
