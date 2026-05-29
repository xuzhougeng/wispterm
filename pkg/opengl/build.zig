const std = @import("std");

pub fn build(b: *std.Build) !void {
    const module = b.addModule("opengl", .{ .root_source_file = b.path("main.zig") });
    // Path adjusted for wispterm project structure
    module.addIncludePath(b.path("../../vendor/glad/include"));
}
