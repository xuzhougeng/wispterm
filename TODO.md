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
      symmetric MSL shader set lives at `gpu/metal/shaders.zig` (reserved in A5,
      filled by the Metal backend in D1). *Ghostty: `renderer/shaders/`.*
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

### Phase C — POSIX PTY/process backend (Linux done; macOS/BSD deferred to Phase D)

- [x] **C1** `src/platform/pty_posix.zig` satisfies the `pty.zig` facade:
      `posix_openpt`/`grantpt`/`unlockpt`/`ptsname_r` for the master + slave path,
      `fork`+`setsid`/`TIOCSCTTY`/`dup2`/`chdir`/`execvp` in the child (pid stored
      in the `Command`), `ioctl(TIOCSWINSZ)` for size, poll-based `readOutput`
      with a self-pipe so `cancelOutputRead` breaks the blocking read, `FIONREAD`
      for `outputAvailable`, EIO→`BrokenPipe`. `pty.zig` gains a `.posix` backend
      (Linux only — macOS/BSD use different ioctl request codes, deferred).
- [x] **C2** `process_posix.zig` `waitForPid`/`childExited` implemented via a
      shared `reapChild` (raw `wait4` syscall on Linux so the no-libc fast-test
      graph links; `std.c.waitpid` elsewhere); `pty_command` POSIX `Command` got
      a `pid` + waitpid-based `wait`/`deinit` (zombie reaping).
- [x] **C3** Native Linux tests in `pty_posix.zig` (real `fork`/`exec`/`poll`/
      `waitpid`): backend selection, open+resize, spawn+read, child-exit→
      `BrokenPipe`/0 + `wait` exit code, `outputAvailable` count, cancel breaks a
      blocking read. Run via `zig test src/platform/pty_posix.zig -lc`.

### Phase D — Native macOS port (next port target; Linux deferred)

The actual port work, gated on Phase A (GPU spine) and Phase C (POSIX PTY).
**Focus: macOS.** Per AGENTS.md, compare each track against Ghostty before
starting.

> **D-prep landed** (see `docs/superpowers/plans/2026-05-26-d-prep-gpu-neutralize.md`):
> the rendering layer is fully backend-neutral (no raw `gl.*`, guard-enforced), a
> `gpu/metal/` skeleton mirrors `gpu/opengl/api.zig`, the project cross-compiles
> to `aarch64-macos`, and the macOS pty constants are in. Starting macOS =
> fill in Metal/AppKit/CoreText bodies against a building skeleton — no
> core/OpenGL refactoring needed on the Mac.
>
> **D1 Metal interface landed:** the `gpu/metal/` skeleton now owns a real
> `MTLDevice`/command queue/`CAMetalLayer` context, retained `MTLBuffer` and
> `MTLTexture` registries, `MTLRenderPipelineState` compilation, offscreen color
> texture targets, MSL shader sources, and a native `zig build test-metal` smoke
> path that encodes and commits a simple Metal draw.

macOS reuses the platform-neutral core; it needs a Metal GPU backend,
an AppKit host, CoreText fonts, `_macos` siblings of the `_windows` platform
services, and `.app` packaging. Ghostty reference: `src/renderer/metal/`,
`macos/` (AppKit app + GhosttyKit), `src/font/discovery.zig` (CoreText),
`src/apprt/embedded.zig`.

**D0 — Build & target plumbing**
- [x] `build.zig`: a macOS target path (`aarch64-macos` / `x86_64-macos`), link
      frameworks (Metal, QuartzCore, AppKit/Cocoa, CoreText, CoreGraphics,
      Foundation), and a `.app` artifact wired to the real `src/main.zig`
      desktop entrypoint. Keep the comptime guards
      (`build_guards`, `apprt_win32_guard`, `gl_backend_guard`) green for macOS.
      Native proof: `zig test build.zig`, `zig build macos-app -Dtarget=aarch64-macos`,
      `zig build macos-app -Dtarget=x86_64-macos`, `zig build test-metal`,
      `zig build test-full -Dtarget=aarch64-macos`, and
      `zig build test-full -Dtarget=x86_64-macos`.
- [x] Decide the ObjC interop seam: extern `objc_msgSend` from Zig vs. a thin
      ObjC/`.m` shim compiled in (Ghostty calls into `libghostty` from a Swift/
      ObjC app layer). Chosen boundary: a thin Objective-C shim at
      `src/renderer/gpu/metal/bridge.m` owns Objective-C/Metal message sends and
      exports C ABI functions to Zig; Zig keeps the backend API surface and
      stores opaque registry handles.

