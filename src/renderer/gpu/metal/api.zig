//! Metal backend root. Symmetric counterpart to `gpu/opengl/api.zig`: re-exports
//! the backend's primitives for `gpu.zig` to resolve at comptime on Darwin.
//!
//! The primitives mirror the OpenGL backend's public surface so the shared
//! rendering layer + AppWindow compile against either backend.

pub const c = @import("c.zig"); // GL-flavored constants/types shim (no @cInclude)
pub const Context = @import("Context.zig"); // context lifecycle + GL table
pub const GlTable = @import("GlTable.zig").GlTable; // the table type (for gpu.glTable())

pub const gl_init = @import("gl_init.zig");

pub const Buffer = @import("Buffer.zig");
pub const Texture = @import("Texture.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const readback = @import("readback.zig");
pub const shaders = @import("shaders.zig");
pub const render_state = @import("render_state.zig");
pub const vertex = @import("vertex.zig");
