# Linux Port — Roadmap & Design

Realizes the **"Linux — deferred"** track of the Cross-Platform Portability plan
in [TODO.md](../../../TODO.md), building on the core↔host contract in
[architecture.md](../../architecture.md). Phase A (GPU/OpenGL spine) and Phase C
(POSIX PTY/process) are already complete; this document covers the remaining
work to ship a production Linux build: a **Linux host** plus the `_linux`/
`_posix` platform services, packaging, desktop integration, and CI.

This is an **umbrella roadmap**. The port is too large for one implementation
plan, so it is decomposed into six sub-projects (SP1–SP6). SP1 is the spine and
gate; each sub-project gets its own spec → plan → implementation cycle. SP1 is
specified in detail here; SP2–SP6 are at roadmap depth and will be expanded into
their own specs when reached.

## Decisions (locked during brainstorming)

- **Host = SDL3.** SDL3 supplies the window, GL context (EGL/GLX), input,
  clipboard, file dialogs, and IME across X11 and Wayland from one codebase. Its
  "create window → create GL context → poll events into a queue" model maps
  almost 1:1 onto the existing `window_backend.zig` host interface, and fits
  WispTerm's "borderless window + self-drawn GPU chrome + neutral input queue"
  pattern already proven on Win32.
  - **Rejected — GTK4 + libadwaita:** most native and the closest Ghostty
    parity, but WispTerm draws *all* its own chrome (titlebar/tabs) on the GPU,
    so GTK's widget tree is dead weight (GTK would be used only as a window + GL
    surface + input + IME provider); the thread-per-window model clashes with
    GTK's single-main-loop assumption; and because Ghostty-on-GTK uses native
    GTK widgets, its `apprt/gtk` is mostly **non-copyable** into WispTerm's
    draw-everything-ourselves model — undercutting the "reference Ghostty"
    benefit for this layer.
  - **Rejected — raw X11/Wayland:** maximum control and smallest runtime deps,
    consistent with the hand-rolled Win32/AppKit hosts, but the largest effort:
    clipboard/DnD/HiDPI/IME hand-rolled, and X11 + Wayland are two entirely
    different protocols to implement each (IME especially).
  - **Noted but rejected within the SDL tier — GLFW:** lighter and
    battle-tested, but CJK IME support is too weak for an IME-first app.
