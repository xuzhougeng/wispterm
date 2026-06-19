//! WeChat poll loop. processUpdates is the pure, tested core; Poller wraps it in
//! a background thread with stop/staleness handling (port of poller.ts).
const std = @import("std");
const types = @import("types.zig");
const binding = @import("binding.zig");
const agent = @import("agent.zig");
const ilink = @import("ilink_client.zig");
const control_mod = @import("control.zig");
const reply_progress = @import("reply_progress.zig");
const media_inbound_mod = @import("media_inbound.zig");

const log = std.log.scoped(.weixin);

pub const SESSION_EXPIRED_ERRCODE: i64 = -14;
/// Elapsed times at which an in-progress AI follow-up pings the user so a slow
/// task visibly stays alive: 30s, then 2m, 5m, 10m, 20m. The ~30-minute mark is
/// the context-token window edge, handled by the window-expired resend notice.
const AI_REPLY_CHECKPOINTS_MS = [_]u64{ 30_000, 120_000, 300_000, 600_000, 1_200_000 };
const AI_REPLY_POLL_MS: u64 = 1_000;
const POLL_ERROR_BACKOFF_MS: u64 = 1_000;
const SHUTDOWN_JOIN_TIMEOUT_MS: u32 = 1500;
/// The WeChat `context_token` that lets the bot reply to an inbound message is
/// only valid for ~30 minutes. A reply sent with an expired token is rejected by
/// the server and the user silently receives nothing — the root cause of "the
/// bot just stops replying" for slow AI tasks. The follow-up must therefore
/// finish (or hand back) within this window, regardless of reply_timeout_ms.
const CONTEXT_TOKEN_WINDOW_MS: u64 = 30 * 60 * 1000;
/// Send the final answer / progress / resend notice this far before the hard
/// expiry so it still goes out on a valid token.
const EXPIRY_NOTICE_MARGIN_MS: u64 = 30 * 1000;
/// Latest elapsed time at which the follow-up still sends on the original token.
const AI_REPLY_DEADLINE_MS: u64 = CONTEXT_TOKEN_WINDOW_MS - EXPIRY_NOTICE_MARGIN_MS;
/// Sent once when the window closes with no final answer: the token is about to
/// expire, so a fresh inbound message is needed to keep the conversation going.
const AI_REPLY_WINDOW_EXPIRED_NOTICE = "AI 处理已超过 30 分钟仍未完成，微信回复窗口即将关闭。请重新发送一条消息以继续接收回复。";

pub const RouteResult = struct {
    expect_ai_progress: bool = false,
    /// true ⇒ cancel any active AI-reply progress streaming (set by /stop).
    stop_followup: bool = false,
    /// Heap-owned by ProcessInput. Freed after start_progress_fn returns.
    baseline_transcript: []u8 = &.{},
};

pub const MediaOutcome = struct {
    /// true ⇒ this message carried inbound media (text path is skipped).
    handled: bool = false,
    /// true ⇒ at least one file saved (route the synthetic prompt).
    any_saved: bool = false,
};

pub const ThreadControl = struct {
    request_synchronous_io_cancel: *const fn (thread: std.Thread) bool,
    wait_for_exit: *const fn (thread: std.Thread, timeout_ms: u32) bool,
};

pub const SyncCallback = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, sync_buf: []const u8) anyerror!void,
};

