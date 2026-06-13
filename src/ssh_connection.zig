//! Self-contained SSH connection descriptor (fixed-buffer fields + accessors).
//! Lives outside Surface.zig so remote-IO logic modules (scp, ssh_tunnel,
//! file_backend, file_explorer) can use it without compiling the heavy
//! ghostty-vt / renderer graph that Surface pulls in.

const std = @import("std");

pub const SshConnection = struct {
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    port_buf: [16]u8 = undefined,
    port_len: usize = 0,
    password_buf: [128]u8 = undefined,
    password_len: usize = 0,
    proxy_jump_buf: [256]u8 = undefined,
    proxy_jump_len: usize = 0,
    password_auth: bool = false,
    legacy_algorithms: bool = false,

    pub fn user(self: *const SshConnection) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn proxyJump(self: *const SshConnection) []const u8 {
        return self.proxy_jump_buf[0..self.proxy_jump_len];
    }

    pub fn host(self: *const SshConnection) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn port(self: *const SshConnection) []const u8 {
        return self.port_buf[0..self.port_len];
    }

    pub fn password(self: *const SshConnection) []const u8 {
        return self.password_buf[0..self.password_len];
    }

    pub const Parts = struct {
        user: []const u8,
        host: []const u8,
        port: []const u8 = "",
        proxy_jump: []const u8 = "",
    };

    /// Build a connection from already-validated SSH params (the caller
    /// validates with isSshTokenSafe/isPortTokenSafe). Truncates to buffer
    /// capacity. password is left empty (tmux injects it at the ssh prompt).
    pub fn fromParts(p: Parts) SshConnection {
        var c: SshConnection = .{};
        c.user_len = copyInto(&c.user_buf, p.user);
        c.host_len = copyInto(&c.host_buf, p.host);
        c.port_len = copyInto(&c.port_buf, p.port);
        c.proxy_jump_len = copyInto(&c.proxy_jump_buf, p.proxy_jump);
        return c;
    }

    fn copyInto(buf: []u8, src: []const u8) usize {
        const n = @min(buf.len, src.len);
        @memcpy(buf[0..n], src[0..n]);
        return n;
    }
};

test "fromParts copies fields into the fixed buffers" {
    const c = SshConnection.fromParts(.{
        .user = "alice",
        .host = "10.0.0.5",
        .port = "2222",
        .proxy_jump = "jump.example",
    });
    try std.testing.expectEqualStrings("alice", c.user());
    try std.testing.expectEqualStrings("10.0.0.5", c.host());
    try std.testing.expectEqualStrings("2222", c.port());
    try std.testing.expectEqualStrings("jump.example", c.proxyJump());
}

test "fromParts handles empty optional fields" {
    const c = SshConnection.fromParts(.{ .user = "u", .host = "h" });
    try std.testing.expectEqualStrings("u", c.user());
    try std.testing.expectEqualStrings("h", c.host());
    try std.testing.expectEqualStrings("", c.port());
    try std.testing.expectEqualStrings("", c.proxyJump());
}
