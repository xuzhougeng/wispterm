//! SSH loopback port forwarding for URLs opened from SSH terminal surfaces.

const std = @import("std");
const builtin = @import("builtin");
const Surface = @import("Surface.zig");
const ssh_connection = @import("ssh_connection.zig");
const browser_url = @import("browser_url.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const ui_perf = @import("ui_perf.zig");

const MAX_SSH_DEST_BYTES = 280;
const MAX_TUNNEL_SPEC_BYTES = 96;
const MAX_LOCAL_HOST_BYTES = 32;
const MAX_ACTIVE_TUNNELS = 32;
const TUNNEL_READY_TIMEOUT_MS = 8000;
const TUNNEL_READY_POLL_NS = 50 * std.time.ns_per_ms;

threadlocal var g_tunnels: [MAX_ACTIVE_TUNNELS]?SshTunnel = [_]?SshTunnel{null} ** MAX_ACTIVE_TUNNELS;

const SshTunnel = struct {
    child: std.process.Child,
    local_port: u16,
    remote_port: u16,
    local_host_buf: [MAX_LOCAL_HOST_BYTES]u8 = undefined,
    local_host_len: usize = 0,
    remote_host_buf: [MAX_LOCAL_HOST_BYTES]u8 = undefined,
    remote_host_len: usize = 0,
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    ssh_port_buf: [16]u8 = undefined,
    ssh_port_len: usize = 0,

    fn init(child: std.process.Child, conn: *const ssh_connection.SshConnection, remote_port: u16, local_port: u16, local_host: []const u8, remote_host: []const u8) SshTunnel {
        var tunnel: SshTunnel = .{
            .child = child,
            .local_port = local_port,
            .remote_port = remote_port,
        };
        tunnel.local_host_len = copyBounded(tunnel.local_host_buf[0..], local_host);
        tunnel.remote_host_len = copyBounded(tunnel.remote_host_buf[0..], remote_host);
        tunnel.user_len = copyBounded(tunnel.user_buf[0..], conn.user());
        tunnel.host_len = copyBounded(tunnel.host_buf[0..], conn.host());
        tunnel.ssh_port_len = copyBounded(tunnel.ssh_port_buf[0..], conn.port());
        return tunnel;
    }

    fn matches(self: *const SshTunnel, conn: *const ssh_connection.SshConnection, remote_port: u16, local_host: []const u8, remote_host: []const u8) bool {
        return self.remote_port == remote_port and
            std.mem.eql(u8, self.localHost(), local_host) and
            std.mem.eql(u8, self.remoteHost(), remote_host) and
            std.mem.eql(u8, self.user(), conn.user()) and
            std.mem.eql(u8, self.host(), conn.host()) and
            std.mem.eql(u8, self.sshPort(), conn.port());
    }

    fn localHost(self: *const SshTunnel) []const u8 {
        return self.local_host_buf[0..self.local_host_len];
    }

    fn remoteHost(self: *const SshTunnel) []const u8 {
        return self.remote_host_buf[0..self.remote_host_len];
    }

    fn user(self: *const SshTunnel) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    fn host(self: *const SshTunnel) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn sshPort(self: *const SshTunnel) []const u8 {
        return self.ssh_port_buf[0..self.ssh_port_len];
    }
};

pub fn externalUrlForSurface(allocator: std.mem.Allocator, url: []const u8, surface: ?*const Surface) ?[]u8 {
    if (sshLoopbackUrl(surface, url)) |request| {
        const local_port = ensureSshTunnel(
            allocator,
            &request.conn,
            request.parsed.port,
            browser_url.localTunnelHost(request.parsed.host),
            browser_url.remoteTunnelHost(request.parsed.host),
        ) orelse return null;
        return browser_url.buildLocalTunnelUrl(allocator, request.parsed, local_port);
    }

    if (browser_url.parseHttpUrl(url)) |parsed| {
        if (browser_url.isUnspecifiedHost(parsed.host)) {
            return browser_url.buildLocalTunnelUrl(allocator, parsed, parsed.port);
        }
    }

    return allocator.dupe(u8, url) catch null;
}

pub fn deinit() void {
    stopAll();
}

pub fn stopAll() void {
    for (&g_tunnels) |*slot| {
        stopTunnelSlot(slot);
    }
}

const SshLoopbackUrl = struct {
    conn: ssh_connection.SshConnection,
    parsed: browser_url.HttpUrl,
};

fn sshLoopbackUrl(surface: ?*const Surface, url: []const u8) ?SshLoopbackUrl {
    const s = surface orelse return null;
    if (s.launch_kind != .ssh) return null;
    const conn = s.ssh_connection orelse return null;
    const parsed = browser_url.parseHttpUrl(url) orelse return null;
    if (!browser_url.isLoopbackHost(parsed.host)) return null;
    return .{ .conn = conn, .parsed = parsed };
}

fn ensureSshTunnel(allocator: std.mem.Allocator, conn: *const ssh_connection.SshConnection, remote_port: u16, local_host: []const u8, remote_host: []const u8) ?u16 {
    const perf = ui_perf.begin("ssh_tunnel.ensure_ssh_tunnel");
    defer perf.end();

    pruneExitedTunnels();

    if (findReusableTunnel(allocator, conn, remote_port, local_host, remote_host)) |local_port| {
        return local_port;
    }

    const slot = firstEmptySlot() orelse return null;
    const local_port = reservePreferredLocalPort(remote_port) orelse return null;
    const child = spawnSshTunnel(allocator, conn, remote_port, local_port, local_host, remote_host) orelse return null;

    g_tunnels[slot] = SshTunnel.init(child, conn, remote_port, local_port, local_host, remote_host);
    if (g_tunnels[slot]) |*tunnel| {
        if (!waitForTunnelReady(allocator, local_host, local_port, &tunnel.child)) {
            std.debug.print("SSH browser tunnel did not become ready on {s}:{d}\n", .{ local_host, local_port });
            stopTunnelSlot(&g_tunnels[slot]);
            return null;
        }
    } else {
        return null;
    }

    std.debug.print("SSH browser tunnel: {s}:{d} -> remote {s}:{d}\n", .{ local_host, local_port, remote_host, remote_port });
    return local_port;
}

fn findReusableTunnel(allocator: std.mem.Allocator, conn: *const ssh_connection.SshConnection, remote_port: u16, local_host: []const u8, remote_host: []const u8) ?u16 {
    for (&g_tunnels) |*slot| {
        const tunnel = if (slot.*) |*tunnel| tunnel else continue;
        if (!tunnel.matches(conn, remote_port, local_host, remote_host)) continue;
        if (childHasExited(&tunnel.child)) {
            stopTunnelSlot(slot);
            continue;
        }
        if (!canConnectToLocalPort(allocator, tunnel.localHost(), tunnel.local_port)) {
            stopTunnelSlot(slot);
            continue;
        }
        return tunnel.local_port;
    }
    return null;
}

fn spawnSshTunnel(allocator: std.mem.Allocator, conn: *const ssh_connection.SshConnection, remote_port: u16, local_port: u16, local_host: []const u8, remote_host: []const u8) ?std.process.Child {
    var local_spec_buf: [MAX_TUNNEL_SPEC_BYTES]u8 = undefined;
    const local_spec = std.fmt.bufPrint(
        &local_spec_buf,
        "{s}:{d}:{s}:{d}",
        .{ local_host, local_port, remote_host, remote_port },
    ) catch return null;

    var dest_buf: [MAX_SSH_DEST_BYTES]u8 = undefined;
    const dest = sshDestination(&dest_buf, conn) orelse return null;

    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return null;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return null;
            map.put("DISPLAY", "wispterm") catch return null;
            map.put("WISPTERM_SSH_PASSWORD", conn.password()) catch return null;
        }
    }

    var argv_buf: [48][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "-T";
    argc += 1;
    argv_buf[argc] = "-L";
    argc += 1;
    argv_buf[argc] = local_spec;
    argc += 1;

    appendSshOption(&argv_buf, &argc, "ExitOnForwardFailure=yes");
    appendSshOption(&argv_buf, &argc, "StrictHostKeyChecking=accept-new");
    appendSshOption(&argv_buf, &argc, "ConnectTimeout=8");
    appendSshOption(&argv_buf, &argc, "ServerAliveInterval=60");
    appendSshOption(&argv_buf, &argc, "ServerAliveCountMax=3");
    if (conn.password_auth) {
        appendSshOption(&argv_buf, &argc, "PreferredAuthentications=publickey,password,keyboard-interactive");
        appendSshOption(&argv_buf, &argc, "NumberOfPasswordPrompts=1");
    } else {
        appendSshOption(&argv_buf, &argc, "BatchMode=yes");
    }
    // Route the forwarding connection through the same jump host as the
    // interactive session so loopback tunnels reach the real destination.
    // `proxy_opt_buf` must outlive the child spawn below, which it does.
    var proxy_opt_buf: [288]u8 = undefined;
    if (conn.proxyJump().len > 0) {
        const opt = std.fmt.bufPrint(&proxy_opt_buf, "ProxyJump={s}", .{conn.proxyJump()}) catch return null;
        appendSshOption(&argv_buf, &argc, opt);
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    argv_buf[argc] = dest;
    argc += 1;

    // Keep this helper independent. Windows OpenSSH ControlMaster options are
    // intentionally not used here; they break on Windows socket semantics.
    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    if (env_map) |*map| child.env_map = map;
    child.spawn() catch |err| {
        std.debug.print("SSH browser tunnel spawn failed: {}\n", .{err});
        return null;
    };
    return child;
}

fn firstEmptySlot() ?usize {
    for (&g_tunnels, 0..) |*slot, i| {
        if (slot.* == null) return i;
    }
    return null;
}

fn pruneExitedTunnels() void {
    for (&g_tunnels) |*slot| {
        const tunnel = if (slot.*) |*tunnel| tunnel else continue;
        if (childHasExited(&tunnel.child)) {
            stopTunnelSlot(slot);
        }
    }
}

fn stopTunnelSlot(slot: *?SshTunnel) void {
    if (slot.*) |*tunnel| {
        if (childHasExited(&tunnel.child)) {
            // On POSIX childHasExited() already reaped the zombie via
            // waitpid(WNOHANG). Pre-set Child.term so child.wait() takes std's
            // cleanup-only fast path instead of a second waitpid — that would
            // hit ECHILD, which std.posix.waitpid treats as `unreachable`
            // (abort, not catchable). On Windows the handle is not consumed,
            // so leave term unset and let wait() close it.
            if (builtin.os.tag != .windows) tunnel.child.term = .{ .Unknown = 0 };
            _ = tunnel.child.wait() catch {};
        } else {
            _ = tunnel.child.kill() catch {};
        }
        slot.* = null;
    }
}

fn waitForTunnelReady(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16, child: *const std.process.Child) bool {
    const perf = ui_perf.begin("ssh_tunnel.wait_for_tunnel_ready");
    defer perf.end();

    const deadline = std.time.milliTimestamp() + TUNNEL_READY_TIMEOUT_MS;
    while (std.time.milliTimestamp() < deadline) {
        if (canConnectToLocalPort(allocator, local_host, local_port)) return true;
        if (childHasExited(child)) return false;
        std.Thread.sleep(TUNNEL_READY_POLL_NS);
    }
    return false;
}

fn canConnectToLocalPort(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    if (std.mem.eql(u8, local_host, "127.0.0.1") or std.mem.eql(u8, local_host, "localhost")) {
        const address = std.net.Address.parseIp4("127.0.0.1", local_port) catch return false;
        var stream = std.net.tcpConnectToAddress(address) catch {
            if (!std.mem.eql(u8, local_host, "localhost")) return false;
            return canConnectToLocalHostName(allocator, local_host, local_port);
        };
        stream.close();
        return true;
    }
    return canConnectToLocalHostName(allocator, local_host, local_port);
}

fn canConnectToLocalHostName(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    var stream = std.net.tcpConnectToHost(allocator, local_host, local_port) catch return false;
    stream.close();
    return true;
}

fn childHasExited(child: *const std.process.Child) bool {
    return switch (platform_process.childExited(child.id, 0)) {
        .running => false,
        .exited, .gone => true,
    };
}

fn reservePreferredLocalPort(preferred_port: u16) ?u16 {
    var port: u32 = if (preferred_port == 0) 1 else preferred_port;
    while (port <= std.math.maxInt(u16)) : (port += 1) {
        const candidate: u16 = @intCast(port);
        if (isLocalPortAvailable(candidate)) return candidate;
    }
    return null;
}

fn isLocalPortAvailable(port: u16) bool {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return false;
    var server = address.listen(.{}) catch return false;
    server.deinit();
    return true;
}

fn reserveLocalPort() ?u16 {
    const address = std.net.Address.parseIp4("127.0.0.1", 0) catch return null;
    var server = address.listen(.{}) catch return null;
    const port = server.listen_address.getPort();
    server.deinit();
    return if (port == 0) null else port;
}

fn sshDestination(buf: *[MAX_SSH_DEST_BYTES]u8, conn: *const ssh_connection.SshConnection) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const len = user.len + 1 + host.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..user.len], user);
    buf[user.len] = '@';
    @memcpy(buf[user.len + 1 ..][0..host.len], host);
    return buf[0..len];
}

