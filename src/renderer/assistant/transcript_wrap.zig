//! Wrapped-line math and a cross-frame measurement cache for the assistant
//! transcript.
//!
//! The transcript wraps every message body by summing titlebar glyph advances.
//! With a long tool card (thousands of lines) that walk dominated each repaint:
//! layout measured the whole transcript twice and painting walked the card a
//! third time, even far below the viewport. This module keeps the one wrap
//! rule in one place (`Lines`), records a sparse line index (`Index`) so a
//! painter can resume wrapping next to the first visible line (`Visible`), and
//! caches measurements across frames keyed by content hash, wrap width and the
//! caller's font-metrics fingerprint (`Cache`).
//!
//! Kept free of renderer/font globals so it is unit-testable: callers inject
//! codepoint advances via `advance`, like `composer_detail_wrap.zig`.

const std = @import("std");

pub const AdvanceFn = *const fn (u21) f32;

/// One wrapped display line: a byte range of the measured text, excluding the
/// '\n' that ended it.
pub const Line = struct {
    start: usize,
    end: usize,
};

const Codepoint = struct { len: usize, advance: f32 };

fn nextCodepoint(text: []const u8, i: usize, advance: AdvanceFn) Codepoint {
    const first = text[i];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (i + len > text.len) return .{ .len = 1, .advance = advance('?') };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch @as(u21, '?');
    return .{ .len = len, .advance = advance(cp) };
}

/// Iterates wrapped lines with the transcript's wrap rule: a '\n' ends a line
/// (and is consumed), and a codepoint that would push a non-empty line past
/// `max_w` starts the next one. The final line is always yielded, so empty
/// text and a trailing '\n' each produce one empty line.
pub const Lines = struct {
    text: []const u8,
    max_w: f32,
    advance: AdvanceFn,
    i: usize = 0,
    done: bool = false,

    pub fn init(text: []const u8, max_w: f32, advance: AdvanceFn) Lines {
        return .{ .text = text, .max_w = max_w, .advance = advance };
    }

    /// Resume at `offset`, which must be where a wrapped line starts (e.g. an
    /// `Index` anchor): the wrap state there is fully described by the offset.
    pub fn initAt(text: []const u8, offset: usize, max_w: f32, advance: AdvanceFn) Lines {
        return .{ .text = text, .max_w = max_w, .advance = advance, .i = @min(offset, text.len) };
    }

    pub fn next(self: *Lines) ?Line {
        if (self.done) return null;
        const start = self.i;
        var width: f32 = 0;
        while (self.i < self.text.len) {
            if (self.text[self.i] == '\n') {
                const end = self.i;
                self.i += 1;
                return .{ .start = start, .end = end };
            }
            const item = nextCodepoint(self.text, self.i, self.advance);
            if (width > 0 and width + item.advance > self.max_w) return .{ .start = start, .end = self.i };
            width += item.advance;
            self.i += item.len;
        }
        self.done = true;
        return .{ .start = start, .end = self.i };
    }
};

/// Number of wrapped lines `text` occupies at `max_w` (at least 1).
pub fn countLines(text: []const u8, max_w: f32, advance: AdvanceFn) usize {
    var lines = Lines.init(text, max_w, advance);
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    return n;
}

/// Caret byte offset for a click at `x` (px from the line's left edge) on
/// wrapped line `row`; rows past the end clamp to the last line, and a click
/// past a glyph's midpoint lands after it.
pub fn offsetAt(text: []const u8, max_w: f32, advance: AdvanceFn, row: usize, x: f32) usize {
    var lines = Lines.init(text, max_w, advance);
    var line = lines.next().?;
    var r: usize = 0;
    while (r < row) : (r += 1) line = lines.next() orelse break;
    var width: f32 = 0;
    var i = line.start;
    while (i < line.end) {
        const item = nextCodepoint(text, i, advance);
        if (x < width + item.advance / 2) break;
        width += item.advance;
        i += item.len;
    }
    return i;
}

/// Wrapped lines between consecutive `Index` anchors.
pub const anchor_stride: usize = 64;

pub const Anchor = struct {
    line: usize,
    offset: usize,
};

/// A text's wrapped-line count plus the start offset of every
/// `anchor_stride`-th wrapped line, so a painter can resume wrapping near any
/// line instead of from byte 0.
pub const Index = struct {
    /// Wrapped line count (at least 1).
    lines: usize = 1,
    /// `anchors[k]` = byte offset where wrapped line `k * anchor_stride` starts.
    anchors: []const usize = &.{},

    pub fn build(allocator: std.mem.Allocator, text: []const u8, max_w: f32, advance: AdvanceFn) !Index {
        var anchors: std.ArrayListUnmanaged(usize) = .empty;
        errdefer anchors.deinit(allocator);
        var lines = Lines.init(text, max_w, advance);
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            if (n % anchor_stride == 0) try anchors.append(allocator, line.start);
        }
        return .{ .lines = n, .anchors = try anchors.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: Index, allocator: std.mem.Allocator) void {
        allocator.free(self.anchors);
    }

    /// The closest anchored line at or before `line`.
    pub fn seek(self: Index, line: usize) Anchor {
        if (self.anchors.len == 0) return .{ .line = 0, .offset = 0 };
        const k = @min(line / anchor_stride, self.anchors.len - 1);
        return .{ .line = k * anchor_stride, .offset = self.anchors[k] };
    }
};

