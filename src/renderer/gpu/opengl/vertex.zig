//! Declarative vertex-array builder. Lets callers describe VAO layouts without
//! issuing raw GL ops. Supports multiple buffer sources per VAO (needed by
//! cell_pipeline's bg/fg VAOs that pull attribute 0 from a static quad buffer
//! and instanced attributes from a separate instances buffer).
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Buffer = @import("Buffer.zig");

pub const VaoHandle = c.GLuint;

/// One float vertex attribute. `count` = number of floats (1..4). `divisor` > 0
/// makes it instanced (advances per `divisor` instances).
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

/// Build a VAO binding each layout's buffer and configuring its float attributes.
pub fn buildVertexArray(layouts: []const BufferLayout) VaoHandle {
    const gl = Context.gl;
    var vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &vao);
    gl.BindVertexArray.?(vao);
    for (layouts) |layout| {
        layout.buffer.bind();
        for (layout.attrs) |a| {
            gl.EnableVertexAttribArray.?(a.loc);
            gl.VertexAttribPointer.?(a.loc, @intCast(a.count), c.GL_FLOAT, c.GL_FALSE, @intCast(a.stride), @ptrFromInt(a.offset));
            if (a.divisor > 0) gl.VertexAttribDivisor.?(a.loc, a.divisor);
        }
    }
    gl.BindVertexArray.?(0);
    return vao;
}

pub fn deleteVertexArray(vao: VaoHandle) void {
    var v = vao;
    Context.gl.DeleteVertexArrays.?(1, &v);
}
