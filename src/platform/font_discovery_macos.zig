const std = @import("std");

const FontStyle = enum {
    NORMAL,
};

pub const FontWeight = enum(u32) {
    THIN = 100,
    NORMAL = 400,
    BOLD = 700,
    BLACK = 900,
};

pub const FontFilePath = struct {
    path: [:0]const u8,
    face_index: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FontFilePath) void {
        self.allocator.free(self.path);
    }
};

extern fn wispterm_coretext_is_available() bool;
extern fn wispterm_coretext_find_font(family: [*:0]const u8, weight: u16) ?*anyopaque;
extern fn wispterm_coretext_find_fallback(codepoint: u32) ?*anyopaque;
extern fn wispterm_coretext_font_retain(handle: *anyopaque) void;
extern fn wispterm_coretext_font_release(handle: *anyopaque) void;
extern fn wispterm_coretext_font_has_character(handle: *anyopaque, codepoint: u32) bool;
extern fn wispterm_coretext_font_glyph_index(handle: *anyopaque, codepoint: u32) u16;
extern fn wispterm_coretext_font_copy_path(handle: *anyopaque) ?[*:0]u8;
extern fn wispterm_coretext_font_copy_table_data(handle: *anyopaque, out_len: *usize) ?[*]u8;
extern fn wispterm_coretext_family_count() usize;
extern fn wispterm_coretext_copy_family_name(index: usize) ?[*:0]u8;
extern fn wispterm_coretext_free(ptr: ?*anyopaque) void;

pub const FallbackFont = struct {
    handle: *anyopaque,

    fn wrap(handle: *anyopaque) !*FallbackFont {
        const font = try std.heap.c_allocator.create(FallbackFont);
        font.* = .{ .handle = handle };
        return font;
    }

    pub fn release(self: *FallbackFont) void {
        wispterm_coretext_font_release(self.handle);
        std.heap.c_allocator.destroy(self);
    }

    pub fn hasCharacter(self: *FallbackFont, codepoint: u32) bool {
        return wispterm_coretext_font_has_character(self.handle, codepoint);
    }
};

pub const FontDiscovery = struct {
    pub const FontResult = FontFilePath;

    pub fn init() !FontDiscovery {
        if (!wispterm_coretext_is_available()) return error.CoreTextUnavailable;
        return .{};
    }

    pub fn deinit(self: *FontDiscovery) void {
        _ = self;
    }

    pub fn findFont(
        self: *FontDiscovery,
        family_name: []const u8,
        weight: FontWeight,
        style: FontStyle,
    ) !?*FallbackFont {
        _ = self;
        _ = style;
        const family_z = try std.heap.c_allocator.dupeZ(u8, family_name);
        defer std.heap.c_allocator.free(family_z);
        const handle = wispterm_coretext_find_font(family_z.ptr, @intCast(@intFromEnum(weight))) orelse return null;
        return try FallbackFont.wrap(handle);
    }

    pub fn findFallbackFont(self: *FontDiscovery, codepoint: u32) !?*FallbackFont {
        _ = self;
        const handle = wispterm_coretext_find_fallback(codepoint) orelse return null;
        return try FallbackFont.wrap(handle);
    }

    pub fn findPreferredFallbackFont(
        self: *FontDiscovery,
        codepoint: u32,
        families: []const []const u8,
    ) !?*FallbackFont {
        for (families) |family_name| {
            const font = (try self.findFont(family_name, .NORMAL, .NORMAL)) orelse continue;
            if (font.hasCharacter(codepoint)) return font;
            font.release();
        }
        return null;
    }

    pub fn listFontFamilies(self: *FontDiscovery, allocator: std.mem.Allocator) ![][]const u8 {
        _ = self;
        const count = wispterm_coretext_family_count();
        var families = try allocator.alloc([]const u8, count);
        var added: usize = 0;
        errdefer {
            for (families[0..added]) |family| allocator.free(family);
            allocator.free(families);
        }

        for (0..count) |i| {
            const raw = wispterm_coretext_copy_family_name(i) orelse continue;
            defer wispterm_coretext_free(raw);
            families[added] = try allocator.dupe(u8, std.mem.span(raw));
            added += 1;
        }

        if (added == count) return families;
        const trimmed = try allocator.alloc([]const u8, added);
        @memcpy(trimmed, families[0..added]);
        allocator.free(families);
        return trimmed;
    }

    pub fn findFontFilePath(
        self: *FontDiscovery,
        allocator: std.mem.Allocator,
        family_name: []const u8,
        weight: FontWeight,
        style: FontStyle,
    ) !?FontResult {
        const font = (try self.findFont(family_name, weight, style)) orelse return null;
        defer font.release();
        return fontFilePathAlloc(allocator, font);
    }
};

pub const LoadedFont = struct {
    handle: *anyopaque,

    pub fn init(font: *FallbackFont) !LoadedFont {
        wispterm_coretext_font_retain(font.handle);
        return .{ .handle = font.handle };
    }

    pub fn deinit(self: *LoadedFont) void {
        wispterm_coretext_font_release(self.handle);
    }

    pub fn getGlyphIndex(self: *LoadedFont, codepoint: u32) u16 {
        return wispterm_coretext_font_glyph_index(self.handle, codepoint);
    }

    pub fn hasGlyph(self: *LoadedFont, codepoint: u32) bool {
        return self.getGlyphIndex(codepoint) != 0;
    }
};

pub fn fontWeightFromValue(value: u16) FontWeight {
    return switch (value) {
        100 => .THIN,
        700 => .BOLD,
        900 => .BLACK,
        else => .NORMAL,
    };
}

pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    const raw_path = wispterm_coretext_font_copy_path(font.handle) orelse return null;
    defer wispterm_coretext_free(raw_path);

    const path = allocator.dupeZ(u8, std.mem.span(raw_path)) catch return null;
    return .{
        .path = path,
        .face_index = 0,
        .allocator = allocator,
    };
}

/// Copy the font's sfnt bytes (reconstructed from CoreText tables) into an
/// allocator-owned buffer. Used to load fonts whose file path FreeType cannot
/// open (e.g. macOS 26's reserved PingFang.ttc). Caller owns the returned slice.
pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    var len: usize = 0;
    const raw = wispterm_coretext_font_copy_table_data(font.handle, &len) orelse return null;
    defer wispterm_coretext_free(raw);
    if (len == 0) return null;

    const data = allocator.alloc(u8, len) catch return null;
    @memcpy(data, raw[0..len]);
    return data;
}
