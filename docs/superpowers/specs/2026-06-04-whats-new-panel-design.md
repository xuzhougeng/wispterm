# What's New panel — design

**Date:** 2026-06-04
**Branch:** `worktree-feat-update-panel`
**Status:** Approved, ready for implementation plan

## Problem

WispTerm already ships per-version release notes (`release-notes/vX.Y.Z.md`, also
used as the GitHub release bodies) and an update checker
(`src/update_check.zig` + `App.zig`) that downloads new builds. But after a user
upgrades and relaunches, nothing inside the app tells them *what changed* in the
version they are now running. We have the raw material; we lack an in-app
surface.

## Goal

After a user upgrades to a new build and launches it, show a "What's New" modal
once that displays that version's release notes. The same modal is reopenable on
demand at any time. Works fully offline.

## Decisions (locked during brainstorming)

1. **Content source:** embed the matching release note into the binary at build
   time (no network). Show **only the current build's** notes — not an
   accumulation of skipped versions. A "View on GitHub" link covers older
   releases.
2. **Trigger:** automatically once on the first launch after the build version
   changes, **and** reopenable on demand from the command center / menu.
3. **Surface:** a centered, scrollable modal overlay (matches the existing
   close-confirm / restore-defaults modal pattern).
4. **Opt-out:** a `whats-new-on-update` config key (default `true`) disables only
   the automatic popup; the on-demand command always works.

### Accepted caveat

The current build (v1.9.0) has no `last-seen-version` persisted yet, so the
**first** upgrade after this feature ships will not auto-popup — the feature
"arms" itself on first run and works from the next upgrade onward. This is
acceptable and is the standard behavior for this class of feature.

## Architecture

The feature decomposes into five well-bounded units, each independently testable.

### 1. Content pipeline (build → binary)

`build.zig` already derives `app_version` from `build.zig.zon` via
`packageVersion(b)`, and threads it into every module as the `app_version` build
option (`app_options.addOption([]const u8, "app_version", app_version)` in
`createAppModuleWithRoot`). We extend that path:

- New helper `readReleaseNotes(b, app_version) []const u8`: reads
  `release-notes/v{app_version}.md` from the build root at configure time
  (e.g. `b.build_root.handle.readFileAlloc`). If the file is missing or unreadable,
  return `""`. **A missing notes file must never fail the build.**
- Add `app_options.addOption([]const u8, "release_notes", notes)` alongside the
  existing `app_version` option in `createAppModuleWithRoot`. The fast/shared
  test option blocks may pass `""` (they only assert `app_version`).
- Do **not** use `@embedFile` — it is a hard compile error on a missing path.
  The build-option string is graceful and reuses the established pattern.

Expose it for app code:

- `src/app_metadata.zig` adds `pub const release_notes = build_options.release_notes;`
  next to the existing `pub const version = build_options.app_version;`.

The notes are a few KB of markdown; a build-option string of that size is fine.

### 2. Upgrade detection + persistence

Reuse the existing UI state file via `src/platform/window_state_codec.zig` (the
pure, std-only codec; `window_state.zig` is its I/O layer).

- Add a `last-seen-version` key to `PersistedState`, stored as a **fixed inline
  buffer** to keep the codec allocation-free and avoid aliasing the parse input:

  ```zig
  pub const version_max_len = 24;
  last_seen_version_buf: [version_max_len]u8 = undefined,
  last_seen_version_len: usize = 0,

  pub fn lastSeenVersion(self: *const PersistedState) []const u8 {
      return self.last_seen_version_buf[0..self.last_seen_version_len];
  }
  ```

  - `parse`: on the `last-seen-version` key, copy up to `version_max_len` bytes of
    the value into the buffer and set the length (truncate, never overflow).
  - `format`: write `last-seen-version = {s}\n` only when the length is non-zero
    (omit when empty, like the optional geometry fields).
  - Add a merge helper `withLastSeenVersion(state, version) PersistedState` for the
    save path (mirrors `mergeGeometry` / `mergeQuakeFrame`), truncating to
    `version_max_len`.

