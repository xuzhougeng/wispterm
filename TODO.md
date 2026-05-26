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
- **GPU graphics API — Phase A complete (A1–A6).** The `GraphicsAPI` spine
  under `src/renderer/gpu/` owns the GL context and primitives (`Buffer`/
  `Texture`/`Pipeline`/`Framebuffer`); all renderer files route draws through
  `gpu`/`ui_pipeline`/`cell_pipeline`; the font atlas uses `Texture`; the MSL
  shader slot is reserved at `gpu/metal/shaders.zig`; and a comptime guard
  (`gpu/gl_backend_guard.zig`) keeps `@cInclude("glad/gl.h")` backend-only and
  regression-locks the decoupled feature files. A small documented residue of
  files still calls `gpu.glTable()` (the GL presentation layer + not-yet-extracted
  plumbing) — to be absorbed as the primitive set grows. → **Phase D** (Metal/Linux
  backends) is now the gate. See guide §1.
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

- [x] **A1** Define `src/renderer/gpu/gpu.zig` (the `GraphicsAPI` interface:
      `Target`/`Frame`/`RenderPass`/`Pipeline`/`Buffer`/`Texture`/`Sampler`/
      `shaders`) and `src/renderer/gpu/backend.zig` (`Backend{opengl,metal}`,
      `default(target)` → Metal on Darwin). *Ghostty: `renderer/generic.zig`,
      `renderer/backend.zig`.*
- [x] **A2** Move current OpenGL into `src/renderer/gpu/opengl/` as the first
      backend; move GL-context ownership out of `AppWindow.zig` to the
      backend/host seam. *Ghostty: `renderer/opengl/`.* The GL table + context
      load now live in `gpu/opengl/Context.zig`, `gl_init` and GLSL shaders
      under `gpu/opengl/`, and `AppWindow.zig` no longer `@cImport`s `glad`
      (consumers reach the table via `AppWindow.gpu.glTable()`). Renderer files
      keep their own `glad` includes until A6.
- [x] **A3** Route renderer files from raw `gl.*` to `gpu.zig`, splitting each
      file's presentation/logic in the same pass (one touch each):
      `cell_renderer`, `titlebar`, `overlays`, `ai_chat_renderer`,
      `image_renderer`, `post_process`, `background_image`, `fbo`,
      `markdown_preview_renderer`, `file_explorer_renderer` — **all converted**.
      *Increment 1 done:* real `Buffer`/`Texture`/`Pipeline` primitives exist in
      `gpu/opengl/`; `cell_renderer` is converted — `drawCells` routes through
      `cell_pipeline.zig` (cell pipelines built from the primitives) and the pure
      BG/cursor/selection + glyph-rect logic + instance types moved to std-only,
      unit-tested `cell_geometry.zig`.
      *Increment 2 done:* the shared UI rendering (solid quad / text-glyph /
      color-emoji) moved out of `gl_init` into primitives-backed
      `ui_pipeline.zig`; `gl_init` keeps compat mirror handles (`shader_program`/
      `simple_color_shader`/`vao`/`vbo`, set via `syncSharedHandles()`) +
      re-exports `renderQuad`/`renderQuadAlpha`/`setProjection`, so the
      still-unconverted files are untouched. `titlebar` is converted (glyph/emoji
      through `ui_pipeline`, no raw `gl.*`/glad) and its pure layout logic moved
      to std-only `titlebar_layout.zig`. `overlay_shader` stays in `gl_init`.
      *Increment 3 done:* `ai_chat_renderer` is converted — its 56 quad draws
      route through `ui_pipeline.fillQuad*`, the two scissor regions through new
      `ui_pipeline.beginClip`/`endClip`, and the redundant local blend setup +
      `glad` cImport + `gl_init` import are gone (the file is now raw-`gl.*`-free,
      like `titlebar`). Its pure rect geometry moved to std-only, unit-tested
      `ai_chat_layout.zig`.
      *Increment 4 done (remaining 7 files):* `file_explorer_renderer` (quads →
      `ui_pipeline.fillQuad`). Added GPU primitives — `Texture.create/upload2D/
      setWrap/destroy`, new `Framebuffer`, `Pipeline.setVec3/setVec4/drawArrays`
      — plus `ui_pipeline.drawTextureQuad`/`fillOverlay`/`setBlendEnabled` and a
      `ui_pipeline`-owned `overlay` pipeline (so `overlay_shader` left `gl_init`).
      `fbo`/`post_process` → `gpu.Framebuffer`; `image_renderer`/`background_image`/
      `markdown_preview_renderer` image uploads → `gpu.Texture` + `drawTextureQuad`;
      `overlays`/`background_image` tint → `fillOverlay`; `markdown_preview` +
      `overlays` quads → `fillQuad`. None carries its own `@cInclude("glad/gl.h")`;
      `markdown_preview`/`post_process` keep `gpu.glTable()` plumbing for VAO
      build / scissor save-restore / Clear-Viewport (the `cell_pipeline` bar).
- [x] **A4** Route font atlas → GPU texture through the `Texture` primitive;
      drop `font/manager.zig`'s direct `@cImport("glad/gl.h")`. Added
      `Texture.subImage2D`/`levelWidth`; `font/manager.zig` is now fully GL-free
      (atlas create/upload/sub-update/teardown via `gpu.Texture`, constants via
      `gpu.c`).
- [x] **A5** Backend-scope shaders: GLSL under `gpu/opengl/shaders.zig`; the
      symmetric MSL slot is reserved at `gpu/metal/shaders.zig` (documented
      placeholder, filled by the Metal backend in D1). *Ghostty: `renderer/shaders/`.*
- [x] **A6** Guard `src/renderer/gpu/gl_backend_guard.zig` (comptime source
      scans, imported by `test_main.zig`): (1) `@cInclude("glad/gl.h")` only
      under `src/renderer/gpu/opengl/` — every other renderer/font/`AppWindow`
      file now sources GL constants from `gpu.c`; (2) the A3/A4-decoupled feature
      files are regression-locked against re-acquiring `gpu.glTable()`. The
      remaining `gpu.glTable()` users (GL presentation layer `ui_pipeline`/
      `cell_pipeline`, render coordination `Renderer`/`cell_renderer`/
      `post_process`, and plumbing in `markdown_preview_renderer`/
      `weixin_qr_renderer`/`overlays/{resize,scrollbar,startup_shortcuts}`) are
      the documented residue to absorb as the primitive set grows.

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
- [x] **(Phase A6)** Raw GPU API stays in its backend, enforced by
      `src/renderer/gpu/gl_backend_guard.zig` (comptime scans, imported by
      `test_main.zig`): `@cInclude("glad/gl.h")` only under
      `src/renderer/gpu/opengl/` (every other renderer/font/`AppWindow` file uses
      `gpu.c`), and the A3/A4-decoupled feature files are locked against
      re-acquiring `gpu.glTable()`. Remaining `gpu.glTable()` callers (GL
      presentation layer + not-yet-extracted render plumbing) are the documented,
      shrinking residue — a full `gl.*`-outside-backend ban awaits extracting
      VAO-build / render-state primitives for those.
