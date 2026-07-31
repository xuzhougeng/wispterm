//! Benchmark statistics: nearest-rank percentiles over a caller-owned sample
//! slice, plus a throughput helper. Complements `src/appwindow/frame_latency.zig`
//! (which keeps a rolling ring buffer for live frame-latency probes): bench
//! cases instead collect a fixed sample set per run and summarize it once, so
//! this module takes the samples by reference rather than owning them.
//!
//! Zero project dependencies (std only) so it runs in the fast suite.

const std = @import("std");

pub const Summary = struct {
    count: usize,
    /// All latency/time fields are caller-defined units (typically ns). The
    /// module is unit-agnostic; callers label the units in their reports.
    p50: i64,
    p95: i64,
    max: i64,
    min: i64,
    mean: i64,
};

/// Compute a summary over `samples` (caller-owned). The slice is copied into a
/// stack-backed temp via `sort_buf` so the caller's input order is preserved.
/// `sort_buf` must be at least `samples.len` long.
pub fn summaryWithBuf(samples: []const i64, sort_buf: []i64) Summary {
    if (samples.len == 0) return .{ .count = 0, .p50 = 0, .p95 = 0, .max = 0, .min = 0, .mean = 0 };
    @memcpy(sort_buf[0..samples.len], samples);
    std.mem.sort(i64, sort_buf[0..samples.len], {}, std.sort.asc(i64));

    var sum: i64 = 0;
    var maxv: i64 = sort_buf[0];
    var minv: i64 = sort_buf[0];
    for (samples) |s| {
        sum += s;
        if (s > maxv) maxv = s;
        if (s < minv) minv = s;
    }
    const mean = @divTrunc(sum, @as(i64, @intCast(samples.len)));
    return .{
        .count = samples.len,
        .p50 = percentileSorted(sort_buf[0..samples.len], 50),
        .p95 = percentileSorted(sort_buf[0..samples.len], 95),
        .max = maxv,
        .min = minv,
        .mean = mean,
    };
}

/// Convenience for small fixed-size sample sets. For large sets use
/// `summaryWithBuf` with a caller-provided buffer to avoid the fixed cap.
pub fn summaryFixed(samples: []const i64) Summary {
    var buf: [4096]i64 = undefined;
    if (samples.len > buf.len) {
        // Fall back to summarizing only the first buf.len samples; callers
        // with larger sets should use summaryWithBuf.
        return summaryWithBuf(samples[0..buf.len], &buf);
    }
    return summaryWithBuf(samples, &buf);
}

/// Nearest-rank percentile of an ascending-sorted slice, p ∈ [1,100].
/// rank = ceil(p*n/100), clamped to [1,n]. Matches `frame_latency.percentile`.
pub fn percentileSorted(sorted: []const i64, p: u8) i64 {
    if (sorted.len == 0) return 0;
    const n = sorted.len;
    const num = @as(usize, p) * n;
    var rank = num / 100;
    if (num % 100 != 0) rank += 1; // ceil
    if (rank == 0) rank = 1;
    if (rank > n) rank = n;
    return sorted[rank - 1];
}

test "stats: empty sample set yields zero summary" {
    const s = summaryFixed(&.{});
    try std.testing.expectEqual(@as(usize, 0), s.count);
    try std.testing.expectEqual(@as(i64, 0), s.max);
}

test "stats: nearest-rank p50/p95 over 1..10" {
    var samples: [10]i64 = undefined;
    for (0..10) |i| samples[i] = @intCast(i + 1);
    const s = summaryFixed(&samples);
    try std.testing.expectEqual(@as(usize, 10), s.count);
    // sorted 1..10: p50 rank=ceil(5)=5 → 5; p95 rank=ceil(9.5)=10 → 10
    try std.testing.expectEqual(@as(i64, 5), s.p50);
    try std.testing.expectEqual(@as(i64, 10), s.p95);
    try std.testing.expectEqual(@as(i64, 10), s.max);
    try std.testing.expectEqual(@as(i64, 1), s.min);
    try std.testing.expectEqual(@as(i64, 5), s.mean); // (1+..+10)/10 = 5.5 → 5
}

test "stats: preserves caller input order (summaryWithBuf copies)" {
    var samples = [_]i64{ 30, 10, 20 };
    const before = samples;
    _ = summaryFixed(&samples);
    try std.testing.expectEqualSlices(i64, &before, &samples);
}

test "stats: percentileSorted boundary ranks" {
    const data = [_]i64{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(i64, 10), percentileSorted(&data, 1));
    try std.testing.expectEqual(@as(i64, 20), percentileSorted(&data, 50));
    try std.testing.expectEqual(@as(i64, 40), percentileSorted(&data, 100));
}

test "stats: single sample" {
    const samples = [_]i64{42};
    const s = summaryFixed(&samples);
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqual(@as(i64, 42), s.p50);
    try std.testing.expectEqual(@as(i64, 42), s.p95);
    try std.testing.expectEqual(@as(i64, 42), s.max);
    try std.testing.expectEqual(@as(i64, 42), s.min);
    try std.testing.expectEqual(@as(i64, 42), s.mean);
}
