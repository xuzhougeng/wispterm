const std = @import("std");
const builtin = @import("builtin");
const rule_mod = @import("rule.zig");
const platform_process = @import("../platform/process.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const ssh_connection = @import("../ssh/connection.zig");
const ssh_profile_store = @import("../ssh/profile_store.zig");

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
    id: u64 = 0,
    rule: rule_mod.Rule,
    generation: u64 = 0,
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

const PendingStart = struct {
    entry_id: u64,
    generation: u64,
    rule: rule_mod.Rule,
};

const StartLease = struct {
    pending: PendingStart,
    child_to_stop: ?ChildState,
};

const UpdateRuleLease = struct {
    child_to_stop: ?ChildState,
};

const AutoStartCandidate = struct {
    entry_id: u64,
    generation: u64,
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

const ExitedChild = struct {
    entry_id: u64,
    generation: u64,
    child: ChildState,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,

    fn init(entry_id: u64, generation: u64, child: ChildState) ExitedChild {
        var item: ExitedChild = .{
            .entry_id = entry_id,
            .generation = generation,
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

const StoppedEntry = struct {
    entry_id: u64,
    generation: u64,
    child: ?ChildState,
};

const StopList = struct {
    items: [MAX_RULES]StoppedEntry = undefined,
    len: usize = 0,

    fn append(self: *StopList, stopped: StoppedEntry) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = stopped;
        self.len += 1;
    }

    fn slice(self: *StopList) []StoppedEntry {
        return self.items[0..self.len];
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    next_entry_id: u64 = 1,
    next_generation: u64 = 1,
    storage_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.stopAll();
        self.entries.deinit(self.allocator);
        if (self.storage_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn setStoragePath(self: *Manager, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        self.mutex.lock();
        const old = self.storage_path;
        self.storage_path = owned;
        self.mutex.unlock();
        if (old) |old_path| self.allocator.free(old_path);
    }

    pub fn setStoragePathForTest(self: *Manager, path: []const u8) void {
        self.setStoragePath(path) catch @panic("setStoragePathForTest failed");
    }

    pub fn load(self: *Manager) !bool {
        const path = try self.storagePathSnapshot() orelse return false;
        defer self.allocator.free(path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(content);

        try self.loadFromContent(content);
        return true;
    }

    pub fn save(self: *Manager) bool {
        const path = (self.storagePathSnapshot() catch return false) orelse return false;
        defer self.allocator.free(path);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        self.encode(self.allocator, &out) catch return false;

        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch return false;
        }
        platform_atomic_file.writeFileReplaceSafe(path, out.items) catch return false;
        return true;
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
        try self.entries.append(self.allocator, .{
            .id = self.nextEntryIdLocked(),
            .rule = rule,
            .generation = self.nextGenerationLocked(),
        });
    }

    pub fn updateRule(self: *Manager, index: usize, rule: rule_mod.Rule) bool {
        var lease = self.beginUpdateRule(index, rule) orelse return false;
        stopUpdateRuleLease(&lease);
        return true;
    }

    pub fn deleteRule(self: *Manager, index: usize) bool {
        var removed: Entry = undefined;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        _ = self.nextGenerationLocked();
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
        self.prepareEntriesLocked(entries.items);
        old_entries = self.entries;
        self.entries = entries;
        entries = .empty;
        self.mutex.unlock();

        stopEntries(old_entries.items);
        old_entries.deinit(self.allocator);
    }

    fn prepareEntriesLocked(self: *Manager, entries: []Entry) void {
        for (entries) |*entry| {
            entry.id = self.nextEntryIdLocked();
            entry.generation = self.nextGenerationLocked();
        }
    }

    pub fn startIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        var lease = self.beginStart(index) orelse return false;
        return self.runStartLease(&lease, legacy_algorithms);
    }

    pub fn stopIndex(self: *Manager, index: usize) bool {
        var child_to_stop: ?ChildState = null;
        var entry_id: u64 = 0;
        var generation: u64 = 0;

        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        entry_id = self.entries.items[index].id;
        child_to_stop = self.entries.items[index].child;
        self.entries.items[index].child = null;
        generation = self.nextGenerationLocked();
        self.entries.items[index].generation = generation;
        self.mutex.unlock();

        if (child_to_stop) |*child| stopChildState(child);

        self.mutex.lock();
        defer self.mutex.unlock();
        const current_index = self.findEntryIndexByIdAndGenerationLocked(entry_id, generation) orelse return false;
        self.entries.items[current_index].setStatus(.stopped, "");
        return true;
    }

    pub fn restartIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        return self.startIndex(index, legacy_algorithms);
    }

    pub fn startAuto(self: *Manager, legacy_algorithms: bool) void {
        var i: usize = 0;
        while (true) : (i += 1) {
            var candidate: ?AutoStartCandidate = null;

            self.mutex.lock();
            const done = i >= self.entries.items.len;
            if (!done) candidate = self.autoStartCandidateAtIndexLocked(i);
            self.mutex.unlock();

            if (done) break;
            if (candidate) |item| {
                var lease = self.beginAutoStart(item) orelse continue;
                _ = self.runStartLease(&lease, legacy_algorithms);
            }
        }
    }

    pub fn tick(self: *Manager) bool {
        var exited: ExitedChildList = .{};

        self.mutex.lock();
        for (self.entries.items) |*entry| {
            if (takeExitedChildFromEntry(entry)) |child| {
                exited.append(child);
            }
        }
        self.mutex.unlock();

        for (exited.slice()) |*item| {
            stopChildState(&item.child);
        }

        for (exited.slice()) |*item| {
            _ = self.finishExitedChild(item);
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
        self.entries.items[index].generation = self.nextGenerationLocked();
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

    fn beginPendingStartForTest(self: *Manager, index: usize) ?PendingStart {
        var lease = self.beginStart(index) orelse return null;
        if (lease.child_to_stop) |*child| stopChildState(child);
        return lease.pending;
    }

    fn completePendingStartFailureForTest(self: *Manager, pending: PendingStart, status: StatusKind, reason: []const u8) bool {
        return self.completePendingStartFailure(pending, status, reason);
    }

    fn completePendingStartFakeForTest(self: *Manager, pending: PendingStart, pid: u32) bool {
        return self.completePendingStartInstall(pending, .{ .fake = .{ .pid = pid } });
    }

    fn beginUpdateRuleForTest(self: *Manager, index: usize, rule: rule_mod.Rule) ?UpdateRuleLease {
        return self.beginUpdateRule(index, rule);
    }

    fn finishUpdateRuleForTest(self: *Manager, lease: *UpdateRuleLease) void {
        _ = self;
        stopUpdateRuleLease(lease);
    }

    fn sampleAutoStartForTest(self: *Manager, index: usize) ?AutoStartCandidate {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.autoStartCandidateAtIndexLocked(index);
    }

    fn beginAutoStartForTest(self: *Manager, candidate: AutoStartCandidate) ?PendingStart {
        var lease = self.beginAutoStart(candidate) orelse return null;
        if (lease.child_to_stop) |*child| stopChildState(child);
        return lease.pending;
    }

    fn takeExitedChildForTest(self: *Manager, index: usize) ?ExitedChild {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        return takeExitedChildFromEntry(&self.entries.items[index]);
    }

    fn finishExitedChildForTest(self: *Manager, exited: *ExitedChild) bool {
        return self.finishExitedChild(exited);
    }

    fn beginRestartForTest(self: *Manager, index: usize) ?PendingStart {
        return self.beginPendingStartForTest(index);
    }

    fn completeRestartFakeForTest(self: *Manager, pending: *const PendingStart, pid: u32) bool {
        return self.completePendingStartFakeForTest(pending.*, pid);
    }

    pub fn stopAll(self: *Manager) void {
        var stopped: StopList = .{};

        self.mutex.lock();
        for (self.entries.items) |*entry| {
            const child = entry.child;
            entry.child = null;
            entry.generation = self.nextGenerationLocked();
            stopped.append(.{
                .entry_id = entry.id,
                .generation = entry.generation,
                .child = child,
            });
        }
        self.mutex.unlock();

        for (stopped.slice()) |*item| {
            if (item.child) |*child| stopChildState(child);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (stopped.slice()) |item| {
            if (self.findEntryIndexByIdAndGenerationLocked(item.entry_id, item.generation)) |index| {
                self.entries.items[index].setStatus(.stopped, "");
            }
        }
    }

    fn beginUpdateRule(self: *Manager, index: usize, rule: rule_mod.Rule) ?UpdateRuleLease {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        const entry = &self.entries.items[index];
        const child_to_stop = entry.child;
        entry.child = null;
        entry.rule = rule;
        entry.generation = self.nextGenerationLocked();
        entry.setStatus(.stopped, "");
        return .{ .child_to_stop = child_to_stop };
    }

    fn storagePathSnapshot(self: *Manager) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const path = self.storage_path orelse return null;
        return try self.allocator.dupe(u8, path);
    }

    fn beginStart(self: *Manager, index: usize) ?StartLease {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        return self.beginStartAtIndexLocked(index);
    }

    fn beginAutoStart(self: *Manager, candidate: AutoStartCandidate) ?StartLease {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findEntryIndexByIdAndGenerationLocked(candidate.entry_id, candidate.generation) orelse return null;
        if (self.autoStartCandidateAtIndexLocked(index) == null) return null;
        return self.beginStartAtIndexLocked(index);
    }

    fn beginStartAtIndexLocked(self: *Manager, index: usize) StartLease {
        const entry = &self.entries.items[index];
        const child_to_stop = entry.child;
        const generation = self.nextGenerationLocked();
        entry.child = null;
        entry.generation = generation;
        entry.setStatus(.starting, "");
        return .{
            .pending = .{
                .entry_id = entry.id,
                .generation = generation,
                .rule = entry.rule,
            },
            .child_to_stop = child_to_stop,
        };
    }

    fn runStartLease(self: *Manager, lease: *StartLease, legacy_algorithms: bool) bool {
        if (lease.child_to_stop) |*child| stopChildState(child);
        lease.child_to_stop = null;
        const pending = lease.pending;

        const conn = ssh_profile_store.connectionByName(self.allocator, pending.rule.profileName(), legacy_algorithms) orelse {
            _ = self.completePendingStartFailure(pending, .missing_profile, "profile missing");
            return false;
        };

        const child = spawnForward(self.allocator, &pending.rule, &conn) catch |err| {
            var buf: [REASON_MAX]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "spawn failed: {}", .{err}) catch "spawn failed";
            _ = self.completePendingStartFailure(pending, .error_, msg);
            return false;
        };

        var spawned_state: ChildState = .{ .real = child };
        const accepted = self.completePendingStartInstall(pending, spawned_state);
        if (!accepted) stopChildState(&spawned_state);
        return accepted;
    }

    fn completePendingStartFailure(self: *Manager, pending: PendingStart, status: StatusKind, reason: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.pendingStartIndexLocked(pending) orelse return false;
        self.entries.items[index].setStatus(status, reason);
        return true;
    }

    fn completePendingStartInstall(self: *Manager, pending: PendingStart, child: ChildState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.pendingStartIndexLocked(pending) orelse return false;
        self.entries.items[index].child = child;
        self.entries.items[index].setStatus(.running, "");
        return true;
    }

    fn finishExitedChild(self: *Manager, exited: *const ExitedChild) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findEntryIndexByIdAndGenerationLocked(exited.entry_id, exited.generation) orelse return false;
        if (self.entries.items[index].child != null) return false;
        self.entries.items[index].setStatus(.error_, exited.reason());
        return true;
    }

    fn pendingStartIndexLocked(self: *Manager, pending: PendingStart) ?usize {
        const index = self.findEntryIndexByIdAndGenerationLocked(pending.entry_id, pending.generation) orelse return null;
        const entry = &self.entries.items[index];
        if (entry.child != null or !rulesEqual(&entry.rule, &pending.rule)) return null;
        return index;
    }

    fn autoStartCandidateAtIndexLocked(self: *Manager, index: usize) ?AutoStartCandidate {
        if (index >= self.entries.items.len) return null;
        const entry = &self.entries.items[index];
        if (!entry.rule.enabled or !entry.rule.auto_start) return null;
        return .{
            .entry_id = entry.id,
            .generation = entry.generation,
        };
    }

    fn findEntryIndexByIdAndGenerationLocked(self: *Manager, entry_id: u64, generation: u64) ?usize {
        const index = self.findEntryIndexByIdLocked(entry_id) orelse return null;
        return if (self.entries.items[index].generation == generation) index else null;
    }

    fn findEntryIndexByIdLocked(self: *Manager, entry_id: u64) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.id == entry_id) return index;
        }
        return null;
    }

    fn nextEntryIdLocked(self: *Manager) u64 {
        const id = self.next_entry_id;
        self.next_entry_id = if (self.next_entry_id == std.math.maxInt(u64)) 1 else self.next_entry_id + 1;
        return id;
    }

    fn nextGenerationLocked(self: *Manager) u64 {
        const generation = self.next_generation;
        self.next_generation = if (self.next_generation == std.math.maxInt(u64)) 1 else self.next_generation + 1;
        return generation;
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
    if (conn.usesPasswordAuth()) {
        try appendSshOption(allocator, &argv, "PreferredAuthentications=password,keyboard-interactive");
        try appendSshOption(allocator, &argv, "NumberOfPasswordPrompts=1");
    } else {
        try appendSshOption(allocator, &argv, "BatchMode=yes");
    }
    if (conn.usesIdentityFile()) {
        try argv.append(allocator, "-i");
        try argv.append(allocator, try allocator.dupe(u8, conn.identityFile()));
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

    if (conn.usesPasswordAuth()) {
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
    child.create_no_window = true;
    if (env_map) |*map| child.env_map = map;
    try child.spawn();
    child.waitForSpawn() catch |err| {
        stopRealChild(&child);
        return err;
    };
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

fn stopUpdateRuleLease(lease: *UpdateRuleLease) void {
    if (lease.child_to_stop) |*child| {
        stopChildState(child);
        lease.child_to_stop = null;
    }
}

fn stopRealChild(child: *std.process.Child) void {
    if (childHasExitedReal(child)) {
        cleanupExitedChild(child);
    } else {
        _ = child.kill() catch |err| {
            switch (err) {
                error.AlreadyTerminated => cleanupExitedChild(child),
                else => {
                    if (childHasExitedReal(child)) cleanupExitedChild(child);
                },
            }
        };
    }
}

fn cleanupExitedChild(child: *std.process.Child) void {
    if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
    _ = child.wait() catch {};
}

fn childHasExited(child: *const ChildState) bool {
    return switch (child.*) {
        .real => |*real_child| childHasExitedReal(real_child),
        .fake => |*fake| fake.exited,
    };
}

fn takeExitedChildFromEntry(entry: *Entry) ?ExitedChild {
    const child = entry.child orelse return null;
    if (!childHasExited(&child)) return null;
    entry.child = null;
    return ExitedChild.init(entry.id, entry.generation, child);
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

fn rulesEqual(a: *const rule_mod.Rule, b: *const rule_mod.Rule) bool {
    return std.mem.eql(u8, a.name(), b.name()) and
        std.mem.eql(u8, a.profileName(), b.profileName()) and
        a.direction == b.direction and
        std.mem.eql(u8, a.localHost(), b.localHost()) and
        a.local_port == b.local_port and
        std.mem.eql(u8, a.remoteHost(), b.remoteHost()) and
        a.remote_port == b.remote_port and
        a.enabled == b.enabled;
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

test "port_forward_manager: save and load from explicit path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);
    const storage_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_root, "nested", "port_forwards" });
    defer std.testing.allocator.free(storage_path);

    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setStoragePathForTest(storage_path);

    var rule = rule_mod.defaultReverseProxy("devbox");
    rule.setName("Proxy");
    rule.auto_start = false;
    try manager.addRule(rule);

    try std.testing.expect(manager.save());

    var loaded = Manager.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.setStoragePathForTest(storage_path);

    try std.testing.expect(try loaded.load());
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    const row = loaded.rowAt(0).?;
    try std.testing.expectEqualStrings("Proxy", row.rule.name());
    try std.testing.expectEqualStrings("devbox", row.rule.profileName());
    try std.testing.expect(!row.auto_start);
    try std.testing.expectEqual(StatusKind.stopped, row.status);
}

test "port_forward_manager: load reports storage path snapshot allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var manager = Manager.init(failing_allocator.allocator());
    defer manager.deinit();
    try manager.setStoragePath("port_forwards");

    try std.testing.expectError(error.OutOfMemory, manager.load());
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

    try std.testing.expectEqualStrings(platform_pty_command.sshExecutableName(), argv[0]);
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
    try std.testing.expect(argvContainsForTest(password_argv, "PreferredAuthentications=password,keyboard-interactive"));
    try std.testing.expect(argvContainsForTest(password_argv, "NumberOfPasswordPrompts=1"));
    try std.testing.expect(!argvContainsForTest(password_argv, "BatchMode=yes"));
    try expectArgvLacksForTest(password_argv, "secret");

    var key_conn = sshConnectionForTest("alice", "key.test", "", "", "", false, false);
    const key_argv = try buildSshArgvForTest(arena.allocator(), &rule, &key_conn);
    try std.testing.expect(argvContainsForTest(key_argv, "BatchMode=yes"));
    try std.testing.expect(!argvContainsForTest(key_argv, "PreferredAuthentications=password,keyboard-interactive"));
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

test "port_forward_manager: update applies logical replacement before detached child cleanup" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old"));
    try std.testing.expect(manager.markRunningForTest(0, 123));

    var update = manager.beginUpdateRuleForTest(0, rule_mod.defaultReverseProxy("updated")) orelse return error.ExpectedUpdate;
    defer manager.finishUpdateRuleForTest(&update);

    const updated = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, updated.status);
    try std.testing.expectEqualStrings("", updated.reason());
    try std.testing.expectEqualStrings("updated", updated.rule.profileName());

    const pending = manager.beginPendingStartForTest(0) orelse return error.ExpectedPendingStart;
    try std.testing.expectEqualStrings("updated", pending.rule.profileName());
    try std.testing.expect(manager.completePendingStartFakeForTest(pending, 456));

    const running = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.running, running.status);
    try std.testing.expectEqualStrings("updated", running.rule.profileName());
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

test "port_forward_manager: stale pending start failure leaves replacement row alone" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old"));

    const pending = manager.beginPendingStartForTest(0) orelse return error.ExpectedPendingStart;
    try std.testing.expect(manager.updateRule(0, rule_mod.defaultReverseProxy("replacement")));

    try std.testing.expect(!manager.completePendingStartFailureForTest(pending, .missing_profile, "profile missing"));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expectEqualStrings("replacement", row.rule.profileName());
}

test "port_forward_manager: shifted pending start failure follows logical row" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("earlier"));
    try manager.addRule(rule_mod.defaultReverseProxy("target"));

    const pending = manager.beginPendingStartForTest(1) orelse return error.ExpectedPendingStart;
    try std.testing.expect(manager.deleteRule(0));

    try std.testing.expect(manager.completePendingStartFailureForTest(pending, .missing_profile, "profile missing"));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.missing_profile, row.status);
    try std.testing.expectEqualStrings("profile missing", row.reason());
}

