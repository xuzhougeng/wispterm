# Weixin Agent Attachments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the desktop direct Weixin bridge route inbound text and voice transcripts into AI Chat, and let AI Chat call `weixin_send_attachment` to send local `file`, `image`, or `voice` attachments back to the active Weixin conversation.

**Architecture:** Keep iLink upload protocol code inside `src/weixin/`, keep terminal/VT/rendering unaware of Weixin, and pass a short-lived reply context from the poller through the app control boundary into the AI Chat request. The Agent tool dispatch uses that context only when the current request came from Weixin; normal local AI Chat requests return a clear no-context tool result.

**Tech Stack:** Zig 0.15.2, `std.json`, `std.http.Client`, `std.crypto.core.aes.Aes128`, `std.crypto.hash.Md5`, existing AI Chat tool protocol, existing Weixin direct poller.

---

## Reference Notes

Ghostty has no Weixin bridge and no Agent tool layer. Its closest comparable feature is host-layer automation on macOS: App Intents and AppleScript commands call app/surface APIs such as `surface.sendText`, while VT parsing, terminal state, rendering, and fonts stay independent. Match that boundary here: Weixin tokens, upload URLs, CDN encryption, and reply context stay in `src/weixin/`, `src/AppWindow.zig`, and `src/ai_chat.zig`.

CiteBox reference mapping:

- `internal/weixin/types.go`: item types, upload URL request and CDN media structs.
- `internal/weixin/media.go`: upload URL flow, AES-ECB with PKCS7 padding, CDN upload, file/image/voice send bodies, voice codec mapping.
- `internal/weixin/cdn.go`: confirms `media.aes_key` is base64 of the hex-encoded AES key.
- `internal/service/weixin_im_bridge.go`: confirms inbound `voice_item.text` is the transcript used as ordinary text.

## File Structure

- Create `src/weixin/media.zig`: pure media helpers plus narrow `ffprobe` parsing helpers. No bot token storage.
- Modify `src/weixin/types.zig`: attachment kinds, upload URL response, CDN media structs, uploaded media structs, sender and reply context structs.
- Modify `src/weixin/ilink_codec.zig`: JSON builders for upload URL and typed sendmessage bodies; parser for upload URL response.
- Modify `src/weixin/ilink_client.zig`: high-level attachment send flow and `ClientApi.send_attachment`.
- Modify `src/weixin/control.zig`: pass optional Weixin reply context through `sendInput`.
- Modify `src/weixin/agent.zig`: route normal Weixin text into AI with reply context; keep `/term`, `/keys`, and `/stop` context-free.
- Modify `src/weixin/poller.zig`: route callback receives current `from_user_id` and `context_token`; build a reply context around the active iLink client.
- Modify `src/AppWindow.zig`: marshal reply context to the UI thread and call `Session.applyWeixinInput` for AI chat surfaces.
- Modify `src/ai_chat.zig`: own request-time Weixin reply context, tool dispatch, no-context behavior, fake sender tests.
- Modify `src/ai_chat_protocol.zig`: expose `weixin_send_attachment` in all tool schema builders.
- Modify `src/platform/agent_prompt.zig`: tell the Agent when to use the tool.
- Modify `src/test_fast.zig`: include pure Weixin modules in fast tests.

## Task 1: Add Attachment Types

**Files:**
- Modify: `src/weixin/types.zig`
- Test: `src/weixin/types.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write failing type tests**

Add this import and tests to `src/weixin/types.zig`. The import goes immediately after the file-level `//!` module comment.

```zig
const std = @import("std");
```

Append these tests at the end of `src/weixin/types.zig`.

```zig
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
            const self: *Capture = @ptrCast(@alignCast(ctx));
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
```

- [ ] **Step 2: Run the new module test and verify it fails**

Run:

```bash
zig test src/weixin/types.zig
```

Expected: FAIL with errors for `AttachmentKind` and `AttachmentSender` not existing.

- [ ] **Step 3: Add attachment structs and helpers**

Add these definitions after `pub const Message` in `src/weixin/types.zig`.

```zig
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
            .file => 3,
            .voice => 4,
        };
    }
};

pub const UploadUrl = struct {
    url: []const u8 = "",
    ticket: []const u8 = "",
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

pub const VoiceMetadata = struct {
    encode_type: i64,
    sample_rate: i64,
    playtime: i64,
    codec: []const u8 = "",
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

pub const UploadedVoice = struct {
    media: CdnMedia,
    encode_type: i64,
    sample_rate: i64,
    playtime: i64,
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
```

- [ ] **Step 4: Add Weixin modules to fast tests**

Append these imports inside the `test { ... }` block in `src/test_fast.zig`, near the existing `ai_chat_protocol.zig` import.

```zig
    _ = @import("weixin/types.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/binding.zig");
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
zig test src/weixin/types.zig
zig build test
```

Expected: both commands PASS.

Commit:

```bash
git add src/weixin/types.zig src/test_fast.zig
git commit -m "feat: add weixin attachment types"
```

## Task 2: Add Pure Media Helpers

**Files:**
- Create: `src/weixin/media.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Create failing tests in `src/weixin/media.zig`**

Create `src/weixin/media.zig` with this test-first skeleton.

```zig
//! Pure helpers for Weixin iLink media uploads.
const std = @import("std");
const types = @import("types.zig");

pub const AesKey = [16]u8;

pub fn pkcs7PaddedLen(input_len: usize) usize {
    _ = input_len;
    @compileError("pkcs7PaddedLen is not implemented");
}

pub fn aes128EcbPkcs7Encrypt(allocator: std.mem.Allocator, key: AesKey, plain: []const u8) ![]u8 {
    _ = allocator;
    _ = key;
    _ = plain;
    @compileError("aes128EcbPkcs7Encrypt is not implemented");
}

pub fn aes128EcbPkcs7DecryptForTest(allocator: std.mem.Allocator, key: AesKey, encrypted: []const u8) ![]u8 {
    _ = allocator;
    _ = key;
    _ = encrypted;
    @compileError("aes128EcbPkcs7DecryptForTest is not implemented");
}

