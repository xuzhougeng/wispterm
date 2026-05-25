# TODO

## Cross-Platform Portability

Goal: ship native macOS and Linux ports without rewriting the terminal core.

"Decouple UI from functionality" has **two axes**, both required for the port:

- **Axis A — Portability seam (host swap):** platform/host code is separable so
  a new platform implements a host + platform-service impls and reuses the core.
- **Axis B — Presentation/logic separation:** within the core, *what a feature
  does* is separable from *how it is drawn / how input is handled*, so logic is
  independently testable and UI-agnostic.

Strategy (**Approach C**): the **GPU backend interface is the spine** — introduce
it with OpenGL as the first backend (verifiable on Windows, no shipping break),
and as each renderer file is routed through it, split that file's
presentation/logic in the same pass (touch once). POSIX PTY and the
non-renderer file splits run in parallel. Metal joins later as a second backend.

The full audit, target architecture, rationale, and per-file detail live in
[docs/decoupling-guide.md](docs/decoupling-guide.md). The core ↔ host contract
is in [docs/architecture.md](docs/architecture.md).

Scope note: these platform checks apply to the desktop app/build/shared Zig
code only — not the `remote/` web console or packaged `plugins/`.

### Architecture principle: core vs. host

- The **core** never imports a platform runtime. It exposes a surface API; the
  host calls into it and supplies platform services through narrow interfaces.
- Each platform service lives in `src/platform/` as `<cap>.zig` (the interface)
  plus `<cap>_windows.zig` / `<cap>_posix.zig` / `<cap>_unsupported.zig` impls.
- The host owns the OS event loop (Win32 today; AppKit and GTK own their own)
  and pumps the core from there.

- [x] Define and document the core↔host surface API boundary as a named
      contract. Documented in [docs/architecture.md](docs/architecture.md): the
      host interface is `src/platform/window_backend.zig`, platform-service
      capabilities are the `src/platform/<cap>.zig` facades, and the boundary
      invariants (plus the guards enforcing them) are listed there.

### Decoupling status

- **Axis A platform-runtime seam — done and enforced.** App logic routes through
  `src/platform/`; no `std.os.windows` / `apprt/win32.zig` leakage; comptime
  guards fail the build on violations; input uses neutral `key_*` codes.
- **GPU graphics API — NOT decoupled.** ~700 raw `gl.*` sites across 16 renderer
  files; GL handles are global state in `gl_init.zig`; `AppWindow.zig`
  `@cImport`s `glad/gl.h` and owns the GL context; shaders are GLSL-only. This
  is the top blocker for macOS (Metal-only). → **Phase A**. See guide §1.
- **Giant files conflate presentation + logic.** `ai_chat.zig` (248 KB),
  `input.zig` (3,462 ln), `AppWindow.zig` (3,742 ln), `overlays.zig` (171 KB).
  → **Phase B**.

### Phase 1 — Platform-runtime boundaries (complete)

These extracted platform-*runtime* coupling behind interfaces so a port is
*possible*. Done and enforced by the comptime guards in
[docs/architecture.md](docs/architecture.md).

- [x] Split platform APIs behind narrow interfaces instead of importing
      `src/apprt/win32.zig` and `std.os.windows` from app logic.
- [x] PTY/process abstraction (Windows ConPTY + `CreateProcessW` implemented;
      POSIX process layer present; POSIX PTY impl is Phase C).
- [x] Separate window/event/input backends from `AppWindow.zig` behind a host
      interface (Windows backend implemented; macOS/Linux hosts are Phase D).
- [x] Abstract font *discovery* and fallback (DirectWrite implemented;
      CoreText/fontconfig are Phase D).
- [x] Renderer has **no platform-runtime leakage** — no win32/DirectWrite/
      WebView2 names in `src/renderer/`. (NOTE: this does **not** mean the GPU
      API is abstracted — raw OpenGL is still pervasive. See Phase A.)
- [x] Remote client networking behind one transport API
      (`src/platform/remote_transport*.zig`).
- [x] Embedded browser integration split by platform behind an
      `EmbeddedBrowserBackend` build gate (WebView2 implemented).
- [x] Isolate updater and release-asset logic from app runtime code.
- [x] Build target selection and platform feature gates in `build.zig`, Windows
      default until a port starts.
- [x] Compile-only checks for shared modules on non-Windows targets.
- [x] Abstract clipboard, file picker, file drop, open-url, notifications,
      global hotkeys, DPI/content-scale, and config/theme directories.

### Phase A — GPU interface spine (actionable now; verifiable on Windows)

OpenGL stays working behind the new interface at every step. Detail + Ghostty
mapping in guide §2 and §5.

