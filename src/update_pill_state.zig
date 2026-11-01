//! Whether the titlebar shows the "Update" pill: a staged update is ready to
//! restart into (Ghostty's macOS UpdatePill, magpie's header Update button).
//! Written by the updater worker, read by the titlebar renderer and by the
//! Win32/SDL hit-tests that carve the pill out of the draggable caption, so it
//! is a lone atomic with no imports.
const std = @import("std");

/// Width of the pill slot, left of the command center button, while visible.
pub const width: f32 = 84;

var ready = std.atomic.Value(bool).init(false);

pub fn setReady(value: bool) void {
    ready.store(value, .release);
}

pub fn isReady() bool {
    return ready.load(.acquire);
}

/// Titlebar width the pill takes now (0 while hidden).
pub fn currentWidth() f32 {
    return if (isReady()) width else 0;
}

test "update pill takes width only while ready" {
    setReady(false);
    try std.testing.expectEqual(@as(f32, 0), currentWidth());
    setReady(true);
    defer setReady(false);
    try std.testing.expectEqual(width, currentWidth());
}
