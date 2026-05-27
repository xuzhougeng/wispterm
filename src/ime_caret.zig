const std = @import("std");

pub const Point = struct {
    x: usize,
    y: usize,
};

pub fn candidateScore(anchor: Point, candidate: Point) usize {
    const row_distance = absDiff(anchor.y, candidate.y);
    const col_distance = absDiff(anchor.x, candidate.x);
    return row_distance * 4096 + col_distance;
}

pub fn isBetterCandidate(anchor: Point, current: ?Point, candidate: Point) bool {
    const current_point = current orelse return true;
    const candidate_score = candidateScore(anchor, candidate);
    const current_score = candidateScore(anchor, current_point);
    if (candidate_score != current_score) return candidate_score < current_score;
    if (candidate.y != current_point.y) return candidate.y > current_point.y;
    return candidate.x < current_point.x;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

pub const Source = enum { terminal_cursor, visual_inverse };

pub const Sample = struct {
    x: i64,
    y: i64,
    source: Source,

    pub fn eql(self: Sample, other: Sample) bool {
        return self.x == other.x and self.y == other.y and self.source == other.source;
    }
};

pub const PixelPos = struct { x: f32, y: f32 };

/// Cell (caret_x, caret_y) -> pixel position, given the surface origin (window
/// or split-rect top-left), cell padding, and cell size. Pure placement math.
pub fn pixelPosition(
    caret_x: usize,
    caret_y: usize,
    origin_x: f32,
    origin_y: f32,
    pad_left: u32,
    pad_top: u32,
    cell_w: f32,
    cell_h: f32,
) PixelPos {
    return .{
        .x = origin_x + @as(f32, @floatFromInt(pad_left)) + @as(f32, @floatFromInt(caret_x)) * cell_w,
        .y = origin_y + @as(f32, @floatFromInt(pad_top)) + @as(f32, @floatFromInt(caret_y)) * cell_h,
    };
}

/// Decides when an IME caret sample is stable enough to push to the OS. A
/// `terminal_cursor` sample must repeat on two consecutive frames at the same
/// position before it commits (skips single-frame transients during TUI status
/// repaints); a `visual_inverse` sample (an app-drawn stable cell) commits
/// immediately. A sample equal to the already-committed one is a no-op.
pub const StabilityTracker = struct {
    // {-1,-1} is a sentinel for "no sample seen yet" — real caret coords are
    // usize values cast to i64, so they never collide with it.
    last_sample: Sample = .{ .x = -1, .y = -1, .source = .terminal_cursor },
    committed: Sample = .{ .x = -1, .y = -1, .source = .terminal_cursor },

    /// Returns the sample to commit (push to the OS), or null to skip this frame.
    pub fn commit(self: *StabilityTracker, sample: Sample) ?Sample {
        if (sample.source == .terminal_cursor) {
            if (!sample.eql(self.last_sample)) {
                self.last_sample = sample;
                return null;
            }
        } else {
            self.last_sample = sample;
        }
        if (sample.eql(self.committed)) return null;
        self.committed = sample;
        return sample;
    }
};

test "pixelPosition places cell by origin, padding, and cell size" {
    const p = pixelPosition(2, 3, 100, 30, 5, 7, 10, 20);
    try std.testing.expectEqual(@as(f32, 100 + 5 + 2 * 10), p.x);
    try std.testing.expectEqual(@as(f32, 30 + 7 + 3 * 20), p.y);
}

test "terminal_cursor caret requires two identical frames to commit" {
    var t: StabilityTracker = .{};
    const s: Sample = .{ .x = 4, .y = 9, .source = .terminal_cursor };
    try std.testing.expectEqual(@as(?Sample, null), t.commit(s));
    try std.testing.expectEqual(s, t.commit(s).?);
    try std.testing.expectEqual(@as(?Sample, null), t.commit(s));
}

test "a moved terminal_cursor caret re-arms the two-frame wait" {
    var t: StabilityTracker = .{};
    const a: Sample = .{ .x = 4, .y = 9, .source = .terminal_cursor };
    _ = t.commit(a);
    try std.testing.expectEqual(a, t.commit(a).?);
    const b: Sample = .{ .x = 5, .y = 9, .source = .terminal_cursor };
    try std.testing.expectEqual(@as(?Sample, null), t.commit(b));
    try std.testing.expectEqual(b, t.commit(b).?);
}

test "visual_inverse caret commits immediately" {
    var t: StabilityTracker = .{};
    const v: Sample = .{ .x = 7, .y = 2, .source = .visual_inverse };
    try std.testing.expectEqual(v, t.commit(v).?);
    try std.testing.expectEqual(@as(?Sample, null), t.commit(v));
    // A moved visual_inverse caret also commits immediately (no two-frame wait).
    const v2: Sample = .{ .x = 9, .y = 2, .source = .visual_inverse };
    try std.testing.expectEqual(v2, t.commit(v2).?);
}

test "IME visual caret prefers nearest candidate to terminal anchor" {
    const anchor: Point = .{ .x = 4, .y = 20 };
    const near: Point = .{ .x = 5, .y = 20 };
    const far_right: Point = .{ .x = 100, .y = 20 };

    try std.testing.expect(isBetterCandidate(anchor, null, far_right));
    try std.testing.expect(isBetterCandidate(anchor, far_right, near));
    try std.testing.expect(!isBetterCandidate(anchor, near, far_right));
}

test "IME visual caret ranks row distance ahead of column distance" {
    const anchor: Point = .{ .x = 60, .y = 12 };
    const same_row: Point = .{ .x = 12, .y = 12 };
    const next_row_near_x: Point = .{ .x = 60, .y = 13 };

    try std.testing.expect(isBetterCandidate(anchor, next_row_near_x, same_row));
}
