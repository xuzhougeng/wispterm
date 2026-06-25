//! Pure decision logic + state machine for terminal mouse-event reporting
//! (xterm 1000/1002/1003). Extracted from input.zig's handleMouseButton so the
//! "should this button event be reported to the focused terminal instead of
//! driving local selection?" decision is std-only and unit-testable.
//!
//! This module owns NO I/O: it does not touch a PTY, a surface mutex, focus, or
//! AppWindow. input.zig keeps all of that — it resolves the report target, sends
//! the encoded bytes, and updates focus — and uses this module only to (a) gate
//! which presses are eligible to begin reporting and (b) track the in-progress
//! reported-drag state across press/motion/release.
//!
//! The state is generic over the surface pointer type so the module never has to
//! import Surface.zig or AppWindow.zig.
const std = @import("std");

const mouse_report = @import("mouse_report.zig");

pub const Button = mouse_report.Button;

/// Outcome of routing one button event through the terminal-mouse-report path.
pub const MouseButtonOutcome = enum {
    /// The event was NOT consumed by terminal reporting; the caller should fall
    /// through to local handling (selection / paste / chrome hit-tests).
    not_handled,
    /// The event was consumed by terminal reporting; the caller should send the
    /// encoded report (begin/finish details are in the returned action) and
    /// early-return from handleMouseButton.
    reported_to_terminal,
};

/// Modifier state for a button event, as the press-gate predicate sees it.
pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    /// True when the platform's primary "open link / preview" modifier is held
    /// (Cmd on macOS, Ctrl elsewhere). input.zig computes this via
    /// terminal_link_action.primaryOpenMod so the rule stays platform-correct
    /// without this module importing builtin.target.
    primary_open: bool = false,
};

/// The gate that handleMouseButton applies before a PRESS may begin reporting:
/// Shift must be up (Shift forces the terminal's own local selection) and the
/// link-open modifier must not be held on its own (Ctrl/Cmd without Alt keeps
/// opening links/previews through the local path). Alt being held alongside the
/// open modifier still allows reporting, matching the original
/// `!shift and !(primaryOpenMod and !alt)` predicate byte-for-byte.
pub fn pressShouldReport(mods: Mods) bool {
    return !mods.shift and !(mods.primary_open and !mods.alt);
}

/// A cell coordinate, used to deduplicate streamed drag-motion reports.
pub const Cell = struct { col: usize, row: usize };

/// Tracks an in-progress reported drag for one window/thread. input.zig owns a
/// single instance (threadlocal) and drives it; `Surface` is the caller's
/// surface pointer type, kept opaque here.
pub fn TerminalMouseReportState(comptime SurfacePtr: type) type {
    return struct {
        const Self = @This();

        button: ?Button = null,
        surface: ?SurfacePtr = null,
        last_cell: ?Cell = null,

        /// Record that a reported press has begun on `surface` with `button`.
        /// Clears any stale last-cell so the first motion always reports.
        pub fn begin(self: *Self, surface: SurfacePtr, button: Button) void {
            self.button = button;
            self.surface = surface;
            self.last_cell = null;
        }

        /// Result of a release: whether a matching reported press was in
        /// progress and, if so, which surface + button the caller must send the
        /// release report to. The state is cleared as a side effect when matched.
        pub const ReleaseResult = struct {
            matched: bool,
            surface: ?SurfacePtr = null,
            button: Button = .left,
        };

        /// Attempt to finish a reported drag on release of `button`. Returns
        /// matched=false (and leaves state untouched) when no reported press is
        /// active or a different button is released — so a stray release never
        /// clears an unrelated in-progress drag. On a match, clears all state and
        /// returns the surface/button the caller should send the release to.
        pub fn finishRelease(self: *Self, button: Button) ReleaseResult {
            const active_button = self.button orelse return .{ .matched = false };
            if (active_button != button) return .{ .matched = false };
            const surface = self.surface;
            self.button = null;
            self.surface = null;
            self.last_cell = null;
            return .{ .matched = true, .surface = surface, .button = active_button };
        }

        /// True while a reported press is held. When set, `button`/`surface` are
        /// the active drag; the caller streams motion reports.
        pub fn active(self: *const Self) ?Button {
            return self.button;
        }

        pub fn activeSurface(self: *const Self) ?SurfacePtr {
            return self.surface;
        }

        /// Note that motion reached `cell`; returns true when the cell changed
        /// since the last reported motion (so the caller should emit a report)
        /// and false when it is a duplicate to be skipped. Records the new cell.
        pub fn motionShouldReport(self: *Self, cell: Cell) bool {
            if (self.last_cell) |last| {
                if (last.col == cell.col and last.row == cell.row) return false;
            }
            self.last_cell = cell;
            return true;
        }

        /// Drop all reported-drag state (used on focus loss / surface teardown).
        pub fn clear(self: *Self) void {
            self.button = null;
            self.surface = null;
            self.last_cell = null;
        }
    };
}

