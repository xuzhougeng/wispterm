const std = @import("std");
const agent_detector = @import("terminal_agents/detector.zig");

/// Max bytes retained for a notification title / body. Longer input is truncated.
pub const max_title: usize = 256;
pub const max_body: usize = 1024;
/// Bounded queue capacity. When full, the oldest item is dropped.
pub const queue_cap: usize = 8;
/// Rate limit: at most one notification per this many ms, regardless of content.
pub const rate_limit_ms: i64 = 1000;
/// Content dedup: an identical (same-hash) notification is suppressed for this
/// many ms — longer than the rate limit, so a program re-emitting the same
/// notification stays quiet even at intervals that clear the rate limit.
pub const dedup_ms: i64 = 5000;

/// One queued notification, owning fixed-size copies of title/body so the
/// transient slices handed to us by the VT parser can be safely retained.
pub const Item = struct {
    title_buf: [max_title]u8 = undefined,
    title_len: usize = 0,
    body_buf: [max_body]u8 = undefined,
    body_len: usize = 0,
    /// True when the body carried the WispTerm notifier's WeChat-forward marker
    /// (stripped before storage). Read by AppWindow.handleNotification.
    forward_wechat: bool = false,

    pub fn title(self: *const Item) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn body(self: *const Item) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

/// Zero-width space (U+200B) the WispTerm notifier appends to a notification's
/// OSC 777 body to mark it for forwarding to the bound WeChat owner. It is
/// invisible in every renderer, so a build that does not strip it still shows a
/// clean toast. We strip it here so the stored/hashed/displayed body is clean.
pub const wechat_marker = "\u{200b}"; // bytes E2 80 8B

/// Copy + truncate raw (transient) title/body slices into an owned Item.
pub fn makeItem(title_in: []const u8, body_in: []const u8) Item {
    var item: Item = .{};
    item.title_len = @min(title_in.len, max_title);
    @memcpy(item.title_buf[0..item.title_len], title_in[0..item.title_len]);

    var body = body_in;
    if (std.mem.endsWith(u8, body, wechat_marker)) {
        item.forward_wechat = true;
        body = body[0 .. body.len - wechat_marker.len];
    }
    item.body_len = @min(body.len, max_body);
    @memcpy(item.body_buf[0..item.body_len], body[0..item.body_len]);
    return item;
}

/// Mutex-protected bounded FIFO. Pushed from the IO reader thread, popped from
/// the main thread (same producer/consumer split as `Surface.bell_pending`).
pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: [queue_cap]Item = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Enqueue; if full, drop the oldest item to make room (newest wins).
    pub fn push(self: *Queue, item: Item) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == queue_cap) {
            self.head = (self.head + 1) % queue_cap; // drop oldest
            self.len -= 1;
        }
        const tail = (self.head + self.len) % queue_cap;
        self.items[tail] = item;
        self.len += 1;
    }

    /// Dequeue the oldest item, or null if empty.
    pub fn pop(self: *Queue) ?Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % queue_cap;
        self.len -= 1;
        return item;
    }
};

/// Convenience: copy/truncate and enqueue in one call (used by the VtHandler).
pub fn ingest(queue: *Queue, title_in: []const u8, body_in: []const u8) void {
    queue.push(makeItem(title_in, body_in));
}

/// Stable hash of (title, body) for dedup. The zero byte separates the two
/// fields so ("ab","c") and ("a","bc") hash differently.
pub fn contentHash(title_in: []const u8, body_in: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(title_in);
    h.update(&[_]u8{0});
    h.update(body_in);
    return h.final();
}

/// True if this notification should be delivered now. Two rules, both keyed off
/// the last *delivered* notification's time/hash:
///   1. Rate limit: drop anything within `rate_limit_ms` (≤ 1 per second).
///   2. Content dedup: drop an identical (same-hash) notification within the
///      longer `dedup_ms` window.
/// `last_time_ms == 0` means "none delivered yet" → always allow.
pub fn shouldDeliver(now_ms: i64, h: u64, last_time_ms: i64, last_hash: u64) bool {
    if (last_time_ms == 0) return true;
    const dt = now_ms - last_time_ms;
    if (dt < rate_limit_ms) return false; // rate limit (any content)
    if (h == last_hash and dt < dedup_ms) return false; // identical-content dedup
    return true;
}

/// Cached macOS authorization status (mirrors the bridge's int contract).
pub const AuthStatus = enum(u8) { unavailable = 0, denied = 1, authorized = 2 };

/// What to do with a deliverable notification.
pub const Route = enum { none, toast, badge };

