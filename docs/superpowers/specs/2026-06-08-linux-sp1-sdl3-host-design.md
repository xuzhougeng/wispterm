# SP1 — SDL3 host bring-up (Linux)

Sub-project 1 of the Linux port roadmap
([2026-06-08-linux-port-design.md](2026-06-08-linux-port-design.md)). Realizes
the host half of the core↔host contract in [architecture.md](../../architecture.md)
for Linux, on top of the completed Phase A (OpenGL spine) and Phase C (POSIX
PTY).

## Goal

A single SDL3 window on **X11** rendering a live terminal through the existing
**OpenGL 3.3 core** backend, with keyboard + mouse input and a shell running
over `pty_posix`. SP1 is the spine and gate for SP2–SP6. When SP1 lands, the
whole GPU-self-drawn UI (tabs, splits, file explorer, AI chat, overlays,
titlebar) renders on Linux for free — what's missing after SP1 is real font
discovery (SP2), the remaining platform services (SP3), and IME (SP4).

## Decisions carried in / resolved here

- **Host = SDL3; X11 first** (from the roadmap).
- **GL = 3.3 core.** The OpenGL backend's shaders are `#version 330 core`
  (`src/renderer/gpu/opengl/shaders.zig`), so the host requests a 3.3 core
  context. SDL replaces the entire Win32 "dummy context →
  `wglCreateContextAttribsARB`" dance (`apprt/win32.zig:996`) with one
  `SDL_GL_CreateContext`.
- **SDL3 linkage:** dev/CI links the **system `libSDL3`** (fast iteration,
  simplest `build.zig`); **distribution bundles SDL3** (AppImage/Flatpak in
  SP6). Rationale: SDL3 is too new to assume present on user distros, and a
  fully-static vendored SDL3 build is heavy; defer a `pkg/sdl` static build
  until/if SP6 needs it.