pub const ProcessInput = struct {
    allocator: std.mem.Allocator,
    owner: []const u8,
    account_id: []const u8,
    messages: []const types.Message,
    route_ctx: *anyopaque,
    /// Fills `reply` with the response text; returns true if the caller should
    /// begin AI-reply progress streaming.
    route_fn: *const fn (
        ctx: *anyopaque,
        text: []const u8,
        model_context: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
        allocator: std.mem.Allocator,
        reply: *std.ArrayListUnmanaged(u8),
    ) anyerror!RouteResult,
    send_ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
    progress_ctx: ?*anyopaque = null,
    start_progress_fn: ?*const fn (ctx: *anyopaque, baseline_transcript: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void = null,
    /// Cancels any active AI-reply progress streaming. Invoked (with progress_ctx)
    /// when a routed message reports stop_followup (e.g. /stop).
    stop_progress_fn: ?*const fn (ctx: *anyopaque) void = null,
    media_ctx: ?*anyopaque = null,
    /// Downloads + saves inbound media in `msg`. Fills `receipt` (sent verbatim
    /// as the ack), `prompt` (visible copilot text), and `model_context`
    /// (request-only context; its reply is suppressed).
    media_fn: ?*const fn (
        ctx: *anyopaque,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
        model_context: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome = null,
};

/// Mirror of processWeixinUpdates: filter, extract, route, reply.
pub fn processUpdates(input: ProcessInput) !void {
    for (input.messages, 0..) |msg, i| {
        std.debug.print(
            "weixin process({d}): index={d} from_len={d} from_hash={x} to_len={d} to_hash={x} group={} context={} items={d}\n",
            .{
                debugNowMs(),
                i,
                msg.from_user_id.len,
                debugHash(msg.from_user_id),
                msg.to_user_id.len,
                debugHash(msg.to_user_id),
                msg.group_id.len != 0,
                msg.context_token.len != 0,
                msg.item_list.len,
            },
        );
        const decision = binding.shouldHandle(input.owner, input.account_id, msg);
        if (!decision.ok) {
            std.debug.print("weixin process({d}): index={d} skipped reason={s}\n", .{ debugNowMs(), i, decision.reason });
            continue;
        }

        if (input.media_fn) |media_fn| {
            var receipt: std.ArrayListUnmanaged(u8) = .empty;
            defer receipt.deinit(input.allocator);
            var prompt: std.ArrayListUnmanaged(u8) = .empty;
            defer prompt.deinit(input.allocator);
            var model_context: std.ArrayListUnmanaged(u8) = .empty;
            defer model_context.deinit(input.allocator);
            const outcome = media_fn(input.media_ctx.?, msg, input.allocator, &receipt, &prompt, &model_context) catch |err| blk: {
                std.debug.print("weixin process({d}): index={d} media=failed err={}\n", .{ debugNowMs(), i, err });
                break :blk MediaOutcome{};
            };
            if (outcome.handled) {
                const receipt_trimmed = std.mem.trim(u8, receipt.items, " \t\r\n");
                if (receipt_trimmed.len != 0) {
                    input.send_fn(input.send_ctx, msg.from_user_id, receipt_trimmed, msg.context_token) catch |err| {
                        std.debug.print("weixin send({d}): index={d} kind=receipt status=failed err={}\n", .{ debugNowMs(), i, err });
                    };
                }
                if (outcome.any_saved and prompt.items.len != 0) {
                    var throwaway: std.ArrayListUnmanaged(u8) = .empty;
                    defer throwaway.deinit(input.allocator);
                    const rr = input.route_fn(input.route_ctx, prompt.items, model_context.items, msg.from_user_id, msg.context_token, input.allocator, &throwaway) catch |err| route_blk: {
                        std.debug.print("weixin process({d}): index={d} media_route=failed err={}\n", .{ debugNowMs(), i, err });
                        break :route_blk RouteResult{};
                    };
                    defer if (rr.baseline_transcript.len != 0) input.allocator.free(rr.baseline_transcript);
                    if (rr.expect_ai_progress) {
                        if (input.progress_ctx) |ctx| {
                            if (input.start_progress_fn) |start| {
                                start(ctx, rr.baseline_transcript, msg.from_user_id, msg.context_token) catch |err| {
                                    std.debug.print("weixin process({d}): index={d} media_followup=failed err={}\n", .{ debugNowMs(), i, err });
                                };
                            }
                        }
                    }
                }
                continue; // media handled → skip the text path
            }
        }

        const text = binding.extractText(msg);
        if (text.len == 0) {
            std.debug.print("weixin process({d}): index={d} skipped reason=no_text_item\n", .{ debugNowMs(), i });
            continue;
        }
        std.debug.print("weixin process({d}): index={d} text_bytes={d} route=begin\n", .{ debugNowMs(), i, text.len });

        var reply: std.ArrayListUnmanaged(u8) = .empty;
        defer reply.deinit(input.allocator);
        const route_result = input.route_fn(input.route_ctx, text, "", msg.from_user_id, msg.context_token, input.allocator, &reply) catch |err| {
            std.debug.print("weixin process({d}): index={d} route=failed err={}\n", .{ debugNowMs(), i, err });
            continue;
        };
        defer if (route_result.baseline_transcript.len != 0) input.allocator.free(route_result.baseline_transcript);
        std.debug.print(
            "weixin process({d}): index={d} route=done reply_bytes={d} ai_followup={} baseline_bytes={d}\n",
            .{ debugNowMs(), i, reply.items.len, route_result.expect_ai_progress, route_result.baseline_transcript.len },
        );

        // /stop (and any stop_followup route) cancels active reply streaming
        // before the confirmation reply is sent, so no stale progress/final
        // reply trails the stop.
        if (route_result.stop_followup) {
            if (input.progress_ctx) |ctx| {
                if (input.stop_progress_fn) |stop| {
                    std.debug.print("weixin process({d}): index={d} ai_followup=cancel\n", .{ debugNowMs(), i });
                    stop(ctx);
                }
            }
        }

        const trimmed = std.mem.trim(u8, reply.items, " \t\r\n");
        if (trimmed.len != 0) {
            std.debug.print(
                "weixin send({d}): index={d} kind=reply to_len={d} to_hash={x} bytes={d} context={}\n",
                .{ debugNowMs(), i, msg.from_user_id.len, debugHash(msg.from_user_id), trimmed.len, msg.context_token.len != 0 },
            );
            input.send_fn(input.send_ctx, msg.from_user_id, trimmed, msg.context_token) catch |err| {
                std.debug.print("weixin send({d}): index={d} kind=reply status=failed err={}\n", .{ debugNowMs(), i, err });
                continue;
            };
            std.debug.print("weixin send({d}): index={d} kind=reply status=sent bytes={d}\n", .{ debugNowMs(), i, trimmed.len });
        }
        if (route_result.expect_ai_progress) {
            if (input.progress_ctx) |ctx| {
                if (input.start_progress_fn) |start| {
                    std.debug.print("weixin process({d}): index={d} ai_followup=start\n", .{ debugNowMs(), i });
                    start(ctx, route_result.baseline_transcript, msg.from_user_id, msg.context_token) catch |err| {
                        std.debug.print("weixin process({d}): index={d} ai_followup=failed err={}\n", .{ debugNowMs(), i, err });
                    };
                }
            }
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
    sync_callback: ?SyncCallback = null,
    bootstrap_skip_pending: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    transcript_mutex: std.Thread.Mutex = .{},
    followup_mutex: std.Thread.Mutex = .{},
    followup_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    followup_thread: ?std.Thread = null,

    pub fn start(self: *Poller) !void {
        self.stop_requested.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        log.info("poller started", .{});
    }

    pub fn stop(self: *Poller) void {
        self.stop_requested.store(true, .release);
        self.cancelAiFollowup();
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
        self.cancelAiFollowup();
        log.info("poller stopped", .{});
    }

    pub fn stopForProcessExit(self: *Poller, thread_control: ThreadControl) bool {
        self.stop_requested.store(true, .release);
        var clean = self.cancelAiFollowupForProcessExit(thread_control);
        if (self.thread) |th| {
            _ = thread_control.request_synchronous_io_cancel(th);
            if (thread_control.wait_for_exit(th, SHUTDOWN_JOIN_TIMEOUT_MS)) {
                th.join();
            } else {
                th.detach();
                clean = false;
                std.debug.print("weixin poller shutdown timed out; detaching for process exit\n", .{});
            }
            self.thread = null;
        }
        clean = self.cancelAiFollowupForProcessExit(thread_control) and clean;
        if (clean) std.debug.print("weixin poller stopped\n", .{});
        return clean;
    }

    fn threadMain(self: *Poller) void {
        while (!self.stop_requested.load(.acquire)) {
            self.tickOnce() catch |err| {
                log.warn("poll failed: {}; retrying in {d}ms", .{ err, POLL_ERROR_BACKOFF_MS });
                std.Thread.sleep(POLL_ERROR_BACKOFF_MS * std.time.ns_per_ms);
            };
        }
    }

    fn tickOnce(self: *Poller) !void {
        var updates = try self.getUpdatesLocked(self.sync_buf);
        defer updates.deinit();
        if (self.stop_requested.load(.acquire)) return;

        if (updates.value.errcode == SESSION_EXPIRED_ERRCODE) {
            std.debug.print("weixin session expired; stopping poller\n", .{});
            self.stop_requested.store(true, .release);
            return;
        }
        const bootstrap_skip = self.bootstrap_skip_pending;
        self.bootstrap_skip_pending = false;
        const sync_changed = updates.value.get_updates_buf.len != 0 and
            !std.mem.eql(u8, updates.value.get_updates_buf, self.sync_buf);
        if (updates.value.msgs.len != 0 or updates.value.ret != 0 or updates.value.errcode != 0 or sync_changed or bootstrap_skip) {
            std.debug.print(
                "weixin receive({d}): ret={} errcode={} messages={d} sync_len={d} next_sync_len={d} sync_changed={} bootstrap={}\n",
                .{
                    debugNowMs(),
                    updates.value.ret,
                    updates.value.errcode,
                    updates.value.msgs.len,
                    self.sync_buf.len,
                    updates.value.get_updates_buf.len,
                    sync_changed,
                    bootstrap_skip,
                },
            );
        }
        try self.advanceSyncBuf(updates.value.get_updates_buf);
        if (bootstrap_skip) {
            if (updates.value.msgs.len != 0) {
                std.debug.print("weixin process({d}): bootstrap_skip historical_messages={d}\n", .{ debugNowMs(), updates.value.msgs.len });
            }
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
            .progress_ctx = self,
            .start_progress_fn = startProgressAdapter,
            .stop_progress_fn = stopProgressAdapter,
            .media_ctx = self,
            .media_fn = pollerMediaAdapterThunk,
        });
    }

    fn routeAdapter(
        ctx: *anyopaque,
        text: []const u8,
        model_context: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
        allocator: std.mem.Allocator,
        reply: *std.ArrayListUnmanaged(u8),
    ) anyerror!RouteResult {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        if (self.stop_requested.load(.acquire)) return error.PollerStopped;
        const baseline = try self.allocTranscriptSnapshot(allocator);
        errdefer if (baseline.len != 0) allocator.free(baseline);

        var r = agent.Reply.init(allocator);
        defer r.deinit();
        const reply_context = types.ReplyContext{
            .sender = .{ .ctx = self, .send_attachment = pollerSendAttachment },
            .to_user_id = to_user_id,
            .context_token = context_token,
            .model_context = model_context,
        };
        try agent.route(allocator, self.control, self.settings, text, reply_context, &r);
        try reply.appendSlice(allocator, r.text.items);
        if (!r.expect_ai_progress) {
            if (baseline.len != 0) allocator.free(baseline);
            return .{ .stop_followup = r.stop_followup };
        }
        return .{
            .expect_ai_progress = true,
            .baseline_transcript = baseline,
        };
    }

    fn pollerSendAttachment(
        ctx: *anyopaque,
        kind: types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        if (self.stop_requested.load(.acquire)) return error.PollerStopped;
        try self.client.sendAttachment(kind, path, display_name, to_user_id, context_token);
    }

    fn pollerMediaAdapterThunk(
        ctx: *anyopaque,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
        model_context: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        return self.pollerMediaAdapter(msg, allocator, receipt, prompt, model_context);
    }

    fn pollerMediaAdapter(
        self: *Poller,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
        model_context: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome {
        if (self.stop_requested.load(.acquire)) return .{};
        const plans = try media_inbound_mod.planDownloads(allocator, msg.item_list);
        defer allocator.free(plans);
        if (plans.len == 0) return .{};

        // Resolve <working-dir>/weixin_inbound, falling back to cwd.
        var dir_buf: [4096]u8 = undefined;
        const base_dir = self.control.inboundFileDir(&dir_buf);
        const save_dir = blk: {
            if (base_dir.len != 0) {
                break :blk try std.fs.path.join(allocator, &.{ base_dir, "weixin_inbound" });
            }
            break :blk try allocator.dupe(u8, "weixin_inbound");
        };
        defer allocator.free(save_dir);
        std.fs.cwd().makePath(save_dir) catch |err| {
            std.debug.print("weixin media: makePath failed dir_len={d} err={}\n", .{ save_dir.len, err });
            try receipt.appendSlice(allocator, "收到文件，但无法创建保存目录，已忽略。");
            return .{ .handled = true, .any_saved = false };
        };

        var saved_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (saved_names.items) |n| allocator.free(n);
            saved_names.deinit(allocator);
        }
        var saved_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (saved_paths.items) |pth| allocator.free(pth);
            saved_paths.deinit(allocator);
        }
        var failed_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer failed_names.deinit(allocator);

        // Reserve capacity up front so every in-loop append is infallible: the
        // loop body then has no `try` that could return mid-iteration, so the
        // `name`/`full` allocations are either appended (owned by the lists,
        // freed by the defers above) or freed on their own failure path — no
        // errdefer needed, no double-free on OOM.
        try saved_names.ensureTotalCapacity(allocator, plans.len);
        try saved_paths.ensureTotalCapacity(allocator, plans.len);
        try failed_names.ensureTotalCapacity(allocator, plans.len);

        for (plans, 0..) |plan, idx| {
            if (self.stop_requested.load(.acquire)) break;
            const bytes = self.client.downloadAttachment(allocator, plan.encrypt_query_param, plan.aes_key, plan.allow_plain) catch |err| {
                std.debug.print("weixin media: download failed kind={s} err={}\n", .{ plan.kind.name(), err });
                failed_names.appendAssumeCapacity(failureLabel(plan));
                continue;
            };
            defer allocator.free(bytes);

            const chosen = media_inbound_mod.chooseFileName(allocator, plan, bytes, idx) catch {
                failed_names.appendAssumeCapacity(failureLabel(plan));
                continue;
            };
            defer allocator.free(chosen);

            const name = media_inbound_mod.dedupeFileName(allocator, chosen, saved_names.items) catch {
                failed_names.appendAssumeCapacity(failureLabel(plan));
                continue;
            };
            const full = std.fs.path.join(allocator, &.{ save_dir, name }) catch {
                allocator.free(name);
                failed_names.appendAssumeCapacity(failureLabel(plan));
                continue;
            };
            writeFileAbsolute(full, bytes) catch |err| {
                std.debug.print("weixin media: write failed err={}\n", .{err});
                allocator.free(name);
                allocator.free(full);
                failed_names.appendAssumeCapacity(failureLabel(plan));
                continue;
            };
            saved_names.appendAssumeCapacity(name);
            saved_paths.appendAssumeCapacity(full);
        }

        if (saved_names.items.len == 0) {
            try appendFailureLine(allocator, receipt, failed_names.items);
            return .{ .handled = true, .any_saved = false };
        }

        const receipt_text = try media_inbound_mod.buildReceiptText(allocator, saved_names.items);
        defer allocator.free(receipt_text);
        try receipt.appendSlice(allocator, receipt_text);
        try appendFailureLine(allocator, receipt, failed_names.items);

        const caption = binding.extractText(msg);
        const prompt_text = try media_inbound_mod.buildCopilotPrompt(allocator, saved_names.items, caption);
        defer allocator.free(prompt_text);
        try prompt.appendSlice(allocator, prompt_text);
        const model_context_text = try media_inbound_mod.buildCopilotModelContext(allocator, saved_paths.items);
        defer allocator.free(model_context_text);
        try model_context.appendSlice(allocator, model_context_text);

        return .{ .handled = true, .any_saved = true };
    }

    fn sendAdapter(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        if (self.stop_requested.load(.acquire)) return error.PollerStopped;
        try self.sendTextLocked(to_user_id, text, context_token);
    }

    fn startProgressAdapter(ctx: *anyopaque, baseline_transcript: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        try self.startAiFollowup(baseline_transcript, to_user_id, context_token);
    }

    fn stopProgressAdapter(ctx: *anyopaque) void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        self.cancelAiFollowup();
    }

    fn getUpdatesLocked(self: *Poller, sync_buf_value: []const u8) !@import("ilink_codec.zig").ParsedUpdates {
        return self.client.getUpdates(sync_buf_value);
    }

    fn advanceSyncBuf(self: *Poller, next_buf: []const u8) !void {
        if (next_buf.len == 0 or std.mem.eql(u8, next_buf, self.sync_buf)) return;

        const old_len = self.sync_buf.len;
        const next = try self.allocator.dupe(u8, next_buf);
        self.allocator.free(self.sync_buf);
        self.sync_buf = next;
        std.debug.print("weixin receive({d}): sync_cursor=advanced old_len={d} new_len={d}\n", .{ debugNowMs(), old_len, self.sync_buf.len });

        if (self.sync_callback) |cb| {
            cb.callback(cb.ctx, self.sync_buf) catch |err| {
                std.debug.print("weixin receive({d}): sync_cursor=persist_failed err={}\n", .{ debugNowMs(), err });
            };
        }
    }

    fn sendTextLocked(self: *Poller, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        try self.client.sendText(to_user_id, text, context_token);
    }

    fn allocTranscriptSnapshot(self: *Poller, allocator: std.mem.Allocator) ![]u8 {
        self.transcript_mutex.lock();
        defer self.transcript_mutex.unlock();
        const snapshot = self.control.latestTranscript();
        if (snapshot.len == 0) return &.{};
        return allocator.dupe(u8, snapshot);
    }

    fn cancelAiFollowup(self: *Poller) void {
        _ = self.followup_generation.fetchAdd(1, .acq_rel);
        var thread_to_join: ?std.Thread = null;
        {
            self.followup_mutex.lock();
            defer self.followup_mutex.unlock();
            thread_to_join = self.followup_thread;
            self.followup_thread = null;
        }
        if (thread_to_join) |th| th.join();
    }

    fn cancelAiFollowupForProcessExit(self: *Poller, thread_control: ThreadControl) bool {
        _ = self.followup_generation.fetchAdd(1, .acq_rel);
        var thread_to_join: ?std.Thread = null;
        {
            self.followup_mutex.lock();
            defer self.followup_mutex.unlock();
            thread_to_join = self.followup_thread;
            self.followup_thread = null;
        }
        if (thread_to_join) |th| {
            _ = thread_control.request_synchronous_io_cancel(th);
            if (thread_control.wait_for_exit(th, SHUTDOWN_JOIN_TIMEOUT_MS)) {
                th.join();
                return true;
            }
            th.detach();
            std.debug.print("weixin AI followup shutdown timed out; detaching for process exit\n", .{});
            return false;
        }
        return true;
    }

    fn startAiFollowup(self: *Poller, baseline_transcript: []const u8, to_user_id: []const u8, context_token: []const u8) !void {
        if (self.stop_requested.load(.acquire)) return;
        self.cancelAiFollowup();

        const generation = self.followup_generation.fetchAdd(1, .acq_rel) + 1;
        const baseline_owned = try self.allocator.dupe(u8, baseline_transcript);
        errdefer self.allocator.free(baseline_owned);
        const to_owned = try self.allocator.dupe(u8, to_user_id);
        errdefer self.allocator.free(to_owned);
        const context_owned = try self.allocator.dupe(u8, context_token);
        errdefer self.allocator.free(context_owned);

        const job = try self.allocator.create(FollowupJob);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .baseline_transcript = baseline_owned,
            .to_user_id = to_owned,
            .context_token = context_owned,
        };

        const th = try std.Thread.spawn(.{}, followupThreadMain, .{ self, job, generation });
        self.followup_mutex.lock();
        self.followup_thread = th;
        self.followup_mutex.unlock();
        std.debug.print(
            "weixin process({d}): ai_followup=started generation={d} baseline_bytes={d} to_len={d} to_hash={x} context={}\n",
            .{ debugNowMs(), generation, baseline_owned.len, to_owned.len, debugHash(to_owned), context_owned.len != 0 },
        );
    }

    fn followupThreadMain(self: *Poller, job: *FollowupJob, generation: u64) void {
        defer {
            job.deinit(self.allocator);
            self.allocator.destroy(job);
        }

        var schedule = ProgressSchedule{};
        var elapsed_ms: u64 = 0;
        var announcer = ApprovalAnnouncer{};
        var question_announcer = ApprovalAnnouncer{};

        // Wait for the AI's answer up to the context_token's validity window, not
        // the old reply_timeout_ms (<= 3 min) cap that abandoned slow tasks.
        while (!self.stop_requested.load(.acquire) and
            self.followup_generation.load(.acquire) == generation and
            elapsed_ms < AI_REPLY_DEADLINE_MS)
        {
            std.Thread.sleep(AI_REPLY_POLL_MS * std.time.ns_per_ms);
            elapsed_ms += AI_REPLY_POLL_MS;

            const progress = self.allocProgressText(job.baseline_transcript) catch continue;
            defer if (progress.text.len != 0) self.allocator.free(progress.text);

            const announce_now = announcer.due(progress.needs_approval);
            const question_announce_now = question_announcer.due(progress.needs_question);
            if (progress.needs_approval) {
                if (announce_now and progress.text.len != 0) {
                    std.debug.print(
                        "weixin send({d}): kind=ai_approval generation={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                        .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                    );
                    self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                        std.debug.print("weixin send({d}): kind=ai_approval generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    };
                }
                continue;
            }
            if (progress.needs_question) {
                if (question_announce_now and progress.text.len != 0) {
                    std.debug.print(
                        "weixin send({d}): kind=ai_question generation={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                        .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                    );
                    self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                        std.debug.print("weixin send({d}): kind=ai_question generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    };
                }
                continue;
            }

            if (progress.done and progress.text.len != 0) {
                std.debug.print(
                    "weixin send({d}): kind=ai_final generation={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                    .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                );
                self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                    std.debug.print("weixin send({d}): kind=ai_final generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    return;
                };
                std.debug.print("weixin send({d}): kind=ai_final generation={d} status=sent bytes={d}\n", .{ debugNowMs(), generation, progress.text.len });
                return;
            }

            if (schedule.pingDue(elapsed_ms) and progress.text.len != 0) {
                std.debug.print(
                    "weixin send({d}): kind=ai_progress generation={d} elapsed_ms={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                    .{ debugNowMs(), generation, elapsed_ms, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                );
                self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                    std.debug.print("weixin send({d}): kind=ai_progress generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    continue;
                };
                std.debug.print("weixin send({d}): kind=ai_progress generation={d} status=sent bytes={d}\n", .{ debugNowMs(), generation, progress.text.len });
            }
        }

        // Reached the window's edge with no final answer (the loop ran out, not a
        // stop/refresh). The token is about to expire, so prompt the user to send
        // a fresh message — a silent stop here looks exactly like the old bug.
        if (self.stop_requested.load(.acquire) or self.followup_generation.load(.acquire) != generation) return;
        std.debug.print(
            "weixin send({d}): kind=ai_window_expired generation={d} to_len={d} to_hash={x} context={}\n",
            .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), job.context_token.len != 0 },
        );
        self.sendTextLocked(job.to_user_id, AI_REPLY_WINDOW_EXPIRED_NOTICE, job.context_token) catch |err| {
            std.debug.print("weixin send({d}): kind=ai_window_expired generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
        };
    }

    fn allocProgressText(self: *Poller, baseline_transcript: []const u8) !struct { done: bool, needs_approval: bool, needs_question: bool, text: []u8 } {
        self.transcript_mutex.lock();
        defer self.transcript_mutex.unlock();

        const current = self.control.latestTranscript();
        const progress_value = reply_progress.progress(baseline_transcript, current);
        if (progress_value.needs_approval) {
            const subject = if (progress_value.approval_command.len != 0)
                progress_value.approval_command
            else
                progress_value.approval_tool;
            const clipped = clipUtf8(subject, 400);
            const text = try std.fmt.allocPrint(
                self.allocator,
                "⚠️ 副驾需要你确认是否执行：\n{s}\n\n回复 Y 同意 / N 拒绝。",
                .{clipped},
            );
            return .{ .done = false, .needs_approval = true, .needs_question = false, .text = text };
        }
        if (progress_value.needs_question) {
            // The snapshot's Question section already lists the numbered options;
            // wrap it with the Chinese instruction the WeChat user reads.
            const clipped = clipUtf8(progress_value.question_text, 1200);
            const text = try std.fmt.allocPrint(
                self.allocator,
                "❓ 副驾想请你选择：\n{s}\n\n回复序号，或直接输入你的答案。",
                .{clipped},
            );
            return .{ .done = false, .needs_approval = false, .needs_question = true, .text = text };
        }
        if (progress_value.text.len == 0) return .{ .done = progress_value.done, .needs_approval = false, .needs_question = false, .text = &.{} };
        return .{
            .done = progress_value.done,
            .needs_approval = false,
            .needs_question = false,
            .text = try self.allocator.dupe(u8, progress_value.text),
        };
    }
};

fn failureLabel(plan: media_inbound_mod.DownloadPlan) []const u8 {
    if (plan.kind == .file and plan.file_name.len != 0) return plan.file_name;
    return plan.kind.name();
}

fn appendFailureLine(allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), failed: []const []const u8) !void {
    if (failed.len == 0) return;
    if (receipt.items.len != 0) try receipt.appendSlice(allocator, "\n");
    try receipt.appendSlice(allocator, "文件接收失败：");
    for (failed, 0..) |name, i| {
        if (i != 0) try receipt.appendSlice(allocator, "、");
        try receipt.appendSlice(allocator, name);
    }
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{})
    else
        try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

fn debugHash(bytes: []const u8) u64 {
    if (bytes.len == 0) return 0;
    return std.hash.Wyhash.hash(0, bytes);
}

fn debugNowMs() i64 {
    return std.time.milliTimestamp();
}

/// Decides when an AI follow-up should ping progress: a fixed, increasingly
/// spaced set of checkpoints (30s, 2m, 5m, 10m, 20m). Pure and state-advancing
/// so each checkpoint fires exactly once; the caller drives it with monotonically
/// increasing `elapsed_ms` at AI_REPLY_POLL_MS steps. The ~30-minute window edge
/// is covered separately by the window-expired resend notice.
const ProgressSchedule = struct {
    checkpoint_index: usize = 0,

    fn pingDue(self: *ProgressSchedule, elapsed_ms: u64) bool {
        if (self.checkpoint_index < AI_REPLY_CHECKPOINTS_MS.len and
            elapsed_ms >= AI_REPLY_CHECKPOINTS_MS[self.checkpoint_index])
        {
            self.checkpoint_index += 1;
            return true;
        }
        return false;
    }
};

/// Tracks "announce a pending approval exactly once per episode". The followup
/// loop calls due() every tick with the current needs_approval flag: it returns
/// true on the first tick a new approval appears, false while it persists, and
/// resets when the approval clears so a later approval re-announces.
const ApprovalAnnouncer = struct {
    announced: bool = false,

    fn due(self: *ApprovalAnnouncer, needs_approval: bool) bool {
        if (!needs_approval) {
            self.announced = false;
            return false;
        }
        if (self.announced) return false;
        self.announced = true;
        return true;
    }
};

/// Clips `s` to at most `max` bytes WITHOUT splitting a UTF-8 codepoint, so a
/// truncated command (which may contain CJK paths) stays valid UTF-8 in the
/// WeChat message. Backs up off any trailing continuation bytes (0b10xxxxxx).
fn clipUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return s[0..end];
}

const FollowupJob = struct {
    baseline_transcript: []u8 = &.{},
    to_user_id: []u8 = &.{},
    context_token: []u8 = &.{},

    fn deinit(self: *FollowupJob, allocator: std.mem.Allocator) void {
        if (self.baseline_transcript.len != 0) allocator.free(self.baseline_transcript);
        if (self.to_user_id.len != 0) allocator.free(self.to_user_id);
        if (self.context_token.len != 0) allocator.free(self.context_token);
        self.* = .{};
    }
};

const t = std.testing;
const codec = @import("ilink_codec.zig");

const Captured = struct {
    sent: std.ArrayListUnmanaged([]u8) = .empty,
    routed: std.ArrayListUnmanaged([]u8) = .empty,
    routed_model_context: std.ArrayListUnmanaged([]u8) = .empty,
    routed_to: std.ArrayListUnmanaged([]u8) = .empty,
    routed_context: std.ArrayListUnmanaged([]u8) = .empty,
    fn deinit(self: *Captured) void {
        for (self.sent.items) |s| t.allocator.free(s);
        for (self.routed.items) |s| t.allocator.free(s);
        for (self.routed_model_context.items) |s| t.allocator.free(s);
        for (self.routed_to.items) |s| t.allocator.free(s);
        for (self.routed_context.items) |s| t.allocator.free(s);
        self.sent.deinit(t.allocator);
        self.routed.deinit(t.allocator);
        self.routed_model_context.deinit(t.allocator);
        self.routed_to.deinit(t.allocator);
        self.routed_context.deinit(t.allocator);
    }
};

const RouteCtx = struct {
    cap: *Captured,
    fn route(ctx: *anyopaque, text: []const u8, model_context: []const u8, to_user_id: []const u8, context_token: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!RouteResult {
        const self: *RouteCtx = @ptrCast(@alignCast(ctx));
        try self.cap.routed.append(t.allocator, try t.allocator.dupe(u8, text));
        try self.cap.routed_model_context.append(t.allocator, try t.allocator.dupe(u8, model_context));
        try self.cap.routed_to.append(t.allocator, try t.allocator.dupe(u8, to_user_id));
        try self.cap.routed_context.append(t.allocator, try t.allocator.dupe(u8, context_token));
        try reply.appendSlice(allocator, "ok");
        return .{};
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

const ProgressCtx = struct {
    started: bool = false,
    stopped: bool = false,
    baseline: std.ArrayListUnmanaged(u8) = .empty,
    to_user_id: std.ArrayListUnmanaged(u8) = .empty,
    context_token: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ProgressCtx) void {
        self.baseline.deinit(t.allocator);
        self.to_user_id.deinit(t.allocator);
        self.context_token.deinit(t.allocator);
    }

    fn start(ctx: *anyopaque, baseline_transcript: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx));
        self.started = true;
        try self.baseline.appendSlice(t.allocator, baseline_transcript);
        try self.to_user_id.appendSlice(t.allocator, to_user_id);
        try self.context_token.appendSlice(t.allocator, context_token);
    }

    fn stop(ctx: *anyopaque) void {
        const self: *ProgressCtx = @ptrCast(@alignCast(ctx));
        self.stopped = true;
    }
};

const FakeClient = struct {
    get_calls: usize = 0,
    send_count: usize = 0,

    fn api(self: *FakeClient) ilink.ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = getUpdates,
            .send_text = sendText,
            .send_attachment = sendAttachment,
            .download_attachment = downloadAttachment,
        } };
    }

    fn downloadAttachment(ctx: *anyopaque, allocator: std.mem.Allocator, enc: []const u8, key: []const u8, allow_plain: bool) anyerror![]u8 {
        _ = ctx;
        _ = enc;
        _ = key;
        _ = allow_plain;
        return allocator.dupe(u8, "");
    }

    fn getUpdates(ctx: *anyopaque, _: []const u8) anyerror!codec.ParsedUpdates {
        const self: *FakeClient = @ptrCast(@alignCast(ctx));
        self.get_calls += 1;
        return codec.parseGetUpdates(t.allocator,
            \\{"ret":0,"get_updates_buf":"NEXT",
            \\"msgs":[{"from_user_id":"u1","context_token":"ctx",
            \\"item_list":[{"type":1,"text_item":{"text":"old"}}]}]}
        );
    }

    fn sendText(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
        const self: *FakeClient = @ptrCast(@alignCast(ctx));
        self.send_count += 1;
    }

    fn sendAttachment(
        ctx: *anyopaque,
        _: types.AttachmentKind,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) anyerror!void {
        _ = ctx;
    }
};

