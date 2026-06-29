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

// eventType 辅助结构：只读 header.event_type，避免完整解析
const EventTypeHeader = struct {
    event_type: []const u8 = "",
};
const EventTypeEnv = struct {
    header: EventTypeHeader = .{},
};

/// 峰值取 payload 的 header.event_type；失败/缺失返回 null。
/// 供 onEvent 分派前判断 event 类型，避免对 card.action.trigger 误走 parseReceiveV1。
pub fn eventType(arena: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    const env = std.json.parseFromSliceLeaky(EventTypeEnv, arena, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    if (env.header.event_type.len == 0) return null;
    return env.header.event_type;
}

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
// card.action.trigger 解析
// ---------------------------------------------------------------------------

/// card.action.trigger 点击事件解析结果。
/// 所有 []const u8 字段借用 arena，生命周期由调用方负责。
pub const CardAction = struct {
    act: []const u8, // "stop" | "approval" | "question"
    decision: []const u8 = "", // approval: "approve" | "reject"
    option: i64 = -1, // question: 0-based index; -1 for non-question
    open_id: []const u8 = "", // 点击者 open_id
    message_id: []const u8 = "", // event.context.open_message_id
    chat_id: []const u8 = "", // event.context.open_chat_id
};

/// 解析 card.action.trigger 事件 payload → CardAction。
/// event.action.value 是 JSON 对象，直接读字段，无需二次解析。
/// act 缺失或结构不合法 → error.FeishuCardActionMalformed。
pub fn parseCardAction(arena: std.mem.Allocator, payload: []const u8) !CardAction {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    // 路径: event.action.value (是对象)
    const event_obj = switch (root) {
        .object => |o| o.get("event") orelse return error.FeishuCardActionMalformed,
        else => return error.FeishuCardActionMalformed,
    };
    const action_obj = switch (event_obj) {
        .object => |o| o.get("action") orelse return error.FeishuCardActionMalformed,
        else => return error.FeishuCardActionMalformed,
    };
    const value_obj = switch (action_obj) {
        .object => |o| o.get("value") orelse return error.FeishuCardActionMalformed,
        else => return error.FeishuCardActionMalformed,
    };
    const value_map = switch (value_obj) {
        .object => |o| o,
        else => return error.FeishuCardActionMalformed,
    };

    // act 必需
    const act = switch (value_map.get("act") orelse return error.FeishuCardActionMalformed) {
        .string => |s| s,
        else => return error.FeishuCardActionMalformed,
    };

    // decision 可选
    const decision: []const u8 = if (value_map.get("decision")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    // option 可选，JSON number → i64
    const option: i64 = if (value_map.get("option")) |v| switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => -1,
    } else -1;

    // event.operator.open_id
    const open_id: []const u8 = blk: {
        const op = switch (event_obj) {
            .object => |o| o.get("operator") orelse break :blk "",
            else => break :blk "",
        };
        break :blk switch (op) {
            .object => |o| if (o.get("open_id")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "",
            else => "",
        };
    };

    // event.context.open_message_id / open_chat_id
    var message_id: []const u8 = "";
    var chat_id: []const u8 = "";
    if (switch (event_obj) {
        .object => |o| o.get("context"),
        else => null,
    }) |ctx| {
        if (switch (ctx) {
            .object => |o| o,
            else => null,
        }) |ctx_map| {
            if (ctx_map.get("open_message_id")) |v| {
                if (v == .string) message_id = v.string;
            }
            if (ctx_map.get("open_chat_id")) |v| {
                if (v == .string) chat_id = v.string;
            }
        }
    }

    return .{
        .act = act,
        .decision = decision,
        .option = option,
        .open_id = open_id,
        .message_id = message_id,
        .chat_id = chat_id,
    };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

// TODO(M2.E2E): 捕获 fixtures/02_event_data_frame.bin 后，在此补一条
// "pbbp2.decode 真帧 → parseReceiveV1" 的端到端断言。

// ---------------------------------------------------------------------------
// eventType 测试
// ---------------------------------------------------------------------------

test "eventType: card.action.trigger payload" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const et = eventType(arena.allocator(), card_stop_payload);
    try std.testing.expect(et != null);
    try std.testing.expectEqualStrings("card.action.trigger", et.?);
}

test "eventType: im.message.receive_v1 payload" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0","header":{"event_id":"ev-001","event_type":"im.message.receive_v1"},"event":{}}
    ;
    const et = eventType(arena.allocator(), payload);
    try std.testing.expect(et != null);
    try std.testing.expectEqualStrings("im.message.receive_v1", et.?);
}

test "eventType: malformed JSON → null" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const et = eventType(arena.allocator(), "not json at all");
    try std.testing.expect(et == null);
}

