//! ilink HTTP client over std.http.Client. Network calls are not unit-tested on
//! the dev host (no live WeChat endpoint); logic that consumes this goes through
//! ClientApi so the poller can be tested with a fake.
const std = @import("std");
const codec = @import("ilink_codec.zig");
const media = @import("media.zig");
const types = @import("types.zig");

/// Abstract transport the poller depends on, so it can be faked in tests.
pub const ClientApi = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Returned value owns its own arena; caller must call `.deinit()`.
        get_updates: *const fn (ctx: *anyopaque, buf: []const u8) anyerror!codec.ParsedUpdates,
        send_text: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
        send_attachment: *const fn (
            ctx: *anyopaque,
            kind: types.AttachmentKind,
            path: []const u8,
            display_name: []const u8,
            to_user_id: []const u8,
            context_token: []const u8,
        ) anyerror!void,
    };

    pub fn getUpdates(self: ClientApi, buf: []const u8) !codec.ParsedUpdates {
        return self.vtable.get_updates(self.ctx, buf);
    }
    pub fn sendText(self: ClientApi, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        return self.vtable.send_text(self.ctx, to_user_id, text, context_token);
    }
    pub fn sendAttachment(
        self: ClientApi,
        kind: types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) !void {
        return self.vtable.send_attachment(self.ctx, kind, path, display_name, to_user_id, context_token);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    token: []const u8,
    rng: std.Random.DefaultPrng,
    rng_mutex: std.Thread.Mutex = .{},

    const UploadedLocalFile = struct {
        media: types.CdnMedia,
        raw_len: u64,
        encrypted_len: u64,
    };

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
        const path = try qrcodeStatusPath(arena, qrcode);
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
        const client_id = try self.clientId(a);
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

    pub fn clientId(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "wispterm-weixin-{d}-{d}", .{
            std.time.milliTimestamp(), self.nextRandomU32(),
        });
    }

    pub fn sendAttachment(
        self: *Client,
        kind: types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) !void {
        return switch (kind) {
            .file => self.sendFileAttachment(path, displayNameOrBasename(display_name, path), to_user_id, context_token),
            .image => self.sendImageFile(path, to_user_id, context_token),
            .voice => self.sendVoiceFile(path, to_user_id, context_token),
        };
    }

    fn sendFileAttachment(self: *Client, path: []const u8, file_name: []const u8, to_user_id: []const u8, context_token: []const u8) !void {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();
        const uploaded = try self.uploadLocalFile(a, .file, path);
        const client_id = try self.clientId(a);
        const body = try codec.buildSendUploadedFileBody(a, to_user_id, context_token, client_id, .{
            .media = uploaded.media,
            .file_name = file_name,
            .len = uploaded.raw_len,
        });
        try self.postSendMessage(a, body);
    }

    fn sendImageFile(self: *Client, path: []const u8, to_user_id: []const u8, context_token: []const u8) !void {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();
        const uploaded = try self.uploadLocalFile(a, .image, path);
        const client_id = try self.clientId(a);
        const body = try codec.buildSendUploadedImageBody(a, to_user_id, context_token, client_id, .{
            .media = uploaded.media,
            .mid_size = uploaded.encrypted_len,
        });
        try self.postSendMessage(a, body);
    }

    fn sendVoiceFile(self: *Client, path: []const u8, to_user_id: []const u8, context_token: []const u8) !void {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();
        const metadata = try self.probeVoiceFile(a, path);
        const uploaded = try self.uploadLocalFile(a, .voice, path);
        const client_id = try self.clientId(a);
        const body = try codec.buildSendUploadedVoiceBody(a, to_user_id, context_token, client_id, .{
            .media = uploaded.media,
            .encode_type = metadata.encode_type,
            .sample_rate = metadata.sample_rate,
            .playtime = metadata.playtime,
        });
        try self.postSendMessage(a, body);
    }

    fn uploadLocalFile(self: *Client, arena: std.mem.Allocator, kind: types.AttachmentKind, path: []const u8) !UploadedLocalFile {
        const plain = readLocalFileAlloc(arena, path) catch |err| switch (err) {
            error.FileNotFound => return error.WeixinAttachmentFileNotFound,
            error.IsDir => return error.WeixinAttachmentPathIsDirectory,
            else => return err,
        };
        const md5 = try media.md5Hex(arena, plain);

        var file_key_bytes: [16]u8 = undefined;
        self.randomBytes(file_key_bytes[0..]);
        const file_key_hex = std.fmt.bytesToHex(file_key_bytes, .lower);
        const file_key = try arena.dupe(u8, &file_key_hex);

        var aes_key: media.AesKey = undefined;
        self.randomBytes(aes_key[0..]);
        const encoded_aes_key = try media.encodeIlinkAesKey(arena, aes_key);

        const upload = try self.getUploadUrl(arena, kind, plain.len, md5, file_key);
        const encrypted = try media.aes128EcbPkcs7Encrypt(arena, aes_key, plain);
        const encrypted_param = try self.uploadBufferToCdn(arena, upload.url, upload.ticket, encrypted);

        return .{
            .media = .{
                .encrypt_query_param = encrypted_param,
                .aes_key = encoded_aes_key,
                .md5 = md5,
                .size = plain.len,
                .file_key = if (upload.file_key.len != 0) upload.file_key else file_key,
            },
            .raw_len = plain.len,
            .encrypted_len = encrypted.len,
        };
    }

    fn getUploadUrl(
        self: *Client,
        arena: std.mem.Allocator,
        kind: types.AttachmentKind,
        size: u64,
        md5: []const u8,
        file_key: []const u8,
    ) !types.UploadUrl {
        const body = try codec.buildGetUploadUrlBody(arena, kind, size, md5, file_key);
        const resp = try self.fetch(arena, .POST, "/ilink/bot/getuploadurl", body, null);
        var parsed = try codec.parseGetUploadUrl(self.allocator, resp);
        defer parsed.deinit();
        const upload = parsed.value;
        if (upload.ret != 0) {
            std.debug.print("weixin upload-url({d}): kind={s} status=failed ret={} errcode={} message={s}\n", .{
                std.time.milliTimestamp(),
                kind.name(),
                upload.ret,
                upload.errcode,
                upload.message,
            });
            return error.WeixinGetUploadUrlFailed;
        }
        if (upload.url.len == 0 or upload.ticket.len == 0) {
            std.debug.print("weixin upload-url({d}): kind={s} status=missing-url ret={} errcode={} message={s}\n", .{
                std.time.milliTimestamp(),
                kind.name(),
                upload.ret,
                upload.errcode,
                upload.message,
            });
            return error.WeixinGetUploadUrlMissingUrl;
        }
        return .{
            .url = try arena.dupe(u8, upload.url),
            .ticket = try arena.dupe(u8, upload.ticket),
            .file_key = try arena.dupe(u8, upload.file_key),
            .ret = upload.ret,
            .errcode = upload.errcode,
            .message = try arena.dupe(u8, upload.message),
        };
    }

    fn uploadBufferToCdn(self: *Client, arena: std.mem.Allocator, upload_url: []const u8, ticket: []const u8, encrypted: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const ticket_url = try media.uploadUrlWithTicket(arena, upload_url, ticket);
        const uri = try std.Uri.parse(ticket_url);
        var req = try client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
            .keep_alive = false,
        });
        defer req.deinit();

        try req.sendBodyComplete(encrypted);

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        var encrypted_param: ?[]u8 = null;
        var header_it = response.head.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-encrypted-param")) {
                encrypted_param = try arena.dupe(u8, header.value);
                break;
            }
        }

        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var discard_buffer: [1024]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&discard_buffer);
        _ = reader.streamRemaining(&discarding.writer) catch {};

        if (response.head.status != .ok) return error.WeixinCdnUploadFailed;
        return encrypted_param orelse error.WeixinCdnMissingEncryptedParam;
    }

    fn postSendMessage(self: *Client, arena: std.mem.Allocator, body: []const u8) !void {
        const resp = try self.fetch(arena, .POST, "/ilink/bot/sendmessage", body, null);
        const W = struct { ret: ?i64 = null, errcode: i64 = 0, message: []const u8 = "" };
        const w = try std.json.parseFromSliceLeaky(W, arena, resp, .{
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

    fn probeVoiceFile(self: *Client, arena: std.mem.Allocator, path: []const u8) !types.VoiceMetadata {
        _ = self;
        const argv = [_][]const u8{
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type,codec_name,sample_rate,duration:format=duration",
            "-of",
            "json",
            path,
        };
        var child = std.process.Child.init(&argv, arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.create_no_window = true;
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return error.FfprobeNotFound,
            else => return error.FfprobeFailed,
        };

        const stdout = if (child.stdout) |out| try out.readToEndAlloc(arena, 64 * 1024) else "";
        const term = child.wait() catch return error.FfprobeFailed;
        switch (term) {
            .Exited => |code| if (code != 0) return error.FfprobeFailed,
            else => return error.FfprobeFailed,
        }
        return media.parseFfprobeVoiceMetadata(arena, stdout, path);
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

    fn randomBytes(self: *Client, out: []u8) void {
        self.rng_mutex.lock();
        defer self.rng_mutex.unlock();
        self.rng.random().bytes(out);
    }

    // --- ClientApi adapter ---

    pub fn api(self: *Client) ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = apiGetUpdates,
            .send_text = apiSendText,
            .send_attachment = apiSendAttachment,
        } };
    }
    fn apiGetUpdates(ctx: *anyopaque, buf: []const u8) anyerror!codec.ParsedUpdates {
        return @as(*Client, @ptrCast(@alignCast(ctx))).getUpdates(buf);
    }
    fn apiSendText(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
        return @as(*Client, @ptrCast(@alignCast(ctx))).sendText(to_user_id, text, context_token);
    }
    fn apiSendAttachment(
        ctx: *anyopaque,
        kind: types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        return @as(*Client, @ptrCast(@alignCast(ctx))).sendAttachment(kind, path, display_name, to_user_id, context_token);
    }
};

