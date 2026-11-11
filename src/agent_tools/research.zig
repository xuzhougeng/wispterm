//! Agent research tool runtime adapters.
const std = @import("std");
const web_search = @import("../research/web_search.zig");
const web_read = @import("../research/web_read.zig");
const pubmed = @import("../research/pubmed.zig");
const http_proxy = @import("../platform/http_proxy.zig");
const types = @import("../assistant/conversation/types.zig");
const tool_access = @import("access.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

/// Agent `websearch` tool: full-content Jina search, formatted for the model.
pub fn webSearch(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    const key = (web_search.jinaApiKeyAlloc(allocator) catch null) orelse
        return web_search.formatErrorText(allocator, error.MissingApiKey);
    defer allocator.free(key);
    var route = http_proxy.loadResearch(allocator);
    defer route.deinit(allocator);
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = web_search.executeSearch(allocator, query, .{
        .engine = .jina,
        .api_key = key,
        .with_content = true,
        .max_results = max,
        .proxy = route.explicit,
    }) catch |err| return web_search.formatErrorText(allocator, err);
    defer results.deinit();
    return web_search.formatForAgent(allocator, query, results.items);
}

/// Agent `webread` entry point. A URL is fetched as-is. A local file is
/// different: it is *uploaded* to the reader service to be converted, so it
/// leaves the machine. That path used to run with no access check in every
/// permission mode. Now a deny-listed path is refused outright (it is never
/// uploaded, whatever the mode), and any other local file needs the
/// operator's approval unless permission is `full`.
pub fn webReadTool(ctx: *ToolContext, target_in: []const u8) ![]u8 {
    const target = std.mem.trim(u8, target_in, " \t\r\n");
    if (!web_read.isHttpUrl(target)) {
        const resolved = try web_read.resolveFilePath(ctx.allocator, target, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        const gate = tool_access.fileGate(ctx, resolved, false);
        if (gate.blacklisted) {
            return tool_output.deniedResult(ctx.allocator, resolved, "protected path - webread does not upload it");
        }
        if (ctx.settings.permission != .full) {
            if (!ctx.requestApproval("webread", resolved, "Uploads this local file to the web reader service to convert it")) {
                return tool_output.deniedResult(ctx.allocator, resolved, "operator rejected uploading the file");
            }
        }
    }
    return webRead(ctx.allocator, target, ctx.settings.working_dir);
}

/// Agent `webread` tool: read a URL or local file into markdown for the model.
/// Key is optional (anonymous read works), so a null key becomes "". `working_dir`
/// (the conversation's cwd) is the cache root and resolves relative file targets.
pub fn webRead(allocator: std.mem.Allocator, target_in: []const u8, working_dir: ?[]const u8) ![]u8 {
    const target = std.mem.trim(u8, target_in, " \t\r\n");
    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";
    var route = http_proxy.loadResearch(allocator);
    defer route.deinit(allocator);
    var result = web_read.executeRead(allocator, target, .{ .api_key = key, .cache_dir = working_dir, .proxy = route.explicit }) catch |err|
        return web_read.formatErrorText(allocator, err);
    defer result.deinit();
    return web_read.formatForAgent(allocator, target, &result);
}

/// Agent `pubmed` tool: NCBI PubMed search with abstracts, formatted for the model.
pub fn pubMed(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    var route = http_proxy.loadResearch(allocator);
    defer route.deinit(allocator);
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = pubmed.executeSearch(allocator, query, .{ .max_results = max, .proxy = route.explicit }) catch |err|
        return pubmed.formatErrorText(allocator, err);
    defer results.deinit();
    return pubmed.formatForAgent(allocator, query, results.items);
}
