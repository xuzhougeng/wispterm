//! Frame-local reveal of ellipsized UI labels. No window or renderer imports:
//! the host supplies the pointer, the text renderer offers clipped labels,
//! and the frame tail paints a wrapped hint. It never changes application data.
const std = @import("std");

pub const State = struct {
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    width: f32 = 0,
    height: f32 = 0,
    anchor_y: f32 = 0,
    text: [8192]u8 = undefined,
    len: usize = 0,

    pub fn begin(self: *State, width: f32, height: f32, mouse_x: f32, mouse_y: f32) void {
        self.width = width;
        self.height = height;
        self.mouse_x = mouse_x;
        self.mouse_y = mouse_y;
        self.len = 0;
    }

    pub fn clear(self: *State) void {
        self.len = 0;
    }

    pub fn offer(self: *State, text: []const u8, x: f32, y: f32, w: f32, h: f32) void {
        if (w <= 0 or self.mouse_x < x or self.mouse_x >= x + w or
            self.mouse_y < y or self.mouse_y >= y + h) return;
        // Later labels win, matching painter order. Copy stack-backed strings.
        var len = @min(text.len, self.text.len);
        while (len < text.len and len > 0 and (text[len] & 0xc0) == 0x80) len -= 1;
        @memcpy(self.text[0..len], text[0..len]);
        self.len = len;
        self.anchor_y = y;
    }
};

// Like the glyph atlas, this state belongs to the window's render thread.
pub threadlocal var current: State = .{};

pub const Line = struct { start: usize, end: usize };
pub const Layout = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    line_h: f32,
    lines: [64]Line = undefined,
    count: usize = 0,
};

pub fn layout(state: *const State, cell_h: f32, advance: *const fn (u32) f32) ?Layout {
    if (state.len == 0 or state.width < 64 or state.height < cell_h + 48) return null;
    const text = state.text[0..state.len];
    const view = std.unicode.Utf8View.init(text) catch return null;
    var measure_it = view.iterator();
    var measured: f32 = 0;
    while (measure_it.nextCodepoint()) |cp| measured += advance(cp);
    const w = @min(state.width - 32, @min(720, @max(160, measured + 24)));
    const line_h = cell_h + 6;
    const max_lines: usize = @intFromFloat(@min(64, @floor((state.height - 48) / line_h)));
    var result = Layout{ .x = 0, .y = 0, .w = w, .h = 0, .line_h = line_h };
    var it = view.iterator();
    var start: usize = 0;
    var line_w: f32 = 0;
    while (it.i < text.len and result.count < max_lines) {
        const before = it.i;
        const cp = it.nextCodepoint().?;
        const glyph_w = advance(cp);
        if (cp == '\n' or (line_w + glyph_w > w - 24 and before > start)) {
            result.lines[result.count] = .{ .start = start, .end = before };
            result.count += 1;
            start = if (cp == '\n') it.i else before;
            line_w = 0;
        }
        if (cp != '\n') line_w += glyph_w;
    }
    if (start < text.len and result.count < max_lines) {
        result.lines[result.count] = .{ .start = start, .end = text.len };
        result.count += 1;
    }
    if (result.count == 0) return null;
    result.h = @as(f32, @floatFromInt(result.count)) * line_h + 16;
    result.x = @max(16, @min(state.mouse_x, state.width - w - 16));
    const below = state.anchor_y - result.h - 8;
    result.y = @max(16, @min(if (below >= 16) below else state.anchor_y + cell_h + 8, state.height - result.h - 16));
    return result;
}

fn testAdvance(cp: u32) f32 {
    return if (cp < 128) 10 else 20;
}

test "hint owns the hovered text and clears at the next frame or modal" {
    var state = State{};
    state.begin(600, 400, 40, 50);
    var text = [_]u8{ 'l', 'o', 'n', 'g' };
    state.offer(&text, 20, 40, 100, 20);
    text[0] = 'X';
    try std.testing.expectEqualStrings("long", state.text[0..state.len]);
    state.offer("elsewhere", 200, 40, 100, 20);
    try std.testing.expectEqualStrings("long", state.text[0..state.len]);
    state.clear();
    try std.testing.expectEqual(@as(usize, 0), state.len);
    state.offer("again", 20, 40, 100, 20);
    state.begin(600, 400, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), state.len);
}

test "wrapped Chinese and model names stay inside narrow viewport gutters" {
    var state = State{};
    state.begin(260, 240, 230, 30);
    const text = "浏览 Codex / Claude Code 会话，完整说明与模型名称";
    state.offer(text, 20, 20, 220, 20);
    const result = layout(&state, 20, testAdvance).?;
    try std.testing.expect(result.count > 1);
    try std.testing.expect(result.x >= 16 and result.x + result.w <= 244);
    try std.testing.expect(result.y >= 16 and result.y + result.h <= 224);
    var end: usize = 0;
    for (result.lines[0..result.count]) |line| {
        try std.testing.expectEqual(end, line.start);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[line.start..line.end]));
        end = line.end;
    }
    try std.testing.expectEqual(text.len, end);
}
