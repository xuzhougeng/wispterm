# Weixin Receive Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Receive files and images sent from the bound user's WeChat — download from the Weixin CDN, AES-decrypt, save under `<working-dir>/weixin_inbound/`, reply a receipt naming the file(s), and hand the saved absolute path(s) to the copilot.

**Architecture:** Inbound counterpart to the existing `weixin_send_attachment` outbound path, entirely inside `src/weixin/` plus one new `Control` seam method in `AppWindow.zig`. Pure planning/naming/text in a new `media_inbound.zig`; CDN download behind the existing injectable `ClientApi`; orchestration added to the poller as a media branch that runs before today's `no_text_item` skip.

**Tech Stack:** Zig 0.15.2, `std.json`, `std.http.Client`, `std.crypto.core.aes.Aes128`, the existing Weixin direct poller + ilink client.

**Spec:** `docs/superpowers/specs/2026-06-06-weixin-receive-files-design.md`

---

## File Structure

- `src/weixin/media.zig` — MODIFY: add `parseAesKey`, rename decrypt to `aes128EcbPkcs7Decrypt`, add `cdnDownloadUrl`. (pure crypto/url helpers)
- `src/weixin/types.zig` — MODIFY: add `InboundMedia` + `MessageItem.media`/`file_name`. (pure data)
- `src/weixin/ilink_codec.zig` — MODIFY: parse inbound `file_item`/`image_item`. (pure JSON)
- `src/weixin/media_inbound.zig` — CREATE: download planning, mime sniff, filename derivation/sanitize/dedupe, receipt + copilot-prompt builders. (pure)
- `src/weixin/ilink_client.zig` — MODIFY: `downloadAttachment` + `ClientApi.download_attachment`. (network behind seam)
- `src/weixin/control.zig` — MODIFY: `Control.inboundFileDir`. (seam interface)
- `src/AppWindow.zig` — MODIFY: `inbound_file_dir` dispatch op + handler + vtable entry. (UI-thread impl)
- `src/ai_chat.zig` — MODIFY: make `defaultWorkingDir` public. (seam dependency)
- `src/weixin/poller.zig` — MODIFY: media branch in `processUpdates` + `pollerMediaAdapter`. (orchestration)
- `src/test_main.zig` — MODIFY: register `media_inbound.zig`.

**Test commands:** `zig build test-full` runs the full app graph (weixin tests live here). `zig build test` is the fast native suite. Run both before finishing; per-task steps below use `zig build test-full`.

---

## Task 1: media.zig — AES key parsing, public decrypt, CDN download URL

**Files:**
- Modify: `src/weixin/media.zig`

- [ ] **Step 1: Write failing tests**

Append to the test section of `src/weixin/media.zig`:

