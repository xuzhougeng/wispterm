//! D3D11 2D texture wrapper.
//!
//! `handle` is a small registry id. The registry owns the native texture,
//! shader-resource view, and sampler state.

const std = @import("std");

const Context = @import("Context.zig");
const c = @import("c.zig");
const core = @import("../../../platform/dxgi_core.zig");
const types = @import("../types.zig");
const Texture = @This();

handle: c.GLuint,

const max_textures = 8192;

const Entry = struct {
    texture: ?*anyopaque = null,
    srv: ?*anyopaque = null,
    sampler: ?*anyopaque = null,
    width: c_int = 0,
    height: c_int = 0,
    format: types.TextureFormat = .rgba8,
    sampler_mode: types.SamplerMode = .linear_clamp,

    fn releaseNative(self: *Entry) void {
        if (self.sampler) |p| core.comRelease(p);
        if (self.srv) |p| core.comRelease(p);
        if (self.texture) |p| core.comRelease(p);
        self.sampler = null;
        self.srv = null;
        self.texture = null;
        self.width = 0;
        self.height = 0;
    }

    fn release(self: *Entry) void {
        self.releaseNative();
        self.* = .{};
    }
};

threadlocal var next_handle: c.GLuint = 1;
threadlocal var live: [max_textures]bool = @splat(false);
threadlocal var table: [max_textures]Entry = @splat(.{});

fn allocHandle() c.GLuint {
    for (0..max_textures - 1) |_| {
        const h = next_handle;
        next_handle +%= 1;
        if (next_handle == 0 or next_handle >= max_textures) next_handle = 1;
        if (!live[h]) {
            live[h] = true;
            table[h] = .{};
            return h;
        }
    }
    return 0;
}

fn entry(handle: c.GLuint) ?*Entry {
    if (handle == 0 or handle >= max_textures or !live[handle]) return null;
    return &table[handle];
}

pub fn invalid() Texture {
    return .{ .handle = 0 };
}

pub fn isValid(self: Texture) bool {
    return if (entry(self.handle)) |e| e.texture != null else false;
}

pub fn fromHandle(h: c.GLuint) Texture {
    return .{ .handle = h };
}

pub fn bind(self: Texture, unit: u32) void {
    const e = entry(self.handle) orelse return;
    const context = Context.contextHandle() orelse return;
    const slot = std.math.cast(u32, unit) orelse return;
    const ps_set_srv = core.comCall(context, core.slot.D3D11DeviceContext_PSSetShaderResources, *const fn (
        *anyopaque,
        u32,
        u32,
        [*]const ?*anyopaque,
    ) callconv(.winapi) void);
    var srvs = [_]?*anyopaque{e.srv};
    ps_set_srv(context, slot, 1, &srvs);

    const ps_set_samplers = core.comCall(context, core.slot.D3D11DeviceContext_PSSetSamplers, *const fn (
        *anyopaque,
        u32,
        u32,
        [*]const ?*anyopaque,
    ) callconv(.winapi) void);
    var samplers = [_]?*anyopaque{e.sampler};
    ps_set_samplers(context, slot, 1, &samplers);
}

pub const Upload = struct {
    format: types.TextureFormat = .rgba8,
    sampler: types.SamplerMode = .linear_clamp,
    unpack_alignment: ?i32 = null,
};

pub fn create() Texture {
    return .{ .handle = allocHandle() };
}

fn dxgiFormat(format: types.TextureFormat) u32 {
    return switch (format) {
        .r8 => core.DXGI_FORMAT_R8_UNORM,
        .rgba8 => core.DXGI_FORMAT_R8G8B8A8_UNORM,
        .bgra8 => core.DXGI_FORMAT_B8G8R8A8_UNORM,
    };
}

fn bytesPerPixel(format: types.TextureFormat) u32 {
    return switch (format) {
        .r8 => 1,
        .rgba8, .bgra8 => 4,
    };
}

fn samplerDesc(mode: types.SamplerMode) core.D3D11_SAMPLER_DESC {
    const filter = switch (mode) {
        .nearest_clamp => core.D3D11_FILTER_MIN_MAG_MIP_POINT,
        .linear_clamp, .linear_repeat => core.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
    };
    const address = switch (mode) {
        .nearest_clamp, .linear_clamp => core.D3D11_TEXTURE_ADDRESS_CLAMP,
        .linear_repeat => core.D3D11_TEXTURE_ADDRESS_WRAP,
    };
    return .{
        .filter = filter,
        .address_u = address,
        .address_v = address,
        .address_w = address,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .comparison_func = core.D3D11_COMPARISON_NEVER,
        .border_color = .{ 0, 0, 0, 0 },
        .min_lod = 0,
        .max_lod = core.D3D11_FLOAT32_MAX,
    };
}

