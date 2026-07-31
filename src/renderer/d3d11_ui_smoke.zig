//! Opt-in D3D11 backend-neutral UI pipeline smoke.
//!
//! Enable with `WISPTERM_D3D11_UI_SMOKE=1`. The pass draws a small panel
//! through the shared `ui_pipeline` helpers, including solid quads, baked-alpha
//! quads, an alpha-blended overlay primitive, scissor clipping, and titlebar
//! atlas glyphs. It then probes the panel region from the swapchain backbuffer.

const std = @import("std");

const font = @import("../font/manager.zig");
const gpu = @import("gpu/gpu.zig");
const render_diagnostics = @import("../render_diagnostics.zig");
const ui_pipeline = @import("ui_pipeline.zig");

const ENV_NAME = "WISPTERM_D3D11_UI_SMOKE";
const smoke_text = "UI";

const Panel = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

threadlocal var checked_env = false;
threadlocal var enabled_cache = false;
threadlocal var logged_ready = false;
threadlocal var logged_glyph_pending = false;
threadlocal var logged_pipeline_pending = false;
threadlocal var last_probe_width: c_int = 0;
threadlocal var last_probe_height: c_int = 0;

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

pub fn render(backbuffer_width: c_int, backbuffer_height: c_int) void {
    if (!enabled()) return;
    if (backbuffer_width < 260 or backbuffer_height < 180) return;
    if (!pipelinesReady()) {
        if (!logged_pipeline_pending) {
            logged_pipeline_pending = true;
            render_diagnostics.log("d3d11-ui-smoke waiting for ui pipelines", .{});
        }
        return;
    }

    const panel = panelLayout(backbuffer_width, backbuffer_height);

    const saved_scissor = gpu.state.scissorState();
    defer gpu.state.restoreScissor(saved_scissor);

    gpu.state.setViewport(0, 0, backbuffer_width, backbuffer_height);
    gpu.state.disableScissor();
    ui_pipeline.setProjection(@floatFromInt(backbuffer_width), @floatFromInt(backbuffer_height));

    if (!ensureGlyphsReady()) {
        if (!logged_glyph_pending) {
            logged_glyph_pending = true;
            render_diagnostics.log("d3d11-ui-smoke waiting for titlebar glyph atlas", .{});
        }
        return;
    }

    drawPanel(panel);
    logBackbufferProbe(panel, backbuffer_width, backbuffer_height);

    if (!logged_ready) {
        logged_ready = true;
        render_diagnostics.log(
            "d3d11-ui-smoke active panel={d:.0},{d:.0} {d:.0}x{d:.0} backbuffer={}x{}",
            .{ panel.x, panel.y, panel.w, panel.h, backbuffer_width, backbuffer_height },
        );
    }
}

pub fn deinit() void {
    logged_ready = false;
    logged_glyph_pending = false;
    logged_pipeline_pending = false;
    last_probe_width = 0;
    last_probe_height = 0;
}

fn pipelinesReady() bool {
    return ui_pipeline.text.program != 0 and
        ui_pipeline.emoji.program != 0 and
        ui_pipeline.overlay.program != 0 and
        ui_pipeline.solid.isValid();
}

fn panelLayout(backbuffer_width: c_int, backbuffer_height: c_int) Panel {
    const fb_w: f32 = @floatFromInt(backbuffer_width);
    const fb_h: f32 = @floatFromInt(backbuffer_height);
    const panel_w = @min(@max(fb_w * 0.22, 240.0), 340.0);
    const panel_h = @min(@max(fb_h * 0.12, 104.0), 132.0);
    return .{
        .x = if (fb_w >= 700.0) 340.0 else 18.0,
        .y = 18.0,
        .w = panel_w,
        .h = panel_h,
    };
}

fn ensureGlyphsReady() bool {
    var ok = true;
    for (smoke_text) |ch| {
        if (font.loadTitlebarGlyph(@intCast(ch)) == null) ok = false;
    }
    if (font.g_titlebar_atlas != null) {
        font.syncAtlasTexture(&font.g_titlebar_atlas, &font.g_titlebar_atlas_texture, &font.g_titlebar_atlas_modified);
    }
    return ok and font.g_titlebar_atlas_texture.isValid();
}

