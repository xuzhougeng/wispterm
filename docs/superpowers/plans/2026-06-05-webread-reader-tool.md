# `$webread` / `webread` (Jina Reader) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "read a web page or local file into clean markdown" capability to the AI chat, exposed as a `$webread <target>` user command and a `webread` agent tool, both backed by Jina Reader (`r.jina.ai`).

**Architecture:** A new pure-ish module `src/web_read.zig` (mirroring `src/web_search.zig`) owns the request-build / response-parse / format logic plus one impure `executeRead`. `<target>` starting with `http(s)://` is read as a web page (`POST {"url":…}`); anything else is treated as a local file path and uploaded via `multipart/form-data` (PDF + Office, MIME-sniffed by Reader). Both entry points reuse the existing `jina-api-key` global (`web_search.jinaApiKeyAlloc`), passed in via `Options.api_key`; the key is **optional** (anonymous read works). No approval gate, consistent with `websearch`.

**Tech Stack:** Zig, `std.http` via `src/platform/http_client.zig`, `std.json`. Mirrors the existing `$websearch` feature end-to-end.

**Spec:** `docs/superpowers/specs/2026-06-05-webread-reader-tool-design.md`

**Branch:** `feat/webread-reader-tool` (already created; spec already committed there).

---

## File Structure

- **Create** `src/web_read.zig` — reader module: `ReadResult`, `Options`, pure helpers (`isHttpUrl`, `buildUrlRequestBody`, `buildMultipartBody`, `parseReaderResponse`, `readLocalFileForUpload`, `formatForUser`, `formatForAgent`), error plumbing, and impure `executeRead`.
- **Modify** `src/test_fast.zig` — register `web_read.zig` so its pure tests run.
- **Modify** `src/ai_chat_composer.zig` — extend `WebCommand`, `reserved_web_commands`, `parseWebCommand`.
- **Modify** `src/ai_chat.zig` — `WebReadRequest`, `startWebReadRequest`, submit-path dispatch branch.
- **Modify** `src/ai_chat_request.zig` — `webReadThreadMain` worker.
- **Modify** `src/ai_chat_protocol.zig` — `webread` tool spec emit + a tool-set test.
- **Modify** `src/ai_chat_tools.zig` — `webread` dispatch branch + `webReadTool`.
- **Modify** `src/config.zig` — reword the `jina-api-key` help/doc text (now powers read too).

Constants used throughout: reader endpoint `https://r.jina.ai/`, transcript truncation cap `8000` bytes, local-file upload cap `25 * 1024 * 1024` bytes, multipart boundary `----WispTermReaderBoundary7MA4YWxkTrZu0gW`.

---

## Task 1: `web_read.zig` core — types + URL request + response parse

**Files:**
- Create: `src/web_read.zig`
- Modify: `src/test_fast.zig:56` (add import)

- [ ] **Step 1: Write the failing tests** — create `src/web_read.zig` with exactly this content (types + pure helpers + tests):

```zig
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
```

- [ ] **Step 2: Register the module in the fast suite** — in `src/test_fast.zig`, add directly under line 56 (`_ = @import("web_search.zig");`):

```zig
    _ = @import("web_read.zig");
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (build succeeds; the 4 new `web_read` tests pass).

- [ ] **Step 4: Commit**

```bash
git add src/web_read.zig src/test_fast.zig
git commit -m "feat(web_read): reader module core — url request + response parse"
```

---

## Task 2: Multipart upload body + local file reader

**Files:**
- Modify: `src/web_read.zig` (add functions + tests)

- [ ] **Step 1: Write the failing tests** — append to `src/web_read.zig` (before the `test "isHttpUrl …"` block is fine, but appending at end of the non-test section is cleanest; place these functions after `parseReaderResponse` and the tests at the end of the file):

Functions:

```zig
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
```

Tests (append at end of file):

```zig
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
```

- [ ] **Step 2: Run the tests**

Run: `zig build test`
Expected: PASS (2 new tests pass).

- [ ] **Step 3: Commit**

```bash
git add src/web_read.zig
git commit -m "feat(web_read): multipart upload body + local file reader"
```

---

## Task 3: Formatting for transcript and model

**Files:**
- Modify: `src/web_read.zig` (add functions + tests)

- [ ] **Step 1: Write the failing tests** — add the functions and tests.

Functions (place after `readLocalFileForUpload`):

```zig
/// Render for the transcript (user `$webread`): title + source + content,
/// truncated to `user_truncate_cap` bytes with a note when longer.
pub fn formatForUser(allocator: std.mem.Allocator, target: []const u8, result: ReadResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Read \"{s}\":\n", .{target});
    if (result.title.len > 0) try w.print("\n# {s}\n", .{result.title});
    if (result.url.len > 0) try w.print("{s}\n", .{result.url});
    try w.writeAll("\n");
    if (result.content.len > user_truncate_cap) {
        try w.writeAll(result.content[0..user_truncate_cap]);
        try w.print("\n\n…(truncated, {d} chars total)\n", .{result.content.len});
    } else {
        try w.writeAll(result.content);
    }
    return out.toOwnedSlice(allocator);
}

