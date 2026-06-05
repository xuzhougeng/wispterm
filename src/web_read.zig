//! Engine-agnostic web reader core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeRead`). Backed by Jina Reader (`r.jina.ai`):
//! an http(s) URL is fetched as a page; any other target is treated as a local
//! file path and uploaded (PDF + Office, MIME-sniffed by Reader). HTTP transport
//! goes through `platform/http_client.zig` so desktop builds can use system proxies.
//! Mirrors `web_search.zig`; intentionally does NOT depend on it — the Jina key is
//! passed in via `Options.api_key` (empty = anonymous).
const std = @import("std");
const platform_http = @import("platform/http_client.zig");
const web_read_cache = @import("web_read_cache.zig");

const reader_url = "https://r.jina.ai/";
const upload_boundary = "----WispTermReaderBoundary7MA4YWxkTrZu0gW";
const user_truncate_cap: usize = 8000;

pub const Options = struct {
    api_key: []const u8 = "", // "" = anonymous (no Authorization header)
    max_file_bytes: usize = 25 * 1024 * 1024, // reject larger local files (OOM guard)
    cache_dir: ?[]const u8 = null, // working dir; null = cache next to the file. Used for the
    // .webread_cache root AND to resolve a relative file target.
};

pub const ReadResult = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    url: []const u8,
    content: []const u8,
    cached: bool = false,
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
/// The filename is sanitized: `"`, CR, and LF are replaced with `_` to prevent
/// Content-Disposition header corruption or injection.
/// Caller frees `.body` and `.content_type`.
pub fn buildMultipartBody(allocator: std.mem.Allocator, filename: []const u8, bytes: []const u8) !MultipartBody {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("--{s}\r\n", .{upload_boundary});
    try w.writeAll("Content-Disposition: form-data; name=\"file\"; filename=\"");
    for (filename) |c| try w.writeByte(if (c == '"' or c == '\r' or c == '\n') '_' else c);
    try w.writeAll("\"\r\nContent-Type: application/octet-stream\r\n\r\n");
    try w.writeAll(bytes);
    try w.print("\r\n--{s}--\r\n", .{upload_boundary});
    const body = try out.toOwnedSlice(allocator);
    errdefer allocator.free(body);
    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{upload_boundary});
    return .{ .body = body, .content_type = content_type };
}

/// Resolve a relative file `target` against `cache_dir` (the working dir); an absolute
/// target is returned as-is. Caller frees. Mirrors ai_chat_tools.resolveLocalPath so
/// `webread` resolves the same way the file-edit tools do.
fn resolveFilePath(allocator: std.mem.Allocator, target: []const u8, cache_dir: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target);
    if (cache_dir) |cd| if (cd.len > 0) return std.fs.path.join(allocator, &.{ cd, target });
    return allocator.dupe(u8, target);
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

/// Largest byte index <= cap that is not inside a UTF-8 multi-byte sequence, so a
/// truncation there never splits a codepoint (important for CJK/markdown content).
fn utf8SafeCut(s: []const u8, cap: usize) usize {
    if (cap >= s.len) return s.len;
    var cut = cap;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    return cut;
}

/// Render for the transcript (user `$webread`): title + source + content,
/// truncated to `user_truncate_cap` bytes with a note when longer.
pub fn formatForUser(allocator: std.mem.Allocator, target: []const u8, result: *const ReadResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Read \"{s}\"{s}:\n", .{ target, if (result.cached) " (cached)" else "" });
    if (result.title.len > 0) try w.print("\n# {s}\n", .{result.title});
    if (result.url.len > 0) try w.print("{s}\n", .{result.url});
    try w.writeAll("\n");
    if (result.content.len > user_truncate_cap) {
        const cut = utf8SafeCut(result.content, user_truncate_cap);
        try w.writeAll(result.content[0..cut]);
        try w.print("\n\n…(truncated, {d} chars total)\n", .{result.content.len});
    } else {
        try w.writeAll(result.content);
    }
    return out.toOwnedSlice(allocator);
}

