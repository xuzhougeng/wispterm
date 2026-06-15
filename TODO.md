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
  backends) is now the gate. See guide §1. **D1.y render-correctness work done:
  per-pane viewport/scissor (P0, fixes the split bug), blend-mode PSO variants
  (P1), sampler filter/wrap (P2), and frame throughput (P3) all land + verify on
  three platforms. The only D1.y item left — FBO render-target switching — is
  DEFERRED into a separate "macOS custom-shader" feature, because its sole
  consumer (post-process GLSL) needs a GLSL→MSL layer before an FBO is useful on
  Metal. See D1.y.**
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

- [x] **B1** `input.zig`: extract keybind parsing + command dispatch from
      platform input handling into pure, unit-testable modules. Done via targeted
      pure-module extraction (no global struct-ification): `input/click_tracker.zig`
      (multi-click counter), `input/hit_test.zig` (sidebar geometry over a
      `SidebarLayout` descriptor), `input/command_dispatch.zig` (pure
      `resolve(action, phase) → ?Command`; `input.zig` keeps `executeCommand`).
      19 std-only unit tests, run in the fast loop via `test_fast.zig` and
      regression-locked in `test_main.zig`; `input.zig` 3573 → 3467 ln. Spec/plan:
      `docs/superpowers/{specs/2026-05-27-b1-input-decouple-design,plans/2026-05-27-b1-input-decouple}.md`.
      Native proof: `zig build test` (268 tests) and
      `zig build test-full -Dtarget=x86_64-windows-gnu`.
- [x] **B2** `ai_chat.zig`: separate conversation/state/protocol logic from UI
      state into independently testable sub-modules. Done via targeted pure-module
      extraction (Session/threads/tooling/network untouched): `ai_chat_input_text.zig`
      (UTF-8/visual-cursor/wrap geometry), `ai_chat_composer.zig` (slash/skill/composer
      suggestion parsing), `ai_chat_protocol.zig` (API wire format — protocol types +
      request-JSON building via a `RequestParams` seam + response parsing). `ai_chat.zig`
      delegates via re-export aliases; 7051 → 6003 ln. Modules run in the fast loop
      (`test_fast.zig`) + regression-locked in `test_main.zig`. Spec/plan:
      `docs/superpowers/{specs/2026-05-27-b2-ai-chat-decouple-design,plans/2026-05-27-b2-ai-chat-decouple}.md`.
      Native proof: `zig build test` and `zig build test-full -Dtarget=x86_64-windows-gnu`.
- [x] **B3** `AppWindow.zig`: layer tab/split orchestration, render
      orchestration, and input routing (GL binding removed in A2). Tab/split
      orchestration was already layered into `appwindow/{tab,split_layout,thread_message}.zig`
      by prior work; B3 finishes by extracting the remaining pure decision logic
      into testable modules (Session/threads/GL/frame-loop untouched):
      `appwindow/flush_scheduler.zig` (agent-history flush debounce; replaced 2
      globals + a const) and `ime_caret.zig` extensions (`pixelPosition` placement
      math + `StabilityTracker` two-frame commit decision; replaced 6 threadlocal
      globals). `AppWindow.zig` 4045 → 4003 ln, 47 → 41 globals. Spec/plan:
      `docs/superpowers/{specs/2026-05-27-b3-appwindow-decouple-design,plans/2026-05-27-b3-appwindow-decouple}.md`.
      Native proof: `zig build test` and `zig build test-full -Dtarget=x86_64-windows-gnu`.
- [x] **B4** Unit tests for the extracted pure logic (`zig test`). Satisfied across
      B1–B3: every extracted pure module ships std-only `test` blocks that run in the
      fast `zig build test` loop (registered in `test_fast.zig`) and are
      regression-locked in `test_main.zig` — `input/{click_tracker,hit_test,command_dispatch}.zig`,
      `ai_chat_{input_text,composer,protocol}.zig`, `appwindow/flush_scheduler.zig`,
      and the `ime_caret.zig` additions.

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
      `zig build test-metal`, `zig build test-macos-ui`, and
      `zig build test-full -Dtarget=aarch64-macos`.
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
- [x] **Neutralize the GL-shaped presentation layer (prerequisite, call sites only).**
      `ui_pipeline.zig`, `cell_pipeline.zig`, and the render-coordination files
      no longer call `gpu.glTable()` directly (guard-enforced by
      `gl_backend_guard`); only the documented AppWindow diagnostics/context
      residue still touches `gpu.glTable()`. **However, this only neutralized the
      call sites — the Metal-backend implementations of those primitives are
      still partial. See D1.x below.**
