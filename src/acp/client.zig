//! ACP stdio client — a bidirectional JSON-RPC 2.0 connection over a child
//! agent's stdin/stdout. Outbound calls block on a per-call condition until the
//! agent answers or the connection dies; inbound requests and `session/update`
//! notifications are dispatched back through a `Handler`. Pure transport: it
//! parses envelopes and routes them, delegating `session/update` payload
//! decoding to sibling `schema.zig`. std-only on purpose so it stays
//! unit-testable with `zig test src/acp/client.zig`.
const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");

/// Callbacks invoked by the reader/inbound threads. `ctx` is opaque owner state.
pub const Handler = struct {
    ctx: *anyopaque,
    /// Called on the reader thread; the `update` is handed off to the callee,
    /// which must `update.deinit(allocator)` when done.
    onSessionUpdate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, update: schema.SessionUpdate) void,
    /// Called on a dedicated thread per inbound request. Returns owned JSON
    /// (the `result`) or any error → the client replies with a JSON-RPC error.
    onRequest: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8,
};

/// One outstanding outbound call. Reference counted between the caller (who
/// owns the returned pointer) and the connection (which holds the pending-map
/// entry); whichever drops last frees it.
pub const PendingCall = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    is_error: bool = false,
    /// Owned re-serialized `result` JSON; null on error/death.
    result_json: ?[]u8 = null,
    refcount: usize = 2,

    /// Deliver a completion (called once, by whoever removed the map entry).
    /// Takes ownership of `result`.
    fn complete(self: *PendingCall, result: ?[]u8, is_error: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.result_json = result;
        self.is_error = is_error;
        self.done = true;
        self.cond.signal();
    }

    /// Wait up to `timeout_ms` for completion; returns done-ness. Safe to call
    /// repeatedly (poll loop). Tolerates spurious wakeups.
    pub fn wait(self: *PendingCall, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.done) return true;
        const total = timeout_ms *| std.time.ns_per_ms;
        var timer = std.time.Timer.start() catch {
            self.cond.timedWait(&self.mutex, total) catch {};
            return self.done;
        };
        while (!self.done) {
            const elapsed = timer.read();
            if (elapsed >= total) break;
            self.cond.timedWait(&self.mutex, total - elapsed) catch break;
        }
        return self.done;
    }

    /// Take the result once done. Error response or connection death →
    /// `error.AcpCallFailed`. Returns a copy owned by `allocator`.
    pub fn take(self: *PendingCall, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.done or self.is_error) return error.AcpCallFailed;
        const src = self.result_json orelse return error.AcpCallFailed;
        return allocator.dupe(u8, src);
    }

    /// Drop this party's vote; frees at zero.
    pub fn release(self: *PendingCall) void {
        self.mutex.lock();
        self.refcount -= 1;
        const zero = self.refcount == 0;
        self.mutex.unlock();
        if (zero) {
            const allocator = self.allocator;
            if (self.result_json) |r| allocator.free(r);
            allocator.destroy(self);
        }
    }
};

