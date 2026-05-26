//! Transitional "GL function table" for the Metal backend.
//!
//! The OpenGL backend exposes `c.GladGLContext` (a struct of optional function
//! pointers) as its `GlTable`, and `gpu.glTable()` hands the app a `*GlTable`.
//! AppWindow's render diagnostics still reach through that table directly
//! (`glTable().GetString.?(...)`, `.GetIntegerv.?(...)`, `.IsEnabled.?(...)`).
//!
//! Until those diagnostics are routed through the backend-neutral `state`
//! primitives, the Metal backend must hand back a type-compatible table so the
//! shared code compiles. The fields default to `null`; calling `.?` on them at
//! runtime is the documented "metal: TODO" panic (an unimplemented optional).
//! A real Metal backend will instead expose Metal device/queue introspection
//! here (or, preferably, the diagnostics will be converted off `gpu.c.*`).
const c = @import("c.zig");

/// Mirrors the subset of glad's `GladGLContext` fields the app references via
/// `gpu.glTable()`. Same field names + compatible function-pointer shapes so
/// call sites type-check unchanged.
pub const GlTable = struct {
    GetString: ?*const fn (name: c.GLenum) callconv(.c) [*c]const c.GLubyte = null,
    GetIntegerv: ?*const fn (pname: c.GLenum, data: [*c]c.GLint) callconv(.c) void = null,
    IsEnabled: ?*const fn (cap: c.GLenum) callconv(.c) c.GLboolean = null,
};