**D1 — Metal GPU backend** (`src/renderer/gpu/metal/`, mirrors `gpu/opengl/api.zig`)
- [x] `metal/api.zig` exporting the same surface as `opengl/api.zig`: `Context`
      (MTLDevice + command queue + `CAMetalLayer`), `Buffer`, `Texture` (incl.
      `upload2D`/`subImage2D`/`levelWidth` the font atlas uses), `Pipeline`
      (`MTLRenderPipelineState`), `Framebuffer` (offscreen `MTLTexture` target),
      `shaders`. Wire `gpu.zig`'s `impl` switch `.metal => @import("metal/api.zig")`
      (replace the `@compileError`). Native proof: `zig build test-metal`
      covers context, buffers, textures, framebuffers, pipelines, vertex layout
      handles, compatibility helpers, and a committed simple draw. *Ghostty:
      `renderer/metal/`.*
- [x] **Neutralize the GL-shaped presentation layer (prerequisite).**
      `ui_pipeline.zig`, `cell_pipeline.zig`, and the render-coordination files
      still call `gpu.glTable()` directly (the residue `gl_backend_guard`
      documents) — OpenGL-only. Route their draws through the backend-dispatched
      `gpu.Pipeline`/`Buffer`/`Texture`/`Framebuffer` methods so they compile and
      render on Metal. This is guard-enforced by `gl_backend_guard`; only the
      documented AppWindow diagnostics/context residue still touches
      `gpu.glTable()`.
- [x] Port the shader set to MSL in `gpu/metal/shaders.zig` (the A5 slot already
      lists the symmetric set: text/glyph, instanced bg/fg cells, color-emoji,
      simple-textured, overlay). Native proof: `zig build test-metal` compiles
      every bundled MSL shader pair into `MTLRenderPipelineState`.

**D2 — AppKit host** (`window_backend_macos.zig` + `window_macos.zig`)
- [x] `NSApplication`/`NSWindow` + the AppKit run loop (AppKit owns the event
      loop and pumps the core — unlike the Win32 message pump). Add `.macos` to
      `window_backend.zig`'s `Backend` + impl switch. Native proof:
      `zig build test-macos-window`, `zig build test-full`, and
      `zig build test-full -Dtarget=aarch64-macos`.
- [x] Surface seam: `window_backend` currently exposes `glGetProcAddress` (a GL
      assumption). Add a Metal-drawable seam (hand the renderer a `CAMetalLayer`)
      so the host↔renderer contract is not GL-specific. Implemented as
      `window_backend.metalLayer()` with `AppWindow` dispatching Metal context
      init through the layer while OpenGL keeps `glGetProcAddress`.
- [x] Input/IME/DPI: `NSEvent` → the core's neutral `key_*` codes; mouse/scroll/
      trackpad; IME via `NSTextInputClient`; DPI via `backingScaleFactor`/`NSScreen`.
      Native proof: `zig build test-macos-window` covers key, text, mouse button,
      mouse move, wheel, IME preedit, Metal layer creation, and DPI.
- [x] Reconcile the app-drawn titlebar / caption buttons with macOS traffic-light
      conventions. macOS uses AppKit's titlebar/traffic lights (`titlebar_height`
      and caption button width are zero), so Phantty's app-drawn titlebar path
      skips itself while Windows keeps the custom caption metrics.

**D3 — CoreText fonts** (`font_discovery_macos.zig`, `font_backend_macos.zig`)
- [x] Discovery + fallback via CoreText (`CTFontCreateWithName`,
      `CTFontCopyDefaultCascadeListForLanguages`), rasterizing into the existing
      atlas/`gpu.Texture` path. Add `.macos` to `font_backend.zig` /
      `font_discovery.zig` backend selection. Implemented with a thin CoreText
      bridge for family lookup, file paths for FreeType atlas loading, glyph
      checks, cascade-list fallback, and Ghostty-style `CTFontCreateForString`
      fallback. Native proof: `zig build test-macos-font`, `zig test build.zig`,
      `zig build test`, `zig build test-full`, and
      `zig build test-full -Dtarget=aarch64-macos`.

