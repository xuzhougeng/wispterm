//! ACP external-agent turn driver. Bridges the stdio JSON-RPC client
//! (`acp/client.zig` + `acp/schema.zig`) to the AI-chat session write-backs so
//! an ACP profile actually converses: it spawns the agent once per session,
//! runs `initialize`/`session/new`, then drives one `session/prompt` per user
//! turn — streaming `agent_message_chunk` text into the transcript, surfacing
//! tool calls as progress cards, and round-tripping `session/request_permission`
//! through the session's blocking `askUser`.
//!
//! Threading: the connection's reader thread calls `onSessionUpdate` and each
//! inbound request runs on its own thread calling `onRequest`. Both mutate the
//! transcript ONLY through the `session.mutex`-guarded `ai_chat` write-backs
//! (same contract `request.zig` follows). `AcpState.state_mutex` guards the
//! per-turn `stream_idx` hand-off between the reader thread and the turn thread.
const std = @import("std");
const builtin = @import("builtin");
const ai_chat = @import("session.zig");
const proto = @import("protocol.zig");
const types = @import("types.zig");
const terminal_lease = @import("../../agent/terminal_lease.zig");
const agent_history = @import("../../agent/history.zig");
const acp_client = @import("../../acp/client.zig");
const schema = @import("../../acp/schema.zig");

const Session = ai_chat.Session;
const ChatRequest = ai_chat.ChatRequest;
const ToolHost = types.ToolHost;

/// Default `terminal/output` tail cap when the agent gives no `outputByteLimit`.
const DEFAULT_TERMINAL_OUTPUT_LIMIT: usize = 32 * 1024;
/// Upper bound so a hostile/buggy `outputByteLimit` can't request unbounded copies.
const MAX_TERMINAL_OUTPUT_LIMIT: usize = 1024 * 1024;
/// `terminal/wait_for_exit` poll granularity (also the max teardown-observe lag).
const TERMINAL_WAIT_POLL_MS: u64 = 150;

/// Bounded wait for the `initialize` / `session/new` handshake replies.
const HANDSHAKE_TIMEOUT_MS: u64 = 20_000;
/// Poll granularity while blocked on the `session/prompt` reply (so the stop
/// button can inject a `session/cancel` within ~100ms).
const PROMPT_POLL_MS: u64 = 100;

/// Live ACP connection + per-turn stream state, owned by the Session. Created on
/// the first ACP turn and reused across turns; torn down on connection death or
/// `Session.deinit`. `state_mutex` guards `stream_idx` only.
pub const AcpState = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    conn: *acp_client.Connection,
    acp_session_id: []u8,
    stream_idx: ?usize,
    state_mutex: std.Thread.Mutex = .{},
    /// Serializes concurrent `session/request_permission` handlers: Session.askUser
    /// is a single-slot Q&A (a second concurrent question would overwrite the
    /// first's payload and one resolve could wake both askers, cross-wiring the
    /// answers). ACP agents ask permissions serially in practice; defensive.
    permission_mutex: std.Thread.Mutex = .{},

    /// ACP `terminal/*` state: panes this session's agent created, plus the live
    /// `ToolHost` the handlers reach the app through. Guarded by `terminals_mutex`
    /// (host refreshed once per turn; handlers run on per-request inbound threads).
    terminals: std.ArrayListUnmanaged(Terminal) = .empty,
    terminals_mutex: std.Thread.Mutex = .{},
    tool_host: ?ToolHost = null,
    /// One-shot latch so the "env ignored" progress note posts at most once.
    env_note_posted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Terminal = struct {
        id: []u8, // owned copy of the surface id (== ACP terminalId)
        ptr: *anyopaque, // live Surface, borrowed from the host
        output_byte_limit: usize,
    };

    /// Kill the child + join every client thread (so no more handler callbacks
    /// reference this struct), then free. `conn.deinit()` MUST run first — it
    /// joins the inbound threads that touch `terminals`.
    pub fn deinit(self: *AcpState) void {
        self.conn.deinit();
        for (self.terminals.items) |t| self.allocator.free(t.id);
        self.terminals.deinit(self.allocator);
        if (self.acp_session_id.len > 0) self.allocator.free(self.acp_session_id);
        self.allocator.destroy(self);
    }

    fn setToolHost(self: *AcpState, host: ?ToolHost) void {
        self.terminals_mutex.lock();
        defer self.terminals_mutex.unlock();
        self.tool_host = host;
    }

    fn getToolHost(self: *AcpState) ?ToolHost {
        self.terminals_mutex.lock();
        defer self.terminals_mutex.unlock();
        return self.tool_host;
    }

    fn addTerminal(self: *AcpState, id: []const u8, ptr: *anyopaque, limit: usize) !void {
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        self.terminals_mutex.lock();
        defer self.terminals_mutex.unlock();
        try self.terminals.append(self.allocator, .{ .id = id_owned, .ptr = ptr, .output_byte_limit = limit });
    }

    fn findTerminal(self: *AcpState, id: []const u8) ?Terminal {
        self.terminals_mutex.lock();
        defer self.terminals_mutex.unlock();
        for (self.terminals.items) |t| {
            if (std.mem.eql(u8, t.id, id)) return t;
        }
        return null;
    }

    fn removeTerminal(self: *AcpState, id: []const u8) void {
        self.terminals_mutex.lock();
        defer self.terminals_mutex.unlock();
        var i: usize = 0;
        while (i < self.terminals.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.terminals.items[i].id, id)) {
                const t = self.terminals.swapRemove(i);
                self.allocator.free(t.id);
                return;
            }
        }
    }

    fn takeStreamIdx(self: *AcpState) ?usize {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const idx = self.stream_idx;
        self.stream_idx = null;
        return idx;
    }

    fn peekStreamIdx(self: *AcpState) ?usize {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.stream_idx;
    }
};