- New **pure** decision function — placed in a small new module so the fast suite
  can test it without pulling in App/platform code, e.g.
  `src/whats_new_gate.zig`:

  ```zig
  pub const Decision = enum { show, suppress };
  pub fn whatsNewDecision(last_seen: []const u8, current: []const u8, notes_present: bool) Decision
  ```

  Rules:
  - `last_seen.len == 0` → `suppress` (fresh install or pre-feature upgrade).
  - `!notes_present` → `suppress`.
  - `update_check.compareVersions(last_seen, current) == .newer` → `show`
    (i.e. `current` is newer than `last_seen`).
  - any other order (`equal`, `older`, `unknown`) → `suppress`.

  Reuse `update_check.compareVersions` rather than re-parsing semver.

### 3. Startup wiring (in `App.zig`)

After the persisted state is loaded at startup (alongside the existing
window-state / `ai-setup-prompted` handling):

1. `const current = app_metadata.version;`
2. `const last_seen = state.lastSeenVersion();`
3. `const notes_present = app_metadata.release_notes.len > 0;`
4. If `cfg.@"whats-new-on-update"` is true and
   `whatsNewDecision(last_seen, current, notes_present) == .show`, trigger the
   modal (see §4).
5. **Always** persist `last-seen-version = current` back to the state file (via the
   merge helper + existing save path), so the popup shows at most once per
   upgrade regardless of the toggle.

The toggle gates only step 4's auto-popup; step 5 (recording the seen version)
runs unconditionally so toggling the option off does not cause a stale popup
later.

### 4. The modal (display)

Follows the existing modal/overlay pattern in `src/renderer/overlays.zig` (the
close-confirm / restore-defaults modals and the `update_prompt` toast are the
references).

- New pure model `src/renderer/overlays/whats_new_model.zig` (mirrors
  `overlays/update_prompt_model.zig`). Given the raw notes plus viewport metrics
  (cell size, framebuffer width/height, current scroll offset), it produces:
  - wrapped, styled display lines built with the existing
    `src/markdown_text.zig` helpers (`cleanedLine`, `LineStyle`, heading/list
    parsing) — headings emphasized, list bullets indented, links flattened to
    their text;
  - the clamped scroll range (so PageDown/End cannot scroll past the end);
  - the title string and the two button hit-rects + their actions.
  - Button action enum: `{ none, view_on_github, close }`.
- `overlays.zig` gains `renderWhatsNew(...)` (drawing) and the input handling:
  - mouse wheel, PageUp/PageDown, Home/End → scroll;
  - Esc / Enter / clicking **Close** → dismiss;
  - clicking **View on GitHub** → open
    `https://github.com/xuzhougeng/wispterm/releases/tag/v{version}` via the
    existing release-open path (`openLatestRelease` is the analog).
  - Title: `What's New in WispTerm v{version}`.
- The modal stores its own visibility + scroll-offset state in `overlays.zig`
  threadlocals (same style as `g_update_prompt_*`). An `App`/`AppWindow` method
  `showWhatsNew()` opens it; both the startup gate (§3) and the on-demand command
  (§5) call it.

### 5. On-demand entry point

- Add a "What's New" command to the command center (`src/command_center_state.zig`
  + wherever command actions are dispatched in `overlays.zig`, near
  `check_for_updates` / `open_latest_release`).
- Add the corresponding macOS menu item (`src/platform/menu_macos_bridge.m` /
  `menu` wiring), near the existing "Check for Updates".
- Both invoke `showWhatsNew()` and render the same modal from the embedded notes,
  independent of the upgrade gate and the config toggle.

### 6. Config + i18n

- `src/config.zig`: add `@"whats-new-on-update": bool = true` and thread it into
  the `App` cached config (`App.zig` `updateConfig` + init), mirroring
  `@"auto-update-check"`.
