//! Box Drawing Characters (U+2500 - U+257F)
//!
//! Adapted from Ghostty's box drawing implementation to use z2d canvas.

const std = @import("std");
const z2d = @import("z2d");
const canvas_mod = @import("../canvas.zig");
const Canvas = canvas_mod.Canvas;
const common = @import("common.zig");
const Metrics = common.Metrics;
const Thickness = common.Thickness;
const hline = common.hline;
const vline = common.vline;

/// Specification of a traditional intersection-style line/box-drawing char.
pub const Lines = packed struct(u8) {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,

    pub const Style = enum(u2) {
        none,
        light,
        heavy,
        double,
    };
};

pub fn draw(codepoint: u32, canvas: *Canvas, metrics: Metrics) !void {
    switch (codepoint) {
        // Basic horizontal and vertical lines
        0x2500 => linesChar(metrics, canvas, .{ .left = .light, .right = .light }),
        0x2501 => linesChar(metrics, canvas, .{ .left = .heavy, .right = .heavy }),
        0x2502 => linesChar(metrics, canvas, .{ .up = .light, .down = .light }),
        0x2503 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy }),

        // Dashed lines
        0x2504 => dashHorizontal(metrics, canvas, 3, .light),
        0x2505 => dashHorizontal(metrics, canvas, 3, .heavy),
        0x2506 => dashVertical(metrics, canvas, 3, .light),
        0x2507 => dashVertical(metrics, canvas, 3, .heavy),
        0x2508 => dashHorizontal(metrics, canvas, 4, .light),
        0x2509 => dashHorizontal(metrics, canvas, 4, .heavy),
        0x250A => dashVertical(metrics, canvas, 4, .light),
        0x250B => dashVertical(metrics, canvas, 4, .heavy),

        // Corners
        0x250C => linesChar(metrics, canvas, .{ .down = .light, .right = .light }),
        0x250D => linesChar(metrics, canvas, .{ .down = .light, .right = .heavy }),
        0x250E => linesChar(metrics, canvas, .{ .down = .heavy, .right = .light }),
        0x250F => linesChar(metrics, canvas, .{ .down = .heavy, .right = .heavy }),
        0x2510 => linesChar(metrics, canvas, .{ .down = .light, .left = .light }),
        0x2511 => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy }),
        0x2512 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light }),
        0x2513 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .heavy }),
        0x2514 => linesChar(metrics, canvas, .{ .up = .light, .right = .light }),
        0x2515 => linesChar(metrics, canvas, .{ .up = .light, .right = .heavy }),
        0x2516 => linesChar(metrics, canvas, .{ .up = .heavy, .right = .light }),
        0x2517 => linesChar(metrics, canvas, .{ .up = .heavy, .right = .heavy }),
        0x2518 => linesChar(metrics, canvas, .{ .up = .light, .left = .light }),
        0x2519 => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy }),
        0x251A => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light }),
        0x251B => linesChar(metrics, canvas, .{ .up = .heavy, .left = .heavy }),

        // T-junctions
        0x251C => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .light }),
        0x251D => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .heavy }),
        0x251E => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .right = .light }),
        0x251F => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .right = .light }),
        0x2520 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .right = .light }),
        0x2521 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .right = .heavy }),
        0x2522 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .right = .heavy }),
        0x2523 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .right = .heavy }),
        0x2524 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .light }),
        0x2525 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .heavy }),
        0x2526 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .light }),
        0x2527 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .light }),
        0x2528 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .light }),
        0x2529 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .heavy }),
        0x252A => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .heavy }),
        0x252B => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy }),
        0x252C => linesChar(metrics, canvas, .{ .down = .light, .left = .light, .right = .light }),
        0x252D => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy, .right = .light }),
        0x252E => linesChar(metrics, canvas, .{ .down = .light, .left = .light, .right = .heavy }),
        0x252F => linesChar(metrics, canvas, .{ .down = .light, .left = .heavy, .right = .heavy }),
        0x2530 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light, .right = .light }),
        0x2531 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .heavy, .right = .light }),
        0x2532 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .light, .right = .heavy }),
        0x2533 => linesChar(metrics, canvas, .{ .down = .heavy, .left = .heavy, .right = .heavy }),
        0x2534 => linesChar(metrics, canvas, .{ .up = .light, .left = .light, .right = .light }),
        0x2535 => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy, .right = .light }),
        0x2536 => linesChar(metrics, canvas, .{ .up = .light, .left = .light, .right = .heavy }),
        0x2537 => linesChar(metrics, canvas, .{ .up = .light, .left = .heavy, .right = .heavy }),
        0x2538 => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light, .right = .light }),
        0x2539 => linesChar(metrics, canvas, .{ .up = .heavy, .left = .heavy, .right = .light }),
        0x253A => linesChar(metrics, canvas, .{ .up = .heavy, .left = .light, .right = .heavy }),
        0x253B => linesChar(metrics, canvas, .{ .up = .heavy, .left = .heavy, .right = .heavy }),

        // Crosses
        0x253C => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .light, .right = .light }),
        0x253D => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .heavy, .right = .light }),
        0x253E => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .light, .right = .heavy }),
        0x253F => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy }),
        0x2540 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .light, .right = .light }),
        0x2541 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .light, .right = .light }),
        0x2542 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),
        0x2543 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .heavy, .right = .light }),
        0x2544 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .light, .right = .heavy }),
        0x2545 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .heavy, .right = .light }),
        0x2546 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .light, .right = .heavy }),
        0x2547 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light, .left = .heavy, .right = .heavy }),
        0x2548 => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy }),
        0x2549 => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .light }),
        0x254A => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .heavy }),
        0x254B => linesChar(metrics, canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy }),

        // More dashes
        0x254C => dashHorizontal(metrics, canvas, 2, .light),
        0x254D => dashHorizontal(metrics, canvas, 2, .heavy),
        0x254E => dashVertical(metrics, canvas, 2, .light),
        0x254F => dashVertical(metrics, canvas, 2, .heavy),

        // Double lines
        0x2550 => linesChar(metrics, canvas, .{ .left = .double, .right = .double }),
        0x2551 => linesChar(metrics, canvas, .{ .up = .double, .down = .double }),
        0x2552 => linesChar(metrics, canvas, .{ .down = .light, .right = .double }),
        0x2553 => linesChar(metrics, canvas, .{ .down = .double, .right = .light }),
        0x2554 => linesChar(metrics, canvas, .{ .down = .double, .right = .double }),
        0x2555 => linesChar(metrics, canvas, .{ .down = .light, .left = .double }),
        0x2556 => linesChar(metrics, canvas, .{ .down = .double, .left = .light }),
        0x2557 => linesChar(metrics, canvas, .{ .down = .double, .left = .double }),
        0x2558 => linesChar(metrics, canvas, .{ .up = .light, .right = .double }),
        0x2559 => linesChar(metrics, canvas, .{ .up = .double, .right = .light }),
        0x255A => linesChar(metrics, canvas, .{ .up = .double, .right = .double }),
        0x255B => linesChar(metrics, canvas, .{ .up = .light, .left = .double }),
        0x255C => linesChar(metrics, canvas, .{ .up = .double, .left = .light }),
        0x255D => linesChar(metrics, canvas, .{ .up = .double, .left = .double }),
        0x255E => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .right = .double }),
        0x255F => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .right = .light }),
        0x2560 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .right = .double }),
        0x2561 => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .double }),
        0x2562 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .light }),
        0x2563 => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .double }),
        0x2564 => linesChar(metrics, canvas, .{ .down = .light, .left = .double, .right = .double }),
        0x2565 => linesChar(metrics, canvas, .{ .down = .double, .left = .light, .right = .light }),
        0x2566 => linesChar(metrics, canvas, .{ .down = .double, .left = .double, .right = .double }),
        0x2567 => linesChar(metrics, canvas, .{ .up = .light, .left = .double, .right = .double }),
        0x2568 => linesChar(metrics, canvas, .{ .up = .double, .left = .light, .right = .light }),
        0x2569 => linesChar(metrics, canvas, .{ .up = .double, .left = .double, .right = .double }),
        0x256A => linesChar(metrics, canvas, .{ .up = .light, .down = .light, .left = .double, .right = .double }),
        0x256B => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .light, .right = .light }),
        0x256C => linesChar(metrics, canvas, .{ .up = .double, .down = .double, .left = .double, .right = .double }),

        // Arcs (rounded corners)
        0x256D => try arc(canvas, metrics, .br),
        0x256E => try arc(canvas, metrics, .bl),
        0x256F => try arc(canvas, metrics, .tl),
        0x2570 => try arc(canvas, metrics, .tr),

        // Diagonals
        0x2571 => try diagonal(canvas, metrics, true),
        0x2572 => try diagonal(canvas, metrics, false),
        0x2573 => {
            try diagonal(canvas, metrics, true);
            try diagonal(canvas, metrics, false);
        },

        // Half lines
        0x2574 => linesChar(metrics, canvas, .{ .left = .light }),
        0x2575 => linesChar(metrics, canvas, .{ .up = .light }),
        0x2576 => linesChar(metrics, canvas, .{ .right = .light }),
        0x2577 => linesChar(metrics, canvas, .{ .down = .light }),
        0x2578 => linesChar(metrics, canvas, .{ .left = .heavy }),
        0x2579 => linesChar(metrics, canvas, .{ .up = .heavy }),
        0x257A => linesChar(metrics, canvas, .{ .right = .heavy }),
        0x257B => linesChar(metrics, canvas, .{ .down = .heavy }),
        0x257C => linesChar(metrics, canvas, .{ .left = .light, .right = .heavy }),
        0x257D => linesChar(metrics, canvas, .{ .up = .light, .down = .heavy }),
        0x257E => linesChar(metrics, canvas, .{ .left = .heavy, .right = .light }),
        0x257F => linesChar(metrics, canvas, .{ .up = .heavy, .down = .light }),

        else => {},
    }
}