```zig
test "parseAesKey decodes a base64 raw 16-byte key" {
    // base64 of 16 raw bytes 0x00..0x0f
    const encoded = try encodeRaw16ForTest(t.allocator);
    defer t.allocator.free(encoded);
    const key = try parseAesKey(t.allocator, encoded);
    try t.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &key);
}

test "parseAesKey decodes base64 of 32 hex chars into 16 bytes" {
    // This is what WispTerm's own encodeIlinkAesKey produces.
    const key_in: AesKey = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const encoded = try encodeIlinkAesKey(t.allocator, key_in);
    defer t.allocator.free(encoded);
    const key = try parseAesKey(t.allocator, encoded);
    try t.expectEqualSlices(u8, &key_in, &key);
}

test "parseAesKey rejects malformed keys" {
    try t.expectError(error.WeixinInvalidAesKey, parseAesKey(t.allocator, "not base64!!"));
    // base64 of 5 bytes → neither 16 nor 32
    try t.expectError(error.WeixinInvalidAesKey, parseAesKey(t.allocator, "aGVsbG8="));
}

test "decrypt round-trips ciphertext from aes128EcbPkcs7Encrypt" {
    const key: AesKey = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const encrypted = try aes128EcbPkcs7Encrypt(t.allocator, key, "weixin inbound payload");
    defer t.allocator.free(encrypted);
    const decrypted = try aes128EcbPkcs7Decrypt(t.allocator, key, encrypted);
    defer t.allocator.free(decrypted);
    try t.expectEqualStrings("weixin inbound payload", decrypted);
}

test "cdnDownloadUrl builds the c2c download endpoint with escaped param" {
    const url = try cdnDownloadUrl(t.allocator, "a+b&c=1");
    defer t.allocator.free(url);
    try t.expectEqualStrings(DEFAULT_CDN_UPLOAD_BASE_URL ++ "/download?encrypted_query_param=a%2Bb%26c%3D1", url);
}

fn encodeRaw16ForTest(allocator: std.mem.Allocator) ![]u8 {
    const raw: AesKey = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(out, &raw);
    return out;
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `parseAesKey`, `aes128EcbPkcs7Decrypt`, and `cdnDownloadUrl` are undefined (the existing decrypt is named `aes128EcbPkcs7DecryptForTest`).

- [ ] **Step 3: Rename the decrypt function to its public name**

In `src/weixin/media.zig`, rename `pub fn aes128EcbPkcs7DecryptForTest` to `pub fn aes128EcbPkcs7Decrypt` (body unchanged). Update the two existing in-module test call sites (`aes128EcbPkcs7DecryptForTest(` → `aes128EcbPkcs7Decrypt(`).

- [ ] **Step 4: Add parseAesKey and cdnDownloadUrl**

Add to `src/weixin/media.zig` (after `encodeIlinkAesKey`):

```zig
/// Decodes a Weixin `media.aes_key` into a 16-byte AES-128 key. The value is
/// base64; the decoded bytes are either the raw 16-byte key or 32 ASCII hex
/// chars (WispTerm's own outbound form) that hex-decode to 16 bytes.
pub fn parseAesKey(allocator: std.mem.Allocator, aes_key_base64: []const u8) !AesKey {
    const trimmed = std.mem.trim(u8, aes_key_base64, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(trimmed) catch return error.WeixinInvalidAesKey;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, trimmed) catch return error.WeixinInvalidAesKey;

    var key: AesKey = undefined;
    if (decoded.len == 16) {
        @memcpy(&key, decoded);
        return key;
    }
    if (decoded.len == 32 and isAsciiHex(decoded)) {
        for (0..16) |i| {
            const hi = hexNibble(decoded[i * 2]) orelse return error.WeixinInvalidAesKey;
            const lo = hexNibble(decoded[i * 2 + 1]) orelse return error.WeixinInvalidAesKey;
            key[i] = (hi << 4) | lo;
        }
        return key;
    }
    return error.WeixinInvalidAesKey;
}

fn isAsciiHex(data: []const u8) bool {
    for (data) |c| {
        if (hexNibble(c) == null) return false;
    }
    return true;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `<cdn-base>/download?encrypted_query_param=<escaped>` — the inbound GET URL.
/// No filekey (unlike upload).
pub fn cdnDownloadUrl(allocator: std.mem.Allocator, encrypt_query_param: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, DEFAULT_CDN_UPLOAD_BASE_URL);
    try out.appendSlice(allocator, "/download?encrypted_query_param=");
    try appendQueryEscaped(&out, allocator, encrypt_query_param);
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS (all media.zig tests, including the renamed-decrypt callers).

- [ ] **Step 6: Commit**

```bash
git add src/weixin/media.zig
git commit -m "feat(weixin): media.zig parseAesKey + public decrypt + cdnDownloadUrl"
```

---

## Task 2: types.zig + ilink_codec.zig — parse inbound file_item/image_item

**Files:**
- Modify: `src/weixin/types.zig`
- Modify: `src/weixin/ilink_codec.zig`

- [ ] **Step 1: Write failing tests**

Append to the test section of `src/weixin/ilink_codec.zig`:

```zig
test "parseGetUpdates maps an inbound file_item with media and file name" {
    const json =
        \\{"ret":0,"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":4,"file_item":{"file_name":"report.pdf",
        \\"media":{"encrypt_query_param":"ENC","aes_key":"KEY","encrypt_type":1}}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    const item = parsed.value.msgs[0].item_list[0];
    try t.expectEqual(@as(i64, 4), item.type);
    try t.expectEqualStrings("report.pdf", item.file_name);
    try t.expect(item.media != null);
    try t.expectEqualStrings("ENC", item.media.?.encrypt_query_param);
    try t.expectEqualStrings("KEY", item.media.?.aes_key);
}

test "parseGetUpdates maps an inbound image_item media" {
    const json =
        \\{"ret":0,"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":2,"image_item":{
        \\"media":{"encrypt_query_param":"IMGENC","aes_key":"IMGKEY"}}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    const item = parsed.value.msgs[0].item_list[0];
    try t.expectEqual(@as(i64, 2), item.type);
    try t.expect(item.media != null);
    try t.expectEqualStrings("IMGENC", item.media.?.encrypt_query_param);
    try t.expectEqualStrings("IMGKEY", item.media.?.aes_key);
}

test "parseGetUpdates falls back to legacy image aeskey when media.aes_key absent" {
    const json =
        \\{"ret":0,"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":2,"image_item":{"aeskey":"LEGACYHEX",
        \\"media":{"encrypt_query_param":"IMGENC"}}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    const item = parsed.value.msgs[0].item_list[0];
    try t.expect(item.media != null);
    try t.expectEqualStrings("IMGENC", item.media.?.encrypt_query_param);
    try t.expectEqualStrings("LEGACYHEX", item.media.?.aes_key);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `MessageItem` has no `media`/`file_name` fields; `WireItem` has no `file_item`/`image_item`.

- [ ] **Step 3: Add InboundMedia and MessageItem fields in types.zig**

In `src/weixin/types.zig`, replace the `MessageItem` declaration with:

```zig
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
```

- [ ] **Step 4: Parse inbound media in ilink_codec.zig**

In `src/weixin/ilink_codec.zig`, replace the `WireItem` struct with:

```zig
const WireMedia = struct {
    encrypt_query_param: []const u8 = "",
    aes_key: []const u8 = "",
    encrypt_type: i64 = 0,
};
const WireItem = struct {
    type: i64 = 0,
    text_item: ?struct { text: []const u8 = "" } = null,
    voice_item: ?struct { text: []const u8 = "" } = null,
    image_item: ?struct {
        media: ?WireMedia = null,
        aeskey: []const u8 = "",
        url: []const u8 = "",
    } = null,
    file_item: ?struct {
        media: ?WireMedia = null,
        file_name: []const u8 = "",
        md5: []const u8 = "",
        len: []const u8 = "",
    } = null,
};
```

Then in `parseGetUpdates`, replace the inner `items[ii] = .{ ... }` assignment with:

```zig
            items[ii] = .{
                .type = wi.type,
                .text = if (wi.text_item) |x| x.text else "",
                .voice_text = if (wi.voice_item) |x| x.text else "",
                .media = inboundMediaFromWire(wi),
                .file_name = if (wi.file_item) |f| f.file_name else "",
            };
```

And add this helper above `parseGetUpdates` (or anywhere in the file's fn section):

```zig
fn inboundMediaFromWire(wi: WireItem) ?types.InboundMedia {
    if (wi.file_item) |f| {
        if (f.media) |m| return .{ .encrypt_query_param = m.encrypt_query_param, .aes_key = m.aes_key };
    }
    if (wi.image_item) |img| {
        if (img.media) |m| {
            const key = if (m.aes_key.len != 0) m.aes_key else img.aeskey;
            return .{ .encrypt_query_param = m.encrypt_query_param, .aes_key = key };
        }
    }
    return null;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS (new codec tests + existing text/voice tests still green).

- [ ] **Step 6: Commit**

```bash
git add src/weixin/types.zig src/weixin/ilink_codec.zig
git commit -m "feat(weixin): parse inbound file_item/image_item CDN media"
```

---

## Task 3: media_inbound.zig — pure planning, naming, and message text

**Files:**
- Create: `src/weixin/media_inbound.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Create the module with its full implementation and tests**

Create `src/weixin/media_inbound.zig`:

```zig
//! Pure inbound-media helpers for the Weixin direct bridge: decide what to
//! download from a message, name the saved files, and build the WeChat receipt
//! and the synthetic copilot prompt. No I/O lives here.
const std = @import("std");
const types = @import("types.zig");

pub const DownloadPlan = struct {
    kind: types.AttachmentKind,
    encrypt_query_param: []const u8,
    aes_key: []const u8,
    /// file_item only; "" for images.
    file_name: []const u8 = "",
    /// images with no key are fetched as-is (already-decrypted bytes).
    allow_plain: bool = false,
};

/// Selects image (type 2) and file (type 4) items with a usable CDN reference,
/// deduplicating repeated encrypt_query_param values within one message.
/// `out` borrows the input strings; caller owns the returned slice.
pub fn planDownloads(allocator: std.mem.Allocator, items: []const types.MessageItem) ![]DownloadPlan {
    var out: std.ArrayListUnmanaged(DownloadPlan) = .empty;
    errdefer out.deinit(allocator);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(allocator);

    for (items) |item| {
        const media = item.media orelse continue;
        const enc = std.mem.trim(u8, media.encrypt_query_param, " \t\r\n");
        if (enc.len == 0) continue;
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, enc)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const key = std.mem.trim(u8, media.aes_key, " \t\r\n");
        switch (item.type) {
            2 => {
                try out.append(allocator, .{
                    .kind = .image,
                    .encrypt_query_param = enc,
                    .aes_key = key,
                    .allow_plain = key.len == 0,
                });
                try seen.append(allocator, enc);
            },
            4 => {
                if (key.len == 0) continue; // files require a key
                try out.append(allocator, .{
                    .kind = .file,
                    .encrypt_query_param = enc,
                    .aes_key = key,
                    .file_name = item.file_name,
                });
                try seen.append(allocator, enc);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Image extension from magic bytes; defaults to "jpg".
pub fn detectImageMimeExt(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return "jpg";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "png";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "webp";
    return "jpg";
}

/// Strips any directory components and rejects empty/dotty names, so a remote
/// file_name can never escape the save directory. Returns a borrowed slice of
/// `name` (the basename) or a fallback literal.
pub fn sanitizeFileName(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "attachment.bin";
    // basename after the last '/' or '\'
    var start: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const base = trimmed[start..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return "attachment.bin";
    return base;
}

/// Chooses the on-disk name for a saved item. Allocator-owned result.
/// `index` makes image names unique within a message.
pub fn chooseFileName(allocator: std.mem.Allocator, plan: DownloadPlan, bytes: []const u8, index: usize) ![]u8 {
    return switch (plan.kind) {
        .file, .voice => allocator.dupe(u8, sanitizeFileName(plan.file_name)),
        .image => std.fmt.allocPrint(allocator, "image_{d}.{s}", .{ index, detectImageMimeExt(bytes) }),
    };
}

/// If `name` collides with an entry in `taken`, inserts " (n)" before the
/// extension until unique. Allocator-owned result; `taken` holds borrowed names.
pub fn dedupeFileName(allocator: std.mem.Allocator, name: []const u8, taken: []const []const u8) ![]u8 {
    if (!nameTaken(name, taken)) return allocator.dupe(u8, name);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d..] else "";
    var n: usize = 2;
    while (n < 10000) : (n += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, n, ext });
        if (!nameTaken(candidate, taken)) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, name);
}

fn nameTaken(name: []const u8, taken: []const []const u8) bool {
    for (taken) |t_name| {
        if (std.mem.eql(u8, t_name, name)) return true;
    }
    return false;
}

/// The combined receipt + ack sent to WeChat when at least one file is saved.
pub fn buildReceiptText(allocator: std.mem.Allocator, saved_names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "已收到文件：");
    for (saved_names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, "、");
        try out.appendSlice(allocator, name);
    }
    try out.appendSlice(allocator, "，正在交给副驾处理。\n发送 /stop 可停止本次处理。");
    return out.toOwnedSlice(allocator);
}

/// The synthetic prompt routed to the copilot. Lists absolute saved paths and
/// appends the user's caption if present. No trailing carriage return.
pub fn buildCopilotPrompt(allocator: std.mem.Allocator, saved_paths: []const []const u8, caption: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "用户通过微信发送了文件：");
    for (saved_paths) |p| {
        try out.appendSlice(allocator, "\n- ");
        try out.appendSlice(allocator, p);
    }
    const cap = std.mem.trim(u8, caption, " \t\r\n");
    if (cap.len != 0) {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, cap);
    }
    return out.toOwnedSlice(allocator);
}

const t = std.testing;

test "planDownloads selects image and file items and dedups by encrypt param" {
    const items = [_]types.MessageItem{
        .{ .type = 1, .text = "caption" },
        .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        .{ .type = 2, .media = .{ .encrypt_query_param = "E2", .aes_key = "K2" } },
        .{ .type = 2, .media = .{ .encrypt_query_param = "E2", .aes_key = "K2" } }, // dup → skip
        .{ .type = 4, .file_name = "nokey.bin", .media = .{ .encrypt_query_param = "E3", .aes_key = "" } }, // file w/o key → skip
        .{ .type = 2, .media = .{ .encrypt_query_param = "E4", .aes_key = "" } }, // image plain
    };
    const plans = try planDownloads(t.allocator, &items);
    defer t.allocator.free(plans);
    try t.expectEqual(@as(usize, 3), plans.len);
    try t.expectEqual(types.AttachmentKind.file, plans[0].kind);
    try t.expectEqualStrings("a.pdf", plans[0].file_name);
    try t.expectEqual(types.AttachmentKind.image, plans[1].kind);
    try t.expect(!plans[1].allow_plain);
    try t.expectEqualStrings("E4", plans[2].encrypt_query_param);
    try t.expect(plans[2].allow_plain);
}

test "detectImageMimeExt sniffs common formats" {
    try t.expectEqualStrings("png", detectImageMimeExt("\x89PNG\r\n\x1a\n----"));
    try t.expectEqualStrings("jpg", detectImageMimeExt(&[_]u8{ 0xFF, 0xD8, 0xFF, 0x00 }));
    try t.expectEqualStrings("gif", detectImageMimeExt("GIF89a..."));
    try t.expectEqualStrings("jpg", detectImageMimeExt("unknown"));
}

test "sanitizeFileName strips path components and rejects traversal" {
    try t.expectEqualStrings("report.pdf", sanitizeFileName("report.pdf"));
    try t.expectEqualStrings("report.pdf", sanitizeFileName("/etc/../report.pdf"));
    try t.expectEqualStrings("report.pdf", sanitizeFileName("C:\\Users\\x\\report.pdf"));
    try t.expectEqualStrings("attachment.bin", sanitizeFileName("   "));
    try t.expectEqualStrings("attachment.bin", sanitizeFileName("a/b/.."));
}

test "chooseFileName names files and images" {
    const fplan = DownloadPlan{ .kind = .file, .encrypt_query_param = "E", .aes_key = "K", .file_name = "doc.pdf" };
    const fname = try chooseFileName(t.allocator, fplan, "", 0);
    defer t.allocator.free(fname);
    try t.expectEqualStrings("doc.pdf", fname);

    const iplan = DownloadPlan{ .kind = .image, .encrypt_query_param = "E", .aes_key = "" };
    const iname = try chooseFileName(t.allocator, iplan, "\x89PNG\r\n\x1a\n", 3);
    defer t.allocator.free(iname);
    try t.expectEqualStrings("image_3.png", iname);
}

test "dedupeFileName appends a counter before the extension" {
    const taken = [_][]const u8{ "doc.pdf", "doc (2).pdf" };
    const a = try dedupeFileName(t.allocator, "fresh.pdf", &taken);
    defer t.allocator.free(a);
    try t.expectEqualStrings("fresh.pdf", a);

    const b = try dedupeFileName(t.allocator, "doc.pdf", &taken);
    defer t.allocator.free(b);
    try t.expectEqualStrings("doc (3).pdf", b);
}

test "buildReceiptText joins names with the start-of-processing line" {
    const names = [_][]const u8{ "a.pdf", "image_0.png" };
    const text = try buildReceiptText(t.allocator, &names);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "已收到文件：a.pdf、image_0.png") != null);
    try t.expect(std.mem.indexOf(u8, text, "/stop") != null);
}

