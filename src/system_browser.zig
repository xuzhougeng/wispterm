//! Compatibility wrapper for opening URLs with the platform default browser.

const std = @import("std");
const platform_open_url = @import("platform/open_url.zig");

pub fn openUrl(allocator: std.mem.Allocator, url: []const u8) bool {
    return platform_open_url.open(allocator, .{ .url = url });
}

test "system browser wrapper exposes only the platform-neutral URL open API" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(openUrl)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(openUrl)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(openUrl)).@"fn".params[1].type.? == []const u8);
    try std.testing.expect(@typeInfo(@TypeOf(openUrl)).@"fn".return_type.? == bool);
}
