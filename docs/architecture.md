# Architecture: the core ↔ host surface API

WispTerm is split into a platform-agnostic **core** and a per-platform **host**.
This document names that seam as an explicit contract so it stays a deliberate
boundary rather than an implicit convention. It is the reference for the
portability work tracked in [`ROADMAP.md`](../ROADMAP.md) and current platform
limitations tracked in [`KNOWN_ISSUES.md`](../KNOWN_ISSUES.md).

WispTerm follows Ghostty's core/host split: Ghostty keeps terminal behavior in a
platform-agnostic core and drives it from native hosts (AppKit on macOS, GTK on
Linux) that own their own event loops and supply platform services. WispTerm's
core follows the same idea with a primary Win32 host, an AppKit macOS host, and
an experimental Linux host.

## The three layers

1. **Core** — terminal state, IO, and rendering. It never imports a platform
   runtime; it only talks to the OS through the platform-service interfaces in
   `src/platform/`.
   - `src/Surface.zig` — per-terminal surface state and PTY integration.
   - `src/termio/` — PTY read/write threads and the terminal IO mailbox.
   - `src/renderer/` — GPU-backend-agnostic cell rendering, overlays, titlebar.
   - `libghostty-vt` (vendored) — the VT parser and terminal state machine.

2. **Host** — owns the OS window and event loop and pumps the core. There is one
   host per platform. The host is the *only* layer allowed to talk to a concrete
   platform runtime.
   - `src/AppWindow.zig` — window-level tabs, splits, and the render/input
     routing that drives surfaces. Platform-neutral; calls the host interface.
     It is an **integration layer** (see below), not terminal core: it
     coordinates features but must not own their state. Its orchestration is
     being decomposed into `src/appwindow/*` (aggregated state structs, the
     `UiEffect` invalidation boundary, and feature bridges) — see the
     structural-debt governance in
     [docs/decoupling-guide.md §8](decoupling-guide.md#8-structural-debt-governance-axis-b-in-practice).
   - `src/platform/window_backend.zig` — **the host interface** (see below).
   - `src/apprt/win32.zig` — the concrete Win32 host runtime behind the
     `window_backend` facade. The macOS host uses AppKit, and the experimental
     Linux host uses SDL3.

3. **Platform services** — narrow capability interfaces the host/core use for
   OS facilities. Each lives in `src/platform/` as `<cap>.zig` (the interface)
   plus `<cap>_windows.zig` / `<cap>_posix.zig` / `<cap>_unsupported.zig`
   implementations selected at comptime by target OS.

## The host interface (`src/platform/window_backend.zig`)

`window_backend.zig` is the named surface/window contract a host implements. It
exposes an opaque `Window` type and forwards a narrow set of operations to the
backend selected for the target OS (`window_backend_windows.zig`,
`window_backend_macos.zig`, or `window_backend_linux.zig` where available, with
unsupported stubs only for missing capabilities). A new host implements a
`window_backend_<platform>.zig` whose `Window` satisfies these operation groups:

- **Lifecycle** — `create`, `destroy`, `setEventHandlers`, `showVisible` /
  `showHidden`, `closeRequested` / `clearCloseRequested`.
- **Event loop** — `pollEvents` pumps the OS event loop once; the host owns the
  loop (Win32 message loop, AppKit run loop, SDL3 event pump). The core calls
  `pollEvents` each frame and drains the input queue.
- **Input event queue** — `popKeyEvent`, `popCharEvent`, `popMouseButtonEvent`,
  and related drains return platform-neutral events typed by
  `src/platform/input_events.zig` (backend-neutral `key_*` codes, not raw OS
  keycodes). IME composition goes through `setImeCaret` / `imePreeditText`.
- **Rendering surface** — `swapBuffers`, `framebufferSize`, `clientSize`. The
  GPU backend (OpenGL on Windows, Metal on macOS, OpenGL/Vulkan on Linux) is
  selected behind the renderer and wired to this surface.
- **Window state** — DPI/content scale (`dpi`, `effectiveDpi`,
  `consumeDpiChanged`), geometry (`clientRect`, `windowRect`,
  `nearestMonitorWorkArea`, `setOuterFrame`), and chrome state (fullscreen,
  maximize, minimize, focus, titlebar/sidebar metrics, caption buttons).

App logic calls only the `window_backend` facade — never a concrete runtime —
so the host can be swapped per platform without touching `AppWindow.zig`.

## Platform-service capabilities

Each capability is an interface module the host backs with a per-OS impl. The
current set (interface = `src/platform/<name>.zig`):

- **Windowing / input**: `window_backend`, `window`, `window_state`, `cursor`,
  `display`, `global_hotkey`, `input_events`.
- **Process / terminal IO**: `pty`, `pty_command` (launch command building),
  `process` (local-shell fallback), `wsl` (host/guest path adapter).
- **Files / paths / dialogs**: `file_dialog`, `dirs` (config/theme/data dirs),
  `local_path` (native path rules), `atomic_file` (replace-safe writes),
  `remote_file`, `editor`.
- **System integration**: `clipboard`, `open_url`, `notifications` (bell +
  window attention), `session_lock` (single instance), `text` (locale-aware
  compare), `threading` (thread spawn policy), `memory` (process stats),
  `console` (parent console), `com` (COM init).
- **Fonts**: `font_backend` (discovery + fallback).
- **Networking / web / updates**: `remote_transport` (HTTP transport),
  `webview` (embedded browser), `update_package` (release packaging),
  `agent_prompt` (per-OS AI agent system prompt).

## Contract invariants

These rules keep the boundary from being quietly re-broken. Most are enforced by
comptime guards, so a violation fails the build or `zig build test`:

- **The core never imports a platform runtime.** It uses `src/platform/`
  facades only. Shared/test modules do not embed a platform runtime either —
  the Win32 API-surface checks live in `src/platform/apprt_win32_guard.zig`, not
  in `test_main.zig`.
- **Facade names describe platform roles, not backend details.** A facade may
  not name `win32` / `directwrite` / `webview2` / `winhttp` etc., nor expose raw
  OS handles. `src/test_main.zig` scans the facades to enforce this.
- **`build.zig` exposes artifact capabilities, not target-OS booleans or
  Windows-specific names** to app modules. The guard patterns live in
  `src/build_guards.zig` (`firstLeak`) and are unit-tested; `build.zig` runs
  them over its own source at comptime.
- **Shared input/keybind code uses neutral `key_*` codes**, never Win32 `VK_`
  names. App modules describe platform-neutral events, not Win32 messages.

Scope note: these platform-leakage checks apply to the desktop app, build, and
shared Zig code. The `remote/` web console and packaged `plugins/` content are
out of scope.

## Internal-architecture invariants

Beyond the platform seam, a second set of invariants keeps the core itself
maintainable. **Cohesion and coupling — not file length — are the criteria**: a
file should own one coherent responsibility with explicit state ownership. Large
files are acceptable when they stay cohesive (Ghostty ships 10k–15k-line core
files that do); the smell is tangled responsibility, not size. These are
enforced by source-scan ratchet tests in `src/source_guards/` that freeze
today's structural debt so it can only **shrink**:

- **`file_size_guard`** — no `src/**/*.zig` over 10,000 lines (a runaway
  backstop; also `zig build check-sizes`).
- **`global_state_guard`** — the top-level `g_*` / `threadlocal` count in
  `AppWindow.zig` / `input.zig` / `renderer/overlays.zig` / `ai_chat.zig` may
  only shrink; new state belongs in an explicit state struct.
- **`import_hub_guard`** — `AppWindow.zig`'s `pub const X = @import(...)`
  re-export count may only shrink; import the real module directly, not via
  `AppWindow.X`.
- **`side_effect_guard`** — direct `g_force_rebuild` / `g_cells_valid` writes in
  those files may only shrink; route UI invalidation through the `UiEffect`
  boundary (`AppWindow.applyUiEffect`).

Because `test-full` is a superset of `test`, these gate the pre-merge build. The
cohesion criterion, the remediation roadmap, and the layer model live in
[docs/decoupling-guide.md §8](decoupling-guide.md#8-structural-debt-governance-axis-b-in-practice);
the contributor-facing summary is in [`AGENTS.md`](../AGENTS.md).

## Integration layer vs feature domains

A second boundary cuts *across* the core, orthogonal to the platform seam: the
distinction between the **integration layer** that coordinates features and the
**feature domains** that own them. The four monoliths above sit on the wrong
side of it today, which is why they carry the ratchets.

- **Integration layer** — `src/AppWindow.zig`, `src/input.zig`, and
  `src/renderer/overlays.zig`. These *coordinate*: AppWindow assembles modules
  and routes render/input, `input.zig` dispatches keyboard/mouse events to
  whoever should handle them, and `overlays.zig` is the overlay facade/registry.
  They are **not** the terminal "core" and must **not own feature state**. When
  they hold a feature's `g_*` globals or reach into a feature's internals, that
  is the entanglement the ratchets are freezing — not a property of being a host.

- **Feature domains** — each owns its own state, query/action API, and tests:
  `ai_chat*` (agent/session/tools/streaming), `weixin/*`, the `skill_*` modules,
  `file_explorer.zig`, the `tmux_*` controllers, and the `remote_*` client/sync
  code. A domain is responsible for its own behavior; the integration layer only
  wires it in and asks it to do things.

Guidance for new code (these keep the boundary from re-tangling):

- **Feature domains should not depend on `AppWindow`.** They expose their own
  API and receive what they need explicitly; they do not reach back through the
  window for context.
- **`input.zig` only dispatches.** It decides *who* handles an event and returns
  a `UiEffect`; it must not read a feature's internal `g_*` state to make that
  decision.
- **Overlays get capabilities through a Host/Context**, not by importing
  `AppWindow.zig` (only narrow types such as `appwindow/ui_effect.zig`).
- Prefer **explicit context structs**, **feature-owned query/action APIs**, and
  **`UiEffect` returns** over scattered globals and direct dirty writes.
- **Each time you touch a monolith, lower the matching source-guard ratchet**
  (`global_state_guard` / `import_hub_guard` / `side_effect_guard`) — moving one
  case to the right pattern is how the boundary actually converges. The layer
  model that names these reverse edges is
  [docs/decoupling-guide.md §8.5](decoupling-guide.md#85-the-layer-model).

## Implementing a new host

To bring up a platform (see [`ROADMAP.md`](../ROADMAP.md)):

1. Add the native host runtime under `src/apprt/` and a
   `window_backend_<platform>.zig` that satisfies the host interface above
   (window, event loop ownership, input routing, IME, DPI).
2. Implement the platform-service impls behind the existing facades
   (`<cap>_posix.zig` or a new `<cap>_<platform>.zig`): PTY/process, fonts,
   clipboard, file dialogs, notifications, config/theme dirs, etc.
3. Wire the renderer's GPU backend to the host's surface (Metal on macOS;
   OpenGL or Vulkan on Linux).
4. Flip the build target's feature gates in `build.zig` once the host backend is
   real, keeping Windows as the default development target.
