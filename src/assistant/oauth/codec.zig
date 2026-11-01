//! Pure OAuth helpers for Codex, Kimi Code, and xAI subscription login:
//! form bodies, device/token JSON, device-poll decisions, and the ChatGPT
//! account id carried in a Codex access token. No network and no disk.
const std = @import("std");

pub const Provider = enum {
    codex,
    kimi,
    xai,

    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .codex => "codex",
            .kimi => "kimi",
            .xai => "xai",
        };
    }

    pub fn parse(value: []const u8) ?Provider {
        if (std.mem.eql(u8, value, "codex")) return .codex;
        if (std.mem.eql(u8, value, "kimi")) return .kimi;
        if (std.mem.eql(u8, value, "xai")) return .xai;
        return null;
    }
};

pub const OwnedCredential = struct {
    access: []u8,
    refresh: []u8,
    expires_ms: i64,

    pub fn deinit(self: OwnedCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.access);
        allocator.free(self.refresh);
    }
};

pub const DeviceStart = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_seconds: u32,
    expires_in_seconds: u32,

    pub fn deinit(self: DeviceStart, allocator: std.mem.Allocator) void {
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
    }
};

/// What a device-token poll should do next. `ok` means the body is a token
/// (or, for Codex, an authorization code) and the caller parses it.
pub const Poll = enum {
    pending,
    slow_down,
    denied,
    expired,
    ok,
    fatal,
};

pub const refresh_skew_ms: i64 = 5 * 60 * 1000;

pub fn needsRefresh(expires_ms: i64, now_ms: i64) bool {
    return now_ms + refresh_skew_ms >= expires_ms;
}

pub fn expiresAt(now_ms: i64, expires_in_seconds: u32) i64 {
    return now_ms + @as(i64, expires_in_seconds) * 1000 - refresh_skew_ms;
}

pub fn classifyPoll(status: u16, oauth_error: ?[]const u8, pending_http: bool) Poll {
    if (status >= 200 and status < 300) return .ok;
    if (oauth_error) |err| {
        if (std.mem.eql(u8, err, "authorization_pending") or std.mem.eql(u8, err, "deviceauth_authorization_pending")) return .pending;
        if (std.mem.eql(u8, err, "slow_down")) return .slow_down;
        if (std.mem.eql(u8, err, "access_denied") or std.mem.eql(u8, err, "authorization_denied")) return .denied;
        if (std.mem.eql(u8, err, "expired_token")) return .expired;
    }
    if (pending_http and (status == 403 or status == 404)) return .pending;
    return .fatal;
}

pub fn appendForm(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, '&');
    try appendFormPart(allocator, out, key);
    try out.append(allocator, '=');
    try appendFormPart(allocator, out, value);
}

pub fn parseDeviceStart(allocator: std.mem.Allocator, body: []const u8) !DeviceStart {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const device_code = jsonString(root, "device_code") orelse jsonString(root, "device_auth_id") orelse return error.InvalidResponse;
    const user_code = jsonString(root, "user_code") orelse return error.InvalidResponse;
    // Codex's device-code response has no URI; the client opens a fixed page.
    const verification = jsonString(root, "verification_uri_complete") orelse jsonString(root, "verification_uri") orelse "";
    if (verification.len > 0 and !trustedHttpUrl(verification)) return error.InvalidResponse;
    const device_copy = try allocator.dupe(u8, device_code);
    errdefer allocator.free(device_copy);
    const user_copy = try allocator.dupe(u8, user_code);
    errdefer allocator.free(user_copy);
    const uri_copy = try allocator.dupe(u8, verification);
    return .{
        .device_code = device_copy,
        .user_code = user_copy,
        .verification_uri = uri_copy,
        .interval_seconds = jsonPositiveU32(root, "interval") orelse 5,
        .expires_in_seconds = jsonPositiveU32(root, "expires_in") orelse 15 * 60,
    };
}

pub fn oauthErrorCode(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const code = oauthErrorFromValue(parsed.value) orelse return null;
    return allocator.dupe(u8, code) catch null;
}

pub fn parseToken(allocator: std.mem.Allocator, body: []const u8, previous_refresh: ?[]const u8, now_ms: i64) !OwnedCredential {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const access = jsonString(parsed.value, "access_token") orelse return error.InvalidResponse;
    if (access.len == 0) return error.InvalidResponse;
    const refresh_raw = jsonString(parsed.value, "refresh_token");
    const refresh_src = refresh_raw orelse previous_refresh orelse return error.InvalidResponse;
    if (refresh_src.len == 0) return error.InvalidResponse;
    const expires_in = jsonPositiveU32(parsed.value, "expires_in") orelse 3600;
    const access_copy = try allocator.dupe(u8, access);
    errdefer allocator.free(access_copy);
    const refresh_copy = try allocator.dupe(u8, refresh_src);
    return .{
        .access = access_copy,
        .refresh = refresh_copy,
        .expires_ms = expiresAt(now_ms, expires_in),
    };
}

/// ChatGPT account id from a Codex access token (`https://api.openai.com/auth`).
pub fn chatgptAccountId(allocator: std.mem.Allocator, jwt: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return error.InvalidToken;
    const payload = parts.next() orelse return error.InvalidToken;
    const decoded = decodeBase64Url(allocator, payload) catch return error.InvalidToken;
    defer allocator.free(decoded);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidToken;
    defer parsed.deinit();
    const auth = parsed.value.object.get("https://api.openai.com/auth") orelse return error.InvalidToken;
    const account = jsonString(auth, "chatgpt_account_id") orelse return error.InvalidToken;
    if (account.len == 0) return error.InvalidToken;
    return allocator.dupe(u8, account);
}

