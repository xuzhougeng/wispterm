//! Pure PNG header (IHDR) dimension probe.
//!
//! The kitty-graphics PNG decoder hands attacker-controllable bytes (any
//! program that can write to the terminal can emit a graphics APC) to stb,
//! which happily decodes images up to INT_MAX output bytes — a tiny crafted
//! file declaring huge dimensions forces a multi-GB transient allocation
//! (decompression bomb). Decoders consult this probe BEFORE decoding and
//! reject oversized declarations outright.

const std = @import("std");

/// Per-axis ceiling, following kitty's own 10000×10000 image limit; worst
/// case decoded RGBA stays at 400MB instead of stb's INT_MAX.
pub const MAX_DIMENSION: u32 = 10000;

pub const Dimensions = struct { width: u32, height: u32 };

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Extract the declared dimensions from a PNG byte stream, or null when the
/// data is not a PNG whose first chunk is a well-formed IHDR (PNGs require
/// IHDR first, so anything else is malformed anyway).
pub fn parse(data: []const u8) ?Dimensions {
    // signature(8) + chunk length(4) + "IHDR"(4) + width(4) + height(4)
    if (data.len < 24) return null;
    if (!std.mem.eql(u8, data[0..8], &png_signature)) return null;
    if (std.mem.readInt(u32, data[8..12], .big) != 13) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    return .{
        .width = std.mem.readInt(u32, data[16..20], .big),
        .height = std.mem.readInt(u32, data[20..24], .big),
    };
}

pub fn exceedsLimit(dims: Dimensions) bool {
    return dims.width > MAX_DIMENSION or dims.height > MAX_DIMENSION;
}

// ---- Tests ----

fn testHeader(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], &png_signature);
    std.mem.writeInt(u32, bytes[8..12], 13, .big); // IHDR data length
    @memcpy(bytes[12..16], "IHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

test "parse reads the declared IHDR dimensions" {
    const header = testHeader(640, 480);
    const dims = parse(&header) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 640), dims.width);
    try std.testing.expectEqual(@as(u32, 480), dims.height);
}

test "parse rejects truncated data" {
    const header = testHeader(640, 480);
    try std.testing.expectEqual(@as(?Dimensions, null), parse(header[0..16]));
    try std.testing.expectEqual(@as(?Dimensions, null), parse(""));
}

test "parse rejects a bad signature" {
    var header = testHeader(640, 480);
    header[0] = 'X';
    try std.testing.expectEqual(@as(?Dimensions, null), parse(&header));
}

test "parse rejects a first chunk that is not IHDR" {
    var header = testHeader(640, 480);
    @memcpy(header[12..16], "IDAT");
    try std.testing.expectEqual(@as(?Dimensions, null), parse(&header));
}

test "exceedsLimit allows up to MAX_DIMENSION per axis" {
    try std.testing.expect(!exceedsLimit(.{ .width = MAX_DIMENSION, .height = MAX_DIMENSION }));
    try std.testing.expect(exceedsLimit(.{ .width = MAX_DIMENSION + 1, .height = 1 }));
    try std.testing.expect(exceedsLimit(.{ .width = 1, .height = MAX_DIMENSION + 1 }));
}
