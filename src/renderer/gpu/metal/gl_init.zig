//! Metal backend gl_init mirror. Symmetric counterpart to
//! `gpu/opengl/gl_init.zig`. Mirrors the PUBLIC surface the app reaches through
//! `gpu.gl_init.*`:
//!   - data the renderer reads/writes every frame: `g_draw_call_count`,
//!     `g_bg_opacity`, and the compat mirror handles
//!     (`vao`/`vbo`/`shader_program`/`simple_color_shader`). These stay as plain
//!     vars (default-initialized) so the read/write call sites compile and run.
//!   - hooks/helpers: `initShaders`, `renderQuad`, `renderQuadAlpha`,
//!     `setProjection`, `syncSharedHandles`, `compileShader`, `linkProgram`,
//!     `setProjectionForProgram`. GPU-work bodies are `@panic("metal: TODO D1")`.
//!
//! NOTE: unlike the OpenGL backend, this file does NOT import `ui_pipeline`/
//! `AppWindow` — the Metal render helpers will be wired when the backend lands,
//! and keeping the import out avoids extra coupling in the stub.
const c = @import("c.zig");

// ----------------------------------------------------------------------------
// Compat mirror handles (populated by syncSharedHandles on the real backend).
// Threadlocal to match the OpenGL backend's storage class.
// ----------------------------------------------------------------------------
pub threadlocal var vao: c.GLuint = 0;
pub threadlocal var vbo: c.GLuint = 0;
pub threadlocal var shader_program: c.GLuint = 0;
pub threadlocal var simple_color_shader: c.GLuint = 0;

/// Draw-call counter (reset each frame by the renderer).
pub threadlocal var g_draw_call_count: u32 = 0;

/// Opacity for cell background quads (0..1). Set from config; read by the
/// renderer. Plain data — kept live so the read/write sites work.
pub threadlocal var g_bg_opacity: f32 = 1.0;

// ----------------------------------------------------------------------------
// Shader compilation / linking — STUBs.
// ----------------------------------------------------------------------------
pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    _ = shader_type;
    _ = source;
    @panic("metal: TODO D1 — gl_init.compileShader (compile MSL)");
}

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    _ = vs_src;
    _ = fs_src;
    @panic("metal: TODO D1 — gl_init.linkProgram");
}

// ----------------------------------------------------------------------------
// Init hook — stable; nothing to compile here (pipelines built by ui_pipeline).
// ----------------------------------------------------------------------------
pub fn initShaders() bool {
    return true;
}

// ----------------------------------------------------------------------------
// Render helpers — STUBs (delegated to ui_pipeline on the real backend).
// ----------------------------------------------------------------------------
pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = color;
    @panic("metal: TODO D1 — gl_init.renderQuad");
}
pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = color;
    _ = alpha;
    @panic("metal: TODO D1 — gl_init.renderQuadAlpha");
}
pub fn setProjection(width: f32, height: f32) void {
    _ = width;
    _ = height;
    @panic("metal: TODO D1 — gl_init.setProjection");
}

/// Populate the compat mirror handles from the backend-owned objects.
pub fn syncSharedHandles() void {
    @panic("metal: TODO D1 — gl_init.syncSharedHandles");
}

/// Set the orthographic projection matrix on a specific program. STUB.
pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    _ = program;
    _ = window_height;
    @panic("metal: TODO D1 — gl_init.setProjectionForProgram");
}
