//! Single owner of the "close shortcut second-confirm" deadline.
//!
//! Pressing the close shortcut (Ctrl+Shift+W) on the last pane shows a
//! press-again toast that stays armed until a deadline. The deadline used to
//! live in two separate threadlocal globals (input.zig glue + overlays.zig
//! render) that could desync; this module owns the single source of truth.
//!
//! This module is deliberately neutral: it imports neither AppWindow, the input
//! layer, nor the renderer. Previously this state lived under `src/input/` and
//! the renderer reached back into the input layer to read it, an unwanted
//! reverse dependency. It now lives under `src/ui/` so both the input glue
//! (which arms/clears it) and the renderer (which reads/renders it) can share it
//! without either depending on the other.
//!
//! NOTE: distinct from `src/close_confirm.zig`, which holds the *pure decision
//! logic* (decideClose / shouldConfirm). This module holds only the *deadline
//! state*. They are imported under different aliases at each call site.

const std = @import("std");

/// The "close shortcut second-confirm" deadline state. Kept as an explicit
/// struct so ownership can later move onto an OverlayState-owned instance; for
/// now a single process-wide threadlocal `instance` preserves the original
/// design and keeps this PR minimal.
pub const State = struct {
    until_ms: i64 = 0,

    /// Arm the confirm window so it stays active until `now_ms + duration_ms`.
    pub fn show(self: *State, now_ms: i64, duration_ms: i64) void {
        self.until_ms = now_ms + duration_ms;
    }

    /// Disarm the confirm window.
    pub fn clear(self: *State) void {
        self.until_ms = 0;
    }

    /// Whether the confirm window is still armed at `now_ms`. Matches the
    /// existing `now < deadline` comparison exactly.
    pub fn isActive(self: *const State, now_ms: i64) bool {
        return now_ms < self.until_ms;
    }

    /// The deadline as an optional, or null when disarmed.
    pub fn expiresAt(self: *const State) ?i64 {
        if (self.until_ms == 0) return null;
        return self.until_ms;
    }

    /// Raw deadline value, for the overlays save/restore pattern.
    pub fn deadline(self: *const State) i64 {
        return self.until_ms;
    }

    /// Restore a previously saved raw deadline value.
    pub fn setDeadline(self: *State, value: i64) void {
        self.until_ms = value;
    }
};

/// Process-wide instance. Threadlocal to preserve the original ownership model.
pub threadlocal var instance: State = .{};

/// Arm the confirm window so it stays active until `now_ms + duration_ms`.
pub fn show(now_ms: i64, duration_ms: i64) void {
    instance.show(now_ms, duration_ms);
}

/// Disarm the confirm window.
pub fn clear() void {
    instance.clear();
}

/// Whether the confirm window is still armed at `now_ms`. Matches the existing
/// `now < deadline` comparison exactly.
pub fn isActive(now_ms: i64) bool {
    return instance.isActive(now_ms);
}

/// The deadline as an optional, or null when disarmed.
pub fn expiresAt() ?i64 {
    return instance.expiresAt();
}

/// Raw deadline value, for the overlays save/restore pattern.
pub fn deadline() i64 {
    return instance.deadline();
}

/// Restore a previously saved raw deadline value.
pub fn setDeadline(value: i64) void {
    instance.setDeadline(value);
}

test "show arms the confirm window and isActive tracks the deadline" {
    var s: State = .{};
    s.show(1000, 5000);
    // Active strictly before the deadline.
    try std.testing.expect(s.isActive(1000));
    try std.testing.expect(s.isActive(5999));
    // Inactive at or after the deadline (now < deadline is false here).
    try std.testing.expect(!s.isActive(6000));
    try std.testing.expect(!s.isActive(6001));
}

test "clear disarms the confirm window" {
    var s: State = .{};
    s.show(0, 5000);
    try std.testing.expect(s.isActive(0));
    s.clear();
    try std.testing.expect(!s.isActive(0));
}

test "expiresAt is null when cleared and the deadline otherwise" {
    var s: State = .{};
    try std.testing.expectEqual(@as(?i64, null), s.expiresAt());
    s.show(1000, 5000);
    try std.testing.expectEqual(@as(?i64, 6000), s.expiresAt());
}

test "deadline and setDeadline round-trip the raw value" {
    var s: State = .{};
    s.show(1000, 5000);
    const saved = s.deadline();
    try std.testing.expectEqual(@as(i64, 6000), saved);
    s.clear();
    try std.testing.expectEqual(@as(i64, 0), s.deadline());
    s.setDeadline(saved);
    try std.testing.expectEqual(@as(i64, 6000), s.deadline());
    try std.testing.expect(s.isActive(5999));
}

test "module-level fns delegate to the threadlocal instance" {
    clear();
    show(1000, 5000);
    try std.testing.expect(isActive(1000));
    try std.testing.expect(isActive(5999));
    try std.testing.expect(!isActive(6000));
    try std.testing.expectEqual(@as(?i64, 6000), expiresAt());
    const saved = deadline();
    clear();
    try std.testing.expectEqual(@as(i64, 0), deadline());
    setDeadline(saved);
    try std.testing.expectEqual(@as(i64, 6000), deadline());
    // restore a clean slate for any subsequent tests in this threadlocal
    clear();
    try std.testing.expectEqual(@as(?i64, null), expiresAt());
}
