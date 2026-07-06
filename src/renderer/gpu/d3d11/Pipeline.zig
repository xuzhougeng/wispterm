//! D3D11 render pipeline wrapper.

const std = @import("std");

const Buffer = @import("Buffer.zig");
const Context = @import("Context.zig");
const c = @import("c.zig");
const core = @import("../../../platform/dxgi_core.zig");
const render_state = @import("render_state.zig");
const types = @import("../types.zig");
const vertex = @import("vertex.zig");
const Pipeline = @This();

program: types.ProgramHandle,
vao: types.VertexArrayHandle,

pub threadlocal var pre_use_hook: ?*const fn (program: types.ProgramHandle) void = null;

const max_programs = 4096;

const Uniforms = extern struct {
    projection: [16]f32 = identity_projection,
    text_color: [4]f32 = .{ 1, 1, 1, 1 },
    overlay_color: [4]f32 = .{ 1, 1, 1, 1 },
    cell_size_grid_offset: [4]f32 = .{ 0, 0, 0, 0 },
    scalars: [4]f32 = .{ 0, 1, 0, 0 },
};

const identity_projection = [16]f32{
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

const Entry = struct {
    vertex_shader: ?*anyopaque = null,
    pixel_shader: ?*anyopaque = null,
    input_layout: ?*anyopaque = null,
    constant_buffer: ?*anyopaque = null,
    vao: types.VertexArrayHandle = 0,
    uniforms: Uniforms = .{},

    fn release(self: *Entry) void {
        if (self.constant_buffer) |p| core.comRelease(p);
        if (self.input_layout) |p| core.comRelease(p);
        if (self.pixel_shader) |p| core.comRelease(p);
        if (self.vertex_shader) |p| core.comRelease(p);
        self.* = .{};
    }
};

const Registry = struct {
    next_program: types.ProgramHandle = 1,
    live: [max_programs]bool = @splat(false),
    table: [max_programs]Entry = @splat(.{}),
};

// Heap-allocated on first use so the table stays out of the TLS template
// (Windows commits the full template per thread; see vertex.zig).
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

fn allocProgram() types.ProgramHandle {
    const r = ensureRegistry() orelse return 0;
    for (0..max_programs - 1) |_| {
        const h = r.next_program;
        r.next_program +%= 1;
        if (r.next_program == 0 or r.next_program >= max_programs) r.next_program = 1;
        if (!r.live[h]) {
            r.live[h] = true;
            r.table[h] = .{};
            return h;
        }
    }
    return 0;
}

fn entry(handle: types.ProgramHandle) ?*Entry {
    const r = registry orelse return null;
    if (handle == 0 or handle >= max_programs or !r.live[handle]) return null;
    return &r.table[handle];
}

pub fn init(vs_src: [*c]const u8, fs_src: [*c]const u8, vao: types.VertexArrayHandle) Pipeline {
    const device = Context.deviceHandle() orelse return .{ .program = 0, .vao = vao };
    const vs_blob = Context.compileShaderBlob(std.mem.span(vs_src), "vs_main", "vs_4_0") catch |err| {
        std.debug.print("D3D11 vertex shader compile failed: {s}\n", .{@errorName(err)});
        return .{ .program = 0, .vao = vao };
    };
    defer core.comRelease(vs_blob);
    const ps_blob = Context.compileShaderBlob(std.mem.span(fs_src), "ps_main", "ps_4_0") catch |err| {
        std.debug.print("D3D11 pixel shader compile failed: {s}\n", .{@errorName(err)});
        return .{ .program = 0, .vao = vao };
    };
    defer core.comRelease(ps_blob);

    const handle = allocProgram();
    if (handle == 0) return .{ .program = 0, .vao = vao };
    const e = entry(handle).?;

    const create_vs = core.comCall(device, core.slot.D3D11Device_CreateVertexShader, *const fn (*anyopaque, *const anyopaque, usize, ?*anyopaque, *?*anyopaque) callconv(.winapi) core.HRESULT);
    const create_ps = core.comCall(device, core.slot.D3D11Device_CreatePixelShader, *const fn (*anyopaque, *const anyopaque, usize, ?*anyopaque, *?*anyopaque) callconv(.winapi) core.HRESULT);

    if (create_vs(device, Context.blobPointer(vs_blob), Context.blobSize(vs_blob), null, &e.vertex_shader) < 0 or e.vertex_shader == null) {
        std.debug.print("D3D11 vertex shader creation failed\n", .{});
        e.release();
        registry.?.live[handle] = false;
        return .{ .program = 0, .vao = vao };
    }
    if (create_ps(device, Context.blobPointer(ps_blob), Context.blobSize(ps_blob), null, &e.pixel_shader) < 0 or e.pixel_shader == null) {
        std.debug.print("D3D11 pixel shader creation failed\n", .{});
        e.release();
        registry.?.live[handle] = false;
        return .{ .program = 0, .vao = vao };
    }
    if (!createInputLayout(device, e, vao, vs_blob)) {
        std.debug.print("D3D11 input layout creation failed\n", .{});
        e.release();
        registry.?.live[handle] = false;
        return .{ .program = 0, .vao = vao };
    }
    if (!createConstantBuffer(device, e)) {
        std.debug.print("D3D11 constant buffer creation failed\n", .{});
        e.release();
        registry.?.live[handle] = false;
        return .{ .program = 0, .vao = vao };
    }
    e.vao = vao;
    return .{ .program = handle, .vao = vao };
}

fn formatForAttr(count: u32) u32 {
    return switch (count) {
        1 => core.DXGI_FORMAT_R32_FLOAT,
        2 => core.DXGI_FORMAT_R32G32_FLOAT,
        3 => core.DXGI_FORMAT_R32G32B32_FLOAT,
        4 => core.DXGI_FORMAT_R32G32B32A32_FLOAT,
        else => core.DXGI_FORMAT_R32G32B32A32_FLOAT,
    };
}

fn createInputLayout(device: *anyopaque, e: *Entry, vao: types.VertexArrayHandle, vs_blob: *anyopaque) bool {
    const l = vertex.layout(vao) orelse return false;
    var descs: [16]core.D3D11_INPUT_ELEMENT_DESC = undefined;
    const attr_count = l.attr_count;
    for (l.attrs[0..attr_count], 0..) |a, i| {
        descs[i] = .{
            .semantic_name = "ATTR",
            .semantic_index = a.loc,
            .format = formatForAttr(a.count),
            .input_slot = a.slot,
            .aligned_byte_offset = std.math.cast(u32, a.offset) orelse 0,
            .input_slot_class = if (a.divisor > 0) core.D3D11_INPUT_PER_INSTANCE_DATA else core.D3D11_INPUT_PER_VERTEX_DATA,
            .instance_data_step_rate = a.divisor,
        };
    }
    const create_layout = core.comCall(device, core.slot.D3D11Device_CreateInputLayout, *const fn (
        *anyopaque,
        [*]const core.D3D11_INPUT_ELEMENT_DESC,
        u32,
        *const anyopaque,
        usize,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    return create_layout(
        device,
        &descs,
        attr_count,
        Context.blobPointer(vs_blob),
        Context.blobSize(vs_blob),
        &e.input_layout,
    ) >= 0 and e.input_layout != null;
}

fn createConstantBuffer(device: *anyopaque, e: *Entry) bool {
    const byte_width = comptime blk: {
        const raw = @sizeOf(Uniforms);
        break :blk (raw + 15) & ~@as(usize, 15);
    };
    const desc = core.D3D11_BUFFER_DESC{
        .byte_width = @intCast(byte_width),
        .usage = core.D3D11_USAGE_DYNAMIC,
        .bind_flags = core.D3D11_BIND_CONSTANT_BUFFER,
        .cpu_access_flags = core.D3D11_CPU_ACCESS_WRITE,
        .misc_flags = 0,
        .structure_byte_stride = 0,
    };
    const create_buffer = core.comCall(device, core.slot.D3D11Device_CreateBuffer, *const fn (
        *anyopaque,
        *const core.D3D11_BUFFER_DESC,
        ?*const core.D3D11_SUBRESOURCE_DATA,
        *?*anyopaque,
    ) callconv(.winapi) core.HRESULT);
    return create_buffer(device, &desc, null, &e.constant_buffer) >= 0 and e.constant_buffer != null;
}

pub fn use(self: Pipeline) void {
    if (pre_use_hook) |hook| hook(self.program);
    bindPipeline(self);
}

pub fn bindVao(self: Pipeline) void {
    bindVertexBuffers(self.vao);
}

pub fn setVec2(self: Pipeline, name: [*c]const u8, x: f32, y: f32) void {
    const e = entry(self.program) orelse return;
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "cellSize")) {
        e.uniforms.cell_size_grid_offset[0] = x;
        e.uniforms.cell_size_grid_offset[1] = y;
    } else if (std.mem.eql(u8, n, "gridOffset")) {
        e.uniforms.cell_size_grid_offset[2] = x;
        e.uniforms.cell_size_grid_offset[3] = y;
    }
}

pub fn setFloat(self: Pipeline, name: [*c]const u8, v: f32) void {
    const e = entry(self.program) orelse return;
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "windowHeight")) {
        e.uniforms.scalars[0] = v;
    } else if (std.mem.eql(u8, n, "opacity")) {
        e.uniforms.scalars[1] = v;
    } else if (std.mem.eql(u8, n, "iTime")) {
        e.uniforms.scalars[2] = v;
    } else if (std.mem.eql(u8, n, "iTimeDelta")) {
        e.uniforms.scalars[3] = v;
    }
}

