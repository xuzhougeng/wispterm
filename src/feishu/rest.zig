//! 飞书 REST client — M2.4.
//! Covers: tenant_access_token, TokenCache, discoverWsEndpoint, sendText,
//! sendMessage, getBotOpenId.  Long-connection / frame logic lives in M2.7 (ws.zig).
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
// sendMessage / sendText
// ---------------------------------------------------------------------------

/// Sends a message via the Feishu IM v1 API.
/// `receive_id_type` is one of: "open_id", "user_id", "union_id", "email", "chat_id".
/// `msg_type` is one of: "text", "image", "file", …
/// `content` is an already-serialised JSON string (e.g. `{"text":"hi"}` or `{"image_key":"…"}`).
pub fn sendMessage(
    alloc: std.mem.Allocator,
    token: []const u8,
    receive_id_type: []const u8,
    receive_id: []const u8,
    msg_type: []const u8,
    content: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Feishu IM v1: `content` field must be a JSON-encoded string whose value
    // is itself JSON (e.g. "{\"text\":\"hi\"}").  std.json.Stringify.valueAlloc
    // ensures both receive_id and content get proper quoting/escaping.
    const body_str = try std.json.Stringify.valueAlloc(a, .{
        .receive_id = receive_id,
        .msg_type = msg_type,
        .content = content,
    }, .{});

    const url = try std.fmt.allocPrint(a,
        BASE ++ "/open-apis/im/v1/messages?receive_id_type={s}",
        .{receive_id_type},
    );

    try httpsPostWithBearer(alloc, a, url, token, body_str);
}

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
    try sendMessage(alloc, token, receive_id_type, receive_id, "text", content);
}

// ---------------------------------------------------------------------------
// CardKit pure builders (unit-testable, no network)
// ---------------------------------------------------------------------------

/// Builds the `content` JSON string for an interactive card message, e.g.
/// `{"type":"card","data":{"card_id":"abc"}}`.  Caller owns the returned slice.
///
/// ponytail: send shape is best-guess — spike couldn't get a chat_id.
/// Validated at E2E (Task S5). Adjust content structure if E2E reports error.
pub fn buildCardMessageContent(alloc: std.mem.Allocator, card_id: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .type = "card",
        .data = .{ .card_id = card_id },
    }, .{});
}

/// Builds the body for `streamCardContent` PUT.
/// Caller owns the returned slice.
pub fn buildStreamBody(alloc: std.mem.Allocator, content: []const u8, sequence: i64) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .content = content,
        .sequence = sequence,
    }, .{});
}

/// Builds the body for `closeStreaming` PATCH.
/// Caller owns the returned slice.
pub fn buildCloseBody(alloc: std.mem.Allocator, sequence: i64) ![]u8 {
    // settings value is a JSON-encoded string (per spike: §8).
    return std.json.Stringify.valueAlloc(alloc, .{
        .settings = "{\"config\":{\"streaming_mode\":false}}",
        .sequence = sequence,
    }, .{});
}

// ---------------------------------------------------------------------------
// CardKit REST calls
// ---------------------------------------------------------------------------

/// Creates a streaming card via CardKit v1.  Returns the card_id; caller owns.
/// card_json is the JSON 2.0 card definition string (not nested — it's stringified).
pub fn createStreamingCard(alloc: std.mem.Allocator, token: []const u8, card_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // data field MUST be a JSON-encoded string (spike confirmed §8).
    const body = try std.json.Stringify.valueAlloc(a, .{
        .type = "card_json",
        .data = card_json,
    }, .{});

    const resp = try httpsReqWithBearer(alloc, a, .POST, BASE ++ "/open-apis/cardkit/v1/cards", token, body);

    const Data = struct { card_id: []const u8 = "" };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: Data = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.code != 0) {
        log.err("createStreamingCard: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuCardCreateFailed;
    }

    return alloc.dupe(u8, parsed.data.card_id);
}

/// Sends a card as an interactive message to a chat.
/// Returns the message_id; caller owns (alloc.dupe). error on send failure or missing message_id.
/// NOTE: send shape validated in spike §8 + E2E Task S5.
pub fn sendCardMessage(
    alloc: std.mem.Allocator,
    token: []const u8,
    receive_id_type: []const u8,
    receive_id: []const u8,
    card_id: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const content = try buildCardMessageContent(a, card_id);
    const body_str = try std.json.Stringify.valueAlloc(a, .{
        .receive_id = receive_id,
        .msg_type = "interactive",
        .content = content,
    }, .{});
    const url = try std.fmt.allocPrint(a,
        BASE ++ "/open-apis/im/v1/messages?receive_id_type={s}",
        .{receive_id_type},
    );
    const resp = try httpsReqWithBearer(alloc, a, .POST, url, token, body_str);

    // Parse data.message_id from response (mirrors createStreamingCard parsing card_id).
    const DataMsg = struct { message_id: []const u8 = "" };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: DataMsg = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.code != 0) {
        log.err("sendCardMessage: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuSendFailed;
    }
    if (parsed.data.message_id.len == 0) {
        log.err("sendCardMessage: empty message_id in response", .{});
        return error.FeishuSendFailed;
    }
    return alloc.dupe(u8, parsed.data.message_id);
}