/// Worker-thread entry point for one ACP turn. Owns `request` and frees it.
pub fn acpTurnThreadMain(request: *ChatRequest) void {
    defer request.deinit();
    const session = request.session;
    defer ai_chat.maybeAutoTitle(session);

    // Sessions restored from history records written before acp_command was
    // persisted carry an empty command. Fail with actionable guidance instead
    // of a spawn crash.
    if (request.acp_command.len == 0) {
        ai_chat.failAssistantStream(session, null, "此 ACP 会话缺少启动命令（通常来自历史记录恢复）。请通过模型切换器（/model 或点击模型名）重新选择 ACP 配置后再继续。");
        return;
    }

    const prompt_text = lastUserText(request.messages) orelse {
        ai_chat.failAssistantStream(session, null, "No user message to send.");
        return;
    };

    // ensureState leaves session.acp_state null on any failure (its own errdefer
    // tears the partial connection down after capturing the stderr tail here),
    // so there is nothing to tear down in this catch.
    var spawn_stderr: ?[]u8 = null;
    defer if (spawn_stderr) |s| request.allocator.free(s);
    const state = ensureState(session, request, &spawn_stderr) catch |err| {
        failTurn(session, "ACP agent 启动失败", err, spawn_stderr, null);
        return;
    };

    // Fresh turn on a reused connection: clear any stale stream from a prior
    // cancelled turn so the first chunk opens a new bubble.
    _ = state.takeStreamIdx();

    // Point the terminal/* handlers at this turn's live host before the agent
    // can call them (it only can after receiving the prompt sent just below).
    state.setToolHost(request.tool_host);

    const params = schema.encodePromptParams(request.allocator, state.acp_session_id, prompt_text) catch return;
    defer request.allocator.free(params);
    const pending = state.conn.beginCall("session/prompt", params) catch |err| {
        failTurnFromState(session, "ACP prompt 发送失败", err, state);
        unblockPermissionAskers(session);
        teardownState(session);
        return;
    };
    defer pending.release();

    var cancel_sent = false;
    while (!pending.wait(PROMPT_POLL_MS)) {
        // Session teardown: abandon the wait so Session.deinit's request_thread
        // join proceeds to tear the connection down (which fails this pending
        // call). Do NOT wait for a graceful stopReason a closing session ignores.
        if (session.closing.load(.acquire)) return;
        if (ai_chat.requestCancelled(request) and !cancel_sent) {
            cancel_sent = true;
            const cp = schema.encodeCancelParams(request.allocator, state.acp_session_id) catch continue;
            defer request.allocator.free(cp);
            state.conn.notify("session/cancel", cp) catch {};
        }
    }

    const result_json = pending.take(request.allocator) catch |err| {
        // Connection died mid-turn: surface stderr, drop the dead state so the
        // NEXT user message restarts the agent (context reset). Unblock MUST
        // come after failTurn (failAssistantStream treats a set stop_requested
        // as a user stop) and before teardownState (whose inbound-thread join
        // waits on any blocked permission askUser).
        failTurnFromState(session, "ACP agent 异常退出（下一条消息将重启并重置上下文）", err, state);
        unblockPermissionAskers(session);
        teardownState(session);
        return;
    };
    defer request.allocator.free(result_json);

    if (cancel_sent) {
        ai_chat.finishStoppedRequest(session);
        return;
    }
    finalizeTurn(session, state, request.started_ms);
}

/// Scan a request's messages tail-first for the last user turn's text.
fn lastUserText(messages: []const proto.RequestMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}

/// Spawn + handshake the agent on first use; reuse a live connection after.
/// On a post-spawn failure, `spawn_stderr` receives the agent's stderr tail
/// (owned by `request.allocator`) so the chat error can show WHY it crashed.
fn ensureState(session: *Session, request: *ChatRequest, spawn_stderr: *?[]u8) !*AcpState {
    if (session.acp_state) |st| {
        if (st.conn.alive()) return st;
        teardownState(session); // dead connection → rebuild below
    }
    const a = request.allocator;

    const argv = try acp_client.splitCommand(a, request.acp_command);
    defer {
        for (argv) |item| a.free(item);
        a.free(argv);
    }
    if (argv.len == 0) return error.AcpCommandMissing;

    const cwd = try resolveCwdAlloc(a, session);
    defer a.free(cwd);

    const st = try a.create(AcpState);
    errdefer a.destroy(st);
    st.* = .{ .allocator = a, .session = session, .conn = undefined, .acp_session_id = &.{}, .stream_idx = null };

    const conn = try acp_client.Connection.spawn(a, argv, cwd, .{
        .ctx = st,
        .onSessionUpdate = onSessionUpdate,
        .onRequest = onRequest,
    });
    st.conn = conn;
    errdefer {
        // Capture stderr for the error message (e.g. node's "module not found")
        // before deinit frees it. Best effort: the stderr thread may not have
        // fully drained yet — a truncated tail beats an error name alone.
        if (conn.stderrTail(a)) |t| {
            if (t.len > 0) spawn_stderr.* = t else a.free(t);
        } else |_| {}
        conn.deinit();
    }

    {
        // ponytail: Windows command assembly is unescaped; keep the capability off there until it is.
        const params = try schema.encodeInitializeParams(a, builtin.os.tag != .windows); // terminal/* handled by onRequest
        defer a.free(params);
        var parsed = try callResult(a, conn, "initialize", params);
        defer parsed.deinit();
        const version = schema.parseInitializeProtocolVersion(parsed.value) orelse return error.AcpInitializeFailed;
        if (version != schema.PROTOCOL_VERSION) return error.AcpProtocolVersionMismatch;
    }
    {
        const params = try schema.encodeNewSessionParams(a, cwd);
        defer a.free(params);
        var parsed = try callResult(a, conn, "session/new", params);
        defer parsed.deinit();
        st.acp_session_id = schema.parseNewSessionId(a, parsed.value) orelse return error.AcpNewSessionFailed;
    }

    // Single-owner publish: only the turn thread writes session.acp_state, and
    // Session.deinit reads it after joining the turn thread. No lock needed.
    session.acp_state = st;
    return st;
}

