//! Terminal scrollbar overlay geometry, hit testing, dragging, and rendering.

const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const Surface = @import("../../Surface.zig");
const scrollbar_model = @import("../../scrollbar_model.zig");
const gl_init = AppWindow.gl_init;
const primitives = @import("primitives.zig");
const mixColor = primitives.mixColor;

pub const SCROLLBAR_WIDTH: f32 = 12; // Width of the scrollbar track
const SCROLLBAR_MARGIN: f32 = 2; // Margin from right edge
const SCROLLBAR_MIN_THUMB: f32 = 20; // Minimum thumb height in pixels
const SCROLLBAR_FADE_DELAY_MS: i64 = 800; // ms to wait before fading
const SCROLLBAR_FADE_DURATION_MS: i64 = 400; // ms for fade-out animation
const SCROLLBAR_HOVER_WIDTH: f32 = 12; // Wider hit area for hover/drag

// Per-surface scrollbar opacity/timing lives in Surface.zig.
// These are global interaction state (only one mouse):
pub threadlocal var g_scrollbar_hover: bool = false; // Mouse is over scrollbar area
pub threadlocal var g_scrollbar_dragging: bool = false; // Currently dragging the thumb
pub threadlocal var g_scrollbar_drag_offset: f32 = 0; // Offset within thumb where drag started

// ============================================================================
// Scrollbar geometry
// ============================================================================

/// Scrollbar geometry result.
pub const ScrollbarGeometry = struct {
    track_x: f32,
    track_y: f32, // bottom of track (GL coords, y=0 is bottom)
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
};

/// Compute scrollbar geometry for a specific surface.
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometryForSurface(surface: *Surface, view_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const sb = AppWindow.input.scrollbarForSurface(surface);
    if (sb.total <= sb.len) return null; // No scrollback, no scrollbar

    // Track spans the terminal content area (below top padding, all the way to bottom)
    const track_top = view_height - top_padding; // top of terminal area in GL coords
    const track_bottom: f32 = 0; // extend to bottom edge
    const track_h = track_top - track_bottom;
    if (track_h <= 0) return null;

    // Thumb proportional to visible / total
    const ratio = @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total));
    const thumb_h = @max(SCROLLBAR_MIN_THUMB, track_h * ratio);

    // Thumb position: offset=0 means top, offset=total-len means bottom
    const max_offset = @as(f32, @floatFromInt(sb.total - sb.len));
    const scroll_frac = if (max_offset > 0)
        @as(f32, @floatFromInt(sb.offset)) / max_offset
    else
        0;
    // In GL coords: top of track is higher y value
    const thumb_top = track_top - scroll_frac * (track_h - thumb_h);
    const thumb_y = thumb_top - thumb_h;

    return .{
        .track_x = 0, // placeholder — caller provides view_width
        .track_y = track_bottom,
        .track_h = track_h,
        .thumb_y = thumb_y,
        .thumb_h = thumb_h,
    };
}

/// Compute scrollbar geometry from terminal state (uses active surface).
/// Returns null if there's no scrollback (nothing to scroll).
pub fn scrollbarGeometry(window_height: f32, top_padding: f32) ?ScrollbarGeometry {
    const surface = AppWindow.activeSurface() orelse return null;
    return scrollbarGeometryForSurface(surface, window_height, top_padding);
}

/// Show the scrollbar on the active surface (reset fade timer).
pub fn scrollbarShow() void {
    const surface = AppWindow.activeSurface() orelse return;
    scrollbarShowForSurface(surface);
}

/// Show a specific surface's scrollbar (reset fade timer).
pub fn scrollbarShowForSurface(surface: *Surface) void {
    surface.scrollbar_opacity = 1.0;
    surface.scrollbar_show_time = std.time.milliTimestamp();
}

/// Update scrollbar fade animation for a surface. Call once per frame.
fn scrollbarUpdateFade(surface: *Surface) void {
    if (g_scrollbar_hover or g_scrollbar_dragging) {
        surface.scrollbar_opacity = 1.0;
        return;
    }
    if (surface.scrollbar_opacity <= 0) return;

    const now = std.time.milliTimestamp();
    const elapsed = now - surface.scrollbar_show_time;

    if (elapsed < SCROLLBAR_FADE_DELAY_MS) {
        surface.scrollbar_opacity = 1.0;
    } else {
        const fade_elapsed = elapsed - SCROLLBAR_FADE_DELAY_MS;
        if (fade_elapsed >= SCROLLBAR_FADE_DURATION_MS) {
            surface.scrollbar_opacity = 0;
        } else {
            surface.scrollbar_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(SCROLLBAR_FADE_DURATION_MS));
        }
    }
}

