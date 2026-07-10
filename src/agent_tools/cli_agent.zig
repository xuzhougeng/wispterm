//! Unified CLI agent delegation tool (`cli_agent`): hand one self-contained
//! task to an external CLI agent (first backend: Codex), stream its progress
//! into the chat card, and return its final report. Leaf module — depends on
//! ai_chat_types, platform process helpers, and sibling exec/output adapters;
//! never on session.zig or AppWindow.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");
const platform_process = @import("../platform/process.zig");
const agent_exec = @import("exec.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

pub const DEFAULT_TIMEOUT_MS: u32 = 600_000;
pub const MAX_TIMEOUT_MS: u32 = 3_600_000;

/// One parsed stdout line from a backend. Set fields are owned by the
/// caller-provided allocator; the caller frees them.
pub const Event = struct {
    progress: ?[]u8 = null,
    final: ?[]u8 = null,
};

pub const Backend = struct {
    key: []const u8, // value of the tool's `agent` argument
    display: []const u8,
    exe: []const u8, // executable name resolved via PATH
    base_args: []const []const u8, // fixed args between exe and task
    parseEvent: *const fn (allocator: std.mem.Allocator, line: []const u8) ?Event,
};

const codex_backend = Backend{
    .key = "codex",
    .display = "Codex",
    .exe = "codex",
    .base_args = &.{ "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--" },
    .parseEvent = codexParseEvent,
};

pub const backends = [_]Backend{codex_backend};

/// Comma-joined backend keys for error messages and docs; stays correct as
/// the table grows.
pub const available_keys = blk: {
    var s: []const u8 = "";
    for (backends, 0..) |b, i| s = s ++ (if (i == 0) "" else ", ") ++ b.key;
    break :blk s;
};

pub fn find(key: []const u8) ?*const Backend {
    for (&backends) |*backend| {
        if (std.mem.eql(u8, backend.key, key)) return backend;
    }
    return null;
}

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse one line of `codex exec --json` output. Tolerant by design: any
/// line that is not JSON or not a recognized event returns null; when no
/// agent_message is ever seen, run() falls back to the raw stdout tail, so
/// codex JSON-format drift degrades gracefully instead of failing.
fn codexParseEvent(allocator: std.mem.Allocator, line: []const u8) ?Event {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const event_type = objectString(parsed.value, "type") orelse return null;
    const item = parsed.value.object.get("item") orelse return null;
    // Real codex CLI (0.144.1+) puts the item's type under "type" inside the
    // item object; older experimental builds used "item_type". Try current
    // first, fall back to the legacy spelling.
    const item_type = objectString(item, "type") orelse objectString(item, "item_type") orelse return null;
    if (std.mem.eql(u8, event_type, "item.completed") and std.mem.eql(u8, item_type, "agent_message")) {
        const text = objectString(item, "text") orelse return null;
        const owned = allocator.dupe(u8, text) catch return null;
        return .{ .final = owned };
    }
    if (std.mem.eql(u8, event_type, "item.started") and std.mem.eql(u8, item_type, "command_execution")) {
        const command = objectString(item, "command") orelse return null;
        const owned = std.fmt.allocPrint(allocator, "codex: $ {s}", .{command}) catch return null;
        return .{ .progress = owned };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Line-streaming child runner
// ---------------------------------------------------------------------------

/// Reader-thread line collector. The thread only does I/O and line splitting;
/// parsed events and all session calls stay on the tool worker thread
/// (markUiDirty is threadlocal — cross-thread UI calls are a known trap).
const LineStream = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    partial: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *LineStream) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.partial.deinit(self.allocator);
    }

    fn readThread(self: *LineStream) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.file.read(&buf) catch break;
            if (n == 0) break;
            self.push(buf[0..n]);
        }
        self.flushPartial();
    }

    // ponytail: `partial` is unbounded for a single line with no newline;
    // codex event lines are bounded in practice — cap it if a backend ever
    // streams raw unbounded output.
    fn push(self: *LineStream, chunk: []const u8) void {
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = std.mem.concat(self.allocator, u8, &.{ self.partial.items, rest[0..nl] }) catch return;
            self.partial.clearRetainingCapacity();
            self.appendLine(line);
            rest = rest[nl + 1 ..];
        }
        self.partial.appendSlice(self.allocator, rest) catch {};
    }

    fn flushPartial(self: *LineStream) void {
        if (self.partial.items.len == 0) return;
        const line = self.allocator.dupe(u8, self.partial.items) catch return;
        self.partial.clearRetainingCapacity();
        self.appendLine(line);
    }

    fn appendLine(self: *LineStream, line: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.lines.append(self.allocator, line) catch self.allocator.free(line);
    }

    /// Move all pending lines to `out`; caller owns and frees each line.
    fn drain(self: *LineStream, out: *std.ArrayListUnmanaged([]u8)) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.appendSlice(self.allocator, self.lines.items) catch return;
        self.lines.clearRetainingCapacity();
    }
};