fn linesChar(metrics: Metrics, canvas: *Canvas, lines: Lines) void {
    const w: i32 = @intCast(metrics.cell_width);
    const h: i32 = @intCast(metrics.cell_height);
    const light_px: i32 = @intCast(Thickness.light.height(metrics.box_thickness));
    const heavy_px: i32 = @intCast(Thickness.heavy.height(metrics.box_thickness));

    // Centered line positions
    const v_light_left: i32 = @divFloor(w - light_px, 2);
    const v_light_right: i32 = v_light_left + light_px;
    const h_light_top: i32 = @divFloor(h - light_px, 2);
    const h_light_bottom: i32 = h_light_top + light_px;

    const v_heavy_left: i32 = @divFloor(w - heavy_px, 2);
    const v_heavy_right: i32 = v_heavy_left + heavy_px;
    const h_heavy_top: i32 = @divFloor(h - heavy_px, 2);
    const h_heavy_bottom: i32 = h_heavy_top + heavy_px;

    // Double line: two light lines with a gap between
    const h_double_top: i32 = h_light_top - light_px;
    const h_double_bottom: i32 = h_light_bottom + light_px;
    const v_double_left: i32 = v_light_left - light_px;
    const v_double_right: i32 = v_light_right + light_px;

    // Calculate where vertical lines should stop based on horizontal connections
    // This handles corners properly for double lines (like Ghostty)
    const up_bottom: i32 = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double)
            h_double_bottom
        else
            h_light_bottom
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    const down_top: i32 = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double)
            h_double_top
        else
            h_light_top
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    // Calculate where horizontal lines should stop based on vertical connections
    const left_right: i32 = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double)
            v_double_right
        else
            v_light_right
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    const right_left: i32 = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double)
            v_double_left
        else
            v_light_left
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    // Draw up segment
    switch (lines.up) {
        .none => {},
        .light => canvas.box(v_light_left, 0, v_light_right, up_bottom, .on),
        .heavy => canvas.box(v_heavy_left, 0, v_heavy_right, up_bottom, .on),
        .double => {
            // For double lines at corners, each line stops at the inner edge
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;
            canvas.box(v_double_left, 0, v_double_left + light_px, left_bottom, .on);
            canvas.box(v_double_right - light_px, 0, v_double_right, right_bottom, .on);
        },
    }

    // Draw down segment
    switch (lines.down) {
        .none => {},
        .light => canvas.box(v_light_left, down_top, v_light_right, h, .on),
        .heavy => canvas.box(v_heavy_left, down_top, v_heavy_right, h, .on),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;
            canvas.box(v_double_left, left_top, v_double_left + light_px, h, .on);
            canvas.box(v_double_right - light_px, right_top, v_double_right, h, .on);
        },
    }

    // Draw left segment
    switch (lines.left) {
        .none => {},
        .light => canvas.box(0, h_light_top, left_right, h_light_bottom, .on),
        .heavy => canvas.box(0, h_heavy_top, left_right, h_heavy_bottom, .on),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;
            canvas.box(0, h_double_top, top_right, h_double_top + light_px, .on);
            canvas.box(0, h_double_bottom - light_px, bottom_right, h_double_bottom, .on);
        },
    }

    // Draw right segment
    switch (lines.right) {
        .none => {},
        .light => canvas.box(right_left, h_light_top, w, h_light_bottom, .on),
        .heavy => canvas.box(right_left, h_heavy_top, w, h_heavy_bottom, .on),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;
            canvas.box(top_left, h_double_top, w, h_double_top + light_px, .on);
            canvas.box(bottom_left, h_double_bottom - light_px, w, h_double_bottom, .on);
        },
    }
}

