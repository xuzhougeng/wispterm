const std = @import("std");
const builtin = @import("builtin");
const rule_mod = @import("port_forward_rule.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const ssh_connection = @import("ssh_connection.zig");
const ssh_profile_store = @import("ssh_profile_store.zig");

pub const MAX_RULES: usize = 128;
pub const REASON_MAX: usize = 192;
const MAX_TUNNEL_SPEC_BYTES: usize = 160;
const MAX_SSH_DEST_BYTES: usize = 280;

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
    child: ?ChildState = null,

    fn reason(self: *const Entry) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn setStatus(self: *Entry, status: StatusKind, reason_text: []const u8) void {
        self.status = status;
        self.reason_len = copyBounded(self.reason_buf[0..], reason_text);
    }
};

const ChildState = union(enum) {
    real: std.process.Child,
    fake: FakeChild,
};

const FakeChild = struct {
    pid: u32,
    exited: bool = false,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,

    fn reason(self: *const FakeChild) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn setExited(self: *FakeChild, reason_text: []const u8) void {
        self.exited = true;
        self.reason_len = copyBounded(self.reason_buf[0..], reason_text);
    }
};

const ChildList = struct {
    items: [MAX_RULES]ChildState = undefined,
    len: usize = 0,

    fn append(self: *ChildList, child: ChildState) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = child;
        self.len += 1;
    }

    fn slice(self: *ChildList) []ChildState {
        return self.items[0..self.len];
    }
};

const ExitedChild = struct {
    index: usize,
    child: ChildState,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,

    fn init(index: usize, child: ChildState) ExitedChild {
        var item: ExitedChild = .{
            .index = index,
            .child = child,
        };
        item.reason_len = copyBounded(item.reason_buf[0..], childExitReason(&item.child));
        return item;
    }

    fn reason(self: *const ExitedChild) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

const ExitedChildList = struct {
    items: [MAX_RULES]ExitedChild = undefined,
    len: usize = 0,

    fn append(self: *ExitedChildList, child: ExitedChild) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = child;
        self.len += 1;
    }

    fn slice(self: *ExitedChildList) []ExitedChild {
        return self.items[0..self.len];
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
        var child_to_stop: ?ChildState = null;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        child_to_stop = self.entries.items[index].child;
        self.entries.items[index].child = null;
        self.mutex.unlock();

        if (child_to_stop) |*child| stopChildState(child);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].rule = rule;
        self.entries.items[index].setStatus(.stopped, "");
        return true;
    }

    pub fn deleteRule(self: *Manager, index: usize) bool {
        var removed: Entry = undefined;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        removed = self.entries.orderedRemove(index);
        self.mutex.unlock();

        stopEntry(&removed);
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

        var old_entries: std.ArrayListUnmanaged(Entry) = .empty;
        self.mutex.lock();
        old_entries = self.entries;
        self.entries = .empty;
        self.mutex.unlock();

        stopEntries(old_entries.items);
        old_entries.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.replaceEntriesLocked(&entries);
    }

    fn replaceEntriesLocked(self: *Manager, entries: *std.ArrayListUnmanaged(Entry)) void {
        std.debug.assert(self.entries.items.len == 0);
        self.entries.deinit(self.allocator);
        self.entries = entries.*;
        entries.* = .empty;
    }

    pub fn startIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        var child_to_stop: ?ChildState = null;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        const rule = self.entries.items[index].rule;
        child_to_stop = self.entries.items[index].child;
        self.entries.items[index].child = null;
        self.entries.items[index].setStatus(.starting, "");
        self.mutex.unlock();

        if (child_to_stop) |*child| stopChildState(child);

        const conn = ssh_profile_store.connectionByName(self.allocator, rule.profileName(), legacy_algorithms) orelse {
            self.mutex.lock();
            if (index < self.entries.items.len) self.entries.items[index].setStatus(.missing_profile, "profile missing");
            self.mutex.unlock();
            return false;
        };

        const child = spawnForward(self.allocator, &rule, &conn) catch |err| {
            var buf: [REASON_MAX]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "spawn failed: {}", .{err}) catch "spawn failed";
            self.mutex.lock();
            if (index < self.entries.items.len) self.entries.items[index].setStatus(.error_, msg);
            self.mutex.unlock();
            return false;
        };

        var spawned_state: ChildState = .{ .real = child };
        var replaced_child: ?ChildState = null;
        var accepted = false;
        self.mutex.lock();
        if (index < self.entries.items.len) {
            replaced_child = self.entries.items[index].child;
            self.entries.items[index].child = spawned_state;
            self.entries.items[index].setStatus(.running, "");
            accepted = true;
        }
        self.mutex.unlock();

        if (replaced_child) |*old_child| stopChildState(old_child);
        if (!accepted) stopChildState(&spawned_state);
        return accepted;
    }

    pub fn stopIndex(self: *Manager, index: usize) bool {
        var child_to_stop: ?ChildState = null;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        child_to_stop = self.entries.items[index].child;
        self.entries.items[index].child = null;
        self.mutex.unlock();

        if (child_to_stop) |*child| stopChildState(child);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].setStatus(.stopped, "");
        return true;
    }

    pub fn restartIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        _ = self.stopIndex(index);
        return self.startIndex(index, legacy_algorithms);
    }

    pub fn startAuto(self: *Manager, legacy_algorithms: bool) void {
        var i: usize = 0;
        while (true) : (i += 1) {
            self.mutex.lock();
            const done = i >= self.entries.items.len;
            const should_start = !done and
                self.entries.items[i].rule.enabled and
                self.entries.items[i].rule.auto_start;
            self.mutex.unlock();
            if (done) break;
            if (should_start) _ = self.startIndex(i, legacy_algorithms);
        }
    }

    pub fn tick(self: *Manager) bool {
        var exited: ExitedChildList = .{};

        self.mutex.lock();
        for (self.entries.items, 0..) |*entry, index| {
            const child = entry.child orelse continue;
            if (!childHasExited(&child)) continue;
            entry.child = null;
            exited.append(ExitedChild.init(index, child));
        }
        self.mutex.unlock();

        for (exited.slice()) |*item| {
            stopChildState(&item.child);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (exited.slice()) |*item| {
            if (item.index < self.entries.items.len) {
                self.entries.items[item.index].setStatus(.error_, item.reason());
            }
        }
        return exited.len > 0;
    }

    pub fn markMissingProfileForTest(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].setStatus(.missing_profile, "profile missing");
        return false;
    }

    pub fn markRunningForTest(self: *Manager, index: usize, pid: u32) bool {
        var child_to_stop: ?ChildState = null;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        child_to_stop = self.entries.items[index].child;
        self.entries.items[index].child = .{ .fake = .{ .pid = pid } };
        self.entries.items[index].setStatus(.running, "");
        self.mutex.unlock();

        if (child_to_stop) |*child| stopChildState(child);
        return true;
    }

    pub fn markExitedForTest(self: *Manager, index: usize, reason: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        const child = if (self.entries.items[index].child) |*child| child else return false;
        switch (child.*) {
            .fake => |*fake| fake.setExited(reason),
            .real => return false,
        }
        return true;
    }

    pub fn stopAll(self: *Manager) void {
        var children: ChildList = .{};

        self.mutex.lock();
        for (self.entries.items) |*entry| {
            if (entry.child) |child| {
                children.append(child);
                entry.child = null;
            }
        }
        self.mutex.unlock();

        for (children.slice()) |*child| {
            stopChildState(child);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            entry.setStatus(.stopped, "");
        }
    }
};