/// Blocking request → owned + parsed `result` JSON. Caller `.deinit()`s the Parsed.
fn callResult(a: std.mem.Allocator, conn: *acp_client.Connection, method: []const u8, params: []const u8) !std.json.Parsed(std.json.Value) {
    const pending = try conn.beginCall(method, params);
    defer pending.release();
    if (!pending.wait(HANDSHAKE_TIMEOUT_MS)) return error.AcpCallTimeout;
    const json = try pending.take(a);
    defer a.free(json);
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

/// The working dir the tool layer would use, made absolute. Falls back through
/// session override → global default → process cwd.
fn resolveCwdAlloc(a: std.mem.Allocator, session: *Session) ![]u8 {
    if (session.workingDirOverride()) |w| {
        if (std.fs.cwd().realpathAlloc(a, w)) |abs| return abs else |_| {}
    }
    if (ai_chat.defaultWorkingDir()) |w| {
        if (std.fs.cwd().realpathAlloc(a, w)) |abs| return abs else |_| {}
    }
    return std.process.getCwdAlloc(a);
}

/// Agent-death path: make every permission `askUser` on the dead connection —
/// already blocked OR not yet started — return `.cancelled`, so the connection
/// teardown's inbound-thread join cannot hang (which would wedge this turn
/// thread and, via the next submit's request_thread join, the UI thread).
///
/// `stop_requested` is left set: askUser checks it at entry (late askers) and in
/// its wait predicate (blocked askers); the next submit resets it. Unlike
/// `stopRequest`, this never self-resets, so both orderings are covered:
/// - asker blocked first → the broadcast (taken under question_mutex, after the
///   store) wakes it; the predicate sees the flag → `.cancelled`.
/// - asker arrives after → entry check / predicate sees the flag before any
///   wait; the mutex-held broadcast makes flag-then-wait interleavings safe.
fn unblockPermissionAskers(session: *Session) void {
    session.stop_requested.store(true, .release);
    session.question_mutex.lock();
    session.question_cond.broadcast();
    session.question_mutex.unlock();
}

/// Drop and free the session's ACP connection. `AcpState.deinit` kills the child
/// and joins the client threads. Safe no-op when no state is stored. Does NOT
/// touch request state, so it is safe to call mid-turn (dead-connection rebuild).
fn teardownState(session: *Session) void {
    const st = session.acp_state orelse return;
    session.acp_state = null;
    st.deinit();
}

/// Finish the turn on the standard path so request_inflight / the status line
/// clear even for a pure-tool turn that streamed no text.
fn finalizeTurn(session: *Session, state: *AcpState, started_ms: i64) void {
    if (state.takeStreamIdx()) |idx| {
        ai_chat.finishAssistantStream(session, idx, started_ms, 0, null);
    } else {
        ai_chat.appendAssistantResult(session, .{ .content = @constCast("") }, started_ms);
    }
}

/// `failAssistantStream` with a formatted reason + optional agent stderr tail.
fn failTurn(session: *Session, prefix: []const u8, err: anyerror, tail: ?[]const u8, stream_idx: ?usize) void {
    const a = session.allocator;
    const trimmed = std.mem.trim(u8, tail orelse "", " \t\r\n");
    const text = if (trimmed.len > 0)
        std.fmt.allocPrint(a, "{s}: {s}\n--- agent stderr ---\n{s}", .{ prefix, @errorName(err), trimmed }) catch return
    else
        std.fmt.allocPrint(a, "{s}: {s}", .{ prefix, @errorName(err) }) catch return;
    defer a.free(text);
    ai_chat.failAssistantStream(session, stream_idx, text);
}

/// `failTurn` against a live connection: grabs its stderr tail + open stream idx.
fn failTurnFromState(session: *Session, prefix: []const u8, err: anyerror, state: *AcpState) void {
    const tail = state.conn.stderrTail(session.allocator) catch null;
    defer if (tail) |t| session.allocator.free(t);
    failTurn(session, prefix, err, tail, state.peekStreamIdx());
}

// ---------------------------------------------------------------------------
// Handler callbacks (client reader / inbound threads → session write-backs)
// ---------------------------------------------------------------------------

fn onSessionUpdate(ctx: *anyopaque, allocator: std.mem.Allocator, update: schema.SessionUpdate) void {
    const state: *AcpState = @ptrCast(@alignCast(ctx));
    var u = update;
    defer u.deinit(allocator);
    switch (u) {
        .agent_message_chunk => |text| appendDelta(state, text, ""),
        .agent_thought_chunk => |text| appendDelta(state, "", text),
        .tool_call => |info| {
            closeStream(state);
            progressCard(state.session, info);
        },
        .tool_call_update => |info| if (isFailed(info.status)) progressFail(state.session, info),
        .plan => |text| ai_chat.appendProgressMessage(state.session, text) catch {},
        .ignored => {},
    }
}

/// Append streamed content/reasoning, opening the assistant bubble on first use.
/// Runs only on the (single) reader thread, so the open-once check is race-free;
/// state_mutex is held only for the stream_idx hand-off to the turn thread.
fn appendDelta(state: *AcpState, content: []const u8, reasoning: []const u8) void {
    state.state_mutex.lock();
    if (state.stream_idx == null) {
        state.stream_idx = ai_chat.beginAssistantStream(state.session) catch {
            state.state_mutex.unlock();
            return;
        };
    }
    const idx = state.stream_idx.?;
    state.state_mutex.unlock();
    ai_chat.appendAssistantStreamDelta(state.session, idx, content, reasoning) catch {};
}

/// Seal the current assistant bubble so a following tool card / new text starts
/// a fresh message. Leaves earlier bubbles rendered as-is (no usage footer).
fn closeStream(state: *AcpState) void {
    state.state_mutex.lock();
    defer state.state_mutex.unlock();
    state.stream_idx = null;
}

fn progressCard(session: *Session, info: schema.ToolCallInfo) void {
    const text = progressCardText(session.allocator, info) catch return;
    defer session.allocator.free(text);
    ai_chat.appendProgressMessage(session, text) catch {};
}

fn progressFail(session: *Session, info: schema.ToolCallInfo) void {
    const text = std.fmt.allocPrint(session.allocator, "[{s}] {s} 失败", .{ kindText(info.kind), titleText(info.title) }) catch return;
    defer session.allocator.free(text);
    ai_chat.appendProgressMessage(session, text) catch {};
}

fn isFailed(status: []const u8) bool {
    return std.mem.eql(u8, status, "failed");
}

fn kindText(kind: []const u8) []const u8 {
    return if (kind.len > 0) kind else "tool";
}

fn titleText(title: []const u8) []const u8 {
    return if (title.len > 0) title else "(untitled)";
}

/// Progress-card label for a tool call. Terminal-backed calls point the user at
/// the terminal tab that PR3 will attach; everything else is `[kind] title`.
fn progressCardText(allocator: std.mem.Allocator, info: schema.ToolCallInfo) ![]u8 {
    if (info.terminal_id.len > 0) {
        return std.fmt.allocPrint(allocator, "[terminal] {s} → 已在终端标签运行", .{titleText(info.title)});
    }
    return std.fmt.allocPrint(allocator, "[{s}] {s}", .{ kindText(info.kind), titleText(info.title) });
}

fn onRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8 {
    const state: *AcpState = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, method, "session/request_permission")) {
        state.permission_mutex.lock();
        defer state.permission_mutex.unlock();
        var req = try schema.parsePermissionRequest(allocator, params);
        defer req.deinit(allocator);
        var options: [8]ai_chat.QuestionOption = undefined; // ACP option lists are small (≤4 observed)
        const n = @min(req.options.len, options.len);
        if (n == 0) return schema.encodePermissionCancelled(allocator); // nothing to select
        for (req.options[0..n], 0..) |opt, i| options[i] = .{ .label = opt.name, .description = opt.kind };
        const answer = state.session.askUser(req.title, options[0..n]);
        return switch (answer) {
            .option_index => |i| schema.encodePermissionSelected(allocator, req.options[@min(i, n - 1)].id),
            .custom, .cancelled => schema.encodePermissionCancelled(allocator),
        };
    }
    if (std.mem.eql(u8, method, "terminal/create")) return terminalCreate(state, allocator, params);
    if (std.mem.eql(u8, method, "terminal/output")) return terminalOutput(state, allocator, params);
    if (std.mem.eql(u8, method, "terminal/wait_for_exit")) return terminalWaitForExit(state, allocator, params);
    if (std.mem.eql(u8, method, "terminal/kill")) return terminalKill(state, allocator, params);
    if (std.mem.eql(u8, method, "terminal/release")) return terminalRelease(state, allocator, params);
    return error.MethodNotFound;
}