- [x] **D1.x — Wire the Metal `gl_init` stub to `ui_pipeline` (macOS UI gap).**
      Root cause turned out to be two narrow bugs, not the missing-pipeline
      story I originally feared. The MSL shaders and the `gpu.Pipeline`/
      `Buffer`/`Texture` primitives were already complete enough for
      `ui_pipeline.fillQuad`; the call never made it to the GPU because:
      1. `src/renderer/gpu/metal/gl_init.zig`'s `renderQuad`/`renderQuadAlpha`/
         `setProjection` were stubs that dropped their arguments. In
         particular, `setProjection` only updated the viewport — it never
         pushed the orthographic projection into the text pipeline's
         uniforms, so every vertex came out at `(0, 0, 0, 0)` in clip space.
         Now they dispatch through a `BackendHooks` function-pointer table
         registered by `ui_pipeline.init()` (the indirection is needed because
         `test-metal`'s module root sits inside `gpu/metal/`, which forbids
         walking out to `renderer/ui_pipeline.zig` with a static `@import`).
      2. `wispterm_metal_buffer_upload` reused the same `MTLBuffer` storage
         across uploads (`memcpy([buffer contents])`). Metal's
         `setVertexBuffer:offset:atIndex:` captures the buffer pointer at
         encoding time but the GPU only reads its bytes at command-buffer
         commit, so successive `ui_pipeline.fillQuad` calls all shared the
         last upload — every overlay piled up at the same coordinates and
         the prior contents were silently overwritten. Upload now always
         allocates a fresh `MTLBuffer`; Metal's encoder retain keeps the
         prior one alive until the command buffer completes, then drops it
         asynchronously.
      Native proof: `zig build test-metal` (new hook-dispatch assertion),
      `zig build test-macos-ui`, `zig build test`, and
      `zig build test-full -Dtarget=aarch64-macos`; plus the macOS app now
      renders the tab sidebar, NSMenu "Open Command Center" overlay, SSH
      Server / AI Agent forms, and settings page with backgrounds, borders,
      selection highlights, and text all visible.
- [x] Port the shader set to MSL in `gpu/metal/shaders.zig` (the A5 slot already
      lists the symmetric set: text/glyph, instanced bg/fg cells, color-emoji,
      simple-textured, overlay). Native proof: `zig build test-metal` compiles
      every bundled MSL shader pair into `MTLRenderPipelineState`.

**D1.y — Metal render-state application (split / scissor / blend) — INCOMPLETE**

