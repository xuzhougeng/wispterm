//! 飞书 channel controller — M2.8.
//! Lifecycle (create/start/stop/destroy) mirroring src/weixin/controller.zig,
//! but uses longconn.Client instead of ilink poller.
//!
//! onEvent pipeline (runs on the longconn thread):
//!   codec.parseReceiveV1 → Dedup → binding.shouldHandle
//!   → build ReplyContext → chatops_router.route
//!   → immediate ack via send_text sink (injectable for tests)
//!   → TODO(M2.9): schedule AI-progress driver if expect_ai_progress
//!
//! Security: token/secret are never logged.
const std = @import("std");
const longconn = @import("longconn.zig");
const rest = @import("rest.zig");
const codec = @import("codec.zig");
const binding_mod = @import("binding.zig");
const types = @import("types.zig");
const control_mod = @import("../chatops/control.zig");
const router = @import("../chatops/router.zig");
const reply_mod = @import("../chatops/reply.zig");

const log = std.log.scoped(.feishu_ctrl);

// Bounded dedup capacity: last 256 event_ids retained in a ring.
// ponytail: fixed cap, upgrade if storm/replay rates demand larger window.
const DEDUP_CAP: usize = 256;

// ---------------------------------------------------------------------------
// Injectable send sink (makes ack testable without hitting the network)
// ---------------------------------------------------------------------------

/// Abstracts "send the ack text" so tests can capture it without a real token.
pub const SendTextFn = *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    chat_id: []const u8,
    text: []const u8,
) anyerror!void;

pub const SendSink = struct {
    ctx: *anyopaque,
    send: SendTextFn,
};

/// Production sink: calls rest.sendText with the live token.
fn restSendText(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    chat_id: []const u8,
    text: []const u8,
) anyerror!void {
    const self: *Controller = @ptrCast(@alignCast(ctx));
    const token = self.token_cache.get(alloc, self.creds) catch |err| {
        log.warn("restSendText: token refresh failed: {s}", .{@errorName(err)});
        return err;
    };
    rest.sendText(alloc, token, "chat_id", chat_id, text) catch |err| {
        log.warn("restSendText: send failed: {s}", .{@errorName(err)});
        return err;
    };
}

// ---------------------------------------------------------------------------
// feishu AttachmentSender — text is handled above; files → TODO M3
// ---------------------------------------------------------------------------