/// Render for the model (agent `webread` tool): title + source + full content.
pub fn formatForAgent(allocator: std.mem.Allocator, target: []const u8, result: ReadResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("Content of \"{s}\":\n", .{target});
    if (result.title.len > 0) try w.print("Title: {s}\n", .{result.title});
    if (result.url.len > 0) try w.print("URL: {s}\n", .{result.url});
    try w.print("\n{s}\n", .{result.content});
    return out.toOwnedSlice(allocator);
}
```

Tests (append at end of file). These build a `ReadResult` with an arena so `formatForUser`'s truncation path is exercised:

```zig
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
    const text = try formatForUser(a, "https://x/", big);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "truncated, " ) != null);
    try std.testing.expect(text.len < user_truncate_cap + 300);

    var small = testReadResult(false);
    defer small.deinit();
    const text2 = try formatForUser(a, "https://x/", small);
    defer a.free(text2);
    try std.testing.expect(std.mem.indexOf(u8, text2, "short body") != null);
    try std.testing.expect(std.mem.indexOf(u8, text2, "truncated") == null);
}

test "formatForAgent keeps full content" {
    const a = std.testing.allocator;
    var small = testReadResult(false);
    defer small.deinit();
    const text = try formatForAgent(a, "https://x/", small);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "URL: https://x/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "short body") != null);
}
```

- [ ] **Step 2: Run the tests**

Run: `zig build test`
Expected: PASS (3 new tests pass).

- [ ] **Step 3: Commit**

```bash
git add src/web_read.zig
git commit -m "feat(web_read): transcript + model formatters with truncation"
```

---

## Task 4: Error plumbing + impure `executeRead`

**Files:**
- Modify: `src/web_read.zig` (add error helpers, `executeRead`, tests)

- [ ] **Step 1: Add the error plumbing and `executeRead`** — append these (after the formatters, before the tests):

```zig
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

