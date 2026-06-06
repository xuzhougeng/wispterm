const std = @import("std");
const platform_process = @import("platform/process.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const password = std.process.getEnvVarOwned(allocator, platform_process.SSH_ASKPASS_PASSWORD_ENV) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(password);

    try std.fs.File.stdout().deprecatedWriter().writeAll(password);
}