> **Found on-device (2026-05-28):** creating a split pane on macOS renders both
> panes blank and draws the shell prompt over the title bar (the split *logic*
> is fine — `Split created: ... tree nodes: 3`). Root cause: the Metal backend
> **records render state into thread-locals but never applies it to the
> `MTLRenderCommandEncoder`.** A single full-window surface accidentally hides
> this (origin is `(0,0)`, nothing needs clipping, plain alpha blend is enough);
> the moment a feature needs a sub-rectangle origin, a clip, or a non-alpha
> blend, it breaks. So D1's "Metal GPU backend" is functionally complete only
> for the full-window single-surface path. The state-application layer below is
> the real gap.
>
> **Architecture note vs. Ghostty.** Ghostty renders each terminal surface into
> its **own** `NSView` + `CAMetalLayer`; AppKit's split container lays the views
> out, so each Metal renderer instance owns a drawable that *is* the pane — it
> never needs per-pane viewport/scissor inside one drawable. WispTerm instead
> keeps **one window / one `CAMetalLayer` / one drawable** and renders every pane
> in a loop with per-pane viewport + scissor (symmetric with its Windows OpenGL
> path: `AppWindow.zig:3893-3947`). **Decision: keep WispTerm's single-drawable
> model and make Metal honor `setViewport:`/`setScissorRect:` per draw** (Option
> A — symmetric with OpenGL, low risk, no AppKit/host rework). Option B (one
> layer per surface, Ghostty-style) is a much larger host refactor and is *not*
> chosen here.
>
> **Verified against Ghostty/cmux (2026-05-28).** Ghostty's Metal renderer is
> one `IOSurfaceLayer` + one renderer instance **per surface**; its
> `metal/RenderPass.zig` calls **neither** `setViewport` **nor**
> `setScissorRect` — the drawable *is* the pane, so padding rides in the
> projection/cell coordinates and clipping is unneeded. cmux is a Ghostty-based
> macOS terminal (vertical tabs, splits, embedded browser, agent socket API) and
> inherits this rendering model. WispTerm's single-drawable choice is the
> deliberate trade for sharing one render loop with Windows; the cost is that
> WispTerm **must** implement the per-draw `setViewport:`/`setScissorRect:` that
> Ghostty sidesteps. That is standard Metal usage (an encoder's viewport and
> scissor are mutable between draws), so **the architecture is sound — only the
> application step is missing.** Keep Option A; revisit per-surface layers
> (Option B) only if multi-split frame pacing on the single render thread ever
> becomes a problem.