/// Pure routing decision. `.toast` only when the platform supports native
/// toasts (macOS) AND authorized AND you're not looking right at it; `.badge`
/// everywhere else; `.none` only when disabled.
pub fn decideRoute(
    notif_enabled: bool,
    native_toast_supported: bool,
    auth: AuthStatus,
    window_focused: bool,
    is_active_surface: bool,
) Route {
    if (!notif_enabled) return .none;
    const suppress = window_focused and is_active_surface;
    if (native_toast_supported and auth == .authorized and !suppress) return .toast;
    return .badge;
}

// ---------------------------------------------------------------------------
// Agent attention edges (in-app AI sessions + OSC 7748 terminal agents).
// Pure classifiers; AppWindow's main loop polls once per frame and feeds edges
// here, so notifications are edge-triggered — a pending approval never nags
// twice, and re-entering a state re-notifies.
// ---------------------------------------------------------------------------

/// Attention phase of an in-app AI session (AI-chat tab / copilot sidebar),
/// derived each frame from approvalView()/questionView() + request_inflight.
pub const SessionPhase = enum { idle, running, waiting };

pub const SessionEdge = enum { none, finished, needs_attention };

/// Classify a phase change. `stopped` = the user pressed Stop during this turn
/// (their own action — finishing silently, like Orca's `interrupted`).
pub fn sessionEdge(prev: SessionPhase, cur: SessionPhase, stopped: bool) SessionEdge {
    if (prev == cur) return .none;
    if (cur == .waiting) return .needs_attention;
    if (cur == .idle) return if (stopped) .none else .finished;
    return .none;
}

/// Quiet window for a terminal agent's `done` marker: notify only if the agent
/// is still done this long after the edge — goal-loop agents bounce
/// done→running between milestones (calibrated to match Orca).
pub const agent_done_quiet_ms: i64 = 1500;

pub const AgentMarkerAction = enum { none, notify_attention, stage_done };

/// A hook's own OSC 777 (richer, custom text) may announce the same completion
/// the OSC 7748 marker signals — usually in the same burst, but the synthetic
/// done fires `agent_done_quiet_ms` later, past the rate-limit window. Skip the
/// synthetic when anything was delivered near/after the done edge.
pub const done_announce_window_ms: i64 = 1000;

pub fn doneAlreadyAnnounced(last_delivered_ms: i64, staged_ms: i64) bool {
    if (last_delivered_ms == 0) return false;
    return last_delivered_ms + done_announce_window_ms >= staged_ms;
}

/// Classify an OSC 7748 state edge. `stage_done` starts the quiet window; the
/// caller cancels the stage whenever the state leaves `.done` before it fires.
pub fn agentMarkerAction(prev: agent_detector.State, cur: agent_detector.State) AgentMarkerAction {
    if (prev == cur) return .none;
    return switch (cur) {
        .waiting_approval, .needs_input => .notify_attention,
        .done => .stage_done,
        else => .none,
    };
}

test "makeItem copies and truncates title/body" {
    const long_title = "T" ** 300;
    const item = makeItem(long_title, "hello");
    try std.testing.expectEqual(@as(usize, max_title), item.title().len);
    try std.testing.expectEqualStrings("hello", item.body());

    const empty = makeItem("", "");
    try std.testing.expectEqual(@as(usize, 0), empty.title().len);
    try std.testing.expectEqual(@as(usize, 0), empty.body().len);
}

test "Queue is FIFO and drops oldest when full" {
    var q: Queue = .{};
    var i: usize = 0;
    while (i < queue_cap + 2) : (i += 1) {
        var buf: [8]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        ingest(&q, t, "b");
    }
    // First two ("0","1") were dropped; oldest remaining is "2".
    const first = q.pop().?;
    try std.testing.expectEqualStrings("2", first.title());
    var count: usize = 1;
    while (q.pop() != null) count += 1;
    try std.testing.expectEqual(queue_cap, count);
    try std.testing.expect(q.pop() == null);
}

test "contentHash distinguishes title vs body boundary" {
    try std.testing.expect(contentHash("ab", "c") != contentHash("a", "bc"));
    try std.testing.expectEqual(contentHash("x", "y"), contentHash("x", "y"));
}

test "shouldDeliver: rate limit (any content) + longer content dedup" {
    const h1: u64 = 111;
    const h2: u64 = 222;
    // First ever (last_time = 0 sentinel) -> allowed
    try std.testing.expect(shouldDeliver(10_000, h1, 0, 0));
    // Within rate-limit window, same content -> dropped (rate limit)
    try std.testing.expect(!shouldDeliver(10_500, h1, 10_000, h1));
    // Within rate-limit window, different content -> dropped (rate limit dominates)
    try std.testing.expect(!shouldDeliver(10_500, h2, 10_000, h1));
    // Past rate limit, different content -> allowed
    try std.testing.expect(shouldDeliver(11_000, h2, 10_000, h1));
    // Past rate limit but identical content within dedup window -> dropped (dedup)
    try std.testing.expect(!shouldDeliver(13_000, h1, 10_000, h1));
    // Past dedup window, identical content -> allowed
    try std.testing.expect(shouldDeliver(16_000, h1, 10_000, h1));
}

