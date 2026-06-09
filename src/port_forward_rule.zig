const std = @import("std");

pub const NAME_MAX: usize = 96;
pub const PROFILE_MAX: usize = 128;
pub const HOST_MAX: usize = 64;

const DIRECTION_TEXT_MAX: usize = 7;
const PORT_TEXT_MAX: usize = 5;
const BOOL_TEXT_MAX: usize = 5;

pub const Direction = enum {
    local,
    reverse,

    pub fn flag(self: Direction) []const u8 {
        return switch (self) {
            .local => "-L",
            .reverse => "-R",
        };
    }

    pub fn text(self: Direction) []const u8 {
        return switch (self) {
            .local => "local",
            .reverse => "reverse",
        };
    }

    pub fn parse(value: []const u8) ?Direction {
        if (std.ascii.eqlIgnoreCase(value, "local")) return .local;
        if (std.ascii.eqlIgnoreCase(value, "reverse")) return .reverse;
        return null;
    }
};

pub const Rule = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    profile_buf: [PROFILE_MAX]u8 = undefined,
    profile_len: usize = 0,
    direction: Direction = .reverse,
    local_host_buf: [HOST_MAX]u8 = undefined,
    local_host_len: usize = 0,
    local_port: u16 = 7890,
    remote_host_buf: [HOST_MAX]u8 = undefined,
    remote_host_len: usize = 0,
    remote_port: u16 = 7890,
    enabled: bool = true,
    auto_start: bool = true,

    pub fn name(self: *const Rule) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn profileName(self: *const Rule) []const u8 {
        return self.profile_buf[0..self.profile_len];
    }

    pub fn localHost(self: *const Rule) []const u8 {
        return self.local_host_buf[0..self.local_host_len];
    }

    pub fn remoteHost(self: *const Rule) []const u8 {
        return self.remote_host_buf[0..self.remote_host_len];
    }

    pub fn setName(self: *Rule, value: []const u8) void {
        self.name_len = copyBounded(self.name_buf[0..], value);
    }

    pub fn setProfileName(self: *Rule, value: []const u8) void {
        self.profile_len = copyBounded(self.profile_buf[0..], value);
    }

    pub fn setLocalHost(self: *Rule, value: []const u8) void {
        self.local_host_len = copyBounded(self.local_host_buf[0..], value);
    }

    pub fn setRemoteHost(self: *Rule, value: []const u8) void {
        self.remote_host_len = copyBounded(self.remote_host_buf[0..], value);
    }

    pub fn validate(self: *const Rule) bool {
        return self.profileName().len > 0 and
            validateHost(self.localHost()) and
            validateHost(self.remoteHost()) and
            self.local_port != 0 and
            self.remote_port != 0;
    }

    pub fn forwardSpec(self: *const Rule, buf: []u8) ?[]const u8 {
        if (!self.validate()) return null;
        return switch (self.direction) {
            .local => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.localHost(), self.local_port, self.remoteHost(), self.remote_port },
            ) catch null,
            .reverse => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.remoteHost(), self.remote_port, self.localHost(), self.local_port },
            ) catch null,
        };
    }
};

pub fn defaultReverseProxy(profile_name: []const u8) Rule {
    var rule: Rule = .{};
    rule.setName("Local proxy");
    rule.setProfileName(profile_name);
    rule.direction = .reverse;
    rule.setLocalHost("127.0.0.1");
    rule.local_port = 7890;
    rule.setRemoteHost("127.0.0.1");
    rule.remote_port = 7890;
    rule.enabled = true;
    rule.auto_start = true;
    return rule;
}

pub fn validateHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

pub fn parsePort(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (value == 0 or value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

pub fn freeRules(allocator: std.mem.Allocator, rules: []Rule) void {
    allocator.free(rules);
}

pub fn encodeRules(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rules: []const Rule) !void {
    try out.appendSlice(allocator, "# WispTerm port forwarding rules. Fields are hex encoded: name, profile, direction, local_host, local_port, remote_host, remote_port, enabled, auto_start.\n");
    for (rules) |rule| {
        try appendHexField(allocator, out, rule.name());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.profileName());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.direction.text());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.localHost());
        try out.append(allocator, '\t');
        var local_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&local_port_buf, "{d}", .{rule.local_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.remoteHost());
        try out.append(allocator, '\t');
        var remote_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&remote_port_buf, "{d}", .{rule.remote_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.enabled) "true" else "false");
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.auto_start) "true" else "false");
        try out.append(allocator, '\n');
    }
}

