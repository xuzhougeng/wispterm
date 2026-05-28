const std = @import("std");
const builtin = @import("builtin");
const shared = @import("process_shared.zig");

extern fn phantty_macos_proc_cwd(pid: i32, buf: [*]u8, buf_len: i32) i32;

pub fn currentProcessId() u32 {
    return @intCast(std.c.getpid());
}

/// Best-effort current working directory of a live process by pid. macOS uses
/// proc_pidinfo via the ObjC bridge; Linux reads /proc/<pid>/cwd. Caller owns
/// the returned slice. Used to resolve relative preview paths for shells that
/// don't emit OSC 7 (e.g. zsh).
pub fn processCwd(allocator: std.mem.Allocator, pid: i32) ?[]u8 {
    if (pid <= 0) return null;
    if (builtin.os.tag == .macos) {
        var buf: [4096]u8 = undefined;
        const len = phantty_macos_proc_cwd(pid, &buf, @intCast(buf.len));
        if (len <= 0) return null;
        return allocator.dupe(u8, buf[0..@intCast(len)]) catch null;
    } else {
        var link_buf: [64]u8 = undefined;
        const link = std.fmt.bufPrint(&link_buf, "/proc/{d}/cwd", .{pid}) catch return null;
        var path_buf: [4096]u8 = undefined;
        const path = std.fs.readLinkAbsolute(link, &path_buf) catch return null;
        return allocator.dupe(u8, path) catch null;
    }
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
pub fn childExited(id: std.process.Child.Id, timeout_ms: u32) shared.ChildExit {
    const target: i32 = @intCast(id);
    var elapsed: u32 = 0;
    while (true) {
        switch (shared.reapChild(target, shared.WNOHANG)) {
            .reaped => |code| return .{ .exited = code },
            .reaped_unknown, .no_child => return .gone,
            .still_running => {},
        }

        if (elapsed >= timeout_ms) return .running;
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
