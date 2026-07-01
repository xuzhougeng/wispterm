//! Backend-neutral GPU vocabulary owned by WispTerm.
//!
//! These types describe renderer intent. Backend-specific constants
//! (OpenGL/Metal/D3D11/DXGI) are mapped only inside each backend.

const std = @import("std");

pub const PrimitiveTopology = enum {
    triangles,
    triangle_strip,
};

pub const BufferUsage = enum {
    static,
    dynamic,
    stream,
};

pub const TextureFormat = enum {
    r8,
    rgba8,
    bgra8,
};

pub const TextureUsage = enum {
    sampled,
    render_target,
    readback,
};

pub const BlendMode = enum {
    alpha,
    premultiplied,
};

pub const BlendFactor = enum {
    zero,
    one,
    src_alpha,
    one_minus_src_alpha,
    unknown,
};

pub const ProgramHandle = u32;
pub const VertexArrayHandle = u32;

pub const SamplerMode = enum {
    nearest_clamp,
    linear_clamp,
    linear_repeat,
};

pub const Viewport = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Scissor = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const ClearColor = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const DriverInfo = struct {
    vendor: []const u8,
    renderer: []const u8,
    version: []const u8,
    shading_language: []const u8,
};

pub const BlendSnapshot = struct {
    enabled: bool,
    src_rgb: BlendFactor,
    dst_rgb: BlendFactor,
    src_alpha: BlendFactor,
    dst_alpha: BlendFactor,
};

pub const SwapDiagnostics = struct {
    viewport: Viewport,
    blend: BlendSnapshot,
};

test "phase 1 gpu vocabulary exposes backend-neutral renderer intent" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(PrimitiveTopology).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(BufferUsage).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(TextureFormat).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(TextureUsage).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(BlendMode).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(BlendFactor).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(SamplerMode).@"enum".fields.len);
    try std.testing.expectEqualStrings("triangle_strip", @tagName(PrimitiveTopology.triangle_strip));
    try std.testing.expectEqualStrings("stream", @tagName(BufferUsage.stream));
    try std.testing.expectEqualStrings("bgra8", @tagName(TextureFormat.bgra8));
    try std.testing.expectEqualStrings("render_target", @tagName(TextureUsage.render_target));
    try std.testing.expectEqualStrings("premultiplied", @tagName(BlendMode.premultiplied));
    try std.testing.expectEqualStrings("one_minus_src_alpha", @tagName(BlendFactor.one_minus_src_alpha));
    try std.testing.expectEqualStrings("linear_repeat", @tagName(SamplerMode.linear_repeat));
    try std.testing.expectEqual(@as(ProgramHandle, 0), @as(ProgramHandle, 0));
    try std.testing.expectEqual(@as(VertexArrayHandle, 0), @as(VertexArrayHandle, 0));
    try std.testing.expectEqual(Viewport{ .x = 1, .y = 2, .w = 3, .h = 4 }, Viewport{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(Scissor{ .x = 1, .y = 2, .w = 3, .h = 4 }, Scissor{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(ClearColor{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 }, ClearColor{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 });
    try std.testing.expectEqual(Viewport{ .x = 0, .y = 0, .w = 80, .h = 24 }, (SwapDiagnostics{
        .viewport = .{ .x = 0, .y = 0, .w = 80, .h = 24 },
        .blend = .{
            .enabled = true,
            .src_rgb = .src_alpha,
            .dst_rgb = .one_minus_src_alpha,
            .src_alpha = .src_alpha,
            .dst_alpha = .one_minus_src_alpha,
        },
    }).viewport);
}