**D4 — Platform services** (`_macos` siblings of the existing `_windows` impls)
- [x] clipboard (NSPasteboard), file_dialog (NSOpenPanel/NSSavePanel + drop),
      open_url (NSWorkspace), notifications (UNUserNotificationCenter),
      global_hotkey (Carbon `RegisterEventHotKey` or `CGEventTap`), cursor,
      display (NSScreen), session_lock, config_watcher (FSEvents/kqueue),
      console, text, update_package, dirs (`~/Library/Application Support`).
      Implemented as `_macos` siblings for clipboard, file dialogs/open URL,
      cursor, display, text, global hotkeys (Carbon `RegisterEventHotKey`),
      AppKit file drops, and update-package current-package detection; existing
      portable/no-op seams cover session_lock and console on macOS; dirs already
      resolve to `~/Library/Application Support/phantty`; config watching now
      uses kqueue `EVFILT_VNODE`. Phantty's current notification seam is bell +
      window attention (`NSBeep`/`requestUserAttention`); Ghostty's broader
      desktop-notification path uses `UNUserNotificationCenter` in its AppKit
      layer. Native proof: `zig build test-macos-services`,
      `zig build test-macos-window`, `zig test build.zig`, `zig build test`,
      `zig build test-full`, `zig build test-full -Dtarget=aarch64-macos`,
      `zig build test-metal`, and `zig build test-macos-font`.
- [x] **pty/process:** reuse the Phase C POSIX backend; add the **macOS ioctl
      request constants** (`TIOCSWINSZ`/`TIOCSCTTY`/`FIONREAD` differ from
      `std.os.linux.T`) so `pty.zig`'s `backendForOs(.macos)` can return `.posix`.
      (Deferred from Phase C; also revisit `O_CLOEXEC` on the master/cancel fds.)
      Native proof: `zig test src/platform/pty_posix.zig -lc`,
      `zig build test`, `zig build test-full`, and
      `zig build test-full -Dtarget=aarch64-macos`. macOS uses the BSD IOC
      constants, applies child startup sizing on the slave PTY, uses the slave
      side for explicit resize, and falls back to nonblocking `poll` when
      `FIONREAD` reports zero on a readable PTY master.

**D5 — Embedded browser**
- [x] WKWebView backend (`webview_macos.zig`) behind the `EmbeddedBrowserBackend`
      gate, or keep the panel disabled on macOS until viable.
      Chosen for this port slice: keep disabled on macOS until a real WKWebView
      backend is designed. `build.zig` maps macOS to
      `EmbeddedBrowserBackend.none`, rejects `-Dwebview` without a supported
      backend, and does not compile the WebView2 bridge for macOS; `webview.zig`
      selects `.unsupported` for macOS. Ghostty has no equivalent embedded
      browser panel (`gh search code 'WKWebView repo:ghostty-org/ghostty'`
      returned no matches). Proof: `zig test build.zig` and
      `zig build test-full -Dtarget=aarch64-macos`.

**D6 — Packaging & distribution**
- [x] `.app` bundle + `Info.plist`; code signing + notarization; `.dmg`. Updater
      story (adapt the existing portable updater or adopt Sparkle).
      Implemented a `macos-dist` build step, `packaging/macos/package.sh`, and
      `packaging/macos/Phantty.entitlements`. Local builds ad-hoc sign with
      hardened runtime and create `zig-out/dist/macos/phantty-macos-vX.Y.Z.dmg`;
      release builds set `PHANTTY_MACOS_SIGN_IDENTITY` and
      `PHANTTY_MACOS_NOTARY_PROFILE` to enable Developer ID signing,
      `notarytool submit --wait`, and stapling. The macOS updater story is:
      initial macOS releases publish a matching DMG asset selected by the
      existing update checker (`phantty-macos-{tag}.dmg`) and saved to
      Downloads; a full automatic updater should follow Ghostty's Sparkle
      approach once the macOS release-update flow is ready for unattended
      replacement. Ghostty
      reference: its release workflow signs nested code and app with hardened
      runtime, creates a DMG, notarizes/staples app + DMG, and generates Sparkle
      appcast metadata. Proof: `zig build macos-dist -Dtarget=aarch64-macos`,
      `codesign -dvvv --entitlements :- zig-out/bin/Phantty.app`,
      `hdiutil verify zig-out/dist/macos/phantty-macos-v0.32.0.dmg`,
      `zig test build.zig`, `zig build test`, `zig build test-macos-services`,
      `zig build test-full`, and `zig build test-full -Dtarget=aarch64-macos`.

Critical path to "a shell renders on screen": **D0 → D1 (Metal + presentation-
layer neutralization) → D2 (AppKit host + drawable seam) → D3 (CoreText) → the
macOS pty constants in D4.** Services / webview / packaging follow.

### Linux — deferred

Postponed in favor of the macOS port. The groundwork already exists (Phase A
renderer abstraction, Phase C Linux PTY), so the remaining work is a Linux host
(GTK/libadwaita or another toolkit + event loop wired to the reusable OpenGL
backend), fontconfig discovery + fallback, XDG dirs and the `_linux`/POSIX
platform services, WebKitGTK (or keep disabled), and packaging. Revisit once the
macOS port lands.

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
