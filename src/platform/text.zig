const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("text_windows.zig"),
    .unsupported => @import("text_unsupported.zig"),
};

pub const nativeOrdinalIgnoreCaseUtf8Equal = impl.nativeOrdinalIgnoreCaseUtf8Equal;

test "platform text exposes optional native ordinal ignore-case comparison" {
    const info = @typeInfo(@TypeOf(nativeOrdinalIgnoreCaseUtf8Equal)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), info.params.len);
    try std.testing.expect(info.params[0].type.? == []const u8);
    try std.testing.expect(info.params[1].type.? == []const u8);
    try std.testing.expect(info.return_type.? == ?bool);

    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(?bool, null), nativeOrdinalIgnoreCaseUtf8Equal("A", "a"));
    }
}

test "platform text selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