pub fn setInt(self: Pipeline, name: [*c]const u8, v: i32) void {
    _ = self;
    _ = name;
    _ = v;
    // Textures are bound explicitly through Texture.bind(unit).
}

pub fn setProjection(self: Pipeline) void {
    const size = render_state.viewportSize();
    if (size.w <= 0 or size.h <= 0) return;
    const width: f32 = @floatFromInt(size.w);
    const height: f32 = @floatFromInt(size.h);
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };
    self.setMat4("projection", &projection);
}

pub fn setMat4(self: Pipeline, name: [*c]const u8, m: *const [16]f32) void {
    const e = entry(self.program) orelse return;
    if (std.mem.eql(u8, std.mem.span(name), "projection")) {
        e.uniforms.projection = m.*;
    }
}

pub fn setVec3(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    const e = entry(self.program) orelse return;
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "textColor")) {
        e.uniforms.text_color = .{ x, y, z, 1 };
    } else if (std.mem.eql(u8, n, "iResolution")) {
        e.uniforms.scalars = .{ x, y, z, e.uniforms.scalars[3] };
    }
}

pub fn setVec4(self: Pipeline, name: [*c]const u8, x: f32, y: f32, z: f32, w: f32) void {
    const e = entry(self.program) orelse return;
    if (std.mem.eql(u8, std.mem.span(name), "overlayColor")) {
        e.uniforms.overlay_color = .{ x, y, z, w };
    }
}

