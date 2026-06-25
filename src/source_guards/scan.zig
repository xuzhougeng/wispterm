//! Shared source-scanning primitives for the cross-cutting `source_guards/`
//! ratchet tests. Pure `std`-only helpers so they live in the fast suite and
//! can be unit-tested against synthetic inputs.

const std = @import("std");

/// Count non-overlapping occurrences of `needle` in `haystack`. An empty needle
/// counts as zero so callers never divide by it.
pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| {
        count += 1;
        i = pos + needle.len;
    }
    return count;
}

/// Return true when `haystack` contains at least one forbidden marker.
pub fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

/// Count source lines that begin (with no leading indentation) with any of
/// `prefixes`. Indented lines never match, so this only sees top-level decls.
pub fn countTopLevelDecls(source: []const u8, prefixes: []const []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

/// Count top-level lines that begin with `start_prefix` (no leading
/// indentation) and also contain `substr` somewhere on the line.
pub fn countTopLevelLinesContaining(source: []const u8, start_prefix: []const u8, substr: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, start_prefix) and std.mem.indexOf(u8, line, substr) != null) {
            count += 1;
        }
    }
    return count;
}

test "countOccurrences counts non-overlapping needles" {
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("g_x = true; g_x = false;", "g_x = "));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("aaaa", "aa"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", "x"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences("abc", ""));
}

test "containsAny reports whether any needle is present" {
    const needles = [_][]const u8{ "ConPTY", "ReadFile", "CancelIoEx" };
    try std.testing.expect(containsAny("shared code mentions ReadFile", &needles));
    try std.testing.expect(!containsAny("shared code is platform-neutral", &needles));
}

test "countTopLevelDecls matches only unindented prefix lines" {
    const src =
        \\var g_foo = 1;
        \\    var g_bar = 2;
        \\pub var g_baz = 3;
        \\threadlocal var g_qux = 4;
        \\fn notAGlobal() void {}
    ;
    const prefixes = [_][]const u8{ "var g_", "pub var g_", "threadlocal var g_", "pub threadlocal var g_" };
    try std.testing.expectEqual(@as(usize, 3), countTopLevelDecls(src, &prefixes));
}

test "countTopLevelLinesContaining requires unindented start prefix and substring" {
    const src =
        \\pub const A = @import("a.zig");
        \\const B = @import("b.zig");
        \\pub const C = foo.Bar;
        \\    pub const D = @import("d.zig");
    ;
    try std.testing.expectEqual(@as(usize, 1), countTopLevelLinesContaining(src, "pub const ", "= @import("));
}
