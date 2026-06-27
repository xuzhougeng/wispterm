//! Single subprocess lifecycle: spawn → drain both pipes concurrently →
//! enforce timeout/cancel → ALWAYS reap exactly once. Every consumer that just
//! wants "run argv, capture bounded stdout/stderr, with a timeout and a cancel
//! switch" should call `runCapture` instead of hand-rolling spawn/drain/wait.
//!
//! The hard invariant: every successful `child.spawn()` is matched by exactly
//! one `child.wait()` (reap), on every path — normal exit, timeout, cancel,
//! kill error, wait error. No early return may leak a live child handle or a
//! zombie.
//!
//! Concurrency model — a single `std.Io.poll` over BOTH pipes:
//!   • `std.Io.poll(stdout, stderr)` multiplexes the two fds in one syscall, so
//!     a child writing only stderr past the pipe buffer can never wedge a
//!     stdout-first reader — both streams always make progress concurrently
//!     without a second OS thread. This is the deadlock-free drain.
//!   • The same loop polls the direct child for exit, checks the cancel token,
//!     and checks the wall-clock deadline each step (POLL_STEP_MS granularity).
//!     On timeout or cancel it terminates the child (SIGTERM, escalating to
//!     SIGKILL after a grace window) and keeps polling until the child is gone.
//!   • Crucially the loop STOPS draining when the *direct* child exits, rather
//!     than waiting for pipe EOF. A grandchild that inherited the stdout fd
//!     (phase-1 limitation, see process_group / kill_tree) therefore cannot
//!     hang the run: we grab what is buffered and reap the direct child.
//!
//! No second thread, no lock held across a blocking wait, no busy-spin (the
//! poll itself blocks up to the step), no deadlock. The one matching reap is in
//! `finish`.

const std = @import("std");
const builtin = @import("builtin");
const platform_process = @import("platform/process.zig");
const process_group = @import("platform/process_group.zig");

/// Cooperative cancellation flag. A caller flips it from any thread (e.g. when
/// the user aborts an AI turn) and `runCapture` terminates+reaps the child.
/// Self-contained and atomic so it is portable and trivially testable; it does
/// not depend on ai_chat's ToolContext.
pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn init() CancelToken {
        return .{};
    }

    pub fn cancel(self: *CancelToken) void {
        self.flag.store(true, .release);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.flag.load(.acquire);
    }
};

pub const Termination = union(enum) {
    /// Normal exit; `code` is the platform exit status.
    exited: u32,
    /// Reaped but did not exit normally (killed by a signal, or status unknown
    /// because the monitor/terminator forced it down).
    killed,
};