- **Scope = production release.** Full desktop feature parity + packaging
  (AppImage/Flatpak/.deb/.rpm) + desktop integration (`.desktop`, icons,
  AppStream) + CI. Auto-update and the embedded webview are deliberately
  degraded (see [Out of scope & degrades](#out-of-scope--degrades)).
- **Bring-up order = X11 first, Wayland next.** Same SDL3 code runs on both;
  X11 is simpler to bring up (no client-side decorations, mature tooling),
  Wayland is validated and polished immediately after. Production ships both.

## Reuse vs. build

**Already present — reused as-is on Linux:**

- Terminal core: `libghostty-vt`, `src/Surface.zig`, `src/termio/`.
- Renderer: all of `src/renderer/` is GPU-backend-neutral; the **OpenGL
  backend** (`src/renderer/gpu/opengl/`, the backend Windows already uses) is
  reused via SDL's GL context. No renderer changes needed.
- `src/platform/pty_posix.zig` / `process_posix.zig` — Linux PTY/process, with
  native Linux tests (Phase C; `fork`/`exec`/`poll`/`waitpid`).
- `src/platform/open_url_posix.zig`, `session_lock_local_process.zig`,
  `display_portable.zig` — POSIX/portable services already present (verify on
  Linux, do not rewrite).
- FreeType + HarfBuzz (vendored in `pkg/`) — the Linux text stack.
- The entire UI/feature layer (tabs, splits, file explorer, AI chat, command
  center, overlays, titlebar) is platform-neutral and GPU-self-drawn; it appears
  automatically once host + GL + input work. **The feature layer is not
  touched.**

**Built for Linux:** SDL3 host + GL wiring (SP1); fontconfig discovery (SP2); a
batch of `_linux` platform services (SP3); IME (SP4); webview degrade (SP5);
packaging + desktop integration + CI (SP6).

## The host-selection seam (applies to every backend facade)

Each `src/platform/<cap>.zig` facade selects an impl with:

```zig
pub const Backend = enum { windows, macos, unsupported };
pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend { ... }
const impl = switch (backendForOs(builtin.os.tag)) { ... };
```

Bringing up Linux means adding a **`linux`** value to the relevant `Backend`
enums and a `.linux => @import("<cap>_linux.zig")` arm, then writing the impl.
The facades that gain a `linux` arm in SP1–SP3: `window_backend`, `font_backend`
(+ `font_discovery`), `clipboard`, `cursor`, `file_dialog`, `notifications`,
`config_watcher`, `dirs` (XDG), and the few that today fall through to
`unsupported`. Facades already covered by `_posix`/portable variants
(`open_url`, `pty`, `process`, `session_lock`, `display`) only need a Linux
build wiring + verification, not a new impl.

The contract invariants in [architecture.md](../../architecture.md) still hold:
the core never imports a platform runtime, facade names stay role-based (no
`sdl`/`x11`/`wayland`/`fontconfig` leaking into facade *names* or app modules),
and `build.zig` exposes capabilities, not target-OS booleans. The new concrete
runtime lives behind the facade in `src/apprt/` + `src/platform/*_linux.zig`.

---

## SP1 — SDL3 host bring-up (critical path, the spine)

**Goal:** a single SDL3 window on X11 rendering a live terminal (OpenGL),
keyboard + mouse input, a shell running over `pty_posix`. This is the gate for
everything else.

**New files**

- `src/apprt/sdl.zig` — the concrete SDL3 runtime (sibling of
  `src/apprt/win32.zig`). Owns `SDL_Init`, window/GL-context creation, the event
  pump, and the IME/clipboard SDL calls. This is the *only* new module allowed
  to name SDL.
- `src/platform/window_backend_linux.zig` — the `Window` type + module fns that
  satisfy the `window_backend.zig` facade, mirroring
  `window_backend_windows.zig` (lifecycle, event loop, neutral input queues,
  rendering surface, window state). Delegates to `apprt/sdl.zig`.

**Wiring**

- `src/platform/window_backend.zig` + `window.zig`: add `linux` to `Backend`,
  add the `.linux` import arm. (Today `backendForOs(.linux) == .unsupported`.)
- `build.zig`: extend `PlatformFeatures.forOs` so `.linux` reports
  `has_desktop_backend = true` and `supports_desktop_exe = true`; make
  `defaultEmitDesktopExe(.linux)` true; link SDL3 + GL + (vendored) FreeType/
  HarfBuzz. Keep `x86_64-windows-gnu` the **default** dev target (existing
  guard tests in `build.zig` assert linux defaults — update those alongside).

**GL surface**

- Request a context matching what `gpu/opengl/` targets via
  `SDL_GL_SetAttribute` (core profile, the existing GL version), then
  `SDL_GL_CreateContext`.
- `glGetProcAddress` in the Linux backend wraps `SDL_GL_GetProcAddress`; the
  host hands it to `gpu/opengl/Context.zig:init(loader)` (the glad loader). SDL
  picks EGL on Wayland / GLX on X11 — the renderer is unaware.
- `swapBuffers` → `SDL_GL_SwapWindow`.

**Input translation** (the largest single piece of SP1)

- `SDL_PollEvent` in `pollEvents`; translate into the neutral structs in
  `src/platform/input_events.zig` and push onto the queues that `popKeyEvent` /
  `popCharEvent` / `popMouseButtonEvent` / `popMouseMoveEvent` /
  `popMouseWheelEvent` drain.
- Map SDL scancodes/keycodes → the project's neutral `key_*` codes (never raw OS
  keycodes — contract invariant), and SDL keymods → the neutral modifier set.
  Mirror the mapping the Win32 host performs from `WM_KEYDOWN`/`WM_CHAR`.

**DPI / geometry / chrome state**

- DPI/scale: `SDL_GetWindowDisplayScale` / `SDL_GetWindowPixelDensity` →
  `dpi` / `effectiveDpi` / `consumeDpiChanged`.
- Geometry: `SDL_GetWindowSizeInPixels` (framebuffer), `SDL_GetWindowSize`
  (client), `SDL_SetWindowPosition`/`Size`, `SDL_GetDisplayUsableBounds`
  (`nearestMonitorWorkArea`), `SDL_SetWindowFullscreen`, `SDL_MaximizeWindow` /
  `SDL_MinimizeWindow`.
- **Custom chrome:** create the window `SDL_WINDOW_BORDERLESS` and register
  `SDL_SetWindowHitTest` — return `SDL_HITTEST_DRAGGABLE` over the self-drawn
  titlebar region and `SDL_HITTEST_RESIZE_*` over the window edges. Feed the
  app's titlebar/caption-button geometry (`setTitlebarHeight`,
  `setTabCloseButtonBounds`, `setNewTabButtonBounds`) into the hit-test
  callback. This is the X11+Wayland-portable answer to "drag my custom
  titlebar."

