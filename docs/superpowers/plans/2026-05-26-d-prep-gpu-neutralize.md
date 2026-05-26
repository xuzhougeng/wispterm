# D-prep — make the codebase "ready to start the macOS port cold"

Branch `feat/d-prep-gpu-neutralize`. All items are platform-neutral and
**verifiable on Windows/Linux** (OpenGL behavior preserved). After these, the
macOS work is pure fill-in against defined seams (Metal/AppKit/CoreText), with no
need to refactor the core or OpenGL code on the Mac. Each step: `zig build` +
`zig build test-full -Dtarget=x86_64-windows-gnu` green.

## ① Render-layer de-GL-ification (the linchpin; prerequisite for ③/⑤)
Today these call `gpu.glTable()` directly (raw GL): `ui_pipeline`(10), `cell_pipeline`(1+VAO builds),
`cell_renderer`(3), `Renderer`(2), `post_process`(3), `markdown_preview_renderer`(1),
`weixin_qr_renderer`(2), `overlays/{resize,scrollbar,startup_shortcuts}`(1 each), `AppWindow`(26 frame-loop).
Distinct ops to absorb into the gpu interface: VAO/vertex-attrib (VertexAttribPointer/
EnableVertexAttribArray/BindVertexArray/VertexAttribDivisor/Gen/DeleteVertexArrays),
blend (Enable/Disable/BlendFunc), scissor (Enable/Disable/Scissor/IsEnabled/GetIntegerv SCISSOR_BOX),
clear/viewport (Clear/ClearColor/Viewport/GetIntegerv VIEWPORT), draw (DrawArrays), and stray
Uniform*/BindTexture/TexParameteri/BindBuffer/BufferSubData (→ existing Pipeline/Texture/Buffer methods).

### ①a — extend the gpu interface (additive, opengl impl, build stays green)
- **Vertex layout / VAO** — a declarative attribute layout so callers don't issue raw VAO ops.
  e.g. `gpu.VertexAttr{ index, size, gl_type, normalized, stride, offset, divisor }` + a builder
  `gpu.buildVertexArray(buffer, attrs) -> Vao` (OpenGL: GenVertexArrays + EnableVertexAttribArray +
  VertexAttribPointer + VertexAttribDivisor; Metal: a vertex descriptor on the pipeline). Replaces the
  VAO building in `ui_pipeline.buildQuadVao` + `cell_pipeline`'s 3 VAOs.
- **Render state** — `gpu.setBlendEnabled(bool)`, `gpu.setBlendMode(.alpha|.premultiplied)` (the two
  BlendFunc modes in use), `gpu.setScissor(rect)`/`gpu.clearScissor()`/`gpu.scissorState()` (save/restore
  for markdown), `gpu.clear(rgba)`, `gpu.setViewport(x,y,w,h)`, `gpu.viewportSize() -> {w,h}`.
- **Frame seam** — `gpu.beginFrame()` / `gpu.endFrame()` (OpenGL: no-op / flush hook; Metal: command
  buffer + drawable). Lets the host drive frames without backend-specific calls. Present/swap stays host.
- Put these on `gpu.zig` (dispatch to the active backend) or as backend-exported fns; opengl implements
  them over `Context.gl`. `ui_pipeline.setBlendEnabled`/`beginClip`/`endClip` fold into these.

### ①b… — rewire each file off `glTable()` onto the interface (one at a time, verified)
Order: ui_pipeline → cell_pipeline (VAO builder) → cell_renderer → post_process → Renderer →
markdown_preview → weixin_qr_renderer → overlays/{resize,scrollbar,startup_shortcuts} → AppWindow frame loop.
Each: replace raw gl ops with the new gpu methods; `zig build` + windows `test-full` green.

### ①c — strengthen `gl_backend_guard`
Once a file is glTable-free, move it from the (documented) allowlist into the regression-locked set.
Goal end-state: **no `gpu.glTable()` outside `src/renderer/gpu/opengl/`** (+ the host context-creation seam).

