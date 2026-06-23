const std = @import("std");
const agent_history = @import("agent_history.zig");

pub const MAX_INDEX_BYTES = 32 * 1024 * 1024;
const MIGRATION_MAX_BYTES = 1 << 30;

pub const MetaStore = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    entries: std.ArrayListUnmanaged(agent_history.IndexEntry) = .empty,
    pending: std.ArrayListUnmanaged(agent_history.SessionRecord) = .empty,
    index_dirty: bool = false,

    pub fn open(allocator: std.mem.Allocator, dir_in: []const u8) !MetaStore {
        var self = MetaStore{ .allocator = allocator, .dir = try allocator.dupe(u8, dir_in) };
        errdefer self.deinit();
        try std.fs.cwd().makePath(self.dir);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        try std.fs.cwd().makePath(sessions);
        if (try self.loadIndexFromDisk()) return self;

        try self.rebuildIndexFromSessions();
        if (self.entries.items.len > 0) {
            self.index_dirty = true;
            try self.flush();
        }
        return self;
    }

    pub fn deinit(self: *MetaStore) void {
        for (self.entries.items) |*e| agent_history.freeOwnedIndexEntry(self.allocator, e);
        self.entries.deinit(self.allocator);
        for (self.pending.items) |*r| agent_history.freeOwnedRecord(self.allocator, r);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    fn sessionsDirPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "sessions" });
    }

    fn indexPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "index.json" });
    }

    fn sessionFilePath(self: *const MetaStore, allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
        const fname = try agent_history.sanitizeSessionFileName(allocator, session_id);
        defer allocator.free(fname);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        return std.fs.path.join(allocator, &.{ sessions, fname });
    }

    pub fn buildRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildRowsFromEntries(allocator, self.entries.items);
    }

    pub fn buildCopilotRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildCopilotRowsFromEntries(allocator, self.entries.items);
    }

    fn entryIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.session_id, session_id)) return i;
        }
        return null;
    }

    fn pendingIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.pending.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.session_id, session_id)) return i;
        }
        return null;
    }

    pub fn upsertRecord(self: *MetaStore, input: anytype) !void {
        var cloned = try agent_history.cloneRecord(self.allocator, input);
        errdefer agent_history.freeOwnedRecord(self.allocator, &cloned);
        var new_entry = try agent_history.recordToIndexEntry(self.allocator, cloned);
        errdefer agent_history.freeOwnedIndexEntry(self.allocator, &new_entry);

        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.pending.ensureUnusedCapacity(self.allocator, 1);

        if (self.entryIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedIndexEntry(self.allocator, &self.entries.items[i]);
            self.entries.items[i] = new_entry;
        } else {
            self.entries.appendAssumeCapacity(new_entry);
        }
        if (self.pendingIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedRecord(self.allocator, &self.pending.items[i]);
            self.pending.items[i] = cloned;
        } else {
            self.pending.appendAssumeCapacity(cloned);
        }
        self.index_dirty = true;
    }

    pub fn cloneRecordBySessionId(
        self: *const MetaStore,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) !?agent_history.SessionRecord {
        if (self.pendingIndex(session_id)) |i| {
            return try agent_history.cloneRecord(allocator, self.pending.items[i]);
        }
        const path = try self.sessionFilePath(allocator, session_id);
        defer allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_INDEX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return null,
        };
        defer allocator.free(bytes);
        return try agent_history.recordFromJson(allocator, bytes);
    }

    fn writeSessionFile(self: *const MetaStore, record: agent_history.SessionRecord) !void {
        const json = try agent_history.recordToJson(self.allocator, record);
        defer self.allocator.free(json);
        const path = try self.sessionFilePath(self.allocator, record.session_id);
        defer self.allocator.free(path);
        try agent_history.saveJsonToPath(path, json);
    }

    fn writeIndex(self: *MetaStore) !void {
        const json = try agent_history.dumpIndex(self.allocator, .{
            .version = agent_history.INDEX_VERSION,
            .entries = self.entries.items,
        });
        defer self.allocator.free(json);
        const path = try self.indexPath(self.allocator);
        defer self.allocator.free(path);
        try agent_history.saveJsonToPath(path, json);
    }

    pub fn flush(self: *MetaStore) !void {
        if (!self.index_dirty and self.pending.items.len == 0) return;
        for (self.pending.items) |record| {
            try self.writeSessionFile(record);
        }
        for (self.pending.items) |*r| agent_history.freeOwnedRecord(self.allocator, r);
        self.pending.clearRetainingCapacity();
        try self.writeIndex();
        self.index_dirty = false;
    }

    fn loadIndexFromDisk(self: *MetaStore) !bool {
        const path = try self.indexPath(self.allocator);
        defer self.allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, path, MAX_INDEX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
        defer self.allocator.free(bytes);
        var parsed = agent_history.parseIndex(self.allocator, bytes) catch return false;
        defer parsed.deinit();
        if (parsed.value.version != agent_history.INDEX_VERSION) return false;
        for (parsed.value.entries) |e| {
            const cloned = try agent_history.cloneIndexEntry(self.allocator, e);
            self.entries.append(self.allocator, cloned) catch |err| {
                var owned = cloned;
                agent_history.freeOwnedIndexEntry(self.allocator, &owned);
                return err;
            };
        }
        return true;
    }

    pub fn deleteBySessionId(self: *MetaStore, session_id: []const u8) bool {
        const idx = self.entryIndex(session_id) orelse return false;
        if (self.sessionFilePath(self.allocator, session_id)) |path| {
            defer self.allocator.free(path);
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}
        var removed = self.entries.orderedRemove(idx);
        agent_history.freeOwnedIndexEntry(self.allocator, &removed);
        if (self.pendingIndex(session_id)) |pi| {
            var r = self.pending.orderedRemove(pi);
            agent_history.freeOwnedRecord(self.allocator, &r);
        }
        self.index_dirty = true;
        return true;
    }

    fn rebuildIndexFromSessions(self: *MetaStore) !void {
        const sessions = try self.sessionsDirPath(self.allocator);
        defer self.allocator.free(sessions);
        var dir = std.fs.cwd().openDir(sessions, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const bytes = dir.readFileAlloc(self.allocator, ent.name, agent_history.MAX_SESSION_BYTES) catch continue;
            defer self.allocator.free(bytes);
            var rec = agent_history.recordFromJson(self.allocator, bytes) catch continue;
            defer agent_history.freeOwnedRecord(self.allocator, &rec);
            const entry = try agent_history.recordToIndexEntry(self.allocator, rec);
            self.entries.append(self.allocator, entry) catch |err| {
                var owned = entry;
                agent_history.freeOwnedIndexEntry(self.allocator, &owned);
                return err;
            };
        }
    }
};

