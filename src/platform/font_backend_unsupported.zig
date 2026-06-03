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

pub const FontFace = struct {
    pub fn release(self: *FontFace) void {
        _ = self;
    }

    pub fn getIndex(self: *FontFace) u32 {
        _ = self;
        return 0;
    }

    pub fn getFiles(self: *FontFace) !*FontFile {
        _ = self;
        return error.UnsupportedFontBackend;
    }
};

pub const ReferenceKey = struct {
    key: *const anyopaque,
    size: u32,
};

pub const FontFile = struct {
    pub fn release(self: *FontFile) void {
        _ = self;
    }

    pub fn getLoader(self: *FontFile) !*FontFileLoader {
        _ = self;
        return error.UnsupportedFontBackend;
    }

    pub fn getReferenceKey(self: *FontFile) !ReferenceKey {
        _ = self;
        return error.UnsupportedFontBackend;
    }
};

pub const FontFileLoader = struct {
    pub fn release(self: *FontFileLoader) void {
        _ = self;
    }

    pub fn queryLocalFontFileLoader(self: *FontFileLoader) ?*LocalFontFileLoader {
        _ = self;
        return null;
    }
};

pub const LocalFontFileLoader = struct {
    pub fn release(self: *LocalFontFileLoader) void {
        _ = self;
    }

    pub fn getFilePathLengthFromKey(self: *LocalFontFileLoader, key: *const anyopaque, size: u32) !u32 {
        _ = self;
        _ = key;
        _ = size;
        return error.UnsupportedFontBackend;
    }

    pub fn getFilePathFromKey(self: *LocalFontFileLoader, key: *const anyopaque, size: u32, path: []u16) !void {
        _ = self;
        _ = key;
        _ = size;
        _ = path;
        return error.UnsupportedFontBackend;
    }
};

pub const FallbackFont = struct {
    pub fn release(self: *FallbackFont) void {
        _ = self;
    }

    pub fn hasCharacter(self: *FallbackFont, codepoint: u32) bool {
        _ = self;
        _ = codepoint;
        return false;
    }

    pub fn createFontFace(self: *FallbackFont) !*FontFace {
        _ = self;
        return error.UnsupportedFontBackend;
    }
};

pub const FontDiscovery = struct {
    pub const FontResult = struct {
        path: [:0]const u8,
        face_index: u32,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *FontResult) void {
            self.allocator.free(self.path);
        }
    };

    pub fn init() !FontDiscovery {
        return error.UnsupportedFontBackend;
    }

    pub fn deinit(self: *FontDiscovery) void {
        _ = self;
    }

    pub fn findFont(self: *FontDiscovery, family_name: []const u8, weight: FontWeight, style: FontStyle) !?*FallbackFont {
        _ = self;
        _ = family_name;
        _ = weight;
        _ = style;
        return null;
    }

    pub fn findFallbackFont(self: *FontDiscovery, codepoint: u32) !?*FallbackFont {
        _ = self;
        _ = codepoint;
        return null;
    }

    pub fn findPreferredFallbackFont(self: *FontDiscovery, codepoint: u32, families: []const []const u8) !?*FallbackFont {
        _ = self;
        _ = codepoint;
        _ = families;
        return null;
    }

    pub fn listFontFamilies(self: *FontDiscovery, allocator: std.mem.Allocator) ![][]const u8 {
        _ = self;
        return allocator.alloc([]const u8, 0);
    }

    pub fn findFontFilePath(
        self: *FontDiscovery,
        allocator: std.mem.Allocator,
        family_name: []const u8,
        weight: FontWeight,
        style: FontStyle,
    ) !?FontResult {
        _ = self;
        _ = allocator;
        _ = family_name;
        _ = weight;
        _ = style;
        return null;
    }
};

pub const LoadedFont = struct {
    pub fn init(font: *FallbackFont) !LoadedFont {
        _ = font;
        return error.UnsupportedFontBackend;
    }

    pub fn deinit(self: *LoadedFont) void {
        _ = self;
    }

    pub fn getGlyphIndex(self: *LoadedFont, codepoint: u32) u16 {
        _ = self;
        _ = codepoint;
        return 0;
    }

    pub fn hasGlyph(self: *LoadedFont, codepoint: u32) bool {
        _ = self;
        _ = codepoint;
        return false;
    }
};

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
    return switch (value) {
        100 => .THIN,
        700 => .BOLD,
        900 => .BLACK,
        else => .NORMAL,
    };
}

pub fn fontFilePathAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?FontFilePath {
    _ = allocator;
    _ = font;
    return null;
}

pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    _ = allocator;
    _ = font;
    return null;
}
