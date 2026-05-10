// src/session_persist.zig
const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;

pub const Layout = enum { horizontal, vertical };

pub const SurfaceSnap = union(enum) {
    local_shell: LocalShellSnap,
    ssh: SshSnap,

    pub const LocalShellSnap = struct {
        cwd: ?[]const u8 = null,
        command: ?[]const []const u8 = null,
    };

    pub const SshSnap = struct {
        cwd: ?[]const u8 = null,
        user: []const u8,
        host: []const u8,
        port: u16 = 22,
        // SECURITY INVARIANT (I1): NO password field. Adding one would
        // cause SSH passwords to be persisted to disk on every close.
    };
};

pub const NodeSnap = union(enum) {
    leaf: LeafSnap,
    split: SplitSnap,

    pub const LeafSnap = struct {
        surface: SurfaceSnap,
    };

    pub const SplitSnap = struct {
        layout: Layout,
        ratio: f64,
        left: *NodeSnap,
        right: *NodeSnap,
    };
};

pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
};

pub const Session = struct {
    version: u32 = SCHEMA_VERSION,
    active_tab: u32 = 0,
    tabs: []TabSnap,
};

test "session_persist: empty Session compiles and has expected defaults" {
    const empty: Session = .{ .tabs = &.{} };
    try std.testing.expectEqual(@as(u32, 1), empty.version);
    try std.testing.expectEqual(@as(u32, 0), empty.active_tab);
    try std.testing.expectEqual(@as(usize, 0), empty.tabs.len);
}