fn feishuSendAttachment(
    _: *anyopaque,
    kind: reply_mod.AttachmentKind,
    _: []const u8,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror!void {
    log.warn("feishu attachment kind={s}: file/media send not implemented (M3)", .{kind.name()});
    return error.Unsupported;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

pub const Controller = struct {
    allocator: std.mem.Allocator,
    creds: types.Credentials,
    cfg: binding_mod.Config,
    control: control_mod.Control,

    // Owned copies of credential strings (app_id / app_secret).
    app_id_buf: []u8,
    app_secret_buf: []u8,

    token_cache: rest.TokenCache = .{},
    dedup: binding_mod.Dedup,

    // longconn ownership — addr stable because Controller is heap-allocated.
    conn: longconn.Client,
    running: bool = false,

    // Injectable send sink: points at restSendText in production; tests override.
    send_sink: SendSink,

    pub fn create(
        allocator: std.mem.Allocator,
        creds: types.Credentials,
        cfg: binding_mod.Config,
        control: control_mod.Control,
    ) !*Controller {
        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);

        const app_id_buf = try allocator.dupe(u8, creds.app_id);
        errdefer allocator.free(app_id_buf);
        const app_secret_buf = try allocator.dupe(u8, creds.app_secret);
        errdefer allocator.free(app_secret_buf);

        const dedup = try binding_mod.Dedup.init(allocator, DEDUP_CAP);

        self.* = .{
            .allocator = allocator,
            .creds = .{ .app_id = app_id_buf, .app_secret = app_secret_buf },
            .cfg = cfg,
            .control = control,
            .app_id_buf = app_id_buf,
            .app_secret_buf = app_secret_buf,
            .dedup = dedup,
            .conn = .{ .allocator = allocator },
            .send_sink = .{ .ctx = self, .send = restSendText },
        };
        return self;
    }

    pub fn destroy(self: *Controller) void {
        self.stop();
        self.dedup.deinit();
        self.token_cache.deinit(self.allocator);
        self.allocator.free(self.app_id_buf);
        self.allocator.free(self.app_secret_buf);
        self.allocator.destroy(self);
    }

    /// Starts the long-connection thread. Idempotent: no-op if already running.
    pub fn start(self: *Controller) !void {
        if (self.running) return;
        try self.conn.start(self.creds, onEvent, self);
        self.running = true;
        log.info("feishu controller started", .{});
    }

    /// Signals stop and joins the longconn thread cleanly.
    pub fn stop(self: *Controller) void {
        if (!self.running) return;
        self.conn.stop(); // signals + joins
        self.running = false;
        log.info("feishu controller stopped", .{});
    }

    // ---------------------------------------------------------------------------
    // onEvent — runs on the longconn thread
    // ---------------------------------------------------------------------------

    fn onEvent(ctx: *anyopaque, payload: []const u8) void {
        const self: *Controller = @ptrCast(@alignCast(ctx));

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Step 1: parse
        const msg = codec.parseReceiveV1(a, payload) catch |err| {
            log.debug("onEvent: parse error {s}; skipping", .{@errorName(err)});
            return;
        };

        // Step 2: dedup
        if (self.dedup.seen(msg.event_id)) {
            log.debug("onEvent: duplicate event_id={s}; skipping", .{msg.event_id});
            return;
        }
        self.dedup.markSeen(msg.event_id) catch |err| {
            log.warn("onEvent: dedup.markSeen failed: {s}", .{@errorName(err)});
            // Continue — a dedup failure is not fatal; worst case we process once.
        };

        // Step 3: binding filter
        if (!binding_mod.shouldHandle(msg, self.cfg)) {
            log.debug("onEvent: message filtered by binding.shouldHandle", .{});
            return;
        }

        // Step 4: build ReplyContext (feishu replies to chat_id)
        const reply_ctx = reply_mod.ReplyContext{
            .sender = .{
                .ctx = self,
                .send_attachment = feishuSendAttachment,
            },
            .to_user_id = msg.chat_id,
            .context_token = msg.message_id,
            .model_context = "",
        };

        // Step 5: route
        var r = router.Reply.init(a);
        defer r.deinit();
        router.route(a, self.control, msg.text, reply_ctx, &r) catch |err| {
            log.warn("onEvent: route error: {s}", .{@errorName(err)});
            // Still attempt to ack so the user isn't left hanging.
        };

        // Step 6: immediate ack via injectable sink
        const reply_text = r.text.items;
        if (reply_text.len > 0) {
            self.send_sink.send(self.send_sink.ctx, self.allocator, msg.chat_id, reply_text) catch |err| {
                log.warn("onEvent: ack send failed: {s}", .{@errorName(err)});
            };
        }

        // Step 7: AI progress hook
        if (r.expect_ai_progress) {
            // TODO(M2.9): schedule progress driver — poll latestTranscript and
            // forward AI reply to msg.chat_id via send_sink. Must run off-thread
            // (not here on the longconn read loop). See task M2.9 brief.
            log.debug("onEvent: expect_ai_progress=true (M2.9 hook pending)", .{});
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

/// FakeControl mirrors router.zig's FakeControl but minimal: just captures
/// send_input calls so we can assert route was invoked.
const FakeControl = struct {
    connected: bool = true,
    last_input: std.ArrayListUnmanaged(u8) = .empty,
    last_reply_ctx: ?reply_mod.ReplyContext = null,

    fn deinit(self: *FakeControl) void {
        self.last_input.deinit(t.allocator);
    }

    fn is_connected(ctx: *anyopaque) bool {
        return cast(ctx).connected;
    }
    fn find_ai_surface(_: *anyopaque) ?control_mod.Surface {
        return .{ .id = "aichat0000000000".*, .title = "Copilot" };
    }
    fn find_terminal_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .opened;
    }
    fn open_ai_agent_profile(_: *anyopaque, _: []const u8, _: u32) control_mod.OpenResult {
        return .opened;
    }
    fn model_profiles(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn switch_ai_profile(_: *anyopaque, _: []const u8) control_mod.SwitchModelResult {
        return .offline;
    }
    fn send_input(ctx: *anyopaque, _: [16]u8, bytes: []const u8, reply_context: ?reply_mod.ReplyContext) control_mod.SendResult {
        const self = cast(ctx);
        if (!self.connected) return .offline;
        self.last_reply_ctx = reply_context;
        self.last_input.clearRetainingCapacity();
        self.last_input.appendSlice(t.allocator, bytes) catch {};
        return .ok;
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
    fn ai_question_option_count(_: *anyopaque) usize {
        return 0;
    }
    fn resolve_ai_question(_: *anyopaque, _: reply_mod.QuestionReply) bool {
        return false;
    }
    fn inbound_file_dir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn list_ai_conversations(_: *anyopaque, out: *control_mod.ConversationList) void {
        out.count = 0;
    }
    fn pin_ai_conversation_by_index(_: *anyopaque, _: usize, _: *control_mod.Conversation) bool {
        return false;
    }
    fn cast(ctx: *anyopaque) *FakeControl {
        return @ptrCast(@alignCast(ctx));
    }
    fn iface(self: *FakeControl) control_mod.Control {
        return .{ .ctx = self, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .open_ai_agent_profile = open_ai_agent_profile,
            .model_profiles = model_profiles,
            .switch_ai_profile = switch_ai_profile,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
            .ai_question_option_count = ai_question_option_count,
            .resolve_ai_question = resolve_ai_question,
            .inbound_file_dir = inbound_file_dir,
            .list_ai_conversations = list_ai_conversations,
            .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
        } };
    }
};

/// Captures ack text without touching the network.
const AckCapture = struct {
    calls: usize = 0,
    last_chat_id: std.ArrayListUnmanaged(u8) = .empty,
    last_text: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *AckCapture) void {
        self.last_chat_id.deinit(t.allocator);
        self.last_text.deinit(t.allocator);
    }

    fn send(ctx: *anyopaque, _: std.mem.Allocator, chat_id: []const u8, text: []const u8) anyerror!void {
        const self: *AckCapture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_chat_id.clearRetainingCapacity();
        self.last_chat_id.appendSlice(t.allocator, chat_id) catch {};
        self.last_text.clearRetainingCapacity();
        self.last_text.appendSlice(t.allocator, text) catch {};
    }
};

// Synthetic receive_v1 payload (p2p, text).
fn buildPayload(
    alloc: std.mem.Allocator,
    event_id: []const u8,
    chat_id: []const u8,
    sender_open_id: []const u8,
    chat_type: []const u8,
    text: []const u8,
) ![]u8 {
    // content is double-encoded JSON (see codec.zig).
    const inner_content = try std.fmt.allocPrint(alloc, "{{\"text\":\"{s}\"}}", .{text});
    defer alloc.free(inner_content);
    // Escape the inner JSON string for embedding in outer JSON.
    const content_escaped = try std.json.Stringify.valueAlloc(alloc, inner_content, .{});
    defer alloc.free(content_escaped);
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema":"2.0",
        \\  "header":{{"event_id":"{s}","event_type":"im.message.receive_v1"}},
        \\  "event":{{
        \\    "sender":{{"sender_id":{{"open_id":"{s}"}}}},
        \\    "message":{{
        \\      "message_id":"om_test001",
        \\      "chat_id":"{s}",
        \\      "chat_type":"{s}",
        \\      "message_type":"text",
        \\      "content":{s}
        \\    }}
        \\  }}
        \\}}
    , .{ event_id, sender_open_id, chat_id, chat_type, content_escaped });
}

