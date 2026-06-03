const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    macos,
    unsupported,
};

pub fn backendForOs(comptime os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .macos => .macos,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("font_backend_windows.zig"),
    .macos => @import("font_backend_macos.zig"),
    .unsupported => @import("font_backend_unsupported.zig"),
};

pub const FontWeight = impl.FontWeight;
pub const FallbackFont = impl.FallbackFont;
pub const FontDiscovery = impl.FontDiscovery;
pub const FontFilePath = impl.FontFilePath;
pub const LoadedFont = impl.LoadedFont;

pub const TitlebarIconFont = struct {
    display_name: []const u8,
    path: [:0]const u8,
    face_index: u32 = 0,
};

pub const TitlebarIcon = enum {
    add,
    close,
    maximize,
    minimize,
    restore,
};

pub fn discoveryDisplayName() []const u8 {
    return "system font backend";
}

pub fn discoveryInitErrorPrefix() []const u8 {
    return "Failed to initialize system font backend";
}

pub fn titlebarIconFont() TitlebarIconFont {
    const icon_font = impl.titlebarIconFont();
    return .{
        .display_name = icon_font.display_name,
        .path = icon_font.path,
        .face_index = icon_font.face_index,
    };
}

pub fn titlebarIconGlyph(icon: TitlebarIcon) u32 {
    return impl.titlebarIconGlyph(icon);
}

pub fn fontWeightFromValue(value: u16) FontWeight {
    return impl.fontWeightFromValue(value);
}

pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    return impl.fontFilePathAlloc(allocator, font);
}

/// Copy a fallback font's raw sfnt bytes into an allocator-owned buffer, for
/// loading via FreeType's memory-face API. Returns null when the backend cannot
/// extract data (only macOS implements this; other backends rely on path-based
/// loading). Caller owns the returned slice.
pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    return impl.fontDataAlloc(allocator, font);
}

test "platform font backend exposes discovery and weight APIs" {
    _ = FontDiscovery;
    _ = LoadedFont;
    _ = FallbackFont;
    _ = FontFilePath;
    try std.testing.expect(@hasDecl(@This(), "fontFilePathAlloc"));
    try std.testing.expect(@hasDecl(@This(), "fontDataAlloc"));
    try std.testing.expectEqual(FontWeight.BOLD, fontWeightFromValue(700));
    try std.testing.expectEqual(FontWeight.NORMAL, fontWeightFromValue(123));
}

test "platform font backend exposes platform-neutral user labels" {
    try std.testing.expect(std.mem.indexOf(u8, discoveryDisplayName(), "DirectWrite") == null);
    try std.testing.expect(std.mem.indexOf(u8, discoveryInitErrorPrefix(), "DirectWrite") == null);
}

test "platform font backend exposes titlebar icon font through facade" {
    const icon_font = titlebarIconFont();
    try std.testing.expect(icon_font.display_name.len > 0);
    try std.testing.expect(icon_font.path.len > 0);
    try std.testing.expect(icon_font.face_index == 0);
}

test "platform font backend owns titlebar icon glyph mapping" {
    try std.testing.expect(titlebarIconGlyph(.add) != 0);
    try std.testing.expect(titlebarIconGlyph(.close) != 0);
    try std.testing.expect(titlebarIconGlyph(.minimize) != 0);
    try std.testing.expect(titlebarIconGlyph(.maximize) != 0);
    try std.testing.expect(titlebarIconGlyph(.restore) != 0);
    try std.testing.expect(titlebarIconGlyph(.maximize) != titlebarIconGlyph(.restore));
}

test "platform font backend selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.macos, backendForOs(.macos));
}
