//! Transitional gl_init mirror for the D3D11 backend.

const c = @import("c.zig");
const Pipeline = @import("Pipeline.zig");

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

pub threadlocal var vao: c.GLuint = 1;
pub threadlocal var vbo: c.GLuint = 1;
pub threadlocal var shader_program: c.GLuint = 1;
pub threadlocal var simple_color_shader: c.GLuint = 1;
pub threadlocal var g_draw_call_count: u32 = 0;
pub threadlocal var g_bg_opacity: f32 = 1.0;

pub fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    return Pipeline.compileShader(shader_type, source);
}

pub fn initShaders() bool {
    return true;
}

pub fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    if (g_hooks) |hk| hk.fillQuad(x, y, w, h, color);
}

pub fn renderQuadAlpha(x: f32, y: f32, w: f32, h: f32, color: [3]f32, alpha: f32) void {
    if (g_hooks) |hk| hk.fillQuadAlpha(x, y, w, h, color, alpha);
}

pub fn setProjection(width: f32, height: f32) void {
    if (g_hooks) |hk| hk.setProjection(width, height);
}

pub fn syncSharedHandles() void {}

pub fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    _ = program;
    _ = window_height;
}
