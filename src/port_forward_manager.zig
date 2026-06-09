const std = @import("std");
const rule_mod = @import("port_forward_rule.zig");

pub const MAX_RULES: usize = 128;
pub const REASON_MAX: usize = 192;

pub const StatusKind = enum {
    stopped,
    starting,
    running,
    error_,
    missing_profile,
};

pub const RowView = struct {
    rule: rule_mod.Rule,
    status: StatusKind,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,
    auto_start: bool,

    pub fn reason(self: *const RowView) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

const Entry = struct {
    rule: rule_mod.Rule,
    status: StatusKind = .stopped,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,

    fn reason(self: *const Entry) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn setStatus(self: *Entry, status: StatusKind, reason_text: []const u8) void {
        self.status = status;
        self.reason_len = copyBounded(self.reason_buf[0..], reason_text);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.stopAll();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    pub fn rowAt(self: *Manager, index: usize) ?RowView {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        const entry = &self.entries.items[index];
        var row: RowView = .{
            .rule = entry.rule,
            .status = entry.status,
            .auto_start = entry.rule.auto_start,
        };
        row.reason_len = copyBounded(row.reason_buf[0..], entry.reason());
        return row;
    }

    pub fn addRule(self: *Manager, rule: rule_mod.Rule) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.items.len >= MAX_RULES) return error.TooManyRules;
        try self.entries.append(self.allocator, .{ .rule = rule });
    }

    pub fn updateRule(self: *Manager, index: usize, rule: rule_mod.Rule) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].rule = rule;
        self.entries.items[index].setStatus(.stopped, "");
        return true;
    }

    pub fn deleteRule(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        _ = self.entries.orderedRemove(index);
        return true;
    }

    pub fn toggleAutoStart(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].rule.auto_start = !self.entries.items[index].rule.auto_start;
        return true;
    }

    pub fn encode(self: *Manager, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var rules = try allocator.alloc(rule_mod.Rule, self.entries.items.len);
        defer allocator.free(rules);
        for (self.entries.items, 0..) |entry, i| rules[i] = entry.rule;
        try rule_mod.encodeRules(allocator, out, rules);
    }

    pub fn loadFromContent(self: *Manager, content: []const u8) !void {
        var entries = try decodeEntriesBounded(self.allocator, content);
        defer entries.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.replaceEntriesLocked(&entries);
    }

    fn replaceEntriesLocked(self: *Manager, entries: *std.ArrayListUnmanaged(Entry)) void {
        self.entries.deinit(self.allocator);
        self.entries = entries.*;
        entries.* = .empty;
    }

    pub fn markMissingProfileForTest(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].setStatus(.missing_profile, "profile missing");
        return false;
    }

    pub fn stopAll(self: *Manager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            entry.setStatus(.stopped, "");
        }
    }
};

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn decodeEntriesBounded(allocator: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged(Entry) {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (rule_mod.decodeRuleLine(line)) |rule| {
            if (entries.items.len >= MAX_RULES) return error.TooManyRules;
            if (entries.capacity == 0) try entries.ensureTotalCapacity(allocator, MAX_RULES);
            entries.appendAssumeCapacity(.{ .rule = rule });
        }
    }
    return entries;
}

test "port_forward_manager: add save load and toggle auto start" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expect(manager.rowAt(0).?.auto_start);

    try std.testing.expect(manager.toggleAutoStart(0));
    try std.testing.expect(!manager.rowAt(0).?.auto_start);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try manager.encode(std.testing.allocator, &out);

    var loaded = Manager.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromContent(out.items);
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expect(!loaded.rowAt(0).?.auto_start);
}

test "port_forward_manager: missing profile records status without spawning" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("missing"));

    const started = manager.markMissingProfileForTest(0);
    try std.testing.expect(!started);
    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.missing_profile, row.status);
    try std.testing.expectEqualStrings("profile missing", row.reason());
}

test "port_forward_manager: row view reason snapshot survives status changes" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    _ = manager.markMissingProfileForTest(0);

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.missing_profile, row.status);
    try std.testing.expectEqualStrings("profile missing", row.reason());
    try std.testing.expect(row.reason().ptr != manager.entries.items[0].reason_buf[0..].ptr);

    manager.entries.items[0].setStatus(.error_, "rewritten");
    try std.testing.expectEqual(StatusKind.missing_profile, row.status);
    try std.testing.expectEqualStrings("profile missing", row.reason());
}

test "port_forward_manager: load rejects too many rules without replacing existing" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("existing"));

    var rules: [MAX_RULES + 1]rule_mod.Rule = undefined;
    for (&rules) |*rule| {
        rule.* = rule_mod.defaultReverseProxy("loaded");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try rule_mod.encodeRules(std.testing.allocator, &out, rules[0..]);

    try std.testing.expectError(error.TooManyRules, manager.loadFromContent(out.items));
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqualStrings("existing", manager.rowAt(0).?.rule.profileName());
}

test "port_forward_manager: load replacement fully replaces old entries" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old-a"));
    try manager.addRule(rule_mod.defaultReverseProxy("old-b"));

    var rules = [_]rule_mod.Rule{rule_mod.defaultReverseProxy("new")};
    rules[0].auto_start = false;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try rule_mod.encodeRules(std.testing.allocator, &out, rules[0..]);

    try manager.loadFromContent(out.items);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("new", row.rule.profileName());
    try std.testing.expect(!row.auto_start);
}

test "port_forward_manager: oversized load stops at the max rule boundary" {
    var rules: [MAX_RULES + 1]rule_mod.Rule = undefined;
    for (&rules) |*rule| {
        rule.* = rule_mod.defaultReverseProxy("loaded");
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try rule_mod.encodeRules(std.testing.allocator, &out, rules[0..]);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var manager = Manager.init(failing_allocator.allocator());
    defer manager.deinit();

    try std.testing.expectError(error.TooManyRules, manager.loadFromContent(out.items));
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "port_forward_manager: update resets status and invalid indexes are ignored" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    _ = manager.markMissingProfileForTest(0);

    try std.testing.expect(!manager.updateRule(8, rule_mod.defaultReverseProxy("ignored")));
    try std.testing.expect(!manager.toggleAutoStart(8));
    try std.testing.expect(!manager.deleteRule(8));
    try std.testing.expect(manager.rowAt(8) == null);

    try std.testing.expect(manager.updateRule(0, rule_mod.defaultReverseProxy("updated")));
    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expectEqualStrings("updated", row.rule.profileName());
}
