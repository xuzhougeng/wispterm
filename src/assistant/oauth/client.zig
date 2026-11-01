//! Device-code login and refresh for Codex, Kimi Code, and xAI subscriptions.
//! Tokens are stored by `store.zig`. Request threads call `resolve` and never
//! log access tokens, refresh tokens, or device codes.
const std = @import("std");
const builtin = @import("builtin");
const ai_chat_protocol = @import("../conversation/protocol.zig");
const codec = @import("codec.zig");
const store = @import("store.zig");

const codex_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
const codex_token_url = "https://auth.openai.com/oauth/token";
const codex_device_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const codex_device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token";
const codex_device_verification = "https://auth.openai.com/codex/device";
const codex_device_redirect = "https://auth.openai.com/deviceauth/callback";

const kimi_client_id = "17e5f671-d194-4dfb-9706-5516cb48c098";
const kimi_oauth_host_default = "https://auth.kimi.com";

const xai_client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const xai_scope = "openid profile email offline_access grok-cli:access api:access";
const xai_device_url = "https://auth.x.ai/oauth2/device/code";
const xai_token_url = "https://auth.x.ai/oauth2/token";

pub const Prompt = struct {
    ctx: *anyopaque,
    show: *const fn (ctx: *anyopaque, url: []const u8, user_code: []const u8) void,
    cancelled: *const fn (ctx: *anyopaque) bool,
    /// Short, non-secret failure text. Called before `login` returns `LoginFailed`.
    note: *const fn (ctx: *anyopaque, message: []const u8) void,
};

pub const Access = struct {
    token: []u8,
    account_id: []u8,

    pub fn deinit(self: Access, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.account_id);
    }
};

pub fn providerOf(protocol: ai_chat_protocol.ApiProtocol) ?codec.Provider {
    return switch (protocol) {
        .codex => .codex,
        .kimi => .kimi,
        .xai => .xai,
        else => null,
    };
}

pub fn failureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotSignedIn => "Sign in to this subscription from the AI profile (Sign in row).",
        error.RefreshFailed => "Subscription sign-in expired. Open the AI profile and sign in again.",
        else => "Subscription sign-in failed.",
    };
}

/// Access token for one request. Subscription protocols use the stored OAuth
/// token (refreshed when it is near expiry). Kimi and xAI fall back to the
/// profile API key when no subscription is stored. Codex requires OAuth.
pub fn resolve(allocator: std.mem.Allocator, protocol: ai_chat_protocol.ApiProtocol, profile_key: []const u8) !Access {
    const provider = providerOf(protocol) orelse {
        return accessFromKey(allocator, profile_key, "");
    };
    if (store.copy(allocator, provider)) |cred| {
        defer cred.deinit(allocator);
        const fresh = if (codec.needsRefresh(cred.expires_ms, std.time.milliTimestamp()))
            try refresh(allocator, provider, cred.refresh)
        else
            null;
        defer if (fresh) |owned| owned.deinit(allocator);
        const token_src = if (fresh) |owned| owned.access else cred.access;
        const account = if (provider == .codex)
            codec.chatgptAccountId(allocator, token_src) catch return error.RefreshFailed
        else
            try allocator.dupe(u8, "");
        errdefer allocator.free(account);
        const token = try allocator.dupe(u8, token_src);
        return .{ .token = token, .account_id = account };
    }
    if (provider != .codex and profile_key.len > 0) return accessFromKey(allocator, profile_key, "");
    return error.NotSignedIn;
}

pub fn login(allocator: std.mem.Allocator, provider: codec.Provider, prompt: Prompt) !codec.OwnedCredential {
    return switch (provider) {
        .codex => loginCodex(allocator, prompt),
        .kimi => loginKimi(allocator, prompt),
        .xai => loginXai(allocator, prompt),
    };
}

fn accessFromKey(allocator: std.mem.Allocator, key: []const u8, account: []const u8) !Access {
    const token = try allocator.dupe(u8, key);
    errdefer allocator.free(token);
    const account_id = try allocator.dupe(u8, account);
    return .{ .token = token, .account_id = account_id };
}

fn refresh(allocator: std.mem.Allocator, provider: codec.Provider, refresh_token: []const u8) !codec.OwnedCredential {
    const cred = refreshOnce(allocator, provider, refresh_token) catch |err| switch (err) {
        error.NotSignedIn => {
            store.clear(provider);
            return error.NotSignedIn;
        },
        else => return error.RefreshFailed,
    };
    store.put(provider, cred.access, cred.refresh, cred.expires_ms) catch {};
    return cred;
}

