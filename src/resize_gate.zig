//! Decides when a surface's computed grid size is forwarded to the IO
//! thread (PTY setSize + terminal resize). Pure, main-thread-only state.
//!
//! Issue #171: during an interactive drag (window border, split divider,
//! side-panel edge) the per-frame layout produces a burst of grid changes
//! (~every 30ms, 20+ per drag). For an SSH surface each PTY resize reaches
//! the remote shell one network round-trip later, so its SIGWINCH prompt
//! redraw comes back tuned for a grid the terminal has already left. A
//! long (wrapping) prompt then re-wraps at the wrong width, every overflow
//! line forces a scroll, and the scrollback floods with interleaved prompt
//! fragments while reflow re-wraps the damage on each step. Local ConPTY
//! shells survive the same burst because their redraw round-trip is
//! sub-millisecond; short prompts survive because no redraw line crosses an
//! intermediate width.
//!
//! The gate collapses the burst: while `hold` is true (an interactive drag
//! is in progress) nothing is queued, and the first non-held submit flushes
//! the latest grid once. Layout re-submits every frame, so the flush needs
//! no explicit drag-end hook. Deduplication against the last queued grid
//! also means a drag that returns to its starting size queues nothing.

pub const Grid = struct {
    cols: u16,
    rows: u16,

    pub fn eql(a: Grid, b: Grid) bool {
        return a.cols == b.cols and a.rows == b.rows;
    }
};

pub const ResizeGate = struct {
    /// The grid the IO thread was last told about (terminal + PTY size).
    last_queued: Grid,

    pub fn init(cols: u16, rows: u16) ResizeGate {
        return .{ .last_queued = .{ .cols = cols, .rows = rows } };
    }

    /// Decide whether `grid` should be queued to the IO thread now.
    /// Returns the grid to queue, or null to skip this frame.
    pub fn submit(self: *ResizeGate, hold: bool, grid: Grid) ?Grid {
        if (hold) return null;
        if (grid.eql(self.last_queued)) return null;
        self.last_queued = grid;
        return grid;
    }
};

const std = @import("std");

test "queues a changed grid and dedupes repeats" {
    var gate = ResizeGate.init(80, 24);
    const queued = gate.submit(false, .{ .cols = 100, .rows = 30 });
    try std.testing.expect(queued != null);
    try std.testing.expectEqual(@as(u16, 100), queued.?.cols);
    try std.testing.expectEqual(@as(u16, 30), queued.?.rows);
    // Same grid again: nothing to queue (layout re-submits every frame).
    try std.testing.expect(gate.submit(false, .{ .cols = 100, .rows = 30 }) == null);
}

test "initial grid is the baseline: no spurious resize on first submit" {
    var gate = ResizeGate.init(142, 49);
    try std.testing.expect(gate.submit(false, .{ .cols = 142, .rows = 49 }) == null);
}

test "held submits queue nothing" {
    var gate = ResizeGate.init(142, 49);
    // Drag in progress: a burst of intermediate sizes is parked.
    try std.testing.expect(gate.submit(true, .{ .cols = 94, .rows = 49 }) == null);
    try std.testing.expect(gate.submit(true, .{ .cols = 74, .rows = 49 }) == null);
    try std.testing.expect(gate.submit(true, .{ .cols = 60, .rows = 49 }) == null);
}

test "first non-held submit flushes the final grid once" {
    var gate = ResizeGate.init(142, 49);
    try std.testing.expect(gate.submit(true, .{ .cols = 94, .rows = 49 }) == null);
    try std.testing.expect(gate.submit(true, .{ .cols = 60, .rows = 49 }) == null);
    // Drag ended; layout re-submits the final grid without hold.
    const queued = gate.submit(false, .{ .cols = 60, .rows = 49 });
    try std.testing.expect(queued != null);
    try std.testing.expectEqual(@as(u16, 60), queued.?.cols);
    // Steady state afterwards: deduped.
    try std.testing.expect(gate.submit(false, .{ .cols = 60, .rows = 49 }) == null);
}

test "drag that returns to the starting size queues nothing" {
    var gate = ResizeGate.init(142, 49);
    try std.testing.expect(gate.submit(true, .{ .cols = 90, .rows = 49 }) == null);
    try std.testing.expect(gate.submit(true, .{ .cols = 120, .rows = 49 }) == null);
    // Released exactly where it started: terminal is already that size.
    try std.testing.expect(gate.submit(false, .{ .cols = 142, .rows = 49 }) == null);
}
