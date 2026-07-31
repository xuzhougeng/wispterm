//! Agent research tool runtime adapters.
const std = @import("std");
const web_search = @import("../research/web_search.zig");
const web_read = @import("../research/web_read.zig");
const pubmed = @import("../research/pubmed.zig");

/// Agent `websearch` tool: full-content Jina search, formatted for the model.
pub fn webSearch(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    const key = (web_search.jinaApiKeyAlloc(allocator) catch null) orelse
        return web_search.formatErrorText(allocator, error.MissingApiKey);
    defer allocator.free(key);
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = web_search.executeSearch(allocator, query, .{
        .engine = .jina,
        .api_key = key,
        .with_content = true,
        .max_results = max,
    }) catch |err| return web_search.formatErrorText(allocator, err);
    defer results.deinit();
    return web_search.formatForAgent(allocator, query, results.items);
}

/// Agent `webread` tool: read a URL or local file into markdown for the model.
/// Key is optional (anonymous read works), so a null key becomes "". `working_dir`
/// (the conversation's cwd) is the cache root and resolves relative file targets.
pub fn webRead(allocator: std.mem.Allocator, target_in: []const u8, working_dir: ?[]const u8) ![]u8 {
    const target = std.mem.trim(u8, target_in, " \t\r\n");
    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";
    var result = web_read.executeRead(allocator, target, .{ .api_key = key, .cache_dir = working_dir }) catch |err|
        return web_read.formatErrorText(allocator, err);
    defer result.deinit();
    return web_read.formatForAgent(allocator, target, &result);
}

/// Agent `pubmed` tool: NCBI PubMed search with abstracts, formatted for the model.
pub fn pubMed(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = pubmed.executeSearch(allocator, query, .{ .max_results = max }) catch |err|
        return pubmed.formatErrorText(allocator, err);
    defer results.deinit();
    return pubmed.formatForAgent(allocator, query, results.items);
}