// ---------------------------------------------------------------------------
// terminal/* handlers. Each runs on its own inbound thread, so blocking in
// wait_for_exit is fine. Any error propagates to a JSON-RPC error reply
// (unknown terminal, closed pane, missing host, …). Results are owned JSON.
// ---------------------------------------------------------------------------

fn terminalCreate(state: *AcpState, allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    var create = try schema.parseTerminalCreate(allocator, params);
    defer create.deinit(allocator);

    const host = state.getToolHost() orelse return error.NoTerminalHost;

    // ponytail: env has no spawnTab channel in the MVP → ignored; note it once.
    // Upgrade path: thread env through AgentTabNewRequest if agents rely on it.
    if (envRequested(params)) noteEnvIgnoredOnce(state);

    const cmd = try buildTerminalCommand(allocator, create.command, create.args, create.cwd, builtin.os.tag == .windows);
    defer allocator.free(cmd);

    // spawnTab only takes ownership of the returned ToolSurface metadata; the
    // real pane lives in the app, so `surface.deinit` never closes it.
    var surface = try host.spawnTab(host.ctx, allocator, "command", cmd);
    defer surface.deinit(allocator);

    // Reserve the pane for this agent (mirrors agent_tools/sessions.zig tabNew:
    // fail the call on a lost claim; the pane stays open, no rollback needed).
    const agent_id = state.session.agentInstanceId();
    if (agent_id != 0 and !terminal_lease.active().claim(agent_id, surface.id)) {
        return error.TerminalLeaseClaimFailed;
    }

    const limit = normalizeOutputLimit(create.output_byte_limit);
    try state.addTerminal(surface.id, surface.ptr, limit);
    return schema.encodeTerminalCreated(allocator, surface.id);
}

fn terminalOutput(state: *AcpState, allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const tid = paramTerminalId(params) orelse return error.AcpTerminalBadParams;
    const term = state.findTerminal(tid) orelse return error.AcpUnknownTerminal;
    const host = state.getToolHost() orelse return error.NoTerminalHost;

    const snap = try host.surfaceSnapshot(host.ctx, allocator, tid, term.ptr);
    defer allocator.free(snap);
    const tail = tailBytes(snap, term.output_byte_limit);

    var exited = false;
    var exit_code: ?u32 = null;
    if (host.surfaceExitStatus) |probe| {
        // A probe glitch must not drop the (valid) output — report not-exited.
        if (probe(host.ctx, tid, term.ptr)) |info| {
            exited = info.exited;
            exit_code = info.exit_code;
        } else |_| {}
    }
    return schema.encodeTerminalOutput(allocator, tail, tail.len < snap.len, exited, exit_code);
}