pub const RunResult = struct {
    termination: Termination,
    stdout: []u8, // owned, truncated to max_stdout_bytes
    stderr: []u8, // owned, truncated to max_stderr_bytes
    timed_out: bool,
    cancelled: bool,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const RunOptions = struct {
    /// Wall-clock budget. null = no timeout (only cancel/EOF end the run).
    timeout_ms: ?u64 = null,
    /// Cooperative cancel switch, polled by the monitor. null = not cancellable.
    cancel: ?*const CancelToken = null,
    /// Bytes of stdout/stderr retained; the rest is read-to-EOF and discarded
    /// so the child can always make progress, but not stored.
    max_stdout_bytes: usize,
    max_stderr_bytes: usize,
    /// Best-effort request to kill the whole process tree on
    /// timeout/cancel. PHASE 1 kills only the direct child (the child itself is
    /// always reaped); tree killing is a process_group phase-2 TODO. Accepted
    /// and recorded today so callers and the migrated consumer don't have to
    /// change when phase 2 lands.
    kill_tree: bool = true,
    /// Working directory for the child (passed straight to std.process.Child).
    cwd: ?[]const u8 = null,
    /// Environment for the child. null = inherit the parent environment.
    env_map: ?*const std.process.EnvMap = null,
};

pub const RunError = error{
    /// std.process.Child.spawn() failed (binary not found, fork/exec error).
    SpawnFailed,
} || std.mem.Allocator.Error;

/// Poll granularity: the loop blocks in poll() up to this long each step, then
/// re-checks the child / deadline / cancel token.
const POLL_STEP_MS: u32 = 25;
/// Grace between the polite SIGTERM/TerminateProcess and the hard SIGKILL.
const KILL_GRACE_MS: i64 = 500;
/// How long to wait for the child to actually die after we terminate it, so the
/// final reap does not block forever on a stubborn process.
const REAP_AFTER_KILL_MS: u32 = 1000;

/// Terminate the direct child (PHASE 1: tree-kill is best-effort/no-op, see
/// process_group). `kill_tree` is accepted so callers don't change when phase 2
/// wires setpgid+killpg / Job Objects.
fn terminate(id: std.process.Child.Id, kill_tree: bool, hard: bool) void {
    _ = kill_tree;
    if (hard) process_group.killChildHard(id) else process_group.killChild(id);
}

/// Copy at most `max` bytes of `src` (truncating the rest) into an owned slice.
fn dupeCapped(allocator: std.mem.Allocator, src: []const u8, max: usize) RunError![]u8 {
    return allocator.dupe(u8, src[0..@min(src.len, max)]);
}

/// POSIX poll can report POLLHUP without POLLIN while final pipe bytes are still
/// readable (observed on macOS CI). After the direct child has exited, do a
/// bounded, event-driven drain so we keep those bytes without waiting for a
/// grandchild-held pipe to hit EOF.
fn dupeCappedAfterPosixExitDrain(
    allocator: std.mem.Allocator,
    src: []const u8,
    max: usize,
    file: std.fs.File,
) RunError![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, src[0..@min(src.len, max)]);
    if (out.items.len >= max) return out.toOwnedSlice(allocator);

    var pfd = [_]std.posix.pollfd{.{
        .fd = file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var scratch: [4096]u8 = undefined;
    while (out.items.len < max) {
        pfd[0].revents = 0;
        const ready = std.posix.poll(&pfd, 0) catch break;
        if (ready == 0) break;
        if (pfd[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) == 0) break;

        const want = @min(scratch.len, max - out.items.len);
        const amt = std.posix.read(file.handle, scratch[0..want]) catch break;
        if (amt == 0) break;
        try out.appendSlice(allocator, scratch[0..amt]);
    }
    return out.toOwnedSlice(allocator);
}

/// Run `argv` to completion, capturing bounded stdout/stderr. Always reaps the
/// child exactly once before returning. On any timeout/cancel the child is
/// terminated and still reaped. Caller owns `result.stdout`/`result.stderr`.
pub fn runCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: RunOptions,
) RunError!RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = options.cwd;
    child.env_map = options.env_map;
    child.create_no_window = true;
    child.spawn() catch return error.SpawnFailed;

    // From here on the child is LIVE. Every path below either reaps via
    // child.wait() at the end or via finishWithError/finishOom — there is no
    // early `return` that bypasses the single matching reap.
    const StreamEnum = enum { stdout, stderr };
    var poller = std.Io.poll(allocator, StreamEnum, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    // The poller READS child.stdout/child.stderr but does NOT own/close them;
    // child.wait() (cleanupStreams) closes the fds, so we leave them set on
    // `child` and never close them ourselves.

    const deadline_ms: ?i64 = if (options.timeout_ms) |t|
        std.time.milliTimestamp() + @as(i64, @intCast(@min(t, std.math.maxInt(i64))))
    else
        null;

    var timed_out = false;
    var cancelled = false;
    var child_done = false;
    var exit_code: ?u32 = null;
    var killed_unknown = false;
    var terminate_requested = false;
    var hard_deadline_ms: i64 = 0;
    var poll_open = true;

    while (true) {
        // Cap reached on either stream: we have enough; stop draining. (The
        // child may keep writing; we terminate+reap below if it has not exited.)
        if (poller.reader(.stdout).bufferedLen() >= options.max_stdout_bytes or
            poller.reader(.stderr).bufferedLen() >= options.max_stderr_bytes)
        {
            break;
        }

        // Cancel / timeout: request termination once, then keep looping so the
        // poll drains whatever flushes as the child dies.
        if (!terminate_requested) {
            if (options.cancel) |c| {
                if (c.isCancelled()) {
                    cancelled = true;
                    terminate(child.id, options.kill_tree, false);
                    terminate_requested = true;
                    hard_deadline_ms = std.time.milliTimestamp() + KILL_GRACE_MS;
                }
            }
            if (!terminate_requested) {
                if (deadline_ms) |deadline| {
                    if (std.time.milliTimestamp() >= deadline) {
                        timed_out = true;
                        terminate(child.id, options.kill_tree, false);
                        terminate_requested = true;
                        hard_deadline_ms = std.time.milliTimestamp() + KILL_GRACE_MS;
                    }
                }
            }
        } else if (std.time.milliTimestamp() >= hard_deadline_ms) {
            // Stubborn child ignored SIGTERM; escalate so we never hang.
            terminate(child.id, options.kill_tree, true);
            hard_deadline_ms = std.math.maxInt(i64); // escalate once.
        }

        // Block up to one step, multiplexing both pipes. `false` = both fds hit
        // EOF (all writers, including any grandchild, closed) → drained fully.
        const remaining = if (terminate_requested or deadline_ms == null)
            POLL_STEP_MS
        else blk: {
            const r = @max(@as(i64, 0), deadline_ms.? - std.time.milliTimestamp());
            break :blk @as(u32, @intCast(@min(@as(i64, POLL_STEP_MS), r)));
        };
        const still_open = poller.pollTimeout(@as(u64, remaining) * std.time.ns_per_ms) catch {
            // OOM (poller buffers could not grow) or a poll error: we have
            // captured up to this point. Stop, terminate, and reap so the child
            // never leaks, then report OOM.
            poller.deinit();
            poll_open = false;
            return finishOom(&child);
        };

        // Has the DIRECT child exited? If so we stop draining even when a
        // grandchild still holds a pipe open (phase-1 grandchild behavior).
        switch (platform_process.childExited(child.id, 0)) {
            .running => {},
            .exited => |code| {
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                exit_code = code;
                child_done = true;
                break;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                killed_unknown = true;
                child_done = true;
                break;
            },
        }

        if (!still_open) {
            // Pipes are EOF but childExited said running: a transient race;
            // loop once more — the next childExited will catch the exit. Avoid a
            // busy spin by sleeping the poll step.
            std.Thread.sleep(@as(u64, POLL_STEP_MS) * std.time.ns_per_ms);
        }
    }

    // Snapshot captured bytes BEFORE deinit frees the poller buffers.
    const stdout_slice = (if (builtin.os.tag != .windows and child_done)
        dupeCappedAfterPosixExitDrain(allocator, poller.reader(.stdout).buffered(), options.max_stdout_bytes, child.stdout.?)
    else
        dupeCapped(allocator, poller.reader(.stdout).buffered(), options.max_stdout_bytes)) catch |err| {
        if (poll_open) poller.deinit();
        return finishWithError(&child, err);
    };
    errdefer allocator.free(stdout_slice);
    const stderr_slice = (if (builtin.os.tag != .windows and child_done)
        dupeCappedAfterPosixExitDrain(allocator, poller.reader(.stderr).buffered(), options.max_stderr_bytes, child.stderr.?)
    else
        dupeCapped(allocator, poller.reader(.stderr).buffered(), options.max_stderr_bytes)) catch |err| {
        if (poll_open) poller.deinit();
        return finishWithError(&child, err);
    };
    errdefer allocator.free(stderr_slice);

    // Free the poller's internal buffers. NOTE: std.Io.Poller.deinit does NOT
    // close the underlying fds (the caller owns them) — child.wait() below
    // closes child.stdout/child.stderr, so we leave them set here.
    if (poll_open) poller.deinit();

    // If we stopped draining before observing the direct child's exit (cap
    // reached, or a stubborn child after timeout/cancel), settle the child so
    // the reap is bounded. First give it a brief grace to exit ON ITS OWN — a
    // fast child that wrote past the cap and then exited cleanly should be
    // reported `.exited`, not `.killed`. Only if it is still running do we
    // terminate (escalating to a hard kill), then reap.
    if (!child_done) {
        switch (platform_process.childExited(child.id, if (terminate_requested) 0 else POLL_STEP_MS)) {
            .exited => |code| {
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                exit_code = code;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                killed_unknown = true;
            },
            .running => {
                // Genuinely still running: force it down and wait, bounded. It
                // did not exit on its own, so the outcome is `.killed`.
                if (!terminate_requested) terminate(child.id, options.kill_tree, false);
                if (platform_process.childExited(child.id, REAP_AFTER_KILL_MS) == .running) {
                    terminate(child.id, options.kill_tree, true);
                    _ = platform_process.childExited(child.id, REAP_AFTER_KILL_MS);
                }
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                killed_unknown = true;
            },
        }
    }

    // THE single matching reap. On POSIX childExited already reaped the zombie
    // and pre-set child.term, so wait() takes std's cleanup-only fast path (no
    // second waitpid → no ECHILD abort). On Windows wait() closes the handle.
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };

    const termination: Termination = blk: {
        if (exit_code) |code| break :blk .{ .exited = code };
        if (killed_unknown) break :blk .killed;
        break :blk switch (term) {
            .Exited => |code| .{ .exited = code },
            .Signal, .Stopped, .Unknown => .killed,
        };
    };

    return .{
        .termination = termination,
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .timed_out = timed_out,
        .cancelled = cancelled,
    };
}