pub fn encodeIlinkAesKey(allocator: std.mem.Allocator, key: AesKey) ![]u8 {
    _ = allocator;
    _ = key;
    @compileError("encodeIlinkAesKey is not implemented");
}

pub fn md5Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    _ = allocator;
    _ = data;
    @compileError("md5Hex is not implemented");
}

pub fn uploadUrlWithTicket(allocator: std.mem.Allocator, base_url: []const u8, ticket: []const u8) ![]u8 {
    _ = allocator;
    _ = base_url;
    _ = ticket;
    @compileError("uploadUrlWithTicket is not implemented");
}

pub fn voiceEncodeType(codec: []const u8, path: []const u8) !i64 {
    _ = codec;
    _ = path;
    @compileError("voiceEncodeType is not implemented");
}

pub fn parseFfprobeVoiceMetadata(allocator: std.mem.Allocator, json: []const u8, path: []const u8) !types.VoiceMetadata {
    _ = allocator;
    _ = json;
    _ = path;
    @compileError("parseFfprobeVoiceMetadata is not implemented");
}

const t = std.testing;

test "pkcs7 padding always adds at least one AES block" {
    try t.expectEqual(@as(usize, 16), pkcs7PaddedLen(0));
    try t.expectEqual(@as(usize, 16), pkcs7PaddedLen(1));
    try t.expectEqual(@as(usize, 16), pkcs7PaddedLen(15));
    try t.expectEqual(@as(usize, 32), pkcs7PaddedLen(16));
}

test "AES ECB PKCS7 encrypts and decrypts a short buffer" {
    const key: AesKey = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const encrypted = try aes128EcbPkcs7Encrypt(t.allocator, key, "hello");
    defer t.allocator.free(encrypted);
    try t.expectEqual(@as(usize, 16), encrypted.len);

    const decrypted = try aes128EcbPkcs7DecryptForTest(t.allocator, key, encrypted);
    defer t.allocator.free(decrypted);
    try t.expectEqualStrings("hello", decrypted);
}

test "AES key is encoded as base64 of hex bytes" {
    const key: AesKey = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const encoded = try encodeIlinkAesKey(t.allocator, key);
    defer t.allocator.free(encoded);
    try t.expectEqualStrings("MDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGY=", encoded);
}

test "md5Hex returns lowercase hex digest" {
    const digest = try md5Hex(t.allocator, "abc");
    defer t.allocator.free(digest);
    try t.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", digest);
}

test "uploadUrlWithTicket appends ticket query using question mark or ampersand" {
    const a = try uploadUrlWithTicket(t.allocator, "https://cdn.example/upload", "ticket=abc");
    defer t.allocator.free(a);
    try t.expectEqualStrings("https://cdn.example/upload?ticket=abc", a);

    const b = try uploadUrlWithTicket(t.allocator, "https://cdn.example/upload?x=1", "ticket=abc");
    defer t.allocator.free(b);
    try t.expectEqualStrings("https://cdn.example/upload?x=1&ticket=abc", b);
}

test "voiceEncodeType maps codec and extension values" {
    try t.expectEqual(@as(i64, 1), try voiceEncodeType("pcm_s16le", "note.wav"));
    try t.expectEqual(@as(i64, 5), try voiceEncodeType("amr_nb", "note.amr"));
    try t.expectEqual(@as(i64, 6), try voiceEncodeType("silk", "note.silk"));
    try t.expectEqual(@as(i64, 7), try voiceEncodeType("mp3", "note.mp3"));
    try t.expectEqual(@as(i64, 8), try voiceEncodeType("speex", "note.ogg"));
    try t.expectError(error.UnsupportedVoiceCodec, voiceEncodeType("aac", "note.m4a"));
}

test "parseFfprobeVoiceMetadata reads codec sample rate and duration" {
    const json =
        \\{"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","duration":"2.700000"}],
        \\"format":{"duration":"2.700000"}}
    ;
    const meta = try parseFfprobeVoiceMetadata(t.allocator, json, "voice.mp3");
    try t.expectEqual(@as(i64, 7), meta.encode_type);
    try t.expectEqual(@as(i64, 44100), meta.sample_rate);
    try t.expectEqual(@as(i64, 2700), meta.playtime);
    try t.expectEqualStrings("mp3", meta.codec);
}
```

- [ ] **Step 2: Run the new module test and verify it fails**

Run:

```bash
zig test src/weixin/media.zig
```

Expected: FAIL at compile time because the helper bodies are compile errors.

- [ ] **Step 3: Implement pure helpers**

Replace the compile-error bodies in `src/weixin/media.zig` with this code.

```zig
pub fn pkcs7PaddedLen(input_len: usize) usize {
    const block = 16;
    return input_len + (block - (input_len % block));
}

pub fn aes128EcbPkcs7Encrypt(allocator: std.mem.Allocator, key: AesKey, plain: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, pkcs7PaddedLen(plain.len));
    errdefer allocator.free(out);
    @memcpy(out[0..plain.len], plain);
    const pad: u8 = @intCast(out.len - plain.len);
    @memset(out[plain.len..], pad);

    var ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var offset: usize = 0;
    while (offset < out.len) : (offset += 16) {
        ctx.encrypt(out[offset .. offset + 16], out[offset .. offset + 16]);
    }
    return out;
}

pub fn aes128EcbPkcs7DecryptForTest(allocator: std.mem.Allocator, key: AesKey, encrypted: []const u8) ![]u8 {
    if (encrypted.len == 0 or encrypted.len % 16 != 0) return error.InvalidCiphertext;
    const padded = try allocator.dupe(u8, encrypted);
    errdefer allocator.free(padded);

    var ctx = std.crypto.core.aes.Aes128.initDec(key);
    var offset: usize = 0;
    while (offset < padded.len) : (offset += 16) {
        ctx.decrypt(padded[offset .. offset + 16], padded[offset .. offset + 16]);
    }
    const pad = padded[padded.len - 1];
    const pad_len: usize = pad;
    if (pad == 0 or pad > 16 or pad_len > padded.len) return error.InvalidPadding;
    for (padded[padded.len - pad_len ..]) |b| {
        if (b != pad) return error.InvalidPadding;
    }
    return allocator.realloc(padded, padded.len - pad_len);
}