/// Keep a bounded raw-stdout tail for the no-final-message fallback (the
/// useful part of a stream is at the end).
fn appendTail(allocator: std.mem.Allocator, tail: *std.ArrayListUnmanaged(u8), line: []const u8, limit: u32) void {
    tail.appendSlice(allocator, line) catch return;
    tail.append(allocator, '\n') catch return;
    const max: usize = @max(@as(usize, limit), 1);
    if (tail.items.len > 2 * max) {
        // no overlap: only triggered when len > 2*max
        std.mem.copyForwards(u8, tail.items[0..max], tail.items[tail.items.len - max ..]);
        tail.shrinkRetainingCapacity(max);
    }
}

fn drainAndParse(ctx: *ToolContext, backend: *const Backend, stream: *LineStream, final_message: *?[]u8, tail: *std.ArrayListUnmanaged(u8)) void {
    const allocator = ctx.allocator;
    var drained: std.ArrayListUnmanaged([]u8) = .empty;
    defer drained.deinit(allocator);
    stream.drain(&drained);
    for (drained.items) |line| {
        defer allocator.free(line);
        appendTail(allocator, tail, line, ctx.settings.output_limit);
        const event = backend.parseEvent(allocator, line) orelse continue;
        if (event.progress) |p| {
            defer allocator.free(p);
            ctx.emitProgress(p);
        }
        if (event.final) |f| {
            if (final_message.*) |old| allocator.free(old);
            final_message.* = f;
        }
    }
}

