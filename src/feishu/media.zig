//! 飞书 IM 媒体 REST — M3.1.
//! 图片/文件上传 + 收到消息的附件下载。
//! Security: token 不打印、不记录。
//! 上传依赖 multipart/form-data；核心编码抽为纯函数 buildMultipart 以便离线测试。

const std = @import("std");

const log = std.log.scoped(.feishu_media);

const BASE = "https://open.feishu.cn";

// ---------------------------------------------------------------------------
// multipart/form-data — pure, offline-testable
// ---------------------------------------------------------------------------

pub const Part = struct {
    name: []const u8,
    /// null → no filename parameter (plain text field)
    filename: ?[]const u8 = null,
    /// content_type: when null → "text/plain" (for text fields)
    content_type: ?[]const u8 = null,
    value: []const u8,
};

pub const MultipartResult = struct {
    body: []u8,
    boundary: []u8,

    pub fn deinit(self: MultipartResult, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        alloc.free(self.boundary);
    }
};

/// Builds a multipart/form-data body from the given parts.
/// Returns owned body + boundary strings; caller must free via result.deinit().
/// Use the boundary in Content-Type: multipart/form-data; boundary=<boundary>.
pub fn buildMultipart(alloc: std.mem.Allocator, parts: []const Part) !MultipartResult {
    // Fixed boundary — deterministic for tests, unique enough for single-request use.
    // ponytail: static boundary is fine for sequential requests; randomise if reusing client across concurrent uploads.
    const boundary = try alloc.dupe(u8, "----WispTermFeishuBoundary7f3a9b2c");
    errdefer alloc.free(boundary);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    for (parts) |part| {
        // "--boundary\r\n"
        try buf.appendSlice(alloc, "--");
        try buf.appendSlice(alloc, boundary);
        try buf.appendSlice(alloc, "\r\n");

        // Content-Disposition
        try buf.appendSlice(alloc, "Content-Disposition: form-data; name=\"");
        try buf.appendSlice(alloc, part.name);
        try buf.append(alloc, '"');
        if (part.filename) |fn_| {
            try buf.appendSlice(alloc, "; filename=\"");
            try buf.appendSlice(alloc, fn_);
            try buf.append(alloc, '"');
        }
        try buf.appendSlice(alloc, "\r\n");

        // Content-Type (only for binary parts; skip for plain text fields)
        if (part.content_type) |ct| {
            try buf.appendSlice(alloc, "Content-Type: ");
            try buf.appendSlice(alloc, ct);
            try buf.appendSlice(alloc, "\r\n");
        }

        // blank line + value
        try buf.appendSlice(alloc, "\r\n");
        try buf.appendSlice(alloc, part.value);
        try buf.appendSlice(alloc, "\r\n");
    }

    // "--boundary--\r\n"
    try buf.appendSlice(alloc, "--");
    try buf.appendSlice(alloc, boundary);
    try buf.appendSlice(alloc, "--\r\n");

    return .{
        .body = try buf.toOwnedSlice(alloc),
        .boundary = boundary,
    };
}

// ---------------------------------------------------------------------------
// uploadImage
// ---------------------------------------------------------------------------

/// Uploads image bytes to Feishu IM.  Returns the image_key; caller owns the slice.
/// Max size: 10 MB (enforced by Feishu; not checked here).
pub fn uploadImage(alloc: std.mem.Allocator, token: []const u8, image_bytes: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = [_]Part{
        .{ .name = "image_type", .value = "message" },
        .{ .name = "image", .filename = "image.png", .content_type = "application/octet-stream", .value = image_bytes },
    };
    const mp = try buildMultipart(a, &parts);
    // mp is arena-owned, no manual free needed

    const ct = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{mp.boundary});

    const resp_bytes = try httpsPostMultipart(alloc, a, BASE ++ "/open-apis/im/v1/images", token, mp.body, ct);

    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: struct { image_key: []const u8 = "" } = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.code != 0) {
        log.err("uploadImage: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuUploadImageFailed;
    }
    return alloc.dupe(u8, parsed.data.image_key);
}

// ---------------------------------------------------------------------------
// uploadFile
// ---------------------------------------------------------------------------

/// Uploads a file to Feishu IM.  Returns the file_key; caller owns the slice.
/// file_type: "opus"|"mp4"|"pdf"|"doc"|"xls"|"ppt"|"stream".
/// Max size: 30 MB (enforced by Feishu; not checked here).
pub fn uploadFile(
    alloc: std.mem.Allocator,
    token: []const u8,
    file_name: []const u8,
    file_type: []const u8,
    file_bytes: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = [_]Part{
        .{ .name = "file_type", .value = file_type },
        .{ .name = "file_name", .value = file_name },
        .{ .name = "file", .filename = file_name, .content_type = "application/octet-stream", .value = file_bytes },
    };
    const mp = try buildMultipart(a, &parts);

    const ct = try std.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{mp.boundary});

    const resp_bytes = try httpsPostMultipart(alloc, a, BASE ++ "/open-apis/im/v1/files", token, mp.body, ct);

    const Resp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: struct { file_key: []const u8 = "" } = .{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Resp, a, resp_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (parsed.code != 0) {
        log.err("uploadFile: code={d} msg={s}", .{ parsed.code, parsed.msg });
        return error.FeishuUploadFileFailed;
    }
    return alloc.dupe(u8, parsed.data.file_key);
}

