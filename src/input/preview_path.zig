//! Pure preview-path detection predicate. Extracted from preview_source.zig
//! (which is Surface-coupled and therefore test-full only) so the predicate can
//! be reused by dependency-light modules and unit-tested in the fast suite.
//! Depends only on std and the std-only markdown_preview module.
const std = @import("std");
const markdown_preview = @import("../markdown_preview.zig");

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isPreviewImagePath(path: []const u8) bool {
    return markdown_preview.isImagePath(path);
}

pub fn looksLikePreviewPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return false;
    if (markdown_preview.detectKind(path) != null) return true;
    if (path[0] == '~') return true;
    if (path.len >= 2 and path[1] == ':') return true;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    return endsWithIgnoreCase(path, ".pdf") or isPreviewImagePath(path);
}

test "looksLikePreviewPath: markdown and image and pdf paths" {
    try std.testing.expect(looksLikePreviewPath("README.md"));
    try std.testing.expect(looksLikePreviewPath("notes.pdf"));
    try std.testing.expect(looksLikePreviewPath("~/file"));
    try std.testing.expect(looksLikePreviewPath("dir/file"));
    try std.testing.expect(looksLikePreviewPath("model.R"));
    try std.testing.expect(looksLikePreviewPath("plot.r"));
}

test "looksLikePreviewPath: rejects urls and empty" {
    try std.testing.expect(!looksLikePreviewPath(""));
    try std.testing.expect(!looksLikePreviewPath("https://example.com"));
    try std.testing.expect(!looksLikePreviewPath("http://example.com/x"));
}
