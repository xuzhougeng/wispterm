//! Session-level prompt-queue operations: enqueue hooks, FIFO drain, and the
//! queue-panel selection / reorder / remove / recall actions.
//!
//! Split out of session.zig (file-size backstop) — the pure data structure
//! lives in prompt_queue.zig, while everything here operates on a `*Session`
//! under its documented conventions: `Locked` functions assume the session
//! mutex is already held, and `drainPromptQueue` is UI-thread only (main-loop
//! tick), never called from worker threads or history hooks.

const std = @import("std");
const session_mod = @import("session.zig");
const prompt_queue = @import("prompt_queue.zig");
const chatops_reply = @import("../../chatops/reply.zig");
const ai_chat_protocol = @import("protocol.zig");
const ai_chat_types = @import("types.zig");
const input_key = @import("../../input/key.zig");

const Session = session_mod.Session;
const OwnedReplyContext = ai_chat_types.OwnedReplyContext;

/// 把一条 prompt 追加到队列尾。假定 mutex 已持有。
/// take_images=true 时把 pending_images 一并移入条目（submit 路径，防止
/// 下一条正常提交偷走队列条目的图片）；reply_ctx 非空时为其建立 owned
/// 副本，否则迁移单槽位 pending_reply_context。返回 false 表示队列已满，
/// 此时不触碰图片/上下文，由调用方按原有拒绝行为收尾。
pub fn enqueueQueuedPromptLocked(self: *Session, text: []const u8, take_images: bool, reply_ctx: ?chatops_reply.ReplyContext) bool {
    if (self.prompt_queue.isFull()) {
        self.setStatusLocked("Prompt queue full");
        return false;
    }
    var images: ?[]ai_chat_protocol.ImageBlock = null;
    if (take_images) images = self.takePendingImages();
    var owned_ctx: ?OwnedReplyContext = null;
    if (reply_ctx) |rc| {
        owned_ctx = OwnedReplyContext.init(self.allocator, rc) catch null;
    } else if (self.pending_reply_context) |*pending| {
        owned_ctx = pending.*;
        self.pending_reply_context = null;
    }
    _ = self.prompt_queue.enqueue(text, images, owned_ctx, std.time.milliTimestamp()) catch {
        // OOM: release what we took so nothing leaks; treat as rejected.
        if (images) |imgs| {
            for (imgs) |img| img.deinit(self.allocator);
            self.allocator.free(imgs);
        }
        if (owned_ctx) |*ctx| ctx.deinit(self.allocator);
        return false;
    };
    self.queue_selected = self.prompt_queue.len() - 1;
    return true;
}

/// 把 entry 的图片挂回 pending_images（假定 mutex 已持有）。容器 slice
/// 总是被释放；append 失败（OOM）时连内容一起释放，不丢所有权。
fn restoreQueuedImagesLocked(self: *Session, images: ?[]ai_chat_protocol.ImageBlock) void {
    const imgs = images orelse return;
    self.pending_images.appendSlice(self.allocator, imgs) catch {
        for (imgs) |img| img.deinit(self.allocator);
    };
    self.allocator.free(imgs);
}