fn dashHorizontal(metrics: Metrics, canvas: *Canvas, count: u32, thickness: Thickness) void {
    const thick_px: i32 = @intCast(thickness.height(metrics.box_thickness));
    const y: i32 = @divFloor(@as(i32, @intCast(metrics.cell_height)) - thick_px, 2);
    const w: i32 = @intCast(metrics.cell_width);

    // Dashes fill the cell with small gaps between them
    // Gap is 1 pixel (or line thickness, whichever is smaller)
    const n: i32 = @intCast(count);
    const gap: i32 = @min(thick_px, @max(1, @divFloor(w, n * 4)));
    const total_gaps: i32 = (n - 1) * gap;
    const dash_width: i32 = @divFloor(w - total_gaps, n);
    var extra: i32 = w - total_gaps - dash_width * n;

    var x: i32 = 0;
    for (0..count) |_| {
        var dw = dash_width;
        if (extra > 0) {
            dw += 1;
            extra -= 1;
        }
        canvas.box(x, y, x + dw, y + thick_px, .on);
        x += dw + gap;
    }
}

fn dashVertical(metrics: Metrics, canvas: *Canvas, count: u32, thickness: Thickness) void {
    const thick_px: i32 = @intCast(thickness.height(metrics.box_thickness));
    const x: i32 = @divFloor(@as(i32, @intCast(metrics.cell_width)) - thick_px, 2);
    const h: i32 = @intCast(metrics.cell_height);

    // Dashes fill the cell with small gaps between them
    const n: i32 = @intCast(count);
    const gap: i32 = @min(thick_px, @max(1, @divFloor(h, n * 4)));
    const total_gaps: i32 = (n - 1) * gap;
    const dash_height: i32 = @divFloor(h - total_gaps, n);
    var extra: i32 = h - total_gaps - dash_height * n;

    var y: i32 = 0;
    for (0..count) |_| {
        var dh = dash_height;
        if (extra > 0) {
            dh += 1;
            extra -= 1;
        }
        canvas.box(x, y, x + thick_px, y + dh, .on);
        y += dh + gap;
    }
}

