const std = @import("std");

pub const IDLE_OPACITY: f32 = 0.72;

pub fn effectiveOpacity(stored_opacity: f32, has_scrollback: bool) f32 {
    if (!has_scrollback) return 0;
    const clamped = if (stored_opacity < 0)
        @as(f32, 0)
    else if (stored_opacity > 1)
        @as(f32, 1)
    else
        stored_opacity;
    return @max(IDLE_OPACITY, clamped);
}

pub fn canInteract(has_scrollback: bool) bool {
    return has_scrollback;
}

test "scrollbar remains visible and interactive at idle when scrollback exists" {
    try std.testing.expect(effectiveOpacity(0, true) > 0.01);
    try std.testing.expect(canInteract(true));
}

test "scrollbar hides and ignores input without scrollback" {
    try std.testing.expectEqual(@as(f32, 0), effectiveOpacity(1, false));
    try std.testing.expect(!canInteract(false));
}
