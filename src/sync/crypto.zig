//! End-to-end encryption for sync. Everything WispTerm puts on a WebDAV drive
//! or a synced folder is sealed here first, so the drive (and anyone who can
//! read it) only ever sees ciphertext.
//!
//! The key comes from the user's sync passphrase through Argon2id; the salt and
//! cost parameters live in the plaintext `wispterm-sync.json` next to the data,
//! so a second computer derives the same key from the same passphrase. Files
//! are XChaCha20-Poly1305 sealed with their logical name as associated data, so
//! a file renamed or swapped on the drive fails to open instead of being read
//! as another kind.
const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const KEY_LEN = 32;
pub const Key = [KEY_LEN]u8;
pub const SALT_LEN = 16;

/// Prefix of every sealed file: format tag, then nonce ‖ ciphertext ‖ tag.
pub const MAGIC = "WSY1";
const CHECK_NAME = "wispterm-sync-check";
const CHECK_TEXT = "wispterm-sync passphrase check v1";

pub const KdfParams = struct {
    /// Argon2id time cost.
    t: u32,
    /// Memory cost in KiB.
    m: u32,
    p: u24,

    /// OWASP's Argon2id baseline: strong enough for a passphrase, and quick on
    /// a laptop even in a debug build (it runs once per computer).
    pub const default: KdfParams = .{ .t = 2, .m = 19 * 1024, .p = 1 };
    /// Cheap parameters for tests only.
    pub const testing: KdfParams = .{ .t = 1, .m = 64, .p = 1 };
};

pub fn deriveKey(allocator: std.mem.Allocator, passphrase: []const u8, salt: []const u8, params: KdfParams) !Key {
    var key: Key = undefined;
    try argon2.kdf(allocator, &key, passphrase, salt, .{ .t = params.t, .m = params.m, .p = params.p }, .argon2id);
    return key;
}

pub fn randomSalt() [SALT_LEN]u8 {
    var salt: [SALT_LEN]u8 = undefined;
    std.crypto.random.bytes(&salt);
    return salt;
}

/// Seal `plaintext` for the file called `name`. Caller frees the result.
pub fn seal(allocator: std.mem.Allocator, key: Key, name: []const u8, plaintext: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, MAGIC.len + Aead.nonce_length + plaintext.len + Aead.tag_length);
    @memcpy(out[0..MAGIC.len], MAGIC);
    const nonce = out[MAGIC.len..][0..Aead.nonce_length];
    std.crypto.random.bytes(nonce);
    const ciphertext = out[MAGIC.len + Aead.nonce_length ..][0..plaintext.len];
    const tag = out[MAGIC.len + Aead.nonce_length + plaintext.len ..][0..Aead.tag_length];
    Aead.encrypt(ciphertext, tag, plaintext, name, nonce.*, key);
    return out;
}

/// Open a file sealed by `seal` under the same `name`. Caller frees (and, for
/// secrets, wipes) the result.
pub fn open(allocator: std.mem.Allocator, key: Key, name: []const u8, sealed: []const u8) ![]u8 {
    const overhead = MAGIC.len + Aead.nonce_length + Aead.tag_length;
    if (sealed.len < overhead or !std.mem.eql(u8, sealed[0..MAGIC.len], MAGIC)) return error.NotSyncFile;
    const plain_len = sealed.len - overhead;
    const out = try allocator.alloc(u8, plain_len);
    errdefer allocator.free(out);
    const nonce = sealed[MAGIC.len..][0..Aead.nonce_length];
    Aead.decrypt(
        out,
        sealed[MAGIC.len + Aead.nonce_length ..][0..plain_len],
        sealed[MAGIC.len + Aead.nonce_length + plain_len ..][0..Aead.tag_length].*,
        name,
        nonce.*,
        key,
    ) catch return error.WrongKey;
    return out;
}

/// A sealed known value stored in the plaintext meta file: opening it proves a
/// passphrase is the one this sync folder was created with.
pub fn checkValue(allocator: std.mem.Allocator, key: Key) ![]u8 {
    return seal(allocator, key, CHECK_NAME, CHECK_TEXT);
}

pub fn verifyCheck(allocator: std.mem.Allocator, key: Key, check: []const u8) bool {
    const plain = open(allocator, key, CHECK_NAME, check) catch return false;
    defer allocator.free(plain);
    return std.mem.eql(u8, plain, CHECK_TEXT);
}

pub const HashHex = [Sha256.digest_length * 2]u8;

pub fn sha256Hex(bytes: []const u8) HashHex {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const b64 = std.base64.standard;

pub fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, b64.Encoder.calcSize(bytes.len));
    return @constCast(b64.Encoder.encode(out, bytes));
}

pub fn unbase64Alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = b64.Decoder.calcSizeForSlice(text) catch return error.InvalidBase64;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    b64.Decoder.decode(out, text) catch return error.InvalidBase64;
    return out;
}

test "sync crypto seals with the file name as associated data" {
    const allocator = std.testing.allocator;
    const key: Key = @splat(7);
    const sealed = try seal(allocator, key, "passwords", "hello");
    defer allocator.free(sealed);
    try std.testing.expect(std.mem.startsWith(u8, sealed, MAGIC));
    try std.testing.expect(std.mem.indexOf(u8, sealed, "hello") == null);

    const plain = try open(allocator, key, "passwords", sealed);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("hello", plain);

    try std.testing.expectError(error.WrongKey, open(allocator, key, "ssh_hosts", sealed));
    try std.testing.expectError(error.WrongKey, open(allocator, @splat(8), "passwords", sealed));
    try std.testing.expectError(error.NotSyncFile, open(allocator, key, "passwords", "plain text"));
}

test "sync crypto derives the same key from the same passphrase and salt" {
    const allocator = std.testing.allocator;
    const salt = [_]u8{1} ** SALT_LEN;
    const a = try deriveKey(allocator, "correct horse", &salt, KdfParams.testing);
    const b = try deriveKey(allocator, "correct horse", &salt, KdfParams.testing);
    const c = try deriveKey(allocator, "wrong horse", &salt, KdfParams.testing);
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));

    const check = try checkValue(allocator, a);
    defer allocator.free(check);
    try std.testing.expect(verifyCheck(allocator, b, check));
    try std.testing.expect(!verifyCheck(allocator, c, check));
}

test "sync crypto base64 round-trips and hashes are stable hex" {
    const allocator = std.testing.allocator;
    const encoded = try base64Alloc(allocator, "\x00\xffabc");
    defer allocator.free(encoded);
    const decoded = try unbase64Alloc(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("\x00\xffabc", decoded);
    try std.testing.expectError(error.InvalidBase64, unbase64Alloc(allocator, "!!"));
    const h = sha256Hex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &h);
}

test "sync crypto declarations compile" {
    std.testing.refAllDecls(@This());
}
