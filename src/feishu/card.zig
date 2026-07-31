//! 飞书 CardKit 流式卡片 JSON 2.0 构造 — 纯函数，无网络，无 I/O。
//! 上游文档: docs/superpowers/specs/feishu-longconn-protocol-notes.md §8 §9

const std = @import("std");

/// 流式进度元素 ID，与 PUT .../elements/:element_id/content 保持一致。
pub const PROGRESS_ELEMENT_ID: []const u8 = "md";

/// 构造 CardKit 流式卡片 JSON 2.0 字符串（含停止按钮）。
/// 返回形如:
///   {"schema":"2.0","config":{"streaming_mode":true},"body":{"elements":[
///     {"tag":"markdown","element_id":"md","content":"<initial_md>"},
///     {"tag":"button","text":{"tag":"plain_text","content":"⏹ 停止"},"type":"danger",
///      "behaviors":[{"type":"callback","value":{"act":"stop"}}]}
///   ]}}
/// Caller 拥有返回值，用同一 alloc 释放。
pub fn buildStreamingCard(alloc: std.mem.Allocator, initial_md: []const u8) ![]u8 {
    const content_json = try std.json.Stringify.valueAlloc(alloc, initial_md, .{});
    defer alloc.free(content_json);

    // ponytail: hand-concat static structure; only `content` (initial_md) is variable.
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema\":\"2.0\",\"config\":{{\"streaming_mode\":true}},\"body\":{{\"elements\":[" ++
            "{{\"tag\":\"markdown\",\"element_id\":\"{s}\",\"content\":{s}}}," ++
            "{{\"tag\":\"button\",\"text\":{{\"tag\":\"plain_text\",\"content\":\"⏹ 停止\"}}," ++
            "\"type\":\"danger\",\"behaviors\":[{{\"type\":\"callback\",\"value\":{{\"act\":\"stop\"}}}}]}}" ++
            "]}}}}",
        .{ PROGRESS_ELEMENT_ID, content_json },
    );
}

/// 构造审批卡片：描述 markdown + 批准/拒绝两个按钮。
/// value: {"act":"approval","decision":"approve"} / {"act":"approval","decision":"reject"}
pub fn buildApprovalCard(alloc: std.mem.Allocator, desc: []const u8) ![]u8 {
    const desc_json = try std.json.Stringify.valueAlloc(alloc, desc, .{});
    defer alloc.free(desc_json);

    return std.fmt.allocPrint(
        alloc,
        "{{\"schema\":\"2.0\",\"body\":{{\"elements\":[" ++
            "{{\"tag\":\"markdown\",\"content\":{s}}}," ++
            "{{\"tag\":\"button\",\"text\":{{\"tag\":\"plain_text\",\"content\":\"✅ 批准\"}}," ++
            "\"type\":\"primary\",\"behaviors\":[{{\"type\":\"callback\",\"value\":{{\"act\":\"approval\",\"decision\":\"approve\"}}}}]}}," ++
            "{{\"tag\":\"button\",\"text\":{{\"tag\":\"plain_text\",\"content\":\"❌ 拒绝\"}}," ++
            "\"type\":\"danger\",\"behaviors\":[{{\"type\":\"callback\",\"value\":{{\"act\":\"approval\",\"decision\":\"reject\"}}}}]}}" ++
            "]}}}}",
        .{desc_json},
    );
}

/// 构造问题卡片：question markdown + 每个 option 一个按钮。
/// value: {"act":"question","option":N}  N=0 起的下标。
pub fn buildQuestionCard(alloc: std.mem.Allocator, question: []const u8, options: []const []const u8) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(alloc);

    const q_json = try std.json.Stringify.valueAlloc(alloc, question, .{});
    defer alloc.free(q_json);

    try buf.appendSlice(alloc, "{\"schema\":\"2.0\",\"body\":{\"elements\":[");
    try buf.writer(alloc).print("{{\"tag\":\"markdown\",\"content\":{s}}}", .{q_json});

    for (options, 0..) |opt, i| {
        const opt_json = try std.json.Stringify.valueAlloc(alloc, opt, .{});
        defer alloc.free(opt_json);

        try buf.writer(alloc).print(
            ",{{\"tag\":\"button\",\"text\":{{\"tag\":\"plain_text\",\"content\":{s}}}," ++
                "\"type\":\"default\",\"behaviors\":[{{\"type\":\"callback\",\"value\":{{\"act\":\"question\",\"option\":{d}}}}}]}}",
            .{ opt_json, i },
        );
    }

    try buf.appendSlice(alloc, "]}}");
    return buf.toOwnedSlice(alloc);
}

/// 构造已处理态卡片：纯 markdown，无按钮，无 streaming_mode。
/// 用于 "⏹ 已停止"、"✅ 已批准"、"已选: 选项B" 等。
pub fn buildResolvedCard(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const text_json = try std.json.Stringify.valueAlloc(alloc, text, .{});
    defer alloc.free(text_json);

    return std.fmt.allocPrint(
        alloc,
        "{{\"schema\":\"2.0\",\"body\":{{\"elements\":[{{\"tag\":\"markdown\",\"content\":{s}}}]}}}}",
        .{text_json},
    );
}

