//! Pure formatters for the WeChat /list and /switch replies. No IO, no GUI —
//! unit-tested directly. Operates on control.Conversation values produced by
//! the Control vtable.
const std = @import("std");
const control = @import("control.zig");
const Conversation = control.Conversation;

/// Append a formatted segment to an unmanaged byte list.
fn appendFmt(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Return the last `max_lines` lines of `s`, further clipped to at most
/// `max_bytes` bytes kept from the end (never splitting a UTF-8 sequence).
/// Trailing blank lines are trimmed first. The result borrows from `s`.
pub fn tailLines(s: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
    const trimmed = std.mem.trimRight(u8, s, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    var start: usize = trimmed.len;
    var seen: usize = 0;
    var i: usize = trimmed.len;
    while (i > 0) : (i -= 1) {
        if (trimmed[i - 1] == '\n') {
            seen += 1;
            if (seen == max_lines) break;
        }
        start = i - 1;
    }
    var tail = trimmed[start..];
    if (tail.len > max_bytes) {
        var b = tail.len - max_bytes;
        while (b < tail.len and (tail[b] & 0xC0) == 0x80) : (b += 1) {}
        tail = tail[b..];
    }
    return tail;
}

/// Render the /list reply into `buf`.
pub fn writeList(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    convs: []const Conversation,
) !void {
    if (convs.len == 0) {
        try buf.appendSlice(allocator, "当前没有副驾会话，发送任意消息可自动打开。");
        return;
    }
    try appendFmt(buf, allocator, "副驾会话（共 {d} 个）：\n", .{convs.len});
    var any_current = false;
    for (convs, 0..) |c, idx| {
        if (c.is_current) any_current = true;
        const marker: []const u8 = if (c.is_current) "➤ " else "  ";
        const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
        const state: []const u8 = if (c.busy) "忙" else "闲";
        try appendFmt(buf, allocator, "{d}. {s}{s}{s}  [{s}]  {s}\n", .{
            idx + 1, marker, c.title(), tag, c.model(), state,
        });
    }
    if (!any_current) {
        try buf.appendSlice(allocator, "（当前默认：发送消息将新建副驾会话）\n");
    }
    try buf.appendSlice(allocator, "发送 /switch <编号> 切换；微信将固定到所选会话。");
}

/// Render the post-switch digest into `buf`. `idx1` is the 1-based number the
/// user selected; `tail` is a short transcript excerpt (may be empty).
pub fn writeDigest(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    idx1: usize,
    c: Conversation,
    tail: []const u8,
) !void {
    const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
    const state: []const u8 = if (c.busy) "忙" else "闲";
    try appendFmt(buf, allocator, "已切换到会话 {d}：{s}{s}\n模型：{s}\n", .{
        idx1, c.title(), tag, c.model(),
    });
    if (c.cwd().len != 0) try appendFmt(buf, allocator, "目录：{s}\n", .{c.cwd()});
    try appendFmt(buf, allocator, "状态：{s}\n", .{state});
    if (tail.len != 0) try appendFmt(buf, allocator, "最近：\n{s}\n", .{tail});
    try buf.appendSlice(allocator, "（已固定，后续消息将发送到此会话。本摘要仅供参考，未作为对话上下文。）");
}

const t = std.testing;

test "tailLines keeps the last N lines" {
    try t.expectEqualStrings("c\nd", tailLines("a\nb\nc\nd", 2, 100));
    try t.expectEqualStrings("hello", tailLines("hello", 5, 100));
    try t.expectEqualStrings("x", tailLines("x\n\n\n", 3, 100));
}

test "tailLines clips bytes on a UTF-8 boundary" {
    // 4 CJK chars (3 bytes each = 12 bytes); a 7-byte budget must back off to
    // the last 2 whole chars (6 bytes), never a partial char.
    const out = tailLines("你好世界", 5, 7);
    try t.expect(out.len <= 7);
    try t.expect(std.unicode.utf8ValidateSlice(out));
    try t.expectEqualStrings("世界", out);
}

test "writeList renders count, current marker, copilot tag, busy state" {
    var c0: Conversation = .{};
    c0.setTitle("Claude");
    c0.setModel("glm-5.2");
    c0.is_current = true;
    var c1: Conversation = .{};
    c1.setTitle("zsh ~/p");
    c1.setModel("opus");
    c1.is_copilot = true;
    c1.busy = true;
    const convs = [_]Conversation{ c0, c1 };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &convs);
    const s = buf.items;
    try t.expect(std.mem.indexOf(u8, s, "共 2 个") != null);
    try t.expect(std.mem.indexOf(u8, s, "➤") != null);
    try t.expect(std.mem.indexOf(u8, s, "· 副驾") != null);
    try t.expect(std.mem.indexOf(u8, s, "忙") != null);
    try t.expect(std.mem.indexOf(u8, s, "闲") != null);
}

test "writeList empty" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &.{});
    try t.expect(std.mem.indexOf(u8, buf.items, "没有副驾会话") != null);
}

test "writeList notes default when nothing is current" {
    var c0: Conversation = .{};
    c0.setTitle("only-copilot");
    c0.is_copilot = true;
    const convs = [_]Conversation{c0};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &convs);
    try t.expect(std.mem.indexOf(u8, buf.items, "将新建副驾会话") != null);
}

test "writeDigest includes title, model, footer; cwd/tail optional" {
    var c: Conversation = .{};
    c.setTitle("B");
    c.setModel("m2");
    c.setCwd("/home/x/p");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeDigest(&buf, t.allocator, 2, c, "last line");
    const s = buf.items;
    try t.expect(std.mem.indexOf(u8, s, "已切换到会话 2：B") != null);
    try t.expect(std.mem.indexOf(u8, s, "模型：m2") != null);
    try t.expect(std.mem.indexOf(u8, s, "目录：/home/x/p") != null);
    try t.expect(std.mem.indexOf(u8, s, "最近：\nlast line") != null);
    try t.expect(std.mem.indexOf(u8, s, "未作为对话上下文") != null);
}
