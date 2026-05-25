const std = @import("std");
const font_discovery = @import("font_discovery_windows.zig");

pub const FontWeight = font_discovery.DWRITE_FONT_WEIGHT;
pub const FallbackFont = font_discovery.IDWriteFont;
pub const FontDiscovery = font_discovery.FontDiscovery;
pub const LoadedFont = font_discovery.LoadedFont;

pub const FontFilePath = struct {
    path: [:0]const u8,
    face_index: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FontFilePath) void {
        self.allocator.free(self.path);
    }
};

pub const TitlebarIconFont = struct {
    display_name: []const u8,
    path: [:0]const u8,
    face_index: u32 = 0,
};

pub fn titlebarIconFont() TitlebarIconFont {
    return .{
        .display_name = "Segoe MDL2 Assets",
        .path = "C:\\Windows\\Fonts\\segmdl2.ttf",
    };
}

pub fn titlebarIconGlyph(icon: anytype) u32 {
    return switch (icon) {
        .add => 0xE948,
        .close => 0xE8BB,
        .maximize => 0xE922,
        .minimize => 0xE921,
        .restore => 0xE923,
    };
}

pub fn fontWeightFromValue(value: u16) FontWeight {
    return font_discovery.fontWeightFromValue(value);
}

pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    const face = font.createFontFace() catch return null;
    defer face.release();

    const face_index = face.getIndex();

    const font_file = face.getFiles() catch return null;
    defer font_file.release();

    const loader = font_file.getLoader() catch return null;
    defer loader.release();

    const local_loader = loader.queryLocalFontFileLoader() orelse return null;
    defer local_loader.release();

    const ref_key = font_file.getReferenceKey() catch return null;
    const path_len = local_loader.getFilePathLengthFromKey(ref_key.key, ref_key.size) catch return null;

    var path_buf = allocator.alloc(u16, path_len + 1) catch return null;
    defer allocator.free(path_buf);

    local_loader.getFilePathFromKey(ref_key.key, ref_key.size, path_buf) catch return null;

    const utf8_path = std.unicode.utf16LeToUtf8AllocZ(allocator, path_buf[0..path_len]) catch return null;
    return .{
        .path = utf8_path,
        .face_index = face_index,
        .allocator = allocator,
    };
}
