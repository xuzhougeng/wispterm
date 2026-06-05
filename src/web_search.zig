//! Engine-agnostic web search core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeSearch`). Only the `jina` engine exists
//! today; a new engine is a new branch in `executeSearch`. Leaf module: std only.
const std = @import("std");

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
