//! Pure, IO-free file-edit logic shared by the agent's read_file / write_file /
//! edit_file tools: exact-match string replacement, line slicing for reads,
//! unified diffs for the approval card, and size/binary guards. Leaf module —
//! no imports beyond std. All functions allocate only what they return (or a
//! scratch arena) so the fast test suite can exercise them without IO.
const std = @import("std");

/// Largest file (bytes) read_file/edit_file will load. Larger files are refused
/// with guidance to narrow the range, keeping a single edit in context.
pub const MAX_FILE_BYTES: usize = 256 * 1024;

pub const EditOutcome = struct {
    /// Owned by the caller's allocator.
    new_content: []u8,
    /// How many matches existed (1 unless replace_all replaced several).
    occurrences: usize,
};

pub const EditError = error{ EmptyOld, NotFound, NotUnique };

/// Replace `old_string` with `new_string` in `content`. With `replace_all`
/// false the match must be unique. Returns owned new content. Exact byte match.
pub fn applyEdit(
    allocator: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) (EditError || error{OutOfMemory})!EditOutcome {
    if (old_string.len == 0) return error.EmptyOld;

    var count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, content, scan, old_string)) |pos| {
        count += 1;
        scan = pos + old_string.len;
    }
    if (count == 0) return error.NotFound;
    if (count > 1 and !replace_all) return error.NotUnique;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, old_string)) |pos| {
        try out.appendSlice(allocator, content[cursor..pos]);
        try out.appendSlice(allocator, new_string);
        cursor = pos + old_string.len;
        if (!replace_all) break;
    }
    try out.appendSlice(allocator, content[cursor..]);
    return .{ .new_content = try out.toOwnedSlice(allocator), .occurrences = count };
}

/// True if `content` looks binary (a NUL byte in the first 8 KiB).
pub fn looksBinary(content: []const u8) bool {
    const scan = content[0..@min(content.len, 8 * 1024)];
    return std.mem.indexOfScalar(u8, scan, 0) != null;
}

/// Render `content` as numbered lines `   <n>\t<line>\n` starting at 1-based
/// `offset` (0 means 1), emitting at most `limit` lines (0 means all). Owned.
pub fn sliceLinesAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    offset: usize,
    limit: usize,
) ![]u8 {
    const start = if (offset == 0) 1 else offset;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var line_no: usize = 1;
    var emitted: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < start) continue;
        if (limit != 0 and emitted >= limit) break;
        try out.print(allocator, "{d: >6}\t{s}\n", .{ line_no, line });
        emitted += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Split `text` into lines, dropping a single trailing empty element so a final
/// newline does not produce a phantom blank line. Caller frees the outer slice
/// (line slices alias `text`).
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(allocator);
}

/// Produce a minimal unified diff of `old` -> `new` for `path`. Trims common
/// leading/trailing lines and emits one hunk of removals then additions. Owned.
pub fn unifiedDiffAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    old: []const u8,
    new: []const u8,
) ![]u8 {
    const old_lines = try splitLines(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new);
    defer allocator.free(new_lines);

    var p: usize = 0;
    while (p < old_lines.len and p < new_lines.len and
        std.mem.eql(u8, old_lines[p], new_lines[p])) : (p += 1)
    {}
    var s: usize = 0;
    while (s < old_lines.len - p and s < new_lines.len - p and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - s], new_lines[new_lines.len - 1 - s])) : (s += 1)
    {}

    const old_count = old_lines.len - p - s;
    const new_count = new_lines.len - p - s;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "--- a/{s}\n+++ b/{s}\n", .{ path, path });
    try out.print(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{ p + 1, old_count, p + 1, new_count });
    for (old_lines[p .. old_lines.len - s]) |line| try out.print(allocator, "-{s}\n", .{line});
    for (new_lines[p .. new_lines.len - s]) |line| try out.print(allocator, "+{s}\n", .{line});
    return out.toOwnedSlice(allocator);
}

test "applyEdit replaces a unique match" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "alpha beta gamma", "beta", "BETA", false);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("alpha BETA gamma", r.new_content);
    try std.testing.expectEqual(@as(usize, 1), r.occurrences);
}

test "applyEdit errors when not found" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotFound, applyEdit(a, "abc", "zzz", "x", false));
}

test "applyEdit errors when not unique without replace_all" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotUnique, applyEdit(a, "x x x", "x", "y", false));
}

test "applyEdit replace_all replaces every occurrence" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "x x x", "x", "y", true);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("y y y", r.new_content);
    try std.testing.expectEqual(@as(usize, 3), r.occurrences);
}

test "applyEdit errors on empty old_string" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyOld, applyEdit(a, "abc", "", "x", false));
}

test "applyEdit preserves multiline content exactly" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "line1\nline2\nline3\n", "line2", "LINE2", false);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("line1\nLINE2\nline3\n", r.new_content);
}

test "looksBinary detects NUL" {
    try std.testing.expect(looksBinary("ab\x00cd"));
    try std.testing.expect(!looksBinary("plain text\nlines"));
}

test "sliceLinesAlloc numbers from offset with a limit" {
    const a = std.testing.allocator;
    const r = try sliceLinesAlloc(a, "a\nb\nc\nd\n", 2, 2);
    defer a.free(r);
    try std.testing.expectEqualStrings("     2\tb\n     3\tc\n", r);
}

test "sliceLinesAlloc with offset 0 starts at line 1" {
    const a = std.testing.allocator;
    const r = try sliceLinesAlloc(a, "x\ny\n", 0, 0);
    defer a.free(r);
    try std.testing.expectEqualStrings("     1\tx\n     2\ty\n     3\t\n", r);
}

test "unifiedDiffAlloc shows a single changed line" {
    const a = std.testing.allocator;
    const d = try unifiedDiffAlloc(a, "f.txt", "a\nb\nc\n", "a\nB\nc\n");
    defer a.free(d);
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -2,1 +2,1 @@\n-b\n+B\n",
        d,
    );
}

test "unifiedDiffAlloc for a new file shows only additions" {
    const a = std.testing.allocator;
    const d = try unifiedDiffAlloc(a, "n.txt", "", "x\ny\n");
    defer a.free(d);
    try std.testing.expectEqualStrings(
        "--- a/n.txt\n+++ b/n.txt\n@@ -1,0 +1,2 @@\n+x\n+y\n",
        d,
    );
}
