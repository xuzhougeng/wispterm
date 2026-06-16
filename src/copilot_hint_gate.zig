//! Pure (std-only) decisions for the Copilot discoverability hint. No I/O, no
//! GL, no window — unit-tested in the fast suite. The render/input shell in
//! AppWindow/input.zig supplies the runtime inputs and performs the effects.
const std = @import("std");

pub const ShimmerDecision = enum { shimmer, skip };

/// Whether to play the one-time first-session shimmer on the edge handle.
/// Shimmer only when the feature is enabled, the handle is eligible (a terminal
/// tab with Copilot closed and room to open it), and the user has never seen
/// the hint before.
pub fn shimmerDecision(
    feature_enabled: bool,
    handle_eligible: bool,
    hint_already_shown: bool,
) ShimmerDecision {
    if (!feature_enabled) return .skip;
    if (!handle_eligible) return .skip;
    if (hint_already_shown) return .skip;
    return .shimmer;
}

/// Target reveal alpha [0, revealed_alpha] for the closed-state handle, from the
/// cursor's proximity to the window's right content edge. Pure math; the
/// renderer eases the actual alpha toward this and applies the hover boost.
/// `mouse_x`/`mouse_y` are framebuffer px (top-left origin); the platform passes
/// negative values when the cursor is outside the window.
pub fn handleRevealTarget(
    mouse_x: f32,
    mouse_y: f32,
    window_w: f32,
    titlebar_h: f32,
    reveal_zone_w: f32,
    revealed_alpha: f32,
) f32 {
    if (mouse_x < 0 or mouse_y < 0) return 0;
    if (mouse_y < titlebar_h) return 0; // in the titlebar, not content
    const dist = window_w - mouse_x;
    if (dist < 0 or dist > reveal_zone_w) return 0;
    return revealed_alpha;
}

test "shimmer only on first eligible terminal frame" {
    try std.testing.expectEqual(ShimmerDecision.shimmer, shimmerDecision(true, true, false));
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(false, true, false)); // disabled
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(true, false, false)); // not eligible
    try std.testing.expectEqual(ShimmerDecision.skip, shimmerDecision(true, true, true)); // already shown
}

test "reveal target rises near the right edge only, below the titlebar" {
    // far from edge -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(100, 400, 1000, 30, 28, 0.5));
    // within zone, in content -> revealed
    try std.testing.expectEqual(@as(f32, 0.5), handleRevealTarget(985, 400, 1000, 30, 28, 0.5));
    // within zone but in the titlebar -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(985, 10, 1000, 30, 28, 0.5));
    // cursor outside window (negative sentinel) -> 0
    try std.testing.expectEqual(@as(f32, 0), handleRevealTarget(-1, -1, 1000, 30, 28, 0.5));
}
