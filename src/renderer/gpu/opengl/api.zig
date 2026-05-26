//! OpenGL backend root. Re-exports the backend's primitives for `gpu.zig` to
//! resolve at comptime. The first GraphicsAPI backend; `metal/` mirrors this
//! in Phase D.
const c_mod = @import("c.zig");

pub const c = c_mod.c;                       // glad constants/types
pub const Context = @import("Context.zig");  // context lifecycle + GL table
pub const GlTable = c_mod.c.GladGLContext;   // the table type

/// gl_init helpers live in the same directory as api.zig.
pub const gl_init = @import("gl_init.zig");

// Reserved Ghostty-shaped primitive slots. Declared now so gpu.zig's public
// surface is stable; bodies are filled when the renderers are rewritten.
pub const Texture = struct {}; // reserved: A4 (font atlas → GPU texture)
pub const Buffer = struct {}; // reserved: A3
pub const Pipeline = struct {}; // reserved: A3
