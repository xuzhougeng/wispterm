//! JSON-lines wire protocol for the agent terminal control API (wisptermctl).
//! Pure: std-only, no GUI/socket deps, so both the in-process server and the
//! standalone client compile against it. One JSON object per line,
//! '\n'-terminated.
const std = @import("std");

pub const Cmd = enum { panes, get_text, send_text };

pub fn cmdToStr(c: Cmd) []const u8 {
    return switch (c) {
        .panes => "panes",
        .get_text => "get-text",
        .send_text => "send-text",
    };
}

pub fn cmdFromStr(s: []const u8) ?Cmd {
    if (std.mem.eql(u8, s, "panes")) return .panes;
    if (std.mem.eql(u8, s, "get-text")) return .get_text;
    if (std.mem.eql(u8, s, "send-text")) return .send_text;
    return null;
}

pub const Request = struct {
    token: []const u8 = "",
    cmd: Cmd,
    id: []const u8 = "",
    recent: ?u32 = null,
    data: []const u8 = "",
};

/// Build one newline-terminated JSON request line. Caller owns the result.
pub fn encodeRequest(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"token\":");
    try writeJsonString(allocator, &out, req.token);
    try out.appendSlice(allocator, ",\"cmd\":");
    try writeJsonString(allocator, &out, cmdToStr(req.cmd));
    if (req.id.len != 0) {
        try out.appendSlice(allocator, ",\"id\":");
        try writeJsonString(allocator, &out, req.id);
    }
    if (req.recent) |n| {
        try out.appendSlice(allocator, ",\"recent\":");
        try out.print(allocator, "{d}", .{n});
    }
    if (req.cmd == .send_text) {
        try out.appendSlice(allocator, ",\"data\":");
        try writeJsonString(allocator, &out, req.data);
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// Parsed request; owns the JSON arena that backs the borrowed slices.
pub const ParsedRequest = struct {
    parsed: std.json.Parsed(std.json.Value),
    value: Request,
    pub fn deinit(self: *ParsedRequest) void {
        self.parsed.deinit();
    }
};

/// Parse one request line. Errors on malformed JSON or unknown/absent cmd.
/// `.alloc_always` keeps parsed strings independent of `line` (the caller may
/// free or reuse the source buffer immediately after).
pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) !ParsedRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const obj = parsed.value.object;

    const cmd_str = stringField(obj, "cmd") orelse return error.InvalidRequest;
    const cmd = cmdFromStr(cmd_str) orelse return error.UnknownCommand;
    var req = Request{ .cmd = cmd };
    req.token = stringField(obj, "token") orelse "";
    req.id = stringField(obj, "id") orelse "";
    req.data = stringField(obj, "data") orelse "";
    if (obj.get("recent")) |v| {
        // Clamp to u32 range: a huge value must not panic (@intCast) the server
        // thread — and parseRequest runs BEFORE token auth, so this is reachable
        // pre-auth by any local client.
        if (v == .integer and v.integer >= 0)
            req.recent = @intCast(@min(v.integer, @as(i64, std.math.maxInt(u32))));
    }
    return .{ .parsed = parsed, .value = req };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// --- server response builders (newline-terminated; caller owns) ---

pub fn encodeOk(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"ok\":true}\n");
}

pub fn encodeOkText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"result\":");
    try writeJsonString(allocator, &out, text);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// `raw` must already be valid JSON (e.g. the panes object). Embedded verbatim.
pub fn encodeOkRawJson(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"result\":");
    try out.appendSlice(allocator, raw);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

pub fn encodeError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"error\":");
    try writeJsonString(allocator, &out, msg);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

// --- client response parsing ---

pub const Response = struct {
    parsed: std.json.Parsed(std.json.Value),
    ok: bool,
    error_msg: []const u8 = "", // borrows the arena
    /// result decoded as a JSON string (get-text), else null. Borrows arena.
    result_text: ?[]const u8 = null,
    /// raw JSON text of `result` (panes object), or "" when absent. Borrows arena.
    result_raw: []const u8 = "",
    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }
};

