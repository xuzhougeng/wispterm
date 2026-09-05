//! Persisted digest input selection, shared by the workbench and scheduler.
const std = @import("std");
const dirs = @import("../platform/dirs.zig");
const atomic_file = @import("../platform/atomic_file.zig");
const types = @import("types.zig");

pub const Providers = struct {
    codex: bool = true,
    claude: bool = true,
    kimi: bool = false,
    grok: bool = false,
    wispterm: bool = true,

    pub fn enabled(self: Providers, provider: types.DigestProvider) bool {
        return switch (provider) {
            inline else => |p| @field(self, @tagName(p)),
        };
    }
};

pub const Selection = struct {
    providers: Providers = .{},
    // null inherits the legacy local + scan-remote behavior. An empty list
    // explicitly disables all locations; new servers aren't silently opted in.
    locations: ?[]const []const u8 = null,

    pub fn includes(self: Selection, id: []const u8, legacy_remote: bool) bool {
        const selected = self.locations orelse return std.mem.eql(u8, id, "local") or legacy_remote;
        for (selected) |location| if (std.mem.eql(u8, id, location)) return true;
        return false;
    }
};

pub fn path(allocator: std.mem.Allocator) ![]const u8 {
    const root = try dirs.memoryDir(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "sources.json" });
}

pub fn load(arena: std.mem.Allocator) !Selection {
    const filename = try path(arena);
    const bytes = std.fs.cwd().readFileAlloc(arena, filename, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Selection, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

pub fn save(allocator: std.mem.Allocator, selection: Selection) !void {
    const filename = try path(allocator);
    defer allocator.free(filename);
    const bytes = try std.json.Stringify.valueAlloc(allocator, selection, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try atomic_file.writeFileReplaceSafe(filename, bytes);
}

test "source selection preserves legacy defaults and explicit empty selection" {
    const defaults = Selection{};
    try std.testing.expect(defaults.includes("local", false));
    try std.testing.expect(!defaults.includes("ssh:GPU", false));
    try std.testing.expect(defaults.includes("ssh:GPU", true));
    const selected = Selection{ .locations = &.{"ssh:GPU"}, .providers = .{ .codex = false, .kimi = true } };
    try std.testing.expect(selected.includes("ssh:GPU", false));
    try std.testing.expect(!selected.includes("local", true));
    try std.testing.expect(!selected.includes("ssh:new", true));
    try std.testing.expect(!selected.providers.enabled(.codex));
    try std.testing.expect(selected.providers.enabled(.kimi));
    try std.testing.expect(!(Selection{ .locations = &.{} }).includes("local", true));
}
