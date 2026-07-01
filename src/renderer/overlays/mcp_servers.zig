//! In-app "MCP Servers" config panel: overlay state that loads configured
//! servers from disk into a fixed-size, heap-free struct. Mirrors
//! ssh_profiles.zig conventions (fixed arrays, fixed char buffers with a
//! `_len`, no heap allocation stored on the struct — this lives inside the
//! multi-MB OverlayState).
const std = @import("std");
const mcp_registry = @import("../../tools/mcp_registry.zig");

pub const MCP_SERVER_MAX = 32;
pub const FIELD_MAX = 512;

/// One server row as displayed in the panel. `args` is the arg list joined
/// by single spaces (display-only — mcp_registry.ServerConfig owns the real
/// `[][]u8`).
pub const Server = struct {
    name: [FIELD_MAX]u8 = undefined,
    name_len: usize = 0,
    command: [FIELD_MAX]u8 = undefined,
    command_len: usize = 0,
    args: [FIELD_MAX]u8 = undefined,
    args_len: usize = 0,
    enabled: bool = true,
};

pub const View = enum { list, form, json_preview };

pub const State = struct {
    visible: bool = false,
    view: View = .list,
    servers: [MCP_SERVER_MAX]Server = undefined,
    count: usize = 0,
    list_selected: usize = 0,

    /// Reset to defaults and load `<config-dir>/mcp.json` into `servers`.
    /// A missing/unreadable config file yields zero servers (not an error).
    pub fn open(self: *State, allocator: std.mem.Allocator) void {
        self.* = .{ .visible = true };
        const loaded = mcp_registry.loadConfigFile(allocator) catch return;
        defer mcp_registry.freeServersConfig(allocator, loaded);
        for (loaded) |cfg| {
            if (self.count >= MCP_SERVER_MAX) break;
            var s = Server{ .enabled = cfg.enabled };
            setBuf(&s.name, &s.name_len, cfg.name);
            setBuf(&s.command, &s.command_len, cfg.command);
            var joined: [FIELD_MAX]u8 = undefined;
            var n: usize = 0;
            for (cfg.args, 0..) |arg, i| {
                if (i != 0 and n < FIELD_MAX) {
                    joined[n] = ' ';
                    n += 1;
                }
                const take = @min(arg.len, FIELD_MAX - n);
                @memcpy(joined[n..][0..take], arg[0..take]);
                n += take;
            }
            setBuf(&s.args, &s.args_len, joined[0..n]);
            self.servers[self.count] = s;
            self.count += 1;
        }
    }

    /// Move the list selection by `delta`, clamped to `[0, count-1]`.
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.count == 0) return;
        const cur: i32 = @intCast(self.list_selected);
        const max: i32 = @intCast(self.count - 1);
        self.list_selected = @intCast(std.math.clamp(cur + delta, 0, max));
    }

    pub fn serverName(self: *const State, i: usize) []const u8 {
        return self.servers[i].name[0..self.servers[i].name_len];
    }
};

/// Truncate-copy `src` into `buf`, recording the copied length in `len_ptr`.
fn setBuf(buf: []u8, len_ptr: *usize, src: []const u8) void {
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    len_ptr.* = len;
}

test "open loads servers from the config dir and clamps selection" {
    const mcp_registry_dirs = @import("../../platform/dirs.zig");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    mcp_registry_dirs.setTestConfigDirOverride(dir_path);
    defer mcp_registry_dirs.setTestConfigDirOverride(null);
    const servers = [_]mcp_registry.ServerConfig{
        .{ .name = @constCast("a"), .command = @constCast("x"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("b"), .command = @constCast("y"), .args = &.{}, .enabled = false },
    };
    try mcp_registry.saveConfigFile(a, servers[0..]);

    var state: State = .{};
    state.open(a);
    try std.testing.expect(state.visible);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("a", state.serverName(0));
    try std.testing.expect(!state.servers[1].enabled);

    state.list_selected = 0;
    state.moveSelection(-1); // clamps at 0
    try std.testing.expectEqual(@as(usize, 0), state.list_selected);
    state.moveSelection(5); // clamps at count-1
    try std.testing.expectEqual(@as(usize, 1), state.list_selected);
}
