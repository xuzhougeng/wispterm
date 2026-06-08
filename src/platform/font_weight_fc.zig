//! Pure mapping from an OS/2 font weight (100..900, as used by the neutral
//! FontWeight enum) to a fontconfig FC_WEIGHT_* value. No fontconfig dependency
//! so it runs in the fast suite; font_discovery_linux.zig calls fcWeight() with
//! @intFromEnum(weight). FC_WEIGHT_* values are fontconfig's stable scale
//! (THIN=0, REGULAR=80, BOLD=200, BLACK=210).
const std = @import("std");

/// FC_WEIGHT_* constants (fontconfig stable scale).
pub const FC_WEIGHT_THIN: c_int = 0;
pub const FC_WEIGHT_REGULAR: c_int = 80;
pub const FC_WEIGHT_BOLD: c_int = 200;
pub const FC_WEIGHT_BLACK: c_int = 210;

pub fn fcWeight(os_weight: u16) c_int {
    return switch (os_weight) {
        100 => FC_WEIGHT_THIN,
        700 => FC_WEIGHT_BOLD,
        900 => FC_WEIGHT_BLACK,
        else => FC_WEIGHT_REGULAR,
    };
}

test "OS weights map to fontconfig weights" {
    try std.testing.expectEqual(@as(c_int, 0), fcWeight(100)); // THIN
    try std.testing.expectEqual(@as(c_int, 80), fcWeight(400)); // REGULAR
    try std.testing.expectEqual(@as(c_int, 200), fcWeight(700)); // BOLD
    try std.testing.expectEqual(@as(c_int, 210), fcWeight(900)); // BLACK
    try std.testing.expectEqual(@as(c_int, 80), fcWeight(450)); // unknown → REGULAR
}
