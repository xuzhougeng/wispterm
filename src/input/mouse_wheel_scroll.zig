const std = @import("std");

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
