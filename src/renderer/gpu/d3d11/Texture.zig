//! Compile-safe D3D11 texture placeholder for Phase II.

const c = @import("c.zig");
const types = @import("../types.zig");
const Texture = @This();

handle: c.GLuint,

threadlocal var next_handle: c.GLuint = 1;

fn allocHandle() c.GLuint {
    const h = next_handle;
    next_handle +%= 1;
    if (next_handle == 0) next_handle = 1;
    return h;
}

pub fn invalid() Texture {
    return .{ .handle = 0 };
}

pub fn isValid(self: Texture) bool {
    return self.handle != 0;
}

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}

pub fn bind(self: Texture, unit: u32) void {
    _ = self;
    _ = unit;
}

pub const Upload = struct {
    format: types.TextureFormat = .rgba8,
    sampler: types.SamplerMode = .linear_clamp,
    unpack_alignment: ?i32 = null,
};

pub fn create() Texture {
    return .{ .handle = allocHandle() };
}

pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = self;
    _ = width;
    _ = height;
    _ = data;
    _ = o;
}

pub fn setSamplerMode(self: Texture, sampler: types.SamplerMode) void {
    _ = self;
    _ = sampler;
}

pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = self;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = data;
    _ = o;
}

pub fn levelWidth(self: Texture) c_int {
    return if (self.handle == 0) 0 else std.math.maxInt(c_int);
}

pub fn destroy(self: *Texture) void {
    self.handle = 0;
}

const std = @import("std");
