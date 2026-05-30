const std = @import("std");

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

    pub fn title(self: *const Item) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn body(self: *const Item) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

/// Copy + truncate raw (transient) title/body slices into an owned Item.
pub fn makeItem(title_in: []const u8, body_in: []const u8) Item {
    var item: Item = .{};
    item.title_len = @min(title_in.len, max_title);
    @memcpy(item.title_buf[0..item.title_len], title_in[0..item.title_len]);
    item.body_len = @min(body_in.len, max_body);
    @memcpy(item.body_buf[0..item.body_len], body_in[0..item.body_len]);
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

/// Pure routing decision. `.toast` only on macOS + authorized + not looking
/// right at it; `.badge` everywhere else; `.none` only when disabled.
pub fn decideRoute(
    notif_enabled: bool,
    is_macos: bool,
    auth: AuthStatus,
    window_focused: bool,
    is_active_surface: bool,
) Route {
    if (!notif_enabled) return .none;
    const suppress = window_focused and is_active_surface;
    if (is_macos and auth == .authorized and !suppress) return .toast;
    return .badge;
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
