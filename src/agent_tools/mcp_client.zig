//! Minimal MCP (Model Context Protocol) client — v0.
//!
//! WispTerm is the MCP *host*: this module lets the Copilot call tools exposed
//! by an external MCP *server*. Scope is deliberately small — stdio transport
//! only, JSON-RPC 2.0, the three methods `initialize` / `tools/list` /
//! `tools/call`. HTTP/OAuth/marketplace are out of scope (add when a real
//! remote server needs it).
//!
//! std-only on purpose so the protocol layer stays unit-testable with
//! `zig test src/agent_tools/mcp_client.zig`, no Session/ToolContext graph.
const std = @import("std");
const builtin = @import("builtin");

/// One tool advertised by a `tools/list` response. All fields owned.
pub const ToolDef = struct {
    name: []u8,
    description: []u8,
    /// Raw JSON of the tool's `inputSchema` (`{}` when the server omits it).
    input_schema_json: []u8,
};

pub fn freeToolDef(allocator: std.mem.Allocator, def: ToolDef) void {
    allocator.free(def.name);
    allocator.free(def.description);
    allocator.free(def.input_schema_json);
}

pub fn freeToolDefs(allocator: std.mem.Allocator, defs: []ToolDef) void {
    for (defs) |d| freeToolDef(allocator, d);
    allocator.free(defs);
}

/// Parse the `result` object of a `tools/list` response into owned tool defs.
pub fn parseToolsListResult(allocator: std.mem.Allocator, result_json: []const u8) ![]ToolDef {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return error.InvalidMcpResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpResponse;
    const tools_val = parsed.value.object.get("tools") orelse return allocator.alloc(ToolDef, 0);
    if (tools_val != .array) return error.InvalidMcpResponse;

    var list: std.ArrayListUnmanaged(ToolDef) = .empty;
    errdefer {
        for (list.items) |d| freeToolDef(allocator, d);
        list.deinit(allocator);
    }
    for (tools_val.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;

        const name = try allocator.dupe(u8, name_v.string);
        errdefer allocator.free(name);
        const desc = if (item.object.get("description")) |d|
            (if (d == .string) try allocator.dupe(u8, d.string) else try allocator.dupe(u8, ""))
        else
            try allocator.dupe(u8, "");
        errdefer allocator.free(desc);
        const schema = if (item.object.get("inputSchema")) |s|
            try std.json.Stringify.valueAlloc(allocator, s, .{})
        else
            try allocator.dupe(u8, "{}");
        errdefer allocator.free(schema);

        try list.append(allocator, .{ .name = name, .description = desc, .input_schema_json = schema });
    }
    return list.toOwnedSlice(allocator);
}

test "parseToolsListResult extracts name, description and input schema" {
    const a = std.testing.allocator;
    const result =
        \\{"tools":[{"name":"add","description":"Add two numbers","inputSchema":{"type":"object","properties":{"a":{"type":"number"}}}},{"name":"ping","description":"","inputSchema":{"type":"object"}}]}
    ;
    const defs = try parseToolsListResult(a, result);
    defer freeToolDefs(a, defs);
    try std.testing.expectEqual(@as(usize, 2), defs.len);
    try std.testing.expectEqualStrings("add", defs[0].name);
    try std.testing.expectEqualStrings("Add two numbers", defs[0].description);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\"}}}", defs[0].input_schema_json);
    try std.testing.expectEqualStrings("ping", defs[1].name);
    try std.testing.expectEqualStrings("", defs[1].description);
}

test "parseToolsListResult defaults a missing description and inputSchema" {
    const a = std.testing.allocator;
    const defs = try parseToolsListResult(a, "{\"tools\":[{\"name\":\"noargs\"}]}");
    defer freeToolDefs(a, defs);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("noargs", defs[0].name);
    try std.testing.expectEqualStrings("", defs[0].description);
    try std.testing.expectEqualStrings("{}", defs[0].input_schema_json);
}