const Corner = enum { tl, tr, bl, br };

fn arc(canvas: *Canvas, metrics: Metrics, corner: Corner) !void {
    const thick_px = Thickness.light.height(metrics.box_thickness);
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const center_x: f64 = @as(f64, @floatFromInt((metrics.cell_width -| thick_px) / 2)) + float_thick / 2;
    const center_y: f64 = @as(f64, @floatFromInt((metrics.cell_height -| thick_px) / 2)) + float_thick / 2;

    const r = @min(float_width, float_height) / 2;

    // Fraction away from the center to place the middle control points
    const s: f64 = 0.25;

    var path = canvas.staticPath(4);

    switch (corner) {
        .tl => {
            // ╭ - arc from top to left
            path.moveTo(center_x, 0);
            path.lineTo(center_x, center_y - r);
            path.curveTo(
                center_x,
                center_y - s * r,
                center_x - s * r,
                center_y,
                center_x - r,
                center_y,
            );
            path.lineTo(0, center_y);
        },
        .tr => {
            // ╮ - arc from top to right
            path.moveTo(center_x, 0);
            path.lineTo(center_x, center_y - r);
            path.curveTo(
                center_x,
                center_y - s * r,
                center_x + s * r,
                center_y,
                center_x + r,
                center_y,
            );
            path.lineTo(float_width, center_y);
        },
        .bl => {
            // ╰ - arc from bottom to left
            path.moveTo(center_x, float_height);
            path.lineTo(center_x, center_y + r);
            path.curveTo(
                center_x,
                center_y + s * r,
                center_x - s * r,
                center_y,
                center_x - r,
                center_y,
            );
            path.lineTo(0, center_y);
        },
        .br => {
            // ╯ - arc from bottom to right
            path.moveTo(center_x, float_height);
            path.lineTo(center_x, center_y + r);
            path.curveTo(
                center_x,
                center_y + s * r,
                center_x + s * r,
                center_y,
                center_x + r,
                center_y,
            );
            path.lineTo(float_width, center_y);
        },
    }

    try canvas.strokePath(
        path.wrapped_path,
        .{
            .line_cap_mode = .butt,
            .line_width = float_thick,
        },
        .on,
    );
}

fn diagonal(canvas: *Canvas, metrics: Metrics, upper_right_to_lower_left: bool) !void {
    const w: f64 = @floatFromInt(metrics.cell_width);
    const h: f64 = @floatFromInt(metrics.cell_height);
    const thickness: f64 = @floatFromInt(Thickness.light.height(metrics.box_thickness));

    const l = canvas_mod.Line(f64){
        .p0 = if (upper_right_to_lower_left)
            .{ .x = w, .y = 0 }
        else
            .{ .x = 0, .y = 0 },
        .p1 = if (upper_right_to_lower_left)
            .{ .x = 0, .y = h }
        else
            .{ .x = w, .y = h },
    };

    try canvas.line(l, thickness, .on);
}
