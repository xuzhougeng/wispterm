//! WeChat command routing into the local WispTerm surfaces. Port of agent.ts,
//! including /list + /switch conversation switching (aliases /sessions, /ls, /use).
const std = @import("std");
const control = @import("control.zig");
const types = @import("types.zig");
const approval_reply = @import("approval_reply.zig");
const session_list = @import("session_list.zig");

const AI_ACK = "信息已收到，开始处理。\n发送 /stop 可停止本次处理。";
const AI_BUSY = "副驾正在处理上一条消息，请稍候再发，或发送 /stop 停止当前处理。";
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

fn isListCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/list") or eqIgnoreCase(cmd, "/sessions") or eqIgnoreCase(cmd, "/ls");
}

fn isSwitchCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/switch") or eqIgnoreCase(cmd, "/use");
}

fn isKnownCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/term") or eqIgnoreCase(cmd, "/keys") or
        eqIgnoreCase(cmd, "/ai") or eqIgnoreCase(cmd, "/stop") or
        isListCommand(cmd) or isSwitchCommand(cmd);
}

/// Commands that are valid with no argument.
fn isNoArgCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/stop") or isListCommand(cmd);
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
    if (eqIgnoreCase(cmd, "/status")) return statusReply(ctrl, out);
    if (cmd.len != 0 and !isKnownCommand(cmd)) {
        return out.set("未知命令。\n\n" ++ helpTextConst);
    }
    if (cmd.len != 0 and !isNoArgCommand(cmd) and parts.arg.len == 0) {
        return out.set(usageText(cmd));
    }

    if (!ctrl.isConnected()) return out.set("WispTerm 当前离线，无法处理。");

    if (eqIgnoreCase(cmd, "/stop")) return stopAi(ctrl, out);
    if (eqIgnoreCase(cmd, "/term")) return sendTerminal(ctrl, parts.arg, true, out);
    if (eqIgnoreCase(cmd, "/keys")) return sendTerminal(ctrl, parts.arg, false, out);
    if (isListCommand(cmd)) return listConversations(ctrl, out);
    if (isSwitchCommand(cmd)) return switchConversation(ctrl, parts.arg, out);
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

    // A pending approval turns this reply into the answer for it, not a new
    // prompt. resolveAiApproval's bool is discarded: we just checked pending
    // above, and a lost race (resolved locally in between) needs no different
    // reply. Both approve and deny keep streaming — denying a tool does not
    // abort the run, the copilot continues with the denial (use /stop to abort).
    if (ctrl.aiApprovalPending()) {
        switch (approval_reply.classify(text)) {
            .approve => {
                _ = ctrl.resolveAiApproval(true);
                try out.set("已确认，继续执行。");
                out.expect_ai_progress = true;
            },
            .deny => {
                _ = ctrl.resolveAiApproval(false);
                try out.set("已拒绝该操作。");
                out.expect_ai_progress = true;
            },
            .unrecognized => try out.set("当前有待确认操作，请先回复 Y 同意 / N 拒绝。"),
        }
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(out.allocator);
    try buf.appendSlice(out.allocator, text);
    try buf.append(out.allocator, '\r');
    switch (ctrl.sendInput(ai.id, buf.items, reply_context)) {
        .offline => return out.set("WispTerm 当前离线，无法发送给副驾。"),
        // The copilot still has a request inflight: the message was rejected,
        // not queued, so tell the user instead of acking "开始处理" for nothing.
        .busy => return out.set(AI_BUSY),
        .ok => {},
    }
    try out.set(AI_ACK);
    out.expect_ai_progress = true;
}

fn stopAi(ctrl: control.Control, out: *Reply) !void {
    // /stop halts the active AI run; also tell the poller to cancel any
    // in-flight weixin reply streaming so no further progress/final reply is
    // sent after the stop (otherwise a trailing reply looks like /stop failed).
    out.stop_followup = true;
    const ai = ctrl.findAiSurface() orelse return out.set("当前没有副驾可停止。");
    if (ctrl.sendInput(ai.id, ESC, null) != .ok) return out.set("WispTerm 当前离线，无法停止副驾。");
    return out.set("已发送停止指令。");
}

fn listConversations(ctrl: control.Control, out: *Reply) !void {
    var list: control.ConversationList = .{};
    ctrl.listAiConversations(&list);
    out.text.clearRetainingCapacity();
    try session_list.writeList(&out.text, out.allocator, list.slice());
}

