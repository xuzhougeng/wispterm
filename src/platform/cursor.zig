const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    macos,
    linux,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("cursor_windows.zig"),
    .macos => @import("cursor_macos.zig"),
    .linux => @import("cursor_linux.zig"),
    .unsupported => @import("cursor_unsupported.zig"),
};

pub const Shape = enum {
    arrow,
    ibeam,
    size_we,
    size_ns,
    size_all,
};

pub fn set(shape: Shape) void {
    impl.set(shape);
}

test "platform cursor exposes backend-neutral cursor shapes" {
    try std.testing.expectEqual(Shape.arrow, Shape.arrow);
    try std.testing.expectEqual(Shape.ibeam, Shape.ibeam);
    try std.testing.expectEqual(Shape.size_we, Shape.size_we);
    try std.testing.expectEqual(Shape.size_ns, Shape.size_ns);
    try std.testing.expectEqual(Shape.size_all, Shape.size_all);
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(set)).@"fn".return_type.?);
}

test "platform cursor selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.linux, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}