pub fn buildSshArgvForTest(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) ![][]const u8 {
    return buildSshArgv(allocator, rule, conn);
}

fn buildSshArgv(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) ![][]const u8 {
    var spec_buf: [MAX_TUNNEL_SPEC_BYTES]u8 = undefined;
    const spec = rule.forwardSpec(&spec_buf) orelse return error.InvalidRule;
    var dest_buf: [MAX_SSH_DEST_BYTES]u8 = undefined;
    const dest = sshDestination(&dest_buf, conn) orelse return error.InvalidProfile;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    try argv.append(allocator, platform_pty_command.sshExecutableName());
    try argv.append(allocator, "-N");
    try argv.append(allocator, "-T");
    try argv.append(allocator, rule.direction.flag());
    try argv.append(allocator, try allocator.dupe(u8, spec));

    try appendSshOption(allocator, &argv, "ExitOnForwardFailure=yes");
    try appendSshOption(allocator, &argv, "StrictHostKeyChecking=accept-new");
    try appendSshOption(allocator, &argv, "ConnectTimeout=8");
    try appendSshOption(allocator, &argv, "ServerAliveInterval=60");
    try appendSshOption(allocator, &argv, "ServerAliveCountMax=3");
    if (conn.legacy_algorithms) {
        try appendSshOption(allocator, &argv, "HostkeyAlgorithms=+ssh-rsa,ssh-dss");
        try appendSshOption(allocator, &argv, "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss");
        try appendSshOption(allocator, &argv, "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1");
        try appendSshOption(allocator, &argv, "Ciphers=+aes128-cbc,3des-cbc");
    }
    if (conn.password_auth) {
        try appendSshOption(allocator, &argv, "PreferredAuthentications=publickey,password,keyboard-interactive");
        try appendSshOption(allocator, &argv, "NumberOfPasswordPrompts=1");
    } else {
        try appendSshOption(allocator, &argv, "BatchMode=yes");
    }
    if (conn.proxyJump().len > 0) {
        try appendSshOption(allocator, &argv, try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{conn.proxyJump()}));
    }
    if (conn.port().len > 0) {
        try argv.append(allocator, "-p");
        try argv.append(allocator, try allocator.dupe(u8, conn.port()));
    }
    try argv.append(allocator, try allocator.dupe(u8, dest));
    return argv.toOwnedSlice(allocator);
}