/// Vertical clip band in top-down window pixels.
pub const Band = struct {
    top_px: f32,
    bottom_px: f32,

    pub const unbounded: Band = .{ .top_px = -std.math.inf(f32), .bottom_px = std.math.inf(f32) };
};

pub const VisibleLine = struct {
    line: Line,
    top_px: f32,
};

/// Wrapped lines that can touch `band`, with their top edges. Skips (via the
/// index when given) everything more than one line above the band and stops
/// one line below it; the one-line margin keeps glyphs that overhang their
/// line box. Line `n`'s top is `top_px + n * line_h`, exactly as if every
/// line were walked.
pub const Visible = struct {
    lines: Lines,
    line_no: usize,
    first: usize,
    top_px: f32,
    line_h: f32,
    stop_px: f32,

    pub fn init(
        text: []const u8,
        index: ?Index,
        top_px: f32,
        max_w: f32,
        line_h: f32,
        band: Band,
        advance: AdvanceFn,
    ) Visible {
        var first: usize = 0;
        const skip_px = band.top_px - top_px;
        if (line_h > 0 and skip_px > line_h) {
            first = @intFromFloat(@min(@floor(skip_px / line_h) - 1, @as(f32, @floatFromInt(std.math.maxInt(u32)))));
        }
        var self: Visible = .{
            .lines = Lines.init(text, max_w, advance),
            .line_no = 0,
            .first = first,
            .top_px = top_px,
            .line_h = line_h,
            .stop_px = band.bottom_px + line_h,
        };
        if (index) |idx| {
            const anchor = idx.seek(first);
            self.lines = Lines.initAt(text, anchor.offset, max_w, advance);
            self.line_no = anchor.line;
        }
        return self;
    }

    pub fn next(self: *Visible) ?VisibleLine {
        while (self.lines.next()) |line| {
            const n = self.line_no;
            self.line_no += 1;
            const line_top = self.top_px + @as(f32, @floatFromInt(n)) * self.line_h;
            if (line_top > self.stop_px) {
                self.lines.done = true;
                return null;
            }
            if (n < self.first) continue;
            return .{ .line = line, .top_px = line_top };
        }
        return null;
    }
};

pub const Kind = enum(u8) {
    /// `Entry.index` holds the wrapped-line index.
    wrapped,
    /// `Entry.height` holds a caller-measured height.
    markdown,
};

pub fn contentHash(text: []const u8) u64 {
    return std.hash.XxHash3.hash(0, text);
}

/// Content identity plus everything the measurement depends on. The full
/// content hash (not the slice address) keeps a freed-and-reused allocation
/// from aliasing; a streaming append changes `len`/`hash` and so misses.
pub const Key = struct {
    kind: Kind,
    len: usize,
    hash: u64,
    width_bits: u32,
    metrics: u64,

    /// `hash` is `contentHash` of the measured text.
    pub fn init(kind: Kind, text_len: usize, hash: u64, max_w: f32, metrics: u64) Key {
        return .{
            .kind = kind,
            .len = text_len,
            .hash = hash,
            .width_bits = @bitCast(max_w),
            .metrics = metrics,
        };
    }

    pub fn of(kind: Kind, text: []const u8, max_w: f32, metrics: u64) Key {
        return init(kind, text.len, contentHash(text), max_w, metrics);
    }
};

pub const Entry = struct {
    index: Index = .{},
    height: f32 = 0,
    last_pass: u64 = 0,
};

