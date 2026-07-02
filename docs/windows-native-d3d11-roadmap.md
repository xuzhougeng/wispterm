# Windows Native D3D11 Roadmap

This is the long-term renderer plan for making Windows a first-class native GPU
target. The goal is not merely to present OpenGL frames through DXGI. The goal is
for Windows to have its own Direct3D 11 renderer behind the same backend
interface used by Linux OpenGL and macOS Metal.

## Goal

WispTerm's target GPU matrix is:

| Platform | Target backend | Role |
|---|---|---|
| Windows | Direct3D 11 + DXGI | Default native renderer |
| macOS | Metal | Default native renderer |
| Linux | OpenGL | Default experimental Linux renderer |
| Windows fallback | OpenGL + DXGI flip-present | Compatibility path during and after migration |

Current Windows builds already use a DXGI/D3D11 flip-model presenter when
`wispterm-d3d-present = true`, but the terminal content is still drawn by the
OpenGL renderer and then copied into the DXGI swapchain. This roadmap changes
that into a real `d3d11` backend that draws cells, glyphs, emoji, UI, images,
and render targets directly with Direct3D 11.

## Current Branch Status

On the `windows-native-render` integration branch, the opt-in D3D11 backend is a
real native renderer path, not merely OpenGL frames presented through DXGI. The
branch has backend/present/shader diagnostics for `gpu-backend=d3d11`, a D3D11
swapchain, HLSL shader plumbing, terminal grid rendering, D3D11 off-screen
framebuffers, off-screen render-target round-trip smoke coverage, backend-neutral
UI pipeline smoke coverage, and the Phase IV UI/auxiliary parity evidence set.

The explicit Phase IV slices covered by fast-suite layout/policy tests and
source guards are: titlebar/tabs/sidebar/caption-button layout, startup overlay,
file explorer, settings page, background image layout, image preview layout, QR
panel layout, assistant conversation panel layout, command palette layout, skill
center layout, markdown preview layout, and backend-specific
post-process/custom shader policy. Supplemental user-visible panels such as the
port-forwarding renderer are also guarded as backend-neutral when they already
fit the same shared draw-context shape.

Phase IV UI parity evidence is complete on this branch: the guarded layout/policy
slices cover the explicit user-visible renderer surfaces, and the checked-in
normal-session smoke now proves a real D3D11 WispTerm session with the tab
chrome, sidebar, file explorer, background image, Markdown/image previews,
Copilot assistant sidebar, command palette, startup shortcuts overlay, Settings
page, Skill Center, D3D11 present diagnostics, UI probe, and offscreen
round-trip marker. This does not make D3D11 product-default-ready yet: Phase V
hardening has started with backend-owned present/device-loss diagnostics and a
pure D3D11 present policy that latches `needs_recreate` / `fallback_candidate`
state from classified DXGI failures. The host now consumes a single-shot D3D11
recovery request and records whether the requested action is device recreation
or fallback-candidate handling, but actual device recreation, automatic fallback
policy, environment validation, and Phase VI default migration remain blocked
until fallback coverage is proven. Windows `auto` still must not default to
D3D11 on this branch. This hardening slice adds the first controlled
device-recreate preparation path: when the backend latches a recreate-class
failure, the host releases D3D11-owned pipelines, auxiliary render targets,
background/post-process resources, font atlas GPU textures, and backend
backbuffer/RTV/phase2 shader resources, then logs that preparation. Actual
device/swapchain recreation has now started as a controlled single-shot attempt:
after recreate-class failure preparation, the backend can rebuild its D3D11
device, immediate context, swapchain, backbuffer, and minimal shader resources
for the same HWND/current framebuffer size, then the host restores the
backend-neutral feature pipelines and reloadable auxiliary resources. Automatic
fallback, environment validation, and Phase VI default migration are still
intentionally separate work. The normal-session smoke has an opt-in
`-RecreateSmoke` mode that latches one recreate-class request and verifies the
successful recreate/restore diagnostics without changing the healthy path.

The Phase IV normal-session evidence gate is the checked-in Windows GUI smoke:

