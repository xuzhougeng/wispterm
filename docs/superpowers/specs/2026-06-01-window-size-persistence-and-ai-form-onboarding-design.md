# Window size persistence + AI-agent form first-launch-only — Design

Date: 2026-06-01

## Problem

Two startup annoyances reported by the user:

1. **Window size is not remembered.** Every relaunch the window resets to a fixed
   small grid that, on a 27"+ display, reads as a wide, short strip pinned to the
   top of the screen. Today only the window *position* (`window-x`/`window-y`) is
   persisted; the size is always forced to an 80×24 cell grid on launch.

2. **AI-agent setup form pops up on every launch.** When no AI profile is saved,
   the startup path auto-opens the profile-creation form *every* time the app
   starts (every launch is a new process), not just the first time.

## Current behavior (code references)

- The window is created at a hardcoded `800×600`
  (`src/AppWindow.zig:3624`), then unconditionally resized to fit a
  `term_cols × term_rows` cell grid (`src/AppWindow.zig:3862-3877`). `term_cols`
  / `term_rows` default to 80/24 (`src/AppWindow.zig:1322-1323`, fed from
  `App.initial_cols`/`initial_rows` which map `window-width`/`window-height`
  config to 80/24 when unset — `src/App.zig:202-203`).
- Window position only is persisted in the state file
  (`src/platform/window_state.zig`): loaded at `src/AppWindow.zig:3618`, saved at
  `src/AppWindow.zig:4286`/`4289` (gated on not maximized/fullscreen).
- `spawnDefaultAgentAndLocalShellTabs` (`src/AppWindow.zig:1039-1067`) opens the
  default local-shell + agent tabs for a plain first window. When there is no AI
  profile (`!has_ai_profile`) it calls `overlays.openDefaultAgentSessionForStartup()`
  (`src/AppWindow.zig:1062-1064`), which opens the profile-creation form
  (`src/renderer/overlays.zig:2349-2356`). This branch runs on every plain launch.

### Unit semantics (verified)

- `window_backend.resizeClientArea(w, width, height)` and
  `window_backend.framebufferSize(w)` are **both in framebuffer (physical)
  pixels** and round-trip exactly. On macOS, `wispterm_macos_window_set_content_size`
  divides the requested framebuffer px by the backing scale before calling
  `-setContentSize:` (`src/platform/window_macos_bridge.m:1292-1310`), and
  `get_framebuffer_size` returns `bounds × scale` (`:1274-1290`). The existing
  grid-fit path already feeds framebuffer px into `resizeClientArea` and reads it
  back via `framebufferSize`, so framebuffer px is the canonical, self-consistent
  unit.
- `window_backend.windowRect(w)` returns the outer window frame (used today only
  for the saved x/y origin); we keep using it for position and leave position
  handling unchanged.

## Feature 1 — Remember last window size

### Storage

Extend the state file (owned by `src/platform/window_state.zig`) to also persist
`window-width` and `window-height` in **framebuffer pixels**. The file format
stays `key = value` lines; old files that only contain `window-x`/`window-y`
remain valid (missing width/height ⇒ "no saved size").

### Save (on close)

At `src/AppWindow.zig:~4281`, in addition to x/y, capture the current framebuffer
size via `window_backend.framebufferSize(w)` and persist width/height. Same gate
as position: only persist the windowed size when **not** maximized and **not**
fullscreen, so a maximized/fullscreen session does not overwrite the remembered
windowed size. (When maximized/fullscreen, persist the last known windowed size —
mirroring how position already persists `g_windowed_x/y`. If no windowed size was
captured this session, leave the previously saved width/height untouched.)

### Restore (startup)

New precedence for the initial window sizing block (`src/AppWindow.zig:3862`):

