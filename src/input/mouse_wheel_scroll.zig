const std = @import("std");

/// Platform wheel delta of one detent (Win32 WHEEL_DELTA; the macOS and SDL
/// hosts scale their deltas onto the same unit).
pub const delta_per_notch: f64 = 120;

/// Rows scrolled per detent — Ghostty's default discrete
/// `mouse-scroll-multiplier`.
pub const rows_per_notch: f64 = 3;

/// Turns a stream of wheel deltas into whole terminal rows, carrying the
/// sub-row remainder to the next event.
///
/// Precision touchpads, high-resolution wheels and remote-desktop input
/// injectors deliver a detent as many small deltas. Rounding each event on its
/// own either drops them (scrollback barely moves) or rounds every one up to a
/// full row (a mouse-reporting TUI gets a wheel report per event and repaints
/// its whole screen for each — a flood when the TUI runs over SSH). Ghostty's
/// `Surface.scrollCallback` solves it the same way with `pending_scroll_y`.
pub const Accumulator = struct {
    /// Carried remainder in rows; always within (-1, 1).
    pending_rows: f64 = 0,

    /// Feed one wheel delta (positive = scroll up). Returns the whole rows to
    /// scroll now, in the same sign as the delta.
    pub fn feed(self: *Accumulator, delta: i16) isize {
        const total = self.pending_rows + @as(f64, @floatFromInt(delta)) * rows_per_notch / delta_per_notch;
        // Round towards zero; an opposite-direction delta may undo a pending
        // remainder instead of scrolling, as in Ghostty.
        const whole = @trunc(total);
        self.pending_rows = total - whole;
        return @intFromFloat(whole);
    }
};

pub const RepaintFlags = struct {
    force_rebuild: bool,
    cells_valid: bool,
};

pub fn repaintFlagsForViewportScroll(delta_rows: isize) ?RepaintFlags {
    if (delta_rows == 0) return null;
    return .{
        .force_rebuild = true,
        .cells_valid = false,
    };
}

test "viewport wheel scroll requests a repaint when rows move" {
    const flags = repaintFlagsForViewportScroll(-3) orelse return error.ExpectedRepaint;
    try std.testing.expect(flags.force_rebuild);
    try std.testing.expect(!flags.cells_valid);
}

test "zero-row wheel scroll does not request a repaint" {
    try std.testing.expect(repaintFlagsForViewportScroll(0) == null);
}

test "a full detent scrolls three rows with nothing left over" {
    var acc: Accumulator = .{};
    try std.testing.expectEqual(@as(isize, 3), acc.feed(120));
    try std.testing.expectEqual(@as(f64, 0), acc.pending_rows);
    try std.testing.expectEqual(@as(isize, -6), acc.feed(-240));
    try std.testing.expectEqual(@as(f64, 0), acc.pending_rows);
}

test "small deltas accumulate into rows instead of one row per event" {
    var acc: Accumulator = .{};
    // A detent delivered as 12 touchpad events of 10: 3 rows in total, not 12.
    var rows: isize = 0;
    var events_with_rows: usize = 0;
    for (0..12) |_| {
        const step = acc.feed(10);
        rows += step;
        if (step != 0) events_with_rows += 1;
    }
    try std.testing.expectEqual(@as(isize, 3), rows);
    try std.testing.expectEqual(@as(usize, 3), events_with_rows);
}

test "sub-row deltas are kept, not dropped" {
    var acc: Accumulator = .{};
    // 30 is three quarters of a row: nothing yet, then a row on the second.
    try std.testing.expectEqual(@as(isize, 0), acc.feed(30));
    try std.testing.expectEqual(@as(isize, 1), acc.feed(30));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), acc.pending_rows, 1e-9);
}

test "reversing direction undoes the pending remainder first" {
    var acc: Accumulator = .{};
    try std.testing.expectEqual(@as(isize, 0), acc.feed(30));
    try std.testing.expectEqual(@as(isize, 0), acc.feed(-30));
    try std.testing.expectEqual(@as(isize, -1), acc.feed(-40));
}

test "the extreme deltas stay in range" {
    var acc: Accumulator = .{};
    try std.testing.expectEqual(@as(isize, 819), acc.feed(32767));
    try std.testing.expectEqual(@as(isize, -819), acc.feed(-32768));
}