/// 构造卡片回调响应 payload。
/// toast: toast 显示文字（会被 JSON 转义）。
/// card_json: 可选，已是 JSON 文本的卡片字符串，原样嵌入为 "card" 字段值（不再转义）。
/// 结果: {"toast":{"type":"success","content":<toast>}} 或加 ,"card":<card_json>
pub fn buildCallbackResponse(alloc: std.mem.Allocator, toast: []const u8, card_json: ?[]const u8) ![]u8 {
    const toast_json = try std.json.Stringify.valueAlloc(alloc, toast, .{});
    defer alloc.free(toast_json);

    if (card_json) |cj| {
        // card_json 已是合法 JSON，直接嵌入（不转义）。
        return std.fmt.allocPrint(
            alloc,
            "{{\"toast\":{{\"type\":\"success\",\"content\":{s}}},\"card\":{s}}}",
            .{ toast_json, cj },
        );
    } else {
        return std.fmt.allocPrint(
            alloc,
            "{{\"toast\":{{\"type\":\"success\",\"content\":{s}}}}}",
            .{toast_json},
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildStreamingCard: basic — valid JSON + required fields + stop button" {
    const alloc = std.testing.allocator;
    const card = try buildStreamingCard(alloc, "处理中…");
    defer alloc.free(card);

    // 必须含固定字段
    try std.testing.expect(std.mem.indexOf(u8, card, "\"element_id\":\"md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"tag\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"streaming_mode\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "处理中") != null);
    // 停止按钮
    try std.testing.expect(std.mem.indexOf(u8, card, "\"act\":\"stop\"") != null);

    // 必须是合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, card, .{});
    defer parsed.deinit();
}

test "buildStreamingCard: escaping — quotes and newline survive round-trip" {
    const alloc = std.testing.allocator;
    const raw = "say \"hi\"\nnext";
    const card = try buildStreamingCard(alloc, raw);
    defer alloc.free(card);

    // 解析为 JSON Value，然后走到 content 字段验证原始字符串完整保留
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, card, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const body = root.get("body") orelse return error.MissingBody;
    const elements = body.object.get("elements") orelse return error.MissingElements;
    const elem = elements.array.items[0];
    const content = elem.object.get("content") orelse return error.MissingContent;
    try std.testing.expectEqualStrings(raw, content.string);
}

test "buildApprovalCard: valid JSON + two buttons + desc round-trip" {
    const alloc = std.testing.allocator;
    const desc = "请审批该操作\n含\"引号\"";
    const card = try buildApprovalCard(alloc, desc);
    defer alloc.free(card);

    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, card, .{});
    defer parsed.deinit();

    // 两个按钮的 value 必须含 act:approval + decision
    try std.testing.expect(std.mem.indexOf(u8, card, "\"act\":\"approval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"decision\":\"approve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"decision\":\"reject\"") != null);

    // desc 原文在 JSON 的 markdown content 里能 round-trip
    const body = parsed.value.object.get("body") orelse return error.MissingBody;
    const elements = body.object.get("elements") orelse return error.MissingElements;
    const md_elem = elements.array.items[0];
    const content = md_elem.object.get("content") orelse return error.MissingContent;
    try std.testing.expectEqualStrings(desc, content.string);
}

test "buildQuestionCard: valid JSON + three buttons with option indices" {
    const alloc = std.testing.allocator;
    const options = [_][]const u8{ "选项A", "选项B", "选项C" };
    const card = try buildQuestionCard(alloc, "请选择一项", &options);
    defer alloc.free(card);

    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, card, .{});
    defer parsed.deinit();

    // 三个 option 下标
    try std.testing.expect(std.mem.indexOf(u8, card, "\"option\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"option\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"option\":2") != null);
    // act
    try std.testing.expect(std.mem.indexOf(u8, card, "\"act\":\"question\"") != null);
    // 各 option 文本
    try std.testing.expect(std.mem.indexOf(u8, card, "选项A") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "选项B") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "选项C") != null);
}

test "buildResolvedCard: valid JSON, no button, no streaming_mode" {
    const alloc = std.testing.allocator;
    const card = try buildResolvedCard(alloc, "⏹ 已停止");
    defer alloc.free(card);

    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, card, .{});
    defer parsed.deinit();

    // 无按钮元素
    try std.testing.expect(std.mem.indexOf(u8, card, "\"tag\":\"button\"") == null);
    // 无 streaming_mode
    try std.testing.expect(std.mem.indexOf(u8, card, "streaming_mode") == null);
    // 含文本
    try std.testing.expect(std.mem.indexOf(u8, card, "已停止") != null);
}

test "buildCallbackResponse: toast only" {
    const alloc = std.testing.allocator;
    const resp = try buildCallbackResponse(alloc, "已停止", null);
    defer alloc.free(resp);

    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    try std.testing.expect(std.mem.indexOf(u8, resp, "\"toast\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "已停止") != null);
    // 无 card 字段
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"card\"") == null);
}

test "buildCallbackResponse: toast + card_json embedded as raw JSON" {
    const alloc = std.testing.allocator;
    const some_card = "{\"schema\":\"2.0\",\"body\":{\"elements\":[]}}";
    const resp = try buildCallbackResponse(alloc, "已批准", some_card);
    defer alloc.free(resp);

    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    // card 字段是嵌入的对象，parse 后能取到
    const card_val = parsed.value.object.get("card") orelse return error.MissingCard;
    // 确认是对象，含 schema 字段
    try std.testing.expectEqualStrings("2.0", card_val.object.get("schema").?.string);
    // toast
    try std.testing.expect(std.mem.indexOf(u8, resp, "已批准") != null);
}

test "buildCallbackResponse: toast with special chars escaped" {
    const alloc = std.testing.allocator;
    const resp = try buildCallbackResponse(alloc, "含\"引号\"和\n换行", null);
    defer alloc.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const toast = parsed.value.object.get("toast") orelse return error.MissingToast;
    const content = toast.object.get("content") orelse return error.MissingContent;
    try std.testing.expectEqualStrings("含\"引号\"和\n换行", content.string);
}
