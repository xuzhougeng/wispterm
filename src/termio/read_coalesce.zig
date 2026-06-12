const std = @import("std");

pub const MAX_BATCH_BYTES: usize = 64 * 1024;

pub fn nextDrainLen(available: usize, scratch_len: usize, buffered_len: usize) usize {
    if (available == 0 or scratch_len == 0) return 0;
    if (buffered_len >= MAX_BATCH_BYTES) return 0;
    const remaining = MAX_BATCH_BYTES - buffered_len;
    return @min(available, @min(scratch_len, remaining));
}

test "nextDrainLen drains immediately available PTY bytes" {
    try std.testing.expectEqual(@as(usize, 128), nextDrainLen(128, 4096, 32));
}

test "nextDrainLen clamps to scratch buffer" {
    try std.testing.expectEqual(@as(usize, 4096), nextDrainLen(9000, 4096, 32));
}

test "nextDrainLen stops when no bytes are immediately available" {
    try std.testing.expectEqual(@as(usize, 0), nextDrainLen(0, 4096, 32));
}

test "nextDrainLen stops at batch cap" {
    try std.testing.expectEqual(@as(usize, 0), nextDrainLen(9000, 4096, MAX_BATCH_BYTES));
    try std.testing.expectEqual(@as(usize, 10), nextDrainLen(9000, 4096, MAX_BATCH_BYTES - 10));
}