/// Create a controller wired to a fake control + ack capture (no network).
fn makeTestCtrl(fake: *FakeControl, ack: *AckCapture) !*Controller {
    const ctrl = try Controller.create(
        t.allocator,
        .{ .app_id = "app_test", .app_secret = "secret_test" },
        .{}, // empty cfg → no user restriction
        fake.iface(),
    );
    // Override send sink so tests capture acks without hitting the network.
    ctrl.send_sink = .{ .ctx = ack, .send = AckCapture.send };
    return ctrl;
}

test "onEvent pipeline: p2p text → route called + ack captured" {
    var fake = FakeControl{};
    defer fake.deinit();
    var ack = AckCapture{};
    defer ack.deinit();

    const ctrl = try makeTestCtrl(&fake, &ack);
    defer ctrl.destroy();

    const payload = try buildPayload(
        t.allocator, "ev-001", "oc_chat001", "ou_alice", "p2p", "hello feishu",
    );
    defer t.allocator.free(payload);

    Controller.onEvent(ctrl, payload);

    // route was called → sendInput got the text (with trailing \r from sendAi)
    try t.expect(std.mem.indexOf(u8, fake.last_input.items, "hello feishu") != null);

    // ack was sent exactly once
    try t.expectEqual(@as(usize, 1), ack.calls);
    try t.expectEqualStrings("oc_chat001", ack.last_chat_id.items);
    try t.expect(ack.last_text.items.len > 0);
}