test "port_forward_manager: shifted pending start install follows logical row" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("earlier"));
    try manager.addRule(rule_mod.defaultReverseProxy("target"));

    const pending = manager.beginPendingStartForTest(1) orelse return error.ExpectedPendingStart;
    try std.testing.expect(manager.deleteRule(0));

    try std.testing.expect(manager.completePendingStartFakeForTest(pending, 444));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.running, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expect(manager.markExitedForTest(0, "installed child exited"));
}

test "port_forward_manager: pending start survives auto-start toggle" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("target"));

    const pending = manager.beginPendingStartForTest(0) orelse return error.ExpectedPendingStart;
    try std.testing.expect(manager.toggleAutoStart(0));

    try std.testing.expect(manager.completePendingStartFakeForTest(pending, 555));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.running, row.status);
    try std.testing.expect(!row.auto_start);
    try std.testing.expect(manager.markExitedForTest(0, "installed child exited"));
}

test "port_forward_manager: stale pending start install leaves replacement row alone" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old"));

    const pending = manager.beginPendingStartForTest(0) orelse return error.ExpectedPendingStart;
    try std.testing.expect(manager.updateRule(0, rule_mod.defaultReverseProxy("replacement")));

    try std.testing.expect(!manager.completePendingStartFakeForTest(pending, 444));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expectEqualStrings("replacement", row.rule.profileName());
    try std.testing.expect(!manager.markExitedForTest(0, "stale child should not exist"));
}

