//! Pure geometry for the preview pane's top-right close (×) button.
//!
//! Shared by the renderer (markdown_preview_renderer.zig draws the button) and
//! the click hit-test (split_layout/input.zig), so the box that is drawn and the
//! box that is clickable can never drift apart. All coordinates here are
//! TOP-DOWN window pixels (y grows downward, matching mouse events and
//! SplitRect); the renderer flips y into GL space when drawing.
//!
//! This module owns HEADER_HEIGHT (the preview header-bar height) so there is a
//! single source of truth; the renderer re-exports it for its own use.

const std = @import("std");

/// Height of the preview header bar. The header is an otherwise-empty separator
/// strip (the badge/title/path live in the footer), so the whole top-right
/// corner is free for the close button.
pub const HEADER_HEIGHT: f32 = 42;

/// Side length of the square draw/hit box for the × button.
pub const BUTTON_SIZE: f32 = 24;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// Close-button box for a preview pane whose content rect starts at
/// (`panel_x`, `panel_top`) with width `panel_w`. Right-aligned in the header
/// and vertically centered within it.
pub fn rect(panel_x: f32, panel_top: f32, panel_w: f32) Rect {
    const margin = (HEADER_HEIGHT - BUTTON_SIZE) / 2;
    return .{
        .x = panel_x + panel_w - BUTTON_SIZE - margin,
        .y = panel_top + margin,
        .w = BUTTON_SIZE,
        .h = BUTTON_SIZE,
    };
}

/// True when (`px`, `py`) — top-down window pixels — lies within the close
/// button of a pane at (`panel_x`, `panel_top`, `panel_w`).
pub fn contains(panel_x: f32, panel_top: f32, panel_w: f32, px: f32, py: f32) bool {
    const b = rect(panel_x, panel_top, panel_w);
    return px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h;
}

test "rect sits in the header's top-right corner" {
    const b = rect(100, 50, 400);
    // Right-aligned: the button's right edge hugs the panel's right edge with a
    // small margin, and never spills past it.
    try std.testing.expect(b.x + b.w <= 100 + 400);
    try std.testing.expect(b.x + b.w > 100 + 400 - HEADER_HEIGHT);
    // Vertically centered inside the header band.
    try std.testing.expect(b.y >= 50);
    try std.testing.expect(b.y + b.h <= 50 + HEADER_HEIGHT);
    try std.testing.expectEqual(BUTTON_SIZE, b.w);
    try std.testing.expectEqual(BUTTON_SIZE, b.h);
}

test "contains matches the rect bounds" {
    const panel_x: f32 = 100;
    const panel_top: f32 = 50;
    const panel_w: f32 = 400;
    const b = rect(panel_x, panel_top, panel_w);

    // Center of the button is inside.
    try std.testing.expect(contains(panel_x, panel_top, panel_w, b.x + b.w / 2, b.y + b.h / 2));

    // The far-left of the header (over the empty title area) is NOT the button.
    try std.testing.expect(!contains(panel_x, panel_top, panel_w, panel_x + 8, panel_top + 8));

    // Just below the header band is NOT the button (that's the document body).
    try std.testing.expect(!contains(panel_x, panel_top, panel_w, b.x + 1, panel_top + HEADER_HEIGHT + 4));

    // Just past the panel's right edge is NOT the button.
    try std.testing.expect(!contains(panel_x, panel_top, panel_w, panel_x + panel_w + 1, b.y + 1));
}

test "rect tracks panel position and width" {
    const a = rect(0, 0, 300);
    const b = rect(0, 0, 600);
    // Wider panel pushes the button further right by exactly the width delta.
    try std.testing.expectEqual(a.x + 300, b.x);

    const shifted = rect(120, 0, 300);
    try std.testing.expectEqual(a.x + 120, shifted.x);

    const lowered = rect(0, 80, 300);
    try std.testing.expectEqual(a.y + 80, lowered.y);
}