/// Measurements that survive across frames. A pass is one transcript paint;
/// `sweep` drops entries no recent pass touched so deleted or edited messages
/// do not accumulate.
pub const Cache = struct {
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    pass: u64 = 0,

    pub fn beginPass(self: *Cache) void {
        self.pass +%= 1;
    }

    /// The cached entry for `key`, marked as used by the current pass. The
    /// pointer is valid until the next `put` or `sweep`.
    pub fn get(self: *Cache, key: Key) ?*Entry {
        const entry = self.map.getPtr(key) orelse return null;
        entry.last_pass = self.pass;
        return entry;
    }

    /// Store `entry` (taking ownership of its index) under `key`.
    pub fn put(self: *Cache, allocator: std.mem.Allocator, key: Key, entry: Entry) !*Entry {
        const gop = try self.map.getOrPut(allocator, key);
        if (gop.found_existing) gop.value_ptr.index.deinit(allocator);
        gop.value_ptr.* = entry;
        gop.value_ptr.last_pass = self.pass;
        return gop.value_ptr;
    }

    /// Drop entries not touched in the last `max_age` passes.
    pub fn sweep(self: *Cache, allocator: std.mem.Allocator, max_age: u64) void {
        while (true) {
            var stale: [64]Key = undefined;
            var n: usize = 0;
            var it = self.map.iterator();
            while (it.next()) |kv| {
                if (self.pass -% kv.value_ptr.last_pass <= max_age) continue;
                stale[n] = kv.key_ptr.*;
                n += 1;
                if (n == stale.len) break;
            }
            for (stale[0..n]) |key| {
                if (self.map.fetchRemove(key)) |removed| removed.value.index.deinit(allocator);
            }
            if (n < stale.len) return;
        }
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| entry.index.deinit(allocator);
        self.map.deinit(allocator);
        self.* = .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

/// ASCII is 1 wide, everything else 2 (CJK-ish).
fn testAdvance(cp: u21) f32 {
    return if (cp < 0x80) 1 else 2;
}

/// The renderer's original inline wrap loop, kept as the reference the
/// iterator must reproduce line for line.
fn referenceLines(buf: []Line, text: []const u8, max_w: f32) []Line {
    var n: usize = 0;
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            buf[n] = .{ .start = line_start, .end = i };
            n += 1;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i, &testAdvance);
        if (line_width > 0 and line_width + item.advance > max_w) {
            buf[n] = .{ .start = line_start, .end = i };
            n += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    buf[n] = .{ .start = line_start, .end = i };
    return buf[0 .. n + 1];
}

fn expectMatchesReference(text: []const u8, max_w: f32) !void {
    var ref_buf: [512]Line = undefined;
    const expected = referenceLines(&ref_buf, text, max_w);
    var lines = Lines.init(text, max_w, &testAdvance);
    for (expected) |want| {
        const got = lines.next() orelse return error.TooFewLines;
        try std.testing.expectEqual(want, got);
    }
    try std.testing.expect(lines.next() == null);
    try std.testing.expectEqual(expected.len, countLines(text, max_w, &testAdvance));
}

test "Lines reproduces the transcript wrap loop" {
    try expectMatchesReference("", 10);
    try expectMatchesReference("abc", 10);
    try expectMatchesReference("abc\n", 10);
    try expectMatchesReference("\n\n", 10);
    try expectMatchesReference("abcdefghij", 4);
    try expectMatchesReference("ab\ncdefgh\n\nij", 3);
    try expectMatchesReference("中文输出测试 行号", 5);
    try expectMatchesReference("x", 0.5); // narrower than one glyph: one per line
    try expectMatchesReference("bad \xff utf8 \xe4\xb8", 4);
}

test "offsetAt maps a click to the nearest caret on its wrapped line" {
    // "abcdef\n中x" at width 4 → lines "abcd", "ef", "中x".
    const s = "abcdef\n\u{4e2d}x";
    try std.testing.expectEqual(@as(usize, 0), offsetAt(s, 4, &testAdvance, 0, -3));
    try std.testing.expectEqual(@as(usize, 1), offsetAt(s, 4, &testAdvance, 0, 0.6));
    try std.testing.expectEqual(@as(usize, 4), offsetAt(s, 4, &testAdvance, 0, 99));
    try std.testing.expectEqual(@as(usize, 6), offsetAt(s, 4, &testAdvance, 1, 99));
    try std.testing.expectEqual(@as(usize, 7), offsetAt(s, 4, &testAdvance, 2, 0.9));
    try std.testing.expectEqual(@as(usize, 10), offsetAt(s, 4, &testAdvance, 2, 1.1));
    try std.testing.expectEqual(@as(usize, 11), offsetAt(s, 4, &testAdvance, 9, 99));
    try std.testing.expectEqual(@as(usize, 0), offsetAt("", 4, &testAdvance, 3, 5));
}

test "Index anchors resume wrapping at the same lines" {
    var text_buf: [8192]u8 = undefined;
    var len: usize = 0;
    for (0..300) |i| len += (try std.fmt.bufPrint(text_buf[len..], "{d:0>4} line text {d}\n", .{ i, i % 7 })).len;
    const text = text_buf[0..len];

    const index = try Index.build(std.testing.allocator, text, 9, &testAdvance);
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(countLines(text, 9, &testAdvance), index.lines);
    try std.testing.expectEqual((index.lines + anchor_stride - 1) / anchor_stride, index.anchors.len);

    var all: [1024]Line = undefined;
    var n: usize = 0;
    var lines = Lines.init(text, 9, &testAdvance);
    while (lines.next()) |line| : (n += 1) all[n] = line;

    for ([_]usize{ 0, 1, 63, 64, 65, 200, index.lines - 1 }) |target| {
        const anchor = index.seek(target);
        try std.testing.expect(anchor.line <= target);
        try std.testing.expect(target - anchor.line < anchor_stride);
        var resumed = Lines.initAt(text, anchor.offset, 9, &testAdvance);
        var line_no = anchor.line;
        while (resumed.next()) |line| : (line_no += 1) try std.testing.expectEqual(all[line_no], line);
        try std.testing.expectEqual(n, line_no);
    }
}

test "Visible yields only lines near the band, at walked positions" {
    var text_buf: [4096]u8 = undefined;
    var len: usize = 0;
    for (0..400) |i| len += (try std.fmt.bufPrint(text_buf[len..], "row {d}\n", .{i})).len;
    const text = text_buf[0..len];
    const index = try Index.build(std.testing.allocator, text, 100, &testAdvance);
    defer index.deinit(std.testing.allocator);

    const top: f32 = -5000.5;
    const line_h: f32 = 23;
    const band: Band = .{ .top_px = 100, .bottom_px = 400 };
    for ([_]?Index{ null, index }) |maybe_index| {
        var visible = Visible.init(text, maybe_index, top, 100, line_h, band, &testAdvance);
        var count: usize = 0;
        var first_top: f32 = 0;
        var last_top: f32 = 0;
        while (visible.next()) |v| : (count += 1) {
            if (count == 0) first_top = v.top_px;
            last_top = v.top_px;
            // Same line content as a full walk would put at this position.
            const n: usize = @intFromFloat((v.top_px - top) / line_h);
            var want_buf: [16]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "row {d}", .{n});
            try std.testing.expectEqualStrings(want, text[v.line.start..v.line.end]);
        }
        // Covers the band with at most one line of margin on each side.
        try std.testing.expect(first_top <= band.top_px);
        try std.testing.expect(first_top + 2 * line_h > band.top_px);
        try std.testing.expect(last_top + line_h >= band.bottom_px);
        try std.testing.expect(last_top <= band.bottom_px + line_h);
        try std.testing.expect(count < 20);
    }
}

test "Visible with an unbounded band walks every line" {
    const text = "a\nb\nc";
    var visible = Visible.init(text, null, 0, 10, 10, Band.unbounded, &testAdvance);
    var count: usize = 0;
    while (visible.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "Key changes with content, width, and metrics" {
    const base = Key.of(.wrapped, "hello", 100, 1);
    try std.testing.expectEqual(base, Key.of(.wrapped, "hello", 100, 1));
    try std.testing.expect(!std.meta.eql(base, Key.of(.wrapped, "hello!", 100, 1))); // streaming append
    try std.testing.expect(!std.meta.eql(base, Key.of(.wrapped, "hellp", 100, 1))); // same len, new bytes
    try std.testing.expect(!std.meta.eql(base, Key.of(.wrapped, "hello", 101, 1))); // resize
    try std.testing.expect(!std.meta.eql(base, Key.of(.wrapped, "hello", 100, 2))); // font/DPI change
    try std.testing.expect(!std.meta.eql(base, Key.of(.markdown, "hello", 100, 1)));
}

test "Cache keeps entries a recent pass touched and sweeps the rest" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);

    const live = Key.of(.wrapped, "live", 50, 0);
    const stale = Key.of(.wrapped, "stale", 50, 0);
    cache.beginPass();
    _ = try cache.put(allocator, live, .{ .index = try Index.build(allocator, "live", 50, &testAdvance) });
    _ = try cache.put(allocator, stale, .{ .index = try Index.build(allocator, "stale", 50, &testAdvance) });

    for (0..5) |_| {
        cache.beginPass();
        try std.testing.expect(cache.get(live) != null);
    }
    cache.sweep(allocator, 3);
    try std.testing.expect(cache.get(live) != null);
    try std.testing.expect(cache.get(stale) == null);

    // Replacing an entry frees the old index (checked by the testing allocator).
    _ = try cache.put(allocator, live, .{ .height = 12 });
    try std.testing.expectEqual(@as(f32, 12), cache.get(live).?.height);
}

test "Cache sweep handles more stale entries than one batch" {
    const allocator = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(allocator);
    var buf: [16]u8 = undefined;
    for (0..200) |i| {
        const text = try std.fmt.bufPrint(&buf, "msg {d}", .{i});
        _ = try cache.put(allocator, Key.of(.wrapped, text, 50, 0), .{ .index = try Index.build(allocator, text, 50, &testAdvance) });
    }
    for (0..3) |_| cache.beginPass();
    cache.sweep(allocator, 1);
    try std.testing.expectEqual(@as(u32, 0), cache.map.count());
}
