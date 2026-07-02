//! D3D11 vertex-layout registry.
//!
//! D3D11 input layouts are created against shader bytecode, so this module
//! records the backend-neutral VAO description and `Pipeline.init` turns it
//! into a native `ID3D11InputLayout`.

const Buffer = @import("Buffer.zig");
const c = @import("c.zig");
const types = @import("../types.zig");

pub const VaoHandle = types.VertexArrayHandle;

pub const VertexAttr = struct {
    loc: u32,
    count: u32,
    stride: usize,
    offset: usize,
    divisor: u32 = 0,
};

pub const BufferLayout = struct {
    buffer: Buffer,
    attrs: []const VertexAttr,
};

pub const StoredAttr = struct {
    loc: u32,
    count: u32,
    stride: usize,
    offset: usize,
    divisor: u32,
    slot: u32,
};

const max_layouts = 4096;
const max_buffers_per_layout = 8;
const max_attrs_per_layout = 16;

pub const Layout = struct {
    buffers: [max_buffers_per_layout]c.GLuint = @splat(0),
    strides: [max_buffers_per_layout]u32 = @splat(0),
    buffer_count: u8 = 0,
    attrs: [max_attrs_per_layout]StoredAttr = @splat(.{
        .loc = 0,
        .count = 0,
        .stride = 0,
        .offset = 0,
        .divisor = 0,
        .slot = 0,
    }),
    attr_count: u8 = 0,
};

threadlocal var next_handle: VaoHandle = 1;
threadlocal var live: [max_layouts]bool = @splat(false);
threadlocal var layout_table: [max_layouts]Layout = @splat(.{});

pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    for (0..max_layouts - 1) |_| {
        const handle = next_handle;
        next_handle +%= 1;
        if (next_handle == 0 or next_handle >= max_layouts) next_handle = 1;
        if (!live[handle]) {
            live[handle] = true;
            var stored: Layout = .{};
            const buffer_count = @min(layouts.len, max_buffers_per_layout);
            var attr_index: usize = 0;
            for (layouts[0..buffer_count], 0..) |buffer_layout, slot| {
                stored.buffers[slot] = buffer_layout.buffer.handle;
                if (buffer_layout.attrs.len > 0) stored.strides[slot] = @intCast(buffer_layout.attrs[0].stride);
                for (buffer_layout.attrs) |a| {
                    if (attr_index >= max_attrs_per_layout) break;
                    stored.attrs[attr_index] = .{
                        .loc = a.loc,
                        .count = a.count,
                        .stride = a.stride,
                        .offset = a.offset,
                        .divisor = a.divisor,
                        .slot = @intCast(slot),
                    };
                    attr_index += 1;
                }
            }
            stored.buffer_count = @intCast(buffer_count);
            stored.attr_count = @intCast(attr_index);
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

pub fn layout(vao: VaoHandle) ?*const Layout {
    if (vao == 0 or vao >= max_layouts or !live[vao]) return null;
    return &layout_table[vao];
}

pub fn bufferHandle(vao: VaoHandle, index: usize) c.GLuint {
    const l = layout(vao) orelse return 0;
    if (index >= l.buffer_count) return 0;
    return l.buffers[index];
}

pub fn bufferCount(vao: VaoHandle) u8 {
    const l = layout(vao) orelse return 0;
    return l.buffer_count;
}
