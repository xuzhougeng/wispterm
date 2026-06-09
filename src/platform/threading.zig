//! Platform thread spawn policy for WispTerm-owned background threads.

const std = @import("std");
const builtin = @import("builtin");

/// Conservative stack size for per-surface helper threads.
///
/// These helper threads run small event/read loops and do not need a large
/// native runtime stack. On Linux (glibc), the program's static TLS block is
/// carved out of each thread's stack region, so the stack must exceed the
/// static TLS size (several MiB here, dominated by the threadlocal GL function
/// table) plus PTHREAD_STACK_MIN and the guard page — otherwise pthread_create
/// returns EINVAL. Other targets account for static TLS separately from the
/// thread stack, so the smaller 1 MiB stack suffices there.
pub const surface_thread_stack_size: usize = if (builtin.os.tag == .linux)
    8 * 1024 * 1024
else
    1024 * 1024;

pub const surface_thread_spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = surface_thread_stack_size,
};

test "platform threading exposes a bounded surface helper stack" {
    const expected: usize = if (builtin.os.tag == .linux) 8 * 1024 * 1024 else 1024 * 1024;
    try std.testing.expectEqual(expected, surface_thread_stack_size);
    try std.testing.expectEqual(surface_thread_stack_size, surface_thread_spawn_config.stack_size);
}
