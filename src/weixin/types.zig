//! In-memory representations of ilink protocol values. No I/O lives here;
//! `ilink_codec.zig` converts wire JSON to/from these.

const std = @import("std");

const reply = @import("../chatops/reply.zig");
pub const AttachmentKind = reply.AttachmentKind;
pub const AttachmentSender = reply.AttachmentSender;
pub const ReplyContext = reply.ReplyContext;
pub const QuestionReply = reply.QuestionReply;

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