const SyncCapture = struct {
    value: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *SyncCapture) void {
        self.value.deinit(t.allocator);
    }

    fn save(ctx: *anyopaque, sync_buf: []const u8) anyerror!void {
        const self: *SyncCapture = @ptrCast(@alignCast(ctx));
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(t.allocator, sync_buf);
    }
};

const NoopControl = struct {
    fn isConnected(_: *anyopaque) bool {
        return true;
    }
    fn findAiSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn findTerminalSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn openAiAgent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn openAiAgentProfile(_: *anyopaque, _: []const u8, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn modelProfiles(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn switchAiProfile(_: *anyopaque, _: []const u8) control_mod.SwitchModelResult {
        return .offline;
    }
    fn sendInput(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) control_mod.SendResult {
        return .offline;
    }
    fn latestTranscript(_: *anyopaque) []const u8 {
        return "";
    }
    fn aiApprovalPending(_: *anyopaque) bool {
        return false;
    }
    fn resolveAiApproval(_: *anyopaque, _: bool) bool {
        return false;
    }
    fn aiQuestionOptionCount(_: *anyopaque) usize {
        return 0;
    }
    fn resolveAiQuestion(_: *anyopaque, _: types.QuestionReply) bool {
        return false;
    }
    fn inboundFileDir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn listAiConversations(_: *anyopaque, out: *control_mod.ConversationList) void {
        out.count = 0;
    }
    fn pinAiConversationByIndex(_: *anyopaque, _: usize, _: *control_mod.Conversation) bool {
        return false;
    }
    var dummy: u8 = 0;
    fn iface() control_mod.Control {
        return .{ .ctx = &dummy, .vtable = &.{
            .is_connected = isConnected,
            .find_ai_surface = findAiSurface,
            .find_terminal_surface = findTerminalSurface,
            .open_ai_agent = openAiAgent,
            .open_ai_agent_profile = openAiAgentProfile,
            .model_profiles = modelProfiles,
            .switch_ai_profile = switchAiProfile,
            .send_input = sendInput,
            .latest_transcript = latestTranscript,
            .ai_approval_pending = aiApprovalPending,
            .resolve_ai_approval = resolveAiApproval,
            .ai_question_option_count = aiQuestionOptionCount,
            .resolve_ai_question = resolveAiQuestion,
            .inbound_file_dir = inboundFileDir,
            .list_ai_conversations = listAiConversations,
            .pin_ai_conversation_by_index = pinAiConversationByIndex,
        } };
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
    try t.expectEqualStrings("u1", cap.routed_to.items[0]);
    try t.expectEqualStrings("c", cap.routed_context.items[0]);
    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("ok", cap.sent.items[0]);
}

test "processUpdates starts AI followup after ack reply is sent" {
    const Route = struct {
        fn route(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!RouteResult {
            try reply.appendSlice(allocator, "ack");
            return .{
                .expect_ai_progress = true,
                .baseline_transcript = try allocator.dupe(u8, "Status:\nReady\n"),
            };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var sctx = SendCtx{ .cap = &cap };
    var pctx = ProgressCtx{};
    defer pctx.deinit();
    var route_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{.{ .type = 1, .text = "hello" }} },
    };

    try processUpdates(.{
        .allocator = t.allocator,
        .owner = "u1",
        .account_id = "",
        .messages = &msgs,
        .route_ctx = &route_ctx,
        .route_fn = Route.route,
        .send_ctx = &sctx,
        .send_fn = SendCtx.send,
        .progress_ctx = &pctx,
        .start_progress_fn = ProgressCtx.start,
    });

    try t.expectEqualStrings("ack", cap.sent.items[0]);
    try t.expect(pctx.started);
    try t.expectEqualStrings("Status:\nReady\n", pctx.baseline.items);
    try t.expectEqualStrings("u1", pctx.to_user_id.items);
    try t.expectEqualStrings("ctx", pctx.context_token.items);
}

test "processUpdates routes inbound voice transcript as message text" {
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "voice-ctx", .item_list = &.{.{ .type = 3, .voice_text = "transcribed command" }} },
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
    try t.expectEqualStrings("transcribed command", cap.routed.items[0]);
    try t.expectEqualStrings("u1", cap.routed_to.items[0]);
    try t.expectEqualStrings("voice-ctx", cap.routed_context.items[0]);
}

test "processUpdates sends the receipt as ack and routes the synthetic prompt for media" {
    const MediaCtx = struct {
        fn media(_: *anyopaque, _: types.Message, allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), prompt: *std.ArrayListUnmanaged(u8), model_context: *std.ArrayListUnmanaged(u8)) anyerror!MediaOutcome {
            try receipt.appendSlice(allocator, "已收到文件：a.pdf");
            try prompt.appendSlice(allocator, "用户通过微信发送了文件：a.pdf");
            try model_context.appendSlice(allocator, "没有附加明确指令时，只回复“收到”。本地文件路径：/work/weixin_inbound/a.pdf");
            return .{ .handled = true, .any_saved = true };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };
    var pctx = ProgressCtx{};
    defer pctx.deinit();
    var media_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{
            .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        } },
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
        .progress_ctx = &pctx,
        .start_progress_fn = ProgressCtx.start,
        .media_ctx = &media_ctx,
        .media_fn = MediaCtx.media,
    });

    // Receipt is the only ack sent (route reply suppressed).
    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("已收到文件：a.pdf", cap.sent.items[0]);
    // The synthetic prompt was routed to the copilot.
    try t.expectEqual(@as(usize, 1), cap.routed.items.len);
    try t.expectEqualStrings("用户通过微信发送了文件：a.pdf", cap.routed.items[0]);
    try t.expect(std.mem.indexOf(u8, cap.routed.items[0], "/work/") == null);
    try t.expectEqual(@as(usize, 1), cap.routed_model_context.items.len);
    try t.expect(std.mem.indexOf(u8, cap.routed_model_context.items[0], "/work/weixin_inbound/a.pdf") != null);
    try t.expect(std.mem.indexOf(u8, cap.routed_model_context.items[0], "只回复“收到”") != null);
    // RouteCtx.route returns .{} (no progress), so streaming is not started here.
}

