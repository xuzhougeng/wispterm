//! Workbench-owned source checklist; credentials stay in the SSH profile store.
const std = @import("std");
const builtin = @import("builtin");
const selection_mod = @import("../memory_digest/source_selection.zig");
const sources = @import("../memory_digest/sources.zig");
const i18n = @import("../i18n.zig");

pub const Item = struct {
    id: []const u8,
    label: []const u8,
    provider: bool = false,
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
        inline for (.{ .{ "codex", "Codex" }, .{ "claude", "Claude Code" }, .{ "kimi", "Kimi" }, .{ "wispterm", "WispTerm" } }) |pair| {
            try items.append(a, .{ .id = pair[0], .label = pair[1], .provider = true, .checked = @field(selection.providers, pair[0]) });
        }
        try items.append(a, .{ .id = "local", .label = i18n.s().memory_location_local, .checked = selection.includes("local", legacy_remote) });
        if (builtin.os.tag == .windows) try items.append(a, .{ .id = "wsl:default", .label = "WSL", .checked = selection.includes("wsl:default", legacy_remote) });
        for (try sources.loadSshSources(gpa, a)) |source| {
            try items.append(a, .{ .id = source.source_id, .label = source.source_id, .checked = selection.includes(source.source_id, legacy_remote) });
        }
        // Keep selections for temporarily missing profiles visible and editable.
        if (selection.locations) |locations| for (locations) |id| {
            const found = for (items.items) |item| {
                if (!item.provider and std.mem.eql(u8, item.id, id)) break true;
            } else false;
            if (!found) try items.append(a, .{ .id = id, .label = id, .checked = true });
        };
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
            if (std.mem.eql(u8, item.id, id) and item.provider == self.items[index].provider) {
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
        var selection = selection_mod.Selection{};
        var locations: std.ArrayListUnmanaged([]const u8) = .empty;
        defer locations.deinit(gpa);
        for (self.items) |item| {
            if (item.provider) {
                inline for (std.meta.fields(selection_mod.Providers)) |field| {
                    if (std.mem.eql(u8, field.name, item.id)) @field(selection.providers, field.name) = item.checked;
                }
            } else if (item.checked) try locations.append(gpa, item.id);
        }
        selection.locations = locations.items;
        try selection_mod.save(gpa, selection);
    }
};
