//! 飞书 REST client — M2.4.
//! Covers: tenant_access_token, TokenCache, discoverWsEndpoint, sendText,
//! getBotOpenId.  Long-connection / frame logic lives in M2.7 (ws.zig).
//!
//! Security invariants (must never be broken):
//!   • app_secret, tenant_access_token and the wss URL query are NEVER
//!     printed, logged or written to disk.
//!   • Only host+path of the wss URL may appear in logs.

const std = @import("std");
const types = @import("types.zig");

const log = std.log.scoped(.feishu_rest);

const BASE = "https://open.feishu.cn";

// ---------------------------------------------------------------------------
// Pure helpers (unit-testable without network)
// ---------------------------------------------------------------------------

/// Returns true when the cached token should be refreshed.
/// Refresh threshold: remaining lifetime < 30 minutes.
pub fn needsRefresh(expiry_s: i64, now_s: i64) bool {
    return expiry_s - now_s < 30 * 60;
}

/// Builds the `content` JSON string for a text message, e.g.
/// `{"text":"hello \"world\""}`.  Caller owns the returned slice.
pub fn buildTextContent(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    // std.json.Stringify.valueAlloc is the correct 0.15.2 API for alloc-based
    // JSON serialisation (see src/weixin/ilink_codec.zig for precedent).
    return std.json.Stringify.valueAlloc(alloc, .{ .text = text }, .{});
}

// ---------------------------------------------------------------------------
// tenant_access_token
// ---------------------------------------------------------------------------

pub const TokenResult = struct {
    /// Caller owns this slice; free with the same allocator.
    token: []u8,
    /// Absolute Unix timestamp (seconds) at which the token expires.
    expire_s: i64,
};

/// Fetches a new tenant_access_token from the Feishu auth endpoint.
/// On success the caller owns `result.token`.  On failure an error is
/// returned; error details are logged but the secret is never printed.
pub fn tenantAccessToken(alloc: std.mem.Allocator, creds: types.Credentials) !TokenResult {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build body — app_secret handled via std.json so special chars are safe.
    const body = try std.json.Stringify.valueAlloc(a, .{
        .app_id = creds.app_id,
        .app_secret = creds.app_secret,
    }, .{});

    const resp = try httpsPost(alloc, a, BASE ++ "/open-apis/auth/v3/tenant_access_token/internal", body);

    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        tenant_access_token: []const u8 = "",
        expire: i64 = 0,
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (parsed.code != 0) {
        // Log code + msg but NOT the secret or token.
        log.err("tenant_access_token failed: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuTokenFailed;
    }

    const now = std.time.timestamp();
    return .{
        .token = try alloc.dupe(u8, parsed.tenant_access_token),
        .expire_s = now + parsed.expire,
    };
}

// ---------------------------------------------------------------------------
// TokenCache
// ---------------------------------------------------------------------------

pub const TokenCache = struct {
    token: ?[]u8 = null,
    /// Absolute Unix expiry timestamp (0 = no cached token).
    expiry_s: i64 = 0,
    mu: std.Thread.Mutex = .{},

    /// Returns the cached token if still fresh, otherwise fetches a new one.
    /// The returned slice is valid until the next call to `get` or `deinit`.
    /// Caller must NOT free it — the cache owns it.
    pub fn get(self: *TokenCache, alloc: std.mem.Allocator, creds: types.Credentials) ![]const u8 {
        self.mu.lock();
        defer self.mu.unlock();

        const now = std.time.timestamp();
        if (self.token) |tok| {
            if (!needsRefresh(self.expiry_s, now)) return tok;
        }

        // Fetch outside the lock is better for production but M2 is single-
        // threaded on the WS path; keep it simple.
        // ponytail: single-lock fetch — fine for M2 serial WS loop; upgrade to
        // double-checked if high concurrency matters.
        const result = try tenantAccessToken(alloc, creds);

        if (self.token) |old| alloc.free(old);
        self.token = result.token;
        self.expiry_s = result.expire_s;
        return self.token.?;
    }

    pub fn deinit(self: *TokenCache, alloc: std.mem.Allocator) void {
        if (self.token) |tok| alloc.free(tok);
        self.token = null;
    }
};

// ---------------------------------------------------------------------------
// discoverWsEndpoint
// ---------------------------------------------------------------------------

pub const WsEndpoint = struct {
    /// Full wss:// URL including query (contains connection token).
    /// Caller owns this slice.  MUST NOT be logged in full.
    url: []u8,
    ping_interval_s: i64,
};

/// Discovers the WebSocket endpoint for long-connection.
/// The returned `url` is owned by the caller.
/// SECURITY: the URL's query carries a session token — never log it.
pub fn discoverWsEndpoint(alloc: std.mem.Allocator, creds: types.Credentials) !WsEndpoint {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Keys MUST be capitalised per SDK convention; lowercase → code 514.
    const body = try std.json.Stringify.valueAlloc(a, .{
        .AppID = creds.app_id,
        .AppSecret = creds.app_secret,
    }, .{});

    const resp = try httpsPost(alloc, a, BASE ++ "/callback/ws/endpoint", body);

    const ClientConfig = struct {
        PingInterval: i64 = 0,
    };
    const Data = struct {
        URL: []const u8 = "",
        ClientConfig: ClientConfig = .{},
    };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: Data = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    switch (parsed.code) {
        0 => {},
        514 => {
            log.err("discoverWsEndpoint: AuthFailed (code=514) msg={s}", .{parsed.msg});
            return error.FeishuWsAuthFailed;
        },
        1000040350 => {
            log.err("discoverWsEndpoint: ExceedConnLimit (code=1000040350) msg={s}", .{parsed.msg});
            return error.FeishuWsExceedConnLimit;
        },
        else => {
            log.err("discoverWsEndpoint: code={d} msg={s}", .{ parsed.code, parsed.msg });
            return error.FeishuWsEndpointFailed;
        },
    }

    // Log only host+path, never the query (which carries the session token).
    const safe_url = stripQuery(parsed.data.URL);
    log.info("discoverWsEndpoint: ok url_host_path={s}", .{safe_url});

    const ping_ms = parsed.data.ClientConfig.PingInterval;
    // PingInterval in the protocol notes is in milliseconds.
    const ping_s = @divTrunc(ping_ms, 1000);

    return .{
        .url = try alloc.dupe(u8, parsed.data.URL),
        .ping_interval_s = ping_s,
    };
}

// ---------------------------------------------------------------------------
// sendText
// ---------------------------------------------------------------------------

/// Sends a plain-text message via the Feishu IM v1 API.
/// `receive_id_type` is one of: "open_id", "user_id", "union_id", "email",
/// "chat_id".
pub fn sendText(
    alloc: std.mem.Allocator,
    token: []const u8,
    receive_id_type: []const u8,
    receive_id: []const u8,
    text: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const content = try buildTextContent(a, text);

    // Feishu IM v1: `content` field must be a JSON-encoded string whose value
    // is itself JSON (e.g. "{\"text\":\"hi\"}").  std.json.Stringify.valueAlloc
    // ensures both receive_id and content get proper quoting/escaping.
    const body_str = try std.json.Stringify.valueAlloc(a, .{
        .receive_id = receive_id,
        .msg_type = @as([]const u8, "text"),
        .content = content,
    }, .{});

    const url = try std.fmt.allocPrint(a,
        BASE ++ "/open-apis/im/v1/messages?receive_id_type={s}",
        .{receive_id_type},
    );

    try httpsPostWithBearer(alloc, a, url, token, body_str);
}

// ---------------------------------------------------------------------------
// getBotOpenId
// ---------------------------------------------------------------------------

/// Returns the bot's open_id.  Caller owns the returned slice.
pub fn getBotOpenId(alloc: std.mem.Allocator, token: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const resp = try httpsGetWithBearer(alloc, a, BASE ++ "/open-apis/bot/v3/info", token);

    const BotInfo = struct {
        open_id: []const u8 = "",
    };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        bot: BotInfo = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (parsed.code != 0) {
        log.err("getBotOpenId: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuBotInfoFailed;
    }

    return alloc.dupe(u8, parsed.bot.open_id);
}

// ---------------------------------------------------------------------------
// Internal HTTP helpers
// ---------------------------------------------------------------------------

fn httpsPost(
    client_alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json; charset=utf-8" } },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        log.warn("POST {s} -> HTTP {}", .{ endpointForLog(url), response.status });
        return error.FeishuHttpError;
    }
    return out.toArrayList().items;
}

fn httpsPostWithBearer(
    client_alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
) !void {
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();

    // Build "Bearer <token>" in the arena; never store or print token itself.
    const auth = try std.fmt.allocPrint(resp_arena, "Bearer {s}", .{token});

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json; charset=utf-8" },
            .authorization = .{ .override = auth },
        },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        log.warn("POST {s} -> HTTP {}", .{ endpointForLog(url), response.status });
        return error.FeishuHttpError;
    }

    // Parse for API-level errors.
    const items = out.toArrayList().items;
    const Resp = struct { code: i64 = -1, msg: []const u8 = "" };
    const parsed = std.json.parseFromSliceLeaky(Resp, resp_arena, items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return; // best-effort; HTTP 200 is authoritative
    if (parsed.code != 0) {
        log.err("sendText: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuSendTextFailed;
    }
}

fn httpsGetWithBearer(
    client_alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();

    const auth = try std.fmt.allocPrint(resp_arena, "Bearer {s}", .{token});

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .authorization = .{ .override = auth } },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        log.warn("GET {s} -> HTTP {}", .{ endpointForLog(url), response.status });
        return error.FeishuHttpError;
    }
    return out.toArrayList().items;
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

