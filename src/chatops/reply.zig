//! Channel-neutral reply types shared across IM channels (WeChat, Feishu, …).
//! No channel-specific wire format lives here.

const std = @import("std");

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
    /// Optional model-only context associated with the inbound message. The UI
    /// shows the visible prompt text, while AI request construction may append
    /// this context so tools can still access local resources such as saved
    /// inbound files.
    model_context: []const u8 = "",
};

/// A reply classified against a pending `ask_user` question.
/// `.ignore` never reaches the Control vtable — the agent router drops it so the
/// question stays pending (mirrors `approval_reply` ignoring empty replies).
pub const QuestionReply = union(enum) {
    /// Zero-based index into the option list.
    option: usize,
    /// Free-text answer (trimmed). Borrowed from the inbound message buffer.
    custom: []const u8,
    ignore,
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
