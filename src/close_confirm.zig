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

/// What the Ctrl+Shift+W close shortcut should do, decided purely from the focused
/// pane's state. Keeping the priority order here (rather than in input.zig glue)
/// makes it unit-testable.
pub const CloseDecision = enum {
    /// The browser side dock is up; close it first (its only keyboard close).
    close_browser,
    /// The focused terminal runs a full-screen program — strong modal.
    confirm_running_program,
    /// Closing the focused pane would close the whole window — press-again toast.
    window_press_again,
    /// Closing the focused terminal pane — modal so a stray shortcut can't drop it.
    confirm_terminal,
    /// Nothing to guard (e.g. a preview pane): close immediately.
    close_now,
};

pub const CloseContext = struct {
    browser_visible: bool,
    /// `confirm-close-running-program` setting.
    confirm_running_enabled: bool,
    has_running_program: bool,
    /// Closing the focused pane would close the last pane / the window.
    would_close_window: bool,
    /// The focused pane is a terminal (vs a preview or an empty/non-terminal tab).
    focused_is_terminal: bool,
};

/// Decide what a Ctrl+Shift+W press should do. Preview panes fall through to
/// `close_now`; terminal panes are guarded (running-program modal > window
/// press-again > terminal modal) so they are never closed by a single stray key.
pub fn decideClose(ctx: CloseContext) CloseDecision {
    if (ctx.browser_visible) return .close_browser;
    if (shouldConfirm(ctx.confirm_running_enabled, ctx.has_running_program)) return .confirm_running_program;
    if (ctx.would_close_window) return .window_press_again;
    if (ctx.focused_is_terminal) return .confirm_terminal;
    return .close_now;
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

test "decideClose closes a focused preview pane with no confirmation" {
    // The whole point of the new guard: a preview pane still closes on one press.
    try std.testing.expectEqual(CloseDecision.close_now, decideClose(.{
        .browser_visible = false,
        .confirm_running_enabled = true,
        .has_running_program = false,
        .would_close_window = false,
        .focused_is_terminal = false,
    }));
}

test "decideClose asks to confirm closing a plain focused terminal pane" {
    try std.testing.expectEqual(CloseDecision.confirm_terminal, decideClose(.{
        .browser_visible = false,
        .confirm_running_enabled = true,
        .has_running_program = false,
        .would_close_window = false,
        .focused_is_terminal = true,
    }));
}

test "decideClose prioritizes browser, then running program, then window close" {
    const base: CloseContext = .{
        .browser_visible = false,
        .confirm_running_enabled = true,
        .has_running_program = false,
        .would_close_window = false,
        .focused_is_terminal = true,
    };

    // Browser dock wins over everything.
    var ctx = base;
    ctx.browser_visible = true;
    ctx.has_running_program = true;
    try std.testing.expectEqual(CloseDecision.close_browser, decideClose(ctx));

    // A running program shows the strong modal, ahead of the plain terminal guard.
    ctx = base;
    ctx.has_running_program = true;
    try std.testing.expectEqual(CloseDecision.confirm_running_program, decideClose(ctx));

    // Disabling the setting drops back to the terminal-close modal.
    ctx = base;
    ctx.has_running_program = true;
    ctx.confirm_running_enabled = false;
    try std.testing.expectEqual(CloseDecision.confirm_terminal, decideClose(ctx));

    // Closing the last pane keeps the existing window press-again affordance.
    ctx = base;
    ctx.would_close_window = true;
    try std.testing.expectEqual(CloseDecision.window_press_again, decideClose(ctx));
}
