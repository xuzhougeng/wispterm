//! 飞书入站过滤 + event_id 去重。私聊全收；群聊仅响应 @ 机器人的消息。
const std = @import("std");
const types = @import("types.zig");

/// 过滤配置。allowed_user 为空 = 不限制发送方；非空 = 仅接受该 open_id。
pub const Config = struct {
    allowed_user: []const u8 = "",
};

/// 决定是否处理该消息。
/// - group 且未 @ 机器人 → false（群聊仅响应 @ 机器人的消息，避免刷屏）
/// - sender_open_id 空 → false
/// - allowed_user 非空且不匹配 → false
/// - 否则 true
///
/// bot_open_id 为机器人自身 open_id（controller 在 start 时经 getBotOpenId 获取）。
/// 为空时（获取失败的降级）群聊一律 false，私聊不受影响。
pub fn shouldHandle(msg: types.IncomingMessage, cfg: Config, bot_open_id: []const u8) bool {
    if (msg.chat_type == .group and !msg.mentionsOpenId(bot_open_id)) return false;
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

const bot = "ou_bot"; // 测试用机器人 open_id

test "shouldHandle: p2p with sender → true" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_abc" }, .{}, bot));
}

test "shouldHandle: group without @bot → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .group, .sender_open_id = "ou_abc" }, .{}, bot));
}

test "shouldHandle: group @bot → true" {
    const m = [_]types.Mention{.{ .key = "@_user_1", .open_id = bot }};
    try t.expect(shouldHandle(.{ .chat_type = .group, .sender_open_id = "ou_abc", .mentions = &m }, .{}, bot));
}

test "shouldHandle: group @someone-else → false" {
    const m = [_]types.Mention{.{ .key = "@_user_1", .open_id = "ou_other" }};
    try t.expect(!shouldHandle(.{ .chat_type = .group, .sender_open_id = "ou_abc", .mentions = &m }, .{}, bot));
}

test "shouldHandle: group @bot but empty bot_open_id (degraded) → false" {
    const m = [_]types.Mention{.{ .key = "@_user_1", .open_id = bot }};
    try t.expect(!shouldHandle(.{ .chat_type = .group, .sender_open_id = "ou_abc", .mentions = &m }, .{}, ""));
}

test "shouldHandle: empty sender → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "" }, .{}, bot));
}

test "shouldHandle: allowlist hit → true" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_abc" }, .{ .allowed_user = "ou_abc" }, bot));
}

test "shouldHandle: allowlist miss → false" {
    try t.expect(!shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_xyz" }, .{ .allowed_user = "ou_abc" }, bot));
}

test "shouldHandle: empty allowlist → any user passes" {
    try t.expect(shouldHandle(.{ .chat_type = .p2p, .sender_open_id = "ou_anyone" }, .{ .allowed_user = "" }, bot));
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