pub fn encodeIlinkAesKey(allocator: std.mem.Allocator, key: AesKey) ![]u8 {
    const hex = try allocator.alloc(u8, key.len * 2);
    defer allocator.free(hex);
    _ = std.fmt.bufPrint(hex, "{}", .{std.fmt.fmtSliceHexLower(&key)}) catch unreachable;
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(hex.len));
    _ = std.base64.standard.Encoder.encode(out, hex);
    return out;
}

pub fn md5Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    _ = std.fmt.bufPrint(out, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return out;
}

pub fn uploadUrlWithTicket(allocator: std.mem.Allocator, base_url: []const u8, ticket: []const u8) ![]u8 {
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, base_url, '?') == null) "?" else "&";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_url, sep, ticket });
}

pub fn voiceEncodeType(codec: []const u8, path: []const u8) !i64 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(codec, "pcm_s16le") or std.ascii.eqlIgnoreCase(codec, "pcm_u8") or std.ascii.eqlIgnoreCase(ext, ".wav")) return 1;
    if (std.ascii.eqlIgnoreCase(codec, "amr_nb") or std.ascii.eqlIgnoreCase(codec, "amr_wb") or std.ascii.eqlIgnoreCase(ext, ".amr")) return 5;
    if (std.ascii.eqlIgnoreCase(codec, "silk") or std.ascii.eqlIgnoreCase(ext, ".silk")) return 6;
    if (std.ascii.eqlIgnoreCase(codec, "mp3") or std.ascii.eqlIgnoreCase(ext, ".mp3")) return 7;
    if (std.ascii.eqlIgnoreCase(codec, "speex") or std.ascii.eqlIgnoreCase(codec, "opus") or std.ascii.eqlIgnoreCase(codec, "vorbis") or std.ascii.eqlIgnoreCase(ext, ".ogg")) return 8;
    return error.UnsupportedVoiceCodec;
}

fn voiceCodecLabel(encode_type: i64) []const u8 {
    return switch (encode_type) {
        1 => "pcm",
        5 => "amr",
        6 => "silk",
        7 => "mp3",
        8 => "ogg",
        else => "unknown",
    };
}

pub fn parseFfprobeVoiceMetadata(allocator: std.mem.Allocator, json: []const u8, path: []const u8) !types.VoiceMetadata {
    const Probe = struct {
        streams: []struct {
            codec_type: []const u8 = "",
            codec_name: []const u8 = "",
            sample_rate: []const u8 = "",
            duration: []const u8 = "",
        } = &.{},
        format: struct { duration: []const u8 = "" } = .{},
    };
    var parsed = try std.json.parseFromSlice(Probe, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    for (parsed.value.streams) |stream| {
        if (!std.mem.eql(u8, stream.codec_type, "audio")) continue;
        const sample_rate = std.fmt.parseInt(i64, stream.sample_rate, 10) catch 0;
        const duration_text = if (stream.duration.len != 0) stream.duration else parsed.value.format.duration;
        const seconds = std.fmt.parseFloat(f64, duration_text) catch 0;
        const encode_type = try voiceEncodeType(stream.codec_name, path);
        return .{
            .encode_type = encode_type,
            .sample_rate = sample_rate,
            .playtime = @as(i64, @intFromFloat(@round(seconds * 1000.0))),
            .codec = voiceCodecLabel(encode_type),
        };
    }
    return error.NoAudioStream;
}
```

- [ ] **Step 4: Add `media.zig` to fast tests**

Add this import inside the `test { ... }` block in `src/test_fast.zig` next to the other Weixin imports.

```zig
    _ = @import("weixin/media.zig");
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
zig test src/weixin/media.zig
zig build test
```

Expected: both commands PASS.

Commit:

```bash
git add src/weixin/media.zig src/test_fast.zig
git commit -m "feat: add weixin media helpers"
```

## Task 3: Add iLink Attachment JSON Codecs

**Files:**
- Modify: `src/weixin/ilink_codec.zig`

- [ ] **Step 1: Write failing codec tests**

Append these tests to `src/weixin/ilink_codec.zig`.

```zig
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
```

- [ ] **Step 2: Run codec tests and verify they fail**

Run:

```bash
zig test src/weixin/ilink_codec.zig
```

Expected: FAIL with missing `buildGetUploadUrlBody`, `parseGetUploadUrl`, and typed send builders.

- [ ] **Step 3: Add upload URL codecs**

Add this parsed wrapper near `ParsedUpdates` in `src/weixin/ilink_codec.zig`.

```zig
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
```

- [ ] **Step 4: Add typed sendmessage builders**

Add these structs and functions after `buildSendTextBody` in `src/weixin/ilink_codec.zig`.

```zig
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
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
zig test src/weixin/ilink_codec.zig
zig build test
```

Expected: both commands PASS.

Commit:

```bash
git add src/weixin/ilink_codec.zig
git commit -m "feat: build weixin attachment payloads"
```

## Task 4: Implement iLink Client Attachment Sending

**Files:**
- Modify: `src/weixin/ilink_client.zig`

- [ ] **Step 1: Write failing ClientApi and helper tests**

Append these tests to `src/weixin/ilink_client.zig`.

```zig
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
            const self: *Capture = @ptrCast(@alignCast(ctx));
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
```

- [ ] **Step 2: Run client tests and verify they fail**

Run:

```bash
zig test src/weixin/ilink_client.zig
```

Expected: FAIL because `ClientApi.VTable.send_attachment`, `ClientApi.sendAttachment`, and `Client.clientId` do not exist.

- [ ] **Step 3: Extend `ClientApi`**

In `src/weixin/ilink_client.zig`, extend `ClientApi.VTable` and methods to this shape.

```zig
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
```

- [ ] **Step 4: Factor client ID creation**

In `src/weixin/ilink_client.zig`, add this public helper inside `Client`.

```zig
    pub fn clientId(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "wispterm-weixin-{d}-{d}", .{
            std.time.milliTimestamp(), self.nextRandomU32(),
        });
    }
