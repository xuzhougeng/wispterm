//! Concurrently drain a child process's stdout and stderr to EOF so neither
//! pipe can fill and deadlock the other. The classic bug this prevents: read
//! stdout fully *then* stderr — if the child writes >64KB to stderr it blocks
//! on the full stderr pipe, never closes stdout, and the reader waits forever.
//!
//! Stored bytes are capped per stream, but BOTH streams are always read to EOF
//! (excess is discarded) so the child can always make progress and exit.

const std = @import("std");
const builtin = @import("builtin");

pub const Captured = struct {
    stdout: []u8, // owned, truncated to stdout_max
    stderr: []u8, // owned, truncated to stderr_max

    pub fn deinit(self: *Captured, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const Drain = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    max: usize,
    out: std.ArrayListUnmanaged(u8) = .empty,
    oom: bool = false,
};

fn drain(d: *Drain) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = d.file.read(&buf) catch break;
        if (n == 0) break;
        if (d.out.items.len < d.max and !d.oom) {
            const room = d.max - d.out.items.len;
            const take = @min(room, n);
            d.out.appendSlice(d.allocator, buf[0..take]) catch {
                d.oom = true;
                // keep looping to drain the rest to EOF, just stop storing
            };
        }
        // past the cap (or after OOM): keep reading to EOF, discard bytes
    }
}

/// Read `stdout_file` on the calling thread and `stderr_file` on a worker
/// thread, both to EOF. Caller owns the returned slices. Caller is responsible
/// for `child.wait()` AFTER this returns (both pipes are drained, so wait won't
/// block on a full pipe).
pub fn capture(
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    stderr_file: std.fs.File,
    stdout_max: usize,
    stderr_max: usize,
) !Captured {
    var err_d = Drain{ .file = stderr_file, .allocator = allocator, .max = stderr_max };
    const err_thread = try std.Thread.spawn(.{}, drain, .{&err_d});
    var out_d = Drain{ .file = stdout_file, .allocator = allocator, .max = stdout_max };
    drain(&out_d);
    err_thread.join();

    errdefer {
        out_d.out.deinit(allocator);
        err_d.out.deinit(allocator);
    }
    if (out_d.oom or err_d.oom) return error.OutOfMemory;
    const stdout_slice = try out_d.out.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try err_d.out.toOwnedSlice(allocator);
    return .{ .stdout = stdout_slice, .stderr = stderr_slice };
}

fn largeStderrCommand() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{
            "cmd.exe",
            "/C",
            "echo hello & for /L %i in (1,1,40000) do @echo E 1>&2",
        },
        else => &.{ "sh", "-c", "printf hello; printf 'E%.0s' $(seq 1 100000) 1>&2" },
    };
}

fn cappedStdoutCommand() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{
            "cmd.exe",
            "/C",
            "for /L %i in (1,1,5000) do @echo O",
        },
        else => &.{ "sh", "-c", "printf 'O%.0s' $(seq 1 5000)" },
    };
}

test "capture drains both streams without deadlock when stderr is large" {
    const a = std.testing.allocator;
    // Child writes a small stdout and a >64KB stderr. The old "read stdout to
    // EOF then stderr" order would deadlock here; concurrent drain must not.
    var child = std.process.Child.init(largeStderrCommand(), a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var cap = try capture(a, child.stdout.?, child.stderr.?, 1024 * 1024, 1024 * 1024);
    defer cap.deinit(a);
    _ = try child.wait();
    try std.testing.expect(std.mem.indexOf(u8, cap.stdout, "hello") != null);
    try std.testing.expect(cap.stderr.len > 64 * 1024);
}

test "capture truncates stored bytes to the cap but still reaches EOF" {
    const a = std.testing.allocator;
    var child = std.process.Child.init(cappedStdoutCommand(), a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var cap = try capture(a, child.stdout.?, child.stderr.?, 100, 100);
    defer cap.deinit(a);
    const term = try child.wait();
    try std.testing.expectEqual(@as(usize, 100), cap.stdout.len); // capped
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term); // reached EOF/exit
}