fn terminalWaitForExit(state: *AcpState, allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const tid = paramTerminalId(params) orelse return error.AcpTerminalBadParams;
    const term = state.findTerminal(tid) orelse return error.AcpUnknownTerminal;
    const host = state.getToolHost() orelse return error.NoTerminalHost;
    const probe = host.surfaceExitStatus orelse return error.AcpTerminalWaitUnsupported;

    while (true) {
        // Bail before Connection.deinit reaches the inbound-thread join (which
        // would otherwise deadlock waiting on this loop) or the session closes.
        if (state.conn.isClosing() or state.session.closing.load(.acquire)) return error.AcpConnectionClosing;
        const info = try probe(host.ctx, tid, term.ptr); // SurfaceClosed → error
        if (info.exited) return schema.encodeWaitForExit(allocator, info.exit_code);
        std.Thread.sleep(TERMINAL_WAIT_POLL_MS * std.time.ns_per_ms);
    }
}

fn terminalKill(state: *AcpState, allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const tid = paramTerminalId(params) orelse return error.AcpTerminalBadParams;
    const term = state.findTerminal(tid) orelse return error.AcpUnknownTerminal;
    const host = state.getToolHost() orelse return error.NoTerminalHost;
    const kill = host.killSurfaceChild orelse return error.AcpTerminalKillUnsupported;
    try kill(host.ctx, tid, term.ptr); // pane stays open; only the child dies
    return allocator.dupe(u8, "{}");
}

fn terminalRelease(state: *AcpState, allocator: std.mem.Allocator, params: std.json.Value) ![]u8 {
    const tid = paramTerminalId(params) orelse return error.AcpTerminalBadParams;
    // ponytail: drop the record only; the lease is freed for all panes at
    // session end via releaseOwner, and the pane itself is left for the user.
    state.removeTerminal(tid);
    return allocator.dupe(u8, "{}");
}

fn normalizeOutputLimit(requested: u64) usize {
    if (requested == 0) return DEFAULT_TERMINAL_OUTPUT_LIMIT;
    return @min(@as(usize, @intCast(@min(requested, MAX_TERMINAL_OUTPUT_LIMIT))), MAX_TERMINAL_OUTPUT_LIMIT);
}

/// Last `limit` bytes of `s`, advanced to a UTF-8 leading byte so the truncated
/// output stays valid for JSON string encoding.
fn tailBytes(s: []const u8, limit: usize) []const u8 {
    if (s.len <= limit) return s;
    var start = s.len - limit;
    while (start < s.len and (s[start] & 0xC0) == 0x80) start += 1;
    return s[start..];
}

fn paramTerminalId(params: std.json.Value) ?[]const u8 {
    if (params != .object) return null;
    const v = params.object.get("terminalId") orelse return null;
    return if (v == .string) v.string else null;
}

fn envRequested(params: std.json.Value) bool {
    if (params != .object) return false;
    const env = params.object.get("env") orelse return false;
    return env == .array and env.array.items.len > 0;
}

fn noteEnvIgnoredOnce(state: *AcpState) void {
    if (state.env_note_posted.swap(true, .acq_rel)) return;
    ai_chat.appendProgressMessage(state.session, "[terminal] 自定义环境变量已忽略（当前实现不支持传递 env）") catch {};
}

/// Assemble the single command-line string handed to `ToolHost.spawnTab`, whose
/// downstream tokenizer is a NO-SHELL whitespace+quotes parser (pty_posix
/// parseArgv) → execvp. Each token is single-quoted (embedded `'` → `'\''`) so
/// spaces/quotes survive. A `cwd` rides in via a `/bin/sh -c 'cd … && exec …'`
/// wrapper since spawnTab has no cwd/env parameter.
/// ponytail: Windows path is shape-only (macOS is the e2e target) — raw
/// space-join under `cmd.exe /c`; real Windows agents would need caret/quote
/// escaping, add it when one ships. The `terminal` capability is gated off on
/// Windows (see the `initialize` call) so this path is currently unreachable
/// there in practice.
fn buildTerminalCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []u8,
    cwd: ?[]const u8,
    is_windows: bool,
) ![]u8 {
    if (is_windows) {
        var raw: std.ArrayListUnmanaged(u8) = .empty;
        defer raw.deinit(allocator);
        try raw.appendSlice(allocator, command);
        for (args) |arg| {
            try raw.append(allocator, ' ');
            try raw.appendSlice(allocator, arg);
        }
        if (cwd) |c| return std.fmt.allocPrint(allocator, "cmd.exe /c \"cd /d {s} && {s}\"", .{ c, raw.items });
        return std.fmt.allocPrint(allocator, "cmd.exe /c \"{s}\"", .{raw.items});
    }

    const joined = try joinQuoted(allocator, command, args);
    defer allocator.free(joined);
    const dir = cwd orelse return allocator.dupe(u8, joined);

    const dir_q = try sqQuote(allocator, dir);
    defer allocator.free(dir_q);
    const script = try std.fmt.allocPrint(allocator, "cd {s} && exec {s}", .{ dir_q, joined });
    defer allocator.free(script);
    const script_q = try sqQuote(allocator, script);
    defer allocator.free(script_q);
    return std.fmt.allocPrint(allocator, "/bin/sh -c {s}", .{script_q});
}

/// Space-join `command` + `args`, each POSIX single-quoted.
fn joinQuoted(allocator: std.mem.Allocator, command: []const u8, args: []const []u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const cq = try sqQuote(allocator, command);
    defer allocator.free(cq);
    try out.appendSlice(allocator, cq);
    for (args) |arg| {
        try out.append(allocator, ' ');
        const aq = try sqQuote(allocator, arg);
        defer allocator.free(aq);
        try out.appendSlice(allocator, aq);
    }
    return out.toOwnedSlice(allocator);
}

