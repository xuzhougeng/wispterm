//! Pure helpers for Weixin iLink media uploads.
const std = @import("std");

pub const AesKey = [16]u8;

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

pub fn aes128EcbPkcs7DecryptForTest(allocator: std.mem.Allocator, key: AesKey, encrypted: []const u8) ![]u8 {
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

pub fn uploadUrlWithTicket(allocator: std.mem.Allocator, base_url: []const u8, ticket: []const u8) ![]u8 {
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, base_url, '?') == null) "?" else "&";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_url, sep, ticket });
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

test "AES ECB PKCS7 encrypts and decrypts multiple blocks" {
    const key: AesKey = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const plain = "0123456789abcdef0123456789abcdef!";
    const encrypted = try aes128EcbPkcs7Encrypt(t.allocator, key, plain);
    defer t.allocator.free(encrypted);
    try t.expectEqual(@as(usize, 48), encrypted.len);
    try t.expect(!std.mem.eql(u8, encrypted[0..plain.len], plain));

    const decrypted = try aes128EcbPkcs7DecryptForTest(t.allocator, key, encrypted);
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

test "uploadUrlWithTicket appends ticket query using question mark or ampersand" {
    const a = try uploadUrlWithTicket(t.allocator, "https://cdn.example/upload", "ticket=abc");
    defer t.allocator.free(a);
    try t.expectEqualStrings("https://cdn.example/upload?ticket=abc", a);

    const b = try uploadUrlWithTicket(t.allocator, "https://cdn.example/upload?x=1", "ticket=abc");
    defer t.allocator.free(b);
    try t.expectEqualStrings("https://cdn.example/upload?x=1&ticket=abc", b);
}
