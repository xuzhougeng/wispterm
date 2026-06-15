const std = @import("std");
const ssh_connection = @import("ssh_connection.zig");
const profile_codec = @import("renderer/overlays/profile_codec.zig");
const platform_dirs = @import("platform/dirs.zig");
const command_palette_model = @import("command_palette_model.zig");

pub fn connectionByName(allocator: std.mem.Allocator, profile_name: []const u8, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    const path = platform_dirs.sshHostsPath(allocator) catch return null;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);
    return findConnectionInContent(content, profile_name, legacy_algorithms);
}

pub fn findConnectionInContent(content: []const u8, profile_name: []const u8, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = profile_codec.decodeSshProfileLine(line) orelse continue;
        if (!std.ascii.eqlIgnoreCase(profile_name, profile_codec.profileField(&profile, .name))) continue;
        return connectionFromProfile(&profile, legacy_algorithms);
    }
    return null;
}

pub fn connectionFromProfile(profile: *const profile_codec.SshProfile, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    const host = profile_codec.profileField(profile, .ip);
    const user = profile_codec.profileField(profile, .user);
    const port = profile_codec.profileField(profile, .port);
    const password = profile_codec.profileField(profile, .password);
    const proxy_jump = profile_codec.profileField(profile, .proxy_jump);
    const auth_method = ssh_connection.SshAuthMethod.parse(profile_codec.profileField(profile, .auth_method)) orelse return null;
    const identity_file = profile_codec.profileField(profile, .identity_file);
    if (host.len == 0 or user.len == 0) return null;
    if (!isSshTokenSafe(host) or !isSshTokenSafe(user)) return null;
    if (port.len > 0 and !isPortTokenSafe(port)) return null;
    if (!command_palette_model.isProxyJumpSafe(proxy_jump)) return null;
    if (auth_method == .password and password.len == 0) return null;
    if (auth_method == .key and !isIdentityFileSafe(identity_file)) return null;

    var conn: ssh_connection.SshConnection = .{};
    conn.host_len = copyBounded(conn.host_buf[0..], host);
    conn.user_len = copyBounded(conn.user_buf[0..], user);
    conn.port_len = copyBounded(conn.port_buf[0..], port);
    conn.password_len = copyBounded(conn.password_buf[0..], password);
    conn.proxy_jump_len = copyBounded(conn.proxy_jump_buf[0..], proxy_jump);
    conn.identity_file_len = copyBounded(conn.identity_file_buf[0..], identity_file);
    conn.auth_method = auth_method;
    conn.password_auth = conn.usesPasswordAuth();
    conn.legacy_algorithms = legacy_algorithms;
    return conn;
}

/// Cycle to the name of the SSH profile `delta` steps from `current` (matched
/// case-insensitively by name) in the order they appear in `content`, wrapping
/// around. The result is copied into `out` and the written slice is returned.
///
/// Returns "" when `content` holds no decodable profiles. When `current` is not
/// found, a positive/zero delta starts at the first profile and a negative delta
/// at the last, so the very first keypress always lands on a real profile.
pub fn cycleProfileName(content: []const u8, current: []const u8, delta: isize, out: []u8) []const u8 {
    var total: usize = 0;
    var found: ?usize = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = profile_codec.decodeSshProfileLine(line) orelse continue;
        if (found == null and std.ascii.eqlIgnoreCase(current, profile_codec.profileField(&profile, .name))) {
            found = total;
        }
        total += 1;
    }
    if (total == 0) return out[0..0];

    const target: usize = if (found) |base| blk: {
        const span: isize = @intCast(total);
        break :blk @intCast(@mod(@as(isize, @intCast(base)) + delta, span));
    } else if (delta < 0) total - 1 else 0;

    var index: usize = 0;
    var walk = std.mem.splitScalar(u8, content, '\n');
    while (walk.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = profile_codec.decodeSshProfileLine(line) orelse continue;
        if (index == target) {
            const name = profile_codec.profileField(&profile, .name);
            const n = copyBounded(out, name);
            return out[0..n];
        }
        index += 1;
    }
    return out[0..0];
}

