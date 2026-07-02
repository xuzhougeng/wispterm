//! Pure background-image UV and fullscreen-quad layout math.
//!
//! The renderer owns image loading, GPU texture lifetime, and tint passes. This
//! module only computes backend-neutral vertices so D3D11/OpenGL/Metal can share
//! the same feature geometry through `ui_pipeline.drawTextureQuad`.

const std = @import("std");

pub const Size = struct {
    width: f32,
    height: f32,

    fn valid(self: Size) bool {
        return self.width > 0 and self.height > 0;
    }
};

pub const Uv = struct {
    u_min: f32,
    v_min: f32,
    u_max: f32,
    v_max: f32,
};

pub const Vertex = [4]f32;
pub const Vertices = [6]Vertex;

pub const default_uv = Uv{ .u_min = 0, .v_min = 0, .u_max = 1, .v_max = 1 };

/// Compute UVs for a fullscreen quad given the chosen background image mode.
///
/// `mode` is intentionally `anytype` so the pure helper can stay independent of
/// the full config module while still accepting `Config.BackgroundImageMode`.
pub fn uvForMode(image: Size, viewport: Size, mode: anytype) Uv {
    if (!image.valid() or !viewport.valid()) return default_uv;

    const win_aspect = viewport.width / viewport.height;
    const img_aspect = image.width / image.height;

    switch (mode) {
        .fill => {
            if (img_aspect > win_aspect) {
                const visible = win_aspect / img_aspect;
                const offset = (1.0 - visible) * 0.5;
                return .{ .u_min = offset, .v_min = 0, .u_max = 1.0 - offset, .v_max = 1 };
            } else {
                const visible = img_aspect / win_aspect;
                const offset = (1.0 - visible) * 0.5;
                return .{ .u_min = 0, .v_min = offset, .u_max = 1, .v_max = 1.0 - offset };
            }
        },
        .fit => {
            if (img_aspect > win_aspect) {
                const extra = img_aspect / win_aspect;
                const offset = (1.0 - extra) * 0.5;
                return .{ .u_min = 0, .v_min = offset, .u_max = 1, .v_max = 1.0 - offset };
            } else {
                const extra = win_aspect / img_aspect;
                const offset = (1.0 - extra) * 0.5;
                return .{ .u_min = offset, .v_min = 0, .u_max = 1.0 - offset, .v_max = 1 };
            }
        },
        .center => {
            const u_range = viewport.width / image.width;
            const v_range = viewport.height / image.height;
            const u_off = (1.0 - u_range) * 0.5;
            const v_off = (1.0 - v_range) * 0.5;
            return .{ .u_min = u_off, .v_min = v_off, .u_max = u_off + u_range, .v_max = v_off + v_range };
        },
        .tile => {
            return .{
                .u_min = 0,
                .v_min = 0,
                .u_max = viewport.width / image.width,
                .v_max = viewport.height / image.height,
            };
        },
    }
}

/// Build the two triangles used by `ui_pipeline.drawTextureQuad`.
pub fn fullscreenVertices(viewport: Size, uv: Uv) Vertices {
    const x_lo: f32 = 0;
    const y_lo: f32 = 0;
    const x_hi = viewport.width;
    const y_hi = viewport.height;

    return .{
        .{ x_lo, y_hi, uv.u_min, uv.v_min },
        .{ x_lo, y_lo, uv.u_min, uv.v_max },
        .{ x_hi, y_lo, uv.u_max, uv.v_max },
        .{ x_lo, y_hi, uv.u_min, uv.v_min },
        .{ x_hi, y_lo, uv.u_max, uv.v_max },
        .{ x_hi, y_hi, uv.u_max, uv.v_min },
    };
}

const TestMode = enum { fill, fit, center, tile };

fn expectApprox(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

fn expectUv(actual: Uv, expected: Uv) !void {
    try expectApprox(actual.u_min, expected.u_min);
    try expectApprox(actual.v_min, expected.v_min);
    try expectApprox(actual.u_max, expected.u_max);
    try expectApprox(actual.v_max, expected.v_max);
}

test "background image fill crops the wider image axis" {
    try expectUv(
        uvForMode(.{ .width = 1600, .height = 900 }, .{ .width = 900, .height = 900 }, TestMode.fill),
        .{ .u_min = 0.21875, .v_min = 0, .u_max = 0.78125, .v_max = 1 },
    );
}

test "background image fill crops the taller image axis" {
    try expectUv(
        uvForMode(.{ .width = 900, .height = 1600 }, .{ .width = 1600, .height = 900 }, TestMode.fill),
        .{ .u_min = 0, .v_min = 0.341796875, .u_max = 1, .v_max = 0.658203125 },
    );
}

test "background image fit expands UVs on the padded axis" {
    try expectUv(
        uvForMode(.{ .width = 1600, .height = 900 }, .{ .width = 800, .height = 600 }, TestMode.fit),
        .{ .u_min = 0, .v_min = -0.16666669, .u_max = 1, .v_max = 1.1666667 },
    );
    try expectUv(
        uvForMode(.{ .width = 900, .height = 1600 }, .{ .width = 800, .height = 600 }, TestMode.fit),
        .{ .u_min = -0.6851852, .v_min = 0, .u_max = 1.6851852, .v_max = 1 },
    );
}

test "background image center uses viewport to image pixel ratio" {
    try expectUv(
        uvForMode(.{ .width = 400, .height = 200 }, .{ .width = 200, .height = 100 }, TestMode.center),
        .{ .u_min = 0.25, .v_min = 0.25, .u_max = 0.75, .v_max = 0.75 },
    );
    try expectUv(
        uvForMode(.{ .width = 100, .height = 50 }, .{ .width = 200, .height = 100 }, TestMode.center),
        .{ .u_min = -0.5, .v_min = -0.5, .u_max = 1.5, .v_max = 1.5 },
    );
}

test "background image tile repeats by viewport to image ratio" {
    try expectUv(
        uvForMode(.{ .width = 100, .height = 50 }, .{ .width = 350, .height = 125 }, TestMode.tile),
        .{ .u_min = 0, .v_min = 0, .u_max = 3.5, .v_max = 2.5 },
    );
}

test "background image invalid dimensions use default UVs" {
    try expectUv(
        uvForMode(.{ .width = 0, .height = 50 }, .{ .width = 350, .height = 125 }, TestMode.fill),
        default_uv,
    );
    try expectUv(
        uvForMode(.{ .width = 100, .height = 50 }, .{ .width = 0, .height = 125 }, TestMode.tile),
        default_uv,
    );
}

test "background image fullscreen vertices match ui texture quad ordering" {
    const vertices = fullscreenVertices(
        .{ .width = 320, .height = 200 },
        .{ .u_min = 0.1, .v_min = 0.2, .u_max = 0.9, .v_max = 0.8 },
    );

    try std.testing.expectEqual(Vertex{ 0, 200, 0.1, 0.2 }, vertices[0]);
    try std.testing.expectEqual(Vertex{ 0, 0, 0.1, 0.8 }, vertices[1]);
    try std.testing.expectEqual(Vertex{ 320, 0, 0.9, 0.8 }, vertices[2]);
    try std.testing.expectEqual(Vertex{ 0, 200, 0.1, 0.2 }, vertices[3]);
    try std.testing.expectEqual(Vertex{ 320, 0, 0.9, 0.8 }, vertices[4]);
    try std.testing.expectEqual(Vertex{ 320, 200, 0.9, 0.2 }, vertices[5]);
}
