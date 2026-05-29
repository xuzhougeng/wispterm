# Architecture: the core ↔ host surface API

WispTerm is split into a platform-agnostic **core** and a per-platform **host**.
This document names that seam as an explicit contract so it stays a deliberate
boundary rather than an implicit convention. It is the reference for the
portability work tracked in [`TODO.md`](../TODO.md).

WispTerm follows Ghostty's core/host split: Ghostty keeps terminal behavior in a
platform-agnostic core and drives it from native hosts (AppKit on macOS, GTK on
Linux) that own their own event loops and supply platform services. WispTerm's
core is the same idea with a Win32 host today and macOS/Linux hosts planned.

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
   - `src/platform/window_backend.zig` — **the host interface** (see below).
   - `src/apprt/win32.zig` — the concrete Win32 host runtime behind the
     `window_backend` facade. A macOS host adds an AppKit runtime here; a Linux
     host adds a GTK (or other toolkit) runtime.

3. **Platform services** — narrow capability interfaces the host/core use for
   OS facilities. Each lives in `src/platform/` as `<cap>.zig` (the interface)
   plus `<cap>_windows.zig` / `<cap>_posix.zig` / `<cap>_unsupported.zig`
   implementations selected at comptime by target OS.

## The host interface (`src/platform/window_backend.zig`)

`window_backend.zig` is the named surface/window contract a host implements. It
exposes an opaque `Window` type and forwards a narrow set of operations to the
backend selected for the target OS (`window_backend_windows.zig` today,
`window_backend_unsupported.zig` otherwise). A new host implements a
`window_backend_<platform>.zig` whose `Window` satisfies these operation groups:

- **Lifecycle** — `create`, `destroy`, `setEventHandlers`, `showVisible` /
  `showHidden`, `closeRequested` / `clearCloseRequested`.
- **Event loop** — `pollEvents` pumps the OS event loop once; the host owns the
  loop (Win32 message loop today; AppKit/GTK own their own). The core calls
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

## Implementing a new host

To bring up a platform (see Phase 2 in [`TODO.md`](../TODO.md)):

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
