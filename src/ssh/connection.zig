//! Self-contained SSH connection descriptor (fixed-buffer fields + accessors).
//! Lives outside Surface.zig so remote-IO logic modules (scp, ssh_tunnel,
//! file_backend, file_explorer) can use it without compiling the heavy
//! ghostty-vt / renderer graph that Surface pulls in.

const std = @import("std");

pub const IDENTITY_FILE_MAX = 512;

pub const SshAuthMethod = enum {
    password,
    key,
    credentials,

    pub fn parse(value: []const u8) ?SshAuthMethod {
        if (std.ascii.eqlIgnoreCase(value, "password")) return .password;
        if (std.ascii.eqlIgnoreCase(value, "key")) return .key;
        if (std.ascii.eqlIgnoreCase(value, "credentials")) return .credentials;
        return null;
    }

    pub fn fieldValue(self: SshAuthMethod) []const u8 {
        return switch (self) {
            .password => "password",
            .key => "key",
            .credentials => "credentials",
        };
    }

    /// Cycle to the next/previous auth method (wraps). Used by the SSH profile
    /// form so the auth-method field is a ←/→ toggle over valid values instead
    /// of a free-text field.
    pub fn cycle(self: SshAuthMethod, forward: bool) SshAuthMethod {
        if (forward) {
            return switch (self) {
                .password => .key,
                .key => .credentials,
                .credentials => .password,
            };
        }
        return switch (self) {
            .password => .credentials,
            .key => .password,
            .credentials => .key,
        };
    }
};

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
    identity_file_buf: [IDENTITY_FILE_MAX]u8 = undefined,
    identity_file_len: usize = 0,
    auth_method: SshAuthMethod = .credentials,
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

    pub fn identityFile(self: *const SshConnection) []const u8 {
        return self.identity_file_buf[0..self.identity_file_len];
    }

    pub fn usesPasswordAuth(self: *const SshConnection) bool {
        return self.password_auth or (self.auth_method == .password and self.password_len > 0);
    }

    pub fn usesIdentityFile(self: *const SshConnection) bool {
        return self.auth_method == .key and self.identity_file_len > 0;
    }

    pub const Parts = struct {
        user: []const u8,
        host: []const u8,
        port: []const u8 = "",
        proxy_jump: []const u8 = "",
        password: []const u8 = "",
        auth_method: ?SshAuthMethod = null,
        identity_file: []const u8 = "",
    };

    /// Build a connection from already-validated SSH params (the caller
    /// validates with isSshTokenSafe/isPortTokenSafe). Truncates to buffer
    /// capacity.
    pub fn fromParts(p: Parts) SshConnection {
        var c: SshConnection = .{};
        c.user_len = copyInto(&c.user_buf, p.user);
        c.host_len = copyInto(&c.host_buf, p.host);
        c.port_len = copyInto(&c.port_buf, p.port);
        c.proxy_jump_len = copyInto(&c.proxy_jump_buf, p.proxy_jump);
        c.password_len = copyInto(&c.password_buf, p.password);
        c.identity_file_len = copyInto(&c.identity_file_buf, p.identity_file);
        c.auth_method = p.auth_method orelse if (p.password.len > 0) .password else .credentials;
        c.password_auth = c.usesPasswordAuth();
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
        .password = "s3cret",
    });
    try std.testing.expectEqualStrings("alice", c.user());
    try std.testing.expectEqualStrings("10.0.0.5", c.host());
    try std.testing.expectEqualStrings("2222", c.port());
    try std.testing.expectEqualStrings("jump.example", c.proxyJump());
    try std.testing.expectEqualStrings("s3cret", c.password());
    try std.testing.expect(c.password_auth);
}

test "fromParts handles empty optional fields" {
    const c = SshConnection.fromParts(.{ .user = "u", .host = "h" });
    try std.testing.expectEqualStrings("u", c.user());
    try std.testing.expectEqualStrings("h", c.host());
    try std.testing.expectEqualStrings("", c.port());
    try std.testing.expectEqualStrings("", c.proxyJump());
    try std.testing.expectEqualStrings("", c.password());
    try std.testing.expect(!c.password_auth);
}

test "fromParts supports explicit key auth" {
    const c = SshConnection.fromParts(.{
        .user = "alice",
        .host = "example.test",
        .auth_method = .key,
        .identity_file = "C:/Users/alice/.ssh/id_ed25519",
    });
    try std.testing.expectEqual(SshAuthMethod.key, c.auth_method);
    try std.testing.expectEqualStrings("C:/Users/alice/.ssh/id_ed25519", c.identityFile());
    try std.testing.expect(!c.password_auth);
}

test "SshAuthMethod.cycle wraps forward and backward over all three methods" {
    try std.testing.expectEqual(SshAuthMethod.key, SshAuthMethod.password.cycle(true));
    try std.testing.expectEqual(SshAuthMethod.credentials, SshAuthMethod.key.cycle(true));
    try std.testing.expectEqual(SshAuthMethod.password, SshAuthMethod.credentials.cycle(true));

    try std.testing.expectEqual(SshAuthMethod.credentials, SshAuthMethod.password.cycle(false));
    try std.testing.expectEqual(SshAuthMethod.password, SshAuthMethod.key.cycle(false));
    try std.testing.expectEqual(SshAuthMethod.key, SshAuthMethod.credentials.cycle(false));
}