test "buildCopilotPrompt lists absolute paths and optional caption" {
    const paths = [_][]const u8{"/work/weixin_inbound/a.pdf"};
    const with_cap = try buildCopilotPrompt(t.allocator, &paths, "请总结这个 PDF");
    defer t.allocator.free(with_cap);
    try t.expect(std.mem.indexOf(u8, with_cap, "- /work/weixin_inbound/a.pdf") != null);
    try t.expect(std.mem.indexOf(u8, with_cap, "请总结这个 PDF") != null);

    const no_cap = try buildCopilotPrompt(t.allocator, &paths, "   ");
    defer t.allocator.free(no_cap);
    try t.expect(std.mem.endsWith(u8, no_cap, "a.pdf"));
}
```

- [ ] **Step 2: Register the module in the full test suite**

In `src/test_main.zig`, after line `_ = @import("weixin/ilink_codec.zig");`, add:

```zig
    _ = @import("weixin/media_inbound.zig");
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS — all `media_inbound` tests run and pass.

- [ ] **Step 4: Commit**

```bash
git add src/weixin/media_inbound.zig src/test_main.zig
git commit -m "feat(weixin): pure inbound media planning, naming, receipt + prompt"
```

---

## Task 4: ilink_client.zig — downloadAttachment + ClientApi seam