/// 主循环 tick（UI 线程）调用：空闲且队列非空时取出队首 prompt 走正常
/// submit 路径发送。返回 true 表示取出了一条（用于触发重绘）。绝不从
/// 工作线程或 history hook 调用——submit 系列函数有 UI 线程约定。
pub fn drainPromptQueue(self: *Session) bool {
    if (self.closing.load(.acquire)) return false;
    var draft_text: ?[]u8 = null;
    var draft_images: ?[]ai_chat_protocol.ImageBlock = null;
    defer {
        if (draft_text) |d| self.allocator.free(d);
        if (draft_images) |imgs| {
            for (imgs) |img| img.deinit(self.allocator);
            self.allocator.free(imgs);
        }
    }
    self.mutex.lock();
    if (self.request_inflight or self.prompt_queue.len() == 0) {
        self.mutex.unlock();
        return false;
    }
    var entry = self.prompt_queue.popHead().?;
    // 草稿保护：发送队列条目前暂存 composer 里的草稿文本/图片，发送成功
    // 消耗 composer 后再把草稿填回去。
    if (std.mem.trim(u8, self.input(), " \t\r\n").len != 0) {
        draft_text = self.allocator.dupe(u8, self.input()) catch null;
    }
    draft_images = self.takePendingImages();
    self.setInputTextLocked(entry.text);
    self.allocator.free(entry.text);
    restoreQueuedImagesLocked(self, entry.images);
    if (self.pending_reply_context) |*old| old.deinit(self.allocator);
    self.pending_reply_context = entry.reply_context;
    entry.reply_context = null;
    if (self.queue_selected > 0) self.queue_selected -= 1;
    closePanelIfEmptyLocked(self);
    self.mutex.unlock();

    self.submit();

    // submit 成功会清空 composer，这时把草稿填回；提交失败（如缺 API
    // key）时队列文本仍留在 composer 里，只把草稿图片挂回，避免丢失。
    self.mutex.lock();
    if (std.mem.trim(u8, self.input(), " \t\r\n").len == 0) {
        if (draft_text) |d| {
            self.setInputTextLocked(d);
            self.allocator.free(d);
            draft_text = null;
        }
    }
    restoreQueuedImagesLocked(self, draft_images);
    draft_images = null;
    self.mutex.unlock();
    return true;
}

/// 开关队列面板（命令面板 Show Prompt Queue 入口）。
pub fn togglePromptQueuePanel(self: *Session) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.queue_open) {
        self.queue_open = false;
        return;
    }
    const count = self.prompt_queue.len();
    self.queue_selected = if (count == 0) 0 else @min(self.queue_selected, count - 1);
    self.queue_open = true;
}

/// 清空队列（命令面板 Clear Prompt Queue 入口），返回清掉的条数。
pub fn clearPromptQueue(self: *Session) usize {
    self.mutex.lock();
    defer self.mutex.unlock();
    const n = self.prompt_queue.len();
    self.prompt_queue.clear();
    self.queue_selected = 0;
    self.queue_open = false;
    return n;
}

fn closePanelIfEmptyLocked(self: *Session) void {
    if (self.prompt_queue.len() == 0) self.queue_open = false;
}

/// Queue-panel key dispatch. Returns true if the key was consumed. An empty
/// panel closes without swallowing Enter (so a following submit still fires);
/// Escape and other keys still close and consume so they cannot stop an
/// in-flight request or arm rewind. Enter with composer text dismisses the
/// panel and falls through so the new prompt is submitted (and re-queued if
/// the request is still inflight) instead of recalling the selected entry.
pub fn handlePanelKey(self: *Session, ev: input_key.KeyEvent) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (!self.queue_open) return false;
    if (self.prompt_queue.len() == 0) {
        self.queue_open = false;
        return ev.key != .enter;
    }
    switch (ev.key) {
        .arrow_up => if (ev.alt) moveQueuedPromptLocked(self, -1) else moveQueueSelectionLocked(self, -1),
        .arrow_down => if (ev.alt) moveQueuedPromptLocked(self, 1) else moveQueueSelectionLocked(self, 1),
        .delete, .backspace => removeSelectedQueuedPromptLocked(self),
        .enter => {
            if (std.mem.trim(u8, self.input(), " \t\r\n").len == 0) {
                recallSelectedQueuedPromptLocked(self);
                self.queue_open = false;
                return true;
            }
            self.queue_open = false;
            return false;
        },
        else => self.queue_open = false,
    }
    return true;
}

/// 在 [0, len) 内移动面板选中项，到边界停住（不回绕）。假定 mutex 已持有。
pub fn moveQueueSelectionLocked(self: *Session, delta: i32) void {
    const count = self.prompt_queue.len();
    if (count == 0) {
        self.queue_selected = 0;
        return;
    }
    var cur: i64 = @intCast(@min(self.queue_selected, count - 1));
    cur += delta;
    if (cur < 0) cur = 0;
    const max_i: i64 = @intCast(count - 1);
    if (cur > max_i) cur = max_i;
    self.queue_selected = @intCast(cur);
}

