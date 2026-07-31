const std = @import("std");
const memory_digest_scheduler = @import("../memory_digest/scheduler.zig");
const memory_viewer = @import("../memory_viewer.zig");

pub const Source = memory_viewer.Source;

pub const DigestStatus = enum { in_progress, success, failed, skipped };

pub const DigestNotification = struct {
    status: DigestStatus,
    message: []const u8,
};

pub const Session = struct {
    source: Source = .remembered,
    selected: usize = 0,
    detail_scroll: usize = 0,
    snapshot: ?memory_viewer.Snapshot = null,
    status_buf: [96]u8 = undefined,
    status_len: usize = 0,
    last_digest_progress_seq: u64 = 0,
    digest_status: DigestStatus = .in_progress,
    digest_status_buf: [160]u8 = undefined,
    digest_status_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Session {
        var self = Session{};
        self.reload(allocator);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.clearSnapshot();
        self.status_len = 0;
        self.digest_status_len = 0;
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

    /// Copies a newly published scheduler update into this tab's own UI state.
    pub fn syncDigestProgress(self: *Session, progress: memory_digest_scheduler.ProgressSnapshot) bool {
        if (!progress.visible or progress.seq == 0 or progress.seq == self.last_digest_progress_seq) return false;
        self.last_digest_progress_seq = progress.seq;

        var buf: [160]u8 = undefined;
        const message = switch (progress.stage) {
            .queued => "Memory digest queued",
            .scanning => "Memory digest: scanning chat logs",
            .summarizing => if (progress.detail().len != 0)
                std.fmt.bufPrint(&buf, "Memory digest: summarizing {s} ({d}/{d} done, {d} failed)", .{ progress.detail(), progress.sessions_done, progress.sessions_total, progress.sessions_failed }) catch "Memory digest: summarizing sessions"
            else
                std.fmt.bufPrint(&buf, "Memory digest: summarizing {d}/{d} ({d} failed)", .{ progress.sessions_done, progress.sessions_total, progress.sessions_failed }) catch "Memory digest: summarizing sessions",
            .finalizing => "Memory digest: writing digest files",
            .success => std.fmt.bufPrint(&buf, "Memory digest complete: {d} sessions, {d} days, {d} tokens", .{ progress.sessions_done, progress.days_written, progress.total_tokens }) catch "Memory digest complete",
            .failed => if (progress.detail().len != 0)
                std.fmt.bufPrint(&buf, "Memory digest failed: {s}", .{progress.detail()}) catch "Memory digest failed"
            else
                "Memory digest failed",
            .skipped => if (progress.detail().len != 0)
                std.fmt.bufPrint(&buf, "Memory digest skipped: {s}", .{progress.detail()}) catch "Memory digest skipped"
            else
                "Memory digest skipped",
            .idle => return false,
        };
        self.digest_status = switch (progress.stage) {
            .queued, .scanning, .summarizing, .finalizing => .in_progress,
            .success => .success,
            .failed => .failed,
            .skipped => .skipped,
            .idle => unreachable,
        };
        self.digest_status_len = @min(self.digest_status_buf.len, message.len);
        @memcpy(self.digest_status_buf[0..self.digest_status_len], message[0..self.digest_status_len]);
        return true;
    }

    pub fn digestNotification(self: *const Session) ?DigestNotification {
        if (self.digest_status_len == 0) return null;
        return .{ .status = self.digest_status, .message = self.digest_status_buf[0..self.digest_status_len] };
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

test "memory center session keeps digest progress in the tab" {
    var state = Session{};
    const progress = memory_digest_scheduler.ProgressSnapshot{
        .seq = 9,
        .visible = true,
        .stage = .success,
        .sessions_done = 3,
        .days_written = 1,
        .total_tokens = 42,
    };

    try std.testing.expect(state.syncDigestProgress(progress));
    try std.testing.expect(!state.syncDigestProgress(progress));
    const notification = state.digestNotification().?;
    try std.testing.expectEqual(DigestStatus.success, notification.status);
    try std.testing.expect(std.mem.indexOf(u8, notification.message, "3 sessions") != null);
}
