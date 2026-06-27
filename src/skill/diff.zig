//! Minimal line-level diff for the SKILL.md compare view. LCS over lines, then
//! emit a unified-ish list of ops. Pure; caller frees the returned slice and
//! each op's `text` is borrowed from the inputs (free the slice only).
const std = @import("std");

pub const Op = enum { context, add, del };
pub const Line = struct { op: Op, text: []const u8 };

fn splitLines(allocator: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| try out.append(allocator, ln);
    return out.toOwnedSlice(allocator);
}

/// Diff `a` (local) vs `b` (remote). `del` = present in a not b; `add` = in b not a.
pub fn diff(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]Line {
    const la = try splitLines(allocator, a);
    defer allocator.free(la);
    const lb = try splitLines(allocator, b);
    defer allocator.free(lb);

    // LCS length table.
    const n = la.len;
    const m = lb.len;
    const table = try allocator.alloc(usize, (n + 1) * (m + 1));
    defer allocator.free(table);
    @memset(table, 0);
    const idx = struct {
        fn at(i: usize, j: usize, cols: usize) usize {
            return i * cols + j;
        }
    };
    const cols = m + 1;
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        var j: usize = m;
        while (j > 0) : (j -= 1) {
            if (std.mem.eql(u8, la[i - 1], lb[j - 1])) {
                table[idx.at(i - 1, j - 1, cols)] = table[idx.at(i, j, cols)] + 1;
            } else {
                table[idx.at(i - 1, j - 1, cols)] = @max(table[idx.at(i, j - 1, cols)], table[idx.at(i - 1, j, cols)]);
            }
        }
    }

    var out: std.ArrayListUnmanaged(Line) = .empty;
    errdefer out.deinit(allocator);
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, la[i], lb[j])) {
            try out.append(allocator, .{ .op = .context, .text = la[i] });
            i += 1;
            j += 1;
        } else if (table[idx.at(i + 1, j, cols)] >= table[idx.at(i, j + 1, cols)]) {
            try out.append(allocator, .{ .op = .del, .text = la[i] });
            i += 1;
        } else {
            try out.append(allocator, .{ .op = .add, .text = lb[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try out.append(allocator, .{ .op = .del, .text = la[i] });
    while (j < m) : (j += 1) try out.append(allocator, .{ .op = .add, .text = lb[j] });
    return out.toOwnedSlice(allocator);
}

pub fn hasChanges(lines: []const Line) bool {
    for (lines) |l| if (l.op != .context) return true;
    return false;
}

// --- Tests ---

test "skill_diff: identical inputs -> no changes" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "a\nb\nc", "a\nb\nc");
    defer allocator.free(lines);
    try std.testing.expect(!hasChanges(lines));
}

test "skill_diff: add and delete" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "a\nb\nc", "a\nx\nc");
    defer allocator.free(lines);
    try std.testing.expect(hasChanges(lines));
    try std.testing.expectEqual(Op.context, lines[0].op);
    var saw_del = false;
    var saw_add = false;
    for (lines) |l| {
        if (l.op == .del and std.mem.eql(u8, l.text, "b")) saw_del = true;
        if (l.op == .add and std.mem.eql(u8, l.text, "x")) saw_add = true;
    }
    try std.testing.expect(saw_del and saw_add);
}

test "skill_diff: empty vs non-empty is all add" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "", "x\ny");
    defer allocator.free(lines);
    var adds: usize = 0;
    for (lines) |l| {
        if (l.op == .add) adds += 1;
    }
    try std.testing.expect(adds >= 2);
}