/// Alt+↑/↓：把选中条目向队首/队尾挪一位，选中跟随条目。假定 mutex 已持有。
pub fn moveQueuedPromptLocked(self: *Session, delta: i32) void {
    const count = self.prompt_queue.len();
    if (count == 0) return;
    const sel = @min(self.queue_selected, count - 1);
    const moved = if (delta < 0) self.prompt_queue.moveUp(sel) else self.prompt_queue.moveDown(sel);
    if (moved) moveQueueSelectionLocked(self, delta);
}

/// 删除选中条目。假定 mutex 已持有。
pub fn removeSelectedQueuedPromptLocked(self: *Session) void {
    const count = self.prompt_queue.len();
    if (count == 0) return;
    const sel = @min(self.queue_selected, count - 1);
    _ = self.prompt_queue.remove(sel);
    const remain = self.prompt_queue.len();
    self.queue_selected = if (remain == 0) 0 else @min(sel, remain - 1);
    closePanelIfEmptyLocked(self);
}

/// 把选中条目取回 composer 编辑：出队，文本/图片/回复上下文回到输入区。
/// 假定 mutex 已持有。
pub fn recallSelectedQueuedPromptLocked(self: *Session) void {
    const count = self.prompt_queue.len();
    if (count == 0) return;
    const sel = @min(self.queue_selected, count - 1);
    var entry = self.prompt_queue.take(sel) orelse return;
    self.setInputTextLocked(entry.text);
    self.allocator.free(entry.text);
    restoreQueuedImagesLocked(self, entry.images);
    if (entry.reply_context) |*ctx| {
        if (self.pending_reply_context) |*old| old.deinit(self.allocator);
        self.pending_reply_context = ctx.*;
        entry.reply_context = null;
    }
    const remain = self.prompt_queue.len();
    self.queue_selected = if (remain == 0) 0 else @min(sel, remain - 1);
}

const TestSenderCapture = struct {
    fn send(
        ctx: *anyopaque,
        kind: chatops_reply.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        _ = ctx;
        _ = kind;
        _ = path;
        _ = display_name;
        _ = to_user_id;
        _ = context_token;
    }
};

fn testSender(capture: *TestSenderCapture) chatops_reply.AttachmentSender {
    return .{ .ctx = capture, .send_attachment = TestSenderCapture.send };
}

fn testSession(allocator: std.mem.Allocator, api_key: []const u8) !*Session {
    return Session.init(
        allocator,
        "test",
        "https://api.example",
        api_key,
        "model",
        "prompt",
        "enabled",
        "medium",
        "false",
        "true",
    );
}

test "prompt queue: busy submitScheduledPrompt enqueues FIFO instead of dropping" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    session.request_inflight = true;
    session.mutex.unlock();

    try std.testing.expect(session.submitScheduledPrompt("first"));
    try std.testing.expect(session.submitScheduledPrompt("second"));

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 2), session.prompt_queue.len());
    try std.testing.expectEqualStrings("first", session.prompt_queue.entries.items[0].text);
    try std.testing.expectEqualStrings("second", session.prompt_queue.entries.items[1].text);
    // 调度路径不动 composer。
    try std.testing.expectEqual(@as(usize, 0), session.input().len);
}

