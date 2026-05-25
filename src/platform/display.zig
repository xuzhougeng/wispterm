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
    .windows => @import("display_windows.zig"),
    .portable => @import("display_portable.zig"),
};

pub const default_dpi = impl.default_dpi;

pub const isPointOnAnyDisplay = impl.isPointOnAnyDisplay;

pub fn scaledPixels26Dot6ForDpi(pixels_at_default_dpi: u32, dpi: u32) i32 {
    const scaled: u64 = @as(u64, pixels_at_default_dpi) * 64 * @as(u64, dpi) / default_dpi;
    return @intCast(scaled);
}

test "platform display exposes point visibility check" {
    const info = @typeInfo(@TypeOf(isPointOnAnyDisplay)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), info.params.len);
    try std.testing.expect(info.params[0].type.? == i32);
    try std.testing.expect(info.params[1].type.? == i32);
    try std.testing.expect(info.return_type.? == bool);

    if (builtin.os.tag != .windows) {
        try std.testing.expect(isPointOnAnyDisplay(0, 0));
    }
}

test "platform display selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.portable, backendForOs(.linux));
    try std.testing.expectEqual(Backend.portable, backendForOs(.macos));
}

test "platform display exposes baseline DPI scaling helpers" {
    try std.testing.expectEqual(@as(u32, 96), default_dpi);
    try std.testing.expectEqual(@as(i32, 10 * 64), scaledPixels26Dot6ForDpi(10, default_dpi));
    try std.testing.expectEqual(@as(i32, 20 * 64), scaledPixels26Dot6ForDpi(10, default_dpi * 2));
}
