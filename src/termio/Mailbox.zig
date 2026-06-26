/// SPSC mailbox: fixed-capacity ring buffer with mutex + xev.Async wakeup.
///
/// The main thread pushes messages via send(), then calls notify() to wake
/// the IO writer thread's xev event loop. The writer thread pops messages
/// via pop() in its wakeup callback.
///
/// Design notes:
/// - send() + notify() are separate (like Ghostty) so the caller can batch
///   sends before one notify
/// - On overflow the ring is full for EVERY message kind: send() returns .full
///   and the queue is left intact — an already-queued payload (a real terminal
///   write) is never evicted to make room, not even for a control message.
///   Trailing resizes still coalesce (last-writer-wins) before the full check,
///   so rapid resize streams do not grow the queue
/// - Mutex-based, not lock-free — adequate for our SPSC pattern with tiny
///   critical sections
const std = @import("std");
const xev = @import("xev");
const Message = @import("message.zig").Message;

const Mailbox = @This();

const CAPACITY = 64;

/// Outcome of a send() call so the caller can react (e.g. retry on .full).
pub const SendResult = enum {
    /// The message was enqueued normally.
    queued,
    /// A trailing resize was coalesced into the existing pending resize.
    coalesced,
    /// The ring was full and the message could not be enqueued. The queue is
    /// left intact (nothing dropped); the caller should notify+retry.
    full,
};

queue: [CAPACITY]Message = undefined,
head: usize = 0,
tail: usize = 0,
count: usize = 0,
mutex: std.Thread.Mutex = .{},
wakeup: xev.Async,

pub fn init() !Mailbox {
    return .{
        .wakeup = try xev.Async.init(),
    };
}

pub fn deinit(self: *Mailbox) void {
    self.wakeup.deinit();
}

/// Push a message onto the ring buffer.
///
/// Returns:
/// - .coalesced if a trailing resize was folded into the pending resize
/// - .queued on a normal enqueue
/// - .full if the ring is full: the message is NOT enqueued and NOTHING is
///   dropped (no message kind evicts an already-queued payload), so the caller
///   can notify+retry once the writer drains.
///
/// Thread-safe (uses mutex).
pub fn send(self: *Mailbox, msg: Message) SendResult {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.coalesceTrailingResize(msg)) return .coalesced;

    // Full means full for every message kind. Never evict an already-queued
    // payload (a real terminal write) to make room — not even for a control
    // message; the caller (Surface.queueIo) wakes the writer and retries.
    if (self.count == CAPACITY) return .full;

    self.queue[self.tail] = msg;
    self.tail = (self.tail + 1) % CAPACITY;
    self.count += 1;
    return .queued;
}

fn coalesceTrailingResize(self: *Mailbox, msg: Message) bool {
    const latest = switch (msg) {
        .resize => |grid| grid,
        else => return false,
    };

    if (self.count == 0) return false;
    const idx = if (self.tail == 0) CAPACITY - 1 else self.tail - 1;
    switch (self.queue[idx]) {
        .resize => {
            self.queue[idx] = .{ .resize = latest };
            return true;
        },
        else => return false,
    }
}

/// Wake the IO writer thread's xev event loop.
/// Call after one or more send() calls.
pub fn notify(self: *Mailbox) void {
    self.wakeup.notify() catch {};
}

/// Pop a message from the ring buffer. Returns null if empty.
/// Thread-safe (uses mutex).
pub fn pop(self: *Mailbox) ?Message {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.count == 0) return null;

    const msg = self.queue[self.head];
    self.head = (self.head + 1) % CAPACITY;
    self.count -= 1;
    return msg;
}

fn writeSmallByte(byte: u8) Message {
    var payload: Message.WriteSmall = .{ .len = 1 };
    payload.data[0] = byte;
    return .{ .write_small = payload };
}

fn expectWriteByte(msg: Message, byte: u8) !void {
    defer msg.deinit();
    switch (msg) {
        .write_small => |payload| {
            try std.testing.expectEqual(@as(u16, 1), payload.len);
            try std.testing.expectEqual(byte, payload.data[0]);
        },
        else => return error.UnexpectedMessage,
    }
}

fn expectResize(msg: Message, cols: u16, rows: u16) !void {
    defer msg.deinit();
    switch (msg) {
        .resize => |grid| {
            try std.testing.expectEqual(cols, grid.cols);
            try std.testing.expectEqual(rows, grid.rows);
        },
        else => return error.UnexpectedMessage,
    }
}

test "Mailbox returns .full for writes on a full ring without dropping" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    // Fill the ring exactly to capacity.
    for (0..CAPACITY) |i| {
        try std.testing.expectEqual(SendResult.queued, mailbox.send(writeSmallByte(@intCast(i))));
    }
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // One more write must NOT be dropped: it is rejected with .full and the
    // existing queue is left untouched.
    try std.testing.expectEqual(SendResult.full, mailbox.send(writeSmallByte(0xFF)));
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // All original messages are preserved in order; none were dropped.
    for (0..CAPACITY) |expected| {
        try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, @intCast(expected));
    }
    try std.testing.expect(mailbox.pop() == null);
}

test "Mailbox coalesces pending resize messages" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    try std.testing.expectEqual(SendResult.queued, mailbox.send(.{ .resize = .{ .cols = 80, .rows = 24 } }));
    try std.testing.expectEqual(SendResult.coalesced, mailbox.send(.{ .resize = .{ .cols = 120, .rows = 40 } }));

    try std.testing.expectEqual(@as(usize, 1), mailbox.count);
    try expectResize(mailbox.pop() orelse return error.MissingMessage, 120, 40);
    try std.testing.expect(mailbox.pop() == null);
}

test "Mailbox resize coalescing preserves write messages" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    try std.testing.expectEqual(SendResult.queued, mailbox.send(writeSmallByte('a')));
    try std.testing.expectEqual(SendResult.queued, mailbox.send(.{ .resize = .{ .cols = 80, .rows = 24 } }));
    try std.testing.expectEqual(SendResult.coalesced, mailbox.send(.{ .resize = .{ .cols = 100, .rows = 30 } }));
    try std.testing.expectEqual(SendResult.queued, mailbox.send(writeSmallByte('b')));

    try std.testing.expectEqual(@as(usize, 3), mailbox.count);
    try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, 'a');
    try expectResize(mailbox.pop() orelse return error.MissingMessage, 100, 30);
    try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, 'b');
    try std.testing.expect(mailbox.pop() == null);
}

test "resize on a full mailbox never evicts queued writes" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    // Fill the ring exactly to capacity with real terminal writes.
    for (0..CAPACITY) |i| {
        try std.testing.expectEqual(SendResult.queued, mailbox.send(writeSmallByte(@intCast(i))));
    }
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // A control (resize) message on a full ring is rejected with .full — it must
    // NOT evict a queued write to make room. The caller (Surface.queueIo)
    // notifies the writer and retries once space frees.
    try std.testing.expectEqual(SendResult.full, mailbox.send(.{ .resize = .{ .cols = 10, .rows = 5 } }));
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // Every queued write survives, in order; none were dropped for the resize.
    for (0..CAPACITY) |expected| {
        try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, @intCast(expected));
    }
    try std.testing.expect(mailbox.pop() == null);
}
