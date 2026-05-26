//! Metal backend GPU buffer. Mirrors `gpu/opengl/Buffer.zig`'s public surface.
//! D-prep STUB: same public fields (`handle`, `target`) + same method
//! signatures; bodies are `@panic("metal: TODO D1")`. A real backend will back
//! `handle` with an `MTLBuffer` (or an index into a buffer pool).
const c = @import("c.zig");
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,

pub fn init(target: c.GLenum) Buffer {
    _ = target;
    @panic("metal: TODO D1 — Buffer.init (allocate MTLBuffer)");
}
pub fn bind(self: Buffer) void {
    _ = self;
    @panic("metal: TODO D1 — Buffer.bind");
}
/// Allocate `size` bytes of uninitialized storage with the given usage hint.
pub fn allocate(self: Buffer, size: usize, usage: c.GLenum) void {
    _ = self;
    _ = size;
    _ = usage;
    @panic("metal: TODO D1 — Buffer.allocate");
}
/// Allocate + fill with `bytes`.
pub fn uploadData(self: Buffer, bytes: []const u8, usage: c.GLenum) void {
    _ = self;
    _ = bytes;
    _ = usage;
    @panic("metal: TODO D1 — Buffer.uploadData");
}
/// Overwrite from offset 0.
pub fn upload(self: Buffer, bytes: []const u8) void {
    _ = self;
    _ = bytes;
    @panic("metal: TODO D1 — Buffer.upload");
}
pub fn deinit(self: *Buffer) void {
    self.handle = 0;
}