```powershell
zig build -Dgpu-backend=d3d11
powershell -NoProfile -ExecutionPolicy Bypass -File .\debug\test-d3d11-normal-session.ps1
```

It launches a real visible D3D11 WispTerm session, captures screenshots while
switching active tabs, validating tab text, the `+` icon, active/inactive tab
states, and the close-hover affordance, then toggling the tab sidebar, file
explorer, and command palette. It also generates a high-contrast background
image, verifies that it is visible through the initial screenshot, opens
Markdown and image preview panes from a temporary File Explorer fixture, opens
the Copilot assistant sidebar with a temporary AI profile, opens the startup
shortcuts overlay from the Command Center, opens the Settings page from the
titlebar gear and the Skill Center from the Command Center, then verifies the
render-diagnostics log for D3D11 present, init details (swap effect, adapter or
unknown-adapter fallback, fallback reason, and healthy D3D11 policy state), UI
probe, offscreen round-trip markers, and the absence of a D3D11 recovery
request in the healthy smoke path. This is runtime evidence for the Phase IV
exit criteria and the first Phase V diagnostics/policy/recovery-coordination
slice; it is not a device-recreation or automatic fallback substitute and does
not change the Windows default backend.

## Ghostty Comparison

Ghostty is still the architectural reference for the renderer boundary. Its
renderer backend selector is `Backend{ opengl, metal, webgl }`; WebAssembly uses
WebGL, Darwin uses Metal, and other native targets use OpenGL. Ghostty also
keeps backend-specific implementations in parallel `renderer/opengl/` and
`renderer/metal/` directories with a common set of target, frame, render-pass,
pipeline, buffer, texture, sampler, and shader concepts.

WispTerm should keep that shape, but add a Windows-native backend:

```
src/renderer/gpu/
├── backend.zig          # Backend{ opengl, metal, d3d11 }
├── gpu.zig              # backend-neutral exports and contracts
├── opengl/              # Linux default + Windows fallback
├── metal/               # macOS default
└── d3d11/               # Windows native target
```

This intentionally diverges from Ghostty's backend set because Ghostty has no
Windows D3D11 renderer to copy. The boundary shape remains Ghostty-aligned; the
Windows implementation is WispTerm-specific.

## Non-Goals

- Do not rewrite terminal emulation. `libghostty-vt` remains the VT/parser/state
  source of truth.
- Do not start with D3D12. D3D11 is the right level for a terminal renderer:
  mature, widely supported, and much less ceremony than explicit D3D12 resource
  management.
- Do not replace FreeType with DirectWrite rasterization in the first D3D11
  milestone. Keep existing glyph rasterization and atlas packing first; native
  DirectWrite rasterization can be a later quality pass.
- Do not remove the Windows OpenGL path until the D3D11 backend has survived at
  least one release as the default and the fallback remains useful for broken
  drivers, RDP, and virtual machines.

## Design Principles

1. **No big-bang renderer rewrite.** Windows must stay shippable after every
   phase. The current OpenGL + DXGI present path remains the fallback until the
   D3D11 backend is proven.
2. **Neutralize the API before adding the backend.** Renderer files must stop
   speaking in `GL_*` constants, GL handles, and `gl_init` compatibility calls.
   Use WispTerm-owned enums and structs: primitive topology, texture format,
   buffer usage, blend mode, sampler mode, viewport, scissor, and render target.
3. **Backend code owns backend details.** D3D11 COM interfaces, DXGI swapchains,
   HLSL bytecode, input layouts, and device-lost recovery live under
   `src/renderer/gpu/d3d11/` or the Win32 host seam, not in renderer feature
   modules.
4. **Keep feature renderers API-agnostic.** Cell rendering, titlebar, overlays,
   assistant UI, image preview, and background rendering should build geometry
   and issue backend-neutral draw calls.
5. **Fallback is part of the design.** If the D3D11 backend fails bring-up,
   loses its device, or hits a known-bad environment, Windows can fall back to
   the current OpenGL + DXGI present path for that launch.

## Phase 0: Current Windows Present Baseline

Status: mostly done.

