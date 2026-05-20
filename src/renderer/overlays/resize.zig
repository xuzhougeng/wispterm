//! Resize overlay state and rendering.

const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const Surface = @import("../../Surface.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const primitives = @import("primitives.zig");
const renderRoundedQuadAlpha = primitives.renderRoundedQuadAlpha;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const RESIZE_OVERLAY_DURATION_MS: i64 = 750; // How long to show after resize stops
const RESIZE_OVERLAY_FADE_MS: i64 = 150; // Fade out duration
const RESIZE_OVERLAY_FIRST_DELAY_MS: i64 = 500; // Delay before first overlay shows

// Global resize overlay state
pub threadlocal var g_resize_overlay_visible: bool = false; // Whether overlay should be showing
threadlocal var g_resize_overlay_last_change: i64 = 0; // When size last changed
threadlocal var g_resize_overlay_cols: u16 = 0; // Current cols being displayed
threadlocal var g_resize_overlay_rows: u16 = 0; // Current rows being displayed
threadlocal var g_resize_overlay_last_cols: u16 = 0; // Last "settled" cols (after timeout)
threadlocal var g_resize_overlay_last_rows: u16 = 0; // Last "settled" rows (after timeout)
threadlocal var g_resize_overlay_ready: bool = false; // Set after initial delay
threadlocal var g_resize_overlay_init_time: i64 = 0; // When window was created
pub threadlocal var g_resize_overlay_opacity: f32 = 0; // For fade out animation

// Resize active state (for cursor hiding) - separate from overlay visibility
const RESIZE_ACTIVE_TIMEOUT_MS: i64 = 50; // Consider resize "done" after this many ms of no changes
pub threadlocal var g_resize_active: bool = false; // True while actively resizing

// Suppress resize overlay briefly after tab switch/creation to avoid false triggers
pub threadlocal var g_resize_overlay_suppress_until: i64 = 0;

// Split resize overlay (for equalize/keyboard resize - shows overlay on all splits temporarily)
pub threadlocal var g_split_resize_overlay_until: i64 = 0; // Timestamp when overlay should hide

// ============================================================================
// Resize overlay
// ============================================================================

/// Trigger the resize overlay to show with the given dimensions.
/// Called whenever the terminal size changes.
pub fn resizeOverlayShow(cols: u16, rows: u16) void {
    const now = std.time.milliTimestamp();

    // Check if overlay is suppressed (e.g., after tab switch)
    if (now < g_resize_overlay_suppress_until) {
        // Still update last cols/rows so we don't flash when suppression ends
        g_resize_overlay_last_cols = cols;
        g_resize_overlay_last_rows = rows;
        return;
    }

    // Mark resize as active (for cursor hiding)
    g_resize_active = true;
    g_resize_overlay_last_change = now;

    // Check if we're past the initial delay (avoid showing during initial window setup)
    if (!g_resize_overlay_ready) {
        if (g_resize_overlay_init_time == 0) {
            g_resize_overlay_init_time = now;
        }
        if (now - g_resize_overlay_init_time < RESIZE_OVERLAY_FIRST_DELAY_MS) {
            // Still in initial delay - update last_cols/rows so we don't flash when ready
            g_resize_overlay_last_cols = cols;
            g_resize_overlay_last_rows = rows;
            return;
        }
        g_resize_overlay_ready = true;
    }

    // Update current size
    g_resize_overlay_cols = cols;
    g_resize_overlay_rows = rows;

    // Show overlay if size differs from last settled size
    if (cols != g_resize_overlay_last_cols or rows != g_resize_overlay_last_rows) {
        g_resize_overlay_visible = true;
        g_resize_overlay_opacity = 1.0;
    }
}

/// Update resize overlay state. Call once per frame.
/// Handles the timeout logic and fade animation.
fn resizeOverlayUpdate() void {
    const now = std.time.milliTimestamp();
    const elapsed = now - g_resize_overlay_last_change;

    // Update resize active state (short timeout for cursor to reappear)
    if (g_resize_active and elapsed >= RESIZE_ACTIVE_TIMEOUT_MS) {
        g_resize_active = false;
    }

    if (!g_resize_overlay_visible and g_resize_overlay_opacity <= 0) return;

    if (g_resize_overlay_visible) {
        // Check if we should start hiding (size hasn't changed for DURATION_MS)
        if (elapsed >= RESIZE_OVERLAY_DURATION_MS) {
            // Timer completed - "settle" the size and start fade out
            g_resize_overlay_last_cols = g_resize_overlay_cols;
            g_resize_overlay_last_rows = g_resize_overlay_rows;
            g_resize_overlay_visible = false;
            // opacity stays at current value, will fade in next block
        }
    }

    // Handle fade out when not visible
    if (!g_resize_overlay_visible and g_resize_overlay_opacity > 0) {
        const fade_start = g_resize_overlay_last_change + RESIZE_OVERLAY_DURATION_MS;
        const fade_elapsed = now - fade_start;
        if (fade_elapsed >= RESIZE_OVERLAY_FADE_MS) {
            g_resize_overlay_opacity = 0;
        } else if (fade_elapsed > 0) {
            g_resize_overlay_opacity = 1.0 - @as(f32, @floatFromInt(fade_elapsed)) / @as(f32, @floatFromInt(RESIZE_OVERLAY_FADE_MS));
        }
    }
}

/// Render the resize overlay centered on screen.
pub fn renderResizeOverlay(window_width: f32, window_height: f32) void {
    renderResizeOverlayWithOffset(window_width, window_height, 0);
}

/// Render the resize overlay centered in the content area (below titlebar).
pub fn renderResizeOverlayWithOffset(window_width: f32, window_height: f32, top_offset: f32) void {
    resizeOverlayUpdate();
    if (g_resize_overlay_opacity <= 0.01) return;

    renderResizeOverlayText(g_resize_overlay_cols, g_resize_overlay_rows, window_width, window_height, top_offset, g_resize_overlay_opacity);
}

/// Render the resize overlay for a specific surface (used during divider dragging or equalize).
/// Shows the surface's current dimensions centered in the viewport.
/// Only shows if this surface's size actually changed during the drag/equalize.
pub fn renderResizeOverlayForSurface(surface: *Surface, window_width: f32, window_height: f32) void {
    // Show during divider dragging OR during timed split resize overlay (equalize, keyboard resize)
    const show_timed = std.time.milliTimestamp() < g_split_resize_overlay_until;
    if (!AppWindow.input.g_divider_dragging and !show_timed) return;
    if (!surface.resize_overlay_active) return;

    const cols = surface.size.grid.cols;
    const rows = surface.size.grid.rows;

    renderResizeOverlayText(cols, rows, window_width, window_height, 0, 1.0);
}

/// Core function to render a resize overlay with specific dimensions.
fn renderResizeOverlayText(cols: u16, rows: u16, window_width: f32, window_height: f32, top_offset: f32, alpha: f32) void {
    const gl = &AppWindow.gl;
    if (alpha <= 0.01) return;

    // Format the size string: "cols x rows"
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ cols, rows }) catch return;

    // Measure text width using titlebar glyph system
    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
    const text_height = font.g_titlebar_cell_height;

    // Padding around text (compact)
    const pad_x: f32 = 10;
    const pad_y: f32 = 6;

    // Box dimensions
    const box_width = text_width + pad_x * 2;
    const box_height = text_height + pad_y * 2;

    // Center horizontally, center vertically in content area (below top_offset)
    const content_height = window_height - top_offset;
    const box_x = (window_width - box_width) / 2;
    const box_y = (content_height - box_height) / 2; // Centered in content area (GL coords)

    // Enable blending
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    gl.UseProgram.?(gl_init.shader_program);
    gl.BindVertexArray.?(gl_init.vao);

    // Draw rounded background box (black with alpha, slightly more transparent than scrollbar)
    const corner_radius: f32 = 6;
    renderRoundedQuadAlpha(box_x, box_y, box_width, box_height, corner_radius, .{ 0.0, 0.0, 0.0 }, alpha * 0.35);

    // Draw text using titlebar rendering system (dimmed gray text)
    var x = box_x + pad_x;
    const y = box_y + pad_y;
    const text_gray: f32 = 0.6; // Dimmed gray
    for (text) |ch| {
        titlebar.renderTitlebarChar(@intCast(ch), x, y, .{ text_gray, text_gray, text_gray });
        x += titlebar.titlebarGlyphAdvance(@intCast(ch));
    }
}
