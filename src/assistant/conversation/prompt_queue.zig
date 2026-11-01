//! FIFO queue of prompts submitted while a request is inflight.
//!
//! Pure data structure with no session, threading, or platform dependencies, so
//! it runs in the fast test suite. Entries own their text / images / reply
//! context: `enqueue` duplicates the text and takes ownership of the image
//! slice and reply context; `popHead`/`take` transfer that ownership to the
//! caller, while `remove`/`clear`/`deinit` release it. Nothing is persisted —
//! the queue dies with its owning Session.

const std = @import("std");
const ai_chat_protocol = @import("protocol.zig");
const ai_chat_types = @import("types.zig");

pub const ImageBlock = ai_chat_protocol.ImageBlock;
pub const OwnedReplyContext = ai_chat_types.OwnedReplyContext;

/// Hard cap on queued prompts per session; `enqueue` fails beyond this.
pub const MAX_ENTRIES: usize = 32;

pub const Entry = struct {
    id: u32,
    text: []u8,
    images: ?[]ImageBlock = null,
    reply_context: ?OwnedReplyContext = null,
    queued_ms: i64 = 0,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.images) |images| {
            for (images) |img| img.deinit(allocator);
            allocator.free(images);
        }
        if (self.reply_context) |*ctx| ctx.deinit(allocator);
        self.* = undefined;
    }
};

pub const PromptQueue = struct {
    // Defaults to `undefined` so `Session` can offer `prompt_queue = .{}` to
    // the struct-literal test idiom (`Session{ .allocator = a }`). A default
    // queue is an empty shell: `len`/`clear`/`deinit` are safe on it, but any
    // allocating call (`enqueue`/`editText`) requires `init()` first.
    allocator: std.mem.Allocator = undefined,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) PromptQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PromptQueue) void {
        self.clear();
        // Skip the allocator entirely when nothing was ever allocated, so a
        // default-constructed shell (undefined allocator) deinits safely.
        if (self.entries.capacity > 0) self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const PromptQueue) usize {
        return self.entries.items.len;
    }

    pub fn isFull(self: *const PromptQueue) bool {
        return self.entries.items.len >= MAX_ENTRIES;
    }

    /// Append a prompt to the tail. `text` is duplicated; `images` and
    /// `reply_context` ownership moves into the new entry (even on OutOfMemory
    /// they stay with the caller — the queue only takes them on success).
    /// Returns the entry id.
    pub fn enqueue(
        self: *PromptQueue,
        text: []const u8,
        images: ?[]ImageBlock,
        reply_context: ?OwnedReplyContext,
        queued_ms: i64,
    ) error{ Full, OutOfMemory }!u32 {
        if (self.isFull()) return error.Full;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const id = self.next_id;
        try self.entries.append(self.allocator, .{
            .id = id,
            .text = owned_text,
            .images = images,
            .reply_context = reply_context,
            .queued_ms = queued_ms,
        });
        self.next_id +%= 1;
        return id;
    }

    /// Detach the head entry (FIFO order), transferring ownership to the caller.
    pub fn popHead(self: *PromptQueue) ?Entry {
        if (self.entries.items.len == 0) return null;
        return self.entries.orderedRemove(0);
    }

    /// Detach the entry at `index`, transferring ownership to the caller.
    pub fn take(self: *PromptQueue, index: usize) ?Entry {
        if (index >= self.entries.items.len) return null;
        return self.entries.orderedRemove(index);
    }

    /// Remove the entry at `index` and release its owned memory.
    pub fn remove(self: *PromptQueue, index: usize) bool {
        var entry = self.take(index) orelse return false;
        entry.deinit(self.allocator);
        return true;
    }

    /// Move the entry at `index` one slot toward the head.
    pub fn moveUp(self: *PromptQueue, index: usize) bool {
        if (index == 0 or index >= self.entries.items.len) return false;
        std.mem.swap(Entry, &self.entries.items[index - 1], &self.entries.items[index]);
        return true;
    }

    /// Move the entry at `index` one slot toward the tail.
    pub fn moveDown(self: *PromptQueue, index: usize) bool {
        if (index + 1 >= self.entries.items.len) return false;
        std.mem.swap(Entry, &self.entries.items[index], &self.entries.items[index + 1]);
        return true;
    }

    /// Move the entry at `index` to the head (next to drain). No allocation.
    /// Returns false when `index` is out of range; already-at-head is success.
    pub fn moveToHead(self: *PromptQueue, index: usize) bool {
        if (index >= self.entries.items.len) return false;
        if (index == 0) return true;
        const items = self.entries.items;
        const entry = items[index];
        var i = index;
        while (i > 0) : (i -= 1) {
            items[i] = items[i - 1];
        }
        items[0] = entry;
        return true;
    }

    /// Replace an entry's text (e.g. after a round trip through the composer).
    pub fn editText(self: *PromptQueue, index: usize, new_text: []const u8) error{OutOfMemory}!bool {
        if (index >= self.entries.items.len) return false;
        const copy = try self.allocator.dupe(u8, new_text);
        self.allocator.free(self.entries.items[index].text);
        self.entries.items[index].text = copy;
        return true;
    }

    /// Release every entry, leaving the queue empty.
    pub fn clear(self: *PromptQueue) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }
};

