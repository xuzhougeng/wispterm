const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("single_instance_windows.zig"),
    .unsupported => @import("single_instance_unsupported.zig"),
};

/// Role of this instance relative to a running WispTerm.
pub const Role = enum {
    /// This is the first/only instance — owns the IPC server.
    first,
    /// A previous instance already owns the IPC server.
    second,
};

/// Try to acquire single-instance ownership. Returns `.first` when this
/// instance should run normally (and optionally start the IPC server), or
/// `.second` when another instance is already running.
pub fn acquire(allocator: std.mem.Allocator) !Role {
    return impl.acquire(allocator);
}

/// Release the single-instance claim. Called at shutdown on the `.first`
/// instance to clean up the mutex and discovery file.
pub fn release(allocator: std.mem.Allocator) void {
    impl.release(allocator);
}

/// Forward a path (or the current working directory) to the running instance
/// via the IPC discovery port. Returns true on success (second instance → first
/// instance received the path). No-op on unsupported platforms.
pub fn forwardCwd(allocator: std.mem.Allocator, path: ?[]const u8) bool {
    return impl.forwardCwd(allocator, path);
}

/// IPC server: listens on a background thread for incoming cwd paths from
/// second-instance clients and makes them available to the main thread.
pub const Server = impl.Server;

/// Global reference to the active server (set by main.zig after starting it,
/// read by AppWindow to check for pending cwd during first-tab creation).
var g_active_server: ?*Server = null;

pub fn setActiveServer(srv: ?*Server) void {
    g_active_server = srv;
}

pub fn getActiveServer() ?*Server {
    return g_active_server;
}

test "platform single_instance selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}

test "platform single_instance API shape" {
    _ = Role;
    _ = acquire;
    _ = forwardCwd;
    _ = Server;
}
