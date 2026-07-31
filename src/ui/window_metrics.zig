const std = @import("std");

/// Snapshot of the window/titlebar/framebuffer geometry that hit-testing and
/// panel-layout code reads over and over.
///
/// `WindowMetrics` is PURE DATA: it owns no handle and has no platform
/// dependency. Call sites in `input.zig` historically recomputed
/// `framebufferSize(win)`, `titlebarHeight()` and `titlebar.sidebarWidth()`
/// inline at every hit-test, so the same three reads were duplicated 20+ times.
/// This struct captures those values once (the caller supplies the primitives,
/// keeping this module free of any reverse dependency on `AppWindow` or the
/// window backend) so a single computed snapshot can be threaded through the
/// geometry math instead.
///
/// Fields mirror the source types EXACTLY so migrated call sites stay
/// byte-for-byte equivalent: framebuffer dimensions are `i32` (as returned by
/// `window_backend.framebufferSize`), and the titlebar height / sidebar width
/// are `f64` (the widened type the hit-test math already used after
/// `@floatCast`).
pub const WindowMetrics = struct {
    framebuffer_width: i32,
    framebuffer_height: i32,
    titlebar_h: f64,
    sidebar_width: f64,

    pub fn init(fb_w: i32, fb_h: i32, titlebar_h: f64, sidebar_width: f64) WindowMetrics {
        return .{
            .framebuffer_width = fb_w,
            .framebuffer_height = fb_h,
            .titlebar_h = titlebar_h,
            .sidebar_width = sidebar_width,
        };
    }
};

test "window metrics carries the supplied primitives verbatim" {
    const m = WindowMetrics.init(1920, 1080, 28.0, 240.0);
    try std.testing.expectEqual(@as(i32, 1920), m.framebuffer_width);
    try std.testing.expectEqual(@as(i32, 1080), m.framebuffer_height);
    try std.testing.expectEqual(@as(f64, 28.0), m.titlebar_h);
    try std.testing.expectEqual(@as(f64, 240.0), m.sidebar_width);
}