fn createSampler(e: *Entry, mode: types.SamplerMode) bool {
    const device = Context.deviceHandle() orelse return false;
    const create_sampler = core.comCall(device, core.slot.D3D11Device_CreateSamplerState, *const fn (
        *anyopaque,
        *const core.D3D11_SAMPLER_DESC,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    const desc = samplerDesc(mode);
    var sampler: ?*anyopaque = null;
    if (create_sampler(device, &desc, &sampler) < 0 or sampler == null) return false;
    if (e.sampler) |old| core.comRelease(old);
    e.sampler = sampler;
    e.sampler_mode = mode;
    return true;
}

pub fn upload2D(self: Texture, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.unpack_alignment;
    if (width <= 0 or height <= 0) return;
    const e = entry(self.handle) orelse return;
    const device = Context.deviceHandle() orelse return;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const desc = core.D3D11_TEXTURE2D_DESC{
        .width = w,
        .height = h,
        .mip_levels = 1,
        .array_size = 1,
        .format = dxgiFormat(o.format),
        .sample_desc = .{ .count = 1, .quality = 0 },
        .usage = core.D3D11_USAGE_DEFAULT,
        .bind_flags = core.D3D11_BIND_SHADER_RESOURCE,
        .cpu_access_flags = 0,
        .misc_flags = 0,
    };
    var init_data = core.D3D11_SUBRESOURCE_DATA{
        .sys_mem = data,
        .sys_mem_pitch = w * bytesPerPixel(o.format),
        .sys_mem_slice_pitch = 0,
    };
    const init_ptr: ?*const core.D3D11_SUBRESOURCE_DATA = if (data != null) &init_data else null;
    const create_texture = core.comCall(device, core.slot.D3D11Device_CreateTexture2D, *const fn (
        *anyopaque,
        *const core.D3D11_TEXTURE2D_DESC,
        ?*const core.D3D11_SUBRESOURCE_DATA,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    var texture: ?*anyopaque = null;
    if (create_texture(device, &desc, init_ptr, &texture) < 0 or texture == null) {
        std.debug.print("D3D11 texture upload2D failed ({}x{})\n", .{ width, height });
        return;
    }

    const create_srv = core.comCall(device, core.slot.D3D11Device_CreateShaderResourceView, *const fn (
        *anyopaque,
        *anyopaque,
        ?*const anyopaque,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    var srv: ?*anyopaque = null;
    if (create_srv(device, texture.?, null, &srv) < 0 or srv == null) {
        std.debug.print("D3D11 texture SRV creation failed ({}x{})\n", .{ width, height });
        core.comRelease(texture.?);
        return;
    }

    e.releaseNative();
    e.texture = texture;
    e.srv = srv;
    e.width = width;
    e.height = height;
    e.format = o.format;
    if (!createSampler(e, o.sampler)) {
        std.debug.print("D3D11 sampler creation failed\n", .{});
    }
}

pub fn setSamplerMode(self: Texture, sampler: types.SamplerMode) void {
    const e = entry(self.handle) orelse return;
    if (!createSampler(e, sampler)) {
        std.debug.print("D3D11 sampler update failed\n", .{});
    }
}

pub fn subImage2D(self: Texture, x: c_int, y: c_int, width: c_int, height: c_int, data: ?*const anyopaque, o: Upload) void {
    _ = o.unpack_alignment;
    const e = entry(self.handle) orelse return;
    const context = Context.contextHandle() orelse return;
    if (e.texture == null or data == null or width <= 0 or height <= 0) return;
    if (o.format != e.format or x < 0 or y < 0 or x + width > e.width or y + height > e.height) {
        self.upload2D(width, height, data, o);
        return;
    }
    const box = core.D3D11_BOX{
        .left = @intCast(x),
        .top = @intCast(y),
        .front = 0,
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
        .back = 1,
    };
    const update = core.comCall(context, core.slot.D3D11DeviceContext_UpdateSubresource, *const fn (
        *anyopaque,
        *anyopaque,
        u32,
        ?*const core.D3D11_BOX,
        *const anyopaque,
        u32,
        u32,
    ) callconv(.winapi) void);
    update(context, e.texture.?, 0, &box, data.?, @as(u32, @intCast(width)) * bytesPerPixel(e.format), 0);
}

pub fn levelWidth(self: Texture) c_int {
    return if (entry(self.handle)) |e| e.width else 0;
}

pub fn nativeTexture(handle: c.GLuint) ?*anyopaque {
    return if (entry(handle)) |e| e.texture else null;
}

pub fn nativeSrv(handle: c.GLuint) ?*anyopaque {
    return if (entry(handle)) |e| e.srv else null;
}

pub fn destroy(self: *Texture) void {
    if (entry(self.handle)) |e| {
        e.release();
        live[self.handle] = false;
    }
    self.handle = 0;
}
