//! Shared geometry contracts for WispTerm's three UI presentation styles.
//!
//! Command palettes are transient search-and-act dialogs. Form dialogs collect
//! or confirm a small amount of configuration. Workbenches are persistent tab
//! pages with a header, content area, and an always-readable footer. Keep this
//! module free of renderer/AppWindow imports so the geometry stays testable.

const std = @import("std");

pub const Style = enum {
    command_palette,
    form_dialog,
    workbench,
};

/// Calculates a centered modal width without allowing narrow windows to paint
/// beyond their side gutters. `preferred_width` is clamped by the style's min
/// and max, then by the viewport that remains after the gutters.
pub fn modalWidth(
    window_width: f32,
    min_width: f32,
    preferred_width: f32,
    max_width: f32,
    side_gutter: f32,
) f32 {
    const available = @max(1.0, window_width - side_gutter * 2.0);
    const capped_max = @min(max_width, available);
    return @round(@min(capped_max, @max(min_width, preferred_width)));
}

/// A workbench footer is its own persistent information band. It keeps
/// keyboard hints and non-blocking status out of feature columns.
pub fn workbenchFooterHeight(cell_height: f32) f32 {
    return @round(@max(44.0, cell_height + 24.0));
}

/// Top-down y coordinate where a workbench footer begins.
pub fn workbenchFooterTop(window_height: f32, top_offset: f32, footer_height: f32) f32 {
    return @max(top_offset, window_height - footer_height);
}

test "modal width honors gutters before the style minimum" {
    // A narrow viewport must not overflow merely to satisfy a modal minimum.
    try std.testing.expectEqual(@as(f32, 396), modalWidth(460, 420, 500, 500, 32));
    try std.testing.expectEqual(@as(f32, 500), modalWidth(1600, 420, 500, 500, 32));
}

test "workbench footer stays below the content top" {
    const h = workbenchFooterHeight(20);
    try std.testing.expectEqual(@as(f32, 44), h);
    try std.testing.expectEqual(@as(f32, 756), workbenchFooterTop(800, 40, h));
    try std.testing.expectEqual(@as(f32, 80), workbenchFooterTop(80, 80, h));
}
