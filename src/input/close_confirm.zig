//! Single owner of the "close shortcut second-confirm" deadline.
//!
//! Pressing the close shortcut (Ctrl+Shift+W) on the last pane shows a
//! press-again toast that stays armed until a deadline. The deadline used to
//! live in two separate threadlocal globals (input.zig glue + overlays.zig
//! render) that could desync; this module owns the single source of truth.
//!
//! NOTE: distinct from `src/close_confirm.zig`, which holds the *pure decision
//! logic* (decideClose / shouldConfirm). This module holds only the *deadline
//! state*. They are imported under different aliases at each call site.

const std = @import("std");

threadlocal var g_until_ms: i64 = 0;

/// Arm the confirm window so it stays active until `now_ms + duration_ms`.
pub fn show(now_ms: i64, duration_ms: i64) void {
    g_until_ms = now_ms + duration_ms;
}

/// Disarm the confirm window.
pub fn clear() void {
    g_until_ms = 0;
}

/// Whether the confirm window is still armed at `now_ms`. Matches the existing
/// `now < deadline` comparison exactly.
pub fn isActive(now_ms: i64) bool {
    return now_ms < g_until_ms;
}

/// The deadline as an optional, or null when disarmed.
pub fn expiresAt() ?i64 {
    if (g_until_ms == 0) return null;
    return g_until_ms;
}

/// Raw deadline value, for the overlays save/restore pattern.
pub fn deadline() i64 {
    return g_until_ms;
}

/// Restore a previously saved raw deadline value.
pub fn setDeadline(value: i64) void {
    g_until_ms = value;
}

test "show arms the confirm window and isActive tracks the deadline" {
    clear();
    show(1000, 5000);
    // Active strictly before the deadline.
    try std.testing.expect(isActive(1000));
    try std.testing.expect(isActive(5999));
    // Inactive at or after the deadline (now < deadline is false here).
    try std.testing.expect(!isActive(6000));
    try std.testing.expect(!isActive(6001));
}

test "clear disarms the confirm window" {
    show(0, 5000);
    try std.testing.expect(isActive(0));
    clear();
    try std.testing.expect(!isActive(0));
}

test "expiresAt is null when cleared and the deadline otherwise" {
    clear();
    try std.testing.expectEqual(@as(?i64, null), expiresAt());
    show(1000, 5000);
    try std.testing.expectEqual(@as(?i64, 6000), expiresAt());
}

test "deadline and setDeadline round-trip the raw value" {
    clear();
    show(1000, 5000);
    const saved = deadline();
    try std.testing.expectEqual(@as(i64, 6000), saved);
    clear();
    try std.testing.expectEqual(@as(i64, 0), deadline());
    setDeadline(saved);
    try std.testing.expectEqual(@as(i64, 6000), deadline());
    try std.testing.expect(isActive(5999));
    // restore a clean slate for any subsequent tests in this threadlocal
    clear();
}