fn switchConversation(ctrl: control.Control, arg: []const u8, out: *Reply) !void {
    const n = std.fmt.parseInt(usize, arg, 10) catch
        return out.set("无效的会话编号，请先 /list 查看。");
    if (n == 0) return out.set("无效的会话编号，请先 /list 查看。");

    var conv: control.Conversation = .{};
    if (!ctrl.pinAiConversationByIndex(n - 1, &conv))
        return out.set("无效的会话编号，请先 /list 查看。");

    // latestTranscript() now resolves to the just-pinned conversation; take a
    // short UTF-8-safe tail for the digest (borrowed, used immediately).
    const tail = session_list.tailLines(ctrl.latestTranscript(), 6, 600);
    out.text.clearRetainingCapacity();
    try session_list.writeDigest(&out.text, out.allocator, n, conv, tail);
}

fn statusReply(ctrl: control.Control, out: *Reply) !void {
    if (!ctrl.isConnected()) return out.set("微信直连：离线");
    var list: control.ConversationList = .{};
    ctrl.listAiConversations(&list);
    for (list.slice()) |c| {
        if (!c.is_current) continue;
        const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
        const s = try std.fmt.allocPrint(out.allocator, "微信直连：在线\n当前会话：{s}{s}  [{s}]", .{ c.title(), tag, c.model() });
        defer out.allocator.free(s);
        return out.set(s);
    }
    return out.set("微信直连：在线\n当前会话：默认（发送消息将新建副驾会话）");
}

fn sendTerminal(ctrl: control.Control, text: []const u8, enter: bool, out: *Reply) !void {
    const term = ctrl.findTerminalSurface() orelse return out.set("当前没有可写终端 surface。");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(out.allocator);
    try buf.appendSlice(out.allocator, text);
    if (enter) try buf.append(out.allocator, '\r');
    if (ctrl.sendInput(term.id, buf.items, null) != .ok) return out.set("WispTerm 当前离线，无法发送到终端。");
    return out.set("已发送到终端。");
}

const helpTextConst =
    "WispTerm 微信直连命令：\n" ++
    "/ping 验证连接\n/status 查看状态\n/list 列出副驾会话\n" ++
    "/switch <编号> 切换并固定会话\n/ai <内容> 发送给副驾\n" ++
    "/stop 停止当前 AI 处理\n/term <命令> 发送到终端并回车\n/keys <文本> 发送原始文本\n" ++
    "普通文本默认发送给当前会话。";

fn usageText(cmd: []const u8) []const u8 {
    if (eqIgnoreCase(cmd, "/term")) return "用法：/term <命令>";
    if (eqIgnoreCase(cmd, "/keys")) return "用法：/keys <文本>";
    if (eqIgnoreCase(cmd, "/ai")) return "用法：/ai <内容>";
    if (isSwitchCommand(cmd)) return "用法：/switch <会话编号>";
    return helpTextConst;
}

const t = std.testing;

const FakeControl = struct {
    connected: bool = true,
    has_ai: bool = true,
    busy: bool = false,
    buf: [256]u8 = undefined,
    len: usize = 0,
    last_surface: [16]u8 = [_]u8{0} ** 16,
    last_reply_context: ?types.ReplyContext = null,
    approval_pending: bool = false,
    resolved_calls: u8 = 0,
    last_resolve_approve: bool = false,
    // Conversation fixture for /list and /switch tests.
    conv_titles: []const []const u8 = &.{},
    conv_models: []const []const u8 = &.{},
    conv_busy: []const bool = &.{},
    conv_copilot: []const bool = &.{},
    conv_current: ?usize = null,
    pin_called_index: ?usize = null,

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
    fn send_input(ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) control.SendResult {
        const self = cast(ctx);
        if (!self.connected) return .offline;
        if (self.busy) return .busy;
        self.last_surface = surface_id;
        self.last_reply_context = reply_context;
        const n = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..n], bytes[0..n]);
        self.len = n;
        return .ok;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    fn ai_approval_pending(ctx: *anyopaque) bool {
        return cast(ctx).approval_pending;
    }
    fn resolve_ai_approval(ctx: *anyopaque, approve: bool) bool {
        const self = cast(ctx);
        if (!self.approval_pending) return false;
        self.approval_pending = false;
        self.resolved_calls += 1;
        self.last_resolve_approve = approve;
        return true;
    }
    fn inbound_file_dir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn list_ai_conversations(ctx: *anyopaque, out: *control.ConversationList) void {
        const self = cast(ctx);
        var n: usize = 0;
        for (self.conv_titles, 0..) |title_v, i| {
            if (n >= out.items.len) break;
            var c = &out.items[n];
            c.* = .{};
            c.setTitle(title_v);
            if (i < self.conv_models.len) c.setModel(self.conv_models[i]);
            if (i < self.conv_busy.len) c.busy = self.conv_busy[i];
            if (i < self.conv_copilot.len) c.is_copilot = self.conv_copilot[i];
            c.is_current = (self.conv_current != null and self.conv_current.? == i);
            n += 1;
        }
        out.count = n;
    }
    fn pin_ai_conversation_by_index(ctx: *anyopaque, idx0: usize, out: *control.Conversation) bool {
        const self = cast(ctx);
        if (idx0 >= self.conv_titles.len) return false;
        self.pin_called_index = idx0;
        out.* = .{};
        out.setTitle(self.conv_titles[idx0]);
        if (idx0 < self.conv_models.len) out.setModel(self.conv_models[idx0]);
        if (idx0 < self.conv_copilot.len) out.is_copilot = self.conv_copilot[idx0];
        out.is_current = true;
        return true;
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
            .inbound_file_dir = inbound_file_dir,
            .list_ai_conversations = list_ai_conversations,
            .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
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

test "busy copilot replies with a busy notice and does not start a follow-up" {
    var fake = FakeControl{ .busy = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "hello", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "正在处理") != null);
    try t.expect(!out.expect_ai_progress);
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

test "approval pending: Y approves, acks, and streams progress" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "Y", null, &out);
    try t.expectEqual(@as(u8, 1), fake.resolved_calls);
    try t.expect(fake.last_resolve_approve);
    try t.expectEqualStrings("已确认，继续执行。", out.text.items);
    try t.expect(out.expect_ai_progress);
}

