//! WeChat poll loop. processUpdates is the pure, tested core; Poller wraps it in
//! a background thread with stop/staleness handling (port of poller.ts).
const std = @import("std");
const types = @import("types.zig");
const binding = @import("binding.zig");
const agent = @import("agent.zig");
const ilink = @import("ilink_client.zig");
const control_mod = @import("control.zig");

pub const SESSION_EXPIRED_ERRCODE: i64 = -14;

pub const ProcessInput = struct {
    allocator: std.mem.Allocator,
    owner: []const u8,
    account_id: []const u8,
    messages: []const types.Message,
    route_ctx: *anyopaque,
    /// Fills `reply` with the response text; returns true if the caller should
    /// begin AI-reply progress streaming.
    route_fn: *const fn (ctx: *anyopaque, text: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!bool,
    send_ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
};

/// Mirror of processWeixinUpdates: filter, extract, route, reply.
pub fn processUpdates(input: ProcessInput) !void {
    for (input.messages) |msg| {
        if (!binding.shouldHandle(input.owner, input.account_id, msg).ok) continue;
        const text = binding.extractText(msg);
        if (text.len == 0) continue;

        var reply: std.ArrayListUnmanaged(u8) = .empty;
        defer reply.deinit(input.allocator);
        _ = input.route_fn(input.route_ctx, text, input.allocator, &reply) catch continue;

        const trimmed = std.mem.trim(u8, reply.items, " \t\r\n");
        if (trimmed.len != 0) {
            input.send_fn(input.send_ctx, msg.from_user_id, trimmed, msg.context_token) catch {};
        }
    }
}

/// Background poller. Owns its thread; `sync_buf` is heap-owned and updated each
/// tick. AI-reply progress streaming (checkpoints) is layered on by the
/// controller, which observes the `expect_ai_progress` flag from routing.
pub const Poller = struct {
    allocator: std.mem.Allocator,
    client: ilink.ClientApi,
    control: control_mod.Control,
    settings: types.Settings,
    owner: []const u8,
    account_id: []const u8,
    sync_buf: []u8,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *Poller) !void {
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    pub fn stop(self: *Poller) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
    }

    fn threadMain(self: *Poller) void {
        while (!self.stop_requested.load(.acquire)) {
            self.tickOnce() catch {
                std.Thread.sleep(5 * std.time.ns_per_s);
            };
        }
    }

    fn tickOnce(self: *Poller) !void {
        var updates = try self.client.getUpdates(self.sync_buf);
        defer updates.deinit();

        if (updates.value.errcode == SESSION_EXPIRED_ERRCODE) {
            self.stop_requested.store(true, .release);
            return;
        }

        try processUpdates(.{
            .allocator = self.allocator,
            .owner = self.owner,
            .account_id = self.account_id,
            .messages = updates.value.msgs,
            .route_ctx = self,
            .route_fn = routeAdapter,
            .send_ctx = self,
            .send_fn = sendAdapter,
        });

        if (updates.value.get_updates_buf.len != 0 and
            !std.mem.eql(u8, updates.value.get_updates_buf, self.sync_buf))
        {
            const next = try self.allocator.dupe(u8, updates.value.get_updates_buf);
            self.allocator.free(self.sync_buf);
            self.sync_buf = next;
        }
    }

    fn routeAdapter(ctx: *anyopaque, text: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!bool {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        var r = agent.Reply.init(allocator);
        defer r.deinit();
        try agent.route(allocator, self.control, self.settings, text, &r);
        try reply.appendSlice(allocator, r.text.items);
        return r.expect_ai_progress;
    }

    fn sendAdapter(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        try self.client.sendText(to_user_id, text, context_token);
    }
};

const t = std.testing;

const Captured = struct {
    sent: std.ArrayListUnmanaged([]u8) = .empty,
    routed: std.ArrayListUnmanaged([]u8) = .empty,
    fn deinit(self: *Captured) void {
        for (self.sent.items) |s| t.allocator.free(s);
        for (self.routed.items) |s| t.allocator.free(s);
        self.sent.deinit(t.allocator);
        self.routed.deinit(t.allocator);
    }
};

const RouteCtx = struct {
    cap: *Captured,
    fn route(ctx: *anyopaque, text: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!bool {
        const self: *RouteCtx = @ptrCast(@alignCast(ctx));
        try self.cap.routed.append(t.allocator, try t.allocator.dupe(u8, text));
        try reply.appendSlice(allocator, "ok");
        return false;
    }
};

const SendCtx = struct {
    cap: *Captured,
    fn send(ctx: *anyopaque, to: []const u8, text: []const u8, _: []const u8) anyerror!void {
        _ = to;
        const self: *SendCtx = @ptrCast(@alignCast(ctx));
        try self.cap.sent.append(t.allocator, try t.allocator.dupe(u8, text));
    }
};

test "processUpdates routes accepted text and sends replies" {
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "c", .item_list = &.{.{ .type = 1, .text = "hi" }} },
        .{ .from_user_id = "u1", .group_id = "g", .item_list = &.{.{ .type = 1, .text = "ignored" }} }, // group → skip
    };

    try processUpdates(.{
        .allocator = t.allocator,
        .owner = "u1",
        .account_id = "",
        .messages = &msgs,
        .route_ctx = &rctx,
        .route_fn = RouteCtx.route,
        .send_ctx = &sctx,
        .send_fn = SendCtx.send,
    });

    try t.expectEqual(@as(usize, 1), cap.routed.items.len);
    try t.expectEqualStrings("hi", cap.routed.items[0]);
    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("ok", cap.sent.items[0]);
}
