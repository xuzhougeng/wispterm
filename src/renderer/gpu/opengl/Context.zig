//! Owns the OpenGL context lifecycle for the OpenGL backend: the glad function
//! table and the one-time load. Replaces the `gl` var + gladLoad that lived in
//! AppWindow.zig (resolves the Renderer.zig:14 "AppWindow owns the GL context"
//! shortcut). The host supplies the proc-address loader; the backend owns the
//! table.
const std = @import("std");
const c = @import("c.zig").c;

/// The active glad function table. Threadlocal because rendering runs on the
/// renderer thread (preserves the previous storage class).
pub threadlocal var gl: c.GladGLContext = undefined;

/// Load the GL function table via glad using the host's proc-address loader.
/// `loader` is `@ptrCast(&window_backend.glGetProcAddress)` from the host.
pub fn init(loader: c.GLADloadfunc) !void {
    const version = c.gladLoadGLContext(&gl, loader);
    if (version == 0) {
        std.debug.print("Failed to initialize GLAD\n", .{});
        return error.GLADInitFailed;
    }
    std.debug.print("OpenGL {}.{}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version) });
}