```

Update `sendText` to use it:

```zig
        const client_id = try self.clientId(a);
```

- [ ] **Step 5: Add high-level upload and send flow**

Add `const media = @import("media.zig");` near the imports in `src/weixin/ilink_client.zig`.

Add these functions inside `Client`.

```zig
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

        const uploaded = try self.uploadLocalFile(a, .voice, path);
        const meta = try self.probeVoiceFile(a, path);
        const client_id = try self.clientId(a);
        const body = try codec.buildSendUploadedVoiceBody(a, to_user_id, context_token, client_id, .{
            .media = uploaded.media,
            .encode_type = meta.encode_type,
            .sample_rate = meta.sample_rate,
            .playtime = meta.playtime,
        });
        try self.postSendMessage(a, body);
    }
```

Add these helper functions inside `Client`.

```zig
    const UploadedLocalFile = struct {
        media: types.CdnMedia,
        raw_len: u64,
        encrypted_len: u64,
    };

    fn uploadLocalFile(self: *Client, arena: std.mem.Allocator, kind: types.AttachmentKind, path: []const u8) !UploadedLocalFile {
        const file_bytes = readLocalFileAlloc(arena, path) catch |err| switch (err) {
            error.FileNotFound => return error.WeixinAttachmentFileNotFound,
            error.IsDir => return error.WeixinAttachmentPathIsDirectory,
            else => return err,
        };
        const md5 = try media.md5Hex(arena, file_bytes);

        var file_key_bytes: [16]u8 = undefined;
        self.randomBytes(&file_key_bytes);
        const file_key = try std.fmt.allocPrint(arena, "{}", .{std.fmt.fmtSliceHexLower(&file_key_bytes)});

        var aes_key: media.AesKey = undefined;
        self.randomBytes(&aes_key);
        const encoded_key = try media.encodeIlinkAesKey(arena, aes_key);

        const upload = try self.getUploadUrl(arena, kind, file_bytes.len, md5, file_key);
        if (upload.ret != 0) return error.IlinkGetUploadUrlFailed;
        if (upload.url.len == 0 or upload.ticket.len == 0) return error.IlinkGetUploadUrlMalformed;

        const encrypted = try media.aes128EcbPkcs7Encrypt(arena, aes_key, file_bytes);
        const encrypted_param = try self.uploadBufferToCdn(arena, upload.url, upload.ticket, encrypted);

        return .{
            .media = .{
                .encrypt_query_param = encrypted_param,
                .aes_key = encoded_key,
                .encrypt_type = 1,
                .md5 = md5,
                .size = file_bytes.len,
                .file_key = file_key,
            },
            .raw_len = file_bytes.len,
            .encrypted_len = encrypted.len,
        };
    }

    fn getUploadUrl(self: *Client, arena: std.mem.Allocator, kind: types.AttachmentKind, size: u64, md5: []const u8, file_key: []const u8) !types.UploadUrl {
        const body = try codec.buildGetUploadUrlBody(arena, kind, size, md5, file_key);
        const resp = try self.fetch(arena, .POST, "/ilink/bot/getuploadurl", body, null);
        var parsed = try codec.parseGetUploadUrl(arena, resp);
        defer parsed.deinit();
        const value = parsed.value;
        if (value.ret != 0) {
            std.debug.print("weixin upload({d}): getuploadurl failed ret={} errcode={} message={s}\n", .{
                std.time.milliTimestamp(), value.ret, value.errcode, value.message,
            });
        }
        return .{
            .ret = value.ret,
            .errcode = value.errcode,
            .message = try arena.dupe(u8, value.message),
            .url = try arena.dupe(u8, value.url),
            .ticket = try arena.dupe(u8, value.ticket),
            .file_key = try arena.dupe(u8, value.file_key),
        };
    }

    fn uploadBufferToCdn(self: *Client, arena: std.mem.Allocator, upload_url: []const u8, ticket: []const u8, encrypted: []const u8) ![]const u8 {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const url = try media.uploadUrlWithTicket(arena, upload_url, ticket);
        const uri = try std.Uri.parse(url);
        var req = try client.request(.POST, uri, .{
            .keep_alive = false,
            .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = encrypted.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(encrypted);
        try body.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        if (response.head.status != .ok) {
            std.debug.print("weixin upload({d}): cdn failed status={}\n", .{ std.time.milliTimestamp(), response.head.status });
            return error.WeixinCdnUploadFailed;
        }
        var encrypted_param: ?[]u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-encrypted-param")) {
                encrypted_param = try arena.dupe(u8, header.value);
                break;
            }
        }

        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch {};
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
                std.debug.print("weixin send({d}): kind=attachment status=failed ret={} errcode={} message={s}\n", .{
                    std.time.milliTimestamp(), ret, w.errcode, w.message,
                });
                return error.IlinkSendMessageFailed;
            }
        }
    }

    fn probeVoiceFile(self: *Client, arena: std.mem.Allocator, path: []const u8) !types.VoiceMetadata {
        _ = self;
        var child = std.process.Child.init(&.{
            "ffprobe",
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,sample_rate,duration:format=duration",
            "-of", "json",
            path,
        }, arena);
        child.stdin_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        const result = child.run() catch |err| switch (err) {
            error.FileNotFound => return error.FfprobeNotFound,
            else => return err,
        };
        defer arena.free(result.stdout);
        defer arena.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) return error.FfprobeFailed;
        return media.parseFfprobeVoiceMetadata(arena, result.stdout, path);
    }

    fn randomBytes(self: *Client, out: []u8) void {
        self.rng_mutex.lock();
        defer self.rng_mutex.unlock();
        self.rng.random().bytes(out);
    }
```

Add this file-level helper after `appendQueryEscaped`.

```zig
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
```

- [ ] **Step 6: Wire the real adapter and fakes**

Update `Client.api()` in `src/weixin/ilink_client.zig`.

```zig
    pub fn api(self: *Client) ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = apiGetUpdates,
            .send_text = apiSendText,
            .send_attachment = apiSendAttachment,
        } };
    }
```

Add this adapter.

```zig
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
```

Any test fake that constructs `ClientApi.VTable` must add:

```zig
            .send_attachment = sendAttachment,