- `src/i18n.zig`: add catalog entries (en + zh-CN) for the modal title, the two
  button labels, and the command-center / menu label for "What's New".

## Data flow

```
build.zig  read release-notes/v1.9.0.md ──► build_options.release_notes ──► app_metadata.release_notes
                                                                                      │
launch ─► load state (window_state) ─► PersistedState.lastSeenVersion()              │
            │                                   │                                     │
            ▼                                   ▼                                     ▼
   cfg.whats-new-on-update?            whatsNewDecision(last_seen, current, notes_present)
            └────────────── both true & .show ──────────► App.showWhatsNew()
                                                                  │
                                          overlays.renderWhatsNew (whats_new_model)
                                                                  │
                            [View on GitHub] → open releases/tag/vX   [Close]/Esc → dismiss

  unconditionally: save state with last-seen-version = current
  on-demand: Command Center / menu "What's New" ─────────────► App.showWhatsNew()
```

## Error / edge handling

- **Missing notes at build time** → `release_notes == ""` → `notes_present` false
  → gate suppresses; on-demand command shows an empty-state ("Release notes
  unavailable" line) rather than an empty box. Build still succeeds.
- **Fresh install** (`last_seen` empty) → suppress popup, record current version.
- **Downgrade / same version** → suppress.
- **Malformed `last_seen`** (`compareVersions` returns `.unknown`) → suppress (safe
  default).
- **Oversized version string in state file** → truncated to `version_max_len` on
  parse; comparison may become `.unknown` → suppress (never overflows, never
  crashes).
- **Notes longer than the viewport** → scroll clamp keeps the view in range;
  content never renders past the modal bounds.

## Testing (fast suite unless noted)

- `whats_new_gate`: `whatsNewDecision` — fresh-install suppress, upgrade show,
  same-version suppress, downgrade suppress, empty-notes suppress, malformed
  `last_seen` suppress.
- `window_state_codec`: `last-seen-version` round-trips through `format`/`parse`;
  an old state file without the key leaves it empty; an over-length value is
  truncated; the key is omitted from `format` output when empty.
- `whats_new_model`: line wrapping of representative markdown; scroll clamp at top
  and bottom; button-action selection for clicks on each button and on empty
  space.
- Build-option presence is already covered for `app_version` in
  `shared_compile_test.zig`; extend or mirror it to assert `release_notes` is a
  valid (possibly empty) string.

## Out of scope (YAGNI)

- Accumulating notes across multiple skipped versions.
- Fetching notes over the network / embed+fetch fallback.
- A dedicated "What's New" tab or reusing the right-side markdown preview panel.
- Rich markdown features beyond what `markdown_text.zig` already renders (tables
  are rendered as-is via the existing helpers; no new markdown features added).

## Files touched (anticipated)

- `build.zig` — `readReleaseNotes` + `release_notes` build option.
- `src/app_metadata.zig` — expose `release_notes`.
- `src/platform/window_state_codec.zig` — `last-seen-version` field + merge helper
  + tests.
- `src/platform/window_state.zig` — save/load the new field (I/O layer).
- `src/whats_new_gate.zig` (new) — pure decision function + tests.
- `src/renderer/overlays/whats_new_model.zig` (new) — pure layout/model + tests.
- `src/renderer/overlays.zig` — `renderWhatsNew` + input + command dispatch.
- `src/App.zig` / `src/AppWindow.zig` — startup gate, `showWhatsNew()`, config
  cache, persist last-seen-version.
- `src/config.zig` — `whats-new-on-update` key.
- `src/command_center_state.zig` — "What's New" command.
- `src/platform/menu_macos_bridge.m` (+ menu wiring) — menu item.
- `src/i18n.zig` — en + zh-CN strings.
- `src/test_fast.zig` / `src/test_main.zig` — register new test modules.
```
