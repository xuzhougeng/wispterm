//! Background image rendering.
//!
//! Loads an image (PNG/JPG/BMP/GIF/...) via stb_image and uploads it as a GL
//! texture. Drawn fullscreen between the framebuffer clear and the cell pass,
//! so per-cell backgrounds drawn with `background-opacity < 1.0` reveal it.

const std = @import("std");
const Config = @import("../config.zig");
const AppWindow = @import("../AppWindow.zig");
const gl_init = AppWindow.gl_init;

const c = @cImport({
    @cInclude("glad/gl.h");
    @cInclude("stb_image.h");
});

pub const Mode = Config.BackgroundImageMode;

pub threadlocal var g_enabled: bool = false;
pub threadlocal var g_mode: Mode = .fill;

threadlocal var g_texture: c.GLuint = 0;
threadlocal var g_width: c_int = 0;
threadlocal var g_height: c_int = 0;

/// Load an image from `path` and upload it as a GL texture. Replaces any
/// previously loaded image. Call with `null` to disable. Safe to call again
/// for hot-reload.
pub fn load(path: ?[]const u8) void {
    const gl = AppWindow.gl;

    // Reset existing state
    if (g_texture != 0) {
        gl.DeleteTextures.?(1, &g_texture);
        g_texture = 0;
    }
    g_enabled = false;
    g_width = 0;
    g_height = 0;

    const p = path orelse return;
    if (p.len == 0) return;

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (p.len >= path_buf.len) {
        std.debug.print("background-image path too long\n", .{});
        return;
    }
    @memcpy(path_buf[0..p.len], p);
    path_buf[p.len] = 0;

    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const data = c.stbi_load(&path_buf[0], &w, &h, &n, 4);
    if (data == null or w <= 0 or h <= 0) {
        std.debug.print("background-image: failed to load '{s}'\n", .{p});
        return;
    }
    defer c.stbi_image_free(data);

    gl.GenTextures.?(1, &g_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_texture);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    const wrap: c.GLint = if (g_mode == .tile) c.GL_REPEAT else c.GL_CLAMP_TO_EDGE;
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrap);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrap);
    gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, data);

    g_width = w;
    g_height = h;
    g_enabled = true;
    std.debug.print("background-image loaded: {s} ({}x{})\n", .{ p, w, h });
}

/// Update the wrap mode after `g_mode` changes (without reloading the image).
pub fn refreshWrapMode() void {
    if (g_texture == 0) return;
    const gl = AppWindow.gl;
    const wrap: c.GLint = if (g_mode == .tile) c.GL_REPEAT else c.GL_CLAMP_TO_EDGE;
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_texture);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, wrap);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, wrap);
}

pub fn deinit() void {
    if (g_texture == 0) return;
    const gl = AppWindow.gl;
    gl.DeleteTextures.?(1, &g_texture);
    g_texture = 0;
    g_enabled = false;
}