test "approval pending: 拒绝 denies and streams the continuation" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "拒绝", null, &out);
    try t.expectEqual(@as(u8, 1), fake.resolved_calls);
    try t.expect(!fake.last_resolve_approve);
    try t.expectEqualStrings("已拒绝该操作。", out.text.items);
    try t.expect(out.expect_ai_progress);
}

test "approval pending: unrecognized reply reminds without acting" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "先删回收站", null, &out);
    try t.expectEqual(@as(u8, 0), fake.resolved_calls);
    try t.expect(!out.expect_ai_progress);
    try t.expect(std.mem.indexOf(u8, out.text.items, "请先回复") != null);
    // The unrecognized text must NOT be forwarded to the composer.
    try t.expectEqual(@as(usize, 0), fake.len);
}

test "no approval pending: default text still goes to the AI surface" {
    var fake = FakeControl{}; // approval_pending defaults false
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "hello world", null, &out);
    try t.expectEqualStrings("hello world\r", fake.lastInput());
    try t.expect(out.expect_ai_progress);
}

test "/list shows conversations with current marker and copilot tag" {
    var fake = FakeControl{
        .conv_titles = &.{ "Claude", "zsh ~/p" },
        .conv_models = &.{ "glm-5.2", "opus" },
        .conv_busy = &.{ false, true },
        .conv_copilot = &.{ false, true },
        .conv_current = 0,
    };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/list", null, &out);
    const s = out.text.items;
    try t.expect(std.mem.indexOf(u8, s, "共 2 个") != null);
    try t.expect(std.mem.indexOf(u8, s, "➤") != null);
    try t.expect(std.mem.indexOf(u8, s, "· 副驾") != null);
    try t.expect(std.mem.indexOf(u8, s, "忙") != null);
}

test "/list with no conversations" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/list", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "没有副驾会话") != null);
}

test "/switch pins the right conversation and replies with a digest" {
    var fake = FakeControl{ .conv_titles = &.{ "A", "B" }, .conv_models = &.{ "m1", "m2" } };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch 2", null, &out);
    try t.expectEqual(@as(?usize, 1), fake.pin_called_index);
    try t.expect(std.mem.indexOf(u8, out.text.items, "已切换到会话 2：B") != null);
    try t.expect(std.mem.indexOf(u8, out.text.items, "未作为对话上下文") != null);
}

test "/switch out of range does not pin" {
    var fake = FakeControl{ .conv_titles = &.{"A"} };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch 9", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "无效的会话编号") != null);
    try t.expect(fake.pin_called_index == null);
}

test "/switch non-numeric arg" {
    var fake = FakeControl{ .conv_titles = &.{"A"} };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch abc", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "无效的会话编号") != null);
}

test "/switch with no argument shows usage" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "用法") != null);
}

test "/sessions, /ls, /use are aliases" {
    var fake = FakeControl{ .conv_titles = &.{ "A", "B" }, .conv_models = &.{ "m1", "m2" } };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/sessions", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "共 2 个") != null);

    var out2 = Reply.init(t.allocator);
    defer out2.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/use 1", null, &out2);
    try t.expectEqual(@as(?usize, 0), fake.pin_called_index);

    var out3 = Reply.init(t.allocator);
    defer out3.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/ls", null, &out3);
    try t.expect(std.mem.indexOf(u8, out3.text.items, "共 2 个") != null);
}

test "unknown command is still rejected" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/bogus x", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "未知命令") != null);
}

test "/status reports the current conversation" {
    var fake = FakeControl{
        .conv_titles = &.{ "Claude", "B" },
        .conv_models = &.{ "glm", "m2" },
        .conv_current = 0,
    };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/status", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "在线") != null);
    try t.expect(std.mem.indexOf(u8, out.text.items, "Claude") != null);
}