const STDERR_TAIL_LIMIT: usize = 2048;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    handler: Handler,

    write_mutex: std.Thread.Mutex = .{},

    state_mutex: std.Thread.Mutex = .{},
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, *PendingCall) = .empty,
    dead: bool = false,
    closing: bool = false,

    reader_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    inbound_mutex: std.Thread.Mutex = .{},
    inbound_threads: std.ArrayListUnmanaged(std.Thread) = .empty,

    stderr_mutex: std.Thread.Mutex = .{},
    stderr_tail: std.ArrayListUnmanaged(u8) = .empty,

    /// Spawn `argv` with piped stdio and start the reader/stderr threads.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, handler: Handler) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .child = std.process.Child.init(argv, allocator),
            .handler = handler,
        };
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;
        self.child.cwd = cwd;
        self.child.create_no_window = true;

        try self.child.spawn();
        // posix_spawn() returns success even when the exec inside the forked
        // child fails (missing executable); the real error only surfaces via
        // waitForSpawn() draining the err_pipe. On that failure wait() re-throws
        // before cleanupStreams()/reaping, so close the pipe fds and reap the
        // exited fork child ourselves or both leak (see cli_agent.zig:230-239).
        self.child.waitForSpawn() catch |err| {
            if (self.child.stdin) |*f| f.close();
            if (self.child.stdout) |*f| f.close();
            if (self.child.stderr) |*f| f.close();
            if (builtin.os.tag != .windows) _ = std.posix.waitpid(self.child.id, 0);
            return err;
        };

        // Child is live; from here any failure must tear it down.
        errdefer {
            self.state_mutex.lock();
            self.closing = true;
            self.state_mutex.unlock();
            _ = self.child.kill() catch {};
            if (self.reader_thread) |t| t.join();
            if (self.stderr_thread) |t| t.join();
            self.stderr_tail.deinit(self.allocator);
        }
        self.stderr_thread = try std.Thread.spawn(.{}, stderrMain, .{self});
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        return self;
    }

    /// Kill the child, join every thread, then free all resources.
    pub fn deinit(self: *Connection) void {
        self.state_mutex.lock();
        self.closing = true;
        self.state_mutex.unlock();

        // Take stdin out under write_mutex before kill(): std.Child killPosix →
        // cleanupStreams close+NULLs child.stdin WITHOUT holding our lock, racing
        // any in-flight writeAll. Once nulled here, writeAll returns
        // AcpConnectionClosed and cleanupStreams skips the field (no double close).
        self.write_mutex.lock();
        if (self.child.stdin) |*f| {
            f.close();
            self.child.stdin = null;
        }
        self.write_mutex.unlock();

        // Killing the child EOFs the reader/stderr pipes so those threads exit.
        // ponytail: kill() is SIGTERM + blocking reap — a SIGTERM-ignoring child
        // hangs here; process-group SIGKILL escalation if real agents need it.
        _ = self.child.kill() catch {};
        if (self.reader_thread) |t| t.join();
        if (self.stderr_thread) |t| t.join();

        self.inbound_mutex.lock();
        for (self.inbound_threads.items) |t| t.join();
        self.inbound_mutex.unlock();
        self.inbound_threads.deinit(self.allocator);

        // Reader already failed+freed the pending map on EOF; this is a no-op
        // backstop for the (unreachable) case it didn't.
        self.failAllPending();
        self.pending.deinit(self.allocator);
        self.stderr_tail.deinit(self.allocator);

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn alive(self: *Connection) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return !self.dead;
    }

    /// Send a request and register a pending call. Blocks only on the write.
    pub fn beginCall(self: *Connection, method: []const u8, params_json: []const u8) !*PendingCall {
        const call = try self.allocator.create(PendingCall);
        call.* = .{ .allocator = self.allocator };

        self.state_mutex.lock();
        if (self.dead) {
            self.state_mutex.unlock();
            self.allocator.destroy(call);
            return error.AcpConnectionClosed;
        }
        const id = self.next_id;
        self.next_id += 1;
        self.pending.put(self.allocator, id, call) catch |err| {
            self.state_mutex.unlock();
            self.allocator.destroy(call);
            return err;
        };
        self.state_mutex.unlock();

        const line = std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ id, method, params_json },
        ) catch |err| {
            self.dropPending(id, call);
            return err;
        };
        defer self.allocator.free(line);
        self.writeAll(line) catch |err| {
            self.dropPending(id, call);
            return err;
        };
        return call;
    }

    /// Fire-and-forget notification (no id, no pending entry).
    pub fn notify(self: *Connection, method: []const u8, params_json: []const u8) !void {
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ method, params_json },
        );
        defer self.allocator.free(line);
        try self.writeAll(line);
    }

    /// Copy the bounded stderr tail (for surfacing in error messages).
    pub fn stderrTail(self: *Connection, allocator: std.mem.Allocator) ![]u8 {
        self.stderr_mutex.lock();
        defer self.stderr_mutex.unlock();
        return allocator.dupe(u8, self.stderr_tail.items);
    }

    // --- internals -----------------------------------------------------------

    fn writeAll(self: *Connection, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        const stdin = self.child.stdin orelse return error.AcpConnectionClosed;
        try stdin.writeAll(bytes);
    }

    /// Undo a pending registration whose request never made it out.
    fn dropPending(self: *Connection, id: i64, call: *PendingCall) void {
        self.state_mutex.lock();
        const present = self.pending.fetchRemove(id) != null;
        self.state_mutex.unlock();
        if (present) {
            // Never delivered to a response/death path → no other thread holds
            // `call`; free directly (result_json is still null).
            self.allocator.destroy(call);
        } else {
            // The death path already took it from the map and will complete +
            // release its vote; drop only the caller vote.
            call.release();
        }
    }

    fn respond(self: *Connection, id: i64, result_json: []const u8) !void {
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}\n",
            .{ id, result_json },
        );
        defer self.allocator.free(line);
        try self.writeAll(line);
    }

    fn respondError(self: *Connection, id: i64, code: i64, message: []const u8) !void {
        const msg_quoted = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .string = message }, .{});
        defer self.allocator.free(msg_quoted);
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":{s}}}}}\n",
            .{ id, code, msg_quoted },
        );
        defer self.allocator.free(line);
        try self.writeAll(line);
    }

    fn isClosing(self: *Connection) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.closing;
    }

    /// Mark dead and fail every outstanding call so blocked callers wake.
    fn failAllPending(self: *Connection) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        self.dead = true;
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const pc = entry.value_ptr.*;
            pc.complete(null, true);
            pc.release(); // map vote
        }
        self.pending.clearRetainingCapacity();
    }

    fn completeResponse(self: *Connection, id: i64, result_val: ?std.json.Value, is_error: bool) void {
        self.state_mutex.lock();
        const kv = self.pending.fetchRemove(id);
        self.state_mutex.unlock();
        const pc = (kv orelse return).value; // unknown id → ignore

        var result_dup: ?[]u8 = null;
        var err = is_error;
        if (!is_error) {
            if (result_val) |rv| {
                result_dup = std.json.Stringify.valueAlloc(self.allocator, rv, .{}) catch null;
                if (result_dup == null) err = true;
            }
        }
        pc.complete(result_dup, err);
        pc.release(); // map vote
    }

    fn dispatchNotification(self: *Connection, method: []const u8, params: ?std.json.Value) void {
        if (!std.mem.eql(u8, method, "session/update")) return; // others ignored
        const p = params orelse return;
        const update = schema.parseSessionUpdate(self.allocator, p) orelse return;
        // Handler owns `update` and will deinit it.
        self.handler.onSessionUpdate(self.handler.ctx, self.allocator, update);
    }

    fn spawnInbound(self: *Connection, raw_line: []const u8) void {
        const owned = self.allocator.dupe(u8, raw_line) catch return;
        const t = std.Thread.spawn(.{}, inboundMain, .{ self, owned }) catch {
            self.allocator.free(owned);
            return;
        };
        self.inbound_mutex.lock();
        defer self.inbound_mutex.unlock();
        self.inbound_threads.append(self.allocator, t) catch {
            // ponytail: OOM tracking the handle → detach so deinit's join set
            // stays consistent; a detached thread can outlive the Connection.
            // Single-agent scale makes this effectively unreachable.
            t.detach();
        };
    }

    /// Route one decoded JSON line. `line` is borrowed (valid for this call).
    fn handleLine(self: *Connection, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;

        const method_val = obj.get("method");
        const id_val = obj.get("id");
        if (method_val) |mv| {
            if (mv != .string) return;
            if (id_val != null) {
                // Inbound request: hand the raw line to a worker thread.
                if (jsonIntId(id_val.?) != null) self.spawnInbound(trimmed);
            } else {
                self.dispatchNotification(mv.string, obj.get("params"));
            }
            return;
        }

        // Response: id + result/error.
        const id = jsonIntId(id_val orelse return) orelse return;
        const has_result = obj.get("result") != null;
        const has_error = obj.get("error") != null;
        if (!has_result and !has_error) return;
        self.completeResponse(id, obj.get("result"), has_error);
    }

    fn readerMain(self: *Connection) void {
        const file = self.child.stdout.?;
        var buf: [4096]u8 = undefined;
        var partial: std.ArrayListUnmanaged(u8) = .empty;
        defer partial.deinit(self.allocator);
        while (true) {
            const n = file.read(&buf) catch break;
            if (n == 0) break;
            var rest: []const u8 = buf[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                if (partial.items.len == 0) {
                    self.handleLine(rest[0..nl]);
                } else {
                    partial.appendSlice(self.allocator, rest[0..nl]) catch {};
                    self.handleLine(partial.items);
                    partial.clearRetainingCapacity();
                }
                rest = rest[nl + 1 ..];
            }
            partial.appendSlice(self.allocator, rest) catch {};
        }
        if (partial.items.len != 0) self.handleLine(partial.items);
        self.failAllPending();
    }

    fn stderrMain(self: *Connection) void {
        const file = self.child.stderr.?;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch break;
            if (n == 0) break;
            self.appendStderr(buf[0..n]);
        }
    }

    fn appendStderr(self: *Connection, chunk: []const u8) void {
        self.stderr_mutex.lock();
        defer self.stderr_mutex.unlock();
        self.stderr_tail.appendSlice(self.allocator, chunk) catch return;
        if (self.stderr_tail.items.len > 2 * STDERR_TAIL_LIMIT) {
            const keep = STDERR_TAIL_LIMIT;
            std.mem.copyForwards(u8, self.stderr_tail.items[0..keep], self.stderr_tail.items[self.stderr_tail.items.len - keep ..]);
            self.stderr_tail.shrinkRetainingCapacity(keep);
        }
    }
};