fn drawPanel(panel: Panel) void {
    ui_pipeline.fillQuad(panel.x, panel.y, panel.w, panel.h, .{ 0.025, 0.065, 0.11 });
    ui_pipeline.fillQuadAlpha(panel.x + 6.0, panel.y + 6.0, panel.w - 12.0, panel.h - 12.0, .{ 0.12, 0.24, 0.33 }, 0.70);

    ui_pipeline.fillQuad(panel.x + 12.0, panel.y + 14.0, panel.w - 24.0, 16.0, .{ 0.04, 0.76, 0.92 });
    ui_pipeline.fillQuad(panel.x + 14.0, panel.y + 38.0, 72.0, 34.0, .{ 0.88, 0.16, 0.76 });

    const clip = Panel{
        .x = panel.x + panel.w - 92.0,
        .y = panel.y + 36.0,
        .w = 68.0,
        .h = 48.0,
    };
    gpu.state.setScissor(.{
        .x = @intFromFloat(@round(clip.x)),
        .y = @intFromFloat(@round(clip.y)),
        .w = @intFromFloat(@round(clip.w)),
        .h = @intFromFloat(@round(clip.h)),
    });
    ui_pipeline.fillOverlay(
        quadVertices(clip.x - 28.0, clip.y - 16.0, clip.w + 56.0, clip.h + 32.0),
        .{ 1.0, 0.72, 0.08, 0.58 },
    );
    gpu.state.disableScissor();

    drawText(smoke_text, panel.x + 104.0, panel.y + 54.0, .{ 0.98, 0.98, 0.92 });
}

fn drawText(text: []const u8, x_start: f32, y: f32, color: [3]f32) void {
    var x = x_start;
    for (text) |cp| {
        const ch = font.loadTitlebarGlyph(@intCast(cp)) orelse continue;
        if (ch.region.width == 0 or ch.region.height == 0 or ch.is_color) continue;

        const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
        const y0 = y + font.g_titlebar_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
        const atlas_size = if (font.g_titlebar_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
        const uv = font.glyphUV(ch.region, atlas_size);
        ui_pipeline.drawGlyph(
            .{
                .x = x0,
                .y = y0,
                .w = @floatFromInt(ch.size_x),
                .h = @floatFromInt(ch.size_y),
            },
            .{ .u0 = uv.u0, .v0 = uv.v0, .u1 = uv.u1, .v1 = uv.v1 },
            font.g_titlebar_atlas_texture,
            color,
        );
        x += @floatFromInt(ch.advance >> 6);
    }
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

fn logBackbufferProbe(panel: Panel, backbuffer_width: c_int, backbuffer_height: c_int) void {
    if (last_probe_width == backbuffer_width and last_probe_height == backbuffer_height) return;

    const read_x: i32 = @intFromFloat(@round(panel.x));
    const read_y: i32 = @intFromFloat(@round(panel.y));
    const read_w: u32 = @intFromFloat(@round(panel.w));
    const read_h: u32 = @intFromFloat(@round(panel.h));

    const pixels = gpu.readback.readRgba(std.heap.page_allocator, read_x, read_y, read_w, read_h) catch |err| {
        render_diagnostics.log("d3d11-ui-smoke backbuffer probe failed: {s}", .{@errorName(err)});
        return;
    };
    defer std.heap.page_allocator.free(pixels);
    last_probe_width = backbuffer_width;
    last_probe_height = backbuffer_height;

    var cyan: u32 = 0;
    var magenta: u32 = 0;
    var amber: u32 = 0;
    var text: u32 = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r = pixels[i + 0];
        const g = pixels[i + 1];
        const b = pixels[i + 2];
        if (r < 80 and g > 145 and b > 160) cyan += 1;
        if (r > 150 and g < 90 and b > 120) magenta += 1;
        if (r > 110 and g > 80 and g < 180 and b < 100) amber += 1;
        if (r > 200 and g > 200 and b > 180) text += 1;
    }

    const ok = cyan > 128 and magenta > 128 and amber > 128 and text > 4;
    render_diagnostics.log(
        "d3d11-ui-smoke probe cyan={} magenta={} amber={} text={} samples={} ok={}",
        .{ cyan, magenta, amber, text, pixels.len / 4, ok },
    );
}

test "D3D11 UI smoke env parser accepts truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("YES"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "D3D11 UI smoke env parser rejects falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
}
