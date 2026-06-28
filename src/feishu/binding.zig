//! 飞书入站过滤 + event_id 去重。M2 p2p-only；群聊 @ 留 M3。
const std = @import("std");
const types = @import("types.zig");

/// 过滤配置。allowed_user 为空 = 不限制发送方；非空 = 仅接受该 open_id。
pub const Config = struct {
    allowed_user: []const u8 = "",
};

/// 决定是否处理该消息。
/// - group → false（v1 仅 p2p；群聊 @ 是 M3）
/// - sender_open_id 空 → false
/// - allowed_user 非空且不匹配 → false
/// - 否则 true
pub fn shouldHandle(msg: types.IncomingMessage, cfg: Config) bool {
    if (msg.chat_type == .group) return false;
    if (msg.sender_open_id.len == 0) return false;
    if (cfg.allowed_user.len != 0 and !std.mem.eql(u8, msg.sender_open_id, cfg.allowed_user)) return false;
    return true;
}

/// 有界内存去重集合（保留最近 cap 条 event_id；FIFO 淘汰）。
/// 调用方：先 `seen` 判重，新则 `markSeen` 再处理。
pub const Dedup = struct {
    // ponytail: ring buffer over ArrayList; cap fixed at init, no realloc after that.
    entries: [][]u8,
    cap: usize,
    head: usize, // 下一个写入位置
    len: usize, // 已存条数
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !Dedup {
        const entries = try alloc.alloc([]u8, cap);
        @memset(entries, &.{});
        return .{ .entries = entries, .cap = cap, .head = 0, .len = 0, .alloc = alloc };
    }

    pub fn deinit(self: *Dedup) void {
        for (self.entries) |e| {
            if (e.len != 0) self.alloc.free(e);
        }
        self.alloc.free(self.entries);
    }

    pub fn seen(self: *const Dedup, event_id: []const u8) bool {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e, event_id)) return true;
        }
        return false;
    }

    /// 将 event_id 记录到环形槽；自动淘汰最旧条目。
    pub fn markSeen(self: *Dedup, event_id: []const u8) !void {
        const slot = self.head;
        // 淘汰旧条目
        if (self.entries[slot].len != 0) {
            self.alloc.free(self.entries[slot]);
        }
        self.entries[slot] = try self.alloc.dupe(u8, event_id);
        self.head = (slot + 1) % self.cap;
        if (self.len < self.cap) self.len += 1;
    }
};

const t = std.testing;

test "shouldHandle: p2p with sender → true" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_abc" }, .{}));
}

test "shouldHandle: group → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .group, .sender_open_id = "ou_abc" }, .{}));
}

test "shouldHandle: empty sender → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "" }, .{}));
}

test "shouldHandle: allowlist hit → true" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_abc" }, .{ .allowed_user = "ou_abc" }));
}

test "shouldHandle: allowlist miss → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_xyz" }, .{ .allowed_user = "ou_abc" }));
}

test "shouldHandle: empty allowlist → any user passes" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_anyone" }, .{ .allowed_user = "" }));
}

test "Dedup: first seen=false, after markSeen seen=true" {
    var d = try Dedup.init(t.allocator, 4);
    defer d.deinit();
    try t.expect(!d.seen("ev1"));
    try d.markSeen("ev1");
    try t.expect(d.seen("ev1"));
}

test "Dedup: eviction after capacity" {
    var d = try Dedup.init(t.allocator, 3);
    defer d.deinit();
    try d.markSeen("ev1");
    try d.markSeen("ev2");
    try d.markSeen("ev3");
    // 满容量；再加一条，ev1 应被淘汰
    try d.markSeen("ev4");
    try t.expect(!d.seen("ev1")); // 最旧的已淘汰
    try t.expect(d.seen("ev2"));
    try t.expect(d.seen("ev3"));
    try t.expect(d.seen("ev4"));
}