// ponytail: one thread per inbound request keeps a blocking permission/exec
// handler from stalling the reader; single-agent scale needs no thread pool.
fn inboundMain(self: *Connection, line: []u8) void {
    defer self.allocator.free(line);
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const id = jsonIntId(obj.get("id") orelse return) orelse return;
    const method_val = obj.get("method") orelse return;
    if (method_val != .string) return;
    const params = obj.get("params") orelse std.json.Value{ .null = {} };

    if (self.isClosing()) return;
    const result = self.handler.onRequest(self.handler.ctx, self.allocator, method_val.string, params) catch |err| {
        if (self.isClosing()) return;
        self.respondError(id, -32603, @errorName(err)) catch {};
        return;
    };
    defer self.allocator.free(result);
    if (self.isClosing()) return;
    self.respond(id, result) catch {};
}

fn jsonIntId(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Whitespace-split a command string into an owned argv (no shell parsing).
/// Caller frees each element and the outer slice.
pub fn splitCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |tok| {
        try list.append(allocator, try allocator.dupe(u8, tok));
    }
    return list.toOwnedSlice(allocator);
}

// ===========================================================================
// Tests
// ===========================================================================

const TestHandler = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    last_method: ?[]u8 = null,
    last_update_text: ?[]u8 = null,
    got_update: bool = false,

    fn handler(self: *TestHandler) Handler {
        return .{ .ctx = self, .onSessionUpdate = onSessionUpdate, .onRequest = onRequest };
    }

    fn onSessionUpdate(ctx: *anyopaque, allocator: std.mem.Allocator, update_in: schema.SessionUpdate) void {
        var update = update_in;
        defer update.deinit(allocator);
        const self: *TestHandler = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (update) {
            .agent_message_chunk => |t| {
                if (self.last_update_text) |old| std.testing.allocator.free(old);
                self.last_update_text = std.testing.allocator.dupe(u8, t) catch null;
                self.got_update = true;
                self.cond.signal();
            },
            else => {},
        }
    }

    fn onRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8 {
        _ = params;
        const self: *TestHandler = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        if (self.last_method) |old| std.testing.allocator.free(old);
        self.last_method = std.testing.allocator.dupe(u8, method) catch null;
        self.mutex.unlock();
        return schema.encodePermissionSelected(allocator, "allow");
    }

    fn waitForUpdate(self: *TestHandler, timeout_ms: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.got_update) return true;
        self.cond.timedWait(&self.mutex, timeout_ms * std.time.ns_per_ms) catch {};
        return self.got_update;
    }

    fn deinit(self: *TestHandler) void {
        if (self.last_method) |m| std.testing.allocator.free(m);
        if (self.last_update_text) |t| std.testing.allocator.free(t);
    }
};