**Files:**
- Modify: `src/weixin/ilink_client.zig`
- Modify: `src/weixin/poller.zig` (FakeClient vtable literal only)

- [ ] **Step 1: Write the failing test**

Append to the test section of `src/weixin/ilink_client.zig`:

```zig
test "downloadAttachment fetches and decrypts CDN bytes via injected transport" {
    const Capture = struct {
        download_url: std.ArrayListUnmanaged(u8) = .empty,
        ciphertext: []u8 = &.{},

        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.download_url.deinit(a);
            if (self.ciphertext.len != 0) a.free(self.ciphertext);
        }

        fn download(
            ctx: ?*anyopaque,
            client: *Client,
            arena: std.mem.Allocator,
            url: []const u8,
        ) anyerror![]u8 {
            _ = client;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            try self.download_url.appendSlice(std.testing.allocator, url);
            return arena.dupe(u8, self.ciphertext);
        }
    };

    const key: media.AesKey = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const ciphertext = try media.aes128EcbPkcs7Encrypt(std.testing.allocator, key, "hello pdf bytes");
    defer std.testing.allocator.free(ciphertext);
    const aes_key_b64 = try media.encodeIlinkAesKey(std.testing.allocator, key);
    defer std.testing.allocator.free(aes_key_b64);

    var capture = Capture{ .ciphertext = try std.testing.allocator.dupe(u8, ciphertext) };
    defer capture.deinit(std.testing.allocator);

    var c = Client.init(std.testing.allocator, "https://x.test", "tok");
    c.transport_ctx = &capture;
    c.cdn_download_impl = Capture.download;

    const out = try c.downloadAttachment(std.testing.allocator, "ENC%PARAM", aes_key_b64, false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello pdf bytes", out);
    try std.testing.expect(std.mem.indexOf(u8, capture.download_url.items, "/download?encrypted_query_param=") != null);
}

test "downloadAttachment returns plain bytes when allow_plain and no key" {
    const Capture = struct {
        fn download(ctx: ?*anyopaque, client: *Client, arena: std.mem.Allocator, url: []const u8) anyerror![]u8 {
            _ = ctx;
            _ = client;
            _ = url;
            return arena.dupe(u8, "\x89PNG\r\n\x1a\nrawimg");
        }
    };
    var c = Client.init(std.testing.allocator, "https://x.test", "tok");
    c.cdn_download_impl = Capture.download;
    const out = try c.downloadAttachment(std.testing.allocator, "ENC", "", true);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nrawimg", out);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `Client` has no `cdn_download_impl` field and no `downloadAttachment` method.

- [ ] **Step 3: Add the download transport seam and method**

In `src/weixin/ilink_client.zig`, add to the `Client` struct fields (next to `cdn_upload_impl`):

```zig
    cdn_download_impl: CdnDownloadImpl = httpDownloadFromCdn,
```

Add the type alias next to `CdnUploadImpl`:

```zig
    const CdnDownloadImpl = *const fn (
        ctx: ?*anyopaque,
        client: *Client,
        arena: std.mem.Allocator,
        url: []const u8,
    ) anyerror![]u8;

    pub const MAX_INBOUND_BYTES: usize = 100 << 20;
```

Add the method (next to `sendAttachment`):

```zig
    /// Downloads an inbound CDN attachment and (unless `allow_plain` with an
    /// empty key) AES-decrypts it. Returns owned plaintext bytes.
    pub fn downloadAttachment(
        self: *Client,
        allocator: std.mem.Allocator,
        encrypt_query_param: []const u8,
        aes_key: []const u8,
        allow_plain: bool,
    ) ![]u8 {
        var req_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer req_arena.deinit();
        const a = req_arena.allocator();

        const url = try media.cdnDownloadUrl(a, encrypt_query_param);
        const raw = try self.cdn_download_impl(self.transport_ctx, self, a, url);
        if (raw.len > MAX_INBOUND_BYTES) return error.WeixinInboundTooLarge;

        if (aes_key.len == 0) {
            if (!allow_plain) return error.WeixinInboundMissingKey;
            return allocator.dupe(u8, raw);
        }
        const key = try media.parseAesKey(a, aes_key);
        return media.aes128EcbPkcs7Decrypt(allocator, key, raw);
    }
```

Add the live HTTP implementation (next to `httpUploadBufferToCdn`):

```zig
    fn httpDownloadFromCdn(
        _: ?*anyopaque,
        self: *Client,
        arena: std.mem.Allocator,
        url: []const u8,
    ) ![]u8 {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var body: std.Io.Writer.Allocating = .init(arena);
        const response = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .keep_alive = false,
            .response_writer = &body.writer,
        }) catch |err| {
            std.debug.print("weixin download-cdn({d}): status=request_failed err={}\n", .{ std.time.milliTimestamp(), err });
            return error.WeixinCdnDownloadFailed;
        };
        const items = body.toArrayList().items;
        if (response.status != .ok) {
            std.debug.print("weixin download-cdn({d}): status=failed http_status={} body_excerpt={s}\n", .{
                std.time.milliTimestamp(),
                response.status,
                logSafeResponseExcerpt(arena, items),
            });
            return error.WeixinCdnDownloadFailed;
        }
        return items;
    }