**Threading spike — do this FIRST, before the input work**

The riskiest unknown. WispTerm runs **one thread per window** (`App.run` →
`runFirstWindowOnce` on the main thread, additional windows via
`requestNewWindow` on worker threads; `joinAllWindowThreads`). SDL prefers video
init + event pumping on a single (main) thread.

**Mitigation — follow the macOS precedent, not the Win32 one.** The macOS host
already solved exactly this: instead of Win32's per-thread message loops, it
pumps events on the main thread and **marshals window mutations from worker
threads back to the main thread** via the GCD main queue (see the `pumpAppEvents`
doc-comment in `window_backend.zig`, which also drains that queue). The Linux
host follows the same shape: a main-thread SDL event pump + a `runOnMain`-style
marshaling queue that worker threads post window ops to. The facade hooks for
this already exist and are no-ops elsewhere: `pumpAppEvents`, `postWakeup`,
`consumeQuitRequest`, `consumeReopenRequest`. The spike validates that an SDL
window created/pumped under this model works on X11 before the rest of SP1 is
built. If the marshaling model proves untenable, the fallback is a Linux-only
single-window-then-tabs simplification — decided in the SP1 spec, not here.

**Minimal font for bring-up:** start with the embedded Cozette
(`src/font/embedded.zig`) + a hardcoded fallback to get pixels on screen;
real discovery is SP2.

**Deliverable / acceptance:** `zig build` for a native Linux target produces a
runnable executable; on X11 it opens a window, renders the cell grid via the
OpenGL backend, runs a shell over `pty_posix`, accepts keyboard/mouse input, and
resizes correctly. The threading spike result is recorded in the SP1 spec.

---

## SP2 — Font discovery + fallback (fontconfig)

**Goal:** real system-font resolution and CJK fallback, replacing the SP1
bring-up stub.

- `src/platform/font_backend_linux.zig` + `font_discovery_linux.zig`,
  implementing the facade's `FontDiscovery` / `FallbackFont` / `FontFilePath` /
  `LoadedFont` against **fontconfig** (`FcFontMatch` / `FcPattern`). FreeType
  loads the matched paths (already cross-platform).
- CJK fallback via fontconfig's lang-based matching, analogous to the macOS
  CoreText fallback work. `font_backend.zig` gains the `.linux` arm.

---

## SP3 — Platform services (`_linux` / `_posix`) — parallelizable after SP1

A batch of mostly-small capability impls behind existing facades. Each is
independent and can be tackled in parallel.

- **`dirs.zig`** → XDG base dirs (`$XDG_CONFIG_HOME` → `~/.config/wispterm`,
  `$XDG_DATA_HOME`, `$XDG_CACHE_HOME`).
- **`clipboard_linux.zig`** → SDL clipboard (`SDL_GetClipboardText` /
  `SDL_SetClipboardText`), avoiding raw X11 selections / `wl_data_device`.
  Text-first; OSC 52 write already has its own path.
- **`file_dialog_linux.zig`** → `SDL_ShowOpenFileDialog` /
  `SDL_ShowSaveFileDialog` (SDL3 native dialogs), with the XDG Desktop Portal as
  the sandbox-friendly alternative for Flatpak.
- **`cursor_linux.zig`** → `SDL_CreateSystemCursor`.
- **`notifications_linux.zig`** → D-Bus `org.freedesktop.Notifications` (or
  libnotify); bell + window-attention. May start as a stub.
- **`config_watcher`** → inotify-based Linux impl, or fall back to the existing
  unsupported/polling variant initially.
- **Verify (no new impl, just build wiring):** `open_url` (posix/xdg-open),
  `session_lock_local_process`, `display_portable`, `text`, `threading`,
  `memory`, `console`, `editor`, `local_path`, `atomic_file`.

---

## SP4 — IME (CJK) — after SP1 input is solid

