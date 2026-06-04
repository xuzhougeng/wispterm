//! Native libc-linked test runner for modules that need real file I/O, the
//! libc timezone functions, or other POSIX capabilities unavailable in the
//! fast (no-libc) or cross-compiled (windows-gnu) test runners.
//!
//! Added to `test-full` (see build.zig) for all non-Windows hosts. Put tests
//! here when they involve:
//!   - std.fs / tmpDir file round-trips
//!   - ai_history_time.localOffsetSeconds() (calls localtime_r / timegm)
//!   - socketpair / fork / other POSIX syscalls
//!
//! Do NOT put tests here that can live in test_fast.zig (no libc needed) or
//! test_main.zig (full app graph, Windows/macOS CI).

const std = @import("std");
// Suppress unused build_options import expected by some imported modules.
pub const build_options = @import("build_options");

comptime {
    _ = @import("ai_loop_store.zig");
}