/// Render the scrollbar overlay for a specific surface within the current viewport.
/// view_width/view_height are the viewport dimensions (not full window).
/// top_padding is the padding from the top of the viewport to the terminal content.
pub fn renderScrollbarForSurface(surface: *Surface, view_width: f32, view_height: f32, top_padding: f32) void {
    const gl = &AppWindow.gl;
    const geo = scrollbarGeometryForSurface(surface, view_height, top_padding) orelse return;

    scrollbarUpdateFade(surface);
    const fade = scrollbar_model.effectiveOpacity(surface.scrollbar_opacity, true);
    if (fade <= 0.01) return;

    const bar_x = view_width - SCROLLBAR_WIDTH;
    const bar_w = SCROLLBAR_WIDTH;

    // Use the shader_program for quad rendering
    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;

    const track_color = mixColor(bg, fg, 0.18);
    const track_alpha = fade * 0.20;
    gl_init.renderQuadAlpha(bar_x, geo.track_y, bar_w, geo.track_h, track_color, track_alpha);

    const thumb_color = mixColor(bg, fg, 0.46);
    const thumb_alpha = fade * 0.62;
    gl_init.renderQuadAlpha(bar_x, geo.thumb_y, bar_w, geo.thumb_h, thumb_color, thumb_alpha);
}

/// Render the scrollbar overlay (uses active surface at full window size).
pub fn renderScrollbar(window_width: f32, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    renderScrollbarForSurface(surface, window_width, window_height, top_padding);
}

/// Check if a point (in client pixel coords, origin top-left) is over the scrollbar.
pub fn scrollbarHitTest(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_padding: f32) bool {
    return scrollbar_model.hitTest(
        .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        top_padding,
        SCROLLBAR_HOVER_WIDTH,
        @floatCast(xpos),
        @floatCast(ypos),
    );
}

/// Check if a point is over a specific surface scrollbar in a viewport.
pub fn scrollbarHitTestForSurface(
    surface: *Surface,
    xpos: f64,
    ypos: f64,
    view_x: f32,
    view_y: f32,
    view_width: f32,
    view_height: f32,
    top_padding: f32,
) bool {
    if (scrollbarGeometryForSurface(surface, view_height, top_padding) == null) return false;
    return scrollbar_model.hitTest(
        .{ .x = view_x, .y = view_y, .width = view_width, .height = view_height },
        top_padding,
        SCROLLBAR_HOVER_WIDTH,
        @floatCast(xpos),
        @floatCast(ypos),
    );
}

/// Check if a point is over the scrollbar thumb specifically.
pub fn scrollbarThumbHitTest(ypos: f64, window_height: f32, top_padding: f32) bool {
    const geo = scrollbarGeometry(window_height, top_padding) orelse return false;
    // Convert ypos (top-left origin) to GL coords (bottom-left origin)
    const gl_y = window_height - @as(f32, @floatCast(ypos));
    return gl_y >= geo.thumb_y and gl_y <= geo.thumb_y + geo.thumb_h;
}

/// Handle scrollbar drag: convert pixel y to scroll position.
pub fn scrollbarDrag(ypos: f64, window_height: f32, top_padding: f32) void {
    const surface = AppWindow.activeSurface() orelse return;
    scrollbarDragForSurface(surface, ypos, 0, window_height, top_padding);
}

/// Handle scrollbar drag for a specific surface viewport.
pub fn scrollbarDragForSurface(surface: *Surface, ypos: f64, view_y: f32, view_height: f32, top_padding: f32) void {
    const sb = AppWindow.input.scrollbarForSurface(surface);
    if (sb.total <= sb.len) return;

    const target_offset_usize = scrollbar_model.dragTargetOffset(
        .{ .total = sb.total, .offset = sb.offset, .len = sb.len },
        @as(f32, @floatCast(ypos)) - view_y,
        top_padding,
        view_height,
        g_scrollbar_drag_offset,
        SCROLLBAR_MIN_THUMB,
    ) orelse return;
    const target_offset: isize = @intCast(target_offset_usize);
    const current_offset: isize = @intCast(sb.offset);
    const delta = target_offset - current_offset;

    if (delta != 0) {
        surface.render_state.mutex.lock();
        defer surface.render_state.mutex.unlock();
        surface.terminal.scrollViewport(.{ .delta = delta });
    }
}
