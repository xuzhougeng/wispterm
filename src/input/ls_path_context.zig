//! Smart path context for ctrl+click: infer a directory prefix from a nearby
//! `ls <dir>/` command line so bare-filename clicks resolve to the right file.
//! Pure logic only — no terminal/Surface dependency — so it is unit-testable.

const std = @import("std");

/// Command names whose single trailing-`/` argument we treat as a path prefix.
const ls_commands = [_][]const u8{ "ls", "ll", "la", "l", "dir" };

fn isLsCommand(tok: []const u8) bool {
    for (ls_commands) |cmd| {
        if (std.mem.eql(u8, tok, cmd)) return true;
    }
    return false;
}

/// If `line` is an `ls`-family command with exactly one directory argument
/// (a non-flag token ending in `/`), return that directory (a slice into
/// `line`). Returns null for zero args, multiple non-flag args, a sole
/// argument not ending in `/`, or a non-ls command. The command token may be
/// preceded by an arbitrary prompt prefix.
pub fn parseLsDirArg(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");

    var found_cmd = false;
    while (it.next()) |tok| {
        if (isLsCommand(tok)) {
            found_cmd = true;
            break;
        }
    }
    if (!found_cmd) return null;

    var dir: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue; // flag
        if (dir != null) return null; // >1 non-flag arg → ambiguous
        dir = tok;
    }

    const d = dir orelse return null; // ls of CWD, no dir arg
    if (d.len == 0 or d[d.len - 1] != '/') return null; // must be a directory
    return d;
}

test "parseLsDirArg: ls with a trailing-slash dir" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("ls Ath/Ph_SE/").?);
}

test "parseLsDirArg: tolerates a prompt prefix" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("$ ls Ath/Ph_SE/").?);
    try std.testing.expectEqualStrings("data/", parseLsDirArg("me@box:~/proj$ ls data/").?);
}

test "parseLsDirArg: skips flags" {
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls -la Ath/").?);
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls --color=auto Ath/").?);
}

