//! Gallery navigation helper for image/PDF preview panes.

const std = @import("std");
const file_backend = @import("file_backend.zig");
const markdown_preview = @import("markdown_preview.zig");

pub const MAX_GALLERY_ENTRIES: usize = 2048;
pub const MAX_TARGET_PATH_BYTES: usize = 512;

pub const Target = struct {
    kind: markdown_preview.Kind,
    title_buf: [file_backend.MAX_NAME_LEN]u8 = undefined,
    title_len: u8 = 0,
    path: []u8,

    pub fn title(self: *const Target) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn findNeighbor(
    allocator: std.mem.Allocator,
    backend: file_backend.Backend,
    current_path: []const u8,
    forward: bool,
) !?Target {
    const parent = parentPath(current_path) orelse return null;

    const entries = try allocator.alloc(file_backend.Entry, MAX_GALLERY_ENTRIES);
    defer allocator.free(entries);

    const result = file_backend.list(allocator, backend, parent, entries);
    if (result.status != .ok) return null;

    return neighborFromEntriesForTest(allocator, current_path, entries[0..result.count], forward);
}

pub fn neighborFromEntriesForTest(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    entries: []const file_backend.Entry,
    forward: bool,
) !?Target {
    const parent = parentPath(current_path) orelse return null;
    const current_name = basename(current_path);
    const separator = separatorForPath(current_path);

    var found_current = false;
    var previous_entry: ?*const file_backend.Entry = null;
    var previous_kind: markdown_preview.Kind = undefined;

    for (entries) |*entry| {
        const kind = rasterKind(entry) orelse continue;
        const name = entry.name();

        if (std.mem.eql(u8, name, current_name)) {
            if (forward) {
                found_current = true;
            } else if (previous_entry) |prev| {
                return makeTarget(allocator, parent, separator, prev.name(), previous_kind);
            } else {
                return null;
            }
            continue;
        }

        if (forward and found_current) {
            return makeTarget(allocator, parent, separator, name, kind);
        }

        previous_entry = entry;
        previous_kind = kind;
    }

    return null;
}

fn rasterKind(entry: *const file_backend.Entry) ?markdown_preview.Kind {
    if (entry.is_dir) return null;
    const kind = markdown_preview.detectKind(entry.name()) orelse return null;
    if (!kind.isRaster()) return null;
    return kind;
}

fn parentPath(path: []const u8) ?[]const u8 {
    const index = lastSeparatorIndex(path) orelse return null;
    if (index == 0) return path[0..1];
    return path[0..index];
}

fn basename(path: []const u8) []const u8 {
    const index = lastSeparatorIndex(path) orelse return path;
    return path[index + 1 ..];
}

fn lastSeparatorIndex(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (isSeparator(path[index])) return index;
    }
    return null;
}

fn separatorForPath(path: []const u8) u8 {
    return if (std.mem.indexOfScalar(u8, path, '\\') != null) '\\' else '/';
}

fn makeTarget(
    allocator: std.mem.Allocator,
    parent: []const u8,
    separator: u8,
    name: []const u8,
    kind: markdown_preview.Kind,
) !?Target {
    const path = try makeTargetPath(allocator, parent, separator, name) orelse return null;

    var target: Target = .{
        .kind = kind,
        .path = path,
    };
    @memcpy(target.title_buf[0..name.len], name);
    target.title_len = @intCast(name.len);
    return target;
}

fn makeTargetPath(
    allocator: std.mem.Allocator,
    parent: []const u8,
    separator: u8,
    name: []const u8,
) !?[]u8 {
    const needs_separator = parent.len > 0 and !isSeparator(parent[parent.len - 1]);
    const separator_len: usize = if (needs_separator) 1 else 0;
    const path_len = parent.len + separator_len + name.len;
    if (path_len > MAX_TARGET_PATH_BYTES) return null;

    const path = try allocator.alloc(u8, path_len);
    var offset: usize = 0;
    @memcpy(path[offset .. offset + parent.len], parent);
    offset += parent.len;
    if (needs_separator) {
        path[offset] = separator;
        offset += 1;
    }
    @memcpy(path[offset .. offset + name.len], name);
    return path;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn testEntry(name: []const u8, is_dir: bool) file_backend.Entry {
    var entry: file_backend.Entry = .{ .is_dir = is_dir };
    const len: u8 = @intCast(@min(name.len, entry.name_buf.len));
    @memcpy(entry.name_buf[0..len], name[0..len]);
    entry.name_len = len;
    return entry;
}

test "preview_gallery: finds previous and next raster siblings" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("a.png", false),
        testEntry("b.txt", false),
        testEntry("c.pdf", false),
        testEntry("d.jpg", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/c.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqual(markdown_preview.Kind.image, next.kind);
    try std.testing.expectEqualStrings("d.jpg", next.title());
    try std.testing.expectEqualStrings("/tmp/d.jpg", next.path);

    var prev = (try neighborFromEntriesForTest(allocator, "/tmp/c.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqual(markdown_preview.Kind.image, prev.kind);
    try std.testing.expectEqualStrings("a.png", prev.title());
    try std.testing.expectEqualStrings("/tmp/a.png", prev.path);
}

test "preview_gallery: filters directories and non-raster previews" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("alpha.png", true),
        testEntry("notes.md", false),
        testEntry("paper.pdf", false),
        testEntry("photo.webp", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/paper.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqualStrings("photo.webp", next.title());
    try std.testing.expectEqual(markdown_preview.Kind.image, next.kind);

    try std.testing.expect((try neighborFromEntriesForTest(allocator, "/tmp/photo.webp", entries[0..], true)) == null);
    try std.testing.expect((try neighborFromEntriesForTest(allocator, "/tmp/paper.pdf", entries[0..], false)) == null);
}

test "preview_gallery: treats a multi-page pdf as one gallery entry" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("01.png", false),
        testEntry("book.pdf", false),
        testEntry("02.png", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/book.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqualStrings("02.png", next.title());

    var prev = (try neighborFromEntriesForTest(allocator, "/tmp/book.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqualStrings("01.png", prev.title());
}

test "preview_gallery: supports windows-style backslash paths" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("a.bmp", false),
        testEntry("b.pdf", false),
    };

    var prev = (try neighborFromEntriesForTest(allocator, "C:\\Users\\me\\Pictures\\b.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqualStrings("a.bmp", prev.title());
    try std.testing.expectEqualStrings("C:\\Users\\me\\Pictures\\a.bmp", prev.path);
}
