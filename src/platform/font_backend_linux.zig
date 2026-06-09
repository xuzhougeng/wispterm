const std = @import("std");
const font_discovery = @import("font_discovery_linux.zig");

pub const FontWeight = font_discovery.FontWeight;
pub const FallbackFont = font_discovery.FallbackFont;
pub const FontDiscovery = font_discovery.FontDiscovery;
pub const LoadedFont = font_discovery.LoadedFont;
pub const FontFilePath = font_discovery.FontFilePath;

pub const TitlebarIconFont = struct {
    display_name: []const u8,
    path: [:0]const u8,
    face_index: u32 = 0,
};

pub fn titlebarIconFont() TitlebarIconFont {
    return .{
        .display_name = "system titlebar icons",
        .path = "system-titlebar-icons",
    };
}

pub fn titlebarIconGlyph(icon: anytype) u32 {
    return switch (icon) {
        .add => '+',
        .close => 'x',
        .maximize => 0x25A1,
        .minimize => '-',
        .restore => 0x25A3,
    };
}

pub fn fontWeightFromValue(value: u16) FontWeight {
    return font_discovery.fontWeightFromValue(value);
}

pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    return font_discovery.fontFilePathAlloc(allocator, font);
}

pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    return font_discovery.fontDataAlloc(allocator, font);
}