pub fn run(ctx: *ToolContext, backend: *const Backend, task: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    const allocator = ctx.allocator;
    if (ctx.isCancelled()) return allocator.dupe(u8, "Canceled.");
    const trimmed_task = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed_task.len == 0) return allocator.dupe(u8, "Missing task");

    // The backend runs with full access and cannot prompt mid-run, so both
    // confirm AND auto permission modes gate the whole delegation up front.
    if (ctx.settings.permission != .full) {
        const reason = try std.fmt.allocPrint(allocator, "Delegate task to {s} with full access", .{backend.display});
        defer allocator.free(reason);
        if (!ctx.requestApproval("cli_agent", trimmed_task, reason)) {
            return tool_output.deniedResult(allocator, trimmed_task, "cli_agent delegation not approved");
        }
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, backend.exe);
    try argv.appendSlice(allocator, backend.base_args);
    try argv.append(allocator, trimmed_task);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    const effective_cwd = cwd orelse ctx.settings.working_dir;
    child.cwd = effective_cwd;
    child.create_no_window = true;
    child.spawn() catch |err| {
        return std.fmt.allocPrint(allocator, "{s} CLI ({s}) not found or failed to start: {} (cwd: {s})", .{ backend.display, backend.exe, err, effective_cwd orelse "." });
    };
    // posix_spawn() itself returns success even when the exec inside the
    // forked child fails (e.g. missing executable) — the real error only
    // surfaces via the err_pipe that waitForSpawn() drains. Must check this
    // BEFORE the poll loop below preemptively sets child.term (to dodge the
    // ECHILD-on-double-waitpid trap), because doing so would make wait()
    // skip waitForSpawn()'s pipe read and silently swallow the spawn error.
    child.waitForSpawn() catch |err| {
        // wait()'s `try waitForSpawn()` re-throws before reaching
        // cleanupStreams() or reaping the pid, so both the stdout/stderr
        // pipe fds and the exited fork child (it _exit(1)s after reporting)
        // would otherwise leak; clean up ourselves.
        if (child.stdout) |*f| f.close();
        if (child.stderr) |*f| f.close();
        if (builtin.os.tag != .windows) _ = platform_process.childExited(child.id, 1000);
        return std.fmt.allocPrint(allocator, "{s} CLI ({s}) not found or failed to start: {} (cwd: {s})", .{ backend.display, backend.exe, err, effective_cwd orelse "." });
    };

    var stream = LineStream{ .allocator = allocator, .file = child.stdout.? };
    defer stream.deinit();
    var stderr_capture = agent_exec.CaptureOutput{
        .allocator = allocator,
        .file = child.stderr.?,
        .max_bytes = ctx.settings.output_limit,
    };
    defer allocator.free(stderr_capture.data);

    const stdout_thread = try std.Thread.spawn(.{}, LineStream.readThread, .{&stream});
    const stderr_thread = try std.Thread.spawn(.{}, agent_exec.captureOutputThread, .{&stderr_capture});

    var final_message: ?[]u8 = null;
    defer if (final_message) |f| allocator.free(f);
    var tail: std.ArrayListUnmanaged(u8) = .empty;
    defer tail.deinit(allocator);

    const wait_ms = @max(@min(timeout_ms, MAX_TIMEOUT_MS), 1);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    var timed_out = false;
    var canceled = false;
    while (true) {
        drainAndParse(ctx, backend, &stream, &final_message, &tail);
        switch (platform_process.childExited(child.id, 25)) {
            .running => {},
            .exited => |code| {
                // Same trap as exec.runArgv: on POSIX childExited() already
                // reaped the zombie; pre-set term so child.wait() skips its
                // second waitpid (ECHILD aborts). Windows keeps the handle.
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                break;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                break;
            },
        }
        if (ctx.isCancelled()) {
            canceled = true;
            // ponytail: kill() is SIGTERM + blocking wait — a SIGTERM-ignoring
            // child hangs here and grandchildren orphan; process-group +
            // SIGKILL escalation if real codex runs hit it. Same ceiling as
            // exec.runArgv, deliberate.
            _ = child.kill() catch {};
            break;
        }
        if (std.time.milliTimestamp() >= deadline) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
    }

    stdout_thread.join();
    stderr_thread.join();
    // Lines that arrived between the last in-loop drain and thread exit.
    drainAndParse(ctx, backend, &stream, &final_message, &tail);

    const exit_code: i32 = if (timed_out or canceled) 124 else blk: {
        const term = try child.wait();
        break :blk switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| @intCast(code),
        };
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (timed_out) try out.appendSlice(allocator, "timed_out=true\n");
    if (canceled) try out.appendSlice(allocator, "canceled=true\n");
    try out.print(allocator, "agent={s} exit_code={d}\n", .{ backend.key, exit_code });
    if (final_message) |f| {
        try out.appendSlice(allocator, f);
    } else {
        try out.appendSlice(allocator, "No final message parsed; raw output tail:\n");
        // appendTail lets `tail` grow to 2x output_limit before compressing;
        // truncateOwned below keeps the FIRST output_limit bytes, which would
        // cut off the very end of the stream the fallback exists to preserve.
        // Budget the tail to half the limit so header+marker+tail survives
        // keep-head truncation, leaving room for stderr too.
        const tail_budget = @max(ctx.settings.output_limit / 2, 1);
        const tail_slice = tail.items[tail.items.len -| tail_budget..];
        try out.appendSlice(allocator, tail_slice);
    }
    if (exit_code != 0 and stderr_capture.data.len > 0) {
        try out.print(allocator, "\nstderr:\n{s}", .{stderr_capture.data});
    }
    return tool_output.truncateOwned(allocator, ctx.settings, try out.toOwnedSlice(allocator));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "find resolves codex and rejects unknown keys" {
    const backend = find("codex") orelse return error.TestExpectedBackend;
    try std.testing.expectEqualStrings("codex", backend.exe);
    try std.testing.expect(find("oh-my-pi") == null);
    try std.testing.expectEqualStrings("codex", available_keys);
}

test "codexParseEvent extracts progress from item.started command_execution" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.started\",\"item\":{\"id\":\"item_0\",\"type\":\"command_execution\",\"command\":\"/bin/zsh -lc 'ls'\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.final == null);
    try std.testing.expectEqualStrings("codex: $ /bin/zsh -lc 'ls'", event.progress.?);
}