fn testImage(allocator: std.mem.Allocator, data_b64: []const u8, media_type: []const u8) !ImageBlock {
    return .{
        .data_b64 = try allocator.dupe(u8, data_b64),
        .media_type = try allocator.dupe(u8, media_type),
    };
}

fn testImages(allocator: std.mem.Allocator, data_b64: []const u8) ![]ImageBlock {
    const imgs = try allocator.alloc(ImageBlock, 1);
    imgs[0] = try testImage(allocator, data_b64, "image/png");
    return imgs;
}

const TestSenderCapture = struct {
    fn send(
        ctx: *anyopaque,
        kind: @import("../../chatops/reply.zig").AttachmentKind,
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

fn testReplyContext(allocator: std.mem.Allocator, to_user_id: []const u8) !OwnedReplyContext {
    var capture = TestSenderCapture{};
    return OwnedReplyContext.init(allocator, .{
        .sender = .{ .ctx = &capture, .send_attachment = TestSenderCapture.send },
        .to_user_id = to_user_id,
        .context_token = "ctx",
    });
}

test "enqueue appends FIFO and popHead transfers ownership" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("first", null, null, 1);
    _ = try queue.enqueue("second", null, null, 2);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    var head = queue.popHead().?;
    try std.testing.expectEqualStrings("first", head.text);
    head.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    var tail = queue.popHead().?;
    try std.testing.expectEqualStrings("second", tail.text);
    tail.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(queue.popHead() == null);
}

test "enqueue rejects beyond the cap" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    for (0..MAX_ENTRIES) |i| {
        _ = try queue.enqueue("prompt", null, null, @intCast(i));
    }
    try std.testing.expect(queue.isFull());
    try std.testing.expectError(error.Full, queue.enqueue("overflow", null, null, 0));
    try std.testing.expectEqual(MAX_ENTRIES, queue.len());
}

test "remove releases the entry and keeps order" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("a", null, null, 0);
    _ = try queue.enqueue("b", null, null, 1);
    _ = try queue.enqueue("c", null, null, 2);

    try std.testing.expect(queue.remove(1));
    try std.testing.expectEqual(@as(usize, 2), queue.len());
    try std.testing.expectEqualStrings("a", queue.entries.items[0].text);
    try std.testing.expectEqualStrings("c", queue.entries.items[1].text);
    try std.testing.expect(!queue.remove(2));
    try std.testing.expect(queue.remove(0)); // index 0 still valid
    try std.testing.expectEqualStrings("c", queue.entries.items[0].text);
}

test "moveUp/moveDown reorder and clamp at the edges" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("a", null, null, 0);
    _ = try queue.enqueue("b", null, null, 1);
    _ = try queue.enqueue("c", null, null, 2);

    try std.testing.expect(!queue.moveUp(0)); // already at head
    try std.testing.expect(queue.moveUp(2));
    try std.testing.expectEqualStrings("c", queue.entries.items[1].text);

    try std.testing.expect(!queue.moveDown(2)); // already at tail
    try std.testing.expect(queue.moveDown(0));
    try std.testing.expectEqualStrings("c", queue.entries.items[0].text);
    try std.testing.expectEqualStrings("a", queue.entries.items[1].text);
    try std.testing.expectEqualStrings("b", queue.entries.items[2].text);
}

test "moveToHead promotes the selected entry without reallocating" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("a", null, null, 0);
    _ = try queue.enqueue("b", null, null, 1);
    _ = try queue.enqueue("c", null, null, 2);

    try std.testing.expect(queue.moveToHead(0)); // already head
    try std.testing.expectEqualStrings("a", queue.entries.items[0].text);
    try std.testing.expect(queue.moveToHead(2));
    try std.testing.expectEqualStrings("c", queue.entries.items[0].text);
    try std.testing.expectEqualStrings("a", queue.entries.items[1].text);
    try std.testing.expectEqualStrings("b", queue.entries.items[2].text);
    try std.testing.expect(!queue.moveToHead(3));
}

test "editText replaces the entry text" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("draft", null, null, 0);
    try std.testing.expect(try queue.editText(0, "rewritten"));
    try std.testing.expectEqualStrings("rewritten", queue.entries.items[0].text);
    try std.testing.expect(!(try queue.editText(1, "nope")));
}

test "entry owns images and reply context; take transfers them" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    const images = try testImages(allocator, "aW1n");
    const ctx = try testReplyContext(allocator, "wx-user");
    _ = try queue.enqueue("with image", images, ctx, 0);

    var entry = queue.take(0).?;
    try std.testing.expectEqual(@as(usize, 1), entry.images.?.len);
    try std.testing.expectEqualStrings("aW1n", entry.images.?[0].data_b64);
    try std.testing.expectEqualStrings("wx-user", entry.reply_context.?.to_user_id);
    entry.deinit(allocator); // frees images + ctx; testing.allocator catches leaks
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "clear releases every entry" {
    const allocator = std.testing.allocator;
    var queue = PromptQueue.init(allocator);
    defer queue.deinit();

    _ = try queue.enqueue("a", try testImages(allocator, "x"), null, 0);
    _ = try queue.enqueue("b", null, try testReplyContext(allocator, "u"), 1);
    queue.clear();
    try std.testing.expectEqual(@as(usize, 0), queue.len());

    // Queue stays usable after clear.
    _ = try queue.enqueue("c", null, null, 2);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
}