test "call round-trip against a scripted agent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}';;
        \\    *'"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}';;
        \\  esac
        \\done
    ;
    var recorder = TestHandler{};
    defer recorder.deinit();
    const conn = try Connection.spawn(a, &.{ "/bin/sh", "-c", script }, null, recorder.handler());
    defer conn.deinit();

    const p1 = try conn.beginCall("initialize", "{\"protocolVersion\":1}");
    defer p1.release();
    try std.testing.expect(p1.wait(5000));
    const r1 = try p1.take(a);
    defer a.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "protocolVersion") != null);

    const p2 = try conn.beginCall("session/new", "{\"cwd\":\"/tmp\"}");
    defer p2.release();
    try std.testing.expect(p2.wait(5000));
    const r2 = try p2.take(a);
    defer a.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "s1") != null);
}

test "inbound request is dispatched and response written back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // On a session/prompt: send an inbound request (id 100), read our reply back
    // (must carry the selected option), notify session/update, then answer the
    // prompt (id 1).
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}'
        \\      IFS= read -r reply
        \\      case "$reply" in *'"id":100'*'"selected"'*) : ;; *) exit 9 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}'
        \\      ;;
        \\  esac
        \\done
    ;
    var recorder = TestHandler{};
    defer recorder.deinit();
    const conn = try Connection.spawn(a, &.{ "/bin/sh", "-c", script }, null, recorder.handler());
    defer conn.deinit();

    const p = try conn.beginCall("session/prompt", "{\"sessionId\":\"s1\",\"prompt\":[]}");
    defer p.release();
    try std.testing.expect(p.wait(5000));
    const r = try p.take(a);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "end_turn") != null);

    try std.testing.expect(recorder.waitForUpdate(5000));
    recorder.mutex.lock();
    defer recorder.mutex.unlock();
    try std.testing.expectEqualStrings("ok", recorder.last_update_text.?);
    try std.testing.expectEqualStrings("session/request_permission", recorder.last_method.?);
}