/// Compute UVs for a fullscreen quad given the chosen mode.
/// For fill/fit/center we keep the quad covering the whole framebuffer and
/// adjust UVs so the image aspect is preserved. For tile we set UVs > 1 and
/// rely on GL_REPEAT wrap.
fn computeUv(fb_w: f32, fb_h: f32, mode: Mode) struct { u0: f32, v0: f32, u1: f32, v1: f32 } {
    if (g_width <= 0 or g_height <= 0) return .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };
    const iw: f32 = @floatFromInt(g_width);
    const ih: f32 = @floatFromInt(g_height);

    switch (mode) {
        .fill => {
            // Cover: the image is scaled so the smaller axis fills the
            // framebuffer; the larger axis is cropped via UVs (< 1 range).
            const win_aspect = fb_w / fb_h;
            const img_aspect = iw / ih;
            if (img_aspect > win_aspect) {
                // image is wider than the window — crop sides
                const visible = win_aspect / img_aspect;
                const offset = (1.0 - visible) * 0.5;
                return .{ .u0 = offset, .v0 = 0, .u1 = 1.0 - offset, .v1 = 1 };
            } else {
                // image is taller — crop top/bottom
                const visible = img_aspect / win_aspect;
                const offset = (1.0 - visible) * 0.5;
                return .{ .u0 = 0, .v0 = offset, .u1 = 1, .v1 = 1.0 - offset };
            }
        },
        .fit => {
            // Letterbox: scale so the larger axis fills, the smaller is
            // padded with extra UV space (sampled outside [0,1]). With
            // CLAMP_TO_EDGE the padding shows the edge pixels — usually fine
            // for landscape wallpapers but acceptable as a v1.
            const win_aspect = fb_w / fb_h;
            const img_aspect = iw / ih;
            if (img_aspect > win_aspect) {
                const extra = img_aspect / win_aspect;
                const offset = (1.0 - extra) * 0.5;
                return .{ .u0 = 0, .v0 = offset, .u1 = 1, .v1 = 1.0 - offset };
            } else {
                const extra = win_aspect / img_aspect;
                const offset = (1.0 - extra) * 0.5;
                return .{ .u0 = offset, .v0 = 0, .u1 = 1.0 - offset, .v1 = 1 };
            }
        },
        .center => {
            // 1:1 pixel scale, centered. UV range is window/image so a
            // center crop or surround happens naturally. Outside [0,1] the
            // CLAMP_TO_EDGE wrap shows the edge row — close enough.
            const u_range = fb_w / iw;
            const v_range = fb_h / ih;
            const u0 = (1.0 - u_range) * 0.5;
            const v0 = (1.0 - v_range) * 0.5;
            return .{ .u0 = u0, .v0 = v0, .u1 = u0 + u_range, .v1 = v0 + v_range };
        },
        .tile => {
            // Repeat the image at native size. UVs equal window / image.
            const u_range = fb_w / iw;
            const v_range = fb_h / ih;
            return .{ .u0 = 0, .v0 = 0, .u1 = u_range, .v1 = v_range };
        },
    }
}

/// Draw the loaded image filling the current viewport. The caller must have
/// already set the viewport and projection. No-op when no image is loaded.
/// Note: `viewport_height` is the height in pixels of the current viewport
/// (used to flip Y in the projection matrix used by the simple shader).
pub fn drawFullscreen(viewport_width: f32, viewport_height: f32) void {
    if (!g_enabled or g_texture == 0) return;
    const gl = AppWindow.gl;
    if (gl_init.simple_color_shader == 0) return;

    const uv = computeUv(viewport_width, viewport_height, g_mode);

    // The simple_color_shader uses gl_init.shader_program's vertex layout
    // (vec4: xy=pos, zw=texcoord) and gl_init.setProjection's projection
    // matrix. We bind the simple_color_shader and set its uniforms.
    gl.UseProgram.?(gl_init.simple_color_shader);
    gl_init.setProjectionForProgram(gl_init.simple_color_shader, viewport_height);
    gl.Uniform1f.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "opacity"), 1.0);
    gl.Uniform1i.?(gl.GetUniformLocation.?(gl_init.simple_color_shader, "text"), 0);

    // Two triangles covering the whole viewport in pixel coords.
    // setProjectionForProgram maps [0..w] x [0..h] to NDC.
    const x0: f32 = 0;
    const y0: f32 = 0;
    const x1: f32 = viewport_width;
    const y1: f32 = viewport_height;
    const vertices = [6][4]f32{
        .{ x0, y1, uv.u0, uv.v0 }, // top-left
        .{ x0, y0, uv.u0, uv.v1 }, // bottom-left
        .{ x1, y0, uv.u1, uv.v1 }, // bottom-right
        .{ x0, y1, uv.u0, uv.v0 },
        .{ x1, y0, uv.u1, uv.v1 },
        .{ x1, y1, uv.u1, uv.v0 }, // top-right
    };

    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_texture);
    gl.BindVertexArray.?(gl_init.vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, gl_init.vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);

    // The image is opaque RGBA; we want to write it directly without blending
    // against whatever ClearColor wrote. Disable blending for this single draw.
    gl.Disable.?(c.GL_BLEND);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
    gl.Enable.?(c.GL_BLEND);
    gl_init.g_draw_call_count += 1;
}
