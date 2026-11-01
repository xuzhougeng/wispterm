//! Hover-reveal for the app-drawn toolbar buttons.
//!
//! With `window-show-toolbar = hover`, WispTerm's own titlebar and sidebar
//! buttons (sidebar toggle, settings, help, Copilot, command center, new tab)
//! stay hidden until the pointer is over the titlebar strip or the tab
//! sidebar of the focused window. They fade in quickly, linger briefly once
//! the pointer leaves, then fade out. Native window controls, the title, and
//! status (the Update pill, SSH latency) are never hidden.
//!
//! Ghostty has no hover-revealed toolbar; the key name and its `always` value
//! follow Ghostty's `window-show-tab-bar`.
//!
//! Pure and std-only so it runs in the fast test suite. The opacity is a pure
//! function of the last hover transition, so a frame drawn after an idle gap
//! still fades instead of snapping.

const std = @import("std");

pub const Mode = enum {
    /// Reveal the buttons while the pointer is over the titlebar or sidebar.
    hover,
    /// Always draw the buttons (the pre-hover behavior).
    always,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

pub const FADE_IN_MS: f32 = 90;
pub const LINGER_MS: i64 = 150;
pub const FADE_OUT_MS: f32 = 180;

/// Whether a top-down framebuffer point is in the reveal zone: the whole
/// titlebar strip, or the tab sidebar below it. Negative coordinates mean the
/// pointer is outside the window's client area.
pub fn pointInZone(x: f32, y: f32, titlebar_h: f32, sidebar_w: f32) bool {
    if (x < 0 or y < 0) return false;
    if (y < titlebar_h) return true;
    return x < sidebar_w;
}

pub const State = struct {
    mode: Mode = .hover,
    hovered: bool = false,
    /// Time of the last hover transition, and the opacity at that moment.
    changed_ms: i64 = 0,
    from: f32 = 0,

    pub fn setMode(self: *State, mode: Mode) void {
        if (self.mode == mode) return;
        self.* = .{ .mode = mode };
    }

    /// Record the pointer's hover state for this loop iteration and report
    /// whether the toolbar still needs frames: the reveal changed, or a
    /// fade/linger is in progress. Steady state (fully shown while hovered,
    /// fully hidden otherwise) returns false so an idle window does not repaint.
    pub fn tick(self: *State, hovered: bool, now_ms: i64) bool {
        if (self.mode == .always) return false;
        if (hovered != self.hovered) {
            self.from = self.opacityAt(now_ms);
            self.hovered = hovered;
            self.changed_ms = now_ms;
            return true;
        }
        const opacity = self.opacityAt(now_ms);
        return if (hovered) opacity < 1 else opacity > 0;
    }

    /// Opacity (0..1) the toolbar buttons are drawn with at `now_ms`.
    pub fn opacityAt(self: State, now_ms: i64) f32 {
        if (self.mode == .always) return 1;
        const elapsed: f32 = @floatFromInt(@max(0, now_ms - self.changed_ms));
        if (self.hovered) return @min(1, self.from + elapsed / FADE_IN_MS);
        const fading: f32 = elapsed - @as(f32, @floatFromInt(LINGER_MS));
        if (fading <= 0) return self.from;
        return @max(0, self.from - fading / FADE_OUT_MS);
    }
};

test "Mode parses the config values" {
    try std.testing.expectEqual(Mode.hover, Mode.parse("hover").?);
    try std.testing.expectEqual(Mode.always, Mode.parse("always").?);
    try std.testing.expect(Mode.parse("never") == null);
}

test "pointInZone covers the titlebar strip and the sidebar" {
    // Titlebar strip spans the full width.
    try std.testing.expect(pointInZone(900, 10, 34, 220));
    // Sidebar column below the titlebar.
    try std.testing.expect(pointInZone(100, 500, 34, 220));
    // Terminal body is outside.
    try std.testing.expect(!pointInZone(400, 500, 34, 220));
    // Hidden sidebar leaves only the titlebar.
    try std.testing.expect(!pointInZone(100, 500, 34, 0));
    // Pointer outside the client area.
    try std.testing.expect(!pointInZone(-1, -1, 34, 220));
    try std.testing.expect(!pointInZone(100, -1, 34, 220));
}

test "hover starts hidden, fades in, and settles" {
    var s: State = .{};
    try std.testing.expectEqual(@as(f32, 0), s.opacityAt(1000));
    try std.testing.expect(!s.tick(false, 1000));

    try std.testing.expect(s.tick(true, 1000));
    try std.testing.expectEqual(@as(f32, 0), s.opacityAt(1000));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.opacityAt(1045), 0.001);
    try std.testing.expect(s.tick(true, 1045));
    try std.testing.expectEqual(@as(f32, 1), s.opacityAt(1090));
    try std.testing.expect(!s.tick(true, 1090));
}

test "leaving lingers before fading out" {
    var s: State = .{};
    _ = s.tick(true, 0);
    try std.testing.expect(s.tick(false, 500));
    // Still fully visible through the linger, and still asking for frames.
    try std.testing.expectEqual(@as(f32, 1), s.opacityAt(500 + LINGER_MS));
    try std.testing.expect(s.tick(false, 500 + LINGER_MS));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.opacityAt(500 + LINGER_MS + 90), 0.001);
    try std.testing.expectEqual(@as(f32, 0), s.opacityAt(500 + LINGER_MS + 180));
    try std.testing.expect(!s.tick(false, 500 + LINGER_MS + 180));
}

test "re-entering mid fade resumes from the current opacity" {
    var s: State = .{};
    _ = s.tick(true, 0);
    _ = s.tick(false, 200);
    const t = 200 + LINGER_MS + 90; // half faded
    try std.testing.expect(s.tick(true, t));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.opacityAt(t), 0.001);
    try std.testing.expectEqual(@as(f32, 1), s.opacityAt(t + 45));
}

test "always mode draws fully and never asks for frames" {
    var s: State = .{};
    s.setMode(.always);
    try std.testing.expectEqual(@as(f32, 1), s.opacityAt(0));
    try std.testing.expect(!s.tick(false, 0));
    try std.testing.expect(!s.tick(true, 10));
    try std.testing.expectEqual(@as(f32, 1), s.opacityAt(20));

    s.setMode(.hover);
    try std.testing.expectEqual(@as(f32, 0), s.opacityAt(30));
}
