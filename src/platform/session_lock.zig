const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    portable,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .portable,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("session_lock_windows.zig"),
    .portable => @import("session_lock_local_process.zig"),
};

pub const Reservation = impl.Reservation;
pub const reserveSessionKey = impl.reserveSessionKey;

test "platform session lock exposes reservation API" {
    try std.testing.expect(@hasDecl(@This(), "Reservation"));

    const reserve_info = @typeInfo(@TypeOf(reserveSessionKey)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), reserve_info.params.len);
    try std.testing.expect(reserve_info.params[0].type.? == std.mem.Allocator);
    try std.testing.expect(reserve_info.params[1].type.? == []const u8);

    if (@import("builtin").os.tag != .windows) {
        var reservation = (try reserveSessionKey(std.testing.allocator, "dev-session")).?;
        reservation.deinit();
    }
}

test "platform session lock selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.portable, backendForOs(.linux));
    try std.testing.expectEqual(Backend.portable, backendForOs(.macos));
}
