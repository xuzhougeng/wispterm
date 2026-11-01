//! Font-level fallback cache.
//!
//! Fallback fonts are held once per *font*, not once per codepoint. This
//! mirrors Ghostty's `font/Collection.zig` (a list of faces, each fallback
//! added once via `addDeferred`) and `font/CodepointResolver.zig` (`getIndex`
//! first asks the already-loaded collection whether any face covers the
//! codepoint, and only then goes to discovery; codepoints are cached as
//! indices into that list).
//!
//! The previous WispTerm cache mapped `codepoint -> freetype.Face`, opening a
//! fresh face for every new codepoint. On macOS 26, where PingFang can only be
//! loaded from a ~768KB CoreText-reconstructed sfnt copy, rendering 800
//! distinct CJK characters kept 800 copies of PingFang alive (~1.2GB).
//!
//! This module is platform independent: it is generic over the loaded font
//! type, which must provide
//!   `fn hasCodepoint(self: *const Font, codepoint: u32) bool`
//!   `fn deinit(self: *Font, allocator: std.mem.Allocator) void`
//! so it can be unit-tested with a fake font in the fast suite.

const std = @import("std");

pub const Index = u32;

pub fn FallbackCache(comptime Font: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            font: Font,
            /// Stable font identity used to dedupe discovery results
            /// ("ps:<PostScript name>" or "file:<path>#<face index>").
            /// Owned by the cache; null when the backend can't identify it.
            identity: ?[]u8,
            /// Loaded from the user's configured cjk/fallback families. Such
            /// fonts outrank other loaded fallbacks, so a configured font is
            /// not shadowed by whichever fallback happened to load first.
            configured: bool,
        };

        entries: std.ArrayListUnmanaged(Entry) = .empty,
        /// codepoint -> index into `entries`.
        codepoints: std.AutoHashMapUnmanaged(u32, Index) = .empty,
        /// Negative cache: codepoints with no usable fallback.
        missing: std.AutoHashMapUnmanaged(u32, void) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.entries.items) |*entry| {
                entry.font.deinit(allocator);
                if (entry.identity) |id| allocator.free(id);
            }
            self.entries.deinit(allocator);
            self.codepoints.deinit(allocator);
            self.missing.deinit(allocator);
            self.* = .{};
        }

        /// Cached resolution for `codepoint`, if any.
        pub fn lookup(self: *const Self, codepoint: u32) ?Index {
            return self.codepoints.get(codepoint);
        }

        pub fn isMissing(self: *const Self, codepoint: u32) bool {
            return self.missing.contains(codepoint);
        }

        pub fn markMissing(self: *Self, allocator: std.mem.Allocator, codepoint: u32) void {
            self.missing.put(allocator, codepoint, {}) catch {};
        }

        /// First already-loaded font (in load order) that covers `codepoint`.
        /// With `configured_only`, only fonts from the user's configured
        /// families are considered.
        pub fn findLoaded(self: *const Self, codepoint: u32, configured_only: bool) ?Index {
            for (self.entries.items, 0..) |*entry, i| {
                if (configured_only and !entry.configured) continue;
                if (entry.font.hasCodepoint(codepoint)) return @intCast(i);
            }
            return null;
        }

        pub fn findByIdentity(self: *const Self, identity: []const u8) ?Index {
            for (self.entries.items, 0..) |entry, i| {
                const id = entry.identity orelse continue;
                if (std.mem.eql(u8, id, identity)) return @intCast(i);
            }
            return null;
        }

        /// Append a newly loaded font. On success the cache owns `font` and
        /// a copy of `identity`; on error the caller still owns `font`.
        pub fn add(
            self: *Self,
            allocator: std.mem.Allocator,
            font: Font,
            identity: ?[]const u8,
            configured: bool,
        ) !Index {
            const owned_id: ?[]u8 = if (identity) |id| try allocator.dupe(u8, id) else null;
            errdefer if (owned_id) |id| allocator.free(id);
            const index: Index = @intCast(self.entries.items.len);
            try self.entries.append(allocator, .{
                .font = font,
                .identity = owned_id,
                .configured = configured,
            });
            return index;
        }

        /// Record that `codepoint` resolves to the font at `index`.
        pub fn assign(self: *Self, allocator: std.mem.Allocator, codepoint: u32, index: Index) !void {
            std.debug.assert(index < self.entries.items.len);
            try self.codepoints.put(allocator, codepoint, index);
        }

        pub fn at(self: *Self, index: Index) *Entry {
            return &self.entries.items[index];
        }

        pub fn fontCount(self: *const Self) usize {
            return self.entries.items.len;
        }

        pub fn codepointCount(self: *const Self) usize {
            return self.codepoints.count();
        }

        pub fn missingCount(self: *const Self) usize {
            return self.missing.count();
        }
    };
}

