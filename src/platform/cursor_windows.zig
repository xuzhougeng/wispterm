const std = @import("std");

pub fn set(shape: anytype) void {
    _ = SetCursor(LoadCursorW(null, cursorResource(shape)));
}

fn cursorResource(shape: anytype) usize {
    return switch (shape) {
        .arrow => 32512,
        .ibeam => 32513,
        .size_we => 32644,
        .size_ns => 32645,
        .size_all => 32646,
    };
}

extern "user32" fn LoadCursorW(hInstance: ?std.os.windows.HINSTANCE, lpCursorName: usize) callconv(.winapi) ?HCURSOR;
extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;

const HCURSOR = *opaque {};
