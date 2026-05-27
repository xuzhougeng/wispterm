//! Metal backend context lifecycle. Symmetric counterpart to
//! `gpu/opengl/Context.zig`.
//!
//! Owns the Metal device, command queue, and the CAMetalLayer the AppKit host
//! hands in. Until the AppKit host exists, tests can initialize a standalone
//! layer by passing null.
//!   - `gl`: the transitional GL-flavored table (`gpu.glTable()` returns `&gl`).
//!   - `init(...)`: context bring-up. Signature kept identical to the OpenGL
//!     backend (`init(loader: c.GLADloadfunc) !void`) so the AppWindow call site
//!     `gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress))` compiles
//!     unchanged. On the real Mac backend this parameter is the surface seam:
//!     the AppKit host passes the CAMetalLayer / device handle (re-typed there)
//!     instead of a GL proc-address loader.
const std = @import("std");

const c = @import("c.zig");
const GlTable = @import("GlTable.zig").GlTable;

/// Transitional GL-flavored table (see GlTable.zig). Threadlocal to match the
/// OpenGL backend's storage class (rendering runs on the renderer thread).
pub threadlocal var gl: GlTable = .{};

pub const Handles = extern struct {
    device: ?*anyopaque = null,
    command_queue: ?*anyopaque = null,
    layer: ?*anyopaque = null,
    drawable: ?*anyopaque = null,
    command_buffer: ?*anyopaque = null,
    encoder: ?*anyopaque = null,
};

pub const Error = error{
    MetalContextInitFailed,
};

pub threadlocal var handles: Handles = .{};

extern fn phantty_metal_context_init(layer: ?*anyopaque, out: *Handles, error_buf: [*]u8, error_buf_len: usize) bool;
extern fn phantty_metal_context_deinit(ctx: *Handles) void;
extern fn phantty_metal_context_is_usable(ctx: *const Handles) bool;

/// Bring up the Metal context.
/// The `loader` parameter is the macOS surface seam (today typed as the OpenGL
/// backend's `GLADloadfunc` so the shared call site compiles; re-type it to
/// `?*anyopaque` / `*CAMetalLayer` when implementing).
pub fn init(loader: c.GLADloadfunc) !void {
    _ = loader;
    try initWithLayer(null);
}

/// Bring up Metal from an AppKit-created CAMetalLayer. Passing null creates a
/// standalone layer for native interface tests until the AppKit host exists.
pub fn initWithLayer(layer: ?*anyopaque) !void {
    if (isInitialized()) deinit();

    var error_buf: [256]u8 = @splat(0);
    if (!phantty_metal_context_init(layer, &handles, &error_buf, error_buf.len)) {
        const end = std.mem.indexOfScalar(u8, &error_buf, 0) orelse error_buf.len;
        std.debug.print("Metal context init failed: {s}\n", .{error_buf[0..end]});
        return Error.MetalContextInitFailed;
    }
}

pub fn deinit() void {
    if (!isInitialized()) return;
    phantty_metal_context_deinit(&handles);
}

pub fn isInitialized() bool {
    return phantty_metal_context_is_usable(&handles);
}

pub fn deviceHandle() ?*anyopaque {
    return handles.device;
}

pub fn commandQueueHandle() ?*anyopaque {
    return handles.command_queue;
}

pub fn layerHandle() ?*anyopaque {
    return handles.layer;
}
