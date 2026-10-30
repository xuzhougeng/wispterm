//! Geometry types for the Copilot panel hosted in the right dock.
//!
//! The Copilot sidebar is now the "Copilot" tab of the right dock
//! (`appwindow/right_dock.zig`), which owns the shared width, the per-tab
//! open/selected state (`TabState.right_dock`) and the dock layout. This module
//! only describes the panel rect the conversation renderer and its hit-tests
//! draw into. Kept free of tab/AppWindow imports so it runs in the fast suite.

const std = @import("std");

/// Copilot panel rect in top-down pixels: the dock's content area below its
/// tab row.
pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const PanelGeometry = struct {
    window_width: f32,
    window_height: f32,
    /// Top edge of the conversation (its header starts here).
    top: f32,
    chat_x: f32,
    chat_w: f32,
};

pub fn panelGeometryForBounds(window_width: i32, window_height: i32, bounds: Bounds) PanelGeometry {
    return .{
        .window_width = @floatFromInt(window_width),
        .window_height = @floatFromInt(window_height),
        .top = @floatFromInt(bounds.top),
        .chat_x = @floatFromInt(bounds.left),
        .chat_w = @floatFromInt(@max(0, bounds.right - bounds.left)),
    };
}

test "panelGeometryForBounds exposes chat origin, top and width" {
    const b = Bounds{
        .left = 1120,
        .top = 64,
        .right = 1600,
        .bottom = 900,
    };
    const geometry = panelGeometryForBounds(1600, 900, b);

    try std.testing.expectApproxEqAbs(@as(f32, 1600), geometry.window_width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 900), geometry.window_height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64), geometry.top, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1120), geometry.chat_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 480), geometry.chat_w, 0.001);
}