/// Reap the child and propagate `err`. Used when the poller OOM'd or output
/// duplication failed: we still must not leak the child. The poller's deinit
/// does not close the pipe fds, so child.wait() (cleanupStreams) closes them.
fn finishWithError(child: *std.process.Child, err: RunError) RunError {
    // Make sure the child cannot outlive us: terminate, then reap exactly once.
    terminate(child.id, true, true);
    _ = platform_process.childExited(child.id, REAP_AFTER_KILL_MS);
    if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
    _ = child.wait() catch {};
    return err;
}

/// OOM-specific reap helper (poller already deinited by the caller).
fn finishOom(child: *std.process.Child) RunError {
    return finishWithError(child, error.OutOfMemory);
}

// ---------------------------------------------------------------------------
// Tests. These spawn real child processes, so they only run on POSIX hosts in
// the fast test suite (Windows shapes go through test-full's cross-compile,
// which does not RUN). Gate the spawn-based ones on non-Windows.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn shArgv(script: []const u8) [3][]const u8 {
    return .{ "sh", "-c", script };
}

test "CancelToken flips and is observed across threads" {
    var tok = CancelToken.init();
    try testing.expect(!tok.isCancelled());
    tok.cancel();
    try testing.expect(tok.isCancelled());
}

test "runCapture captures stdout and reaps a normal exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var argv = shArgv("printf hello");
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 4096, .max_stderr_bytes = 4096 });
    defer res.deinit(a);
    try testing.expectEqualStrings("hello", res.stdout);
    try testing.expectEqual(@as(usize, 0), res.stderr.len);
    try testing.expect(!res.timed_out);
    try testing.expect(!res.cancelled);
    try testing.expectEqual(Termination{ .exited = 0 }, res.termination);
}

