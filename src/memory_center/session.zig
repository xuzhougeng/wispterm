const std = @import("std");
const memory_viewer = @import("../memory_viewer.zig");

pub const Source = memory_viewer.Source;

pub const Session = struct {
    source: Source = .remembered,
    selected: usize = 0,
    detail_scroll: usize = 0,
    snapshot: ?memory_viewer.Snapshot = null,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Session {
        var self = Session{};
        self.reload(allocator);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.clearSnapshot();
        self.status_len = 0;
        self.selected = 0;
        self.detail_scroll = 0;
    }

    pub fn reload(self: *Session, allocator: std.mem.Allocator) void {
        self.clearSnapshot();
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

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn count(self: *const Session) usize {
        const snapshot = self.snapshot orelse return 0;
        return snapshot.count(self.source);
    }

    pub fn selectedRow(self: *const Session) ?*const memory_viewer.Row {
        const snapshot = self.snapshot orelse return null;
        return snapshot.rowAt(self.source, self.selected);
    }

    pub fn setSource(self: *Session, source: Source) void {
        if (self.source == source) return;
        self.source = source;
        self.selected = 0;
        self.detail_scroll = 0;
        self.clamp();
    }

    pub fn cycleSource(self: *Session, delta: isize) void {
        if (delta == 0) return;
        self.setSource(switch (self.source) {
            .remembered => .digest,
            .digest => .remembered,
        });
    }

    pub fn moveSelection(self: *Session, delta: isize) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
            self.detail_scroll = 0;
            return;
        }
        const current: isize = @intCast(self.selected);
        const max_index: isize = @intCast(n - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.selected = @intCast(next);
        self.detail_scroll = 0;
    }

    pub fn selectIndex(self: *Session, index: usize) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
            self.detail_scroll = 0;
            return;
        }
        self.selected = @min(index, n - 1);
        self.detail_scroll = 0;
    }

    pub fn scrollDetailBy(self: *Session, delta: isize) void {
        if (delta < 0) {
            const step: usize = @intCast(-delta);
            self.detail_scroll = if (self.detail_scroll > step) self.detail_scroll - step else 0;
        } else {
            self.detail_scroll += @intCast(delta);
        }
    }

    pub fn listWindowStart(self: *const Session, visible_rows: usize) usize {
        if (visible_rows == 0 or self.selected < visible_rows) return 0;
        return self.selected - visible_rows + 1;
    }

    fn clearSnapshot(self: *Session) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    fn clamp(self: *Session) void {
        const n = self.count();
        if (n == 0) {
            self.selected = 0;
        } else if (self.selected >= n) {
            self.selected = n - 1;
        }
    }
};

test "memory center session switches source and clamps selection" {
    var state = Session{};

    state.selected = 4;
    state.setSource(.digest);
    try std.testing.expectEqual(Source.digest, state.source);
    try std.testing.expectEqual(@as(usize, 0), state.selected);

    state.scrollDetailBy(8);
    try std.testing.expectEqual(@as(usize, 8), state.detail_scroll);
    state.scrollDetailBy(-3);
    try std.testing.expectEqual(@as(usize, 5), state.detail_scroll);
}
