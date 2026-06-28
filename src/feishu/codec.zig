//! 飞书入站事件解析 — M2.5.
//! parseReceiveV1: im.message.receive_v1 envelope JSON → IncomingMessage.
//! 出站 content 构造已在 rest.zig (M2.4)，本模块纯入站，不重复。
//!
//! content 双重解析说明：
//!   event.message.content 是一个 JSON 字符串值，其内容又是一段 JSON，
//!   例如 "{\"text\":\"hi\"}"。需先解析外层取出该字符串，再对字符串本身
//!   做第二次 JSON 解析取 text 字段。

const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// 外层信封结构（仅取 M2 所需字段，ignore_unknown_fields=true 忽略其余）
// ---------------------------------------------------------------------------

const EnvHeader = struct {
    event_id: []const u8 = "",
};

const SenderId = struct {
    open_id: []const u8 = "",
};

const Sender = struct {
    sender_id: SenderId = .{},
};

const Message = struct {
    message_id: []const u8 = "",
    chat_id: []const u8 = "",
    chat_type: []const u8 = "",
    message_type: []const u8 = "",
    /// content 是一段 JSON 字符串，其值本身又是 JSON。
    content: []const u8 = "",
};

const Event = struct {
    sender: Sender = .{},
    message: Message = .{},
};

const Envelope = struct {
    header: EnvHeader = .{},
    event: Event = .{},
};

// ---------------------------------------------------------------------------
// content 内层结构（仅 text）
// ---------------------------------------------------------------------------

const TextContent = struct {
    text: []const u8 = "",
};

// ---------------------------------------------------------------------------
// 公共接口
// ---------------------------------------------------------------------------

/// 将 im.message.receive_v1 事件的 payload JSON 解析为 IncomingMessage。
/// 所有切片由 arena 分配，生命周期由调用方管理。
/// 非 text 消息类型时 text 字段为空字符串。
pub fn parseReceiveV1(arena: std.mem.Allocator, payload_json: []const u8) !types.IncomingMessage {
    const env = try std.json.parseFromSliceLeaky(Envelope, arena, payload_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    var text: []const u8 = "";
    if (std.mem.eql(u8, env.event.message.message_type, "text") and
        env.event.message.content.len > 0)
    {
        // 第二次解析：content 字符串本身是 JSON。
        const inner = std.json.parseFromSliceLeaky(TextContent, arena, env.event.message.content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch TextContent{}; // 解析失败时 text 留空，不中断整体流程。
        text = inner.text;
    }

    return .{
        .event_id = env.header.event_id,
        .message_id = env.event.message.message_id,
        .chat_id = env.event.message.chat_id,
        .sender_open_id = env.event.sender.sender_id.open_id,
        .chat_type = types.ChatType.fromString(env.event.message.chat_type),
        .message_type = env.event.message.message_type,
        .text = text,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

// TODO(M2.E2E): 捕获 fixtures/02_event_data_frame.bin 后，在此补一条
// "pbbp2.decode 真帧 → parseReceiveV1" 的端到端断言。

test "parseReceiveV1: text message — all fields extracted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // 合成 receive_v1 信封，content 是双层 JSON 字符串。
    const json =
        \\{
        \\  "schema":"2.0",
        \\  "header":{"event_id":"ev-001","event_type":"im.message.receive_v1"},
        \\  "event":{
        \\    "sender":{"sender_id":{"open_id":"ou_alice"}},
        \\    "message":{
        \\      "message_id":"om_msg001",
        \\      "chat_id":"oc_chat001",
        \\      "chat_type":"p2p",
        \\      "message_type":"text",
        \\      "content":"{\"text\":\"hello world\"}"
        \\    }
        \\  }
        \\}
    ;

    const msg = try parseReceiveV1(arena.allocator(), json);

    try std.testing.expectEqualStrings("ev-001", msg.event_id);
    try std.testing.expectEqualStrings("om_msg001", msg.message_id);
    try std.testing.expectEqualStrings("oc_chat001", msg.chat_id);
    try std.testing.expectEqualStrings("ou_alice", msg.sender_open_id);
    try std.testing.expectEqual(types.ChatType.p2p, msg.chat_type);
    try std.testing.expectEqualStrings("text", msg.message_type);
    try std.testing.expectEqualStrings("hello world", msg.text);
}

test "parseReceiveV1: text with escaped quotes and CJK" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // content 中含转义引号和中文字符，确认二次解析正确。
    const json =
        \\{
        \\  "schema":"2.0",
        \\  "header":{"event_id":"ev-002","event_type":"im.message.receive_v1"},
        \\  "event":{
        \\    "sender":{"sender_id":{"open_id":"ou_bob"}},
        \\    "message":{
        \\      "message_id":"om_msg002",
        \\      "chat_id":"oc_group001",
        \\      "chat_type":"group",
        \\      "message_type":"text",
        \\      "content":"{\"text\":\"你好 \\\"世界\\\"\"}"
        \\    }
        \\  }
        \\}
    ;

    const msg = try parseReceiveV1(arena.allocator(), json);

    try std.testing.expectEqualStrings("ev-002", msg.event_id);
    try std.testing.expectEqualStrings("ou_bob", msg.sender_open_id);
    try std.testing.expectEqual(types.ChatType.group, msg.chat_type);
    try std.testing.expectEqualStrings("text", msg.message_type);
    // 转义后的真实文本：你好 "世界"
    try std.testing.expectEqualStrings("你好 \"世界\"", msg.text);
}

test "parseReceiveV1: non-text (image) — text is empty, other fields set" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const json =
        \\{
        \\  "schema":"2.0",
        \\  "header":{"event_id":"ev-003","event_type":"im.message.receive_v1"},
        \\  "event":{
        \\    "sender":{"sender_id":{"open_id":"ou_carol"}},
        \\    "message":{
        \\      "message_id":"om_msg003",
        \\      "chat_id":"oc_chat002",
        \\      "chat_type":"p2p",
        \\      "message_type":"image",
        \\      "content":"{\"image_key\":\"img_abc123\"}"
        \\    }
        \\  }
        \\}
    ;

    const msg = try parseReceiveV1(arena.allocator(), json);

    try std.testing.expectEqualStrings("ev-003", msg.event_id);
    try std.testing.expectEqualStrings("om_msg003", msg.message_id);
    try std.testing.expectEqualStrings("oc_chat002", msg.chat_id);
    try std.testing.expectEqualStrings("ou_carol", msg.sender_open_id);
    try std.testing.expectEqual(types.ChatType.p2p, msg.chat_type);
    try std.testing.expectEqualStrings("image", msg.message_type);
    // 非 text 类型，text 应为空。
    try std.testing.expectEqualStrings("", msg.text);
}