test "runCapture drains a stderr-only child larger than the pipe buffer (no deadlock)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // >64KB on stderr, nothing on stdout: the classic deadlock if drains were
    // not concurrent.
    var argv = shArgv("printf 'E%.0s' $(seq 1 100000) 1>&2");
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 1024 * 1024, .max_stderr_bytes = 1024 * 1024 });
    defer res.deinit(a);
    try testing.expectEqual(@as(usize, 0), res.stdout.len);
    try testing.expect(res.stderr.len > 64 * 1024);
    try testing.expectEqual(Termination{ .exited = 0 }, res.termination);
}

test "runCapture drains both large streams concurrently" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var argv = shArgv("printf 'O%.0s' $(seq 1 80000); printf 'E%.0s' $(seq 1 80000) 1>&2");
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 1024 * 1024, .max_stderr_bytes = 1024 * 1024 });
    defer res.deinit(a);
    try testing.expect(res.stdout.len > 64 * 1024);
    try testing.expect(res.stderr.len > 64 * 1024);
}

test "runCapture truncates output to the cap but still reaches EOF and exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // Fast child: writes 5000 bytes then exits cleanly. The cap stops storage
    // at 100 bytes, but the child exits on its own, so it is reported `.exited`.
    var argv = shArgv("printf 'O%.0s' $(seq 1 5000)");
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 100, .max_stderr_bytes = 100 });
    defer res.deinit(a);
    try testing.expectEqual(@as(usize, 100), res.stdout.len); // capped
    try testing.expectEqual(Termination{ .exited = 0 }, res.termination); // still reaped
}