test "decideRoute matrix" {
    const A = AuthStatus.authorized;
    try std.testing.expectEqual(Route.none, decideRoute(false, true, A, false, false));
    try std.testing.expectEqual(Route.toast, decideRoute(true, true, A, false, false));
    try std.testing.expectEqual(Route.toast, decideRoute(true, true, A, true, false));
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, A, true, true));
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, .denied, false, false));
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, .unavailable, false, false));
    try std.testing.expectEqual(Route.badge, decideRoute(true, false, A, false, false));
}

test "makeItem strips the trailing wechat marker and sets forward_wechat" {
    const marked = "完成，轮到你了" ++ wechat_marker;
    const item = makeItem("Claude Code", marked);
    try std.testing.expect(item.forward_wechat);
    try std.testing.expectEqualStrings("完成，轮到你了", item.body());
    try std.testing.expectEqualStrings("Claude Code", item.title());
}

test "makeItem without the marker keeps body intact and forward_wechat false" {
    const item = makeItem("t", "完成，轮到你了");
    try std.testing.expect(!item.forward_wechat);
    try std.testing.expectEqualStrings("完成，轮到你了", item.body());
}

test "sessionEdge: turn end notifies finished unless the user stopped it" {
    // running → idle = turn finished
    try std.testing.expectEqual(SessionEdge.finished, sessionEdge(.running, .idle, false));
    // waiting → idle (approval answered elsewhere / turn aborted by agent) also finishes
    try std.testing.expectEqual(SessionEdge.finished, sessionEdge(.waiting, .idle, false));
    // user pressed Stop → silent
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.running, .idle, true));
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.waiting, .idle, true));
}

test "sessionEdge: entering waiting needs attention" {
    try std.testing.expectEqual(SessionEdge.needs_attention, sessionEdge(.running, .waiting, false));
    // approval popped before we ever observed running (fast first frame)
    try std.testing.expectEqual(SessionEdge.needs_attention, sessionEdge(.idle, .waiting, false));
    // a Stop in flight doesn't suppress a *new* attention request
    try std.testing.expectEqual(SessionEdge.needs_attention, sessionEdge(.running, .waiting, true));
}

test "sessionEdge: no edge without a phase change; starting a turn is silent" {
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.idle, .idle, false));
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.running, .running, false));
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.waiting, .waiting, false));
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.idle, .running, false));
    try std.testing.expectEqual(SessionEdge.none, sessionEdge(.waiting, .running, false));
}

test "agentMarkerAction: attention states notify immediately, done is staged" {
    try std.testing.expectEqual(AgentMarkerAction.notify_attention, agentMarkerAction(.running, .waiting_approval));
    try std.testing.expectEqual(AgentMarkerAction.notify_attention, agentMarkerAction(.running, .needs_input));
    // done goes through the quiet window, not straight to a toast
    try std.testing.expectEqual(AgentMarkerAction.stage_done, agentMarkerAction(.running, .done));
    // even done → waiting (agent finished then asked) re-notifies attention
    try std.testing.expectEqual(AgentMarkerAction.notify_attention, agentMarkerAction(.done, .waiting_approval));
}

test "agentMarkerAction: silent transitions" {
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.none, .running));
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.done, .running));
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.running, .running));
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.running, .halted));
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.running, .failed));
    try std.testing.expectEqual(AgentMarkerAction.none, agentMarkerAction(.waiting_approval, .none));
}

test "agent done quiet window is Orca-calibrated (1.5s)" {
    try std.testing.expectEqual(@as(i64, 1500), agent_done_quiet_ms);
}

test "doneAlreadyAnnounced: hook's own OSC 777 near the done edge wins" {
    // OSC 777 delivered just before the marker (same hook run) → skip synthetic
    try std.testing.expect(doneAlreadyAnnounced(9500, 10_000));
    // delivered right after the edge (marker first, notify second) → skip
    try std.testing.expect(doneAlreadyAnnounced(10_200, 10_000));
    // an old unrelated notification does not count
    try std.testing.expect(!doneAlreadyAnnounced(3000, 10_000));
    // nothing ever delivered (0 sentinel) → fire
    try std.testing.expect(!doneAlreadyAnnounced(0, 10_000));
}
