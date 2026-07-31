//! D3D11 vertex-layout registry.
//!
//! D3D11 input layouts are created against shader bytecode, so this module
//! records the backend-neutral VAO description and `Pipeline.init` turns it
//! into a native `ID3D11InputLayout`.

const std = @import("std");
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

const Registry = struct {
    next_handle: VaoHandle = 1,
    live: [max_layouts]bool = @splat(false),
    layout_table: [max_layouts]Layout = @splat(.{}),
};

// Heap-allocated on first use. As plain `threadlocal` arrays this table lived
// in the module's TLS template, which Windows commits per thread — every
// thread in the process paid ~2.3 MB for a table only render threads touch.
threadlocal var registry: ?*Registry = null;

fn ensureRegistry() ?*Registry {
    if (registry == null) {
        const r = std.heap.page_allocator.create(Registry) catch return null;
        r.* = .{};
        registry = r;
    }
    return registry;
}

/// Free this thread's registry storage (window-thread teardown).
pub fn releaseRegistry() void {
    if (registry) |r| {
        std.heap.page_allocator.destroy(r);
        registry = null;
    }
}

pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    const r = ensureRegistry() orelse return 0;
    for (0..max_layouts - 1) |_| {
        const handle = r.next_handle;
        r.next_handle +%= 1;
        if (r.next_handle == 0 or r.next_handle >= max_layouts) r.next_handle = 1;
        if (!r.live[handle]) {
            r.live[handle] = true;
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
            r.layout_table[handle] = stored;
            return handle;
        }
    }
    return 0;
}

pub fn deleteVertexArray(vao: VaoHandle) void {
    const r = registry orelse return;
    if (vao > 0 and vao < max_layouts) {
        r.live[vao] = false;
        r.layout_table[vao] = .{};
    }
}

pub fn layout(vao: VaoHandle) ?*const Layout {
    const r = registry orelse return null;
    if (vao == 0 or vao >= max_layouts or !r.live[vao]) return null;
    return &r.layout_table[vao];
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