test "eventType: missing event_type field → null" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const et = eventType(arena.allocator(), "{\"schema\":\"2.0\",\"header\":{\"event_id\":\"ev-x\"}}");
    try std.testing.expect(et == null);
}

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

// ---------------------------------------------------------------------------
// parseCardAction 测试（§9 真实 payload 形状，脱敏 id）
// ---------------------------------------------------------------------------

const card_stop_payload =
    \\{"schema":"2.0",
    \\ "header":{"event_id":"ev-c1","event_type":"card.action.trigger","tenant_key":"tk_test","app_id":"cli_test"},
    \\ "event":{
    \\   "operator":{"open_id":"ou_test","union_id":"on_test"},
    \\   "token":"c-token",
    \\   "action":{"value":{"act":"stop"},"tag":"button"},
    \\   "host":"im_message",
    \\   "context":{"open_message_id":"om_test","open_chat_id":"oc_test"}}}
;

test "parseCardAction: stop" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const ca = try parseCardAction(arena.allocator(), card_stop_payload);
    try std.testing.expectEqualStrings("stop", ca.act);
    try std.testing.expectEqualStrings("", ca.decision);
    try std.testing.expectEqual(@as(i64, -1), ca.option);
    try std.testing.expectEqualStrings("ou_test", ca.open_id);
    try std.testing.expectEqualStrings("om_test", ca.message_id);
    try std.testing.expectEqualStrings("oc_test", ca.chat_id);
}

test "parseCardAction: approval approve" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0",
        \\ "header":{"event_id":"ev-c2","event_type":"card.action.trigger"},
        \\ "event":{
        \\   "operator":{"open_id":"ou_test"},
        \\   "action":{"value":{"act":"approval","decision":"approve"},"tag":"button"},
        \\   "context":{"open_message_id":"om_test","open_chat_id":"oc_test"}}}
    ;
    const ca = try parseCardAction(arena.allocator(), payload);
    try std.testing.expectEqualStrings("approval", ca.act);
    try std.testing.expectEqualStrings("approve", ca.decision);
    try std.testing.expectEqual(@as(i64, -1), ca.option);
}

test "parseCardAction: approval reject" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0",
        \\ "header":{"event_id":"ev-c3","event_type":"card.action.trigger"},
        \\ "event":{
        \\   "operator":{"open_id":"ou_test"},
        \\   "action":{"value":{"act":"approval","decision":"reject"},"tag":"button"},
        \\   "context":{"open_message_id":"om_test","open_chat_id":"oc_test"}}}
    ;
    const ca = try parseCardAction(arena.allocator(), payload);
    try std.testing.expectEqualStrings("approval", ca.act);
    try std.testing.expectEqualStrings("reject", ca.decision);
}

test "parseCardAction: question option 2" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0",
        \\ "header":{"event_id":"ev-c4","event_type":"card.action.trigger"},
        \\ "event":{
        \\   "operator":{"open_id":"ou_test"},
        \\   "action":{"value":{"act":"question","option":2},"tag":"button"},
        \\   "context":{"open_message_id":"om_test","open_chat_id":"oc_test"}}}
    ;
    const ca = try parseCardAction(arena.allocator(), payload);
    try std.testing.expectEqualStrings("question", ca.act);
    try std.testing.expectEqualStrings("", ca.decision);
    try std.testing.expectEqual(@as(i64, 2), ca.option);
}

test "parseCardAction: malformed — no event key" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const result = parseCardAction(arena.allocator(), "{\"schema\":\"2.0\",\"header\":{}}");
    try std.testing.expectError(error.FeishuCardActionMalformed, result);
}

test "parseCardAction: malformed — no action key" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0","event":{"operator":{"open_id":"ou_test"},"context":{}}}
    ;
    const result = parseCardAction(arena.allocator(), payload);
    try std.testing.expectError(error.FeishuCardActionMalformed, result);
}

test "parseCardAction: malformed — no value key" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0","event":{"operator":{},"action":{"tag":"button"},"context":{}}}
    ;
    const result = parseCardAction(arena.allocator(), payload);
    try std.testing.expectError(error.FeishuCardActionMalformed, result);
}

test "parseCardAction: malformed — value without act" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const payload =
        \\{"schema":"2.0","event":{"operator":{},"action":{"value":{"decision":"approve"},"tag":"button"},"context":{}}}
    ;
    const result = parseCardAction(arena.allocator(), payload);
    try std.testing.expectError(error.FeishuCardActionMalformed, result);
}