/// Render for the model (agent `webread` tool): title + source + full content.
pub fn formatForAgent(allocator: std.mem.Allocator, target: []const u8, result: *const ReadResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Content of \"{s}\":\n", .{target});
    if (result.title.len > 0) try w.print("Title: {s}\n", .{result.title});
    if (result.url.len > 0) try w.print("URL: {s}\n", .{result.url});
    try w.print("\n{s}\n", .{result.content});
    return out.toOwnedSlice(allocator);
}

// --- threadlocal error detail (mirrors web_search) -------------------------
const ErrorDetailKind = enum { none, network, http_status, parse_failed };
threadlocal var g_error_detail_kind: ErrorDetailKind = .none;
threadlocal var g_error_detail_buf: [512]u8 = undefined;
threadlocal var g_error_detail_len: usize = 0;

fn clearErrorDetail() void {
    g_error_detail_kind = .none;
    g_error_detail_len = 0;
}

fn setErrorDetail(kind: ErrorDetailKind, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&g_error_detail_buf, fmt, args) catch {
        const fallback = "Web read failed: diagnostic message was too long.";
        @memcpy(g_error_detail_buf[0..fallback.len], fallback);
        g_error_detail_len = fallback.len;
        g_error_detail_kind = kind;
        return;
    };
    g_error_detail_len = text.len;
    g_error_detail_kind = kind;
}

fn errorDetail(kind: ErrorDetailKind) ?[]const u8 {
    if (g_error_detail_kind != kind or g_error_detail_len == 0) return null;
    return g_error_detail_buf[0..g_error_detail_len];
}

fn setNetworkErrorDetail(err: anyerror) void {
    setErrorDetail(.network, "Web read request failed before response: {s} ({s})", .{ @errorName(err), reader_url });
}

/// Friendly, user/model-facing message for a read error.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "Web read failed: no such local file (pass an http(s):// URL or an existing file path).",
        error.FileTooLarge => "Web read failed: file exceeds the 25 MB upload limit.",
        error.Network => errorDetail(.network) orelse "Web read failed: could not reach the Jina reader service.",
        error.HttpStatus => errorDetail(.http_status) orelse "Web read failed: the Jina reader service returned an error.",
        error.ParseFailed => errorDetail(.parse_failed) orelse "Web read failed: could not parse the Jina response.",
        else => "Web read failed.",
    };
}

/// Owned error text for transcript/model output. Keeps unexpected error names visible.
pub fn formatErrorText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return switch (err) {
        error.FileNotFound, error.FileTooLarge, error.Network, error.HttpStatus, error.ParseFailed => allocator.dupe(u8, errorText(err)),
        else => std.fmt.allocPrint(allocator, "Web read failed: {s}.", .{@errorName(err)}),
    };
}

fn appendAuthHeader(headers: []platform_http.Header, n: *usize, bearer: ?[]const u8) void {
    if (bearer) |b| {
        headers[n.*] = .{ .name = "Authorization", .value = b };
        n.* += 1;
    }
}

fn fetchUrl(gpa: std.mem.Allocator, url: []const u8, opts: Options) !platform_http.Response {
    const body = try buildUrlRequestBody(gpa, url);
    defer gpa.free(body);
    const bearer: ?[]u8 = if (opts.api_key.len > 0) try std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key}) else null;
    defer if (bearer) |b| gpa.free(b);

    var headers: [4]platform_http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Content-Type", .value = "application/json" };
    n += 1;
    headers[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    appendAuthHeader(&headers, &n, bearer);

    return platform_http.fetch(gpa, .{
        .method = .POST,
        .url = reader_url,
        .headers = headers[0..n],
        .body = body,
        .timeout_ms = 60_000,
    }) catch |err| {
        setNetworkErrorDetail(err);
        return error.Network;
    };
}

