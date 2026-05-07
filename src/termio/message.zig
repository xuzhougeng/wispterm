/// Message types for the IO thread mailbox.
///
/// The main thread sends these to the IO writer thread via the Mailbox.
/// The tagged union is trivially extensible — adding a new variant requires
/// only adding the field here and a switch case in Thread.drainMailbox().

const std = @import("std");
const renderer = @import("../renderer.zig");

pub const Message = union(enum) {
    pub const WRITE_SMALL_MAX = 256;

    pub const WriteSmall = struct {
        data: [WRITE_SMALL_MAX]u8 = undefined,
        len: u16 = 0,
    };

    pub const WriteAlloc = struct {
        allocator: std.mem.Allocator,
        data: []u8,
    };

    /// Resize the terminal grid to the given dimensions.
    /// Coalesced with a 25ms timer before applying.
    resize: renderer.size.GridSize,

    /// Write data to the PTY input pipe from the IO writer thread.
    write_small: WriteSmall,

    /// Write heap-owned data to the PTY input pipe, then free it.
    write_alloc: WriteAlloc,

    pub fn writeReq(allocator: std.mem.Allocator, data: []const u8) !Message {
        if (data.len <= WRITE_SMALL_MAX) {
            var small: WriteSmall = .{ .len = @intCast(data.len) };
            @memcpy(small.data[0..data.len], data);
            return .{ .write_small = small };
        }

        const owned = try allocator.dupe(u8, data);
        return .{ .write_alloc = .{ .allocator = allocator, .data = owned } };
    }

    pub fn deinit(self: Message) void {
        switch (self) {
            .write_alloc => |payload| payload.allocator.free(payload.data),
            else => {},
        }
    }

    // Future variants:
    // focused: bool,
    // clear_screen: void,
};