pub fn parseResponse(allocator: std.mem.Allocator, line: []const u8) !Response {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const obj = parsed.value.object;
    const ok = if (obj.get("ok")) |v| (v == .bool and v.bool) else false;
    var resp = Response{ .parsed = parsed, .ok = ok };
    resp.error_msg = stringField(obj, "error") orelse "";
    if (obj.get("result")) |v| {
        if (v == .string) {
            resp.result_text = v.string;
        } else {
            // Re-stringify non-string results (the panes object) for passthrough,
            // into the parsed arena so it is freed with the Response.
            resp.result_raw = try std.json.Stringify.valueAlloc(parsed.arena.allocator(), v, .{});
        }
    }
    return resp;
}

/// Minimal JSON string writer reusing the stdlib escaper.
fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = s }, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

// ---- tests ----
const t = std.testing;

test "request round-trips token/cmd/id/recent" {
    const line = try encodeRequest(t.allocator, .{ .token = "abc", .cmd = .get_text, .id = "surf01", .recent = 50 });
    defer t.allocator.free(line);
    try t.expect(line[line.len - 1] == '\n');
    var pr = try parseRequest(t.allocator, line);
    defer pr.deinit();
    try t.expectEqualStrings("abc", pr.value.token);
    try t.expectEqual(Cmd.get_text, pr.value.cmd);
    try t.expectEqualStrings("surf01", pr.value.id);
    try t.expectEqual(@as(?u32, 50), pr.value.recent);
}

test "send-text data with newline survives JSON round-trip" {
    const line = try encodeRequest(t.allocator, .{ .token = "x", .cmd = .send_text, .id = "s", .data = "ls -la\n" });
    defer t.allocator.free(line);
    var pr = try parseRequest(t.allocator, line);
    defer pr.deinit();
    try t.expectEqualStrings("ls -la\n", pr.value.data);
}

test "parseRequest clamps an out-of-u32 recent instead of panicking" {
    var pr = try parseRequest(t.allocator, "{\"token\":\"x\",\"cmd\":\"get-text\",\"id\":\"s\",\"recent\":5000000000}");
    defer pr.deinit();
    try t.expectEqual(@as(?u32, std.math.maxInt(u32)), pr.value.recent);
}

test "parseRequest rejects unknown command and non-object" {
    try t.expectError(error.UnknownCommand, parseRequest(t.allocator, "{\"cmd\":\"nope\"}"));
    try t.expectError(error.InvalidRequest, parseRequest(t.allocator, "[]"));
    try t.expectError(error.InvalidRequest, parseRequest(t.allocator, "{\"token\":\"x\"}"));
}

test "ok-text response round-trips terminal text with control + CJK chars" {
    const line = try encodeOkText(t.allocator, "line1\r\n\"quoted\"\t你好");
    defer t.allocator.free(line);
    var r = try parseResponse(t.allocator, line);
    defer r.deinit();
    try t.expect(r.ok);
    try t.expectEqualStrings("line1\r\n\"quoted\"\t你好", r.result_text.?);
}

test "ok-raw-json response exposes result_raw, error response carries message" {
    const ok = try encodeOkRawJson(t.allocator, "{\"activeTab\":0,\"tabs\":[]}");
    defer t.allocator.free(ok);
    var r = try parseResponse(t.allocator, ok);
    defer r.deinit();
    try t.expect(r.ok);
    try t.expect(r.result_raw.len > 0);
    try t.expect(std.mem.indexOf(u8, r.result_raw, "activeTab") != null);

    const err = try encodeError(t.allocator, "unauthorized");
    defer t.allocator.free(err);
    var re = try parseResponse(t.allocator, err);
    defer re.deinit();
    try t.expect(!re.ok);
    try t.expectEqualStrings("unauthorized", re.error_msg);
}

test "encodeOk is a bare success line" {
    const line = try encodeOk(t.allocator);
    defer t.allocator.free(line);
    var r = try parseResponse(t.allocator, line);
    defer r.deinit();
    try t.expect(r.ok);
    try t.expect(r.result_text == null);
    try t.expectEqualStrings("", r.result_raw);
}
