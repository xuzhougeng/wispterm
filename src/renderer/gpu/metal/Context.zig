//! Metal backend context lifecycle. Symmetric counterpart to
//! `gpu/opengl/Context.zig`.
//!
//! D-prep STUB: the real implementation will own the Metal device, command
//! queue, and the CAMetalLayer the AppKit host hands in. For now it exposes the
//! same public surface the spine + diagnostics need:
//!   - `gl`: the transitional GL-flavored table (`gpu.glTable()` returns `&gl`).
//!   - `init(...)`: context bring-up. Signature kept identical to the OpenGL
//!     backend (`init(loader: c.GLADloadfunc) !void`) so the AppWindow call site
//!     `gpu.Context.init(@ptrCast(&window_backend.glGetProcAddress))` compiles
//!     unchanged. On the real Mac backend this parameter is the surface seam:
//!     the AppKit host passes the CAMetalLayer / device handle (re-typed there)
//!     instead of a GL proc-address loader.
const c = @import("c.zig");
const GlTable = @import("GlTable.zig").GlTable;

/// Transitional GL-flavored table (see GlTable.zig). Threadlocal to match the
/// OpenGL backend's storage class (rendering runs on the renderer thread).
pub threadlocal var gl: GlTable = .{};

/// Bring up the Metal context. STUB — fill in on a Mac:
///   1. Take the CAMetalLayer the AppKit host created for the window.
///   2. Acquire `MTLCreateSystemDefaultDevice()` + a command queue.
///   3. Wire the device/queue/layer into module state for the primitives.
/// The `loader` parameter is the macOS surface seam (today typed as the OpenGL
/// backend's `GLADloadfunc` so the shared call site compiles; re-type it to
/// `?*anyopaque` / `*CAMetalLayer` when implementing).
pub fn init(loader: c.GLADloadfunc) !void {
    _ = loader;
    @panic("metal: TODO D1 — Context.init (acquire MTLDevice + CAMetalLayer)");
}