test "processUpdates skips routing when media is handled but nothing saved" {
    const MediaCtx = struct {
        fn media(_: *anyopaque, _: types.Message, allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), prompt: *std.ArrayListUnmanaged(u8), model_context: *std.ArrayListUnmanaged(u8)) anyerror!MediaOutcome {
            _ = prompt;
            _ = model_context;
            try receipt.appendSlice(allocator, "文件接收失败：a.pdf");
            return .{ .handled = true, .any_saved = false };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };
    var media_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{
            .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        } },
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
        .media_ctx = &media_ctx,
        .media_fn = MediaCtx.media,
    });

    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("文件接收失败：a.pdf", cap.sent.items[0]);
    try t.expectEqual(@as(usize, 0), cap.routed.items.len);
}

test "processUpdates cancels AI followup when a routed message reports stop_followup" {
    const Route = struct {
        fn route(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!RouteResult {
            try reply.appendSlice(allocator, "已发送停止指令。");
            return .{ .stop_followup = true };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var sctx = SendCtx{ .cap = &cap };
    var pctx = ProgressCtx{};
    defer pctx.deinit();
    var route_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{.{ .type = 1, .text = "/stop" }} },
    };

    try processUpdates(.{
        .allocator = t.allocator,
        .owner = "u1",
        .account_id = "",
        .messages = &msgs,
        .route_ctx = &route_ctx,
        .route_fn = Route.route,
        .send_ctx = &sctx,
        .send_fn = SendCtx.send,
        .progress_ctx = &pctx,
        .start_progress_fn = ProgressCtx.start,
        .stop_progress_fn = ProgressCtx.stop,
    });

    try t.expect(pctx.stopped);
    try t.expect(!pctx.started);
    try t.expectEqualStrings("已发送停止指令。", cap.sent.items[0]);
}

test "poller bootstrap advances cursor without replying to historical messages" {
    var fake = FakeClient{};
    var sync = SyncCapture{};
    defer sync.deinit();

    var p = Poller{
        .allocator = t.allocator,
        .client = fake.api(),
        .control = NoopControl.iface(),
        .settings = .{},
        .owner = "u1",
        .account_id = "",
        .sync_buf = try t.allocator.dupe(u8, "OLD"),
        .sync_callback = .{ .ctx = &sync, .callback = SyncCapture.save },
        .bootstrap_skip_pending = true,
    };
    defer t.allocator.free(p.sync_buf);

    try p.tickOnce();

    try t.expectEqual(@as(usize, 1), fake.get_calls);
    try t.expectEqual(@as(usize, 0), fake.send_count);
    try t.expect(!p.bootstrap_skip_pending);
    try t.expectEqualStrings("NEXT", p.sync_buf);
    try t.expectEqualStrings("NEXT", sync.value.items);
}

test "ai reply window extends to the 30-minute context-token validity with a resend margin" {
    // The bug: replies were abandoned after deadline = max(reply_timeout_ms, 120s)
    // <= 180s, so any AI task slower than ~3 minutes never delivered its answer.
    // The real ceiling is the WeChat context_token validity (~30 minutes).
    try t.expectEqual(@as(u64, 30 * 60 * 1000), CONTEXT_TOKEN_WINDOW_MS);
    // We keep waiting (and can deliver a final answer) far beyond the old cap.
    try t.expect(AI_REPLY_DEADLINE_MS > 180_000);
    try t.expect(AI_REPLY_DEADLINE_MS >= 25 * 60 * 1000);
    // The resend notice still goes out on a valid token, before the hard expiry.
    try t.expect(AI_REPLY_DEADLINE_MS < CONTEXT_TOKEN_WINDOW_MS);
    try t.expectEqual(CONTEXT_TOKEN_WINDOW_MS - EXPIRY_NOTICE_MARGIN_MS, AI_REPLY_DEADLINE_MS);
}

test "progress schedule pings at increasingly spaced checkpoints up to the window edge" {
    var sched = ProgressSchedule{};
    var pings: std.ArrayListUnmanaged(u64) = .empty;
    defer pings.deinit(t.allocator);

    var elapsed_ms: u64 = 0;
    while (elapsed_ms < AI_REPLY_DEADLINE_MS) {
        elapsed_ms += AI_REPLY_POLL_MS;
        if (sched.pingDue(elapsed_ms)) try pings.append(t.allocator, elapsed_ms);
    }

    // Exactly the fixed cadence: 30s, 2m, 5m, 10m, 20m — each fires once and
    // there is no extra heartbeat beyond the last checkpoint.
    const expected = [_]u64{ 30_000, 120_000, 300_000, 600_000, 1_200_000 };
    try t.expectEqual(expected.len, pings.items.len);
    for (expected, pings.items) |want, got| try t.expectEqual(want, got);
    // The ~30-minute window edge is handled by the resend notice, not a ping, so
    // every checkpoint still lands well before the send deadline.
    const last = pings.items[pings.items.len - 1];
    try t.expect(last < AI_REPLY_DEADLINE_MS);
}

test "approval announcer fires once per pending episode and resets" {
    var a = ApprovalAnnouncer{};
    try t.expect(!a.due(false));
    try t.expect(a.due(true)); // first pending tick → send
    try t.expect(!a.due(true)); // still pending → silent
    try t.expect(!a.due(false)); // cleared → reset
    try t.expect(a.due(true)); // new pending episode → send again
}

test "clipUtf8 never splits a codepoint" {
    try t.expectEqualStrings("rm -rf /tmp/x", clipUtf8("rm -rf /tmp/x", 400)); // shorter than max
    try t.expectEqualStrings("abc", clipUtf8("abcdef", 3)); // ASCII boundary
    // "测试" is 6 bytes (3 each). Cutting at 4 would split the 2nd char → drop it.
    try t.expectEqualStrings("测", clipUtf8("测试", 4));
    // Cutting at 3 lands exactly on the boundary after the 1st char.
    try t.expectEqualStrings("测", clipUtf8("测试", 3));
    // Cutting mid first char drops it entirely rather than emitting partial bytes.
    try t.expectEqualStrings("", clipUtf8("测", 2));
}

const ApprovalTranscriptControl = struct {
    fn isConnected(_: *anyopaque) bool {
        return true;
    }
    fn findAiSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn findTerminalSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn openAiAgent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn openAiAgentProfile(_: *anyopaque, _: []const u8, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn modelProfiles(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn switchAiProfile(_: *anyopaque, _: []const u8) control_mod.SwitchModelResult {
        return .offline;
    }
    fn sendInput(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) control_mod.SendResult {
        return .offline;
    }
    fn latestTranscript(_: *anyopaque) []const u8 {
        return "Model:\nGLM\n\nStatus:\nApproval needed\n\n" ++
            "Approval:\nterminal_repl_exec\nrm -rf /tmp/x\n\nYou:\nclean up\n";
    }
    fn aiApprovalPending(_: *anyopaque) bool {
        return true;
    }
    fn resolveAiApproval(_: *anyopaque, _: bool) bool {
        return false;
    }
    fn aiQuestionOptionCount(_: *anyopaque) usize {
        return 0;
    }
    fn resolveAiQuestion(_: *anyopaque, _: types.QuestionReply) bool {
        return false;
    }
    fn inboundFileDir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn listAiConversations(_: *anyopaque, out: *control_mod.ConversationList) void {
        out.count = 0;
    }
    fn pinAiConversationByIndex(_: *anyopaque, _: usize, _: *control_mod.Conversation) bool {
        return false;
    }
    var dummy: u8 = 0;
    fn iface() control_mod.Control {
        return .{ .ctx = &dummy, .vtable = &.{
            .is_connected = isConnected,
            .find_ai_surface = findAiSurface,
            .find_terminal_surface = findTerminalSurface,
            .open_ai_agent = openAiAgent,
            .open_ai_agent_profile = openAiAgentProfile,
            .model_profiles = modelProfiles,
            .switch_ai_profile = switchAiProfile,
            .send_input = sendInput,
            .latest_transcript = latestTranscript,
            .ai_approval_pending = aiApprovalPending,
            .resolve_ai_approval = resolveAiApproval,
            .ai_question_option_count = aiQuestionOptionCount,
            .resolve_ai_question = resolveAiQuestion,
            .inbound_file_dir = inboundFileDir,
            .list_ai_conversations = listAiConversations,
            .pin_ai_conversation_by_index = pinAiConversationByIndex,
        } };
    }
};

test "allocProgressText surfaces a needs-approval prompt naming the command" {
    const empty_sync = try t.allocator.alloc(u8, 0);
    defer t.allocator.free(empty_sync);
    var p = Poller{
        .allocator = t.allocator,
        .client = undefined, // unused by allocProgressText
        .control = ApprovalTranscriptControl.iface(),
        .settings = .{},
        .owner = "u1",
        .account_id = "",
        .sync_buf = empty_sync,
    };
    const r = try p.allocProgressText("Model:\nGLM\n\nStatus:\nReady\n\nYou:\nclean up\n");
    defer if (r.text.len != 0) t.allocator.free(r.text);
    try t.expect(r.needs_approval);
    try t.expect(!r.done);
    try t.expect(std.mem.indexOf(u8, r.text, "rm -rf /tmp/x") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "回复 Y 同意 / N 拒绝") != null);
}

const DownloadFakeClient = struct {
    plaintext: []const u8,

    fn api(self: *DownloadFakeClient) ilink.ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = getUpdates,
            .send_text = sendText,
            .send_attachment = sendAttachment,
            .download_attachment = downloadAttachment,
        } };
    }
    fn getUpdates(_: *anyopaque, _: []const u8) anyerror!codec.ParsedUpdates {
        return error.NotUsed;
    }
    fn sendText(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn sendAttachment(_: *anyopaque, _: types.AttachmentKind, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn downloadAttachment(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: bool) anyerror![]u8 {
        const self: *DownloadFakeClient = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.plaintext);
    }
};