- [x] **P0 — Apply viewport origin to the encoder (fixes split positioning).**
      Done. `render_state.setViewport` now forwards to the C bridge
      (`wispterm_metal_set_viewport`); `wispterm_metal_apply_viewport_scissor`
      emits `[encoder setViewport:]` before every draw with the GL bottom-left →
      Metal top-left flip (`originY = drawable_h - y - h`, drawable size captured
      at frame begin). `metal/gl_init.zig:setProjection` no longer clobbers the
      viewport to `(0,0)`; projection stays width/height-only (origin honored by
      the encoder viewport, like OpenGL's `glViewport`). Proof: `zig build
      test-metal` (new viewport/scissor assertion), `zig build test-full
      -Dtarget=aarch64-macos`, `zig build -Dtarget=x86_64-windows-gnu` (no
      regression). **On-device split visual check still pending.**
- [x] **P0 — Apply scissor to the encoder (fixes clip overflow).** Done.
      `setScissor`/`disableScissor`/`restoreScissor` forward to
      `wispterm_metal_set_scissor`; the apply helper emits
      `[encoder setScissorRect:]` per draw — enabled → recorded box (y-flipped),
      disabled → full drawable (Metal has no "scissor off"). The rect is
      **clamped to the drawable** (an out-of-bounds `MTLScissorRect` raises and
      kills the command buffer); the test-metal assertion feeds a deliberately
      out-of-bounds box to lock the clamp. Unblocks
      `markdown_preview_renderer.zig:610-614` and `ui_pipeline.zig:110-121`.
- [x] **P1 — Blend modes as pipeline variants (fixes color-emoji / bg image).**
      Done. `pipeline_create` now builds three `MTLRenderPipelineState` variants
      per shader via `wispterm_metal_make_pso` (alpha `(src_alpha,1-src_alpha)` /
      premultiplied `(one,1-src_alpha)` / blending-disabled);
      `wispterm_metal_set_blend_enabled`/`wispterm_metal_set_blend_mode` record the
      state and `encode_draw` selects the matching PSO. `render_state.setBlendMode`/
      `setBlendEnabled` now forward instead of no-op'ing, so `cell_renderer.zig:425`
      (premultiplied color emoji) and `background_image.zig:215`
      (`setBlendEnabled(false)` opaque wallpaper) behave like the OpenGL backend.
      Proof: `zig build test-metal` (new blend-variant assertion). **On-device
      visual check (emoji brightness, wallpaper) still pending.**
      *Ghostty does this differently and more simply: `metal/Pipeline.zig` uses
      **one** blend config everywhere — premultiplied alpha (`src=one`,
      `dst=one_minus_source_alpha`; comment: "We always use premultiplied alpha
      blending for now") — and every fragment shader emits premultiplied color.
      That removes `setBlendMode` entirely and structurally avoids the
      color-emoji double-multiply. **Long-term WispTerm should consider converging
      on this** (rewrite each MSL fragment shader to output premultiplied RGB, so
      one PSO blend config serves all draws) instead of carrying alpha +
      premultiplied PSO variants; short-term the variants are the lower-risk fix.*
- [x] **P2 — Sampler filter/wrap state (fixes `nearest` blur).** Done. The four
      texture-sampling MSL shaders now take `sampler s [[sampler(0)]]` instead of
      a hard-coded `constexpr sampler`; `bridge.m` lazily builds an
      `MTLSamplerState` per (filter, wrap) and `encode_draw` binds it with
      `setFragmentSamplerState:` from the active texture's recorded filter/wrap;
      `Texture.upload2D` now forwards `o.filter`. Default behavior is unchanged
      (everything currently uses linear/clamp) but `.nearest` is now honored.
      Proof: `zig build test-metal`, `zig build test-full -Dtarget=aarch64-macos`.
      *Mirrors Ghostty's dedicated `metal/Sampler.zig` + `setFragmentSamplerState:`.*
- [ ] **P2 — Framebuffer render-target switching — DEFERRED (needs a GLSL→MSL
      path first; not a standalone task).** Evaluated 2026-05-28. The FBO itself
      has a clean Metal equivalent — render-to-texture (end the current encoder,
      open a new render pass whose color attachment is the offscreen `MTLTexture`,
      restore on `unbind`); `metal/Framebuffer.zig` already holds the texture, only
      `bind`/`unbind` need to switch the render pass. **But its only consumer is
      `post_process.zig`, whose custom shaders are Shadertoy-style GLSL**
      (`#version 330 core` + `mainImage`, wrapped in `buildPostFragmentSource`).
      **Metal cannot compile GLSL** (it runs MSL), so even with the FBO wired up
      the user's `custom-shader` would not run on macOS — the FBO would have no
      working consumer. The real macOS work is a **GLSL→MSL translation layer**,
      exactly what Ghostty does in `src/renderer/shadertoy.zig`: GLSL →SPIR-V
      (glslang) →MSL (SPIRV-Cross), so one Shadertoy GLSL runs on every backend.
      → Track this as a separate **"macOS custom-shader support"** feature (FBO
      render-to-texture **plus** the glslang+SPIRV-Cross translation + the
      Shadertoy uniform struct), not as part of D1.y's render-correctness scope.
      `g_post_enabled` defaults off and `fbo.zig` is currently un-wired, so there
      is no regression today.
- [x] **P3 — Frame throughput.** Done. `wispterm_metal_frame_end` no longer calls
      `waitUntilCompleted` every frame (that serialized CPU and GPU with zero
      overlap); GPU errors are now reported via `addCompletedHandler` and our own
      command-buffer/drawable refs are released right after `commit` (Metal
      retains them until the GPU finishes + the frame presents). Proof: `zig build
      test-metal`, `zig build test-full -Dtarget=aarch64-macos`. **On-device
      frame-pacing/no-flicker check still pending.** Per-upload fresh `MTLBuffer`
      allocation (intentional, `bridge.m` comment) can later become a ring buffer
      if profiling shows it matters.

> **Native proof for D1.y:** extend `zig build test-metal` with viewport-origin,
> scissor-rect, and blend-variant assertions; keep `zig build test-full
> -Dtarget=aarch64-macos` green; and verify on-device that a split positions both
> panes correctly with no clip overflow, color emoji render at full brightness,
> and the markdown preview / file explorer clip to their regions.

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
      mouse move, wheel, IME preedit, Metal layer creation, and DPI; `zig build
      test-macos-ui` covers sidebar, command center, and settings/config UI
      smoke paths.
- [x] Reconcile the app-drawn titlebar / caption buttons with macOS traffic-light
      conventions. macOS uses AppKit's titlebar/traffic lights (`titlebar_height`
      and caption button width are zero), so WispTerm's app-drawn titlebar path
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
      resolve to `~/Library/Application Support/wispterm`; config watching now
      uses kqueue `EVFILT_VNODE`. WispTerm's current notification seam is bell +
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
      `packaging/macos/WispTerm.entitlements`. Local builds ad-hoc sign with
      hardened runtime and create `zig-out/dist/macos/wispterm-macos-vX.Y.Z.dmg`;
      release builds set `WISPTERM_MACOS_SIGN_IDENTITY` and
      `WISPTERM_MACOS_NOTARY_PROFILE` to enable Developer ID signing,
      `notarytool submit --wait`, and stapling. The macOS updater story is:
      initial macOS releases publish a matching DMG asset selected by the
      existing update checker (`wispterm-macos-{tag}.dmg`) and saved to
      Downloads; a full automatic updater should follow Ghostty's Sparkle
      approach once the macOS release-update flow is ready for unattended
      replacement. Ghostty
      reference: its release workflow signs nested code and app with hardened
      runtime, creates a DMG, notarizes/staples app + DMG, and generates Sparkle
      appcast metadata. Proof: `zig build macos-dist -Dtarget=aarch64-macos`,
      `codesign -dvvv --entitlements :- zig-out/bin/WispTerm.app`,
      `hdiutil verify zig-out/dist/macos/wispterm-macos-v0.32.0.dmg`,
      `zig test build.zig`, `zig build test`, `zig build test-macos-services`,
      `zig build test-full`, and `zig build test-full -Dtarget=aarch64-macos`.

