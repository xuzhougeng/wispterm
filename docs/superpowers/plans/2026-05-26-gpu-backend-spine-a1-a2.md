# GPU Backend Spine (Phase A: A1+A2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the GPU backend spine (`src/renderer/gpu/`) and move today's OpenGL behind it as the first backend, taking GL-context ownership out of `AppWindow.zig` — without rewriting the renderer files' draw code.

**Architecture:** Comptime-generic backend selection (Ghostty-style, no runtime vtable): `gpu/backend.zig` names `Backend{opengl, metal}` and `default(os_tag) → metal on Darwin`; `gpu/gpu.zig` resolves to the active backend at comptime. The OpenGL table, context loading, GLSL shaders, and the `gl_init` helpers move into `gpu/opengl/`. The single global GL table is relocated in one atomic cutover; consumers reach it through an `AppWindow.gpu` namespace re-export so the cutover is pure find-replace.

**Tech Stack:** Zig 0.15.2, glad (`glad/gl.h` via `@cImport`), OpenGL, FreeType. Target `x86_64-windows-gnu`. Tests: `zig build test` (fast), `zig build test-full` (pre-merge gate).

**Spec:** [docs/superpowers/specs/2026-05-26-gpu-backend-spine-a1-a2-design.md](../specs/2026-05-26-gpu-backend-spine-a1-a2-design.md)

**Reference:** Ghostty `src/renderer/backend.zig`, `src/renderer/generic.zig`, `src/renderer/opengl/*` (gold standard, per AGENTS.md). cmux as secondary pattern source.

---

## Conventions used in this plan

- **The active GL table accessor.** After the cutover, code that used `const gl = AppWindow.gl;` or `const gl = &AppWindow.gl;` uses `const gl = AppWindow.gpu.glTable();`. `glTable()` returns `*c.GladGLContext`; `gl.Foo.?(...)` works on the pointer via Zig auto-deref, so both old forms converge to one.
- **GL constants.** `AppWindow.zig`'s own `glad` `@cImport` is removed; its `c.GL_*` constants become `gpu.c.GL_*`. Renderer files keep their own `@cImport("glad/gl.h")` for constants in this increment (removed later in A6).
- **`gl_init` helpers.** Reached as `AppWindow.gpu.gl_init.*` (re-exported through `gpu.zig`), so physically relocating `gl_init.zig` later does not touch consumers.

---

## Task 1: `backend.zig` — Backend enum + comptime default (A1)

**Files:**
- Create: `src/renderer/gpu/backend.zig`
- Modify: `src/test_fast.zig` (register the new module)

- [ ] **Step 1: Write the failing test (inside the new file)**

Create `src/renderer/gpu/backend.zig`:

```zig
//! GPU backend selection. Mirrors Ghostty's `src/renderer/backend.zig`:
//! a `Backend` enum with `default(os_tag)` that returns `.metal` on Darwin,
//! `.opengl` elsewhere. Selection is comptime (see `gpu.zig`).

const std = @import("std");

pub const Backend = enum {
    opengl,
    metal,

    /// The default backend for a target OS. macOS/iOS are Metal-only
    /// (Apple deprecated OpenGL at 4.1); everything else uses OpenGL.
    pub fn default(os_tag: std.Target.Os.Tag) Backend {
        return switch (os_tag) {
            .macos, .ios => .metal,
            else => .opengl,
        };
    }
};

test "Backend.default maps Darwin to metal, others to opengl" {
    try std.testing.expectEqual(Backend.metal, Backend.default(.macos));
    try std.testing.expectEqual(Backend.metal, Backend.default(.ios));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.windows));
    try std.testing.expectEqual(Backend.opengl, Backend.default(.linux));
}
```

- [ ] **Step 2: Register the module in the fast test suite**

In `src/test_fast.zig`, add the import inside the `test { ... }` block (after the existing entries):

```zig
    _ = @import("renderer/gpu/backend.zig");
```

- [ ] **Step 3: Run the test**

Run: `zig build test`
Expected: PASS (suite stays green; the new `Backend.default` test runs).

- [ ] **Step 4: Commit**

```bash
git add src/renderer/gpu/backend.zig src/test_fast.zig
git commit -m "feat(gpu): add Backend enum with comptime default(os_tag) [A1]"
```

---

## Task 2: OpenGL backend home + `gpu.zig` resolver (A1 + A2 skeleton)

Create the backend's files and the comptime resolver. Nothing is wired into the runtime yet — `AppWindow` still owns the live table — so this is purely additive and the build stays green.

