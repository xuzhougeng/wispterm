//! In-memory representations of ilink protocol values. No I/O lives here;
//! `ilink_codec.zig` converts wire JSON to/from these.

const std = @import("std");

pub const InboundMedia = struct {
    encrypt_query_param: []const u8 = "",
    aes_key: []const u8 = "",
};

pub const MessageItem = struct {
    type: i64 = 0,
    /// text from a text_item (type 1)
    text: []const u8 = "",
    /// transcribed text from a voice_item (type 3)
    voice_text: []const u8 = "",
    /// CDN media for an inbound image (type 2) or file (type 4)
    media: ?InboundMedia = null,
    /// original file name from a file_item (type 4)
    file_name: []const u8 = "",
};

pub const Message = struct {
    from_user_id: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    group_id: []const u8 = "",
    item_list: []const MessageItem = &.{},
};

pub const AttachmentKind = enum {
    file,
    image,
    voice,

    pub fn parse(value: []const u8) ?AttachmentKind {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "file")) return .file;
        if (std.ascii.eqlIgnoreCase(trimmed, "image")) return .image;
        if (std.ascii.eqlIgnoreCase(trimmed, "voice")) return .voice;
        return null;
    }

    pub fn name(self: AttachmentKind) []const u8 {
        return switch (self) {
            .file => "file",
            .image => "image",
            .voice => "voice",
        };
    }

    pub fn uploadMediaType(self: AttachmentKind) i64 {
        return switch (self) {
            .image => 1,
            .file, .voice => 3,
        };
    }
};

pub const UploadUrl = struct {
    upload_param: []const u8 = "",
    upload_full_url: []const u8 = "",
    file_key: []const u8 = "",
    ret: i64 = 0,
    errcode: i64 = 0,
    message: []const u8 = "",
};

pub const CdnMedia = struct {
    encrypt_query_param: []const u8,
    aes_key: []const u8,
    encrypt_type: i64 = 1,
    md5: []const u8 = "",
    size: u64 = 0,
    file_key: []const u8 = "",
};

pub const UploadedFileAttachment = struct {
    media: CdnMedia,
    file_name: []const u8,
    len: u64,
};

pub const UploadedImage = struct {
    media: CdnMedia,
    mid_size: u64,
};

pub const AttachmentSender = struct {
    ctx: *anyopaque,
    send_attachment: *const fn (
        ctx: *anyopaque,
        kind: AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void,

    pub fn sendAttachment(
        self: AttachmentSender,
        kind: AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) !void {
        return self.send_attachment(self.ctx, kind, path, display_name, to_user_id, context_token);
    }
};

pub const ReplyContext = struct {
    sender: AttachmentSender,
    to_user_id: []const u8,
    context_token: []const u8,
};

pub const GetUpdatesResult = struct {
    ret: i64 = 0,
    errcode: i64 = 0,
    longpolling_timeout_ms: i64 = 0,
    get_updates_buf: []const u8 = "",
    msgs: []const Message = &.{},
};

pub const QrCode = struct {
    ret: i64 = 0,
    qrcode: []const u8 = "",
    /// Text payload that must be encoded into the scanable QR image.
    qrcode_img_content: []const u8 = "",
};

pub const QrStatusKind = enum { wait, scaned, confirmed, expired, unknown };

pub const QrStatus = struct {
    ret: i64 = 0,
    status: QrStatusKind = .unknown,
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    bot_id: []const u8 = "",
    user_id: []const u8 = "",
};

pub const Settings = struct {
    enabled: bool = false,
    reply_timeout_ms: u32 = 120000,
    /// empty ⇒ auto-bind first sender
    allowed_user: []const u8 = "",
};

pub const Binding = struct {
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    owner_user_id: []const u8 = "",
    bot_id: []const u8 = "",
    sync_buf: []const u8 = "",
};

const t = std.testing;

test "AttachmentKind parses accepted tool values" {
    try t.expectEqual(AttachmentKind.file, AttachmentKind.parse("file").?);
    try t.expectEqual(AttachmentKind.image, AttachmentKind.parse("image").?);
    try t.expectEqual(AttachmentKind.voice, AttachmentKind.parse("voice").?);
    try t.expect(AttachmentKind.parse("video") == null);
    try t.expectEqualStrings("file", AttachmentKind.file.name());
    try t.expectEqualStrings("image", AttachmentKind.image.name());
    try t.expectEqualStrings("voice", AttachmentKind.voice.name());
    try t.expectEqual(@as(i64, 1), AttachmentKind.image.uploadMediaType());
    try t.expectEqual(@as(i64, 3), AttachmentKind.file.uploadMediaType());
    try t.expectEqual(@as(i64, 3), AttachmentKind.voice.uploadMediaType());
}

test "AttachmentSender forwards typed send calls" {
    const Capture = struct {
        called: bool = false,
        kind: AttachmentKind = .file,
        path: []const u8 = "",
        display_name: []const u8 = "",
        to_user_id: []const u8 = "",
        context_token: []const u8 = "",

        fn send(
            ctx: *anyopaque,
            kind: AttachmentKind,
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
    };

    var capture = Capture{};
    const sender = AttachmentSender{ .ctx = &capture, .send_attachment = Capture.send };
    try sender.sendAttachment(.image, "C:\\tmp\\plot.png", "plot.png", "wx-user", "ctx-1");

    try t.expect(capture.called);
    try t.expectEqual(AttachmentKind.image, capture.kind);
    try t.expectEqualStrings("C:\\tmp\\plot.png", capture.path);
    try t.expectEqualStrings("plot.png", capture.display_name);
    try t.expectEqualStrings("wx-user", capture.to_user_id);
    try t.expectEqualStrings("ctx-1", capture.context_token);
}
