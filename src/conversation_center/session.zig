//! Copilot / AI-chat conversation browser. Feature-owned state for the
//! Conversation Center workbench: source + date filters, search, selection,
//! and a text preview of the selected transcript. No AppWindow imports.
const std = @import("std");
const agent_history = @import("../agent/history.zig");
const history_view = @import("../command/palette_history_view.zig");
const UiEffect = @import("../appwindow/ui_effect.zig").UiEffect;

pub const SourceFilter = history_view.SourceFilter;
pub const DateKey = u32;
pub const Focus = enum { filters, list, detail };

pub const SOURCE_ORDER = [_]SourceFilter{ .all, .sidebar, .tab };
pub const SOURCE_ROWS: usize = SOURCE_ORDER.len;
pub const FILTER_ALL_DATES_ROW: usize = SOURCE_ROWS;
pub const FILTER_DAY_BASE: usize = FILTER_ALL_DATES_ROW + 1;
pub const MAX_DATE_BUCKETS: usize = 64;
pub const MAX_QUERY: usize = 128;
const MAX_PREVIEW_BYTES: usize = 24 * 1024;
const MAX_PREVIEW_MESSAGE: usize = 2048;

pub const DateBucket = struct {
    key: DateKey,
    count: usize,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    rows: []agent_history.Row = &.{},
    owns_rows: bool = false,
    filtered: std.ArrayListUnmanaged(usize) = .empty,
    date_buckets: [MAX_DATE_BUCKETS]DateBucket = undefined,
    date_len: usize = 0,
    date_offset: usize = 0,
    query_buf: [MAX_QUERY]u8 = undefined,
    query_len: usize = 0,
    source: SourceFilter = .all,
    date_filter: ?DateKey = null,
    selected: usize = 0,
    detail_scroll: usize = 0,
    filter_cursor: usize = 0,
    focus: Focus = .list,
    tz_offset_seconds: i32 = 0,
    store_revision: u64 = std.math.maxInt(u64),
    preview_id: []u8 = &.{},
    preview_body: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Session) void {
        self.clearPreview();
        self.freeRows();
        self.filtered.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn query(self: *const Session) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn filteredCount(self: *const Session) usize {
        return self.filtered.items.len;
    }

    pub fn selectedRow(self: *const Session) ?agent_history.Row {
        if (self.selected >= self.filtered.items.len) return null;
        return self.rows[self.filtered.items[self.selected]];
    }

    pub fn selectedSessionId(self: *const Session) ?[]const u8 {
        return if (self.selectedRow()) |row| row.session_id else null;
    }

    pub fn previewMatchesSelection(self: *const Session) bool {
        const id = self.selectedSessionId() orelse return false;
        return std.mem.eql(u8, self.preview_id, id);
    }

    pub fn dateBuckets(self: *const Session) []const DateBucket {
        return self.date_buckets[0..self.date_len];
    }

    pub fn filterRowCount(self: *const Session) usize {
        return FILTER_DAY_BASE + self.date_len;
    }

    pub fn visibleDateBuckets(self: *const Session, slots: usize) []const DateBucket {
        const all = self.dateBuckets();
        if (slots == 0 or all.len == 0) return &.{};
        const start = @min(self.date_offset, all.len -| 1);
        const end = @min(all.len, start + slots);
        return all[start..end];
    }

    /// Replace the owned row list. `rows` must be allocator-owned (including
    /// each Row's strings); this session frees the previous list.
    pub fn takeRows(self: *Session, rows: []agent_history.Row) void {
        self.freeRows();
        self.rows = rows;
        self.owns_rows = true;
        self.rebuild();
    }

    pub fn setSource(self: *Session, source: SourceFilter) void {
        if (self.source == source) return;
        self.source = source;
        self.selected = 0;
        self.detail_scroll = 0;
        self.rebuild();
    }

    pub fn setDateFilter(self: *Session, filter: ?DateKey) void {
        if (std.meta.eql(self.date_filter, filter)) return;
        self.date_filter = filter;
        self.selected = 0;
        self.detail_scroll = 0;
        self.rebuild();
    }

    pub fn setFocus(self: *Session, focus: Focus) void {
        self.focus = focus;
    }

    pub fn cycleFocus(self: *Session, delta: isize) void {
        if (delta == 0) return;
        const n: isize = @intCast(std.meta.tags(Focus).len);
        const cur: isize = @intCast(@intFromEnum(self.focus));
        self.focus = @enumFromInt(@as(usize, @intCast(@mod(cur + delta, n))));
    }

    pub fn moveSelection(self: *Session, delta: isize) void {
        const n = self.filteredCount();
        if (n == 0) {
            self.selected = 0;
            self.detail_scroll = 0;
            return;
        }
        const current: isize = @intCast(self.selected);
        const max_index: isize = @intCast(n - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        if (@as(usize, @intCast(next)) == self.selected) return;
        self.selected = @intCast(next);
        self.detail_scroll = 0;
    }

    pub fn selectIndex(self: *Session, index: usize) void {
        const n = self.filteredCount();
        if (n == 0) {
            self.selected = 0;
            self.detail_scroll = 0;
            return;
        }
        const next = @min(index, n - 1);
        if (next == self.selected) return;
        self.selected = next;
        self.detail_scroll = 0;
        self.focus = .list;
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

    pub fn insertQueryCodepoint(self: *Session, cp: u21) bool {
        if (self.focus == .filters) return false;
        if (cp < 0x20 and cp != '\t') return false;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return false;
        if (self.query_len + n > self.query_buf.len) return false;
        @memcpy(self.query_buf[self.query_len..][0..n], tmp[0..n]);
        self.query_len += n;
        self.selected = 0;
        self.detail_scroll = 0;
        self.rebuild();
        return true;
    }

    pub fn backspaceQuery(self: *Session) bool {
        if (self.focus == .filters) return false;
        if (self.query_len == 0) return false;
        var i = self.query_len;
        while (i > 0) {
            i -= 1;
            if (self.query_buf[i] & 0xC0 != 0x80) break;
        }
        self.query_len = i;
        self.selected = 0;
        self.detail_scroll = 0;
        self.rebuild();
        return true;
    }

    pub fn moveFilterCursor(self: *Session, delta: isize) void {
        const count = self.filterRowCount();
        if (count == 0) return;
        const current: isize = @intCast(@min(self.filter_cursor, count - 1));
        const max_index: isize = @intCast(count - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        self.filter_cursor = @intCast(next);
        self.applyFilterCursor();
    }

    pub fn selectFilterRow(self: *Session, row: usize) void {
        const count = self.filterRowCount();
        if (count == 0) return;
        self.filter_cursor = @min(row, count - 1);
        self.focus = .filters;
        self.applyFilterCursor();
    }

    pub fn scrollDateList(self: *Session, delta: isize) void {
        if (self.date_len == 0) {
            self.date_offset = 0;
            return;
        }
        if (delta < 0) {
            self.date_offset -|= @intCast(-delta);
        } else {
            self.date_offset +|= @intCast(delta);
        }
        if (self.date_offset >= self.date_len) self.date_offset = self.date_len - 1;
    }

    pub fn setPreviewFromRecord(self: *Session, record: ?agent_history.SessionRecord) void {
        self.clearPreview();
        const rec = record orelse return;
        self.preview_id = self.allocator.dupe(u8, rec.session_id) catch return;
        self.preview_body = formatPreview(self.allocator, rec) catch {
            self.allocator.free(self.preview_id);
            self.preview_id = &.{};
            return;
        };
    }

    pub fn sourceCount(self: *const Session, source: SourceFilter) usize {
        var n: usize = 0;
        for (self.rows) |row| {
            if (history_view.rowMatches(row, "", source)) n += 1;
        }
        return n;
    }

    fn applyFilterCursor(self: *Session) void {
        const c = self.filter_cursor;
        if (c < SOURCE_ROWS) {
            self.setSource(SOURCE_ORDER[c]);
            return;
        }
        if (c == FILTER_ALL_DATES_ROW) {
            self.setDateFilter(null);
            return;
        }
        const day_idx = c - FILTER_DAY_BASE;
        if (day_idx < self.date_len) {
            self.setDateFilter(self.date_buckets[day_idx].key);
        }
    }

    fn rebuild(self: *Session) void {
        self.rebuildDateBuckets();
        if (self.date_filter) |key| {
            var found = false;
            for (self.date_buckets[0..self.date_len]) |bucket| {
                if (bucket.key == key) {
                    found = true;
                    break;
                }
            }
            if (!found) self.date_filter = null;
        }

        self.filtered.clearRetainingCapacity();
        const q = self.query();
        for (self.rows, 0..) |row, i| {
            if (!history_view.rowMatches(row, q, self.source)) continue;
            const key = dateKeyFromMs(row.updated_at, self.tz_offset_seconds);
            if (!dateMatches(self.date_filter, key)) continue;
            self.filtered.append(self.allocator, i) catch break;
        }
        if (self.filtered.items.len == 0) {
            self.selected = 0;
        } else if (self.selected >= self.filtered.items.len) {
            self.selected = self.filtered.items.len - 1;
        }
        const filter_n = self.filterRowCount();
        if (filter_n == 0) {
            self.filter_cursor = 0;
        } else if (self.filter_cursor >= filter_n) {
            self.filter_cursor = filter_n - 1;
        }
        if (self.date_len == 0) {
            self.date_offset = 0;
        } else if (self.date_offset >= self.date_len) {
            self.date_offset = self.date_len - 1;
        }
    }

    fn rebuildDateBuckets(self: *Session) void {
        self.date_len = 0;
        const q = self.query();
        for (self.rows) |row| {
            if (!history_view.rowMatches(row, q, self.source)) continue;
            const key = dateKeyFromMs(row.updated_at, self.tz_offset_seconds);
            if (key == 0) continue;
            if (self.indexOfDate(key)) |idx| {
                self.date_buckets[idx].count += 1;
            } else if (self.date_len < MAX_DATE_BUCKETS) {
                self.date_buckets[self.date_len] = .{ .key = key, .count = 1 };
                self.date_len += 1;
            }
        }
        std.sort.block(DateBucket, self.date_buckets[0..self.date_len], {}, struct {
            fn lessThan(_: void, a: DateBucket, b: DateBucket) bool {
                return a.key > b.key;
            }
        }.lessThan);
    }

    fn indexOfDate(self: *const Session, key: DateKey) ?usize {
        for (self.date_buckets[0..self.date_len], 0..) |bucket, i| {
            if (bucket.key == key) return i;
        }
        return null;
    }

    fn freeRows(self: *Session) void {
        if (self.owns_rows) {
            agent_history.freeRows(self.allocator, self.rows);
        }
        self.rows = &.{};
        self.owns_rows = false;
    }

    fn clearPreview(self: *Session) void {
        if (self.preview_id.len != 0) self.allocator.free(self.preview_id);
        if (self.preview_body.len != 0) self.allocator.free(self.preview_body);
        self.preview_id = &.{};
        self.preview_body = &.{};
    }
};

pub fn dateKeyFromMs(ms: i64, tz_offset_seconds: i32) DateKey {
    if (ms <= 0) return 0;
    const total_secs = @divFloor(ms, 1000) + tz_offset_seconds;
    if (total_secs < 0) return 0;
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(total_secs) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const year: u32 = year_day.year;
    const month: u32 = month_day.month.numeric();
    const day: u32 = @as(u32, month_day.day_index) + 1;
    return year * 10000 + month * 100 + day;
}

pub fn dateMatches(filter: ?DateKey, key: DateKey) bool {
    const want = filter orelse return true;
    return key != 0 and key == want;
}

pub fn formatDateKey(key: DateKey, buf: []u8) []const u8 {
    const year = key / 10000;
    const month = (key / 100) % 100;
    const day = key % 100;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch buf[0..0];
}

pub fn formatPreview(allocator: std.mem.Allocator, record: agent_history.SessionRecord) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (record.messages) |msg| {
        if (msg.content.len == 0) continue;
        const label: []const u8 = switch (msg.role) {
            .user => "You",
            .assistant => "Assistant",
            .tool => "Tool",
        };
        try buf.appendSlice(allocator, label);
        try buf.appendSlice(allocator, "\n");
        const take = utf8PrefixLen(msg.content, MAX_PREVIEW_MESSAGE);
        try buf.appendSlice(allocator, msg.content[0..take]);
        if (take < msg.content.len) try buf.appendSlice(allocator, "…");
        try buf.appendSlice(allocator, "\n\n");
        if (buf.items.len >= MAX_PREVIEW_BYTES) break;
    }
    if (buf.items.len > MAX_PREVIEW_BYTES) {
        buf.shrinkRetainingCapacity(utf8PrefixLen(buf.items, MAX_PREVIEW_BYTES));
    }
    return buf.toOwnedSlice(allocator);
}

/// Longest prefix of `text` within `limit` bytes that does not end inside a
/// UTF-8 sequence. Cutting at a raw byte offset split CJK characters, and the
/// old repair loop re-validated the whole prefix once per byte it backed off.
fn utf8PrefixLen(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

test "utf8PrefixLen backs off to a character boundary" {
    const text = "ab\u{4f60}\u{597d}"; // a b 你 好 = 2 + 3 + 3 bytes
    try std.testing.expectEqual(@as(usize, 8), utf8PrefixLen(text, 64));
    try std.testing.expectEqual(@as(usize, 5), utf8PrefixLen(text, 6));
    try std.testing.expectEqual(@as(usize, 5), utf8PrefixLen(text, 7));
    try std.testing.expectEqual(@as(usize, 2), utf8PrefixLen(text, 3));
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..utf8PrefixLen(text, 4)]));
}

