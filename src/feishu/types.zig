//! 飞书 channel 共享类型集合 — M2 p2p 文本闭环所需最小字段集。

const std = @import("std");

/// 飞书应用凭据（app_id + app_secret），切片由调用方持有。
pub const Credentials = struct {
    app_id: []const u8,
    app_secret: []const u8,
};

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
    /// 已从 content JSON 串解析出的纯文本；非 text 类型可为空
    text: []const u8 = "",
};

test "ChatType.fromString" {
    try std.testing.expectEqual(ChatType.group, ChatType.fromString("group"));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString("p2p"));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString(""));
    try std.testing.expectEqual(ChatType.p2p, ChatType.fromString("unknown"));
}