const TmpDirControl = struct {
    dir: []const u8,
    fn is_connected(_: *anyopaque) bool {
        return true;
    }
    fn find_ai_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn open_ai_agent_profile(_: *anyopaque, _: []const u8, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn model_profiles(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn switch_ai_profile(_: *anyopaque, _: []const u8) control_mod.SwitchModelResult {
        return .offline;
    }
    fn send_input(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) control_mod.SendResult {
        return .offline;
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
    fn resolve_ai_question(_: *anyopaque, _: types.QuestionReply) bool {
        return false;
    }
    fn inbound_file_dir(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *TmpDirControl = @ptrCast(@alignCast(ctx));
        const n = @min(self.dir.len, buf.len);
        @memcpy(buf[0..n], self.dir[0..n]);
        return buf[0..n];
    }
    fn list_ai_conversations(_: *anyopaque, out: *control_mod.ConversationList) void {
        out.count = 0;
    }
    fn pin_ai_conversation_by_index(_: *anyopaque, _: usize, _: *control_mod.Conversation) bool {
        return false;
    }
    fn iface(self: *TmpDirControl) control_mod.Control {
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

test "pollerMediaAdapter downloads, saves under weixin_inbound, and builds receipt + prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);

    var client = DownloadFakeClient{ .plaintext = "PDF-CONTENT" };
    var ctrl = TmpDirControl{ .dir = root };
    const empty_sync = try t.allocator.alloc(u8, 0);
    defer t.allocator.free(empty_sync);

    var p = Poller{
        .allocator = t.allocator,
        .client = client.api(),
        .control = ctrl.iface(),
        .settings = .{},
        .owner = "u1",
        .account_id = "",
        .sync_buf = empty_sync,
    };

    const msg = types.Message{
        .from_user_id = "u1",
        .context_token = "ctx",
        .item_list = &.{
            .{ .type = 1, .text = "请看这个" },
            .{ .type = 4, .file_name = "report.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "KEY" } },
        },
    };

    var receipt: std.ArrayListUnmanaged(u8) = .empty;
    defer receipt.deinit(t.allocator);
    var prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt.deinit(t.allocator);
    var model_context: std.ArrayListUnmanaged(u8) = .empty;
    defer model_context.deinit(t.allocator);
    const outcome = try p.pollerMediaAdapter(msg, t.allocator, &receipt, &prompt, &model_context);

    try t.expect(outcome.handled);
    try t.expect(outcome.any_saved);
    // File written under <root>/weixin_inbound/report.pdf with decrypted content.
    const saved_path = try std.fs.path.join(t.allocator, &.{ root, "weixin_inbound", "report.pdf" });
    defer t.allocator.free(saved_path);
    const data = try std.fs.cwd().readFileAlloc(t.allocator, saved_path, 1 << 20);
    defer t.allocator.free(data);
    try t.expectEqualStrings("PDF-CONTENT", data);
    // Receipt and visible prompt name the file; model-only context has the path.
    try t.expect(std.mem.indexOf(u8, receipt.items, "report.pdf") != null);
    try t.expect(std.mem.indexOf(u8, prompt.items, "report.pdf") != null);
    try t.expect(std.mem.indexOf(u8, prompt.items, saved_path) == null);
    try t.expect(std.mem.indexOf(u8, prompt.items, "请看这个") != null);
    try t.expect(std.mem.indexOf(u8, model_context.items, saved_path) != null);
    try t.expect(std.mem.indexOf(u8, model_context.items, "只回复“收到”") != null);
}
