//! In-memory representations of ilink protocol values. No I/O lives here;
//! `ilink_codec.zig` converts wire JSON to/from these.

pub const MessageItem = struct {
    type: i64 = 0,
    /// text from a text_item (type 1)
    text: []const u8 = "",
    /// transcribed text from a voice_item (type 3)
    voice_text: []const u8 = "",
};

pub const Message = struct {
    from_user_id: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    group_id: []const u8 = "",
    item_list: []const MessageItem = &.{},
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
    /// base64 PNG content, when the API returns an inline image
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
