//! Engine-agnostic web search core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeSearch`). Only the `jina` engine exists
//! today; a new engine is a new branch in `executeSearch`. HTTP transport goes
//! through `platform/http_client.zig` so desktop builds can use system proxies.
const std = @import("std");
const platform_http = @import("platform/http_client.zig");

const jina_search_url = "https://s.jina.ai/";

pub const Engine = enum { jina };

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    description: []const u8,
    content: ?[]const u8 = null,
};

pub const Options = struct {
    engine: Engine = .jina,
    api_key: []const u8,
    with_content: bool,
    max_results: usize = 10,
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    items: []SearchResult,
    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }
};

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

/// Build the Jina search request body: `{"q":<json-escaped query>}`.
pub fn buildJinaRequestBody(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"q\":");
    try appendJsonString(allocator, &out, query);
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

/// Parse a Jina search JSON response (`{"data":[{title,url,description,content?},...]}`)
/// into result structs whose strings are duped into `arena`. Caps at `max_results`.
/// Duping into `arena` means the parsed value may safely alias `json_bytes`, which
/// the caller frees after this returns.
pub fn parseJinaResponse(arena: std.mem.Allocator, json_bytes: []const u8, max_results: usize) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const data_val = parsed.value.object.get("data") orelse return error.ParseFailed;
    if (data_val != .array) return &.{};
    const arr = data_val.array.items;
    const n = @min(arr.len, max_results);
    const list = try arena.alloc(SearchResult, n);
    var count: usize = 0;
    for (arr[0..n]) |item| {
        if (item != .object) continue;
        const obj = item.object;
        list[count] = .{
            .title = try arena.dupe(u8, jsonStr(obj, "title") orelse ""),
            .url = try arena.dupe(u8, jsonStr(obj, "url") orelse ""),
            .description = try arena.dupe(u8, jsonStr(obj, "description") orelse ""),
            .content = if (jsonStr(obj, "content")) |c| try arena.dupe(u8, c) else null,
        };
        count += 1;
    }
    return list[0..count];
}

test "buildJinaRequestBody json-escapes the query" {
    const a = std.testing.allocator;
    const body = try buildJinaRequestBody(a, "say \"hi\"\nbye");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"q\":\"say \\\"hi\\\"\\nbye\"}", body);
}

test "parseJinaResponse extracts fields, honors max, tolerates missing content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"code":200,"data":[
        \\{"title":"First","url":"https://a.example","description":"desc a","content":"body a"},
        \\{"title":"Second","url":"https://b.example","description":"desc b"}
        \\]}
    ;
    const items = try parseJinaResponse(arena.allocator(), json, 10);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("First", items[0].title);
    try std.testing.expectEqualStrings("https://b.example", items[1].url);
    try std.testing.expectEqualStrings("body a", items[0].content.?);
    try std.testing.expect(items[1].content == null);
}

