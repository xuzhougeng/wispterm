//! Session-free LLM client for the memory digest (spec §8). Request JSON,
//! endpoint routing and response parsing reuse the assistant protocol layer;
//! the HTTP call mirrors assistant/conversation/request.zig's
//! runChatRequestForMessages (Bearer vs x-api-key, 16KB buffer, blocking).
//! `Client.complete` is network glue with no unit test here — its components
//! (protocol.buildRequestJson/apiEndpoint/parseApiResponse) are tested in
//! place; real-network verification happens in Task 7.
//!
//! M5 Task 1: `complete()` uses the request-level `std.http.Client` API
//! (not `fetch()`) so a per-request read/write timeout can be applied to the
//! underlying socket via SO_RCVTIMEO/SO_SNDTIMEO before the body is sent.
//! `fetch()` has no timeout knob in 0.15.2 — a hung server would block the
//! digest scheduler thread forever otherwise (spec A.4 fallback: if this
//! field chain had not compiled, we'd revert to fetch() + document the
//! scheduler-thread detach as the only starvation guard; it did compile, see
//! below).
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("../assistant/conversation/protocol.zig");
const profile_codec = @import("../renderer/overlays/profile_codec.zig");

pub const Completer = struct {
    ctx: *anyopaque,
    completeFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8,

    pub fn complete(self: Completer, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        return self.completeFn(self.ctx, gpa, system_prompt, user_text);
    }
};

pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    protocol: protocol.ApiProtocol,
    max_tokens: u32 = 4096,
    /// Read/write timeout applied to the request socket (spec M5 Task 1).
    timeout_seconds: u32 = 120,
};

pub const Client = struct {
    config: Config,
    /// Running total of token usage across every `complete()` call made
    /// through this client (spec M5 Task 1 B.1). Callers read this after a
    /// run to persist it into store.RunRecord — never reset mid-run.
    total_usage: protocol.ApiUsage = .{},

    pub fn completer(self: *Client) Completer {
        return .{ .ctx = self, .completeFn = completeShim };
    }

    fn completeShim(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        const self: *Client = @ptrCast(@alignCast(ctx));
        return self.complete(gpa, system_prompt, user_text);
    }

    pub fn complete(self: *Client, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        const config = self.config;
        const params = protocol.RequestParams{
            .model = config.model,
            .system_prompt = system_prompt,
            .protocol = config.protocol,
            .thinking_enabled = false,
            .reasoning_effort = "",
            .stream = false,
            .max_tokens = config.max_tokens,
        };

        const content = try gpa.dupe(u8, user_text);
        defer gpa.free(content);
        var messages = [_]protocol.RequestMessage{.{ .role = .user, .content = content }};

        const body = try protocol.buildRequestJson(gpa, params, &messages, false);
        defer gpa.free(body);

        const endpoint = try protocol.apiEndpoint(gpa, config.base_url, config.protocol);
        defer gpa.free(endpoint);

        const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{config.api_key});
        defer gpa.free(bearer);

        var client: std.http.Client = .{
            .allocator = gpa,
            .write_buffer_size = 16384,
        };
        defer client.deinit();

        const is_anthropic = config.protocol == .anthropic;
        const anthropic_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = config.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };

        const uri = try std.Uri.parse(endpoint);

        var req = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (is_anthropic) .omit else .{ .override = bearer },
            },
            .extra_headers = if (is_anthropic) &anthropic_headers else &.{},
        }) catch |err| {
            std.log.warn("memory_digest: llm request connect failed (model={s}): {s}", .{ config.model, @errorName(err) });
            return err;
        };
        defer req.deinit();

        setRequestTimeout(&req, config.timeout_seconds);

        var timer = try std.time.Timer.start();

        req.transfer_encoding = .{ .content_length = body.len };
        req.sendBodyComplete(@constCast(body)) catch |err| {
            if (isTimeoutError(err)) {
                std.log.warn("memory_digest: llm request timed out sending body (model={s}, limit={d}s)", .{ config.model, config.timeout_seconds });
                return error.LlmTimeout;
            }
            return err;
        };

        // Reuses fetch()'s own redirect_buffer sizing (8KB) since
        // redirect_behavior is `.unhandled` here and this buffer is unused
        // in that mode, but receiveHead still requires a slice.
        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            if (isTimeoutError(err)) {
                std.log.warn("memory_digest: llm request timed out waiting for response head (model={s}, limit={d}s)", .{ config.model, config.timeout_seconds });
                return error.LlmTimeout;
            }
            return err;
        };

        var resp_buf: std.Io.Writer.Allocating = .init(gpa);
        defer resp_buf.deinit();

        var transfer_buffer: [64]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        _ = body_reader.streamRemaining(&resp_buf.writer) catch |err| switch (err) {
            error.ReadFailed => {
                const body_err = response.bodyErr().?;
                if (isTimeoutError(body_err)) {
                    std.log.warn("memory_digest: llm request timed out reading body (model={s}, limit={d}s, elapsed_ms={d})", .{ config.model, config.timeout_seconds, timer.read() / std.time.ns_per_ms });
                    return error.LlmTimeout;
                }
                return body_err;
            },
            else => |e| return e,
        };

        var resp_list = resp_buf.toArrayList();
        defer resp_list.deinit(gpa);

        if (response.head.status != .ok) return error.LlmHttpError;

        var api_result = try protocol.parseApiResponse(gpa, resp_list.items, config.protocol);
        if (api_result.api_error) {
            api_result.deinit(gpa);
            return error.LlmApiError;
        }
        if (api_result.usage) |usage| self.total_usage.add(usage);
        if (api_result.reasoning) |reasoning| gpa.free(reasoning);
        if (api_result.tool_calls) |calls| {
            for (calls) |call| call.deinit(gpa);
            gpa.free(calls);
        }
        return api_result.content;
    }
};