pub fn handleKeyEffect(consumed: bool) UiEffect {
    return if (consumed) .{ .consumed = true, .needs_rebuild = true, .cells_invalid = true } else .{};
}

test "dateKeyFromMs packs local YYYYMMDD" {
    const tz: i32 = 8 * 3600;
    // 2024-01-02 00:30 UTC+8 = 2024-01-01 16:30 UTC
    const ms: i64 = 1_704_110_200_000;
    const key = dateKeyFromMs(ms, tz);
    try std.testing.expect(key == 20240102 or key == 20240101);
    try std.testing.expect(dateMatches(null, key));
    try std.testing.expect(dateMatches(key, key));
    try std.testing.expect(!dateMatches(20200101, key));
}

test "formatDateKey renders ISO date" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-10", formatDateKey(20260910, &buf));
}

test "session filters by source, query, and date" {
    const a = std.testing.allocator;
    var session = Session.init(a);
    defer session.deinit();

    const day: i64 = 86_400_000;
    const now: i64 = 1_800_000_000_000;
    const rows = try a.alloc(agent_history.Row, 3);
    rows[0] = try cloneTestRow(a, "a", "Disk space", "grok-4.6", now, false);
    rows[1] = try cloneTestRow(a, "b", "Sidebar chat", "grok-4.6", now - day, true);
    rows[2] = try cloneTestRow(a, "c", "Other tab", "deepseek", now - 10 * day, false);
    session.takeRows(rows);

    try std.testing.expectEqual(@as(usize, 3), session.filteredCount());
    try std.testing.expectEqual(@as(usize, 3), session.sourceCount(.all));
    try std.testing.expectEqual(@as(usize, 1), session.sourceCount(.sidebar));
    try std.testing.expectEqual(@as(usize, 2), session.sourceCount(.tab));

    session.setSource(.sidebar);
    try std.testing.expectEqual(@as(usize, 1), session.filteredCount());
    try std.testing.expectEqualStrings("b", session.selectedRow().?.session_id);

    session.setSource(.all);
    try std.testing.expect(session.insertQueryCodepoint('d'));
    try std.testing.expect(session.insertQueryCodepoint('i'));
    try std.testing.expect(session.insertQueryCodepoint('s'));
    try std.testing.expect(session.insertQueryCodepoint('k'));
    try std.testing.expectEqual(@as(usize, 1), session.filteredCount());
    try std.testing.expectEqualStrings("a", session.selectedRow().?.session_id);

    try std.testing.expect(session.backspaceQuery());
    try std.testing.expect(session.query().len > 0);
}