```

- [ ] **Step 4: Add download_attachment to the ClientApi seam**

In `ClientApi.VTable`, add:

```zig
        download_attachment: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            encrypt_query_param: []const u8,
            aes_key: []const u8,
            allow_plain: bool,
        ) anyerror![]u8,
```

Add the `ClientApi` method (next to `sendAttachment`):

```zig
    pub fn downloadAttachment(
        self: ClientApi,
        allocator: std.mem.Allocator,
        encrypt_query_param: []const u8,
        aes_key: []const u8,
        allow_plain: bool,
    ) ![]u8 {
        return self.vtable.download_attachment(self.ctx, allocator, encrypt_query_param, aes_key, allow_plain);
    }
```

In `Client.api()`, add `.download_attachment = apiDownloadAttachment,` to the vtable literal, and add the adapter next to `apiSendAttachment`:

```zig
    fn apiDownloadAttachment(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        encrypt_query_param: []const u8,
        aes_key: []const u8,
        allow_plain: bool,
    ) anyerror![]u8 {
        return @as(*Client, @ptrCast(@alignCast(ctx))).downloadAttachment(allocator, encrypt_query_param, aes_key, allow_plain);
    }
```

- [ ] **Step 5: Update the existing ClientApi vtable test literal**

In the `test "ClientApi forwards sendAttachment to the vtable"` block, the `Capture` struct builds a `ClientApi{ .vtable = &.{ ... } }`. Add a stub and field so it compiles:

Add to `Capture`:

```zig
        fn downloadAttachment(ctx: *anyopaque, allocator: std.mem.Allocator, enc: []const u8, key: []const u8, allow_plain: bool) anyerror![]u8 {
            _ = ctx;
            _ = enc;
            _ = key;
            _ = allow_plain;
            return allocator.dupe(u8, "");
        }
```

And add `.download_attachment = Capture.downloadAttachment,` to that test's vtable literal.

- [ ] **Step 6: Update the poller FakeClient vtable literal so the suite compiles**

In `src/weixin/poller.zig`, the `FakeClient.api()` builds a `ClientApi` vtable. Add a stub method to `FakeClient`:

```zig
    fn downloadAttachment(ctx: *anyopaque, allocator: std.mem.Allocator, enc: []const u8, key: []const u8, allow_plain: bool) anyerror![]u8 {
        _ = ctx;
        _ = enc;
        _ = key;
        _ = allow_plain;
        return allocator.dupe(u8, "");
    }
```

And add `.download_attachment = downloadAttachment,` to `FakeClient.api()`'s vtable literal.

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS — new downloadAttachment tests pass; all existing client/poller tests still compile and pass.

- [ ] **Step 8: Commit**

```bash
git add src/weixin/ilink_client.zig src/weixin/poller.zig
git commit -m "feat(weixin): ilink client downloadAttachment + ClientApi seam"
```

---

## Task 5: control.zig + AppWindow.zig — inboundFileDir seam

**Files:**
- Modify: `src/weixin/control.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/weixin/poller.zig`, `src/weixin/controller.zig`, `src/weixin/agent.zig` (fake Control vtable literals)

- [ ] **Step 1: Write the failing test**

Append to the test section of `src/weixin/control.zig`:

```zig
const t = std.testing;

test "inboundFileDir forwards to the vtable and copies into the caller buffer" {
    const Fake = struct {
        fn is_connected(_: *anyopaque) bool {
            return true;
        }
        fn find_ai_surface(_: *anyopaque) ?Surface {
            return null;
        }
        fn find_terminal_surface(_: *anyopaque) ?Surface {
            return null;
        }
        fn open_ai_agent(_: *anyopaque, _: u32) OpenResult {
            return .offline;
        }
        fn send_input(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) bool {
            return false;
        }
        fn latest_transcript(_: *anyopaque) []const u8 {
            return "";
        }
        fn ai_approval_pending(_: *anyopaque) bool {
            return false;
        }
        fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
            return false;
        }
        fn inbound_file_dir(_: *anyopaque, buf: []u8) []const u8 {
            const dir = "/tmp/proj";
            @memcpy(buf[0..dir.len], dir);
            return buf[0..dir.len];
        }
        var dummy: u8 = 0;
        fn iface() Control {
            return .{ .ctx = &dummy, .vtable = &.{
                .is_connected = is_connected,
                .find_ai_surface = find_ai_surface,
                .find_terminal_surface = find_terminal_surface,
                .open_ai_agent = open_ai_agent,
                .send_input = send_input,
                .latest_transcript = latest_transcript,
                .ai_approval_pending = ai_approval_pending,
                .resolve_ai_approval = resolve_ai_approval,
                .inbound_file_dir = inbound_file_dir,
            } };
        }
    };

    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("/tmp/proj", Fake.iface().inboundFileDir(&buf));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `Control` has no `inbound_file_dir`/`inboundFileDir`.

- [ ] **Step 3: Add inbound_file_dir to control.zig**

In `src/weixin/control.zig`, add to `VTable` (after `resolve_ai_approval`):

```zig
        /// Writes the effective agent working directory into `buf` and returns
        /// the slice; empty when no working dir is configured. UI-thread backed.
        inbound_file_dir: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
```

Add the method (after `resolveAiApproval`):

```zig
    pub fn inboundFileDir(self: Control, buf: []u8) []const u8 {
        return self.vtable.inbound_file_dir(self.ctx, buf);
    }
```

- [ ] **Step 4: Make ai_chat.defaultWorkingDir public**

In `src/ai_chat.zig` line ~355, change `fn defaultWorkingDir()` to `pub fn defaultWorkingDir()`.

- [ ] **Step 5: Add the dispatch op + handler + impl in AppWindow.zig**

In `src/AppWindow.zig`:

(a) Extend the `WeixinRequest.op` enum (line ~3234) — add `inbound_file_dir`:

```zig
    op: enum { find_ai, find_term, open_ai, send_input, latest_transcript, ai_approval_pending, resolve_ai_approval, inbound_file_dir },
```

(b) Add an output field to `WeixinRequest` (after `transcript: []u8 = &.{},`):

```zig
    dir: []u8 = &.{}, // inbound_file_dir (heap, page_allocator)
```

(c) Add a handler case in `handleWeixinControlRequest` (after `.resolve_ai_approval`):

```zig
        .inbound_file_dir => {
            // Per-conversation working dir if set, else the global default.
            if (weixinActiveAiTabIndex()) |idx| {
                if (tab.g_tabs[idx]) |tab_state| {
                    if (tab_state.kind == .ai_chat) {
                        if (tab_state.ai_chat_session) |session| {
                            if (session.workingDirOverride()) |w| {
                                req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                                req.found = true;
                                return;
                            }
                        }
                    }
                }
            }
            if (ai_chat.defaultWorkingDir()) |w| {
                req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                req.found = true;
            }
        },
```

(d) Add the vtable function (next to `wxTranscript`):

