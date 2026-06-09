const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module = b.addModule("sdl", .{
        .root_source_file = b.path("sdl.zig"),
        .target = target,
    });
    // pkg-config (the default for linkSystemLibrary) supplies SDL3's include
    // dirs and link flags, so the @cImport resolves wherever SDL3 is installed
    // — no hardcoded prefix. The parent threads the resolved target via
    // b.lazyDependency("sdl", .{ .target = target }).
    module.linkSystemLibrary("SDL3", .{});
}
