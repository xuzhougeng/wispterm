//! ilink HTTP client over std.http.Client. Network calls are not unit-tested on
//! the dev host (no live WeChat endpoint); logic that consumes this goes through
//! ClientApi so the poller can be tested with a fake.
const std = @import("std");
const builtin = @import("builtin");
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
    transport_ctx: ?*anyopaque = null,
    fetch_impl: FetchImpl = httpFetch,
    cdn_upload_impl: CdnUploadImpl = httpUploadBufferToCdn,

    const ERROR_BODY_EXCERPT_BYTES = 256;
    const FetchImpl = *const fn (
        ctx: ?*anyopaque,
        client: *Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
        client_version: ?[]const u8,
    ) anyerror![]u8;
    const CdnUploadImpl = *const fn (
        ctx: ?*anyopaque,
        client: *Client,
        arena: std.mem.Allocator,
        upload_url: []const u8,
        ticket: []const u8,
        encrypted: []u8,
    ) anyerror![]u8;

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
                std.debug.print("weixin send({d}): kind=sendmessage status=failed ret={} errcode={} message={s}\n", .{
                    std.time.milliTimestamp(),
                    ret,
                    w.errcode,
                    logSafeDiagnosticText(a, w.message),
                });
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
            .file, .voice => self.sendFileAttachment(path, displayNameOrBasename(display_name, path), to_user_id, context_token),
            .image => self.sendImageFile(path, to_user_id, context_token),
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

    fn uploadLocalFile(self: *Client, arena: std.mem.Allocator, kind: types.AttachmentKind, path: []const u8) !UploadedLocalFile {
        const plain = readLocalFileAlloc(arena, path) catch |err| switch (err) {
            error.FileNotFound => return error.WeixinAttachmentFileNotFound,
            error.IsDir => return error.WeixinAttachmentPathIsDirectory,
            error.WeixinAttachmentNotRegularFile => return error.WeixinAttachmentNotRegularFile,
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
                logSafeDiagnosticText(arena, upload.message),
            });
            return error.WeixinGetUploadUrlFailed;
        }
        if (upload.url.len == 0 or upload.ticket.len == 0) {
            std.debug.print("weixin upload-url({d}): kind={s} status=missing-url ret={} errcode={} message={s}\n", .{
                std.time.milliTimestamp(),
                kind.name(),
                upload.ret,
                upload.errcode,
                logSafeDiagnosticText(arena, upload.message),
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

    fn uploadBufferToCdn(self: *Client, arena: std.mem.Allocator, upload_url: []const u8, ticket: []const u8, encrypted: []u8) ![]u8 {
        return self.cdn_upload_impl(self.transport_ctx, self, arena, upload_url, ticket, encrypted);
    }

    fn httpUploadBufferToCdn(
        _: ?*anyopaque,
        self: *Client,
        arena: std.mem.Allocator,
        upload_url: []const u8,
        ticket: []const u8,
        encrypted: []u8,
    ) ![]u8 {
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
        const response_excerpt = readResponseBodyExcerpt(arena, reader) catch |err| {
            std.debug.print("weixin upload-cdn({d}): status=read_failed err={}\n", .{ std.time.milliTimestamp(), err });
            return error.WeixinCdnUploadFailed;
        };

        if (response.head.status != .ok) {
            std.debug.print("weixin upload-cdn({d}): status=failed http_status={} body_excerpt={s}\n", .{
                std.time.milliTimestamp(),
                response.head.status,
                logSafeResponseExcerpt(arena, response_excerpt),
            });
            return error.WeixinCdnUploadFailed;
        }
        if (encrypted_param) |param| return param;
        std.debug.print("weixin upload-cdn({d}): status=missing-encrypted-param body_excerpt={s}\n", .{
            std.time.milliTimestamp(),
            logSafeResponseExcerpt(arena, response_excerpt),
        });
        return error.WeixinCdnMissingEncryptedParam;
    }

    fn postSendMessage(self: *Client, arena: std.mem.Allocator, body: []const u8) !void {
        const resp = try self.fetch(arena, .POST, "/ilink/bot/sendmessage", body, null);
        const W = struct { ret: ?i64 = null, errcode: i64 = 0, message: []const u8 = "" };
        const w = try std.json.parseFromSliceLeaky(W, arena, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        const ret = w.ret orelse {
            std.debug.print("weixin send({d}): kind=attachment status=malformed body_excerpt={s}\n", .{
                std.time.milliTimestamp(),
                logSafeResponseExcerpt(arena, resp),
            });
            return error.IlinkSendMessageMalformed;
        };
        if (ret != 0) {
            std.debug.print("weixin send({d}): kind=attachment status=failed ret={} errcode={} message={s}\n", .{
                std.time.milliTimestamp(),
                ret,
                w.errcode,
                logSafeDiagnosticText(arena, w.message),
            });
            return error.IlinkSendMessageFailed;
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
        return self.fetch_impl(self.transport_ctx, self, arena, method, path, payload, client_version);
    }

    fn httpFetch(
        _: ?*anyopaque,
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
        const response_items = body.toArrayList().items;
        if (response.status != .ok) {
            std.debug.print("weixin http({d}): endpoint={s} status=failed http_status={} body_excerpt={s}\n", .{
                std.time.milliTimestamp(),
                endpointForLog(path),
                response.status,
                logSafeResponseExcerpt(arena, response_items),
            });
            return error.IlinkHttpStatus;
        }
        return response_items;
    }

    fn nextRandomU32(self: *Client) u32 {
        self.rng_mutex.lock();
        defer self.rng_mutex.unlock();
        return self.rng.random().int(u32);
    }

    fn randomBytes(_: *Client, out: []u8) void {
        std.crypto.random.bytes(out);
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
    const path_kind = try localPathKind(path);
    switch (path_kind) {
        .file => {},
        .directory => return error.IsDir,
        else => return error.WeixinAttachmentNotRegularFile,
    }

    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Re-check the opened handle so a path replaced after the initial stat is
    // not read if it no longer resolves to a regular file.
    const stat = try file.stat();
    switch (stat.kind) {
        .file => return file.readToEndAlloc(allocator, std.math.maxInt(usize)),
        .directory => return error.IsDir,
        else => return error.WeixinAttachmentNotRegularFile,
    }
}

fn localPathKind(path: []const u8) !std.fs.File.Kind {
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => return .directory,
        error.AccessDenied => {
            if (pathIsDirectory(path)) return .directory;
            return err;
        },
        else => return err,
    };
    return stat.kind;
}

fn pathIsDirectory(path: []const u8) bool {
    var dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{})
    else
        std.fs.cwd().openDir(path, .{});
    if (dir) |*d| {
        d.close();
        return true;
    } else |_| {
        return false;
    }
}

fn displayNameOrBasename(display_name: []const u8, path: []const u8) []const u8 {
    if (display_name.len != 0) return display_name;
    return std.fs.path.basename(path);
}

fn endpointForLog(path: []const u8) []const u8 {
    const query_index = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..query_index];
}

fn readResponseBodyExcerpt(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const out = try allocator.alloc(u8, Client.ERROR_BODY_EXCERPT_BYTES);
    errdefer allocator.free(out);
    const len = try reader.readSliceShort(out);
    _ = try reader.discardRemaining();
    return allocator.realloc(out, len);
}

fn logSafeResponseExcerpt(allocator: std.mem.Allocator, body: []const u8) []const u8 {
    return logSafeDiagnosticText(allocator, body);
}

fn logSafeDiagnosticText(allocator: std.mem.Allocator, text: []const u8) []const u8 {
    return safeDiagnosticTextAlloc(allocator, text) catch "[diagnostic text unavailable]";
}

fn safeDiagnosticTextAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const capped = body[0..@min(body.len, Client.ERROR_BODY_EXCERPT_BYTES)];
    if (looksBinary(capped)) return allocator.dupe(u8, "[binary body omitted]");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < capped.len) {
        if (try appendRedactedJsonField(&out, allocator, capped, &i)) continue;
        try appendLogEscapedByte(&out, allocator, capped[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn looksBinary(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return true;
    for (bytes) |b| {
        if (b == 0 or b == 0x7f) return true;
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') return true;
    }
    return false;
}

fn appendRedactedJsonField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    input: []const u8,
    index: *usize,
) !bool {
    if (jsonStringValueStart(input, index.*)) |field| {
        if (isSensitiveDiagnosticField(field.key)) {
            try out.appendSlice(allocator, input[index.* .. field.value_quote + 1]);
            try out.appendSlice(allocator, "[redacted]");
            try out.append(allocator, '"');
            index.* = skipJsonString(input, field.value_quote + 1);
            return true;
        }
    }
    if (plainValueStart(input, index.*)) |field| {
        if (isSensitiveDiagnosticField(field.key)) {
            try out.appendSlice(allocator, input[index.*..field.value_start]);
            try out.appendSlice(allocator, "[redacted]");
            index.* = skipPlainValue(input, field.value_start);
            return true;
        }
    }
    return false;
}

const JsonDiagnosticField = struct {
    key: []const u8,
    value_quote: usize,
};

fn jsonStringValueStart(input: []const u8, start: usize) ?JsonDiagnosticField {
    if (start >= input.len or input[start] != '"') return null;
    const key_quote_end = skipJsonString(input, start + 1);
    if (key_quote_end <= start + 1 or key_quote_end > input.len or input[key_quote_end - 1] != '"') return null;
    const key = input[start + 1 .. key_quote_end - 1];
    var i = key_quote_end;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len or input[i] != ':') return null;
    i += 1;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len or input[i] != '"') return null;
    return .{ .key = key, .value_quote = i };
}

fn skipJsonString(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\') {
            if (i + 1 < input.len) i += 1;
            continue;
        }
        if (input[i] == '"') return i + 1;
    }
    return input.len;
}

