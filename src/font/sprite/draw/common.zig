//! Common drawing utilities for sprite glyphs.
//!
//! Adapted from Ghostty's sprite drawing implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const canvas_mod = @import("../canvas.zig");
const Canvas = canvas_mod.Canvas;
const Color = canvas_mod.Color;

/// Metrics for sprite rendering
pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    box_thickness: u32 = 1,
};

// Utility names for common fractions
pub const one_eighth: f64 = 0.125;
pub const one_quarter: f64 = 0.25;
pub const one_third: f64 = (1.0 / 3.0);
pub const three_eighths: f64 = 0.375;
pub const half: f64 = 0.5;
pub const five_eighths: f64 = 0.625;
pub const two_thirds: f64 = (2.0 / 3.0);
pub const three_quarters: f64 = 0.75;
pub const seven_eighths: f64 = 0.875;

/// The thickness of a line.
pub const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Calculate the real height of a line based on its
    /// thickness and a base thickness value.
    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

/// Shades.
pub const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,
    _,
};

/// Applicable to any set of glyphs with features
/// that may be present or not in each quadrant.
pub const Quads = packed struct(u4) {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};

/// A corner of a cell.
pub const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};

/// An edge of a cell.
pub const Edge = enum(u2) {
    top,
    left,
    bottom,
    right,
};

/// Alignment of a figure within a cell.
pub const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,

    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,

    pub const upper: Alignment = .{ .vertical = .top };
    pub const lower: Alignment = .{ .vertical = .bottom };
    pub const left: Alignment = .{ .horizontal = .left };
    pub const right: Alignment = .{ .horizontal = .right };

    pub const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    pub const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    pub const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    pub const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };

    pub const center: Alignment = .{};
};

/// A value that indicates some fraction across the cell.
pub const Fraction = enum {
    start,
    left,
    top,
    zero,
    eighth,
    one_eighth,
    two_eighths,
    three_eighths,
    four_eighths,
    five_eighths,
    six_eighths,
    seven_eighths,
    quarter,
    one_quarter,
    two_quarters,
    three_quarters,
    third,
    one_third,
    two_thirds,
    half,
    one_half,
    center,
    middle,
    end,
    right,
    bottom,
    one,
    full,

    /// This can be indexed to get the fraction for `i/8`.
    pub const eighths: [9]Fraction = .{
        .zero,         .one_eighth,  .two_eighths,   .three_eighths, .four_eighths,
        .five_eighths, .six_eighths, .seven_eighths, .one,
    };

    /// Get the position for min (left/top) coordinate.
    pub inline fn min(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        return @intFromFloat(s - @round((1.0 - self.fraction()) * s));
    }

    /// Get the position for max (right/bottom) coordinate.
    pub inline fn max(self: Fraction, size: anytype) i32 {
        const s: f64 = @as(f64, @floatFromInt(size));
        return @intFromFloat(@round(self.fraction() * s));
    }

    /// Get the float value for this fraction.
    pub inline fn float(self: Fraction, size: anytype) f64 {
        return self.fraction() * @as(f64, @floatFromInt(size));
    }

    /// Get the fraction value.
    pub inline fn fraction(self: Fraction) f64 {
        return switch (self) {
            .start, .left, .top, .zero => 0.0,
            .eighth, .one_eighth => 0.125,
            .quarter, .one_quarter, .two_eighths => 0.25,
            .third, .one_third => 1.0 / 3.0,
            .three_eighths => 0.375,
            .half, .one_half, .two_quarters, .four_eighths, .center, .middle => 0.5,
            .five_eighths => 0.625,
            .two_thirds => 2.0 / 3.0,
            .three_quarters, .six_eighths => 0.75,
            .seven_eighths => 0.875,
            .end, .right, .bottom, .one, .full => 1.0,
        };
    }
};

/// Fill a section of the cell, specified by fraction lines.
pub fn fill(
    metrics: Metrics,
    canvas: *Canvas,
    x0: Fraction,
    x1: Fraction,
    y0: Fraction,
    y1: Fraction,
) void {
    canvas.box(
        x0.min(metrics.cell_width),
        y0.min(metrics.cell_height),
        x1.max(metrics.cell_width),
        y1.max(metrics.cell_height),
        .on,
    );
}

/// Centered vertical line of the provided thickness.
pub fn vlineMiddle(
    metrics: Metrics,
    canvas: *Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    vline(
        canvas,
        0,
        @intCast(metrics.cell_height),
        @intCast((metrics.cell_width -| thick_px) / 2),
        thick_px,
    );
}

/// Centered horizontal line of the provided thickness.
pub fn hlineMiddle(
    metrics: Metrics,
    canvas: *Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    hline(
        canvas,
        0,
        @intCast(metrics.cell_width),
        @intCast((metrics.cell_height -| thick_px) / 2),
        thick_px,
    );
}

/// Vertical line with the left edge at `x`, between `y1` and `y2`.
pub fn vline(
    canvas: *Canvas,
    y1: i32,
    y2: i32,
    x: i32,
    thickness_px: u32,
) void {
    canvas.box(x, y1, x + @as(i32, @intCast(thickness_px)), y2, .on);
}

/// Horizontal line with the top edge at `y`, between `x1` and `x2`.
pub fn hline(
    canvas: *Canvas,
    x1: i32,
    x2: i32,
    y: i32,
    thickness_px: u32,
) void {
    canvas.box(x1, y, x2, y + @as(i32, @intCast(thickness_px)), .on);
}
