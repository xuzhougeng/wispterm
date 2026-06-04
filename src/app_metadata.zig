const std = @import("std");
const build_options = @import("build_options");

pub const name = "WispTerm";
pub const version = build_options.app_version;

/// Release notes for the running build (contents of `release-notes/v{version}.md`),
/// embedded at build time. Empty string when no notes file existed at build time.
pub const release_notes = build_options.release_notes;

pub fn versionLine(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}", .{ name, version });
}

pub fn printVersion(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}
