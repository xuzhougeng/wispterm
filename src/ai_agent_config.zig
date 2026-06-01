//! Small, dependency-light AI-agent config types shared by config.zig and
//! ai_chat.zig. Kept out of the 8k-line ai_chat.zig so config (and its fast
//! unit tests) need not compile the full AI session/API/tool-exec graph.
const std = @import("std");

pub const AgentPermission = enum {
    confirm,
    full,

    pub fn parse(value: []const u8) ?AgentPermission {
        if (std.mem.eql(u8, value, "confirm")) return .confirm;
        if (std.mem.eql(u8, value, "full") or std.mem.eql(u8, value, "full-permission")) return .full;
        return null;
    }

    pub fn name(self: AgentPermission) []const u8 {
        return switch (self) {
            .confirm => "confirm",
            .full => "full",
        };
    }
};

test "AgentPermission.parse accepts confirm/full/full-permission" {
    try std.testing.expectEqual(AgentPermission.confirm, AgentPermission.parse("confirm").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full-permission").?);
    try std.testing.expectEqual(@as(?AgentPermission, null), AgentPermission.parse("nope"));
}

test "AgentPermission.name round-trips" {
    try std.testing.expectEqualStrings("confirm", AgentPermission.confirm.name());
    try std.testing.expectEqualStrings("full", AgentPermission.full.name());
}
