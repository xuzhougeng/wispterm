//! Password vault shared by the user (Password Store page, Command Center copy
//! rows) and the AI agent (`password_input` tool). One file,
//! `<config-dir>/passwords`: a JSON array of entries whose `secret` is
//! XChaCha20-Poly1305 ciphertext (base64 of nonce ‖ ciphertext ‖ tag). The key
//! is held by the OS (platform/vault_key.zig), never written next to the vault,
//! so reading the file shows names and notes but no password. Secrets are
//! decrypted only on an explicit reveal/copy or an approved agent request.
//!
//! The first version of this store was plain `name = secret` lines; such a
//! file is encrypted in place the first time it is loaded.
const std = @import("std");
const builtin = @import("builtin");
const platform_dirs = @import("../platform/dirs.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const vault_key = @import("../platform/vault_key.zig");

pub const MAX_BYTES: usize = 256 * 1024;
pub const BASENAME = "passwords";

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const b64 = std.base64.standard;

pub const Entry = struct {
    name: []const u8,
    username: []const u8 = "",
    /// Sealed secret (see module doc); "" means no password set.
    secret: []const u8 = "",
    /// What the secret is for; shown to the agent so it can pick the right one.
    note: []const u8 = "",
    /// false = `password_input` refuses this entry without even asking.
    agent: bool = true,
};

/// Entries plus the arena that owns every string in them. Edits dupe the new
/// text into the arena; replaced strings stay until deinit (the vault is tiny).
pub const Vault = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Set by `parse` for a legacy line file: secrets are still plaintext.
    legacy_plaintext: bool = false,

    pub fn init(child: std.mem.Allocator) Vault {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *Vault) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn dupe(self: *Vault, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }

    pub fn append(self: *Vault, entry: Entry) !void {
        try self.entries.append(self.arena.allocator(), entry);
    }

    /// Index of the entry named `name` (case-insensitive), skipping `except`.
    pub fn find(self: *const Vault, name: []const u8, except: ?usize) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (except != null and except.? == i) continue;
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return i;
        }
        return null;
    }

    /// Encrypt `plaintext` into a sealed secret owned by this vault.
    pub fn seal(self: *Vault, plaintext: []const u8) ![]const u8 {
        if (plaintext.len == 0) return "";
        var key = try vaultKey(self.arena.child_allocator);
        defer std.crypto.secureZero(u8, &key);
        return sealWithKey(self.arena.allocator(), key, plaintext);
    }
};

pub fn lookup(entries: []const Entry, name: []const u8) ?*const Entry {
    for (entries) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
    }
    return null;
}

/// Decrypt an entry's secret. Release it with `wipe`.
pub fn reveal(allocator: std.mem.Allocator, entry: *const Entry) ![]u8 {
    if (entry.secret.len == 0) return allocator.alloc(u8, 0);
    var key = try vaultKey(allocator);
    defer std.crypto.secureZero(u8, &key);
    return openWithKey(allocator, key, entry.secret);
}

/// Zero then free a secret returned by `reveal`.
pub fn wipe(allocator: std.mem.Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    allocator.free(secret);
}

/// Tests never touch the OS keychain: the branch is comptime, so the platform
/// key code is not even compiled into test binaries.
fn vaultKey(allocator: std.mem.Allocator) !vault_key.Key {
    return if (builtin.is_test) @as(vault_key.Key, @splat(0x42)) else vault_key.loadOrCreate(allocator);
}

fn sealWithKey(allocator: std.mem.Allocator, key: vault_key.Key, plaintext: []const u8) ![]const u8 {
    const raw = try allocator.alloc(u8, Aead.nonce_length + plaintext.len + Aead.tag_length);
    defer allocator.free(raw);
    const nonce = raw[0..Aead.nonce_length];
    std.crypto.random.bytes(nonce);
    const ciphertext = raw[Aead.nonce_length..][0..plaintext.len];
    const tag = raw[Aead.nonce_length + plaintext.len ..][0..Aead.tag_length];
    Aead.encrypt(ciphertext, tag, plaintext, "", nonce.*, key);
    const out = try allocator.alloc(u8, b64.Encoder.calcSize(raw.len));
    return b64.Encoder.encode(out, raw);
}

