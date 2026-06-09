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

const run_on_main = @import("apprt/run_on_main.zig");

comptime {
    _ = @import("ai_loop_store.zig");
    _ = @import("child_output.zig");
}

test "run_on_main marshals a task from a worker thread to the draining thread" {
    var q = run_on_main.Queue{};
    defer q.deinit(std.testing.allocator);

    const State = struct { value: i32 = 0, done: std.Thread.ResetEvent = .{} };
    var st = State{};

    const Worker = struct {
        fn go(queue: *run_on_main.Queue, state: *State) void {
            const run = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *State = @ptrCast(@alignCast(ctx));
                    s.value = 42;
                    s.done.set();
                }
            }.f;
            queue.enqueue(std.testing.allocator, .{ .run = run, .ctx = state }) catch unreachable;
        }
    };
    var t = try std.Thread.spawn(.{}, Worker.go, .{ &q, &st });
    t.join();

    try std.testing.expectEqual(@as(i32, 0), st.value); // not run until drained
    q.drain(std.testing.allocator);
    st.done.wait();
    try std.testing.expectEqual(@as(i32, 42), st.value);
}