Critical path to "a shell renders on screen": **D0 → D1 (Metal + presentation-
layer neutralization) → D2 (AppKit host + drawable seam) → D3 (CoreText) → the
macOS pty constants in D4.** Services / webview / packaging follow.

**D7 — Native macOS app menu (NSMenu)**
- [x] **D7.1 NSMenu skeleton.** WispTerm had no application menu on macOS — the
      only way to reach the command center, settings, or sidebar toggle was the
      keyboard shortcut, which gets eaten by IME/remote-control software
      (ToDesk, etc.). Added a thin Objective-C bridge
      (`src/platform/menu_macos_bridge.m`) that builds the standard macOS
      menu set (`WispTerm / File / Edit / View / Window`) with menu items wired
      to the existing keybind `Action` enum: Open Command Center
      (`⌃⇧P`), Settings… (`⌘,`), New Tab (`⌃⇧T`), New Window (`⌃⇧N`),
      Toggle Tab Sidebar (`⌃⇧B`), Toggle File Explorer (`⌃⇧⌥E`), Split Right
      (`⌃⇧O`), Equalize Splits (`⌃⇧Z`), Next/Previous Tab, Minimize, Zoom.
      A C ABI shim hands action ids back to Zig
      (`src/platform/menu_macos.zig`) which dispatches via
      `input.invokeKeybindAction`. Bonus: NSMenu key equivalents are handled
      earlier in the AppKit responder chain than `keyDown:`, so they keep
      working even when third-party utilities intercept the chord at the
      `keyDown:` layer. Native proof: `zig build test-macos-menu`
      validates menu install, item count, action encoding, and round-trip
      decode; covered also by `zig build test-full -Dtarget=aarch64-macos`.
- [ ] **D7.2 Menu items reflect runtime state.** Add NSMenuItem validation:
      grey out actions when no surface is focused, mark the sidebar/command-
      center items checked when the panel is currently visible, surface the
      configured shortcut text from `keybind.Set` instead of hardcoded
      equivalents (so user remaps show in the menu).
- [ ] **D7.3 Localize menu titles.** Currently English-only; add a localized
      string table that matches the rest of WispTerm's locale story.

### Phase D8 — macOS window lifecycle, native title bar & CJK fallback

Polish/bugfix pass after the D-phase skeleton landed. Surfaced by real on-device
use; the Windows port (`builtin.os.tag != .macos`) is unchanged throughout —
every behavior is gated behind a macOS check. Status: implemented, builds clean
for both `aarch64-macos` and the default `x86_64-windows-gnu`; on-device
verification in progress.