/// True when `err` (or, for the body-read path, the more specific
/// `http.Reader.BodyError`) is the WouldBlock surfaced by a SO_RCVTIMEO /
/// SO_SNDTIMEO expiry on a blocking socket (see `setRequestTimeout`).
fn isTimeoutError(err: anyerror) bool {
    return err == error.WouldBlock;
}

/// Applies `timeout_seconds` as a receive+send timeout on the request's
/// underlying socket (macOS/Linux/BSD via SO_RCVTIMEO/SO_SNDTIMEO — both
/// take a `timeval` on every posix target Zig supports desktop-side).
///
/// `std.http.Client` has no built-in request timeout in 0.15.2 (`fetch()`
/// can block forever on a stalled server), so this reaches through
/// `Request.connection.?.stream_reader.getStream().handle` to the raw fd and
/// sets the option directly. Every field on this chain is public in 0.15.2
/// (only some *functions* on Connection are file-private), so this compiles
/// without touching anything std marks private.
///
/// Windows has no SO_RCVTIMEO/SNDTIMEO with a `timeval` layout (it wants a
/// DWORD milliseconds) and this module only ships on desktop hosts running
/// the memory-digest scheduler (macOS/Linux dev today); a Windows branch is
/// intentionally deferred rather than guessed at blind.
/// TODO(windows): setsockopt(SOL_SOCKET, SO_RCVTIMEO/SNDTIMEO, DWORD ms) via
/// ws2_32 once this scheduler ships on Windows.
fn setRequestTimeout(req: *std.http.Client.Request, timeout_seconds: u32) void {
    if (builtin.os.tag == .windows) return; // ponytail: TODO above, no Windows caller yet.
    if (timeout_seconds == 0) return;

    const connection = req.connection orelse return;
    const stream = connection.stream_reader.getStream();
    const tv: std.posix.timeval = .{ .sec = @intCast(timeout_seconds), .usec = 0 };
    const tv_bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes) catch |err| {
        std.log.warn("memory_digest: failed to set RCVTIMEO: {s}", .{@errorName(err)});
    };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes) catch |err| {
        std.log.warn("memory_digest: failed to set SNDTIMEO: {s}", .{@errorName(err)});
    };
}