test "port_forward_manager: stale exited child does not mark restarted row error" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expect(manager.markRunningForTest(0, 111));
    try std.testing.expect(manager.markExitedForTest(0, "old ssh exited"));

    var exited = manager.takeExitedChildForTest(0) orelse return error.ExpectedExitedChild;
    try std.testing.expect(manager.markRunningForTest(0, 222));

    try std.testing.expect(!manager.finishExitedChildForTest(&exited));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.running, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expect(manager.markExitedForTest(0, "new ssh exited"));
}

test "port_forward_manager: stale exited child does not mark replacement row error" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("old"));
    try std.testing.expect(manager.markRunningForTest(0, 111));
    try std.testing.expect(manager.markExitedForTest(0, "old ssh exited"));

    var exited = manager.takeExitedChildForTest(0) orelse return error.ExpectedExitedChild;
    try std.testing.expect(manager.updateRule(0, rule_mod.defaultReverseProxy("replacement")));

    try std.testing.expect(!manager.finishExitedChildForTest(&exited));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.stopped, row.status);
    try std.testing.expectEqualStrings("", row.reason());
    try std.testing.expectEqualStrings("replacement", row.rule.profileName());
}

test "port_forward_manager: shifted exited child completion follows logical row" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("earlier"));
    try manager.addRule(rule_mod.defaultReverseProxy("target"));
    try std.testing.expect(manager.markRunningForTest(1, 111));
    try std.testing.expect(manager.markExitedForTest(1, "target exited"));

    var exited = manager.takeExitedChildForTest(1) orelse return error.ExpectedExitedChild;
    try std.testing.expect(manager.deleteRule(0));

    try std.testing.expect(manager.finishExitedChildForTest(&exited));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.error_, row.status);
    try std.testing.expectEqualStrings("target exited", row.reason());
}

