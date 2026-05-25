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
    .windows => @import("clipboard_windows.zig"),
    .unsupported => @import("clipboard_unsupported.zig"),
};

pub const Owner = impl.Owner;

pub const windowOwner = impl.windowOwner;
pub const writeText = impl.writeText;
pub const readText = impl.readText;
pub const readImageAsPngTemp = impl.readImageAsPngTemp;
pub const normalizeText = impl.normalizeText;

test "platform clipboard normalizes Windows newlines before paste encoding" {
    const text = try normalizeText(std.testing.allocator, "a\r\nb\rc\nd");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("a\nb\nc\nd", text);
}

test "platform clipboard exposes text read write API with an opaque owner" {
    const owner = windowOwner(1234);

    try std.testing.expectEqual(@as(?usize, 1234), owner.native_window);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(@TypeOf(writeText)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".params[2].type.? == []const u8);
    try std.testing.expect(@typeInfo(@TypeOf(writeText)).@"fn".return_type.? == bool);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(readText)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(readText)).@"fn".return_type.? == ?[]u8);
}

test "platform clipboard exposes image paste as a temporary png path" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".params[1].type.? == Owner);
    try std.testing.expect(@typeInfo(@TypeOf(readImageAsPngTemp)).@"fn".return_type.? == ?[]u8);
}

test "platform clipboard selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
