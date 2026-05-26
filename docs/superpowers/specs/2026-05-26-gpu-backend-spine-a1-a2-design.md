# Design: GPU backend spine — Phase A, increments A1 + A2

Status: approved (design); pending spec review
Date: 2026-05-26
Scope: TODO.md Phase A, items **A1** and **A2** only
References: [decoupling-guide.md](../../decoupling-guide.md), [architecture.md](../../architecture.md),
[TODO.md](../../../TODO.md)

## 1. Goal & boundary

Introduce the GPU backend spine and move today's OpenGL behind it as the **first
backend**, so the later macOS Metal port is a *port behind the interface* rather
than a renderer rewrite.

This increment does **A1 + A2 only**:

- **A1** — define `src/renderer/gpu/gpu.zig` (the comptime backend resolver +
  Ghostty-shaped primitive names) and `src/renderer/gpu/backend.zig`
  (`Backend{opengl, metal}`, `default(os_tag)` → Metal on Darwin).
- **A2** — move the current OpenGL implementation into
  `src/renderer/gpu/opengl/` as the first backend (glad table, `gl_init`
  handles, shader compilation, GLSL sources), and **move GL-context ownership
  out of `AppWindow.zig`** to the backend.

### Non-goals (explicitly deferred)

- **A3** — routing the 10 renderer files through `Frame`/`RenderPass`/`Pipeline`
  primitives and splitting each file's presentation vs. logic. Not in this
  increment; renderer files are *repointed* (one-line import swap), not
  rewritten.
- **A4** — font atlas upload through the `Texture` primitive.
- **A5** — backend-scoped MSL shaders beyond a *reserved, empty* `metal/` slot.
- **A6** — comptime guards forbidding `gl.*` / `@cInclude("glad/gl.h")` outside
  the backend. These **cannot pass yet**: after A2 the renderer files still call
  the raw GL table during the transition. The guards land with A3.
- **Phase D** — the Metal backend itself, AppKit host, CoreText. `backend.zig`
  only *names* `.metal` and reserves the Darwin default; no `metal/` impl.

### Guiding rules (from decoupling-guide §4, "Approach C")

1. Windows stays shippable on `x86_64-windows-gnu` at every commit.
2. OpenGL rendering correctly *behind the new interface* is the regression test
   for the interface.
3. Mirror Ghostty's concrete shapes (`renderer/generic.zig`,
   `renderer/backend.zig`, `renderer/opengl/*`) so the future `metal/` backend
   is a port, not a redesign. cmux may be consulted as a secondary pattern
   source.

## 2. Target layout

```
src/renderer/gpu/
├── gpu.zig          # comptime entry: resolves to the active backend's types
├── backend.zig      # Backend{opengl, metal}; default(os_tag) → metal on Darwin, else opengl
└── opengl/          # FIRST backend — absorbs today's GL code
    ├── api.zig      # backend root: re-exports primitives + Context
    ├── Context.zig  # owns the glad table + gladLoadGLContext(getProcAddress); the ONLY glad @cImport
    ├── shaders.zig  # the GLSL sources currently embedded in gl_init.zig
    └── (gl_init.zig content folded in: handles, buffer/shader setup, renderQuad/setProjection)
```

- Home is `src/renderer/gpu/` to match the decoupling guide and Ghostty's
  `src/renderer/` placement (confirmed with the user).
- `metal/` is **not** created in this increment. `backend.zig` names `.metal`
  and `default()` returns it on Darwin so D1 is a drop-in.

## 3. `gpu.zig` — comptime backend resolution (A1)

Backend is selected at comptime from the build target (Ghostty-style, no
runtime vtable, zero cost in the render loop):

```zig
const builtin = @import("builtin");
pub const Backend = @import("backend.zig").Backend;
pub const active: Backend = Backend.default(builtin.target.os.tag); // comptime

const impl = switch (active) {
    .opengl => @import("opengl/api.zig"),
    .metal  => @compileError("metal backend is Phase D (not yet implemented)"),
};

// Fully implemented in A2 (exercised by the OpenGL move):
pub const Context = impl.Context;  // owns the GL table + context init
pub const gl = impl.gl;            // active GL table — a transition handle, removed by A6
pub const shaders = impl.shaders;  // GLSL sources

// Reserved Ghostty-shaped primitive names. Declared in A1 as intentionally
// minimal slots so gpu.zig's public surface is stable; their bodies are filled
// in when the renderers are rewritten (A3), and Texture is wired to the font
// atlas in A4. Defining full bodies now would be unused machinery (YAGNI).
pub const Texture = impl.Texture;    // A4
pub const Buffer = impl.Buffer;      // A3
pub const Pipeline = impl.Pipeline;  // A3
// Frame / RenderPass / Target / Sampler: added as reserved decls in A3.
```

**Scope line:** A1 establishes the comptime selection and the Ghostty-shaped
names (reserved primitives are minimal slots). A2 fully implements only what the
OpenGL move exercises: `Context`, the `gl` table, `shaders`, and the existing
handle/buffer setup relocated from `gl_init.zig`. `Buffer`/`Pipeline`/`Texture`/
`Frame`/`RenderPass`/`Step` become load-bearing in A3–A4.

