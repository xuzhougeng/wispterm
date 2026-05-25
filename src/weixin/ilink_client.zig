//! ilink HTTP client over std.http.Client. Network calls are not unit-tested on
//! the dev host (no live WeChat endpoint); logic that consumes this goes through
//! ClientApi so the poller can be tested with a fake.
const std = @import("std");
const codec = @import("ilink_codec.zig");
const types = @import("types.zig");

/// Abstract transport the poller depends on, so it can be faked in tests.
pub const ClientApi = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returned value owns its own arena; caller must call `.deinit()`.
        get_updates: *const fn (ctx: *anyopaque, buf: []const u8) anyerror!codec.ParsedUpdates,
        send_text: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
    };

    pub fn getUpdates(self: ClientApi, buf: []const u8) !codec.ParsedUpdates {
        return self.vtable.get_updates(self.ctx, buf);
    }
    pub fn sendText(self: ClientApi, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        return self.vtable.send_text(self.ctx, to_user_id, text, context_token);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    token: []const u8,
    rng: std.Random.DefaultPrng,
    rng_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, token: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = if (base_url.len != 0) base_url else codec.DEFAULT_BASE_URL,
            .token = token,
            .rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
        };
    }

    /// GET /ilink/bot/get_bot_qrcode?bot_type=3 — result borrows from `arena`.
    pub fn getBotQrcode(self: *Client, arena: std.mem.Allocator) !types.QrCode {
        const resp = try self.fetch(arena, .GET, "/ilink/bot/get_bot_qrcode?bot_type=" ++ codec.BOT_TYPE, null, null);
        const W = struct { ret: i64 = 0, qrcode: []const u8 = "", qrcode_img_content: []const u8 = "" };
        const w = try std.json.parseFromSliceLeaky(W, arena, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return .{ .ret = w.ret, .qrcode = w.qrcode, .qrcode_img_content = w.qrcode_img_content };
    }

    /// GET /ilink/bot/get_qrcode_status?qrcode=... — result borrows from `arena`.
    pub fn getQrcodeStatus(self: *Client, arena: std.mem.Allocator, qrcode: []const u8) !types.QrStatus {
        const path = try std.fmt.allocPrint(arena, "/ilink/bot/get_qrcode_status?qrcode={s}", .{qrcode});
        const resp = try self.fetch(arena, .GET, path, null, "1");
        const W = struct {
            ret: i64 = 0,
            status: []const u8 = "",
            bot_token: []const u8 = "",
            baseurl: []const u8 = "",
            ilink_bot_id: []const u8 = "",
            ilink_user_id: []const u8 = "",
        };
        const w = try std.json.parseFromSliceLeaky(W, arena, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return .{
            .ret = w.ret,
            .status = codec.statusKindFromString(w.status),
            .bot_token = w.bot_token,
            .base_url = w.baseurl,
            .bot_id = w.ilink_bot_id,
            .user_id = w.ilink_user_id,
        };
    }

    /// POST /ilink/bot/getupdates (≈35s long-poll). Returned value owns its arena.
    pub fn getUpdates(self: *Client, buf: []const u8) !codec.ParsedUpdates {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();
        const body = try codec.buildGetUpdatesBody(a, buf);
        const resp = try self.fetch(a, .POST, "/ilink/bot/getupdates", body, null);
        // parseGetUpdates copies (alloc_always) into its own arena, so it is safe
        // for req_arena (holding `resp`) to be freed on return.
        return codec.parseGetUpdates(self.allocator, resp);
    }

    /// POST /ilink/bot/sendmessage.
    pub fn sendText(self: *Client, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();
        const client_id = try std.fmt.allocPrint(a, "phantty-weixin-{d}-{d}", .{
            std.time.milliTimestamp(), self.nextRandomU32(),
        });
        const body = try codec.buildSendTextBody(a, to_user_id, text, context_token, client_id);
        const resp = try self.fetch(a, .POST, "/ilink/bot/sendmessage", body, null);
        const W = struct { ret: ?i64 = null, errcode: i64 = 0, message: []const u8 = "" };
        const w = try std.json.parseFromSliceLeaky(W, a, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (w.ret) |ret| {
            if (ret != 0) {
                std.debug.print("weixin send({d}): kind=sendmessage status=failed ret={} errcode={} message={s}\n", .{ std.time.milliTimestamp(), ret, w.errcode, w.message });
                return error.IlinkSendMessageFailed;
            }
        }
    }

    /// Performs one HTTP request, returning the response body bytes allocated in
    /// `arena`. `client_version`, when set, adds the iLink-App-ClientVersion header.
    fn fetch(
        self: *Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
        client_version: ?[]const u8,
    ) ![]u8 {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });

        // X-WECHAT-UIN: base64 of a random uint decimal string (mirrors the TS bridge).
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.nextRandomU32()}) catch "0";
        const uin = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(num_str.len));
        _ = std.base64.standard.Encoder.encode(uin, num_str);

        var headers_buf: [3]std.http.Header = undefined;
        headers_buf[0] = .{ .name = "AuthorizationType", .value = "ilink_bot_token" };
        headers_buf[1] = .{ .name = "X-WECHAT-UIN", .value = uin };
        var header_count: usize = 2;
        if (client_version) |cv| {
            headers_buf[2] = .{ .name = "iLink-App-ClientVersion", .value = cv };
            header_count = 3;
        }

        var req_headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
        };
        if (self.token.len != 0) {
            req_headers.authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.token}) };
        }

        var body: std.Io.Writer.Allocating = .init(arena);
        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .keep_alive = false,
            .payload = payload,
            .headers = req_headers,
            .extra_headers = headers_buf[0..header_count],
            .response_writer = &body.writer,
        });
        if (response.status != .ok) return error.IlinkHttpStatus;
        return body.toArrayList().items;
    }

    fn nextRandomU32(self: *Client) u32 {
        self.rng_mutex.lock();
        defer self.rng_mutex.unlock();
        return self.rng.random().int(u32);
    }

    // --- ClientApi adapter ---

    pub fn api(self: *Client) ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = apiGetUpdates,
            .send_text = apiSendText,
        } };
    }
    fn apiGetUpdates(ctx: *anyopaque, buf: []const u8) anyerror!codec.ParsedUpdates {
        return @as(*Client, @ptrCast(@alignCast(ctx))).getUpdates(buf);
    }
    fn apiSendText(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
        return @as(*Client, @ptrCast(@alignCast(ctx))).sendText(to_user_id, text, context_token);
    }
};

test "client init defaults the base url" {
    const c = Client.init(std.testing.allocator, "", "tok");
    try std.testing.expectEqualStrings(codec.DEFAULT_BASE_URL, c.base_url);
    const c2 = Client.init(std.testing.allocator, "https://x.test", "tok");
    try std.testing.expectEqualStrings("https://x.test", c2.base_url);
}
