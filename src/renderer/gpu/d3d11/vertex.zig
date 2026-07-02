//! D3D11 vertex-layout placeholder.

const Buffer = @import("Buffer.zig");
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

threadlocal var next_vao: VaoHandle = 1;

pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    _ = layouts;
    const h = next_vao;
    next_vao +%= 1;
    if (next_vao == 0) next_vao = 1;
    return h;
}

pub fn deleteVertexArray(vao: VaoHandle) void {
    _ = vao;
}
