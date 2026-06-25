const std = @import("std");

/// Dependency-injection seam for UI-thread capabilities.
///
/// `UiContext` is an INTERFACE-ONLY struct: it carries no business logic and
/// owns no state. It exists so call sites can depend on a small, explicit set
/// of capabilities (repaint / rebuild / toast) instead of reaching into the
/// `AppWindow` service locator (its ~67 `g_*` globals). The fn-pointers are
/// wired by `AppWindow.uiContext()` to thin wrappers around existing plumbing,
/// so behavior is preserved exactly.
pub const UiContext = struct {
    allocator: std.mem.Allocator,
    requestRepaint: *const fn () void,
    requestRebuild: *const fn () void,
    showToast: *const fn (msg: []const u8) void,
};

test "ui context is constructible from no-op pointers" {
    const Noop = struct {
        fn repaint() void {}
        fn rebuild() void {}
        fn toast(msg: []const u8) void {
            _ = msg;
        }
    };

    const ctx = UiContext{
        .allocator = std.testing.allocator,
        .requestRepaint = Noop.repaint,
        .requestRebuild = Noop.rebuild,
        .showToast = Noop.toast,
    };

    // Invoking the pointers must be safe and side-effect-free here.
    ctx.requestRepaint();
    ctx.requestRebuild();
    ctx.showToast("hello");
}
