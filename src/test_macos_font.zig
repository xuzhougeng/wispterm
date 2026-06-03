//! Native macOS CoreText font backend smoke-test entry point.

const std = @import("std");
const font_backend = @import("platform/font_backend.zig");

test "CoreText backend discovers family paths and glyph fallback" {
    var discovery = try font_backend.FontDiscovery.init();
    defer discovery.deinit();

    const families = try discovery.listFontFamilies(std.testing.allocator);
    defer {
        for (families) |family| std.testing.allocator.free(family);
        std.testing.allocator.free(families);
    }
    try std.testing.expect(families.len > 0);

    var result = (try discovery.findFontFilePath(
        std.testing.allocator,
        "Menlo",
        .NORMAL,
        .NORMAL,
    )) orelse return error.ExpectedMenloFont;
    defer result.deinit();
    try std.testing.expect(result.path.len > 0);

    const font = (try discovery.findFallbackFont('A')) orelse return error.ExpectedFallbackFont;
    defer font.release();
    try std.testing.expect(font.hasCharacter('A'));

    var loaded = try font_backend.LoadedFont.init(font);
    defer loaded.deinit();
    try std.testing.expect(loaded.hasGlyph('A'));
}

test "CoreText backend honors preferred fallback families" {
    var discovery = try font_backend.FontDiscovery.init();
    defer discovery.deinit();

    const preferred = [_][]const u8{ "Menlo", "Helvetica" };
    const font = (try discovery.findPreferredFallbackFont('A', &preferred)) orelse return error.ExpectedPreferredFallbackFont;
    defer font.release();
    var path = font_backend.fontFilePathAlloc(std.testing.allocator, font) orelse return error.ExpectedPreferredFallbackPath;
    defer path.deinit();

    try std.testing.expect(path.path.len > 0);
}

test "CoreText backend reconstructs a loadable sfnt for the CJK fallback" {
    var discovery = try font_backend.FontDiscovery.init();
    defer discovery.deinit();

    // U+4E2D 中 — a common ideograph present in every macOS CJK system font.
    // On stock macOS this resolves (via the default cascade) to the reserved
    // PingFang.ttc, whose file path FreeType cannot open: the bug this fixes.
    const cjk: u32 = 0x4E2D;
    const font = (try discovery.findFallbackFont(cjk)) orelse return error.ExpectedCjkFallbackFont;
    defer font.release();
    try std.testing.expect(font.hasCharacter(cjk));

    const data = font_backend.fontDataAlloc(std.testing.allocator, font) orelse
        return error.ExpectedReconstructedFontData;
    defer std.testing.allocator.free(data);

    // Validate the sfnt container: 12-byte offset table + 16 bytes per entry.
    try std.testing.expect(data.len > 12);
    const version = std.mem.readInt(u32, data[0..4], .big);
    const truetype: u32 = 0x00010000;
    const opentype: u32 = 0x4F54544F; // 'OTTO'
    try std.testing.expect(version == truetype or version == opentype);

    const num_tables = std.mem.readInt(u16, data[4..6], .big);
    try std.testing.expect(num_tables > 0);
    try std.testing.expect(data.len >= 12 + @as(usize, num_tables) * 16);

    // Every table directory entry must reference bytes inside the buffer.
    var i: usize = 0;
    while (i < num_tables) : (i += 1) {
        const dir = 12 + i * 16;
        const offset = std.mem.readInt(u32, data[dir + 8 ..][0..4], .big);
        const length = std.mem.readInt(u32, data[dir + 12 ..][0..4], .big);
        try std.testing.expect(@as(usize, offset) + @as(usize, length) <= data.len);
    }
}

test {
    _ = font_backend;
}
