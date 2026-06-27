const std = @import("std");

pub const ServerKind = enum {
    python3,
    py_launcher_python3,
    python3_via_python,
    python2,
    python2_via_python,
    node_inline,
    npx_http_server,
};

pub fn isHtmlPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return false;
    return endsWithIgnoreCase(path, ".html") or endsWithIgnoreCase(path, ".htm");
}

pub fn percentEncodeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (segment) |ch| {
        if (isUnreserved(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildHttpUrl(allocator: std.mem.Allocator, host: []const u8, port: u16, file_name: []const u8) ![]u8 {
    const encoded = try percentEncodeSegment(allocator, file_name);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "http://{s}:{d}/{s}", .{ host, port, encoded });
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isUnreserved(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

test "html_server_model: detects html path suffixes only" {
    try std.testing.expect(isHtmlPath("index.html"));
    try std.testing.expect(isHtmlPath("INDEX.HTML"));
    try std.testing.expect(isHtmlPath("report.htm"));
    try std.testing.expect(!isHtmlPath("README.md"));
    try std.testing.expect(!isHtmlPath("html"));
    try std.testing.expect(!isHtmlPath("https://example.com/index.html"));
}

test "html_server_model: percent-encodes path segment for URL" {
    const encoded = try percentEncodeSegment(std.testing.allocator, "a b#c.html");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%23c.html", encoded);
}

test "html_server_model: builds localhost URL with encoded file segment" {
    const url = try buildHttpUrl(std.testing.allocator, "127.0.0.1", 49152, "a b.html");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:49152/a%20b.html", url);
}