test "onEvent dedup: re-delivery with same event_id is ignored" {
    var fake = FakeControl{};
    defer fake.deinit();
    var ack = AckCapture{};
    defer ack.deinit();

    const ctrl = try makeTestCtrl(&fake, &ack);
    defer ctrl.destroy();

    const payload = try buildPayload(
        t.allocator, "ev-dedup", "oc_chat002", "ou_bob", "p2p", "ping",
    );
    defer t.allocator.free(payload);

    Controller.onEvent(ctrl, payload);
    Controller.onEvent(ctrl, payload); // re-delivery

    // Only one ack should have been sent (second delivery dropped by dedup).
    try t.expectEqual(@as(usize, 1), ack.calls);
}

test "onEvent binding filter: group message is ignored" {
    var fake = FakeControl{};
    defer fake.deinit();
    var ack = AckCapture{};
    defer ack.deinit();

    const ctrl = try makeTestCtrl(&fake, &ack);
    defer ctrl.destroy();

    const payload = try buildPayload(
        t.allocator, "ev-group", "oc_group001", "ou_carol", "group", "hello group",
    );
    defer t.allocator.free(payload);

    Controller.onEvent(ctrl, payload);

    // Group messages must be filtered by binding.shouldHandle → no ack.
    try t.expectEqual(@as(usize, 0), ack.calls);
    try t.expectEqual(@as(usize, 0), fake.last_input.items.len);
}

test "onEvent binding filter: allowed_user mismatch → ignored" {
    var fake = FakeControl{};
    defer fake.deinit();
    var ack = AckCapture{};
    defer ack.deinit();

    // cfg restricts to a specific user.
    const ctrl = try Controller.create(
        t.allocator,
        .{ .app_id = "app_test", .app_secret = "secret_test" },
        .{ .allowed_user = "ou_allowed" },
        fake.iface(),
    );
    defer ctrl.destroy();
    ctrl.send_sink = .{ .ctx = &ack, .send = AckCapture.send };

    const payload = try buildPayload(
        t.allocator, "ev-filtered", "oc_chat003", "ou_stranger", "p2p", "hi",
    );
    defer t.allocator.free(payload);

    Controller.onEvent(ctrl, payload);

    // Sender not in allowlist → filtered.
    try t.expectEqual(@as(usize, 0), ack.calls);
}

test "create/destroy without start is clean (no thread spawned)" {
    var fake = FakeControl{};
    defer fake.deinit();
    var ack = AckCapture{};
    defer ack.deinit();

    const ctrl = try makeTestCtrl(&fake, &ack);
    defer ctrl.destroy();

    try t.expect(!ctrl.running);
}
