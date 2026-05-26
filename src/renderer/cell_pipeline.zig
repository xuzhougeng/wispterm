//! Cell-grid render pipelines (bg / fg / color-emoji). Cell-specific
//! presentation, built from the gpu backend primitives + the backend GLSL.
//! Relocated from gl_init.initInstancedBuffers (A3). The vertex-attribute
//! layout matches the CellBg/CellFg memory layout exactly.
const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const Renderer = @import("Renderer.zig");
const gpu = AppWindow.gpu;
const c = gpu.c;

const Pipeline = gpu.Pipeline;
const Buffer = gpu.Buffer;

pub threadlocal var bg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var fg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var color_fg: Pipeline = .{ .program = 0, .vao = 0 };

pub threadlocal var bg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var color_fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };

/// Build the cell pipelines. Call once after the GL context is current.
/// On shader link failure a pipeline's `program` is 0 (draws are guarded on
/// `program != 0`); its VAO is still owned and released by `deinit()`.
pub fn init() void {
    const shaders = gpu.shaders;

    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
    };
    quad = Buffer.init(c.GL_ARRAY_BUFFER);
    quad.uploadData(std.mem.sliceAsBytes(quad_verts[0..]), c.GL_STATIC_DRAW);

    // --- BG VAO ---
    // attr 0 (loc=0, count=2): position xy from quad buffer (divisor=0)
    // attr 1 (loc=1, count=2): grid_col/grid_row from bg_instances (divisor=1)
    // attr 2 (loc=2, count=3): r/g/b from bg_instances (divisor=1)
    // attr 3 (loc=3, count=1): alpha from bg_instances (divisor=1)
    bg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    bg_instances.allocate(@sizeOf(Renderer.CellBg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const bg_stride = @sizeOf(Renderer.CellBg);
    const bg_vao = gpu.vertex.buildVertexArray(&.{
        .{
            .buffer = quad,
            .attrs = &.{
                .{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 },
            },
        },
        .{
            .buffer = bg_instances,
            .attrs = &.{
                .{ .loc = 1, .count = 2, .stride = bg_stride, .offset = 0,                  .divisor = 1 },
                .{ .loc = 2, .count = 3, .stride = bg_stride, .offset = 2 * @sizeOf(f32),   .divisor = 1 },
                .{ .loc = 3, .count = 1, .stride = bg_stride, .offset = 5 * @sizeOf(f32),   .divisor = 1 },
            },
        },
    });

    // --- FG VAO ---
    // attr 0 (loc=0, count=2): position xy from quad buffer (divisor=0)
    // attr 1 (loc=1, count=2): grid_col/grid_row (divisor=1)
    // attr 2 (loc=2, count=4): glyph_x/y/w/h (divisor=1)
    // attr 3 (loc=3, count=4): uv_left/top/right/bottom (divisor=1)
    // attr 4 (loc=4, count=3): r/g/b (divisor=1)
    fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const fg_stride = @sizeOf(Renderer.CellFg);
    const fg_vao = gpu.vertex.buildVertexArray(&.{
        .{
            .buffer = quad,
            .attrs = &.{
                .{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 },
            },
        },
        .{
            .buffer = fg_instances,
            .attrs = &.{
                .{ .loc = 1, .count = 2, .stride = fg_stride, .offset = 0,                   .divisor = 1 },
                .{ .loc = 2, .count = 4, .stride = fg_stride, .offset = 2  * @sizeOf(f32),   .divisor = 1 },
                .{ .loc = 3, .count = 4, .stride = fg_stride, .offset = 6  * @sizeOf(f32),   .divisor = 1 },
                .{ .loc = 4, .count = 3, .stride = fg_stride, .offset = 10 * @sizeOf(f32),   .divisor = 1 },
            },
        },
    });

    // --- Color FG VAO (same layout as FG) ---
    color_fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    color_fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const color_fg_stride = @sizeOf(Renderer.CellFg); // same CellFg layout as fg
    const color_fg_vao = gpu.vertex.buildVertexArray(&.{
        .{
            .buffer = quad,
            .attrs = &.{
                .{ .loc = 0, .count = 2, .stride = 2 * @sizeOf(f32), .offset = 0 },
            },
        },
        .{
            .buffer = color_fg_instances,
            .attrs = &.{
                .{ .loc = 1, .count = 2, .stride = color_fg_stride, .offset = 0,                   .divisor = 1 },
                .{ .loc = 2, .count = 4, .stride = color_fg_stride, .offset = 2  * @sizeOf(f32),   .divisor = 1 },
                .{ .loc = 3, .count = 4, .stride = color_fg_stride, .offset = 6  * @sizeOf(f32),   .divisor = 1 },
                .{ .loc = 4, .count = 3, .stride = color_fg_stride, .offset = 10 * @sizeOf(f32),   .divisor = 1 },
            },
        },
    });

    bg = Pipeline.init(shaders.bg_vertex_source, shaders.bg_fragment_source, bg_vao);
    fg = Pipeline.init(shaders.fg_vertex_source, shaders.fg_fragment_source, fg_vao);
    color_fg = Pipeline.init(shaders.fg_vertex_source, shaders.color_fg_fragment_source, color_fg_vao);
    if (bg.program == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg.program == 0) std.debug.print("FG instanced shader failed\n", .{});
    if (color_fg.program == 0) std.debug.print("Color FG instanced shader failed\n", .{});
}

pub fn deinit() void {
    bg.deinit();
    fg.deinit();
    color_fg.deinit();
    bg_instances.deinit();
    fg_instances.deinit();
    color_fg_instances.deinit();
    quad.deinit();
}
