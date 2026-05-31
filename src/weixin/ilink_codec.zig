//! ilink JSON request builders and response parsers. Pure (std.json).
const std = @import("std");
const types = @import("types.zig");

pub const CHANNEL_VERSION = "1.0.2";
pub const BOT_TYPE = "3";
pub const DEFAULT_BASE_URL = "https://ilinkai.weixin.qq.com";

const BaseInfo = struct { channel_version: []const u8 };

pub fn buildGetUpdatesBody(allocator: std.mem.Allocator, buf: []const u8) ![]u8 {
    const Body = struct {
        get_updates_buf: []const u8,
        base_info: BaseInfo,
    };
    return std.json.Stringify.valueAlloc(allocator, Body{
        .get_updates_buf = buf,
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

const SendItemText = struct { text: []const u8 };
const SendItem = struct { type: i64 = 1, text_item: SendItemText };
const SendMsg = struct {
    to_user_id: []const u8,
    client_id: []const u8,
    message_type: i64 = 2,
    message_state: i64 = 2,
    context_token: []const u8,
    item_list: []const SendItem,
};

pub fn buildSendTextBody(
    allocator: std.mem.Allocator,
    to_user_id: []const u8,
    text: []const u8,
    context_token: []const u8,
    client_id: []const u8,
) ![]u8 {
    const Body = struct {
        msg: SendMsg,
        base_info: BaseInfo,
    };
    const items = [_]SendItem{.{ .text_item = .{ .text = text } }};
    return std.json.Stringify.valueAlloc(allocator, Body{
        .msg = .{
            .to_user_id = to_user_id,
            .client_id = client_id,
            .context_token = context_token,
            .item_list = &items,
        },
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

const WireCdnMedia = struct {
    encrypt_query_param: []const u8,
    aes_key: []const u8,
    encrypt_type: i64 = 1,
};

fn wireMedia(media: types.CdnMedia) WireCdnMedia {
    return .{
        .encrypt_query_param = media.encrypt_query_param,
        .aes_key = media.aes_key,
        .encrypt_type = media.encrypt_type,
    };
}

pub fn buildSendUploadedFileBody(
    allocator: std.mem.Allocator,
    to_user_id: []const u8,
    context_token: []const u8,
    client_id: []const u8,
    file: types.UploadedFileAttachment,
) ![]u8 {
    const FileItem = struct {
        media: WireCdnMedia,
        file_name: []const u8,
        len: []const u8,
    };
    const Item = struct { type: i64 = 4, file_item: FileItem };
    const Msg = struct {
        to_user_id: []const u8,
        client_id: []const u8,
        message_type: i64 = 2,
        message_state: i64 = 2,
        context_token: []const u8,
        item_list: []const Item,
    };
    const Body = struct { msg: Msg, base_info: BaseInfo };
    const len_text = try std.fmt.allocPrint(allocator, "{d}", .{file.len});
    defer allocator.free(len_text);
    const items = [_]Item{.{ .file_item = .{
        .media = wireMedia(file.media),
        .file_name = file.file_name,
        .len = len_text,
    } }};
    return std.json.Stringify.valueAlloc(allocator, Body{
        .msg = .{
            .to_user_id = to_user_id,
            .client_id = client_id,
            .context_token = context_token,
            .item_list = &items,
        },
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn buildSendUploadedImageBody(
    allocator: std.mem.Allocator,
    to_user_id: []const u8,
    context_token: []const u8,
    client_id: []const u8,
    image: types.UploadedImage,
) ![]u8 {
    const ImageItem = struct {
        media: WireCdnMedia,
        mid_size: u64,
    };
    const Item = struct { type: i64 = 2, image_item: ImageItem };
    const Msg = struct {
        to_user_id: []const u8,
        client_id: []const u8,
        message_type: i64 = 2,
        message_state: i64 = 2,
        context_token: []const u8,
        item_list: []const Item,
    };
    const Body = struct { msg: Msg, base_info: BaseInfo };
    const items = [_]Item{.{ .image_item = .{
        .media = wireMedia(image.media),
        .mid_size = image.mid_size,
    } }};
    return std.json.Stringify.valueAlloc(allocator, Body{
        .msg = .{
            .to_user_id = to_user_id,
            .client_id = client_id,
            .context_token = context_token,
            .item_list = &items,
        },
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn buildSendUploadedVoiceBody(
    allocator: std.mem.Allocator,
    to_user_id: []const u8,
    context_token: []const u8,
    client_id: []const u8,
    voice: types.UploadedVoice,
) ![]u8 {
    const VoiceItem = struct {
        media: WireCdnMedia,
        encode_type: i64,
        sample_rate: i64,
        playtime: i64,
    };
    const Item = struct { type: i64 = 3, voice_item: VoiceItem };
    const Msg = struct {
        to_user_id: []const u8,
        client_id: []const u8,
        message_type: i64 = 2,
        message_state: i64 = 2,
        context_token: []const u8,
        item_list: []const Item,
    };
    const Body = struct { msg: Msg, base_info: BaseInfo };
    const items = [_]Item{.{ .voice_item = .{
        .media = wireMedia(voice.media),
        .encode_type = voice.encode_type,
        .sample_rate = voice.sample_rate,
        .playtime = voice.playtime,
    } }};
    return std.json.Stringify.valueAlloc(allocator, Body{
        .msg = .{
            .to_user_id = to_user_id,
            .client_id = client_id,
            .context_token = context_token,
            .item_list = &items,
        },
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn buildGetUploadUrlBody(
    allocator: std.mem.Allocator,
    kind: types.AttachmentKind,
    size: u64,
    md5: []const u8,
    file_key: []const u8,
) ![]u8 {
    const Body = struct {
        media_type: i64,
        size: u64,
        md5: []const u8,
        file_key: []const u8,
        base_info: BaseInfo,
    };
    return std.json.Stringify.valueAlloc(allocator, Body{
        .media_type = kind.uploadMediaType(),
        .size = size,
        .md5 = md5,
        .file_key = file_key,
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn statusKindFromString(s: []const u8) types.QrStatusKind {
    if (std.mem.eql(u8, s, "wait")) return .wait;
    if (std.mem.eql(u8, s, "scaned")) return .scaned;
    if (std.mem.eql(u8, s, "confirmed")) return .confirmed;
    if (std.mem.eql(u8, s, "expired")) return .expired;
    return .unknown;
}

// --- response parsing ---

const WireItem = struct {
    type: i64 = 0,
    text_item: ?struct { text: []const u8 = "" } = null,
    voice_item: ?struct { text: []const u8 = "" } = null,
};
const WireMsg = struct {
    from_user_id: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    group_id: []const u8 = "",
    item_list: []const WireItem = &.{},
};
const WireUpdates = struct {
    ret: i64 = 0,
    errcode: i64 = 0,
    longpolling_timeout_ms: i64 = 0,
    get_updates_buf: []const u8 = "",
    msgs: []const WireMsg = &.{},
};

/// Owns the JSON arena; `value` borrows from it. Free with `deinit`.
pub const ParsedUpdates = struct {
    parsed: std.json.Parsed(WireUpdates),
    value: types.GetUpdatesResult,

    pub fn deinit(self: *ParsedUpdates) void {
        self.parsed.deinit();
    }
};

const WireUploadUrl = struct {
    ret: i64 = 0,
    errcode: i64 = 0,
    message: []const u8 = "",
    url: []const u8 = "",
    ticket: []const u8 = "",
    file_key: []const u8 = "",
};

pub const ParsedUploadUrl = struct {
    parsed: std.json.Parsed(WireUploadUrl),
    value: types.UploadUrl,

    pub fn deinit(self: *ParsedUploadUrl) void {
        self.parsed.deinit();
    }
};

pub fn parseGetUploadUrl(allocator: std.mem.Allocator, json: []const u8) !ParsedUploadUrl {
    const parsed = try std.json.parseFromSlice(WireUploadUrl, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    const wire = parsed.value;
    return .{
        .parsed = parsed,
        .value = .{
            .ret = wire.ret,
            .errcode = wire.errcode,
            .message = wire.message,
            .url = wire.url,
            .ticket = wire.ticket,
            .file_key = wire.file_key,
        },
    };
}

pub fn parseGetUpdates(allocator: std.mem.Allocator, json: []const u8) !ParsedUpdates {
    const parsed = try std.json.parseFromSlice(WireUpdates, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    const a = parsed.arena.allocator();
    const wire = parsed.value;

    const msgs = try a.alloc(types.Message, wire.msgs.len);
    for (wire.msgs, 0..) |wm, mi| {
        const items = try a.alloc(types.MessageItem, wm.item_list.len);
        for (wm.item_list, 0..) |wi, ii| {
            items[ii] = .{
                .type = wi.type,
                .text = if (wi.text_item) |x| x.text else "",
                .voice_text = if (wi.voice_item) |x| x.text else "",
            };
        }
        msgs[mi] = .{
            .from_user_id = wm.from_user_id,
            .to_user_id = wm.to_user_id,
            .context_token = wm.context_token,
            .group_id = wm.group_id,
            .item_list = items,
        };
    }

    return .{ .parsed = parsed, .value = .{
        .ret = wire.ret,
        .errcode = wire.errcode,
        .longpolling_timeout_ms = wire.longpolling_timeout_ms,
        .get_updates_buf = wire.get_updates_buf,
        .msgs = msgs,
    } };
}

const t = std.testing;

test "builds a getupdates body with the channel version" {
    const body = try buildGetUpdatesBody(t.allocator, "BUF==");
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"get_updates_buf\":\"BUF==\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"channel_version\":\"1.0.2\"") != null);
}

test "builds a sendmessage body with the text item" {
    const body = try buildSendTextBody(t.allocator, "u1", "hello", "ctx", "cid-1");
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"to_user_id\":\"u1\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"text\":\"hello\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"context_token\":\"ctx\"") != null);
}

test "parses a getupdates response into typed messages" {
    const json =
        \\{"ret":0,"longpolling_timeout_ms":1500,"get_updates_buf":"NEXT",
        \\"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":1,"text_item":{"text":"hi"}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 1500), parsed.value.longpolling_timeout_ms);
    try t.expectEqualStrings("NEXT", parsed.value.get_updates_buf);
    try t.expectEqual(@as(usize, 1), parsed.value.msgs.len);
    try t.expectEqualStrings("u1", parsed.value.msgs[0].from_user_id);
    try t.expectEqualStrings("hi", parsed.value.msgs[0].item_list[0].text);
}

test "maps qrcode status strings to the enum" {
    try t.expectEqual(types.QrStatusKind.scaned, statusKindFromString("scaned"));
    try t.expectEqual(types.QrStatusKind.confirmed, statusKindFromString("confirmed"));
    try t.expectEqual(types.QrStatusKind.unknown, statusKindFromString("nonsense"));
}

test "builds getuploadurl body for file media" {
    const body = try buildGetUploadUrlBody(t.allocator, .file, 123, "900150983cd24fb0d6963f7d28e17f72", "file-key");
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"media_type\":3") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"size\":123") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"md5\":\"900150983cd24fb0d6963f7d28e17f72\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"file_key\":\"file-key\"") != null);
}

test "parses getuploadurl response" {
    var parsed = try parseGetUploadUrl(t.allocator,
        \\{"ret":0,"errcode":0,"url":"https://cdn.example/upload","ticket":"ticket=abc","file_key":"file-key"}
    );
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 0), parsed.value.ret);
    try t.expectEqualStrings("https://cdn.example/upload", parsed.value.url);
    try t.expectEqualStrings("ticket=abc", parsed.value.ticket);
    try t.expectEqualStrings("file-key", parsed.value.file_key);
}

test "builds uploaded file sendmessage body" {
    const media = types.CdnMedia{
        .encrypt_query_param = "encrypted-param",
        .aes_key = "encoded-key",
        .md5 = "md5",
        .size = 64,
        .file_key = "file-key",
    };
    const body = try buildSendUploadedFileBody(t.allocator, "u1", "ctx", "cid", .{
        .media = media,
        .file_name = "report.pdf",
        .len = 123,
    });
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"type\":4") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"file_name\":\"report.pdf\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"len\":\"123\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"encrypt_query_param\":\"encrypted-param\"") != null);
}

test "builds uploaded image sendmessage body" {
    const media = types.CdnMedia{
        .encrypt_query_param = "encrypted-param",
        .aes_key = "encoded-key",
        .md5 = "md5",
        .size = 64,
        .file_key = "file-key",
    };
    const body = try buildSendUploadedImageBody(t.allocator, "u1", "ctx", "cid", .{
        .media = media,
        .mid_size = 64,
    });
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"type\":2") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"image_item\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"mid_size\":64") != null);
}

test "builds uploaded voice sendmessage body" {
    const media = types.CdnMedia{
        .encrypt_query_param = "encrypted-param",
        .aes_key = "encoded-key",
        .md5 = "md5",
        .size = 64,
        .file_key = "file-key",
    };
    const body = try buildSendUploadedVoiceBody(t.allocator, "u1", "ctx", "cid", .{
        .media = media,
        .encode_type = 7,
        .sample_rate = 44100,
        .playtime = 2700,
    });
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"type\":3") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"voice_item\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"encode_type\":7") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"sample_rate\":44100") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"playtime\":2700") != null);
}

test "parses inbound voice transcription into message item" {
    const json =
        \\{"ret":0,"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":3,"voice_item":{"text":"transcribed voice"}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 3), parsed.value.msgs[0].item_list[0].type);
    try t.expectEqualStrings("transcribed voice", parsed.value.msgs[0].item_list[0].voice_text);
}