```zig
fn wxInboundFileDir(_: *anyopaque, buf: []u8) []const u8 {
    var req = WeixinRequest{ .op = .inbound_file_dir };
    if (!weixinDispatch(&req) or !req.found or req.dir.len == 0) return "";
    defer std.heap.page_allocator.free(req.dir);
    const n = @min(req.dir.len, buf.len);
    @memcpy(buf[0..n], req.dir[0..n]);
    return buf[0..n];
}
```

(e) Add `.inbound_file_dir = wxInboundFileDir,` to the `weixin_vtable` literal.

- [ ] **Step 6: Add the field to the fake Control vtable literals**

Each of these builds a `weixin_control.Control.VTable` / `control_mod.Control` / `control.Control` literal and must gain a `.inbound_file_dir` entry plus a stub fn. Add this stub fn to each enclosing fake struct and the matching `.inbound_file_dir = inbound_file_dir,` line:

```zig
    fn inbound_file_dir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
```

Apply to:
- `src/weixin/poller.zig`: `NoopControl` (iface vtable) and `ApprovalTranscriptControl` (iface vtable).
- `src/weixin/controller.zig`: `NoopControl` (iface vtable).
- `src/weixin/agent.zig`: `FakeControl` (control_iface vtable) — there it follows the `cast`/`fn` naming; add the same stub and `.inbound_file_dir = inbound_file_dir,`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS — control test passes; all fake-Control sites compile.

- [ ] **Step 8: Verify the Windows cross-compile (AppWindow is Windows-heavy)**

Run: `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -20`
Expected: builds clean (no errors). If the project uses a different cross-build invocation, match the one in recent commits.

- [ ] **Step 9: Commit**

```bash
git add src/weixin/control.zig src/ai_chat.zig src/AppWindow.zig src/weixin/poller.zig src/weixin/controller.zig src/weixin/agent.zig
git commit -m "feat(weixin): Control.inboundFileDir seam (per-conv working dir)"
```

---

## Task 6: poller.zig — inbound media orchestration

**Files:**
- Modify: `src/weixin/poller.zig`

This task wires media handling into `processUpdates` via a new injected callback, then implements the real `pollerMediaAdapter` that downloads, saves, and builds the receipt + prompt.

- [ ] **Step 1: Write the failing pure test (processUpdates media branch)**

Append to the test section of `src/weixin/poller.zig`:

```zig
test "processUpdates sends the receipt as ack and routes the synthetic prompt for media" {
    const MediaCtx = struct {
        fn media(_: *anyopaque, _: types.Message, allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), prompt: *std.ArrayListUnmanaged(u8)) anyerror!MediaOutcome {
            try receipt.appendSlice(allocator, "已收到文件：a.pdf");
            try prompt.appendSlice(allocator, "用户通过微信发送了文件：\n- /work/weixin_inbound/a.pdf");
            return .{ .handled = true, .any_saved = true };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };
    var pctx = ProgressCtx{};
    defer pctx.deinit();
    var media_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{
            .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        } },
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
        .progress_ctx = &pctx,
        .start_progress_fn = ProgressCtx.start,
        .media_ctx = &media_ctx,
        .media_fn = MediaCtx.media,
    });

    // Receipt is the only ack sent (route reply suppressed).
    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("已收到文件：a.pdf", cap.sent.items[0]);
    // The synthetic prompt was routed to the copilot.
    try t.expectEqual(@as(usize, 1), cap.routed.items.len);
    try t.expect(std.mem.indexOf(u8, cap.routed.items[0], "/work/weixin_inbound/a.pdf") != null);
    // RouteCtx.route returns .{} (no progress), so streaming is not started here.
}

test "processUpdates skips routing when media is handled but nothing saved" {
    const MediaCtx = struct {
        fn media(_: *anyopaque, _: types.Message, allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), prompt: *std.ArrayListUnmanaged(u8)) anyerror!MediaOutcome {
            _ = prompt;
            try receipt.appendSlice(allocator, "文件接收失败：a.pdf");
            return .{ .handled = true, .any_saved = false };
        }
    };
    var cap = Captured{};
    defer cap.deinit();
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };
    var media_ctx: u8 = 0;

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "ctx", .item_list = &.{
            .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        } },
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
        .media_ctx = &media_ctx,
        .media_fn = MediaCtx.media,
    });

    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("文件接收失败：a.pdf", cap.sent.items[0]);
    try t.expectEqual(@as(usize, 0), cap.routed.items.len);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `MediaOutcome` undefined and `ProcessInput` has no `media_ctx`/`media_fn`.

- [ ] **Step 3: Extend ProcessInput and processUpdates**

In `src/weixin/poller.zig`, add near `RouteResult`:

```zig
pub const MediaOutcome = struct {
    /// true ⇒ this message carried inbound media (text path is skipped).
    handled: bool = false,
    /// true ⇒ at least one file saved (route the synthetic prompt).
    any_saved: bool = false,
};
```

Add to `ProcessInput` (after `stop_progress_fn`):

```zig
    media_ctx: ?*anyopaque = null,
    /// Downloads + saves inbound media in `msg`. Fills `receipt` (sent verbatim
    /// as the ack) and `prompt` (routed to the copilot; its reply is suppressed).
    media_fn: ?*const fn (
        ctx: *anyopaque,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome = null,
```

In `processUpdates`, immediately after the `binding.shouldHandle` gate passes (after the `if (!decision.ok) { ... continue; }` block, BEFORE `const text = binding.extractText(msg);`), insert the media branch:

```zig
        if (input.media_fn) |media_fn| {
            var receipt: std.ArrayListUnmanaged(u8) = .empty;
            defer receipt.deinit(input.allocator);
            var prompt: std.ArrayListUnmanaged(u8) = .empty;
            defer prompt.deinit(input.allocator);
            const outcome = media_fn(input.media_ctx.?, msg, input.allocator, &receipt, &prompt) catch |err| blk: {
                std.debug.print("weixin process({d}): index={d} media=failed err={}\n", .{ debugNowMs(), i, err });
                break :blk MediaOutcome{};
            };
            if (outcome.handled) {
                const receipt_trimmed = std.mem.trim(u8, receipt.items, " \t\r\n");
                if (receipt_trimmed.len != 0) {
                    input.send_fn(input.send_ctx, msg.from_user_id, receipt_trimmed, msg.context_token) catch |err| {
                        std.debug.print("weixin send({d}): index={d} kind=receipt status=failed err={}\n", .{ debugNowMs(), i, err });
                    };
                }
                if (outcome.any_saved and prompt.items.len != 0) {
                    var throwaway: std.ArrayListUnmanaged(u8) = .empty;
                    defer throwaway.deinit(input.allocator);
                    const rr = input.route_fn(input.route_ctx, prompt.items, msg.from_user_id, msg.context_token, input.allocator, &throwaway) catch |err| route_blk: {
                        std.debug.print("weixin process({d}): index={d} media_route=failed err={}\n", .{ debugNowMs(), i, err });
                        break :route_blk RouteResult{};
                    };
                    defer if (rr.baseline_transcript.len != 0) input.allocator.free(rr.baseline_transcript);
                    if (rr.expect_ai_progress) {
                        if (input.progress_ctx) |ctx| {
                            if (input.start_progress_fn) |start| {
                                start(ctx, rr.baseline_transcript, msg.from_user_id, msg.context_token) catch |err| {
                                    std.debug.print("weixin process({d}): index={d} media_followup=failed err={}\n", .{ debugNowMs(), i, err });
                                };
                            }
                        }
                    }
                }
                continue; // media handled → skip the text path
            }
        }
```

- [ ] **Step 4: Run the pure tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS — both new processUpdates media tests pass; existing text/voice/stop tests still pass.

- [ ] **Step 5: Commit the pure orchestration**

```bash
git add src/weixin/poller.zig
git commit -m "feat(weixin): processUpdates media branch (receipt ack + routed prompt)"
```

- [ ] **Step 6: Write the failing Poller integration test (real adapter)**

Append to the test section of `src/weixin/poller.zig`:

```zig
const media_mod = @import("media.zig");
const media_inbound = @import("media_inbound.zig");

const DownloadFakeClient = struct {
    plaintext: []const u8,

    fn api(self: *DownloadFakeClient) ilink.ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = getUpdates,
            .send_text = sendText,
            .send_attachment = sendAttachment,
            .download_attachment = downloadAttachment,
        } };
    }
    fn getUpdates(_: *anyopaque, _: []const u8) anyerror!codec.ParsedUpdates {
        return error.NotUsed;
    }
    fn sendText(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn sendAttachment(_: *anyopaque, _: types.AttachmentKind, _: []const u8, _: []const u8, _: []const u8, _: []const u8) anyerror!void {}
    fn downloadAttachment(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: bool) anyerror![]u8 {
        const self: *DownloadFakeClient = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.plaintext);
    }
};