- **Threading model = mirror macOS, not Win32.** SDL exposes a *single*
  main-thread event queue (events carry a `windowID`), exactly like AppKit and
  unlike Win32's per-thread message queues. So Linux follows the macOS host:
  the main thread owns the pump and routes events to per-window thread-safe
  queues; worker-thread windows marshal window mutations back to the main thread
  (`wispterm_macos_run_on_main` analog). See [Event loop & threading](#event-loop--threading-the-core-design).
- **SP1 scope = the first (main-thread) window, end-to-end.** Multi-window
  (`Ctrl+Shift+N`, worker-thread windows) is where the marshaling complexity
  lives; SP1 includes the **spike** that designs it and implements it only if
  the spike shows it is straightforward — otherwise it splits into a tracked
  follow-on (SP1b) that must land before production ships. SP1's acceptance is
  single-window.

## Structure (mirrors the Windows host)

The Windows host is two files: `window_backend_windows.zig` is a 6-line
re-export, and `apprt/win32.zig` holds the real `Window` + runtime. Linux
mirrors this exactly:

- **`src/platform/window_backend_linux.zig`** — re-export shell:
  ```zig
  const sdl = @import("../apprt/sdl.zig");
  pub const Window = sdl.Window;
  pub const FileDropHandler = sdl.FileDropHandler;
  pub const setGlobalWindow = sdl.setGlobalWindow;
  pub const glGetProcAddress = sdl.glGetProcAddress;
  ```
- **`src/apprt/sdl.zig`** — the concrete SDL3 runtime: `@cImport`s
  `SDL3/SDL.h`, owns `SDL_Init`, the `Window` struct, window/GL-context
  creation, the main-thread event pump + routing, IME and clipboard SDL calls,
  and the run-on-main marshaling queue. **This is the only module allowed to
  name SDL** (contract invariant: facades stay role-based).
- **Facade arms.** Add `linux` to the `Backend` enum and a
  `.linux => @import("..._linux.zig")` arm in the facades SP1 needs:
  `window_backend.zig`, `window.zig`. `font_backend.zig` points at a minimal
  Linux stub for bring-up (embedded font only) until SP2.
- **`pkg/sdl`** — a thin build package exposing the SDL3 C header to
  `apprt/sdl.zig`'s `@cImport` and linking `libSDL3`, mirroring how `pkg/opengl`
  (glad) is wired.

## The `Window` struct

Must carry the fields the facade reads (the set is enumerated by
`window_backend_unsupported.zig`): an opaque native handle (`*SDL_Window`, kept
behind the existing `hwnd`/`NativeHandle` seam), the `SDL_GLContext`, `width` /
`height` / `dpi` / `titlebar_height` / `sidebar_width` / `tab_count`,
`mouse_x` / `mouse_y` / `hovered_button`, the close/plus button-bounds arrays,
the `focused` / `is_minimized` / `is_fullscreen` / `close_requested` /
`dpi_changed` / `size_changed` flags, the `on_resize` / `on_message` /
`on_file_drop` callbacks, and the **five input-event queues**
(`key` / `char` / `mouse_button` / `mouse_move` / `mouse_wheel`). The queues
must be **thread-safe** (mutex-guarded): the main thread pushes during the pump,
the owning window thread pops via `popKeyEvent` etc.

## GL surface

```
SDL_GL_SetAttribute(CONTEXT_MAJOR_VERSION, 3)
SDL_GL_SetAttribute(CONTEXT_MINOR_VERSION, 3)
SDL_GL_SetAttribute(CONTEXT_PROFILE_MASK, CONTEXT_PROFILE_CORE)
SDL_GL_SetAttribute(DOUBLEBUFFER, 1)
win = SDL_CreateWindow(title, w, h,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE |
        SDL_WINDOW_BORDERLESS | SDL_WINDOW_HIGH_PIXEL_DENSITY)
ctx = SDL_GL_CreateContext(win);  SDL_GL_MakeCurrent(win, ctx)
```

- `glGetProcAddress(name)` wraps `SDL_GL_GetProcAddress(name)`; the host passes
  `@ptrCast(&glGetProcAddress)` to `gpu/opengl/Context.zig:init(loader)` (the
  glad load) — unchanged renderer.
- `swapBuffers` → `SDL_GL_SwapWindow`. Mirror the Win32 render-glitch lesson
  (vsync off during live resize): `SDL_GL_SetSwapInterval(0)` while a resize is
  in flight, restore after.
- SDL picks **GLX on X11 / EGL on Wayland** internally; neither the host nor the
  renderer needs to care.

## Event loop & threading (the core design)

SDL's event queue is global and must be pumped on the thread that initialized
video (the main thread). This is the macOS situation, so the facade hooks that
already exist for macOS carry the Linux implementation:

- **`pumpAppEvents(timeout_seconds)`** (main thread): `SDL_WaitEventTimeout` up
  to `timeout`, then drain all currently-queued SDL events. For each event, use
  its `windowID` to find the target `Window` and push the translated neutral
  event onto that window's (thread-safe) queue. **Also drains the run-on-main
  queue** (below). This is the event-driven block that keeps the render loop
  from spinning (the loop calls it at `AppWindow.zig:6225`).
- **`pollEvents(win)`**: non-blocking — returns `!win.close_requested`. The
  actual SDL pump happens in `pumpAppEvents` on the main thread; `pollEvents`
  stays a cheap liveness check (the render loop calls it at
  `AppWindow.zig:6167`).
- **`postWakeup()`** (any thread): `SDL_PushEvent` of a registered user event —
  the documented way to interrupt `SDL_WaitEventTimeout` from another thread.
  Termio read/write threads and background jobs already call this
  (`termio/ReadThread.zig:121`, `termio/Thread.zig:174`).
- **Run-on-main marshaling.** Worker-thread windows must not call SDL window
  mutators directly. Provide a `runOnMain(fn, ctx, wait)` that, off the main
  thread, enqueues the closure and wakes the main pump (`postWakeup`), then
  optionally blocks on a completion signal; on the main thread it runs inline.
  Prefer **`SDL_RunOnMainThread`** if the linked SDL3 provides it (direct
  `dispatch_sync`/`dispatch_async` analog); otherwise a mutex+condvar queue
  drained inside `pumpAppEvents`. This is the `wispterm_macos_run_on_main`
  (`window_macos_bridge.m:262`) equivalent.

**SP1 single-window path** runs the first window's `runMainLoop` on the main
thread, so it pumps directly and needs no marshaling — that is the bring-up
target. The **spike** stands up a second worker-thread window to validate the
routing + marshaling before any multi-window code is committed.

## Input translation (largest single piece)

`input_events.zig` defines the neutral types. Note its `KeyCode` values are
Win32 VK numbers (`key_left = 0x25`, `key_left_shift = 0xA0`, …) used as opaque
named constants; the host just has to emit the right constant. Mapping:

- `SDL_EVENT_KEY_DOWN` → `KeyEvent{ key_code, ctrl, shift, alt, super }` **for
  the named special keys only** (arrows, enter, esc, tab, backspace, space,
  modifiers, F5, page up/down, home/end, insert/delete). Build an
  SDL-scancode/key → `key_*` table; read modifiers from `SDL_GetModState`
  (super = GUI). Match what the AppKit/Win32 hosts emit.
- `SDL_EVENT_TEXT_INPUT` → `CharEvent{ codepoint, … }` (UTF-8 → `u21`). This is
  the printable-text path **and** the IME-committed-text path; SP1 covers ASCII,
  SP4 wires preedit (`SDL_EVENT_TEXT_EDITING`).
- `SDL_EVENT_MOUSE_BUTTON_DOWN`/`_UP` → `MouseButtonEvent` (map L/R/M; SDL
  `clicks==2` → `.double_click`).
- `SDL_EVENT_MOUSE_MOTION` → `MouseMoveEvent`; `SDL_EVENT_MOUSE_WHEEL` →
  `MouseWheelEvent` (scale `y` to the `i16` delta the app expects).
- `SDL_EVENT_DROP_FILE` → `on_file_drop(path, x, y)`.
- Coordinates: convert SDL logical points to the pixel space the app uses
  (HiDPI — see below) consistently across all pointer events.

## DPI / geometry / window state

- DPI/scale: `SDL_GetWindowDisplayScale` / `SDL_GetWindowPixelDensity` →
  `dpi` (× 96) / `effectiveDpi`; raise `dpi_changed` on
  `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`.
- Sizes: `SDL_GetWindowSizeInPixels` → `framebufferSize`; `SDL_GetWindowSize` →
  `clientSize`; `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` sets `size_changed` +
  fires `on_resize`.
- Geometry/state: `SDL_SetWindowPosition`/`Size`, `SDL_GetDisplayUsableBounds`
  (`nearestMonitorWorkArea`), `SDL_SetWindowFullscreen`, `SDL_MaximizeWindow` /
  `SDL_MinimizeWindow` / `SDL_RestoreWindow`, focus from
  `SDL_EVENT_WINDOW_FOCUS_GAINED`/`_LOST`, close from
  `SDL_EVENT_WINDOW_CLOSE_REQUESTED` (set `close_requested`).

## Custom chrome (borderless + hit-test)

The window is `SDL_WINDOW_BORDERLESS`; the app draws its own titlebar/tabs.
Register `SDL_SetWindowHitTest`: return `SDL_HITTEST_DRAGGABLE` over the
titlebar region (minus the caption-button and tab hit areas the app reports via
`setTabCloseButtonBounds` / `setNewTabButtonBounds`) and `SDL_HITTEST_RESIZE_*`
over the window edges/corners. This is the X11+Wayland-portable answer to
dragging/resizing a custom-chromed window; it is what keeps the SDL host
compatible with the existing GPU-drawn titlebar.

## build.zig changes

- `PlatformFeatures.forOs(.linux)`: `has_desktop_backend = true`,
  `supports_desktop_exe = true`. `defaultEmitDesktopExe(.linux)` → true;
  `defaultEmitSharedCompileChecks(.linux)` → false (it now builds a real exe).
- Link `libSDL3` + system GL; reuse vendored FreeType/HarfBuzz. Add the
  `pkg/sdl` C-header package for `@cImport`.
- Keep `x86_64-windows-gnu` the **default** dev target (`defaultDevelopmentTarget`).
- **Update the guard tests** that currently assert Linux has no desktop backend
  (`build.zig` "desktop executable emission defaults to implemented platform
  backends" and "shared compile checks default to platforms without desktop
  backends") — they encode the pre-port state and must flip for `.linux`.

## Acceptance

1. `zig build -Dtarget=x86_64-linux-gnu` (and native) produces a runnable
   `wispterm` executable.
2. On X11: window opens, renders the cell grid via the OpenGL backend, runs a
   shell over `pty_posix`, accepts keyboard (ASCII) + mouse input, drags via the
   custom titlebar, resizes correctly (no GL glitch), and closes cleanly.
3. `zig build test` / `test-full` stay green; the build guard-tests are updated,
   not deleted.
4. The **threading spike** result (multi-window in SP1 vs. SP1b) is recorded
   here before multi-window code is written.

## Out of scope for SP1 (tracked elsewhere)

- Real font discovery / CJK → **SP2** (SP1 uses embedded Cozette +
  hardcoded fallback).
- Clipboard, file dialog, notifications, XDG dirs, cursor → **SP3**.
- IME preedit (`SDL_EVENT_TEXT_EDITING`, `SDL_SetTextInputArea`) → **SP4**.
- Wayland polish (CSD edges under GNOME) → after X11 bring-up.
- Multi-window worker-thread windows → SP1b if the spike defers them.

## Open question for the implementation plan

- Whether the threading spike lands multi-window inside SP1 or splits SP1b
  (decided by the spike, recorded in Acceptance #4).
- Exact `pkg/sdl` shape (system-link only vs. an option for a future vendored
  static build) — confirm when wiring `build.zig`.