/// Returns slice of `url` up to (but not including) '?', for safe logging.
fn stripQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..q];
}

/// Strips query from a URL for safe log output.
fn endpointForLog(url: []const u8) []const u8 {
    return stripQuery(url);
}

// ---------------------------------------------------------------------------
// Offline unit tests (no network)
// ---------------------------------------------------------------------------

test "needsRefresh: more than 30min remaining → false" {
    // 31 minutes remaining
    try std.testing.expect(!needsRefresh(1000 + 31 * 60, 1000));
}

test "needsRefresh: exactly 30min remaining → false (boundary, strict <)" {
    // Threshold is strict < 30min, so exactly 30min remaining is still fresh.
    try std.testing.expect(!needsRefresh(1000 + 30 * 60, 1000));
}

test "needsRefresh: one second under 30min remaining → true" {
    try std.testing.expect(needsRefresh(1000 + 30 * 60 - 1, 1000));
}

test "needsRefresh: less than 30min remaining → true" {
    try std.testing.expect(needsRefresh(1000 + 29 * 60, 1000));
}

test "needsRefresh: already expired → true" {
    try std.testing.expect(needsRefresh(999, 1000));
}

test "buildTextContent: plain text" {
    const content = try buildTextContent(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\"text\":\"hello world\"}", content);
}

test "buildTextContent: text with quotes and newline" {
    const content = try buildTextContent(std.testing.allocator, "say \"hi\"\nnext");
    defer std.testing.allocator.free(content);
    // std.json encodes " as \" and \n as \n
    try std.testing.expectEqualStrings("{\"text\":\"say \\\"hi\\\"\\nnext\"}", content);
}

test "buildTextContent: empty text" {
    const content = try buildTextContent(std.testing.allocator, "");
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\"text\":\"\"}", content);
}