fn appendSshOption(allocator: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), option: []const u8) !void {
    try argv.append(allocator, "-o");
    try argv.append(allocator, option);
}

fn sshDestination(buf: *[MAX_SSH_DEST_BYTES]u8, conn: *const ssh_connection.SshConnection) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const len = user.len + 1 + host.len;
    if (user.len == 0 or host.len == 0 or len > buf.len) return null;
    @memcpy(buf[0..user.len], user);
    buf[user.len] = '@';
    @memcpy(buf[user.len + 1 ..][0..host.len], host);
    return buf[0..len];
}

fn spawnForward(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) !std.process.Child {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = try buildSshArgv(arena.allocator(), rule, conn);

    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return error.AskPassUnavailable;
        env_map = try std.process.getEnvMap(allocator);
        if (env_map) |*map| {
            try platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password());
        }
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    if (env_map) |*map| child.env_map = map;
    try child.spawn();
    return child;
}

fn stopEntries(entries: []Entry) void {
    for (entries) |*entry| stopEntry(entry);
}

fn stopEntry(entry: *Entry) void {
    if (entry.child) |*child| {
        stopChildState(child);
        entry.child = null;
    }
}

fn stopChildState(child: *ChildState) void {
    switch (child.*) {
        .real => |*real_child| stopRealChild(real_child),
        .fake => {},
    }
}

fn stopRealChild(child: *std.process.Child) void {
    if (childHasExitedReal(child)) {
        if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
        _ = child.wait() catch {};
    } else {
        _ = child.kill() catch {};
    }
}

fn childHasExited(child: *const ChildState) bool {
    return switch (child.*) {
        .real => |*real_child| childHasExitedReal(real_child),
        .fake => |*fake| fake.exited,
    };
}

fn childHasExitedReal(child: *const std.process.Child) bool {
    return switch (platform_process.childExited(child.id, 0)) {
        .running => false,
        .exited, .gone => true,
    };
}

fn childExitReason(child: *const ChildState) []const u8 {
    return switch (child.*) {
        .real => "ssh exited",
        .fake => |*fake| if (fake.reason().len > 0) fake.reason() else "ssh exited",
    };
}

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

test "port_forward_manager: builds reverse ssh argv without connection sharing" {
    var conn = sshConnectionForTest("alice", "example.test", "2222", "jump@example.test:22", "", false, false);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rule = rule_mod.defaultReverseProxy("devbox");
    const argv = try buildSshArgvForTest(allocator, &rule, &conn);

    try std.testing.expectEqualStrings("ssh", argv[0]);
    try std.testing.expect(argvContainsForTest(argv, "-N"));
    try std.testing.expect(argvContainsForTest(argv, "-T"));
    try std.testing.expect(argvContainsForTest(argv, "-R"));
    try std.testing.expect(argvContainsForTest(argv, "127.0.0.1:7890:127.0.0.1:7890"));
    try std.testing.expect(argvContainsForTest(argv, "ProxyJump=jump@example.test:22"));
    try std.testing.expect(argvContainsForTest(argv, "-p"));
    try std.testing.expect(argvContainsForTest(argv, "2222"));
    try std.testing.expect(argvContainsForTest(argv, "alice@example.test"));
    try expectNoControlSharingOptionsForTest(argv);
}

test "port_forward_manager: builds local ssh argv with distinct endpoints" {
    var conn = sshConnectionForTest("alice", "example.test", "", "", "", false, false);
    var rule = rule_mod.defaultReverseProxy("devbox");
    rule.direction = .local;
    rule.setLocalHost("127.0.0.1");
    rule.local_port = 18080;
    rule.setRemoteHost("localhost");
    rule.remote_port = 8080;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildSshArgvForTest(arena.allocator(), &rule, &conn);
    try std.testing.expect(argvContainsForTest(argv, "-L"));
    try std.testing.expect(argvContainsForTest(argv, "127.0.0.1:18080:localhost:8080"));
    try expectNoControlSharingOptionsForTest(argv);
}