fn fetchFile(gpa: std.mem.Allocator, path: []const u8, opts: Options) !platform_http.Response {
    const lf = try readLocalFileForUpload(gpa, path, opts.max_file_bytes);
    defer gpa.free(lf.bytes);
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

/// Read `target` (http(s) URL or local file path) into clean markdown. The returned
/// `ReadResult` owns its strings via its arena (free with `result.deinit()`).
pub fn executeRead(gpa: std.mem.Allocator, target: []const u8, opts: Options) !ReadResult {
    clearErrorDetail();
    var result = ReadResult{ .arena = std.heap.ArenaAllocator.init(gpa), .title = "", .url = "", .content = "" };
    errdefer result.arena.deinit();

    var response = if (isHttpUrl(target))
        try fetchUrl(gpa, target, opts)
    else
        try fetchFile(gpa, target, opts);
    defer response.deinit(gpa);

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
    return result;
}
```

- [ ] **Step 2: Write the failing tests** — append at end of file:

```zig
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
```

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: PASS (3 new tests pass; the `executeRead` test returns `FileNotFound` before any HTTP).

- [ ] **Step 4: Commit**

```bash
git add src/web_read.zig
git commit -m "feat(web_read): error plumbing + executeRead (url + file modes)"
```

---

## Task 5: Composer — `$webread` command parsing

**Files:**
- Modify: `src/ai_chat_composer.zig:24` (WebCommand), `:28-30` (reserved_web_commands), `:34-37` (parseWebCommand)

- [ ] **Step 1: Write the failing test** — add this test next to the existing `parseWebCommand` tests in `src/ai_chat_composer.zig` (near line 445):

```zig
test "parseWebCommand matches $webread and still matches $websearch" {
    try std.testing.expectEqual(WebCommand.webread, parseWebCommand("$webread").?);
    try std.testing.expectEqual(WebCommand.websearch, parseWebCommand("$websearch").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$webreadx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("/webread"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("webread"));
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test`
Expected: FAIL to compile — `WebCommand` has no member `webread`.

- [ ] **Step 3: Implement** — make three edits in `src/ai_chat_composer.zig`:

Line 24, extend the enum:

```zig
pub const WebCommand = enum { websearch, webread };
```

Lines 28-30, add a second reserved command (the suggestion dropdown loops over this array, so no other wiring is needed):

```zig
pub const reserved_web_commands = [_]ReservedWebCommand{
    .{ .name = "websearch", .description = "search the web (Jina)" },
    .{ .name = "webread", .description = "read a web page or local file (Jina)" },
};
```

Lines 34-37, extend `parseWebCommand`:

```zig
pub fn parseWebCommand(token: []const u8) ?WebCommand {
    if (std.mem.eql(u8, token, "$websearch")) return .websearch;
    if (std.mem.eql(u8, token, "$webread")) return .webread;
    return null;
}
```

- [ ] **Step 4: Run the tests**

Run: `zig build test`
Expected: PASS (the new test plus the existing composer tests).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(composer): parse \$webread command + reserved suggestion"
```

---

## Task 6: `ai_chat.zig` — request job, dispatch, status

**Files:**
- Modify: `src/ai_chat.zig` — add `WebReadRequest` (after `WebSearchRequest`, ~line 211), `startWebReadRequest` (after `startWebSearchRequest`, ~line 2306), and switch the submit-path branch (~line 1706).

This task is verified by compilation (`zig build test-full`); like `startWebSearchRequest`, it has no isolated unit test (it needs a live `Session`).

- [ ] **Step 1: Add `WebReadRequest`** — insert after the `WebSearchRequest` struct (after line 211):

```zig
/// Lightweight background job for a `$webread` user command. Owns its target.
/// Mirrors `WebSearchRequest`; joined by `Session.deinit` via `request_thread`.
pub const WebReadRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    target: []u8,

    pub fn create(allocator: std.mem.Allocator, session: *Session, target: []const u8) !*WebReadRequest {
        const self = try allocator.create(WebReadRequest);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = session, .target = try allocator.dupe(u8, target) };
        return self;
    }

    pub fn deinit(self: *WebReadRequest) void {
        self.allocator.free(self.target);
        self.allocator.destroy(self);
    }
};
```

- [ ] **Step 2: Switch the submit-path dispatch** — replace the block at lines 1706-1711:

```zig
        if (ai_chat_composer.parseWebCommand(first_tok)) |_| {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            self.startWebSearchRequest(arg);
            return;
        }
```

with:

```zig
        if (ai_chat_composer.parseWebCommand(first_tok)) |web_cmd| {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            switch (web_cmd) {
                .websearch => self.startWebSearchRequest(arg),
                .webread => self.startWebReadRequest(arg),
            }
            return;
        }
```

- [ ] **Step 3: Add `startWebReadRequest`** — insert immediately after `startWebSearchRequest` ends (after line 2306, before `clearMessagesLocked`). Note: unlike search, it does **not** require the key (anonymous read is allowed), and the status reads "Reading…":

```zig
    /// Run a `$webread <target>` command on a background thread. Mirrors
    /// `startWebSearchRequest` but does not require a Jina key (anonymous read is
    /// allowed). Called AFTER the caller has unlocked `self.mutex`.
    fn startWebReadRequest(self: *Session, target_in: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current request to finish.") catch {};
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const target = std.mem.trim(u8, target_in, " \t\r\n");
        if (target.len == 0) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Usage: $webread <url | file path>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const req = WebReadRequest.create(self.allocator, self, target) catch {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Out of memory.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Reading…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.webReadThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start web read thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }
```

- [ ] **Step 4: Verify it compiles** (the worker `webReadThreadMain` is added in Task 7, so a full build is deferred — do a quick type check here)

Run: `zig build test 2>&1 | head -20`
Expected: This compiles the fast suite (which does not include `ai_chat.zig`); it should still PASS. The `ai_chat.zig` reference to `ai_chat_request.webReadThreadMain` is resolved in Task 7; do not run `test-full` until then.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai_chat): \$webread request job + dispatch (worker in next commit)"
```

---

## Task 7: `ai_chat_request.zig` — `webReadThreadMain` worker

**Files:**
- Modify: `src/ai_chat_request.zig` — add `webReadThreadMain` after `webSearchThreadMain` (after line 166); ensure `web_read` is imported.

- [ ] **Step 1: Add the import** — near the top of `src/ai_chat_request.zig` where `web_search` is imported (line 12), add:

```zig
const web_read = @import("web_read.zig");
```

- [ ] **Step 2: Add the worker** — insert after `webSearchThreadMain` (after line 166). The key is fetched but **optional**: a null key becomes `""` (anonymous), never an error:

```zig
/// Background worker for one `$webread` command. Owns `req`; frees it on exit.
/// Reuses the Jina key when configured (optional — anonymous read works), reads the
/// target, and appends the formatted content to the transcript.
pub fn webReadThreadMain(req: *ai_chat.WebReadRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";

    var result = web_read.executeRead(allocator, req.target, .{ .api_key = key }) catch |err| {
        const text = web_read.formatErrorText(allocator, err) catch {
            ai_chat.appendWebSearchResult(session, web_read.errorText(err));
            return;
        };
        defer allocator.free(text);
        ai_chat.appendWebSearchResult(session, text);
        return;
    };
    defer result.deinit();

    const text = web_read.formatForUser(allocator, req.target, result) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting content.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}
```

- [ ] **Step 3: Run the full suite** (now the app graph links)

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS — `0 failed`. (`appendWebSearchResult` is the generic "append local tool message + finish request" helper; reusing it for read is intentional.)

- [ ] **Step 4: Commit**

```bash
git add src/ai_chat_request.zig
git commit -m "feat(ai_chat_request): webReadThreadMain worker for \$webread"
```

---

## Task 8: Agent `webread` tool — spec + dispatch

**Files:**
- Modify: `src/ai_chat_protocol.zig:675` (add emit) and `:1485` area (add test)
- Modify: `src/ai_chat_tools.zig:198` (add dispatch branch) and `:296` area (add `webReadTool`)

- [ ] **Step 1: Write the failing test** — in `src/ai_chat_protocol.zig`, add after the existing `test "agent tool set includes websearch"` (ends ~line 1492). It mirrors that test exactly, only changing the asserted literal:

```zig
test "agent tool set includes webread" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"webread\"") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — the emitted tool JSON does not contain `"webread"`.

- [ ] **Step 3: Add the tool spec** — in `src/ai_chat_protocol.zig`, immediately after the `websearch` emit (line 675), add:

```zig
    try emit(ctx, "webread", "Read a web page or local file into clean markdown via Jina Reader. Pass an http(s):// URL to fetch a page, or a local file path (PDF, Word, Excel, PowerPoint) to upload and convert it. Use when you need the full content of one source, not a search.", "{\"url\":{\"type\":\"string\",\"description\":\"An http(s):// URL, or a local file path to upload.\"}}");
```

- [ ] **Step 4: Add the dispatch + helper** — in `src/ai_chat_tools.zig`:

(a) Add a branch after the `websearch` branch (after line 198, before the `return std.fmt.allocPrint(... "Unknown tool"...)`):

```zig
    if (std.mem.eql(u8, call.name, "webread")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const url = jsonStringArg(args.value, "url") orelse return ctx.allocator.dupe(u8, "Missing url");
        return webReadTool(ctx.allocator, url);
    }
```

(b) Add the helper after `webSearchTool` (after line 296). The key is optional (anonymous read works), so a null key becomes `""` rather than an error:

```zig
/// Agent `webread` tool: read a URL or local file into markdown for the model.
/// Key is optional (anonymous read works), so a null key becomes "".
fn webReadTool(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";
    var result = web_read.executeRead(allocator, target, .{ .api_key = key }) catch |err|
        return web_read.formatErrorText(allocator, err);
    defer result.deinit();
    return web_read.formatForAgent(allocator, target, result);
}
```

(`web_search` is already imported in `ai_chat_tools.zig` at line 31, so its `jinaApiKeyAlloc` is reachable directly — no new helper needed.)

(c) Add the import near the top of `src/ai_chat_tools.zig` next to the `web_search` import (line 31):

```zig
const web_read = @import("web_read.zig");
```

- [ ] **Step 5: Run the full suite**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS — `0 failed`, and the new `webread` tool-set test passes.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_protocol.zig src/ai_chat_tools.zig
git commit -m "feat(agent): webread tool — spec + dispatch (Jina Reader)"
```

---

## Task 9: Config help/doc text mentions read

**Files:**
- Modify: `src/config.zig:308` (doc comment) and `:1286` (--help line)

No new config key — `$webread` reuses `jina-api-key`. This task only reworded text so users learn the key powers both.

- [ ] **Step 1: Reword the doc comment** — replace line 308:

```zig
/// API key for Jina (https://jina.ai) — powers `$websearch` (s.jina.ai) and
/// `$webread` (r.jina.ai). Optional for `$webread` (anonymous read works). Empty = unset.
```

- [ ] **Step 2: Reword the --help line** — replace line 1286:

```zig
        \\  --jina-api-key <key>         API key for Jina web search/read ($websearch, $webread)
```

- [ ] **Step 3: Run the config tests**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (the existing `config: jina-api-key parses from a config line` test still passes; wording changes do not affect parsing).

- [ ] **Step 4: Commit**

```bash
git add src/config.zig
git commit -m "docs(config): note jina-api-key powers \$webread too"
```

---

## Task 10: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the fast suite**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS — `0 failed`.

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full 2>&1 | tail -5`
Expected: PASS — `0 failed`.

- [ ] **Step 3: Confirm the release build compiles**

Run: `zig build 2>&1 | tail -5`
Expected: builds cleanly (no errors).

- [ ] **Step 4: Sanity-grep the wiring** (no code change — just confirm everything is connected)

Run: `rg -n "webread" src/ | sort`
Expected: hits in `web_read.zig`? no — grep `webread` should show: `ai_chat_composer.zig` (enum, reserved, parse), `ai_chat.zig` (startWebReadRequest, dispatch), `ai_chat_request.zig` (webReadThreadMain), `ai_chat_protocol.zig` (emit + test), `ai_chat_tools.zig` (branch + webReadTool), `config.zig` (help text). If any layer is missing, that layer was not wired.

- [ ] **Step 5: GUI verification is manual** — note in the final report that GUI smoke (type `$webread https://example.com`, and `$webread <a local pdf>`; ask the agent to "read https://…") is pending on a machine with a GUI backend, matching the project's standing "GUI verify pending" convention.

---

## Notes for the implementer

- **TDD order:** pure module first (Tasks 1-4, fast suite), then composer (Task 5, fast suite), then the app-graph wiring (Tasks 6-8, `test-full`). Tasks 6-7 split deliberately so `ai_chat.zig` and its worker land in separate commits; do not run `test-full` between them (it won't link until Task 7).
- **Reused helper:** `ai_chat.appendWebSearchResult` is a generic "append local tool message + clear in-flight" helper despite its name — reuse it for read; do **not** add a parallel function.
- **Anonymous key handling:** the one behavioral difference from `websearch` — never short-circuit on a missing key; pass `""` and let Reader serve anonymously.
- **YAGNI (do not add):** no advanced Reader headers (screenshot, chunking, presets, per-page), no SSH-remote file reads, no caching, no env-var key, no per-profile key, no AI summarization turn for the user command. Relative file paths resolve against the process cwd (document "absolute path recommended" if you touch user-facing help).
```
