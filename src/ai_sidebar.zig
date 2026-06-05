//! State and layout math for the right-side AI copilot sidebar.
//!
//! Mirrors browser_panel's right-dock width model, but per-tab UI state lives
//! in TabState: `copilot_session` stores the conversation and `copilot_visible`
//! stores whether that tab's panel is open. This module owns only shared width
//! and layout math. Kept free of tab/AppWindow imports so the math runs in the
//! fast test suite; visibility and the "only on terminal tabs" gate are applied
//! by the caller (AppWindow).

const std = @import("std");

pub const DEFAULT_WIDTH: f32 = 480;
pub const MIN_WIDTH: f32 = 320;
pub const MAX_WIDTH: f32 = 1200;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Shared width across tabs; not persisted across restarts (design decision).
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

/// Set the panel width, clamped to [MIN_WIDTH, maxWidthForWindow]. Returns true
/// if the value changed.
pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

/// Width the panel should occupy for a given window, leaving MIN_CONTENT_WIDTH
/// for the terminal. PURE MATH — does NOT check visibility. Callers MUST gate
/// on visibility themselves; the only supported caller is AppWindow, which
/// checks `aiCopilotVisible()` before using this result. The visibility gate
/// cannot live here because this module deliberately avoids importing
/// `tab`/`AppWindow` so it stays in the fast test suite.
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_width, max_width));
}

/// Pixel bounds of the panel (right-docked). PURE MATH — assumes the caller has
/// already confirmed visibility (see panelWidthForWindow's contract note).
pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);
    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

test "panelWidthForWindow clamps to g_width when it fits" {
    const saved = g_width;
    defer g_width = saved;
    g_width = 480;
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(1600, 0, 0), 0.001);
}

test "panelWidthForWindow shrinks to keep MIN_CONTENT_WIDTH" {
    const saved = g_width;
    defer g_width = saved;
    g_width = 1200;
    // 800 - 0 - 0 - 320 = 480 available; clamped down from 1200.
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(800, 0, 0), 0.001);
}

test "panelWidthForWindow never goes below MIN_WIDTH" {
    const saved = g_width;
    defer g_width = saved;
    g_width = 320;
    // Even a tiny window keeps at least MIN_WIDTH.
    try std.testing.expectApproxEqAbs(MIN_WIDTH, panelWidthForWindow(300, 0, 0), 0.001);
}

test "setWidth clamps and reports change" {
    g_width = DEFAULT_WIDTH;
    try std.testing.expect(setWidth(10_000, 1600)); // clamped to maxWidthForWindow, changed
    try std.testing.expectApproxEqAbs(maxWidthForWindow(1600), g_width, 0.001);
    try std.testing.expect(!setWidth(g_width, 1600)); // no change
    g_width = DEFAULT_WIDTH; // restore for other tests
}

test "boundsForWindow right-docks the panel" {
    const saved = g_width;
    defer g_width = saved;
    g_width = 480;
    const b = boundsForWindow(1600, 900, 30, 0, 0);
    try std.testing.expectEqual(@as(i32, 1600), b.right);
    try std.testing.expectEqual(@as(i32, 1120), b.left); // 1600 - 480
    try std.testing.expectEqual(@as(i32, 30), b.top);
    try std.testing.expectEqual(@as(i32, 900), b.bottom);
}

test "boundsForWindow respects left_offset and right_offset" {
    const saved = g_width;
    defer g_width = saved;
    g_width = 480;
    const b = boundsForWindow(1600, 900, 30, 200, 100);
    try std.testing.expectEqual(@as(i32, 1500), b.right); // 1600 - 100
    try std.testing.expectEqual(@as(i32, 1020), b.left); // 1500 - 480
}