- [x] **D8.1 Close button keeps the process alive (Terminal.app / VS Code
      semantics).** The red traffic-light used to tear down the whole process.
      Added `WispTermAppDelegate` in `window_macos_bridge.m`:
      `applicationShouldTerminateAfterLastWindowClosed:` → NO,
      `applicationShouldHandleReopen:hasVisibleWindows:` sets an atomic reopen
      flag, `applicationShouldTerminate:` sets a quit flag and `performClose:`-es
      every live window then returns `NSTerminateCancel` (zig owns shutdown).
      Bridge exposes `consume_reopen` / `consume_quit` / `request_quit` /
      `pump_events(timeout)`; wired through `window_macos.zig` → `window.zig`
      facade → `window_backend.zig` (no-op stubs for Windows/unsupported). On
      macOS the close button now sets `g_should_close` directly (no confirm
      overlay). `App.run()` runs the first window on the main thread, then enters
      `macIdleUntilQuit()`: blocks in `pumpAppEvents(0.25)`, spawns a fresh window
      on Dock reopen, returns on quit.
- [x] **D8.2 Dock reopen spawns on a worker thread, not the main thread.**
      Reusing the main thread for a second window session resurfaced
      "single-run" thread-local state (font caches, atlas handles, UI flags).
      Reopen now calls `requestNewWindow(null, null)` (same path as `⌃⇧N`), so
      the new window's thread-locals start at their declared defaults. Also fixed
      two latent single-run bugs this exposed: `AppWindow.zig` shutdown defer now
      resets `font.icon_cache` / `font.g_titlebar_cache` to `.empty` after
      `deinit` (a re-entrant `clearTitlebarFont` was double-freeing dangling
      hash-map metadata → `incorrectAlignment` panic).
- [x] **D8.3 NSWindow operations marshalled to the main thread (crash fix).**
      Root macOS-port architecture bug: every `AppWindow` runs its event/render
      loop on a spawned thread but called NSWindow APIs directly, tripping
      AppKit's "Must only be used from the main thread" assertion (crashed in
      `setContentSize` → `-[NSWMWindowCoordinator performTransactionUsingBlock:]`
      on resize/reopen). Added `wispterm_macos_run_on_main(block)` (inline on the
      main thread, else `dispatch_sync` to the main queue) and wrapped
      `set_content_size` / `set_frame` / `show` / `hide` / `make_key` / `zoom` /
      `destroy`. `window_poll` only pumps `[NSApp nextEvent]` on the main thread
      (worker threads just sync the Metal layer; AppKit dispatches their events to
      the window delegate which fills the per-window buffer). `pump_events` gained
      a blocking `timeout` so the main run loop drains the GCD main queue —
      otherwise worker `dispatch_sync` would deadlock against a spin-sleep.
- [ ] **D8.3a Event buffer cross-thread safety (follow-up).** The per-window
      key/char/mouse/file-drop/message ring buffers in `window_macos_bridge.m` are
      SPSC and lock-free; with D8.3 the producer is now the main thread (AppKit
      delegate) and the consumer is the worker thread. Add an `os_unfair_lock` (or
      atomic head/count) before relying on this under load — watch for dropped
      keystrokes / input lag as the symptom.
- [x] **D8.4 Unified title bar + traffic-light-aware toggle placement.** macOS no
      longer shows the empty native title strip above WispTerm's own bar. NSWindow
      gains `NSWindowStyleMaskFullSizeContentView` + `titlebarAppearsTransparent`
      + `titleVisibility = NSWindowTitleHidden`, so the app-drawn titlebar extends
      under the traffic lights (Codex / VS Code style). `titlebar.zig` reserves a
      DPI-scaled strip on the left (`titlebarLeftReserved()` = 80 logical px ×
      `g_dpi/96`, in framebuffer pixels) so the sidebar-toggle hamburger and tab
      title sit to the right of the red/yellow/green controls; `input.zig`
      hit-tests shift to match. (Supersedes the D2 note that macOS skips the
      app-drawn titlebar entirely.)