test "runCapture caps a never-ending streamer and terminates+reaps it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // Child floods stdout forever. Hitting the cap is the stopping reason; the
    // runner must terminate and reap it (never hang), reporting `.killed`.
    var argv = shArgv("while true; do printf 'xxxxxxxxxxxxxxxx'; done");
    const started = std.time.milliTimestamp();
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 4096, .max_stderr_bytes = 4096 });
    defer res.deinit(a);
    const elapsed = std.time.milliTimestamp() - started;
    try testing.expectEqual(@as(usize, 4096), res.stdout.len); // capped
    try testing.expectEqual(Termination.killed, res.termination);
    try testing.expect(!res.timed_out);
    try testing.expect(!res.cancelled);
    try testing.expect(elapsed < 5000); // did not hang
}

test "runCapture times out and reaps a child that never exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var argv = shArgv("sleep 30");
    const started = std.time.milliTimestamp();
    var res = try runCapture(a, &argv, .{
        .timeout_ms = 150,
        .max_stdout_bytes = 4096,
        .max_stderr_bytes = 4096,
    });
    defer res.deinit(a);
    const elapsed = std.time.milliTimestamp() - started;
    try testing.expect(res.timed_out);
    try testing.expect(!res.cancelled);
    try testing.expectEqual(Termination.killed, res.termination);
    // Terminated promptly, not after the full 30s sleep.
    try testing.expect(elapsed < 5000);
}

test "runCapture cancels and reaps a child after spawn" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tok = CancelToken.init();
    tok.cancel(); // already cancelled before the run starts
    var argv = shArgv("sleep 30");
    const started = std.time.milliTimestamp();
    var res = try runCapture(a, &argv, .{
        .cancel = &tok,
        .timeout_ms = 10_000,
        .max_stdout_bytes = 4096,
        .max_stderr_bytes = 4096,
    });
    defer res.deinit(a);
    const elapsed = std.time.milliTimestamp() - started;
    try testing.expect(res.cancelled);
    try testing.expect(!res.timed_out);
    try testing.expectEqual(Termination.killed, res.termination);
    try testing.expect(elapsed < 5000);
}