**Goal:** working CJK input (fcitx5 / ibus), a first-class requirement for this
app.

- `SDL_StartTextInput` / `SDL_StopTextInput`; `SDL_EVENT_TEXT_EDITING`
  (preedit) → the app's `imePreeditText` / `setImeCaret` seam (`ime_caret.zig`);
  `SDL_EVENT_TEXT_INPUT` (committed text) → char events.
- `SDL_SetTextInputArea` positions the candidate window.
- Backends: ibus + fcitx5 through SDL3's IME support. **X11 first** (mature),
  then **Wayland `text-input-v3`** (newer in SDL3 — validate explicitly).

---

## SP5 — Webview decision (mostly confirmation)

`browser_panel` / Jupyter use an embedded webview (WebView2 on Windows,
WKWebView on macOS). With an SDL3 host (no GTK), embedding WebKitGTK is awkward
(it needs a GTK widget hierarchy + its own compositing).

**Decision: disable on Linux for v1.** `webview_unsupported.zig` and
`browser_panel_stub.zig` already exist, and `EmbeddedBrowserBackend.none` is
already the linux default in `build.zig`. The browser/Jupyter features degrade
gracefully. Revisit post-1.0 (out-of-process WebKitGTK composited via a shared
GL texture, or launch the system browser). Near-zero build work.

---

## SP6 — Packaging + desktop integration + CI (production)

- **AppImage** (linuxdeploy) — single-file, most portable; bundles SDL3 +
  FreeType + HarfBuzz (fontconfig from the host).
- **Flatpak** (Flathub manifest) — sandboxed; XDG portals for file dialog /
  notifications / global shortcuts fit naturally. Likely the primary channel.
- **.deb / .rpm** — distro packages (nfpm/fpm), nice-to-have after the above.
- **Desktop integration:** `.desktop` entry, hicolor icons, AppStream
  metainfo (required for Flathub / GNOME Software).
- **CI:** extend the existing Linux test job (Ubuntu runner) to build the
  desktop exe + produce AppImage/Flatpak artifacts. Stand up a basic Linux
  build job **early** (during SP1) to prevent regressions.

---

## Dependency / ordering

```
SP1 (SDL3 host, spine) ──┬─→ SP2 fonts ──┐
                         ├─→ SP3 services ┼─→ SP6 packaging / CI (final)
                         └─→ SP4 IME ─────┘
SP5 webview-disable: any time (tiny)
Basic Linux build CI: stand up during SP1
```

SP1 gates all. Within SP1: **threading spike → input translation → chrome/GL**.

## Risks & mitigations

1. **Thread-per-window × SDL event pump (largest unknown).** Mitigation: follow
   the macOS main-thread-pump + worker-marshal precedent (already in the
   codebase), not the Win32 per-thread-loop model. Validated by the SP1 spike
   before further SP1 work.
2. **Wayland custom chrome (CSD).** Drag/resize/shadows via
   `SDL_SetWindowHitTest`; validate resize edges under GNOME (no server-side
   decorations for apps). Risk isolated to the Wayland polish pass after X11.
3. **Quake global hotkey on Wayland.** No traditional global hotkeys. Degrade:
   X11 via `XGrabKey`, Wayland via the GlobalShortcuts portal, else mark
   unsupported. Decided per-protocol; does not block bring-up.

## Out of scope & degrades

- **Embedded webview:** disabled on Linux (SP5).
- **In-app auto-update:** disabled on Linux; delegate to the distribution
  channel (Flatpak / package manager / AppImageUpdate). The existing
  `update_*` flow stays Windows/macOS-only.
- **Quake global hotkey:** degraded per protocol (see risks).
- **Windows-only features** (WeChat bridge, `remote_transport` HTTP transport)
  are already build-gated off elsewhere and simply absent on Linux.

## Open items for the SP1 spec

- SDL3 as a **vendored static** build under `pkg/` vs. linking the **system
  libSDL3** (affects AppImage/Flatpak bundling in SP6).
- The exact GL version/profile `gpu/opengl/` requires, to set
  `SDL_GL_SetAttribute` correctly.
- Final call on keeping thread-per-window (macOS-style marshaling) vs. a
  Linux-only single-main-loop simplification — pending the spike.

## Next step

After this roadmap is reviewed, **SP1 gets its own detailed spec** (then
writing-plans → implementation). SP2–SP6 are expanded into specs as they are
reached.