fn topologyEnum(topology: types.PrimitiveTopology) u32 {
    return switch (topology) {
        .triangles => core.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
        .triangle_strip => core.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
    };
}

pub fn drawArrays(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei) void {
    if (count <= 0 or first < 0) return;
    if (!prepareDraw(self, topology)) return;
    const context = Context.contextHandle() orelse return;
    const draw = core.comCall(context, core.slot.D3D11DeviceContext_Draw, *const fn (*anyopaque, u32, u32) callconv(.winapi) void);
    draw(context, @intCast(count), @intCast(first));
    Context.noteFeatureDraw();
}

pub fn drawArraysInstanced(self: Pipeline, topology: types.PrimitiveTopology, first: c.GLint, count: c.GLsizei, instances: c.GLsizei) void {
    if (count <= 0 or instances <= 0 or first < 0) return;
    if (!prepareDraw(self, topology)) return;
    const context = Context.contextHandle() orelse return;
    const draw = core.comCall(context, core.slot.D3D11DeviceContext_DrawInstanced, *const fn (*anyopaque, u32, u32, u32, u32) callconv(.winapi) void);
    draw(context, @intCast(count), @intCast(instances), @intCast(first), 0);
    Context.noteFeatureDraw();
}

fn prepareDraw(self: Pipeline, topology: types.PrimitiveTopology) bool {
    const context = Context.contextHandle() orelse return false;
    if (entry(self.program) == null) return false;
    bindPipeline(self);
    bindVertexBuffers(self.vao);
    uploadUniforms(self.program);
    const ia_topology = core.comCall(context, core.slot.D3D11DeviceContext_IASetPrimitiveTopology, *const fn (*anyopaque, u32) callconv(.winapi) void);
    ia_topology(context, topologyEnum(topology));
    return true;
}