```

and this no-op or capture function:

```zig
    fn sendAttachment(ctx: *anyopaque, kind: types.AttachmentKind, path: []const u8, display_name: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void {
        _ = ctx;
        _ = kind;
        _ = path;
        _ = display_name;
        _ = to_user_id;
        _ = context_token;
    }
```

- [ ] **Step 7: Run tests and commit**

Run:

```bash
zig test src/weixin/ilink_client.zig
zig build test
```

Expected: both commands PASS.

Commit:

```bash
git add src/weixin/ilink_client.zig
git commit -m "feat: send weixin attachments through ilink"
```

## Task 5: Expose the Agent Tool Schema and Prompt

**Files:**
- Modify: `src/ai_chat_protocol.zig`
- Modify: `src/platform/agent_prompt.zig`

- [ ] **Step 1: Write failing schema and prompt tests**

Append this test to `src/ai_chat_protocol.zig`.

```zig
test "tool schemas include weixin_send_attachment" {
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("send the report") }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
    };
    const json = try buildRequestJson(std.testing.allocator, params, &msgs, true);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"weixin_send_attachment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"display_name\"") != null);
}
```

Append this test to `src/platform/agent_prompt.zig`.

```zig
test "platform agent prompt describes the Weixin attachment tool" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "weixin_send_attachment") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "kind=image") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "kind=voice") != null);
        try std.testing.expect(std.mem.indexOf(u8, p, "kind=file") != null);
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
zig test src/ai_chat_protocol.zig
zig test src/platform/agent_prompt.zig
```

Expected: both fail because the schema and prompt do not mention `weixin_send_attachment`.

- [ ] **Step 3: Add tool schema**

In `src/ai_chat_protocol.zig`, add this `emit` call inside `forEachToolSpec`, after `wispterm_docs`.

```zig
    try emit(ctx, "weixin_send_attachment", "Send a local file back to the active Weixin conversation that triggered this agent request. Use only when the current request came from Weixin; normal local chat requests have no Weixin reply context.", "{\"kind\":{\"type\":\"string\",\"description\":\"Attachment kind: file, image, or voice.\"},\"path\":{\"type\":\"string\",\"description\":\"Readable local file path to send.\"},\"display_name\":{\"type\":\"string\",\"description\":\"Optional filename shown in Weixin for file attachments; defaults to the path basename.\"}}");
```

- [ ] **Step 4: Add prompt guidance**

In `src/platform/agent_prompt.zig`, insert these lines in `common_tools_after_wsl`, after the `wispterm_docs` bullet and before the blank line that precedes `Python:`.

```zig
    \\- When the request came from Weixin and the user asks you to send a generated or local artifact, call `weixin_send_attachment`.
    \\- Use `kind=image` for image previews, `kind=voice` only for playable voice messages, and `kind=file` for ordinary attachments.
    \\- If voice metadata probing fails or playback as an in-chat voice message is not required, send the same path with `kind=file`.
```

- [ ] **Step 5: Run tests and commit**

Run:

```bash
zig test src/ai_chat_protocol.zig
zig test src/platform/agent_prompt.zig
zig build test
```

Expected: all commands PASS.

Commit:

```bash
git add src/ai_chat_protocol.zig src/platform/agent_prompt.zig
git commit -m "feat: expose weixin attachment tool"
```

## Task 6: Add Weixin Context and Tool Dispatch in AI Chat

**Files:**
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Add failing tool dispatch tests**

Add `const weixin_types = @import("weixin/types.zig");` near the imports in `src/ai_chat.zig`.

Append these tests near the other `executeToolCall` tests in `src/ai_chat.zig`.

```zig
const WeixinAttachmentCapture = struct {
    called: bool = false,
    kind: weixin_types.AttachmentKind = .file,
    path: []const u8 = "",
    display_name: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",

    fn send(
        ctx: *anyopaque,
        kind: weixin_types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *WeixinAttachmentCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.kind = kind;
        self.path = path;
        self.display_name = display_name;
        self.to_user_id = to_user_id;
        self.context_token = context_token;
    }
};

fn testWeixinSender(capture: *WeixinAttachmentCapture) weixin_types.AttachmentSender {
    return .{ .ctx = capture, .send_attachment = WeixinAttachmentCapture.send };
}