fn refreshOnce(allocator: std.mem.Allocator, provider: codec.Provider, refresh_token: []const u8) !codec.OwnedCredential {
    const body = switch (provider) {
        .codex => try formPairs(allocator, &.{
            .{ "grant_type", "refresh_token" },
            .{ "refresh_token", refresh_token },
            .{ "client_id", codex_client_id },
        }),
        .kimi => try formPairs(allocator, &.{
            .{ "client_id", kimi_client_id },
            .{ "grant_type", "refresh_token" },
            .{ "refresh_token", refresh_token },
        }),
        .xai => try formPairs(allocator, &.{
            .{ "grant_type", "refresh_token" },
            .{ "client_id", xai_client_id },
            .{ "refresh_token", refresh_token },
        }),
    };
    defer allocator.free(body);
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |owned| allocator.free(owned);
    const url: []const u8 = switch (provider) {
        .codex => codex_token_url,
        .kimi => blk: {
            const owned = try kimiUrl(allocator, "/api/oauth/token");
            owned_url = owned;
            break :blk owned;
        },
        .xai => xai_token_url,
    };
    const response = try post(allocator, null, url, "application/x-www-form-urlencoded", body);
    defer allocator.free(response.body);
    if (response.status == 401 or response.status == 403) return error.NotSignedIn;
    if (oauthErrorIs(allocator, response.body, "invalid_grant")) return error.NotSignedIn;
    if (response.status < 200 or response.status >= 300) return error.RefreshFailed;
    return codec.parseToken(allocator, response.body, refresh_token, std.time.milliTimestamp());
}

fn loginCodex(allocator: std.mem.Allocator, prompt: Prompt) !codec.OwnedCredential {
    const start_body = try post(allocator, prompt, codex_device_code_url, "application/json", "{\"client_id\":\"" ++ codex_client_id ++ "\"}");
    defer allocator.free(start_body.body);
    if (start_body.status < 200 or start_body.status >= 300) {
        noteHttpFailure(allocator, prompt, start_body.status, start_body.body);
        return error.LoginFailed;
    }
    const device = codec.parseDeviceStart(allocator, start_body.body) catch {
        noteFailure(prompt, "invalid login response");
        return error.LoginFailed;
    };
    defer device.deinit(allocator);
    prompt.show(prompt.ctx, codex_device_verification, device.user_code);

    const deadline = std.time.milliTimestamp() + 15 * 60 * 1000;
    var interval: u32 = device.interval_seconds;
    while (std.time.milliTimestamp() < deadline) {
        try waitSeconds(interval, prompt);
        const payload = try codexPollPayload(allocator, device.device_code, device.user_code);
        defer allocator.free(payload);
        const response = try post(allocator, prompt, codex_device_token_url, "application/json", payload);
        defer allocator.free(response.body);
        switch (pollDecision(allocator, response.status, response.body, true)) {
            .pending => continue,
            .slow_down => {
                interval += 5;
                continue;
            },
            .denied, .expired, .fatal => {
                noteHttpFailure(allocator, prompt, response.status, response.body);
                return error.LoginFailed;
            },
            .ok => {
                const code = jsonField(allocator, response.body, "authorization_code") orelse {
                    noteFailure(prompt, "invalid login response");
                    return error.LoginFailed;
                };
                defer allocator.free(code);
                const verifier = jsonField(allocator, response.body, "code_verifier") orelse return error.LoginFailed;
                defer allocator.free(verifier);
                return exchangeCodex(allocator, code, verifier);
            },
        }
    }
    return error.LoginFailed;
}

fn exchangeCodex(allocator: std.mem.Allocator, code: []const u8, verifier: []const u8) !codec.OwnedCredential {
    const body = try formPairs(allocator, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", codex_client_id },
        .{ "code", code },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", codex_device_redirect },
    });
    defer allocator.free(body);
    const response = try post(allocator, null, codex_token_url, "application/x-www-form-urlencoded", body);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) return error.LoginFailed;
    const cred = try codec.parseToken(allocator, response.body, null, std.time.milliTimestamp());
    errdefer cred.deinit(allocator);
    const account = codec.chatgptAccountId(allocator, cred.access) catch return error.LoginFailed;
    allocator.free(account);
    return cred;
}

