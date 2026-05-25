const std = @import("std");
const windows = std.os.windows;

extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.winapi) usize;

pub fn open(allocator: std.mem.Allocator, request: anytype) bool {
    const sw_shownormal: c_int = 1;

    const url_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.url) catch return false;
    defer allocator.free(url_w);

    const result = ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        url_w.ptr,
        null,
        null,
        sw_shownormal,
    );
    if (!shellExecuteSucceeded(result)) {
        std.debug.print("System browser open failed for {s}: ShellExecuteW returned {d}\n", .{ request.url, result });
        return false;
    }
    return true;
}

fn shellExecuteSucceeded(result: usize) bool {
    return result > 32;
}

test "Windows open-url backend treats native return values at or below 32 as failures" {
    try std.testing.expect(!shellExecuteSucceeded(0));
    try std.testing.expect(!shellExecuteSucceeded(2));
    try std.testing.expect(!shellExecuteSucceeded(31));
    try std.testing.expect(!shellExecuteSucceeded(32));
}

test "Windows open-url backend treats native return values above 32 as success" {
    try std.testing.expect(shellExecuteSucceeded(33));
}