fn openWithKey(allocator: std.mem.Allocator, key: vault_key.Key, sealed: []const u8) ![]u8 {
    const raw_len = b64.Decoder.calcSizeForSlice(sealed) catch return error.CorruptSecret;
    if (raw_len < Aead.nonce_length + Aead.tag_length) return error.CorruptSecret;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    b64.Decoder.decode(raw, sealed) catch return error.CorruptSecret;
    const plain_len = raw_len - Aead.nonce_length - Aead.tag_length;
    const out = try allocator.alloc(u8, plain_len);
    errdefer allocator.free(out);
    Aead.decrypt(
        out,
        raw[Aead.nonce_length..][0..plain_len],
        raw[Aead.nonce_length + plain_len ..][0..Aead.tag_length].*,
        "",
        raw[0..Aead.nonce_length].*,
        key,
    ) catch return error.WrongKey;
    return out;
}

/// Parse file content: a JSON array, or the legacy `name = secret` lines
/// (secrets left plaintext and `legacy_plaintext` set; `load` seals them).
pub fn parse(child: std.mem.Allocator, content: []const u8) !Vault {
    var vault = Vault.init(child);
    errdefer vault.deinit();
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return vault;
    if (trimmed[0] == '[') {
        const parsed = try std.json.parseFromSliceLeaky([]Entry, vault.arena.allocator(), trimmed, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        for (parsed) |entry| {
            if (entry.name.len == 0) continue;
            try vault.append(entry);
        }
        return vault;
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const legacy = parseLegacyLine(line) orelse continue;
        try vault.append(.{ .name = try vault.dupe(legacy.name), .secret = try vault.dupe(legacy.secret) });
        vault.legacy_plaintext = true;
    }
    return vault;
}

const LegacyLine = struct { name: []const u8, secret: []const u8 };

/// `name = secret`; comments, blanks, and lines without a name are skipped.
/// The secret keeps everything after the first `=` (trimmed).
fn parseLegacyLine(line_raw: []const u8) ?LegacyLine {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const name = std.mem.trim(u8, line[0..eq], " \t");
    const secret = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (name.len == 0 or secret.len == 0) return null;
    return .{ .name = name, .secret = secret };
}

/// Seal every plaintext secret of a legacy vault in place.
pub fn sealLegacy(vault: *Vault) !void {
    for (vault.entries.items) |*entry| entry.secret = try vault.seal(entry.secret);
    vault.legacy_plaintext = false;
}

pub fn serialize(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, entries, .{ .whitespace = .indent_2 });
}

pub fn path(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, BASENAME);
}

/// Read the vault (names/notes only; nothing is decrypted). A missing file is
/// an empty vault; a legacy plaintext file is encrypted and rewritten here.
pub fn load(allocator: std.mem.Allocator) !Vault {
    // Tests must never read or rewrite the developer's real vault.
    if (builtin.is_test) return Vault.init(allocator);
    const p = try path(allocator);
    defer allocator.free(p);
    const content = std.fs.cwd().readFileAlloc(allocator, p, MAX_BYTES) catch |err| switch (err) {
        error.FileNotFound => return Vault.init(allocator),
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, content);
        allocator.free(content);
    }
    var vault = try parse(allocator, content);
    errdefer vault.deinit();
    if (vault.legacy_plaintext) {
        try sealLegacy(&vault);
        try save(allocator, vault.entries.items);
    }
    return vault;
}

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// Hash of the vault file as it is on disk now (all zero when missing), so a
/// holder of a loaded copy can tell that a sync or another window rewrote it.
pub fn fileFingerprint(allocator: std.mem.Allocator) Fingerprint {
    var out: Fingerprint = @splat(0);
    if (builtin.is_test) return out;
    const p = path(allocator) catch return out;
    defer allocator.free(p);
    const content = std.fs.cwd().readFileAlloc(allocator, p, MAX_BYTES) catch return out;
    defer allocator.free(content);
    std.crypto.hash.sha2.Sha256.hash(content, &out, .{});
    return out;
}

pub fn save(allocator: std.mem.Allocator, entries: []const Entry) !void {
    if (builtin.is_test) return;
    const p = try path(allocator);
    defer allocator.free(p);
    const json = try serialize(allocator, entries);
    defer allocator.free(json);
    try platform_atomic_file.writeFileReplaceSafeWithOptions(p, json, .{
        .mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else 0o600,
    });
}

