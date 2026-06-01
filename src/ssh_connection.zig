//! Self-contained SSH connection descriptor (fixed-buffer fields + accessors).
//! Lives outside Surface.zig so remote-IO logic modules (scp, ssh_tunnel,
//! file_backend, file_explorer) can use it without compiling the heavy
//! ghostty-vt / renderer graph that Surface pulls in.

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
};
