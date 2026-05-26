//! Metal backend declarative vertex-array builder. Mirrors
//! `gpu/opengl/vertex.zig`'s public surface: the `VaoHandle` type, the
//! `VertexAttr`/`BufferLayout` structs (same public fields callers populate),
//! and `buildVertexArray`/`deleteVertexArray`. D-prep STUB: the build/delete
//! bodies `@panic("metal: TODO D1")`. A real backend translates a layout into
//! an `MTLVertexDescriptor` + a buffer-binding table.
const c = @import("c.zig");
const Buffer = @import("Buffer.zig");

pub const VaoHandle = c.GLuint;

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

/// Build a vertex-array binding from the layouts. STUB.
pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    _ = layouts;
    @panic("metal: TODO D1 — vertex.buildVertexArray (build MTLVertexDescriptor)");
}

pub fn deleteVertexArray(vao: VaoHandle) void {
    _ = vao;
}
