//! Backend-neutral conservative frame-damage collection.
//!
//! A frame may use a bounded dirty rectangle only when the caller can prove
//! that unchanged UI regions were not logically changed. Otherwise `finish`
//! returns null, which means the backend must use its full-frame Present path.

const std = @import("std");

pub const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const Collector = struct {
    full_frame: bool = false,
    has_rect: bool = false,
    rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    pub fn markFull(self: *Collector) void {
        self.full_frame = true;
        self.has_rect = false;
    }

    pub fn includeRect(self: *Collector, candidate: Rect, width: i32, height: i32) void {
        if (self.full_frame or width <= 0 or height <= 0) return;
        const clipped = Rect{
            .left = std.math.clamp(candidate.left, 0, width),
            .top = std.math.clamp(candidate.top, 0, height),
            .right = std.math.clamp(candidate.right, 0, width),
            .bottom = std.math.clamp(candidate.bottom, 0, height),
        };
        if (clipped.left >= clipped.right or clipped.top >= clipped.bottom) return;
        if (!self.has_rect) {
            self.rect = clipped;
            self.has_rect = true;
            return;
        }
        self.rect.left = @min(self.rect.left, clipped.left);
        self.rect.top = @min(self.rect.top, clipped.top);
        self.rect.right = @max(self.rect.right, clipped.right);
        self.rect.bottom = @max(self.rect.bottom, clipped.bottom);
    }

    pub fn includeRows(
        self: *Collector,
        origin_x: f32,
        origin_y: f32,
        cell_width: f32,
        cell_height: f32,
        row_start: usize,
        row_end: usize,
        width: i32,
        height: i32,
    ) void {
        if (row_end <= row_start or cell_width <= 0 or cell_height <= 0) return;
        const left: i32 = @intFromFloat(@floor(origin_x));
        const top: i32 = @intFromFloat(@floor(origin_y + @as(f32, @floatFromInt(row_start)) * cell_height));
        const right: i32 = @intFromFloat(@ceil(origin_x + cell_width));
        const bottom: i32 = @intFromFloat(@ceil(origin_y + @as(f32, @floatFromInt(row_end)) * cell_height));
        self.includeRect(.{ .left = left, .top = top, .right = right, .bottom = bottom }, width, height);
    }

    /// Null means full-frame/legacy Present. A non-null rectangle is safe to
    /// pass to Present1 because the caller only records proven terminal-row
    /// damage.
    pub fn finish(self: *const Collector) ?Rect {
        if (self.full_frame or !self.has_rect) return null;
        return self.rect;
    }
};

test "frame damage merges and clips terminal row rectangles" {
    var damage: Collector = .{};
    damage.includeRows(10, 20, 8, 16, 2, 4, 100, 100);
    damage.includeRows(0, 0, 10, 10, 0, 1, 100, 100);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 18, .bottom = 84 }, damage.finish().?);
}

test "full damage suppresses partial Present1 rectangles" {
    var damage: Collector = .{};
    damage.includeRows(0, 0, 10, 10, 0, 1, 100, 100);
    damage.markFull();
    try std.testing.expect(damage.finish() == null);
}
