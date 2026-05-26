const std = @import("std");
const shared = @import("process_shared.zig");

pub fn currentProcessId() u32 {
    return @intCast(std.c.getpid());
}

const POLL_STEP_MS: u32 = 5;

/// Polls a non-blocking child reap until the child is reaped or `timeout_ms`
/// elapses. Reaping (or a vanished/unknown child) is treated as success; an
/// outright timeout returns `error.WaitTimeout`.
pub fn waitForPid(pid: u32, timeout_ms: u32, diagnostic: ?*shared.WaitForPidDiagnostic) !void {
    const target: i32 = @intCast(pid);
    var elapsed: u32 = 0;
    while (true) {
        switch (shared.reapChild(target, shared.WNOHANG)) {
            .reaped, .reaped_unknown, .no_child => return,
            .still_running => {},
        }

        if (elapsed >= timeout_ms) {
            if (diagnostic) |d| {
                d.operation = "waitpid";
                d.code = 0;
                d.wait_result = 0;
            }
            return error.WaitTimeout;
        }

        const step = @min(POLL_STEP_MS, timeout_ms - elapsed);
        std.Thread.sleep(@as(u64, step) * std.time.ns_per_ms);
        elapsed += step;
    }
}

/// Returns true if the child has exited (reaped now) or is no longer a child of
/// this process, polling up to `timeout_ms`. Still-running within the window
/// returns false.
pub fn childExited(id: std.process.Child.Id, timeout_ms: u32) bool {
    const target: i32 = @intCast(id);
    var elapsed: u32 = 0;
    while (true) {
        switch (shared.reapChild(target, shared.WNOHANG)) {
            .reaped, .reaped_unknown, .no_child => return true,
            .still_running => {},
        }

        if (elapsed >= timeout_ms) return false;
        const step = @min(POLL_STEP_MS, timeout_ms - elapsed);
        std.Thread.sleep(@as(u64, step) * std.time.ns_per_ms);
        elapsed += step;
    }
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
