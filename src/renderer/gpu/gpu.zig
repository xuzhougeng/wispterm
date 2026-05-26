//! GraphicsAPI spine. Resolves the active GPU backend at comptime (Ghostty
//! style, no runtime vtable) and re-exports its types. See
//! docs/decoupling-guide.md §2 and the spec for the abstraction hierarchy.
const builtin = @import("builtin");
const opengl = @import("opengl/api.zig");

pub const Backend = @import("backend.zig").Backend;
pub const active: Backend = Backend.default(builtin.os.tag);

const impl = switch (active) {
    .opengl => opengl,
    .metal => @compileError("metal backend is Phase D (not yet implemented)"),
};

// The active backend's surface. The GL table lives in the backend (moved out
// of AppWindow in A2); the app reaches it through the decls below.
pub const Context = impl.Context; // context lifecycle (owns the GL table)
pub const c = impl.c; // GL constants/types (transition: removed from app code by A6)
pub const gl_init = impl.gl_init; // GL helpers + buffers (GLSL in shaders.zig)
pub const shaders = impl.shaders; // backend GLSL sources (for cell pipelines)

/// Pointer to the active backend's GL function table. Transition handle used by
/// renderer files until they route through the primitives (A3); removed in A6.
pub inline fn glTable() *impl.GlTable {
    return &Context.gl;
}

// Reserved Ghostty-shaped primitive slots (bodies land in A3/A4):
pub const Texture = impl.Texture;
pub const Buffer = impl.Buffer;
pub const Pipeline = impl.Pipeline;
pub const Framebuffer = impl.Framebuffer;
pub const state = impl.render_state;
pub const vertex = impl.vertex;