test "pressShouldReport: plain press reports" {
    try std.testing.expect(pressShouldReport(.{}));
}

test "pressShouldReport: shift forces local selection" {
    try std.testing.expect(!pressShouldReport(.{ .shift = true }));
    try std.testing.expect(!pressShouldReport(.{ .shift = true, .alt = true }));
    try std.testing.expect(!pressShouldReport(.{ .shift = true, .primary_open = true }));
}

test "pressShouldReport: primary-open modifier alone opens links locally" {
    try std.testing.expect(!pressShouldReport(.{ .primary_open = true }));
}

test "pressShouldReport: primary-open + alt still reports" {
    try std.testing.expect(pressShouldReport(.{ .primary_open = true, .alt = true }));
}

test "pressShouldReport: alt alone reports" {
    try std.testing.expect(pressShouldReport(.{ .alt = true }));
}

const TestSurface = struct { id: u32 };
const TestState = TerminalMouseReportState(*TestSurface);

test "state: release with no active press does not match" {
    var s = TestState{};
    const r = s.finishRelease(.left);
    try std.testing.expect(!r.matched);
    try std.testing.expectEqual(@as(?Button, null), s.active());
}

test "state: begin then matching release reports to same surface" {
    var surf = TestSurface{ .id = 7 };
    var s = TestState{};
    s.begin(&surf, .left);
    try std.testing.expectEqual(@as(?Button, .left), s.active());
    try std.testing.expectEqual(@as(?*TestSurface, &surf), s.activeSurface());

    const r = s.finishRelease(.left);
    try std.testing.expect(r.matched);
    try std.testing.expectEqual(@as(?*TestSurface, &surf), r.surface);
    try std.testing.expectEqual(Button.left, r.button);
    // State cleared after a matched release.
    try std.testing.expectEqual(@as(?Button, null), s.active());
}

test "state: release of a different button does not finish the drag" {
    var surf = TestSurface{ .id = 1 };
    var s = TestState{};
    s.begin(&surf, .left);
    const r = s.finishRelease(.right);
    try std.testing.expect(!r.matched);
    // Left drag still in progress.
    try std.testing.expectEqual(@as(?Button, .left), s.active());
}

test "state: motion dedupes by cell" {
    var surf = TestSurface{ .id = 2 };
    var s = TestState{};
    s.begin(&surf, .left);
    // begin clears last_cell, so the first motion always reports.
    try std.testing.expect(s.motionShouldReport(.{ .col = 3, .row = 4 }));
    // Same cell is a duplicate.
    try std.testing.expect(!s.motionShouldReport(.{ .col = 3, .row = 4 }));
    // A new cell reports again.
    try std.testing.expect(s.motionShouldReport(.{ .col = 3, .row = 5 }));
}

test "state: clear drops active drag" {
    var surf = TestSurface{ .id = 9 };
    var s = TestState{};
    s.begin(&surf, .middle);
    s.clear();
    try std.testing.expectEqual(@as(?Button, null), s.active());
    try std.testing.expectEqual(@as(?*TestSurface, null), s.activeSurface());
}
