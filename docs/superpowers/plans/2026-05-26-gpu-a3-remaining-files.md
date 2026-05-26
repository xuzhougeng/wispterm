# GPU A3 — remaining 7 files: plan

Goal: route the last A3 renderer files through `gpu`/`ui_pipeline`, raw-GL-free, behavior-preserving. Branch `feat/gpu-a3-remaining` (off the ai_chat branch, so `beginClip`/`endClip` exist).

## File categories

**Group 1 — UI quad/text (existing `ui_pipeline` pattern):**
- `file_explorer_renderer` ✅ DONE — 13 quads→fillQuad, ambient/glad/gl_init removed.
- `markdown_preview_renderer` — 12 quads→fillQuad, 2 scissor→beginClip/endClip; PLUS its own image texture (see Group 2 infra).
- `overlays` (4564 ln) — 27 quads→fillQuad; 3 `overlay_shader` sites→`ui_pipeline.fillOverlay`; 9 UseProgram/bind ambient blocks.

**Group 2 — GPU-effect (need new primitives):**
- `fbo` — FBO mgmt + textured-quad composite (uses `simple_color_shader`).
- `image_renderer` — kitty image texture upload + textured-quad draw (uses `simple_color_shader`).
- `background_image` — stb_image texture load + textured-quad draw + `overlay_shader` tint pass.
- `post_process` — off-screen FBO + dynamic user shader (Shadertoy uniforms) + fullscreen quad.

## Primitive infrastructure to add (additive, build stays green)

### P1 — `gpu/opengl/Texture.zig` extensions
Current: only `fromHandle`, `bind`. Add (keep callers storing raw `GLuint` via `.handle` to avoid Renderer struct ripple):
```zig
pub const Filter = enum { nearest, linear };
pub const Wrap = enum { clamp_to_edge, repeat };
pub const Upload = struct {
    internal_format: c.GLint = c.GL_RGBA8,
    format: c.GLenum = c.GL_RGBA,
    data_type: c.GLenum = c.GL_UNSIGNED_BYTE,
    filter: Filter = .linear,
    wrap: Wrap = .clamp_to_edge,
    unpack_alignment: ?c.GLint = null, // when set, PixelStorei(UNPACK_ALIGNMENT, v)
};
pub fn create() Texture;                              // GenTextures
pub fn upload2D(self: Texture, w: c_int, h: c_int, data: ?*const anyopaque, o: Upload) void;
pub fn setWrap(self: Texture, wrap: Wrap) void;       // bind + TexParameteri WRAP_S/T
pub fn destroy(self: *Texture) void;                  // DeleteTextures, handle=0
```
`upload2D`: bind, set MIN/MAG filter + WRAP_S/T, optional PixelStorei, TexImage2D. `data` may be null (FBO color attach).

### P2 — `gpu/opengl/Framebuffer.zig` (new) + export via `gpu.zig`/`api.zig`
```zig
handle: c.GLuint = 0,
color: c.GLuint = 0,
width: c_int = 0,
height: c_int = 0,
pub fn initColor(w: c_int, h: c_int) ?Framebuffer;   // gen fbo + color tex (RGBA8 LINEAR CLAMP) + attach + completeness; null+cleanup if incomplete
pub fn bind(self: Framebuffer) void;                  // BindFramebuffer(FRAMEBUFFER, handle) + Viewport(0,0,w,h)
pub fn unbind() void;                                 // BindFramebuffer(FRAMEBUFFER, 0)
pub fn deinit(self: *Framebuffer) void;               // delete fbo + color tex
```
Used by `fbo.zig` (per-Renderer; Renderer keeps raw handles — use `Framebuffer{ .handle=…, .color=…, .width=…, .height=… }` round-trips or store the struct) and `post_process.zig`.

### P3 — `gpu/opengl/Pipeline.zig` extensions
Add: `setVec3(name,x,y,z)`, `setVec4(name,x,y,z,w)`, `drawArrays(mode, first, count)` (non-instanced; increments g_draw_call_count via gl_init).

### P4 — `ui_pipeline.zig`: textured-quad + overlay
- `drawTextureQuad(verts: [6][4]f32, tex: c.GLuint, opacity: f32) void` — emoji pipeline (the `simple_color_shader`): use+bindVao+setProjection(viewport)+opacity uniform+`text`=0+bind tex+upload verts to `quad`+DrawArrays. **No blend change** (caller controls blend, matching the originals).
- New `overlay` pipeline owned by ui_pipeline (built in `init()` from `shaders.vertex_shader_source`/`shaders.overlay_fragment_source`, own VAO over `quad`). Helper `fillOverlay(verts: [6][4]f32, color: [4]f32) void` — use+bindVao+setProjection+`overlayColor`=color+upload+DrawArrays.
- `gl_init.overlay_shader` becomes a compat mirror synced from `ui_pipeline.overlay.program` in `syncSharedHandles()` (so unconverted users keep working). Remove from `gl_init.initShaders` once both `overlays`+`background_image` are converted.

## Conversion order (each: build + `zig build test` + `test-full` green, commit; Windows visual check batched at end)

1. ✅ `file_explorer_renderer`
2. P1+P3 (Texture + Pipeline extensions) — additive
3. P2 (Framebuffer) — additive
4. P4 (ui_pipeline textured-quad + overlay) — additive, wire into ui_pipeline.init + syncSharedHandles
5. `fbo` → Framebuffer + drawTextureQuad
6. `image_renderer` → Texture.upload2D + drawTextureQuad
7. `background_image` → Texture + drawTextureQuad + fillOverlay
8. `post_process` → Framebuffer + dedicated pipeline (Pipeline.init from dynamic source + setVec3) ; keep its own NDC fullscreen-quad VAO/VBO via gpu.Buffer
9. `markdown_preview_renderer` → fillQuad + beginClip/endClip + image part via Texture/drawTextureQuad
10. `overlays` → fillQuad + fillOverlay ; then drop `overlay_shader` from gl_init

## Notes / invariants
- Behavior-preserving: blend bookends stay where they were (background_image disables blend around its image draw; image_renderer relies on ambient). `drawTextureQuad` must NOT change blend.
- `g_draw_call_count` increments preserved on every converted draw.
- After all conversions, each file: no `gl.*`, no `@cInclude("glad/gl.h")`, no `gl_init.*` (except where a file legitimately still needs a gl_init-owned helper — aim for none).
- A6 guard (forbid gl.* outside gpu/opengl) becomes possible once all renderer files convert — out of scope here but this unblocks it.