The current Windows host creates an OpenGL context and, by default, presents via
`src/apprt/win32_dx_present.zig`: OpenGL renders into FBO 0, WGL/DX interop
copies into a shared D3D11 texture, and DXGI presents a flip-model swapchain.
This solved several GDI `SwapBuffers` resize, DPI, and black-region issues while
preserving the existing renderer.

Keep this path working while D3D11 is developed. It is the fallback and the
regression oracle for visual parity.

Deliverables:

- Keep `wispterm-d3d-present` documented as the current DXGI present option.
- Keep the bring-up fuse, adapter matching, first-frame probe, watchdog, and
  persistent fallback markers intact.
- Add diagnostics that clearly distinguish `gpu-backend=opengl` with
  `present=dxgi` from a future `gpu-backend=d3d11`.

## Phase 1: Backend-Neutral Renderer Vocabulary

Before a D3D11 backend can be clean, renderer code must stop depending on
OpenGL-shaped names.

Deliverables:

- Add backend-neutral GPU types:
  `PrimitiveTopology`, `TextureFormat`, `TextureUsage`, `BufferUsage`,
  `BlendMode`, `SamplerMode`, `Viewport`, `Scissor`, and `ClearColor`.
- Replace renderer use of `gpu.c.GL_*` with these types outside backend
  implementations.
- Move remaining `gl_init.renderQuad` / `renderQuadAlpha` consumers onto
  `ui_pipeline` or a smaller backend-neutral `DrawContext`.
- Reduce `gpu.c` and `gl_init` exports from `gpu.zig` to transition-only
  compatibility, then guard against new use.
- Update `src/renderer/gpu/gl_backend_guard.zig` or a successor guard so new
  renderer code cannot reintroduce GL vocabulary outside `gpu/opengl/`.

Exit criteria:

- `rg "gpu\\.c\\.GL|\\bGL_[A-Z]|gl_init" src/renderer src/AppWindow.zig`
  trends toward backend directories and approved compatibility seams only.
- Linux/OpenGL and macOS/Metal still compile through the same neutral API.

## Phase 2: D3D11 Backend Skeleton

Create the backend without trying to render the full terminal yet.

Deliverables:

- Add `Backend.d3d11` and make Windows select it only behind an explicit config
  or build option at first.
- Create `src/renderer/gpu/d3d11/` with:
  `Context.zig`, `Buffer.zig`, `Texture.zig`, `Pipeline.zig`,
  `Framebuffer.zig`, `render_state.zig`, `readback.zig`, `shaders.zig`,
  `c.zig` or `core.zig`, and `api.zig`.
- Reuse or split the current DXGI/D3D11 ABI definitions from
  `src/platform/dxgi_core.zig` so the presenter and real backend do not drift.
- Initialize an `ID3D11Device`, immediate context, and DXGI flip-model
  swapchain on the same adapter chosen for the window.
- Draw and present a clear color, then a single solid quad.
- Add device and swapchain diagnostics parallel to current `dx-present` logs.

Exit criteria:

- A Windows build can launch with `gpu-backend=d3d11` and show a nonblank
  frame.
- Resize recreates swapchain buffers without crashing.
- `gpu-backend=opengl` remains unchanged.

## Phase 3: Terminal Grid MVP

Bring up the real terminal content with the smallest feature set that proves the
backend model.

Deliverables:

- Port the cell background and foreground instanced pipelines to HLSL.
- Keep FreeType glyph rasterization and existing atlas packing; upload glyph
  atlas textures into D3D11 textures.
- Support monochrome glyph atlas (`R8` or equivalent), BGRA color emoji atlas,
  and premultiplied-alpha blending.
- Render cursor shapes, selection rectangles, underline, strikethrough, and
  overline.
- Implement viewport, scissor, blend state, and sampler behavior needed by the
  cell renderer.
- Add readback for screenshot/diagnostic paths.

Exit criteria:

- A real shell renders readable text in D3D11.
- Unicode fallback and color emoji render through the existing FreeType path.
- Basic resize, tab switching, split panes, cursor blink, and selection match
  the OpenGL path visually.

