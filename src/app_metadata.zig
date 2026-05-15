const std = @import("std");
const build_options = @import("build_options");

pub const name = "Phantty";
pub const version = build_options.app_version;

pub fn versionLine(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ name, version });
}

pub fn printVersion(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}
