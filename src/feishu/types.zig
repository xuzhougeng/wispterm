//! 飞书 channel 共享类型集合 — M2 p2p 文本闭环所需最小字段集。

const std = @import("std");

/// 飞书应用凭据（app_id + app_secret），切片由调用方持有。
pub const Credentials = struct {
    app_id: []const u8,
    app_secret: []const u8,
};

/// Open API region. A Feishu/Lark app belongs to exactly one region — China
/// (open.feishu.cn) vs international Lark (open.larksuite.com) — and credentials
/// are not interchangeable. So the region is a process singleton, set once at
/// controller startup from config (feishu-international).
/// ponytail: set-once global models the one-region-per-process reality, so rest.zig
/// and media.zig read it directly instead of threading a base host through every call.
var g_international: bool = false;

/// Sets the API region. Call once from App.startFeishu before any network call.
pub fn setRegion(international: bool) void {
    g_international = international;
}

/// Returns the Open API base host (scheme + host, no trailing slash) for the
/// configured region.
pub fn apiBase() []const u8 {
    return if (g_international) "https://open.larksuite.com" else "https://open.feishu.cn";
}

test "apiBase switches between Feishu and Lark hosts" {
    defer setRegion(false); // restore default so other tests see China region
    setRegion(false);
    try std.testing.expectEqualStrings("https://open.feishu.cn", apiBase());
    setRegion(true);
    try std.testing.expectEqualStrings("https://open.larksuite.com", apiBase());
}

/// 会话类型：单聊或群聊。
pub const ChatType = enum {
    p2p,
    group,

    /// 从飞书协议字符串解析；"group" → .group，其余一律 .p2p。
    pub fn fromString(s: []const u8) ChatType {
        if (std.mem.eql(u8, s, "group")) return .group;
        return .p2p;
    }
};

/// 群聊 @ 提及项。key 是 text 中的占位符（如 "@_user_1"），open_id 是被 @ 者。
pub const Mention = struct {
    key: []const u8 = "",
    open_id: []const u8 = "",
};

/// im.message.receive_v1 规范化后的消息结构体。
/// 切片借用 codec 的 arena，生命周期由调用方管理。
pub const IncomingMessage = struct {
    /// header.event_id — 幂等去重键
    event_id: []const u8 = "",
    /// event.message.message_id — om_ 开头，用于回复/卡片
    message_id: []const u8 = "",
    /// event.message.chat_id — oc_ 开头
    chat_id: []const u8 = "",
    /// event.sender.sender_id.open_id — ou_ 开头
    sender_open_id: []const u8 = "",
    chat_type: ChatType = .p2p,
    /// event.message.message_type（text / image / post / …）
    message_type: []const u8 = "",
    /// 已从 content JSON 串解析出的纯文本；非 text 类型可为空。
    /// 群聊消息已剥除 @ 占位符（见 codec.stripMentions）。
    text: []const u8 = "",
    /// event.message.mentions —— 群聊 @ 列表；私聊一般为空。
    mentions: []const Mention = &.{},

    /// 该消息是否 @ 了给定 open_id（用于群聊判断是否 @ 了机器人本身）。
    pub fn mentionsOpenId(self: IncomingMessage, open_id: []const u8) bool {
        if (open_id.len == 0) return false;
        for (self.mentions) |m| {
            if (std.mem.eql(u8, m.open_id, open_id)) return true;
        }
        return false;
    }
};

test "mentionsOpenId matches a mentioned open_id, ignores empty/absent" {
    const m = [_]Mention{
        .{ .key = "@_user_1", .open_id = "ou_bot" },
        .{ .key = "@_user_2", .open_id = "ou_alice" },
    };
    const msg = IncomingMessage{ .chat_type = .group, .mentions = &m };
    try std.testing.expect(msg.mentionsOpenId("ou_bot"));
    try std.testing.expect(msg.mentionsOpenId("ou_alice"));
    try std.testing.expect(!msg.mentionsOpenId("ou_stranger"));
    try std.testing.expect(!msg.mentionsOpenId("")); // empty bot id never matches
    const empty = IncomingMessage{ .chat_type = .p2p };
    try std.testing.expect(!empty.mentionsOpenId("ou_bot"));
}

test "ChatType.fromString" {
    try std.testing.expectEqual(ChatType.group, ChatType.fromString("group"));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString("p2p"));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString(""));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString("unknown"));
}