test "port_forward_manager: exited child completion survives auto-start toggle" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("target"));
    try std.testing.expect(manager.markRunningForTest(0, 111));
    try std.testing.expect(manager.markExitedForTest(0, "target exited"));

    var exited = manager.takeExitedChildForTest(0) orelse return error.ExpectedExitedChild;
    try std.testing.expect(manager.toggleAutoStart(0));

    try std.testing.expect(manager.finishExitedChildForTest(&exited));

    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.error_, row.status);
    try std.testing.expectEqualStrings("target exited", row.reason());
    try std.testing.expect(!row.auto_start);
}

test "port_forward_manager: shifted restart lease does not start wrong row" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("earlier"));
    try manager.addRule(rule_mod.defaultReverseProxy("target"));
    try manager.addRule(rule_mod.defaultReverseProxy("wrong"));

    var restart = manager.beginRestartForTest(1) orelse return error.ExpectedRestart;
    try std.testing.expect(manager.deleteRule(0));

    try std.testing.expect(manager.completeRestartFakeForTest(&restart, 222));

    const target = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", target.rule.profileName());
    try std.testing.expectEqual(StatusKind.running, target.status);

    const wrong = manager.rowAt(1).?;
    try std.testing.expectEqualStrings("wrong", wrong.rule.profileName());
    try std.testing.expectEqual(StatusKind.stopped, wrong.status);
}