/// Per-face size adjustment ratio, matching Ghostty's default fallback
/// `SizeAdjustment.ic_width` (Collection.zig `scaleFactor`): normalize by the
/// ideograph advance when the fallback face actually has one, otherwise fall
/// through to ex height. The choice depends only on the face, never on the
/// codepoint that first triggered the load, so one shared face gets one size.
pub fn sizeAdjustRatio(
    primary_ic_width: f64,
    primary_ex_height: f64,
    fallback_ic_width: f64,
    fallback_ex_height: f64,
    fallback_has_ideograph: bool,
) f64 {
    const raw = if (fallback_has_ideograph)
        primary_ic_width / @max(0.01, fallback_ic_width)
    else
        primary_ex_height / @max(0.01, fallback_ex_height);
    return std.math.clamp(raw, 0.75, 1.35);
}

/// Identity string for a font: the PostScript name when the backend knows
/// it (distinguishes faces inside one .ttc), else file path + face index.
/// Caller owns the result.
pub fn formatIdentity(
    allocator: std.mem.Allocator,
    postscript_name: ?[]const u8,
    path: ?[]const u8,
    face_index: u32,
) ?[]u8 {
    if (postscript_name) |name| {
        if (name.len > 0) return std.fmt.allocPrint(allocator, "ps:{s}", .{name}) catch null;
    }
    if (path) |p| {
        if (p.len > 0) return std.fmt.allocPrint(allocator, "file:{s}#{d}", .{ p, face_index }) catch null;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Fake font covering a codepoint range; counts deinit calls so tests can
/// assert every loaded font is released exactly once.
const FakeFont = struct {
    first: u32,
    last: u32,
    deinits: *usize,

    pub fn hasCodepoint(self: *const FakeFont, codepoint: u32) bool {
        return codepoint >= self.first and codepoint <= self.last;
    }

    pub fn deinit(self: *FakeFont, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.deinits.* += 1;
    }
};

const TestCache = FallbackCache(FakeFont);

/// Simulates manager.zig's resolve order against the fake cache. Returns the
/// font index and how many fonts had to be "loaded" (opened) for this call.
fn resolveForTest(
    cache: *TestCache,
    codepoint: u32,
    candidate: ?struct { id: []const u8, font: FakeFont },
    loads: *usize,
) !?Index {
    if (cache.lookup(codepoint)) |idx| return idx;
    if (cache.isMissing(codepoint)) return null;
    if (cache.findLoaded(codepoint, false)) |idx| {
        try cache.assign(testing.allocator, codepoint, idx);
        return idx;
    }
    const c = candidate orelse {
        cache.markMissing(testing.allocator, codepoint);
        return null;
    };
    if (cache.findByIdentity(c.id)) |idx| {
        try cache.assign(testing.allocator, codepoint, idx);
        return idx;
    }
    loads.* += 1;
    const idx = try cache.add(testing.allocator, c.font, c.id, false);
    try cache.assign(testing.allocator, codepoint, idx);
    return idx;
}

test "fallback cache loads one font for many codepoints it covers" {
    var deinits: usize = 0;
    var loads: usize = 0;
    var cache: TestCache = .{};
    defer cache.deinit(testing.allocator);

    const pingfang: FakeFont = .{ .first = 0x4E00, .last = 0x9FFF, .deinits = &deinits };
    var cp: u32 = 0x4E00;
    while (cp < 0x4E00 + 800) : (cp += 1) {
        const idx = try resolveForTest(&cache, cp, .{ .id = "ps:PingFangSC-Regular", .font = pingfang }, &loads);
        try testing.expectEqual(@as(?Index, 0), idx);
    }
    try testing.expectEqual(@as(usize, 1), loads);
    try testing.expectEqual(@as(usize, 1), cache.fontCount());
    try testing.expectEqual(@as(usize, 800), cache.codepointCount());
}

test "fallback cache dedupes discovery results by identity" {
    var deinits: usize = 0;
    var loads: usize = 0;
    var cache: TestCache = .{};
    defer cache.deinit(testing.allocator);

    // Loaded font's FreeType face covers less than discovery claims (e.g. the
    // codepoint is outside its cmap): the identity match must still prevent a
    // second copy of the same font from being opened.
    const narrow: FakeFont = .{ .first = 'a', .last = 'z', .deinits = &deinits };
    _ = try resolveForTest(&cache, 'a', .{ .id = "file:/f.ttc#0", .font = narrow }, &loads);
    _ = try resolveForTest(&cache, 0x2603, .{ .id = "file:/f.ttc#0", .font = narrow }, &loads);
    try testing.expectEqual(@as(usize, 1), loads);
    try testing.expectEqual(@as(usize, 1), cache.fontCount());

    // A different face index of the same file is a different font.
    const other: FakeFont = .{ .first = 0x2600, .last = 0x26FF, .deinits = &deinits };
    _ = try resolveForTest(&cache, 0x2604, .{ .id = "file:/f.ttc#1", .font = other }, &loads);
    try testing.expectEqual(@as(usize, 2), cache.fontCount());
}

test "fallback cache keeps the negative cache" {
    var loads: usize = 0;
    var cache: TestCache = .{};
    defer cache.deinit(testing.allocator);

    try testing.expectEqual(@as(?Index, null), try resolveForTest(&cache, 0xE000, null, &loads));
    try testing.expect(cache.isMissing(0xE000));
    try testing.expectEqual(@as(usize, 1), cache.missingCount());
    try testing.expectEqual(@as(usize, 0), cache.fontCount());
}

test "fallback cache prefers configured fonts when asked" {
    var deinits: usize = 0;
    var cache: TestCache = .{};
    defer cache.deinit(testing.allocator);

    const system = try cache.add(testing.allocator, .{ .first = 0x3000, .last = 0x9FFF, .deinits = &deinits }, "ps:PingFangSC-Regular", false);
    const configured = try cache.add(testing.allocator, .{ .first = 0x4E00, .last = 0x9FFF, .deinits = &deinits }, "ps:SarasaMonoSC-Regular", true);

    try testing.expectEqual(@as(?Index, system), cache.findLoaded(0x4E2D, false));
    try testing.expectEqual(@as(?Index, configured), cache.findLoaded(0x4E2D, true));
    try testing.expectEqual(@as(?Index, null), cache.findLoaded(0x3001, true));
}

test "fallback cache deinit releases each font exactly once" {
    var deinits: usize = 0;
    var cache: TestCache = .{};
    _ = try cache.add(testing.allocator, .{ .first = 1, .last = 1, .deinits = &deinits }, "ps:A", false);
    _ = try cache.add(testing.allocator, .{ .first = 2, .last = 2, .deinits = &deinits }, null, false);
    try cache.assign(testing.allocator, 1, 0);
    try cache.assign(testing.allocator, 2, 1);
    cache.markMissing(testing.allocator, 3);
    cache.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), deinits);
    try testing.expectEqual(@as(usize, 0), cache.fontCount());
    try testing.expectEqual(@as(usize, 0), cache.codepointCount());
    try testing.expectEqual(@as(usize, 0), cache.missingCount());
}