1. **Quake mode** → quake frame (unchanged).
2. **Explicit config** `window-width`/`window-height` (> 0) → size to that cell
   grid (unchanged existing behavior; the user's opt-in fixed size still wins).
3. **Saved size present & valid** → `window_backend.resizeClientArea(w, saved_w,
   saved_h)` instead of the 80×24 grid-fit. ← the fix
4. **Neither** → current 80×24 grid-fit default (only the very first launch).

Detecting case 2 requires knowing whether the config size was explicitly set.
Add `App.window_size_from_config: bool`, computed as
`cfg.@"window-width" > 0 or cfg.@"window-height" > 0` at both App construction
(`src/App.zig:~202`) and reconfigure (`src/App.zig:~373`), and read in
`AppWindow` to choose branch 2 vs 3.

### Validation / clamp

Before applying a saved size:
- Reject degenerate sizes (`width < 200` or `height < 150` ⇒ treat as "no saved
  size", fall through to default).
- Clamp width/height to the target monitor's work area (reuse
  `nearestMonitorWorkArea` / equivalent already used for position validation) so a
  smaller or different monitor cannot restore an oversized or effectively
  off-screen window.

### Rationale: framebuffer px vs logical points

Framebuffer px round-trips **exactly** on the same display with zero DPI
arithmetic. This is deliberately robust against the known DPI-read quirks
(#46/#90): a wrong DPI reading cannot compound the saved size across launches.
The trade-off — restoring onto a *different-DPI* monitor yields a perceptually
different size — is bounded by the work-area clamp and self-corrects on the first
manual resize. Logical-points storage was considered and rejected for adding DPI
dependence to a value that is saved and restored repeatedly.

## Feature 2 — AI-agent form only on first launch

### Storage

Add an `ai-setup-prompted` boolean to the same state file. To avoid the
geometry-save and flag-save clobbering each other (the writer truncates and
rewrites the whole file), generalize `window_state.zig` to load/save the file as
a single struct holding `{ x, y, width, height, ai_setup_prompted }`, and perform
partial updates as read-modify-write (load current file, mutate one field, write
all fields back). Missing keys parse to their defaults so old files upgrade
cleanly.

### Behavior

In `spawnDefaultAgentAndLocalShellTabs` (`src/AppWindow.zig:1062-1064`), gate the
form auto-open on `!ai_setup_prompted`:

- If no AI profile **and** not yet prompted → open the form (as today) **and**
  persist `ai-setup-prompted = true`.
- If no AI profile **and** already prompted → skip the form; the local-shell +
  fallback-shell tabs still open exactly as today.

The "should auto-show the startup form" decision is extracted into a small pure
helper in `src/startup_tabs.zig` (input: `has_ai_profile`, `already_prompted`;
output: bool) so it is unit-testable without the GUI, next to the existing
`initialTabPlan` startup-decision helper.

Setting up an AI agent later remains available anytime via the session launcher →
AI agent entry; only the *automatic* popup is suppressed after the first launch.

## Components touched

- `src/platform/window_state.zig` — generalize struct + load/save to include
  width, height, ai_setup_prompted; add validation helpers; add read-modify-write
  partial updaters.
- `src/App.zig` — add `window_size_from_config` field (construct + reconfigure).
- `src/AppWindow.zig` — restore saved size (new precedence branch), save size on
  close, gate the startup AI form on the persisted flag, persist the flag on first
  show.
- `src/startup_tabs.zig` — new pure helper "should auto-show startup AI form"
  decision, unit-tested.

## Testing

- `window_state.zig` unit tests (fast suite): round-trip of width/height/flag;
  backward-compat parse of an old `window-x`/`window-y`-only file; degenerate-size
  rejection; partial-update read-modify-write preserves other fields.
- Pure-helper unit test for the form-auto-show decision (4 cases of
  profile×prompted).
- `App.window_size_from_config` derivation covered where App config tests live (or
  a focused test).
- GUI verification on macOS/Windows is the user's (no Linux GUI backend): relaunch
  remembers size; explicit `window-width`/`window-height` config still overrides;
  AI form shows once then never auto-pops.

## Out of scope (YAGNI)

- No config option to toggle the AI-form behavior (chosen: persistent
  first-launch-only flag).
- No DPI-aware logical-size storage / per-monitor remembered sizes.
- No change to maximize/fullscreen restore beyond preserving the windowed size.
