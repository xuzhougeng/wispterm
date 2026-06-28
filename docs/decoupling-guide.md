# Decoupling Guide: UI vs. functionality, and the path to macOS

This guide is the engineering playbook for separating WispTerm's **functionality**
from its **UI/platform layer**, so the macOS (and later Linux) port reuses the
terminal core and only swaps the host + GPU backend.

It builds on [`architecture.md`](architecture.md) (the named core ↔ host
contract) and drives the roadmap in [`../ROADMAP.md`](../ROADMAP.md). Where
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
  `renderer/assistant/conversation.zig` (68), `post_process.zig` (66), `cell_renderer.zig`
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

**Correction to the historical portability plan.** The Phase 1 item *"keep the terminal rendering
core independent from the presentation backend … support multiple GPU backends
behind one interface"* was marked done. That checkbox is only half true: the
renderer has **no platform-runtime leakage** (no win32/DirectWrite/WebView2 —
true ✅), but the **GPU API itself is not behind an interface** (false ❌). The
two claims are split in the updated roadmap.

**Gap 2 — Several UI files conflate presentation with business logic (Axis B).**

These are WispTerm's largest files. None crosses the 10,000-line backstop, yet
each is hard to change because it carries several roles at once — the problem is
entanglement, not raw size. For contrast, Ghostty's largest files are *bigger*
(`terminal/PageList.zig` ~14.8k lines, `terminal/Terminal.zig` ~13.3k,
`config/Config.zig` ~10.9k, `terminal/Screen.zig` ~10.5k) but each owns one
coherent domain object with explicit state ownership and no scattered module
globals, so they stay tractable. WispTerm's files are smaller and harder.

| File | Lines | What is tangled |
|------|------|-----------------|
| `src/assistant/conversation/session.zig` | ~8,800 | agent config + dynamic tools + global callbacks + session lifecycle + summary/title generation + streaming + test hooks |
| `src/renderer/overlays.zig` | ~7,670 | overlay facade + per-overlay state + input handling + layout + rendering, for many unrelated overlays in one module |
| `src/AppWindow.zig` | ~7,090 | window orchestration + 123 imports (29 re-exported as a hub) + 67 top-level `g_*` globals + render/input routing |
| `src/input.zig` | ~7,040 | platform events + mouse selection + panel swap + preview + AI copilot + browser + terminal mouse report + repaint side effects |