test "size adjust ratio is per face, ic_width with ex_height fallthrough" {
    // Face with an ideograph: match ideograph advance.
    try testing.expectApproxEqAbs(@as(f64, 1.2), sizeAdjustRatio(18, 7, 15, 5, true), 1e-9);
    // Face without one: match ex height instead.
    try testing.expectApproxEqAbs(@as(f64, 1.0), sizeAdjustRatio(18, 7, 15, 7, false), 1e-9);
    // Clamped to [0.75, 1.35].
    try testing.expectEqual(@as(f64, 1.35), sizeAdjustRatio(40, 7, 10, 7, true));
    try testing.expectEqual(@as(f64, 0.75), sizeAdjustRatio(1, 7, 10, 7, true));
}

test "font identity prefers PostScript name, then path and face index" {
    const ps = formatIdentity(testing.allocator, "PingFangSC-Regular", "/x/PingFang.ttc", 0).?;
    defer testing.allocator.free(ps);
    try testing.expectEqualStrings("ps:PingFangSC-Regular", ps);

    const file = formatIdentity(testing.allocator, null, "/x/NotoSansCJK.ttc", 2).?;
    defer testing.allocator.free(file);
    try testing.expectEqualStrings("file:/x/NotoSansCJK.ttc#2", file);

    try testing.expect(formatIdentity(testing.allocator, "", null, 0) == null);
}