## Phase 4: UI And Auxiliary Renderers

Move all user-visible renderer features onto D3D11.

Deliverables:

- Titlebar, tabs, sidebar, caption-button glyphs, QR panels, file explorer, AI
  conversation panel, skill center, command palette, settings page, and startup
  overlay render through the backend-neutral UI pipeline.
- Background image rendering works with opacity and scaling.
- Image and markdown previews work with D3D11 textures and framebuffers.
- Post-processing and Ghostty-compatible custom shader support are either
  implemented through an HLSL path or explicitly disabled with a clear fallback
  message while the D3D11 backend is experimental.
- `Framebuffer` and offscreen render target semantics are shared by OpenGL,
  Metal, and D3D11.

Exit criteria:

- The D3D11 backend can run a normal WispTerm session without missing major UI.
- Feature differences from OpenGL are documented in `KNOWN_ISSUES.md` while the
  backend is experimental.

## Phase 5: Windows Hardening

This is where the backend becomes product-grade rather than merely functional.

Deliverables:

- Handle `DXGI_ERROR_DEVICE_REMOVED`, `DXGI_ERROR_DEVICE_RESET`, and swapchain
  recreation without corrupting renderer state.
- Validate hybrid GPU adapter selection, RDP, virtual machines, weak integrated
  GPUs, high-DPI multi-monitor moves, maximize/restore, fullscreen, and rapid
  resize.
- Add a D3D11 bring-up marker and fallback policy parallel to the existing
  DXGI-present fuse.
- Add frame-latency and present diagnostics that report backend, adapter, swap
  effect, device-lost events, and fallback reason.
- Add Windows screenshot checks for a terminal grid, emoji, titlebar, overlays,
  image preview, and post-process fallback behavior.

Exit criteria:

- D3D11 survives the same manual UI automation and smoke tests currently used
  for Windows releases.
- Known bad environments fall back to OpenGL + DXGI present automatically.

## Phase 6: Default Migration

Only switch the Windows default after D3D11 has feature parity and fallback
coverage.

Deliverables:

- Add or finalize `wispterm-gpu-backend = auto | d3d11 | opengl`.
- In `auto`, select D3D11 on Windows unless a persisted fallback marker or
  runtime probe says not to.
- Keep OpenGL + DXGI present as a documented compatibility path for at least one
  full release cycle after D3D11 becomes the default.
- Update release notes, README feature text, configuration docs, FAQ, and
  diagnostics so "Windows native renderer" means D3D11 drawing, not only DXGI
  presentation.

Exit criteria:

- Windows default is D3D11.
- OpenGL fallback is available, tested, and documented.
- The release can explain the difference between `gpu-backend=d3d11` and the
  older `wispterm-d3d-present` setting.

## Future: DirectWrite Rasterization

After the D3D11 backend is stable, evaluate replacing Windows FreeType
rasterization with DirectWrite/Direct2D atlas generation.

This is a separate quality project, not a prerequisite for Windows native GPU
support. D3D11 should first reuse the current FreeType pipeline because it
already supports WispTerm's Unicode and color emoji behavior.

Possible deliverables:

- DirectWrite shaping and fallback for complex scripts.
- Direct2D or DirectWrite color glyph rendering into D3D11 atlas textures.
- Native Segoe UI text for titlebar/chrome where appropriate.
- Side-by-side glyph metrics comparison against the existing FreeType path.

## References

- Ghostty `src/renderer/backend.zig`: backend enum and default selection
  (`opengl`, `metal`, `webgl`; Darwin defaults to Metal).
- Ghostty `src/renderer/opengl/` and `src/renderer/metal/`: parallel backend
  implementations behind common renderer concepts.
- WispTerm `src/apprt/win32_dx_present.zig`: current DXGI flip-model presenter
  for the Win32 OpenGL host.
- WispTerm `src/renderer/gpu/`: current OpenGL/Metal backend spine.
- Windows Terminal AtlasEngine, refterm, and Flow editor: useful D3D11 terminal
  renderer references, especially for HLSL pipelines and atlas-backed glyph
  drawing.
