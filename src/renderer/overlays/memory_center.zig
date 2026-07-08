const std = @import("std");
const input_key = @import("../../input/key.zig");
const memory_viewer = @import("../../memory_viewer.zig");

pub const Source = memory_viewer.Source;

pub const State = struct {
    visible: bool = false,
    source: Source = .remembered,
    selected: usize = 0,
    detail_scroll: usize = 0,
    snapshot: ?memory_viewer.Snapshot = null,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,

    pub fn open(self: *State, allocator: std.mem.Allocator) void {
        self.close();
        self.visible = true;
        self.source = .remembered;
        self.selected = 0;
        self.detail_scroll = 0;
        self.snapshot = memory_viewer.load(allocator) catch |err| {
            const msg = std.fmt.bufPrint(&self.status_buf, "Could not load memory: {s}", .{@errorName(err)}) catch "";
            self.status_len = msg.len;
            return;
        };
        self.status_len = 0;
        self.clamp();
    }

    pub fn close(self: *State) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
        self.visible = false;
        self.status_len = 0;
        self.selected = 0;
        self.detail_scroll = 0;
    }

    pub fn deinit(self: *State) void {
        self.close();
    }

    pub fn status(self: *const State) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn count(self: *const State) usize {
        const snapshot = self.snapshot orelse return 0;
        return snapshot.count(self.source);
    }

    pub fn selectedRow(self: *const State) ?*const memory_viewer.Row {
        const snapshot = self.snapshot orelse return null;
        return snapshot.rowAt(self.source, self.selected);
    }

    pub fn handleKey(self: *State, ev: input_key.KeyEvent) void {
        switch (ev.key) {
            .escape => self.close(),
            .tab, .arrow_left, .arrow_right => self.cycleSource(),
            .arrow_down => self.moveSelection(1),
            .arrow_up => self.moveSelection(-1),
            .page_down => self.detail_scroll += 5,
            .page_up => self.detail_scroll = if (self.detail_scroll > 5) self.detail_scroll - 5 else 0,
            else => {},
        }
    }

    pub fn handleScroll(self: *State, delta_y: f64) void {
        if (delta_y > 0) self.moveSelection(-1) else if (delta_y < 0) self.moveSelection(1);
    }

    fn cycleSource(self: *State) void {
        self.source = switch (self.source) {
            .remembered => .digest,
            .digest => .remembered,
        };
        self.selected = 0;
        self.detail_scroll = 0;
        self.clamp();
    }

    fn moveSelection(self: *State, delta: isize) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
            return;
        }
        const current: isize = @intCast(self.selected);
        const max_index: isize = @intCast(n - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.selected = @intCast(next);
        self.detail_scroll = 0;
    }

    fn clamp(self: *State) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
        } else if (self.selected >= n) {
            self.selected = n - 1;
        }
    }
};

test "memory center state switches source and clamps selection" {
    var state = State{};

    state.visible = true;
    state.handleKey(.{ .key = .tab });
    try std.testing.expectEqual(Source.digest, state.source);

    state.handleKey(.{ .key = .escape });
    try std.testing.expect(!state.visible);
}