/// Picks the profile matching `name`, falling back to the first profile when
/// `name` is empty or not found. Returns null when there are no profiles.
/// Logging the "name not found, using first" fallback is the caller's job.
pub fn pickProfile(profiles: []const profile_codec.AiProfile, count: usize, name: []const u8) ?usize {
    if (count == 0) return null;
    if (name.len == 0) return 0;
    for (profiles[0..count], 0..) |*p, i| {
        if (std.mem.eql(u8, profile_codec.aiProfileField(p, .name), name)) return i;
    }
    return 0;
}

/// Builds a Config from a stored AiProfile, duping string fields into `arena`.
pub fn configFromProfile(arena: std.mem.Allocator, profile: *const profile_codec.AiProfile) !Config {
    const max_tokens_str = profile_codec.aiProfileField(profile, .max_tokens);
    const max_tokens: u32 = if (max_tokens_str.len == 0)
        4096
    else
        std.fmt.parseInt(u32, max_tokens_str, 10) catch 4096;

    return Config{
        .base_url = try arena.dupe(u8, profile_codec.aiProfileField(profile, .base_url)),
        .api_key = try arena.dupe(u8, profile_codec.aiProfileField(profile, .api_key)),
        .model = try arena.dupe(u8, profile_codec.aiProfileField(profile, .model)),
        .protocol = protocol.ApiProtocol.parse(profile_codec.aiProfileField(profile, .protocol)),
        .max_tokens = max_tokens,
    };
}

fn testProfile(name: []const u8, model: []const u8, proto: []const u8, max_tokens: []const u8) profile_codec.AiProfile {
    var p: profile_codec.AiProfile = .{};
    setField(&p, .name, name);
    setField(&p, .base_url, "https://api.example.com/v1");
    setField(&p, .api_key, "k");
    setField(&p, .model, model);
    setField(&p, .protocol, proto);
    setField(&p, .max_tokens, max_tokens);
    return p;
}

fn setField(p: *profile_codec.AiProfile, field: profile_codec.AiField, value: []const u8) void {
    const idx: usize = @intFromEnum(field);
    @memcpy(p.fields[idx][0..value.len], value);
    p.lens[idx] = value.len;
}

test "memory_digest_llm: pickProfile by name with first as fallback" {
    var profiles = [_]profile_codec.AiProfile{ testProfile("a", "m1", "", "8192"), testProfile("b", "m2", "anthropic", "") };
    try std.testing.expectEqual(@as(?usize, 1), pickProfile(&profiles, 2, "b"));
    try std.testing.expectEqual(@as(?usize, 0), pickProfile(&profiles, 2, ""));
    try std.testing.expectEqual(@as(?usize, 0), pickProfile(&profiles, 2, "missing")); // fallback first + log by caller
    try std.testing.expectEqual(@as(?usize, null), pickProfile(&profiles, 0, ""));
}

test "memory_digest_llm: configFromProfile parses protocol and max_tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = testProfile("a", "deepseek-v4", "anthropic", "9000");
    const cfg = try configFromProfile(arena.allocator(), &p);
    try std.testing.expectEqualStrings("deepseek-v4", cfg.model);
    try std.testing.expectEqual(protocol.ApiProtocol.anthropic, cfg.protocol);
    try std.testing.expectEqual(@as(u32, 9000), cfg.max_tokens);
    var p2 = testProfile("a", "m", "", "");
    const cfg2 = try configFromProfile(arena.allocator(), &p2);
    try std.testing.expectEqual(protocol.ApiProtocol.chat_completions, cfg2.protocol);
    try std.testing.expectEqual(@as(u32, 4096), cfg2.max_tokens);
}
