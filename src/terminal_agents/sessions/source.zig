const std = @import("std");
const types = @import("types.zig");

pub const Target = union(enum) {
    local,
    wsl: WslTarget,
    ssh: SshTargetRef,
};

pub const WslTarget = struct { distro: []const u8 = "" };
pub const SshTargetRef = struct { profile_name: []const u8 };

pub const ProviderFlags = packed struct {
    codex: bool = true,
    claude: bool = true,
    kimi: bool = true,
    opencode: bool = true,
    pi: bool = true,
};

pub const ProviderRoot = struct {
    provider: types.ProviderId,
    path: []const u8,
};

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    target: Target,
    providers: ProviderFlags = .{},
    codex_root_override: ?[]const u8 = null,
    claude_root_override: ?[]const u8 = null,
    kimi_root_override: ?[]const u8 = null,
    opencode_root_override: ?[]const u8 = null,
    pi_root_override: ?[]const u8 = null,
    extra_roots: []const ProviderRoot = &.{},
};

pub fn defaultRoot(provider: types.ProviderId, home: []const u8, out: []u8) ?[]const u8 {
    const suffix = switch (provider) {
        .codex => ".codex",
        .claude => ".claude",
        .kimi => ".kimi-code",
        .opencode => ".local/share/opencode",
        .pi => ".pi/agent/sessions",
    };
    return std.fmt.bufPrint(out, "{s}/{s}", .{ home, suffix }) catch null;
}

test "ai_history_source: default provider roots use target home" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/.codex", defaultRoot(.codex, "/home/me", &buf).?);
    try std.testing.expectEqualStrings("/home/me/.claude", defaultRoot(.claude, "/home/me", &buf).?);
    try std.testing.expectEqualStrings("/home/me/.kimi-code", defaultRoot(.kimi, "/home/me", &buf).?);
    try std.testing.expectEqualStrings("/home/me/.local/share/opencode", defaultRoot(.opencode, "/home/me", &buf).?);
    try std.testing.expectEqualStrings("/home/me/.pi/agent/sessions", defaultRoot(.pi, "/home/me", &buf).?);
}
