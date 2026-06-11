//! 纯逻辑：URL 悬停下划线的逐行列跨度计算。
//!
//! 渲染端原来对每个 cell 调一次判定（内部每次都拿 surface 锁算视口偏移，
//! 悬停链接时一帧上万次锁操作）；现在改为每行一次 O(1) 跨度计算，
//! 视口偏移由调用方用快照期缓存的值传入。
//! 刻意零项目依赖（只用 std），便于 `zig test src/input/underline_span.zig` 独立单测。
const std = @import("std");

/// 下划线覆盖范围（绝对滚动行号 + 起止列，闭区间；跨行时首行从 start_col
/// 到行尾、末行从行首到 end_col、中间行整行）。
pub const Range = struct {
    start_row_abs: usize,
    end_row_abs: usize,
    start_col: usize,
    end_col: usize,
};

/// 一行内的下划线列跨度（闭区间）。
pub const Span = struct {
    start_col: usize,
    end_col: usize,
};

/// 绝对行 abs_row（宽 cols 列）上的下划线跨度；不相交时返回 null。
/// 列越界按 cols 截断（cols == 0 恒为 null）。
pub fn colSpanForRow(range: Range, abs_row: usize, cols: usize) ?Span {
    if (cols == 0) return null;
    if (abs_row < range.start_row_abs or abs_row > range.end_row_abs) return null;

    const single_row = range.start_row_abs == range.end_row_abs;
    const start: usize = if (abs_row == range.start_row_abs) range.start_col else 0;
    const end_raw: usize = if (single_row or abs_row == range.end_row_abs) range.end_col else cols - 1;

    if (start >= cols) return null;
    const end = @min(end_raw, cols - 1);
    if (end < start) return null;
    return .{ .start_col = start, .end_col = end };
}

// ============================================================================
// Tests
// ============================================================================

test "单行范围：起止列原样返回" {
    const r: Range = .{ .start_row_abs = 5, .end_row_abs = 5, .start_col = 3, .end_col = 9 };
    const span = colSpanForRow(r, 5, 80).?;
    try std.testing.expectEqual(@as(usize, 3), span.start_col);
    try std.testing.expectEqual(@as(usize, 9), span.end_col);
}

test "行不相交返回 null" {
    const r: Range = .{ .start_row_abs = 5, .end_row_abs = 6, .start_col = 3, .end_col = 9 };
    try std.testing.expect(colSpanForRow(r, 4, 80) == null);
    try std.testing.expect(colSpanForRow(r, 7, 80) == null);
}

test "跨行：首行到行尾、末行从行首、中间行整行" {
    const r: Range = .{ .start_row_abs = 5, .end_row_abs = 7, .start_col = 70, .end_col = 9 };
    const first = colSpanForRow(r, 5, 80).?;
    try std.testing.expectEqual(@as(usize, 70), first.start_col);
    try std.testing.expectEqual(@as(usize, 79), first.end_col);

    const mid = colSpanForRow(r, 6, 80).?;
    try std.testing.expectEqual(@as(usize, 0), mid.start_col);
    try std.testing.expectEqual(@as(usize, 79), mid.end_col);

    const last = colSpanForRow(r, 7, 80).?;
    try std.testing.expectEqual(@as(usize, 0), last.start_col);
    try std.testing.expectEqual(@as(usize, 9), last.end_col);
}

test "列越界截断到 cols-1；起点越界返回 null" {
    const r: Range = .{ .start_row_abs = 2, .end_row_abs = 2, .start_col = 10, .end_col = 200 };
    const span = colSpanForRow(r, 2, 80).?;
    try std.testing.expectEqual(@as(usize, 79), span.end_col);

    const off: Range = .{ .start_row_abs = 2, .end_row_abs = 2, .start_col = 100, .end_col = 200 };
    try std.testing.expect(colSpanForRow(off, 2, 80) == null);
    try std.testing.expect(colSpanForRow(r, 2, 0) == null);
}
