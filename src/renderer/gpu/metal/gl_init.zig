//! Metal backend gl_init mirror. Symmetric counterpart to
//! `gpu/opengl/gl_init.zig`. Mirrors the PUBLIC surface the app reaches through
//! `gpu.gl_init.*`:
//!   - data the renderer reads/writes every frame: `g_draw_call_count`,
//!     `g_bg_opacity`, and the compat mirror handles
//!     (`vao`/`vbo`/`shader_program`/`simple_color_shader`). These stay as plain
//!     vars (default-initialized) so the read/write call sites compile and run.
//!   - hooks/helpers: `initShaders`, `renderQuad`, `renderQuadAlpha`,
//!     `setProjection`, `syncSharedHandles`, `compileShader`, `linkProgram`,
//!     `setProjectionForProgram`.
//!
//! D1.x: this file now mirrors `gpu/opengl/gl_init.zig`'s delegation to
//! `ui_pipeline` for the solid-color quad helpers and `setProjection`. The
//! prior stub silently dropped these calls — leaving the text pipeline's
//! projection at zero — and every overlay (command center, sidebar, settings
//! page, SSH list, …) rendered into the wrong clip space.
//!
//! NOTE: `ui_pipeline` cannot be imported here at file scope because the
//! `test-metal` build step roots its module at `gpu/metal/test.zig`, and
//! Zig 0.15 rejects imports that walk outside the module root. Transition-era
//! backend tests may still install `BackendHooks` directly; otherwise the
//! helpers below silently no-op. Shared renderer code no longer routes through
//! this compat shim.
const std = @import("std");
const c = @import("c.zig");
const Pipeline = @import("Pipeline.zig");
const render_state = @import("render_state.zig");

/// Function-pointer surface the renderer fills in at startup so this file
/// (which sits inside the Metal backend's module root) can call into
/// `renderer/ui_pipeline.zig` without an absolute import path.
pub const BackendHooks = struct {
    fillQuad: *const fn (x: f32, y: f32, w: f32, h: f32, color: [3]f32) void,
    fillQuadAlpha: *const fn (x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void,
    setProjection: *const fn (width: f32, height: f32) void,
};

threadlocal var g_hooks: ?BackendHooks = null;

pub fn setBackendHooks(hooks: BackendHooks) void {
    g_hooks = hooks;
}

pub fn clearBackendHooks() void {
    g_hooks = null;
}

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
// Shader compilation / linking.
// ----------------------------------------------------------------------------
pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    return Pipeline.compileShader(shader_type, source);
}

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const pipeline = Pipeline.init(vs_src, fs_src, 0);
    return pipeline.program;
}

// ----------------------------------------------------------------------------
// Init hook — stable; nothing to compile here (pipelines built by ui_pipeline).
// ----------------------------------------------------------------------------
pub fn initShaders() bool {
    return true;
}

// ----------------------------------------------------------------------------
// Render helpers — dispatch through optional BackendHooks in backend tests.
// ----------------------------------------------------------------------------
pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    if (g_hooks) |hk| hk.fillQuad(x, y, w, h, color);
}
pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    if (g_hooks) |hk| hk.fillQuadAlpha(x, y, w, h, color, alpha);
}
pub fn setProjection(width: f32, height: f32) void {
    // Do NOT touch the viewport here. The viewport (including its per-pane
    // origin) is set by the caller via `gpu.state.setViewport` immediately
    // before this call; overwriting it to (0,0,w,h) dropped the origin and made
    // every split pane render at the window origin. Projection is width/height
    // only — the origin is honored by the encoder viewport (see bridge.m), the
    // same way the OpenGL backend relies on `glViewport`.
    if (g_hooks) |hk| hk.setProjection(width, height);
}

/// Populate the compat mirror handles from the backend-owned objects.
pub fn syncSharedHandles() void {
    // Metal does not expose GL object names. Keep the mirrors stable for
    // transition-era diagnostics and code that checks nonzero handles.
    if (vao == 0) vao = 1;
    if (vbo == 0) vbo = 1;
    if (shader_program == 0) shader_program = 1;
    if (simple_color_shader == 0) simple_color_shader = 1;
}

/// Set the orthographic projection matrix on a specific program.
pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    _ = program;
    _ = window_height;
}
