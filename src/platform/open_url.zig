const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    posix,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .linux, .freebsd, .macos => .posix,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("open_url_windows.zig"),
    .posix => @import("open_url_posix.zig"),
    .unsupported => @import("open_url_unsupported.zig"),
};

pub const Kind = enum {
    unknown,
    text,
    html,
};

pub const Request = struct {
    kind: Kind = .unknown,
    url: []const u8,
};

pub fn open(allocator: std.mem.Allocator, request: Request) bool {
    return impl.open(allocator, request);
}

test "platform open url API accepts a typed request without a native window handle" {
    const request = Request{ .kind = .html, .url = "https://example.test" };

    try std.testing.expectEqual(Kind.html, request.kind);
    try std.testing.expectEqualStrings("https://example.test", request.url);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(open)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(open)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(open)).@"fn".params[1].type.? == Request);
    try std.testing.expect(@typeInfo(@TypeOf(open)).@"fn".return_type.? == bool);
}

test "platform open url selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.posix, backendForOs(.linux));
    try std.testing.expectEqual(Backend.posix, backendForOs(.macos));
}
