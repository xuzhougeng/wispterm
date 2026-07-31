//! Metal backend declarative vertex-array builder. Mirrors
//! `gpu/opengl/vertex.zig`'s public surface: the `VaoHandle` type, the
//! `VertexAttr`/`BufferLayout` structs (same public fields callers populate),
//! and `buildVertexArray`/`deleteVertexArray`. The handle is a backend layout
//! id; the render encoder consumes the stored layout as D1 grows.
const c = @import("c.zig");
const Buffer = @import("Buffer.zig");
const types = @import("../types.zig");

pub const VaoHandle = types.VertexArrayHandle;

/// One float vertex attribute (same public fields as the OpenGL backend).
pub const VertexAttr = struct {
    loc: u32,
    count: u32,
    stride: usize,
    offset: usize,
    divisor: u32 = 0,
};

/// A buffer + the attributes sourced from it.
pub const BufferLayout = struct {
    buffer: Buffer,
    attrs: []const VertexAttr,
};

const max_layouts = 4096;
const max_buffers_per_layout = 2;
const Layout = struct {
    buffers: [max_buffers_per_layout]c.GLuint = @splat(0),
    count: u8 = 0,
};
threadlocal var next_handle: VaoHandle = 1;
threadlocal var live: [max_layouts]bool = @splat(false);
threadlocal var layout_table: [max_layouts]Layout = @splat(.{});

/// Build a vertex-array binding from the layouts.
pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    for (0..max_layouts - 1) |_| {
        const handle = next_handle;
        next_handle +%= 1;
        if (next_handle == 0 or next_handle >= max_layouts) next_handle = 1;
        if (!live[handle]) {
            live[handle] = true;
            var stored: Layout = .{};
            const count = @min(layouts.len, max_buffers_per_layout);
            for (layouts[0..count], 0..) |layout, i| {
                stored.buffers[i] = layout.buffer.handle;
            }
            stored.count = @intCast(count);
            layout_table[handle] = stored;
            return handle;
        }
    }
    return 0;
}

pub fn deleteVertexArray(vao: VaoHandle) void {
    if (vao > 0 and vao < max_layouts) {
        live[vao] = false;
        layout_table[vao] = .{};
    }
}

pub fn bufferHandle(vao: VaoHandle, index: usize) c.GLuint {
    if (vao == 0 or vao >= max_layouts or index >= max_buffers_per_layout) return 0;
    return layout_table[vao].buffers[index];
}

pub fn bufferCount(vao: VaoHandle) u8 {
    if (vao == 0 or vao >= max_layouts) return 0;
    return layout_table[vao].count;
}
