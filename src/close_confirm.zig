//! Pure decision logic for "confirm before closing a surface that is running a
//! full-screen program." Kept free of the app graph so it runs in the fast
//! unit-test suite. Wiring (overlay state, AppWindow globals) lives in
//! overlays.zig / input.zig / AppWindow.zig.

const std = @import("std");
const input_key = @import("input/key.zig");

/// What a confirmed close should actually do. Carried by the confirm overlay
/// so a single modal can serve all three close gestures.
pub const PendingClose = union(enum) {
    /// Close the whole window (sets AppWindow.g_should_close).
    window,
    /// Close the focused split (AppWindow.closeFocusedSplit).
    focused_split,
    /// Close a specific tab by index (AppWindow.closeTab).
    tab: usize,
};

/// Result of a key press while the confirm modal is open.
pub const KeyOutcome = enum { none, confirm, cancel };

/// Enter confirms the close; Esc cancels; everything else is ignored.
pub fn keyOutcome(ev: input_key.KeyEvent) KeyOutcome {
    return switch (ev.key) {
        .enter => .confirm,
        .escape => .cancel,
        else => .none,
    };
}

/// Whether a close gesture on a surface should prompt: only when the feature is
/// enabled AND a full-screen program is running in the target surface(s).
pub fn shouldConfirm(feature_enabled: bool, running_program: bool) bool {
    return feature_enabled and running_program;
}

test "keyOutcome maps Enter to confirm and Esc to cancel" {
    try std.testing.expectEqual(KeyOutcome.confirm, keyOutcome(.{ .key = .enter }));
    try std.testing.expectEqual(KeyOutcome.cancel, keyOutcome(.{ .key = .escape }));
    try std.testing.expectEqual(KeyOutcome.none, keyOutcome(.{ .key = .tab }));
}

test "shouldConfirm requires both the toggle and a running program" {
    try std.testing.expect(shouldConfirm(true, true));
    try std.testing.expect(!shouldConfirm(false, true));
    try std.testing.expect(!shouldConfirm(true, false));
    try std.testing.expect(!shouldConfirm(false, false));
}