pub fn decodeRules(allocator: std.mem.Allocator, content: []const u8) ![]Rule {
    var rules: std.ArrayListUnmanaged(Rule) = .empty;
    errdefer rules.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (decodeRuleLine(line)) |rule| {
            try rules.append(allocator, rule);
        }
    }
    return rules.toOwnedSlice(allocator);
}

pub fn decodeRuleLine(line: []const u8) ?Rule {
    var parts = std.mem.splitScalar(u8, line, '\t');

    var name_buf: [NAME_MAX]u8 = undefined;
    const name_len = decodeHexField(parts.next() orelse return null, name_buf[0..]) orelse return null;
    var profile_buf: [PROFILE_MAX]u8 = undefined;
    const profile_len = decodeHexField(parts.next() orelse return null, profile_buf[0..]) orelse return null;
    var direction_buf: [DIRECTION_TEXT_MAX]u8 = undefined;
    const direction_len = decodeHexField(parts.next() orelse return null, direction_buf[0..]) orelse return null;
    var local_host_buf: [HOST_MAX]u8 = undefined;
    const local_host_len = decodeHexField(parts.next() orelse return null, local_host_buf[0..]) orelse return null;
    var local_port_buf: [PORT_TEXT_MAX]u8 = undefined;
    const local_port_len = decodeHexField(parts.next() orelse return null, local_port_buf[0..]) orelse return null;
    var remote_host_buf: [HOST_MAX]u8 = undefined;
    const remote_host_len = decodeHexField(parts.next() orelse return null, remote_host_buf[0..]) orelse return null;
    var remote_port_buf: [PORT_TEXT_MAX]u8 = undefined;
    const remote_port_len = decodeHexField(parts.next() orelse return null, remote_port_buf[0..]) orelse return null;
    var enabled_buf: [BOOL_TEXT_MAX]u8 = undefined;
    const enabled_len = decodeHexField(parts.next() orelse return null, enabled_buf[0..]) orelse return null;
    var auto_start_buf: [BOOL_TEXT_MAX]u8 = undefined;
    const auto_start_len = decodeHexField(parts.next() orelse return null, auto_start_buf[0..]) orelse return null;
    if (parts.next() != null) return null;

    var rule: Rule = .{};
    rule.setName(name_buf[0..name_len]);
    rule.setProfileName(profile_buf[0..profile_len]);
    rule.direction = Direction.parse(direction_buf[0..direction_len]) orelse return null;
    rule.setLocalHost(local_host_buf[0..local_host_len]);
    rule.local_port = parsePort(local_port_buf[0..local_port_len]) orelse return null;
    rule.setRemoteHost(remote_host_buf[0..remote_host_len]);
    rule.remote_port = parsePort(remote_port_buf[0..remote_port_len]) orelse return null;
    rule.enabled = parseBool(enabled_buf[0..enabled_len]) orelse return null;
    rule.auto_start = parseBool(auto_start_buf[0..auto_start_len]) orelse return null;
    if (!rule.validate()) return null;
    return rule;
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (field) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

fn decodeHexField(value: []const u8, out: []u8) ?usize {
    if (value.len % 2 != 0) return null;
    const len = value.len / 2;
    if (len > out.len) return null;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const hi = hexValue(value[i * 2]) orelse return null;
        const lo = hexValue(value[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

fn hexValue(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

test "port_forward_rule: default reverse rule targets local proxy" {
    const rule = defaultReverseProxy("devbox");
    try std.testing.expectEqual(Direction.reverse, rule.direction);
    try std.testing.expectEqualStrings("devbox", rule.profileName());
    try std.testing.expectEqualStrings("127.0.0.1", rule.localHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.local_port);
    try std.testing.expectEqualStrings("127.0.0.1", rule.remoteHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.remote_port);
    try std.testing.expect(rule.enabled);
    try std.testing.expect(rule.auto_start);
}

test "port_forward_rule: validates loopback hosts and port range" {
    try std.testing.expect(validateHost("127.0.0.1"));
    try std.testing.expect(validateHost("localhost"));
    try std.testing.expect(!validateHost("0.0.0.0"));
    try std.testing.expect(!validateHost("10.0.0.1"));
    try std.testing.expect(parsePort("1").? == 1);
    try std.testing.expect(parsePort("65535").? == 65535);
    try std.testing.expect(parsePort("0") == null);
    try std.testing.expect(parsePort("65536") == null);
    try std.testing.expect(parsePort("abc") == null);
}

test "port_forward_rule: forward specs match ssh -L and -R semantics" {
    var rule = defaultReverseProxy("devbox");
    rule.setRemoteHost("localhost");
    rule.remote_port = 1111;
    rule.setLocalHost("127.0.0.1");
    rule.local_port = 2222;

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "localhost:1111:127.0.0.1:2222",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-R", rule.direction.flag());

    rule.direction = .local;
    rule.setLocalHost("localhost");
    rule.local_port = 1111;
    rule.setRemoteHost("127.0.0.1");
    rule.remote_port = 2222;
    try std.testing.expectEqualStrings(
        "localhost:1111:127.0.0.1:2222",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-L", rule.direction.flag());
}

test "port_forward_rule: storage round trips two rules" {
    var rules = [_]Rule{
        defaultReverseProxy("devbox"),
        defaultReverseProxy("lab"),
    };
    rules[1].direction = .local;
    rules[1].local_port = 8888;
    rules[1].remote_port = 8888;
    rules[1].auto_start = false;
    rules[1].setName("Jupyter");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try encodeRules(std.testing.allocator, &out, rules[0..]);

    var decoded = try decodeRules(std.testing.allocator, out.items);
    defer freeRules(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(Direction.reverse, decoded[0].direction);
    try std.testing.expectEqualStrings("devbox", decoded[0].profileName());
    try std.testing.expectEqual(Direction.local, decoded[1].direction);
    try std.testing.expectEqualStrings("Jupyter", decoded[1].name());
    try std.testing.expect(!decoded[1].auto_start);
}

test "port_forward_rule: decoder rejects extra fields" {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(std.testing.allocator);

    try appendValidEncodedRuleForTest(std.testing.allocator, &line);
    try line.append(std.testing.allocator, '\t');
    try appendHexField(std.testing.allocator, &line, "extra");
    try std.testing.expect(decodeRuleLine(line.items) == null);
}

test "port_forward_rule: decoder rejects malformed hex" {
    try std.testing.expect(decodeRuleLine("GG") == null);
}

test "port_forward_rule: decoder rejects overlong fields" {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(std.testing.allocator);

    var too_long_name: [NAME_MAX + 1]u8 = undefined;
    @memset(too_long_name[0..], 'n');
    try appendEncodedFieldsForTest(std.testing.allocator, &line, &.{
        too_long_name[0..],
        "devbox",
        "reverse",
        "127.0.0.1",
        "7890",
        "127.0.0.1",
        "7890",
        "true",
        "true",
    });
    try std.testing.expect(decodeRuleLine(line.items) == null);

    line.clearRetainingCapacity();
    var too_long_profile: [PROFILE_MAX + 1]u8 = undefined;
    @memset(too_long_profile[0..], 'p');
    try appendEncodedFieldsForTest(std.testing.allocator, &line, &.{
        "Local proxy",
        too_long_profile[0..],
        "reverse",
        "127.0.0.1",
        "7890",
        "127.0.0.1",
        "7890",
        "true",
        "true",
    });
    try std.testing.expect(decodeRuleLine(line.items) == null);
}

test "port_forward_rule: decoder rejects invalid decoded rules" {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(std.testing.allocator);

    try appendEncodedFieldsForTest(std.testing.allocator, &line, &.{
        "Local proxy",
        "devbox",
        "reverse",
        "0.0.0.0",
        "7890",
        "127.0.0.1",
        "7890",
        "true",
        "true",
    });
    try std.testing.expect(decodeRuleLine(line.items) == null);
}

test "port_forward_rule: forward specs reject invalid rules and small buffers" {
    var rule = defaultReverseProxy("devbox");
    rule.setLocalHost("0.0.0.0");
    var buf: [128]u8 = undefined;
    try std.testing.expect(rule.forwardSpec(&buf) == null);

    rule = defaultReverseProxy("devbox");
    var tiny_buf: [4]u8 = undefined;
    try std.testing.expect(rule.forwardSpec(&tiny_buf) == null);
}

fn appendValidEncodedRuleForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try appendEncodedFieldsForTest(allocator, out, &.{
        "Local proxy",
        "devbox",
        "reverse",
        "127.0.0.1",
        "7890",
        "127.0.0.1",
        "7890",
        "true",
        "true",
    });
}

fn appendEncodedFieldsForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    for (fields, 0..) |field, idx| {
        if (idx > 0) try out.append(allocator, '\t');
        try appendHexField(allocator, out, field);
    }
}
