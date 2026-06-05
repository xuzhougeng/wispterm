//! Engine-agnostic web reader core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeRead`). Backed by Jina Reader (`r.jina.ai`):
//! an http(s) URL is fetched as a page; any other target is treated as a local
//! file path and uploaded (PDF + Office, MIME-sniffed by Reader). HTTP transport
//! goes through `platform/http_client.zig` so desktop builds can use system proxies.
//! Mirrors `web_search.zig`; intentionally does NOT depend on it — the Jina key is
//! passed in via `Options.api_key` (empty = anonymous).
const std = @import("std");
const platform_http = @import("platform/http_client.zig");

const reader_url = "https://r.jina.ai/";
const upload_boundary = "----WispTermReaderBoundary7MA4YWxkTrZu0gW";
const user_truncate_cap: usize = 8000;

pub const Options = struct {
    api_key: []const u8 = "", // "" = anonymous (no Authorization header)
    max_file_bytes: usize = 25 * 1024 * 1024, // reject larger local files (OOM guard)
};

pub const ReadResult = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    url: []const u8,
    content: []const u8,
    pub fn deinit(self: *ReadResult) void {
        self.arena.deinit();
    }
};

/// True when `target` is an http(s) URL (case-insensitive scheme).
pub fn isHttpUrl(target: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(target, "http://") or
        std.ascii.startsWithIgnoreCase(target, "https://");
}

/// JSON-escape `s` into `out` (mirrors web_search.appendJsonString; duplicated to
/// keep this module independent of web_search).
fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => |ch| if (ch < 0x20)
            try out.writer(allocator).print("\\u{x:0>4}", .{ch})
        else
            try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

/// Build the Reader URL-mode request body: `{"url":<json-escaped url>}`.
pub fn buildUrlRequestBody(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"url\":");
    try appendJsonString(allocator, &out, url);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const ParsedFields = struct { title: []const u8, url: []const u8, content: []const u8 };

/// Parse a Jina Reader JSON response (`{"code":200,"data":{title,url,content,...}}`).
/// Strings are duped into `arena`. A missing/empty `content` → error.ParseFailed.
/// Duping into `arena` here means the result may safely alias `json_bytes`, which the
/// caller frees right after this returns.
pub fn parseReaderResponse(arena: std.mem.Allocator, json_bytes: []const u8) !ParsedFields {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const data_val = parsed.value.object.get("data") orelse return error.ParseFailed;
    if (data_val != .object) return error.ParseFailed;
    const obj = data_val.object;
    const content = jsonStr(obj, "content") orelse return error.ParseFailed;
    if (content.len == 0) return error.ParseFailed;
    return .{
        .title = try arena.dupe(u8, jsonStr(obj, "title") orelse ""),
        .url = try arena.dupe(u8, jsonStr(obj, "url") orelse ""),
        .content = try arena.dupe(u8, content),
    };
}

pub const MultipartBody = struct { body: []u8, content_type: []u8 };

/// Build a `multipart/form-data` body with one `file` field (raw bytes, binary-safe).
/// Caller frees `.body` and `.content_type`.
pub fn buildMultipartBody(allocator: std.mem.Allocator, filename: []const u8, bytes: []const u8) !MultipartBody {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("--{s}\r\n", .{upload_boundary});
    try w.print("Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n", .{filename});
    try w.writeAll("Content-Type: application/octet-stream\r\n\r\n");
    try w.writeAll(bytes);
    try w.print("\r\n--{s}--\r\n", .{upload_boundary});
    const body = try out.toOwnedSlice(allocator);
    errdefer allocator.free(body);
    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{upload_boundary});
    return .{ .body = body, .content_type = content_type };
}

pub const LocalFile = struct { basename: []const u8, bytes: []u8 };

/// Read a local file for upload. `basename` aliases `path` (caller keeps it alive).
/// Caller frees `.bytes`. Maps open/stat failure to error.FileNotFound and an
/// oversize file to error.FileTooLarge.
pub fn readLocalFileForUpload(gpa: std.mem.Allocator, path: []const u8, max_bytes: usize) !LocalFile {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = file.stat() catch return error.FileNotFound;
    if (stat.size > max_bytes) return error.FileTooLarge;
    const bytes = file.readToEndAlloc(gpa, max_bytes) catch |err| switch (err) {
        error.FileTooBig => return error.FileTooLarge,
        else => return error.FileNotFound,
    };
    return .{ .basename = std.fs.path.basename(path), .bytes = bytes };
}

test "isHttpUrl recognizes only http(s) schemes" {
    try std.testing.expect(isHttpUrl("http://x"));
    try std.testing.expect(isHttpUrl("HTTPS://x"));
    try std.testing.expect(!isHttpUrl("ftp://x"));
    try std.testing.expect(!isHttpUrl("/tmp/report.pdf"));
    try std.testing.expect(!isHttpUrl("report.pdf"));
}

test "buildUrlRequestBody json-escapes the url" {
    const a = std.testing.allocator;
    const body = try buildUrlRequestBody(a, "https://x/?q=\"a\"&b");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"url\":\"https://x/?q=\\\"a\\\"&b\"}", body);
}

test "parseReaderResponse extracts data object fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"code":200,"status":20000,"data":{"title":"Example","url":"https://e.example/","content":"# Example\nbody"}}
    ;
    const f = try parseReaderResponse(arena.allocator(), json);
    try std.testing.expectEqualStrings("Example", f.title);
    try std.testing.expectEqualStrings("https://e.example/", f.url);
    try std.testing.expectEqualStrings("# Example\nbody", f.content);
}

test "parseReaderResponse tolerates missing title/url, rejects empty content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ok = try parseReaderResponse(arena.allocator(), "{\"data\":{\"content\":\"hi\"}}");
    try std.testing.expectEqualStrings("", ok.title);
    try std.testing.expectEqualStrings("hi", ok.content);
    try std.testing.expectError(error.ParseFailed, parseReaderResponse(arena.allocator(), "{\"data\":{\"content\":\"\"}}"));
    try std.testing.expectError(error.ParseFailed, parseReaderResponse(arena.allocator(), "{\"data\":[]}"));
}

test "buildMultipartBody frames the file field with the boundary" {
    const a = std.testing.allocator;
    const mp = try buildMultipartBody(a, "report.pdf", "PDFBYTES");
    defer a.free(mp.body);
    defer a.free(mp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "--" ++ upload_boundary) != null);
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "name=\"file\"; filename=\"report.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "PDFBYTES") != null);
    try std.testing.expect(std.mem.endsWith(u8, mp.body, "--" ++ upload_boundary ++ "--\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, mp.content_type, upload_boundary) != null);
}

test "readLocalFileForUpload reads bytes, reports missing and oversize" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.txt", .data = "hello world" });
    const path = try tmp.dir.realpathAlloc(a, "doc.txt");
    defer a.free(path);

    const lf = try readLocalFileForUpload(a, path, 1024);
    defer a.free(lf.bytes);
    try std.testing.expectEqualStrings("doc.txt", lf.basename);
    try std.testing.expectEqualStrings("hello world", lf.bytes);

    try std.testing.expectError(error.FileTooLarge, readLocalFileForUpload(a, path, 4));
    try std.testing.expectError(error.FileNotFound, readLocalFileForUpload(a, "/no/such/file.pdf", 1024));
}
