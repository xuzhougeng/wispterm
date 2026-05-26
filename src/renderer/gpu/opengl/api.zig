//! OpenGL backend root. Re-exports the backend's primitives for `gpu.zig` to
//! resolve at comptime. The first GraphicsAPI backend; `metal/` mirrors this
//! in Phase D.
const c_mod = @import("c.zig");

pub const c = c_mod.c;                       // glad constants/types
pub const Context = @import("Context.zig");  // context lifecycle + GL table
pub const GlTable = c_mod.c.GladGLContext;   // the table type

/// gl_init helpers live in the same directory as api.zig.
pub const gl_init = @import("gl_init.zig");

pub const Buffer = @import("Buffer.zig");
pub const Texture = @import("Texture.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const shaders = @import("shaders.zig");
pub const render_state = @import("render_state.zig");
pub const vertex = @import("vertex.zig");
