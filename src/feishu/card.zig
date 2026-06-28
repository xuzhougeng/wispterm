//! 飞书 CardKit 流式卡片 JSON 2.0 构造 — 纯函数，无网络，无 I/O。
//! 上游文档: docs/superpowers/specs/feishu-longconn-protocol-notes.md §8

const std = @import("std");

/// 流式进度元素 ID，与 PUT .../elements/:element_id/content 保持一致。
pub const PROGRESS_ELEMENT_ID: []const u8 = "md";

/// 构造 CardKit 流式卡片 JSON 2.0 字符串。
/// 返回形如:
///   {"schema":"2.0","config":{"streaming_mode":true},"body":{"elements":[{"tag":"markdown","element_id":"md","content":"<initial_md>"}]}}
/// Caller 拥有返回值，用同一 alloc 释放。
/// initial_md 内的引号/换行等字符由 std.json.Stringify.valueAlloc 正确转义。
pub fn buildStreamingCard(alloc: std.mem.Allocator, initial_md: []const u8) ![]u8 {
    // 把 initial_md 序列化为 JSON 字符串字面量（带外层引号+转义），然后直接嵌入模板。
    const content_json = try std.json.Stringify.valueAlloc(alloc, initial_md, .{});
    defer alloc.free(content_json);

    return std.fmt.allocPrint(
        alloc,
        // ponytail: hand-concat; only `content` needs escaping, rest is static literals.
        "{{\"schema\":\"2.0\",\"config\":{{\"streaming_mode\":true}},\"body\":{{\"elements\":[{{\"tag\":\"markdown\",\"element_id\":\"{s}\",\"content\":{s}}}]}}}}",
        .{ PROGRESS_ELEMENT_ID, content_json },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildStreamingCard: basic — valid JSON + required fields" {
    const alloc = std.testing.allocator;
    const card = try buildStreamingCard(alloc, "处理中…");
    defer alloc.free(card);

    // 必须含固定字段
    try std.testing.expect(std.mem.indexOf(u8, card, "\"element_id\":\"md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"tag\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "\"streaming_mode\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, card, "处理中") != null);

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