/// Wrap `s` in single quotes for the no-shell tokenizer, escaping embedded `'`
/// as `'\''` (close, backslash-escaped quote, reopen) — exactly what parseArgv
/// decodes (see pty_posix.zig tests).
fn sqQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

// ===========================================================================
// Tests
// ===========================================================================

test "lastUserText returns the final user turn, ignoring later assistant/tool" {
    var messages = [_]proto.RequestMessage{
        .{ .role = .user, .content = @constCast("first") },
        .{ .role = .assistant, .content = @constCast("reply") },
        .{ .role = .user, .content = @constCast("second") },
        .{ .role = .tool, .content = @constCast("tool output") },
    };
    try std.testing.expectEqualStrings("second", lastUserText(messages[0..]).?);
    try std.testing.expect(lastUserText(&.{}) == null);
    var only_tool = [_]proto.RequestMessage{.{ .role = .tool, .content = @constCast("x") }};
    try std.testing.expect(lastUserText(only_tool[0..]) == null);
}

test "progressCardText maps tool kind/title and terminal calls" {
    const a = std.testing.allocator;
    const plain = try progressCardText(a, .{
        .id = @constCast("t1"),
        .title = @constCast("run tests"),
        .kind = @constCast("execute"),
        .status = @constCast("pending"),
        .content_text = @constCast(""),
        .terminal_id = @constCast(""),
    });
    defer a.free(plain);
    try std.testing.expectEqualStrings("[execute] run tests", plain);

    const term = try progressCardText(a, .{
        .id = @constCast("t2"),
        .title = @constCast("npm test"),
        .kind = @constCast("execute"),
        .status = @constCast("pending"),
        .content_text = @constCast(""),
        .terminal_id = @constCast("term-1"),
    });
    defer a.free(term);
    try std.testing.expect(std.mem.startsWith(u8, term, "[terminal] npm test"));

    const untitled = try progressCardText(a, .{
        .id = @constCast(""),
        .title = @constCast(""),
        .kind = @constCast(""),
        .status = @constCast(""),
        .content_text = @constCast(""),
        .terminal_id = @constCast(""),
    });
    defer a.free(untitled);
    try std.testing.expectEqualStrings("[tool] (untitled)", untitled);
}

test "buildTerminalCommand quotes argv and wraps cwd for the no-shell tokenizer" {
    const a = std.testing.allocator;
    var no_args = [_][]u8{};

    // No args, no cwd → just the quoted command.
    const bare = try buildTerminalCommand(a, "ls", no_args[0..], null, false);
    defer a.free(bare);
    try std.testing.expectEqualStrings("'ls'", bare);

    // Args with a space and an embedded single quote get quoted independently.
    var args = [_][]u8{ @constCast("hello world"), @constCast("it's") };
    const quoted = try buildTerminalCommand(a, "echo", args[0..], null, false);
    defer a.free(quoted);
    try std.testing.expectEqualStrings("'echo' 'hello world' 'it'\\''s'", quoted);

    // cwd present → /bin/sh -c 'cd <cwd> && exec <argv>'.
    const with_cwd = try buildTerminalCommand(a, "echo", args[0..1], "/my dir", false);
    defer a.free(with_cwd);
    try std.testing.expectEqualStrings(
        "/bin/sh -c 'cd '\\''/my dir'\\'' && exec '\\''echo'\\'' '\\''hello world'\\'''",
        with_cwd,
    );

    // Windows shape (compile + shape only; e2e is macOS).
    const win = try buildTerminalCommand(a, "echo", args[0..1], "C:\\tmp", true);
    defer a.free(win);
    try std.testing.expectEqualStrings("cmd.exe /c \"cd /d C:\\tmp && echo hello world\"", win);
}

test "tailBytes keeps the tail on a UTF-8 boundary" {
    try std.testing.expectEqualStrings("cd", tailBytes("abcd", 2));
    try std.testing.expectEqualStrings("abc", tailBytes("abc", 10)); // shorter than limit
    // 'é' is two bytes (0xC3 0xA9); a mid-codepoint cut skips forward to 'x'.
    try std.testing.expectEqualStrings("x", tailBytes("é" ++ "x", 2));
}

fn buildAcpRequest(a: std.mem.Allocator, session: *Session, prompt: []const u8) !*ChatRequest {
    const messages = try a.alloc(proto.RequestMessage, 1);
    errdefer a.free(messages);
    messages[0] = .{ .role = .user, .content = try a.dupe(u8, prompt) };

    const req = try a.create(ChatRequest);
    req.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, ""),
        .api_key = try a.dupe(u8, ""),
        .model = try a.dupe(u8, "agent"),
        .protocol = .acp,
        .system_prompt = try a.dupe(u8, ""),
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, ""),
        .stream = false,
        .agent_enabled = false,
        .acp_command = try a.dupe(u8, session.acp_command),
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = std.time.milliTimestamp(),
    };
    return req;
}

fn waitForQuestion(session: *Session, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (session.questionView() == null) {
        if (waited >= timeout_ms) return error.QuestionTimeout;
        std.Thread.sleep(2 * std.time.ns_per_ms);
        waited += 2;
    }
}

/// Non-deepseek base_url so no DEEPSEEK_API_KEY env pickup → empty key → no
/// auto-title network call fires from the turn's `defer maybeAutoTitle`.
fn newAcpTestSession(a: std.mem.Allocator) !*Session {
    return Session.initWithProtocol(a, "acp", "https://example.invalid", "", "agent", "acp", "sys", "false", "", "false", "false");
}

