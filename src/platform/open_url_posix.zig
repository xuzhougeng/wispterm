const std = @import("std");
const builtin = @import("builtin");
const platform_process = @import("process.zig");

pub fn open(allocator: std.mem.Allocator, request: anytype) bool {
    switch (builtin.os.tag) {
        .linux, .freebsd => platform_process.spawnDetached(allocator, &.{ "xdg-open", request.url }) catch return false,
        .macos => switch (request.kind) {
            .text => platform_process.spawnDetached(allocator, &.{ "open", "-t", request.url }) catch return false,
            .html, .unknown => platform_process.spawnDetached(allocator, &.{ "open", request.url }) catch return false,
        },
        else => return false,
    }
    return true;
}

pub fn reveal(allocator: std.mem.Allocator, path: []const u8) bool {
    switch (builtin.os.tag) {
        // `open -R` reveals the file in Finder with it selected.
        .macos => platform_process.spawnDetached(allocator, &.{ "open", "-R", path }) catch return false,
        // No portable "select file" verb; open the containing folder instead.
        .linux, .freebsd => {
            const dir = std.fs.path.dirname(path) orelse path;
            platform_process.spawnDetached(allocator, &.{ "xdg-open", dir }) catch return false;
        },
        else => return false,
    }
    return true;
}
