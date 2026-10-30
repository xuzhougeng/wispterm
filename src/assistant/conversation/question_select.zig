//! Drag selection over the pending `ask_user` question card, so part of an
//! option can be copied into a custom answer instead of picking it whole.
//! Row 0 is the question; row k + 1 is option k, shown as
//! "N. label — description". Offsets are bytes in a row's display text. The
//! renderer measures glyphs and the Session owns the `State`.
const std = @import("std");
const types = @import("types.zig");

pub const AdvanceFn = *const fn (u21) f32;

pub const Point = struct {
    row: usize,
    byte: usize,

    fn before(a: Point, b: Point) bool {
        return a.row < b.row or (a.row == b.row and a.byte < b.byte);
    }
};

/// Ordered, non-empty selection: `start` sorts before `end`.
pub const Span = struct { start: Point, end: Point };

pub const Range = struct { start: usize, end: usize };

/// Mouse-up outcome. A press that never became a selection on an option row
/// still chooses that option, so a plain click keeps answering the question.
pub const Release = union(enum) {
    none,
    selected,
    choose: usize,
};

pub const State = struct {
    /// Question generation (`question_hscroll.State.generation`) this
    /// selection belongs to; a newer question makes it stale.
    generation: u64 = 0,
    anchor: Point = .{ .row = 0, .byte = 0 },
    cursor: Point = .{ .row = 0, .byte = 0 },
    active: bool = false,
    dragging: bool = false,
    pressed_option: ?usize = null,

    pub fn begin(self: *State, generation: u64, at: Point, option: ?usize) void {
        self.* = .{
            .generation = generation,
            .anchor = at,
            .cursor = at,
            .active = true,
            .dragging = true,
            .pressed_option = option,
        };
    }

    /// Move the drag end. Returns whether the selection changed.
    pub fn update(self: *State, generation: u64, at: Point) bool {
        if (!self.dragging or self.generation != generation) return false;
        if (std.meta.eql(self.cursor, at)) return false;
        self.cursor = at;
        return true;
    }

    /// `current` is the pending question's generation, or null when none is.
    pub fn finish(self: *State, current: ?u64) Release {
        self.dragging = false;
        const generation = current orelse {
            self.clear();
            return .none;
        };
        if (self.span(generation) != null) return .selected;
        // Copy the field before clear(): `if (c) self.pressed_option else null`
        // aliases the field and would read back null after the reset.
        const option = self.pressed_option;
        const same_question = self.active and self.generation == generation;
        self.clear();
        if (!same_question) return .none;
        return if (option) |index| .{ .choose = index } else .none;
    }

    pub fn clear(self: *State) void {
        self.* = .{};
    }

    pub fn span(self: State, generation: u64) ?Span {
        if (!self.active or self.generation != generation) return null;
        if (std.meta.eql(self.anchor, self.cursor)) return null;
        if (self.anchor.before(self.cursor)) return .{ .start = self.anchor, .end = self.cursor };
        return .{ .start = self.cursor, .end = self.anchor };
    }
};

/// A row's display text as consecutive pieces, so the card paints and
/// measures exactly what a copy returns.
pub const Row = struct {
    parts: [4][]const u8 = @splat(""),

    pub fn len(self: Row) usize {
        var total: usize = 0;
        for (self.parts) |part| total += part.len;
        return total;
    }

    fn appendRange(self: Row, allocator: std.mem.Allocator, out: *std.ArrayList(u8), range: Range) !void {
        var base: usize = 0;
        for (self.parts) |part| {
            const lo = @max(range.start, base);
            const hi = @min(range.end, base + part.len);
            if (lo < hi) try out.appendSlice(allocator, part[lo - base .. hi - base]);
            base += part.len;
        }
    }
};

pub fn rowCount(view: types.QuestionView) usize {
    return 1 + view.options.len;
}

/// `number_buf` backs the "N. " prefix and must outlive the returned row.
pub fn row(view: types.QuestionView, index: usize, number_buf: *[24]u8) Row {
    if (index == 0) return .{ .parts = .{ view.question, "", "", "" } };
    if (index > view.options.len) return .{};
    const opt = view.options[index - 1];
    const number = std.fmt.bufPrint(number_buf, "{d}. ", .{index}) catch unreachable;
    if (opt.description.len == 0) return .{ .parts = .{ number, opt.label, "", "" } };
    return .{ .parts = .{ number, opt.label, " — ", opt.description } };
}

/// Byte boundary nearest `x` (relative to the row's first glyph). Never splits
/// a codepoint; left of the row is 0 and right of it is the row length.
pub fn byteAtX(r: Row, x: f32, advance: AdvanceFn) usize {
    var pen: f32 = 0;
    var base: usize = 0;
    for (r.parts) |part| {
        defer base += part.len;
        const view = std.unicode.Utf8View.init(part) catch continue;
        var it = view.iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |slice| : (i += slice.len) {
            const w = advance(std.unicode.utf8Decode(slice) catch 0xFFFD);
            if (x < pen + w / 2) return base + i;
            pen += w;
        }
    }
    return base;
}

/// Pen position before byte `byte` of the row.
pub fn xAtByte(r: Row, byte: usize, advance: AdvanceFn) f32 {
    var pen: f32 = 0;
    var base: usize = 0;
    for (r.parts) |part| {
        defer base += part.len;
        const view = std.unicode.Utf8View.init(part) catch continue;
        var it = view.iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |slice| : (i += slice.len) {
            if (base + i >= byte) return pen;
            pen += advance(std.unicode.utf8Decode(slice) catch 0xFFFD);
        }
    }
    return pen;
}