## ② Host↔renderer surface seam
`window_backend` exposes `glGetProcAddress` (GL-specific). Add a neutral surface/drawable seam so the
renderer gets an abstract surface (Windows: still creates the GL context; Metal host: hands a `CAMetalLayer`).
Design + verify on Windows.

## ③ Metal backend interface contract + compiling stub
Create `src/renderer/gpu/metal/api.zig` exporting the SAME surface as `opengl/api.zig` (Context/Buffer/
Texture/Pipeline/Framebuffer/shaders/render-state/frame), with stub bodies (`@panic("metal: TODO D1")`)
that **compile**. Replace `gpu.zig`'s `.metal => @compileError(...)` with `=> @import("metal/api.zig")`.
This proves the neutral interface is implementable and gives the Mac work a fill-in target. Verify the
opengl path is unaffected; the metal path only compiles under a Darwin target.

## ④ macOS pty ioctl constants (quick, certain)
`pty_posix.zig`: OS-dispatch the ioctl request numbers (macOS `TIOCSWINSZ=0x80087467`, `TIOCSCTTY=0x20007461`,
`FIONREAD=0x4004667f` differ from `std.os.linux.T`); add `O_CLOEXEC` to master + cancel-pipe fds. Then
`pty.zig` `backendForOs(.macos) => .posix`. Can't run on Linux, but the values are fixed → Mac-ready.

## ⑤ macOS cross-compile reaches the platform layer
With ③'s metal stub compiling, get `zig build -Dtarget=aarch64-macos` (and `test`) to compile as far as
possible: add `_macos`/`_unsupported` fallbacks for any platform `<cap>` facade that only has `_windows`,
so missing-symbol errors surface HERE, not on the Mac. Renderer/Metal bodies panic at runtime (stub) but
must compile. Document the residual gaps the Mac must fill.

## Done = "ready to start macOS cold" — ✅ COMPLETE
- ✅ **①** No raw `gpu.glTable()`/`gpu.Context.gl` in the rendering layer — `ui_pipeline`/
  `cell_pipeline`/`cell_renderer`/`post_process`/`Renderer`/`markdown`/`weixin`/`overlays/*`/
  `titlebar`/`ai_chat`/`file_explorer`/`image`/`background`/`fbo`/`font.manager` all route
  through `gpu.Pipeline`/`Buffer`/`Texture`/`Framebuffer`/`state`/`vertex`; AppWindow's
  frame-loop render-state too. Guard-enforced (`gl_backend_guard.zig`, ①c). Residue:
  AppWindow's `Context.init` seam + a diagnostics snapshot (host-specific).
- ✅ **②** Surface seam documented as per-backend `Context.init` (GL loader vs `CAMetalLayer`)
  in `window_backend.zig` + `gpu/metal/Context.zig`.
- ✅ **③** `gpu/metal/*` stub mirrors `opengl/api.zig`'s full interface (`@panic("metal: TODO D1")`
  bodies); `gpu.zig` `.metal` branch wired (lazy imports so glad isn't analyzed on Darwin).
- ✅ **④** macOS pty ioctl constants OS-dispatched; `backendForOs(.macos)=.posix`.
- ✅ **⑤** `zig build test-full -Dtarget=aarch64-macos` compiles (renderer/Metal/host bodies
  are `@panic` stubs to fill on a Mac); platform facades' `_unsupported` macOS fallbacks sufficed.
- ✅ Windows `zig build`/`test`/`test-full` + Linux native pty tests stayed green throughout.

**Mac fill-in TODO** (the skeleton to flesh out on a Mac, all tagged `metal: TODO D1`):
implement `gpu/metal/` bodies (Context/Buffer/Texture/Pipeline/Framebuffer/render_state/vertex
+ real MSL in `shaders.zig`), the AppKit host (`window_backend_macos.zig`) feeding a
`CAMetalLayer` to `Context.init`, CoreText fonts, and the `_macos` platform-service impls.
