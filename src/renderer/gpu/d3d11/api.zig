//! Direct3D 11 backend root. This mirrors the OpenGL/Metal backend spine so
//! `gpu.zig` can resolve the active backend at comptime.

pub const c = @import("c.zig");
pub const Context = @import("Context.zig");
pub const GlTable = @import("GlTable.zig").GlTable;

pub const gl_init = @import("gl_init.zig");

pub const Buffer = @import("Buffer.zig");
pub const Texture = @import("Texture.zig");
pub const Pipeline = @import("Pipeline.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const readback = @import("readback.zig");
pub const shaders = @import("shaders.zig");
pub const render_state = @import("render_state.zig");
pub const vertex = @import("vertex.zig");