test "codexParseEvent extracts final from item.completed agent_message" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"agent_message\",\"text\":\"All tests pass.\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.progress == null);
    try std.testing.expectEqualStrings("All tests pass.", event.final.?);
}

test "codexParseEvent falls back to legacy item_type field for older codex builds" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_9\",\"item_type\":\"agent_message\",\"text\":\"legacy format still works\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.progress == null);
    try std.testing.expectEqualStrings("legacy format still works", event.final.?);
}

test "codexParseEvent ignores unknown events, other item phases, and non-JSON lines" {
    const a = std.testing.allocator;
    try std.testing.expect(codexParseEvent(a, "[2026-07-10] plain human output") == null);
    try std.testing.expect(codexParseEvent(a, "") == null);
    try std.testing.expect(codexParseEvent(a, "{not json") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"thread.started\",\"thread_id\":\"t1\"}") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"hmm\"}}") == null);
    // command_execution progress only fires on item.started, not completed (no dupes)
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"command_execution\",\"command\":\"ls\",\"aggregated_output\":\"\",\"exit_code\":0,\"status\":\"completed\"}}") == null);
    // agent_message only counts when completed
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.started\",\"item\":{\"type\":\"agent_message\",\"text\":\"partial\"}}") == null);
}

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeDeny(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    const called: *bool = @ptrCast(@alignCast(ctx));
    called.* = true;
    return false;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const ProgressCapture = struct {
    count: usize = 0,
    last: [256]u8 = undefined,
    last_len: usize = 0,

    fn hook(ctx: *anyopaque, text: []const u8) void {
        const self: *ProgressCapture = @ptrCast(@alignCast(ctx));
        self.count += 1;
        const n = @min(text.len, self.last.len);
        @memcpy(self.last[0..n], text[0..n]);
        self.last_len = n;
    }
};

test "run streams progress and returns the final agent message" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const script =
        "printf '%s\\n' " ++
        "'{\"type\":\"item.started\",\"item\":{\"id\":\"item_0\",\"type\":\"command_execution\",\"command\":\"ls\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}' " ++
        "'{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"agent_message\",\"text\":\"first\"}}' " ++
        "'{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"all done\"}}'";
    const args = [_][]const u8{ "-c", script };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var progress = ProgressCapture{};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &progress,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .progress = ProgressCapture.hook,
    };
    const out = try run(&ctx, &fake, "do the thing", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "agent=fake") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit_code=0") != null);
    // last agent_message wins
    try std.testing.expect(std.mem.indexOf(u8, out, "all done") != null);
    try std.testing.expectEqual(@as(usize, 1), progress.count);
    try std.testing.expectEqualStrings("codex: $ ls", progress.last[0..progress.last_len]);
}

test "run falls back to the raw stdout tail when no final message parses" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "printf '%s\\n' 'plain line one' 'plain line two'" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No final message parsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "plain line two") != null);
}

test "run fallback tail keeps the most recent output under a small output_limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const script = "for i in $(seq 1 40); do echo \"noise line $i padding padding padding\"; done; echo \"LAST_LINE_MARKER\"";
    const args = [_][]const u8{ "-c", script };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .output_limit = 256 },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No final message parsed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "LAST_LINE_MARKER") != null);
}

test "run requires approval outside full permission and reports denial" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "true" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var approve_called = false;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &approve_called,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .auto },
        .approve = fakeDeny,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "risky task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(approve_called);
    try std.testing.expect(std.mem.indexOf(u8, out, "DENIED") != null);
}

test "run reports a missing executable clearly" {
    const a = std.testing.allocator;
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "definitely-missing-cli-agent-binary",
        .base_args = &.{},
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 30_000);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "not found or failed to start") != null);
}

test "run kills the child on timeout and marks the result" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    const args = [_][]const u8{ "-c", "sleep 30" };
    const fake = Backend{
        .key = "fake",
        .display = "Fake",
        .exe = "/bin/sh",
        .base_args = args[0..],
        .parseEvent = codexParseEvent,
    };
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try run(&ctx, &fake, "task", null, 100);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "timed_out=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit_code=124") != null);
}
