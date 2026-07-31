//! Small, dependency-light AI-agent config types shared by config.zig and
//! the AI chat session. Kept out of the heavy conversation session so config
//! (and its fast unit tests) need not compile the full AI session/API/tool-exec
//! graph.
const std = @import("std");

pub const AgentPermission = enum {
    confirm,
    auto,
    full,

    pub fn parse(value: []const u8) ?AgentPermission {
        if (std.mem.eql(u8, value, "ask") or std.mem.eql(u8, value, "confirm")) return .confirm;
        if (std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "guarded")) return .auto;
        if (std.mem.eql(u8, value, "full") or std.mem.eql(u8, value, "full-permission")) return .full;
        return null;
    }

    pub fn name(self: AgentPermission) []const u8 {
        return switch (self) {
            .confirm => "ask",
            .auto => "auto",
            .full => "full",
        };
    }
};

test "AgentPermission.parse accepts ask auto full and legacy aliases" {
    try std.testing.expectEqual(AgentPermission.confirm, AgentPermission.parse("confirm").?);
    try std.testing.expectEqual(AgentPermission.confirm, AgentPermission.parse("ask").?);
    try std.testing.expectEqual(AgentPermission.auto, AgentPermission.parse("auto").?);
    try std.testing.expectEqual(AgentPermission.auto, AgentPermission.parse("guarded").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full-permission").?);
    try std.testing.expectEqual(@as(?AgentPermission, null), AgentPermission.parse("nope"));
}

test "AgentPermission.name round-trips" {
    try std.testing.expectEqualStrings("ask", AgentPermission.confirm.name());
    try std.testing.expectEqualStrings("auto", AgentPermission.auto.name());
    try std.testing.expectEqualStrings("full", AgentPermission.full.name());
}