// ---------------------------------------------------------------------------
// downloadResource
// ---------------------------------------------------------------------------

pub const ResourceKind = enum { image, file };

/// Downloads a resource from an inbound Feishu message.
/// Use the messages/.../resources endpoint (NOT /images/:image_key — that only
/// serves bot-uploaded images; inbound attachments require this path).
/// Returns the raw resource bytes; caller owns the slice.
/// Max size: ~100 MB (large; caller should stream-to-disk for production use).
pub fn downloadResource(
    alloc: std.mem.Allocator,
    token: []const u8,
    message_id: []const u8,
    file_key: []const u8,
    kind: ResourceKind,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const kind_str: []const u8 = switch (kind) {
        .image => "image",
        .file => "file",
    };
    const url = try std.fmt.allocPrint(
        a,
        BASE ++ "/open-apis/im/v1/messages/{s}/resources/{s}?type={s}",
        .{ message_id, file_key, kind_str },
    );

    // httpsGetWithBearer returns bytes owned by arena `a`; dupe into the
    // caller's allocator before `defer arena.deinit()` frees them (UAF otherwise).
    const raw = try httpsGetWithBearer(alloc, a, url, token);
    return alloc.dupe(u8, raw);
}

// ---------------------------------------------------------------------------
// Internal HTTP helpers (mirror rest.zig patterns)
// ---------------------------------------------------------------------------

fn httpsPostMultipart(
    client_alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
    content_type: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();

    // Build "Bearer <token>" in arena; never store or print token itself.
    const auth = try std.fmt.allocPrint(resp_arena, "Bearer {s}", .{token});

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = content_type },
            .authorization = .{ .override = auth },
        },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        log.warn("POST {s} -> HTTP {}", .{ stripQuery(url), response.status });
        return error.FeishuHttpError;
    }
    return out.toArrayList().items;
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
        log.warn("GET {s} -> HTTP {}", .{ stripQuery(url), response.status });
        return error.FeishuHttpError;
    }
    return out.toArrayList().items;
}

fn stripQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..q];
}

// ---------------------------------------------------------------------------
// Offline unit tests — buildMultipart only; network calls not tested
// ---------------------------------------------------------------------------

test "buildMultipart: single text field" {
    const parts = [_]Part{
        .{ .name = "image_type", .value = "message" },
    };
    const mp = try buildMultipart(std.testing.allocator, &parts);
    defer mp.deinit(std.testing.allocator);

    const body = mp.body;
    const bnd = mp.boundary;

    // starts with --boundary
    try std.testing.expect(std.mem.startsWith(u8, body, "--"));
    try std.testing.expect(std.mem.indexOf(u8, body, bnd) != null);
    // Content-Disposition present
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"image_type\"") != null);
    // field value present
    try std.testing.expect(std.mem.indexOf(u8, body, "message") != null);
    // terminator
    const terminator = try std.fmt.allocPrint(std.testing.allocator, "--{s}--\r\n", .{bnd});
    defer std.testing.allocator.free(terminator);
    try std.testing.expect(std.mem.indexOf(u8, body, terminator) != null);
}

test "buildMultipart: binary part with filename" {
    const binary_data = "\x00\x01\x02\x03\xFF\xFE";
    const parts = [_]Part{
        .{ .name = "image_type", .value = "message" },
        .{ .name = "image", .filename = "photo.png", .content_type = "application/octet-stream", .value = binary_data },
    };
    const mp = try buildMultipart(std.testing.allocator, &parts);
    defer mp.deinit(std.testing.allocator);

    const body = mp.body;
    const bnd = mp.boundary;

    // Both part separators present (2 parts = 2 --boundary lines before terminator)
    var count: usize = 0;
    const delim = try std.fmt.allocPrint(std.testing.allocator, "--{s}\r\n", .{bnd});
    defer std.testing.allocator.free(delim);
    var search = body;
    while (std.mem.indexOf(u8, search, delim)) |idx| {
        count += 1;
        search = search[idx + delim.len ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // filename in Content-Disposition
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"photo.png\"") != null);
    // Content-Type for binary part
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: application/octet-stream") != null);
    // blank line separating headers from body (RFC 2046 §5.1.1)
    try std.testing.expect(std.mem.indexOf(u8, body, "\r\n\r\n") != null);
    // binary bytes survive verbatim
    try std.testing.expect(std.mem.indexOf(u8, body, binary_data) != null);
    // terminator
    const terminator = try std.fmt.allocPrint(std.testing.allocator, "--{s}--\r\n", .{bnd});
    defer std.testing.allocator.free(terminator);
    try std.testing.expect(std.mem.endsWith(u8, body, terminator));
}

test "buildMultipart: no filename on plain text field" {
    const parts = [_]Part{
        .{ .name = "file_type", .value = "pdf" },
    };
    const mp = try buildMultipart(std.testing.allocator, &parts);
    defer mp.deinit(std.testing.allocator);

    // no filename= in the disposition
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "filename") == null);
    // no Content-Type header (no content_type set)
    try std.testing.expect(std.mem.indexOf(u8, mp.body, "Content-Type") == null);
}
