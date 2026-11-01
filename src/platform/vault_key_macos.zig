//! macOS: the key is a generic-password item in the login Keychain, created by
//! WispTerm itself so only WispTerm reads it without a Keychain prompt.
const std = @import("std");

extern fn wispterm_macos_vault_key(out: [*]u8, len: i32) i32;

pub fn loadOrCreate(_: std.mem.Allocator) ![32]u8 {
    var key: [32]u8 = undefined;
    const status = wispterm_macos_vault_key(&key, key.len);
    if (status != 0) {
        std.log.warn("password store: Keychain error {d}", .{status});
        return error.KeychainUnavailable;
    }
    return key;
}
