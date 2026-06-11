//! Pure layout math shared by right-docked panels.

const std = @import("std");

/// Keep enough terminal columns visible when a right-docked panel is open.
/// Very narrow SSH PTYs can cause host-side prompt redraws to corrupt history.
pub const MIN_TERMINAL_COLS: u16 = 40;

pub fn terminalReserveWidth(cell_width: f32, padding_left: f32, padding_right: f32) f32 {
    const safe_cell_width = @max(cell_width, 1.0);
    return @as(f32, @floatFromInt(MIN_TERMINAL_COLS)) * safe_cell_width + padding_left + padding_right;
}

pub fn rightPanelBudget(window_width: i32, left_offset: f32, reserve_width: f32) f32 {
    const win_w: f32 = @floatFromInt(@max(window_width, 0));
    return @max(0, win_w - left_offset - reserve_width);
}

/// Clamp a panel to the remaining right-panel budget. If the whole window is
/// too small to satisfy both panel min width and terminal reserve, keep the
/// terminal reserve and let the panel shrink below its nominal minimum.
pub fn clampPanelWidth(stored_width: f32, min_width: f32, max_width: f32, budget: f32) f32 {
    const usable_budget = @max(0, budget);
    const capped = @min(stored_width, @min(max_width, usable_budget));
    if (usable_budget >= min_width) return @max(min_width, capped);
    return @max(0, capped);
}

test "terminalReserveWidth includes cell columns and horizontal padding" {
    try std.testing.expectApproxEqAbs(@as(f32, 432), terminalReserveWidth(10, 10, 22), 0.001);
}

test "rightPanelBudget reserves terminal content after left panels" {
    try std.testing.expectApproxEqAbs(@as(f32, 968), rightPanelBudget(1600, 200, 432), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rightPanelBudget(500, 200, 432), 0.001);
}

test "clampPanelWidth respects panel min when budget allows" {
    try std.testing.expectApproxEqAbs(@as(f32, 480), clampPanelWidth(480, 320, 1200, 900), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 320), clampPanelWidth(120, 320, 1200, 900), 0.001);
}

test "clampPanelWidth preserves terminal reserve when budget is tiny" {
    try std.testing.expectApproxEqAbs(@as(f32, 180), clampPanelWidth(480, 320, 1200, 180), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), clampPanelWidth(480, 320, 1200, 0), 0.001);
}