fn uploadFile(gpa: std.mem.Allocator, lf: LocalFile, opts: Options) !platform_http.Response {
    const mp = try buildMultipartBody(gpa, lf.basename, lf.bytes);
    defer gpa.free(mp.body);
    defer gpa.free(mp.content_type);
    const bearer: ?[]u8 = if (opts.api_key.len > 0) try std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key}) else null;
    defer if (bearer) |b| gpa.free(b);

    var headers: [4]platform_http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Content-Type", .value = mp.content_type };
    n += 1;
    headers[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    appendAuthHeader(&headers, &n, bearer);

    return platform_http.fetch(gpa, .{
        .method = .POST,
        .url = reader_url,
        .headers = headers[0..n],
        .body = mp.body,
        .timeout_ms = 60_000,
    }) catch |err| {
        setNetworkErrorDetail(err);
        return error.Network;
    };
}

/// Check the HTTP status and parse the Jina JSON body into `result` (title/url/content
/// duped into result.arena). Sets the threadlocal error detail on failure.
fn parseResponseInto(result: *ReadResult, response: platform_http.Response) !void {
    if (response.status != 200) {
        const trimmed = std.mem.trim(u8, response.body, " \t\r\n");
        const excerpt = trimmed[0..@min(trimmed.len, 300)];
        if (excerpt.len > 0)
            setErrorDetail(.http_status, "Web read failed: Jina returned HTTP {d}: {s}", .{ response.status, excerpt })
        else
            setErrorDetail(.http_status, "Web read failed: Jina returned HTTP {d}.", .{response.status});
        std.log.warn("jina reader HTTP {d}: {s}", .{ response.status, trimmed });
        return error.HttpStatus;
    }
    const fields = parseReaderResponse(result.arena.allocator(), response.body) catch |err| {
        if (err == error.ParseFailed)
            setErrorDetail(.parse_failed, "Web read failed: could not parse the Jina response ({s}).", .{@errorName(err)});
        return err;
    };
    result.title = fields.title;
    result.url = fields.url;
    result.content = fields.content;
}

/// Read `target` (http(s) URL or local file path) into clean markdown. The returned
/// `ReadResult` owns its strings via its arena (free with `result.deinit()`).
pub fn executeRead(gpa: std.mem.Allocator, target: []const u8, opts: Options) !ReadResult {
    clearErrorDetail();
    var result = ReadResult{ .arena = std.heap.ArenaAllocator.init(gpa), .title = "", .url = "", .content = "" };
    errdefer result.arena.deinit();

    if (isHttpUrl(target)) {
        var response = try fetchUrl(gpa, target, opts);
        defer response.deinit(gpa);
        try parseResponseInto(&result, response);
        return result;
    }

    const resolved = try resolveFilePath(gpa, target, opts.cache_dir);
    defer gpa.free(resolved);
    const lf = try readLocalFileForUpload(gpa, resolved, opts.max_file_bytes);
    defer gpa.free(lf.bytes);

    var hash_buf: [64]u8 = undefined;
    const hash = web_read_cache.sha256Hex(lf.bytes, &hash_buf);
    const cpath: ?[]u8 = web_read_cache.cachePath(gpa, opts.cache_dir, resolved, hash) catch null;
    defer if (cpath) |p| gpa.free(p);

    if (cpath) |p| {
        if (web_read_cache.read(gpa, p)) |cached| {
            defer gpa.free(cached);
            const arena = result.arena.allocator();
            result.url = try arena.dupe(u8, resolved);
            result.content = try arena.dupe(u8, cached);
            result.cached = true;
            return result;
        }
    }

    var response = try uploadFile(gpa, lf, opts);
    defer response.deinit(gpa);
    try parseResponseInto(&result, response);
    if (cpath) |p| web_read_cache.store(gpa, p, result.content);
    return result;
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

test "buildMultipartBody sanitizes quotes and newlines in the filename" {
    const a = std.testing.allocator;
    const mp = try buildMultipartBody(a, "a\"b\r\nc.pdf", "X");
    defer a.free(mp.body);
    defer a.free(mp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "filename=\"a_b__c.pdf\"") != null);
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

fn testReadResult(big: bool) ReadResult {
    var r = ReadResult{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .title = "T",
        .url = "https://x/",
        .content = undefined,
    };
    const a = r.arena.allocator();
    r.content = if (big) (a.alloc(u8, user_truncate_cap + 50) catch unreachable) else (a.dupe(u8, "short body") catch unreachable);
    if (big) @memset(@constCast(r.content), 'a');
    return r;
}

test "formatForUser truncates past the cap and notes total length" {
    const a = std.testing.allocator;
    var big = testReadResult(true);
    defer big.deinit();
    const text = try formatForUser(a, "https://x/", &big);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "truncated, " ) != null);
    try std.testing.expect(text.len < user_truncate_cap + 300);

    var small = testReadResult(false);
    defer small.deinit();
    const text2 = try formatForUser(a, "https://x/", &small);
    defer a.free(text2);
    try std.testing.expect(std.mem.indexOf(u8, text2, "short body") != null);
    try std.testing.expect(std.mem.indexOf(u8, text2, "truncated") == null);
}