## 4. `backend.zig` (A1)

```zig
const std = @import("std");

pub const Backend = enum {
    opengl,
    metal,

    pub fn default(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios => .metal,
            else => .opengl,
        };
    }
};
```

This mirrors the existing `PlatformFeatures.forOs(os_tag)` pattern in `build.zig`
(which already keys `opengl_system_library` off `os_tag`), keeping backend
selection beside conventions already in the tree.

## 5. A2 — move OpenGL behind the seam + context ownership

### 5.1 Context ownership leaves `AppWindow`

These move from `AppWindow.zig` into `gpu/opengl/Context.zig`:

- the `gl: c.GladGLContext` var (`AppWindow.zig:1074`),
- the `glad/gl.h` `@cImport` (`AppWindow.zig:64`),
- the `gladLoadGLContext` call (`AppWindow.zig:3186`).

`AppWindow` instead calls `gpu.Context.init(window_backend.glGetProcAddress)`.
The host (`window_backend`) still supplies the proc-address loader and
`swapBuffers` (that seam already exists); the backend now owns the GL table.
This resolves the `Renderer.zig:14` "AppWindow owns the GL context" shortcut.

### 5.2 `gl_init.zig` folds into `gpu/opengl/`

The handles (VAOs/VBOs/shader programs), shader compilation
(`compileShader`/`linkProgram`), the embedded GLSL sources (→ `shaders.zig`),
and the helpers (`renderQuad`, `renderQuadAlpha`, `setProjection`,
`setProjectionForProgram`, `initBuffers`, `initInstancedBuffers`,
`initSolidTexture`, `deinitInstancedResources`) move under `gpu/opengl/`.

### 5.3 Renderer files are repointed, not rewritten

The ~16 files that reference `AppWindow.gl` / `AppWindow.gl_init` change their
import lines to point at the backend (e.g. `const gl = gpu.gl`). This is a
**mechanical one-line import swap per file**, behavior-identical, and is *not*
the A3 "touch each file once" rewrite. Their own `@cImport("glad/gl.h")` for GL
*constants* stays for now (A6 removes it later).

Rationale (confirmed with the user): the alternative — leaving a compatibility
alias `AppWindow.gl` re-exported from the backend so zero files change — would
keep `AppWindow` in the GL-ownership path and defeat A2's point. We do the
repoint.

### 5.4 State stays `threadlocal` module-level for now

The existing GL handles are `threadlocal var` globals. Making the backend
instance-owned per surface (Ghostty's model) is A3. A2 only *relocates* the
globals behind the backend module.

## 6. `build.zig` wiring

- The `gpu/` files compile as part of the existing app module. No new build
  option: backend is comptime from the target `os_tag`.
- `opengl_system_library` (`opengl32` on Windows) is already linked by
  `PlatformFeatures`; unchanged.

## 7. Verification

Because this increment is a **behavior-preserving move**, the bar is:

1. `zig build test` (fast inner loop) stays green.
2. `zig build test-full` (pre-merge gate) stays green — baseline 520/523 (2
   known Windows-API failures, per project memory).
3. `zig build` of the default `x86_64-windows-gnu` target succeeds.
4. `backend.zig`'s `default()` gets a pure unit test, listed in
   `src/test_fast.zig`:
   - `default(.macos) == .metal`, `default(.ios) == .metal`,
     `default(.windows) == .opengl`, `default(.linux) == .opengl`.
5. **Manual Windows visual smoke-check by the user.** Rendering correctness can
   only be eyeballed on a real Windows run; this cannot be verified from the
   WSL/cross host. This is the final gate for declaring A2 done.

## 8. Ghostty / cmux cross-reference

| This increment | Ghostty | Notes |
|----------------|---------|-------|
| `gpu/gpu.zig` (comptime resolver) | `renderer/generic.zig` | Renderer generic over a GraphicsAPI; we resolve at comptime |
| `gpu/backend.zig` | `renderer/backend.zig` | `Backend` enum; `default(target)` → Metal on Darwin |
| `gpu/opengl/*` | `renderer/opengl/*` | First backend; mirrors the primitive set |
| `gpu/metal/*` (reserved name only) | `renderer/metal/*` | Phase D drop-in |

cmux may be consulted for additional patterns; Ghostty is the documented gold
standard (per AGENTS.md) and the primary reference for concrete API shapes.

## 9. Risks

- **Hidden coupling to `AppWindow.gl`.** Moving the table may surface call sites
  beyond the 16 grepped files (e.g. via `AppWindow.gl_init` re-exports). The
  repoint must be exhaustive; the build will catch misses.
- **`threadlocal` semantics.** The GL table is `threadlocal var`; relocating it
  must preserve which thread initializes/uses it (renderer thread). Keep the
  same `threadlocal` storage class in `Context.zig`.
- **No visual CI.** Verification step 5 depends on a human; a behavior change
  that still compiles and passes logic tests could slip through. Mitigated by
  keeping A2 a pure move with no logic edits.
