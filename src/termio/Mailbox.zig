/// Termio mailbox: a payload/control split with mutex + xev.Async wakeup.
///
/// The main thread enqueues messages, then calls notify() to wake the IO
/// writer thread's xev event loop. The writer thread drains the mailbox in its
/// wakeup callback.
///
/// Two separately governed lanes share one mutex and one wakeup:
///
///   PAYLOAD lane — terminal writes (`write_small` / `write_alloc`).
///     A fixed-capacity, order-preserving ring (CAPACITY 64). This is the
///     stream of bytes destined for the child PTY; order matters and nothing
///     may be silently dropped. When the ring is full, sendWrite() returns
///     `.full` and the queue is left intact — the caller wakes the writer and
///     retries. A resize storm can NEVER displace a queued write because resize
///     no longer occupies a ring slot.
///
///   CONTROL lane — resize requests (coalesced + immediate).
///     Two last-writer-wins fields, not a queue: `pending_resize` and
///     `pending_immediate_resize`. Resize is inherently a "latest geometry
///     wins" operation (and the writer thread additionally coalesces the
///     non-immediate one behind a 25ms timer), so a single overwriting slot per
///     kind is sufficient. setResize()/setImmediateResize() never fail.
///
/// Design notes:
/// - send + notify are separate (like Ghostty) so the caller can batch sends
///   before one notify.
/// - Mutex-based, not lock-free — adequate for our pattern with tiny critical
///   sections.
const std = @import("std");
const xev = @import("xev");
const Message = @import("message.zig").Message;
const geometry = @import("../core/geometry.zig");

const Mailbox = @This();

const CAPACITY = 64;

/// Outcome of a sendWrite() call so the caller can react (e.g. retry on .full).
pub const SendResult = enum {
    /// The write was enqueued onto the payload ring.
    queued,
    /// The payload ring was full and the write could not be enqueued. The queue
    /// is left intact (nothing dropped); the caller should notify+retry.
    full,
};

// PAYLOAD lane — order-preserving write ring.
queue: [CAPACITY]Message = undefined,
head: usize = 0,
tail: usize = 0,
count: usize = 0,

// CONTROL lane — last-writer-wins resize fields (NOT ring slots).
pending_resize: ?geometry.GridSize = null,
pending_immediate_resize: ?geometry.GridSize = null,

mutex: std.Thread.Mutex = .{},
wakeup: xev.Async,

pub fn init() !Mailbox {
    return .{
        .wakeup = try xev.Async.init(),
    };
}

pub fn deinit(self: *Mailbox) void {
    // Free any heap-owned payload still queued (write_alloc) so teardown does
    // not leak. Resize fields own nothing.
    while (self.popWrite()) |msg| msg.deinit();
    self.wakeup.deinit();
}

/// Enqueue a terminal write (`write_small` / `write_alloc`) onto the payload
/// ring, preserving order.
///
/// Returns:
/// - .queued on a normal enqueue.
/// - .full if the ring is full: the message is NOT enqueued and NOTHING is
///   dropped, so the caller can notify+retry once the writer drains.
///
/// Asserts the message is a write variant — resize must go through
/// setResize()/setImmediateResize(), which can never fail and never occupy a
/// ring slot.
///
/// Thread-safe (uses mutex).
pub fn sendWrite(self: *Mailbox, msg: Message) SendResult {
    switch (msg) {
        .write_small, .write_alloc => {},
        .resize, .resize_immediate => unreachable, // use setResize/setImmediateResize
    }

    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.count == CAPACITY) return .full;

    self.queue[self.tail] = msg;
    self.tail = (self.tail + 1) % CAPACITY;
    self.count += 1;
    return .queued;
}

/// Record a coalesced resize request (last-writer-wins). Never fails; never
/// occupies a payload ring slot. The previous pending value is simply
/// overwritten — resize is inherently "latest geometry wins".
///
/// Thread-safe (uses mutex).
pub fn setResize(self: *Mailbox, grid: geometry.GridSize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.pending_resize = grid;
}

/// Record an immediate resize request (last-writer-wins). Never fails; never
/// occupies a payload ring slot.
///
/// Thread-safe (uses mutex).
pub fn setImmediateResize(self: *Mailbox, grid: geometry.GridSize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.pending_immediate_resize = grid;
}

/// Wake the IO writer thread's xev event loop.
/// Call after one or more send/set calls.
pub fn notify(self: *Mailbox) void {
    self.wakeup.notify() catch {};
}

/// Pop the next queued write from the payload ring. Returns null if empty.
/// Thread-safe (uses mutex).
pub fn popWrite(self: *Mailbox) ?Message {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.count == 0) return null;

    const msg = self.queue[self.head];
    self.head = (self.head + 1) % CAPACITY;
    self.count -= 1;
    return msg;
}

/// Atomically read and clear the pending coalesced resize.
/// Returns null if none pending. Thread-safe (uses mutex).
pub fn takePendingResize(self: *Mailbox) ?geometry.GridSize {
    self.mutex.lock();
    defer self.mutex.unlock();

    const grid = self.pending_resize;
    self.pending_resize = null;
    return grid;
}

