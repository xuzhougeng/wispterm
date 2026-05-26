//! A 2D GPU texture. This increment wraps an existing handle for binding only;
//! ownership/upload of the font atlas is taken over in A4.
const Context = @import("Context.zig");
const c = @import("c.zig").c;
const Texture = @This();

handle: c.GLuint,

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}
pub fn bind(self: Texture, unit: u32) void {
    Context.gl.ActiveTexture.?(c.GL_TEXTURE0 + unit);
    Context.gl.BindTexture.?(c.GL_TEXTURE_2D, self.handle);
}
