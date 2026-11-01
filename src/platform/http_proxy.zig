const std = @import("std");
const Config = @import("../config.zig");

/// Resolved route for WispTerm-owned HTTP requests.
/// `explicit` is owned by this value and borrowed only until `deinit`.
pub const Route = struct {
    enabled: bool = false,
    explicit: ?[]u8 = null,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        if (self.explicit) |value| allocator.free(value);
        self.* = .{};
    }
};

/// Resolve the shared HTTP proxy settings without reading configuration twice.
pub fn load(allocator: std.mem.Allocator) Route {
    var cfg = Config.load(allocator) catch return .{};
    defer cfg.deinit(allocator);
    return fromSettings(allocator, cfg.@"http-use-system-proxy", cfg.@"http-proxy");
}

/// Resolve the independent research route. An empty custom value inherits the AI proxy address.
pub fn loadResearch(allocator: std.mem.Allocator) Route {
    var cfg = Config.load(allocator) catch return .{};
    defer cfg.deinit(allocator);
    return fromResearchSettings(
        allocator,
        cfg.@"research-use-proxy",
        cfg.@"research-proxy",
        cfg.@"http-use-system-proxy",
        cfg.@"http-proxy",
    );
}

/// Pure research route construction. A custom address wins. Empty inherits
/// `base_value` and stays enabled: `research_enabled` is the switch, and the
/// AI proxy toggle does not gate this route.
pub fn fromResearchSettings(
    allocator: std.mem.Allocator,
    research_enabled: bool,
    research_value: []const u8,
    base_enabled: bool,
    base_value: []const u8,
) Route {
    if (!research_enabled) return .{};
    _ = base_enabled;
    const trimmed = std.mem.trim(u8, research_value, " \t\r\n");
    if (trimmed.len > 0) return fromSettings(allocator, true, trimmed);
    return fromSettings(allocator, true, base_value);
}

/// Pure route construction used by callers and unit tests.
pub fn fromSettings(allocator: std.mem.Allocator, enabled: bool, value: []const u8) Route {
    if (!enabled) return .{};
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return .{ .enabled = true };
    const explicit = allocator.dupe(u8, trimmed) catch return .{ .enabled = true };
    return .{ .enabled = true, .explicit = explicit };
}

test "research route inherits or overrides the AI proxy" {
    const allocator = std.testing.allocator;

    var inherited = fromResearchSettings(allocator, true, "", true, "127.0.0.1:1");
    defer inherited.deinit(allocator);
    try std.testing.expectEqualStrings("127.0.0.1:1", inherited.explicit.?);

    var system = fromResearchSettings(allocator, true, "", true, "");
    defer system.deinit(allocator);
    try std.testing.expect(system.enabled);
    try std.testing.expect(system.explicit == null);

    var custom = fromResearchSettings(allocator, true, "127.0.0.1:2", false, "127.0.0.1:1");
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings("127.0.0.1:2", custom.explicit.?);

    var inherited_while_ai_off = fromResearchSettings(allocator, true, "", false, "127.0.0.1:1");
    defer inherited_while_ai_off.deinit(allocator);
    try std.testing.expect(inherited_while_ai_off.enabled);
    try std.testing.expectEqualStrings("127.0.0.1:1", inherited_while_ai_off.explicit.?);

    var system_while_ai_off = fromResearchSettings(allocator, true, "", false, "  ");
    defer system_while_ai_off.deinit(allocator);
    try std.testing.expect(system_while_ai_off.enabled);
    try std.testing.expect(system_while_ai_off.explicit == null);

    var disabled = fromResearchSettings(allocator, false, "127.0.0.1:2", true, "127.0.0.1:1");
    defer disabled.deinit(allocator);
    try std.testing.expect(!disabled.enabled);
}

test "http proxy route preserves direct, system, and explicit modes" {
    const allocator = std.testing.allocator;

    var direct = fromSettings(allocator, false, "127.0.0.1:8080");
    defer direct.deinit(allocator);
    try std.testing.expect(!direct.enabled);
    try std.testing.expect(direct.explicit == null);

    var system = fromSettings(allocator, true, "  ");
    defer system.deinit(allocator);
    try std.testing.expect(system.enabled);
    try std.testing.expect(system.explicit == null);

    var explicit = fromSettings(allocator, true, " http://127.0.0.1:8080 ");
    defer explicit.deinit(allocator);
    try std.testing.expect(explicit.enabled);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", explicit.explicit.?);
}
