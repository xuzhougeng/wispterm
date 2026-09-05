//! Workbench-owned source checklist; credentials stay in the SSH profile store.
const std = @import("std");
const builtin = @import("builtin");
const selection_mod = @import("../memory_digest/source_selection.zig");
const sources = @import("../memory_digest/sources.zig");
const i18n = @import("../i18n.zig");

pub const Item = struct {
    id: []const u8,
    label: []const u8,
    tool: ?@import("../memory_digest/types.zig").DigestProvider = null,
    location_enabled: bool = true,
    checked: bool,
};

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item,

    pub fn load(gpa: std.mem.Allocator, legacy_remote: bool) !Settings {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const selection = try selection_mod.load(a);
        var items: std.ArrayListUnmanaged(Item) = .empty;
        try appendLocation(a, &items, selection, "local", i18n.s().memory_location_local, legacy_remote);
        if (builtin.os.tag == .windows) try appendLocation(a, &items, selection, "wsl:default", "WSL", legacy_remote);
        for (try sources.loadSshSources(gpa, a)) |source| {
            try appendLocation(a, &items, selection, source.source_id, source.source_id, legacy_remote);
        }
        // Retain temporarily missing profiles instead of silently deleting choices.
        if (selection.sources) |saved| {
            for (saved) |source| try appendMissingLocation(a, &items, selection, source.id, legacy_remote);
        } else if (selection.locations) |locations| {
            for (locations) |id| try appendMissingLocation(a, &items, selection, id, legacy_remote);
        }
        return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
    }

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }

    pub fn toggle(self: *Settings, gpa: std.mem.Allocator, index: usize) !void {
        if (index >= self.items.len) return;
        // Reload before changing one item so another Memory Center tab's
        // saved choices aren't overwritten by this tab's older snapshot.
        var fresh = try Settings.load(gpa, @import("../memory_digest/scheduler.zig").remoteScanEnabled());
        errdefer fresh.deinit();
        const id = self.items[index].id;
        for (fresh.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.id, id) and item.tool == self.items[index].tool) {
                try fresh.saveToggle(gpa, i);
                self.deinit();
                self.* = fresh;
                return;
            }
        }
        return error.SourceRemoved;
    }

    fn saveToggle(self: *Settings, gpa: std.mem.Allocator, index: usize) !void {
        self.items[index].checked = !self.items[index].checked;
        errdefer self.items[index].checked = !self.items[index].checked;
        const selection = try self.toSelection(gpa);
        defer gpa.free(selection.sources.?);
        try selection_mod.save(gpa, selection);
        const location_enabled = for (self.items) |item| {
            if (item.tool == null and std.mem.eql(u8, item.id, self.items[index].id)) break item.checked;
        } else false;
        for (self.items) |*item| {
            if (std.mem.eql(u8, item.id, self.items[index].id)) item.location_enabled = location_enabled;
        }
    }

    fn toSelection(self: *const Settings, gpa: std.mem.Allocator) !selection_mod.Selection {
        var locations: std.ArrayListUnmanaged(selection_mod.Location) = .empty;
        errdefer locations.deinit(gpa);
        for (self.items) |item| {
            if (item.tool) |tool| {
                inline for (std.meta.fields(selection_mod.Providers)) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(tool))) @field(locations.items[locations.items.len - 1].providers, field.name) = item.checked;
                }
            } else {
                try locations.append(gpa, .{ .id = item.id, .enabled = item.checked });
            }
        }
        return .{ .sources = try locations.toOwnedSlice(gpa) };
    }
};

fn appendMissingLocation(a: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), selection: selection_mod.Selection, id: []const u8, legacy_remote: bool) !void {
    for (items.items) |item| if (item.tool == null and std.mem.eql(u8, item.id, id)) return;
    try appendLocation(a, items, selection, id, id, legacy_remote);
}

fn appendLocation(a: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), selection: selection_mod.Selection, id: []const u8, label: []const u8, legacy_remote: bool) !void {
    const enabled = selection.includes(id, legacy_remote);
    const providers = selection.providersFor(id);
    try items.append(a, .{ .id = id, .label = label, .checked = enabled, .location_enabled = enabled });
    inline for (.{ .{ "codex", "Codex" }, .{ "claude", "Claude Code" }, .{ "kimi", "Kimi" }, .{ "grok", "Grok Build" }, .{ "wispterm", "WispTerm" } }) |pair| {
        // WispTerm's own assistant history is only collected locally.
        if (!std.mem.eql(u8, pair[0], "wispterm") or std.mem.eql(u8, id, "local")) {
            try items.append(a, .{ .id = id, .label = pair[1], .tool = @field(@import("../memory_digest/types.zig").DigestProvider, pair[0]), .checked = @field(providers, pair[0]), .location_enabled = enabled });
        }
    }
}

test "source tree migrates flat choices and keeps per-server tools independent" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var items: std.ArrayListUnmanaged(Item) = .empty;
    const legacy = selection_mod.Selection{ .locations = &.{ "local", "ssh:CPU", "ssh:GPU" }, .providers = .{ .grok = true } };
    try appendLocation(arena.allocator(), &items, legacy, "local", "Local", false);
    try appendLocation(arena.allocator(), &items, legacy, "ssh:CPU", "CPU", false);
    try appendLocation(arena.allocator(), &items, legacy, "ssh:GPU", "GPU", false);
    var settings = Settings{ .arena = arena, .items = items.items };
    defer settings.deinit();
    for (settings.items) |*item| {
        if (std.mem.eql(u8, item.id, "ssh:CPU") and item.tool == .codex) item.checked = false;
        if (std.mem.eql(u8, item.id, "ssh:GPU") and item.tool == null) item.checked = false;
        if (item.tool == .wispterm) try std.testing.expectEqualStrings("local", item.id);
    }
    const selected = try settings.toSelection(a);
    defer a.free(selected.sources.?);
    try std.testing.expectEqual(@as(usize, 3), selected.sources.?.len);
    try std.testing.expect(selected.includes("ssh:CPU", false));
    try std.testing.expect(!selected.providersFor("ssh:CPU").codex);
    try std.testing.expect(selected.providersFor("local").codex);
    try std.testing.expect(!selected.includes("ssh:GPU", true));
    try std.testing.expect(selected.providersFor("ssh:GPU").codex);
    try std.testing.expect(selected.providersFor("ssh:GPU").grok);
    try std.testing.expect(!selected.includes("ssh:new", true));
}
