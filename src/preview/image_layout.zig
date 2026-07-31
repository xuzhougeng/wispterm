//! Pure layout math for raster preview panes.
//!
//! Image/PDF preview rendering owns decode/upload in the renderer and zoom/pan
//! state in `PreviewPane`; this module only converts image size + viewport size
//! into backend-neutral draw rectangles, scissor boxes, and texture vertices.

const std = @import("std");

pub const Size = struct {
    width: f32,
    height: f32,

    fn valid(self: Size) bool {
        return self.width > 0 and self.height > 0;
    }
};

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Scissor = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Vertex = [4]f32;
pub const Vertices = [6]Vertex;

pub const Input = struct {
    content_x: f32,
    content_width: f32,
    body_top: f32,
    body_height: f32,
    window_height: f32,
    image: Size,
    zoom: f32,
    pan: Point = .{},
};

pub const Layout = struct {
    scale: f32,
    draw: Rect,
    border: Rect,
    scissor: Scissor,
    vertices: Vertices,
    clamped_pan: Point,
};

pub fn drawSize(image: Size, view: Size, zoom: f32) ?Size {
    if (!image.valid() or !view.valid() or zoom <= 0) return null;
    const scale = @min(view.width / image.width, view.height / image.height) * zoom;
    if (scale <= 0) return null;
    return .{ .width = image.width * scale, .height = image.height * scale };
}

pub fn clampPan(view: Size, draw: Size, pan: Point) Point {
    if (!view.valid() or !draw.valid()) return .{};
    const max_x = if (draw.width > view.width) (draw.width - view.width) / 2 else 0;
    const max_y = if (draw.height > view.height) (draw.height - view.height) / 2 else 0;
    return .{
        .x = @max(-max_x, @min(max_x, pan.x)),
        .y = @max(-max_y, @min(max_y, pan.y)),
    };
}

pub fn compute(input: Input) ?Layout {
    if (input.window_height <= 0) return null;

    const view = Size{ .width = input.content_width, .height = input.body_height };
    const draw = drawSize(input.image, view, input.zoom) orelse return null;
    const scale = draw.width / input.image.width;
    const pan = clampPan(view, draw, input.pan);

    const draw_x = input.content_x + (view.width - draw.width) / 2 + pan.x;
    const draw_top = input.body_top + (view.height - draw.height) / 2 + pan.y;
    const draw_y = input.window_height - draw_top - draw.height;
    const rect = Rect{ .x = draw_x, .y = draw_y, .w = draw.width, .h = draw.height };

    const scissor = scissorFor(input.content_x, input.body_top, view, input.window_height) orelse return null;
    return .{
        .scale = scale,
        .draw = rect,
        .border = .{ .x = rect.x - 1, .y = rect.y - 1, .w = rect.w + 2, .h = rect.h + 2 },
        .scissor = scissor,
        .vertices = textureVertices(rect),
        .clamped_pan = pan,
    };
}