fn qrcodeStatusPath(allocator: std.mem.Allocator, qrcode: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "/ilink/bot/get_qrcode_status?qrcode=");
    try appendQueryEscaped(&out, allocator, qrcode);
    return out.toOwnedSlice(allocator);
}

fn appendQueryEscaped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
}

fn readLocalFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

fn displayNameOrBasename(display_name: []const u8, path: []const u8) []const u8 {
    if (display_name.len != 0) return display_name;
    return std.fs.path.basename(path);
}

test "client init defaults the base url" {
    const c = Client.init(std.testing.allocator, "", "tok");
    try std.testing.expectEqualStrings(codec.DEFAULT_BASE_URL, c.base_url);
    const c2 = Client.init(std.testing.allocator, "https://x.test", "tok");
    try std.testing.expectEqualStrings("https://x.test", c2.base_url);
}

test "client qrcode status path percent-encodes the qrcode query value" {
    const path = try qrcodeStatusPath(std.testing.allocator, "qr session+&=%");
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/ilink/bot/get_qrcode_status?qrcode=qr%20session%2B%26%3D%25",
        path,
    );
}

test "ClientApi forwards sendAttachment to the vtable" {
    const Capture = struct {
        called: bool = false,
        kind: types.AttachmentKind = .file,
        path: []const u8 = "",
        display_name: []const u8 = "",
        to_user_id: []const u8 = "",
        context_token: []const u8 = "",

        fn sendAttachment(
            ctx: *anyopaque,
            kind: types.AttachmentKind,
            path: []const u8,
            display_name: []const u8,
            to_user_id: []const u8,
            context_token: []const u8,
        ) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
            self.kind = kind;
            self.path = path;
            self.display_name = display_name;
            self.to_user_id = to_user_id;
            self.context_token = context_token;
        }

        fn getUpdates(ctx: *anyopaque, buf: []const u8) anyerror!codec.ParsedUpdates {
            _ = ctx;
            _ = buf;
            return error.NotUsed;
        }

        fn sendText(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
            _ = ctx;
            _ = to_user_id;
            _ = text;
            _ = context_token;
        }
    };

    var capture = Capture{};
    const api = ClientApi{ .ctx = &capture, .vtable = &.{
        .get_updates = Capture.getUpdates,
        .send_text = Capture.sendText,
        .send_attachment = Capture.sendAttachment,
    } };
    try api.sendAttachment(.voice, "C:\\tmp\\a.mp3", "a.mp3", "wx-user", "ctx");
    try std.testing.expect(capture.called);
    try std.testing.expectEqual(types.AttachmentKind.voice, capture.kind);
    try std.testing.expectEqualStrings("C:\\tmp\\a.mp3", capture.path);
    try std.testing.expectEqualStrings("a.mp3", capture.display_name);
    try std.testing.expectEqualStrings("wx-user", capture.to_user_id);
    try std.testing.expectEqualStrings("ctx", capture.context_token);
}

test "client ids are generated with the wispterm weixin prefix" {
    var c = Client.init(std.testing.allocator, "https://x.test", "tok");
    const id = try c.clientId(std.testing.allocator);
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "wispterm-weixin-"));
}