/// Selected bytes of row `index`, or null when the span misses it.
pub fn rowRange(s: Span, index: usize, row_len: usize) ?Range {
    if (index < s.start.row or index > s.end.row) return null;
    const lo = if (index == s.start.row) @min(s.start.byte, row_len) else 0;
    const hi = if (index == s.end.row) @min(s.end.byte, row_len) else row_len;
    return if (lo < hi) .{ .start = lo, .end = hi } else null;
}

/// Selected text with rows joined by '\n'. Caller owns the result.
pub fn allocText(allocator: std.mem.Allocator, view: types.QuestionView, s: Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const last = @min(s.end.row, rowCount(view) - 1);
    var index = s.start.row;
    while (index <= last) : (index += 1) {
        if (index > s.start.row) try out.append(allocator, '\n');
        var number_buf: [24]u8 = undefined;
        const r = row(view, index, &number_buf);
        const range = rowRange(s, index, r.len()) orelse continue;
        try r.appendRange(allocator, &out, range);
    }
    return out.toOwnedSlice(allocator);
}

fn unitAdvance(_: u21) f32 {
    return 10;
}

const test_view = types.QuestionView{
    .question = "Pick a name",
    .options = &.{
        .{ .label = "alpha", .description = "first" },
        .{ .label = "beta" },
    },
    .generation = 3,
};

test "rows mirror the card text and copy only the selected part of an option" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(@as(usize, "1. alpha — first".len), row(test_view, 1, &buf).len());
    try std.testing.expectEqual(@as(usize, "2. beta".len), row(test_view, 2, &buf).len());
    try std.testing.expectEqual(@as(usize, 0), row(test_view, 9, &buf).len());

    // "alpha" inside "1. alpha — first".
    const text = try allocText(std.testing.allocator, test_view, .{ .start = .{ .row = 1, .byte = 3 }, .end = .{ .row = 1, .byte = 8 } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("alpha", text);
}

test "multi-row selections join rows with newlines and cross piece boundaries" {
    const text = try allocText(std.testing.allocator, test_view, .{ .start = .{ .row = 0, .byte = 5 }, .end = .{ .row = 2, .byte = 4 } });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a name\n1. alpha — first\n2. b", text);
}

test "x maps to the nearest codepoint boundary and back" {
    var buf: [24]u8 = undefined;
    const r = row(test_view, 1, &buf); // "1. alpha — first", 10 units per codepoint
    try std.testing.expectEqual(@as(usize, 0), byteAtX(r, -40, unitAdvance));
    try std.testing.expectEqual(@as(usize, 0), byteAtX(r, 4, unitAdvance));
    try std.testing.expectEqual(@as(usize, 1), byteAtX(r, 6, unitAdvance));
    // The em dash is one 3-byte codepoint: the boundary after it is byte 12.
    try std.testing.expectEqual(@as(usize, 12), byteAtX(r, 96, unitAdvance));
    try std.testing.expectEqual(r.len(), byteAtX(r, 9999, unitAdvance));
    try std.testing.expectEqual(@as(f32, 90), xAtByte(r, 9, unitAdvance));
    try std.testing.expectEqual(@as(f32, 100), xAtByte(r, 12, unitAdvance));
}

test "a click without a drag chooses its option; a drag keeps the selection" {
    var state: State = .{};
    state.begin(3, .{ .row = 2, .byte = 4 }, 1);
    try std.testing.expect(!state.update(3, .{ .row = 2, .byte = 4 }));
    try std.testing.expectEqual(Release{ .choose = 1 }, state.finish(3));
    try std.testing.expect(!state.active);

    state.begin(3, .{ .row = 2, .byte = 4 }, 1);
    try std.testing.expect(state.update(3, .{ .row = 1, .byte = 2 }));
    try std.testing.expectEqual(Release.selected, state.finish(3));
    const s = state.span(3).?;
    try std.testing.expectEqual(Point{ .row = 1, .byte = 2 }, s.start);
    try std.testing.expectEqual(Point{ .row = 2, .byte = 4 }, s.end);
    try std.testing.expect(!state.update(3, .{ .row = 0, .byte = 0 })); // released

    // A press on the question title never chooses anything.
    state.begin(3, .{ .row = 0, .byte = 1 }, null);
    try std.testing.expectEqual(Release.none, state.finish(3));
}

test "a selection never outlives or answers a newer question" {
    var state: State = .{};
    state.begin(3, .{ .row = 1, .byte = 0 }, 0);
    try std.testing.expect(!state.update(4, .{ .row = 1, .byte = 5 }));
    try std.testing.expectEqual(Release.none, state.finish(4));

    state.begin(3, .{ .row = 1, .byte = 0 }, 0);
    _ = state.update(3, .{ .row = 1, .byte = 5 });
    try std.testing.expectEqual(Release.selected, state.finish(3));
    try std.testing.expect(state.span(4) == null);
    try std.testing.expectEqual(Release.none, state.finish(null));
    try std.testing.expect(!state.active);
}

test "row ranges clamp to each row" {
    const s = Span{ .start = .{ .row = 0, .byte = 5 }, .end = .{ .row = 2, .byte = 3 } };
    try std.testing.expectEqual(Range{ .start = 5, .end = 11 }, rowRange(s, 0, 11).?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 7 }, rowRange(s, 1, 7).?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 3 }, rowRange(s, 2, 9).?);
    try std.testing.expect(rowRange(s, 3, 9) == null);
    try std.testing.expect(rowRange(.{ .start = .{ .row = 0, .byte = 11 }, .end = .{ .row = 1, .byte = 0 } }, 0, 11) == null);
}
