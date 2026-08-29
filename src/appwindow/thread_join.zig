//! Join helper that keeps draining a main-thread event queue.
//!
//! WispTerm runs extra windows on worker threads. On macOS those workers tear
//! down NSWindow via `dispatch_sync` onto the main GCD queue. Ghostty does not
//! have this deadlock: its macOS host is a native AppKit app, so window close
//! and `applicationShouldTerminate` already run on the main thread
//! (`macos/Sources/App/AppDelegate.swift`). A blocking `Thread.join()` on
//! WispTerm's main thread starves that queue and deadlocks (GitHub issue #611).
//! Pump until the live worker count reaches 0, then join (joins are then instant).

const std = @import("std");

pub const PumpFn = *const fn (timeout_seconds: f64) void;

/// Invoke `pump` until `live` reaches 0. `pump_timeout_seconds` must be > 0
/// so the macOS AppKit pump actually runs the GCD main queue (a 0s
/// `distantPast` drain never does).
pub fn pumpWhileLive(
    live: *const std.atomic.Value(usize),
    pump: PumpFn,
    pump_timeout_seconds: f64,
) void {
    while (live.load(.acquire) > 0) {
        pump(pump_timeout_seconds);
    }
}

test "pumpWhileLive is a no-op when live is already 0" {
    const Holder = struct {
        var pumps: std.atomic.Value(u32) = .init(0);
        fn pump(_: f64) void {
            _ = pumps.fetchAdd(1, .monotonic);
        }
    };
    Holder.pumps.store(0, .release);
    var live = std.atomic.Value(usize).init(0);
    pumpWhileLive(&live, Holder.pump, 0.01);
    try std.testing.expectEqual(@as(u32, 0), Holder.pumps.load(.acquire));
}

test "pumpWhileLive keeps pumping until a worker waiting on the pump drops live" {
    // Mirrors issue #611: the worker cannot finish teardown until the main
    // thread pumps. Blocking join without a pump would hang this test.
    const Holder = struct {
        var pumped: std.atomic.Value(bool) = .init(false);
        fn pump(_: f64) void {
            pumped.store(true, .release);
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    };
    Holder.pumped.store(false, .release);

    var live = std.atomic.Value(usize).init(1);
    const Worker = struct {
        live: *std.atomic.Value(usize),
        fn run(self: *@This()) void {
            while (!Holder.pumped.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            _ = self.live.fetchSub(1, .acq_rel);
        }
    };
    var worker = Worker{ .live = &live };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});

    var done = std.atomic.Value(bool).init(false);
    const Runner = struct {
        live: *std.atomic.Value(usize),
        done: *std.atomic.Value(bool),
        fn run(self: *@This()) void {
            pumpWhileLive(self.live, Holder.pump, 0.01);
            self.done.store(true, .release);
        }
    };
    var runner_ctx = Runner{ .live = &live, .done = &done };
    const runner = try std.Thread.spawn(.{}, Runner.run, .{&runner_ctx});

    var timer = try std.time.Timer.start();
    const timeout_ns: u64 = 2 * std.time.ns_per_s;
    while (!done.load(.acquire)) {
        if (timer.read() > timeout_ns) return error.JoinDeadlock;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    runner.join();
    thread.join();
    try std.testing.expectEqual(@as(usize, 0), live.load(.acquire));
    try std.testing.expect(Holder.pumped.load(.acquire));
}
