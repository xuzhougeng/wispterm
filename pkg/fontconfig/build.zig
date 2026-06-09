const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module = b.addModule("fontconfig", .{
        .root_source_file = b.path("fontconfig.zig"),
        .target = target,
    });
    module.linkSystemLibrary("fontconfig", .{});
    // fontconfig.h pulls in <stdio.h> etc. from the system includedir, which
    // pkg-config --cflags does not emit (implicit for the system compiler, but
    // Zig's translate-c needs it explicit). Discover it via pkg-config
    // --variable so we don't hardcode a distro-specific prefix.
    if (pkgConfigVariable(b, "fontconfig", "includedir")) |inc| {
        module.addIncludePath(.{ .cwd_relative = inc });
    }
}

/// Resolve a pkg-config variable (e.g. "includedir") at configure time so the
/// header path is not hardcoded per distro. Returns null if unavailable.
fn pkgConfigVariable(b: *std.Build, lib: []const u8, variable: []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", b.fmt("--variable={s}", .{variable}), lib },
    }) catch return null;
    if (result.term != .Exited or result.term.Exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (trimmed.len == 0) null else b.dupe(trimmed);
}
