//! WeChat command routing into the local WispTerm surfaces. Port of agent.ts,
//! minus /sessions and /use (one local app).
const std = @import("std");
const control = @import("control.zig");
const types = @import("types.zig");

const AI_ACK = "信息已收到，开始处理。\n发送 /stop 可停止本次处理。";
const ESC = "\x1b";
const AI_OPEN_TIMEOUT_MS: u32 = 2000;

pub const Reply = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8) = .empty,
    /// true ⇒ caller should start AI-reply progress streaming.
    expect_ai_progress: bool = false,
    /// true ⇒ caller should cancel any active AI-reply progress streaming
    /// (set by /stop), so no further progress/final replies are sent.
    stop_followup: bool = false,

    pub fn init(allocator: std.mem.Allocator) Reply {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Reply) void {
        self.text.deinit(self.allocator);
    }
    fn set(self: *Reply, s: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, s);
    }
};

pub fn defaultSettings() types.Settings {
    return .{};
}

/// Returns the command token (including leading '/') and the trimmed argument.
fn splitCommand(text: []const u8) struct { cmd: []const u8, arg: []const u8 } {
    if (text.len == 0 or text[0] != '/') return .{ .cmd = "", .arg = text };
    const sp = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    return .{ .cmd = text[0..sp], .arg = std.mem.trim(u8, text[sp..], " \t\r\n") };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isPing(text: []const u8) bool {
    const n = std.mem.trim(u8, text, " \t\r\n");
    return eqIgnoreCase(n, "ping") or eqIgnoreCase(n, "/ping");
}

pub fn route(
    allocator: std.mem.Allocator,
    ctrl: control.Control,
    settings: types.Settings,
    raw_text: []const u8,
    reply_context: ?types.ReplyContext,
    out: *Reply,
) !void {
    _ = allocator;
    _ = settings;
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (text.len == 0) return;
    if (isPing(text)) return out.set("pong");

    const parts = splitCommand(text);
    const cmd = parts.cmd;

    if (eqIgnoreCase(cmd, "/help")) return out.set(helpTextConst);
    if (eqIgnoreCase(cmd, "/status")) return out.set(statusText(ctrl));
    if (cmd.len != 0 and !eqIgnoreCase(cmd, "/term") and !eqIgnoreCase(cmd, "/keys") and
        !eqIgnoreCase(cmd, "/ai") and !eqIgnoreCase(cmd, "/stop"))
    {
        return out.set("未知命令。\n\n" ++ helpTextConst);
    }
    if (cmd.len != 0 and !eqIgnoreCase(cmd, "/stop") and parts.arg.len == 0) {
        return out.set(usageText(cmd));
    }

    if (!ctrl.isConnected()) return out.set("WispTerm 当前离线，无法处理。");

    if (eqIgnoreCase(cmd, "/stop")) return stopAi(ctrl, out);
    if (eqIgnoreCase(cmd, "/term")) return sendTerminal(ctrl, parts.arg, true, out);
    if (eqIgnoreCase(cmd, "/keys")) return sendTerminal(ctrl, parts.arg, false, out);
    if (eqIgnoreCase(cmd, "/ai")) return sendAi(ctrl, parts.arg, reply_context, out);
    return sendAi(ctrl, text, reply_context, out);
}

fn sendAi(ctrl: control.Control, text: []const u8, reply_context: ?types.ReplyContext, out: *Reply) !void {
    const ai = ctrl.findAiSurface() orelse blk: {
        switch (ctrl.openAiAgent(AI_OPEN_TIMEOUT_MS)) {
            .no_profile => return out.set("WispTerm 尚未配置副驾。"),
            .failed => return out.set("WispTerm 无法打开副驾。"),
            .offline => return out.set("WispTerm 当前离线，无法打开副驾。"),
            .timeout => return out.set("已请求打开副驾，但未等到副驾标签页。"),
            .opened => {},
        }
        break :blk ctrl.findAiSurface() orelse return out.set("已请求打开副驾，但未等到副驾标签页。");
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(out.allocator);
    try buf.appendSlice(out.allocator, text);
    try buf.append(out.allocator, '\r');
    if (!ctrl.sendInput(ai.id, buf.items, reply_context)) return out.set("WispTerm 当前离线，无法发送给副驾。");
    try out.set(AI_ACK);
    out.expect_ai_progress = true;
}

fn stopAi(ctrl: control.Control, out: *Reply) !void {
    // /stop halts the active AI run; also tell the poller to cancel any
    // in-flight weixin reply streaming so no further progress/final reply is
    // sent after the stop (otherwise a trailing reply looks like /stop failed).
    out.stop_followup = true;
    const ai = ctrl.findAiSurface() orelse return out.set("当前没有副驾可停止。");
    if (!ctrl.sendInput(ai.id, ESC, null)) return out.set("WispTerm 当前离线，无法停止副驾。");
    return out.set("已发送停止指令。");
}

fn sendTerminal(ctrl: control.Control, text: []const u8, enter: bool, out: *Reply) !void {
    const term = ctrl.findTerminalSurface() orelse return out.set("当前没有可写终端 surface。");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(out.allocator);
    try buf.appendSlice(out.allocator, text);
    if (enter) try buf.append(out.allocator, '\r');
    if (!ctrl.sendInput(term.id, buf.items, null)) return out.set("WispTerm 当前离线，无法发送到终端。");
    return out.set("已发送到终端。");
}

const helpTextConst =
    "WispTerm 微信直连命令：\n" ++
    "/ping 验证连接\n/status 查看状态\n/ai <内容> 发送给副驾\n" ++
    "/stop 停止当前 AI 处理\n/term <命令> 发送到终端并回车\n/keys <文本> 发送原始文本\n" ++
    "普通文本默认发送给副驾。";

fn statusText(ctrl: control.Control) []const u8 {
    return if (ctrl.isConnected()) "微信直连：在线" else "微信直连：离线";
}

fn usageText(cmd: []const u8) []const u8 {
    if (eqIgnoreCase(cmd, "/term")) return "用法：/term <命令>";
    if (eqIgnoreCase(cmd, "/keys")) return "用法：/keys <文本>";
    if (eqIgnoreCase(cmd, "/ai")) return "用法：/ai <内容>";
    return helpTextConst;
}

const t = std.testing;

const FakeControl = struct {
    connected: bool = true,
    has_ai: bool = true,
    buf: [256]u8 = undefined,
    len: usize = 0,
    last_surface: [16]u8 = [_]u8{0} ** 16,
    last_reply_context: ?types.ReplyContext = null,

    /// Bytes captured from the last send_input. send_input borrows its argument
    /// (production consumes it synchronously), so the fake copies for inspection.
    fn lastInput(self: *FakeControl) []const u8 {
        return self.buf[0..self.len];
    }

    fn is_connected(ctx: *anyopaque) bool {
        return cast(ctx).connected;
    }
    fn find_ai_surface(ctx: *anyopaque) ?control.Surface {
        return if (cast(ctx).has_ai) .{ .id = aiId(), .title = "Copilot" } else null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control.Surface {
        return .{ .id = termId(), .title = "zsh" };
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control.OpenResult {
        return .opened;
    }
    fn send_input(ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) bool {
        const self = cast(ctx);
        if (!self.connected) return false;
        self.last_surface = surface_id;
        self.last_reply_context = reply_context;
        const n = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..n], bytes[0..n]);
        self.len = n;
        return true;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    fn ai_approval_pending(_: *anyopaque) bool {
        return false;
    }
    fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
        return false;
    }
    fn cast(ctx: *anyopaque) *FakeControl {
        return @ptrCast(@alignCast(ctx));
    }
    fn aiId() [16]u8 {
        return "aichat0000000000".*;
    }
    fn termId() [16]u8 {
        return "term000000000000".*;
    }
    fn control_iface(self: *FakeControl) control.Control {
        return .{ .ctx = self, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
        } };
    }
};

test "ping returns pong without touching surfaces" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "ping", null, &out);
    try t.expectEqualStrings("pong", out.text.items);
    try t.expect(!out.expect_ai_progress);
}