fn bindPipeline(self: Pipeline) void {
    const e = entry(self.program) orelse return;
    const context = Context.contextHandle() orelse return;
    const ia_layout = core.comCall(context, core.slot.D3D11DeviceContext_IASetInputLayout, *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) void);
    ia_layout(context, e.input_layout);

    const vs_set = core.comCall(context, core.slot.D3D11DeviceContext_VSSetShader, *const fn (*anyopaque, ?*anyopaque, ?[*]const ?*anyopaque, u32) callconv(.winapi) void);
    const ps_set = core.comCall(context, core.slot.D3D11DeviceContext_PSSetShader, *const fn (*anyopaque, ?*anyopaque, ?[*]const ?*anyopaque, u32) callconv(.winapi) void);
    vs_set(context, e.vertex_shader, null, 0);
    ps_set(context, e.pixel_shader, null, 0);
}

fn bindVertexBuffers(vao: types.VertexArrayHandle) void {
    const l = vertex.layout(vao) orelse return;
    const context = Context.contextHandle() orelse return;
    var buffers: [8]?*anyopaque = @splat(null);
    var strides: [8]u32 = @splat(0);
    var offsets: [8]u32 = @splat(0);
    for (0..l.buffer_count) |i| {
        buffers[i] = Buffer.nativeHandle(l.buffers[i]);
        strides[i] = l.strides[i];
    }
    const set_buffers = core.comCall(context, core.slot.D3D11DeviceContext_IASetVertexBuffers, *const fn (
        *anyopaque,
        u32,
        u32,
        [*]const ?*anyopaque,
        [*]const u32,
        [*]const u32,
    ) callconv(.winapi) void);
    set_buffers(context, 0, l.buffer_count, &buffers, &strides, &offsets);
}

fn uploadUniforms(handle: types.ProgramHandle) void {
    const e = entry(handle) orelse return;
    const context = Context.contextHandle() orelse return;
    const cb = e.constant_buffer orelse return;
    const src = std.mem.asBytes(&e.uniforms);
    const map = core.comCall(context, core.slot.D3D11DeviceContext_Map, *const fn (
        *anyopaque,
        *anyopaque,
        u32,
        u32,
        u32,
        *core.D3D11_MAPPED_SUBRESOURCE,
    ) callconv(.winapi) core.HRESULT);
    var mapped: core.D3D11_MAPPED_SUBRESOURCE = undefined;
    if (map(context, cb, 0, core.D3D11_MAP_WRITE_DISCARD, 0, &mapped) >= 0 and mapped.p_data != null) {
        const dst: [*]u8 = @ptrCast(mapped.p_data.?);
        @memcpy(dst[0..src.len], src);
        const unmap = core.comCall(context, core.slot.D3D11DeviceContext_Unmap, *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void);
        unmap(context, cb, 0);
    }

    var cbs = [_]?*anyopaque{cb};
    const vs_cb = core.comCall(context, core.slot.D3D11DeviceContext_VSSetConstantBuffers, *const fn (*anyopaque, u32, u32, [*]const ?*anyopaque) callconv(.winapi) void);
    const ps_cb = core.comCall(context, core.slot.D3D11DeviceContext_PSSetConstantBuffers, *const fn (*anyopaque, u32, u32, [*]const ?*anyopaque) callconv(.winapi) void);
    vs_cb(context, 0, 1, &cbs);
    ps_cb(context, 0, 1, &cbs);
}

pub fn drawPhase2Quad() void {
    Context.drawPhase2Quad();
}

pub fn deinit(self: *Pipeline) void {
    if (entry(self.program)) |e| {
        e.release();
        registry.?.live[self.program] = false;
    }
    if (self.vao != 0) vertex.deleteVertexArray(self.vao);
    self.* = .{ .program = 0, .vao = 0 };
}
