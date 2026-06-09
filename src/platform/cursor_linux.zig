const std = @import("std");
const c = @import("../apprt/sdl.zig").c;

// One cached SDL_Cursor per SDL_SystemCursor value (SDL_SYSTEM_CURSOR_COUNT = 19).
const N = 19;
var g_cursors: [N]?*c.SDL_Cursor = .{null} ** N;

pub fn set(shape: anytype) void {
    const sys: c.SDL_SystemCursor = switch (shape) {
        .arrow => c.SDL_SYSTEM_CURSOR_DEFAULT,
        .ibeam => c.SDL_SYSTEM_CURSOR_TEXT,
        .size_we => c.SDL_SYSTEM_CURSOR_EW_RESIZE,
        .size_ns => c.SDL_SYSTEM_CURSOR_NS_RESIZE,
        .size_all => c.SDL_SYSTEM_CURSOR_MOVE,
    };

    const idx = @as(usize, @intCast(sys));
    if (idx >= N) return;

    if (g_cursors[idx] == null) {
        g_cursors[idx] = c.SDL_CreateSystemCursor(sys);
    }
    if (g_cursors[idx]) |cur| {
        _ = c.SDL_SetCursor(cur);
    }
}
