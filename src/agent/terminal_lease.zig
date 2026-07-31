//! Runtime ownership for terminals exposed to AI agents.
//!
//! The registry is intentionally small and fixed-size: desktop tabs and
//! splits are bounded, and a linear scan keeps this cross-thread boundary
//! allocation-free.
const std = @import("std");

pub const AgentId = u64;
pub const MAX_SURFACES = 512;
pub const MAX_SURFACE_ID_BYTES = 64;

pub const Access = enum {
    unowned,
    owned,
    foreign,

    pub fn label(self: Access) []const u8 {
        return switch (self) {
            .unowned => "unowned",
            .owned => "owned",
            .foreign => "foreign",
        };
    }
};

const Record = struct {
    id: [MAX_SURFACE_ID_BYTES]u8 = undefined,
    id_len: u8 = 0,
    owner: AgentId = 0,
    seen_epoch: u64 = 0,

    fn matches(self: *const Record, surface_id: []const u8) bool {
        return @as(usize, self.id_len) == surface_id.len and std.mem.eql(u8, self.id[0..self.id_len], surface_id);
    }

    fn setId(self: *Record, surface_id: []const u8) bool {
        if (surface_id.len == 0 or surface_id.len > self.id.len) return false;
        @memcpy(self.id[0..surface_id.len], surface_id);
        self.id_len = @intCast(surface_id.len);
        return true;
    }
};

pub const Registry = struct {
    // A complete UI snapshot must use one epoch. Keep concurrent agent
    // requests from interleaving begin/observe/finish cycles.
    sync_mutex: std.Thread.Mutex = .{},
    mutex: std.Thread.Mutex = .{},
    records: [MAX_SURFACES]Record = undefined,
    count: usize = 0,
    epoch: u64 = 0,

    pub fn clear(self: *Registry) void {
        self.sync_mutex.lock();
        defer self.sync_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count = 0;
        self.epoch = 0;
    }

    /// Begin a UI-thread snapshot sync. Every live terminal surface must be
    /// marked with `observe`; `finishSync` prunes closed terminal records.
    pub fn beginSync(self: *Registry) void {
        self.sync_mutex.lock();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.epoch +%= 1;
        if (self.epoch == 0) self.epoch = 1;
    }

    pub fn observe(self: *Registry, surface_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findLocked(surface_id)) |idx| {
            self.records[idx].seen_epoch = self.epoch;
            return;
        }
        if (self.count >= self.records.len) return;
        if (!self.records[self.count].setId(surface_id)) return;
        self.records[self.count].owner = 0;
        self.records[self.count].seen_epoch = self.epoch;
        self.count += 1;
    }

    pub fn finishSync(self: *Registry) void {
        defer self.sync_mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        var write: usize = 0;
        for (self.records[0..self.count]) |record| {
            if (record.seen_epoch != self.epoch) continue;
            self.records[write] = record;
            write += 1;
        }
        self.count = write;
    }

    /// Atomically assign an unowned surface to an agent. An existing owner is
    /// never replaced; only that same agent may reclaim it.
    pub fn claim(self: *Registry, actor: AgentId, surface_id: []const u8) bool {
        if (actor == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findLocked(surface_id) orelse self.insertLocked(surface_id) orelse return false;
        const record = &self.records[idx];
        if (record.owner != 0 and record.owner != actor) return false;
        record.owner = actor;
        return true;
    }

    /// Claim every surface in a terminal tab. The caller supplies the tab's
    /// surface ids from one coherent UI snapshot, so a partial claim is never
    /// left behind when a foreign owner is present.
    pub fn claimGroup(self: *Registry, actor: AgentId, surface_ids: []const []const u8) bool {
        if (actor == 0 or surface_ids.len == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (surface_ids) |surface_id| {
            const idx = self.findLocked(surface_id) orelse return false;
            const current_owner = self.records[idx].owner;
            if (current_owner != 0 and current_owner != actor) return false;
        }
        for (surface_ids) |surface_id| {
            const idx = self.findLocked(surface_id).?;
            self.records[idx].owner = actor;
        }
        return true;
    }

    pub fn access(self: *Registry, actor: AgentId, surface_id: []const u8) Access {
        // Zero is reserved for unit-test and non-agent contexts. Real sessions
        // always receive a non-zero runtime identity.
        if (actor == 0) return .owned;
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findLocked(surface_id) orelse return .unowned;
        const current_owner = self.records[idx].owner;
        if (current_owner == actor) return .owned;
        return if (current_owner == 0) .unowned else .foreign;
    }

    /// Return the current owner without exposing mutable registry storage.
    /// Callers use this only while expanding an already-owned tab to a new
    /// split observed in the same UI snapshot.
    pub fn owner(self: *Registry, surface_id: []const u8) AgentId {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findLocked(surface_id) orelse return 0;
        return self.records[idx].owner;
    }

    /// Release every terminal still assigned to an Agent that has ended. A
    /// transient SSH disconnect never calls this, so reconnecting the original
    /// surface cannot transfer it to another Agent.
    pub fn releaseOwner(self: *Registry, actor: AgentId) void {
        if (actor == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records[0..self.count]) |*record| {
            if (record.owner == actor) record.owner = 0;
        }
    }

    pub fn canRead(self: *Registry, actor: AgentId, surface_id: []const u8) bool {
        return self.access(actor, surface_id) == .owned;
    }

    pub fn canWrite(self: *Registry, actor: AgentId, surface_id: []const u8) bool {
        return self.access(actor, surface_id) == .owned;
    }

    fn findLocked(self: *Registry, surface_id: []const u8) ?usize {
        for (self.records[0..self.count], 0..) |*record, idx| {
            if (record.matches(surface_id)) return idx;
        }
        return null;
    }

    fn insertLocked(self: *Registry, surface_id: []const u8) ?usize {
        if (self.count >= self.records.len) return null;
        if (!self.records[self.count].setId(surface_id)) return null;
        self.records[self.count].owner = 0;
        self.records[self.count].seen_epoch = self.epoch;
        self.count += 1;
        return self.count - 1;
    }
};

var g_active: Registry = .{};

pub fn active() *Registry {
    return &g_active;
}

test "registry claims a group atomically and hides foreign terminals" {
    var registry = Registry{};
    registry.beginSync();
    registry.observe("a");
    registry.observe("b");
    registry.finishSync();

    try std.testing.expect(registry.claimGroup(11, &.{ "a", "b" }));
    try std.testing.expectEqual(Access.owned, registry.access(11, "a"));
    try std.testing.expectEqual(Access.foreign, registry.access(22, "b"));
    try std.testing.expect(!registry.claimGroup(22, &.{"a"}));
}

test "registry removes records absent from the next live snapshot" {
    var registry = Registry{};
    registry.beginSync();
    registry.observe("old");
    registry.finishSync();
    try std.testing.expect(registry.claim(7, "old"));

    registry.beginSync();
    registry.observe("new");
    registry.finishSync();
    try std.testing.expectEqual(Access.unowned, registry.access(7, "old"));
}

test "registry releases ownership only when the Agent ends" {
    var registry = Registry{};
    registry.beginSync();
    registry.observe("ssh-surface");
    registry.finishSync();
    try std.testing.expect(registry.claim(7, "ssh-surface"));
    try std.testing.expectEqual(Access.owned, registry.access(7, "ssh-surface"));

    registry.releaseOwner(7);
    try std.testing.expectEqual(Access.unowned, registry.access(7, "ssh-surface"));
}