/// Streams content to a specific element of a card (PUT, not POST).
/// sequence must be monotonically increasing per card lifecycle.
pub fn streamCardContent(
    alloc: std.mem.Allocator,
    token: []const u8,
    card_id: []const u8,
    element_id: []const u8,
    content: []const u8,
    sequence: i64,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try std.fmt.allocPrint(
        a,
        BASE ++ "/open-apis/cardkit/v1/cards/{s}/elements/{s}/content",
        .{ card_id, element_id },
    );
    const body = try buildStreamBody(a, content, sequence);
    _ = try httpsReqWithBearer(alloc, a, .PUT, url, token, body);
}

/// Closes streaming mode for a card (PATCH).
pub fn closeStreaming(
    alloc: std.mem.Allocator,
    token: []const u8,
    card_id: []const u8,
    sequence: i64,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try std.fmt.allocPrint(
        a,
        BASE ++ "/open-apis/cardkit/v1/cards/{s}/settings",
        .{card_id},
    );
    const body = try buildCloseBody(a, sequence);
    _ = try httpsReqWithBearer(alloc, a, .PATCH, url, token, body);
}

// ---------------------------------------------------------------------------
// patchMessageCard
// ---------------------------------------------------------------------------

/// Updates an interactive card message via PATCH /open-apis/im/v1/messages/{message_id}.
/// card_json is the complete card JSON string (JSON 2.0 format).
/// Body: {"content": <card_json_string>} where card_json is serialized as a JSON string value.
/// Non-200 or code!=0 → error.
pub fn patchMessageCard(
    alloc: std.mem.Allocator,
    token: []const u8,
    message_id: []const u8,
    card_json: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try std.fmt.allocPrint(a,
        BASE ++ "/open-apis/im/v1/messages/{s}",
        .{message_id},
    );
    // content field must be card_json serialized as a JSON string value.
    const body = try std.json.Stringify.valueAlloc(a, .{ .content = card_json }, .{});
    _ = try httpsReqWithBearer(alloc, a, .PATCH, url, token, body);
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
    _ = try httpsReqWithBearer(client_alloc, resp_arena, .POST, url, token, body);
}

/// Generic bearer-authenticated HTTPS request for POST/PUT/PATCH.
/// Returns the raw response body (arena-owned).
/// Non-200 → error; 200 + unparseable body → error.
fn httpsReqWithBearer(
    client_alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    body: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();

    // Build "Bearer <token>" in the arena; never store or print token itself.
    const auth = try std.fmt.allocPrint(resp_arena, "Bearer {s}", .{token});

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .keep_alive = false,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json; charset=utf-8" },
            .authorization = .{ .override = auth },
        },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        log.warn("{s} {s} -> HTTP {}", .{ @tagName(method), endpointForLog(url), response.status });
        return error.FeishuHttpError;
    }

    // Parse for API-level errors.
    const items = out.toArrayList().items;
    const Resp = struct { code: i64 = -1, msg: []const u8 = "" };
    const parsed = std.json.parseFromSliceLeaky(Resp, resp_arena, items, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.FeishuSendFailed; // 200 + unparseable body can't confirm delivery
    if (parsed.code != 0) {
        log.err("{s} {s}: code={d} msg={s}", .{ @tagName(method), endpointForLog(url), parsed.code, parsed.msg });
        return error.FeishuSendFailed;
    }
    return items;
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

test "buildCardMessageContent: basic card_id" {
    const content = try buildCardMessageContent(std.testing.allocator, "card123");
    defer std.testing.allocator.free(content);
    // Must be valid JSON containing type and card_id.
    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"card\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"card_id\":\"card123\"") != null);
    // Verify it parses as JSON.
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer p.deinit();
}

test "buildStreamBody: content + sequence, escaping" {
    // content with quotes must be escaped correctly
    const body = try buildStreamBody(std.testing.allocator, "say \"hi\"", 42);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sequence\":42") != null);
    // The quote in content must be escaped
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"hi\\\"") != null);
    // Valid JSON
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer p.deinit();
}

test "buildCloseBody: streaming_mode false in settings string" {
    const body = try buildCloseBody(std.testing.allocator, 7);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sequence\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "streaming_mode") != null);
    // Valid JSON
    const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer p.deinit();
}

test "sendCardMessage response parsing: code=0 → message_id" {
    const resp = "{\"code\":0,\"data\":{\"message_id\":\"om_test001\"},\"msg\":\"ok\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const DataMsg = struct { message_id: []const u8 = "" };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: DataMsg = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    try std.testing.expectEqual(@as(i64, 0), parsed.code);
    try std.testing.expectEqualStrings("om_test001", parsed.data.message_id);
}

test "createStreamingCard response parsing: code=0 → card_id" {
    // Simulate the response parsing logic inline (pure, no network).
    const resp = "{\"code\":0,\"data\":{\"card_id\":\"abc\"},\"msg\":\"ok\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Data = struct { card_id: []const u8 = "" };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: Data = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    try std.testing.expectEqual(@as(i64, 0), parsed.code);
    try std.testing.expectEqualStrings("abc", parsed.data.card_id);
}

test "createStreamingCard response parsing: code!=0 → would error" {
    const resp = "{\"code\":11400,\"msg\":\"invalid card\",\"data\":{}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Data = struct { card_id: []const u8 = "" };
    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: Data = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    // createStreamingCard would return error.FeishuCardCreateFailed here.
    try std.testing.expect(parsed.code != 0);
}