test "default text goes to the AI surface with a carriage return" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "hello world", null, &out);
    try t.expectEqualStrings("hello world\r", fake.lastInput());
    try t.expectEqualSlices(u8, &FakeControl.aiId(), &fake.last_surface);
    try t.expect(out.expect_ai_progress);
}

test "default AI route forwards Weixin reply context only to AI surface" {
    const Sender = struct {
        fn sendAttachment(ctx: *anyopaque, kind: types.AttachmentKind, path: []const u8, display_name: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void {
            _ = ctx;
            _ = kind;
            _ = path;
            _ = display_name;
            _ = to_user_id;
            _ = context_token;
        }
    };

    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    const reply_ctx = types.ReplyContext{
        .sender = .{ .ctx = &fake, .send_attachment = Sender.sendAttachment },
        .to_user_id = "wx-user",
        .context_token = "ctx-1",
    };

    try route(t.allocator, fake.control_iface(), defaultSettings(), "make a chart", reply_ctx, &out);
    try t.expect(fake.last_reply_context != null);
    try t.expectEqualStrings("wx-user", fake.last_reply_context.?.to_user_id);
    try t.expectEqualStrings("ctx-1", fake.last_reply_context.?.context_token);
}

test "/term sends to terminal with enter, /keys without" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/term ls", null, &out);
    try t.expectEqualStrings("ls\r", fake.lastInput());

    var out2 = Reply.init(t.allocator);
    defer out2.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/keys abc", null, &out2);
    try t.expectEqualStrings("abc", fake.lastInput());
}

test "offline control yields an offline message and no progress" {
    var fake = FakeControl{ .connected = false };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "do a thing", null, &out);
    try t.expect(!out.expect_ai_progress);
    try t.expect(std.mem.indexOf(u8, out.text.items, "离线") != null);
}

test "/stop sends ESC to the AI surface and requests followup cancellation" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/stop", null, &out);
    try t.expectEqualStrings(ESC, fake.lastInput());
    try t.expect(out.stop_followup);
    try t.expect(!out.expect_ai_progress);
}
