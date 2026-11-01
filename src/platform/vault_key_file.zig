//! Fallback (Linux and other targets): the key is a raw owner-only (0600)
//! `<config-dir>/passwords.key`. Secrets are still ciphertext in the vault, but
//! a same-user process can read this key file.
//! ponytail: no Secret Service (libsecret/D-Bus) yet; add it here when the
//! Linux build leaves experimental.
const std = @import("std");
const platform_dirs = @import("dirs.zig");
const platform_atomic_file = @import("atomic_file.zig");

pub fn loadOrCreate(allocator: std.mem.Allocator) ![32]u8 {
    const path = try platform_dirs.pathInConfigDir(allocator, "passwords.key");
    defer allocator.free(path);
    var key: [32]u8 = undefined;
    if (std.fs.cwd().readFile(path, &key)) |read| {
        if (read.len != key.len) return error.KeyFileCorrupt;
        return key;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.crypto.random.bytes(&key);
    try platform_atomic_file.writeFileReplaceSafeWithOptions(path, &key, .{ .mode = 0o600 });
    return key;
}
