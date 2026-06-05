const std = @import("std");

pub const FIELD_MAX: usize = 128;
pub const MAX_ALIASES_PER_HOST: usize = 16;

pub const Candidate = struct {
    name_buf: [FIELD_MAX]u8 = undefined,
    name_len: usize = 0,
    host_buf: [FIELD_MAX]u8 = undefined,
    host_len: usize = 0,
    user_buf: [FIELD_MAX]u8 = undefined,
    user_len: usize = 0,
    port_buf: [FIELD_MAX]u8 = undefined,
    port_len: usize = 0,
    proxy_jump_buf: [FIELD_MAX]u8 = undefined,
    proxy_jump_len: usize = 0,

    pub fn name(self: *const Candidate) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn host(self: *const Candidate) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn user(self: *const Candidate) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn port(self: *const Candidate) []const u8 {
        return self.port_buf[0..self.port_len];
    }

    pub fn proxyJump(self: *const Candidate) []const u8 {
        return self.proxy_jump_buf[0..self.proxy_jump_len];
    }
};

const PendingBlock = struct {
    aliases: [MAX_ALIASES_PER_HOST][]const u8 = undefined,
    alias_count: usize = 0,
    host: []const u8 = "",
    user: []const u8 = "",
    port: []const u8 = "",
    proxy_jump: []const u8 = "",

    fn addAlias(self: *PendingBlock, alias: []const u8) void {
        if (self.alias_count >= MAX_ALIASES_PER_HOST) return;
        if (!compatibleAlias(alias)) return;
        self.aliases[self.alias_count] = alias;
        self.alias_count += 1;
    }
};

pub fn parseCandidates(config: []const u8, out: []Candidate) []Candidate {
    var pending: PendingBlock = .{};
    var have_block = false;
    var count: usize = 0;

    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(stripComment(raw_line));
        if (line.len == 0) continue;

        const key_value = splitKeyValue(line);
        if (std.ascii.eqlIgnoreCase(key_value.key, "Host")) {
            if (have_block) flushPending(&pending, out, &count);
            pending = .{};
            have_block = true;

            var aliases = std.mem.tokenizeAny(u8, key_value.value, " \t");
            while (aliases.next()) |alias| pending.addAlias(alias);
            continue;
        }
        if (std.ascii.eqlIgnoreCase(key_value.key, "Match")) {
            if (have_block) flushPending(&pending, out, &count);
            pending = .{};
            have_block = false;
            continue;
        }

        if (!have_block) continue;

        if (std.ascii.eqlIgnoreCase(key_value.key, "HostName")) {
            pending.host = key_value.value;
        } else if (std.ascii.eqlIgnoreCase(key_value.key, "User")) {
            pending.user = key_value.value;
        } else if (std.ascii.eqlIgnoreCase(key_value.key, "Port")) {
            pending.port = key_value.value;
        } else if (std.ascii.eqlIgnoreCase(key_value.key, "ProxyJump")) {
            pending.proxy_jump = key_value.value;
        }
    }

    if (have_block) flushPending(&pending, out, &count);
    return out[0..count];
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn stripComment(line: []const u8) []const u8 {
    const comment_idx = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..comment_idx];
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

fn splitKeyValue(line: []const u8) KeyValue {
    const sep_idx = firstSeparator(line) orelse return .{ .key = line, .value = "" };
    const key = trimLine(line[0..sep_idx]);
    const value_start = if (line[sep_idx] == '=') sep_idx + 1 else skipWhitespace(line, sep_idx);
    return .{
        .key = key,
        .value = trimLine(line[value_start..]),
    };
}

fn firstSeparator(line: []const u8) ?usize {
    for (line, 0..) |ch, idx| {
        if (ch == ' ' or ch == '\t' or ch == '=') return idx;
    }
    return null;
}

fn skipWhitespace(line: []const u8, start: usize) usize {
    var idx = start;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}
    return idx;
}

fn compatibleAlias(alias: []const u8) bool {
    if (alias.len == 0 or alias.len > FIELD_MAX) return false;
    for (alias) |ch| {
        if (ch == '*' or ch == '?' or ch == '[' or ch == ']') return false;
    }
    return true;
}