const PlainDiagnosticField = struct {
    key: []const u8,
    value_start: usize,
};

fn plainValueStart(input: []const u8, start: usize) ?PlainDiagnosticField {
    if (start >= input.len or !isDiagnosticKeyChar(input[start])) return null;
    var key_end = start + 1;
    while (key_end < input.len and isDiagnosticKeyChar(input[key_end])) : (key_end += 1) {}
    var i = key_end;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    if (i >= input.len or (input[i] != ':' and input[i] != '=')) return null;
    i += 1;
    while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
    return .{ .key = input[start..key_end], .value_start = i };
}

fn isDiagnosticKeyChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.';
}

fn skipPlainValue(input: []const u8, start: usize) usize {
    if (start < input.len and input[start] == '"') return skipJsonString(input, start + 1);
    var i = start;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            ' ', '\t', '\r', '\n', ',', ';', '&', '}' => return i,
            else => {},
        }
    }
    return input.len;
}

fn isSensitiveDiagnosticField(field: []const u8) bool {
    const sensitive = [_][]const u8{
        "contexttoken",
        "aeskey",
        "encryptqueryparam",
        "encryptedparam",
        "xencryptedparam",
        "token",
        "bottoken",
        "accesstoken",
        "authorization",
        "ticket",
    };
    for (sensitive) |canonical| {
        if (normalizedDiagnosticFieldEquals(field, canonical)) return true;
    }
    return false;
}

