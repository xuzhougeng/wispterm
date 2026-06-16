//! Closed-state Copilot "summon handle" at the terminal's right edge — the
//! universal, cross-platform affordance for the Copilot sidebar. Reveal-on-
//! proximity + hover tooltip + a one-time first-session shimmer. Structured like
//! startup_shortcuts.zig: threadlocal animation state, time-based easing.
const std = @import("std");
const AppWindow = @import("../../AppWindow.zig");
const ai_sidebar = @import("../../ai_sidebar.zig");
const keybind = @import("../../keybind.zig");
const primitives = @import("primitives.zig");
const hint_tooltip = @import("hint_tooltip.zig");

pub const REVEAL_ZONE_W: f32 = 28;
pub const REVEALED_ALPHA: f32 = 0.5;
const HOVER_ALPHA: f32 = 0.95;
const EASE_PER_MS: f32 = 0.012; // ~80ms to traverse 0->1
const TOOLTIP_DWELL_MS: i64 = 350;
const SHIMMER_MS: i64 = 700;

threadlocal var g_alpha: f32 = 0;
threadlocal var g_target: f32 = 0;
threadlocal var g_hovered: bool = false;
threadlocal var g_hover_since: i64 = 0;
threadlocal var g_last_frame_ms: i64 = 0;
threadlocal var g_shimmer_start: i64 = 0; // 0 = inactive

pub fn setProximityTarget(target: f32) void {
    g_target = target;
}

pub fn setHovered(h: bool) void {
    if (h and !g_hovered) g_hover_since = std.time.milliTimestamp();
    g_hovered = h;
}

pub fn startShimmer() void {
    g_shimmer_start = std.time.milliTimestamp();
}

/// Whether the handle still needs per-frame repaints: a shimmer is in progress,
/// the eased alpha has not yet reached its effective target, or a hover tooltip
/// dwell is still pending. The render loop's frame driver
/// (overlays.anyOverlayActive) consults this so these time-based animations keep
/// producing frames even without input events. Returns false at steady state
/// (fully hidden, or settled hover with the tooltip already shown) so an idle
/// terminal does not repaint.
pub fn isAnimating() bool {
    if (g_shimmer_start != 0) return true;
    const target = if (g_hovered) HOVER_ALPHA else g_target;
    if (@abs(g_alpha - target) > 0.01) return true;
    if (g_hovered and std.time.milliTimestamp() - g_hover_since < TOOLTIP_DWELL_MS) return true;
    return false;
}

fn shortcutText(buf: []u8) []const u8 {
    const binding = AppWindow.g_keybinds.firstForAction(.toggle_ai_copilot) orelse return "";
    return keybind.formatTrigger(binding.trigger, buf) catch "";
}

/// Render the closed-state handle. Caller guarantees Copilot is closed, the
/// active tab is a terminal, the feature is enabled, and no other right-docked
/// panel is open. `left_offset` is `AppWindow.leftPanelsWidth()`.
pub fn render(window_w: f32, window_h: f32, titlebar_h: f32, left_offset: f32) void {
    const now = std.time.milliTimestamp();
    const dt: f32 = if (g_last_frame_ms == 0) 0 else @floatFromInt(now - g_last_frame_ms);
    g_last_frame_ms = now;

    const rect = ai_sidebar.closedHandleRect(window_w, window_h, titlebar_h, left_offset);
    if (!rect.eligible) {
        g_alpha = 0;
        return;
    }

    const target = if (g_hovered) HOVER_ALPHA else g_target;
    const step = EASE_PER_MS * dt;
    if (g_alpha < target) {
        g_alpha = @min(target, g_alpha + step);
    } else {
        g_alpha = @max(target, g_alpha - step);
    }

    var draw_alpha = g_alpha;
    if (g_shimmer_start != 0) {
        const elapsed = now - g_shimmer_start;
        if (elapsed >= SHIMMER_MS) {
            g_shimmer_start = 0;
        } else {
            const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(SHIMMER_MS));
            const bump = std.math.sin(t * std.math.pi); // peek up then settle
            draw_alpha = @max(draw_alpha, 0.85 * bump);
        }
    }
    if (draw_alpha <= 0.01) return;

    // top-down rect -> GL bottom-left (mirror renderAiCopilotCloseButton).
    const gl_y = window_h - (rect.y + rect.h);
    const accent = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.cursor_color, 0.6);
    const base = primitives.mixColor(AppWindow.g_theme.background, AppWindow.g_theme.foreground, 0.35);
    const color = if (g_hovered) accent else base;
    primitives.renderRoundedQuadAlpha(rect.x, gl_y, rect.w, rect.h, rect.w / 2, color, draw_alpha);

    if (g_hovered and (now - g_hover_since) >= TOOLTIP_DWELL_MS) {
        var key_buf: [64]u8 = undefined;
        const keys = shortcutText(&key_buf);
        var label_buf: [96]u8 = undefined;
        const label = if (keys.len > 0)
            (std.fmt.bufPrint(&label_buf, "Copilot  {s}", .{keys}) catch "Copilot")
        else
            "Copilot";
        const center_y = gl_y + rect.h / 2;
        hint_tooltip.render(label, rect.x, center_y, .left, 1.0);
    }
}
