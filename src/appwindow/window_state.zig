const std = @import("std");

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const PendingResize = struct {
    pending: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    last_ms: i64 = 0,
};

pub const State = struct {
    present_bringup_settled: bool = false,
    pending_resize: PendingResize = .{},
    layout_resize_immediate: bool = false,

    pub fn requestImmediateLayoutResize(self: *State) void {
        self.layout_resize_immediate = true;
    }

    pub fn consumeImmediateLayoutResize(self: *State) bool {
        const immediate = self.layout_resize_immediate;
        self.layout_resize_immediate = false;
        return immediate;
    }

    pub fn queueResize(self: *State, cols: u16, rows: u16, now_ms: i64) void {
        self.pending_resize = .{ .pending = true, .cols = cols, .rows = rows, .last_ms = now_ms };
    }

    pub fn clearPendingResize(self: *State) void {
        self.pending_resize.pending = false;
    }

    pub fn consumeCoalescedResize(self: *State, now_ms: i64, interval_ms: i64, current_cols: u16, current_rows: u16) ?GridSize {
        if (!self.pending_resize.pending) return null;
        if (now_ms - self.pending_resize.last_ms < interval_ms) return null;
        const next = GridSize{ .cols = self.pending_resize.cols, .rows = self.pending_resize.rows };
        self.pending_resize.pending = false;
        if (next.cols == current_cols and next.rows == current_rows) return null;
        return next;
    }

    pub fn takePresentBringupSettlement(self: *State) bool {
        if (self.present_bringup_settled) return false;
        self.present_bringup_settled = true;
        return true;
    }
};

test "window state pending resize coalesces and ignores unchanged grid" {
    var state = State{};

    state.queueResize(100, 40, 1_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(1_010, 25, 80, 24));
    try std.testing.expect(state.pending_resize.pending);

    const consumed = state.consumeCoalescedResize(1_030, 25, 80, 24).?;
    try std.testing.expectEqual(@as(u16, 100), consumed.cols);
    try std.testing.expectEqual(@as(u16, 40), consumed.rows);
    try std.testing.expect(!state.pending_resize.pending);

    state.queueResize(100, 40, 2_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(2_030, 25, 100, 40));
    try std.testing.expect(!state.pending_resize.pending);
}

test "window state immediate layout resize is one-shot" {
    var state = State{};

    state.requestImmediateLayoutResize();
    try std.testing.expect(state.layout_resize_immediate);
    try std.testing.expect(state.consumeImmediateLayoutResize());
    try std.testing.expect(!state.consumeImmediateLayoutResize());
}

test "window state present bringup settlement fires once" {
    var state = State{};

    try std.testing.expect(state.takePresentBringupSettlement());
    try std.testing.expect(!state.takePresentBringupSettlement());
}
