//! Metal backend render-state + frame seam. Mirrors `gpu/opengl/render_state.zig`:
//! same public types (`Rect`/`Size`/`BlendMode`/`ScissorState`) and same fns
//! (`beginFrame`/`endFrame`/`setBlendEnabled`/`setBlendMode`/`clear`/
//! `setViewport`/`viewportSize`/`setScissor`/`disableScissor`/`scissorState`/
//! `restoreScissor`). D-prep STUB: bodies `@panic("metal: TODO D1")` (the
//! OpenGL frame seam was a no-op, but the Metal backend OWNS the command buffer
//! here, so even `beginFrame`/`endFrame` become real work — left as TODO).

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = enum { alpha, premultiplied };
pub const ScissorState = struct { enabled: bool, box: Rect };

/// Frame seam — the Metal backend owns the command buffer / drawable here.
pub fn beginFrame() void {
    @panic("metal: TODO D1 — render_state.beginFrame (acquire drawable + command buffer)");
}
pub fn endFrame() void {
    @panic("metal: TODO D1 — render_state.endFrame (commit + present drawable)");
}

pub fn setBlendEnabled(enabled: bool) void {
    _ = enabled;
    @panic("metal: TODO D1 — render_state.setBlendEnabled");
}

pub fn setBlendMode(mode: BlendMode) void {
    _ = mode;
    @panic("metal: TODO D1 — render_state.setBlendMode");
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    _ = r;
    _ = g;
    _ = b;
    _ = a;
    @panic("metal: TODO D1 — render_state.clear");
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    @panic("metal: TODO D1 — render_state.setViewport");
}

pub fn viewportSize() Size {
    @panic("metal: TODO D1 — render_state.viewportSize");
}

pub fn setScissor(rect: Rect) void {
    _ = rect;
    @panic("metal: TODO D1 — render_state.setScissor");
}

pub fn disableScissor() void {
    @panic("metal: TODO D1 — render_state.disableScissor");
}

pub fn scissorState() ScissorState {
    @panic("metal: TODO D1 — render_state.scissorState");
}

pub fn restoreScissor(s: ScissorState) void {
    _ = s;
    @panic("metal: TODO D1 — render_state.restoreScissor");
}