- [ ] **D8.4a Draggable titlebar region (follow-up).** With the native title bar
      hidden the window is only draggable via the traffic-light gaps. Give the
      non-interactive part of the app-drawn titlebar a window-drag affordance
      (`-mouseDownCanMoveWindow` / a hit-test drag region).
- [x] **D8.5 CJK fallback no longer renders tofu.** macOS 26 moved PingFang into
      `PrivateFrameworks/.../Reserved/PingFangUI.ttc`, a system-reserved `.ttc`
      that FreeType cannot open (`FT_New_Face` → err 144) — and CoreText's default
      cascade prefers exactly that font, so every CJK glyph fell through to a
      blank box. `font/manager.zig`: `preferredFallbackFamilies` gained a macOS
      branch listing FreeType-loadable public system fonts (`Hiragino Sans GB`,
      `Songti SC`, `Heiti SC`, `STHeiti`, …); `findOrLoadFallbackFace` was
      restructured to try candidates in priority order (config → preferred →
      CoreText default), each validated by `openFallbackFreetypeFace` which
      actually opens the file with FreeType and confirms the glyph exists — so an
      unloadable reserved font no longer aborts the lookup. First candidate
      (`Hiragino Sans GB` → `/System/Library/Fonts/Hiragino Sans GB.ttc`) resolves
      cleanly.
