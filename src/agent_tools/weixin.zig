//! Weixin agent tool adapters.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const ai_agent_access = @import("../agent/access.zig");
const weixin_types = @import("../weixin/types.zig");
const tool_access = @import("access.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

pub fn sendAttachment(
    ctx: *ToolContext,
    kind: weixin_types.AttachmentKind,
    path: []const u8,
    display_name: []const u8,
) ![]u8 {
    const wx_ctx = ctx.weixin_reply_context orelse {
        return ctx.allocator.dupe(u8, "No active Weixin reply context; cannot send attachment.");
    };
    // Sending an attachment reads the file off disk and uploads it to a remote
    // user, so a protected path here is an exfiltration risk. In auto mode,
    // protected paths still require approval; full mode intentionally bypasses
    // this guard.
    if (ctx.settings.access_rules) |rules| {
        if (ai_agent_access.isPathDenied(ctx.allocator, rules, path, null)) {
            const gate = tool_access.Gate{ .dangerous = false, .blacklisted = true, .force = true, .skip = false, .matched = path };
            if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
                const bl_reason = tool_access.allocBlacklistReason(ctx.allocator, path);
                defer if (bl_reason) |r| ctx.allocator.free(r);
                const reason = bl_reason orelse "Sends a protected file - confirm to allow";
                if (!ctx.requestApproval("weixin_send_attachment", path, reason)) {
                    return tool_output.deniedResult(ctx.allocator, path, "operator rejected sending a protected file");
                }
            }
        }
    }
    wx_ctx.sender.sendAttachment(kind, path, display_name, wx_ctx.to_user_id, wx_ctx.context_token) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to send {s} to Weixin: {}", .{ kind.name(), err });
    };
    const shown = if (display_name.len != 0) display_name else std.fs.path.basename(path);
    return std.fmt.allocPrint(ctx.allocator, "Sent {s} to Weixin: {s}", .{ kind.name(), shown });
}

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const AttachmentCapture = struct {
    called: bool = false,
    kind: weixin_types.AttachmentKind = .file,
    path: []const u8 = "",
    display_name: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    path_buf: [512]u8 = undefined,
    display_name_buf: [256]u8 = undefined,
    to_user_id_buf: [256]u8 = undefined,
    context_token_buf: [256]u8 = undefined,

    fn copyField(buf: []u8, value: []const u8) []const u8 {
        const n = @min(buf.len, value.len);
        @memcpy(buf[0..n], value[0..n]);
        return buf[0..n];
    }

    fn send(
        ctx: *anyopaque,
        kind: weixin_types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *AttachmentCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.kind = kind;
        self.path = copyField(&self.path_buf, path);
        self.display_name = copyField(&self.display_name_buf, display_name);
        self.to_user_id = copyField(&self.to_user_id_buf, to_user_id);
        self.context_token = copyField(&self.context_token_buf, context_token);
    }
};

fn testSender(capture: *AttachmentCapture) weixin_types.AttachmentSender {
    return .{ .ctx = capture, .send_attachment = AttachmentCapture.send };
}

test "sendAttachment without reply context returns a clear tool result" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .weixin_reply_context = null,
    };

    const result = try sendAttachment(&ctx, .image, "C:\\tmp\\plot.png", "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No active Weixin reply context; cannot send attachment.", result);
}

test "sendAttachment calls the active Weixin sender" {
    const allocator = std.testing.allocator;
    var capture = AttachmentCapture{};
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .weixin_reply_context = try types.WeixinReplyContext.init(allocator, .{
            .sender = testSender(&capture),
            .to_user_id = "wx-user",
            .context_token = "ctx-1",
        }),
    };
    defer if (ctx.weixin_reply_context) |*wx| wx.deinit(allocator);

    const result = try sendAttachment(&ctx, .file, "C:\\tmp\\report.pdf", "report.pdf");
    defer allocator.free(result);

    try std.testing.expect(capture.called);
    try std.testing.expectEqual(weixin_types.AttachmentKind.file, capture.kind);
    try std.testing.expectEqualStrings("C:\\tmp\\report.pdf", capture.path);
    try std.testing.expectEqualStrings("report.pdf", capture.display_name);
    try std.testing.expectEqualStrings("wx-user", capture.to_user_id);
    try std.testing.expectEqualStrings("ctx-1", capture.context_token);
    try std.testing.expectEqualStrings("Sent file to Weixin: report.pdf", result);
}
