//! Platform thread spawn policy for WispTerm-owned background threads.

const std = @import("std");
const builtin = @import("builtin");

/// Conservative stack size for per-surface helper threads.
///
/// These helper threads run small event/read loops and do not need a large
/// native runtime stack.
///
/// - Linux (glibc): the program's static TLS block is carved out of each
///   thread's stack region, so the stack must exceed the static TLS size
///   (several MiB here, dominated by the threadlocal GL function table) plus
///   PTHREAD_STACK_MIN and the guard page — otherwise pthread_create returns
///   EINVAL.
/// - Reserve-growing native thread runtimes: stack_size controls the initial
///   committed stack, while the stack can still grow to the executable's
///   reserve. Keep the commit small for the two per-surface IO helpers; 256 KiB
///   covers the reader's 64 KiB on-stack buffer plus VT-parse frames without
///   early guard-page faults.
/// - Lazily committed mapped-stack runtimes: stack_size is the mapping ceiling,
///   so shrinking buys no RSS; keep 1 MiB of headroom.
pub const surface_thread_stack_size: usize = switch (builtin.os.tag) {
    .linux => 8 * 1024 * 1024,
    .windows => 256 * 1024,
    else => 1024 * 1024,
};

pub const surface_thread_spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = surface_thread_stack_size,
};

test "platform threading exposes a bounded surface helper stack" {
    const expected: usize = switch (builtin.os.tag) {
        .linux => 8 * 1024 * 1024,
        .windows => 256 * 1024,
        else => 1024 * 1024,
    };
    try std.testing.expectEqual(expected, surface_thread_stack_size);
    try std.testing.expectEqual(surface_thread_stack_size, surface_thread_spawn_config.stack_size);
}