test "parseJinaResponse caps at max_results and handles empty data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"data\":[{\"title\":\"a\",\"url\":\"u\",\"description\":\"d\"},{\"title\":\"b\",\"url\":\"u\",\"description\":\"d\"}]}";
    const capped = try parseJinaResponse(arena.allocator(), json, 1);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    const empty = try parseJinaResponse(arena.allocator(), "{\"data\":[]}", 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

/// Render results for the transcript (user `$websearch`): snippets only.
pub fn formatForUser(allocator: std.mem.Allocator, query: []const u8, results: []const SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    if (results.len == 0) {
        try w.print("No web results for: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try w.print("Web results for \"{s}\":\n", .{query});
    for (results, 0..) |r, i| {
        try w.print("\n{d}. {s}\n{s}\n", .{ i + 1, r.title, r.url });
        if (r.description.len > 0) try w.print("{s}\n", .{r.description});
    }
    return out.toOwnedSlice(allocator);
}

/// Render results for the model (agent `websearch` tool): includes page content.
pub fn formatForAgent(allocator: std.mem.Allocator, query: []const u8, results: []const SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    if (results.len == 0) {
        try w.print("No results found for query: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try w.print("Search results for \"{s}\" ({d} results):\n", .{ query, results.len });
    for (results, 0..) |r, i| {
        try w.print("\n[{d}] {s}\nURL: {s}\n", .{ i + 1, r.title, r.url });
        if (r.description.len > 0) try w.print("{s}\n", .{r.description});
        if (r.content) |c| try w.print("\n{s}\n", .{c});
    }
    return out.toOwnedSlice(allocator);
}

test "formatForUser lists snippets and omits content" {
    const a = std.testing.allocator;
    const results = [_]SearchResult{
        .{ .title = "T", .url = "https://x", .description = "d", .content = "SECRET-CONTENT" },
    };
    const text = try formatForUser(a, "q", &results);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1. T") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "https://x") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET-CONTENT") == null);
}

test "formatForAgent includes content; empty results message" {
    const a = std.testing.allocator;
    const results = [_]SearchResult{
        .{ .title = "T", .url = "https://x", .description = "d", .content = "BODY-TEXT" },
    };
    const text = try formatForAgent(a, "q", &results);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "BODY-TEXT") != null);
    const none = try formatForAgent(a, "q", &.{});
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "No results") != null);
}

// --- Process-global Jina API key (set from config, read by both entry points) ---
var g_jina_mutex: std.Thread.Mutex = .{};
var g_jina_key_buf: [512]u8 = undefined;
var g_jina_key_len: usize = 0;

/// Set the Jina API key from config. Empty clears it. Oversized keys truncate.
pub fn setJinaApiKey(key: []const u8) void {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    const n = @min(key.len, g_jina_key_buf.len);
    @memcpy(g_jina_key_buf[0..n], key[0..n]);
    g_jina_key_len = n;
}

pub fn jinaApiKeySet() bool {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    return g_jina_key_len > 0;
}

/// Return an owned copy of the Jina key, or null when unset. Caller frees.
/// Copying under the lock avoids racing a concurrent `setJinaApiKey`.
pub fn jinaApiKeyAlloc(allocator: std.mem.Allocator) !?[]u8 {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    if (g_jina_key_len == 0) return null;
    return try allocator.dupe(u8, g_jina_key_buf[0..g_jina_key_len]);
}

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
        const fallback = "Web search failed: diagnostic message was too long.";
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
    switch (err) {
        error.ConnectionTimedOut => setErrorDetail(
            .network,
            "Web search request timed out before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        error.UnknownHostName,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.HostLacksNetworkAddresses,
        => setErrorDetail(
            .network,
            "Web search DNS lookup failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => setErrorDetail(
            .network,
            "Web search TLS setup failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionResetByPeer,
        => setErrorDetail(
            .network,
            "Web search connection failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        error.ProxyConfigurationFailed => setErrorDetail(
            .network,
            "Web search system proxy configuration failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        error.WinHttpRequestFailed,
        error.MacosHttpRequestFailed,
        => setErrorDetail(
            .network,
            "Web search platform HTTP request failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
        else => setErrorDetail(
            .network,
            "Web search request failed before response: {s} ({s})",
            .{ @errorName(err), jina_search_url },
        ),
    }
}

/// Friendly, user/model-facing message for a search error.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingApiKey => "Jina API key not set — add `jina-api-key = <key>` to your WispTerm config.",
        error.Network => errorDetail(.network) orelse "Web search failed: could not reach the Jina search service.",
        error.HttpStatus => errorDetail(.http_status) orelse "Web search failed: the Jina search service returned an error.",
        error.ParseFailed => errorDetail(.parse_failed) orelse "Web search failed: could not parse the Jina response.",
        else => "Web search failed.",
    };
}

/// Owned error text for transcript/model output. Unlike `errorText`, this keeps
/// unexpected lower-level error names visible instead of collapsing them.
pub fn formatErrorText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return switch (err) {
        error.MissingApiKey, error.Network, error.HttpStatus, error.ParseFailed => allocator.dupe(u8, errorText(err)),
        else => std.fmt.allocPrint(allocator, "Web search failed: {s}.", .{@errorName(err)}),
    };
}