pub fn scissorFor(content_x: f32, body_top: f32, view: Size, window_height: f32) ?Scissor {
    if (!view.valid() or window_height <= 0) return null;
    const x: i32 = @intFromFloat(@max(0, @floor(content_x)));
    const y: i32 = @intFromFloat(@max(0, @floor(window_height - body_top - view.height)));
    const w: i32 = @intFromFloat(@max(0, @ceil(view.width)));
    const h: i32 = @intFromFloat(@max(0, @ceil(view.height)));
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn textureVertices(rect: Rect) Vertices {
    return .{
        .{ rect.x, rect.y + rect.h, 0, 0 },
        .{ rect.x, rect.y, 0, 1 },
        .{ rect.x + rect.w, rect.y, 1, 1 },
        .{ rect.x, rect.y + rect.h, 0, 0 },
        .{ rect.x + rect.w, rect.y, 1, 1 },
        .{ rect.x + rect.w, rect.y + rect.h, 1, 0 },
    };
}

fn expectApprox(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

fn expectPoint(actual: Point, expected: Point) !void {
    try expectApprox(actual.x, expected.x);
    try expectApprox(actual.y, expected.y);
}

fn expectRect(actual: Rect, expected: Rect) !void {
    try expectApprox(actual.x, expected.x);
    try expectApprox(actual.y, expected.y);
    try expectApprox(actual.w, expected.w);
    try expectApprox(actual.h, expected.h);
}

test "preview image drawSize fits inside the body and honors zoom" {
    const fitted = drawSize(.{ .width = 400, .height = 200 }, .{ .width = 800, .height = 600 }, 1).?;
    try expectApprox(fitted.width, 800);
    try expectApprox(fitted.height, 400);

    const zoomed = drawSize(.{ .width = 400, .height = 200 }, .{ .width = 800, .height = 600 }, 1.5).?;
    try expectApprox(zoomed.width, 1200);
    try expectApprox(zoomed.height, 600);
}

test "preview image clampPan permits panning only when draw exceeds view" {
    try expectPoint(
        clampPan(.{ .width = 300, .height = 200 }, .{ .width = 200, .height = 100 }, .{ .x = 80, .y = -80 }),
        .{},
    );
    try expectPoint(
        clampPan(.{ .width = 300, .height = 200 }, .{ .width = 700, .height = 500 }, .{ .x = 400, .y = -600 }),
        .{ .x = 200, .y = -150 },
    );
}

test "preview image compute centers fitted images in GL coordinates" {
    const layout = compute(.{
        .content_x = 100,
        .content_width = 800,
        .body_top = 50,
        .body_height = 600,
        .window_height = 800,
        .image = .{ .width = 400, .height = 200 },
        .zoom = 1,
    }).?;

    try expectApprox(layout.scale, 2);
    try expectRect(layout.draw, .{ .x = 100, .y = 250, .w = 800, .h = 400 });
    try expectRect(layout.border, .{ .x = 99, .y = 249, .w = 802, .h = 402 });
    try std.testing.expectEqual(Scissor{ .x = 100, .y = 150, .w = 800, .h = 600 }, layout.scissor);
}

test "preview image compute clamps pan before positioning a zoomed image" {
    const layout = compute(.{
        .content_x = 10,
        .content_width = 200,
        .body_top = 20,
        .body_height = 100,
        .window_height = 300,
        .image = .{ .width = 400, .height = 300 },
        .zoom = 3,
        .pan = .{ .x = 200, .y = -150 },
    }).?;

    try expectApprox(layout.scale, 1);
    try expectPoint(layout.clamped_pan, .{ .x = 100, .y = -100 });
    try expectRect(layout.draw, .{ .x = 10, .y = 180, .w = 400, .h = 300 });
}

test "preview image textureVertices match ui texture quad ordering" {
    const vertices = textureVertices(.{ .x = 10, .y = 20, .w = 30, .h = 40 });
    try std.testing.expectEqual(Vertex{ 10, 60, 0, 0 }, vertices[0]);
    try std.testing.expectEqual(Vertex{ 10, 20, 0, 1 }, vertices[1]);
    try std.testing.expectEqual(Vertex{ 40, 20, 1, 1 }, vertices[2]);
    try std.testing.expectEqual(Vertex{ 10, 60, 0, 0 }, vertices[3]);
    try std.testing.expectEqual(Vertex{ 40, 20, 1, 1 }, vertices[4]);
    try std.testing.expectEqual(Vertex{ 40, 60, 1, 0 }, vertices[5]);
}

test "preview image invalid sizes do not produce layout" {
    try std.testing.expect(drawSize(.{ .width = 0, .height = 20 }, .{ .width = 100, .height = 100 }, 1) == null);
    try std.testing.expect(compute(.{
        .content_x = 0,
        .content_width = 100,
        .body_top = 0,
        .body_height = 100,
        .window_height = 200,
        .image = .{ .width = 10, .height = 10 },
        .zoom = 0,
    }) == null);
}
