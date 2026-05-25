const std = @import("std");

pub const Reservation = struct {
    handle: ?std.os.windows.HANDLE = null,

    pub fn deinit(self: *Reservation) void {
        if (self.handle) |handle| {
            std.os.windows.CloseHandle(handle);
            self.handle = null;
        }
    }
};

pub fn reserveSessionKey(allocator: std.mem.Allocator, session_key: []const u8) !?Reservation {
    const name_w = try sessionKeyMutexName(allocator, session_key);
    defer allocator.free(name_w);

    const handle = CreateMutexW(null, 0, name_w.ptr) orelse return error.CreateMutexFailed;
    if (std.os.windows.kernel32.GetLastError() == .ALREADY_EXISTS) {
        std.os.windows.CloseHandle(handle);
        return null;
    }

    return .{ .handle = handle };
}

extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*anyopaque,
    bInitialOwner: std.os.windows.BOOL,
    lpName: std.os.windows.LPCWSTR,
) callconv(.winapi) ?std.os.windows.HANDLE;

fn sessionKeyMutexName(allocator: std.mem.Allocator, session_key: []const u8) ![:0]u16 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session_key, &digest, .{});

    const prefix = "Local\\PhanttyRemoteSessionKey-";
    var ascii: [prefix.len + digest.len * 2]u8 = undefined;
    @memcpy(ascii[0..prefix.len], prefix);

    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        ascii[prefix.len + i * 2] = hex[byte >> 4];
        ascii[prefix.len + i * 2 + 1] = hex[byte & 0x0f];
    }

    return std.unicode.utf8ToUtf16LeAllocZ(allocator, ascii[0..]);
}