- [ ] **D8.6 Window position persistence is wrong on macOS (known bug, not yet
      fixed).** `window_state.zig` saves `rect.left/top`, but on macOS
      `wispterm_macos_rect_from_nsrect` stores `NSMinY` (the window's *bottom* edge
      in AppKit's bottom-left origin) into the `top` field. Combined with
      `isPointOnAnyDisplay` only validating a single `(x+50, y+50)` point, a
      previously off-screen / multi-monitor position can be restored off-screen.
      Fix: translate NSRect into Windows-style top-left semantics (or persist
      native AppKit coords separately), validate the whole frame against
      `visibleFrame`, and default new windows to `[NSWindow center]` / cascade
      instead of the hard-coded `(120, 120)`.

### macOS UI status (post D1.x + D7.1 + D8)

| Feature | Status on macOS |
|---|---|
| Terminal text rendering | ✅ works (cell pipeline + CoreText/FreeType) |
| CJK / 中文 rendering | ✅ fixed in D8.5 (public-font fallback; PingFang reserved-ttc was unloadable) |
| Default shell | ✅ `zsh` (was `sh` until 2026-05-27) |
| NSMenu (WispTerm / File / Edit / View / Window) | ✅ visible, clickable, key equivalents fire |
| Window title bar | ✅ unified — app-drawn bar extends under traffic lights (D8.4) |
| Close button (red) | ✅ closes window, keeps process in Dock; Dock icon reopens (D8.1) |
| cmd+Q | ✅ tears down the whole app (D8.1) |
| Window resize / reopen | ✅ no longer crashes — NSWindow ops marshalled to main thread (D8.3) |
| Command center / settings page / SSH form / AI form / session launcher | ✅ render fully (panels, borders, selection highlights, text) |
| Tab sidebar | ✅ renders rows, selection highlight, tab numbers |
| File explorer panel | ✅ unblocked by D1.x; verify icons/scroll on real workloads |
| Markdown / image preview | ✅ unblocked by D1.x; verify chrome on real previews |
| Quake-style drop-down | ✅ window position + overlay rendering |
| Window position restore | ⚠️ buggy on macOS (D8.6 — coordinate-system mismatch) |
| Draggable titlebar | ⚠️ only via traffic-light gaps until D8.4a |
| Embedded browser panel | ❌ disabled (D5 — no WKWebView backend yet) |

### Silent platform stubs — audit 2026-06-15

A code audit of every `src/platform/*` facade for the clipboard image-paste
shape (facade wired, but a platform's `backendForOs` resolves to a
`*_unsupported`/no-op impl, so the capability silently does nothing with no
error surfaced). macOS items are the priority (active port); Linux items fold
into the Linux-host work below.

**macOS:**
- [x] Clipboard image paste (`readImageAsPngTemp`) — fixed (PR #228).
- [x] File dialog type filters + save default-extension — fixed: `file_dialog_macos.zig`
      derives `NSOpenPanel`/`NSSavePanel.allowedFileTypes` from the filter
      patterns and auto-appends the save extension (previously `_ = request.filters`).
- [ ] **Remote-relay client (`remote_transport`)** — macOS **and** Linux resolve to
      `.unsupported` (`remote_transport.zig:11-14`); with `remote-enabled = true`
      the relay never connects — `remote_client.zig:321` errors, only a
      `std.debug.print` to stderr, then a perpetual 2s reconnect loop. No UI
      error. Add `remote_transport_posix.zig` (macOS `NSURLSessionWebSocketTask`
      bridge like `http_client_macos_bridge.m`; Linux minimal RFC6455 over
      `std.net` + `std.crypto.tls`), route `.macos|.linux → .posix`. **HIGH.**
- [ ] **Single-instance session lock (`session_lock`)** — macOS+Linux use
      `session_lock_local_process` whose `reserveSessionKey` always returns
      success (`:11-15`); no cross-process lock (Windows uses a named mutex), so
      a double-launched/restored session key isn't detected. Add
      `session_lock_posix.zig` (`flock`/`O_CREAT|O_EXCL` lockfile). **MEDIUM.**
- [ ] **Process memory HUD (`memory`)** — macOS+Linux → `memory_unsupported`
      (`queryProcess` null); the debug memory overlay line is blank. Add
      `memory_macos.zig` (`task_info`/`TASK_VM_INFO`) and `memory_linux.zig`
      (`/proc/self/status`). **LOW** (developer diagnostic only).
- [ ] **Cooperative blocking-thread shutdown (`thread_control`)** — macOS+Linux →
      `thread_control_unsupported` (no-op); a WeChat login/poll worker stuck in a
      long-poll is force-killed at quit instead of cooperatively cancelled
      (`weixin/controller.zig:397`). Add `thread_control_posix.zig`
      (`pthread_kill` interrupt + timed join). **LOW** (only with WeChat).

**Linux (in addition to the deferred Linux host below):**
- [ ] **Quake-mode global hotkey** — `global_hotkey_unsupported.register()` →
      false; `quake-mode` never binds a system-wide hotkey, and the
      "already registered by another app" print (`AppWindow.zig:6532`) is
      misleading. Add `global_hotkey_linux.zig` (X11 `XGrabKey` / Wayland
      global-shortcuts portal), mirroring the macOS Carbon path.
- [ ] **Live config reload** — `config_watcher_unsupported.initPath()` → null;
      config edits need a full restart ("Config watcher not available",
      `AppWindow.zig:7749`). Add `config_watcher_linux.zig` (inotify), mirroring
      `config_watcher_macos.zig` (kqueue `EVFILT_VNODE`).
- [ ] **Auto-update asset detection** — `update_package.zig:48-60` has no
      `.linux` arm, so the update check can never match a Linux asset →
      `state.failed`. Add `update_package_linux.zig`.
- [ ] **Font family enumeration** — `font_discovery_linux.zig:119` returns an
      empty list; any font picker/auto-complete is blank (exact `font-family`
      still works). Implement via fontconfig `FcFontList`.
- [ ] **Off-screen window guard** — `display_portable.isPointOnAnyDisplay`
      always returns true; a restored window can open off-screen on Linux. Add
      an SDL3 `SDL_GetDisplayBounds` containment check.

**Doc corrections found in the same audit (code already done; text stale):**
- Embedded browser on macOS appears implemented (`webview_macos.zig` + WKWebView;
  `build.zig` maps macOS → webkit), but D5 (504-514) and the status table (676)
  still say "❌ disabled" — verify on-device and flip to ✅.
- Desktop notifications on macOS/Linux are implemented
  (`notifications_macos.zig` UNUserNotificationCenter; Linux `notify-send`), but
  D4 (486-492) still reads "bell + window attention only" — update the caveat.

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
