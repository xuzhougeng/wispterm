const std = @import("std");
const c = @import("../apprt/sdl.zig").c;
const platform_dirs = @import("dirs.zig");

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
    _ = owner;
    // Most Linux screenshot tools and browsers expose pasted images as
    // image/png on the clipboard. Pull that target through SDL's clipboard
    // data provider and spill it to a temp file the terminal can reference.
    var size: usize = 0;
    const raw = c.SDL_GetClipboardData("image/png", &size) orelse return null;
    defer c.SDL_free(raw);
    if (size == 0) return null;

    const bytes = @as([*]const u8, @ptrCast(raw))[0..size];
    return writeClipboardPngTemp(allocator, bytes);
}

fn writeClipboardPngTemp(allocator: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const dir = platform_dirs.tempDir(allocator) catch return null;
    defer allocator.free(dir);

    const ts = std.time.milliTimestamp();
    const path = std.fmt.allocPrint(allocator, "{s}/wispterm-clipboard-{d}.png", .{ dir, ts }) catch return null;
    var keep_path = false;
    defer if (!keep_path) allocator.free(path);

    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return null;
    defer file.close();
    file.writeAll(bytes) catch return null;

    keep_path = true;
    return path;
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