test "weixin_send_attachment without reply context returns a clear tool result" {
    var session = try Session.init(
        std.testing.allocator,
        "test",
        "https://api.example",
        "key",
        "model",
        "prompt",
        "enabled",
        "medium",
        "false",
        "true",
    );
    defer session.deinit();

    const request = try std.testing.allocator.create(ChatRequest);
    request.* = .{
        .allocator = std.testing.allocator,
        .session = session,
        .base_url = try std.testing.allocator.dupe(u8, "https://api.example"),
        .api_key = try std.testing.allocator.dupe(u8, "key"),
        .model = try std.testing.allocator.dupe(u8, "model"),
        .system_prompt = try std.testing.allocator.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try std.testing.allocator.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    defer request.deinit();

    var call = ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_1"),
        .name = try std.testing.allocator.dupe(u8, "weixin_send_attachment"),
        .arguments = try std.testing.allocator.dupe(u8, "{\"kind\":\"image\",\"path\":\"C:\\\\tmp\\\\plot.png\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(request, call);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("No active Weixin reply context; cannot send attachment.", result);
}

test "weixin_send_attachment calls the active Weixin sender" {
    var capture = WeixinAttachmentCapture{};
    var session = try Session.init(
        std.testing.allocator,
        "test",
        "https://api.example",
        "key",
        "model",
        "prompt",
        "enabled",
        "medium",
        "false",
        "true",
    );
    defer session.deinit();

    const request = try std.testing.allocator.create(ChatRequest);
    request.* = .{
        .allocator = std.testing.allocator,
        .session = session,
        .base_url = try std.testing.allocator.dupe(u8, "https://api.example"),
        .api_key = try std.testing.allocator.dupe(u8, "key"),
        .model = try std.testing.allocator.dupe(u8, "model"),
        .system_prompt = try std.testing.allocator.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try std.testing.allocator.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
        .weixin_reply_context = try WeixinReplyContext.init(std.testing.allocator, .{
            .sender = testWeixinSender(&capture),
            .to_user_id = "wx-user",
            .context_token = "ctx-1",
        }),
    };
    defer request.deinit();

    var call = ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_1"),
        .name = try std.testing.allocator.dupe(u8, "weixin_send_attachment"),
        .arguments = try std.testing.allocator.dupe(u8, "{\"kind\":\"file\",\"path\":\"C:\\\\tmp\\\\report.pdf\",\"display_name\":\"report.pdf\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try executeToolCall(request, call);
    defer std.testing.allocator.free(result);

    try std.testing.expect(capture.called);
    try std.testing.expectEqual(weixin_types.AttachmentKind.file, capture.kind);
    try std.testing.expectEqualStrings("C:\\tmp\\report.pdf", capture.path);
    try std.testing.expectEqualStrings("report.pdf", capture.display_name);
    try std.testing.expectEqualStrings("wx-user", capture.to_user_id);
    try std.testing.expectEqualStrings("ctx-1", capture.context_token);
    try std.testing.expectEqualStrings("Sent file to Weixin: report.pdf", result);
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
zig test src/ai_chat.zig
```

Expected: FAIL because `WeixinReplyContext`, `weixin_reply_context`, and tool dispatch do not exist.

- [ ] **Step 3: Add owned request context**

Add this struct near `ChatRequest` in `src/ai_chat.zig`.

```zig
const WeixinReplyContext = struct {
    sender: weixin_types.AttachmentSender,
    to_user_id: []u8,
    context_token: []u8,

    fn init(allocator: std.mem.Allocator, ctx: weixin_types.ReplyContext) !WeixinReplyContext {
        return .{
            .sender = ctx.sender,
            .to_user_id = try allocator.dupe(u8, ctx.to_user_id),
            .context_token = try allocator.dupe(u8, ctx.context_token),
        };
    }

    fn clone(self: WeixinReplyContext, allocator: std.mem.Allocator) !WeixinReplyContext {
        return .{
            .sender = self.sender,
            .to_user_id = try allocator.dupe(u8, self.to_user_id),
            .context_token = try allocator.dupe(u8, self.context_token),
        };
    }

    fn deinit(self: *WeixinReplyContext, allocator: std.mem.Allocator) void {
        allocator.free(self.to_user_id);
        allocator.free(self.context_token);
        self.* = undefined;
    }
};
```

Add this field to `ChatRequest`.

```zig
    weixin_reply_context: ?WeixinReplyContext = null,
```

Add this deinit block before `self.allocator.destroy(self);`.

```zig
        if (self.weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
```

- [ ] **Step 4: Store pending context on Session and apply Weixin input**

Add this field to `Session`.

```zig
    pending_weixin_reply_context: ?WeixinReplyContext = null,
```

In `Session.deinit`, before `self.allocator.destroy(self);`, add:

```zig
        if (self.pending_weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
```

Add these methods near `applyRemoteInput`.

```zig
    pub fn applyWeixinInput(self: *Session, data: []const u8, ctx: weixin_types.ReplyContext) void {
        self.mutex.lock();
        if (self.pending_weixin_reply_context) |*old| old.deinit(self.allocator);
        self.pending_weixin_reply_context = WeixinReplyContext.init(self.allocator, ctx) catch null;
        self.mutex.unlock();
        self.applyRemoteInput(data);
    }

    fn clearPendingWeixinReplyContextLocked(self: *Session) void {
        if (self.pending_weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
        self.pending_weixin_reply_context = null;
    }
```

In `submit`, when `prompt_raw.len == 0`, clear the pending context before unlocking:

```zig
        if (prompt_raw.len == 0) {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            return;
        }
```

In `submit`, when an existing request is still inflight, clear the pending context before returning:

```zig
            if (self.request_inflight) {
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            }
```

Before each built-in command or custom-command early return in `submit`, add:

```zig
            self.clearPendingWeixinReplyContextLocked();
```

This keeps Weixin reply context attached only to model requests, not to local slash commands.

- [ ] **Step 5: Clone pending context into ChatRequest**

In `buildRequestLocked`, add:

```zig
        var weixin_ctx: ?WeixinReplyContext = null;
        errdefer if (weixin_ctx) |*ctx| ctx.deinit(self.allocator);
        if (self.pending_weixin_reply_context) |ctx| {
            weixin_ctx = try ctx.clone(self.allocator);
            self.clearPendingWeixinReplyContextLocked();
        }
```

Add this field to `req.* = .{ ... }`:

```zig
            .weixin_reply_context = weixin_ctx,
```

After ownership transfers, set:

```zig
        weixin_ctx = null;
```

- [ ] **Step 6: Add tool dispatch**

Add this branch to `executeToolCall` before the final unknown-tool return.

```zig
    if (std.mem.eql(u8, call.name, "weixin_send_attachment")) {
        const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind_text = jsonStringArg(args.value, "kind") orelse return request.allocator.dupe(u8, "Missing kind");
        const kind = weixin_types.AttachmentKind.parse(kind_text) orelse return request.allocator.dupe(u8, "Invalid kind; expected file, image, or voice");
        const path = jsonStringArg(args.value, "path") orelse return request.allocator.dupe(u8, "Missing path");
        const display_name = jsonStringArg(args.value, "display_name") orelse "";
        return weixinSendAttachmentTool(request, kind, path, display_name);
    }
```

Add this function near other tool functions.

```zig
fn weixinSendAttachmentTool(
    request: *ChatRequest,
    kind: weixin_types.AttachmentKind,
    path: []const u8,
    display_name: []const u8,
) ![]u8 {
    const ctx = request.weixin_reply_context orelse {
        return request.allocator.dupe(u8, "No active Weixin reply context; cannot send attachment.");
    };
    ctx.sender.sendAttachment(kind, path, display_name, ctx.to_user_id, ctx.context_token) catch |err| {
        return std.fmt.allocPrint(request.allocator, "Failed to send {s} to Weixin: {}", .{ kind.name(), err });
    };
    const shown = if (display_name.len != 0) display_name else std.fs.path.basename(path);
    return std.fmt.allocPrint(request.allocator, "Sent {s} to Weixin: {s}", .{ kind.name(), shown });
}
```

- [ ] **Step 7: Run tests and commit**

Run:

```bash
zig test src/ai_chat.zig
zig build test
```

Expected: both commands PASS.

Commit:

```bash
git add src/ai_chat.zig
git commit -m "feat: handle weixin attachment tool calls"
```

## Task 7: Wire Weixin Reply Context Through Poller and AppWindow

**Files:**
- Modify: `src/weixin/control.zig`
- Modify: `src/weixin/agent.zig`
- Modify: `src/weixin/poller.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/weixin/controller.zig`

- [ ] **Step 1: Update control contract with failing tests**

In `src/weixin/control.zig`, add `const types = @import("types.zig");` near the top.

Change the vtable signature to:

```zig
        send_input: *const fn (ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) bool,
```

Change the method to:

```zig
    pub fn sendInput(self: Control, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) bool {
        return self.vtable.send_input(self.ctx, surface_id, bytes, reply_context);
    }
```

Run:

```bash
zig test src/weixin/agent.zig
```

Expected: FAIL at fake control implementations and call sites that still use the three-argument `sendInput`.

- [ ] **Step 2: Update agent routing**

Change `agent.route` in `src/weixin/agent.zig` to accept reply context.

```zig
pub fn route(
    allocator: std.mem.Allocator,
    ctrl: control.Control,
    settings: types.Settings,
    raw_text: []const u8,
    reply_context: ?types.ReplyContext,
    out: *Reply,
) !void {
```

Update the default and `/ai` calls to pass context:

```zig
    if (eqIgnoreCase(cmd, "/ai")) return sendAi(ctrl, parts.arg, reply_context, out);
    return sendAi(ctrl, text, reply_context, out);
```

Change `sendAi` signature and call:

```zig
fn sendAi(ctrl: control.Control, text: []const u8, reply_context: ?types.ReplyContext, out: *Reply) !void {
```

```zig
    if (!ctrl.sendInput(ai.id, buf.items, reply_context)) return out.set("WispTerm 当前离线，无法发送给 AI Agent。");
```

Keep `/term`, `/keys`, and `/stop` context-free:

```zig
    if (!ctrl.sendInput(ai.id, ESC, null)) return out.set("WispTerm 当前离线，无法停止 AI Agent。");
```

```zig
    if (!ctrl.sendInput(term.id, buf.items, null)) return out.set("WispTerm 当前离线，无法发送到终端。");
```

Update every test call to `route` by passing `null` before `&out`, except the new context test in the next step.

- [ ] **Step 3: Add agent context forwarding test**

Append this test to `src/weixin/agent.zig`.

```zig
test "default AI route forwards Weixin reply context only to AI surface" {
    const Sender = struct {
        fn sendAttachment(ctx: *anyopaque, kind: types.AttachmentKind, path: []const u8, display_name: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void {
            _ = ctx;
            _ = kind;
            _ = path;
            _ = display_name;
            _ = to_user_id;
            _ = context_token;
        }
    };

    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    const reply_ctx = types.ReplyContext{
        .sender = .{ .ctx = &fake, .send_attachment = Sender.sendAttachment },
        .to_user_id = "wx-user",
        .context_token = "ctx-1",
    };

    try route(t.allocator, fake.control_iface(), defaultSettings(), "make a chart", reply_ctx, &out);
    try t.expect(fake.last_reply_context != null);
    try t.expectEqualStrings("wx-user", fake.last_reply_context.?.to_user_id);
    try t.expectEqualStrings("ctx-1", fake.last_reply_context.?.context_token);
}
```

Extend `FakeControl` with:

```zig
    last_reply_context: ?types.ReplyContext = null,
```

Change fake `send_input` signature and body:

```zig
    fn send_input(ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?types.ReplyContext) bool {
        const self = cast(ctx);
        if (!self.connected) return false;
        self.last_surface = surface_id;
        self.last_reply_context = reply_context;
        const n = @min(bytes.len, self.buf.len);
        @memcpy(self.buf[0..n], bytes[0..n]);
        self.len = n;
        return true;
    }
```

- [ ] **Step 4: Update poller route callback and tests**

Change `ProcessInput.route_fn` in `src/weixin/poller.zig` to:

```zig
    route_fn: *const fn (
        ctx: *anyopaque,
        text: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
        allocator: std.mem.Allocator,
        reply: *std.ArrayListUnmanaged(u8),
    ) anyerror!RouteResult,
```

Change the call in `processUpdates` to:

```zig
        const route_result = input.route_fn(input.route_ctx, text, msg.from_user_id, msg.context_token, input.allocator, &reply) catch |err| {
```

Change `Poller.routeAdapter` signature:

```zig
    fn routeAdapter(
        ctx: *anyopaque,
        text: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
        allocator: std.mem.Allocator,
        reply: *std.ArrayListUnmanaged(u8),
    ) anyerror!RouteResult {
```

Inside `routeAdapter`, create the context:

```zig
        const reply_context = types.ReplyContext{
            .sender = .{ .ctx = self, .send_attachment = pollerSendAttachment },
            .to_user_id = to_user_id,
            .context_token = context_token,
        };
```

Change `agent.route` call:

```zig
        try agent.route(allocator, self.control, self.settings, text, reply_context, &r);
```

Add this adapter inside `Poller`.

```zig
    fn pollerSendAttachment(
        ctx: *anyopaque,
        kind: types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        if (self.stop_requested.load(.acquire)) return error.PollerStopped;
        try self.client.sendAttachment(kind, path, display_name, to_user_id, context_token);
    }
```

Update test route callback signatures. For `RouteCtx`, capture to/context:

```zig
const Captured = struct {
    sent: std.ArrayListUnmanaged([]u8) = .empty,
    routed: std.ArrayListUnmanaged([]u8) = .empty,
    routed_to: std.ArrayListUnmanaged([]u8) = .empty,
    routed_context: std.ArrayListUnmanaged([]u8) = .empty,
    fn deinit(self: *Captured) void {
        for (self.sent.items) |s| t.allocator.free(s);
        for (self.routed.items) |s| t.allocator.free(s);
        for (self.routed_to.items) |s| t.allocator.free(s);
        for (self.routed_context.items) |s| t.allocator.free(s);
        self.sent.deinit(t.allocator);
        self.routed.deinit(t.allocator);
        self.routed_to.deinit(t.allocator);
        self.routed_context.deinit(t.allocator);
    }
};
```

```zig
    fn route(ctx: *anyopaque, text: []const u8, to_user_id: []const u8, context_token: []const u8, allocator: std.mem.Allocator, reply: *std.ArrayListUnmanaged(u8)) anyerror!RouteResult {
        const self: *RouteCtx = @ptrCast(@alignCast(ctx));
        try self.cap.routed.append(t.allocator, try t.allocator.dupe(u8, text));
        try self.cap.routed_to.append(t.allocator, try t.allocator.dupe(u8, to_user_id));
        try self.cap.routed_context.append(t.allocator, try t.allocator.dupe(u8, context_token));
        try reply.appendSlice(allocator, "ok");
        return .{};
    }
```

In `processUpdates routes accepted text and sends replies`, add:

```zig
    try t.expectEqualStrings("u1", cap.routed_to.items[0]);
    try t.expectEqualStrings("c", cap.routed_context.items[0]);
```

Add this test for inbound voice routing:

```zig
test "processUpdates routes inbound voice transcript as message text" {
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "voice-ctx", .item_list = &.{.{ .type = 3, .voice_text = "transcribed command" }} },
    };

    try processUpdates(.{
        .allocator = t.allocator,
        .owner = "u1",
        .account_id = "",
        .messages = &msgs,
        .route_ctx = &rctx,
        .route_fn = RouteCtx.route,
        .send_ctx = &sctx,
        .send_fn = SendCtx.send,
    });

    try t.expectEqual(@as(usize, 1), cap.routed.items.len);
    try t.expectEqualStrings("transcribed command", cap.routed.items[0]);
    try t.expectEqualStrings("u1", cap.routed_to.items[0]);
    try t.expectEqualStrings("voice-ctx", cap.routed_context.items[0]);
}
```

- [ ] **Step 5: Update AppWindow UI-thread marshal**

In `src/AppWindow.zig`, make sure the import list includes the Weixin types module. Use the local import style already present in the file; the resulting alias must be:

```zig
const weixin_types = @import("weixin/types.zig");
```

Add this field to `WeixinRequest`.

```zig
    reply_context: ?weixin_types.ReplyContext = null,
```

In `handleWeixinControlRequest`, change the AI send path:

```zig
                if (req.reply_context) |ctx| {
                    session.applyWeixinInput(req.bytes, ctx);
                } else {
                    session.applyRemoteInput(req.bytes);
                }
```

Change `wxSendInput` signature and request construction:

```zig
fn wxSendInput(_: *anyopaque, surface_id: [16]u8, bytes: []const u8, reply_context: ?weixin_types.ReplyContext) bool {
    var req = WeixinRequest{ .op = .send_input, .surface_id = surface_id, .bytes = bytes, .reply_context = reply_context };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}
```

- [ ] **Step 6: Update control fakes**

In `src/weixin/poller.zig` and `src/weixin/controller.zig`, update every `NoopControl.sendInput` fake to:

```zig
    fn sendInput(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) bool {
        return false;
    }
```

If the fake file imports `control_mod` but not `types`, use the existing `types` alias in `poller.zig`; `controller.zig` already imports `types.zig`.

- [ ] **Step 7: Run tests and commit**

Run:

```bash
zig test src/weixin/agent.zig
zig test src/weixin/poller.zig
zig build test
```

Expected: all commands PASS.

Commit:

```bash
git add src/weixin/control.zig src/weixin/agent.zig src/weixin/poller.zig src/AppWindow.zig src/weixin/controller.zig
git commit -m "feat: pass weixin reply context to agent"
```

## Task 8: Final Verification and Cleanup

**Files:**
- Modify only if tests reveal compile errors in files changed by earlier tasks.

- [ ] **Step 1: Run focused tests**

Run:

```bash
zig test src/weixin/types.zig
zig test src/weixin/media.zig
zig test src/weixin/ilink_codec.zig
zig test src/weixin/ilink_client.zig
zig test src/weixin/binding.zig
zig test src/weixin/agent.zig
zig test src/weixin/poller.zig
zig test src/ai_chat_protocol.zig
zig test src/platform/agent_prompt.zig
zig test src/ai_chat.zig
```

Expected: all commands PASS.

- [ ] **Step 2: Run fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 3: Run full suite before merge on Windows**

On the Windows development host, run:

```powershell
zig build test-full
```

Expected: PASS. If this environment is not Windows, record that `test-full` still needs to be run on Windows before merge because this repository targets `x86_64-windows-gnu` by default.

- [ ] **Step 4: Run Windows checkout-safety checks if files were added**

Because this plan adds `src/weixin/media.zig`, run the path-safety check documented in `docs/development.md#windows-checkout-safety`.

Expected: no reserved names, illegal characters, case-fold collisions, symlinks, or excessive paths.

- [ ] **Step 5: Review secrets and logging**

Inspect changed files:

```bash
git diff -- src/weixin src/ai_chat.zig src/ai_chat_protocol.zig src/platform/agent_prompt.zig src/AppWindow.zig src/test_fast.zig
```

Expected:

- No bot token, `context_token`, AES key, or raw file contents are printed.
- Debug logs may print lengths, hashes, status codes, `ret`, `errcode`, and non-secret API messages.
- The tool success message prints only kind and display filename.

- [ ] **Step 6: Commit final fixes if any**

If Step 1 through Step 5 required fixes, commit only those tracked changes:

```bash
git add src/weixin src/ai_chat.zig src/ai_chat_protocol.zig src/platform/agent_prompt.zig src/AppWindow.zig src/test_fast.zig
git commit -m "fix: stabilize weixin attachment support"
```

If there were no final fixes, do not create an empty commit.
