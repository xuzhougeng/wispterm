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
