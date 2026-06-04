const std = @import("std");

/// Owned list of detected Jupyter URLs, most-recent first, deduped by token.
pub const Result = struct {
    urls: [][]u8,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        for (self.urls) |u| allocator.free(u);
        allocator.free(self.urls);
    }
};

const Match = struct { pos: usize, url: []const u8, host_localhost: bool, token: []const u8 };

fn isUrlByte(c: u8) bool {
    return switch (c) {
        0...0x1f, ' ', '"', '\'', '<', '>', '`', '(', ')', '[', ']', '{', '}' => false,
        else => true,
    };
}

fn matchAt(text: []const u8, i: usize) ?Match {
    const schemes = [_][]const u8{ "http://", "https://" };
    var scheme_len: usize = 0;
    for (schemes) |s| {
        if (std.mem.startsWith(u8, text[i..], s)) {
            scheme_len = s.len;
            break;
        }
    }
    if (scheme_len == 0) return null;

    var end = i + scheme_len;
    while (end < text.len and isUrlByte(text[end])) end += 1;
    while (end > i + scheme_len and (text[end - 1] == '.' or text[end - 1] == ',' or text[end - 1] == ';')) end -= 1;
    const url = text[i..end];

    const after_scheme = url[scheme_len..];
    const host_end = std.mem.indexOfAny(u8, after_scheme, ":/") orelse return null;
    const host = after_scheme[0..host_end];
    const is_localhost = std.mem.eql(u8, host, "localhost");
    const is_loopback_ip = std.mem.eql(u8, host, "127.0.0.1");
    if (!is_localhost and !is_loopback_ip) return null;

    if (host_end >= after_scheme.len or after_scheme[host_end] != ':') return null;
    if (host_end + 1 >= after_scheme.len or !std.ascii.isDigit(after_scheme[host_end + 1])) return null;

    const tk = std.mem.indexOf(u8, url, "token=") orelse return null;
    const tok_start = tk + "token=".len;
    var tok_end = tok_start;
    while (tok_end < url.len and url[tok_end] != '&') tok_end += 1;
    if (tok_end == tok_start) return null;

    return .{ .pos = i, .url = url, .host_localhost = is_localhost, .token = url[tok_start..tok_end] };
}

pub fn findJupyterUrls(allocator: std.mem.Allocator, text: []const u8) !Result {
    var matches: std.ArrayListUnmanaged(Match) = .empty;
    defer matches.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (matchAt(text, i)) |m| {
            try matches.append(allocator, m);
            i = m.pos + m.url.len;
        }
    }

    const Group = struct { token: []const u8, max_pos: usize, url: []const u8, is_localhost: bool };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer groups.deinit(allocator);
    for (matches.items) |m| {
        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.token, m.token)) {
                found = true;
                if (m.pos > g.max_pos) g.max_pos = m.pos;
                if (m.host_localhost and !g.is_localhost) {
                    g.url = m.url;
                    g.is_localhost = true;
                }
                break;
            }
        }
        if (!found) try groups.append(allocator, .{ .token = m.token, .max_pos = m.pos, .url = m.url, .is_localhost = m.host_localhost });
    }

    std.mem.sort(Group, groups.items, {}, struct {
        fn lessThan(_: void, a: Group, b: Group) bool {
            return a.max_pos > b.max_pos;
        }
    }.lessThan);

    var urls = try allocator.alloc([]u8, groups.items.len);
    errdefer allocator.free(urls);
    var n: usize = 0;
    errdefer for (urls[0..n]) |u| allocator.free(u);
    for (groups.items) |g| {
        urls[n] = try allocator.dupe(u8, g.url);
        n += 1;
    }
    return .{ .urls = urls };
}

test "single localhost url with token is detected" {
    const t = "Jupyter Server is running at:\n  http://localhost:8889/lab?token=abc123\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:8889/lab?token=abc123", r.urls[0]);
}

test "localhost and 127.0.0.1 with same token dedupe to one (prefer localhost)" {
    const t =
        "  http://localhost:8889/lab?token=deadbeef\n" ++
        "  http://127.0.0.1:8889/lab?token=deadbeef\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:8889/lab?token=deadbeef", r.urls[0]);
}

test "two different servers (different tokens) both detected, most-recent first" {
    const t =
        "  http://localhost:8888/lab?token=aaa\n" ++
        "  http://localhost:9999/lab?token=bbb\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), r.urls.len);
    try std.testing.expectEqualStrings("http://localhost:9999/lab?token=bbb", r.urls[0]);
    try std.testing.expectEqualStrings("http://localhost:8888/lab?token=aaa", r.urls[1]);
}

test "no token, non-loopback, or no port are ignored" {
    const t =
        "http://localhost:8888/lab\n" ++
        "http://example.com:8888/lab?token=x\n" ++
        "http://localhost/lab?token=y\n";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), r.urls.len);
}

test "https and trailing punctuation/whitespace handled" {
    const t = "see (https://127.0.0.1:8890/tree?token=zz9 ) now";
    const r = try findJupyterUrls(std.testing.allocator, t);
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), r.urls.len);
    try std.testing.expectEqualStrings("https://127.0.0.1:8890/tree?token=zz9", r.urls[0]);
}
