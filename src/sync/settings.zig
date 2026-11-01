//! This computer's sync settings and state, under `<config-dir>/sync/`:
//!
//! - `settings.json`: where to sync (WebDAV URL + user, or a folder), which
//!   kinds, and how often. The WebDAV password and the derived sync key are
//!   stored sealed with the password store's OS-held key
//!   (platform/vault_key.zig), never in clear text; the sync passphrase itself
//!   is never stored.
//! - `base-<kind>.json`: the item set this computer last agreed on with the
//!   drive (sync/merge.zig), no payloads or secrets.
//!
//! Every function takes the state directory explicitly so tests use a temp dir.
const std = @import("std");
const builtin = @import("builtin");
const crypto = @import("crypto.zig");
const merge = @import("merge.zig");
const platform_dirs = @import("../platform/dirs.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const vault_key = @import("../platform/vault_key.zig");

pub const DIR_NAME = "sync";
const SETTINGS_BASENAME = "settings.json";
const MAX_STATE_BYTES: usize = 16 * 1024 * 1024;
const LOCAL_SEAL_NAME = "wispterm-sync-local";

pub const Target = enum { webdav, folder };

pub const Kind = enum {
    passwords,
    history,
    ssh_hosts,
    ai_profiles,

    /// Manifest name on the drive (also the AEAD associated data).
    pub fn manifestName(kind: Kind) []const u8 {
        return switch (kind) {
            .passwords => "passwords.wsync",
            .history => "history.wsync",
            .ssh_hosts => "ssh_hosts.wsync",
            .ai_profiles => "ai_profiles.wsync",
        };
    }
};

pub const INTERVAL_CHOICES = [_]u32{ 0, 5, 15, 30, 60 };

pub const Settings = struct {
    version: u32 = 1,
    target: Target = .webdav,
    url: []const u8 = "",
    username: []const u8 = "",
    /// Folder inside the WebDAV share (created on first sync).
    remote_folder: []const u8 = "WispTerm",
    /// Local folder for the synced-folder target.
    folder: []const u8 = "",
    passwords: bool = true,
    history: bool = true,
    ssh_hosts: bool = true,
    ai_profiles: bool = true,
    /// Automatic sync period; 0 = only on "Sync Now".
    interval_minutes: u32 = 15,
    /// WebDAV password sealed with this computer's vault key (base64).
    password_sealed: []const u8 = "",
    /// Sync key sealed with the vault key (base64) and the drive salt (base64)
    /// it was derived with; a different salt on the drive means the drive was
    /// reset and the passphrase is needed again.
    key_sealed: []const u8 = "",
    key_salt: []const u8 = "",

    pub fn kindEnabled(self: Settings, kind: Kind) bool {
        return switch (kind) {
            .passwords => self.passwords,
            .history => self.history,
            .ssh_hosts => self.ssh_hosts,
            .ai_profiles => self.ai_profiles,
        };
    }

    pub fn setKindEnabled(self: *Settings, kind: Kind, on: bool) void {
        switch (kind) {
            .passwords => self.passwords = on,
            .history => self.history = on,
            .ssh_hosts => self.ssh_hosts = on,
            .ai_profiles => self.ai_profiles = on,
        }
    }

    /// Enough to reach the drive (the key may still be missing).
    pub fn hasLocation(self: Settings) bool {
        return switch (self.target) {
            .webdav => std.mem.trim(u8, self.url, " \t").len > 0,
            .folder => std.mem.trim(u8, self.folder, " \t").len > 0,
        };
    }

    pub fn hasKey(self: Settings) bool {
        return self.key_sealed.len > 0 and self.key_salt.len > 0;
    }
};

/// Settings plus the arena that owns their strings.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    value: Settings = .{},

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn dupe(self: *Loaded, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }
};

/// `<config-dir>/sync`.
pub fn defaultDir(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, DIR_NAME);
}