**Files:**
- Create: `src/renderer/gpu/opengl/c.zig`
- Create: `src/renderer/gpu/opengl/Context.zig`
- Create: `src/renderer/gpu/opengl/api.zig`
- Create: `src/renderer/gpu/gpu.zig`
- Modify: `src/AppWindow.zig` (add the `gpu` namespace re-export only)

- [ ] **Step 1: Create the glad cImport module**

`usingnamespace` is removed in Zig 0.15.2, so the cImport is exposed as a named `pub const c` and backend files reference `@import("c.zig").c`. Create `src/renderer/gpu/opengl/c.zig`:

```zig
//! The single glad/gl.h cImport for the OpenGL backend.
//! After Phase A6 this is the only place in the tree that includes glad/gl.h.
pub const c = @cImport({
    @cInclude("glad/gl.h");
});
```

Backend code references `@import("c.zig").c.GL_*` and `@import("c.zig").c.GladGLContext`. The GL-constants namespace exposed to the app is this `c`, re-exported as `gpu.c` (see Step 4).

- [ ] **Step 2: Create the context module (owns the table + loader)**

`src/renderer/gpu/opengl/Context.zig`:

```zig
//! Owns the OpenGL context lifecycle for the OpenGL backend: the glad function
//! table and the one-time load. Replaces the `gl` var + gladLoad that lived in
//! AppWindow.zig (resolves the Renderer.zig:14 "AppWindow owns the GL context"
//! shortcut). The host supplies the proc-address loader; the backend owns the
//! table.
const std = @import("std");
const c = @import("c.zig").c;

/// The active glad function table. Threadlocal because rendering runs on the
/// renderer thread (preserves the previous storage class).
pub threadlocal var gl: c.GladGLContext = undefined;

/// Load the GL function table via glad using the host's proc-address loader.
/// `loader` is `@ptrCast(&window_backend.glGetProcAddress)` from the host.
pub fn init(loader: c.GLADloadfunc) !void {
    const version = c.gladLoadGLContext(&gl, loader);
    if (version == 0) {
        std.debug.print("Failed to initialize GLAD\n", .{});
        return error.GLADInitFailed;
    }
    std.debug.print("OpenGL {}.{}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version) });
}
```

- [ ] **Step 3: Create the backend root that re-exports primitives**

`src/renderer/gpu/opengl/api.zig`:

```zig
//! OpenGL backend root. Re-exports the backend's primitives for `gpu.zig` to
//! resolve at comptime. The first GraphicsAPI backend; `metal/` mirrors this
//! in Phase D.
const c_mod = @import("c.zig");

pub const c = c_mod.c;                       // glad constants/types
pub const Context = @import("Context.zig");  // context lifecycle + GL table
pub const GlTable = c_mod.c.GladGLContext;   // the table type

/// The `gl_init` helpers currently live at src/renderer/gl_init.zig; they are
/// physically relocated under this directory in a later task. Re-exporting here
/// keeps consumers (gpu.gl_init.*) stable across that move.
pub const gl_init = @import("../../gl_init.zig");

// Reserved Ghostty-shaped primitive slots. Declared now so gpu.zig's public
// surface is stable; bodies are filled when the renderers are rewritten.
pub const Texture = struct {}; // reserved: A4 (font atlas → GPU texture)
pub const Buffer = struct {}; // reserved: A3
pub const Pipeline = struct {}; // reserved: A3
```

- [ ] **Step 4: Create the comptime resolver**

`src/renderer/gpu/gpu.zig`:

```zig
//! GraphicsAPI spine. Resolves the active GPU backend at comptime (Ghostty
//! style, no runtime vtable) and re-exports its types. See
//! docs/decoupling-guide.md §2 and the spec for the abstraction hierarchy.
const builtin = @import("builtin");
const opengl = @import("opengl/api.zig");

pub const Backend = @import("backend.zig").Backend;
pub const active: Backend = Backend.default(builtin.target.os.tag);

const impl = switch (active) {
    .opengl => opengl,
    .metal => @compileError("metal backend is Phase D (not yet implemented)"),
};

// Fully implemented (exercised by the A2 move):
pub const Context = impl.Context; // context lifecycle (owns the GL table)
pub const c = impl.c; // GL constants/types (transition: removed from app code by A6)
pub const gl_init = impl.gl_init; // shared GL helpers + buffers + shaders

/// Pointer to the active backend's GL function table. Transition handle used by
/// renderer files until they route through the primitives (A3); removed in A6.
pub inline fn glTable() *impl.GlTable {
    return &Context.gl;
}

// Reserved Ghostty-shaped primitive slots (bodies land in A3/A4):
pub const Texture = impl.Texture;
pub const Buffer = impl.Buffer;
pub const Pipeline = impl.Pipeline;
```