test "port_forward_manager: sampled auto-start follows shifted logical row" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("earlier"));
    try manager.addRule(rule_mod.defaultReverseProxy("target"));
    try manager.addRule(rule_mod.defaultReverseProxy("wrong"));

    const candidate = manager.sampleAutoStartForTest(1) orelse return error.ExpectedAutoStart;
    try std.testing.expect(manager.deleteRule(0));

    const pending = manager.beginAutoStartForTest(candidate) orelse return error.ExpectedPendingStart;
    try std.testing.expectEqualStrings("target", pending.rule.profileName());
    try std.testing.expect(manager.completePendingStartFakeForTest(pending, 333));

    const target = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("target", target.rule.profileName());
    try std.testing.expectEqual(StatusKind.running, target.status);

    const wrong = manager.rowAt(1).?;
    try std.testing.expectEqualStrings("wrong", wrong.rule.profileName());
    try std.testing.expectEqual(StatusKind.stopped, wrong.status);
}

test "port_forward_manager: sampled auto-start skips loaded replacement" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("target"));

    const candidate = manager.sampleAutoStartForTest(0) orelse return error.ExpectedAutoStart;

    var rules = [_]rule_mod.Rule{rule_mod.defaultReverseProxy("replacement")};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try rule_mod.encodeRules(std.testing.allocator, &out, rules[0..]);
    try manager.loadFromContent(out.items);

    try std.testing.expect(manager.beginAutoStartForTest(candidate) == null);
    const row = manager.rowAt(0).?;
    try std.testing.expectEqualStrings("replacement", row.rule.profileName());
    try std.testing.expectEqual(StatusKind.stopped, row.status);
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

fn expectArgvLacksForTest(argv: []const []const u8, needle: []const u8) !void {
    for (argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, needle) == null);
    }
}