fn loginKimi(allocator: std.mem.Allocator, prompt: Prompt) !codec.OwnedCredential {
    const begin = try formPairs(allocator, &.{.{ "client_id", kimi_client_id }});
    defer allocator.free(begin);
    const url = try kimiUrl(allocator, "/api/oauth/device_authorization");
    defer allocator.free(url);
    const response = try post(allocator, prompt, url, "application/x-www-form-urlencoded", begin);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) {
        noteHttpFailure(allocator, prompt, response.status, response.body);
        return error.LoginFailed;
    }
    const device = codec.parseDeviceStart(allocator, response.body) catch {
        noteFailure(prompt, "invalid login response");
        return error.LoginFailed;
    };
    defer device.deinit(allocator);
    prompt.show(prompt.ctx, device.verification_uri, device.user_code);
    return pollFormToken(allocator, prompt, device, kimiTokenFields(device.device_code));
}

fn loginXai(allocator: std.mem.Allocator, prompt: Prompt) !codec.OwnedCredential {
    const begin = try formPairs(allocator, &.{
        .{ "client_id", xai_client_id },
        .{ "scope", xai_scope },
        .{ "referrer", "wispterm" },
    });
    defer allocator.free(begin);
    const response = try post(allocator, prompt, xai_device_url, "application/x-www-form-urlencoded", begin);
    defer allocator.free(response.body);
    if (response.status < 200 or response.status >= 300) {
        noteHttpFailure(allocator, prompt, response.status, response.body);
        return error.LoginFailed;
    }
    const device = codec.parseDeviceStart(allocator, response.body) catch {
        noteFailure(prompt, "invalid login response");
        return error.LoginFailed;
    };
    defer device.deinit(allocator);
    prompt.show(prompt.ctx, device.verification_uri, device.user_code);
    return pollFormToken(allocator, prompt, device, xaiTokenFields(device.device_code));
}

const TokenFields = struct {
    url_kind: enum { kimi, xai },
    device_code: []const u8,
};

fn kimiTokenFields(device_code: []const u8) TokenFields {
    return .{ .url_kind = .kimi, .device_code = device_code };
}

fn xaiTokenFields(device_code: []const u8) TokenFields {
    return .{ .url_kind = .xai, .device_code = device_code };
}

fn pollFormToken(allocator: std.mem.Allocator, prompt: Prompt, device: codec.DeviceStart, fields: TokenFields) !codec.OwnedCredential {
    const deadline = std.time.milliTimestamp() + @as(i64, device.expires_in_seconds) * 1000;
    var interval: u32 = device.interval_seconds;
    while (std.time.milliTimestamp() < deadline) {
        try waitSeconds(interval, prompt);
        const client_id = if (fields.url_kind == .kimi) kimi_client_id else xai_client_id;
        const body = try formPairs(allocator, &.{
            .{ "client_id", client_id },
            .{ "device_code", fields.device_code },
            .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
        });
        defer allocator.free(body);
        const url = switch (fields.url_kind) {
            .kimi => try kimiUrl(allocator, "/api/oauth/token"),
            .xai => try allocator.dupe(u8, xai_token_url),
        };
        defer allocator.free(url);
        const response = try post(allocator, prompt, url, "application/x-www-form-urlencoded", body);
        defer allocator.free(response.body);
        switch (pollDecision(allocator, response.status, response.body, false)) {
            .pending => continue,
            .slow_down => {
                interval += 5;
                continue;
            },
            .ok => return codec.parseToken(allocator, response.body, null, std.time.milliTimestamp()) catch {
                noteFailure(prompt, "invalid token response");
                return error.LoginFailed;
            },
            .denied, .expired, .fatal => {
                noteHttpFailure(allocator, prompt, response.status, response.body);
                return error.LoginFailed;
            },
        }
    }
    return error.LoginFailed;
}

fn pollDecision(allocator: std.mem.Allocator, status: u16, body: []const u8, pending_http: bool) codec.Poll {
    const code = codec.oauthErrorCode(allocator, body);
    defer if (code) |c| allocator.free(c);
    return codec.classifyPoll(status, if (code) |c| c else null, pending_http);
}

fn waitSeconds(seconds: u32, prompt: Prompt) !void {
    var left = @max(seconds, 1);
    while (left > 0) : (left -= 1) {
        if (prompt.cancelled(prompt.ctx)) return error.Canceled;
        std.Thread.sleep(std.time.ns_per_s);
    }
}

fn oauthErrorIs(allocator: std.mem.Allocator, body: []const u8, expected: []const u8) bool {
    const code = codec.oauthErrorCode(allocator, body) orelse return false;
    defer allocator.free(code);
    return std.mem.eql(u8, code, expected);
}

const HttpResponse = struct {
    status: u16,
    body: []u8,
};

