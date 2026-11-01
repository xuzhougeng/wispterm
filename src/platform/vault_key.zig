//! The password store's 32-byte encryption key, held by the OS instead of
//! sitting next to the vault in the clear: the login Keychain on macOS, a
//! DPAPI-sealed file on Windows. Because only WispTerm (not a shell the agent
//! drives) can unseal it without a prompt, `cat passwords` shows ciphertext and
//! every agent use has to go through the approved `password_input` path.
const std = @import("std");
const builtin = @import("builtin");

pub const KEY_LEN = 32;
pub const Key = [KEY_LEN]u8;

const impl = switch (builtin.os.tag) {
    .macos => @import("vault_key_macos.zig"),
    .windows => @import("vault_key_windows.zig"),
    else => @import("vault_key_file.zig"),
};

/// Serializes first-use creation: the UI thread and an agent worker must never
/// each mint a different key.
var mutex: std.Thread.Mutex = .{};

/// Fetch the key, creating it on first use.
pub fn loadOrCreate(allocator: std.mem.Allocator) !Key {
    mutex.lock();
    defer mutex.unlock();
    return impl.loadOrCreate(allocator);
}