fn flushPending(block: *const PendingBlock, out: []Candidate, count: *usize) void {
    if (block.alias_count == 0 or block.user.len == 0) return;

    for (block.aliases[0..block.alias_count]) |alias| {
        if (count.* >= out.len) return;

        const host = if (block.host.len > 0) block.host else alias;
        const port = if (block.port.len > 0) block.port else "22";
        if (!candidateFieldsFit(alias, host, block.user, port, block.proxy_jump)) continue;

        var candidate: Candidate = .{};
        candidate.name_len = copyExact(candidate.name_buf[0..], alias).?;
        candidate.host_len = copyExact(candidate.host_buf[0..], host).?;
        candidate.user_len = copyExact(candidate.user_buf[0..], block.user).?;
        candidate.port_len = copyExact(candidate.port_buf[0..], port).?;
        candidate.proxy_jump_len = copyExact(candidate.proxy_jump_buf[0..], block.proxy_jump).?;

        out[count.*] = candidate;
        count.* += 1;
    }
}

fn candidateFieldsFit(name: []const u8, host: []const u8, user: []const u8, port: []const u8, proxy_jump: []const u8) bool {
    return name.len <= FIELD_MAX and
        host.len <= FIELD_MAX and
        user.len <= FIELD_MAX and
        port.len <= FIELD_MAX and
        proxy_jump.len <= FIELD_MAX;
}

fn copyExact(buf: []u8, value: []const u8) ?usize {
    if (value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return value.len;
}

test "openssh config import: parses a basic host block" {
    const config =
        \\Host lab
        \\  HostName 192.0.2.10
        \\  User alice
        \\  Port 2222
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("lab", rows[0].name());
    try std.testing.expectEqualStrings("192.0.2.10", rows[0].host());
    try std.testing.expectEqualStrings("alice", rows[0].user());
    try std.testing.expectEqualStrings("2222", rows[0].port());
}

test "openssh config import: defaults host from alias and port to 22" {
    const config =
        \\Host staging
        \\  User deploy
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("staging", rows[0].host());
    try std.testing.expectEqualStrings("22", rows[0].port());
}

test "openssh config import: parses proxy jump" {
    const config =
        \\Host prod
        \\  HostName prod.internal
        \\  User root
        \\  ProxyJump jumpuser@bastion:22
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("jumpuser@bastion:22", rows[0].proxyJump());
}

test "openssh config import: splits aliases and skips wildcard aliases" {
    const config =
        \\Host gpu gpu-lab gpu-* ?bad [group] *
        \\  HostName gpu.example
        \\  User xzg
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("gpu", rows[0].name());
    try std.testing.expectEqualStrings("gpu.example", rows[0].host());
    try std.testing.expectEqualStrings("xzg", rows[0].user());
    try std.testing.expectEqualStrings("gpu-lab", rows[1].name());
    try std.testing.expectEqualStrings("gpu.example", rows[1].host());
    try std.testing.expectEqualStrings("xzg", rows[1].user());
}

test "openssh config import: ignores comments blank lines and unsupported blocks" {
    const config =
        \\# comment
        \\
        \\Host nouser
        \\  HostName 192.0.2.11
        \\
        \\Host ok # inline comment
        \\  HostName ok.example
        \\  User bob
        \\  IdentityFile ~/.ssh/id_ed25519
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("ok", rows[0].name());
    try std.testing.expectEqualStrings("ok.example", rows[0].host());
}

test "openssh config import: ignores match blocks" {
    const config =
        \\Host ok
        \\  HostName ok.example
        \\  User bob
        \\Match host *
        \\  HostName ignored.example
        \\  User root
        \\Host next
        \\  HostName next.example
        \\  User alice
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("ok", rows[0].name());
    try std.testing.expectEqualStrings("ok.example", rows[0].host());
    try std.testing.expectEqualStrings("bob", rows[0].user());
    try std.testing.expectEqualStrings("next", rows[1].name());
    try std.testing.expectEqualStrings("next.example", rows[1].host());
    try std.testing.expectEqualStrings("alice", rows[1].user());
}