test "agent death fails pending calls with stderr tail available" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // Read our request (so the write lands), spew to stderr, then die without
    // answering.
    const script = "IFS= read -r line; printf 'boom-stderr\\n' 1>&2; exit 3";
    var recorder = TestHandler{};
    defer recorder.deinit();
    const conn = try Connection.spawn(a, &.{ "/bin/sh", "-c", script }, null, recorder.handler());
    defer conn.deinit();

    const p = try conn.beginCall("initialize", "{\"protocolVersion\":1}");
    defer p.release();
    try std.testing.expect(p.wait(5000)); // completed via connection death
    try std.testing.expectError(error.AcpCallFailed, p.take(a));

    // stderr is captured asynchronously; poll until the reader thread drains it.
    var found = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const tail = try conn.stderrTail(a);
        defer a.free(tail);
        if (std.mem.indexOf(u8, tail, "boom-stderr") != null) {
            found = true;
            break;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(found);
}

test "splitCommand whitespace-splits without a shell" {
    const a = std.testing.allocator;
    const argv = try splitCommand(a, "  codex   acp --json  ");
    defer {
        for (argv) |item| a.free(item);
        a.free(argv);
    }
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("codex", argv[0]);
    try std.testing.expectEqualStrings("acp", argv[1]);
    try std.testing.expectEqualStrings("--json", argv[2]);
}
