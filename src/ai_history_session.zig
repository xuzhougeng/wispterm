const std = @import("std");
const types = @import("ai_history_types.zig");
const source_mod = @import("ai_history_source.zig");

pub const LoadState = enum { idle, scanning, ready, failed };

pub const Session = struct {
    /// Allocator used for row storage. Do not change while rows are live.
    allocator: std.mem.Allocator,
    /// Source is stored shallowly; nested string slices must outlive Session.
    source: source_mod.Source,
    state: LoadState = .idle,
    /// Rows shallow-copy SessionMeta values. All string slices inside each row
    /// are borrowed and must outlive these rows until replacement or deinit.
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    selected: usize = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    status: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source: source_mod.Source) Session {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Session) void {
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginScan(self: *Session) void {
        self.state = .scanning;
        self.status = "Scanning";
    }

    /// Replaces rows with shallow copies of `rows`. SessionMeta string slices
    /// remain borrowed; callers must keep them alive until replacement/deinit.
    pub fn replaceRows(self: *Session, rows: []const types.SessionMeta) !void {
        var next: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
        errdefer next.deinit(self.allocator);

        try next.appendSlice(self.allocator, rows);
        std.mem.sort(types.SessionMeta, next.items, {}, types.lessRecent);

        self.rows.deinit(self.allocator);
        self.rows = next;
        self.selected = 0;
        self.state = .ready;
        self.status = "Ready";
    }

    pub fn setFilter(self: *Session, text: []const u8) void {
        self.filter_len = @min(text.len, self.filter.len);
        @memcpy(self.filter[0..self.filter_len], text[0..self.filter_len]);
        self.selected = 0;
    }

    pub fn visibleCount(self: *const Session) usize {
        var count: usize = 0;
        const query = self.filter[0..self.filter_len];
        for (self.rows.items) |row| {
            if (types.metadataMatches(row, query)) count += 1;
        }
        return count;
    }

    /// Returns a shallow SessionMeta copy. Its string slices are borrowed from
    /// the stored rows and follow the same replacement/deinit lifetime.
    pub fn selectedVisible(self: *const Session) ?types.SessionMeta {
        const query = self.filter[0..self.filter_len];
        var visible_index: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, query)) continue;
            if (visible_index == self.selected) return row;
            visible_index += 1;
        }
        return null;
    }
};

test "ai_history_session: replacing rows sorts by last active time" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "old",
            .title = "Old",
            .source_path = "old.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
        .{
            .provider = .codex,
            .session_id = "new",
            .title = "New",
            .source_path = "new.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try session.replaceRows(&rows);

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id);
}

test "ai_history_session: metadata filter controls visible rows" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
        .{
            .provider = .claude,
            .session_id = "b",
            .title = "Docs",
            .project_dir = "/repo/docs",
            .source_path = "b.jsonl",
            .resume_kind = .claude_resume,
        },
    };

    try session.replaceRows(&rows);
    session.setFilter("docs");

    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const selected = session.selectedVisible() orelse return error.ExpectedSelectedSession;
    try std.testing.expectEqualStrings("b", selected.session_id);
}

test "ai_history_session: replace rows preserves existing state on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var session = Session.init(failing_allocator.allocator(), .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const existing = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "kept",
            .title = "Kept",
            .source_path = "kept.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
    };
    try session.replaceRows(&existing);
    session.status = "Existing";

    const replacement = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "new-a",
            .title = "New A",
            .source_path = "new-a.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 30,
        },
        .{
            .provider = .codex,
            .session_id = "new-b",
            .title = "New B",
            .source_path = "new-b.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try std.testing.expectError(error.OutOfMemory, session.replaceRows(&replacement));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("kept", session.rows.items[0].session_id);
    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Existing", session.status);
}

test "ai_history_session: selected visible returns null when selection is unavailable" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectEqual(null, session.selectedVisible());

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
    };
    try session.replaceRows(&rows);

    session.setFilter("missing");
    try std.testing.expectEqual(@as(usize, 0), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());

    session.setFilter("");
    session.selected = 1;
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());
}

test "ai_history_session: filter truncates to fixed buffer length" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    var long_filter: [130]u8 = undefined;
    @memset(&long_filter, 'x');
    long_filter[128] = 'y';
    long_filter[129] = 'z';

    session.setFilter(&long_filter);

    try std.testing.expectEqual(@as(usize, 128), session.filter_len);
    try std.testing.expectEqualSlices(u8, long_filter[0..128], session.filter[0..session.filter_len]);
}