test "MetaStore: open empty dir yields no rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "MetaStore: upsert is visible via rows and clone before flush (pending)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1", .title = "T", .base_url = "https://api.example.com", .api_key = "k", .model = "m",
        .system_prompt = "sys", .thinking_enabled = false, .reasoning_effort = "low", .stream = true,
        .agent_enabled = true, .created_at = 1, .updated_at = 2,
        .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hi" }},
    });
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("s1", rows[0].session_id);
    var rec = (try store.cloneRecordBySessionId(allocator, "s1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("hi", rec.messages[0].content);
    try std.testing.expect((try store.cloneRecordBySessionId(allocator, "nope")) == null);
}

test "MetaStore: flush writes files and index, reopen reads cold from disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    {
        var store = try MetaStore.open(allocator, root);
        defer store.deinit();
        try store.upsertRecord(.{
            .session_id = "s1", .title = "T", .base_url = "https://api.example.com", .api_key = "k", .model = "m",
            .system_prompt = "sys", .thinking_enabled = false, .reasoning_effort = "low", .stream = true,
            .agent_enabled = true, .created_at = 1, .updated_at = 2,
            .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hi" }},
        });
        try store.flush();
        try std.testing.expectEqual(@as(usize, 0), store.pending.items.len);
    }
    var store2 = try MetaStore.open(allocator, root);
    defer store2.deinit();
    const rows = try store2.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    var rec = (try store2.cloneRecordBySessionId(allocator, "s1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("hi", rec.messages[0].content);
}

test "MetaStore: delete removes entry, pending and on-disk file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1", .title = "T", .base_url = "u", .api_key = "k", .model = "m",
        .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
        .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2,
        .messages = &[_]agent_history.MessageRecord{},
    });
    try store.flush();
    try std.testing.expect(store.deleteBySessionId("s1"));
    try std.testing.expect(!store.deleteBySessionId("s1"));
    try store.flush();
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
    var reopened = try MetaStore.open(allocator, root);
    defer reopened.deinit();
    try std.testing.expect((try reopened.cloneRecordBySessionId(allocator, "s1")) == null);
}

test "MetaStore: rebuilds index from session files when index missing/corrupt; skips bad files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    {
        var store = try MetaStore.open(allocator, root);
        defer store.deinit();
        inline for (.{ "s1", "s2" }) |sid| {
            try store.upsertRecord(.{
                .session_id = sid, .title = "T", .base_url = "u", .api_key = "k", .model = "m",
                .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
                .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2,
                .messages = &[_]agent_history.MessageRecord{},
            });
        }
        try store.flush();
    }
    try tmp.dir.deleteFile("index.json");
    try tmp.dir.writeFile(.{ .sub_path = "sessions/broken.json", .data = "{ not json" });
    var rebuilt = try MetaStore.open(allocator, root);
    defer rebuilt.deinit();
    const rows = try rebuilt.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
}