pub fn load(allocator: std.mem.Allocator, dir: []const u8) !Loaded {
    var loaded = Loaded{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer loaded.deinit();
    const a = loaded.arena.allocator();
    const p = try std.fs.path.join(a, &.{ dir, SETTINGS_BASENAME });
    const bytes = std.fs.cwd().readFileAlloc(a, p, MAX_STATE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return loaded,
        else => return err,
    };
    loaded.value = try std.json.parseFromSliceLeaky(Settings, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    return loaded;
}

pub fn save(allocator: std.mem.Allocator, dir: []const u8, value: Settings) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeStateFile(allocator, dir, SETTINGS_BASENAME, json);
}

/// Forget this computer's sync setup (settings, sealed secrets, bases). The
/// drive is not touched.
pub fn forget(dir: []const u8) void {
    std.fs.cwd().deleteTree(dir) catch {};
}

fn writeStateFile(allocator: std.mem.Allocator, dir: []const u8, basename: []const u8, data: []const u8) !void {
    try std.fs.cwd().makePath(dir);
    const p = try std.fs.path.join(allocator, &.{ dir, basename });
    defer allocator.free(p);
    try platform_atomic_file.writeFileReplaceSafeWithOptions(p, data, .{
        .mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else 0o600,
    });
}

fn baseBasename(buf: []u8, kind: Kind) []const u8 {
    return std.fmt.bufPrint(buf, "base-{s}.json", .{@tagName(kind)}) catch unreachable;
}

/// The kind's base; missing or unreadable = empty (first sync).
pub fn loadBase(arena: std.mem.Allocator, dir: []const u8, kind: Kind) merge.Base {
    var name_buf: [64]u8 = undefined;
    const p = std.fs.path.join(arena, &.{ dir, baseBasename(&name_buf, kind) }) catch return .{};
    const bytes = std.fs.cwd().readFileAlloc(arena, p, MAX_STATE_BYTES) catch return .{};
    return merge.parseBase(arena, bytes) catch .{};
}

pub fn saveBase(allocator: std.mem.Allocator, dir: []const u8, kind: Kind, base: merge.Base) !void {
    const json = try merge.serializeBase(allocator, base);
    defer allocator.free(json);
    var name_buf: [64]u8 = undefined;
    try writeStateFile(allocator, dir, baseBasename(&name_buf, kind), json);
}

pub fn clearBases(allocator: std.mem.Allocator, dir: []const u8) void {
    for (std.enums.values(Kind)) |kind| {
        var name_buf: [64]u8 = undefined;
        const p = std.fs.path.join(allocator, &.{ dir, baseBasename(&name_buf, kind) }) catch continue;
        defer allocator.free(p);
        std.fs.cwd().deleteFile(p) catch {};
    }
}

// ---------------------------------------------------------------------------
// Secrets sealed with this computer's vault key
// ---------------------------------------------------------------------------

/// Tests never touch the OS keychain (same rule as credential/store.zig).
fn localKey(allocator: std.mem.Allocator) !crypto.Key {
    return if (builtin.is_test) @as(crypto.Key, @splat(0x24)) else vault_key.loadOrCreate(allocator);
}

/// Seal `plaintext` with the vault key; base64 result owned by `allocator`.
pub fn sealLocal(allocator: std.mem.Allocator, plaintext: []const u8) ![]u8 {
    var key = try localKey(allocator);
    defer std.crypto.secureZero(u8, &key);
    const sealed = try crypto.seal(allocator, key, LOCAL_SEAL_NAME, plaintext);
    defer allocator.free(sealed);
    return crypto.base64Alloc(allocator, sealed);
}

/// Open a value from `sealLocal`. Wipe and free the result.
pub fn openLocal(allocator: std.mem.Allocator, sealed_b64: []const u8) ![]u8 {
    const sealed = try crypto.unbase64Alloc(allocator, sealed_b64);
    defer allocator.free(sealed);
    var key = try localKey(allocator);
    defer std.crypto.secureZero(u8, &key);
    return crypto.open(allocator, key, LOCAL_SEAL_NAME, sealed);
}

pub fn wipe(allocator: std.mem.Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    allocator.free(secret);
}

/// The stored sync key, or null when none is saved.
pub fn openSyncKey(allocator: std.mem.Allocator, value: Settings) !?crypto.Key {
    if (!value.hasKey()) return null;
    const raw = try openLocal(allocator, value.key_sealed);
    defer wipe(allocator, raw);
    if (raw.len != crypto.KEY_LEN) return error.CorruptSyncKey;
    return raw[0..crypto.KEY_LEN].*;
}

test "sync settings round-trip and keep secrets sealed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    {
        var empty = try load(allocator, dir);
        defer empty.deinit();
        try std.testing.expect(!empty.value.hasLocation());
        try std.testing.expectEqual(@as(u32, 15), empty.value.interval_minutes);
    }

    const sealed_pw = try sealLocal(allocator, "app-password");
    defer allocator.free(sealed_pw);
    const key: crypto.Key = @splat(9);
    const sealed_key = try sealLocal(allocator, &key);
    defer allocator.free(sealed_key);
    try save(allocator, dir, .{
        .url = "https://dav.example.com/dav",
        .username = "me",
        .history = false,
        .password_sealed = sealed_pw,
        .key_sealed = sealed_key,
        .key_salt = "c2FsdA==",
    });
    const raw = try tmp.dir.readFileAlloc(allocator, "settings.json", 1 << 20);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "app-password") == null);

    var back = try load(allocator, dir);
    defer back.deinit();
    try std.testing.expect(back.value.hasLocation() and back.value.hasKey());
    try std.testing.expect(!back.value.kindEnabled(.history));
    const pw = try openLocal(allocator, back.value.password_sealed);
    defer wipe(allocator, pw);
    try std.testing.expectEqualStrings("app-password", pw);
    const opened = (try openSyncKey(allocator, back.value)).?;
    try std.testing.expectEqualSlices(u8, &key, &opened);
}

test "sync settings bases are per kind and default to empty" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(usize, 0), loadBase(arena.allocator(), dir, .passwords).items.len);
    try saveBase(allocator, dir, .ssh_hosts, .{ .items = &.{.{ .key = "box", .updated_at = 3, .hash = "h", .token = "t" }} });
    const base = loadBase(arena.allocator(), dir, .ssh_hosts);
    try std.testing.expectEqualStrings("box", base.items[0].key);
    try std.testing.expectEqual(@as(usize, 0), loadBase(arena.allocator(), dir, .ai_profiles).items.len);
    clearBases(allocator, dir);
    try std.testing.expectEqual(@as(usize, 0), loadBase(arena.allocator(), dir, .ssh_hosts).items.len);
}

test "sync settings declarations compile" {
    std.testing.refAllDecls(@This());
}