- [ ] **Step 5: Expose the `gpu` namespace from AppWindow**

In `src/AppWindow.zig`, add a re-export alongside the existing module re-exports (the block around line 40-59, e.g. right after `pub const gl_init = @import("renderer/gl_init.zig");` at line 45):

```zig
pub const gpu = @import("renderer/gpu/gpu.zig");
```

Do NOT remove anything yet in this task.

- [ ] **Step 6: Build to verify the additive change compiles**

Run: `zig build`
Expected: success. The new files compile; `gpu.glTable()` points at the (still unused) `Context.gl`; the live table is still `AppWindow.gl`.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/gpu/gpu.zig src/renderer/gpu/opengl/ src/AppWindow.zig
git commit -m "feat(gpu): add gpu.zig resolver + opengl backend skeleton [A1/A2]"
```

---

## Task 3: Atomic cutover — relocate the live GL table to the backend (A2)

This is one commit by necessity: there is exactly one global GL table, and every consumer names it. After this task, `AppWindow` no longer owns or `@cImport`s GL; the backend owns the context; all consumers go through `AppWindow.gpu`.

**Files:**
- Modify: `src/AppWindow.zig` (remove glad cImport, the `gl` var, the `gl_init` re-export; switch loader to `gpu.Context.init`; repoint internal GL calls/constants/helpers)
- Modify: `src/renderer/gl_init.zig` (repoint its internal table refs)
- Modify (repoint `AppWindow.gl`/`AppWindow.gl_init` → `AppWindow.gpu.*`):
  `src/renderer/Renderer.zig`, `cell_renderer.zig`, `titlebar.zig`, `overlays.zig`,
  `ai_chat_renderer.zig`, `image_renderer.zig`, `post_process.zig`,
  `background_image.zig`, `fbo.zig`, `markdown_preview_renderer.zig`,
  `file_explorer_renderer.zig`, `weixin_qr_renderer.zig`,
  `overlays/scrollbar.zig`, `overlays/resize.zig`, `overlays/startup_shortcuts.zig`,
  `overlays/primitives.zig`, `src/appwindow/split_layout.zig`, `src/font/manager.zig`

- [ ] **Step 1: Repoint every renderer/font consumer (bulk find-replace)**

For the table accessor, both value (`const gl = AppWindow.gl;`) and pointer (`const gl = &AppWindow.gl;`) forms become `const gl = AppWindow.gpu.glTable();`. The regex `&\?AppWindow\.gl\b` matches both and does NOT match `AppWindow.gl_init` (the `_` defeats `\b` after `gl`).

Run from the repo root:

```bash
files=$(grep -rl 'AppWindow\.gl' src/renderer src/font src/appwindow)
for f in $files; do
  perl -pi -e 's/&?AppWindow\.gl\b/AppWindow.gpu.glTable()/g; s/AppWindow\.gl_init\b/AppWindow.gpu.gl_init/g' "$f"
done
```

This also covers `src/renderer/gl_init.zig`'s own internal `AppWindow.gl` references (it is in the `grep -rl` set).

- [ ] **Step 2: Verify no consumer still names the old symbols**

Run:

```bash
grep -rn 'AppWindow\.gl\b' src/ ; grep -rn 'AppWindow\.gl_init\b' src/
```

Expected: no output (every reference now uses `AppWindow.gpu.glTable()` / `AppWindow.gpu.gl_init`).

- [ ] **Step 3: In `AppWindow.zig`, switch the loader and remove GL ownership**

a) Remove the glad `@cImport` (lines ~63-65):

```zig
const c = @cImport({
    @cInclude("glad/gl.h");
});
```

If `c` is used elsewhere in `AppWindow.zig` for non-GL includes, check first with `grep -n '\bc\.' src/AppWindow.zig`. (Expected: only `c.GL*`/`c.Glad*`/`c.gladLoad*` uses, all GL.) Remove the import.

b) Remove the table var (line ~1074):

```zig
pub threadlocal var gl: c.GladGLContext = undefined;
```

c) Remove the `gl_init` re-export (line ~45) — consumers now use `gpu.gl_init`:

```zig
pub const gl_init = @import("renderer/gl_init.zig");
```

d) Replace the GLAD load block (lines ~3184-3192) with a call into the backend:

```zig
    // --- Load OpenGL via the GPU backend ---
    try gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress));