fn oauthErrorFromValue(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const err = root.object.get("error") orelse return null;
    return switch (err) {
        .string => |s| s,
        .object => |obj| blk: {
            const code = obj.get("code") orelse break :blk null;
            break :blk switch (code) {
                .string => |s| s,
                else => null,
            };
        },
        else => null,
    };
}

fn jsonString(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn jsonPositiveU32(root: std.json.Value, name: []const u8) ?u32 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    const n: i64 = switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch return null,
        else => return null,
    };
    if (n <= 0 or n > std.math.maxInt(u32)) return null;
    return @intCast(n);
}

fn trustedHttpUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://");
}

fn appendFormPart(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try out.append(allocator, ch);
        } else {
            try out.writer(allocator).print("%{X:0>2}", .{ch});
        }
    }
}

fn decodeBase64Url(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    const pad = (4 - (segment.len % 4)) % 4;
    const padded = try allocator.alloc(u8, segment.len + pad);
    defer allocator.free(padded);
    @memcpy(padded[0..segment.len], segment);
    @memset(padded[segment.len..], '=');
    const Decoder = std.base64.url_safe.Decoder;
    const len = Decoder.calcSizeForSlice(padded) catch return error.InvalidToken;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    Decoder.decode(out, padded) catch return error.InvalidToken;
    return out;
}

fn formOf(allocator: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (pairs) |pair| try appendForm(allocator, &out, pair[0], pair[1]);
    return out.toOwnedSlice(allocator);
}

test "device poll classification matches RFC 8628 and Codex pending HTTP" {
    try std.testing.expectEqual(Poll.ok, classifyPoll(200, null, true));
    try std.testing.expectEqual(Poll.pending, classifyPoll(400, "authorization_pending", false));
    try std.testing.expectEqual(Poll.pending, classifyPoll(403, "deviceauth_authorization_pending", true));
    try std.testing.expectEqual(Poll.pending, classifyPoll(404, null, true));
    try std.testing.expectEqual(Poll.fatal, classifyPoll(404, null, false));
    try std.testing.expectEqual(Poll.slow_down, classifyPoll(400, "slow_down", false));
    try std.testing.expectEqual(Poll.denied, classifyPoll(400, "access_denied", false));
    try std.testing.expectEqual(Poll.expired, classifyPoll(400, "expired_token", false));
}

test "device start prefers the complete verification uri" {
    const body =
        \\{"device_code":"dev","user_code":"ABCD-1234","verification_uri":"https://auth.example/device","verification_uri_complete":"https://auth.example/device?user_code=ABCD-1234","interval":5,"expires_in":600}
    ;
    const start = try parseDeviceStart(std.testing.allocator, body);
    defer start.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dev", start.device_code);
    try std.testing.expectEqualStrings("ABCD-1234", start.user_code);
    try std.testing.expect(std.mem.indexOf(u8, start.verification_uri, "user_code=ABCD-1234") != null);
    try std.testing.expectEqual(@as(u32, 5), start.interval_seconds);
}

test "codex device start accepts device_auth_id without a verification uri" {
    const body =
        \\{"device_auth_id":"dev-1","user_code":"WXYZ","interval":"5"}
    ;
    const start = try parseDeviceStart(std.testing.allocator, body);
    defer start.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dev-1", start.device_code);
    try std.testing.expectEqualStrings("", start.verification_uri);
    try std.testing.expectEqual(@as(u32, 5), start.interval_seconds);
}

test "token parse keeps the previous refresh token when the server omits it" {
    const cred = try parseToken(std.testing.allocator, "{\"access_token\":\"acc\",\"expires_in\":3600}", "old-refresh", 1_000_000);
    defer cred.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("acc", cred.access);
    try std.testing.expectEqualStrings("old-refresh", cred.refresh);
    try std.testing.expect(needsRefresh(cred.expires_ms, cred.expires_ms));
    try std.testing.expect(!needsRefresh(cred.expires_ms, cred.expires_ms - refresh_skew_ms - 1));
}

test "chatgpt account id is read from the access-token claim" {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try payload.appendSlice(std.testing.allocator, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_42\"}}");
    const Encoder = std.base64.url_safe_no_pad.Encoder;
    const enc_len = Encoder.calcSize(payload.items.len);
    const enc = try std.testing.allocator.alloc(u8, enc_len);
    defer std.testing.allocator.free(enc);
    _ = Encoder.encode(enc, payload.items);
    const jwt = try std.fmt.allocPrint(std.testing.allocator, "e30.{s}.sig", .{enc});
    defer std.testing.allocator.free(jwt);
    const account = try chatgptAccountId(std.testing.allocator, jwt);
    defer std.testing.allocator.free(account);
    try std.testing.expectEqualStrings("acct_42", account);
}

test "form body percent-encodes reserved characters" {
    const body = try formOf(std.testing.allocator, &.{
        .{ "client_id", "abc" },
        .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("client_id=abc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code", body);
}

test "oauth error object code is extracted" {
    const code = oauthErrorCode(std.testing.allocator, "{\"error\":{\"code\":\"slow_down\"}}");
    defer if (code) |c| std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("slow_down", code.?);
}