// ---------------------------------------------------------------------------
// Palette cache: feature-owned UI state (threadlocal = per window thread, like
// recipe/ui_state.zig) so renderer/overlays.zig gains no new g_* field.
// ---------------------------------------------------------------------------

threadlocal var g_palette: ?Vault = null;

pub fn paletteItems() []const Entry {
    return if (g_palette) |*vault| vault.entries.items else &.{};
}

pub fn ensurePaletteList(allocator: std.mem.Allocator) void {
    if (g_palette != null) return;
    g_palette = load(allocator) catch Vault.init(allocator);
}

pub fn invalidatePaletteList() void {
    if (g_palette) |*vault| vault.deinit();
    g_palette = null;
}

test "password store reads legacy lines and seals them" {
    const content = "# header\n\nroot = s3cret\nmysql=pa=ss word \n  # mysql = commented\nbroken line\n= nosecret\nempty =\n";
    var vault = try parse(std.testing.allocator, content);
    defer vault.deinit();
    try std.testing.expect(vault.legacy_plaintext);
    try std.testing.expectEqual(@as(usize, 2), vault.entries.items.len);
    try std.testing.expectEqualStrings("pa=ss word", vault.entries.items[1].secret);

    try sealLegacy(&vault);
    const json = try serialize(std.testing.allocator, vault.entries.items);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "s3cret") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pa=ss") == null);
    const secret = try reveal(std.testing.allocator, &vault.entries.items[1]);
    defer wipe(std.testing.allocator, secret);
    try std.testing.expectEqualStrings("pa=ss word", secret);
}

test "password store JSON round-trips fields and keeps the secret sealed" {
    var vault = Vault.init(std.testing.allocator);
    defer vault.deinit();
    try vault.append(.{ .name = "root", .username = "root", .secret = try vault.seal("a\"b\\c"), .note = "lab sudo", .agent = false });
    try vault.append(.{ .name = "MySQL" });
    const json = try serialize(std.testing.allocator, vault.entries.items);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "a\\\"b") == null);

    var back = try parse(std.testing.allocator, json);
    defer back.deinit();
    try std.testing.expect(!back.legacy_plaintext);
    const root = back.entries.items[0];
    try std.testing.expectEqualStrings("lab sudo", root.note);
    try std.testing.expect(!root.agent);
    try std.testing.expect(back.entries.items[1].agent);
    const secret = try reveal(std.testing.allocator, &root);
    defer wipe(std.testing.allocator, secret);
    try std.testing.expectEqualStrings("a\"b\\c", secret);
    const empty = try reveal(std.testing.allocator, &back.entries.items[1]);
    defer wipe(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    var sparse = try parse(std.testing.allocator, "[{\"name\":\"\"},{\"name\":\"pg\",\"extra\":1}]");
    defer sparse.deinit();
    try std.testing.expectEqual(@as(usize, 1), sparse.entries.items.len);
}

test "password store rejects tampered or wrong-key secrets" {
    var vault = Vault.init(std.testing.allocator);
    defer vault.deinit();
    const sealed = try vault.seal("hunter2");
    try std.testing.expectError(error.WrongKey, openWithKey(std.testing.allocator, @splat(0x01), sealed));
    const tampered = try vault.dupe(sealed);
    @constCast(tampered)[tampered.len - 3] ^= 1;
    try std.testing.expect(std.meta.isError(reveal(std.testing.allocator, &.{ .name = "x", .secret = tampered })));
    try std.testing.expectError(error.CorruptSecret, reveal(std.testing.allocator, &.{ .name = "x", .secret = "AAAA" }));
}

test "password store lookup and find are case-insensitive" {
    var vault = try parse(std.testing.allocator, "root = a\nMySQL = b\n");
    defer vault.deinit();
    try std.testing.expectEqualStrings("MySQL", lookup(vault.entries.items, "mysql").?.name);
    try std.testing.expect(lookup(vault.entries.items, "postgres") == null);
    try std.testing.expectEqual(@as(?usize, 1), vault.find("MYSQL", null));
    try std.testing.expectEqual(@as(?usize, null), vault.find("mysql", 1));
}