test "formatForAgent keeps full content" {
    const a = std.testing.allocator;
    var small = testReadResult(false);
    defer small.deinit();
    const text = try formatForAgent(a, "https://x/", &small);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "URL: https://x/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "short body") != null);
}

test "formatForUser truncation never splits a UTF-8 codepoint" {
    const a = std.testing.allocator;
    // Many 3-byte CJK chars so the byte cap lands mid-character.
    var r = ReadResult{ .arena = std.heap.ArenaAllocator.init(a), .title = "", .url = "", .content = undefined };
    defer r.deinit();
    const n = (user_truncate_cap / 3) + 200;
    const buf = try r.arena.allocator().alloc(u8, n * 3);
    var i: usize = 0;
    while (i < n) : (i += 1) std.mem.copyForwards(u8, buf[i * 3 ..][0..3], "\xe4\xb8\xad"); // 中
    r.content = buf;
    const text = try formatForUser(a, "x", &r);
    defer a.free(text);
    const note_at = std.mem.indexOf(u8, text, "\n\n…(truncated").?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..note_at]));
}

test "formatForUser omits empty title and url" {
    const a = std.testing.allocator;
    var r = ReadResult{ .arena = std.heap.ArenaAllocator.init(a), .title = "", .url = "", .content = "body text" };
    defer r.deinit();
    const text = try formatForUser(a, "x", &r);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "# ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "body text") != null);
}

test "executeRead reports a missing local file without touching the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.FileNotFound, executeRead(arena.allocator(), "/no/such/file.pdf", .{}));
}

test "errorText maps reader errors to friendly text" {
    clearErrorDetail();
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.FileNotFound), "local file") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.FileTooLarge), "25 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "reader") != null);
}

test "formatErrorText surfaces unexpected error names" {
    const text = try formatErrorText(std.testing.allocator, error.SomethingWeird);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "SomethingWeird") != null);
}

test "executeRead returns cached content with no network on a cache hit" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    try tmp.dir.writeFile(.{ .sub_path = "doc.pdf", .data = "PDFDATA" });
    const pdf = try std.fs.path.join(a, &.{ dir, "doc.pdf" });
    defer a.free(pdf);

    // Pre-seed the cache at the exact path executeRead will compute.
    var hb: [64]u8 = undefined;
    const hash = web_read_cache.sha256Hex("PDFDATA", &hb);
    const cpath = try web_read_cache.cachePath(a, dir, pdf, hash);
    defer a.free(cpath);
    web_read_cache.store(a, cpath, "CACHED MARKDOWN");

    var result = try executeRead(a, pdf, .{ .cache_dir = dir });
    defer result.deinit();
    try std.testing.expect(result.cached);
    try std.testing.expectEqualStrings("CACHED MARKDOWN", result.content);
    try std.testing.expectEqualStrings(pdf, result.url);
}

test "formatForUser marks cached results" {
    const a = std.testing.allocator;
    var r = ReadResult{ .arena = std.heap.ArenaAllocator.init(a), .title = "", .url = "x", .content = "body", .cached = true };
    defer r.deinit();
    const text = try formatForUser(a, "x", &r);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "(cached)") != null);
}
