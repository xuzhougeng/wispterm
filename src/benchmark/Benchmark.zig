//! A single benchmark case. Mirrors Ghostty's `src/benchmark/Benchmark.zig`:
//! a vtable-driven run abstraction with `RunMode{ once, duration }` and
//! `RunResult{ iterations, duration }`. Setup/teardown are excluded from the
//! measured window, matching Ghostty so branch-to-branch comparisons stay
//! meaningful (see Ghostty's `src/benchmark/AGENTS.md`).
//!
//! Deliberately zero project dependencies (std only) so this compiles in the
//! fast suite and the bench CLI alike.

const Benchmark = @This();

const std = @import("std");

ptr: *anyopaque,
vtable: VTable,

/// Wrap a pointer + vtable. Usually called by benchmark implementations,
/// not benchmark users.
pub fn init(pointer: anytype, vtable: VTable) Benchmark {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer); // Must be a pointer
    assert(@typeInfo(Ptr).pointer.size == .one); // Must be a single-item pointer
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct"); // Must point to a struct
    return .{ .ptr = pointer, .vtable = vtable };
}

/// Run the benchmark. Setup/teardown run outside the timed window.
pub fn run(self: Benchmark, mode: RunMode) Error!RunResult {
    if (self.vtable.setupFn) |func| try func(self.ptr);
    defer if (self.vtable.teardownFn) |func| func(self.ptr);

    var result: RunResult = .{};
    const start = std.time.Instant.now() catch return error.BenchmarkFailed;
    while (true) {
        try self.vtable.stepFn(self.ptr);
        result.iterations += 1;

        const now = std.time.Instant.now() catch return error.BenchmarkFailed;
        const exit = switch (mode) {
            .once => true,
            .duration => |ns| now.since(start) >= ns,
        };
        if (exit) {
            result.duration = now.since(start);
            return result;
        }
    }
    unreachable;
}

/// How a benchmark is driven. `once` runs a single step (setup+teardown still
/// excluded); `duration` runs steps until `ns` nanoseconds have elapsed.
pub const RunMode = union(enum) {
    once,
    duration: u64,
};

pub const RunResult = struct {
    iterations: u32 = 0,
    /// Nanoseconds. For `duration` runs this is close to the requested window.
    duration: u64 = 0,

    /// Throughput in iterations/sec over the measured window.
    pub fn iterationsPerSecond(self: RunResult) f64 {
        if (self.duration == 0) return 0;
        return @as(f64, @floatFromInt(self.iterations)) * std.time.ns_per_s /
            @as(f64, @floatFromInt(self.duration));
    }
};

pub const Error = error{BenchmarkFailed};

pub const VTable = struct {
    /// A single step of the work under test. Called repeatedly under `duration`.
    stepFn: *const fn (ptr: *anyopaque) Error!void,
    setupFn: ?*const fn (ptr: *anyopaque) Error!void = null,
    teardownFn: ?*const fn (ptr: *anyopaque) void = null,
};

fn assert(condition: bool) void {
    if (!condition) unreachable;
}

test "Benchmark: once mode runs setup+step once, excludes setup from duration" {
    // Ghostty's equivalent test skips on Windows/FreeBSD because a single
    // trivial step can complete within one timer tick (duration == 0). We keep
    // the structural assertions (which are timer-independent) and skip only the
    // positivity check on those hosts; the duration-mode test below covers
    // timing on every host.
    const Simple = struct {
        setup_i: usize = 0,
        step_i: usize = 0,

        fn setup(ptr: *anyopaque) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.setup_i += 1;
        }
        fn step(ptr: *anyopaque) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step_i += 1;
        }
        fn benchmark(self: *@This()) Benchmark {
            return .init(self, .{ .stepFn = step, .setupFn = setup });
        }
    };

    var s: Simple = .{};
    const b = s.benchmark();
    const result = try b.run(.once);
    try std.testing.expectEqual(@as(usize, 1), s.setup_i);
    try std.testing.expectEqual(@as(usize, 1), s.step_i);
    try std.testing.expectEqual(@as(u32, 1), result.iterations);
    if (@import("builtin").os.tag != .windows and @import("builtin").os.tag != .freebsd) {
        try std.testing.expect(result.duration > 0);
    }
}

test "Benchmark: duration mode accumulates iterations until window elapses" {
    const Counter = struct {
        step_i: usize = 0,
        fn step(ptr: *anyopaque) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step_i += 1;
        }
        fn benchmark(self: *@This()) Benchmark {
            return .init(self, .{ .stepFn = step });
        }
    };

    var c: Counter = .{};
    const b = c.benchmark();
    // 5ms window — enough for many iterations of an increment, short enough
    // for a unit test.
    const result = try b.run(.{ .duration = 5 * std.time.ns_per_ms });
    try std.testing.expectEqual(@as(u32, @intCast(c.step_i)), result.iterations);
    try std.testing.expect(result.duration >= 5 * std.time.ns_per_ms);
    try std.testing.expect(result.iterationsPerSecond() > 0);
}

test "RunResult.iterationsPerSecond is zero for zero duration" {
    const r: RunResult = .{ .iterations = 100, .duration = 0 };
    try std.testing.expectEqual(@as(f64, 0), r.iterationsPerSecond());
}