test "port_forward_manager: legacy profile includes legacy algorithm ssh options" {
    var conn = sshConnectionForTest("alice", "legacy.test", "", "", "", false, true);
    const rule = rule_mod.defaultReverseProxy("legacy");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildSshArgvForTest(arena.allocator(), &rule, &conn);
    try std.testing.expect(argvContainsForTest(argv, "HostkeyAlgorithms=+ssh-rsa,ssh-dss"));
    try std.testing.expect(argvContainsForTest(argv, "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss"));
    try std.testing.expect(argvContainsForTest(argv, "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1"));
    try std.testing.expect(argvContainsForTest(argv, "Ciphers=+aes128-cbc,3des-cbc"));
    try expectNoControlSharingOptionsForTest(argv);
}

test "port_forward_manager: password auth argv uses askpass compatible options and key auth uses BatchMode" {
    var password_conn = sshConnectionForTest("alice", "password.test", "", "", "secret", true, false);
    const rule = rule_mod.defaultReverseProxy("password");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const password_argv = try buildSshArgvForTest(arena.allocator(), &rule, &password_conn);
    try std.testing.expect(argvContainsForTest(password_argv, "PreferredAuthentications=publickey,password,keyboard-interactive"));
    try std.testing.expect(argvContainsForTest(password_argv, "NumberOfPasswordPrompts=1"));
    try std.testing.expect(!argvContainsForTest(password_argv, "BatchMode=yes"));

    var key_conn = sshConnectionForTest("alice", "key.test", "", "", "", false, false);
    const key_argv = try buildSshArgvForTest(arena.allocator(), &rule, &key_conn);
    try std.testing.expect(argvContainsForTest(key_argv, "BatchMode=yes"));
    try std.testing.expect(!argvContainsForTest(key_argv, "PreferredAuthentications=publickey,password,keyboard-interactive"));
}

test "port_forward_manager: running child exit becomes error on tick" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));

    try std.testing.expect(manager.markRunningForTest(0, 99));
    try std.testing.expect(manager.markExitedForTest(0, "ssh exited"));
    try std.testing.expect(manager.tick());

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.error_, row.status);
    try std.testing.expectEqualStrings("ssh exited", row.reason());
    try std.testing.expect(!manager.tick());
}

test "port_forward_manager: update clears fake child before replacing rule" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expect(manager.markRunningForTest(0, 123));

    try std.testing.expect(manager.updateRule(0, rule_mod.defaultReverseProxy("updated")));
    try std.testing.expect(!manager.markExitedForTest(0, "old child exited"));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("updated", row.rule.profileName());
}

test "port_forward_manager: delete clears fake child for removed rule" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expect(manager.markRunningForTest(0, 123));

    try std.testing.expect(manager.deleteRule(0));
    try std.testing.expectEqual(@as(usize, 0), manager.count());
    try std.testing.expect(!manager.markExitedForTest(0, "old child exited"));
}

test "port_forward_manager: load replacement clears old fake child" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old"));
    try std.testing.expect(manager.markRunningForTest(0, 123));

    var rules = [_]rule_mod.Rule{rule_mod.defaultReverseProxy("new")};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try rule_mod.encodeRules(std.testing.allocator, &out, rules[0..]);

    try manager.loadFromContent(out.items);
    try std.testing.expect(!manager.markExitedForTest(0, "old child exited"));
    try std.testing.expectEqualStrings("new", manager.rowAt(0).?.rule.profileName());
}

test "port_forward_manager: stop all clears fake children after stopping" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expect(manager.markRunningForTest(0, 123));

    manager.stopAll();
    try std.testing.expect(!manager.markExitedForTest(0, "old child exited"));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("", row.reason());
}

fn sshConnectionForTest(
    user: []const u8,
    host: []const u8,
    port: []const u8,
    proxy_jump: []const u8,
    password: []const u8,
    password_auth: bool,
    legacy_algorithms: bool,
) ssh_connection.SshConnection {
    var conn: ssh_connection.SshConnection = .{};
    conn.user_len = copyBounded(conn.user_buf[0..], user);
    conn.host_len = copyBounded(conn.host_buf[0..], host);
    conn.port_len = copyBounded(conn.port_buf[0..], port);
    conn.proxy_jump_len = copyBounded(conn.proxy_jump_buf[0..], proxy_jump);
    conn.password_len = copyBounded(conn.password_buf[0..], password);
    conn.password_auth = password_auth;
    conn.legacy_algorithms = legacy_algorithms;
    return conn;
}

fn argvContainsForTest(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn expectNoControlSharingOptionsForTest(argv: []const []const u8) !void {
    for (argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlMaster") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlPersist") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlPath") == null);
    }
}
