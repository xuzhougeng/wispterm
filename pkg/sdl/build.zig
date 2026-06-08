const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module = b.addModule("sdl", .{
        .root_source_file = b.path("sdl.zig"),
        .target = target,
    });
    module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    module.linkSystemLibrary("SDL3", .{});
}
