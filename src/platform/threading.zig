//! Platform thread spawn policy for Phantty-owned background threads.

const std = @import("std");

/// Conservative stack size for per-surface helper threads.
///
/// These helper threads run small event/read loops and do not need a large
/// native runtime stack.
pub const surface_thread_stack_size: usize = 1024 * 1024;

pub const surface_thread_spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = surface_thread_stack_size,
};

test "platform threading exposes a bounded surface helper stack" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), surface_thread_stack_size);
    try std.testing.expectEqual(surface_thread_stack_size, surface_thread_spawn_config.stack_size);
}