test "parseLsDirArg: accepts ls-family aliases" {
    try std.testing.expectEqualStrings("d/", parseLsDirArg("ll d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("la d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("l d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("dir d/").?);
}

test "parseLsDirArg: rejects non-ls and lookalike commands" {
    try std.testing.expect(parseLsDirArg("lsblk d/") == null);
    try std.testing.expect(parseLsDirArg("cat foo.txt") == null);
    try std.testing.expect(parseLsDirArg("~/tools/ls d/") == null);
}

test "parseLsDirArg: rejects zero, multiple, and non-dir args" {
    try std.testing.expect(parseLsDirArg("ls") == null);
    try std.testing.expect(parseLsDirArg("ls -la") == null);
    try std.testing.expect(parseLsDirArg("ls A/ B/") == null);
    try std.testing.expect(parseLsDirArg("ls foo.txt") == null);
    try std.testing.expect(parseLsDirArg("ls Ath") == null);
}

/// Encode one grid row into UTF-8 bytes in `buf`. Empty cells (codepoint 0)
/// become spaces so tokenization sees word boundaries. Truncates at `buf` len.
fn encodeRow(grid: anytype, row: usize, buf: []u8) []const u8 {
    const cols = grid.colCount(row);
    var n: usize = 0;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        var cp = grid.codepoint(row, col);
        if (cp == 0) cp = ' ';
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch blk: {
            // Un-encodable codepoint (shouldn't occur from a real grid):
            // substitute a space so column structure / token boundaries hold.
            tmp[0] = ' ';
            break :blk @as(usize, 1);
        };
        if (n + len > buf.len) break;
        @memcpy(buf[n .. n + len], tmp[0..len]);
        n += len;
    }
    return buf[0..n];
}

/// Scan upward from `click_row` (bounded to the grid) for the nearest line that
/// parses as an `ls <dir>/` command. On a hit, copy the directory into
/// `out_buf` and return it; otherwise null. `grid` must expose
/// `rowCount() usize`, `colCount(row) usize`, and `codepoint(row, col) u21`.
pub fn inferPrefixForClick(grid: anytype, click_row: usize, out_buf: []u8) ?[]const u8 {
    const count = grid.rowCount();
    if (count == 0) return null;
    var row = if (click_row >= count) count - 1 else click_row;
    var line_buf: [1024]u8 = undefined;
    while (true) {
        const line = encodeRow(grid, row, &line_buf);
        if (parseLsDirArg(line)) |dir| {
            if (dir.len == 0 or dir.len > out_buf.len) return null;
            @memcpy(out_buf[0..dir.len], dir);
            return out_buf[0..dir.len];
        }
        if (row == 0) break;
        row -= 1;
    }
    return null;
}

/// Test-only grid backed by ASCII rows (index 0 = top row).
const FakeGrid = struct {
    rows: []const []const u8,

    fn rowCount(self: FakeGrid) usize {
        return self.rows.len;
    }
    fn colCount(self: FakeGrid, row: usize) usize {
        return self.rows[row].len;
    }
    fn codepoint(self: FakeGrid, row: usize, col: usize) u21 {
        return self.rows[row][col];
    }
};

test "inferPrefixForClick: finds the ls command above the clicked row" {
    const grid = FakeGrid{ .rows = &.{
        "$ ls Ath/Ph_SE/",
        "cluster_resolution_summary.tsv",
        "summary.txt",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Ath/Ph_SE/", inferPrefixForClick(grid, 2, &buf).?);
}

test "inferPrefixForClick: picks the nearest ls when several exist" {
    const grid = FakeGrid{ .rows = &.{
        "$ ls first/",
        "a.txt",
        "$ ls second/",
        "b.txt",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("second/", inferPrefixForClick(grid, 3, &buf).?);
}

test "inferPrefixForClick: no ls above returns null" {
    const grid = FakeGrid{ .rows = &.{
        "$ cat notes.txt",
        "some output",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expect(inferPrefixForClick(grid, 1, &buf) == null);
}

test "inferPrefixForClick: empty grid returns null" {
    const grid = FakeGrid{ .rows = &.{} };
    var buf: [256]u8 = undefined;
    try std.testing.expect(inferPrefixForClick(grid, 0, &buf) == null);
}

/// True when `path` is a plain filename with no directory component: not
/// absolute, not `~`-rooted, no `/` or `\`, and not a `X:` Windows drive path.
pub fn isBareRelativeFilename(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '~') return false;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return false; // windows drive letter
    for (path) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

/// When `ls_prefix` is present and `path` is a bare filename, return an
/// allocator-owned `prefix ++ path`. Returns null to mean "use `path` as-is"
/// (no prefix, or the token is already a path). Caller frees a non-null result.
pub fn applyLsPrefix(allocator: std.mem.Allocator, path: []const u8, ls_prefix: ?[]const u8) !?[]u8 {
    const pfx = ls_prefix orelse return null;
    if (!isBareRelativeFilename(path)) return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, path });
}

test "isBareRelativeFilename: accepts plain names, rejects pathed tokens" {
    try std.testing.expect(isBareRelativeFilename("cluster_resolution_summary.tsv"));
    try std.testing.expect(!isBareRelativeFilename("Ath/Ph_SE/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("/abs/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("~/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("C:/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("dir\\x.tsv"));
    try std.testing.expect(!isBareRelativeFilename(""));
    try std.testing.expect(isBareRelativeFilename("a:b")); // POSIX colon name, not a drive
    try std.testing.expect(!isBareRelativeFilename("Z:\\x.tsv")); // real drive letter still rejected
}

test "applyLsPrefix: joins prefix onto a bare filename" {
    const allocator = std.testing.allocator;
    const joined = (try applyLsPrefix(allocator, "x.tsv", "Ath/Ph_SE/")).?;
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("Ath/Ph_SE/x.tsv", joined);
}

test "applyLsPrefix: concatenates verbatim (caller owns the separator)" {
    const allocator = std.testing.allocator;
    // applyLsPrefix does not insert a separator; parseLsDirArg guarantees the
    // trailing slash. A prefix without one concatenates directly.
    const joined = (try applyLsPrefix(allocator, "x.tsv", "Ath")).?;
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("Athx.tsv", joined);
}

test "applyLsPrefix: null prefix or already-pathed token yields null" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try applyLsPrefix(allocator, "x.tsv", null)) == null);
    try std.testing.expect((try applyLsPrefix(allocator, "sub/x.tsv", "Ath/")) == null);
    try std.testing.expect((try applyLsPrefix(allocator, "/abs/x.tsv", "Ath/")) == null);
}