/// Atomically read and clear the pending immediate resize.
/// Returns null if none pending. Thread-safe (uses mutex).
pub fn takePendingImmediateResize(self: *Mailbox) ?geometry.GridSize {
    self.mutex.lock();
    defer self.mutex.unlock();

    const grid = self.pending_immediate_resize;
    self.pending_immediate_resize = null;
    return grid;
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

test "payload ring returns .full without dropping queued writes" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    // Fill the ring exactly to capacity.
    for (0..CAPACITY) |i| {
        try std.testing.expectEqual(SendResult.queued, mailbox.sendWrite(writeSmallByte(@intCast(i))));
    }
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // One more write must NOT be dropped: it is rejected with .full and the
    // existing queue is left untouched.
    try std.testing.expectEqual(SendResult.full, mailbox.sendWrite(writeSmallByte(0xFF)));
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // All original messages are preserved in order; none were dropped.
    for (0..CAPACITY) |expected| {
        try expectWriteByte(mailbox.popWrite() orelse return error.MissingMessage, @intCast(expected));
    }
    try std.testing.expect(mailbox.popWrite() == null);
}

test "64 queued writes then a resize: resize evicts nothing" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    // Fill the payload ring exactly to capacity with real terminal writes.
    for (0..CAPACITY) |i| {
        try std.testing.expectEqual(SendResult.queued, mailbox.sendWrite(writeSmallByte(@intCast(i))));
    }
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // A resize on a full ring goes to the control lane (last-writer-wins). It
    // cannot occupy a payload slot, so it evicts NOTHING.
    mailbox.setResize(.{ .cols = 10, .rows = 5 });
    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);

    // Every queued write survives, in order; none were dropped for the resize.
    for (0..CAPACITY) |expected| {
        try expectWriteByte(mailbox.popWrite() orelse return error.MissingMessage, @intCast(expected));
    }
    try std.testing.expect(mailbox.popWrite() == null);

    // The resize is still pending, last-writer-wins.
    const grid = mailbox.takePendingResize() orelse return error.MissingResize;
    try std.testing.expectEqual(@as(u16, 10), grid.cols);
    try std.testing.expectEqual(@as(u16, 5), grid.rows);
}

test "interleaved writes and resizes: write order exact, resize last-writer-wins" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    // Interleave writes with resizes. Writes go to the ordered ring; resizes
    // overwrite the single pending field.
    const sequence = "ghostty-mailbox";
    var resize_n: u16 = 0;
    for (sequence) |byte| {
        try std.testing.expectEqual(SendResult.queued, mailbox.sendWrite(writeSmallByte(byte)));
        resize_n += 1;
        mailbox.setResize(.{ .cols = resize_n, .rows = resize_n });
    }

    // The popped write byte sequence is EXACTLY the sent order — resizes did
    // not perturb the payload lane at all.
    try std.testing.expectEqual(@as(usize, sequence.len), mailbox.count);
    for (sequence) |byte| {
        try expectWriteByte(mailbox.popWrite() orelse return error.MissingMessage, byte);
    }
    try std.testing.expect(mailbox.popWrite() == null);

    // The resize ends last-writer-wins: only the final geometry survives.
    const grid = mailbox.takePendingResize() orelse return error.MissingResize;
    try std.testing.expectEqual(@as(u16, sequence.len), grid.cols);
    try std.testing.expectEqual(@as(u16, sequence.len), grid.rows);
}

test "pending resize is last-writer-wins and clears on take" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    mailbox.setResize(.{ .cols = 80, .rows = 24 });
    mailbox.setResize(.{ .cols = 120, .rows = 40 });

    const grid = mailbox.takePendingResize() orelse return error.MissingResize;
    try std.testing.expectEqual(@as(u16, 120), grid.cols);
    try std.testing.expectEqual(@as(u16, 40), grid.rows);

    // Taking again yields null — the field was cleared.
    try std.testing.expect(mailbox.takePendingResize() == null);
}

test "pending immediate resize is last-writer-wins and clears on take" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    mailbox.setImmediateResize(.{ .cols = 100, .rows = 30 });
    mailbox.setImmediateResize(.{ .cols = 132, .rows = 50 });

    const grid = mailbox.takePendingImmediateResize() orelse return error.MissingResize;
    try std.testing.expectEqual(@as(u16, 132), grid.cols);
    try std.testing.expectEqual(@as(u16, 50), grid.rows);

    try std.testing.expect(mailbox.takePendingImmediateResize() == null);

    // Coalesced and immediate fields are independent lanes.
    try std.testing.expect(mailbox.takePendingResize() == null);
}

test "deinit frees heap-owned write_alloc payload left in the ring" {
    // A leak here would fail the testing allocator. The ring keeps the owning
    // write_alloc, and deinit must drain+free it.
    var mailbox = try Mailbox.init();
    const owned = try std.testing.allocator.dupe(u8, "x" ** (Message.WRITE_SMALL_MAX + 1));
    const msg: Message = .{ .write_alloc = .{ .allocator = std.testing.allocator, .data = owned } };
    try std.testing.expectEqual(SendResult.queued, mailbox.sendWrite(msg));
    mailbox.deinit();
}
