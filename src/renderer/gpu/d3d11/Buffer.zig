//! D3D11 GPU buffer wrapper.
//!
//! The public `handle` is a small WispTerm registry id so renderer code can
//! keep the same backend-neutral shape as OpenGL/Metal. The registry owns the
//! native `ID3D11Buffer`.

const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const core = @import("../../../platform/dxgi_core.zig");
const types = @import("../types.zig");
const Buffer = @This();

handle: c.GLuint = 0,
target: c.GLenum,

const max_buffers = 8192;

const Entry = struct {
    ptr: ?*anyopaque = null,
    target: c.GLenum = 0,
    len: usize = 0,
    usage: types.BufferUsage = .dynamic,

    fn release(self: *Entry) void {
        if (self.ptr) |p| core.comRelease(p);
        self.* = .{};
    }
};

threadlocal var next_handle: c.GLuint = 1;
threadlocal var live: [max_buffers]bool = @splat(false);
threadlocal var table: [max_buffers]Entry = @splat(.{});

fn allocHandle() c.GLuint {
    for (0..max_buffers - 1) |_| {
        const h = next_handle;
        next_handle +%= 1;
        if (next_handle == 0 or next_handle >= max_buffers) next_handle = 1;
        if (!live[h]) {
            live[h] = true;
            table[h] = .{};
            return h;
        }
    }
    return 0;
}

fn entry(handle: c.GLuint) ?*Entry {
    if (handle == 0 or handle >= max_buffers or !live[handle]) return null;
    return &table[handle];
}

fn initTarget(target: c.GLenum) Buffer {
    const handle = allocHandle();
    if (entry(handle)) |e| e.target = target;
    return .{ .handle = handle, .target = target };
}

pub fn initVertex() Buffer {
    return initTarget(c.GL_ARRAY_BUFFER);
}

fn usageDesc(usage: types.BufferUsage) struct { usage: u32, cpu: u32 } {
    return switch (usage) {
        .static => .{ .usage = core.D3D11_USAGE_DEFAULT, .cpu = 0 },
        .dynamic, .stream => .{ .usage = core.D3D11_USAGE_DYNAMIC, .cpu = core.D3D11_CPU_ACCESS_WRITE },
    };
}

fn checkedByteWidth(size: usize) ?u32 {
    if (size == 0) return null;
    return std.math.cast(u32, size);
}

fn createNativeBuffer(e: *Entry, size: usize, usage: types.BufferUsage, initial: ?[]const u8) bool {
    const device = Context.deviceHandle() orelse return false;
    const byte_width = checkedByteWidth(size) orelse return false;
    const desc_usage = usageDesc(usage);
    const desc = core.D3D11_BUFFER_DESC{
        .byte_width = byte_width,
        .usage = desc_usage.usage,
        .bind_flags = core.D3D11_BIND_VERTEX_BUFFER,
        .cpu_access_flags = desc_usage.cpu,
        .misc_flags = 0,
        .structure_byte_stride = 0,
    };
    var init_data = core.D3D11_SUBRESOURCE_DATA{
        .sys_mem = if (initial) |bytes| bytes.ptr else null,
        .sys_mem_pitch = 0,
        .sys_mem_slice_pitch = 0,
    };
    const init_ptr: ?*const core.D3D11_SUBRESOURCE_DATA = if (initial != null) &init_data else null;
    const create_buffer = core.comCall(device, core.slot.D3D11Device_CreateBuffer, *const fn (
        *anyopaque,
        *const core.D3D11_BUFFER_DESC,
        ?*const core.D3D11_SUBRESOURCE_DATA,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);

    var out: ?*anyopaque = null;
    if (create_buffer(device, &desc, init_ptr, &out) < 0 or out == null) return false;

    if (e.ptr) |old| core.comRelease(old);
    e.ptr = out;
    e.len = size;
    e.usage = usage;
    return true;
}

pub fn bind(self: Buffer) void {
    _ = self;
    // D3D11 binds buffers as part of the VAO/pipeline draw call.
}

/// Allocate `size` bytes of uninitialized storage with the given usage hint.
pub fn allocate(self: Buffer, size: usize, usage: types.BufferUsage) void {
    const e = entry(self.handle) orelse return;
    e.target = self.target;
    if (!createNativeBuffer(e, size, usage, null)) {
        std.debug.print("D3D11 buffer allocate failed ({} bytes)\n", .{size});
    }
}

/// Allocate + fill with `bytes`.
pub fn uploadData(self: Buffer, bytes: []const u8, usage: types.BufferUsage) void {
    const e = entry(self.handle) orelse return;
    e.target = self.target;
    if (bytes.len == 0) return;
    if (!createNativeBuffer(e, bytes.len, usage, bytes)) {
        std.debug.print("D3D11 buffer uploadData failed ({} bytes)\n", .{bytes.len});
    }
}

/// Overwrite from offset 0.
pub fn upload(self: Buffer, bytes: []const u8) void {
    const e = entry(self.handle) orelse return;
    if (bytes.len == 0) return;
    if (e.ptr == null or bytes.len > e.len) {
        if (!createNativeBuffer(e, bytes.len, e.usage, bytes)) {
            std.debug.print("D3D11 buffer upload recreate failed ({} bytes)\n", .{bytes.len});
        }
        return;
    }

    const context = Context.contextHandle() orelse return;
    if (e.usage == .dynamic or e.usage == .stream) {
        const map = core.comCall(context, core.slot.D3D11DeviceContext_Map, *const fn (
            *anyopaque,
            *anyopaque,
            u32,
            u32,
            u32,
            *core.D3D11_MAPPED_SUBRESOURCE,
        ) callconv(.winapi) core.HRESULT);
        var mapped: core.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (map(context, e.ptr.?, 0, core.D3D11_MAP_WRITE_DISCARD, 0, &mapped) >= 0 and mapped.p_data != null) {
            const dst: [*]u8 = @ptrCast(mapped.p_data.?);
            @memcpy(dst[0..bytes.len], bytes);
            const unmap = core.comCall(context, core.slot.D3D11DeviceContext_Unmap, *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void);
            unmap(context, e.ptr.?, 0);
            return;
        }
    }

    const update = core.comCall(context, core.slot.D3D11DeviceContext_UpdateSubresource, *const fn (
        *anyopaque,
        *anyopaque,
        u32,
        ?*const core.D3D11_BOX,
        *const anyopaque,
        u32,
        u32,
    ) callconv(.winapi) void);
    update(context, e.ptr.?, 0, null, bytes.ptr, 0, 0);
}

pub fn byteLength(self: Buffer) usize {
    return if (entry(self.handle)) |e| e.len else 0;
}

pub fn nativeHandle(handle: c.GLuint) ?*anyopaque {
    return if (entry(handle)) |e| e.ptr else null;
}

pub fn deinit(self: *Buffer) void {
    if (entry(self.handle)) |e| {
        e.release();
        live[self.handle] = false;
    }
    self.* = .{ .handle = 0, .target = self.target };
}
