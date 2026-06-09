//! Pure classifier for a borderless window's hit-test: maps a point to a
//! drag/resize zone so the SDL shell can return the matching SDL_HITTEST_*.
//! No SDL dependency. The shell supplies window size, titlebar height, the
//! resize border thickness, and the sub-rects that must stay clickable
//! (caption buttons, tab strip).
const std = @import("std");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const DragHit = enum {
    normal, draggable,
    resize_top, resize_bottom, resize_left, resize_right,
    resize_top_left, resize_top_right, resize_bottom_left, resize_bottom_right,
};

pub const Opts = struct { titlebar_height: i32, border: i32, exclusions: []const Rect };

fn inRect(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

pub fn classify(w: i32, h: i32, x: i32, y: i32, o: Opts) DragHit {
    const b = o.border;
    const left = x < b;
    const right = x >= w - b;
    const top = y < b;
    const bottom = y >= h - b;
    if (top and left) return .resize_top_left;
    if (top and right) return .resize_top_right;
    if (bottom and left) return .resize_bottom_left;
    if (bottom and right) return .resize_bottom_right;
    if (top) return .resize_top;
    if (bottom) return .resize_bottom;
    if (left) return .resize_left;
    if (right) return .resize_right;
    if (y < o.titlebar_height) {
        for (o.exclusions) |r| if (inRect(r, x, y)) return .normal;
        return .draggable;
    }
    return .normal;
}

test "edges classify as resize zones" {
    const o = Opts{ .titlebar_height = 30, .border = 4, .exclusions = &.{} };
    try std.testing.expectEqual(DragHit.resize_top_left, classify(800, 600, 1, 1, o));
    try std.testing.expectEqual(DragHit.resize_right, classify(800, 600, 799, 300, o));
    try std.testing.expectEqual(DragHit.resize_bottom, classify(800, 600, 400, 599, o));
}

test "titlebar is draggable except over exclusions" {
    const excl = [_]Rect{.{ .x = 700, .y = 0, .w = 100, .h = 30 }}; // caption buttons
    const o = Opts{ .titlebar_height = 30, .border = 4, .exclusions = &excl };
    try std.testing.expectEqual(DragHit.draggable, classify(800, 600, 200, 10, o));
    try std.testing.expectEqual(DragHit.normal, classify(800, 600, 750, 10, o)); // on buttons
    try std.testing.expectEqual(DragHit.normal, classify(800, 600, 200, 300, o)); // body
}