fn post(allocator: std.mem.Allocator, prompt: ?Prompt, url: []const u8, content_type: []const u8, payload: []const u8) !HttpResponse {
    const response = switch (builtin.os.tag) {
        // WinHTTP / NSURLSession already speak the system proxy and TLS stack.
        .windows, .macos => postViaPlatform(allocator, url, content_type, payload),
        // std.http.Client's HTTPS proxy path sends the request in cleartext
        // after CONNECT, which auth servers reject before a browser can open.
        else => postPosix(allocator, url, content_type, payload),
    } catch |err| {
        if (prompt) |active| noteFailure(active, @errorName(err));
        return error.LoginFailed;
    };
    return response;
}

fn postViaPlatform(allocator: std.mem.Allocator, url: []const u8, content_type: []const u8, payload: []const u8) !HttpResponse {
    const platform_http = @import("../../platform/http_client.zig");
    const headers = [_]platform_http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Accept", .value = "application/json" },
    };
    const response = try platform_http.fetch(allocator, .{
        .method = .POST,
        .url = url,
        .headers = &headers,
        .body = payload,
        .timeout_ms = 20_000,
    });
    return .{ .status = response.status, .body = response.body };
}

fn postPosix(allocator: std.mem.Allocator, url: []const u8, content_type: []const u8, payload: []const u8) !HttpResponse {
    if (proxyFromEnv(allocator)) |proxy| {
        defer allocator.free(proxy.host);
        return postThroughHttpProxy(allocator, proxy, url, content_type, payload);
    }
    return postDirect(allocator, url, content_type, payload);
}

fn postDirect(allocator: std.mem.Allocator, url: []const u8, content_type: []const u8, payload: []const u8) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator, .write_buffer_size = 16 * 1024 };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Accept", .value = "application/json" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = payload,
        .extra_headers = &headers,
        .response_writer = &out.writer,
    });
    var list = out.toArrayList();
    const body = list.toOwnedSlice(allocator) catch |err| {
        list.deinit(allocator);
        return err;
    };
    return .{ .status = @intFromEnum(result.status), .body = body };
}

const ProxyEndpoint = struct { host: []u8, port: u16 };

fn proxyFromEnv(allocator: std.mem.Allocator) ?ProxyEndpoint {
    const names = [_][]const u8{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" };
    for (names) |name| {
        const value = std.process.getEnvVarOwned(allocator, name) catch continue;
        if (value.len == 0) {
            allocator.free(value);
            continue;
        }
        const uri = std.Uri.parse(value) catch {
            allocator.free(value);
            continue;
        };
        const host_component = uri.host orelse {
            allocator.free(value);
            continue;
        };
        const encoded = host_component.percent_encoded;
        if (encoded.len == 0 or encoded.len > 255) {
            allocator.free(value);
            continue;
        }
        const host = allocator.dupe(u8, encoded) catch {
            allocator.free(value);
            continue;
        };
        const port = uri.port orelse 80;
        allocator.free(value);
        return .{ .host = host, .port = port };
    }
    return null;
}

/// HTTP CONNECT, then TLS, then the POST. Used when `https_proxy` is set.
fn postThroughHttpProxy(
    allocator: std.mem.Allocator,
    proxy: ProxyEndpoint,
    url: []const u8,
    content_type: []const u8,
    payload: []const u8,
) !HttpResponse {
    const uri = try std.Uri.parse(url);
    const host_component = uri.host orelse return error.MissingHost;
    const host = host_component.percent_encoded;
    const port: u16 = uri.port orelse 443;
    const path = if (uri.path.isEmpty()) "/" else uri.path.percent_encoded;

    const stream = try std.net.tcpConnectToHost(allocator, proxy.host, proxy.port);
    defer stream.close();
    const socket_read = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(socket_read);
    const socket_write = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(socket_write);
    var socket_reader = stream.reader(socket_read);
    var socket_writer = stream.writer(socket_write);

    const connect_req = try std.fmt.allocPrint(allocator, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host, port, host, port });
    defer allocator.free(connect_req);
    try socket_writer.interface.writeAll(connect_req);
    try socket_writer.interface.flush();
    var connect_head: [512]u8 = undefined;
    const connect_len = try readUntilHeaderEnd(socket_reader.interface(), &connect_head);
    if (std.mem.indexOf(u8, connect_head[0..connect_len], " 200 ") == null) return error.ProxyConnectFailed;

    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(allocator);
    try bundle.rescan(allocator);
    const tls_read = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(tls_read);
    const tls_write = try allocator.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer allocator.free(tls_write);
    var tls = try std.crypto.tls.Client.init(socket_reader.interface(), &socket_writer.interface, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = bundle },
        .read_buffer = tls_read,
        .write_buffer = tls_write,
    });

    const request = try std.fmt.allocPrint(allocator, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: {s}\r\nAccept: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        path, host, content_type, payload.len, payload,
    });
    defer allocator.free(request);
    try tls.writer.writeAll(request);
    try tls.writer.flush();
    try socket_writer.interface.flush();

    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (raw.items.len < 256 * 1024) {
        const n = tls.reader.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try raw.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |header_end| {
            const length = contentLengthOf(raw.items[0..header_end]) orelse continue;
            if (raw.items.len >= header_end + 4 + length) break;
        }
    }
    const header_end = std.mem.indexOf(u8, raw.items, "\r\n\r\n") orelse return error.BadHttpResponse;
    const status = httpStatusCode(raw.items[0..header_end]) orelse return error.BadHttpResponse;
    const body = try allocator.dupe(u8, raw.items[header_end + 4 ..]);
    return .{ .status = status, .body = body };
}

