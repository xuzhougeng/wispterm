//! Opt-in D3D11 off-screen render-target round-trip smoke.
//!
//! Enable with `WISPTERM_D3D11_OFFSCREEN_SMOKE=1`. The pass renders a tiny
//! marker into a `gpu.Framebuffer`, unbinds back to the swapchain backbuffer,
//! then samples the framebuffer color texture into the lower-left corner.

const std = @import("std");

const gpu = @import("gpu/gpu.zig");
const render_diagnostics = @import("../render_diagnostics.zig");
const ui_pipeline = @import("ui_pipeline.zig");

const ENV_NAME = "WISPTERM_D3D11_OFFSCREEN_SMOKE";

threadlocal var checked_env = false;
threadlocal var enabled_cache = false;
threadlocal var framebuffer: gpu.Framebuffer = .{};
threadlocal var logged_ready = false;
threadlocal var logged_create_failed = false;
threadlocal var logged_probe = false;
threadlocal var logged_pipeline_pending = false;

fn parseEnabledValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn enabled() bool {
    if (comptime gpu.active != .d3d11) return false;
    if (checked_env) return enabled_cache;
    checked_env = true;

    const value = std.process.getEnvVarOwned(std.heap.page_allocator, ENV_NAME) catch {
        enabled_cache = false;
        return enabled_cache;
    };
    defer std.heap.page_allocator.free(value);

    enabled_cache = parseEnabledValue(value);
    return enabled_cache;
}

fn quadVertices(x: f32, y: f32, w: f32, h: f32) [6][4]f32 {
    return .{
        .{ x, y + h, 0.0, 1.0 },
        .{ x, y, 0.0, 0.0 },
        .{ x + w, y, 1.0, 0.0 },
        .{ x, y + h, 0.0, 1.0 },
        .{ x + w, y, 1.0, 0.0 },
        .{ x + w, y + h, 1.0, 1.0 },
    };
}

fn ensureFramebuffer(width: c_int, height: c_int) bool {
    if (framebuffer.isValid() and framebuffer.width == width and framebuffer.height == height) return true;
    if (framebuffer.isValid()) framebuffer.deinit();

    framebuffer = gpu.Framebuffer.initColor(width, height) orelse {
        if (!logged_create_failed) {
            logged_create_failed = true;
            render_diagnostics.log("d3d11-offscreen-smoke framebuffer create failed {}x{}", .{ width, height });
        }
        return false;
    };
    logged_create_failed = false;
    return true;
}

pub fn render(backbuffer_width: c_int, backbuffer_height: c_int) void {
    if (!enabled()) return;
    if (backbuffer_width < 48 or backbuffer_height < 48) return;
    if (!pipelinesReady()) {
        if (!logged_pipeline_pending) {
            logged_pipeline_pending = true;
            render_diagnostics.log("d3d11-offscreen-smoke waiting for ui pipelines", .{});
        }
        return;
    }

    const target_width: c_int = @min(@max(@divTrunc(backbuffer_width, 5), 96), 256);
    const target_height: c_int = @min(@max(@divTrunc(backbuffer_height, 8), 48), 128);
    if (!ensureFramebuffer(target_width, target_height)) return;

    const saved_scissor = gpu.state.scissorState();
    defer gpu.state.restoreScissor(saved_scissor);
    gpu.state.disableScissor();

    framebuffer.bind();
    ui_pipeline.setProjection(@floatFromInt(target_width), @floatFromInt(target_height));
    gpu.state.clear(0.05, 0.10, 0.72, 1.0);

    const inset: f32 = 8.0;
    const marker_x = inset;
    const marker_y = inset;
    const marker_w = @max(@as(f32, @floatFromInt(target_width)) - inset * 2.0, 1.0);
    const marker_h = @max(@as(f32, @floatFromInt(target_height)) - inset * 2.0, 1.0);
    ui_pipeline.fillQuad(
        marker_x,
        marker_y,
        marker_w,
        marker_h,
        .{ 1.0, 0.72, 0.08 },
    );

    gpu.Framebuffer.unbind();
    gpu.state.setViewport(0, 0, backbuffer_width, backbuffer_height);
    gpu.state.disableScissor();
    ui_pipeline.setProjection(@floatFromInt(backbuffer_width), @floatFromInt(backbuffer_height));

    const composite = quadVertices(
        12.0,
        12.0,
        @floatFromInt(target_width),
        @floatFromInt(target_height),
    );
    ui_pipeline.drawTextureQuad(composite, framebuffer.colorTexture(), 1.0);
    logBackbufferProbe();

    if (!logged_ready) {
        logged_ready = true;
        render_diagnostics.log(
            "d3d11-offscreen-smoke round-trip active target={}x{} backbuffer={}x{}",
            .{ target_width, target_height, backbuffer_width, backbuffer_height },
        );
    }
}

pub fn deinit() void {
    if (framebuffer.isValid()) framebuffer.deinit();
    framebuffer = .{};
    logged_ready = false;
    logged_create_failed = false;
    logged_probe = false;
    logged_pipeline_pending = false;
}

fn pipelinesReady() bool {
    return ui_pipeline.text.program != 0 and
        ui_pipeline.emoji.program != 0 and
        ui_pipeline.overlay.program != 0;
}

fn logBackbufferProbe() void {
    if (logged_probe) return;
    logged_probe = true;

    const pixels = gpu.readback.readRgba(std.heap.page_allocator, 0, 0, 320, 180) catch |err| {
        render_diagnostics.log("d3d11-offscreen-smoke backbuffer probe failed: {s}", .{@errorName(err)});
        return;
    };
    defer std.heap.page_allocator.free(pixels);

    var red: u32 = 0;
    var blue: u32 = 0;
    var gold: u32 = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r = pixels[i + 0];
        const g = pixels[i + 1];
        const b = pixels[i + 2];
        if (r > 170 and g < 90 and b < 90) red += 1;
        if (b > 120 and r < 90 and g < 120) blue += 1;
        if (r > 170 and g > 90 and b < 110) gold += 1;
    }
    render_diagnostics.log(
        "d3d11-offscreen-smoke backbuffer probe red={} blue={} gold={} samples={}",
        .{ red, blue, gold, pixels.len / 4 },
    );
}

test "D3D11 offscreen smoke env parser accepts truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("YES"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "D3D11 offscreen smoke env parser rejects falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
}