```

- [ ] **Step 4: Repoint AppWindow's internal GL usage**

In `src/AppWindow.zig`, the 24 bare `gl.Foo.?(...)` calls used the now-removed module var; the 4 `c.GL_*` constants used the now-removed cImport; bare `gl_init.*` used the removed re-export. Apply:

```bash
perl -pi -e 's/\bgl\.([A-Z])/gpu.glTable().$1/g; s/\bc\.(GL_[A-Z0-9_]+)/gpu.c.$1/g; s/\bgl_init\.([A-Za-z])/gpu.gl_init.$1/g' src/AppWindow.zig
```

Notes on why these are safe:
- `\bgl\.[A-Z]` matches `gl.ClearColor` etc., not `gl_init.` (the char after `gl` is `_`, not `.`).
- `\bc\.GL_…` rewrites only GL constants; verify nothing else used `c.` (Step 3a).
- `\bgl_init\.[A-Za-z]` rewrites the helper calls (`setProjection`, `g_bg_opacity`, `shader_program`, `vao`, …) to `gpu.gl_init.*`.

- [ ] **Step 5: Build**

Run: `zig build`
Expected: success. Watch for:
- Any remaining `c.` reference in `AppWindow.zig` (a non-GL include you missed) — fix by routing through the right module.
- Import-cycle errors (gl_init↔AppWindow↔gpu): this cycle already existed (gl_init imports AppWindow; AppWindow re-exported gl_init) and compiles; if a new comptime cycle appears, it will name the file — break it by importing the specific decl rather than the module.

- [ ] **Step 6: Run the full test suite**

Run: `zig build test-full`
Expected: green baseline — 520/523 (the 2 known Windows-API failures only; no new failures). This is a behavior-preserving move, so any new failure indicates a mis-repoint.

- [ ] **Step 7: Verify GL ownership left AppWindow**

Run:

```bash
grep -n 'glad/gl.h' src/AppWindow.zig ; grep -n 'threadlocal var gl' src/AppWindow.zig
```

Expected: no output for both — `AppWindow.zig` no longer `@cImport`s glad nor declares the GL table.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(gpu): move GL context ownership from AppWindow to opengl backend [A2]"
```

---

## Task 4: Relocate `gl_init.zig` into the backend directory (A2)

Physically move the helpers under the backend. Consumers use `gpu.gl_init.*`, so only the backend's internal import path changes.

**Files:**
- Move: `src/renderer/gl_init.zig` → `src/renderer/gpu/opengl/gl_init.zig`
- Modify: `src/renderer/gpu/opengl/api.zig` (import path), `src/renderer/gpu/opengl/gl_init.zig` (its AppWindow + Renderer import paths)

- [ ] **Step 1: Move the file**

```bash
git mv src/renderer/gl_init.zig src/renderer/gpu/opengl/gl_init.zig
```

- [ ] **Step 2: Fix the import path in `api.zig`**

In `src/renderer/gpu/opengl/api.zig`, change the relocated re-export from the old relative path to the local one:

```zig
pub const gl_init = @import("gl_init.zig");
```

(was `@import("../../gl_init.zig");`)

- [ ] **Step 3: Fix `gl_init.zig`'s own imports**

`gl_init.zig` moved two directories deeper (`src/renderer/` → `src/renderer/gpu/opengl/`). Update its imports of `AppWindow` and `Renderer`:

```zig
const AppWindow = @import("../../../AppWindow.zig");
const Renderer = @import("../../Renderer.zig");
```

(were `@import("../AppWindow.zig")` and `@import("Renderer.zig")` — verify the originals with `grep -n '@import(' src/renderer/gpu/opengl/gl_init.zig` and adjust each by adding the two extra `../` levels.)

- [ ] **Step 4: Build and test**

