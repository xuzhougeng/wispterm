const std = @import("std");
const c = @import("../apprt/sdl.zig").c;

pub const Owner = struct {
    native_window: ?usize = null,
};

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

pub fn writeText(allocator: std.mem.Allocator, owner: Owner, text: []const u8) bool {
    _ = owner;
    // NUL-terminate and hand off to SDL.
    const text_z = allocator.dupeZ(u8, text) catch return false;
    defer allocator.free(text_z);
    return c.SDL_SetClipboardText(text_z.ptr);
}

pub fn readText(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = owner;
    // SDL_GetClipboardText returns an owned char* (never null; "" if empty).
    const raw = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(raw);
    const span = std.mem.span(raw);
    if (span.len == 0) return null;
    return allocator.dupe(u8, span) catch null;
}

pub fn readImageAsPngTemp(allocator: std.mem.Allocator, owner: Owner) ?[]u8 {
    _ = allocator;
    _ = owner;
    // Image paste is deferred on Linux.
    return null;
}

pub fn normalizeText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            try out.append(allocator, '\n');
            i += 1;
            if (i < text.len and text[i] == '\n') i += 1;
            continue;
        }

        try out.append(allocator, text[i]);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}