const TmpDirControl = struct {
    dir: []const u8,
    fn is_connected(_: *anyopaque) bool {
        return true;
    }
    fn find_ai_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn send_input(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) bool {
        return false;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    fn ai_approval_pending(_: *anyopaque) bool {
        return false;
    }
    fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
        return false;
    }
    fn inbound_file_dir(ctx: *anyopaque, buf: []u8) []const u8 {
        const self: *TmpDirControl = @ptrCast(@alignCast(ctx));
        const n = @min(self.dir.len, buf.len);
        @memcpy(buf[0..n], self.dir[0..n]);
        return buf[0..n];
    }
    fn iface(self: *TmpDirControl) control_mod.Control {
        return .{ .ctx = self, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
            .inbound_file_dir = inbound_file_dir,
        } };
    }
};

test "pollerMediaAdapter downloads, saves under weixin_inbound, and builds receipt + prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);

    var client = DownloadFakeClient{ .plaintext = "PDF-CONTENT" };
    var ctrl = TmpDirControl{ .dir = root };
    const empty_sync = try t.allocator.alloc(u8, 0);
    defer t.allocator.free(empty_sync);

    var p = Poller{
        .allocator = t.allocator,
        .client = client.api(),
        .control = ctrl.iface(),
        .settings = .{},
        .owner = "u1",
        .account_id = "",
        .sync_buf = empty_sync,
    };

    const msg = types.Message{
        .from_user_id = "u1",
        .context_token = "ctx",
        .item_list = &.{
            .{ .type = 1, .text = "请看这个" },
            .{ .type = 4, .file_name = "report.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "KEY" } },
        },
    };

    var receipt: std.ArrayListUnmanaged(u8) = .empty;
    defer receipt.deinit(t.allocator);
    var prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt.deinit(t.allocator);
    const outcome = try pollerMediaAdapter(&p, msg, t.allocator, &receipt, &prompt);

    try t.expect(outcome.handled);
    try t.expect(outcome.any_saved);
    // File written under <root>/weixin_inbound/report.pdf with decrypted content.
    const saved_path = try std.fs.path.join(t.allocator, &.{ root, "weixin_inbound", "report.pdf" });
    defer t.allocator.free(saved_path);
    const data = try std.fs.cwd().readFileAlloc(t.allocator, saved_path, 1 << 20);
    defer t.allocator.free(data);
    try t.expectEqualStrings("PDF-CONTENT", data);
    // Receipt names the file; prompt has the absolute path and the caption.
    try t.expect(std.mem.indexOf(u8, receipt.items, "report.pdf") != null);
    try t.expect(std.mem.indexOf(u8, prompt.items, saved_path) != null);
    try t.expect(std.mem.indexOf(u8, prompt.items, "请看这个") != null);
}
```

Note: `DownloadFakeClient.downloadAttachment` ignores the key and returns the canned plaintext directly, so the adapter's save path is exercised without real crypto (decryption itself is covered by Task 4). The file item carries a non-empty `aes_key` so `planDownloads` selects it as a file.

- [ ] **Step 7: Run the test to verify it fails**

Run: `zig build test-full 2>&1 | tail -20`
Expected: FAIL — `pollerMediaAdapter` is undefined.

- [ ] **Step 8: Implement pollerMediaAdapter and wire it into tickOnce**

In `src/weixin/poller.zig`, add imports at the top (next to the other `@import`s):

```zig
const media_inbound_mod = @import("media_inbound.zig");
```

Add the adapter as a `Poller` method (next to `pollerSendAttachment`):

```zig
    fn pollerMediaAdapter(
        self: *Poller,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome {
        if (self.stop_requested.load(.acquire)) return .{};
        const plans = try media_inbound_mod.planDownloads(allocator, msg.item_list);
        defer allocator.free(plans);
        if (plans.len == 0) return .{};

        // Resolve <working-dir>/weixin_inbound, falling back to cwd.
        var dir_buf: [4096]u8 = undefined;
        const base_dir = self.control.inboundFileDir(&dir_buf);
        const save_dir = blk: {
            if (base_dir.len != 0) {
                break :blk try std.fs.path.join(allocator, &.{ base_dir, "weixin_inbound" });
            }
            break :blk try allocator.dupe(u8, "weixin_inbound");
        };
        defer allocator.free(save_dir);
        std.fs.cwd().makePath(save_dir) catch |err| {
            std.debug.print("weixin media: makePath failed dir_len={d} err={}\n", .{ save_dir.len, err });
            try receipt.appendSlice(allocator, "收到文件，但无法创建保存目录，已忽略。");
            return .{ .handled = true, .any_saved = false };
        };

        var saved_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (saved_names.items) |n| allocator.free(n);
            saved_names.deinit(allocator);
        }
        var saved_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (saved_paths.items) |pth| allocator.free(pth);
            saved_paths.deinit(allocator);
        }
        var failed_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer failed_names.deinit(allocator);

        for (plans, 0..) |plan, idx| {
            if (self.stop_requested.load(.acquire)) break;
            const bytes = self.client.downloadAttachment(allocator, plan.encrypt_query_param, plan.aes_key, plan.allow_plain) catch |err| {
                std.debug.print("weixin media: download failed kind={s} err={}\n", .{ plan.kind.name(), err });
                try failed_names.append(allocator, failureLabel(plan));
                continue;
            };
            defer allocator.free(bytes);

            const chosen = media_inbound_mod.chooseFileName(allocator, plan, bytes, idx) catch {
                try failed_names.append(allocator, failureLabel(plan));
                continue;
            };
            defer allocator.free(chosen);
            const name = media_inbound_mod.dedupeFileName(allocator, chosen, saved_names.items) catch {
                try failed_names.append(allocator, failureLabel(plan));
                continue;
            };
            errdefer allocator.free(name);

            const full = try std.fs.path.join(allocator, &.{ save_dir, name });
            errdefer allocator.free(full);
            writeFileAbsolute(full, bytes) catch |err| {
                std.debug.print("weixin media: write failed err={}\n", .{err});
                allocator.free(name);
                allocator.free(full);
                try failed_names.append(allocator, failureLabel(plan));
                continue;
            };
            try saved_names.append(allocator, name);
            try saved_paths.append(allocator, full);
        }

        if (saved_names.items.len == 0) {
            // Nothing saved: report only the failures (if any).
            try appendFailureLine(allocator, receipt, failed_names.items);
            return .{ .handled = true, .any_saved = false };
        }

        const receipt_text = try media_inbound_mod.buildReceiptText(allocator, saved_names.items);
        defer allocator.free(receipt_text);
        try receipt.appendSlice(allocator, receipt_text);
        try appendFailureLine(allocator, receipt, failed_names.items);

        const caption = binding.extractText(msg);
        const prompt_text = try media_inbound_mod.buildCopilotPrompt(allocator, saved_paths.items, caption);
        defer allocator.free(prompt_text);
        try prompt.appendSlice(allocator, prompt_text);

        return .{ .handled = true, .any_saved = true };
    }