fn appendSshOption(argv_buf: *[48][]const u8, argc: *usize, option: []const u8) void {
    argv_buf[argc.*] = "-o";
    argc.* += 1;
    argv_buf[argc.*] = option;
    argc.* += 1;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

test "ssh_tunnel external URL helper preserves public URLs" {
    const target = externalUrlForSurface(std.testing.allocator, "https://example.com/app?q=1", null) orelse unreachable;
    defer std.testing.allocator.free(target);

    try std.testing.expectEqualStrings("https://example.com/app?q=1", target);
}

test "ssh_tunnel external URL helper maps unspecified hosts to loopback" {
    const target = externalUrlForSurface(std.testing.allocator, "http://0.0.0.0:1234/app?q=1", null) orelse unreachable;
    defer std.testing.allocator.free(target);

    try std.testing.expectEqualStrings("http://127.0.0.1:1234/app?q=1", target);
}

test "reservePreferredLocalPort returns the preferred port when it is free" {
    const preferred = reserveLocalPort() orelse return error.SkipZigTest;
    const selected = reservePreferredLocalPort(preferred) orelse return error.SkipZigTest;
    try std.testing.expectEqual(preferred, selected);
}

test "reservePreferredLocalPort skips an occupied preferred port" {
    const preferred = reserveLocalPort() orelse return error.SkipZigTest;
    if (preferred == std.math.maxInt(u16)) return error.SkipZigTest;

    const address = std.net.Address.parseIp4("127.0.0.1", preferred) catch return error.SkipZigTest;
    var server = address.listen(.{}) catch return error.SkipZigTest;
    defer server.deinit();

    const selected = reservePreferredLocalPort(preferred) orelse return error.SkipZigTest;
    try std.testing.expect(selected > preferred);
}
