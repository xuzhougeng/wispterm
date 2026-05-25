const std = @import("std");
const shared = @import("process_shared.zig");

pub fn currentProcessId() u32 {
    return @intCast(std.c.getpid());
}

pub fn waitForPid(pid: u32, timeout_ms: u32, diagnostic: ?*shared.WaitForPidDiagnostic) !void {
    _ = pid;
    _ = timeout_ms;
    _ = diagnostic;
}

pub fn childExited(id: std.process.Child.Id, timeout_ms: u32) bool {
    _ = id;
    _ = timeout_ms;
    return false;
}

pub fn terminateChild(id: std.process.Child.Id) void {
    std.posix.kill(id, std.posix.SIG.TERM) catch {};
}

pub fn writeAllToPipe(file: std.fs.File, data: []const u8) shared.PipeWriteError!void {
    return file.writeAll(data) catch |err| switch (err) {
        error.BrokenPipe => error.BrokenPipe,
        else => error.WriteFailed,
    };
}

pub fn spawnDetachedWithOptions(allocator: std.mem.Allocator, options: shared.DetachedSpawnOptions) !void {
    const child = try allocator.create(std.process.Child);
    errdefer allocator.destroy(child);

    child.* = std.process.Child.init(options.argv, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const thread = try std.Thread.spawn(.{}, waitAndDestroyChild, .{ allocator, child });
    thread.detach();
}

fn waitAndDestroyChild(allocator: std.mem.Allocator, child: *std.process.Child) void {
    _ = child.wait() catch {};
    allocator.destroy(child);
}