- [ ] **A1** Define `src/renderer/gpu/gpu.zig` (the `GraphicsAPI` interface:
      `Target`/`Frame`/`RenderPass`/`Pipeline`/`Buffer`/`Texture`/`Sampler`/
      `shaders`) and `src/renderer/gpu/backend.zig` (`Backend{opengl,metal}`,
      `default(target)` → Metal on Darwin). *Ghostty: `renderer/generic.zig`,
      `renderer/backend.zig`.*
- [ ] **A2** Move current OpenGL into `src/renderer/gpu/opengl/` as the first
      backend; move GL-context ownership out of `AppWindow.zig` to the
      backend/host seam. *Ghostty: `renderer/opengl/`.*
- [ ] **A3** Route renderer files from raw `gl.*` to `gpu.zig`, splitting each
      file's presentation/logic in the same pass (one touch each):
      `cell_renderer`, `titlebar`, `overlays`, `ai_chat_renderer`,
      `image_renderer`, `post_process`, `background_image`, `fbo`,
      `markdown_preview_renderer`, `file_explorer_renderer`.
- [ ] **A4** Route font atlas → GPU texture through the `Texture` primitive;
      drop `font/manager.zig`'s direct `@cImport("glad/gl.h")`.
- [ ] **A5** Backend-scope shaders: GLSL under `gpu/opengl/shaders.zig`; reserve
      MSL slot under `gpu/metal/shaders.zig`. *Ghostty: `renderer/shaders/`.*
- [ ] **A6** Extend guards: forbid `gl.*` / `@cInclude("glad/gl.h")` outside
      `src/renderer/gpu/opengl/`; forbid `AppWindow.zig` importing `glad`.

### Phase B — Presentation/logic separation (actionable now; verifiable on Windows)

- [ ] **B1** `input.zig`: extract keybind parsing + command dispatch from
      platform input handling into pure, unit-testable modules.
- [ ] **B2** `ai_chat.zig`: separate conversation/state/protocol logic from UI
      state into independently testable sub-modules.
- [ ] **B3** `AppWindow.zig`: layer tab/split orchestration, render
      orchestration, and input routing (GL binding removed in A2).
- [ ] **B4** Unit tests for the extracted pure logic (`zig test`).

### Phase C — POSIX PTY/process backend (actionable now; unit-testable on Linux)

- [ ] **C1** `src/platform/pty_posix.zig`: `openpty`/`fork`/`exec` +
      `ioctl(TIOCSWINSZ)` satisfying the `pty.zig` facade. *Ghostty:
      `src/pty.zig` (POSIX).*
- [ ] **C2** Complete `src/platform/process_posix.zig` to drive the PTY.
- [ ] **C3** Linux unit tests for spawn/resize/teardown.

### Phase D — Native host implementations (deferred; needs macOS/Linux SDK)

The actual port work. Gated on Phase A. Per AGENTS.md, break each track down
together and compare against Ghostty before starting.

Cross-cutting:
- [ ] Input/IME/keymap handling per platform behind the input interface.
- [ ] Renderer backend selection wired to the host's surface/event loop.

macOS (native, Metal):
- [ ] **D1** Metal backend `src/renderer/gpu/metal/` — second backend behind the
      Phase A interface (no OpenGL fallback). *Ghostty: `renderer/metal/`.*
- [ ] **D2** AppKit host + `window_backend_macos.zig` (window, native menus,
      event loop, input routing, IME, DPI).
- [ ] **D3** CoreText font discovery and fallback.
- [ ] WKWebView embedded browser backend.
- [ ] Clipboard, file picker/drop, open-url, notifications, global hotkeys,
      DPI/content-scale via AppKit; config/theme dirs under `~/Library`.
- [ ] Packaging: `.app` bundle / `.dmg`, updater story.

Linux (native):
- [ ] Host decision (GTK/libadwaita vs. another native toolkit) and impl.
- [ ] Renderer backend behind Phase A: OpenGL backend reusable; Vulkan optional.
- [ ] fontconfig font discovery and fallback.
- [ ] WebKitGTK embedded browser, or keep disabled until viable.
- [ ] Clipboard, portals/file picker, open-url, notifications, global hotkeys,
      DPI/content-scale; config/theme dirs under XDG paths.
- [ ] Packaging: chosen distribution format + updater story.

### Invariants to maintain

- [x] Keep the `build.zig` `@compileError` guards that forbid leaking target OS
      booleans / Windows-specific names into app modules. Guard patterns live in
      `src/build_guards.zig` (`firstLeak`); `build.zig` runs them at comptime;
      `test_main.zig` imports the module so the logic is unit-tested.
- [x] No shared/test code outside `src/platform/` depends on a platform runtime.
      The `apprt/win32.zig` API-surface leak checks live in
      `src/platform/apprt_win32_guard.zig`.
- [ ] **(Phase A6)** No raw GPU API outside its backend: `gl.*` and
      `@cInclude("glad/gl.h")` only under `src/renderer/gpu/opengl/`; the host
      owns the GPU context, so `AppWindow.zig` must not `@cImport` `glad`.