/// Flatten a `tools/call` result into the plain text handed back to the model:
/// text content blocks joined by newlines, non-text blocks shown as a marker,
/// and an `isError:true` result prefixed so the model knows the call failed.
pub fn parseToolCallResult(allocator: std.mem.Allocator, result_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return error.InvalidMcpResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpResponse;
    const root = parsed.value.object;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const is_error = if (root.get("isError")) |v| (v == .bool and v.bool) else false;
    if (is_error) try out.appendSlice(allocator, "[tool error] ");

    if (root.get("content")) |content| {
        if (content == .array) {
            var first = true;
            for (content.array.items) |block| {
                if (block != .object) continue;
                const typ = if (block.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (!first) try out.appendSlice(allocator, "\n");
                first = false;
                if (std.mem.eql(u8, typ, "text")) {
                    const txt = if (block.object.get("text")) |t| (if (t == .string) t.string else "") else "";
                    try out.appendSlice(allocator, txt);
                } else {
                    try out.appendSlice(allocator, "[non-text content: ");
                    try out.appendSlice(allocator, if (typ.len == 0) "unknown" else typ);
                    try out.append(allocator, ']');
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

test "parseToolCallResult joins text content blocks with newlines" {
    const a = std.testing.allocator;
    const out = try parseToolCallResult(a, "{\"content\":[{\"type\":\"text\",\"text\":\"line 1\"},{\"type\":\"text\",\"text\":\"line 2\"}],\"isError\":false}");
    defer a.free(out);
    try std.testing.expectEqualStrings("line 1\nline 2", out);
}

test "parseToolCallResult prefixes an error result" {
    const a = std.testing.allocator;
    const out = try parseToolCallResult(a, "{\"content\":[{\"type\":\"text\",\"text\":\"boom\"}],\"isError\":true}");
    defer a.free(out);
    try std.testing.expectEqualStrings("[tool error] boom", out);
}

test "parseToolCallResult marks a non-text content block" {
    const a = std.testing.allocator;
    const out = try parseToolCallResult(a, "{\"content\":[{\"type\":\"image\",\"data\":\"...\"}]}");
    defer a.free(out);
    try std.testing.expectEqualStrings("[non-text content: image]", out);
}

/// A parsed JSON-RPC response: either the raw `result` JSON, or the human
/// message from a JSON-RPC `error` object. Both payloads are owned.
pub const Response = union(enum) {
    ok: []u8,
    err: []u8,
};

pub fn freeResponse(allocator: std.mem.Allocator, r: Response) void {
    switch (r) {
        .ok => |s| allocator.free(s),
        .err => |s| allocator.free(s),
    }
}

/// Parse one JSON-RPC response line. Returns `.ok` with the re-serialized
/// `result`, or `.err` with the error message. Malformed → InvalidMcpResponse.
/// ponytail: id correlation ignored — v0 is one request → one response, in order.
pub fn parseResponse(allocator: std.mem.Allocator, line: []const u8) !Response {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidMcpResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpResponse;
    const root = parsed.value.object;

    if (root.get("error")) |e| {
        const msg = if (e == .object)
            (if (e.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error")
        else
            "unknown error";
        return Response{ .err = try allocator.dupe(u8, msg) };
    }
    if (root.get("result")) |res| {
        return Response{ .ok = try std.json.Stringify.valueAlloc(allocator, res, .{}) };
    }
    return error.InvalidMcpResponse;
}

test "parseResponse returns the raw result JSON on success" {
    const a = std.testing.allocator;
    const r = try parseResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}");
    defer freeResponse(a, r);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("{\"tools\":[]}", r.ok);
}

test "parseResponse surfaces a JSON-RPC error message" {
    const a = std.testing.allocator;
    const r = try parseResponse(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}");
    defer freeResponse(a, r);
    try std.testing.expect(r == .err);
    try std.testing.expectEqualStrings("Method not found", r.err);
}

test "parseResponse rejects a malformed line" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidMcpResponse, parseResponse(a, "not json"));
}

/// Encode a JSON-RPC 2.0 request line. `params_json` is raw, already-valid JSON
/// (or null to omit). `method` is a caller-controlled constant, embedded as-is.
/// Result ends in '\n' per the MCP stdio framing (one message per line).
pub fn encodeRequest(allocator: std.mem.Allocator, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
    if (params_json) |p| {
        return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ id, method, p });
    }
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}\n", .{ id, method });
}

/// Build the `params` object for a `tools/call` request: `{"name":..,"arguments":..}`.
/// `name` is JSON-escaped; `arguments_json` is raw model-supplied JSON (empty → `{}`).
pub fn toolsCallParams(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]u8 {
    const name_quoted = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = name }, .{});
    defer allocator.free(name_quoted);
    const args = if (std.mem.trim(u8, arguments_json, " \t\r\n").len == 0) "{}" else arguments_json;
    return std.fmt.allocPrint(allocator, "{{\"name\":{s},\"arguments\":{s}}}", .{ name_quoted, args });
}

test "toolsCallParams escapes the tool name and embeds raw arguments" {
    const a = std.testing.allocator;
    const out = try toolsCallParams(a, "read-file", "{\"path\":\"/tmp/x\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"name\":\"read-file\",\"arguments\":{\"path\":\"/tmp/x\"}}", out);
}

test "toolsCallParams defaults blank arguments to an empty object" {
    const a = std.testing.allocator;
    const out = try toolsCallParams(a, "ping", "  \n");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"name\":\"ping\",\"arguments\":{}}", out);
}

test "toolsCallParams escapes a quote in the tool name" {
    const a = std.testing.allocator;
    const out = try toolsCallParams(a, "we\"ird", "{}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"name\":\"we\\\"ird\",\"arguments\":{}}", out);
}

test "encodeRequest builds a newline-terminated JSON-RPC request with params" {
    const a = std.testing.allocator;
    const out = try encodeRequest(a, 7, "tools/call", "{\"name\":\"x\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"x\"}}\n",
        out,
    );
}

test "encodeRequest omits params when null" {
    const a = std.testing.allocator;
    const out = try encodeRequest(a, 1, "tools/list", null);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n",
        out,
    );
}

// ---------------------------------------------------------------------------
// stdio transport — spawn one MCP server subprocess and talk JSON-RPC to it.
// ---------------------------------------------------------------------------