/// Write `script` into the tmp dir and point the session's acp_command at it.
fn setScriptedAgent(a: std.mem.Allocator, tmp_dir: std.fs.Dir, session: *Session, script: []const u8) !void {
    try tmp_dir.writeFile(.{ .sub_path = "agent.sh", .data = script });
    const script_path = try tmp_dir.realpathAlloc(a, "agent.sh");
    defer a.free(script_path);
    const cmd = try std.fmt.allocPrint(a, "/bin/sh {s}", .{script_path});
    defer a.free(cmd);
    session.setAcpCommand(cmd);
}

fn transcriptContains(session: *Session, role: proto.Role, needle: []const u8) bool {
    session.mutex.lock();
    defer session.mutex.unlock();
    for (session.messages.items) |msg| {
        if (msg.role == role and std.mem.indexOf(u8, msg.content, needle) != null) return true;
    }
    return false;
}

test "acp turn streams text, shows a tool card, and round-trips a permission" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Scripted /bin/sh agent: echoes back request ids, gates the prompt on a
    // permission round-trip, emits a tool card + streamed text, then end_turn.
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"run tests"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
        \\      IFS= read -r reply
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"run tests","kind":"execute","status":"pending"}}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello world"}}}}'
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session = try newAcpTestSession(a);
    defer session.deinit();
    try setScriptedAgent(a, tmp.dir, session, script);

    const req = try buildAcpRequest(a, session, "please run the tests");
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});

    // Answer the permission the agent gates its work on; then the turn finishes.
    try waitForQuestion(session, 15_000);
    const view = session.questionView().?;
    try std.testing.expectEqualStrings("run tests", view.question);
    try std.testing.expectEqual(@as(usize, 2), view.options.len);
    try std.testing.expect(session.resolveQuestionOption(0));
    thread.join();

    // The connection is live and owned by the session; deinit tears it down.
    try std.testing.expect(session.acp_state != null);

    try std.testing.expect(transcriptContains(session, .assistant, "hello world"));
    try std.testing.expect(transcriptContains(session, .tool, "[execute] run tests"));
}

test "acp turn works on a session restored from a history record" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Minimal scripted agent: handshake, then one streamed chunk + end_turn.
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"restored ok"}}}}'
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = try newAcpTestSession(a);
    defer original.deinit();
    try setScriptedAgent(a, tmp.dir, original, script);

    // Persist → restore, as an app restart would (issue: restored ACP sessions
    // lost acp_command and demanded a profile re-pick before the first turn).
    var record = try original.toHistoryRecord(a);
    defer agent_history.freeOwnedRecord(a, &record);
    const session = try Session.initFromHistoryRecord(a, record);
    defer session.deinit();
    try std.testing.expectEqualStrings(original.acp_command, session.acp_command);

    const req = try buildAcpRequest(a, session, "hello after restart");
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});
    thread.join();

    try std.testing.expect(transcriptContains(session, .assistant, "restored ok"));
}

test "agent-death unlock cancels blocked and late askUser callers" {
    const a = std.testing.allocator;
    const session = try newAcpTestSession(a);
    defer session.deinit();

    // Ordering A: asker already blocked when the death path runs. Regression
    // for askUser's wait predicate missing stop_requested (a broadcast without
    // a resolved answer previously woke it into waiting again forever).
    const Runner = struct {
        session: *Session,
        result: ai_chat.AskResult = .cancelled,
        fn run(self: *@This()) void {
            self.result = self.session.askUser("perm?", &.{.{ .label = "Allow" }});
        }
    };
    var runner = Runner{ .session = session };
    var thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    try waitForQuestion(session, 15_000);
    unblockPermissionAskers(session);
    thread.join();
    try std.testing.expect(runner.result == .cancelled);

    // Ordering B: asker arrives after the death path (its inbound thread was
    // scheduled late). The persistent stop flag cancels it at entry — this is
    // exactly what stopRequest's self-reset used to break.
    try std.testing.expect(session.askUser("late?", &.{.{ .label = "A" }}) == .cancelled);
}

test "agent death with a pending permission does not hang the turn" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // On session/prompt: ask permission, then die WITHOUT reading the reply.
    // The permission asker must be cancelled or the turn thread hangs in the
    // connection teardown's inbound-thread join.
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"doomed"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}'
        \\      exit 7
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session = try newAcpTestSession(a);
    defer session.deinit();
    try setScriptedAgent(a, tmp.dir, session, script);

    const req = try buildAcpRequest(a, session, "go");
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});
    // No resolve on purpose: the death path must unblock the asker itself.
    // A regression hangs this join (and the whole test binary — the failure mode).
    thread.join();

    try std.testing.expect(transcriptContains(session, .assistant, "异常退出"));
    try std.testing.expect(session.acp_state == null); // dead connection dropped
}

test "concurrent permission requests serialize and each gets its own answer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Two back-to-back permission requests with distinct option ids. The agent
    // verifies each reply id carries ITS OWN option id (cross-wired answers or
    // a swallowed second question → exit 9 → no "both-ok" in the transcript).
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"perm-A"},"options":[{"optionId":"allow-a","name":"Allow","kind":"allow_once"}]}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":101,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t2","title":"perm-B"},"options":[{"optionId":"allow-b","name":"Allow","kind":"allow_once"}]}}'
        \\      ok=0
        \\      n=0
        \\      while [ "$n" -lt 2 ]; do
        \\        IFS= read -r reply
        \\        n=$((n+1))
        \\        case "$reply" in
        \\          *'"id":100'*'allow-a'*) ok=$((ok+1));;
        \\          *'"id":101'*'allow-b'*) ok=$((ok+1));;
        \\        esac
        \\      done
        \\      [ "$ok" = 2 ] || exit 9
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"both-ok"}}}}'
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session = try newAcpTestSession(a);
    defer session.deinit();
    try setScriptedAgent(a, tmp.dir, session, script);

    const req = try buildAcpRequest(a, session, "go");
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});

    // Answer the two serialized questions in whatever order they surface; each
    // asker maps option 0 to its own option id, which the agent verifies by id.
    try waitForQuestion(session, 15_000);
    try std.testing.expect(session.resolveQuestionOption(0));
    try waitForQuestion(session, 15_000);
    try std.testing.expect(session.resolveQuestionOption(0));
    thread.join();

    try std.testing.expect(transcriptContains(session, .assistant, "both-ok"));
}