test "prompt queue: busy applyChatInput keeps a per-entry reply context" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    session.setInputTextLocked("draft");
    session.request_inflight = true;
    session.mutex.unlock();

    var capture = TestSenderCapture{};
    try std.testing.expect(session.applyChatInput("wx one", .{
        .sender = testSender(&capture),
        .to_user_id = "user-a",
        .context_token = "ctx-a",
    }));
    try std.testing.expect(session.applyChatInput("wx two\r\n", .{
        .sender = testSender(&capture),
        .to_user_id = "user-b",
        .context_token = "ctx-b",
    }));

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 2), session.prompt_queue.len());
    const first = session.prompt_queue.entries.items[0];
    const second = session.prompt_queue.entries.items[1];
    try std.testing.expectEqualStrings("wx one", first.text);
    try std.testing.expectEqualStrings("wx two", second.text); // trailing CR/LF stripped
    try std.testing.expectEqualStrings("user-a", first.reply_context.?.to_user_id);
    try std.testing.expectEqualStrings("ctx-a", first.reply_context.?.context_token);
    try std.testing.expectEqualStrings("user-b", second.reply_context.?.to_user_id);
    // 每条各存各的 ctx，单槽位 pending_reply_context 保持空。
    try std.testing.expect(session.pending_reply_context == null);
    try std.testing.expectEqualStrings("draft", session.input());
}

test "prompt queue: enqueue takes pending images so a later submit cannot steal them" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    try session.addPendingImage("aW1n", "image/png");
    try std.testing.expect(enqueueQueuedPromptLocked(session, "with image", true, null));
    try std.testing.expectEqual(@as(usize, 0), session.pending_images.items.len);
    const entry = session.prompt_queue.entries.items[0];
    try std.testing.expectEqual(@as(usize, 1), entry.images.?.len);
    try std.testing.expectEqualStrings("aW1n", entry.images.?[0].data_b64);
    try std.testing.expectEqualStrings("image/png", entry.images.?[0].media_type);
}

test "prompt queue: full queue rejects without touching images or context" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    for (0..prompt_queue.MAX_ENTRIES) |_| {
        try std.testing.expect(enqueueQueuedPromptLocked(session, "prompt", false, null));
    }
    try std.testing.expect(session.prompt_queue.isFull());
    try session.addPendingImage("aW1n", "image/png");
    try std.testing.expect(!enqueueQueuedPromptLocked(session, "overflow", true, null));
    // 满了就不取走图片，保持原有拒绝行为（提交方自己收尾）。
    try std.testing.expectEqual(@as(usize, 1), session.pending_images.items.len);
    try std.testing.expectEqual(prompt_queue.MAX_ENTRIES, session.prompt_queue.len());
}

test "prompt queue: recall returns text and images to the composer" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    try session.addPendingImage("aW1n", "image/png");
    try std.testing.expect(enqueueQueuedPromptLocked(session, "edit me", true, null));
    try std.testing.expect(enqueueQueuedPromptLocked(session, "stay", false, null));
    session.queue_selected = 0;
    recallSelectedQueuedPromptLocked(session);
    defer session.mutex.unlock();

    try std.testing.expectEqual(@as(usize, 1), session.prompt_queue.len());
    try std.testing.expectEqualStrings("stay", session.prompt_queue.entries.items[0].text);
    try std.testing.expectEqualStrings("edit me", session.input());
    try std.testing.expectEqual(@as(usize, 1), session.pending_images.items.len);
    try std.testing.expectEqualStrings("aW1n", session.pending_images.items[0].data_b64);
}

test "prompt queue: panel selection, reorder, and remove stay clamped" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "a", false, null));
    try std.testing.expect(enqueueQueuedPromptLocked(session, "b", false, null));
    try std.testing.expect(enqueueQueuedPromptLocked(session, "c", false, null));

    session.queue_selected = 2;
    moveQueueSelectionLocked(session, 1); // clamp at tail
    try std.testing.expectEqual(@as(usize, 2), session.queue_selected);
    moveQueueSelectionLocked(session, -5); // clamp at head
    try std.testing.expectEqual(@as(usize, 0), session.queue_selected);

    session.queue_selected = 2;
    moveQueuedPromptLocked(session, -1); // "c" toward head, selection follows
    try std.testing.expectEqual(@as(usize, 1), session.queue_selected);
    try std.testing.expectEqualStrings("c", session.prompt_queue.entries.items[1].text);

    removeSelectedQueuedPromptLocked(session);
    try std.testing.expectEqual(@as(usize, 2), session.prompt_queue.len());
    try std.testing.expectEqualStrings("b", session.prompt_queue.entries.items[1].text);
    try std.testing.expectEqual(@as(usize, 1), session.queue_selected);
}

