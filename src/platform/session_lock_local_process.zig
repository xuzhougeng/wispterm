const std = @import("std");

pub const Reservation = struct {
    handle: bool = false,

    pub fn deinit(self: *Reservation) void {
        self.handle = false;
    }
};

pub fn reserveSessionKey(allocator: std.mem.Allocator, session_key: []const u8) !?Reservation {
    _ = allocator;
    _ = session_key;
    return .{ .handle = true };
}