fn normalizedDiagnosticFieldEquals(field: []const u8, canonical: []const u8) bool {
    var j: usize = 0;
    for (field) |raw| {
        if (raw == '_' or raw == '-' or raw == '.') continue;
        if (j >= canonical.len) return false;
        if (std.ascii.toLower(raw) != canonical[j]) return false;
        j += 1;
    }
    return j == canonical.len;
}

fn appendLogEscapedByte(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, b: u8) !void {
    switch (b) {
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, b),
    }
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

test "voice attachment uses file path handling before network access" {
    var c = Client.init(std.testing.allocator, "https://x.test", "tok");
    try std.testing.expectError(
        error.WeixinAttachmentFileNotFound,
        c.sendAttachment(.voice, "definitely-missing-file.mp3", "", "u", "ctx"),
    );
}

test "readLocalFileAlloc rejects non-regular files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    if (readLocalFileAlloc(std.testing.allocator, "/dev/null")) |bytes| {
        defer std.testing.allocator.free(bytes);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.WeixinAttachmentNotRegularFile, err);
    }
}

test "readLocalFileAlloc rejects directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try std.testing.expectError(error.IsDir, readLocalFileAlloc(std.testing.allocator, root));
}

test "safe response excerpts redact sensitive fields and omit binary bodies" {
    const redacted = try safeDiagnosticTextAlloc(std.testing.allocator, "{\"context_token\":\"ctx-1\",\"aesKey\":\"secret\",\"encryptQueryParam\":\"param\",\"x-encrypted-param\":\"header-param\",\"accessToken\":\"access\",\"bot_token\":\"bot\",\"message\":\"line\nnext\"}");
    defer std.testing.allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "ctx-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\":\"param\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "header-param") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\":\"access\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\":\"bot\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "[redacted]") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "\\n") != null);

    const message = try safeDiagnosticTextAlloc(std.testing.allocator, "failed contextToken=ctx-2 aes_key=key-2 encrypted_param=param-2");
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "ctx-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "key-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "param-2") == null);

    const binary = try safeDiagnosticTextAlloc(std.testing.allocator, "abc\x00def");
    defer std.testing.allocator.free(binary);
    try std.testing.expectEqualStrings("[binary body omitted]", binary);

    const invalid_utf8 = try safeDiagnosticTextAlloc(std.testing.allocator, "abc\xffdef");
    defer std.testing.allocator.free(invalid_utf8);
    try std.testing.expectEqualStrings("[binary body omitted]", invalid_utf8);
}

