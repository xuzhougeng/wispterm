const std = @import("std");

const ssh_askpass_password_env = "WISPTERM_SSH_PASSWORD";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const password = std.process.getEnvVarOwned(allocator, ssh_askpass_password_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(password);

    try std.fs.File.stdout().deprecatedWriter().writeAll(password);
}
