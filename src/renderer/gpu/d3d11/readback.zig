//! D3D11 framebuffer readback helpers.

const std = @import("std");

const Context = @import("Context.zig");
const core = @import("../../../platform/dxgi_core.zig");

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0 or x < 0 or y < 0) return error.InvalidReadbackRect;
    const size = Context.swapchainSize() orelse return error.D3D11ReadbackNotAvailable;
    const read_width = std.math.cast(i32, width) orelse return error.InvalidReadbackRect;
    const read_height = std.math.cast(i32, height) orelse return error.InvalidReadbackRect;
    if (x + read_width > size.width or y + read_height > size.height)
        return error.InvalidReadbackRect;
    const device = Context.deviceHandle() orelse return error.D3D11ReadbackNotAvailable;
    const context = Context.contextHandle() orelse return error.D3D11ReadbackNotAvailable;
    const backbuffer = Context.backbufferHandle() orelse return error.D3D11ReadbackNotAvailable;

    const desc = core.D3D11_TEXTURE2D_DESC{
        .width = width,
        .height = height,
        .mip_levels = 1,
        .array_size = 1,
        .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
        .sample_desc = .{ .count = 1, .quality = 0 },
        .usage = core.D3D11_USAGE_STAGING,
        .bind_flags = 0,
        .cpu_access_flags = core.D3D11_CPU_ACCESS_READ,
        .misc_flags = 0,
    };
    const create_texture = core.comCall(device, core.slot.D3D11Device_CreateTexture2D, *const fn (
        *anyopaque,
        *const core.D3D11_TEXTURE2D_DESC,
        ?*const core.D3D11_SUBRESOURCE_DATA,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    var staging: ?*anyopaque = null;
    if (create_texture(device, &desc, null, &staging) < 0 or staging == null)
        return error.D3D11ReadbackNotAvailable;
    defer core.comRelease(staging.?);

    const src_top: u32 = @intCast(size.height - y - read_height);
    const src_box = core.D3D11_BOX{
        .left = @intCast(x),
        .top = src_top,
        .front = 0,
        .right = @intCast(x + read_width),
        .bottom = src_top + height,
        .back = 1,
    };
    const copy_region = core.comCall(context, core.slot.D3D11DeviceContext_CopySubresourceRegion, *const fn (
        *anyopaque,
        *anyopaque,
        u32,
        u32,
        u32,
        u32,
        *anyopaque,
        u32,
        ?*const core.D3D11_BOX,
    ) callconv(.winapi) void);
    copy_region(context, staging.?, 0, 0, 0, 0, backbuffer, 0, &src_box);

    const map = core.comCall(context, core.slot.D3D11DeviceContext_Map, *const fn (
        *anyopaque,
        *anyopaque,
        u32,
        u32,
        u32,
        *core.D3D11_MAPPED_SUBRESOURCE,
    ) callconv(.winapi) core.HRESULT);
    var mapped: core.D3D11_MAPPED_SUBRESOURCE = undefined;
    if (map(context, staging.?, 0, core.D3D11_MAP_READ, 0, &mapped) < 0 or mapped.p_data == null)
        return error.D3D11ReadbackNotAvailable;
    defer {
        const unmap = core.comCall(context, core.slot.D3D11DeviceContext_Unmap, *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void);
        unmap(context, staging.?, 0);
    }

    const pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidReadbackRect;
    const len = std.math.mul(usize, pixels, 4) catch return error.InvalidReadbackRect;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    const src: [*]const u8 = @ptrCast(mapped.p_data.?);
    const row_pitch: usize = mapped.row_pitch;
    const w: usize = width;
    const h: usize = height;
    for (0..h) |row| {
        const src_row = src + row * row_pitch;
        const dst_row_index = h - 1 - row;
        const dst_base = dst_row_index * w * 4;
        for (0..w) |col| {
            const s = src_row + col * 4;
            const d = dst_base + col * 4;
            out[d + 0] = s[2];
            out[d + 1] = s[1];
            out[d + 2] = s[0];
            out[d + 3] = s[3];
        }
    }
    return out;
}