```

Add these file-scope helpers (next to `debugHash`):

```zig
fn failureLabel(plan: media_inbound_mod.DownloadPlan) []const u8 {
    if (plan.kind == .file and plan.file_name.len != 0) return plan.file_name;
    return plan.kind.name();
}

fn appendFailureLine(allocator: std.mem.Allocator, receipt: *std.ArrayListUnmanaged(u8), failed: []const []const u8) !void {
    if (failed.len == 0) return;
    if (receipt.items.len != 0) try receipt.appendSlice(allocator, "\n");
    try receipt.appendSlice(allocator, "文件接收失败：");
    for (failed, 0..) |name, i| {
        if (i != 0) try receipt.appendSlice(allocator, "、");
        try receipt.appendSlice(allocator, name);
    }
}

fn writeFileAbsolute(path: []const u8, bytes: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{})
    else
        try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(bytes);
}
```

Wire it into `tickOnce` by adding two fields to the `processUpdates(.{ ... })` call:

```zig
            .media_ctx = self,
            .media_fn = pollerMediaAdapterThunk,
```

And add a thin thunk next to `pollerMediaAdapter` matching the `media_fn` signature (the adapter is a method; the callback takes `*anyopaque`):

```zig
    fn pollerMediaAdapterThunk(
        ctx: *anyopaque,
        msg: types.Message,
        allocator: std.mem.Allocator,
        receipt: *std.ArrayListUnmanaged(u8),
        prompt: *std.ArrayListUnmanaged(u8),
    ) anyerror!MediaOutcome {
        const self: *Poller = @ptrCast(@alignCast(ctx));
        return self.pollerMediaAdapter(msg, allocator, receipt, prompt);
    }
```

(Update the Task 6 Step 6 integration test to call `pollerMediaAdapter(&p, ...)` — the method form — which it already does.)

- [ ] **Step 9: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS — the integration test writes and reads `weixin_inbound/report.pdf`, all poller tests green.

- [ ] **Step 10: Commit**

```bash
git add src/weixin/poller.zig
git commit -m "feat(weixin): poller downloads + saves inbound media, informs copilot"
```

---

## Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run the fast suite**

Run: `zig build test 2>&1 | tail -15`
Expected: exit 0, no failures.

- [ ] **Step 2: Run the full suite**

Run: `zig build test-full 2>&1 | tail -15`
Expected: exit 0, 0 failed (skips allowed).

- [ ] **Step 3: Verify the Windows cross-compile**

Run: `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -15`
Expected: builds clean.

- [ ] **Step 4: Confirm no stray debug or leaks in new code**

Manually skim the diff for the new modules; confirm every allocation in `pollerMediaAdapter` is freed on all paths (the `errdefer`/`defer` pairs around `name`/`full` when appended vs. on failure).

- [ ] **Step 5: Update memory**

Add a one-line entry to `/home/xzg/.claude/projects/-home-xzg-project-phantty/memory/MEMORY.md` and a topic file describing the inbound-files feature (status: branch `worktree-feat-recevie-wechat-file`, tests green, GUI verify pending), linking `[[wispterm-weixin-agent-attachments]]` if present.

---

## Self-Review Notes

- **Spec coverage:** parseAesKey/decrypt/cdnDownloadUrl (Task 1) ✓; inbound item parsing (Task 2) ✓; planDownloads/mime/sanitize/dedupe/receipt/prompt (Task 3) ✓; downloadAttachment + ClientApi seam (Task 4) ✓; inboundFileDir seam (Task 5) ✓; poller orchestration: download→save→receipt(ack)→prompt→streaming, before the no_text_item skip, failure handling, save-dir fallback (Task 6) ✓; testing strategy (every task) ✓; non-goals (video/voice/Vision/worker/remote) untouched ✓.
- **Type consistency:** `MediaOutcome{handled, any_saved}`, `DownloadPlan{kind, encrypt_query_param, aes_key, file_name, allow_plain}`, `Control.inbound_file_dir`/`inboundFileDir`, `ClientApi.download_attachment`/`downloadAttachment`, `Client.cdn_download_impl`, `media.parseAesKey`/`aes128EcbPkcs7Decrypt`/`cdnDownloadUrl` are used identically across tasks.
- **GUI note:** the `AppWindow` handler and dispatch op cannot be unit-tested on Linux (no GUI backend); covered by the Windows cross-compile check and deferred GUI verification, consistent with the rest of the weixin direct bridge.