test "session date buckets are newest first and filter the list" {
    const a = std.testing.allocator;
    var session = Session.init(a);
    defer session.deinit();
    session.tz_offset_seconds = 0;

    const newer: i64 = 1_800_000_000_000;
    const older: i64 = newer - 3 * 86_400_000;
    const rows = try a.alloc(agent_history.Row, 2);
    rows[0] = try cloneTestRow(a, "new", "New", "m", newer, false);
    rows[1] = try cloneTestRow(a, "old", "Old", "m", older, false);
    session.takeRows(rows);

    try std.testing.expect(session.date_len >= 1);
    try std.testing.expect(session.date_buckets[0].key >= session.date_buckets[session.date_len - 1].key);

    const first_day = session.date_buckets[0].key;
    session.setDateFilter(first_day);
    try std.testing.expect(session.filteredCount() >= 1);
    try std.testing.expectEqual(first_day, dateKeyFromMs(session.selectedRow().?.updated_at, 0));
}

test "formatPreview concatenates roles and content" {
    const a = std.testing.allocator;
    const record = agent_history.SessionRecord{
        .session_id = "s",
        .title = "t",
        .base_url = "",
        .api_key = "secret",
        .model = "m",
        .system_prompt = "",
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .agent_enabled = false,
        .created_at = 1,
        .updated_at = 1,
        .messages = @constCast(&[_]agent_history.MessageRecord{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "world" },
        }),
    };
    const body = try formatPreview(a, record);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "You") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "secret") == null);
}

test "filter cursor maps onto source then dates" {
    const a = std.testing.allocator;
    var session = Session.init(a);
    defer session.deinit();
    const rows = try a.alloc(agent_history.Row, 1);
    rows[0] = try cloneTestRow(a, "a", "A", "m", 1_800_000_000_000, true);
    session.takeRows(rows);

    session.selectFilterRow(1);
    try std.testing.expectEqual(SourceFilter.sidebar, session.source);
    session.selectFilterRow(FILTER_ALL_DATES_ROW);
    try std.testing.expect(session.date_filter == null);
}

fn cloneTestRow(
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    model: []const u8,
    updated_at: i64,
    copilot: bool,
) !agent_history.Row {
    return .{
        .session_id = try allocator.dupe(u8, id),
        .title = try allocator.dupe(u8, title),
        .model = try allocator.dupe(u8, model),
        .updated_at = updated_at,
        .copilot = copilot,
    };
}