test "permission request with no options answers cancelled without asking" {
    const a = std.testing.allocator;
    const session = try newAcpTestSession(a);
    defer session.deinit();
    var st = AcpState{ .allocator = a, .session = session, .conn = undefined, .acp_session_id = &.{}, .stream_idx = null };

    var parsed = try std.json.parseFromSlice(std.json.Value, a,
        \\{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"x"},"options":[]}
    , .{});
    defer parsed.deinit();
    const out = try onRequest(@ptrCast(&st), a, "session/request_permission", parsed.value);
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"outcome\":{\"outcome\":\"cancelled\"}}", out);
}

/// Stub ToolHost backing the terminal/* e2e test: spawnTab hands back a fixed
/// surface id, surfaceSnapshot returns canned text, and the exit probe reports
/// an already-exited child so wait_for_exit returns at once.
const FakeTerminalHost = struct {
    const surface_id = "acp-term-e2e-1";
    var surface_sentinel: u8 = 0;

    fn collectSnapshot(_: *anyopaque, _: std.mem.Allocator) anyerror!types.ToolSnapshot {
        return error.Unsupported;
    }
    fn surfaceSnapshot(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        return allocator.dupe(u8, "hello from terminal\n$ ");
    }
    fn writeSurface(_: *anyopaque, _: []const u8, _: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn spawnTab(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, command: ?[]const u8) anyerror!types.ToolSurface {
        // Prove the cwd wrapper reached spawnTab; the pane itself is faked.
        if (command == null or std.mem.indexOf(u8, command.?, "/bin/sh -c ") == null) return error.BadCommand;
        return types.ToolSurface.initOwned(allocator, surface_id, "echo", "/tmp", try allocator.dupe(u8, ""), .{
            .tab_index = 0,
            .focused = true,
            .is_ssh = false,
            .is_wsl = false,
            .ptr = @ptrCast(&surface_sentinel),
        });
    }
    fn closeTab(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!types.ToolClosedTab {
        return error.Unsupported;
    }
    fn saveSshProfile(_: *anyopaque, _: std.mem.Allocator, _: types.SshProfileSaveArgs) anyerror!types.SavedSshProfile {
        return error.Unsupported;
    }
    fn connectSshProfile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!types.ToolSurface {
        return error.Unsupported;
    }
    fn surfaceExitStatus(_: *anyopaque, _: []const u8, _: *anyopaque) anyerror!types.SurfaceExitInfo {
        return .{ .exited = true, .exit_code = 0 };
    }
    fn killSurfaceChild(_: *anyopaque, _: []const u8, _: *anyopaque) anyerror!void {}

    fn host() ToolHost {
        return .{
            .ctx = @ptrCast(&surface_sentinel),
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = surfaceSnapshot,
            .writeSurface = writeSurface,
            .spawnTab = spawnTab,
            .closeTab = closeTab,
            .saveSshProfile = saveSshProfile,
            .connectSshProfile = connectSshProfile,
            .surfaceExitStatus = surfaceExitStatus,
            .killSurfaceChild = killSurfaceChild,
        };
    }
};

test "acp terminal/* round-trips create, output, wait, kill, release against a fake host" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Scripted agent: on session/prompt it drives the full terminal lifecycle,
    // asserting each reply by exiting non-zero on any mismatch (so a broken
    // handler kills the connection and "terminal-ok" never reaches the chat).
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":200,"method":"terminal/create","params":{"sessionId":"s1","command":"echo","args":["hello world"],"cwd":"/tmp","outputByteLimit":1024}}'
        \\      IFS= read -r r; case "$r" in *'"id":200'*'acp-term-e2e-1'*) : ;; *) exit 21 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":201,"method":"terminal/output","params":{"sessionId":"s1","terminalId":"acp-term-e2e-1"}}'
        \\      IFS= read -r r; case "$r" in *'"id":201'*'hello from terminal'*'"exitCode":0'*) : ;; *) exit 22 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":202,"method":"terminal/wait_for_exit","params":{"sessionId":"s1","terminalId":"acp-term-e2e-1"}}'
        \\      IFS= read -r r; case "$r" in *'"id":202'*'"exitCode":0'*) : ;; *) exit 23 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":203,"method":"terminal/kill","params":{"sessionId":"s1","terminalId":"acp-term-e2e-1"}}'
        \\      IFS= read -r r; case "$r" in *'"id":203'*'"result"'*) : ;; *) exit 24 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":205,"method":"terminal/output","params":{"sessionId":"s1","terminalId":"unknown-id"}}'
        \\      IFS= read -r r; case "$r" in *'"id":205'*'"error"'*) : ;; *) exit 25 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":206,"method":"terminal/release","params":{"sessionId":"s1","terminalId":"acp-term-e2e-1"}}'
        \\      IFS= read -r r; case "$r" in *'"id":206'*'"result"'*) : ;; *) exit 26 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"terminal-ok"}}}}'
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const session = try newAcpTestSession(a);
    defer session.deinit();
    try setScriptedAgent(a, tmp.dir, session, script);

    const req = try buildAcpRequest(a, session, "run a command");
    req.tool_host = FakeTerminalHost.host();
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});
    thread.join();

    try std.testing.expect(session.acp_state != null); // connection survived the chain
    try std.testing.expect(transcriptContains(session, .assistant, "terminal-ok"));
}