Run: `zig build && zig build test-full`
Expected: `zig build` succeeds; `test-full` green baseline 520/523.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(gpu): relocate gl_init helpers under gpu/opengl [A2]"
```

---

## Task 5: Extract GLSL shader sources into `gpu/opengl/shaders.zig` (A2)

Per spec §5.2, the embedded GLSL strings become backend-scoped, reserving the symmetric `metal/shaders.zig` (MSL) slot for Phase D.

**Files:**
- Create: `src/renderer/gpu/opengl/shaders.zig`
- Modify: `src/renderer/gpu/opengl/gl_init.zig` (import the sources instead of defining them)

- [ ] **Step 1: Create the shaders module**

Create `src/renderer/gpu/opengl/shaders.zig` and move the GLSL source string constants out of `gl_init.zig` into it (these are: `vertex_shader_source`, `fragment_shader_source`, `bg_vertex_source`, `bg_fragment_source`, `fg_vertex_source`, `fg_fragment_source`, `color_fg_fragment_source`, `simple_color_fragment_source`, `overlay_fragment_source`). Make each `pub`:

```zig
//! GLSL shader sources for the OpenGL backend. The Metal backend (Phase D)
//! provides the symmetric MSL set under gpu/metal/shaders.zig.

pub const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;
// ... (move the remaining 8 source constants verbatim, each marked `pub`)
```

- [ ] **Step 2: Reference the sources from `gl_init.zig`**

In `src/renderer/gpu/opengl/gl_init.zig`, delete the moved `const *_source` definitions and add at the top:

```zig
const shaders = @import("shaders.zig");
```

Then replace each bare use (e.g. `vertex_shader_source`) with `shaders.vertex_shader_source`. Find them with:

```bash
grep -n '_source\b' src/renderer/gpu/opengl/gl_init.zig
```

- [ ] **Step 3: Build and test**

Run: `zig build && zig build test-full`
Expected: `zig build` succeeds; `test-full` green baseline 520/523.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(gpu): scope GLSL shader sources under gpu/opengl/shaders.zig [A2/A5 slot]"
```

---

## Task 6: Update roadmap docs + final verification handoff

**Files:**
- Modify: `TODO.md`, `docs/decoupling-guide.md`

- [ ] **Step 1: Mark A1 and A2 complete in `TODO.md`**

In `TODO.md` Phase A, change the `- [ ]` to `- [x]` for **A1** and **A2**, and append a short note under A2 that GL-context ownership moved out of `AppWindow.zig` (it no longer `@cImport`s glad). Leave A3–A6 unchecked. In the "Invariants to maintain" section, note that the AppWindow-must-not-`@cImport`-glad half of the A6 invariant now holds, while the general `gl.*`-outside-backend guard is still pending A3.

- [ ] **Step 2: Add a status line to `docs/decoupling-guide.md`**

Under §5 Phase A, note that A1+A2 landed: `gpu/gpu.zig` + `gpu/backend.zig` exist, OpenGL is the first backend under `gpu/opengl/`, and context ownership left `AppWindow`. A3 (route renderer files) is next.

- [ ] **Step 3: Final verification**

Run: `zig build test-full`
Expected: green baseline 520/523.

Run: `zig build`
Expected: a successful `x86_64-windows-gnu` build artifact.

- [ ] **Step 4: Request the manual Windows visual smoke-check**

This is the gate that cannot be automated from WSL/cross. Ask the maintainer to run the built `phantty.exe` on Windows and confirm: the terminal grid renders, the titlebar/overlays draw, AI-chat and file-explorer panels render, and background images composite — i.e. no visual regression from the GL relocation.

- [ ] **Step 5: Commit**

```bash
git add TODO.md docs/decoupling-guide.md
git commit -m "docs(gpu): mark Phase A A1+A2 complete; note context-ownership move"
```

---

## Self-review notes (resolved)

- **Spec coverage:** A1 → Task 1 (backend.zig) + Task 2 (gpu.zig resolver). A2 context-ownership move → Task 3. A2 `gl_init` relocation → Task 4. A2 GLSL→shaders.zig (and A5 reserved slot) → Task 5. Reserved primitive slots → Task 2 (`Texture`/`Buffer`/`Pipeline`). Verification matrix (build + test-full + manual Windows) → Task 6. `backend.default` unit test in `test_fast.zig` → Task 1. Non-goals (A3 routing, A4 font atlas, A6 guards, Metal impl) are explicitly NOT implemented.
- **Atomicity rationale:** Task 3 is one commit because a single global GL table cannot be half-moved while keeping `zig build` green at every commit (Approach C rule 1). Routing through `AppWindow.gpu` keeps the edits mechanical.
- **Type consistency:** `glTable()` returns `*c.GladGLContext` everywhere; `Context.init(loader: c.GLADloadfunc) !void` matches the call `gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress))`; `gpu.gl_init` / `gpu.c` names are used consistently across Tasks 2–5.
- **Zig 0.15.2:** no `usingnamespace`; the GL table is reached via the `glTable()` accessor, not a re-exported var.