These are accreted responsibility, not bugs. The `feat/ui-state-debt` refactor
(PR #310) started the decomposition: it pulled `AppWindow.zig` from 10,521 down
to ~7,090 lines, introduced the `UiEffect` boundary and the `appwindow/` state
structs, and extracted feature bridge/control/snapshot modules — each locked by
a source-scan guard. The remaining work, and the ratchets that now stop these
files regrowing, are in
[§8 — structural-debt governance](#8-structural-debt-governance-axis-b-in-practice).

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
- **`cell_geometry.zig`** (cell/cursor/selection geometry, consumed by
  `cell_renderer.zig`) and **`image_renderer.zig`** stay API-agnostic —
  they build geometry/instances, not GL/Metal calls.

### WispTerm target layout

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
  each): `cell_renderer`, `titlebar`, `overlays`, `renderer/assistant/conversation.zig`,
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

> **Status (ui-state-debt P1–P3 landed, PR #310).** The `UiEffect` boundary
> (`appwindow/ui_effect.zig` + `AppWindow.applyUiEffect`) and the `appwindow/`
> state structs (`state.zig` / `window_state.zig` / `remote_state.zig`) exist,
> and `AppWindow.zig` shed its weixin/agent/remote-sync/control/snapshot glue
> into `appwindow/*` (10,521 → ~7,090 lines). B1/B3 are **in progress**, not
> done. The per-file decomposition that remains and the ratchets that keep these
> files from regrowing are in [§8](#8-structural-debt-governance-axis-b-in-practice).

- **B1** `input.zig` (~7,040 ln): continue extracting the input pipeline by
  concern (dispatch, selection, panel drag, preview, terminal mouse report) and
  route every repaint through `UiEffect`. *Ghostty: `input/` + `Binding.zig` are
  separate from apprt input.*
- **B2** `assistant/conversation/session.zig` (~8,800 ln): separate agent config / session / protocol /
  tools / streaming / summary-title from UI callbacks; inject a `Host` interface
  instead of holding global UI triggers. Split into testable sub-modules.
- **B3** `AppWindow.zig` (~7,090 ln): keep reducing it toward an orchestration
  root — lifecycle, main loop, module assembly — and stop using it as the import
  hub (GL binding already removed in A2).
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
*Gated on Phase A. Mirrors the roadmap's native-port track; not verifiable on the
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

| WispTerm (target) | Ghostty | Notes |
|------------------|---------|-------|
| `src/renderer/gpu/gpu.zig` | `src/renderer/generic.zig` | Renderer generic over a `GraphicsAPI`; documented abstraction hierarchy |
| `src/renderer/gpu/backend.zig` | `src/renderer/backend.zig` | `Backend{opengl,metal,webgl}`; `default(target)` → Metal on Darwin |
| `src/renderer/gpu/opengl/*` | `src/renderer/opengl/*` | `Target/Frame/RenderPass/Pipeline/Buffer/Texture/Sampler/shaders` |
| `src/renderer/gpu/metal/*` | `src/renderer/metal/*` | Phase D; mirrors opengl with MSL shaders |
| `src/renderer/cell_geometry.zig`, `image_renderer.zig` | `src/renderer/cell.zig`, `cursor.zig`, `image.zig` | API-agnostic; build geometry, not GL/Metal calls |
| `src/platform/pty_posix.zig` | `src/pty.zig` (POSIX) | `openpty`/`fork`/`exec` + `ioctl(TIOCSWINSZ)` |
| `src/platform/window_backend_macos.zig` | Swift/AppKit + `src/apprt/embedded.zig` | AppKit host owns its own event loop |
| `src/platform/font_backend_macos.zig` | `src/font/discovery.zig` | CoreText discovery + fallback |

> `remote/` is out of scope for the Ghostty comparison and for these
> platform-leakage checks (per `AGENTS.md`, `ROADMAP.md`, and `KNOWN_ISSUES.md`).

---

## 8. Structural-debt governance (Axis B in practice)

Axis B used to be a roadmap aspiration. It is now governed mechanically so the
monolith UI files cannot quietly regrow while they are being decomposed. This
section is the playbook the `AGENTS.md` "Cohesion and coupling" section points
to.

Directory moves are governed separately because they should only reflect
boundaries that have already stabilized. See
[source-layout.md](source-layout.md) before moving files between directories.

### 8.1 The criterion

Cohesion and coupling — **not** line count — decide whether a file is too big. A
file is fine when it owns one coherent responsibility, exposes a clear API, has
explicit state ownership, a stable dependency direction, and real test coverage.
The smell is entanglement: presentation mixed with business mutation, input
dispatch mixed with rendering, global mutable state scattered across facades, a
file becoming the import hub for unrelated features.

The sharpest case of that entanglement is the **integration layer owning feature
state**. `AppWindow.zig`, `input.zig`, and `renderer/overlays.zig` are an
integration layer: they *coordinate* features (module assembly + render/input
routing, event dispatch, overlay facade/registry) and are **not** terminal
"core". The **feature domains** are the modules that own their own state and
behavior — `assistant/conversation/*`, `assistant/loop/*`, `agent/*`,
`agent_tools/*`, `terminal_agents/*`, `weixin/*`, `skill/`,
`file_explorer.zig`, `tmux/*`, and the remote client/sync code. Today the
integration layer holds feature `g_*` globals, re-exports unrelated feature
modules, and reaches into feature internals; that is exactly what the §8.2
ratchets freeze and shrink. Treat each ratchet step as moving one responsibility
back to the domain that owns it. The architecture-doc summary of this split is
[architecture.md § Integration layer vs feature domains](architecture.md#integration-layer-vs-feature-domains).

Two numeric signals sit on top of that judgment, neither of which is the goal:

- **> 5,000 lines** — a soft signal to review responsibility, dependency
  direction, import fan-in/out, state ownership, and test boundaries. Not
  enforced.
- **≥ 10,000 lines** — a hard backstop (`file_size_guard`). A *runaway tripwire,
  not a health certificate*: a file well under it can still be tangled, and one
  approaching it has usually already lost cohesion. `check-sizes` prevents
  uncontrolled growth; it does not certify architectural health.

### 8.2 The boundary guards (`src/source_guards/`)

These are the primary enforcement mechanism. Each is a source-scan test (the
`@embedFile`-and-count idiom of `input/dirty_guard.zig`) that **freezes a count
at today's value; the count may only shrink**. Adding a new occurrence fails the
gate — you must first remove one, or use the pattern the guard names.

| Guard | Freezes | Today's ceiling | Escape hatch |
|---|---|---|---|
| `file_size_guard` | lines in any `src/**/*.zig` (whole tree, future files too) | < 10,000 | split by responsibility; never raise the limit |
| `global_state_guard` | top-level `g_*` / `threadlocal` in the watched integration/session files | AppWindow 67, input 52, overlays 39, assistant/conversation/session 20 | new state → an explicit state struct (`appwindow/state.zig`, …) |
| `import_hub_guard` | `pub const X = @import(...)` re-exports in `AppWindow.zig` | 17 | import the real module directly, not via `AppWindow.X` |
| `side_effect_guard` | direct `g_force_rebuild` / `g_cells_valid` writes in the watched integration/session files | AppWindow 57, input 81, overlays 12, assistant/conversation/session 0 | return a `UiEffect`; land it via `AppWindow.applyUiEffect` |

They run in `zig build test` and — since `test-full` is now a superset of `test`
— in the pre-merge gate. The file-size backstop is also a standalone command,
`zig build check-sizes`.

**Next guard (documented, not yet mechanized): layered-dependency.** A scan that
forbids reverse imports across the layer model in §8.5 — e.g. `renderer/overlays/*`
importing `AppWindow.zig`, or `input/*` importing a concrete renderer. It needs
per-edge allowlists seeded from current violations, so it lands once those edges
have converged rather than freezing the violations in place.

### 8.3 Remediation priority

Decompose in this order. The point of the ordering is to *freeze new debt first*
and *move state before functions*, so the work never makes the files larger on
the way to making them smaller.

1. **Freeze new debt (done — the §8.2 ratchets).** No new `g_*` in watched
   integration/session files, no new `AppWindow` re-export hub entry, no new
   direct dirty write, no file over 10k. New input paths return a `UiEffect` /
   result; new overlays own their state/input/render modules.
2. **Finish the side-effect boundary.** Extend `UiEffect` returns from input to
   every overlay handler, command palette, confirm modal, settings page, and
   session launcher, so all repaint/rebuild/wake requests flow through
   `AppWindow.applyUiEffect`. Ratchet `side_effect_guard` down as each converts.
3. **Split state before functions.** Move scattered globals into explicit state
   owners (`AppWindow.State`, `InputState`, `OverlayState`,
   `AssistantConversationState`, `RemoteState`, `BrowserState`, `PreviewState`)
   and ratchet `global_state_guard` down. Moving functions before state only
   manufactures more imports.
4. **Dismantle the import hub.** Stop routing unrelated modules through
   `AppWindow`; convert callers to direct imports / narrow interfaces and ratchet
   `import_hub_guard` down.
5. **Split the big files by domain** (§8.4), in the order overlays → input →
   assistant conversation session → AppWindow: overlays decompose naturally by
   feature; input by event type and consumer; the assistant conversation session
   needs its `Host`/`State`/`Session` boundaries designed first; AppWindow thins
   out last, once its dependencies have boundaries.

### 8.4 Per-file target decomposition

Targets, not a mandate to hit a line number. The aim is local understandability.

**`AppWindow.zig` → an orchestration root**, not a god-window. It should own
window lifecycle, the main loop, platform-window binding, and module assembly —
a *composer* that initializes the pieces and passes state in. Candidate splits:
`appwindow/lifecycle.zig`, `appwindow/main_loop.zig`, `appwindow/render_bridge.zig`,
`appwindow/state.zig`, `appwindow/actions.zig`, `appwindow/agent_bridge.zig`,
`appwindow/remote_bridge.zig` (joining the existing `ui_effect.zig`,
`weixin_bridge.zig`, `remote_sync.zig`, `surface_snapshots.zig`,
`control_api.zig`). Crucially, stop adding `pub const X = @import(...)` re-exports.

**`input.zig` → an input pipeline.** Split by event scenario rather than size:
`input/pipeline.zig` (entry/dispatch), `input/key_dispatch.zig`,
`input/mouse_dispatch.zig`, `input/selection.zig`, `input/panel_drag.zig`,
`input/terminal_mouse.zig`, `input/overlay_dispatch.zig`,
`input/browser_dispatch.zig`, `input/preview_dispatch.zig`, plus the existing
`input/command_dispatch.zig` / `input/effects.zig`. Handlers should return a
result instead of poking globals:

```zig
pub const InputResult = struct {
    consumed: bool = false,
    action: ?InputAction = null,
    effect: UiEffect = .none,
};
```

**`renderer/overlays.zig` → facade + registry.** `overlays.zig` keeps only the
facade/registry; each overlay moves to its own module/dir
(`command_palette/`, `settings/`, `confirm/`, `session_launcher/`,
`ssh_profiles/`, `assistant_profiles/`, `toasts/`, `update_prompt/`) with a uniform
trio — `state.zig`, `input.zig`, `render.zig` (`+ layout.zig`/`model.zig` as
needed) — behind a uniform interface:

```zig
pub fn visible(state: *const State) bool
pub fn handleKey(state: *State, ev: KeyEvent) UiEffect
pub fn handleMouse(state: *State, ev: MouseEvent) UiEffect
pub fn render(ctx: *RenderContext, state: *const State) void
```

**`assistant/conversation/session.zig` → an assistant conversation domain.**
Split by domain, not by slicing: `assistant/conversation/session.zig`,
`assistant/conversation/settings.zig`, `assistant/conversation/tool_state.zig`,
`assistant/conversation/access.zig`, `assistant/conversation/stream.zig`,
`assistant/conversation/summary.zig`, `assistant/conversation/title.zig`,
`assistant/conversation/memory.zig`,
`assistant/conversation/slash_commands.zig`, `assistant/conversation/host.zig`,
`assistant/conversation/test_support.zig`. Collapse the scattered global UI
callbacks into one injected `Host` interface:

```zig
pub const Host = struct {
    resume_session: ?*const fn (...) void = null,
    open_copilot_picker: ?*const fn (...) void = null,
    export_markdown: ?*const fn (...) void = null,
    switch_model: ?*const fn (...) void = null,
};
```

`AppWindow` injects the `Host`; the assistant conversation domain stops reaching
back for window details.

### 8.5 The layer model

The dependency direction these guards defend. Imports should flow downward only:

- **`platform/*`** — platform capabilities only; never imports app business.
- **core / domain** (terminal state, IO, assistant conversation domain) — no
  UI/renderer imports.
- **`input/*`** — produces actions/effects; does not render directly.
- **`renderer/*`** — renders view state; does not perform business mutation.
- **`appwindow/*`** — orchestration; does not carry concrete feature business.
- **`assistant/conversation/*`** — owns agent/session/protocol/tools; does not
  know window details (reaches the UI only through an injected `Host`).
- **`remote/*`** — an independent security boundary; does not reach into
  main-app state (also out of scope for the Ghostty/platform-leakage checks).

The reverse edges worth locking first (the layered-dependency guard in §8.2):
`renderer/overlays/*` must not import `AppWindow.zig` (only narrow types such as
`appwindow/ui_effect.zig`); `input/*` must not import a concrete renderer module;
`assistant/conversation/session.zig` must not hold a set of UI-trigger callbacks
directly.

Restated as rules for new code, against the integration-layer/feature-domain
split above: **feature domains must not depend on `AppWindow`** — they expose a
query/action API and receive context explicitly rather than reaching back
through the window; **`input/*` only dispatches** — it decides who handles an
event and returns a `UiEffect`, and must not read a feature's internal `g_*`
state to do so; **overlays receive capabilities through an injected
Host/Context**, not by importing `AppWindow.zig`. Prefer explicit context
structs, feature-owned query/action APIs, and `UiEffect` returns over scattered
globals — and each time you touch a monolith, lower the matching §8.2 ratchet so
the boundary converges instead of being re-frozen in place.
