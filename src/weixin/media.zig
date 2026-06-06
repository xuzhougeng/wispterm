//! Pure helpers for Weixin iLink media uploads.
const std = @import("std");

pub const AesKey = [16]u8;
pub const DEFAULT_CDN_UPLOAD_BASE_URL = "https://novac2c.cdn.weixin.qq.com/c2c";

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
        const block: *[16]u8 = out[offset..][0..16];
        ctx.encrypt(block, block);
    }
    return out;
}

pub fn aes128EcbPkcs7Decrypt(allocator: std.mem.Allocator, key: AesKey, encrypted: []const u8) ![]u8 {
    if (encrypted.len == 0 or encrypted.len % 16 != 0) return error.InvalidCiphertext;
    const padded = try allocator.dupe(u8, encrypted);
    errdefer allocator.free(padded);

    var ctx = std.crypto.core.aes.Aes128.initDec(key);
    var offset: usize = 0;
    while (offset < padded.len) : (offset += 16) {
        const block: *[16]u8 = padded[offset..][0..16];
        ctx.decrypt(block, block);
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
    writeHexLower(hex, &key);
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(hex.len));
    _ = std.base64.standard.Encoder.encode(out, hex);
    return out;
}

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

pub fn md5Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    writeHexLower(out, &digest);
    return out;
}

fn writeHexLower(out: []u8, data: []const u8) void {
    const hex = "0123456789abcdef";
    std.debug.assert(out.len == data.len * 2);
    for (data, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
}

pub fn cdnUploadUrl(allocator: std.mem.Allocator, upload_full_url: []const u8, upload_param: []const u8, file_key: []const u8) ![]u8 {
    if (upload_full_url.len != 0) return allocator.dupe(u8, upload_full_url);

    const base_url = DEFAULT_CDN_UPLOAD_BASE_URL;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, base_url);
    if (std.mem.endsWith(u8, base_url, "/")) {
        try out.appendSlice(allocator, "upload?");
    } else {
        try out.appendSlice(allocator, "/upload?");
    }
    try out.appendSlice(allocator, "encrypted_query_param=");
    try appendQueryEscaped(&out, allocator, upload_param);
    try out.appendSlice(allocator, "&filekey=");
    try appendQueryEscaped(&out, allocator, file_key);
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

    const decrypted = try aes128EcbPkcs7Decrypt(t.allocator, key, encrypted);
    defer t.allocator.free(decrypted);
    try t.expectEqualStrings("hello", decrypted);
}

test "AES ECB PKCS7 encrypts and decrypts multiple blocks" {
    const key: AesKey = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const plain = "0123456789abcdef0123456789abcdef!";
    const encrypted = try aes128EcbPkcs7Encrypt(t.allocator, key, plain);
    defer t.allocator.free(encrypted);
    try t.expectEqual(@as(usize, 48), encrypted.len);
    try t.expect(!std.mem.eql(u8, encrypted[0..plain.len], plain));

    const decrypted = try aes128EcbPkcs7Decrypt(t.allocator, key, encrypted);
    defer t.allocator.free(decrypted);
    try t.expectEqualStrings(plain, decrypted);
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

test "parseAesKey decodes a base64 raw 16-byte key" {
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

test "cdnUploadUrl appends encrypted upload query fields" {
    const a = try cdnUploadUrl(t.allocator, "", "a+b&c=1", "file key");
    defer t.allocator.free(a);
    try t.expectEqualStrings(DEFAULT_CDN_UPLOAD_BASE_URL ++ "/upload?encrypted_query_param=a%2Bb%26c%3D1&filekey=file%20key", a);

    const b = try cdnUploadUrl(t.allocator, "https://cdn.example/full-upload?token=1", "ignored", "ignored-key");
    defer t.allocator.free(b);
    try t.expectEqualStrings("https://cdn.example/full-upload?token=1", b);
}
