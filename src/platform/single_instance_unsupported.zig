const std = @import("std");

/// On unsupported platforms the first instance always succeeds (no-op).
pub fn acquire(_: std.mem.Allocator) !@import("single_instance.zig").Role {
    return .first;
}

pub fn release(_: std.mem.Allocator) void {}

pub const Server = struct {
    pub fn start(_: std.mem.Allocator) !*Server {
        @compileError("single-instance not supported on this platform");
    }
    pub fn stop(_: *Server) void {}
    pub fn destroy(_: *Server) void {}
    pub fn tryTakeCwd(_: *Server) ?[]u8 { return null; }
    pub fn tryTakeActivate(_: *Server) bool { return false; }
};

pub fn forwardCwd(_: std.mem.Allocator, _: ?[]const u8) bool {
    return false;
}
