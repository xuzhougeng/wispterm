//! Session-owned SOCKS5/HTTP CONNECT route. No credentials or arbitrary commands.
//! OpenSSH still owns SSH authentication and host-key verification; a bundled
//! stdio helper only establishes the underlying byte stream (as in MobaXterm's
//! per-session proxy settings, not an SSH ProxyJump).
const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum {
    none,
    socks5,
    http,

    pub fn parse(value: []const u8) ?Kind {
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "none")) return .none;
        if (std.ascii.eqlIgnoreCase(value, "socks5")) return .socks5;
        if (std.ascii.eqlIgnoreCase(value, "http") or std.ascii.eqlIgnoreCase(value, "http-connect")) return .http;
        return null;
    }

    pub fn fieldValue(self: Kind) []const u8 {
        return @tagName(self);
    }

    pub fn cycle(self: Kind, forward: bool) Kind {
        return switch (self) {
            .none => if (forward) .socks5 else .http,
            .socks5 => if (forward) .http else .none,
            .http => if (forward) .none else .socks5,
        };
    }
};

pub const Config = struct {
    kind: Kind = .none,
    host_buf: [255]u8 = undefined,
    host_len: usize = 0,
    port_buf: [5]u8 = undefined,
    port_len: usize = 0,
    // Owned bytes: argv slices remain valid when a connection is copied to a
    // worker, unlike a ProxyCommand formatted into a helper's stack frame.
    option_buf: [2048]u8 = undefined,
    option_len: usize = 0,

    pub fn host(self: *const Config) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn port(self: *const Config) []const u8 {
        return self.port_buf[0..self.port_len];
    }

    pub fn option(self: *const Config) []const u8 {
        return self.option_buf[0..self.option_len];
    }

    pub fn fromFields(kind_text: []const u8, host_text: []const u8, port_text: []const u8) ?Config {
        const kind = Kind.parse(kind_text) orelse return null;
        if (kind == .none) return .{};
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fs.selfExeDirPath(&dir_buf) catch return null;
        var helper_buf: [std.fs.max_path_bytes]u8 = undefined;
        const helper = std.fmt.bufPrint(&helper_buf, "{s}{s}wispterm-ssh-proxy{s}", .{
            dir, std.fs.path.sep_str, if (builtin.os.tag == .windows) ".exe" else "",
        }) catch return null;
        return forHelper(kind, host_text, port_text, helper);
    }

    pub fn forHelper(kind: Kind, host_text: []const u8, port_text: []const u8, helper: []const u8) ?Config {
        if (kind == .none) return .{};
        const host_value = unbracket(host_text);
        if (!isHostSafe(host_value) or !isPortSafe(port_text)) return null;
        // ProxyCommand is interpreted by a shell. Only the application-owned
        // executable path is quoted; never accept shell syntax in endpoint fields.
        if (helper.len == 0) return null;
        for (helper) |ch| {
            if (ch < 0x20 or ch == 0x7f or std.mem.indexOfScalar(u8, "\"%!^`$", ch) != null) return null;
        }
        var result: Config = .{ .kind = kind };
        @memcpy(result.host_buf[0..host_value.len], host_value);
        result.host_len = host_value.len;
        const port_number = std.fmt.parseInt(u16, port_text, 10) catch return null;
        result.port_len = (std.fmt.bufPrint(&result.port_buf, "{d}", .{port_number}) catch return null).len;
        const option_value = std.fmt.bufPrint(&result.option_buf, "ProxyCommand=\"{s}\" {s} {s} {s} %h %p", .{ helper, kind.fieldValue(), result.host(), result.port() }) catch return null;
        result.option_len = option_value.len;
        return result;
    }

    pub fn eql(self: *const Config, other: *const Config) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.host(), other.host()) and std.mem.eql(u8, self.port(), other.port());
    }

    pub fn allowsJump(self: *const Config, jump: []const u8) bool {
        return self.kind == .none or jump.len == 0;
    }
};

pub fn unbracket(value: []const u8) []const u8 {
    if (value.len > 2 and value[0] == '[' and value[value.len - 1] == ']') return value[1 .. value.len - 1];
    return value;
}

pub fn isHostSafe(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or value[0] == '-') return false;
    for (value) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_' and ch != ':') return false;
    }
    return true;
}

pub fn isPortSafe(value: []const u8) bool {
    if (value.len == 0 or value.len > 5) return false;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return false;
    return (std.fmt.parseInt(u16, value, 10) catch return false) != 0;
}

test "network proxy defaults, choice cycle, and typed validation" {
    try std.testing.expectEqual(Kind.none, Kind.parse("").?);
    try std.testing.expectEqual(Kind.socks5, Kind.none.cycle(true));
    try std.testing.expectEqual(Kind.http, Kind.none.cycle(false));
    try std.testing.expect(Kind.parse("local") == null);
    for ([_][]const u8{ "", "x y", "x;whoami", "$(id)", "%PATH%", "x\r\nHost: evil" }) |host| {
        try std.testing.expect(Config.forHelper(.socks5, host, "7897", "helper") == null);
    }
    for ([_][]const u8{ "", "0", "65536", "-1", "22 & calc", "1\n" }) |port| {
        try std.testing.expect(Config.forHelper(.http, "127.0.0.1", port, "helper") == null);
    }
}

test "network proxy owns its command and keeps helper paths with spaces quoted" {
    const c = Config.forHelper(.socks5, "[::1]", "07897", "C:/Program Files/WispTerm/wispterm-ssh-proxy.exe").?;
    try std.testing.expectEqualStrings("::1", c.host());
    try std.testing.expectEqualStrings("7897", c.port());
    try std.testing.expectEqualStrings("ProxyCommand=\"C:/Program Files/WispTerm/wispterm-ssh-proxy.exe\" socks5 ::1 7897 %h %p", c.option());
    try std.testing.expect(!c.allowsJump("bastion"));
    try std.testing.expect(c.allowsJump(""));
    const copied = c;
    try std.testing.expectEqualStrings(c.option(), copied.option());
}
