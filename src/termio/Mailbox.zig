/// SPSC mailbox: fixed-capacity ring buffer with mutex + xev.Async wakeup.
///
/// The main thread pushes messages via send(), then calls notify() to wake
/// the IO writer thread's xev event loop. The writer thread pops messages
/// via pop() in its wakeup callback.
///
/// Design notes:
/// - send() + notify() are separate (like Ghostty) so the caller can batch
///   sends before one notify
/// - Drop-oldest on overflow (not blocking) — simpler than Ghostty's
///   blocking-with-mutex-release, and resize messages are last-writer-wins anyway
/// - Mutex-based, not lock-free — adequate for our SPSC pattern with tiny
///   critical sections
const std = @import("std");
const xev = @import("xev");
const Message = @import("message.zig").Message;

const Mailbox = @This();

const CAPACITY = 64;

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

/// Push a message onto the ring buffer. If full, drops the oldest message.
/// Thread-safe (uses mutex).
pub fn send(self: *Mailbox, msg: Message) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.coalesceTrailingResize(msg)) return;

    if (self.count == CAPACITY) {
        // Drop oldest: advance head and release any owned payload.
        self.queue[self.head].deinit();
        self.head = (self.head + 1) % CAPACITY;
        self.count -= 1;
    }

    self.queue[self.tail] = msg;
    self.tail = (self.tail + 1) % CAPACITY;
    self.count += 1;
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

test "Mailbox drops oldest message when full" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    for (0..CAPACITY + 1) |i| {
        mailbox.send(writeSmallByte(@intCast(i)));
    }

    try std.testing.expectEqual(@as(usize, CAPACITY), mailbox.count);
    for (1..CAPACITY + 1) |expected| {
        try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, @intCast(expected));
    }
    try std.testing.expect(mailbox.pop() == null);
}

test "Mailbox coalesces pending resize messages" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    mailbox.send(.{ .resize = .{ .cols = 80, .rows = 24 } });
    mailbox.send(.{ .resize = .{ .cols = 120, .rows = 40 } });

    try std.testing.expectEqual(@as(usize, 1), mailbox.count);
    try expectResize(mailbox.pop() orelse return error.MissingMessage, 120, 40);
    try std.testing.expect(mailbox.pop() == null);
}

test "Mailbox resize coalescing preserves write messages" {
    var mailbox = try Mailbox.init();
    defer mailbox.deinit();

    mailbox.send(writeSmallByte('a'));
    mailbox.send(.{ .resize = .{ .cols = 80, .rows = 24 } });
    mailbox.send(.{ .resize = .{ .cols = 100, .rows = 30 } });
    mailbox.send(writeSmallByte('b'));

    try std.testing.expectEqual(@as(usize, 3), mailbox.count);
    try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, 'a');
    try expectResize(mailbox.pop() orelse return error.MissingMessage, 100, 30);
    try expectWriteByte(mailbox.pop() orelse return error.MissingMessage, 'b');
    try std.testing.expect(mailbox.pop() == null);
}