fn readUntilHeaderEnd(reader: *std.Io.Reader, buf: []u8) !usize {
    var len: usize = 0;
    while (len + 1 < buf.len) {
        const n = reader.readSliceShort(buf[len .. len + 1]) catch return error.EndOfStream;
        if (n == 0) return error.EndOfStream;
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") != null) return len;
    }
    return error.HeaderTooLarge;
}

fn httpStatusCode(header: []const u8) ?u16 {
    const line_end = std.mem.indexOfScalar(u8, header, '\r') orelse header.len;
    var parts = std.mem.tokenizeScalar(u8, header[0..line_end], ' ');
    _ = parts.next() orelse return null;
    const code = parts.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

fn contentLengthOf(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

test "oauth http response header parsing" {
    const header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n";
    try std.testing.expectEqual(@as(u16, 200), httpStatusCode(header).?);
    try std.testing.expectEqual(@as(usize, 12), contentLengthOf(header).?);
    try std.testing.expect(httpStatusCode("not http") == null);
}

fn noteFailure(prompt: Prompt, message: []const u8) void {
    prompt.note(prompt.ctx, message);
}

fn noteHttpFailure(allocator: std.mem.Allocator, prompt: ?Prompt, status: u16, body: []const u8) void {
    const active = prompt orelse return;
    const code = codec.oauthErrorCode(allocator, body);
    defer if (code) |value| allocator.free(value);
    var buf: [96]u8 = undefined;
    const text = if (code) |value|
        std.fmt.bufPrint(&buf, "HTTP {d} {s}", .{ status, value }) catch "login failed"
    else
        std.fmt.bufPrint(&buf, "HTTP {d}", .{status}) catch "login failed";
    noteFailure(active, text);
}

fn formPairs(allocator: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (pairs) |pair| try codec.appendForm(allocator, &out, pair[0], pair[1]);
    return out.toOwnedSlice(allocator);
}

fn kimiUrl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const host = kimiHost(allocator);
    defer if (host.owned) allocator.free(host.value);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ host.value, path });
}

const Host = struct { value: []const u8, owned: bool };

fn kimiHost(allocator: std.mem.Allocator) Host {
    const env = std.process.getEnvVarOwned(allocator, "KIMI_CODE_OAUTH_HOST") catch
        std.process.getEnvVarOwned(allocator, "KIMI_OAUTH_HOST") catch return .{ .value = kimi_oauth_host_default, .owned = false };
    var end = env.len;
    while (end > 0 and env[end - 1] == '/') end -= 1;
    if (end == 0 or !std.mem.startsWith(u8, env[0..end], "https://")) {
        allocator.free(env);
        return .{ .value = kimi_oauth_host_default, .owned = false };
    }
    if (end == env.len) return .{ .value = env, .owned = true };
    const trimmed = allocator.dupe(u8, env[0..end]) catch {
        allocator.free(env);
        return .{ .value = kimi_oauth_host_default, .owned = false };
    };
    allocator.free(env);
    return .{ .value = trimmed, .owned = true };
}

fn codexPollPayload(allocator: std.mem.Allocator, device_code: []const u8, user_code: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"device_auth_id\":");
    try appendJsonString(allocator, &out, device_code);
    try out.appendSlice(allocator, ",\"user_code\":");
    try appendJsonString(allocator, &out, user_code);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20) return error.LoginFailed;
        try out.append(allocator, ch);
    }
    try out.append(allocator, '"');
}

fn jsonField(allocator: std.mem.Allocator, body: []const u8, name: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(name) orelse return null;
    const text = switch (value) {
        .string => |s| s,
        else => return null,
    };
    if (text.len == 0) return null;
    return allocator.dupe(u8, text) catch null;
}
