const std = @import("std");

extern "kernel32" fn CompareStringOrdinal(
    lpString1: [*]const u16,
    cchCount1: i32,
    lpString2: [*]const u16,
    cchCount2: i32,
    bIgnoreCase: i32,
) callconv(.winapi) i32;

pub fn nativeOrdinalIgnoreCaseUtf8Equal(a: []const u8, b: []const u8) ?bool {
    var a_buf: [4096]u16 = undefined;
    var b_buf: [4096]u16 = undefined;
    const a_len = std.unicode.utf8ToUtf16Le(&a_buf, a) catch return null;
    const b_len = std.unicode.utf8ToUtf16Le(&b_buf, b) catch return null;
    const result = CompareStringOrdinal(
        a_buf[0..a_len].ptr,
        @intCast(a_len),
        b_buf[0..b_len].ptr,
        @intCast(b_len),
        1,
    );
    return switch (result) {
        2 => true,
        1, 3 => false,
        else => null,
    };
}