/// Run a web search. `gpa` is used for transient HTTP buffers; the returned
/// `Results` owns its strings via its own arena (free with `results.deinit()`).
pub fn executeSearch(gpa: std.mem.Allocator, query: []const u8, opts: Options) !Results {
    clearErrorDetail();
    if (opts.api_key.len == 0) return error.MissingApiKey;
    var results = Results{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
    errdefer results.arena.deinit();
    results.items = switch (opts.engine) {
        .jina => try searchJina(results.arena.allocator(), gpa, query, opts),
    };
    return results;
}

fn searchJina(arena: std.mem.Allocator, gpa: std.mem.Allocator, query: []const u8, opts: Options) ![]SearchResult {
    const body = try buildJinaRequestBody(gpa, query);
    defer gpa.free(body);
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key});
    defer gpa.free(bearer);

    var headers: [4]platform_http.Header = undefined;
    var header_len: usize = 0;
    headers[header_len] = .{ .name = "Content-Type", .value = "application/json" };
    header_len += 1;
    headers[header_len] = .{ .name = "Authorization", .value = bearer };
    header_len += 1;
    headers[header_len] = .{ .name = "Accept", .value = "application/json" };
    header_len += 1;
    if (!opts.with_content) {
        headers[header_len] = .{ .name = "X-Respond-With", .value = "no-content" };
        header_len += 1;
    }

    var response = platform_http.fetch(gpa, .{
        .method = .POST,
        .url = jina_search_url,
        .headers = headers[0..header_len],
        .body = body,
        .timeout_ms = 30_000,
    }) catch |err| {
        setNetworkErrorDetail(err);
        std.log.warn("{s}", .{errorText(error.Network)});
        return error.Network;
    };
    defer response.deinit(gpa);

    if (response.status != 200) {
        const trimmed = std.mem.trim(u8, response.body, " \t\r\n");
        const excerpt = trimmed[0..@min(trimmed.len, 300)];
        if (excerpt.len > 0) {
            setErrorDetail(
                .http_status,
                "Web search failed: Jina returned HTTP {d}: {s}",
                .{ response.status, excerpt },
            );
        } else {
            setErrorDetail(
                .http_status,
                "Web search failed: Jina returned HTTP {d}.",
                .{response.status},
            );
        }
        std.log.warn("jina search HTTP {d}: {s}", .{ response.status, trimmed });
        return error.HttpStatus;
    }
    return parseJinaResponse(arena, response.body, opts.max_results) catch |err| {
        if (err == error.ParseFailed) {
            setErrorDetail(.parse_failed, "Web search failed: could not parse the Jina response ({s}).", .{@errorName(err)});
        }
        return err;
    };
}

test "executeSearch rejects an empty api key without touching the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingApiKey, executeSearch(arena.allocator(), "q", .{ .api_key = "", .with_content = false }));
}

test "errorText maps known errors to friendly text" {
    clearErrorDetail();
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.MissingApiKey), "jina-api-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "reach") != null);
}

test "errorText exposes captured transport and HTTP details" {
    clearErrorDetail();
    setNetworkErrorDetail(error.ConnectionTimedOut);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "ConnectionTimedOut") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "timed out") != null);
    clearErrorDetail();
    setErrorDetail(.http_status, "Web search failed: Jina returned HTTP {d}: {s}", .{ 401, "AuthenticationRequiredError" });
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.HttpStatus), "401") != null);
    clearErrorDetail();
}

test "formatErrorText includes unexpected lower-level error names" {
    const text = try formatErrorText(std.testing.allocator, error.ConnectionTimedOut);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ConnectionTimedOut") != null);
}

test "jina api key globals round-trip and clear" {
    setJinaApiKey("abc123");
    try std.testing.expect(jinaApiKeySet());
    const k = (try jinaApiKeyAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(k);
    try std.testing.expectEqualStrings("abc123", k);
    setJinaApiKey("");
    try std.testing.expect(!jinaApiKeySet());
}