fn isSshTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        switch (ch) {
            '.', '-', '_', ':', '@' => {},
            else => return false,
        }
    }
    return true;
}

fn isPortTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isIdentityFileSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn appendEncodedProfileForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    for (fields, 0..) |field, idx| {
        if (idx > 0) try out.append(allocator, '\t');
        try appendHexFieldForTest(allocator, out, field);
    }
    try out.append(allocator, '\n');
}

fn appendHexFieldForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (field) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

test "ssh_profile_store: resolves connection from encoded ssh_hosts content" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "devbox", "10.0.0.9", "alice", "secret", "2222", "jump@example.com:22",
    });

    const conn = findConnectionInContent(content.items, "devbox", true) orelse return error.ExpectedConnection;
    try std.testing.expectEqualStrings("alice", conn.user());
    try std.testing.expectEqualStrings("10.0.0.9", conn.host());
    try std.testing.expectEqualStrings("2222", conn.port());
    try std.testing.expectEqualStrings("secret", conn.password());
    try std.testing.expectEqualStrings("jump@example.com:22", conn.proxyJump());
    try std.testing.expectEqual(ssh_connection.SshAuthMethod.password, conn.auth_method);
    try std.testing.expect(conn.password_auth);
    try std.testing.expect(conn.legacy_algorithms);
}

test "ssh_profile_store: resolves key-auth connection from encoded ssh_hosts content" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "keybox", "key.example", "alice", "", "22", "", "key", "C:/Users/alice/.ssh/id_ed25519",
    });

    const conn = findConnectionInContent(content.items, "keybox", false) orelse return error.ExpectedConnection;
    try std.testing.expectEqual(ssh_connection.SshAuthMethod.key, conn.auth_method);
    try std.testing.expectEqualStrings("C:/Users/alice/.ssh/id_ed25519", conn.identityFile());
    try std.testing.expect(!conn.password_auth);
}

test "ssh_profile_store: rejects unsafe profile fields" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "bad", "host;rm -rf /", "alice", "", "22", "",
    });

    try std.testing.expect(findConnectionInContent(content.items, "bad", false) == null);
}

test "ssh_profile_store: cycleProfileName steps through profiles and wraps" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{ "devbox", "10.0.0.1", "a", "", "22", "" });
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{ "lab", "10.0.0.2", "a", "", "22", "" });
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{ "prod", "10.0.0.3", "a", "", "22", "" });

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("lab", cycleProfileName(content.items, "devbox", 1, &buf));
    try std.testing.expectEqualStrings("prod", cycleProfileName(content.items, "devbox", -1, &buf));
    try std.testing.expectEqualStrings("devbox", cycleProfileName(content.items, "prod", 1, &buf));
    // Case-insensitive match on the current name.
    try std.testing.expectEqualStrings("prod", cycleProfileName(content.items, "LAB", 1, &buf));
}

test "ssh_profile_store: cycleProfileName falls back when current is unknown" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{ "devbox", "10.0.0.1", "a", "", "22", "" });
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{ "prod", "10.0.0.3", "a", "", "22", "" });

    var buf: [128]u8 = undefined;
    // Empty/unknown current: forward picks the first, backward picks the last.
    try std.testing.expectEqualStrings("devbox", cycleProfileName(content.items, "", 1, &buf));
    try std.testing.expectEqualStrings("devbox", cycleProfileName(content.items, "", 0, &buf));
    try std.testing.expectEqualStrings("prod", cycleProfileName(content.items, "missing", -1, &buf));
}

test "ssh_profile_store: cycleProfileName returns empty without profiles" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("", cycleProfileName("# only comments\n", "devbox", 1, &buf));
    try std.testing.expectEqualStrings("", cycleProfileName("", "", -1, &buf));
}