test "prompt queue: drain guards on busy and empty" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    try std.testing.expect(!session.drainPromptQueue()); // empty

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "queued", false, null));
    session.request_inflight = true;
    session.mutex.unlock();
    try std.testing.expect(!session.drainPromptQueue()); // busy

    session.mutex.lock();
    session.request_inflight = false;
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), session.prompt_queue.len());
}

test "prompt queue: drain replays the head through the normal submit path" {
    const allocator = std.testing.allocator;
    // Empty API key + non-DeepSeek base URL: submit() early-outs on
    // missingApiKey without spawning a request thread, so the drained head
    // lands in the composer and stays there.
    const session = try testSession(allocator, "");
    defer session.deinit();

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "first", false, null));
    try std.testing.expect(enqueueQueuedPromptLocked(session, "second", false, null));
    session.mutex.unlock();

    try std.testing.expect(session.drainPromptQueue());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), session.prompt_queue.len());
    try std.testing.expectEqualStrings("second", session.prompt_queue.entries.items[0].text);
    try std.testing.expectEqualStrings("first", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expect(!session.request_inflight);
}

test "prompt queue: drain closes the panel after the last entry is sent" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "");
    defer session.deinit();

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "only", false, null));
    session.queue_open = true;
    session.mutex.unlock();

    try std.testing.expect(session.drainPromptQueue());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), session.prompt_queue.len());
    try std.testing.expect(!session.queue_open);
}

test "prompt queue: drain keeps the panel open while entries remain" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "");
    defer session.deinit();

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "first", false, null));
    try std.testing.expect(enqueueQueuedPromptLocked(session, "second", false, null));
    session.queue_open = true;
    session.mutex.unlock();

    try std.testing.expect(session.drainPromptQueue());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), session.prompt_queue.len());
    try std.testing.expect(session.queue_open);
}

test "prompt queue: removing the last entry closes the panel" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "only", false, null));
    session.queue_open = true;
    session.queue_selected = 0;
    removeSelectedQueuedPromptLocked(session);
    try std.testing.expectEqual(@as(usize, 0), session.prompt_queue.len());
    try std.testing.expect(!session.queue_open);
}

test "prompt queue: empty panel lets Enter fall through" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.queue_open = true;
    try std.testing.expect(!handlePanelKey(session, .{ .key = .enter }));
    try std.testing.expect(!session.queue_open);
}

test "prompt queue: empty panel still consumes Escape" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.queue_open = true;
    try std.testing.expect(handlePanelKey(session, .{ .key = .escape }));
    try std.testing.expect(!session.queue_open);
}

test "prompt queue: Enter with composer text dismisses instead of recalling" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "queued", false, null));
    session.setInputTextLocked("new prompt");
    session.queue_open = true;
    session.mutex.unlock();

    try std.testing.expect(!handlePanelKey(session, .{ .key = .enter }));

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(!session.queue_open);
    try std.testing.expectEqual(@as(usize, 1), session.prompt_queue.len());
    try std.testing.expectEqualStrings("queued", session.prompt_queue.entries.items[0].text);
    try std.testing.expectEqualStrings("new prompt", session.input());
}

test "prompt queue: Enter with empty composer recalls the selected entry" {
    const allocator = std.testing.allocator;
    const session = try testSession(allocator, "key");
    defer session.deinit();

    session.mutex.lock();
    try std.testing.expect(enqueueQueuedPromptLocked(session, "edit me", false, null));
    session.queue_open = true;
    session.queue_selected = 0;
    session.mutex.unlock();

    try std.testing.expect(handlePanelKey(session, .{ .key = .enter }));

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expect(!session.queue_open);
    try std.testing.expectEqual(@as(usize, 0), session.prompt_queue.len());
    try std.testing.expectEqualStrings("edit me", session.input());
}
