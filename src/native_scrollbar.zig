const std = @import("std");

pub const State = struct {
    total: usize,
    len: usize,
    offset: usize,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Command = enum {
    line_up,
    line_down,
    page_up,
    page_down,
    thumb,
    top,
    bottom,
    end_scroll,
};

pub fn maxOffset(state: State) usize {
    if (state.total <= state.len) return 0;
    return state.total - state.len;
}

pub fn clampedOffset(state: State, offset: usize) usize {
    return @min(offset, maxOffset(state));
}

pub fn targetOffset(state: State, command: Command, thumb_pos: ?i32) ?usize {
    const max_offset = maxOffset(state);
    if (max_offset == 0) return null;
    const current = @min(state.offset, max_offset);

    return switch (command) {
        .line_up => if (current == 0) 0 else current - 1,
        .line_down => @min(current + 1, max_offset),
        .page_up => if (current <= state.len) 0 else current - state.len,
        .page_down => @min(current + state.len, max_offset),
        .thumb => blk: {
            const pos = thumb_pos orelse return null;
            if (pos <= 0) break :blk 0;
            break :blk @min(@as(usize, @intCast(pos)), max_offset);
        },
        .top => 0,
        .bottom => max_offset,
        .end_scroll => null,
    };
}

pub fn deltaToTarget(state: State, target: usize) isize {
    const current: i64 = @intCast(clampedOffset(state, state.offset));
    const wanted: i64 = @intCast(clampedOffset(state, target));
    return @intCast(wanted - current);
}

pub fn rightPadding(scrollbar_width: i32, default_padding: i32) u32 {
    const width = @max(0, scrollbar_width);
    const padding = @max(0, default_padding);
    return @intCast(width + padding);
}

pub fn trackRect(view_x: i32, view_y: i32, view_width: i32, view_height: i32, scrollbar_width: i32) ?Rect {
    if (view_width <= 0 or view_height <= 0 or scrollbar_width <= 0) return null;

    const width = @min(scrollbar_width, view_width);
    return .{
        .x = view_x + view_width - width,
        .y = view_y,
        .width = width,
        .height = view_height,
    };
}

test "native scrollbar commands clamp to scrollback range" {
    const state = State{ .total = 200, .len = 40, .offset = 30 };

    try std.testing.expectEqual(@as(?usize, 70), targetOffset(state, .page_down, null));
    try std.testing.expectEqual(@as(?usize, 0), targetOffset(state, .thumb, -20));
    try std.testing.expectEqual(@as(?usize, 160), targetOffset(state, .thumb, 240));
}

test "native scrollbar delta is relative to current viewport offset" {
    const state = State{ .total = 200, .len = 40, .offset = 30 };

    try std.testing.expectEqual(@as(isize, -30), deltaToTarget(state, 0));
    try std.testing.expectEqual(@as(isize, 130), deltaToTarget(state, 160));
}

test "native scrollbar reserves padding from native control width" {
    try std.testing.expectEqual(@as(u32, 27), rightPadding(17, 10));
    try std.testing.expectEqual(@as(u32, 10), rightPadding(0, 10));
}

test "native scrollbar track sits on viewport right edge" {
    const rect = trackRect(20, 40, 800, 600, 17).?;

    try std.testing.expectEqual(@as(i32, 803), rect.x);
    try std.testing.expectEqual(@as(i32, 40), rect.y);
    try std.testing.expectEqual(@as(i32, 17), rect.width);
    try std.testing.expectEqual(@as(i32, 600), rect.height);
}
