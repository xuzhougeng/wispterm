const std = @import("std");
const fc = @import("fontconfig").c;
const fcw = @import("font_weight_fc.zig");

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

pub const FallbackFont = struct {
    handle: *fc.FcPattern,

    fn wrap(handle: *fc.FcPattern) !*FallbackFont {
        const font = try std.heap.c_allocator.create(FallbackFont);
        font.* = .{ .handle = handle };
        return font;
    }

    pub fn release(self: *FallbackFont) void {
        fc.FcPatternDestroy(self.handle);
        std.heap.c_allocator.destroy(self);
    }

    pub fn hasCharacter(self: *FallbackFont, codepoint: u32) bool {
        var cs: ?*fc.FcCharSet = null;
        if (fc.FcPatternGetCharSet(self.handle, fc.FC_CHARSET, 0, &cs) != fc.FcResultMatch) return false;
        const charset = cs orelse return false;
        return fc.FcCharSetHasChar(charset, codepoint) != 0;
    }
};

pub const FontDiscovery = struct {
    pub const FontResult = FontFilePath;

    pub fn init() !FontDiscovery {
        if (fc.FcInit() == 0) return error.FontconfigInitFailed;
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
        const pat = fc.FcPatternCreate() orelse return null;
        const family_z = try std.heap.c_allocator.dupeZ(u8, family_name);
        defer std.heap.c_allocator.free(family_z);
        _ = fc.FcPatternAddString(pat, fc.FC_FAMILY, @ptrCast(family_z.ptr));
        // Secondary family: if the configured family is not installed, fontconfig
        // falls back to a generic monospace font (terminals need uniform cells)
        // instead of the proportional default. An installed configured family
        // still wins — an exact match outranks this weaker secondary preference.
        // (FC_SPACING=mono was tried first but is a no-op on some fontconfig
        // configs; a secondary family is the reliable lever.)
        const mono_fallback: [:0]const u8 = "monospace";
        _ = fc.FcPatternAddString(pat, fc.FC_FAMILY, @ptrCast(mono_fallback.ptr));
        _ = fc.FcPatternAddInteger(pat, fc.FC_WEIGHT, fcw.fcWeight(@intCast(@intFromEnum(weight))));
        _ = fc.FcConfigSubstitute(null, pat, fc.FcMatchPattern);
        fc.FcDefaultSubstitute(pat);
        var res: fc.FcResult = undefined;
        const match = fc.FcFontMatch(null, pat, &res);
        fc.FcPatternDestroy(pat);
        if (match == null) return null;
        return try FallbackFont.wrap(match.?);
    }

    pub fn findFallbackFont(self: *FontDiscovery, codepoint: u32) !?*FallbackFont {
        _ = self;
        const cs = fc.FcCharSetCreate() orelse return null;
        defer fc.FcCharSetDestroy(cs);
        _ = fc.FcCharSetAddChar(cs, codepoint);
        const pat = fc.FcPatternCreate() orelse return null;
        _ = fc.FcPatternAddCharSet(pat, fc.FC_CHARSET, cs);
        _ = fc.FcConfigSubstitute(null, pat, fc.FcMatchPattern);
        fc.FcDefaultSubstitute(pat);
        var res: fc.FcResult = undefined;
        const match = fc.FcFontMatch(null, pat, &res);
        fc.FcPatternDestroy(pat);
        if (match == null) return null;
        return try FallbackFont.wrap(match.?);
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
        const pattern = fc.FcPatternCreate() orelse return error.FontconfigPatternCreateFailed;
        defer fc.FcPatternDestroy(pattern);
        const objects = fc.FcObjectSetCreate() orelse return error.FontconfigObjectSetFailed;
        defer fc.FcObjectSetDestroy(objects);
        if (fc.FcObjectSetAdd(objects, fc.FC_FAMILY) == 0) return error.FontconfigObjectSetFailed;

        const font_set = fc.FcFontList(null, pattern, objects) orelse return error.FontconfigFontListFailed;
        defer fc.FcFontSetDestroy(font_set);

        var families: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (families.items) |family| allocator.free(family);
            families.deinit(allocator);
        }
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        const fonts = font_set.*.fonts;
        const font_count: usize = @intCast(font_set.*.nfont);
        for (0..font_count) |font_index| {
            const font_pattern = fonts[font_index];
            if (font_pattern == null) continue;
            var value_index: c_int = 0;
            while (true) : (value_index += 1) {
                var family_ptr: ?[*:0]fc.FcChar8 = null;
                if (fc.FcPatternGetString(font_pattern, fc.FC_FAMILY, value_index, @ptrCast(&family_ptr)) != fc.FcResultMatch) break;
                const family = std.mem.span(@as([*:0]const u8, @ptrCast(family_ptr orelse continue)));
                if (family.len == 0 or seen.contains(family)) continue;

                const owned = try allocator.dupe(u8, family);
                errdefer allocator.free(owned);
                try seen.put(owned, {});
                try families.append(allocator, owned);
            }
        }

        std.sort.heap([]const u8, families.items, {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        return families.toOwnedSlice(allocator);
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
    handle: *fc.FcPattern,

    pub fn init(font: *FallbackFont) !LoadedFont {
        const dup = fc.FcPatternDuplicate(font.handle) orelse return error.FontconfigDuplicateFailed;
        return .{ .handle = dup };
    }

    pub fn deinit(self: *LoadedFont) void {
        fc.FcPatternDestroy(self.handle);
    }

    pub fn hasGlyph(self: *LoadedFont, codepoint: u32) bool {
        var cs: ?*fc.FcCharSet = null;
        if (fc.FcPatternGetCharSet(self.handle, fc.FC_CHARSET, 0, &cs) != fc.FcResultMatch) return false;
        const charset = cs orelse return false;
        return fc.FcCharSetHasChar(charset, codepoint) != 0;
    }

    pub fn getGlyphIndex(self: *LoadedFont, codepoint: u32) u16 {
        return if (self.hasGlyph(codepoint)) 1 else 0;
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
    var file: ?[*:0]fc.FcChar8 = null;
    if (fc.FcPatternGetString(font.handle, fc.FC_FILE, 0, @ptrCast(&file)) != fc.FcResultMatch) return null;
    const file_ptr = file orelse return null;
    var idx: c_int = 0;
    _ = fc.FcPatternGetInteger(font.handle, fc.FC_INDEX, 0, &idx);
    const path = allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch return null;
    return .{
        .path = path,
        .face_index = @intCast(@max(@as(c_int, 0), idx)),
        .allocator = allocator,
    };
}

pub fn fontDataAlloc(allocator: std.mem.Allocator, font: *FallbackFont) ?[]u8 {
    _ = allocator;
    _ = font;
    return null;
}