/// A live connection to one MCP server over its stdin/stdout pipes.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    read_buf: std.ArrayListUnmanaged(u8) = .empty,
    next_id: i64 = 1,

    /// Spawn `argv[0]` as an MCP server with piped stdin/stdout.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) !Connection {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // ponytail: drop server logs; pipe stderr to a diag log if a server needs debugging.
        child.stderr_behavior = .Ignore;
        child.create_no_window = true;
        try child.spawn();
        return .{ .allocator = allocator, .child = child };
    }

    pub fn deinit(self: *Connection) void {
        _ = self.child.kill() catch {};
        self.read_buf.deinit(self.allocator);
    }

    /// Read one newline-delimited message from the server, buffering any bytes
    /// read past the newline for the next call.
    fn readLine(self: *Connection) ![]u8 {
        var tmp: [4096]u8 = undefined;
        while (true) {
            if (std.mem.indexOfScalar(u8, self.read_buf.items, '\n')) |nl| {
                const line = try self.allocator.dupe(u8, self.read_buf.items[0..nl]);
                errdefer self.allocator.free(line);
                const rest_len = self.read_buf.items.len - (nl + 1);
                std.mem.copyForwards(u8, self.read_buf.items[0..rest_len], self.read_buf.items[nl + 1 ..]);
                self.read_buf.shrinkRetainingCapacity(rest_len);
                return line;
            }
            const stdout = self.child.stdout orelse return error.McpServerClosed;
            const n = try stdout.read(&tmp);
            if (n == 0) return error.McpServerClosed;
            try self.read_buf.appendSlice(self.allocator, tmp[0..n]);
        }
    }

    fn isNotification(allocator: std.mem.Allocator, line: []const u8) bool {
        var p = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
        defer p.deinit();
        if (p.value != .object) return false;
        return p.value.object.get("method") != null and p.value.object.get("id") == null;
    }

    /// Send a request and return the matching response, skipping notification
    /// lines (e.g. `notifications/message` logs) the server emits first.
    pub fn call(self: *Connection, method: []const u8, params_json: ?[]const u8) !Response {
        const id = self.next_id;
        self.next_id += 1;
        const req = try encodeRequest(self.allocator, id, method, params_json);
        defer self.allocator.free(req);
        const stdin = self.child.stdin orelse return error.McpServerClosed;
        try stdin.writeAll(req);
        while (true) {
            const line = try self.readLine();
            if (isNotification(self.allocator, line)) {
                self.allocator.free(line);
                continue;
            }
            defer self.allocator.free(line);
            return parseResponse(self.allocator, line);
        }
    }

    /// Send a JSON-RPC notification (no id, no response awaited).
    pub fn notify(self: *Connection, method: []const u8, params_json: ?[]const u8) !void {
        const line = if (params_json) |p|
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, p })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}\n", .{method});
        defer self.allocator.free(line);
        const stdin = self.child.stdin orelse return error.McpServerClosed;
        try stdin.writeAll(line);
    }

    /// MCP lifecycle handshake: `initialize` request, then the required
    /// `notifications/initialized` notification.
    pub fn initialize(self: *Connection) !void {
        const params = "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"WispTerm\",\"version\":\"0\"}}";
        const resp = try self.call("initialize", params);
        defer freeResponse(self.allocator, resp);
        if (resp == .err) return error.McpInitializeFailed;
        try self.notify("notifications/initialized", null);
    }

    /// List the server's tools.
    pub fn listTools(self: *Connection) ![]ToolDef {
        const resp = try self.call("tools/list", null);
        defer freeResponse(self.allocator, resp);
        return switch (resp) {
            .err => error.McpServerError,
            .ok => |raw| parseToolsListResult(self.allocator, raw),
        };
    }

    /// Call one tool and return its flattened text result (owned). A JSON-RPC
    /// error becomes a readable `[mcp error] ...` string rather than failing.
    pub fn callTool(self: *Connection, name: []const u8, arguments_json: []const u8) ![]u8 {
        const params = try toolsCallParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        const resp = try self.call("tools/call", params);
        defer freeResponse(self.allocator, resp);
        return switch (resp) {
            .err => |m| std.fmt.allocPrint(self.allocator, "[mcp error] {s}", .{m}),
            .ok => |raw| parseToolCallResult(self.allocator, raw),
        };
    }
};

test "Connection round-trips initialize, tools/list and tools/call against a real server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;

    // A canned MCP server: print three JSON-RPC responses, then `exec cat` so
    // the process stays alive (keeps our stdin write-end open) until deinit
    // kills it. Single-quoted in sh — the JSON has no single quotes.
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo text\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const call_line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello from mcp\"}],\"isError\":false}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "' '" ++ call_line ++ "'; exec cat >/dev/null";

    var conn = try Connection.spawn(a, &.{ "/bin/sh", "-c", script });
    defer conn.deinit();

    try conn.initialize();

    const tools = try conn.listTools();
    defer freeToolDefs(a, tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("echo", tools[0].name);

    const out = try conn.callTool("echo", "{\"text\":\"hi\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("hello from mcp", out);
}