test "readResponseBodyExcerpt caps diagnostic body reads" {
    var long_body: [Client.ERROR_BODY_EXCERPT_BYTES + 64]u8 = undefined;
    @memset(long_body[0..], 'a');
    var reader: std.Io.Reader = .fixed(&long_body);
    const excerpt = try readResponseBodyExcerpt(std.testing.allocator, &reader);
    defer std.testing.allocator.free(excerpt);
    try std.testing.expectEqual(@as(usize, Client.ERROR_BODY_EXCERPT_BYTES), excerpt.len);
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}

test "voice attachment uploads as a file item through injected transport" {
    const Capture = struct {
        getuploadurl_body: std.ArrayListUnmanaged(u8) = .empty,
        sendmessage_body: std.ArrayListUnmanaged(u8) = .empty,
        cdn_url: std.ArrayListUnmanaged(u8) = .empty,
        cdn_ticket: std.ArrayListUnmanaged(u8) = .empty,
        encrypted_len: usize = 0,

        fn deinit(self: *@This()) void {
            self.getuploadurl_body.deinit(std.testing.allocator);
            self.sendmessage_body.deinit(std.testing.allocator);
            self.cdn_url.deinit(std.testing.allocator);
            self.cdn_ticket.deinit(std.testing.allocator);
        }

        fn fetch(
            ctx: ?*anyopaque,
            client: *Client,
            arena: std.mem.Allocator,
            method: std.http.Method,
            path: []const u8,
            payload: ?[]const u8,
            client_version: ?[]const u8,
        ) anyerror![]u8 {
            _ = client;
            _ = client_version;
            try std.testing.expectEqual(std.http.Method.POST, method);
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (std.mem.eql(u8, path, "/ilink/bot/getuploadurl")) {
                try self.getuploadurl_body.appendSlice(std.testing.allocator, payload.?);
                return arena.dupe(u8,
                    \\{"ret":0,"url":"https://cdn.test/upload","ticket":"ticket=abc","file_key":"server-file-key"}
                );
            }
            if (std.mem.eql(u8, path, "/ilink/bot/sendmessage")) {
                try self.sendmessage_body.appendSlice(std.testing.allocator, payload.?);
                return arena.dupe(u8, "{\"ret\":0}");
            }
            return error.UnexpectedPath;
        }

        fn uploadCdn(
            ctx: ?*anyopaque,
            client: *Client,
            arena: std.mem.Allocator,
            upload_url: []const u8,
            ticket: []const u8,
            encrypted: []u8,
        ) anyerror![]u8 {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            try self.cdn_url.appendSlice(std.testing.allocator, upload_url);
            try self.cdn_ticket.appendSlice(std.testing.allocator, ticket);
            self.encrypted_len = encrypted.len;
            return arena.dupe(u8, "encrypted-param");
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "voice.mp3", .data = "hello" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "voice.mp3" });
    defer std.testing.allocator.free(path);

    var capture = Capture{};
    defer capture.deinit();
    var c = Client.init(std.testing.allocator, "https://x.test", "tok");
    c.transport_ctx = &capture;
    c.fetch_impl = Capture.fetch;
    c.cdn_upload_impl = Capture.uploadCdn;

    try c.sendAttachment(.voice, path, "", "wx-user", "ctx-1");

    try std.testing.expect(std.mem.indexOf(u8, capture.getuploadurl_body.items, "\"media_type\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.getuploadurl_body.items, "\"size\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.getuploadurl_body.items, "\"md5\":\"5d41402abc4b2a76b9719d911017c592\"") != null);
    try std.testing.expectEqualStrings("https://cdn.test/upload", capture.cdn_url.items);
    try std.testing.expectEqualStrings("ticket=abc", capture.cdn_ticket.items);
    try std.testing.expectEqual(@as(usize, 16), capture.encrypted_len);
    try std.testing.expect(std.mem.indexOf(u8, capture.sendmessage_body.items, "\"type\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.sendmessage_body.items, "\"file_item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.sendmessage_body.items, "\"voice_item\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.sendmessage_body.items, "\"file_name\":\"voice.mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.sendmessage_body.items, "\"encrypt_query_param\":\"encrypted-param\"") != null);
}
