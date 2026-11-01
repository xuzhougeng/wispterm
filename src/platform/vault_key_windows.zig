//! Windows: the key lives in `<config-dir>/passwords.key`, sealed with DPAPI
//! (CryptProtectData) so it only unseals under this Windows user account.
const std = @import("std");
const windows = std.os.windows;
const platform_dirs = @import("dirs.zig");
const platform_atomic_file = @import("atomic_file.zig");

const DATA_BLOB = extern struct {
    cbData: u32,
    pbData: ?[*]u8,
};

const CRYPTPROTECT_UI_FORBIDDEN: u32 = 0x1;

extern "crypt32" fn CryptProtectData(
    data_in: *const DATA_BLOB,
    description: ?[*:0]const u16,
    entropy: ?*const DATA_BLOB,
    reserved: ?*anyopaque,
    prompt: ?*anyopaque,
    flags: u32,
    data_out: *DATA_BLOB,
) callconv(.winapi) windows.BOOL;

extern "crypt32" fn CryptUnprotectData(
    data_in: *const DATA_BLOB,
    description: ?*?[*:0]u16,
    entropy: ?*const DATA_BLOB,
    reserved: ?*anyopaque,
    prompt: ?*anyopaque,
    flags: u32,
    data_out: *DATA_BLOB,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// Ties the blob to WispTerm so a generic DPAPI unseal of the file fails.
const entropy_bytes = "WispTerm Password Store";

fn blob(bytes: []const u8) DATA_BLOB {
    return .{ .cbData = @intCast(bytes.len), .pbData = @constCast(bytes.ptr) };
}

pub fn loadOrCreate(allocator: std.mem.Allocator) ![32]u8 {
    const path = try platform_dirs.pathInConfigDir(allocator, "passwords.key");
    defer allocator.free(path);
    const entropy = blob(entropy_bytes);

    if (std.fs.cwd().readFileAlloc(allocator, path, 4096)) |sealed| {
        defer allocator.free(sealed);
        var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
        if (CryptUnprotectData(&blob(sealed), null, &entropy, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) return error.KeyUnsealFailed;
        defer {
            if (out.pbData) |p| std.crypto.secureZero(u8, p[0..out.cbData]);
            _ = LocalFree(out.pbData);
        }
        if (out.cbData != 32) return error.KeyUnsealFailed;
        var key: [32]u8 = undefined;
        @memcpy(&key, out.pbData.?[0..32]);
        return key;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);
    var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (CryptProtectData(&blob(&key), null, &entropy, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) return error.KeySealFailed;
    defer _ = LocalFree(out.pbData);
    try platform_atomic_file.writeFileReplaceSafeWithOptions(path, out.pbData.?[0..out.cbData], .{});
    return key;
}
