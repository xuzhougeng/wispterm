//! tmux layout-string parser. Pure: depends only on `std`.
//!
//! Grammar (tmux `window_layout`):
//!   layout := [checksum ','] cell
//!   cell   := W 'x' H ',' X ',' Y ( ',' paneid | '{' cells '}' | '[' cells ']' )
//!   cells  := cell (',' cell)*
//! `{...}` lays panes left-to-right (horizontal row); `[...]` top-to-bottom.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dir = enum { horizontal, vertical };

pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct { x: u32, y: u32, w: u32, h: u32, pane_id: usize };
    pub const Split = struct { dir: Dir, x: u32, y: u32, w: u32, h: u32, children: []Node };
};

/// Owns an arena holding the whole node tree. Call `deinit` to free it all.
pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    root: Node,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{SyntaxError} || Allocator.Error;

pub fn parse(gpa: Allocator, str: []const u8) ParseError!Layout {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p = CellParser{ .s = stripChecksum(str), .i = 0, .arena = arena.allocator() };
    const root = try p.parseCell();
    if (p.i != p.s.len) return error.SyntaxError;
    return .{ .arena = arena, .root = root };
}

fn stripChecksum(str: []const u8) []const u8 {
    // A checksum prefix is exactly 4 hex digits then ','. A cell instead has
    // 'x' within its first token (e.g. "80x24"), and widths are decimal-only,
    // so this never misfires on a leading cell.
    if (str.len >= 5 and str[4] == ',' and
        isHex(str[0]) and isHex(str[1]) and isHex(str[2]) and isHex(str[3]))
        return str[5..];
    return str;
}

const CellParser = struct {
    s: []const u8,
    i: usize,
    arena: Allocator,

    fn peek(self: *CellParser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn expect(self: *CellParser, c: u8) ParseError!void {
        if (self.peek() != c) return error.SyntaxError;
        self.i += 1;
    }

    fn parseU32(self: *CellParser) ParseError!u32 {
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        if (self.i == start) return error.SyntaxError;
        return std.fmt.parseInt(u32, self.s[start..self.i], 10) catch return error.SyntaxError;
    }

    fn parseCell(self: *CellParser) ParseError!Node {
        const w = try self.parseU32();
        try self.expect('x');
        const h = try self.parseU32();
        try self.expect(',');
        const x = try self.parseU32();
        try self.expect(',');
        const y = try self.parseU32();
        switch (self.peek() orelse return error.SyntaxError) {
            ',' => {
                self.i += 1;
                const pane_id = try self.parseU32();
                return .{ .leaf = .{ .x = x, .y = y, .w = w, .h = h, .pane_id = pane_id } };
            },
            '{' => return self.parseChildren('{', '}', .horizontal, x, y, w, h),
            '[' => return self.parseChildren('[', ']', .vertical, x, y, w, h),
            else => return error.SyntaxError,
        }
    }

    fn parseChildren(
        self: *CellParser,
        open: u8,
        close: u8,
        dir: Dir,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) ParseError!Node {
        try self.expect(open);
        var children: std.ArrayListUnmanaged(Node) = .empty;
        while (true) {
            const child = try self.parseCell();
            try children.append(self.arena, child);
            const c = self.peek() orelse return error.SyntaxError;
            if (c == ',') {
                self.i += 1;
                continue;
            }
            if (c == close) {
                self.i += 1;
                break;
            }
            return error.SyntaxError;
        }
        return .{ .split = .{ .dir = dir, .x = x, .y = y, .w = w, .h = h, .children = children.items } };
    }
};

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// tmux layout checksum (16-bit, computed over the cell portion of the layout
/// string, i.e. without the `csum,` prefix). tmux formats it as `%04x`.
pub fn checksum(layout: []const u8) u16 {
    var csum: u16 = 0;
    for (layout) |c| {
        csum = (csum >> 1) +% ((csum & 1) << 15);
        csum +%= c;
    }
    return csum;
}

test "parses a single leaf cell with checksum prefix" {
    var layout = try parse(std.testing.allocator, "bd1b,80x24,0,0,1");
    defer layout.deinit();
    const leaf = layout.root.leaf;
    try std.testing.expectEqual(@as(u32, 80), leaf.w);
    try std.testing.expectEqual(@as(u32, 24), leaf.h);
    try std.testing.expectEqual(@as(u32, 0), leaf.x);
    try std.testing.expectEqual(@as(u32, 0), leaf.y);
    try std.testing.expectEqual(@as(usize, 1), leaf.pane_id);
}

test "parses a leaf cell without a checksum prefix" {
    var layout = try parse(std.testing.allocator, "80x24,0,0,5");
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 5), layout.root.leaf.pane_id);
}

test "rejects trailing garbage" {
    try std.testing.expectError(error.SyntaxError, parse(std.testing.allocator, "80x24,0,0,1xx"));
}

test "parses a horizontal split of two leaves" {
    var layout = try parse(std.testing.allocator, "bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer layout.deinit();
    const split = layout.root.split;
    try std.testing.expectEqual(Dir.horizontal, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(usize, 1), split.children[0].leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 41), split.children[1].leaf.x);
    try std.testing.expectEqual(@as(usize, 2), split.children[1].leaf.pane_id);
}

test "parses a vertical split" {
    var layout = try parse(std.testing.allocator, "80x24,0,0[80x12,0,0,1,80x11,0,13,2]");
    defer layout.deinit();
    const split = layout.root.split;
    try std.testing.expectEqual(Dir.vertical, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(u32, 13), split.children[1].leaf.y);
}

test "parses a split nested inside a split" {
    var layout = try parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}");
    defer layout.deinit();
    const outer = layout.root.split;
    try std.testing.expectEqual(Dir.horizontal, outer.dir);
    const inner = outer.children[1].split;
    try std.testing.expectEqual(Dir.vertical, inner.dir);
    try std.testing.expectEqual(@as(usize, 2), inner.children.len);
    try std.testing.expectEqual(@as(usize, 3), inner.children[1].leaf.pane_id);
}

test "checksum matches tmux's rotate-add algorithm" {
    try std.testing.expectEqual(@as(u16, 0), checksum(""));
    try std.testing.expectEqual(@as(u16, 97), checksum("a"));
    try std.testing.expectEqual(@as(u16, 32914), checksum("ab"));
}
