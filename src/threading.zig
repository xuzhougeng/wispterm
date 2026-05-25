//! Thread spawn settings shared by Phantty-owned background threads.

const platform_threading = @import("platform/threading.zig");

pub const surface_thread_spawn_config = platform_threading.surface_thread_spawn_config;