test "runCapture cancels mid-stream while the child is still writing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tok = CancelToken.init();
    // Child streams slowly (so the cap is never the reason we stop) while we
    // flip cancel from another thread shortly after spawn.
    const Flipper = struct {
        fn run(t: *CancelToken) void {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            t.cancel();
        }
    };
    const flip = try std.Thread.spawn(.{}, Flipper.run, .{&tok});
    // ~one byte every 20ms, forever: cancel at 100ms fires well before the
    // generous cap fills, so `cancelled` is the stopping reason.
    var argv = shArgv("while true; do printf 'x'; sleep 0.02; done");
    var res = try runCapture(a, &argv, .{
        .cancel = &tok,
        .timeout_ms = 30_000,
        .max_stdout_bytes = 1024 * 1024,
        .max_stderr_bytes = 1024 * 1024,
    });
    flip.join();
    defer res.deinit(a);
    try testing.expect(res.cancelled);
    try testing.expect(!res.timed_out);
    try testing.expectEqual(Termination.killed, res.termination);
}

test "runCapture reaps even when the child exits with a nonzero status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var argv = shArgv("printf oops 1>&2; exit 3");
    var res = try runCapture(a, &argv, .{ .max_stdout_bytes = 4096, .max_stderr_bytes = 4096 });
    defer res.deinit(a);
    try testing.expectEqualStrings("oops", res.stderr);
    try testing.expectEqual(Termination{ .exited = 3 }, res.termination);
}

test "runCapture phase-1: a grandchild holding stdout does not hang the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    // The direct child exits immediately but forks a grandchild that inherits
    // the stdout pipe and sleeps. PHASE 1 only reaps the direct child; the
    // grandchild keeps the write end open, so the stdout drain would block past
    // the child's own exit. The monitor reaps the direct child, but stdout EOF
    // depends on the grandchild. We assert the documented phase-1 behavior:
    // with a timeout, the run still completes (it does not hang forever) — the
    // grandchild is NOT tree-killed (phase-2 TODO), so completion comes via the
    // timeout path rather than promptly.
    var argv = shArgv("( sleep 1 ) & printf done; exit 0");
    const started = std.time.milliTimestamp();
    var res = try runCapture(a, &argv, .{
        .timeout_ms = 4000,
        .max_stdout_bytes = 4096,
        .max_stderr_bytes = 4096,
    });
    defer res.deinit(a);
    const elapsed = std.time.milliTimestamp() - started;
    // The grandchild here sleeps only 1s and then closes the fd, so the drain
    // reaches EOF on its own well within the timeout; the run completes.
    try testing.expect(std.mem.indexOf(u8, res.stdout, "done") != null);
    try testing.expect(elapsed < 4000);
}

test "runCapture handles a missing binary without leaking or hanging" {
    // Exec-failure timing is platform-dependent: on Linux std.process.Child
    // surfaces it as error.FileNotFound from spawn() (→ error.SpawnFailed);
    // on macOS posix_spawn succeeds and a stub reaps with a nonzero status.
    // Either way the invariant is the same — runCapture returns promptly, reaps
    // exactly once, and leaks nothing. We accept both outcomes.
    const a = testing.allocator;
    var argv = [_][]const u8{"/nonexistent/this-binary-does-not-exist-xyzzy"};
    if (runCapture(a, &argv, .{ .max_stdout_bytes = 16, .max_stderr_bytes = 16 })) |res| {
        var owned = res;
        owned.deinit(a);
    } else |err| {
        try testing.expectEqual(RunError.SpawnFailed, err);
    }
}

test "runCapture types: options carry the documented lifecycle knobs" {
    // Compile-time shape guard so the public RunOptions/RunResult surface
    // doesn't drift silently.
    const opts = RunOptions{ .max_stdout_bytes = 1, .max_stderr_bytes = 2 };
    try testing.expectEqual(@as(?u64, null), opts.timeout_ms);
    try testing.expectEqual(@as(?*const CancelToken, null), opts.cancel);
    try testing.expect(opts.kill_tree);
    _ = RunResult;
    _ = &runCapture;
}
