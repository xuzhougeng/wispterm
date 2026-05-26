# Decoupling Guide: UI vs. functionality, and the path to macOS

This guide is the engineering playbook for separating Phantty's **functionality**
from its **UI/platform layer**, so the macOS (and later Linux) port reuses the
terminal core and only swaps the host + GPU backend.

It builds on [`architecture.md`](architecture.md) (the named core ↔ host
contract) and drives the roadmap in [`../TODO.md`](../TODO.md). Where
`architecture.md` describes the *target* boundary, this guide audits the
*current* boundary, names what is still coupled, and sequences the work.

Per [`AGENTS.md`](../AGENTS.md), the terminal-app design tracks Ghostty as the
gold standard. Ghostty references are inline throughout and collected in
[§7](#7-ghostty-cross-reference).

---

## The two decoupling axes

"Decouple UI from functionality" splits into two distinct axes. Both are
required for the macOS port; they are worked in parallel (see
[§4](#4-execution-strategy-approach-c)).

- **Axis A — Portability seam (host swap).** The platform/host layer must be
  cleanly separable so a new platform implements a host + platform-service
  impls and reuses the core unchanged. This is the `architecture.md` contract.
- **Axis B — Presentation/logic separation.** Within the core, *what a feature
  does* must be separable from *how it is drawn and how input is handled*, so
  functionality is independently testable and can be driven by more than one
  UI. This is an internal-architecture concern, not a platform one.

Axis A makes a port *mechanically possible*; Axis B makes the port *cheap and
the core trustworthy*. The GPU backend abstraction sits on both axes: it is the
biggest missing piece of Axis A, and defining it forces a clean renderer
interface, which is Axis B for the rendering layer.

---

## 1. Current state audit

### Genuinely decoupled (Axis A, done and enforced)

The **platform-runtime** seam is real and guarded:

- App logic talks only to `src/platform/<cap>.zig` facades; no `std.os.windows`
  / `src/apprt/win32.zig` imports leak into the core.
- `main.zig` is a thin 149-line entry point.
- Comptime guards (`src/build_guards.zig`, `src/platform/apprt_win32_guard.zig`,
  facade scans in `src/test_main.zig`) fail the build / `zig build test` if
  Win32/DirectWrite/WebView2/WinHTTP names or raw OS handles leak through a
  facade, or if `build.zig` exposes target-OS booleans to app modules.
- Shared input/keybind code uses neutral `key_*` codes, not Win32 `VK_` names.

This part of the decoupling does not need rework.

### NOT decoupled (the real gaps)

**Gap 1 — The GPU graphics API (OpenGL) is not behind an interface.**

This is the single biggest blocker for macOS, which is **Metal-only** (Apple
deprecated OpenGL at 4.1; there is no OpenGL fallback on modern macOS — Ghostty
is Metal-only on Darwin). Evidence:

- ~**700 raw `gl.*` call sites across 16 files**. Heaviest:
  `gl_init.zig` (123), `titlebar.zig` (113), `overlays.zig` (72),
  `ai_chat_renderer.zig` (68), `post_process.zig` (66), `cell_renderer.zig`
  (62), `markdown_preview_renderer.zig` (44), `background_image.zig` (39),
  `fbo.zig` (33), `image_renderer.zig` (23), `file_explorer_renderer.zig` (17),
  plus the `overlays/` primitives.
- GL object handles (VAOs, VBOs, shader programs) live as **global
  `threadlocal var` state** in `gl_init.zig`.
- `AppWindow.zig` — which `architecture.md` calls "platform-neutral" —
  **directly `@cImport`s `glad/gl.h`** (`src/AppWindow.zig:61`) and is the hub
  that re-exports `gl` / `gl_init` to every renderer file (`AppWindow.gl`,
  `AppWindow.gl_init`).
- `src/renderer/Renderer.zig:14` admits the shortcut in a comment: *"GL
  operations are performed by AppWindow since it owns the GL context. Renderer
  just stores the handles."*
- `font/manager.zig` (`src/font/manager.zig:17`) `@cImport`s `glad/gl.h` and
  uploads the glyph atlas straight to GL textures (`GL_RED` / `GL_BGRA`).
- Shaders are **GLSL-only** (`shaders/glitchy.glsl` + embedded GLSL strings in
  `gl_init.zig`). Metal needs MSL.

**Correction to `TODO.md`.** The Phase 1 item *"keep the terminal rendering
core independent from the presentation backend … support multiple GPU backends
behind one interface"* was marked done. That checkbox is only half true: the
renderer has **no platform-runtime leakage** (no win32/DirectWrite/WebView2 —
true ✅), but the **GPU API itself is not behind an interface** (false ❌). The
two claims are split in the updated roadmap.

**Gap 2 — Several files conflate presentation with business logic (Axis B).**

Large files mix *what a feature does* with *how it is drawn / how input is
routed*, which makes the logic hard to test and hard to reuse under a different
host:

| File | Size | What is tangled |
|------|------|-----------------|
| `src/ai_chat.zig` | 248 KB | AI conversation/state/protocol logic + UI state |
| `src/renderer/overlays.zig` | 171 KB | Many unrelated overlay renderers in one module |
| `src/AppWindow.zig` | 149 KB / 3,742 ln | Window orchestration + GL binding + tab/split + input routing |
| `src/input.zig` | 136 KB / 3,462 ln | Platform input handling + keybind parsing + command dispatch |
| `src/renderer/ai_chat_renderer.zig` | 73 KB | Chat rendering (also a heavy `gl.*` site) |

These are not bugs; they are accreted responsibility. The roadmap decomposes
them along the presentation/logic line, touching each file once (see
[§4](#4-execution-strategy-approach-c)).

---

## 2. Target architecture: the GPU backend abstraction

The fix for Gap 1 is the abstraction Ghostty already ships and that
`Renderer.zig:4` already points at (`src/renderer/generic.zig`,
`src/renderer/opengl/Target.zig`).

### How Ghostty does it

- **`src/renderer/backend.zig`** — a `Backend` enum `{ opengl, metal, webgl }`
  with `default(target)` that returns **`.metal` on Darwin**, `.opengl`
  otherwise.
- **`src/renderer/generic.zig`** — *"Create a renderer type with the provided
  graphics API wrapper."* The renderer is generic over a `GraphicsAPI` type.
  Its documented abstraction hierarchy:

  ```
  [ GraphicsAPI ] — configures the runtime surface; provides Targets, Frames, Pipelines
       └─ [ Target ]     — an abstract render target (the surface, or an off-screen FBO)
  [ Frame ]      — context for drawing one frame; provides RenderPasses; reports frame health
  [ RenderPass ] — one or more Steps applied to the same target(s)
  [ Step ]       — input buffers + textures + vertex/fragment functions + geometry
  [ Pipeline ]   — a vertex+fragment function for a Step; built and cached ahead of time
  ```

- **`src/renderer/opengl/`** and **`src/renderer/metal/`** each expose the
  *same* primitive set: `Target`, `RenderPass`, `Frame`, `Pipeline`, `Buffer`,
  `Texture`, `Sampler`, `shaders` (Metal adds `IOSurfaceLayer`, `api`).
- **`cell.zig` / `cursor.zig` / `image.zig` / `row.zig`** stay API-agnostic —
  they build geometry/instances, not GL/Metal calls.

### Phantty target layout

Mirror Ghostty (per `AGENTS.md`) under `src/renderer/gpu/`:

```
src/renderer/gpu/
├── gpu.zig            # the GraphicsAPI interface (Target/Frame/RenderPass/Pipeline/Buffer/Texture/Sampler/shaders)
├── backend.zig        # Backend enum {opengl, metal}; default(target) → metal on Darwin
├── opengl/            # FIRST backend — wraps today's glad/gl.h code + gl_init handles
│   ├── Target.zig  Frame.zig  RenderPass.zig  Pipeline.zig
│   ├── Buffer.zig  Texture.zig  Sampler.zig  shaders.zig (GLSL)
└── metal/             # Phase D — mirrors opengl/, shaders.zig (MSL)
```

The renderer (`cell_renderer`, `titlebar`, `overlays`, …) issues draw work
through `gpu.zig` primitives instead of raw `gl.*`. The GL context moves out of
`AppWindow` and is owned by the backend/host seam.

---

## 3. Why both axes converge here

Routing a renderer file through `gpu.zig` requires reading and restructuring
that file's draw code — which is exactly the moment to separate its
presentation from its logic (Axis B). Doing both in one pass means each
renderer file is touched **once**, not twice. That convergence is why the
execution strategy leads with the GPU interface.

---

## 4. Execution strategy (Approach C)

**The GPU interface is the spine; we abstract-while-decomposing; PTY proceeds in
parallel.**

Rules that keep this safe:

1. **Windows stays shippable at every step.** No phase leaves `main` unbuildable
   on `x86_64-windows-gnu`.
2. **OpenGL is the live regression test for the interface.** Introduce
   `gpu.zig` with OpenGL as the first backend *behind it*; if Windows still
   renders correctly, the interface is sound. Metal joins later as a second
   backend, validated against the same interface.
3. **Touch each renderer file once** — route it through `gpu.zig` and split its
   presentation/logic in the same change.
4. **Compare against Ghostty per file** (`AGENTS.md`). The `opengl/` backend and
   the `gpu.zig` primitives should resemble Ghostty's, so the future `metal/`
   backend is a port, not a redesign.
5. **PTY/process (Phase C) runs in parallel** — it is independent of rendering
   and is the only piece fully verifiable off-Windows today (on Linux).

---

## 5. Phased roadmap

Dependency summary: **A** gates **D1** (Metal). **B** and **C** run in parallel
with **A**. **D** is deferred until a macOS SDK environment exists.

### Phase A — GPU interface spine
*Verifiable on Windows; OpenGL keeps working behind the new interface.*

> **Status (A1+A2 landed).** `src/renderer/gpu/gpu.zig` (comptime backend
> resolver) and `gpu/backend.zig` (`Backend{opengl,metal}`, `default→metal` on
> Darwin) exist. OpenGL is the first backend under `gpu/opengl/`
> (`c.zig`, `Context.zig`, `api.zig`, `gl_init.zig`, `shaders.zig`); the GL
> table + context load moved out of `AppWindow.zig`, which no longer `@cImport`s
> `glad`. Consumers reach the table via `AppWindow.gpu.glTable()` (a transition
> handle). Next: **A3** routes the renderer files through `gpu.zig` primitives.

> **Status (A3 increment 1 landed).** Real `Buffer`/`Texture`/`Pipeline`
> primitives now live in `gpu/opengl/` (replacing the reserved stubs).
> `cell_renderer` is the first converted file: `drawCells` issues its bg/fg/
> color-emoji passes through `cell_pipeline.zig` (cell pipelines built from the
> primitives, relocated out of `gl_init`), and the pure snap→instance logic +
> instance types moved to std-only, unit-tested `cell_geometry.zig`. Pattern for
> the rest: route draw through primitives + extract pure geometry, one file at a
> time. Remaining: the other 9 renderer files, the shared pipelines still in
> `gl_init`, then A4–A6.

> **Status (A3 increment 2 landed).** The shared UI rendering (solid quad /
> text-glyph / color-emoji) moved out of `gl_init` into primitives-backed
> `ui_pipeline.zig` (self-contained draw helpers). `gl_init` keeps compat mirror
> handles + re-exports (`renderQuad` → `ui_pipeline.fillQuad`, etc.) so the
> still-unconverted files are untouched — the **compat-shim** strategy.
> `titlebar` is converted (glyph/emoji through `ui_pipeline`, zero raw `gl.*`)
> and its pure layout logic extracted to std-only `titlebar_layout.zig`. The
> mirror handles dissolve as each remaining UI file converts to `ui_pipeline`.

- **A1** Define `src/renderer/gpu/gpu.zig` (the `GraphicsAPI` interface:
  `Target`, `Frame`, `RenderPass`, `Pipeline`, `Buffer`, `Texture`, `Sampler`,
  `shaders`) and `src/renderer/gpu/backend.zig` (`Backend{opengl,metal}`,
  `default(target)` → Metal on Darwin). *Ghostty: `renderer/generic.zig`,
  `renderer/backend.zig`.*
- **A2** Move the current OpenGL implementation into
  `src/renderer/gpu/opengl/` as the first backend (wrap `glad/gl.h`, the
  `gl_init` global handles, and shader compilation). **Move GL-context
  ownership out of `AppWindow.zig`** to the backend/host seam — resolves the
  `Renderer.zig:14` shortcut. *Ghostty: `renderer/opengl/`.*
- **A3** Convert renderer files from raw `gl.*` to `gpu.zig` primitives, and
  **split each file's presentation vs. logic in the same pass** (one touch
  each): `cell_renderer`, `titlebar`, `overlays`, `ai_chat_renderer`,
  `image_renderer`, `post_process`, `background_image`, `fbo`,
  `markdown_preview_renderer`, `file_explorer_renderer`. *Ghostty:
  API-agnostic `renderer/cell.zig`, `cursor.zig`, `image.zig`.*
- **A4** Route the font atlas → GPU texture upload through the `Texture`
  primitive; remove `font/manager.zig`'s direct `@cImport("glad/gl.h")`.
  *Ghostty: font atlas uploads via the backend's texture type.*
- **A5** Make shaders backend-scoped: keep GLSL under
  `gpu/opengl/shaders.zig`; reserve an MSL slot under `gpu/metal/shaders.zig`.
  *Ghostty: `renderer/shaders/` + per-API `shaders.zig`.*
- **A6** Extend the comptime guards: forbid raw `gl.*` and
  `@cInclude("glad/gl.h")` anywhere outside `src/renderer/gpu/opengl/`; forbid
  `AppWindow.zig` from importing `glad`. *Pattern: extend `build_guards.zig` /
  the `test_main.zig` facade scan.*

### Phase B — Presentation/logic separation (non-renderer files)
*Verifiable on Windows; runs in parallel with A.*

- **B1** `input.zig` (3,462 ln): extract keybind parsing and command dispatch
  from platform input-event handling into pure, unit-testable modules
  (continuing `input_shortcuts.zig` / `keybind.zig`). *Ghostty: `input/` +
  `Binding.zig` are separate from apprt input.*
- **B2** `ai_chat.zig` (248 KB): separate conversation/state/protocol logic
  from UI state; split into independently testable sub-modules.
- **B3** `AppWindow.zig` (3,742 ln): layer tab/split orchestration, render
  orchestration, and input routing (GL binding already removed in A2).
- **B4** Add unit tests for the extracted pure logic (runnable locally with
  `zig test` — see the test-execution note in project memory).

### Phase C — POSIX PTY/process backend
*Unit-testable on Linux; the first piece of real cross-platform code; parallel.*

- **C1** `src/platform/pty_posix.zig`: `openpty` / `fork` / `exec` +
  `ioctl(TIOCSWINSZ)`, satisfying the existing `pty.zig` facade. *Ghostty:
  `src/pty.zig` (POSIX), `src/os/` exec.*
- **C2** Complete `src/platform/process_posix.zig` so it can drive the PTY.
- **C3** Linux unit tests for spawn/resize/teardown.

### Phase D — macOS native host (deferred; needs macOS SDK)
*Gated on Phase A. Mirrors `TODO.md` Phase 2; not verifiable on the
Windows-default toolchain.*

- **D1** Metal backend `src/renderer/gpu/metal/` — second backend behind the
  Phase A interface (no OpenGL fallback). *Ghostty: `renderer/metal/`.*
- **D2** AppKit host + `src/platform/window_backend_macos.zig` (window, event
  loop ownership, input routing, IME, DPI). *Ghostty: Swift/AppKit app +
  `src/apprt/embedded.zig`.*
- **D3** CoreText `src/platform/font_backend_macos.zig`. *Ghostty:
  `src/font/discovery.zig` (CoreText).*
- **D4** Clipboard, file picker/drop, open-url, notifications, global hotkeys,
  DPI/content-scale via AppKit; config/theme dirs under `~/Library`.
- **D5** Packaging: `.app` bundle / `.dmg` + updater story.

---

## 6. Invariants & verification

### New invariants (extend the existing guard pattern)

- **No raw GPU API outside its backend.** `gl.*` and `@cInclude("glad/gl.h")`
  may appear only under `src/renderer/gpu/opengl/`. The rest of `src/renderer/`
  and the core go through `gpu.zig`.
- **The host owns the GPU context, not `AppWindow`.** `AppWindow.zig` must not
  `@cImport("glad/gl.h")`.

These join the existing checks in `src/build_guards.zig` and the facade scan in
`src/test_main.zig`, so a regression fails `zig build test`.

### Verification matrix (what is provable where)

| Phase | Windows | Linux | macOS |
|-------|:------:|:-----:|:-----:|
| A (GPU interface, OpenGL backend) | ✅ full | compile-only (shared) | — |
| B (presentation/logic split) | ✅ full | ✅ `zig test` (pure modules) | — |
| C (POSIX PTY/process) | n/a | ✅ unit tests | (also valid) |
| D (Metal, AppKit, CoreText, packaging) | — | — | requires SDK |

Note: this host is Windows/WSL today; per project memory, most tests are
compile-only here and pure modules run with `zig test`. Phases A and B are
designed so their *correctness* is observable on Windows; Phase C is the piece
that gets real runtime coverage on Linux.

---

## 7. Ghostty cross-reference

| Phantty (target) | Ghostty | Notes |
|------------------|---------|-------|
| `src/renderer/gpu/gpu.zig` | `src/renderer/generic.zig` | Renderer generic over a `GraphicsAPI`; documented abstraction hierarchy |
| `src/renderer/gpu/backend.zig` | `src/renderer/backend.zig` | `Backend{opengl,metal,webgl}`; `default(target)` → Metal on Darwin |
| `src/renderer/gpu/opengl/*` | `src/renderer/opengl/*` | `Target/Frame/RenderPass/Pipeline/Buffer/Texture/Sampler/shaders` |
| `src/renderer/gpu/metal/*` | `src/renderer/metal/*` | Phase D; mirrors opengl with MSL shaders |
| API-agnostic cell/cursor/image | `src/renderer/cell.zig`, `cursor.zig`, `image.zig` | Build geometry, not GL/Metal calls |
| `src/platform/pty_posix.zig` | `src/pty.zig` (POSIX) | `openpty`/`fork`/`exec` + `ioctl(TIOCSWINSZ)` |
| `src/platform/window_backend_macos.zig` | Swift/AppKit + `src/apprt/embedded.zig` | AppKit host owns its own event loop |
| `src/platform/font_backend_macos.zig` | `src/font/discovery.zig` | CoreText discovery + fallback |

> `remote/` is out of scope for the Ghostty comparison and for these
> platform-leakage checks (per `AGENTS.md` and `TODO.md`).
